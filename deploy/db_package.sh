#!/usr/bin/env bash
# ==============================================================================
# Package a reference database for transfer to the collaborator.
# ------------------------------------------------------------------------------
# Produces a split, checksummed, self-describing package:
#
#   <out>/<name>_<date>/
#     MANIFEST.tsv          provenance + per-file SHA-256 of the database contents
#     SHA256SUMS.volumes    SHA-256 of every transfer volume and of the whole archive
#     SMOKE_EXPECTED.tsv    kraken2 calls this database produced HERE, on a fixed
#                           input, so the receiving side can prove it got the same
#                           database and not merely the same bytes
#     smoke_contigs.fna     the fixed input for the above
#     db_verify.sh          the receiver-side verifier (self-contained copy)
#     README.txt
#     volumes/<name>.tar.zst.part-000 ...   2 GiB volumes
#
# Works for any database directory: kraken2, genomad_db, checkv-db, a bowtie2
# host index. The kraken2-specific smoke test runs only when the directory
# actually looks like a kraken2 database.
#
# Usage:
#   ./db_package.sh --db-dir /home/allen/data2/db/kraken2/inphared_7Apr2026 \
#                   --name inphared_7Apr2026 --out /mnt/nas26/outbox
#
# Exit codes: 0 ok · 1 failure · 3 usage error
# ==============================================================================

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
readonly SCRIPT_PATH SCRIPT_DIR

DB_DIR=""; NAME=""; OUT_ROOT=""; VOLUME_SIZE="2G"; ZSTD_LEVEL=""
SOURCE_NOTE=""; SKIP_SMOKE=0; THREADS="4"; SIGN_KEY=""; NO_HOST_META=0

usage() {
    cat <<EOF
Package a reference database for transfer.

Usage: ${SCRIPT_PATH} --db-dir DIR --name NAME [options]

  --db-dir DIR       the database directory to package (required)
  --name NAME        package name, e.g. inphared_7Apr2026 (default: basename of --db-dir)
  --out DIR          output root (default: \$PWD/db-packages)
  --volume-size SZ   split size, split(1) syntax (default: 2G)
  --level N          zstd compression level. Default is chosen from the database size:
                     3 above 2 GiB, 19 below. Override only with a reason.
  --source TEXT      free-text provenance note recorded in the manifest
  --threads N        threads for zstd and the kraken2 smoke test (default: 4)
  --sign KEYID       GPG-sign MANIFEST.tsv and SHA256SUMS.volumes (detached, armored).
                     Checksums prove integrity; only a signature proves authorship.
  --no-host-metadata omit our hostname and absolute source path from the manifest
                     (some sites treat internal paths as information disclosure)
  --skip-smoke       do not run the kraken2 functional check
  -h, --help         this text

Sizing note: a kraken2 hash table is close to incompressible, so level 19 on a
multi-GiB database costs about an hour of CPU and saves almost nothing. That is why
the default is size-dependent rather than a fixed 19.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-dir)       DB_DIR="${2:-}"; shift 2 ;;
        --db-dir=*)     DB_DIR="${1#*=}"; shift ;;
        --name)         NAME="${2:-}"; shift 2 ;;
        --name=*)       NAME="${1#*=}"; shift ;;
        --out)          OUT_ROOT="${2:-}"; shift 2 ;;
        --out=*)        OUT_ROOT="${1#*=}"; shift ;;
        --volume-size)  VOLUME_SIZE="${2:-}"; shift 2 ;;
        --volume-size=*) VOLUME_SIZE="${1#*=}"; shift ;;
        --level)        ZSTD_LEVEL="${2:-}"; shift 2 ;;
        --level=*)      ZSTD_LEVEL="${1#*=}"; shift ;;
        --source)       SOURCE_NOTE="${2:-}"; shift 2 ;;
        --source=*)     SOURCE_NOTE="${1#*=}"; shift ;;
        --threads)      THREADS="${2:-}"; shift 2 ;;
        --threads=*)    THREADS="${1#*=}"; shift ;;
        --sign)         SIGN_KEY="${2:-}"; shift 2 ;;
        --sign=*)       SIGN_KEY="${1#*=}"; shift ;;
        --no-host-metadata) NO_HOST_META=1; shift ;;
        --skip-smoke)   SKIP_SMOKE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "db_package: unknown option '$1' (try --help)" >&2; exit 3 ;;
    esac
done

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

[[ -n "${DB_DIR}" ]] || { usage; exit 3; }
DB_DIR="$(readlink -f "${DB_DIR}")"
[[ -d "${DB_DIR}" ]] || die "not a directory: ${DB_DIR}"
NAME="${NAME:-$(basename "${DB_DIR}")}"
OUT_ROOT="$(readlink -f "${OUT_ROOT:-${PWD}/db-packages}")"

need tar; need zstd; need sha256sum; need split; need find

DATE_TAG="$(date -u '+%Y%m%d')"
PKG_DIR="${OUT_ROOT}/${NAME}_${DATE_TAG}"
VOL_DIR="${PKG_DIR}/volumes"
ARCHIVE_BASE="${NAME}.tar.zst"

# --- capacity check before we start writing GB ---------------------------------
# Never probe with a bare global df: an offline network mount hangs it forever.
DB_BYTES="$(timeout 300 du -sb "${DB_DIR}" 2>/dev/null | awk '{print $1}')"
[[ -n "${DB_BYTES}" ]] || die "could not measure the size of ${DB_DIR}"
mkdir -p "${VOL_DIR}"
OUT_FREE_KB="$(timeout 15 df -Pk "${PKG_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "${OUT_FREE_KB}" ]] && [[ "${OUT_FREE_KB}" -lt $((DB_BYTES / 1024)) ]]; then
    die "not enough free space in ${OUT_ROOT}: need at least $((DB_BYTES / 1024 / 1024)) MiB, have $((OUT_FREE_KB / 1024)) MiB"
fi

# Pick the compression level from the data unless the caller insisted.
# kraken2 hash tables are near-random bytes: level 19 buys a few percent for an
# order of magnitude more CPU. Below ~2 GiB the absolute cost is small enough
# that the better ratio is worth having.
LEVEL_REASON=""
if [[ -z "${ZSTD_LEVEL}" ]]; then
    if [[ "${DB_BYTES}" -gt 2147483648 ]]; then
        ZSTD_LEVEL=3
        LEVEL_REASON="auto: database is over 2 GiB, and a kraken2 hash table barely compresses"
    else
        ZSTD_LEVEL=19
        LEVEL_REASON="auto: database is under 2 GiB, so the better ratio is cheap"
    fi
fi

log "Database : ${DB_DIR}  ($(numfmt --to=iec "${DB_BYTES}" 2>/dev/null || echo "${DB_BYTES} B"))"
log "Package  : ${PKG_DIR}"
log "Volumes  : ${VOLUME_SIZE} each, zstd -${ZSTD_LEVEL}${LEVEL_REASON:+  (${LEVEL_REASON})}"

# ==============================================================================
# 1. Functional expectation: what does this database actually DO?
# ------------------------------------------------------------------------------
# Checksums prove the bytes arrived. They do not prove the receiving side
# pointed kraken2 at the right directory, or that their kraken2 reads it the
# same way. Recording the classification of a fixed input closes that gap.
# ==============================================================================
SMOKE_INPUT="${SCRIPT_DIR}/assets/smoke_contigs.fna"
SMOKE_DONE=0
if [[ "${SKIP_SMOKE}" -eq 0 && -f "${DB_DIR}/hash.k2d" ]]; then
    if ! command -v kraken2 >/dev/null 2>&1; then
        warn "kraken2 not on PATH — skipping the functional check (activate the phamseek environment to include it)"
    elif [[ ! -f "${SMOKE_INPUT}" ]]; then
        warn "smoke input not found at ${SMOKE_INPUT} — skipping the functional check"
    else
        log "Running the kraken2 functional check against the source database"
        SMOKE_TMP="$(mktemp -d)"
        trap 'rm -rf "${SMOKE_TMP}"' EXIT
        kraken2 --db "${DB_DIR}" --threads "${THREADS}" --confidence 0.02 \
                --output "${SMOKE_TMP}/out.kraken" --report "${SMOKE_TMP}/out.report" \
                "${SMOKE_INPUT}" > "${SMOKE_TMP}/stderr.txt" 2>&1 \
            || die "kraken2 failed on the source database — do not ship it. See ${SMOKE_TMP}/stderr.txt"
        # Sequences assigned anywhere in the Viruses (10239) clade. This, not
        # "was it classified", is the phage-detection criterion: on a database
        # with decoys, a bacterial contig called Bacteria is the right answer.
        VIRAL_N="$(awk -F'\t' '$5 == 10239 {print $2; exit}' "${SMOKE_TMP}/out.report")"
        VIRAL_N="${VIRAL_N:-0}"
        {
            printf '# phamseek kraken2 functional expectation\n'
            printf '# database\t%s\n' "${NAME}"
            printf '# confidence\t0.02\n'
            printf '# input_sha256\t%s\n' "$(sha256sum "${SMOKE_INPUT}" | awk '{print $1}')"
            printf '# viruses_clade_assigned\t%s\n' "${VIRAL_N}"
            printf 'seq_id\tcall\ttaxid\n'
            awk -F'\t' '{print $2"\t"$1"\t"$3}' "${SMOKE_TMP}/out.kraken" | sort
        } > "${PKG_DIR}/SMOKE_EXPECTED.tsv"
        cp -a "${SMOKE_INPUT}" "${PKG_DIR}/smoke_contigs.fna"
        SMOKE_DONE=1
        log "  ${VIRAL_N}/$(grep -c '^>' "${SMOKE_INPUT}") sequences assigned within Viruses (10239)"
    fi
fi

# ==============================================================================
# 2. Manifest: provenance + per-file checksums of the database contents
# ==============================================================================
log "Checksumming database contents (this reads every byte once)"
{
    printf '# phamseek database package manifest\n'
    printf '# name\t%s\n' "${NAME}"
    printf '# packaged_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ "${NO_HOST_META}" -eq 0 ]]; then
        printf '# packaged_on_host\t%s\n' "$(hostname 2>/dev/null || echo unknown)"
        printf '# source_path\t%s\n' "${DB_DIR}"
    fi
    [[ -n "${SOURCE_NOTE}" ]] && printf '# source_note\t%s\n' "${SOURCE_NOTE}"
    printf '# total_bytes\t%s\n' "${DB_BYTES}"
    printf '# archive\t%s\n' "${ARCHIVE_BASE}"
    printf '# volume_size\t%s\n' "${VOLUME_SIZE}"
    printf '# zstd_level\t%s\n' "${ZSTD_LEVEL}"
    printf '# smoke_test\t%s\n' "$( [[ "${SMOKE_DONE}" -eq 1 ]] && echo present || echo absent )"
    # Build parameters, when the database carries them (our kraken2 builds do).
    if [[ -f "${DB_DIR}/opts.k2d" ]]; then
        printf '# kraken2_db\ttrue\n'
        if command -v kraken2-inspect >/dev/null 2>&1 && [[ -f "${DB_DIR}/inspect.txt" ]]; then
            printf '# kraken2_taxa_in_db\t%s\n' "$(grep -cv '^#' "${DB_DIR}/inspect.txt" 2>/dev/null || echo unknown)"
        fi
    fi
    for prov in build.slurm taxonomy_build_report.txt; do
        [[ -f "${DB_DIR}/${prov}" ]] && printf '# provenance_file\t%s\n' "${prov}"
    done
    printf 'path\tsize_bytes\tsha256\n'
    # Sorted, relative paths: the manifest must be reproducible and location-free.
    ( cd "${DB_DIR}" && find . -type f -printf '%P\n' | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\t%s\t%s\n' "${f}" "$(stat -c '%s' "${f}")" "$(sha256sum "${f}" | awk '{print $1}')"
      done )
} > "${PKG_DIR}/MANIFEST.tsv"
log "  $(grep -cv '^#' "${PKG_DIR}/MANIFEST.tsv" | awk '{print $1-1}') files recorded"

# ==============================================================================
# 3. Archive, compress, split
# ==============================================================================
log "Creating volumes"
DB_PARENT="$(dirname "${DB_DIR}")"
DB_BASE="$(basename "${DB_DIR}")"
# --long=31 on BOTH ends. Without it on the decompressing side, a large-window
# frame is REFUSED ("Frame requires too much memory") and looks like corruption.
tar -C "${DB_PARENT}" -cf - "${DB_BASE}" \
    | zstd "-${ZSTD_LEVEL}" -T"${THREADS}" --long=31 -c \
    | split -b "${VOLUME_SIZE}" -d -a 3 --additional-suffix='' - "${VOL_DIR}/${ARCHIVE_BASE}.part-"

VOL_COUNT="$(find "${VOL_DIR}" -maxdepth 1 -type f -name "${ARCHIVE_BASE}.part-*" | wc -l)"
[[ "${VOL_COUNT}" -ge 1 ]] || die "split produced no volumes"
log "  ${VOL_COUNT} volume(s)"

# ==============================================================================
# 4. Volume checksums + the checksum of the reassembled archive
# ==============================================================================
log "Checksumming volumes"
( cd "${VOL_DIR}" && find . -maxdepth 1 -type f -name "${ARCHIVE_BASE}.part-*" -printf '%P\n' \
    | LC_ALL=C sort | xargs sha256sum > "${PKG_DIR}/SHA256SUMS.volumes" )
# Stream the volumes back in lexical order. `split -d -a 3` guarantees lexical
# order == numeric order up to 1000 volumes (2 TiB at 2 GiB each).
cat_volumes() {
    local -a vols
    mapfile -t vols < <(find "${VOL_DIR}" -maxdepth 1 -type f -name "${ARCHIVE_BASE}.part-*" | LC_ALL=C sort)
    cat "${vols[@]}"
}

# The concatenation checksum catches a volume that is individually intact but
# reassembled in the wrong order.
ARCHIVE_SHA="$(cat_volumes | sha256sum | awk '{print $1}')"
printf '# reassembled_archive\t%s\t%s\n' "${ARCHIVE_BASE}" "${ARCHIVE_SHA}" >> "${PKG_DIR}/SHA256SUMS.volumes"

# --- prove the archive actually decompresses before anyone ships it -----------
# `zstd -t` without --long=31 REFUSES large-window frames with "Frame requires
# too much memory for decoding". That is a decoder limit, not corruption; a real
# 8 GiB re-download was nearly triggered by this once.
log "Verifying the archive stream (zstd -t --long=31)"
cat_volumes | zstd -t --long=31 2>&1 | tail -2 \
    || die "the archive does not decompress — do not ship it"

# ==============================================================================
# 5. Ship the verifier and a human-readable note alongside
# ==============================================================================
cp -a "${SCRIPT_DIR}/db_verify.sh" "${PKG_DIR}/db_verify.sh" 2>/dev/null || warn "db_verify.sh not found next to this script"
chmod +x "${PKG_DIR}/db_verify.sh" 2>/dev/null || true

# ==============================================================================
# 5b. Signature — integrity is not authenticity
# ------------------------------------------------------------------------------
# Checksums prove the bytes did not change in transit. They do NOT prove who
# produced them: anyone who can alter the data can recompute the manifest.
# Hospital information security will ask for this. A detached GPG signature over
# the two files that bind everything else is the cheap answer.
if [[ -n "${SIGN_KEY}" ]]; then
    if ! command -v gpg >/dev/null 2>&1; then
        die "--sign requested but gpg is not installed"
    fi
    log "Signing MANIFEST.tsv and SHA256SUMS.volumes with ${SIGN_KEY}"
    for f in MANIFEST.tsv SHA256SUMS.volumes; do
        gpg --batch --yes --local-user "${SIGN_KEY}" \
            --output "${PKG_DIR}/${f}.asc" --armor --detach-sign "${PKG_DIR}/${f}" \
            || die "signing ${f} failed"
    done
    gpg --batch --yes --armor --export "${SIGN_KEY}" > "${PKG_DIR}/signing-key.asc" \
        || warn "could not export the public key"
    log "  wrote MANIFEST.tsv.asc, SHA256SUMS.volumes.asc, signing-key.asc"
else
    warn "package is NOT signed. Checksums prove integrity, not authenticity."
    warn "Hospital IT may require a signature: re-run with --sign <gpg-key-id>."
fi

cat > "${PKG_DIR}/README.txt" <<EOF
phamseek reference database package
===================================

  name              ${NAME}
  packaged (UTC)    $(date -u '+%Y-%m-%dT%H:%M:%SZ')
  uncompressed size $(numfmt --to=iec "${DB_BYTES}" 2>/dev/null || echo "${DB_BYTES} bytes")
  volumes           ${VOL_COUNT} x ${VOLUME_SIZE}

HOW TO RECEIVE IT
-----------------
1. Copy the whole directory. Over the network, resume-safe:

     rsync -av --partial --append-verify \\
           <sender>:/path/to/$(basename "${PKG_DIR}")/ ./$(basename "${PKG_DIR}")/

   On an encrypted external drive, copy the directory as-is.

2. Verify and extract in one step:

     ./db_verify.sh --package-dir ./$(basename "${PKG_DIR}") --dest /path/to/databases

   This checks every volume, reassembles them, extracts, re-checks every file
   inside, and finally runs kraken2 on a fixed input to confirm the database
   behaves the way it did on our machine.

3. The checksums were sent to you over a DIFFERENT channel than the data
   (e.g. data by SFTP, checksums by email). Compare SHA256SUMS.volumes with the
   copy you received separately before trusting anything.

WHAT IS IN HERE
---------------
  MANIFEST.tsv         provenance and a SHA-256 for every file in the database
  SHA256SUMS.volumes   a SHA-256 for every volume, plus one for the whole archive
  SMOKE_EXPECTED.tsv   the classification this database produced on our machine
  smoke_contigs.fna    the fixed 12-sequence input for that check
  db_verify.sh         the verifier described above
  volumes/             the data

MERGING WITH AN EXISTING KRAKEN2 DATABASE
-----------------------------------------
You cannot. Two built kraken2 databases cannot be combined by concatenating
their hash.k2d files: the hash table encodes a single taxonomy and a single
k-mer space. Merging requires the original FASTA libraries of both databases,
a single shared taxonomy snapshot, non-colliding taxids, and a full rebuild
with kraken2-build. Talk to us before attempting it.
EOF

cat <<EOF

Package complete.

  ${PKG_DIR}
  $(du -sh "${PKG_DIR}" | cut -f1) total, ${VOL_COUNT} volume(s)

Next:
  1. Transfer ${PKG_DIR} to the collaborator (SFTP / Nextcloud / encrypted disk).
     rsync -av --partial --append-verify ${PKG_DIR}/ <target>:<path>/
  2. Send ${PKG_DIR}/SHA256SUMS.volumes over a SEPARATE channel.
  3. They run: ./db_verify.sh --package-dir <dir> --dest <databases>
EOF
