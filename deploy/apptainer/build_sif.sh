#!/usr/bin/env bash
# ==============================================================================
# Build the phamseek Apptainer image.
# ------------------------------------------------------------------------------
# Stages the inputs phamseek.def expects, then runs `apptainer build`.
# The image never solves or downloads conda packages: it consumes the pixi-pack
# payload produced by deploy/pack_offline.sh, so the container and the offline
# bundle contain byte-identical software.
#
# Usage:
#   ./build_sif.sh [--bundle DIR] [--out FILE] [--platform PLAT] [--no-test]
#
# With no arguments it uses the newest bundle in <repo>/dist for this machine's
# platform, and writes to $VPIPE_SIF_DIR (default ~/singularity).
#
# Exit codes: 0 ok · 1 build failure · 3 usage error
# ==============================================================================

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
DEPLOY_DIR="$(dirname "${SCRIPT_DIR}")"
REPO_ROOT="$(dirname "${DEPLOY_DIR}")"
readonly SCRIPT_PATH SCRIPT_DIR DEPLOY_DIR REPO_ROOT

BUNDLE=""; OUT=""; PLATFORM=""; RUN_TEST=1

usage() {
    cat <<EOF
Build the phamseek Apptainer image.

Usage: ${SCRIPT_PATH} [options]

  --bundle DIR    offline bundle directory from deploy/pack_offline.sh
                  (default: newest matching bundle in ${REPO_ROOT}/dist)
  --out FILE      output .sif path
                  (default: \${VPIPE_SIF_DIR:-\$HOME/singularity}/phamseek-<ver>-<arch>.img)
  --platform PLAT linux-64 or linux-aarch64 (default: this machine's)
  --no-test       skip the %test block
  -h, --help      this text

Build the bundle first if you have not:
  ${DEPLOY_DIR}/pack_offline.sh --platform linux-aarch64
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle)     BUNDLE="${2:-}"; shift 2 ;;
        --bundle=*)   BUNDLE="${1#*=}"; shift ;;
        --out)        OUT="${2:-}"; shift 2 ;;
        --out=*)      OUT="${1#*=}"; shift ;;
        --platform)   PLATFORM="${2:-}"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        --no-test)    RUN_TEST=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "build_sif: unknown option '$1' (try --help)" >&2; exit 3 ;;
    esac
done

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v apptainer >/dev/null 2>&1 || die "apptainer not found on PATH"

if [[ -z "${PLATFORM}" ]]; then
    case "$(uname -m)" in
        x86_64)  PLATFORM="linux-64" ;;
        aarch64) PLATFORM="linux-aarch64" ;;
        *) die "unsupported host architecture $(uname -m)" ;;
    esac
fi

# Apptainer builds natively only. Cross-architecture builds need qemu, which is
# deliberately out of scope: build each architecture on its own machine.
HOST_PLATFORM="$( [[ "$(uname -m)" == "x86_64" ]] && echo linux-64 || echo linux-aarch64 )"
if [[ "${PLATFORM}" != "${HOST_PLATFORM}" ]]; then
    die "cannot build a ${PLATFORM} image on a ${HOST_PLATFORM} machine.
       Copy this repository and the ${PLATFORM} bundle to a ${PLATFORM} host and run this script there."
fi

if [[ -z "${BUNDLE}" ]]; then
    BUNDLE="$(find "${REPO_ROOT}/dist" -maxdepth 1 -type d -name "phamseek-offline-*-${PLATFORM}" 2>/dev/null | sort | tail -n1)"
    [[ -n "${BUNDLE}" ]] || die "no bundle found in ${REPO_ROOT}/dist for ${PLATFORM}.
       Build one first: ${DEPLOY_DIR}/pack_offline.sh --platform ${PLATFORM}"
fi
BUNDLE="$(readlink -f "${BUNDLE}")"
[[ -f "${BUNDLE}/env/phamseek-env.sh" ]] || die "no environment payload at ${BUNDLE}/env/phamseek-env.sh"
[[ -d "${BUNDLE}/pipeline" ]] || die "no pipeline/ in ${BUNDLE}"

VERSION="$(awk -F'\t' '$1 == "pipeline_version" {print $2}' "${BUNDLE}/MANIFEST.tsv" 2>/dev/null || true)"
# Fall back to the manifest in the checkout rather than to a literal: a hardcoded
# version silently names the image after whatever release it was written for.
[[ -n "${VERSION}" ]] || VERSION="$(sed -n "s/^ *version *= *'\(.*\)'.*/\1/p" "${REPO_ROOT}/nextflow.config" | head -n1)"
[[ -n "${VERSION}" ]] || die "cannot determine the pipeline version from ${BUNDLE}/MANIFEST.tsv or nextflow.config"

# ~/singularity is the local convention (VPIPE_SIF_DIR default), not ~/apptainer.
SIF_DIR="${VPIPE_SIF_DIR:-${HOME}/singularity}"
OUT="${OUT:-${SIF_DIR}/phamseek-${VERSION}-$(uname -m).img}"
mkdir -p "$(dirname "${OUT}")"
OUT="$(readlink -f "$(dirname "${OUT}")")/$(basename "${OUT}")"

# --- stage ---------------------------------------------------------------------
# %files paths in a def file resolve against the build's working directory, so
# everything must sit together in one staging directory.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phamseek-sif-stage.XXXXXX")"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

log "Bundle : ${BUNDLE}"
log "Output : ${OUT}"
log "Staging: ${STAGE}"

cp -a "${BUNDLE}/env/phamseek-env.sh" "${STAGE}/phamseek-env.sh"
cp -a "${BUNDLE}/pipeline"            "${STAGE}/pipeline"
if [[ -d "${BUNDLE}/nxf-home" ]]; then
    cp -a "${BUNDLE}/nxf-home" "${STAGE}/nxf-home"
else
    mkdir -p "${STAGE}/nxf-home/plugins"
fi
cp -a "${SCRIPT_DIR}/phamseek.def" "${STAGE}/phamseek.def"

# --- build ---------------------------------------------------------------------
# --fakeroot lets an unprivileged user run apt-get inside %post. Fall back to a
# plain build (works when the builder is configured for it) and say so clearly.
BUILD_ARGS=()
[[ "${RUN_TEST}" -eq 0 ]] && BUILD_ARGS+=(--notest)

log "Building (apt + a 1.6 GiB unpack inside %post; expect several minutes)"
if ! ( cd "${STAGE}" && apptainer build --fakeroot "${BUILD_ARGS[@]}" "${OUT}" phamseek.def ); then
    log "--fakeroot build failed; retrying without it"
    ( cd "${STAGE}" && apptainer build "${BUILD_ARGS[@]}" "${OUT}" phamseek.def ) \
        || die "apptainer build failed.
       If the error mentions fakeroot or user namespaces, ask an administrator to
       run: sudo apptainer config fakeroot --add \$USER"
fi

[[ -f "${OUT}" ]] || die "build reported success but ${OUT} does not exist"
sha256sum "${OUT}" > "${OUT}.sha256"

cat <<EOF

Built.

  image    : ${OUT}  ($(du -h "${OUT}" | cut -f1))
  checksum : ${OUT}.sha256

Smoke test:
  apptainer exec --cleanenv "${OUT}" kraken2 --version
  apptainer exec --cleanenv "${OUT}" nextflow -version

Run, with the databases bound read-only:
  apptainer run --cleanenv \\
    -B /data/run01:/work \\
    -B /data/databases:/db:ro \\
    "${OUT}" --input /work/samplesheet.csv --outdir /work/results --db_dir /db
EOF
