#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export XDG_DATA_HOME="${TEST_ROOT}/data"
export XDG_STATE_HOME="${TEST_ROOT}/state"
export XDG_CONFIG_HOME="${TEST_ROOT}/config"
mkdir -p -- "${HOME}" "${XDG_DATA_HOME}/colibri-setup/hf-venv/bin"

MODEL_DIR_FIXTURE="${TEST_ROOT}/model"
HF_ARGS_FILE="${TEST_ROOT}/hf.args"
readonly MODEL_DIR_FIXTURE HF_ARGS_FILE
mkdir -p -- "${MODEL_DIR_FIXTURE}"
printf 'original broken shard\n' >"${MODEL_DIR_FIXTURE}/out-mtp-00000.safetensors"

cat >"${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "cache" && "${2:-}" == "verify" ]]; then
    destination=""
    while (($#)); do
        case "$1" in
            --local-dir)
                destination=$2
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "${HF_VERIFY_RESULT:-failure}" == "success" ]] ||
        grep -Fxq 'repaired shard' "${destination}/out-mtp-00000.safetensors" 2>/dev/null; then
        printf 'Verified model files. All checksums match.\n'
        exit 0
    fi

    printf 'Checksum verification failed for the following file(s):\n'
    printf '  - out-mtp-00000.safetensors: expected expected-sha256 (sha256), got actual-sha256\n'
    printf 'Missing files (present remotely, absent locally):\n'
    printf '  - .coli_usage\n'
    printf 'Error: Verification failed.\n'
    exit 1
fi

[[ "${1:-}" == "download" ]] || {
    printf 'Unexpected fake hf command: %s\n' "$*" >&2
    exit 1
}

printf '%s\n' "$@" >"${HF_ARGS_FILE:?}"
[[ "${HF_TOKEN:-}" == "${HF_EXPECT_TOKEN:-}" ]] || {
    printf 'HF_TOKEN was not supplied to the repair download\n' >&2
    exit 1
}

destination=""
while (($#)); do
    case "$1" in
        --local-dir)
            destination=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "${destination}" ]] || exit 1
printf 'repaired shard\n' >"${destination}/out-mtp-00000.safetensors"
EOF
chmod +x "${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf"
export HF_ARGS_FILE

# shellcheck source=../colibri.sh
source "${REPOSITORY_ROOT}/colibri.sh"

require_non_root() {
    :
}

load_config() {
    # The sourced command_model function consumes these cross-file globals.
    # shellcheck disable=SC2034
    MODEL_REPO="mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp"
    # shellcheck disable=SC2034
    MODEL_DIR="${MODEL_DIR_FIXTURE}"
}

ensure_hf_cli() {
    :
}

export HF_EXPECT_TOKEN='hf_testrepairtoken'
mkdir -p -- "${XDG_CONFIG_HOME}/colibri-setup"
printf 'HF_TOKEN=%s\n' "${HF_EXPECT_TOKEN}" \
    >"${XDG_CONFIG_HOME}/colibri-setup/.env"
chmod 600 "${XDG_CONFIG_HOME}/colibri-setup/.env"

export HF_VERIFY_RESULT=success
output="$(command_model verify)"
grep -Fq 'Model verification passed' <<<"${output}" || {
    printf 'model verify: success message was not printed\n' >&2
    exit 1
}

export HF_VERIFY_RESULT=failure
if (command_model verify >/dev/null 2>&1); then
    printf 'model verify: checksum failure was not propagated\n' >&2
    exit 1
fi

output="$(command_model repair --yes 2>&1)"
grep -Fq 'Exactly these 1 missing or corrupt model file(s)' <<<"${output}" || {
    printf 'model repair: exact repair plan was not printed\n' >&2
    exit 1
}
grep -Fq 'Model repair passed' <<<"${output}" || {
    printf 'model repair: success message was not printed\n' >&2
    exit 1
}
grep -Fxq 'repaired shard' "${MODEL_DIR_FIXTURE}/out-mtp-00000.safetensors" || {
    printf 'model repair: repaired file was not activated\n' >&2
    exit 1
}

grep -Fxq -- '--force-download' "${HF_ARGS_FILE}" && {
    printf 'model repair: unsafe --force-download was used\n' >&2
    exit 1
}
grep -Fxq 'out-mtp-00000.safetensors' "${HF_ARGS_FILE}" || {
    printf 'model repair: corrupt shard was not requested\n' >&2
    exit 1
}
grep -Fxq '.coli_usage' "${HF_ARGS_FILE}" && {
    printf 'model repair: mutable runtime state was incorrectly requested\n' >&2
    exit 1
}

printf 'checksum verification and isolated repair: passed\n'
