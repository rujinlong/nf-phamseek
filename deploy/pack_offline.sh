#!/usr/bin/env bash
# ==============================================================================
# Build a fully offline phamseek installation bundle.
# ------------------------------------------------------------------------------
# Run this on a machine WITH internet access. The bundle it produces installs
# phamseek on a machine with NO internet access and no conda.
#
# What goes into the bundle
#   1. env/phamseek-env.sh   self-extracting conda environment (pixi-pack)
#   2. nxf-home/             pre-fetched Nextflow plugins  <- the step everyone
#                            forgets; without it the first run dies trying to
#                            reach github.com
#   3. pipeline/             the pipeline source tree
#   4. install.sh            receiver-side installer (no network, no root)
#   5. SHA256SUMS, MANIFEST.tsv
#
# What does NOT go into the bundle (by design)
#   - reference databases. They are big, they change on their own schedule, and
#     the hospital may already have some. Ship them with deploy/db_package.sh.
#
# Usage:
#   ./pack_offline.sh [--platform linux-64|linux-aarch64] [--outdir DIR]
#                     [--skip-env] [--skip-plugins] [--no-archive]
#
# Exit codes: 0 ok · 1 build failure · 3 usage error
# ==============================================================================

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
readonly SCRIPT_PATH SCRIPT_DIR REPO_ROOT

# ==============================================================================
# Options
# ==============================================================================
PLATFORM=""
OUTDIR=""
SKIP_ENV=0
SKIP_PLUGINS=0
MAKE_ARCHIVE=1

usage() {
    cat <<EOF
Build an offline phamseek installation bundle.

Usage: ${SCRIPT_PATH} [options]

  --platform PLAT   linux-64 (collaborator workstations) or linux-aarch64
                    (DGX Spark). Default: this machine's platform.
  --outdir DIR      where to write the bundle. Default: \$REPO_ROOT/dist
  --skip-env        do not run pixi-pack (reuse an existing env/ payload)
  --skip-plugins    do not pre-fetch Nextflow plugins (NOT recommended)
  --no-archive      leave the bundle as a directory, do not tar it
  -h, --help        this text

IMPORTANT — cross-platform packing:
  --create-executable embeds a pixi-unpack binary that must match the TARGET
  platform. pixi-pack resolves it for --platform, but the safest and verified
  path is to build each platform's bundle ON that platform. For linux-64, run
  this same script on any x86_64 Linux box with internet access; nothing else
  changes.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)   PLATFORM="${2:-}"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        --outdir)     OUTDIR="${2:-}"; shift 2 ;;
        --outdir=*)   OUTDIR="${1#*=}"; shift ;;
        --skip-env)   SKIP_ENV=1; shift ;;
        --skip-plugins) SKIP_PLUGINS=1; shift ;;
        --no-archive) MAKE_ARCHIVE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "pack_offline: unknown option '$1' (try --help)" >&2; exit 3 ;;
    esac
done

if [[ -z "${PLATFORM}" ]]; then
    case "$(uname -m)" in
        x86_64)  PLATFORM="linux-64" ;;
        aarch64) PLATFORM="linux-aarch64" ;;
        *) echo "pack_offline: unsupported host architecture $(uname -m)" >&2; exit 1 ;;
    esac
fi
case "${PLATFORM}" in
    linux-64|linux-aarch64) ;;
    *) echo "pack_offline: --platform must be linux-64 or linux-aarch64" >&2; exit 3 ;;
esac

OUTDIR="${OUTDIR:-${REPO_ROOT}/dist}"
mkdir -p "${OUTDIR}"
OUTDIR="$(readlink -f "${OUTDIR}")"

# ==============================================================================
# Preconditions
# ==============================================================================
log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"; }

need pixi-pack "install with: pixi global install pixi-pack"
need tar
need sha256sum

[[ -f "${REPO_ROOT}/pixi.toml" ]] || die "pixi.toml not found at ${REPO_ROOT}"
[[ -f "${REPO_ROOT}/pixi.lock" ]] || die "pixi.lock not found at ${REPO_ROOT} — run 'pixi install' first"

PIPELINE_VERSION="$(grep -E '^version *=' "${REPO_ROOT}/pixi.toml" | head -n1 | sed 's/.*"\(.*\)".*/\1/')"
PIPELINE_VERSION="${PIPELINE_VERSION:-0.0.0}"

BUNDLE_NAME="phamseek-offline-v${PIPELINE_VERSION}-${PLATFORM}"
BUNDLE_DIR="${OUTDIR}/${BUNDLE_NAME}"

log "Bundle:   ${BUNDLE_DIR}"
log "Platform: ${PLATFORM}"
log "Version:  ${PIPELINE_VERSION}"

# Rebuild everything except the env payload, which --skip-env exists to reuse.
if [[ "${SKIP_ENV}" -eq 1 && -f "${BUNDLE_DIR}/env/phamseek-env.sh" ]]; then
    log "--skip-env: keeping the existing environment payload"
    rm -rf "${BUNDLE_DIR}/pipeline" "${BUNDLE_DIR}/nxf-home" \
           "${BUNDLE_DIR}/install.sh" "${BUNDLE_DIR}/MANIFEST.tsv" "${BUNDLE_DIR}/SHA256SUMS"
else
    rm -rf "${BUNDLE_DIR}"
fi
mkdir -p "${BUNDLE_DIR}/env" "${BUNDLE_DIR}/pipeline" "${BUNDLE_DIR}/nxf-home"

# ==============================================================================
# 1. Conda environment (pixi-pack)
# ==============================================================================
ENV_PAYLOAD="${BUNDLE_DIR}/env/phamseek-env.sh"
if [[ "${SKIP_ENV}" -eq 1 ]]; then
    warn "--skip-env: no environment payload will be built"
else
    log "Packing the conda environment for ${PLATFORM} (this downloads ~2 GiB, takes a few minutes)"
    # --create-executable makes a self-extracting .sh with pixi-unpack embedded,
    # so the target machine needs nothing but bash + tar.
    ( cd "${REPO_ROOT}" && pixi-pack \
        --platform "${PLATFORM}" \
        --environment default \
        --create-executable \
        --output-file "${ENV_PAYLOAD}" \
        "${REPO_ROOT}" ) || die "pixi-pack failed"
    [[ -s "${ENV_PAYLOAD}" ]] || die "pixi-pack produced no output at ${ENV_PAYLOAD}"
    chmod +x "${ENV_PAYLOAD}"
    log "Environment payload: $(du -h "${ENV_PAYLOAD}" | cut -f1)"
fi

# ==============================================================================
# 2. Nextflow plugins — the classic offline trap
# ==============================================================================
# nextflow.config declares plugins with `id 'name@version'`. On first run
# Nextflow fetches the index from raw.githubusercontent.com and the zip from
# github.com. On a hospital network that is a hard failure with an unhelpful
# message. We pre-populate NXF_HOME/plugins here and ship it.
#
# Note: the framework jar itself does NOT need pre-fetching. The bioconda
# `nextflow` package ships nextflow-<ver>-one.jar in $PREFIX/share/nextflow/dist,
# so the launcher never downloads it. Verified on 2026-08-07 with a clean
# NXF_HOME: `nextflow -version` created no framework/ or capsule/ directory.
if [[ "${SKIP_PLUGINS}" -eq 1 ]]; then
    warn "--skip-plugins: the first run on the target machine WILL try to reach github.com"
else
    mapfile -t PLUGIN_IDS < <(
        grep -oE "id +'[A-Za-z0-9._-]+@[0-9][0-9A-Za-z._-]*'" "${REPO_ROOT}/nextflow.config" 2>/dev/null \
            | sed "s/.*'\(.*\)'/\1/" | sort -u
    )
    if [[ "${#PLUGIN_IDS[@]}" -eq 0 ]]; then
        warn "no versioned plugin declarations found in nextflow.config — nothing to pre-fetch"
        warn "if you later add 'plugins { id \"x@1.2.3\" }', re-run this script"
    else
        # We need a nextflow binary to do the fetching. Prefer the one from the
        # project's own environment so the plugin API version matches.
        NF_BIN=""
        for cand in "${REPO_ROOT}/.pixi/envs/default/bin/nextflow" "$(command -v nextflow 2>/dev/null || true)"; do
            [[ -n "${cand}" && -x "${cand}" ]] && { NF_BIN="${cand}"; break; }
        done
        [[ -n "${NF_BIN}" ]] || die "no nextflow binary available to pre-fetch plugins — run 'pixi install' first, or pass --skip-plugins"
        log "Pre-fetching Nextflow plugins with ${NF_BIN}"
        for pid in "${PLUGIN_IDS[@]}"; do
            log "  plugin ${pid}"
            NXF_HOME="${BUNDLE_DIR}/nxf-home" "${NF_BIN}" plugin install "${pid}" \
                || die "failed to download plugin ${pid} (is this machine online?)"
        done
        # Drop the transient cache dirs; only plugins/ needs to travel.
        rm -rf "${BUNDLE_DIR}/nxf-home/tmp"
        find "${BUNDLE_DIR}/nxf-home/plugins" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' 2>/dev/null \
            | while read -r p; do log "  packed:${p}"; done
    fi
fi

# ==============================================================================
# 3. Pipeline source
# ==============================================================================
log "Copying the pipeline source tree"
PIPELINE_ITEMS=(
    main.nf nextflow.config nextflow_schema.json
    conf modules subworkflows workflows bin assets deploy
    pixi.toml pixi.lock
    README.md CITATIONS.md CHANGELOG.md LICENSE
)
for item in "${PIPELINE_ITEMS[@]}"; do
    src="${REPO_ROOT}/${item}"
    if [[ -e "${src}" ]]; then
        cp -a "${src}" "${BUNDLE_DIR}/pipeline/"
    else
        warn "not present, skipped: ${item}"
    fi
done
# Never ship build artefacts or another machine's state.
rm -rf "${BUNDLE_DIR}/pipeline/.pixi" "${BUNDLE_DIR}/pipeline/work" \
       "${BUNDLE_DIR}/pipeline/.nextflow" "${BUNDLE_DIR}/pipeline/dist" \
       "${BUNDLE_DIR}/pipeline/deploy/dist"

# ==============================================================================
# 4. Receiver-side installer
# ==============================================================================
log "Writing install.sh"
cat > "${BUNDLE_DIR}/install.sh" <<'INSTALLER'
#!/usr/bin/env bash
# ==============================================================================
# phamseek offline installer — runs on the target machine. No network, no root.
# ==============================================================================
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BUNDLE_DIR="$(dirname "${SCRIPT_PATH}")"
readonly SCRIPT_PATH BUNDLE_DIR

PREFIX="${1:-${HOME}/phamseek}"
PREFIX="$(readlink -f "$(dirname "${PREFIX}")")/$(basename "${PREFIX}")"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

cat <<EOF
phamseek offline install
  bundle : ${BUNDLE_DIR}
  target : ${PREFIX}

EOF

# --- refuse to install into a polluted shell ---------------------------------
# A leaked CONDA_PREFIX / LD_LIBRARY_PATH is the number one cause of an install
# that appears to succeed and then fails at run time with a linker error.
DIRTY=""
for v in CONDA_PREFIX PYTHONPATH PYTHONHOME LD_LIBRARY_PATH LD_PRELOAD; do
    val="${!v:-}"
    [[ -z "${val}" ]] && continue
    # Apptainer injects LD_LIBRARY_PATH=/.singularity.d/libs into every container.
    # That is the runtime doing its job, not a leaked conda environment.
    [[ "${v}" == "LD_LIBRARY_PATH" && "${val}" == "/.singularity.d/libs" ]] && continue
    DIRTY="${DIRTY} ${v}"
done
if [[ -n "${DIRTY}" ]]; then
    cat >&2 <<EOF
[error] These variables are set and will corrupt the installation:${DIRTY}

  Run 'conda deactivate' (possibly more than once), then unset the rest:
      unset${DIRTY}
  and start this installer again.

  Override at your own risk with PHAMSEEK_ALLOW_DIRTY_ENV=1
EOF
    [[ -n "${PHAMSEEK_ALLOW_DIRTY_ENV:-}" ]] || exit 1
fi

# --- CA certificates ---------------------------------------------------------
# pixi-unpack constructs an HTTP client at start-up even though it never makes a
# request, and panics with "No CA certificates were loaded from the system" when
# the OS trust store is missing. Verified 2026-08-07 on debian:12-slim: the
# unpack dies before extracting a single package, with a Rust backtrace that
# says nothing about certificates being the fix.
CA_FOUND=0
for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
          /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem "${SSL_CERT_FILE:-}"; do
    [[ -n "${ca}" && -e "${ca}" ]] && { CA_FOUND=1; break; }
done
[[ "${CA_FOUND}" -eq 0 && -d /etc/ssl/certs ]] && \
    [[ -n "$(ls -A /etc/ssl/certs 2>/dev/null)" ]] && CA_FOUND=1
if [[ "${CA_FOUND}" -eq 0 ]]; then
    die "no system CA certificate store found.

  The unpacker needs one even though this install is entirely offline.
  Install your distribution's certificate package:
      Debian/Ubuntu : sudo apt-get install ca-certificates
      RHEL/Rocky    : sudo dnf install ca-certificates
  or point SSL_CERT_FILE at an existing bundle and run this installer again."
fi

[[ -e "${PREFIX}" ]] && die "target already exists: ${PREFIX} (remove it or choose another path)"
mkdir -p "${PREFIX}"

# --- 1. environment ----------------------------------------------------------
if [[ -x "${BUNDLE_DIR}/env/phamseek-env.sh" ]]; then
    log "Unpacking the conda environment (a few minutes; it is decompressing ~2 GiB)"
    # -s bash makes pixi-unpack emit an activation script with absolute paths
    # that sources the packages' own activate.d hooks. Those hooks are what set
    # JAVA_HOME; a packed prefix has no bin/activate, so without them Nextflow
    # finds no JVM.
    ( cd "${PREFIX}" && "${BUNDLE_DIR}/env/phamseek-env.sh" --output-directory "${PREFIX}" --shell bash ) \
        || die "environment unpack failed"
    [[ -d "${PREFIX}/env" ]] || die "expected ${PREFIX}/env after unpacking — the payload may be for a different platform"
    # Keep the generated script under its own name: ours takes activate.sh.
    [[ -f "${PREFIX}/activate.sh" ]] && mv "${PREFIX}/activate.sh" "${PREFIX}/env-activate.sh"
    [[ -f "${PREFIX}/env-activate.sh" ]] || die "pixi-unpack did not produce an activation script"
else
    die "no environment payload in ${BUNDLE_DIR}/env/"
fi

# --- 2. pipeline -------------------------------------------------------------
log "Installing the pipeline source"
cp -a "${BUNDLE_DIR}/pipeline" "${PREFIX}/pipeline"

# --- 3. NXF_HOME with pre-fetched plugins ------------------------------------
log "Installing the pre-fetched Nextflow plugins"
mkdir -p "${PREFIX}/nxf-home"
if [[ -d "${BUNDLE_DIR}/nxf-home" ]]; then
    cp -a "${BUNDLE_DIR}/nxf-home/." "${PREFIX}/nxf-home/"
fi

# --- 4. activation script ----------------------------------------------------
log "Writing ${PREFIX}/activate.sh"
cat > "${PREFIX}/activate.sh" <<ACT
#!/usr/bin/env bash
# Source this to get a shell that can run phamseek:  source ${PREFIX}/activate.sh
PHAMSEEK_ROOT="${PREFIX}"
export PHAMSEEK_ROOT

# Generated by pixi-unpack: sets PATH and CONDA_PREFIX, then runs each package's
# own activate.d hook (that is where JAVA_HOME comes from).
# shellcheck disable=SC1091
source "\${PHAMSEEK_ROOT}/env-activate.sh"

# Nextflow must look only at the plugins we shipped.
export NXF_HOME="\${PHAMSEEK_ROOT}/nxf-home"
export NXF_OFFLINE=true
export NXF_DISABLE_CHECK_LATEST=true

# Keep the host's other pipelines out of ours. The Tower tokens matter even
# though we never enable Tower: their presence alone makes Nextflow try to
# report the run to seqera.io.
unset PYTHONPATH PYTHONHOME LD_PRELOAD
unset NXF_TOWER_ACCESS_TOKEN TOWER_ACCESS_TOKEN TOWER_WORKSPACE_ID NXF_TOWER_WORKSPACE_ID

echo "phamseek environment active."
echo "  pipeline : \${PHAMSEEK_ROOT}/pipeline"
echo "  nextflow : \$(command -v nextflow)"
echo "  NXF_HOME : \${NXF_HOME} (offline mode)"
ACT
chmod +x "${PREFIX}/activate.sh"

# --- 5. wrapper on PATH ------------------------------------------------------
mkdir -p "${PREFIX}/bin"
cat > "${PREFIX}/bin/phamseek" <<WRAP
#!/usr/bin/env bash
# Thin wrapper: activate the bundled environment, then run the pipeline.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "${PREFIX}/activate.sh" >/dev/null
# An absolute local path, never an org/repo shorthand: shorthand makes Nextflow
# resolve the pipeline through GitHub, which cannot work offline.
exec nextflow -c "${PREFIX}/pipeline/deploy/offline.config" \\
     run "${PREFIX}/pipeline/main.nf" "\$@"
WRAP
chmod +x "${PREFIX}/bin/phamseek"

cat <<EOF

Installed.

  1. Check the machine and your database:
       ${PREFIX}/pipeline/deploy/preflight.sh --offline --db-dir /path/to/db

  2. Activate and run:
       source ${PREFIX}/activate.sh
       nextflow run ${PREFIX}/pipeline/main.nf --help

     or use the wrapper directly:
       ${PREFIX}/bin/phamseek --help

  3. Optional — put it on PATH permanently:
       echo 'export PATH="${PREFIX}/bin:\$PATH"' >> ~/.bashrc

Nothing outside ${PREFIX} was modified. To uninstall: rm -rf ${PREFIX}
EOF
INSTALLER
chmod +x "${BUNDLE_DIR}/install.sh"

# ==============================================================================
# 5. Manifest + checksums
# ==============================================================================
log "Writing MANIFEST.tsv and SHA256SUMS"
{
    printf 'key\tvalue\n'
    printf 'bundle\t%s\n' "${BUNDLE_NAME}"
    printf 'pipeline_version\t%s\n' "${PIPELINE_VERSION}"
    printf 'target_platform\t%s\n' "${PLATFORM}"
    printf 'built_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'built_on_host\t%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'built_on_arch\t%s\n' "$(uname -m)"
    printf 'built_on_glibc\t%s\n' "$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || echo unknown)"
    printf 'pixi_pack_version\t%s\n' "$(pixi-pack --version 2>/dev/null || echo unknown)"
    printf 'pixi_lock_sha256\t%s\n' "$(sha256sum "${REPO_ROOT}/pixi.lock" | awk '{print $1}')"
    printf 'glibc_baseline\t%s\n' "2.28"
    if [[ -d "${BUNDLE_DIR}/nxf-home/plugins" ]]; then
        while IFS= read -r p; do printf 'nextflow_plugin\t%s\n' "${p}"; done \
            < <(find "${BUNDLE_DIR}/nxf-home/plugins" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
    fi
} > "${BUNDLE_DIR}/MANIFEST.tsv"

( cd "${BUNDLE_DIR}" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )

# ==============================================================================
# 6. Archive
# ==============================================================================
if [[ "${MAKE_ARCHIVE}" -eq 1 ]]; then
    if command -v zstd >/dev/null 2>&1; then
        ARCHIVE="${OUTDIR}/${BUNDLE_NAME}.tar.zst"
        log "Creating ${ARCHIVE}"
        tar --use-compress-program='zstd -19 -T0' \
            -cf "${ARCHIVE}" -C "${OUTDIR}" "${BUNDLE_NAME}"
    else
        ARCHIVE="${OUTDIR}/${BUNDLE_NAME}.tar.gz"
        warn "zstd not found, falling back to gzip"
        log "Creating ${ARCHIVE}"
        tar -czf "${ARCHIVE}" -C "${OUTDIR}" "${BUNDLE_NAME}"
    fi
    sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"
    log "Archive: $(du -h "${ARCHIVE}" | cut -f1)  ${ARCHIVE}"
    log "Checksum: ${ARCHIVE}.sha256"
fi

cat <<EOF

Done.

  bundle directory : ${BUNDLE_DIR}
$( [[ "${MAKE_ARCHIVE}" -eq 1 ]] && echo "  archive          : ${ARCHIVE}" )

Send the archive AND its .sha256 to the collaborator by different channels
(archive over SFTP/Nextcloud, checksum by email) so a corrupted or swapped
transfer cannot pass unnoticed.

On the target machine:
  tar -xf ${BUNDLE_NAME}.tar.zst
  cd ${BUNDLE_NAME}
  ./install.sh ~/phamseek
EOF
