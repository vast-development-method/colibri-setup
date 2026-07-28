#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="colibri.sh"
readonly PROGRAM_VERSION="0.1.1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly UPSTREAM_URL="https://github.com/JustVugg/colibri.git"
readonly DEFAULT_UPSTREAM_REF="v1.1.1"
readonly DEFAULT_MODEL_REPO="mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp"
readonly DEFAULT_MODEL_ID="glm-5.2-colibri"
readonly DEFAULT_PORT="11435"
readonly SERVICE_NAME="colibri.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SYSTEM_CONFIG_DIR="/etc/colibri-setup"
readonly CONFIG_FILE="${SYSTEM_CONFIG_DIR}/colibri.env"
readonly SYSTEM_STATE_DIR="/var/lib/colibri-setup"
readonly INSTALL_MANIFEST="${SYSTEM_STATE_DIR}/install.manifest"
readonly SYSTEM_LIBEXEC_DIR="/usr/local/libexec/colibri-setup"
readonly INSTALLED_WAIT_SCRIPT="${SYSTEM_LIBEXEC_DIR}/wait_for_address.sh"
readonly USER_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/colibri-setup"
readonly USER_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/colibri-setup"
readonly USER_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/colibri-setup"
readonly HF_ENV_FILE="${USER_CONFIG_DIR}/.env"
readonly DEFAULT_SOURCE_DIR="${USER_DATA_DIR}/upstream"
readonly DEFAULT_MODEL_DIR="${HOME}/models/glm52-colibri-gs64"
readonly HF_VENV_DIR="${USER_DATA_DIR}/hf-venv"
readonly LOCK_FILE="${USER_STATE_DIR}/manager.lock"
readonly DOWNLOAD_SCRIPT="${SCRIPT_DIR}/scripts/download_model.sh"
readonly MIRROR_SCRIPT="${SCRIPT_DIR}/scripts/mirror_model.sh"

DEPLOY_USER="$(id -un)"
DEPLOY_GROUP="$(id -gn)"
SOURCE_DIR="${DEFAULT_SOURCE_DIR}"
MODEL_DIR="${DEFAULT_MODEL_DIR}"
MODEL_REPO="${DEFAULT_MODEL_REPO}"
MODEL_ID="${DEFAULT_MODEL_ID}"
MIRROR_DIR=""
UPSTREAM_REF="${DEFAULT_UPSTREAM_REF}"
BIND_HOST="127.0.0.1"
PORT="${DEFAULT_PORT}"
PROFILE="performance"
RAM_GB=""
CTX=""
PIPE_WORKERS=""
PIN_GB=""
MAX_QUEUE=""
QUEUE_TIMEOUT="1800"
KV_SLOTS="1"
DIRECT="1"
URING="0"
PILOT="0"
PILOT_REAL="0"
UI_MODE="colibri-web"
COLI_API_KEY=""
SOURCE_CREATED="0"

AUTO_YES="0"
NO_START="0"
NO_DOWNLOAD="0"
ROTATE_API_KEY="0"
UPDATE_SOURCE="0"
CUSTOM_RAM=""
CUSTOM_CTX=""
CUSTOM_WORKERS=""
LOCK_HELD="0"

STAGED_SOURCE_DIR=""
STAGED_SOURCE_LIVE_COMMIT=""
STAGED_RESOLVED_REF=""
ACTIVATION_NEEDS_ROLLBACK="0"
ACTIVATION_PREVIOUS_SOURCE=""
ACTIVATION_HAD_PREVIOUS="0"
ACTIVATION_SERVICE_WAS_ACTIVE="0"
ACTIVATION_SERVICE_STOPPED="0"

error() {
    printf 'ERROR: %s\n' "$*" >&2
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

info() {
    printf '\n==> %s\n' "$*"
}

die() {
    error "$*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    error "Command failed at line ${line_no} (exit ${exit_code})."
    exit "${exit_code}"
}

trap 'on_error "$LINENO"' ERR

is_managed_staging_path() {
    local candidate=$1
    local source_parent
    local source_name
    source_parent="$(dirname -- "${SOURCE_DIR}")"
    source_name="$(basename -- "${SOURCE_DIR}")"
    [[ "$(dirname -- "${candidate}")" == "${source_parent}" &&
        "$(basename -- "${candidate}")" == ".${source_name}.stage."* ]]
}

discard_staged_source() {
    local candidate=${1:-${STAGED_SOURCE_DIR}}
    [[ -n "${candidate}" && -e "${candidate}" ]] || return 0
    if ! is_managed_staging_path "${candidate}"; then
        warn "Refusing to remove an unexpected staging path: ${candidate}"
        return 1
    fi
    rm -rf --one-file-system -- "${candidate}"
    [[ "${candidate}" != "${STAGED_SOURCE_DIR}" ]] || STAGED_SOURCE_DIR=""
}

atomic_exchange_paths() {
    local first=$1
    local second=$2
    local first_parent
    local temporary

    [[ -e "${first}" && -e "${second}" ]] ||
        die "Both source paths must exist before they can be exchanged."
    [[ "$(stat -c '%d' "${first}")" == "$(stat -c '%d' "${second}")" ]] ||
        die "Source exchange requires both paths on the same filesystem."

    first_parent="$(dirname -- "${first}")"
    temporary="${first_parent}/.$(basename -- "${first}").exchange.$$"
    [[ ! -e "${temporary}" ]] ||
        die "Temporary source exchange path already exists: ${temporary}"

    mv -T -- "${first}" "${temporary}"
    if ! mv -T -- "${second}" "${first}"; then
        mv -T -- "${temporary}" "${first}"
        return 1
    fi
    if ! mv -T -- "${temporary}" "${second}"; then
        mv -T -- "${first}" "${second}" || true
        mv -T -- "${temporary}" "${first}" || true
        return 1
    fi
}

rollback_activated_source() {
    [[ "${ACTIVATION_NEEDS_ROLLBACK}" == "1" ]] || return 0

    warn "Rolling back the activated Colibri source."
    if [[ "${ACTIVATION_HAD_PREVIOUS}" == "1" ]]; then
        if [[ -e "${SOURCE_DIR}" && -e "${ACTIVATION_PREVIOUS_SOURCE}" ]]; then
            atomic_exchange_paths "${SOURCE_DIR}" "${ACTIVATION_PREVIOUS_SOURCE}"
            warn "Previous source restored. Failed candidate retained at ${ACTIVATION_PREVIOUS_SOURCE}."
        else
            error "Cannot restore the previous source because an activation path is missing."
            return 1
        fi
    elif [[ -e "${SOURCE_DIR}" ]]; then
        local failed_source
        failed_source="${SOURCE_DIR}.failed-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        mv -T -- "${SOURCE_DIR}" "${failed_source}"
        warn "Failed first-install candidate retained at ${failed_source}."
    fi

    ACTIVATION_NEEDS_ROLLBACK="0"
}

release_cleanup() {
    local exit_code=$1
    trap - ERR EXIT
    set +e

    if ((exit_code != 0)) && [[ "${ACTIVATION_NEEDS_ROLLBACK}" == "1" ]]; then
        # A first install may have partially started the candidate even though
        # no service was active before activation.
        sudo systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1
        rollback_activated_source
    fi

    if ((exit_code != 0)) &&
        [[ "${ACTIVATION_SERVICE_STOPPED}" == "1" &&
            "${ACTIVATION_SERVICE_WAS_ACTIVE}" == "1" ]]; then
        sudo systemctl start "${SERVICE_NAME}" >/dev/null 2>&1 ||
            error "The previous source was restored, but the service could not be restarted."
    fi

    if [[ -n "${STAGED_SOURCE_DIR}" && -e "${STAGED_SOURCE_DIR}" ]]; then
        discard_staged_source "${STAGED_SOURCE_DIR}"
    fi
    exit "${exit_code}"
}

trap 'release_cleanup "$?"' EXIT

usage() {
    cat <<'EOF'
Colibri Setup - CPU/NVMe deployment and operations manager

Usage:
  ./colibri.sh <command> [options]

Core commands:
  install                  Install dependencies, Colibri, configuration and service
  configure                Change model, bind, port, UI mode or resource profile
  upgrade                  Explicitly update and rebuild the upstream Colibri source
  start                    Validate, enable and start the service
  stop                     Stop the service without removing anything
  restart                  Validate and restart the service
  enable                   Enable automatic startup
  disable                  Stop and disable automatic startup
  status                   Show deployment, service, API and background-job status
  logs [--follow]          Show service logs
  doctor                   Run local checks and upstream `coli doctor`
  plan                     Show the exact CPU/RAM/NVMe placement plan
  test [--chat]            Verify health/models, optionally run a tiny completion

Model and storage:
  model download [REPO] [DEST] [options]
  model verify [REPO] [DEST]
  model repair [REPO] [DEST] [--yes]
  model status [JOB]
  model attach [JOB]
  model resume [JOB]
  model cancel [JOB]
  model mirror <DEST> [options]
  model mirror-status [JOB]
  model mirror-attach [JOB]
  model enable-mirror <DEST> [--full-verify]
  model disable-mirror

Profiles and interfaces:
  profile list
  profile show [NAME]
  profile set <NAME> [--no-restart]
  ui show
  ui set <api-only|open-webui|colibri-web>
  open-webui setup [--container NAME|--local]
  open-webui check [--container NAME]
  open-webui values

Credentials and upstream CLI:
  hf-token set|status|remove
                           Manage HF_TOKEN in the private user .env file
  api-key show|rotate
  cli [Colibri arguments ...]  Run the bundled upstream `coli` with managed config

Removal:
  uninstall [--yes] [--remove-source] [--purge-config]
              Stops/removes only this integration. Model weights are NEVER deleted.

Common install/configure options:
  --model-dir PATH
  --model-repo OWNER/REPOSITORY
  --source-dir PATH
  --ref TAG_OR_BRANCH
  --host ADDRESS
  --port PORT
  --profile conservative|balanced|performance|experimental|custom
  --ram GB
  --ctx TOKENS
  --workers COUNT
  --ui api-only|open-webui|colibri-web
  --no-start
  --no-download
  --update-source
  --rotate-api-key
  --yes

Defaults:
  Port:         11435
  Bind:         127.0.0.1
  Profile:      performance
  UI:           colibri-web
  Upstream:     Colibri v1.1.1 (updated only by `upgrade`)
  Model:        mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp
EOF
}

require_non_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        die "Run ${PROGRAM_NAME} as the account that will own the deployment, not as root. It will use sudo only for packages and systemd."
    fi
}

require_command() {
    local command_name=$1
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "Required command is not installed: ${command_name}"
}

ensure_state_dirs() {
    umask 077
    mkdir -p -- "${USER_STATE_DIR}" "${USER_DATA_DIR}" "${USER_CONFIG_DIR}"
    chmod 0700 -- "${USER_STATE_DIR}" "${USER_DATA_DIR}" "${USER_CONFIG_DIR}"
}

validate_hf_token_value() {
    local token=$1
    [[ "${token}" =~ ^hf_[A-Za-z0-9]+$ ]] ||
        die "HF_TOKEN must be a Hugging Face user token beginning with 'hf_'."
}

validate_hf_env_file() {
    local mode
    local owner

    [[ -f "${HF_ENV_FILE}" ]] ||
        die "HF_TOKEN environment file does not exist: ${HF_ENV_FILE}"
    [[ ! -L "${HF_ENV_FILE}" ]] ||
        die "HF_TOKEN environment file must not be a symbolic link: ${HF_ENV_FILE}"
    mode="$(stat -c '%a' "${HF_ENV_FILE}")"
    [[ "${mode}" == "600" ]] ||
        die "HF_TOKEN environment file must have mode 0600: ${HF_ENV_FILE}"
    owner="$(stat -c '%u' "${HF_ENV_FILE}")"
    [[ "${owner}" == "$(id -u)" ]] ||
        die "HF_TOKEN environment file must be owned by the deployment user: ${HF_ENV_FILE}"
}

load_hf_token() {
    if [[ -n "${HF_TOKEN:-}" ]]; then
        validate_hf_token_value "${HF_TOKEN}"
        export HF_TOKEN
        return 0
    fi
    [[ -e "${HF_ENV_FILE}" ]] || return 1

    validate_hf_env_file
    local -a environment_lines=()
    mapfile -t environment_lines <"${HF_ENV_FILE}"
    ((${#environment_lines[@]} == 1)) ||
        die "HF_TOKEN environment file must contain exactly one assignment."
    local line=${environment_lines[0]}
    [[ "${line}" == HF_TOKEN=* ]] ||
        die "HF_TOKEN environment file must contain an HF_TOKEN assignment."

    HF_TOKEN="${line#HF_TOKEN=}"
    validate_hf_token_value "${HF_TOKEN}"
    export HF_TOKEN
}

write_hf_token() {
    local token=$1
    local temporary_file

    validate_hf_token_value "${token}"
    ensure_state_dirs
    umask 077
    temporary_file="$(mktemp "${USER_CONFIG_DIR}/.env.tmp.XXXXXX")"
    printf 'HF_TOKEN=%s\n' "${token}" >"${temporary_file}"
    chmod 0600 "${temporary_file}"
    mv -f -- "${temporary_file}" "${HF_ENV_FILE}"
}

ensure_hf_token() {
    if load_hf_token; then
        return 0
    fi
    [[ -t 0 ]] ||
        die "HF_TOKEN is required. Configure it first with: ./colibri.sh hf-token set"

    local token=""
    printf '\nA Hugging Face read token is required for managed Hub access.\n'
    printf 'Create one at: https://huggingface.co/settings/tokens\n'
    IFS= read -r -s -p 'HF_TOKEN: ' token
    printf '\n'
    [[ -n "${token}" ]] || die "HF_TOKEN was empty."
    write_hf_token "${token}"
    token=""
    unset token
    load_hf_token
    info "HF_TOKEN saved and exported for Hugging Face operations."
}

acquire_lock() {
    [[ "${LOCK_HELD}" == "0" ]] || return 0
    ensure_state_dirs
    require_command flock
    exec 9>"${LOCK_FILE}"
    flock -n 9 || die "Another ${PROGRAM_NAME} operation is already running."
    LOCK_HELD="1"
}

confirm() {
    local prompt=$1
    local default_answer=${2:-no}
    local answer=""

    if [[ "${AUTO_YES}" == "1" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        die "Confirmation is required in a non-interactive session. Re-run with --yes after reviewing the command."
    fi

    if [[ "${default_answer}" == "yes" ]]; then
        read -r -p "${prompt} [Y/n] " answer
        [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]]
    else
        read -r -p "${prompt} [y/N] " answer
        [[ "${answer}" =~ ^[Yy]$ ]]
    fi
}

validate_safe_path() {
    local path=$1
    local label=$2

    [[ -n "${path}" ]] || die "${label} must not be empty."
    [[ "${path}" == /* ]] || die "${label} must be an absolute path: ${path}"
    [[ "${path}" != "/" && "${path}" != "/home" && "${path}" != "/root" ]] ||
        die "${label} is too broad and unsafe: ${path}"
    [[ "${path}" != *$'\n'* && "${path}" != *$'\r'* && "${path}" != *$'\t'* ]] ||
        die "${label} contains control characters."
    [[ "${path}" != *" "* ]] ||
        die "${label} contains whitespace. Colibri systemd paths must not contain whitespace."
    [[ "${path}" =~ ^/[A-Za-z0-9._/+:-]+$ ]] ||
        die "${label} contains characters that cannot be serialized safely: ${path}"
}

canonicalize_managed_path() {
    readlink -m -- "$1"
}

paths_overlap() {
    local first
    local second
    first="$(canonicalize_managed_path "$1")"
    second="$(canonicalize_managed_path "$2")"
    [[ "${first}" == "${second}" || "${first}/" == "${second}/"* || "${second}/" == "${first}/"* ]]
}

validate_managed_path_separation() {
    SOURCE_DIR="$(canonicalize_managed_path "${SOURCE_DIR}")"
    MODEL_DIR="$(canonicalize_managed_path "${MODEL_DIR}")"
    [[ -z "${MIRROR_DIR}" ]] || MIRROR_DIR="$(canonicalize_managed_path "${MIRROR_DIR}")"

    if paths_overlap "${SOURCE_DIR}" "${MODEL_DIR}"; then
        die "Source and primary model directories must not contain one another."
    fi
    if [[ -n "${MIRROR_DIR}" ]]; then
        if paths_overlap "${SOURCE_DIR}" "${MIRROR_DIR}"; then
            die "Source and mirror directories must not contain one another."
        fi
        if paths_overlap "${MODEL_DIR}" "${MIRROR_DIR}"; then
            die "Primary and mirror directories must not contain one another."
        fi
    fi
}

validate_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] || die "Port must be an integer: ${port}"
    ((port >= 1024 && port <= 65535)) ||
        die "Choose an unprivileged port between 1024 and 65535."
}

validate_host() {
    local host=$1
    [[ -n "${host}" ]] || die "Bind address must not be empty."
    [[ "${host}" =~ ^[A-Za-z0-9._:-]+$ ]] ||
        die "Invalid bind address: ${host}"
}

validate_profile_name() {
    case "$1" in
        conservative | balanced | performance | experimental | custom) ;;
        *) die "Unknown profile '$1'. Use conservative, balanced, performance, experimental, or custom." ;;
    esac
}

validate_ui_mode() {
    case "$1" in
        api-only | open-webui | colibri-web) ;;
        *) die "Unknown UI mode '$1'. Use api-only, open-webui, or colibri-web." ;;
    esac
}

validate_integer() {
    local value=$1
    local label=$2
    local min=$3
    local max=$4

    [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} must be an integer."
    ((value >= min && value <= max)) ||
        die "${label} must be between ${min} and ${max}."
}

total_ram_gb() {
    awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 / 1024 }' /proc/meminfo
}

logical_cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || nproc
}

min_int() {
    local left=$1
    local right=$2
    if ((left < right)); then
        printf '%s\n' "${left}"
    else
        printf '%s\n' "${right}"
    fi
}

resolve_profile() {
    local requested_profile=$1
    local total_ram
    local cpus
    local percent
    local reserve

    validate_profile_name "${requested_profile}"
    total_ram="$(total_ram_gb)"
    cpus="$(logical_cpu_count)"
    ((total_ram >= 16)) ||
        die "Colibri needs at least approximately 16 GiB RAM. Detected ${total_ram} GiB."

    case "${requested_profile}" in
        conservative)
            percent=50
            reserve=8
            CTX="4096"
            PIPE_WORKERS="$(min_int "${cpus}" 4)"
            PIN_GB="6"
            MAX_QUEUE="2"
            DIRECT="0"
            URING="0"
            PILOT="0"
            PILOT_REAL="0"
            ;;
        balanced)
            percent=70
            reserve=12
            CTX="8192"
            PIPE_WORKERS="$(min_int "${cpus}" 8)"
            PIN_GB="10"
            MAX_QUEUE="4"
            DIRECT="1"
            URING="0"
            PILOT="0"
            PILOT_REAL="0"
            ;;
        performance)
            percent=80
            reserve=8
            CTX="8192"
            PIPE_WORKERS="$(min_int "${cpus}" 12)"
            PIN_GB="14"
            MAX_QUEUE="4"
            DIRECT="1"
            URING="0"
            PILOT="0"
            PILOT_REAL="0"
            ;;
        experimental)
            percent=80
            reserve=8
            CTX="8192"
            PIPE_WORKERS="$(min_int "${cpus}" 12)"
            PIN_GB="14"
            MAX_QUEUE="4"
            DIRECT="1"
            URING="1"
            PILOT="1"
            PILOT_REAL="1"
            ;;
        custom)
            CUSTOM_RAM="${CUSTOM_RAM:-${RAM_GB:-}}"
            CUSTOM_CTX="${CUSTOM_CTX:-${CTX:-}}"
            CUSTOM_WORKERS="${CUSTOM_WORKERS:-${PIPE_WORKERS:-}}"
            [[ -n "${CUSTOM_RAM}" && -n "${CUSTOM_CTX}" && -n "${CUSTOM_WORKERS}" ]] ||
                die "The custom profile requires --ram, --ctx, and --workers."
            validate_integer "${CUSTOM_RAM}" "RAM budget" 16 "${total_ram}"
            validate_integer "${CUSTOM_CTX}" "Context" 512 131072
            validate_integer "${CUSTOM_WORKERS}" "Worker count" 1 64
            RAM_GB="${CUSTOM_RAM}"
            CTX="${CUSTOM_CTX}"
            PIPE_WORKERS="${CUSTOM_WORKERS}"
            PIN_GB="$((CUSTOM_RAM / 4))"
            ((PIN_GB >= 4)) || PIN_GB="4"
            MAX_QUEUE="4"
            DIRECT="1"
            URING="0"
            PILOT="0"
            PILOT_REAL="0"
            PROFILE="custom"
            return
            ;;
    esac

    RAM_GB="$((total_ram * percent / 100))"
    if ((RAM_GB > total_ram - reserve)); then
        RAM_GB="$((total_ram - reserve))"
    fi
    ((RAM_GB >= 16)) ||
        die "Profile '${requested_profile}' leaves too little RAM for Colibri on this host."
    PROFILE="${requested_profile}"
}

show_profile_values() {
    printf 'Profile:           %s\n' "${PROFILE}"
    printf 'RAM budget:        %s GiB\n' "${RAM_GB}"
    printf 'Context:           %s tokens\n' "${CTX}"
    printf 'Pipeline workers:  %s\n' "${PIPE_WORKERS}"
    printf 'Pinned hot store:  %s GiB\n' "${PIN_GB}"
    printf 'Queue:             %s\n' "${MAX_QUEUE}"
    printf 'Direct I/O:        %s\n' "${DIRECT}"
    printf 'io_uring:          %s\n' "${URING}"
    printf 'Pilot prefetch:    %s\n' "${PILOT}"
    printf 'GPU:               disabled by CPU-only build\n'
}

assert_config_permissions() {
    [[ -e "${CONFIG_FILE}" ]] || return 0
    [[ ! -L "${CONFIG_FILE}" ]] || die "Refusing symlinked configuration: ${CONFIG_FILE}"

    local owner_uid
    local mode
    owner_uid="$(stat -c '%u' "${CONFIG_FILE}")"
    mode="$(stat -c '%a' "${CONFIG_FILE}")"
    [[ "${owner_uid}" == "0" ]] || die "Configuration must be owned by root: ${CONFIG_FILE}"
    ((8#${mode} & 8#022 == 0)) ||
        die "Configuration must not be group- or world-writable: ${CONFIG_FILE}"
}

assert_service_owned_or_absent() {
    [[ -e "${SERVICE_FILE}" ]] || return 0
    [[ ! -L "${SERVICE_FILE}" ]] ||
        die "Refusing a symlinked systemd unit: ${SERVICE_FILE}"
    sudo grep -Fq '# Managed by vast-development-method/colibri-setup' "${SERVICE_FILE}" ||
        die "Refusing to modify an unmanaged systemd unit: ${SERVICE_FILE}"
}

load_config() {
    [[ -r "${CONFIG_FILE}" ]] || return 0
    assert_config_permissions

    # The file is generated by this script, root-owned, and contains only
    # validated KEY=VALUE pairs without shell metacharacters.
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    [[ "${DEPLOY_USER}" == "$(id -un)" ]] ||
        die "This deployment is owned by ${DEPLOY_USER}; current user is $(id -un)."
}

generate_api_key() {
    require_command openssl
    openssl rand -hex 32
}

write_config() {
    assert_config_permissions
    validate_managed_path_separation
    validate_safe_path "${SOURCE_DIR}" "Source directory"
    validate_safe_path "${MODEL_DIR}" "Model directory"
    [[ -z "${MIRROR_DIR}" ]] || validate_safe_path "${MIRROR_DIR}" "Mirror directory"
    validate_port "${PORT}"
    validate_host "${BIND_HOST}"
    validate_profile_name "${PROFILE}"
    validate_ui_mode "${UI_MODE}"
    [[ "${MODEL_REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die "Invalid Hugging Face repository id: ${MODEL_REPO}"
    [[ "${MODEL_ID}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid model id: ${MODEL_ID}"
    [[ "${UPSTREAM_REF}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid upstream ref: ${UPSTREAM_REF}"

    if [[ -z "${COLI_API_KEY}" || "${ROTATE_API_KEY}" == "1" ]]; then
        COLI_API_KEY="$(generate_api_key)"
    fi

    local temp_file
    umask 077
    temp_file="$(mktemp)"
    trap 'rm -f -- "${temp_file:-}"' RETURN

    {
        printf 'DEPLOY_USER=%s\n' "${DEPLOY_USER}"
        printf 'DEPLOY_GROUP=%s\n' "${DEPLOY_GROUP}"
        printf 'SOURCE_DIR=%s\n' "${SOURCE_DIR}"
        printf 'MODEL_DIR=%s\n' "${MODEL_DIR}"
        printf 'MODEL_REPO=%s\n' "${MODEL_REPO}"
        printf 'MODEL_ID=%s\n' "${MODEL_ID}"
        printf 'MIRROR_DIR=%s\n' "${MIRROR_DIR}"
        printf 'UPSTREAM_REF=%s\n' "${UPSTREAM_REF}"
        printf 'SOURCE_CREATED=%s\n' "${SOURCE_CREATED}"
        printf 'BIND_HOST=%s\n' "${BIND_HOST}"
        printf 'PORT=%s\n' "${PORT}"
        printf 'PROFILE=%s\n' "${PROFILE}"
        printf 'RAM_GB=%s\n' "${RAM_GB}"
        printf 'CTX=%s\n' "${CTX}"
        printf 'PIPE_WORKERS=%s\n' "${PIPE_WORKERS}"
        printf 'PIN_GB=%s\n' "${PIN_GB}"
        printf 'MAX_QUEUE=%s\n' "${MAX_QUEUE}"
        printf 'QUEUE_TIMEOUT=%s\n' "${QUEUE_TIMEOUT}"
        printf 'KV_SLOTS=%s\n' "${KV_SLOTS}"
        printf 'DIRECT=%s\n' "${DIRECT}"
        printf 'URING=%s\n' "${URING}"
        printf 'PILOT=%s\n' "${PILOT}"
        printf 'PILOT_REAL=%s\n' "${PILOT_REAL}"
        printf 'UI_MODE=%s\n' "${UI_MODE}"
        printf 'COLI_API_KEY=%s\n' "${COLI_API_KEY}"
        printf 'COLI_MODEL=%s\n' "${MODEL_DIR}"
        printf 'COLI_MODEL_ID=%s\n' "${MODEL_ID}"
        printf 'COLI_MODEL_MIRROR=%s\n' "${MIRROR_DIR}"
        printf 'COLI_GPU=none\n'
        printf 'COLI_POLICY=quality\n'
        printf 'COLI_MAX_QUEUE=%s\n' "${MAX_QUEUE}"
        printf 'COLI_QUEUE_TIMEOUT=%s\n' "${QUEUE_TIMEOUT}"
        printf 'COLI_KV_SLOTS=%s\n' "${KV_SLOTS}"
        printf 'PIPE=1\n'
        printf 'PIPE_WORKERS=%s\n' "${PIPE_WORKERS}"
        printf 'DIRECT=%s\n' "${DIRECT}"
        printf 'URING=%s\n' "${URING}"
        printf 'PILOT=%s\n' "${PILOT}"
        printf 'PILOT_REAL=%s\n' "${PILOT_REAL}"
        printf 'PIN=auto\n'
        printf 'PIN_GB=%s\n' "${PIN_GB}"
        printf 'AUTOPIN=1\n'
        printf 'KVSAVE=1\n'
        printf 'COLI_TOOL_SALVAGE=1\n'
        printf 'PROF=1\n'
        printf 'RAM_GB=%s\n' "${RAM_GB}"
        printf 'CTX=%s\n' "${CTX}"
    } >"${temp_file}"

    sudo install -d -m 0750 -o root -g "${DEPLOY_GROUP}" "${SYSTEM_CONFIG_DIR}"
    sudo install -m 0640 -o root -g "${DEPLOY_GROUP}" "${temp_file}" "${CONFIG_FILE}"
    rm -f -- "${temp_file}"
    trap - RETURN
}

write_manifest() {
    local temp_file
    umask 077
    temp_file="$(mktemp)"
    trap 'rm -f -- "${temp_file:-}"' RETURN
    {
        printf 'DEPLOY_USER=%s\n' "${DEPLOY_USER}"
        printf 'SOURCE_DIR=%s\n' "${SOURCE_DIR}"
        printf 'SOURCE_CREATED=%s\n' "${SOURCE_CREATED}"
        printf 'SERVICE_FILE=%s\n' "${SERVICE_FILE}"
        printf 'CONFIG_FILE=%s\n' "${CONFIG_FILE}"
    } >"${temp_file}"
    sudo install -d -m 0750 -o root -g "${DEPLOY_GROUP}" "${SYSTEM_STATE_DIR}"
    sudo install -m 0640 -o root -g "${DEPLOY_GROUP}" "${temp_file}" "${INSTALL_MANIFEST}"
    rm -f -- "${temp_file}"
    trap - RETURN
}

any_path_exists() {
    local path
    for path in "$@"; do
        [[ ! -e "${path}" ]] || return 0
    done
    return 1
}

managed_installation_artifacts_exist() {
    any_path_exists "${SERVICE_FILE}" "${CONFIG_FILE}" "${INSTALLED_WAIT_SCRIPT}"
}

service_exec_subcommand() {
    if [[ "${UI_MODE}" == "colibri-web" ]]; then
        printf 'web\n'
    else
        printf 'serve\n'
    fi
}

render_service_unit() {
    local output_file=$1
    local coli_path="${SOURCE_DIR}/c/coli"
    local working_dir="${SOURCE_DIR}/c"
    local subcommand
    local docker_after=""
    local docker_wants="network-online.target"
    local bind_wait=""

    validate_safe_path "${working_dir}" "Working directory"
    validate_safe_path "${MODEL_DIR}" "Model directory"
    subcommand="$(service_exec_subcommand)"

    if [[ "${UI_MODE}" == "open-webui" &&
        "${BIND_HOST}" != "127.0.0.1" &&
        "${BIND_HOST}" != "::1" &&
        "${BIND_HOST}" != "0.0.0.0" &&
        "${BIND_HOST}" != "::" ]]; then
        docker_after=" docker.service"
        docker_wants="network-online.target docker.service"
        bind_wait="ExecStartPre=${INSTALLED_WAIT_SCRIPT} ${BIND_HOST}"
    fi

    cat >"${output_file}" <<EOF
# Managed by vast-development-method/colibri-setup
[Unit]
Description=Colibri CPU/NVMe Inference Service
Documentation=https://github.com/JustVugg/colibri
Wants=${docker_wants}
After=network-online.target local-fs.target${docker_after}
RequiresMountsFor=${MODEL_DIR}

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_GROUP}
WorkingDirectory=${working_dir}
EnvironmentFile=${CONFIG_FILE}
Environment=PYTHONUNBUFFERED=1
${bind_wait}
ExecStart=${coli_path} ${subcommand} --model ${MODEL_DIR} --host ${BIND_HOST} --port ${PORT} --model-id ${MODEL_ID} --ram ${RAM_GB} --ctx ${CTX} --policy quality --max-queue ${MAX_QUEUE} --queue-timeout ${QUEUE_TIMEOUT} --kv-slots ${KV_SLOTS}$([[ "${subcommand}" == "web" ]] && printf ' --no-browser')
Restart=on-failure
RestartSec=10
TimeoutStartSec=0
TimeoutStopSec=120
KillSignal=SIGINT
UMask=0027
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
}

install_service_unit() {
    local temp_unit
    local backup_unit
    local had_previous="0"

    temp_unit="$(mktemp --suffix=.service)"
    backup_unit="$(mktemp)"
    trap 'rm -f -- "${temp_unit:-}" "${backup_unit:-}"' RETURN
    render_service_unit "${temp_unit}"

    if [[ -e "${SERVICE_FILE}" ]]; then
        assert_service_owned_or_absent
        sudo cp -- "${SERVICE_FILE}" "${backup_unit}"
        had_previous="1"
    fi

    sudo install -d -m 0755 -o root -g root "${SYSTEM_LIBEXEC_DIR}"
    sudo install -m 0755 -o root -g root \
        "${SCRIPT_DIR}/scripts/wait_for_address.sh" \
        "${INSTALLED_WAIT_SCRIPT}"

    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "${temp_unit}" >/dev/null
    fi

    sudo install -m 0644 -o root -g root "${temp_unit}" "${SERVICE_FILE}"
    if ! sudo systemctl daemon-reload; then
        if [[ "${had_previous}" == "1" ]]; then
            sudo install -m 0644 -o root -g root "${backup_unit}" "${SERVICE_FILE}"
        else
            sudo rm -f -- "${SERVICE_FILE}"
        fi
        sudo systemctl daemon-reload
        die "systemd rejected the new service unit; the previous unit was restored."
    fi

    rm -f -- "${temp_unit}" "${backup_unit}"
    trap - RETURN
}

install_dependencies() {
    require_command sudo
    command -v apt-get >/dev/null 2>&1 ||
        die "Automatic package installation currently supports Ubuntu/Debian (apt-get)."

    info "Installing required Ubuntu/Debian packages"
    sudo -v
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        iproute2 \
        jq \
        openssl \
        python3 \
        python3-venv \
        rsync \
        screen \
        util-linux
}

ensure_hf_cli() {
    if [[ -x "${HF_VENV_DIR}/bin/hf" ]] &&
        "${HF_VENV_DIR}/bin/hf" cache verify --help >/dev/null 2>&1; then
        return 0
    fi

    require_command python3
    info "Installing/upgrading Hugging Face CLI in an isolated virtual environment"
    python3 -m venv "${HF_VENV_DIR}"
    "${HF_VENV_DIR}/bin/python" -m pip install --upgrade pip huggingface_hub
    [[ -x "${HF_VENV_DIR}/bin/hf" ]] ||
        die "Hugging Face CLI was not installed successfully."
    "${HF_VENV_DIR}/bin/hf" cache verify --help >/dev/null 2>&1 ||
        die "The installed Hugging Face CLI does not provide 'hf cache verify'."
}

format_elapsed_time() {
    local total_seconds=$1
    local output_variable=$2
    printf -v "${output_variable}" '%02d:%02d:%02d' \
        "$((total_seconds / 3600))" \
        "$(((total_seconds % 3600) / 60))" \
        "$((total_seconds % 60))"
}

heartbeat_worker() {
    local label=$1
    local command_pid=$2
    local started_at=$3
    local interval=$4
    local elapsed

    while sleep "${interval}"; do
        kill -0 "${command_pid}" 2>/dev/null || return 0
        format_elapsed_time "$((SECONDS - started_at))" elapsed
        printf '... %s is still running (%s elapsed)\n' \
            "${label}" \
            "${elapsed}" >&2
    done
}

run_with_heartbeat() {
    local label=$1
    local output_file=$2
    shift 2

    local interval=${COLIBRI_HEARTBEAT_INTERVAL_SECONDS:-10}
    [[ "${interval}" =~ ^[1-9][0-9]*$ ]] || interval=10

    local started_at=${SECONDS}
    local command_pid
    local heartbeat_pid=""
    local status
    local elapsed

    : >"${output_file}"
    "$@" >"${output_file}" 2>&1 &
    command_pid=$!

    if [[ -t 2 || "${COLIBRI_FORCE_HEARTBEAT:-0}" == "1" ]]; then
        printf '%s started; checksum progress will be reported every %s seconds.\n' \
            "${label}" "${interval}" >&2
        heartbeat_worker "${label}" "${command_pid}" "${started_at}" "${interval}" &
        heartbeat_pid=$!
    fi

    if wait "${command_pid}"; then
        status=0
    else
        status=$?
    fi

    if [[ -n "${heartbeat_pid}" ]]; then
        kill "${heartbeat_pid}" 2>/dev/null || true
        wait "${heartbeat_pid}" 2>/dev/null || true
        format_elapsed_time "$((SECONDS - started_at))" elapsed
        printf '%s finished after %s.\n' \
            "${label}" \
            "${elapsed}" >&2
    fi

    return "${status}"
}

validate_model_repository() {
    local repository=$1
    [[ "${repository}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die "Invalid Hugging Face repository id: ${repository}"
}

resolve_existing_model_directory() {
    local destination=$1
    destination="$(canonicalize_managed_path "${destination}")"
    validate_safe_path "${destination}" "Model directory"
    [[ -d "${destination}" ]] ||
        die "Model directory does not exist: ${destination}"
    [[ ! -L "${destination}" ]] ||
        die "Model directory must not be a symlink: ${destination}"
    printf '%s\n' "${destination}"
}

extract_model_repair_targets() {
    local verification_output=$1
    awk '
        function is_sha256(value) {
            return length(value) == 64 && value !~ /[^[:xdigit:]]/
        }
        function is_model_artifact(path) {
            return path ~ /\.safetensors$/ ||
                path ~ /\.safetensors\.index\.json$/ ||
                path == "config.json" ||
                path == "generation_config.json" ||
                path == "tokenizer.json" ||
                path == "tokenizer_config.json" ||
                path == "special_tokens_map.json" ||
                path == "added_tokens.json" ||
                path == "chat_template.jinja" ||
                path == "merges.txt" ||
                path == "vocab.json" ||
                path == "tokenizer.model" ||
                path == "preprocessor_config.json"
        }
        index($0, "Checksum verification failed for the following file(s):") {
            section = "mismatch"
            next
        }
        index($0, "Missing files (present remotely, absent locally):") {
            section = "missing"
            next
        }
        section == "mismatch" && /^  - / {
            target = substr($0, 5)
            details = target
            sub(/^[^:]*: /, "", details)
            sub(/: expected .*/, "", target)
            split(details, checksum_fields, /[[:space:]]+/)
            if (length(checksum_fields) == 5 &&
                checksum_fields[1] == "expected" &&
                is_sha256(checksum_fields[2]) &&
                checksum_fields[3] == "(sha256)," &&
                checksum_fields[4] == "got" &&
                is_sha256(checksum_fields[5]) &&
                is_model_artifact(target)) {
                printf "%s\t%s\n", target, tolower(checksum_fields[2])
            }
            next
        }
        section == "missing" && /^  - / {
            target = substr($0, 5)
            if (is_model_artifact(target)) {
                printf "%s\t-\n", target
            }
            next
        }
        /^[^[:space:]]/ {
            section = ""
        }
    ' "${verification_output}" |
        LC_ALL=C sort -u
}

model_repair_record_path() {
    printf '%s\n' "${1%%$'\t'*}"
}

model_repair_record_expected_sha256() {
    local record=$1
    [[ "${record}" == *$'\t'* ]] ||
        die "Invalid model repair record without an expected-hash field."
    printf '%s\n' "${record#*$'\t'}"
}

has_only_mutable_usage_mismatch() {
    local verification_output=$1
    awk '
        index($0, "Checksum verification failed for the following file(s):") {
            section = "mismatch"
            next
        }
        index($0, "Missing files (present remotely, absent locally):") {
            section = "missing"
            next
        }
        section == "mismatch" && /^  - / {
            target = substr($0, 5)
            sub(/: expected .*/, "", target)
            mismatch_count++
            if (target != ".coli_usage") {
                significant_count++
            }
            next
        }
        section == "missing" && /^  - / {
            if (substr($0, 5) != ".coli_usage") {
                significant_count++
            }
            next
        }
        /^[^[:space:]]/ {
            section = ""
        }
        END {
            exit !(mismatch_count > 0 && significant_count == 0)
        }
    ' "${verification_output}"
}

run_model_integrity() {
    local repository=$1
    local destination=$2
    local output_file=$3
    local repair_list=${4:-}
    local status=0

    [[ -z "${repair_list}" ]] || : >"${repair_list}"
    if run_with_heartbeat \
        "Model checksum verification" \
        "${output_file}" \
        env HF_HUB_DISABLE_TELEMETRY=1 \
        "${HF_VENV_DIR}/bin/hf" cache verify "${repository}" \
            --local-dir "${destination}" \
            --fail-on-missing-files; then
        status=0
    else
        status=$?
    fi

    if ((status == 0)); then
        cat -- "${output_file}"
    elif has_only_mutable_usage_mismatch "${output_file}"; then
        grep '^Warning:' "${output_file}" || true
        warn "Skipping .coli_usage because Colibri owns and may recreate this runtime file."
        status=0
    else
        cat -- "${output_file}" >&2
        if [[ -n "${repair_list}" ]]; then
            extract_model_repair_targets "${output_file}" >"${repair_list}"
        fi
    fi
    return "${status}"
}

validate_model_repair_target() {
    local destination=$1
    local relative_path=$2
    local current=${destination}
    local -a path_parts=()
    local index

    [[ -n "${relative_path}" && "${relative_path}" != /* ]] ||
        die "Unsafe repair target returned by Hugging Face: ${relative_path}"
    [[ "${relative_path}" != *$'\n'* &&
        "${relative_path}" != *$'\r'* &&
        "${relative_path}" != *$'\t'* ]] ||
        die "Repair target contains control characters."

    IFS='/' read -r -a path_parts <<<"${relative_path}"
    ((${#path_parts[@]} > 0)) ||
        die "Repair target is empty."
    for index in "${!path_parts[@]}"; do
        [[ -n "${path_parts[index]}" &&
            "${path_parts[index]}" != "." &&
            "${path_parts[index]}" != ".." ]] ||
            die "Unsafe repair target returned by Hugging Face: ${relative_path}"
        if ((index + 1 < ${#path_parts[@]})); then
            current="${current}/${path_parts[index]}"
            [[ ! -L "${current}" ]] ||
                die "Repair target traverses a symbolic link: ${current}"
        fi
    done
    [[ ! -L "${destination}/${relative_path}" ]] ||
        die "Refusing to replace a symbolic link: ${destination}/${relative_path}"
}

parse_model_repair_arguments() {
    local repository_variable=$1
    local destination_variable=$2
    shift 2

    local -a positionals=()

    while (($#)); do
        case "$1" in
            --yes | -y)
                AUTO_YES="1"
                shift
                ;;
            --)
                shift
                while (($#)); do
                    positionals+=("$1")
                    shift
                done
                ;;
            -*)
                die "Unknown model repair option: $1"
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    ((${#positionals[@]} <= 2)) ||
        die "Usage: ./colibri.sh model repair [MODEL_REPOSITORY] [MODEL_DIRECTORY] [--yes]"

    printf -v "${repository_variable}" '%s' \
        "${positionals[0]:-${MODEL_REPO}}"
    printf -v "${destination_variable}" '%s' \
        "${positionals[1]:-${MODEL_DIR}}"
}

build_model_repair_plan() {
    local repository=$1
    local destination=$2
    local repair_records_variable=$3
    local -n repair_records_reference="${repair_records_variable}"
    local verification_output
    local repair_list
    local verification_status=0

    verification_output="$(mktemp)"
    repair_list="$(mktemp)"
    rm -f -- "${repair_list}"

    if run_model_integrity \
        "${repository}" \
        "${destination}" \
        "${verification_output}" \
        "${repair_list}"; then
        rm -f -- "${verification_output}" "${repair_list}"
        return 0
    else
        verification_status=$?
    fi
    rm -f -- "${verification_output}"

    if ((verification_status != 1)) || [[ ! -f "${repair_list}" ]]; then
        rm -f -- "${repair_list}"
        die "Could not build a reliable repair plan; no model files were changed."
    fi

    mapfile -t repair_records_reference <"${repair_list}"
    rm -f -- "${repair_list}"
    ((${#repair_records_reference[@]} > 0)) ||
        die "Verification failed without identifying a safe model-artifact repair target."
    return 1
}

validate_and_print_model_repair_plan() {
    local destination=$1
    shift
    local -a repair_records=("$@")
    local repair_record
    local repair_file
    local expected_sha256

    printf '\nExactly these %d missing or corrupt model file(s) will be repaired:\n' \
        "${#repair_records[@]}"
    for repair_record in "${repair_records[@]}"; do
        repair_file="$(model_repair_record_path "${repair_record}")"
        expected_sha256="$(model_repair_record_expected_sha256 "${repair_record}")"
        validate_model_repair_target "${destination}" "${repair_file}"
        if [[ "${expected_sha256}" == "-" ]]; then
            printf '  - %s (missing; checksum will be verified before activation)\n' \
                "${repair_file}"
        else
            [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] ||
                die "Invalid expected SHA-256 in model repair plan for ${repair_file}."
            printf '  - %s (expected SHA-256: %s)\n' \
                "${repair_file}" "${expected_sha256}"
        fi
    done
}

assert_model_repair_service_stopped() {
    if [[ -e "${SERVICE_FILE}" ]] &&
        command -v systemctl >/dev/null 2>&1 &&
        systemctl is-active --quiet "${SERVICE_NAME}"; then
        die "Colibri is running. Stop it with './colibri.sh stop' before replacing model files."
    fi
}

download_model_repair_files() {
    local repository=$1
    local repair_stage=$2
    shift 2
    local -a repair_records=("$@")
    local -a repair_files=()
    local repair_record

    for repair_record in "${repair_records[@]}"; do
        repair_files+=("$(model_repair_record_path "${repair_record}")")
    done

    info "Downloading the exact repair list into an isolated staging directory"
    printf 'Hugging Face may display many transfer chunks for one large file; the file list above is the complete repair scope.\n'
    if ! HF_HUB_DISABLE_TELEMETRY=1 \
        HF_HOME="${repair_stage}/.hf-home" \
        HF_HUB_CACHE="${repair_stage}/.hf-home/hub" \
        HF_XET_CACHE="${repair_stage}/.hf-home/xet" \
        "${HF_VENV_DIR}/bin/hf" download \
            "${repository}" \
            "${repair_files[@]}" \
            --repo-type model \
            --local-dir "${repair_stage}"; then
        return 1
    fi
}

validate_staged_model_repair() {
    local repository=$1
    local destination=$2
    local repair_stage=$3
    shift 3
    local -a repair_records=("$@")
    local repair_record
    local repair_file
    local expected_sha256
    local actual_sha256
    local verification_view
    local verification_output

    for repair_record in "${repair_records[@]}"; do
        repair_file="$(model_repair_record_path "${repair_record}")"
        expected_sha256="$(model_repair_record_expected_sha256 "${repair_record}")"
        [[ -s "${repair_stage}/${repair_file}" ]] || {
            error "Hugging Face did not produce the requested repair file: ${repair_file}"
            return 1
        }
        if [[ "${expected_sha256}" != "-" ]]; then
            actual_sha256="$(sha256sum -- "${repair_stage}/${repair_file}")"
            actual_sha256=${actual_sha256%% *}
            if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
                error "Downloaded repair file failed SHA-256 verification: ${repair_file}"
                error "Expected: ${expected_sha256}"
                error "Actual:   ${actual_sha256}"
                return 1
            fi
        fi
    done

    verification_view="$(
        mktemp -d "$(dirname -- "${destination}")/.colibri-repair-verify.XXXXXX"
    )"
    if ! cp -al -- "${destination}/." "${verification_view}/"; then
        rm -rf --one-file-system -- "${verification_view}"
        error "Could not create the hard-linked model verification view."
        return 1
    fi
    # Never expose the live model's downloader metadata to the verifier through
    # hard links. Any verifier metadata must remain isolated in this disposable
    # prospective-model view.
    rm -rf --one-file-system -- "${verification_view}/.cache"

    for repair_record in "${repair_records[@]}"; do
        repair_file="$(model_repair_record_path "${repair_record}")"
        mkdir -p -- "${verification_view}/$(dirname -- "${repair_file}")"
        rm -f -- "${verification_view}/${repair_file}"
        if ! ln -- "${repair_stage}/${repair_file}" \
            "${verification_view}/${repair_file}"; then
            rm -rf --one-file-system -- "${verification_view}"
            error "Could not add staged file to verification view: ${repair_file}"
            return 1
        fi
    done

    verification_output="$(mktemp)"
    if ! run_model_integrity \
        "${repository}" \
        "${verification_view}" \
        "${verification_output}"; then
        rm -f -- "${verification_output}"
        rm -rf --one-file-system -- "${verification_view}"
        error "The prospective repaired model failed complete checksum verification."
        return 1
    fi
    rm -f -- "${verification_output}"
    rm -rf --one-file-system -- "${verification_view}"
}

activate_model_repair_files() {
    local destination=$1
    local repair_stage=$2
    local repair_backup=$3
    local activated_files_variable=$4
    shift 4
    local -n activated_files_reference="${activated_files_variable}"
    local repair_file

    for repair_file in "$@"; do
        mkdir -p -- \
            "${repair_backup}/$(dirname -- "${repair_file}")" \
            "${destination}/$(dirname -- "${repair_file}")"
        if [[ -e "${destination}/${repair_file}" ]]; then
            if ! mv -- "${destination}/${repair_file}" \
                "${repair_backup}/${repair_file}"; then
                return 1
            fi
        fi
        if ! mv -- "${repair_stage}/${repair_file}" \
            "${destination}/${repair_file}"; then
            if [[ -e "${repair_backup}/${repair_file}" ]]; then
                mv -- "${repair_backup}/${repair_file}" \
                    "${destination}/${repair_file}" || true
            fi
            return 1
        fi
        activated_files_reference+=("${repair_file}")
    done
}

restore_model_repair_files() {
    local destination=$1
    local repair_backup=$2
    shift 2
    local repair_file

    for repair_file in "$@"; do
        rm -f -- "${destination}/${repair_file}"
        if [[ -e "${repair_backup}/${repair_file}" ]]; then
            mkdir -p -- "${destination}/$(dirname -- "${repair_file}")"
            mv -- "${repair_backup}/${repair_file}" \
                "${destination}/${repair_file}"
        fi
    done
}

verify_completed_model_repair() {
    local repository=$1
    local destination=$2
    local verification_output

    verification_output="$(mktemp)"
    if ! run_model_integrity \
        "${repository}" \
        "${destination}" \
        "${verification_output}"; then
        rm -f -- "${verification_output}"
        return 1
    fi
    rm -f -- "${verification_output}"
}

perform_model_repair() {
    local repository=$1
    local destination=$2
    local -a repair_records=()
    local -a repair_files=()
    local -a activated_files=()
    local repair_record
    local repair_stage
    local repair_backup

    info "Finding missing or checksum-mismatched model files"
    printf 'Repository: %s\n' "${repository}"
    printf 'Directory:  %s\n' "${destination}"

    if build_model_repair_plan \
        "${repository}" \
        "${destination}" \
        repair_records; then
        info "No repair is needed; the model already passes verification."
        return 0
    fi

    validate_and_print_model_repair_plan "${destination}" "${repair_records[@]}"
    for repair_record in "${repair_records[@]}"; do
        repair_files+=("$(model_repair_record_path "${repair_record}")")
    done
    assert_model_repair_service_stopped
    confirm "Download and atomically repair only the listed file(s)?" no ||
        die "Model repair cancelled."

    repair_stage="$(mktemp -d "$(dirname -- "${destination}")/.colibri-repair.XXXXXX")"
    repair_backup="${repair_stage}/.original"
    mkdir -p -- "${repair_backup}"

    if ! download_model_repair_files \
        "${repository}" \
        "${repair_stage}" \
        "${repair_records[@]}"; then
        rm -rf --one-file-system -- "${repair_stage}"
        die "Staged repair download failed. The live model directory was not changed."
    fi

    if ! validate_staged_model_repair \
        "${repository}" \
        "${destination}" \
        "${repair_stage}" \
        "${repair_records[@]}"; then
        rm -rf --one-file-system -- "${repair_stage}"
        die "Staged repair validation failed. The live model directory was not changed."
    fi
    info "Activating only the verified repair list"
    if ! activate_model_repair_files \
        "${destination}" \
        "${repair_stage}" \
        "${repair_backup}" \
        activated_files \
        "${repair_files[@]}"; then
        restore_model_repair_files \
            "${destination}" \
            "${repair_backup}" \
            "${activated_files[@]}"
        rm -rf --one-file-system -- "${repair_stage}"
        die "Repair activation failed; every changed model file was restored."
    fi

    info "Re-verifying the complete model after repair"
    if ! verify_completed_model_repair "${repository}" "${destination}"; then
        warn "Post-repair verification failed. Restoring every original file."
        restore_model_repair_files \
            "${destination}" \
            "${repair_backup}" \
            "${repair_files[@]}"
        rm -rf --one-file-system -- "${repair_stage}"
        die "Repair was rolled back; the original local model files were restored."
    fi

    rm -rf --one-file-system -- "${repair_stage}"
    info "Model repair passed. Only the listed missing or corrupt files were changed."
}

command_model_repair() {
    load_config
    ensure_hf_cli
    ensure_hf_token

    local repository
    local destination
    parse_model_repair_arguments repository destination "$@"
    validate_model_repository "${repository}"
    destination="$(resolve_existing_model_directory "${destination}")"
    perform_model_repair "${repository}" "${destination}"
}

validate_source_checkout() {
    local checkout_dir=${1:-${SOURCE_DIR}}
    [[ -d "${checkout_dir}/.git" ]] ||
        die "Colibri source checkout is missing: ${checkout_dir}"
    local remote_url
    remote_url="$(git -C "${checkout_dir}" remote get-url origin)"
    case "${remote_url}" in
        "${UPSTREAM_URL}" | "git@github.com:JustVugg/colibri.git") ;;
        *) die "Existing source checkout has the wrong origin: ${remote_url}" ;;
    esac

    # Upstream v1.1.1 creates this untracked build stamp while parsing
    # c/Makefile but does not list it in .gitignore. Ignore only this exact
    # known artifact locally; all other tracked or untracked changes remain a
    # hard stop.
    local exclude_file="${checkout_dir}/.git/info/exclude"
    mkdir -p -- "$(dirname -- "${exclude_file}")"
    if ! grep -Fxq 'c/.build-config' "${exclude_file}" 2>/dev/null; then
        printf 'c/.build-config\n' >>"${exclude_file}"
    fi

    if [[ -n "$(git -C "${checkout_dir}" status --porcelain --untracked-files=all)" ]]; then
        die "Colibri source checkout has local changes. Preserve or remove them before continuing: ${checkout_dir}"
    fi
}

create_staging_path() {
    validate_safe_path "${SOURCE_DIR}" "Source directory"
    local source_parent
    local source_name
    local staging_path
    source_parent="$(dirname -- "${SOURCE_DIR}")"
    source_name="$(basename -- "${SOURCE_DIR}")"
    mkdir -p -- "${source_parent}"
    staging_path="$(mktemp -d "${source_parent}/.${source_name}.stage.XXXXXX")"
    rmdir -- "${staging_path}"
    printf '%s\n' "${staging_path}"
}

checkout_staged_ref() {
    local checkout_dir=$1
    local requested_ref=$2
    [[ "${requested_ref}" =~ ^[A-Za-z0-9._/-]+$ ]] ||
        die "Invalid ref: ${requested_ref}"

    git -C "${checkout_dir}" fetch --tags --prune origin
    if [[ "${requested_ref}" == "latest" ]]; then
        requested_ref="$(
            git -C "${checkout_dir}" tag --list 'v*' --sort=-v:refname |
                head -n 1
        )"
        [[ -n "${requested_ref}" ]] || die "No upstream release tags were found."
    fi

    if git -C "${checkout_dir}" show-ref --verify --quiet "refs/tags/${requested_ref}"; then
        git -C "${checkout_dir}" checkout --detach "refs/tags/${requested_ref}"
    elif git -C "${checkout_dir}" show-ref --verify --quiet \
        "refs/remotes/origin/${requested_ref}"; then
        git -C "${checkout_dir}" checkout --detach "refs/remotes/origin/${requested_ref}"
    elif git -C "${checkout_dir}" rev-parse --verify --quiet \
        "${requested_ref}^{commit}" >/dev/null; then
        git -C "${checkout_dir}" checkout --detach "${requested_ref}"
    else
        die "Upstream ref was not found: ${requested_ref}"
    fi
    STAGED_RESOLVED_REF="${requested_ref}"
}

prepare_staged_source() {
    local requested_ref=$1
    local update_requested=$2
    validate_safe_path "${SOURCE_DIR}" "Source directory"
    [[ "${requested_ref}" =~ ^[A-Za-z0-9._/-]+$ ]] ||
        die "Invalid ref: ${requested_ref}"

    STAGED_SOURCE_DIR="$(create_staging_path)"
    if [[ -d "${SOURCE_DIR}/.git" ]]; then
        validate_source_checkout
        STAGED_SOURCE_LIVE_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
        info "Copying the current Colibri checkout into a staged release"
        git clone --no-hardlinks -- "${SOURCE_DIR}" "${STAGED_SOURCE_DIR}"
        git -C "${STAGED_SOURCE_DIR}" remote set-url origin "${UPSTREAM_URL}"
    elif [[ -e "${SOURCE_DIR}" ]]; then
        die "${SOURCE_DIR} exists but is not a Git checkout."
    else
        info "Cloning Colibri into a staged release"
        git clone --no-checkout -- "${UPSTREAM_URL}" "${STAGED_SOURCE_DIR}"
        SOURCE_CREATED="1"
    fi

    if [[ -z "${STAGED_SOURCE_LIVE_COMMIT}" || "${update_requested}" == "1" ]]; then
        info "Resolving Colibri ${requested_ref} in the staged release"
        checkout_staged_ref "${STAGED_SOURCE_DIR}" "${requested_ref}"
    else
        git -C "${STAGED_SOURCE_DIR}" checkout --detach "${STAGED_SOURCE_LIVE_COMMIT}"
        STAGED_RESOLVED_REF="${requested_ref}"
        printf 'Staged commit: %s\n' \
            "$(git -C "${STAGED_SOURCE_DIR}" rev-parse --short HEAD)"
    fi
    validate_source_checkout "${STAGED_SOURCE_DIR}"
}

build_colibri() {
    local checkout_dir=${1:-${SOURCE_DIR}}
    validate_source_checkout "${checkout_dir}"
    info "Building a CPU-native Colibri binary"
    (
        cd -- "${checkout_dir}/c"
        ARCH=native ./setup.sh
    )

    [[ -x "${checkout_dir}/c/colibri" ]] ||
        die "Colibri engine binary was not built."
    [[ -x "${checkout_dir}/c/coli" ]] || die "Colibri CLI was not found."

    if ldd "${checkout_dir}/c/colibri" 2>/dev/null | grep -q 'libcudart'; then
        die "The generated binary links CUDA. Refusing it because this deployment reserves the GPU for other workloads."
    fi
}

node_version_supports_colibri_web() {
    local version=${1#v}
    local major
    local minor

    [[ "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}

    ((major == 20 && minor >= 19)) ||
        ((major == 22 && minor >= 12)) ||
        ((major >= 23))
}

install_supported_nodejs() {
    require_command sudo
    require_command curl
    command -v apt-get >/dev/null 2>&1 ||
        die "Automatic Node.js installation currently supports Ubuntu/Debian (apt-get)."

    info "Installing Node.js 22 for the optional Colibri dashboard"
    sudo install -d -m 0755 /etc/apt/keyrings

    local keyring
    keyring="$(mktemp)"
    if ! curl --fail --silent --show-error --location \
        https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
        gpg --dearmor >"${keyring}"; then
        rm -f -- "${keyring}"
        die "Could not download the NodeSource repository signing key."
    fi
    sudo install -m 0644 "${keyring}" /etc/apt/keyrings/nodesource.gpg
    rm -f -- "${keyring}"

    printf '%s\n' \
        'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' |
        sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y nodejs
}

ensure_supported_nodejs() {
    local installed_version=""

    if command -v node >/dev/null 2>&1; then
        installed_version="$(node --version)"
    fi
    if [[ -n "${installed_version}" ]] &&
        node_version_supports_colibri_web "${installed_version}" &&
        command -v npm >/dev/null 2>&1; then
        return 0
    fi

    if [[ -n "${installed_version}" ]]; then
        warn "Node.js ${installed_version} cannot build the Colibri dashboard; Node.js 20.19+ or 22.12+ is required."
    fi
    install_supported_nodejs

    installed_version="$(node --version)"
    node_version_supports_colibri_web "${installed_version}" ||
        die "A supported Node.js release was not installed (found ${installed_version})."
    require_command npm
}

ensure_colibri_web_assets() {
    local checkout_dir=${1:-${SOURCE_DIR}}
    [[ "${UI_MODE}" == "colibri-web" ]] || return 0
    [[ -d "${checkout_dir}/web" ]] || die "Upstream Colibri web source is missing."
    ensure_supported_nodejs
    info "Building Colibri's optional dashboard"
    (
        cd -- "${checkout_dir}/web"
        if [[ -f package-lock.json ]]; then
            npm ci
        else
            npm install
        fi
        npm run build
    )
}

apply_ui_asset_mode() {
    local checkout_dir=${1:-${SOURCE_DIR}}
    local web_dir="${checkout_dir}/web"
    local enabled_dir="${web_dir}/dist"

    [[ -d "${web_dir}" ]] || return 0

    if [[ "${UI_MODE}" == "colibri-web" ]]; then
        [[ -d "${enabled_dir}" ]] ||
            die "Colibri dashboard assets are missing after the web build."
    else
        # Upstream also serves web/dist from `coli serve` when it exists. These
        # are generated assets, so remove them in API-only modes and rebuild
        # explicitly if the operator later selects colibri-web.
        if [[ -d "${enabled_dir}" ]]; then
            rm -rf --one-file-system -- "${enabled_dir}"
        fi
    fi
}

activate_staged_source() {
    [[ -n "${STAGED_SOURCE_DIR}" && -d "${STAGED_SOURCE_DIR}/.git" ]] ||
        die "The staged Colibri checkout is missing."
    validate_source_checkout "${STAGED_SOURCE_DIR}"
    if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
        die "Refusing to activate source while ${SERVICE_NAME} is running."
    fi

    local rollback_path
    rollback_path="${SOURCE_DIR}.previous-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    if [[ -n "${STAGED_SOURCE_LIVE_COMMIT}" ]]; then
        validate_source_checkout
        [[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" == "${STAGED_SOURCE_LIVE_COMMIT}" ]] ||
            die "The live source changed while the staged release was being built."
        [[ ! -e "${rollback_path}" ]] ||
            die "Rollback path already exists: ${rollback_path}"

        atomic_exchange_paths "${SOURCE_DIR}" "${STAGED_SOURCE_DIR}"
        ACTIVATION_HAD_PREVIOUS="1"
        ACTIVATION_PREVIOUS_SOURCE="${STAGED_SOURCE_DIR}"
        ACTIVATION_NEEDS_ROLLBACK="1"
        mv -T -- "${STAGED_SOURCE_DIR}" "${rollback_path}"
        ACTIVATION_PREVIOUS_SOURCE="${rollback_path}"
        STAGED_SOURCE_DIR=""
    else
        [[ ! -e "${SOURCE_DIR}" ]] ||
            die "The source path appeared while the staged release was being built: ${SOURCE_DIR}"
        mv -T -- "${STAGED_SOURCE_DIR}" "${SOURCE_DIR}"
        STAGED_SOURCE_DIR=""
        ACTIVATION_HAD_PREVIOUS="0"
        ACTIVATION_PREVIOUS_SOURCE=""
        ACTIVATION_NEEDS_ROLLBACK="1"
    fi

    validate_source_checkout
    printf 'Activated commit: %s\n' "$(git -C "${SOURCE_DIR}" rev-parse --short HEAD)"
}

complete_source_activation() {
    ACTIVATION_NEEDS_ROLLBACK="0"
    ACTIVATION_SERVICE_STOPPED="0"
    if [[ -n "${ACTIVATION_PREVIOUS_SOURCE}" ]]; then
        printf 'Previous source retained for rollback: %s\n' \
            "${ACTIVATION_PREVIOUS_SOURCE}"
    fi
}

stop_service_for_source_activation() {
    local was_active=$1
    ACTIVATION_SERVICE_WAS_ACTIVE="${was_active}"
    if [[ "${was_active}" == "1" ]]; then
        ACTIVATION_SERVICE_STOPPED="1"
        info "Stopping Colibri for atomic source activation"
        sudo systemctl stop "${SERVICE_NAME}"
    fi
}

model_is_ready() {
    [[ -r "${MODEL_DIR}/config.json" ]] || return 1
    [[ -r "${MODEL_DIR}/tokenizer.json" ]] || return 1
    local shard_count
    shard_count="$(
        find -L "${MODEL_DIR}" -maxdepth 1 -type f -name '*.safetensors' -printf '.' |
            wc -c
    )"
    ((shard_count > 0)) || return 1

    if [[ "${MODEL_REPO}" == "${DEFAULT_MODEL_REPO}" ]]; then
        ((shard_count >= 100)) || return 1
        local -a mtp_sizes=()
        mapfile -t mtp_sizes < <(
            find -L "${MODEL_DIR}" -maxdepth 1 -type f -name 'out-mtp-*' -printf '%s\n' |
                sort -n
        )
        local expected_sizes="1065950496 3527131672 5366238584"
        [[ "${mtp_sizes[*]:-}" == "${expected_sizes}" ]] || return 1
    fi

    if [[ -r "${MODEL_DIR}/model.safetensors.index.json" ]]; then
        command -v jq >/dev/null 2>&1 || return 1
        jq -e '
            (.weight_map | type == "object") and
            (.weight_map | length > 0) and
            ([.weight_map[] | type == "string"] | all)
        ' "${MODEL_DIR}/model.safetensors.index.json" >/dev/null || return 1
        local -a indexed_shards=()
        mapfile -t indexed_shards < <(
            jq -r '.weight_map[]' "${MODEL_DIR}/model.safetensors.index.json" |
                LC_ALL=C sort -u
        )
        local indexed_shard
        for indexed_shard in "${indexed_shards[@]}"; do
            [[ -n "${indexed_shard}" &&
                "${indexed_shard}" != /* &&
                "${indexed_shard}" != *$'\t'* &&
                "${indexed_shard}" != *$'\r'* &&
                "${indexed_shard}" != *$'\n'* ]] || return 1
            case "/${indexed_shard}/" in
                */../* | */./*) return 1 ;;
            esac
            [[ -f "${MODEL_DIR}/${indexed_shard}" ]] || return 1
        done
    fi
    return 0
}

validate_model() {
    validate_safe_path "${MODEL_DIR}" "Model directory"
    [[ -d "${MODEL_DIR}" ]] || die "Model directory does not exist: ${MODEL_DIR}"
    [[ ! -L "${MODEL_DIR}" ]] || die "Model directory must not be a symlink: ${MODEL_DIR}"
    [[ -r "${MODEL_DIR}/config.json" ]] ||
        die "Missing config.json directly inside ${MODEL_DIR}. The repository may be nested one level too deeply."
    [[ -r "${MODEL_DIR}/tokenizer.json" ]] ||
        die "Missing tokenizer.json directly inside ${MODEL_DIR}."
    model_is_ready ||
        die "Model artifacts are incomplete. Finish/resume the managed download, then run doctor again."
    [[ -w "${MODEL_DIR}" ]] ||
        die "The deployment user needs write access to ${MODEL_DIR} for .coli_usage and KV sidecars."
}

configured_base_url() {
    local host="${BIND_HOST}"
    if [[ "${host}" == "0.0.0.0" || "${host}" == "::" ]]; then
        if [[ "${host}" == "::" ]]; then
            host="::1"
        else
            host="127.0.0.1"
        fi
    fi
    if [[ "${host}" == *:* ]]; then
        host="[${host}]"
    fi
    printf 'http://%s:%s' "${host}" "${PORT}"
}

api_request() {
    local method=$1
    local url=$2
    local payload=${3:-}
    local curl_config
    local response_file
    local payload_file=""
    local status=0

    require_command curl
    require_command jq
    [[ "${method}" == "GET" || "${method}" == "POST" ]] ||
        die "Unsupported API request method: ${method}"
    [[ "${COLI_API_KEY}" =~ ^[A-Fa-f0-9]{64}$ ]] ||
        die "Configured Colibri API key is invalid."

    umask 077
    curl_config="$(mktemp)"
    response_file="$(mktemp)"
    printf 'header = "Authorization: Bearer %s"\n' \
        "${COLI_API_KEY}" >"${curl_config}"

    local -a curl_arguments=(
        --silent
        --show-error
        --fail-with-body
        --noproxy '*'
        --request "${method}"
        --url "${url}"
        --config "${curl_config}"
        --output "${response_file}"
    )
    if [[ -n "${payload}" ]]; then
        payload_file="$(mktemp)"
        printf '%s' "${payload}" >"${payload_file}"
        printf 'header = "Content-Type: application/json"\n' >>"${curl_config}"
        curl_arguments+=(--data-binary "@${payload_file}")
    fi

    if curl "${curl_arguments[@]}"; then
        status=0
    else
        status=$?
        [[ ! -s "${response_file}" ]] || cat -- "${response_file}" >&2
        rm -f -- "${curl_config}" "${response_file}"
        [[ -z "${payload_file}" ]] || rm -f -- "${payload_file}"
        return "${status}"
    fi

    if jq -e . "${response_file}" >/dev/null 2>&1; then
        jq . "${response_file}"
    else
        cat -- "${response_file}"
    fi
    rm -f -- "${curl_config}" "${response_file}"
    [[ -z "${payload_file}" ]] || rm -f -- "${payload_file}"
}

port_is_listening() {
    ss -H -ltn "sport = :${PORT}" 2>/dev/null | grep -q .
}

preflight_start() {
    load_config
    assert_service_owned_or_absent
    validate_source_checkout
    [[ -x "${SOURCE_DIR}/c/coli" && -x "${SOURCE_DIR}/c/colibri" ]] ||
        die "Colibri is not built. Run: ./colibri.sh upgrade"
    validate_model
    validate_port "${PORT}"
    validate_host "${BIND_HOST}"

    if ldd "${SOURCE_DIR}/c/colibri" 2>/dev/null | grep -q 'libcudart'; then
        die "Configured engine links CUDA; this CPU/NVMe deployment will not start it."
    fi

    if ! sudo systemctl is-active --quiet "${SERVICE_NAME}" && port_is_listening; then
        die "Port ${PORT} is already in use. Choose another port with ./colibri.sh configure --port PORT."
    fi
}

parse_common_options() {
    while (($#)); do
        case "$1" in
            --model-dir)
                [[ $# -ge 2 ]] || die "--model-dir requires a value."
                MODEL_DIR=$2
                shift 2
                ;;
            --model-repo)
                [[ $# -ge 2 ]] || die "--model-repo requires a value."
                MODEL_REPO=$2
                shift 2
                ;;
            --source-dir)
                [[ $# -ge 2 ]] || die "--source-dir requires a value."
                if [[ "$2" != "${SOURCE_DIR}" ]]; then
                    SOURCE_CREATED="0"
                fi
                SOURCE_DIR=$2
                shift 2
                ;;
            --ref)
                [[ $# -ge 2 ]] || die "--ref requires a value."
                UPSTREAM_REF=$2
                UPDATE_SOURCE="1"
                shift 2
                ;;
            --host)
                [[ $# -ge 2 ]] || die "--host requires a value."
                BIND_HOST=$2
                shift 2
                ;;
            --port)
                [[ $# -ge 2 ]] || die "--port requires a value."
                PORT=$2
                shift 2
                ;;
            --profile)
                [[ $# -ge 2 ]] || die "--profile requires a value."
                PROFILE=$2
                shift 2
                ;;
            --ram)
                [[ $# -ge 2 ]] || die "--ram requires a value."
                CUSTOM_RAM=$2
                PROFILE="custom"
                shift 2
                ;;
            --ctx)
                [[ $# -ge 2 ]] || die "--ctx requires a value."
                CUSTOM_CTX=$2
                PROFILE="custom"
                shift 2
                ;;
            --workers)
                [[ $# -ge 2 ]] || die "--workers requires a value."
                CUSTOM_WORKERS=$2
                PROFILE="custom"
                shift 2
                ;;
            --ui)
                [[ $# -ge 2 ]] || die "--ui requires a value."
                UI_MODE=$2
                shift 2
                ;;
            --no-start)
                NO_START="1"
                shift
                ;;
            --no-download)
                NO_DOWNLOAD="1"
                shift
                ;;
            --rotate-api-key)
                ROTATE_API_KEY="1"
                shift
                ;;
            --update-source)
                UPDATE_SOURCE="1"
                shift
                ;;
            --yes | -y)
                AUTO_YES="1"
                shift
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

command_install() {
    require_non_root
    ensure_state_dirs
    acquire_lock
    load_config
    parse_common_options "$@"

    validate_profile_name "${PROFILE}"
    validate_ui_mode "${UI_MODE}"
    validate_port "${PORT}"
    validate_host "${BIND_HOST}"
    validate_safe_path "${SOURCE_DIR}" "Source directory"
    validate_safe_path "${MODEL_DIR}" "Model directory"
    validate_managed_path_separation
    assert_service_owned_or_absent

    printf 'Colibri source:     %s (%s)\n' "${SOURCE_DIR}" "${UPSTREAM_REF}"
    printf 'Model repository:   %s\n' "${MODEL_REPO}"
    printf 'Model directory:    %s\n' "${MODEL_DIR}"
    printf 'API listener:       http://%s:%s\n' "${BIND_HOST}" "${PORT}"
    printf 'UI mode:            %s\n' "${UI_MODE}"
    resolve_profile "${PROFILE}"
    show_profile_values
    confirm "Install this Colibri deployment?" yes || die "Installation cancelled."

    local was_active="0"
    if sudo systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        was_active="1"
    fi

    # Keep an existing healthy service alive while dependencies and a complete
    # staged release are prepared. The live source path is not touched until
    # the service has stopped for the atomic activation.
    # Record ownership before any fallible package or build operation so a
    # partial first installation remains safely uninstallable.
    write_manifest
    install_dependencies
    prepare_staged_source "${UPSTREAM_REF}" "${UPDATE_SOURCE}"
    build_colibri "${STAGED_SOURCE_DIR}"
    ensure_colibri_web_assets "${STAGED_SOURCE_DIR}"
    apply_ui_asset_mode "${STAGED_SOURCE_DIR}"
    UPSTREAM_REF="${STAGED_RESOLVED_REF}"
    stop_service_for_source_activation "${was_active}"
    activate_staged_source
    write_config
    install_service_unit
    write_manifest

    if model_is_ready; then
        info "Validating existing model"
        validate_model
        command_doctor
        command_plan
        if [[ "${NO_START}" == "0" ]]; then
            if [[ "${was_active}" == "1" ]]; then
                command_restart
            else
                command_start
            fi
        else
            sudo systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
            info "Installation complete; service left stopped by request."
        fi
    else
        sudo systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        warn "The service remains disabled because the model is not complete."
        if [[ "${NO_DOWNLOAD}" == "0" ]] &&
            confirm "Start the approximately 372 GB model download in GNU Screen?" yes; then
            command_model download "${MODEL_REPO}" "${MODEL_DIR}" --yes
        else
            printf 'Start it later with:\n'
            printf '  ./colibri.sh model download %q %q\n' "${MODEL_REPO}" "${MODEL_DIR}"
        fi
    fi
    complete_source_activation

    if [[ "${UI_MODE}" == "open-webui" ]]; then
        info "Open WebUI integration"
        printf 'After the model is ready, run:\n'
        printf '  ./colibri.sh open-webui setup\n'
    fi
}

command_configure() {
    require_non_root
    acquire_lock
    load_config
    local option
    for option in "$@"; do
        case "${option}" in
            --source-dir | --ref | --update-source)
                die "Source changes are not a configure operation. Use ./colibri.sh upgrade --ref REF."
                ;;
        esac
    done
    parse_common_options "$@"
    resolve_profile "${PROFILE}"
    validate_managed_path_separation
    assert_service_owned_or_absent

    printf 'Model directory:    %s\n' "${MODEL_DIR}"
    printf 'API listener:       http://%s:%s\n' "${BIND_HOST}" "${PORT}"
    printf 'UI mode:            %s\n' "${UI_MODE}"
    show_profile_values
    confirm "Apply this configuration?" yes || die "Configuration cancelled."

    local was_active="0"
    if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
        was_active="1"
    fi

    ensure_colibri_web_assets
    apply_ui_asset_mode
    write_config
    install_service_unit
    write_manifest

    if [[ "${was_active}" == "1" && "${NO_START}" == "0" ]]; then
        preflight_start
        sudo systemctl restart "${SERVICE_NAME}"
    fi
    info "Configuration updated."
}

command_upgrade() {
    require_non_root
    acquire_lock
    load_config
    local requested_ref="${UPSTREAM_REF}"
    while (($#)); do
        case "$1" in
            --ref)
                [[ $# -ge 2 ]] || die "--ref requires a value."
                requested_ref=$2
                shift 2
                ;;
            --latest)
                requested_ref="latest"
                shift
                ;;
            --yes | -y)
                AUTO_YES="1"
                shift
                ;;
            *)
                die "Unknown upgrade option: $1"
                ;;
        esac
    done

    assert_service_owned_or_absent
    validate_source_checkout

    printf 'Current commit: %s\n' "$(git -C "${SOURCE_DIR}" rev-parse --short HEAD)"
    printf 'Target ref:     %s\n' "${requested_ref}"
    confirm "Stage, build and atomically activate this Colibri release?" yes ||
        die "Upgrade cancelled."

    local was_active="0"
    if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
        was_active="1"
    fi

    # Clone, fetch, build and validate without changing the live checkout or
    # process. The service is stopped only for the atomic directory exchange.
    prepare_staged_source "${requested_ref}" "1"
    build_colibri "${STAGED_SOURCE_DIR}"
    ensure_colibri_web_assets "${STAGED_SOURCE_DIR}"
    apply_ui_asset_mode "${STAGED_SOURCE_DIR}"
    UPSTREAM_REF="${STAGED_RESOLVED_REF}"
    stop_service_for_source_activation "${was_active}"
    activate_staged_source
    write_config
    install_service_unit
    write_manifest

    if [[ "${was_active}" == "1" ]]; then
        command_restart
    fi
    complete_source_activation
    info "Colibri upgraded to ${requested_ref}."
}

command_start() {
    require_non_root
    acquire_lock
    preflight_start
    sudo systemctl enable --now "${SERVICE_NAME}"
    info "Colibri start requested."
    printf 'Follow startup with: ./colibri.sh logs --follow\n'
    printf 'The first /health response appears only after the model has loaded.\n'
}

command_stop() {
    require_non_root
    acquire_lock
    load_config
    assert_service_owned_or_absent
    if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
        sudo systemctl stop "${SERVICE_NAME}"
        info "Colibri stopped. Models, cache, configuration and source were preserved."
    else
        info "Colibri is already stopped."
    fi
}

command_restart() {
    require_non_root
    acquire_lock
    preflight_start
    sudo systemctl restart "${SERVICE_NAME}"
    info "Colibri restart requested."
}

command_enable() {
    require_non_root
    acquire_lock
    load_config
    assert_service_owned_or_absent
    sudo systemctl enable "${SERVICE_NAME}"
    info "Colibri will start automatically at boot."
}

command_disable() {
    require_non_root
    acquire_lock
    load_config
    assert_service_owned_or_absent
    sudo systemctl disable --now "${SERVICE_NAME}"
    info "Colibri is stopped and disabled. Nothing was removed."
}

command_status() {
    require_non_root
    load_config

    printf 'Colibri Setup %s\n' "${PROGRAM_VERSION}"
    printf 'Source:          %s\n' "${SOURCE_DIR}"
    if [[ -d "${SOURCE_DIR}/.git" ]]; then
        printf 'Source commit:   %s\n' "$(git -C "${SOURCE_DIR}" rev-parse --short HEAD 2>/dev/null || printf unknown)"
    fi
    printf 'Model:           %s\n' "${MODEL_DIR}"
    printf 'Mirror:          %s\n' "${MIRROR_DIR:-disabled}"
    printf 'Profile:         %s (%s GiB RAM, %s context)\n' "${PROFILE}" "${RAM_GB}" "${CTX}"
    printf 'UI mode:         %s\n' "${UI_MODE}"
    printf 'API:             %s/v1\n' "$(configured_base_url)"
    printf 'GPU:             reserved (CPU-only engine)\n'
    local enabled_state
    local active_state
    enabled_state="$(sudo systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null)" ||
        enabled_state="unknown"
    active_state="$(sudo systemctl is-active "${SERVICE_NAME}" 2>/dev/null)" ||
        active_state="unknown"
    printf 'Enabled:         %s\n' "${enabled_state}"
    printf 'Active:          %s\n' "${active_state}"

    if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
        local pid
        pid="$(sudo systemctl show -p MainPID --value "${SERVICE_NAME}")"
        printf 'PID:             %s\n' "${pid}"
        local health_output
        health_output="$(mktemp)"
        if api_request GET "$(configured_base_url)/health" >"${health_output}" 2>/dev/null; then
            printf 'Health:          ready\n'
        else
            printf 'Health:          loading or unavailable\n'
        fi
        rm -f -- "${health_output}"
    fi

    if [[ -x "${DOWNLOAD_SCRIPT}" ]]; then
        printf '\nBackground model jobs:\n'
        "${DOWNLOAD_SCRIPT}" status --all --quiet || true
    fi
    if [[ -x "${MIRROR_SCRIPT}" ]]; then
        printf '\nBackground mirror jobs:\n'
        "${MIRROR_SCRIPT}" status --all || true
    fi
}

command_logs() {
    require_non_root
    local follow="0"
    local lines="100"
    local since=""

    while (($#)); do
        case "$1" in
            --follow | -f)
                follow="1"
                shift
                ;;
            --lines)
                [[ $# -ge 2 ]] || die "--lines requires a value."
                lines=$2
                shift 2
                ;;
            --since)
                [[ $# -ge 2 ]] || die "--since requires a value."
                since=$2
                shift 2
                ;;
            *)
                die "Unknown logs option: $1"
                ;;
        esac
    done

    local args=(-u "${SERVICE_NAME}" --no-pager -n "${lines}")
    [[ -z "${since}" ]] || args+=(--since "${since}")
    [[ "${follow}" == "0" ]] || args+=(-f)
    sudo journalctl "${args[@]}"
}

command_doctor() {
    require_non_root
    load_config
    local failures=0

    info "Local deployment checks"
    if [[ ! -x "${SOURCE_DIR}/c/coli" ]]; then
        error "Missing Colibri CLI: ${SOURCE_DIR}/c/coli"
        failures=$((failures + 1))
    fi
    if [[ ! -x "${SOURCE_DIR}/c/colibri" ]]; then
        error "Missing Colibri engine: ${SOURCE_DIR}/c/colibri"
        failures=$((failures + 1))
    elif ldd "${SOURCE_DIR}/c/colibri" 2>/dev/null | grep -q 'libcudart'; then
        error "Engine links CUDA; this deployment must remain CPU-only."
        failures=$((failures + 1))
    else
        printf 'CPU-only engine: OK\n'
    fi

    if model_is_ready; then
        validate_model
        printf 'Model layout:    OK\n'
    else
        error "Model download is absent or incomplete: ${MODEL_DIR}"
        failures=$((failures + 1))
    fi

    if [[ -n "${MIRROR_DIR}" ]]; then
        [[ -d "${MIRROR_DIR}" ]] || {
            error "Configured mirror is missing: ${MIRROR_DIR}"
            failures=$((failures + 1))
        }
    fi

    validate_port "${PORT}"
    validate_host "${BIND_HOST}"
    show_profile_values
    ((failures == 0)) || return 1

    info "Upstream Colibri doctor"
    (
        export COLI_MODEL="${MODEL_DIR}"
        export COLI_MODEL_MIRROR="${MIRROR_DIR}"
        export COLI_GPU=none
        export RAM_GB CTX PIPE_WORKERS DIRECT URING PILOT PILOT_REAL
        cd -- "${SOURCE_DIR}/c"
        ./coli doctor \
            --model "${MODEL_DIR}" \
            --ram "${RAM_GB}" \
            --ctx "${CTX}" \
            --gpu none \
            --policy quality
    )
}

command_plan() {
    require_non_root
    load_config
    validate_model
    info "Colibri CPU/RAM/NVMe plan"
    (
        export COLI_MODEL="${MODEL_DIR}"
        export COLI_MODEL_MIRROR="${MIRROR_DIR}"
        export COLI_GPU=none
        export RAM_GB CTX PIPE_WORKERS DIRECT URING PILOT PILOT_REAL
        cd -- "${SOURCE_DIR}/c"
        ./coli plan \
            --model "${MODEL_DIR}" \
            --ram "${RAM_GB}" \
            --ctx "${CTX}" \
            --gpu none \
            --policy quality
    )
}

command_test() {
    require_non_root
    load_config
    local run_chat="0"
    while (($#)); do
        case "$1" in
            --chat)
                run_chat="1"
                shift
                ;;
            *)
                die "Unknown test option: $1"
                ;;
        esac
    done

    local base_url
    base_url="$(configured_base_url)"
    info "Health"
    api_request GET "${base_url}/health"
    info "Models"
    api_request GET "${base_url}/v1/models"

    if [[ "${run_chat}" == "1" ]]; then
        info "Tiny deterministic chat completion"
        api_request POST "${base_url}/v1/chat/completions" \
            "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Return exactly: Colibri is ready.\"}],\"max_tokens\":32,\"temperature\":0,\"stream\":false}"
    fi
}

command_profile() {
    require_non_root
    local action=${1:-list}
    shift || true

    case "${action}" in
        list)
            printf '%s\n' conservative balanced performance experimental custom
            ;;
        show)
            local requested=${1:-}
            if [[ -z "${requested}" ]]; then
                load_config
                show_profile_values
            else
                PROFILE="${requested}"
                resolve_profile "${PROFILE}"
                show_profile_values
            fi
            ;;
        set)
            local requested=${1:-}
            [[ -n "${requested}" ]] || die "Usage: ./colibri.sh profile set NAME [--no-restart]"
            shift
            local no_restart="0"
            while (($#)); do
                case "$1" in
                    --no-restart)
                        no_restart="1"
                        shift
                        ;;
                    --ram)
                        [[ $# -ge 2 ]] || die "--ram requires a value."
                        CUSTOM_RAM=$2
                        shift 2
                        ;;
                    --ctx)
                        [[ $# -ge 2 ]] || die "--ctx requires a value."
                        CUSTOM_CTX=$2
                        shift 2
                        ;;
                    --workers)
                        [[ $# -ge 2 ]] || die "--workers requires a value."
                        CUSTOM_WORKERS=$2
                        shift 2
                        ;;
                    *)
                        die "Unknown profile option: $1"
                        ;;
                esac
            done
            acquire_lock
            load_config
            assert_service_owned_or_absent
            PROFILE="${requested}"
            resolve_profile "${PROFILE}"
            show_profile_values
            confirm "Apply profile '${PROFILE}'?" yes || die "Profile change cancelled."
            write_config
            install_service_unit
            if [[ "${no_restart}" == "0" ]] && sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                command_plan
                sudo systemctl restart "${SERVICE_NAME}"
            fi
            ;;
        *)
            die "Usage: ./colibri.sh profile list|show|set"
            ;;
    esac
}

command_model() {
    require_non_root
    local action=${1:-}
    shift || true

    case "${action}" in
        download)
            load_config
            ensure_hf_cli
            ensure_hf_token
            [[ -x "${DOWNLOAD_SCRIPT}" ]] || die "Download helper is missing: ${DOWNLOAD_SCRIPT}"
            local repo="${1:-${MODEL_REPO}}"
            local destination="${2:-${MODEL_DIR}}"
            if (($# >= 1)); then shift; fi
            if (($# >= 1)); then shift; fi
            HF_BIN="${HF_VENV_DIR}/bin/hf" \
                "${DOWNLOAD_SCRIPT}" start "${repo}" "${destination}" "$@"
            ;;
        verify)
            load_config
            ensure_hf_cli
            ensure_hf_token
            (($# <= 2)) ||
                die "Usage: ./colibri.sh model verify [MODEL_REPOSITORY] [MODEL_DIRECTORY]"
            local repo="${1:-${MODEL_REPO}}"
            local destination="${2:-${MODEL_DIR}}"
            validate_model_repository "${repo}"
            destination="$(resolve_existing_model_directory "${destination}")"

            info "Verifying model files against Hugging Face checksums"
            printf 'Repository: %s\n' "${repo}"
            printf 'Directory:  %s\n' "${destination}"
            local verification_output
            verification_output="$(mktemp)"
            if ! run_model_integrity \
                "${repo}" \
                "${destination}" \
                "${verification_output}"; then
                rm -f -- "${verification_output}"
                die "Model verification failed. Review the missing-file or checksum details above."
            fi
            rm -f -- "${verification_output}"
            info "Model verification passed: all repository model files are present and match."
            ;;
        repair)
            command_model_repair "$@"
            ;;
        status)
            [[ -x "${DOWNLOAD_SCRIPT}" ]] || die "Download helper is missing."
            "${DOWNLOAD_SCRIPT}" status "$@"
            ;;
        attach)
            [[ -x "${DOWNLOAD_SCRIPT}" ]] || die "Download helper is missing."
            "${DOWNLOAD_SCRIPT}" attach "$@"
            ;;
        resume)
            ensure_hf_cli
            ensure_hf_token
            [[ -x "${DOWNLOAD_SCRIPT}" ]] || die "Download helper is missing."
            "${DOWNLOAD_SCRIPT}" resume "$@"
            ;;
        cancel)
            [[ -x "${DOWNLOAD_SCRIPT}" ]] || die "Download helper is missing."
            "${DOWNLOAD_SCRIPT}" cancel "$@"
            ;;
        mirror)
            load_config
            [[ -x "${MIRROR_SCRIPT}" ]] || die "Mirror helper is missing: ${MIRROR_SCRIPT}"
            local destination=${1:-}
            [[ -n "${destination}" ]] || die "Usage: ./colibri.sh model mirror MIRROR_DIRECTORY"
            shift
            "${MIRROR_SCRIPT}" start "${MODEL_DIR}" "${destination}" "$@"
            ;;
        mirror-status)
            "${MIRROR_SCRIPT}" status "$@"
            ;;
        mirror-attach)
            "${MIRROR_SCRIPT}" attach "$@"
            ;;
        enable-mirror)
            acquire_lock
            load_config
            assert_service_owned_or_absent
            local destination=${1:-}
            [[ -n "${destination}" ]] || die "Usage: ./colibri.sh model enable-mirror DIRECTORY [--full-verify]"
            shift
            validate_safe_path "${destination}" "Mirror directory"
            "${MIRROR_SCRIPT}" verify "${MODEL_DIR}" "${destination}" "$@"
            MIRROR_DIR="${destination}"
            write_config
            install_service_unit
            if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                sudo systemctl restart "${SERVICE_NAME}"
            fi
            info "Mirror enabled. Colibri will probe both drives at startup."
            ;;
        disable-mirror)
            acquire_lock
            load_config
            assert_service_owned_or_absent
            local previous="${MIRROR_DIR}"
            MIRROR_DIR=""
            write_config
            install_service_unit
            if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                sudo systemctl restart "${SERVICE_NAME}"
            fi
            info "Mirror disabled in Colibri. No mirror files were deleted."
            [[ -z "${previous}" ]] || printf 'Preserved mirror: %s\n' "${previous}"
            ;;
        *)
            die "Usage: ./colibri.sh model download|verify|repair|status|attach|resume|cancel|mirror|mirror-status|mirror-attach|enable-mirror|disable-mirror"
            ;;
    esac
}

docker_container_candidates() {
    docker ps --format '{{.Names}} {{.Image}}' |
        awk 'tolower($0) ~ /open[-_]?webui/ {print $1}'
}

detect_open_webui_container() {
    local requested=${1:-}
    if [[ -n "${requested}" ]]; then
        docker inspect "${requested}" >/dev/null 2>&1 ||
            die "Open WebUI container was not found: ${requested}"
        [[ "$(docker inspect --format '{{.State.Running}}' "${requested}")" == "true" ]] ||
            die "Open WebUI container is not running: ${requested}"
        printf '%s\n' "${requested}"
        return
    fi

    mapfile -t containers < <(docker_container_candidates)
    ((${#containers[@]} == 1)) ||
        die "Could not uniquely detect Open WebUI. Pass --container NAME."
    printf '%s\n' "${containers[0]}"
}

docker_gateway_for_container() {
    local container=$1
    local requested_network=${2:-}
    local network_mode
    network_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "${container}")"
    if [[ "${network_mode}" == "host" ]]; then
        printf '127.0.0.1\n'
        return
    fi

    mapfile -t network_rows < <(
        docker inspect --format \
            '{{range $name, $network := .NetworkSettings.Networks}}{{$name}} {{$network.Gateway}}{{"\n"}}{{end}}' \
            "${container}" |
            awk 'NF == 2'
    )

    if [[ -n "${requested_network}" ]]; then
        local row
        for row in "${network_rows[@]}"; do
            if [[ "${row%% *}" == "${requested_network}" ]]; then
                printf '%s\n' "${row#* }"
                return
            fi
        done
        die "Container ${container} is not attached to Docker network ${requested_network}."
    fi

    if ((${#network_rows[@]} != 1)); then
        error "Open WebUI is attached to multiple Docker networks:"
        printf '  %s\n' "${network_rows[@]}" >&2
        die "Select one explicitly with --network NAME."
    fi
    printf '%s\n' "${network_rows[0]#* }"
}

host_has_address() {
    local address=$1
    ip -4 -o addr show |
        awk '{sub(/\/.*/, "", $4); print $4}' |
        grep -Fqx -- "${address}"
}

warn_open_webui_timeout() {
    local container=$1
    local timeout
    timeout="$(
        docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${container}" |
            awk -F= '$1 == "AIOHTTP_CLIENT_TIMEOUT" {print $2; exit}'
    )"
    if [[ -z "${timeout}" || ! "${timeout}" =~ ^[0-9]+$ || "${timeout}" -le 300 ]]; then
        warn "Open WebUI's provider timeout is ${timeout:-the 300-second default}. CPU/NVMe Colibri requests may exceed it."
        warn "Set AIOHTTP_CLIENT_TIMEOUT=1800 in Open WebUI's own deployment, then recreate that container deliberately."
    fi
}

open_webui_container_check() {
    local container=$1
    local base_url=$2
    local payload
    payload="$(printf '%s\n%s\n%s\n' "${base_url}" "${COLI_API_KEY}" "${MODEL_ID}")"
    printf '%s' "${payload}" |
        docker exec -i "${container}" sh -c '
set -eu
IFS= read -r base_url
IFS= read -r api_key
IFS= read -r model_id
base_url=${base_url%/}

if command -v curl >/dev/null 2>&1; then
    health=$(
        curl --silent --show-error --fail --noproxy "*" \
            --header "Authorization: Bearer ${api_key}" \
            "${base_url}/health"
    )
    models=$(
        curl --silent --show-error --fail --noproxy "*" \
            --header "Authorization: Bearer ${api_key}" \
            "${base_url}/v1/models"
    )
elif command -v wget >/dev/null 2>&1; then
    health=$(
        wget -qO- --no-proxy \
            --header="Authorization: Bearer ${api_key}" \
            "${base_url}/health"
    )
    models=$(
        wget -qO- --no-proxy \
            --header="Authorization: Bearer ${api_key}" \
            "${base_url}/v1/models"
    )
else
    printf "Open WebUI container has neither curl nor wget.\n" >&2
    exit 1
fi

compact_health=$(printf "%s" "${health}" | tr -d "[:space:]")
compact_models=$(printf "%s" "${models}" | tr -d "[:space:]")
case "${compact_health}" in
    *"\"status\":\"ok\""* | *"\"status\":\"ready\""*) ;;
    *)
        printf "Colibri health is not ready: %s\n" "${health}" >&2
        exit 1
        ;;
esac
case "${compact_models}" in
    *"\"id\":\"${model_id}\""*) ;;
    *)
        printf "Expected model %s; received: %s\n" "${model_id}" "${models}" >&2
        exit 1
        ;;
esac
printf "Container connectivity passed: health=ready model=%s\n" "${model_id}"
'
}

command_open_webui() {
    require_non_root
    local action=${1:-setup}
    shift || true
    load_config

    case "${action}" in
        setup)
            acquire_lock
            local mode="docker"
            local container=""
            local network=""
            while (($#)); do
                case "$1" in
                    --container)
                        [[ $# -ge 2 ]] || die "--container requires a value."
                        container=$2
                        shift 2
                        ;;
                    --network)
                        [[ $# -ge 2 ]] || die "--network requires a value."
                        network=$2
                        shift 2
                        ;;
                    --local)
                        mode="local"
                        shift
                        ;;
                    --yes | -y)
                        AUTO_YES="1"
                        shift
                        ;;
                    *)
                        die "Unknown Open WebUI setup option: $1"
                        ;;
                esac
            done

            UI_MODE="open-webui"
            if [[ "${mode}" == "docker" ]]; then
                require_command docker
                container="$(detect_open_webui_container "${container}")"
                BIND_HOST="$(docker_gateway_for_container "${container}" "${network}")"
                [[ -n "${BIND_HOST}" ]] || die "Could not determine the Docker gateway for ${container}."
                if [[ "${BIND_HOST}" != "127.0.0.1" ]] && ! host_has_address "${BIND_HOST}"; then
                    die "Docker gateway ${BIND_HOST} is not assigned to a host interface. Rootless/remote Docker needs an explicit proxy."
                fi
                printf 'Open WebUI container: %s\n' "${container}"
                printf 'Docker host gateway: %s\n' "${BIND_HOST}"
                warn_open_webui_timeout "${container}"
            else
                BIND_HOST="127.0.0.1"
            fi

            assert_service_owned_or_absent
            printf 'Colibri API: %s/v1\n' "$(configured_base_url)"
            confirm "Switch Colibri to API-only Open WebUI mode?" yes ||
                die "Open WebUI setup cancelled."
            local was_active="0"
            if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                was_active="1"
            fi
            apply_ui_asset_mode
            write_config
            install_service_unit
            if model_is_ready; then
                preflight_start
                if [[ "${was_active}" == "1" ]]; then
                    sudo systemctl restart "${SERVICE_NAME}"
                else
                    sudo systemctl enable --now "${SERVICE_NAME}"
                fi
            fi

            info "Open WebUI connection values"
            printf 'Admin path:  Admin Panel -> Settings -> Connections -> OpenAI -> Add\n'
            printf 'URL:         %s/v1\n' "$(configured_base_url)"
            printf 'API key:     ./colibri.sh api-key show\n'
            printf 'Model:       %s\n' "${MODEL_ID}"
            printf 'UI behavior: Colibri runs `coli serve`; its own dashboard is OFF.\n'
            if [[ "${mode}" == "docker" ]] && sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                if api_request GET "$(configured_base_url)/health" >/dev/null 2>&1; then
                    info "Testing model discovery from inside ${container}"
                    open_webui_container_check "${container}" "$(configured_base_url)"
                else
                    warn "Colibri is still loading. Verify the connection when /health becomes ready:"
                    printf '  ./colibri.sh open-webui check --container %q\n' "${container}"
                fi
            fi
            ;;
        check)
            local container=""
            local local_check="0"
            while (($#)); do
                case "$1" in
                    --container)
                        [[ $# -ge 2 ]] || die "--container requires a value."
                        container=$2
                        shift 2
                        ;;
                    --local)
                        local_check="1"
                        shift
                        ;;
                    *)
                        die "Unknown Open WebUI check option: $1"
                        ;;
                esac
            done
            if [[ "${local_check}" == "1" ]]; then
                api_request GET "$(configured_base_url)/health"
                api_request GET "$(configured_base_url)/v1/models"
                return
            fi
            require_command docker
            container="$(detect_open_webui_container "${container}")"
            open_webui_container_check "${container}" "$(configured_base_url)"
            ;;
        values)
            local show_key="0"
            while (($#)); do
                case "$1" in
                    --show-key)
                        show_key="1"
                        shift
                        ;;
                    *)
                        die "Unknown Open WebUI values option: $1"
                        ;;
                esac
            done
            printf 'URL:       %s/v1\n' "$(configured_base_url)"
            if [[ "${show_key}" == "1" ]]; then
                printf 'API key:   %s\n' "${COLI_API_KEY}"
            else
                printf 'API key:   ./colibri.sh open-webui values --show-key\n'
            fi
            printf 'Model:     %s\n' "${MODEL_ID}"
            printf 'Admin:     Admin Panel -> Settings -> Connections -> OpenAI -> Add\n'
            ;;
        *)
            die "Usage: ./colibri.sh open-webui setup|check|values"
            ;;
    esac
}

command_ui() {
    require_non_root
    local action=${1:-show}
    shift || true
    case "${action}" in
        show)
            load_config
            printf 'UI mode: %s\n' "${UI_MODE}"
            case "${UI_MODE}" in
                open-webui)
                    printf 'Colibri dashboard: disabled (`coli serve`)\n'
                    printf 'Frontend:          Open WebUI\n'
                    ;;
                colibri-web)
                    printf 'Colibri dashboard: enabled (`coli web --no-browser`)\n'
                    ;;
                api-only)
                    printf 'Colibri dashboard: disabled (`coli serve`)\n'
                    printf 'Frontend:          none configured\n'
                    ;;
            esac
            ;;
        set)
            local requested=${1:-}
            [[ -n "${requested}" ]] || die "Usage: ./colibri.sh ui set api-only|open-webui|colibri-web"
            validate_ui_mode "${requested}"
            if [[ "${requested}" == "open-webui" ]]; then
                command_open_webui setup "${@:2}"
                return
            fi
            acquire_lock
            load_config
            assert_service_owned_or_absent
            UI_MODE="${requested}"
            ensure_colibri_web_assets
            apply_ui_asset_mode
            write_config
            install_service_unit
            if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                sudo systemctl restart "${SERVICE_NAME}"
            fi
            command_ui show
            ;;
        *)
            die "Usage: ./colibri.sh ui show|set"
            ;;
    esac
}

command_hf_token() {
    require_non_root
    local action=${1:-status}

    case "${action}" in
        set)
            local token=""
            printf 'Create a read-only token at:\n'
            printf '  https://huggingface.co/settings/tokens\n'
            printf 'It will be stored as HF_TOKEN in:\n'
            printf '  %s\n' "${HF_ENV_FILE}"
            IFS= read -r -s -p 'HF_TOKEN: ' token
            printf '\n'
            [[ -n "${token}" ]] || die "HF_TOKEN was empty."
            write_hf_token "${token}"
            token=""
            unset token
            info "HF_TOKEN saved in the private user .env file."
            printf 'It will be exported only to Hugging Face subprocesses.\n'
            ;;
        status)
            local source_description="current process environment"
            if [[ -z "${HF_TOKEN:-}" ]]; then
                source_description="${HF_ENV_FILE}"
            fi
            if ! load_hf_token; then
                warn "HF_TOKEN is not configured. Managed Hugging Face operations will not run."
                printf 'Configure it with: ./colibri.sh hf-token set\n' >&2
                return 1
            fi
            printf 'HF_TOKEN is configured from %s.\n' "${source_description}"
            ;;
        remove)
            [[ -e "${HF_ENV_FILE}" ]] || {
                info "HF_TOKEN .env file is already absent."
                return 0
            }
            validate_hf_env_file
            confirm "Remove the private HF_TOKEN .env file?" no ||
                die "HF_TOKEN removal cancelled."
            rm -f -- "${HF_ENV_FILE}"
            info "HF_TOKEN .env file removed."
            ;;
        *)
            die "Usage: ./colibri.sh hf-token set|status|remove"
            ;;
    esac
}

command_api_key() {
    require_non_root
    local action=${1:-show}
    case "${action}" in
        show)
            load_config
            printf '%s\n' "${COLI_API_KEY}"
            ;;
        rotate)
            acquire_lock
            load_config
            assert_service_owned_or_absent
            ROTATE_API_KEY="1"
            write_config
            if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                sudo systemctl restart "${SERVICE_NAME}"
            fi
            info "API key rotated. Update connected clients with: ./colibri.sh api-key show"
            ;;
        *)
            die "Usage: ./colibri.sh api-key show|rotate"
            ;;
    esac
}

command_cli() {
    require_non_root
    acquire_lock
    load_config
    assert_service_owned_or_absent
    validate_source_checkout
    validate_model
    (($# > 0)) || die "Usage: ./colibri.sh cli [Colibri arguments ...]"

    if [[ "$1" == "chat" ]] && sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
        shift
        (
            export COLI_MODEL="${MODEL_DIR}"
            export COLI_API_KEY
            cd -- "${SOURCE_DIR}/c"
            ./coli chat --attach "$(configured_base_url)" "$@"
        )
        return
    fi

    local restart_after="0"
    case "$1" in
        info | plan | doctor | stop)
            ;;
        *)
            if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
                warn "This upstream command may load a second model process and compete for RAM/NVMe."
                confirm "Stop the managed service before running it?" yes ||
                    die "CLI command cancelled."
                sudo systemctl stop "${SERVICE_NAME}"
                restart_after="1"
            fi
            ;;
    esac

    local cli_status
    if (
        export COLI_MODEL="${MODEL_DIR}"
        export COLI_MODEL_MIRROR="${MIRROR_DIR}"
        export COLI_GPU=none
        export COLI_API_KEY
        export RAM_GB CTX PIPE_WORKERS DIRECT URING PILOT PILOT_REAL
        cd -- "${SOURCE_DIR}/c"
        ./coli "$@"
    ); then
        cli_status="0"
    else
        cli_status=$?
    fi
    if [[ "${restart_after}" == "1" ]]; then
        sudo systemctl start "${SERVICE_NAME}" ||
            warn "The upstream command finished, but the managed service could not be restarted."
    fi
    return "${cli_status}"
}

command_uninstall() {
    require_non_root
    acquire_lock
    if [[ ! -r "${INSTALL_MANIFEST}" ]]; then
        if managed_installation_artifacts_exist; then
            die "Managed-looking installation artifacts exist without an install manifest; refusing an unproven removal."
        fi
        info "Colibri integration is already uninstalled; no managed installation artifacts remain."
        printf 'Model files were not changed.\n'
        return 0
    fi
    load_config
    local remove_source="0"
    local purge_config="0"

    while (($#)); do
        case "$1" in
            --remove-source)
                remove_source="1"
                shift
                ;;
            --purge-config)
                purge_config="1"
                shift
                ;;
            --yes | -y)
                AUTO_YES="1"
                shift
                ;;
            *)
                die "Unknown uninstall option: $1"
                ;;
        esac
    done

    printf 'Service/unit:    remove\n'
    printf 'Configuration:   %s\n' "$([[ "${purge_config}" == "1" ]] && printf remove || printf preserve)"
    printf 'Source:          %s\n' "$([[ "${remove_source}" == "1" ]] && printf 'remove if tool-created' || printf preserve)"
    printf 'Primary model:   PRESERVE (%s)\n' "${MODEL_DIR}"
    printf 'Mirror model:    PRESERVE (%s)\n' "${MIRROR_DIR:-not configured}"
    printf 'Learned/KV data: PRESERVE with model\n'
    confirm "Proceed with non-destructive uninstall?" no || die "Uninstall cancelled."

    if [[ -e "${SERVICE_FILE}" ]]; then
        assert_service_owned_or_absent
        sudo systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        sudo rm -f -- "${SERVICE_FILE}"
    fi
    sudo systemctl daemon-reload

    if [[ "${remove_source}" == "1" ]]; then
        local manifest_created="0"
        local manifest_source=""
        local configured_source="${SOURCE_DIR}"
        if [[ -r "${INSTALL_MANIFEST}" ]]; then
            manifest_created="$(
                awk -F= '$1 == "SOURCE_CREATED" {print substr($0, index($0, "=") + 1); exit}' \
                    "${INSTALL_MANIFEST}"
            )"
            manifest_source="$(
                awk -F= '$1 == "SOURCE_DIR" {print substr($0, index($0, "=") + 1); exit}' \
                    "${INSTALL_MANIFEST}"
            )"
        fi
        SOURCE_DIR="${configured_source}"
        if [[ "${manifest_created}" == "1" && "${manifest_source}" == "${configured_source}" ]]; then
            validate_managed_path_separation
            validate_safe_path "${configured_source}" "Source directory"
            [[ -d "${configured_source}/.git" ]] ||
                die "Refusing to remove a non-Git source directory: ${configured_source}"
            validate_source_checkout
            rm -rf --one-file-system -- "${configured_source}"
            printf 'Removed tool-created source: %s\n' "${configured_source}"
        else
            warn "Source was not proven tool-created; preserving ${SOURCE_DIR}."
        fi
    fi

    if [[ "${purge_config}" == "1" ]]; then
        sudo rm -f -- "${CONFIG_FILE}"
        sudo rmdir --ignore-fail-on-non-empty "${SYSTEM_CONFIG_DIR}" 2>/dev/null || true
    fi
    sudo rm -f -- "${INSTALL_MANIFEST}"
    sudo rmdir --ignore-fail-on-non-empty "${SYSTEM_STATE_DIR}" 2>/dev/null || true
    sudo rm -f -- "${INSTALLED_WAIT_SCRIPT}"
    sudo rmdir --ignore-fail-on-non-empty "${SYSTEM_LIBEXEC_DIR}" 2>/dev/null || true

    info "Colibri integration uninstalled."
    printf 'Preserved primary model: %s\n' "${MODEL_DIR}"
    [[ -z "${MIRROR_DIR}" ]] || printf 'Preserved mirror model:  %s\n' "${MIRROR_DIR}"
}

main() {
    local command=${1:-help}
    shift || true

    case "${command}" in
        install) command_install "$@" ;;
        configure | config) command_configure "$@" ;;
        upgrade) command_upgrade "$@" ;;
        start) command_start "$@" ;;
        stop | shutdown) command_stop "$@" ;;
        restart) command_restart "$@" ;;
        enable) command_enable "$@" ;;
        disable) command_disable "$@" ;;
        status) command_status "$@" ;;
        logs) command_logs "$@" ;;
        doctor) command_doctor "$@" ;;
        plan) command_plan "$@" ;;
        test) command_test "$@" ;;
        profile) command_profile "$@" ;;
        model) command_model "$@" ;;
        ui) command_ui "$@" ;;
        open-webui | openwebui) command_open_webui "$@" ;;
        hf-token) command_hf_token "$@" ;;
        api-key) command_api_key "$@" ;;
        cli | coli) command_cli "$@" ;;
        uninstall) command_uninstall "$@" ;;
        version | --version | -V) printf '%s %s\n' "${PROGRAM_NAME}" "${PROGRAM_VERSION}" ;;
        help | --help | -h) usage ;;
        *) die "Unknown command: ${command}. Run ./colibri.sh help." ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
