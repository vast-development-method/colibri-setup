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
REPAIRED_CONTENT='repaired shard'
REPAIRED_SHA256="$(
    printf '%s\n' "${REPAIRED_CONTENT}" | sha256sum | awk '{print $1}'
)"
readonly MODEL_DIR_FIXTURE HF_ARGS_FILE REPAIRED_CONTENT REPAIRED_SHA256
mkdir -p -- "${MODEL_DIR_FIXTURE}"
printf 'original broken shard\n' >"${MODEL_DIR_FIXTURE}/out-mtp-00000.safetensors"
printf '{}\n' >"${MODEL_DIR_FIXTURE}/config.json"
printf '{}\n' >"${MODEL_DIR_FIXTURE}/tokenizer.json"

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

    if [[ "${HF_VERIFY_RESULT:-failure}" == "success" ]]; then
        printf 'Verified model files. All checksums match.\n'
        exit 0
    fi

    actual_sha256="$(
        sha256sum -- "${destination}/out-mtp-00000.safetensors" |
            awk '{print $1}'
    )"
    if [[ "${actual_sha256}" == "${HF_EXPECT_REPAIRED_SHA256:?}" ]]; then
        printf 'Verified model files. All checksums match.\n'
        exit 0
    fi

    printf 'Checksum verification failed for the following file(s):\n'
    printf '  - out-mtp-00000.safetensors: expected %s (sha256), got %s\n' \
        "${HF_EXPECT_REPAIRED_SHA256:?}" "${actual_sha256}"
    printf '  - README.md: expected malformed-value (sha256), got malformed-value\n'
    printf 'Missing files (present remotely, absent locally):\n'
    printf '  - .coli_usage\n'
    printf '  - MODEL_CARD.md\n'
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
if [[ "${HF_DOWNLOAD_WRONG_HASH:-0}" == "1" ]]; then
    printf 'wrong downloaded bytes\n' \
        >"${destination}/out-mtp-00000.safetensors"
else
    printf '%s\n' "${HF_REPAIRED_CONTENT:?}" \
        >"${destination}/out-mtp-00000.safetensors"
fi
EOF
chmod +x "${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf"
export HF_ARGS_FILE
export HF_REPAIRED_CONTENT="${REPAIRED_CONTENT}"
export HF_EXPECT_REPAIRED_SHA256="${REPAIRED_SHA256}"

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
model_repository_output="$(
    model_repository_is_verified         "${MODEL_REPO}"         "${MODEL_DIR_FIXTURE}"
)"
grep -Fq 'Existing model verification passed' <<<"${model_repository_output}" || {
    printf 'install readiness: authoritative verification was not accepted\n' >&2
    exit 1
}
model_is_ready || {
    printf 'install readiness: valid non-indexed shard layout was rejected\n' >&2
    exit 1
}
install_function="$(
    sed -n '/^command_install() {/,/^command_configure() {/p'         "${REPOSITORY_ROOT}/colibri.sh"
)"
grep -Fq 'model_repository_is_verified' <<<"${install_function}" || {
    printf 'install readiness: install does not use authoritative verification\n' >&2
    exit 1
}
if grep -Fq 'if model_is_ready' <<<"${install_function}"; then
    printf 'install readiness: install still uses the legacy heuristic decision\n' >&2
    exit 1
fi
grep -Fq 'No full model download was started or offered.' <<<"${install_function}" || {
    printf 'install readiness: existing failed models can still reach a full download\n' >&2
    exit 1
}

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

original_content="$(<"${MODEL_DIR_FIXTURE}/out-mtp-00000.safetensors")"
export HF_DOWNLOAD_WRONG_HASH=1
if (command_model repair --yes >/dev/null 2>&1); then
    printf 'model repair: wrong staged SHA-256 was accepted\n' >&2
    exit 1
fi
[[ "$(<"${MODEL_DIR_FIXTURE}/out-mtp-00000.safetensors")" == "${original_content}" ]] || {
    printf 'model repair: live shard changed after staged SHA-256 failure\n' >&2
    exit 1
}
export HF_DOWNLOAD_WRONG_HASH=0

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
grep -Fxq 'README.md' "${HF_ARGS_FILE}" && {
    printf 'model repair: non-model repository content was incorrectly requested\n' >&2
    exit 1
}
grep -Fxq 'MODEL_CARD.md' "${HF_ARGS_FILE}" && {
    printf 'model repair: missing non-model content was incorrectly requested\n' >&2
    exit 1
}

printf 'checksum verification and isolated repair: passed\n'
