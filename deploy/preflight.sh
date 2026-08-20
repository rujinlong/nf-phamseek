#!/usr/bin/env bash
# ==============================================================================
# phamseek deployment preflight check
# ------------------------------------------------------------------------------
# Run this FIRST, on the machine that will run phamseek, BEFORE installing
# anything. It answers three questions:
#
#   1. Can this machine run phamseek at all?          (OS / arch / glibc / RAM)
#   2. Which of the three install routes should I use? (online / offline / container)
#   3. Is the kraken2 database usable?                 (files present, RAM fits)
#
# It changes nothing on the system: read-only probes only.
#
# Usage:
#   ./preflight.sh [--db-dir DIR] [--work-dir DIR] [--json FILE]
#                  [--offline] [--no-color] [--quiet] [--help]
#
# Exit codes:
#   0  PASS  — no blockers, no warnings
#   1  WARN  — usable, but read the warnings before you start
#   2  FAIL  — at least one blocker; fix it before installing
#   3  usage error
#
# Requires only coreutils + bash >= 4. No python, no conda, no network needed
# (network probes are optional and time-boxed).
# ==============================================================================

set -Eeuo pipefail

# --- absolute self-location (never rely on the caller's cwd) ------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
readonly SCRIPT_PATH SCRIPT_DIR

# ==============================================================================
# Baseline constants — these mirror what phamseek's pixi.lock was solved against.
# Override via environment only if you know exactly why.
# ==============================================================================
: "${PHAMSEEK_GLIBC_BASELINE:=2.28}"   # __glibc virtual package pinned in pixi.lock
: "${PHAMSEEK_GLIBC_HARD_FLOOR:=2.17}" # lowest __glibc any locked package accepts
: "${PHAMSEEK_KERNEL_BASELINE:=4.18}"  # __linux virtual package pinned in pixi.lock
: "${PHAMSEEK_MIN_CORES:=4}"
: "${PHAMSEEK_REC_CORES:=8}"
: "${PHAMSEEK_MIN_JAVA:=17}"
: "${PHAMSEEK_RAM_HEADROOM_GB:=4}"     # kraken2 index + taxonomy + process overhead
# Resident size of the recommended production database (inphared_decoy, 7.7 GiB
# on disk) plus headroom. Used only when no --db-dir is given, to answer the
# planning question "will this machine do?" before anything has been shipped.
: "${PHAMSEEK_PROD_DB_GB:=8}"
: "${PHAMSEEK_NET_TIMEOUT:=8}"         # seconds per network probe
: "${PHAMSEEK_DF_TIMEOUT:=15}"         # seconds — never probe a mount unbounded

readonly SUPPORTED_ARCHES="x86_64 aarch64"

# ==============================================================================
# Options
# ==============================================================================
DB_DIR=""
WORK_DIR=""
JSON_OUT=""
DO_NETWORK=1
USE_COLOR="auto"
QUIET=0

usage() {
    sed -n '2,25p' "${SCRIPT_PATH}" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options:
  --db-dir DIR     kraken2 database directory to validate (the value you will
                   later pass to phamseek as --db_dir)
  --work-dir DIR   directory where Nextflow work/ and results/ will live
                   (default: current directory)
  --json FILE      write a machine-readable report to FILE
                   (default: <work-dir>/preflight.json)
  --offline        skip all network probes (use on air-gapped machines)
  --no-color       plain ASCII output (also honoured via NO_COLOR=1)
  --quiet          only print the summary and any WARN/FAIL lines
  -h, --help       this text
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-dir)    DB_DIR="${2:-}"; shift 2 ;;
        --db-dir=*)  DB_DIR="${1#*=}"; shift ;;
        --work-dir)  WORK_DIR="${2:-}"; shift 2 ;;
        --work-dir=*) WORK_DIR="${1#*=}"; shift ;;
        --json)      JSON_OUT="${2:-}"; shift 2 ;;
        --json=*)    JSON_OUT="${1#*=}"; shift ;;
        --offline)   DO_NETWORK=0; shift ;;
        --no-color)  USE_COLOR="never"; shift ;;
        --quiet)     QUIET=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "preflight: unknown option '$1' (try --help)" >&2; exit 3 ;;
    esac
done

# Resolve to absolute paths; never carry a relative path further down.
WORK_DIR="$(readlink -f "${WORK_DIR:-$PWD}" 2>/dev/null || echo "${WORK_DIR:-$PWD}")"
[[ -n "${DB_DIR}" ]] && DB_DIR="$(readlink -f "${DB_DIR}" 2>/dev/null || echo "${DB_DIR}")"
[[ -z "${JSON_OUT}" ]] && JSON_OUT="${WORK_DIR}/preflight.json"
JSON_OUT="$(readlink -f "$(dirname "${JSON_OUT}")" 2>/dev/null || dirname "${JSON_OUT}")/$(basename "${JSON_OUT}")"

# ==============================================================================
# Output helpers
# ==============================================================================
if [[ "${USE_COLOR}" == "never" || -n "${NO_COLOR:-}" ]] || { [[ "${USE_COLOR}" == "auto" ]] && [[ ! -t 1 ]]; }; then
    C_RESET=""; C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_DIM=""; C_BOLD=""
else
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
    C_GRN=$'\033[32m'; C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
fi

N_PASS=0; N_WARN=0; N_FAIL=0; N_INFO=0
JSON_ROWS=()

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# record <id> <status: PASS|WARN|FAIL|INFO> <headline> [detail]
record() {
    local id="$1" status="$2" head="$3" detail="${4:-}"
    local tag colour
    case "${status}" in
        PASS) tag="[ OK ]";  colour="${C_GRN}"; N_PASS=$((N_PASS + 1)) ;;
        WARN) tag="[WARN]";  colour="${C_YEL}"; N_WARN=$((N_WARN + 1)) ;;
        FAIL) tag="[FAIL]";  colour="${C_RED}"; N_FAIL=$((N_FAIL + 1)) ;;
        INFO) tag="[info]";  colour="${C_BLU}"; N_INFO=$((N_INFO + 1)) ;;
        *)    tag="[????]";  colour="" ;;
    esac
    if [[ "${QUIET}" -eq 0 || "${status}" == "WARN" || "${status}" == "FAIL" ]]; then
        printf '%s%s%s %-28s %s\n' "${colour}" "${tag}" "${C_RESET}" "${id}" "${head}"
        [[ -n "${detail}" ]] && printf '       %s%s%s\n' "${C_DIM}" "${detail}" "${C_RESET}"
    fi
    JSON_ROWS+=("{\"id\":\"$(json_escape "${id}")\",\"status\":\"${status}\",\"message\":\"$(json_escape "${head}")\",\"detail\":\"$(json_escape "${detail}")\"}")
}

section() {
    [[ "${QUIET}" -eq 1 ]] && return 0
    printf '\n%s%s── %s %s%s\n' "${C_BOLD}" "${C_BLU}" "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))" "${C_RESET}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# numeric version comparison: ver_ge A B  → true if A >= B
ver_ge() {
    [[ "$1" == "$2" ]] && return 0
    local first
    first="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
    [[ "${first}" == "$2" ]]
}

human_kb() {   # KiB -> human
    local kb="${1:-0}"
    awk -v k="${kb}" 'BEGIN{
        split("KiB MiB GiB TiB", u, " ");
        v = k; i = 1;
        while (v >= 1024 && i < 4) { v /= 1024; i++ }
        printf "%.1f %s", v, u[i]
    }'
}

human_bytes() {  # bytes -> human, keeps small files legible (opts.k2d is 64 B)
    local b="${1:-0}"
    awk -v b="${b}" 'BEGIN{
        split("B KiB MiB GiB TiB", u, " ");
        v = b; i = 1;
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        if (i == 1) printf "%d %s", v, u[i]; else printf "%.1f %s", v, u[i]
    }'
}

# ==============================================================================
# Facts collected for the JSON report / final recommendation
# ==============================================================================
FACT_ARCH=""; FACT_GLIBC=""; FACT_OS=""; FACT_KERNEL=""
FACT_CORES=0; FACT_MEM_TOTAL_KB=0; FACT_MEM_AVAIL_KB=0
FACT_DB_BYTES=0; FACT_DB_HASH_BYTES=0
FACT_NET="unknown"
FACT_HAS_PIXI=0; FACT_HAS_NEXTFLOW=0; FACT_HAS_JAVA=0; FACT_HAS_APPTAINER=0

echo "${C_BOLD}phamseek deployment preflight${C_RESET}  ${C_DIM}$(date -u '+%Y-%m-%dT%H:%M:%SZ')${C_RESET}"
echo "${C_DIM}host=$(hostname 2>/dev/null || echo unknown)  user=${USER:-$(id -un)}  work-dir=${WORK_DIR}${C_RESET}"

# ==============================================================================
section "1. Platform"
# ==============================================================================
FACT_ARCH="$(uname -m)"
FACT_KERNEL="$(uname -r)"
if [[ " ${SUPPORTED_ARCHES} " == *" ${FACT_ARCH} "* ]]; then
    record "platform.arch" PASS "CPU architecture ${FACT_ARCH}" \
        "phamseek ships builds for: ${SUPPORTED_ARCHES// /, }"
else
    record "platform.arch" FAIL "Unsupported CPU architecture: ${FACT_ARCH}" \
        "Only ${SUPPORTED_ARCHES// /, } are supported. No install route will work here."
fi

if [[ -r /etc/os-release ]]; then
    FACT_OS="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
else
    FACT_OS="unknown"
fi
record "platform.os" INFO "OS: ${FACT_OS}" "kernel ${FACT_KERNEL}"

# --- kernel version vs the __linux virtual package ---------------------------
KERNEL_NUM="$(printf '%s' "${FACT_KERNEL}" | grep -oE '^[0-9]+\.[0-9]+' || true)"
if [[ -n "${KERNEL_NUM}" ]]; then
    if ver_ge "${KERNEL_NUM}" "${PHAMSEEK_KERNEL_BASELINE}"; then
        record "platform.kernel" PASS "Kernel ${KERNEL_NUM} >= ${PHAMSEEK_KERNEL_BASELINE} (lock baseline)"
    else
        record "platform.kernel" FAIL "Kernel ${KERNEL_NUM} < ${PHAMSEEK_KERNEL_BASELINE}" \
            "pixi.lock was solved with __linux=${PHAMSEEK_KERNEL_BASELINE}. Some packages will refuse to install."
    fi
fi

# --- glibc: the single most common reason a relocated conda env dies ---------
FACT_GLIBC=""
if have getconf; then
    FACT_GLIBC="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
fi
if [[ -z "${FACT_GLIBC}" ]] && have ldd; then
    FACT_GLIBC="$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)"
fi
if [[ -z "${FACT_GLIBC}" ]]; then
    record "platform.glibc" WARN "Could not determine the glibc version" \
        "Neither getconf nor ldd reported one. If this is musl (Alpine), phamseek will NOT run: the conda packages are glibc-linked."
else
    if ver_ge "${FACT_GLIBC}" "${PHAMSEEK_GLIBC_BASELINE}"; then
        record "platform.glibc" PASS "glibc ${FACT_GLIBC} >= ${PHAMSEEK_GLIBC_BASELINE} (compatible)" \
            "Matches the baseline pixi.lock was solved against. All three install routes are viable."
    elif ver_ge "${FACT_GLIBC}" "${PHAMSEEK_GLIBC_HARD_FLOOR}"; then
        record "platform.glibc" WARN "glibc ${FACT_GLIBC} is below the ${PHAMSEEK_GLIBC_BASELINE} baseline (at risk)" \
            "Locked packages declare __glibc >= ${PHAMSEEK_GLIBC_HARD_FLOOR}, so most will load, but this combination is untested. Prefer the Apptainer route (route C), which carries its own glibc."
    else
        record "platform.glibc" FAIL "glibc ${FACT_GLIBC} < ${PHAMSEEK_GLIBC_HARD_FLOOR} (incompatible)" \
            "Neither 'pixi install' nor the offline pack can work: the OS C library is older than every locked package requires. Use the Apptainer route (route C), which does not depend on the host glibc."
    fi
fi

# --- musl / non-glibc detection ----------------------------------------------
if have ldd && ldd --version 2>&1 | head -n1 | grep -qi musl; then
    record "platform.libc" FAIL "musl libc detected (Alpine-like)" \
        "conda-forge/bioconda binaries are glibc-only. Only the Apptainer route can work."
fi

# ==============================================================================
section "2. Compute resources"
# ==============================================================================
FACT_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)"
if [[ "${FACT_CORES}" -ge "${PHAMSEEK_REC_CORES}" ]]; then
    record "compute.cores" PASS "${FACT_CORES} CPU cores available"
elif [[ "${FACT_CORES}" -ge "${PHAMSEEK_MIN_CORES}" ]]; then
    record "compute.cores" WARN "${FACT_CORES} CPU cores (below the recommended ${PHAMSEEK_REC_CORES})" \
        "The pipeline will run but assembly and kraken2 will be slow. Lower --max_cpus accordingly."
else
    record "compute.cores" FAIL "${FACT_CORES} CPU cores (minimum is ${PHAMSEEK_MIN_CORES})"
fi

# cgroup CPU quota can be far below the physical core count (container / slice)
CG_QUOTA=""
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    CG_QUOTA="$(awk '{ if ($1 != "max") printf "%.1f", $1/$2 }' /sys/fs/cgroup/cpu.max 2>/dev/null || true)"
elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    _q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"; _p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
    [[ "${_q}" -gt 0 ]] && CG_QUOTA="$(awk -v q="${_q}" -v p="${_p}" 'BEGIN{printf "%.1f", q/p}')"
fi
if [[ -n "${CG_QUOTA}" ]]; then
    record "compute.cgroup_cpu" WARN "cgroup limits this session to ~${CG_QUOTA} CPUs" \
        "Nextflow reads the host core count (${FACT_CORES}) and will oversubscribe. Set --max_cpus ${CG_QUOTA%.*} explicitly."
fi

if [[ -r /proc/meminfo ]]; then
    FACT_MEM_TOTAL_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    FACT_MEM_AVAIL_KB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    [[ -z "${FACT_MEM_AVAIL_KB}" ]] && FACT_MEM_AVAIL_KB="${FACT_MEM_TOTAL_KB}"
    record "compute.ram" INFO "RAM: $(human_kb "${FACT_MEM_TOTAL_KB}") total, $(human_kb "${FACT_MEM_AVAIL_KB}") available now" \
        "The kraken2 check below turns this into a pass/fail."
else
    record "compute.ram" WARN "/proc/meminfo unreadable — cannot check RAM"
fi

# cgroup memory limit (the real ceiling inside a container or systemd slice)
CG_MEM=""
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    if [[ -r "$f" ]]; then
        v="$(cat "$f" 2>/dev/null || true)"
        [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -lt 100000000000000 ]] && CG_MEM="$v"
        break
    fi
done
if [[ -n "${CG_MEM}" ]]; then
    CG_MEM_KB=$((CG_MEM / 1024))
    if [[ "${CG_MEM_KB}" -lt "${FACT_MEM_TOTAL_KB}" ]]; then
        record "compute.cgroup_mem" WARN "cgroup caps memory at $(human_kb "${CG_MEM_KB}") (host has $(human_kb "${FACT_MEM_TOTAL_KB}"))" \
            "kraken2 will be OOM-killed (exit 137) at the cgroup limit, not the host limit. Judge the kraken2 RAM check against $(human_kb "${CG_MEM_KB}")."
        FACT_MEM_AVAIL_KB="${CG_MEM_KB}"
    fi
fi

# --- ulimits -----------------------------------------------------------------
ULIM_N="$(ulimit -n 2>/dev/null || echo 0)"
if [[ "${ULIM_N}" != "unlimited" && "${ULIM_N}" -lt 4096 ]]; then
    record "compute.ulimit_nofile" WARN "open-file limit is ${ULIM_N} (recommend >= 4096)" \
        "Nextflow opens many files per task; a low limit shows up as 'Too many open files' mid-run. Fix with 'ulimit -n 4096' or a limits.conf entry."
else
    record "compute.ulimit_nofile" PASS "open-file limit ${ULIM_N}"
fi

ULIM_V="$(ulimit -v 2>/dev/null || echo unlimited)"
if [[ "${ULIM_V}" != "unlimited" ]]; then
    record "compute.ulimit_as" WARN "virtual-memory ulimit is set (${ULIM_V} KiB)" \
        "kraken2 maps its whole index; a virtual-memory cap makes it fail with a confusing allocation error. Prefer 'ulimit -v unlimited'."
fi

# Process/thread ceilings. Enough CPU and RAM but too few PIDs shows up as
# "unable to create native thread" from the JVM, which reads like a bug in
# Nextflow rather than a site policy.
ULIM_U="$(ulimit -u 2>/dev/null || echo unlimited)"
if [[ "${ULIM_U}" != "unlimited" ]] && [[ "${ULIM_U}" -lt 1024 ]]; then
    record "compute.ulimit_nproc" WARN "process limit is ${ULIM_U} (recommend >= 1024)" \
        "Symptom is 'unable to create native thread' from Java, or 'fork: Resource temporarily unavailable'."
else
    record "compute.ulimit_nproc" PASS "process limit ${ULIM_U}"
fi
for f in /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids/pids.max; do
    if [[ -r "$f" ]]; then
        pmax="$(cat "$f" 2>/dev/null || true)"
        if [[ "${pmax}" =~ ^[0-9]+$ ]] && [[ "${pmax}" -lt 1024 ]]; then
            record "compute.cgroup_pids" WARN "cgroup caps this session at ${pmax} processes" \
                "Same symptom as above, but invisible to ulimit. Ask for a higher pids.max."
        fi
        break
    fi
done

# Nextflow writes .command.sh / .command.run and executes them with bash.
for req in /bin/bash /usr/bin/env; do
    if [[ -x "${req}" ]]; then
        record "compute.$(basename "${req}")" PASS "${req} present"
    else
        record "compute.$(basename "${req}")" FAIL "${req} missing or not executable" \
            "Every Nextflow task wrapper starts with it. Nothing will run."
    fi
done

# Enterprise identity resolution (SSSD/LDAP/AD) blocks for tens of seconds when
# the directory server is unreachable — which is exactly the air-gapped case.
# Java resolves the local hostname at start-up, so this stalls every task.
if ! timeout 5 id -u >/dev/null 2>&1; then
    record "compute.identity" FAIL "'id -u' hangs or fails" \
        "Identity resolution is broken or blocking on an unreachable directory server. Every process start will stall."
else
    HOSTN="$(timeout 5 hostname 2>/dev/null || true)"
    if [[ -z "${HOSTN}" ]]; then
        record "compute.identity" WARN "'hostname' hangs or returns nothing"
    elif ! timeout 5 getent hosts "${HOSTN}" >/dev/null 2>&1; then
        record "compute.identity" WARN "local hostname '${HOSTN}' does not resolve" \
            "The JVM resolves it at start-up; unresolvable means a multi-second stall per task, or an UnknownHostException. Add it to /etc/hosts."
    else
        record "compute.identity" PASS "identity and hostname resolution respond promptly"
    fi
fi

# ==============================================================================
section "3. Disk"
# ==============================================================================
# NEVER probe with a bare global 'df' — an offline NFS mount hangs it forever.
disk_free_kb() {
    local path="$1" out
    out="$(timeout "${PHAMSEEK_DF_TIMEOUT}" df -Pk "${path}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    printf '%s' "${out:-}"
}
disk_fstype() {
    local path="$1"
    if have findmnt; then
        timeout "${PHAMSEEK_DF_TIMEOUT}" findmnt -n -o FSTYPE --target "${path}" 2>/dev/null | head -n1 || true
    else
        timeout "${PHAMSEEK_DF_TIMEOUT}" df -PT "${path}" 2>/dev/null | awk 'NR==2 {print $2}' || true
    fi
}

if [[ ! -d "${WORK_DIR}" ]]; then
    record "disk.workdir" FAIL "Work directory does not exist: ${WORK_DIR}"
elif [[ ! -w "${WORK_DIR}" ]]; then
    record "disk.workdir" FAIL "Work directory is not writable: ${WORK_DIR}" \
        "Nextflow needs to create work/ and results/ here."
else
    WD_FREE_KB="$(disk_free_kb "${WORK_DIR}")"
    WD_FS="$(disk_fstype "${WORK_DIR}")"
    if [[ -z "${WD_FREE_KB}" ]]; then
        record "disk.workdir" WARN "Could not read free space for ${WORK_DIR}" \
            "df timed out after ${PHAMSEEK_DF_TIMEOUT}s — the mount may be a stale network filesystem."
    else
        record "disk.workdir" INFO "Work directory free: $(human_kb "${WD_FREE_KB}") (${WD_FS:-unknown fs})" \
            "Budget ~50 GiB per clinical metagenome run for work/ + results/."
        if [[ "${WD_FREE_KB}" -lt 52428800 ]]; then
            record "disk.workdir_space" WARN "Less than 50 GiB free in the work directory" \
                "Assembly (megahit) and intermediate FASTQ are the space hogs. Point --work-dir at a bigger volume, or clean work/ between runs."
        else
            record "disk.workdir_space" PASS "Work directory space looks sufficient"
        fi
    fi
    case "${WD_FS}" in
        nfs|nfs4|cifs|smb3|fuse.sshfs)
            record "disk.workdir_fs" WARN "Work directory is on a network filesystem (${WD_FS})" \
                "Nextflow's work/ on NFS is slow and can hit file-locking issues. Prefer local disk for work/ and keep only results/ on the share." ;;
    esac

    # A filesystem type is not a behaviour. CIFS and some managed NFS mounts
    # report a familiar type yet cannot do what Nextflow needs on every task:
    # symlink inputs, rename atomically, take an advisory lock. Probe it.
    FS_PROBE="$(mktemp -d "${WORK_DIR}/.phamseek-preflight.XXXXXX" 2>/dev/null || true)"
    if [[ -z "${FS_PROBE}" || ! -d "${FS_PROBE}" ]]; then
        record "disk.workdir_probe" FAIL "Cannot create a temporary directory in ${WORK_DIR}"
    else
        FS_ISSUES=""
        printf 'x' > "${FS_PROBE}/a" 2>/dev/null || FS_ISSUES="${FS_ISSUES} write"
        mv "${FS_PROBE}/a" "${FS_PROBE}/b" 2>/dev/null || FS_ISSUES="${FS_ISSUES} rename"
        if ln -s b "${FS_PROBE}/link" 2>/dev/null; then
            [[ "$(cat "${FS_PROBE}/link" 2>/dev/null)" == "x" ]] || FS_ISSUES="${FS_ISSUES} symlink-deref"
        else
            FS_ISSUES="${FS_ISSUES} symlink"
        fi
        if have flock; then
            flock -n "${FS_PROBE}/lockfile" true 2>/dev/null || FS_ISSUES="${FS_ISSUES} flock"
        fi
        rm -rf "${FS_PROBE}"
        if [[ -n "${FS_ISSUES}" ]]; then
            record "disk.workdir_probe" FAIL "Work filesystem cannot do:${FS_ISSUES}" \
                "Nextflow needs all of these on every task. Symptoms are missing .command.* files, stale locks, and 'resume' behaving randomly. Point --work-dir at local disk."
        else
            record "disk.workdir_probe" PASS "Work filesystem supports symlink, atomic rename and advisory locking"
        fi
    fi
fi

# /tmp — java, nextflow scratch, and conda activation all land here
TMP_FREE_KB="$(disk_free_kb "${TMPDIR:-/tmp}")"
if [[ -n "${TMP_FREE_KB}" && "${TMP_FREE_KB}" -lt 5242880 ]]; then
    record "disk.tmp" WARN "${TMPDIR:-/tmp} has only $(human_kb "${TMP_FREE_KB}") free (recommend >= 5 GiB)" \
        "Set TMPDIR to a larger path before running, e.g. export TMPDIR=${WORK_DIR}/tmp"
else
    record "disk.tmp" PASS "${TMPDIR:-/tmp} free: $(human_kb "${TMP_FREE_KB:-0}")"
fi

# noexec on /tmp silently breaks conda/pixi activation scripts and java
TMP_OPTS=""
if have findmnt; then
    TMP_OPTS="$(timeout "${PHAMSEEK_DF_TIMEOUT}" findmnt -n -o OPTIONS --target "${TMPDIR:-/tmp}" 2>/dev/null | head -n1 || true)"
fi
if [[ "${TMP_OPTS}" == *noexec* ]]; then
    record "disk.tmp_noexec" WARN "${TMPDIR:-/tmp} is mounted noexec" \
        "Java and some conda post-link scripts extract helpers into TMPDIR and exec them. Set TMPDIR to an exec-capable path you own."
fi

# ==============================================================================
section "4. Toolchain already on this machine"
# ==============================================================================
if have pixi; then
    FACT_HAS_PIXI=1
    record "tool.pixi" PASS "pixi found: $(pixi --version 2>/dev/null || echo '?')" "$(command -v pixi)"
else
    record "tool.pixi" INFO "pixi not installed" \
        "Route A needs it. It is one static binary, no root required — see INSTALL.md."
fi

if have nextflow; then
    FACT_HAS_NEXTFLOW=1
    NF_VER="$(timeout 60 nextflow -version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $2}' || true)"
    record "tool.nextflow" INFO "nextflow found on PATH (${NF_VER:-version unknown})" \
        "phamseek ships its own pinned nextflow inside the pixi environment; the pixi one takes precedence once activated."
else
    record "tool.nextflow" INFO "nextflow not on PATH" "That is fine — it comes with the pixi environment."
fi

if have java; then
    FACT_HAS_JAVA=1
    JAVA_VER_RAW="$(java -version 2>&1 | head -n1)"
    JAVA_MAJOR="$(printf '%s' "${JAVA_VER_RAW}" | grep -oE '"[0-9]+' | tr -d '"' || true)"
    if [[ -n "${JAVA_MAJOR}" ]] && [[ "${JAVA_MAJOR}" -ge "${PHAMSEEK_MIN_JAVA}" ]]; then
        record "tool.java" PASS "java ${JAVA_MAJOR} on PATH (>= ${PHAMSEEK_MIN_JAVA})"
    else
        record "tool.java" INFO "java ${JAVA_MAJOR:-?} on PATH is older than ${PHAMSEEK_MIN_JAVA}" \
            "Not a blocker: the pixi environment provides its own JDK. But do NOT set JAVA_HOME to this one."
    fi
else
    record "tool.java" INFO "java not on PATH" "Supplied by the pixi environment."
fi

if have apptainer || have singularity; then
    FACT_HAS_APPTAINER=1
    APP_BIN="$(command -v apptainer || command -v singularity)"
    record "tool.apptainer" PASS "container runtime found: $("${APP_BIN}" --version 2>/dev/null || echo '?')" "${APP_BIN}"
else
    record "tool.apptainer" INFO "no apptainer/singularity" "Routes C and D unavailable; routes A and B do not need a container runtime."
fi

# --- system CA trust store ---------------------------------------------------
# Needed by the offline installer even though it never goes online: pixi-unpack
# builds an HTTP client at start-up and panics without a trust store. Verified
# 2026-08-07 — the failure is a Rust backtrace that never mentions certificates.
CA_FOUND=0; CA_WHERE=""
for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
          /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem "${SSL_CERT_FILE:-}"; do
    if [[ -n "${ca}" && -e "${ca}" ]]; then CA_FOUND=1; CA_WHERE="${ca}"; break; fi
done
if [[ "${CA_FOUND}" -eq 0 && -d /etc/ssl/certs && -n "$(ls -A /etc/ssl/certs 2>/dev/null)" ]]; then
    CA_FOUND=1; CA_WHERE="/etc/ssl/certs (hashed directory)"
fi
if [[ "${CA_FOUND}" -eq 1 ]]; then
    record "tool.ca_certificates" PASS "system CA trust store present" "${CA_WHERE}"
else
    record "tool.ca_certificates" FAIL "no system CA certificate store" \
        "The offline installer needs one even with no network: its unpacker panics without a trust store. Install 'ca-certificates' (apt/dnf) or set SSL_CERT_FILE."
fi

for t in tar zstd sha256sum curl; do
    if have "$t"; then
        record "tool.${t}" PASS "${t} available"
    else
        case "$t" in
            zstd)      record "tool.zstd" WARN "zstd missing" "Needed to unpack the database archives. Install with your OS package manager, or ask us for a .tar.gz build instead." ;;
            sha256sum) record "tool.sha256sum" WARN "sha256sum missing" "Needed to verify the database checksums. 'shasum -a 256' is an acceptable substitute." ;;
            curl)      record "tool.curl" INFO "curl missing" "Only used for the network probe and for downloading pixi." ;;
            *)         record "tool.${t}" FAIL "${t} missing" "Required by the install scripts." ;;
        esac
    fi
done

# ==============================================================================
section "5. Environment hygiene (conflicts with an existing conda setup)"
# ==============================================================================
# These are the silent killers: a leaked variable from the collaborator's own
# conda pipeline makes phamseek load the wrong shared library and fail with an
# error that points nowhere near the cause.
POLLUTION=0
check_env_var() {
    local var="$1" why="$2"
    local val="${!var:-}"
    if [[ -n "${val}" ]]; then
        POLLUTION=1
        record "env.${var}" WARN "${var} is set" "${val}
       ${why}"
    else
        record "env.${var}" PASS "${var} is unset"
    fi
}
check_env_var CONDA_PREFIX      "An active conda environment leaks its bin/ and lib/ into every Nextflow task. Run 'conda deactivate' (possibly twice) before installing or running phamseek."
check_env_var PYTHONPATH        "Python modules from the other pipeline will shadow phamseek's own. Unset it for the phamseek shell."
check_env_var PYTHONHOME        "Points python at another installation; guarantees an ImportError inside the phamseek env."
check_env_var LD_LIBRARY_PATH   "The most common cause of 'symbol not found' / 'GLIBCXX_ not found' in mixed conda setups. Unset it for the phamseek shell."
check_env_var LD_PRELOAD        "Injects a library into every process, including kraken2. Unset it."
check_env_var PERL5LIB          "bioconda tools with perl wrappers (e.g. some krakentools helpers) pick up foreign modules."
check_env_var JAVA_TOOL_OPTIONS "Silently prepended to every JVM launch, including Nextflow's."
check_env_var _JAVA_OPTIONS     "Same as JAVA_TOOL_OPTIONS, and it also prints a banner that breaks output parsing."

if [[ -n "${CONDA_DEFAULT_ENV:-}" ]]; then
    record "env.CONDA_DEFAULT_ENV" WARN "conda environment '${CONDA_DEFAULT_ENV}' is active" \
        "Deactivate it before installing. phamseek does not use conda and must not inherit its PATH."
fi

if [[ "${POLLUTION}" -eq 1 ]]; then
    record "env.summary" WARN "Environment is not clean" \
        "Safest fix: open a fresh login shell with 'env -i HOME=\$HOME PATH=/usr/bin:/bin TERM=\$TERM bash -l' and re-run this preflight there."
else
    record "env.summary" PASS "No conflicting environment variables detected"
fi

# umask that would make the installed files unreadable to colleagues
UMASK_VAL="$(umask)"
record "env.umask" INFO "umask ${UMASK_VAL}" "Files created by the install will follow this."

# locale: a non-UTF-8 locale makes Nextflow/Groovy mangle non-ASCII sample names
if [[ "${LANG:-}${LC_ALL:-}" != *UTF-8* && "${LANG:-}${LC_ALL:-}" != *utf8* ]]; then
    record "env.locale" WARN "Locale is not UTF-8 (LANG='${LANG:-unset}', LC_ALL='${LC_ALL:-unset}')" \
        "Nextflow can fail on non-ASCII characters in paths or sample sheets. Set 'export LANG=C.UTF-8'."
else
    record "env.locale" PASS "Locale is UTF-8 (${LC_ALL:-${LANG}})"
fi

# ==============================================================================
section "6. Network reachability"
# ==============================================================================
PROXY_SET=""
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
    [[ -n "${!v:-}" ]] && PROXY_SET="${PROXY_SET}${v}=${!v} "
done
if [[ -n "${PROXY_SET}" ]]; then
    record "net.proxy" INFO "Proxy variables are set" "${PROXY_SET}
       Nextflow needs these mapped to JVM properties too — see INSTALL.md, 'Behind a proxy'."
fi

probe_url() {  # returns 0 if reachable
    local url="$1"
    if have curl; then
        timeout "$((PHAMSEEK_NET_TIMEOUT + 2))" curl -sS -I --max-time "${PHAMSEEK_NET_TIMEOUT}" \
            -o /dev/null -w '' "${url}" >/dev/null 2>&1
    elif have wget; then
        timeout "$((PHAMSEEK_NET_TIMEOUT + 2))" wget -q --spider --timeout="${PHAMSEEK_NET_TIMEOUT}" "${url}" >/dev/null 2>&1
    else
        return 2
    fi
}

# A reachability probe is not a usability probe. An intercepting proxy answers
# HEAD with 200 and serves a login page; TLS inspection re-signs with a private
# CA that curl may trust and the JVM may not. Fetch real content and look at it.
probe_content() {  # probe_content <url> <string that must appear>
    local url="$1" needle="$2" body
    have curl || return 2
    body="$(timeout "$((PHAMSEEK_NET_TIMEOUT + 2))" curl -fsSL --max-time "${PHAMSEEK_NET_TIMEOUT}" \
             --max-filesize 2000000 "${url}" 2>/dev/null | head -c 4000 || true)"
    [[ -n "${body}" ]] || return 1
    [[ "${body}" == *"${needle}"* ]] || return 3
    return 0
}

if [[ "${DO_NETWORK}" -eq 0 ]]; then
    FACT_NET="skipped"
    record "net.probe" INFO "Network probe skipped (--offline)" "Assuming an air-gapped machine: plan for route B or C."
else
    NET_OK=0; NET_TOTAL=0
    # Probe exactly the hosts the three install routes actually contact.
    # nf-validation/nf-schema are NOT served from nextflow.io: the plugin index
    # lives on raw.githubusercontent.com and the zips on github.com releases.
    declare -A NET_TARGETS=(
        ["conda-forge"]="https://conda.anaconda.org/conda-forge/noarch/repodata.json"
        ["bioconda"]="https://conda.anaconda.org/bioconda/noarch/repodata.json"
        ["nextflow plugin zips (github)"]="https://github.com"
        ["nextflow plugin index (raw.githubusercontent)"]="https://raw.githubusercontent.com/nextflow-io/plugins/main/plugins.json"
    )
    for name in "${!NET_TARGETS[@]}"; do
        NET_TOTAL=$((NET_TOTAL + 1))
        if probe_url "${NET_TARGETS[$name]}"; then
            NET_OK=$((NET_OK + 1))
            record "net.$(echo "${name}" | tr ' ()' '_')" PASS "reachable: ${name}"
        else
            record "net.$(echo "${name}" | tr ' ()' '_')" WARN "NOT reachable: ${name}" "${NET_TARGETS[$name]}"
        fi
    done
    # Content-level probe: distinguishes "reachable" from "actually usable".
    if [[ "${NET_OK}" -gt 0 ]]; then
        set +e
        probe_content "https://raw.githubusercontent.com/nextflow-io/plugins/main/plugins.json" '"id"'
        PC_RC=$?
        set -e
        case "${PC_RC}" in
            0) record "net.content" PASS "plugin index returns real content (no captive portal)" ;;
            3) record "net.content" FAIL "plugin index returned something that is not the plugin index" \
                   "Almost certainly an intercepting proxy or captive portal answering on its behalf. Route A will fail in a confusing way — use route B or C." ;;
            *) record "net.content" WARN "could not fetch the plugin index body" \
                   "HEAD succeeded but GET did not. Treat this machine as offline." ;;
        esac
        # TLS interception also breaks the JVM specifically: curl and Java use
        # different trust stores, so curl can pass while Nextflow reports
        # "PKIX path building failed".
        if [[ -n "${PROXY_SET}" || "${PC_RC}" -ne 0 ]]; then
            record "net.tls_jvm" INFO "If Nextflow later reports 'PKIX path building failed'" \
                "your proxy re-signs TLS with a private CA that Java does not trust. Ask IT for the CA certificate and import it into the JDK, or just use route B (no network at all)."
        fi
    fi

    if [[ "${NET_OK}" -eq "${NET_TOTAL}" && "${PC_RC:-1}" -eq 0 ]]; then
        FACT_NET="online"
        record "net.summary" PASS "All package sources reachable — route A (pixi install) and route D (published container image) will both work"
    elif [[ "${NET_OK}" -eq 0 ]]; then
        FACT_NET="offline"
        record "net.summary" WARN "No package source reachable — you must use the offline package (route B or C)" \
            "This is expected on a clinical network. Nothing is broken."
    else
        FACT_NET="partial"
        record "net.summary" WARN "Only ${NET_OK}/${NET_TOTAL} sources reachable — treat this machine as offline" \
            "A partially-filtered network is worse than no network: pixi may start, then stall mid-download. Use route B."
    fi
fi

# ==============================================================================
section "7. kraken2 database"
# ==============================================================================
if [[ -z "${DB_DIR}" ]]; then
    record "db.check" INFO "No --db-dir given — database check skipped" \
        "Re-run as: ${SCRIPT_PATH} --db-dir /path/to/kraken2_db"
    # Without a database to measure, at least answer the planning question:
    # does this machine have room for the database we recommend?
    if [[ "${FACT_MEM_TOTAL_KB}" -gt 0 ]]; then
        PROD_NEED_KB=$(( PHAMSEEK_PROD_DB_GB * 1024 * 1024 ))
        if [[ "${FACT_MEM_TOTAL_KB}" -ge "${PROD_NEED_KB}" ]]; then
            record "db.ram_planning" PASS "RAM is sufficient for the recommended database" \
                "inphared_decoy (7.7 GiB) needs ~${PHAMSEEK_PROD_DB_GB} GiB resident; this machine has $(human_kb "${FACT_MEM_TOTAL_KB}")."
        else
            record "db.ram_planning" WARN "RAM may be too small for the recommended database" \
                "inphared_decoy (7.7 GiB) needs ~${PHAMSEEK_PROD_DB_GB} GiB resident; this machine has $(human_kb "${FACT_MEM_TOTAL_KB}"). Consider inphared_7Apr2026 (939 MiB) instead — smaller reference set, lower sensitivity."
        fi
    fi
elif [[ ! -d "${DB_DIR}" ]]; then
    record "db.dir" FAIL "Database directory not found: ${DB_DIR}"
else
    # The phamseek --db_dir root looks like this:
    #     <db_dir>/kraken2/<db_name>/   hash.k2d, opts.k2d, taxo.k2d   (v0.1 required)
    #     <db_dir>/host/                minimap2 CHM13v2 .mmi index    (v0.1 required)
    #     <db_dir>/genomad_db/          reserved for v0.2
    #     <db_dir>/checkv/              reserved for v0.2
    # Accept a bare kraken2 database too, so this script is useful before the
    # full layout has been assembled.
    K2_DIR=""
    IS_ROOT=0
    if [[ -f "${DB_DIR}/hash.k2d" ]]; then
        K2_DIR="${DB_DIR}"
    elif [[ -f "${DB_DIR}/kraken2/hash.k2d" ]]; then
        K2_DIR="${DB_DIR}/kraken2"; IS_ROOT=1
    elif [[ -d "${DB_DIR}/kraken2" ]]; then
        # The documented shape: one named database under kraken2/.
        IS_ROOT=1
        # -L follows symlinks: a database directory is very often a link to a
        # bigger volume, and without -L find silently sees nothing there.
        mapfile -t K2_CANDIDATES < <(find -L "${DB_DIR}/kraken2" -maxdepth 2 -name hash.k2d -printf '%h\n' 2>/dev/null | LC_ALL=C sort)
        if [[ "${#K2_CANDIDATES[@]}" -eq 1 ]]; then
            K2_DIR="${K2_CANDIDATES[0]}"
        elif [[ "${#K2_CANDIDATES[@]}" -gt 1 ]]; then
            K2_DIR="${K2_CANDIDATES[0]}"
            record "db.layout" WARN "More than one kraken2 database under ${DB_DIR}/kraken2" \
                "Found: ${K2_CANDIDATES[*]}. Checking the first. phamseek selects one with --kraken2_db; make sure it is the one you intend."
        fi
    fi

    if [[ -z "${K2_DIR}" ]]; then
        record "db.dir" FAIL "No kraken2 database found under ${DB_DIR}" \
            "Expected ${DB_DIR}/kraken2/<db_name>/hash.k2d (or point --db-dir straight at a kraken2 database directory)."
        DB_OK=0
    else
        [[ "${IS_ROOT}" -eq 1 ]] && record "db.layout" INFO "Treating ${DB_DIR} as a --db_dir root" \
            "kraken2 database resolved to ${K2_DIR}"

        # --- companion directories -------------------------------------------
        # v0.1 is Tier 1 only: read-level profiling with kraken2, host depletion
        # with minimap2. geNomad and CheckV are reserved for v0.2, so their
        # absence is the normal state and must not read as a problem.
        if [[ "${IS_ROOT}" -eq 1 ]]; then
            if [[ -d "${DB_DIR}/host" ]]; then
                if find "${DB_DIR}/host" -maxdepth 1 -name '*.mmi' 2>/dev/null | grep -q .; then
                    record "db.host" PASS "host/ present with a minimap2 index"
                else
                    record "db.host" WARN "host/ exists but contains no .mmi index" \
                        "Host depletion needs a minimap2 index of CHM13v2. Either add it, or run with --skip_host_removal true."
                fi
            else
                record "db.host" WARN "host/ not present" \
                    "phamseek v0.1 depletes human reads with a minimap2 CHM13v2 index. Without it you must run with --skip_host_removal true, and human reads will reach the classifier."
            fi
            for sub in genomad_db checkv; do
                if [[ -d "${DB_DIR}/${sub}" ]]; then
                    record "db.${sub}" PASS "${sub}/ present (not used by v0.1)"
                else
                    record "db.${sub}" INFO "${sub}/ not present — expected for v0.1" \
                        "Reserved for v0.2, which adds assembly plus geNomad and CheckV. Nothing to do now."
                fi
            done
        fi

        record "db.dir" PASS "kraken2 database directory: ${K2_DIR}"
        DB_DIR="${K2_DIR}"
        DB_OK=1
    fi
fi
if [[ -n "${DB_DIR}" && -d "${DB_DIR}" && "${DB_OK:-0}" -eq 1 ]]; then
    # kraken2 needs exactly these three files; anything else in the dir is optional.
    declare -A DB_MIN_BYTES=( ["hash.k2d"]=1000000 ["opts.k2d"]=32 ["taxo.k2d"]=100000 )
    for f in hash.k2d opts.k2d taxo.k2d; do
        p="${DB_DIR}/${f}"
        if [[ ! -f "${p}" ]]; then
            record "db.${f}" FAIL "Missing: ${f}" "A kraken2 database is incomplete without it. Re-extract the archive, or you extracted one level too deep/shallow."
            DB_OK=0
            continue
        fi
        sz="$(stat -c '%s' "${p}" 2>/dev/null || stat -f '%z' "${p}" 2>/dev/null || echo 0)"
        min="${DB_MIN_BYTES[$f]}"
        if [[ "${sz}" -lt "${min}" ]]; then
            record "db.${f}" FAIL "${f} is only ${sz} bytes (expected > ${min})" \
                "Almost always a truncated transfer. Re-verify with deploy/db_verify.sh."
            DB_OK=0
        else
            record "db.${f}" PASS "${f}: $(human_bytes "${sz}")"
            [[ "${f}" == "hash.k2d" ]] && FACT_DB_HASH_BYTES="${sz}"
        fi
        FACT_DB_BYTES=$((FACT_DB_BYTES + sz))
    done

    if [[ ! -r "${DB_DIR}/hash.k2d" ]]; then
        record "db.readable" FAIL "hash.k2d exists but is not readable by ${USER:-$(id -un)}"
    fi

    # A MANIFEST from db_package.sh means we can prove provenance.
    if [[ -f "${DB_DIR}/MANIFEST.tsv" ]]; then
        record "db.manifest" PASS "MANIFEST.tsv present" \
            "Run deploy/db_verify.sh --db-dir ${DB_DIR} for a full checksum verification."
    else
        record "db.manifest" INFO "No MANIFEST.tsv in the database directory" \
            "Checksums cannot be verified. Ask for the manifest that shipped with the archive."
    fi

    # --- the number-one failure at deployment time ---------------------------
    if [[ "${FACT_DB_HASH_BYTES}" -gt 0 && "${FACT_MEM_TOTAL_KB}" -gt 0 ]]; then
        NEED_KB=$(( FACT_DB_BYTES / 1024 + PHAMSEEK_RAM_HEADROOM_GB * 1024 * 1024 ))
        if [[ "${FACT_MEM_TOTAL_KB}" -ge "${NEED_KB}" ]]; then
            if [[ "${FACT_MEM_AVAIL_KB}" -ge "${NEED_KB}" ]]; then
                record "db.ram_fit" PASS "RAM is sufficient: need ~$(human_kb "${NEED_KB}"), have $(human_kb "${FACT_MEM_AVAIL_KB}") available"
            else
                record "db.ram_fit" WARN "Enough total RAM but only $(human_kb "${FACT_MEM_AVAIL_KB}") free right now (need ~$(human_kb "${NEED_KB}"))" \
                    "Another job is holding memory. kraken2 will be OOM-killed (exit 137) if you start now. Wait, or run with --kraken2_memory_mapping true (much slower, but bounded)."
            fi
        else
            record "db.ram_fit" FAIL "Not enough RAM: kraken2 needs ~$(human_kb "${NEED_KB}"), this machine has $(human_kb "${FACT_MEM_TOTAL_KB}")" \
                "kraken2 loads the whole index into RAM. Options, best first: (1) use a smaller database, (2) run with --kraken2_memory_mapping true and accept a large slowdown, (3) add RAM."
        fi
    fi

    # Disk headroom next to the database (people extract in place)
    DB_FREE_KB="$(disk_free_kb "${DB_DIR}")"
    if [[ -n "${DB_FREE_KB}" && "${FACT_DB_BYTES}" -gt 0 ]]; then
        if [[ "${DB_FREE_KB}" -lt $((FACT_DB_BYTES / 1024)) ]]; then
            record "db.disk" WARN "Free space beside the database ($(human_kb "${DB_FREE_KB}")) is less than the database itself" \
                "Fine if the database is already extracted and you will not re-extract there. Extraction needs ~2x the final size."
        else
            record "db.disk" PASS "Free space beside the database: $(human_kb "${DB_FREE_KB}")"
        fi
    fi

    DB_FS="$(disk_fstype "${DB_DIR}")"
    case "${DB_FS}" in
        nfs|nfs4|cifs|smb3|fuse.sshfs)
            record "db.fs" WARN "Database is on a network filesystem (${DB_FS})" \
                "The recommended production database (inphared_decoy) is 7.7 GiB; pulling that over the network on every run is slow. Copy it to local disk if runs feel unreasonably long." ;;
        *) [[ -n "${DB_FS}" ]] && record "db.fs" PASS "Database filesystem: ${DB_FS}" ;;
    esac

    [[ "${DB_OK}" -eq 1 ]] && record "db.summary" PASS "Database looks structurally complete"
fi

# ==============================================================================
section "8. Recommendation"
# ==============================================================================
ROUTE=""; ROUTE_WHY=""
if [[ "${N_FAIL}" -gt 0 ]] && printf '%s\n' "${JSON_ROWS[@]}" | grep -q '"id":"platform.glibc","status":"FAIL"'; then
    ROUTE="C — Apptainer container"
    ROUTE_WHY="The host glibc is too old for the conda packages; only a container carries its own."
elif [[ "${FACT_HAS_APPTAINER}" -eq 1 && "${FACT_NET}" != "online" ]]; then
    ROUTE="C — Apptainer container (or B if you prefer no container)"
    ROUTE_WHY="No usable network, but a container runtime is already installed: a single .sif file is the smallest thing to move across the air gap."
elif [[ "${FACT_NET}" == "online" ]]; then
    ROUTE="A — pixi install"
    ROUTE_WHY="conda-forge and bioconda are reachable, so pixi can materialise the locked environment directly. Nothing needs to be shipped by hand."
else
    ROUTE="B — offline pixi-pack bundle"
    ROUTE_WHY="Package sources are not reachable and no container runtime is present. Ask us for the offline bundle built for ${FACT_ARCH}."
fi
if [[ "${QUIET}" -eq 0 ]]; then
    printf '\n  %sSuggested install route: %s%s\n' "${C_BOLD}" "${ROUTE}" "${C_RESET}"
    printf '  %s%s%s\n' "${C_DIM}" "${ROUTE_WHY}" "${C_RESET}"
    printf '  %sFull instructions: %s/INSTALL.md%s\n' "${C_DIM}" "${SCRIPT_DIR}" "${C_RESET}"
fi

# ==============================================================================
# Summary + JSON
# ==============================================================================
if [[ "${N_FAIL}" -gt 0 ]]; then
    OVERALL="FAIL"; EXIT_CODE=2
elif [[ "${N_WARN}" -gt 0 ]]; then
    OVERALL="WARN"; EXIT_CODE=1
else
    OVERALL="PASS"; EXIT_CODE=0
fi

printf '\n%s%s%s  %d passed · %d warnings · %d failures\n' \
    "${C_BOLD}" \
    "$( [[ "${OVERALL}" == "PASS" ]] && printf '%s' "${C_GRN}PASS" || { [[ "${OVERALL}" == "WARN" ]] && printf '%s' "${C_YEL}WARN" || printf '%s' "${C_RED}FAIL"; } )" \
    "${C_RESET}" "${N_PASS}" "${N_WARN}" "${N_FAIL}"

case "${OVERALL}" in
    PASS) echo "  Ready to install. Follow route ${ROUTE%% *} in INSTALL.md." ;;
    WARN) echo "  Usable, but read every [WARN] line above before you start." ;;
    FAIL) echo "  Do not install yet. Every [FAIL] line above must be resolved (or send this report to us)." ;;
esac

# --- machine-readable report -------------------------------------------------
{
    printf '{\n'
    printf '  "schema": "phamseek-preflight/1",\n'
    printf '  "generated_utc": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "overall": "%s",\n' "${OVERALL}"
    printf '  "exit_code": %d,\n' "${EXIT_CODE}"
    printf '  "counts": {"pass": %d, "warn": %d, "fail": %d, "info": %d},\n' "${N_PASS}" "${N_WARN}" "${N_FAIL}" "${N_INFO}"
    printf '  "recommended_route": "%s",\n' "$(json_escape "${ROUTE}")"
    printf '  "recommended_route_reason": "%s",\n' "$(json_escape "${ROUTE_WHY}")"
    printf '  "host": {\n'
    printf '    "hostname": "%s",\n' "$(json_escape "$(hostname 2>/dev/null || echo unknown)")"
    printf '    "os": "%s",\n' "$(json_escape "${FACT_OS}")"
    printf '    "kernel": "%s",\n' "$(json_escape "${FACT_KERNEL}")"
    printf '    "arch": "%s",\n' "$(json_escape "${FACT_ARCH}")"
    printf '    "glibc": "%s",\n' "$(json_escape "${FACT_GLIBC}")"
    printf '    "cpu_cores": %s,\n' "${FACT_CORES:-0}"
    printf '    "mem_total_kb": %s,\n' "${FACT_MEM_TOTAL_KB:-0}"
    printf '    "mem_available_kb": %s,\n' "${FACT_MEM_AVAIL_KB:-0}"
    printf '    "network": "%s"\n' "${FACT_NET}"
    printf '  },\n'
    printf '  "baseline": {"glibc": "%s", "glibc_hard_floor": "%s", "kernel": "%s"},\n' \
        "${PHAMSEEK_GLIBC_BASELINE}" "${PHAMSEEK_GLIBC_HARD_FLOOR}" "${PHAMSEEK_KERNEL_BASELINE}"
    printf '  "database": {"dir": "%s", "total_bytes": %s, "hash_k2d_bytes": %s},\n' \
        "$(json_escape "${DB_DIR}")" "${FACT_DB_BYTES}" "${FACT_DB_HASH_BYTES}"
    printf '  "tools": {"pixi": %s, "nextflow": %s, "java": %s, "apptainer": %s},\n' \
        "${FACT_HAS_PIXI}" "${FACT_HAS_NEXTFLOW}" "${FACT_HAS_JAVA}" "${FACT_HAS_APPTAINER}"
    printf '  "checks": [\n'
    for i in "${!JSON_ROWS[@]}"; do
        printf '    %s%s\n' "${JSON_ROWS[$i]}" "$( [[ $i -lt $((${#JSON_ROWS[@]} - 1)) ]] && printf ',' )"
    done
    printf '  ]\n'
    printf '}\n'
} > "${JSON_OUT}" 2>/dev/null || {
    echo "  (could not write ${JSON_OUT})" >&2
}
[[ -f "${JSON_OUT}" ]] && printf '  %sMachine-readable report: %s%s\n' "${C_DIM}" "${JSON_OUT}" "${C_RESET}"

exit "${EXIT_CODE}"
