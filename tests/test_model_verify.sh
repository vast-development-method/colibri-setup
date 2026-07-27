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

cat >"${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "cache" && "${2:-}" == "verify" ]]; then
    sleep "${HF_VERIFY_DELAY:-0}"
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

    if [[ "${HF_VERIFY_RESULT:-success}" == "success" ||
        ("${HF_VERIFY_RESULT:-success}" == "repairable" &&
            -e "${destination}/.repair-complete") ]]; then
        printf 'Warning: 1 local file(s) do not exist on the remote repository.\n'
        printf 'Verified 2 file(s). All checksums match.\n'
        exit 0
    fi

    printf 'Checksum verification failed for the following file(s):\n'
    if [[ "${HF_VERIFY_RESULT:-}" == "mutable" ]]; then
        printf '  - .coli_usage: expected seed-sha1 (git-sha1), got learned-sha1\n'
        printf 'Error: Verification failed.\n'
        exit 1
    fi
    printf '  - out-mtp-00000.safetensors: expected expected-sha256 (sha256), got actual-sha256\n'
    if [[ "${HF_VERIFY_RESULT:-}" == "repairable" ]]; then
        printf 'Missing files (present remotely, absent locally):\n'
        printf '  - .coli_usage\n'
    fi
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

[[ -n "${destination}" ]] || {
    printf 'repair download did not receive --local-dir\n' >&2
    exit 1
}
printf 'repaired shard\n' >"${destination}/out-mtp-00000.safetensors"
printf 'seed usage\n' >"${destination}/.coli_usage"
touch "${destination}/.repair-complete"
printf 'Selective repair completed.\n'
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
    MODEL_REPO="example/model"
    # shellcheck disable=SC2034
    MODEL_DIR="${MODEL_DIR_FIXTURE}"
}

ensure_hf_cli() {
    :
}

export HF_EXPECT_TOKEN='hf_testrepairtoken'
token_output="$(printf '%s\n' "${HF_EXPECT_TOKEN}" | command_hf_token set 2>&1)"
[[ -f "${XDG_CONFIG_HOME}/colibri-setup/.env" ]] || {
    printf 'hf-token: .env file was not created\n' >&2
    exit 1
}
[[ "$(stat -c '%a' "${XDG_CONFIG_HOME}/colibri-setup/.env")" == "600" ]] || {
    printf 'hf-token: .env file mode is not 0600\n' >&2
    exit 1
}
grep -Fxq "HF_TOKEN=${HF_EXPECT_TOKEN}" \
    "${XDG_CONFIG_HOME}/colibri-setup/.env" || {
    printf 'hf-token: .env file does not contain HF_TOKEN\n' >&2
    exit 1
}
grep -Fq "${HF_EXPECT_TOKEN}" <<<"${token_output}" && {
    printf 'hf-token: token leaked into command output\n' >&2
    exit 1
}

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

export HF_VERIFY_RESULT=mutable
output="$(command_model verify 2>&1)"
grep -Fq 'expected .coli_usage checksum difference' <<<"${output}" || {
    printf 'model verify: mutable .coli_usage was not handled safely\n' >&2
    exit 1
}

export HF_VERIFY_RESULT=success
export HF_VERIFY_DELAY=2
export COLIBRI_FORCE_HEARTBEAT=1
export COLIBRI_HEARTBEAT_INTERVAL_SECONDS=1
output="$(command_model verify 2>&1)"
grep -Fq 'is still running' <<<"${output}" || {
    printf 'model verify: elapsed-time heartbeat was not printed\n' >&2
    exit 1
}
unset HF_VERIFY_DELAY COLIBRI_FORCE_HEARTBEAT COLIBRI_HEARTBEAT_INTERVAL_SECONDS

export HF_VERIFY_RESULT=repairable
if output="$(command_model repair --yes 2>&1)"; then
    :
else
    printf 'model repair command failed:\n%s\n' "${output}" >&2
    exit 1
fi
grep -Fq 'Only these 2 remote file(s) will be downloaded' <<<"${output}" || {
    printf 'model repair: selective plan was not printed\n' >&2
    exit 1
}
grep -Fq 'Model repair passed' <<<"${output}" || {
    printf 'model repair: success message was not printed\n' >&2
    exit 1
}

mapfile -t hf_args <"${HF_ARGS_FILE}"
expected_args=(
    download
    example/model
    .coli_usage
    out-mtp-00000.safetensors
    --repo-type
    model
    --local-dir
    "${MODEL_DIR_FIXTURE}"
    --force-download
)
[[ "${hf_args[*]}" == "${expected_args[*]}" ]] || {
    printf 'model repair: unexpected Hugging Face arguments\n' >&2
    printf 'expected: %q\n' "${expected_args[*]}" >&2
    printf 'actual:   %q\n' "${hf_args[*]}" >&2
    exit 1
}

printf 'model verify and selective repair: passed\n'
