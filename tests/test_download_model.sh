#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/download_model.sh"
TEST_ROOT="$(mktemp -d)"
BIN_DIR="${TEST_ROOT}/bin"
export MOCK_ROOT="${TEST_ROOT}/mock"
export HOME="${TEST_ROOT}/home"
export COLIBRI_DOWNLOAD_STATE_DIR="${TEST_ROOT}/state"
export COLIBRI_MODELS_DIR="${TEST_ROOT}/models"

cleanup() {
    local pid_file pid
    if [[ -d "${MOCK_ROOT}/screens" ]]; then
        for pid_file in "${MOCK_ROOT}"/screens/*.pid; do
            [[ -f "$pid_file" ]] || continue
            pid="$(cat "$pid_file")"
            kill -TERM -- "-${pid}" 2>/dev/null || true
        done
    fi
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$MOCK_ROOT" "$HOME"

cat > "${BIN_DIR}/screen" <<'SCREEN'
#!/usr/bin/env bash
set -euo pipefail
root="${MOCK_ROOT}/screens"
mkdir -p "$root"
case "${1:-}" in
    -DmS)
        name="$2"
        shift 2
        setsid "$@" >"${root}/${name}.output" 2>&1 &
        printf '%s\n' "$!" > "${root}/${name}.pid"
        ;;
    -S)
        name="$2"
        action="${3:-}"
        pid_file="${root}/${name}.pid"
        [[ -f "$pid_file" ]] || exit 1
        pid="$(cat "$pid_file")"
        if [[ "$action" == "-Q" && "${4:-}" == "windows" ]]; then
            kill -0 "$pid" 2>/dev/null
        elif [[ "$action" == "-X" && "${4:-}" == "quit" ]]; then
            kill -TERM -- "-${pid}" 2>/dev/null || true
            rm -f -- "$pid_file"
        else
            exit 1
        fi
        ;;
    -r)
        name="$2"
        cat "${root}/${name}.output"
        ;;
    *)
        exit 1
        ;;
esac
SCREEN

cat > "${BIN_DIR}/hf" <<'HF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_EXPECT_HF_TOKEN:-}" &&
    "${HF_TOKEN:-}" != "${MOCK_EXPECT_HF_TOKEN}" ]]; then
    printf 'HF_TOKEN was not exported to the hf process\n' >&2
    exit 97
fi
printf '%s\n' "$@" > "${MOCK_ROOT}/hf.args"
destination=''
while (($#)); do
    if [[ "$1" == "--local-dir" ]]; then
        destination="$2"
        break
    fi
    shift
done
[[ -n "$destination" ]]
mode="${MOCK_HF_MODE:-success}"
counter_file="${MOCK_ROOT}/hf.counter"
count=0
[[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

case "$mode" in
    transient)
        if ((count == 1)); then
            echo 'temporary connection reset'
            exit 7
        fi
        ;;
    permanent)
        echo 'HTTP 401 Unauthorized'
        exit 1
        ;;
    slow)
        trap 'exit 130' TERM INT HUP
        sleep 30
        ;;
esac

mkdir -p "$destination"
printf '{}\n' > "${destination}/config.json"
printf '{}\n' > "${destination}/tokenizer.json"
printf 'weights\n' > "${destination}/model-00001-of-00001.safetensors"
printf 'mtp\n' > "${destination}/out-mtp.safetensors"
echo 'mock download complete'
HF

chmod +x "$SCRIPT" "${BIN_DIR}/screen" "${BIN_DIR}/hf"
export PATH="${BIN_DIR}:${PATH}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "Expected output to contain: ${needle}"
}

wait_for_status() {
    local job="$1"
    local wanted="$2"
    local attempt output
    for ((attempt = 0; attempt < 100; attempt++)); do
        output="$("$SCRIPT" status "$job" 2>&1 || true)"
        [[ "$output" == *"Status:      ${wanted}"* ]] && return 0
        sleep 0.1
    done
    printf '%s\n' "$output" >&2
    fail "Job ${job} did not reach status ${wanted}"
}

start_job() {
    local model="$1"
    local folder="$2"
    shift 2
    "$SCRIPT" start "$model" "$folder" \
        --yes \
        --no-token-prompt \
        --expected-size-gb 0 \
        --min-free-gb 0 \
        --retry-base 1 \
        --retry-max 1 \
        --hf-bin "${BIN_DIR}/hf" \
        --screen-bin "${BIN_DIR}/screen" \
        "$@"
}

printf '1. start, validation, status, attach, and token secrecy\n'
export HF_TOKEN='hf_testsecretmustnotleak'
output="$(start_job 'test/model-success' "${TEST_ROOT}/direct-success")"
job="$(awk '/^Job: / {print $2}' <<< "$output")"
[[ -n "$job" ]] || fail "Start did not print a job ID"
wait_for_status "$job" complete
status_output="$("$SCRIPT" status "$job")"
assert_contains "$status_output" 'Download completed and required model files were validated.'
attach_output="$("$SCRIPT" attach "$job" 2>&1 || true)"
assert_contains "$attach_output" 'not running'
grep -R -F "$HF_TOKEN" "$COLIBRI_DOWNLOAD_STATE_DIR" "$MOCK_ROOT/hf.args" >/dev/null 2>&1 &&
    fail "HF_TOKEN leaked into state, log, or command arguments"
unset HF_TOKEN
export HF_TOKEN='hf_testruntimetoken'

printf '2. transient failure retries and completes\n'
rm -f "${MOCK_ROOT}/hf.counter"
export MOCK_HF_MODE=transient
output="$(start_job 'test/model-transient' 'transient' --max-retries 2)"
job="$(awk '/^Job: / {print $2}' <<< "$output")"
wait_for_status "$job" complete
[[ "$(cat "${MOCK_ROOT}/hf.counter")" == 2 ]] || fail "Transient job did not retry exactly once"
unset MOCK_HF_MODE

printf '3. permanent failure stops, then resume succeeds\n'
rm -f "${MOCK_ROOT}/hf.counter"
export MOCK_HF_MODE=permanent
output="$(start_job 'test/model-permanent' 'permanent' --max-retries 3)"
job="$(awk '/^Job: / {print $2}' <<< "$output")"
wait_for_status "$job" failed-permanent
[[ "$(cat "${MOCK_ROOT}/hf.counter")" == 1 ]] || fail "Permanent failure was retried"
unset MOCK_HF_MODE
resume_output="$("$SCRIPT" resume "$job" --no-token-prompt)"
assert_contains "$resume_output" 'Download started in detached Screen session'
wait_for_status "$job" complete

printf '4. cancel preserves files and allows a later resume\n'
rm -f "${MOCK_ROOT}/hf.counter"
export MOCK_HF_MODE=slow
output="$(start_job 'test/model-cancel' 'cancel' --max-retries 0)"
job="$(awk '/^Job: / {print $2}' <<< "$output")"
wait_for_status "$job" downloading
cancel_output="$("$SCRIPT" cancel "$job")"
assert_contains "$cancel_output" 'Partial model files were preserved.'
wait_for_status "$job" canceled
unset MOCK_HF_MODE
resume_output="$("$SCRIPT" resume "$job" --no-token-prompt)"
assert_contains "$resume_output" 'Download started in detached Screen session'
wait_for_status "$job" complete

unset HF_TOKEN

printf '5. private .env token is loaded and exported automatically\n'
mkdir -p "${HOME}/.config/colibri-setup"
chmod 700 "${HOME}/.config/colibri-setup"
printf 'HF_TOKEN=hf_envfiletoken\n' >"${HOME}/.config/colibri-setup/.env"
chmod 600 "${HOME}/.config/colibri-setup/.env"
export MOCK_EXPECT_HF_TOKEN='hf_envfiletoken'
rm -f "${MOCK_ROOT}/hf.counter"
output="$(start_job 'test/model-envfile' 'envfile')"
job="$(awk '/^Job: / {print $2}' <<<"$output")"
wait_for_status "$job" complete
unset MOCK_EXPECT_HF_TOKEN

printf 'All download manager tests passed.\n'
