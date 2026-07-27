#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
readonly STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/colibri-setup/mirrors"
readonly LOG_ROOT="${STATE_ROOT}/logs"
readonly JOB_ROOT="${STATE_ROOT}/jobs"
readonly LOCK_FILE="${STATE_ROOT}/mirror.lock"

AUTO_YES="0"
FULL_VERIFY="0"
FOREGROUND="0"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

ensure_state() {
    umask 077
    mkdir -p -- "${LOG_ROOT}" "${JOB_ROOT}"
    chmod 0700 -- "${STATE_ROOT}" "${LOG_ROOT}" "${JOB_ROOT}"
}

validate_path() {
    local path=$1
    local label=$2
    [[ "${path}" == /* ]] || die "${label} must be absolute: ${path}"
    [[ "${path}" != "/" && "${path}" != "/home" && "${path}" != "/root" ]] ||
        die "${label} is unsafe: ${path}"
    [[ "${path}" != *" "* && "${path}" != *$'\n'* && "${path}" != *$'\t'* ]] ||
        die "${label} must not contain whitespace or control characters."
}

canonical_parent_path() {
    local path=$1
    local parent
    parent="$(dirname -- "${path}")"
    mkdir -p -- "${parent}"
    readlink -m -- "${path}"
}

paths_overlap() {
    local first
    local second
    first="$(readlink -m -- "$1")"
    second="$(readlink -m -- "$2")"
    [[ "${first}" == "${second}" || "${first}/" == "${second}/"* || "${second}/" == "${first}/"* ]]
}

filesystem_probe_path() {
    local path=$1
    if [[ -e "${path}" ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s\n' "$(dirname -- "${path}")"
    fi
}

job_id_for() {
    local destination=$1
    local base
    local digest
    base="$(basename -- "${destination}" | tr -cs 'A-Za-z0-9_.-' '-')"
    digest="$(printf '%s' "${destination}" | sha256sum | cut -c1-10)"
    printf 'colibri-mirror-%s-%s\n' "${base:0:32}" "${digest}"
}

state_file_for() {
    printf '%s/%s.state\n' "${JOB_ROOT}" "$1"
}

log_file_for() {
    printf '%s/%s.log\n' "${LOG_ROOT}" "$1"
}

write_state() {
    local state_file=$1
    local status=$2
    local message=${3:-}
    local temp_file
    temp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
    {
        printf 'STATUS=%q\n' "${status}"
        printf 'MESSAGE=%q\n' "${message}"
        printf 'UPDATED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"${temp_file}"
    mv -f -- "${temp_file}" "${state_file}"
}

read_state_value() {
    local state_file=$1
    local key=$2
    [[ -r "${state_file}" ]] || return 1
    (
        # State is generated only by this script and stored mode 0600.
        # shellcheck disable=SC1090
        source "${state_file}"
        printf '%s\n' "${!key:-}"
    )
}

confirm() {
    local prompt=$1
    if [[ "${AUTO_YES}" == "1" ]]; then
        return 0
    fi
    [[ -t 0 ]] || die "Confirmation required; re-run with --yes after review."
    local answer=""
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

mount_source_for() {
    local path=$1
    findmnt -n -o SOURCE -T "${path}" 2>/dev/null || true
}

physical_disk_for() {
    local path=$1
    local source
    source="$(mount_source_for "${path}")"
    [[ -n "${source}" ]] || return 0
    lsblk -s -n -o NAME,TYPE "${source}" 2>/dev/null |
        awk '$2 == "disk" {print $1; exit}'
}

check_distinct_devices() {
    local primary=$1
    local mirror=$2
    local primary_disk
    local mirror_disk
    primary_disk="$(physical_disk_for "${primary}")"
    mirror_disk="$(physical_disk_for "$(filesystem_probe_path "${mirror}")")"
    if [[ -n "${primary_disk}" && -n "${mirror_disk}" && "${primary_disk}" == "${mirror_disk}" ]]; then
        die "Primary and mirror resolve to the same physical disk (${primary_disk}); this would not add read bandwidth."
    fi
    if [[ -z "${primary_disk}" || -z "${mirror_disk}" ]]; then
        warn "Could not prove that primary and mirror are on different physical disks."
        confirm "Continue despite the unresolved device topology?" || die "Mirror cancelled."
    fi
}

required_kib_for() {
    local primary=$1
    local mirror=$2
    local primary_kib
    local existing_kib=0
    primary_kib="$(du -sk --apparent-size -- "${primary}" | awk '{print $1}')"
    if [[ -d "${mirror}" ]]; then
        existing_kib="$(du -sk --apparent-size -- "${mirror}" | awk '{print $1}')"
    fi
    if ((existing_kib >= primary_kib)); then
        printf '0\n'
    else
        printf '%s\n' "$((primary_kib - existing_kib))"
    fi
}

check_space() {
    local primary=$1
    local mirror=$2
    local required_kib
    local available_kib
    required_kib="$(required_kib_for "${primary}" "${mirror}")"
    available_kib="$(df -Pk -- "$(filesystem_probe_path "${mirror}")" | awk 'NR == 2 {print $4}')"
    # Retain 10 GiB of headroom for metadata and filesystem allocation variance.
    if ((available_kib < required_kib + 10 * 1024 * 1024)); then
        die "Insufficient free space for mirror. Need about $(((required_kib + 1024 * 1024 - 1) / 1024 / 1024)) GiB plus 10 GiB headroom."
    fi
}

build_manifest() {
    local directory=$1
    local output=$2
    (
        cd -- "${directory}"
        find . -maxdepth 1 -type f ! -name '.coli_*' \
            -printf '%P %s\n' |
            LC_ALL=C sort
    ) >"${output}"
}

verify_mirror() {
    local primary=$1
    local mirror=$2
    local full_verify=$3
    [[ -d "${primary}" && -d "${mirror}" ]] || die "Primary or mirror directory is missing."
    [[ -r "${primary}/config.json" && -r "${mirror}/config.json" ]] ||
        die "Primary or mirror is missing config.json."
    [[ -r "${primary}/tokenizer.json" && -r "${mirror}/tokenizer.json" ]] ||
        die "Primary or mirror is missing tokenizer.json."
    find "${primary}" -maxdepth 1 -type f -name '*.safetensors' -print -quit |
        grep -q . || die "Primary has no safetensors shards."
    find "${mirror}" -maxdepth 1 -type f -name '*.safetensors' -print -quit |
        grep -q . || die "Mirror has no safetensors shards."
    find "${primary}" -maxdepth 1 -type f -name 'out-mtp-*' -print -quit |
        grep -q . || die "Primary has no MTP artifacts."
    find "${mirror}" -maxdepth 1 -type f -name 'out-mtp-*' -print -quit |
        grep -q . || die "Mirror has no MTP artifacts."

    local primary_manifest
    local mirror_manifest
    primary_manifest="$(mktemp)"
    mirror_manifest="$(mktemp)"
    trap 'rm -f -- "${primary_manifest:-}" "${mirror_manifest:-}"' RETURN
    build_manifest "${primary}" "${primary_manifest}"
    build_manifest "${mirror}" "${mirror_manifest}"
    diff -u -- "${primary_manifest}" "${mirror_manifest}" ||
        die "Mirror filenames or file sizes do not match the primary."

    if [[ "${full_verify}" == "1" ]]; then
        printf 'Running full SHA-256 verification. This reads both model copies completely.\n'
        (
            cd -- "${primary}"
            find . -maxdepth 1 -type f ! -name '.coli_*' \
                -print0 |
                LC_ALL=C sort -z |
                xargs -0 sha256sum
        ) >"${primary_manifest}"
        (
            cd -- "${mirror}"
            find . -maxdepth 1 -type f ! -name '.coli_*' \
                -print0 |
                LC_ALL=C sort -z |
                xargs -0 sha256sum
        ) >"${mirror_manifest}"
        diff -u -- "${primary_manifest}" "${mirror_manifest}" ||
            die "Mirror checksums do not match the primary."
    fi

    rm -f -- "${primary_manifest}" "${mirror_manifest}"
    trap - RETURN
    printf 'Mirror verification passed: %s\n' "${mirror}"
}

worker() {
    local primary=$1
    local mirror=$2
    local state_file=$3
    local full_verify=$4

    local completed="0"
    trap 'exit 130' INT TERM
    trap 'exit_code=$?; if [[ "${completed}" != "1" ]]; then write_state "${state_file}" failed "Mirror worker failed with exit ${exit_code}"; fi; exit "${exit_code}"' EXIT
    write_state "${state_file}" running "Copying model"
    mkdir -p -- "${mirror}"
    rsync \
        -aH \
        --partial \
        --append-verify \
        --info=progress2 \
        --exclude='.coli_*' \
        -- "${primary}/" "${mirror}/"
    verify_mirror "${primary}" "${mirror}" "${full_verify}"
    write_state "${state_file}" completed "Mirror copy and verification completed"
    completed="1"
    trap - EXIT INT TERM
}

start_job() {
    local primary=${1:-}
    local mirror=${2:-}
    shift 2 || true
    [[ -n "${primary}" && -n "${mirror}" ]] ||
        die "Usage: mirror_model.sh start PRIMARY MIRROR [--full-verify] [--foreground] [--yes]"

    while (($#)); do
        case "$1" in
            --full-verify)
                FULL_VERIFY="1"
                shift
                ;;
            --foreground)
                FOREGROUND="1"
                shift
                ;;
            --yes | -y)
                AUTO_YES="1"
                shift
                ;;
            *)
                die "Unknown mirror option: $1"
                ;;
        esac
    done

    validate_path "${primary}" "Primary directory"
    validate_path "${mirror}" "Mirror directory"
    [[ -d "${primary}" ]] || die "Primary model does not exist: ${primary}"
    [[ ! -L "${primary}" && ! -L "${mirror}" ]] || die "Symlinked model directories are not supported."
    mirror="$(canonical_parent_path "${mirror}")"
    primary="$(readlink -m -- "${primary}")"
    validate_path "${primary}" "Primary directory"
    validate_path "${mirror}" "Mirror directory"
    paths_overlap "${primary}" "${mirror}" &&
        die "Primary and mirror directories must not contain one another."

    ensure_state
    exec 9>"${LOCK_FILE}"
    flock -n 9 || die "Another mirror operation is starting."
    check_distinct_devices "${primary}" "${mirror}"
    check_space "${primary}" "${mirror}"

    local job_id
    local state_file
    local log_file
    job_id="$(job_id_for "${mirror}")"
    state_file="$(state_file_for "${job_id}")"
    log_file="$(log_file_for "${job_id}")"

    if screen -list 2>/dev/null | grep -Fq ".${job_id}"; then
        die "Mirror job is already running: ${job_id}"
    fi

    printf 'Primary:       %s\n' "${primary}"
    printf 'Mirror:        %s\n' "${mirror}"
    printf 'Full checksum: %s\n' "${FULL_VERIFY}"
    confirm "Start this resumable mirror copy?" || die "Mirror cancelled."
    write_state "${state_file}" queued "Waiting for worker"

    if [[ "${FOREGROUND}" == "1" ]]; then
        worker "${primary}" "${mirror}" "${state_file}" "${FULL_VERIFY}" 2>&1 |
            tee -a "${log_file}"
        return
    fi

    command -v screen >/dev/null 2>&1 || die "GNU Screen is required."
    touch -- "${log_file}"
    chmod 0600 -- "${log_file}" "${state_file}"
    screen -L -Logfile "${log_file}" -DmS "${job_id}" \
        "${SCRIPT_PATH}" __worker "${primary}" "${mirror}" "${state_file}" "${FULL_VERIFY}"

    printf 'Mirror started in GNU Screen.\n'
    printf 'Job:       %s\n' "${job_id}"
    printf 'Attach:    screen -r %s\n' "${job_id}"
    printf 'Detach:    Ctrl-A, then D\n'
    printf 'Status:    ./colibri.sh model mirror-status %s\n' "${job_id}"
    printf 'After completion, enable it with:\n'
    printf '  ./colibri.sh model enable-mirror %q\n' "${mirror}"
}

status_jobs() {
    ensure_state
    local requested=${1:-}
    local state_file
    local found=0
    shopt -s nullglob
    for state_file in "${JOB_ROOT}"/*.state; do
        local job_id
        job_id="$(basename -- "${state_file}" .state)"
        if [[ -n "${requested}" && "${requested}" != "--all" && "${requested}" != "${job_id}" ]]; then
            continue
        fi
        found=1
        printf '%s: %s' "${job_id}" "$(read_state_value "${state_file}" STATUS)"
        if screen -list 2>/dev/null | grep -Fq ".${job_id}"; then
            printf ' (screen active)'
        fi
        printf '\n'
        local message
        message="$(read_state_value "${state_file}" MESSAGE || true)"
        [[ -z "${message}" ]] || printf '  %s\n' "${message}"
    done
    shopt -u nullglob
    ((found == 1)) || printf 'No managed mirror jobs found.\n'
}

attach_job() {
    local job_id=${1:-}
    [[ -n "${job_id}" ]] || die "Usage: mirror_model.sh attach JOB"
    exec screen -r "${job_id}"
}

main() {
    local action=${1:-help}
    shift || true
    case "${action}" in
        start) start_job "$@" ;;
        status) status_jobs "$@" ;;
        attach) attach_job "$@" ;;
        verify)
            local primary=${1:-}
            local mirror=${2:-}
            shift 2 || true
            local full="0"
            if [[ "${1:-}" == "--full-verify" ]]; then
                full="1"
                shift
            fi
            (($# == 0)) || die "Unknown verify option: $1"
            validate_path "${primary}" "Primary directory"
            validate_path "${mirror}" "Mirror directory"
            verify_mirror "${primary}" "${mirror}" "${full}"
            ;;
        __worker) worker "$@" ;;
        *)
            printf 'Usage: %s start|status|attach|verify\n' "$0"
            exit 2
            ;;
    esac
}

main "$@"
