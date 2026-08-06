#!/usr/bin/env bash
# ==============================================================================
# Verify (and optionally install) a phamseek reference database package.
# ------------------------------------------------------------------------------
# Runs on the RECEIVING machine. Self-contained: a copy of this script travels
# inside every package produced by deploy/db_package.sh.
#
# Four gates, in order. Each one catches something the previous one cannot:
#
#   1. volumes        every .part-NNN matches SHA256SUMS.volumes
#   2. archive        the volumes concatenate into the recorded stream and the
#                     stream decompresses (catches wrong order / bad ordering)
#   3. contents       every extracted file matches MANIFEST.tsv
#   4. behaviour      kraken2 on a fixed input reproduces SMOKE_EXPECTED.tsv
#                     (catches "verified the wrong directory" and "their kraken2
#                     reads it differently" — checksums cannot)
#
# Usage:
#   ./db_verify.sh --package-dir DIR --dest DIR      # full receive: verify + extract + verify
#   ./db_verify.sh --package-dir DIR --verify-only   # gates 1-2 only, no extraction
#   ./db_verify.sh --db-dir DIR --manifest FILE      # re-check an installed database
#
# Exit codes: 0 all gates passed · 1 a gate failed · 3 usage error
# ==============================================================================

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH

PKG_DIR=""; DEST=""; DB_DIR=""; MANIFEST=""; VERIFY_ONLY=0; SKIP_SMOKE=0; THREADS="4"; KEEP_ARCHIVE=0

usage() {
    cat <<EOF
Verify a phamseek reference database package.

Usage: ${SCRIPT_PATH} [options]

  --package-dir DIR  the package directory you received
  --dest DIR         where to extract the database (required unless --verify-only)
  --verify-only      check the volumes and the archive, do not extract
  --db-dir DIR       re-verify an already-installed database instead
  --manifest FILE    manifest for --db-dir (default: <db-dir>/MANIFEST.tsv)
  --threads N        threads for decompression and the kraken2 check (default: 4)
  --skip-smoke       skip the kraken2 functional check
  --keep-archive     keep the reassembled .tar.zst after extraction
  -h, --help         this text
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package-dir)   PKG_DIR="${2:-}"; shift 2 ;;
        --package-dir=*) PKG_DIR="${1#*=}"; shift ;;
        --dest)          DEST="${2:-}"; shift 2 ;;
        --dest=*)        DEST="${1#*=}"; shift ;;
        --db-dir)        DB_DIR="${2:-}"; shift 2 ;;
        --db-dir=*)      DB_DIR="${1#*=}"; shift ;;
        --manifest)      MANIFEST="${2:-}"; shift 2 ;;
        --manifest=*)    MANIFEST="${1#*=}"; shift ;;
        --threads)       THREADS="${2:-}"; shift 2 ;;
        --threads=*)     THREADS="${1#*=}"; shift ;;
        --verify-only)   VERIFY_ONLY=1; shift ;;
        --skip-smoke)    SKIP_SMOKE=1; shift ;;
        --keep-archive)  KEEP_ARCHIVE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "db_verify: unknown option '$1' (try --help)" >&2; exit 3 ;;
    esac
done

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'
else
    C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi
log()  { printf '%s==>%s %s\n' "${C_BLU}" "${C_RESET}" "$*"; }
ok()   { printf '%s  [PASS]%s %s\n' "${C_GRN}" "${C_RESET}" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "${C_YEL}" "${C_RESET}" "$*" >&2; }
die()  { printf '%s  [FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

need sha256sum; need tar

# ==============================================================================
# Shared: verify extracted files against a manifest
# ==============================================================================
verify_contents() {
    local db="$1" manifest="$2"
    [[ -f "${manifest}" ]] || die "manifest not found: ${manifest}"
    local n_ok=0 n_bad=0 n_missing=0 rel size sha actual actual_size
    # Skip '#' metadata lines and the column header.
    while IFS=$'\t' read -r rel size sha; do
        [[ "${rel}" == \#* || "${rel}" == "path" || -z "${rel}" ]] && continue
        local p="${db}/${rel}"
        if [[ ! -f "${p}" ]]; then
            printf '  missing: %s\n' "${rel}" >&2
            n_missing=$((n_missing + 1)); continue
        fi
        actual_size="$(stat -c '%s' "${p}")"
        if [[ "${actual_size}" != "${size}" ]]; then
            printf '  size mismatch: %s (%s != %s)\n' "${rel}" "${actual_size}" "${size}" >&2
            n_bad=$((n_bad + 1)); continue
        fi
        actual="$(sha256sum "${p}" | awk '{print $1}')"
        if [[ "${actual}" != "${sha}" ]]; then
            printf '  checksum mismatch: %s\n' "${rel}" >&2
            n_bad=$((n_bad + 1)); continue
        fi
        n_ok=$((n_ok + 1))
    done < "${manifest}"
    if [[ "${n_bad}" -gt 0 || "${n_missing}" -gt 0 ]]; then
        die "contents: ${n_ok} ok, ${n_bad} corrupt, ${n_missing} missing"
    fi
    ok "contents: ${n_ok}/${n_ok} files match the manifest"

    # Checking every manifest row proves nothing arrived damaged. It does not
    # prove nothing arrived EXTRA. Compare the two directions.
    local extras
    extras="$( { grep -v '^#' "${manifest}" | tail -n +2 | cut -f1 | LC_ALL=C sort
                 ( cd "${db}" && find . -type f -printf '%P\n' ) | LC_ALL=C sort
               } | LC_ALL=C sort | uniq -u | head -20 )"
    # Files we deliberately place next to the data after extraction are expected.
    extras="$(printf '%s\n' "${extras}" | grep -vE '^(MANIFEST\.tsv|SMOKE_EXPECTED\.tsv|smoke_contigs\.fna)$' | grep -v '^$' || true)"
    if [[ -n "${extras}" ]]; then
        printf '  unexpected files not listed in the manifest:\n' >&2
        printf '    %s\n' ${extras} >&2
        die "the extracted database contains files the manifest does not describe. Do not use it; contact the sender."
    fi
    ok "contents: no unexpected extra files"
}

# ==============================================================================
# Shared: functional check
# ==============================================================================
run_smoke() {
    local db="$1" expected="$2" input="$3"
    [[ "${SKIP_SMOKE}" -eq 1 ]] && { warn "functional check skipped (--skip-smoke)"; return 0; }
    [[ -f "${expected}" && -f "${input}" ]] || { warn "no SMOKE_EXPECTED.tsv / smoke_contigs.fna — functional check skipped"; return 0; }
    if ! command -v kraken2 >/dev/null 2>&1; then
        warn "kraken2 not on PATH — functional check skipped."
        warn "Run this again after 'source ~/phamseek/activate.sh' to complete the last gate."
        return 0
    fi
    # A corrupted transfer of the fixed input would silently change the answer.
    local want_in got_in
    want_in="$(awk -F'\t' '$1 == "# input_sha256" {print $2}' "${expected}")"
    got_in="$(sha256sum "${input}" | awk '{print $1}')"
    if [[ -n "${want_in}" && "${want_in}" != "${got_in}" ]]; then
        die "smoke input checksum mismatch — smoke_contigs.fna is not the file we tested with"
    fi

    local tmp; tmp="$(mktemp -d)"
    log "Gate 4/4: functional check (kraken2 on ${input##*/})"
    kraken2 --db "${db}" --threads "${THREADS}" --confidence 0.02 \
            --output "${tmp}/out.kraken" --report "${tmp}/out.report" \
            "${input}" > "${tmp}/stderr.txt" 2>&1 \
        || { cat "${tmp}/stderr.txt" >&2; rm -rf "${tmp}"; die "kraken2 could not read the database at ${db}"; }

    awk -F'\t' '{print $2"\t"$1"\t"$3}' "${tmp}/out.kraken" | sort > "${tmp}/got.tsv"
    grep -v '^#' "${expected}" | grep -v '^seq_id' | sort > "${tmp}/want.tsv"

    if diff -q "${tmp}/want.tsv" "${tmp}/got.tsv" >/dev/null; then
        local viral
        viral="$(awk -F'\t' '$5 == 10239 {print $2; exit}' "${tmp}/out.report")"
        ok "behaviour: every sequence got the taxid we recorded (${viral:-0} within Viruses/10239)"
        rm -rf "${tmp}"
        return 0
    fi
    printf '%s  differences (expected vs got):%s\n' "${C_RED}" "${C_RESET}" >&2
    diff "${tmp}/want.tsv" "${tmp}/got.tsv" | head -20 >&2
    cp "${tmp}/out.kraken" "${tmp}/out.report" /tmp/ 2>/dev/null || true
    rm -rf "${tmp}"
    die "behaviour: the database classifies differently here than it did on our machine.
       The bytes are fine (gate 3 passed), so this is an environment difference:
       a different kraken2 version, or --db pointing at a nested directory.
       Send us the diff above."
}

# ==============================================================================
# Mode B: re-verify an installed database
# ==============================================================================
if [[ -n "${DB_DIR}" ]]; then
    DB_DIR="$(readlink -f "${DB_DIR}")"
    [[ -d "${DB_DIR}" ]] || die "not a directory: ${DB_DIR}"
    MANIFEST="${MANIFEST:-${DB_DIR}/MANIFEST.tsv}"
    log "Re-verifying installed database: ${DB_DIR}"
    verify_contents "${DB_DIR}" "${MANIFEST}"
    run_smoke "${DB_DIR}" "$(dirname "${MANIFEST}")/SMOKE_EXPECTED.tsv" "$(dirname "${MANIFEST}")/smoke_contigs.fna"
    printf '\n%sAll gates passed.%s\n' "${C_GRN}" "${C_RESET}"
    exit 0
fi

# ==============================================================================
# Mode A: receive a package
# ==============================================================================
[[ -n "${PKG_DIR}" ]] || { usage; exit 3; }
PKG_DIR="$(readlink -f "${PKG_DIR}")"
[[ -d "${PKG_DIR}" ]] || die "not a directory: ${PKG_DIR}"
[[ -f "${PKG_DIR}/SHA256SUMS.volumes" ]] || die "SHA256SUMS.volumes not found in ${PKG_DIR}"
[[ -f "${PKG_DIR}/MANIFEST.tsv" ]] || die "MANIFEST.tsv not found in ${PKG_DIR}"
[[ -d "${PKG_DIR}/volumes" ]] || die "volumes/ not found in ${PKG_DIR}"

NAME="$(awk -F'\t' '$1 == "# name" {print $2}' "${PKG_DIR}/MANIFEST.tsv")"
ARCHIVE_BASE="$(awk -F'\t' '$1 == "# archive" {print $2}' "${PKG_DIR}/MANIFEST.tsv")"
ARCHIVE_BASE="${ARCHIVE_BASE:-${NAME}.tar.zst}"
TOTAL_BYTES="$(awk -F'\t' '$1 == "# total_bytes" {print $2}' "${PKG_DIR}/MANIFEST.tsv")"

printf '%sphamseek database verification%s\n' "${C_BLU}" "${C_RESET}"
printf '  package : %s\n' "${PKG_DIR}"
printf '  database: %s\n\n' "${NAME:-unknown}"

# --- gate 1: volumes ---------------------------------------------------------
log "Gate 1/4: volume checksums"
VOL_LINES="$(grep -cv '^#' "${PKG_DIR}/SHA256SUMS.volumes" || true)"
if ! ( cd "${PKG_DIR}/volumes" && grep -v '^#' "${PKG_DIR}/SHA256SUMS.volumes" | sha256sum -c --quiet ); then
    die "one or more volumes are corrupt or missing.
       Re-transfer only the failing volume(s): rsync --partial --append-verify is safe to re-run."
fi
ok "volumes: ${VOL_LINES}/${VOL_LINES} intact"

# --- gate 2: reassembled archive ---------------------------------------------
log "Gate 2/4: reassembled archive"
need zstd
# LC_ALL=C: a locale-dependent sort could order the volumes differently here than
# it did on the packaging machine, silently reassembling a scrambled archive.
mapfile -t VOLS < <(find "${PKG_DIR}/volumes" -maxdepth 1 -type f -name "${ARCHIVE_BASE}.part-*" | LC_ALL=C sort)
[[ "${#VOLS[@]}" -ge 1 ]] || die "no volumes named ${ARCHIVE_BASE}.part-* in ${PKG_DIR}/volumes"

# Numbering must be 000..N-1 with no gaps, duplicates or extras. Glob order alone
# would happily skip a missing middle volume.
EXPECTED_N="$(grep -cv '^#' "${PKG_DIR}/SHA256SUMS.volumes" || true)"
if [[ "${EXPECTED_N}" -gt 0 && "${#VOLS[@]}" -ne "${EXPECTED_N}" ]]; then
    die "volume count mismatch: found ${#VOLS[@]}, the manifest lists ${EXPECTED_N}.
       A volume is missing from the transfer, or an extra file matched the pattern."
fi
for i in "${!VOLS[@]}"; do
    want="$(printf '%s.part-%03d' "${ARCHIVE_BASE}" "${i}")"
    [[ "$(basename "${VOLS[$i]}")" == "${want}" ]] \
        || die "volume numbering is not contiguous: expected ${want}, found $(basename "${VOLS[$i]}")"
done
ok "volumes: numbering is contiguous 000..$(printf '%03d' $(( ${#VOLS[@]} - 1 )))"

WANT_ARCHIVE_SHA="$(awk -F'\t' '$1 == "# reassembled_archive" {print $3}' "${PKG_DIR}/SHA256SUMS.volumes")"
if [[ -n "${WANT_ARCHIVE_SHA}" ]]; then
    GOT_ARCHIVE_SHA="$(cat "${VOLS[@]}" | sha256sum | awk '{print $1}')"
    [[ "${GOT_ARCHIVE_SHA}" == "${WANT_ARCHIVE_SHA}" ]] \
        || die "the reassembled archive does not match. Individual volumes are intact, so this is an ordering problem — check that no volume is missing from the middle."
    ok "archive: reassembles to the recorded SHA-256"
else
    warn "no reassembled-archive checksum in the package (older packaging script)"
fi

# --long=31 is REQUIRED. Without it zstd refuses large-window frames with
# "Frame requires too much memory for decoding" — a decoder limit that looks
# exactly like corruption. It raises the window cap, not actual memory use.
log "  decompressing to /dev/null to confirm the stream is complete"
cat "${VOLS[@]}" | zstd -t --long=31 >/dev/null 2>&1 \
    || die "the archive does not decompress. If the message mentioned memory, your zstd is too old for --long=31; upgrade zstd."
ok "archive: decompresses cleanly"

if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
    printf '\n%sGates 1-2 passed.%s Re-run without --verify-only, with --dest, to extract.\n' "${C_GRN}" "${C_RESET}"
    exit 0
fi

# --- gate 3: extract + contents ----------------------------------------------
[[ -n "${DEST}" ]] || die "--dest is required (or use --verify-only)"
mkdir -p "${DEST}"
DEST="$(readlink -f "${DEST}")"

# Extraction needs the uncompressed size free; we are streaming, so no room for
# the intermediate archive is needed unless --keep-archive.
if [[ -n "${TOTAL_BYTES}" ]]; then
    FREE_KB="$(timeout 15 df -Pk "${DEST}" 2>/dev/null | awk 'NR==2 {print $4}')"
    NEED_KB=$(( TOTAL_BYTES / 1024 ))
    [[ "${KEEP_ARCHIVE}" -eq 1 ]] && NEED_KB=$(( NEED_KB * 2 ))
    if [[ -n "${FREE_KB}" && "${FREE_KB}" -lt "${NEED_KB}" ]]; then
        die "not enough space in ${DEST}: need $(( NEED_KB / 1024 )) MiB, have $(( FREE_KB / 1024 )) MiB"
    fi
fi

# --- inspect the tar before letting it write anywhere ------------------------
# An archive from outside the institution is untrusted input regardless of who
# sent it. Absolute paths, ../ traversal, symlinks, hard links and device nodes
# all let a tar write outside the destination. A reference database legitimately
# contains nothing but regular files and directories, so anything else is a
# reason to stop.
log "  inspecting archive members before extraction"
BAD_MEMBERS="$(cat "${VOLS[@]}" | zstd -d --long=31 -c | tar -tvf - 2>/dev/null | awk '
    {
        type = substr($1, 1, 1)
        name = $NF
        if (type != "-" && type != "d") { print "non-regular member (" type "): " name; next }
        if (name ~ /^\//)               { print "absolute path: " name; next }
        if (name ~ /(^|\/)\.\.(\/|$)/)  { print "path traversal: " name; next }
    }' | head -20 || true)"
if [[ -n "${BAD_MEMBERS}" ]]; then
    printf '%s\n' "${BAD_MEMBERS}" >&2
    die "the archive contains members that a reference database must not have (see above). Do not extract it; contact the sender."
fi
ok "archive: all members are plain files or directories under a relative path"

log "Gate 3/4: extracting to ${DEST}"
# --no-same-owner: never try to honour the sender's uid/gid.
# --no-same-permissions: apply the local umask instead of the archive's modes.
TAR_SAFE=(--no-same-owner --no-same-permissions)
if [[ "${KEEP_ARCHIVE}" -eq 1 ]]; then
    cat "${VOLS[@]}" > "${DEST}/${ARCHIVE_BASE}"
    zstd -d --long=31 -c "${DEST}/${ARCHIVE_BASE}" | tar -C "${DEST}" "${TAR_SAFE[@]}" -xf -
else
    cat "${VOLS[@]}" | zstd -d --long=31 -c | tar -C "${DEST}" "${TAR_SAFE[@]}" -xf -
fi

# The tar contains a single top-level directory: the database.
EXTRACTED="${DEST}/${NAME}"
if [[ ! -d "${EXTRACTED}" ]]; then
    # Fall back to whatever single directory the tar produced.
    EXTRACTED="$(cat "${VOLS[@]}" | zstd -d --long=31 -c | tar -tf - 2>/dev/null | head -n1 | cut -d/ -f1)"
    EXTRACTED="${DEST}/${EXTRACTED}"
fi
[[ -d "${EXTRACTED}" ]] || die "extraction produced no directory under ${DEST}"
ok "extracted: ${EXTRACTED}"

log "  checking every extracted file against MANIFEST.tsv"
verify_contents "${EXTRACTED}" "${PKG_DIR}/MANIFEST.tsv"

# Keep provenance next to the data so a later --db-dir re-check works standalone.
cp -a "${PKG_DIR}/MANIFEST.tsv" "${EXTRACTED}/MANIFEST.tsv" 2>/dev/null || true
for f in SMOKE_EXPECTED.tsv smoke_contigs.fna; do
    [[ -f "${PKG_DIR}/${f}" ]] && cp -a "${PKG_DIR}/${f}" "${EXTRACTED}/${f}"
done

# --- gate 4: behaviour -------------------------------------------------------
run_smoke "${EXTRACTED}" "${PKG_DIR}/SMOKE_EXPECTED.tsv" "${PKG_DIR}/smoke_contigs.fna"

cat <<EOF

${C_GRN}All gates passed.${C_RESET}

  database installed at : ${EXTRACTED}
  use it with           : --db_dir ${DEST}   (phamseek expects kraken2/ under it)
                          or point --kraken2_db directly at ${EXTRACTED}

  re-check it any time  : ${SCRIPT_PATH} --db-dir ${EXTRACTED}

Next: run the preflight so the RAM check runs against this database.
  <phamseek>/deploy/preflight.sh --offline --db-dir ${EXTRACTED}
EOF
