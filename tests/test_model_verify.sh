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
mkdir -p -- "${HOME}" "${XDG_DATA_HOME}/colibri-setup/hf-venv/bin"

MODEL_DIR_FIXTURE="${TEST_ROOT}/model"
HF_ARGS_FILE="${TEST_ROOT}/hf.args"
readonly MODEL_DIR_FIXTURE HF_ARGS_FILE
mkdir -p -- "${MODEL_DIR_FIXTURE}"

cat > "${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" > "${HF_ARGS_FILE:?}"
if [[ "${HF_VERIFY_RESULT:-success}" == "failure" ]]; then
    printf 'checksum mismatch\n' >&2
    exit 1
fi
printf 'All checksums match.\n'
EOF
chmod +x "${XDG_DATA_HOME}/colibri-setup/hf-venv/bin/hf"
export HF_ARGS_FILE

# shellcheck source=../colibri.sh
source "${REPOSITORY_ROOT}/colibri.sh"

require_non_root() {
    :
}

load_config() {
    MODEL_REPO="example/model"
    MODEL_DIR="${MODEL_DIR_FIXTURE}"
}

ensure_hf_cli() {
    :
}

output="$(command_model verify)"
grep -Fq 'Model verification passed' <<<"${output}" || {
    printf 'model verify: success message was not printed\n' >&2
    exit 1
}

mapfile -t hf_args < "${HF_ARGS_FILE}"
expected_args=(
    cache
    verify
    example/model
    --local-dir
    "${MODEL_DIR_FIXTURE}"
    --fail-on-missing-files
)
[[ "${hf_args[*]}" == "${expected_args[*]}" ]] || {
    printf 'model verify: unexpected Hugging Face arguments\n' >&2
    printf 'expected: %q\n' "${expected_args[*]}" >&2
    printf 'actual:   %q\n' "${hf_args[*]}" >&2
    exit 1
}

export HF_VERIFY_RESULT=failure
if (command_model verify >/dev/null 2>&1); then
    printf 'model verify: checksum failure was not propagated\n' >&2
    exit 1
fi

printf 'model verify: passed\n'
