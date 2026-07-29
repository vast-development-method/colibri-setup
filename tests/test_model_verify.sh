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
HF_VERIFY_ARGS_FILE="${TEST_ROOT}/hf-verify.args"
REPAIRED_CONTENT='repaired shard'
REPAIRED_SHA256="$(
    printf '%s\n' "${REPAIRED_CONTENT}" | sha256sum | awk '{print $1}'
)"
readonly MODEL_DIR_FIXTURE HF_ARGS_FILE HF_VERIFY_ARGS_FILE REPAIRED_CONTENT REPAIRED_SHA256
mkdir -p -- "${MODEL_DIR_FIXTURE}"
printf 'original broken shard\n' >"${MODEL_DIR_FIXTURE}/out-mtp-00000.safetensors"
printf '{}\n' >"${MODEL_DIR_FIXTURE}/config.json"
printf '{}\n' >"${MODEL_DIR_FIXTURE}/tokenizer.json"

cat >"${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "cache" && "${2:-}" == "verify" ]]; then
    printf '%s\n' "$@" >"${HF_VERIFY_ARGS_FILE:?}"
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
    if [[ "${HF_VERIFY_RESULT:-failure}" == "metadata-only" ]]; then
        printf 'Checksum verification failed for the following file(s):\n'
        printf '  - README.md: expected b17e81e7bbb6d1ebaddcc3376fc6e66b2d34bf15 (git-sha1), got 77311a8495cbd5984b60d48dd84d7070fb573660\n'
        printf 'Warning: 318 local file(s) do not exist on the remote repo.\n'
        printf 'Error: Verification failed.\n'
        exit 1
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
export HF_VERIFY_ARGS_FILE
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
    MODEL_REVISION="5276684ba30ac0026c07220d3f389171a84eb074"
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

install_function="$(
    sed -n '/^command_install() {/,/^command_configure() {/p' \
        "${REPOSITORY_ROOT}/colibri.sh"
)"
preflight_function="$(
    sed -n '/^preflight_start() {/,/^parse_common_options() {/p' \
        "${REPOSITORY_ROOT}/colibri.sh"
)"
cli_function="$(
    sed -n '/^command_cli() {/,/^command_uninstall() {/p' \
        "${REPOSITORY_ROOT}/colibri.sh"
)"
for forbidden_call in \
    model_repository_is_verified \
    run_model_integrity \
    model_is_ready \
    validate_model \
    ensure_hf_cli \
    ensure_hf_token \
    command_doctor \
    command_plan
do
    if grep -Fq "${forbidden_call}" \
        <<<"${install_function}${preflight_function}${cli_function}"; then
        printf 'lifecycle isolation: install/start/CLI still invokes %s\n' \
            "${forbidden_call}" >&2
        exit 1
    fi
done
grep -Fq 'accepted without checksum or layout verification' \
    <<<"${install_function}" || {
    printf 'lifecycle isolation: install does not state the no-verification contract\n' >&2
    exit 1
}

export HF_VERIFY_RESULT=success
output="$(command_model verify)"
grep -Fq 'Model verification passed' <<<"${output}" || {
    printf 'model verify: success message was not printed\n' >&2
    exit 1
}
grep -Fxq -- '--revision' "${HF_VERIFY_ARGS_FILE}" || {
    printf 'model verify: no pinned revision was supplied\n' >&2
    exit 1
}
grep -Fxq '5276684ba30ac0026c07220d3f389171a84eb074' \
    "${HF_VERIFY_ARGS_FILE}" || {
    printf 'model verify: the expected immutable revision was not supplied\n' >&2
    exit 1
}

export HF_VERIFY_RESULT=metadata-only
output="$(command_model verify 2>&1)"
grep -Fq 'Ignoring documentation, downloader metadata, and Colibri runtime sidecars' \
    <<<"${output}" || {
    printf 'model verify: README-only drift was not safely ignored\n' >&2
    exit 1
}
grep -Fq 'Model verification passed' <<<"${output}" || {
    printf 'model verify: README-only drift invalidated model artifacts\n' >&2
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
grep -Fxq -- '--revision' "${HF_ARGS_FILE}" || {
    printf 'model repair: no pinned revision was supplied\n' >&2
    exit 1
}
grep -Fxq '5276684ba30ac0026c07220d3f389171a84eb074' \
    "${HF_ARGS_FILE}" || {
    printf 'model repair: the expected immutable revision was not supplied\n' >&2
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
