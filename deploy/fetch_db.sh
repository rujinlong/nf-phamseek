#!/usr/bin/env bash
# ==============================================================================
# phamseek — download the reference databases
# ------------------------------------------------------------------------------
# One command, one dependency: curl. No Nextflow, no container, no Python, no
# rclone, no Google account. Run this BEFORE the pipeline -- nothing else works
# without these files.
#
#   ./fetch_db.sh --outdir /data/phamseek_db
#   nextflow run rujinlong/nf-phamseek -profile apptainer --db_dir /data/phamseek_db ...
#
# Downloads are resumable: re-run the same command after an interruption and it
# continues rather than starting over. Already-verified components are skipped.
#
# Exit codes: 0 ok · 1 download/verify failure · 3 usage error
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Components. FILE_ID is the Google Drive file id; SHA256 pins the archive.
#
# The sizes are the DOWNLOAD sizes. Unpacked they are larger -- see NEED_GB,
# which is checked against free space before anything is fetched, because
# running out of disk 6 GB into an 11 GB download is a bad way to find out.
# ------------------------------------------------------------------------------
KRAKEN2_ID="1ZvbHa1vLyyhtNSfrJsutUVIqDbCUi3LQ"
KRAKEN2_SHA="cbc5c7cc5f1334bc96294213ef4f7898c861ab7b244b93f3724a1049cb15303d"
KRAKEN2_ARCHIVE="phamseek-db-kraken2-inphared_decoy.tar.zst"

HOST_ID="1b_dXiGrhVweuGK68fsIl-iIstI5S51LU"
HOST_SHA="44725ef15483e1404ec61b787f95d3eeb2f31d3b028fda70cf50252bdd9974a9"
HOST_ARCHIVE="phamseek-db-host-chm13v2.tar.zst"

NEED_GB=32          # unpacked databases + the archives, before cleanup

OUTDIR=""
COMPONENT="all"
KEEP_ARCHIVES=0

usage() {
    cat <<EOF
Download the phamseek reference databases.

Usage: $0 --outdir DIR [options]

  --outdir DIR        where to put them. Pass this same path to the pipeline
                      as --db_dir. Required.
  --component NAME    all (default) | kraken2 | host
  --keep-archives     keep the .tar.zst files after unpacking
                      (default: delete them, they are ~11 GB)
  -h, --help          this text

Produces the layout the pipeline expects:

  DIR/kraken2/   hash.k2d, opts.k2d, taxo.k2d, taxonomy/
  DIR/host/      chm13v2.mmi

Needs ~${NEED_GB} GB free while running, ~16 GB once the archives are removed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir)      OUTDIR="${2:-}"; shift 2 ;;
        --outdir=*)    OUTDIR="${1#*=}"; shift ;;
        --component)   COMPONENT="${2:-}"; shift 2 ;;
        --component=*) COMPONENT="${1#*=}"; shift ;;
        --keep-archives) KEEP_ARCHIVES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "fetch_db: unknown option '$1' (try --help)" >&2; exit 3 ;;
    esac
done

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${OUTDIR}" ]] || { usage >&2; exit 3; }
[[ "${COMPONENT}" =~ ^(all|kraken2|host)$ ]] || { echo "fetch_db: --component must be all, kraken2 or host" >&2; exit 3; }

command -v curl >/dev/null 2>&1 || die "curl not found. It is the only requirement."
command -v tar  >/dev/null 2>&1 || die "tar not found."

# sha256sum on Linux, shasum on macOS. The checksum is the only thing that
# decides whether a download succeeded, so refusing to run without one is
# correct -- skipping it silently is not.
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    die "neither sha256sum nor shasum found; cannot verify the download."
fi

# zstd may be absent on a minimal host; GNU tar can still use it if the binary
# exists, so check for the binary rather than tar's flag support.
command -v zstd >/dev/null 2>&1 || die \
"zstd not found. Install it first:
    Debian/Ubuntu : sudo apt-get install zstd
    RHEL/Rocky    : sudo dnf install zstd
    no root       : conda/pixi install zstd, or ask an administrator"

mkdir -p "${OUTDIR}"
OUTDIR="$(cd "${OUTDIR}" && pwd)"

# `df -B` is GNU-only; fall back to POSIX 512-byte blocks elsewhere. A failure
# to measure free space must not stop the download -- it is a warning, not a gate.
avail_gb=$(df -PB1G "${OUTDIR}" 2>/dev/null | awk 'NR==2 {print $4+0}' \
           || df -P "${OUTDIR}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/2/1024/1024}' \
           || echo "${NEED_GB}")
avail_gb=${avail_gb:-${NEED_GB}}
if (( avail_gb < NEED_GB )); then
    warn "only ${avail_gb} GB free at ${OUTDIR}; about ${NEED_GB} GB is needed while unpacking."
    warn "Continuing anyway -- pass --component kraken2 and --component host separately if it runs out."
fi

# ------------------------------------------------------------------------------
# Google Drive, for a file large enough to trip the virus-scan interstitial.
#
# A plain `curl -L "https://drive.google.com/uc?id=..."` returns an HTML warning
# page, not the file, and writes it to the output path -- so the download
# "succeeds", the archive is 3 kB of HTML, and tar reports a corrupt archive.
# The download host below serves the bytes directly when confirm=t is set.
#
# The checksum is what actually decides success. Never trust the transfer.
# ------------------------------------------------------------------------------
gdrive_fetch() {
    local id="$1" dest="$2"
    # A progress bar is useful on a terminal and 40 kB of carriage returns in a
    # log file. This runs under nohup often enough to matter.
    local progress=(--progress-bar)
    [ -t 1 ] || progress=(-sS)
    curl -fL --retry 5 --retry-delay 5 --retry-connrefused \
         -C - "${progress[@]}" \
         -o "${dest}" \
         "https://drive.usercontent.google.com/download?id=${id}&export=download&confirm=t"
}

verify() {
    local file="$1" want="$2"
    log "Verifying $(basename "${file}")"
    local got
    got="$(sha256 "${file}")"
    if [[ "${got}" != "${want}" ]]; then
        if head -c 512 "${file}" | grep -qi '<html\|<!doctype'; then
            die "downloaded an HTML page rather than the archive.
       Google Drive refused the download -- most often the per-file daily
       quota. Wait, or ask for a direct copy."
        fi
        die "checksum mismatch for $(basename "${file}")
       expected ${want}
       got      ${got}
       Delete it and re-run; a partial file resumed from a truncated transfer
       will fail here every time until it is removed."
    fi
}

# $5 is the path that proves the component is INSTALLED (checked before doing
# anything); $6 is what the archive unpacks to, which is not always the same --
# the kraken2 archive unpacks to inphared_decoy/ and is then renamed to
# kraken2/. Checking the unpack path for the skip test would re-download the
# whole 4.7 GB on every subsequent run, because that path no longer exists once
# the rename has happened.
fetch_component() {
    local name="$1" id="$2" sha="$3" archive="$4" installed="$5" unpacked="$6"

    if [[ -e "${OUTDIR}/${installed}" ]]; then
        log "${name}: already present (${OUTDIR}/${installed}) -- skipping"
        return 0
    fi
    if [[ "${id}" == __*__ ]]; then
        die "${name}: this script has no file id compiled in yet.
       You are running a copy from before the databases were published.
       Get the current deploy/fetch_db.sh from
       https://github.com/rujinlong/nf-phamseek"
    fi

    local dest="${OUTDIR}/${archive}"

    # An archive left over from a previous run that unpacked badly is already
    # complete, and `curl -C -` would then ask for a range past the end and get
    # a 416, which -f turns into a hard failure. Check it instead of re-fetching.
    if [[ -f "${dest}" ]] && [[ "$(sha256 "${dest}")" == "${sha}" ]]; then
        log "${name}: ${archive} already downloaded and verified"
    else
        log "${name}: downloading ${archive}"
        gdrive_fetch "${id}" "${dest}" || die "${name}: download failed. Re-run to resume."
        verify "${dest}" "${sha}"
    fi

    log "${name}: unpacking"
    tar -I zstd -xf "${dest}" -C "${OUTDIR}"
    [[ -e "${OUTDIR}/${unpacked}" ]] || die "${name}: unpacked, but ${unpacked} is missing."

    if (( KEEP_ARCHIVES == 0 )); then
        rm -f "${dest}"
    fi
    log "${name}: done"
}

# The kraken2 archive unpacks to inphared_decoy/; the pipeline looks for
# <db_dir>/kraken2. descendIntoSingleDatabase() in the pipeline accepts a single
# nested database, but a plain directory is one less thing to explain.
if [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "kraken2" ]]; then
    fetch_component "kraken2 database" "${KRAKEN2_ID}" "${KRAKEN2_SHA}" \
                    "${KRAKEN2_ARCHIVE}" "kraken2/hash.k2d" "inphared_decoy/hash.k2d"
    if [[ -d "${OUTDIR}/inphared_decoy" && ! -e "${OUTDIR}/kraken2" ]]; then
        mv "${OUTDIR}/inphared_decoy" "${OUTDIR}/kraken2"
    fi
fi

if [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "host" ]]; then
    fetch_component "host reference" "${HOST_ID}" "${HOST_SHA}" \
                    "${HOST_ARCHIVE}" "host/chm13v2.mmi" "host/chm13v2.mmi"
fi

# ------------------------------------------------------------------------------
# Report the layout the pipeline will see, rather than claiming success.
# ------------------------------------------------------------------------------
echo
log "Databases at ${OUTDIR}"
for f in kraken2/hash.k2d kraken2/opts.k2d kraken2/taxo.k2d host/chm13v2.mmi; do
    if [[ -e "${OUTDIR}/${f}" ]]; then
        printf '  %-22s %s\n' "${f}" "$(du -h "${OUTDIR}/${f}" | cut -f1)"
    else
        printf '  %-22s \033[31mMISSING\033[0m\n' "${f}"
    fi
done

cat <<EOF

Run the pipeline against them:

  nextflow run rujinlong/nf-phamseek -profile test,apptainer \\
      --db_dir ${OUTDIR} --outdir test_results

  nextflow run rujinlong/nf-phamseek -profile apptainer \\
      --input samplesheet.csv --db_dir ${OUTDIR} --outdir results
EOF
