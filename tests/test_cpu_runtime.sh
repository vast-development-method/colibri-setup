#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

# shellcheck source=../colibri.sh
source "${REPOSITORY_ROOT}/colibri.sh"

fail() {
    printf 'cpu-runtime test: %s\n' "$*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf -- "${fixture_root}"' EXIT
SOURCE_DIR="${fixture_root}/upstream"
MODEL_DIR="${fixture_root}/model"
mkdir -p -- "${SOURCE_DIR}/c" "${MODEL_DIR}"
printf '#!/usr/bin/env bash\nexit 0\n' >"${SOURCE_DIR}/c/coli"
printf 'int main(void) { return 0; }\n' >"${fixture_root}/colibri.c"
gcc "${fixture_root}/colibri.c" -o "${SOURCE_DIR}/c/colibri"
chmod +x "${SOURCE_DIR}/c/coli" "${SOURCE_DIR}/c/colibri"

DEPLOY_USER="$(id -un)"
DEPLOY_GROUP="$(id -gn)"
MODEL_REPO="test/model"
MODEL_ID="test-model"
MIRROR_DIR=""
UPSTREAM_REF="v1.2.0"
SOURCE_CREATED="1"
BIND_HOST="127.0.0.1"
PORT="11435"
PROFILE="performance"
RAM_GB="48"
CTX="8192"
PIPE_WORKERS="12"
PIN_GB="14"
MAX_QUEUE="4"
QUEUE_TIMEOUT="1800"
KV_SLOTS="1"
DIRECT="1"
URING="0"
PILOT="0"
PILOT_REAL="0"
COLI_API_KEY="$(
    printf 'a%.0s' {1..64}
)"
export DEPLOY_USER DEPLOY_GROUP SOURCE_DIR MODEL_DIR MODEL_REPO MODEL_ID
export MIRROR_DIR UPSTREAM_REF SOURCE_CREATED BIND_HOST PORT PROFILE RAM_GB
export CTX PIPE_WORKERS PIN_GB MAX_QUEUE QUEUE_TIMEOUT KV_SLOTS DIRECT
export URING PILOT PILOT_REAL UI_MODE COLI_API_KEY

config_output="$(render_config)"
if grep -Eq \
    '^(COLI_CUDA|COLI_GPU|COLI_GPUS|CUDA_DENSE|CUDA_EXPERT_GB|COLI_METAL)=' \
    <<<"${config_output}"; then
    fail "rendered configuration contains a GPU backend selector"
fi
grep -Fxq 'COLI_POLICY=quality' <<<"${config_output}" ||
    fail "rendered configuration lost the quality policy"
grep -Fxq \
    'MODEL_REVISION=5276684ba30ac0026c07220d3f389171a84eb074' \
    <<<"${config_output}" ||
    fail "rendered configuration lost the immutable model revision"
printf '%s\n' "${config_output}" >"${fixture_root}/clean.env"
! config_file_has_gpu_backend_settings "${fixture_root}/clean.env" ||
    fail "clean configuration was classified as GPU-enabled"
printf 'COLI_GPU=none\n' >"${fixture_root}/legacy.env"
config_file_has_gpu_backend_settings "${fixture_root}/legacy.env" ||
    fail "legacy production-breaking configuration was not detected"

for mode in api-only open-webui colibri-web; do
    UI_MODE="${mode}"
    unit_file="${fixture_root}/${mode}.service"
    render_service_unit "${unit_file}"

    grep -Fqx \
        'UnsetEnvironment=COLI_CUDA COLI_GPU COLI_GPUS CUDA_DENSE CUDA_EXPERT_GB COLI_METAL' \
        "${unit_file}" ||
        fail "${mode} unit does not clear inherited GPU backend settings"
    service_unit_file_has_cpu_runtime_contract "${unit_file}" ||
        fail "${mode} unit failed the CPU runtime contract validator"
    grep -Fqx 'StartLimitIntervalSec=300' "${unit_file}" ||
        fail "${mode} unit is missing its restart interval"
    grep -Fqx 'StartLimitBurst=3' "${unit_file}" ||
        fail "${mode} unit is missing its restart burst limit"
    ! grep -Fq 'RequiresMountsFor=' "${unit_file}" ||
        fail "${mode} unit still blocks Colibri behind a wrapper model-mount preflight"
    if grep -Eq '^Environment=(COLI_CUDA|COLI_GPU|COLI_GPUS|CUDA_DENSE|CUDA_EXPERT_GB|COLI_METAL)=' \
        "${unit_file}"; then
        fail "${mode} unit adds a GPU backend setting"
    fi
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "${unit_file}" >/dev/null ||
            fail "systemd rejected the rendered ${mode} unit"
    fi

    if [[ "${mode}" == "colibri-web" ]]; then
        grep -Eq '^ExecStart=.*/coli web .* --no-browser$' "${unit_file}" ||
            fail "colibri-web unit does not use the dashboard command"
    else
        grep -Eq '^ExecStart=.*/coli serve ' "${unit_file}" ||
            fail "${mode} unit does not use the API service command"
        ! grep -Fq -- '--no-browser' "${unit_file}" ||
            fail "${mode} unexpectedly renders a dashboard-only option"
    fi
done

legacy_config="${fixture_root}/migrated.env"
legacy_unit="${fixture_root}/migrated.service"
printf 'COLI_GPU=none\n' >"${legacy_config}"
printf '# legacy unit without CPU environment cleanup\n' >"${legacy_unit}"
(
    trap - ERR EXIT
    managed_config_has_gpu_backend_settings() {
        grep -Eq \
            '^(COLI_CUDA|COLI_GPU|COLI_GPUS|CUDA_DENSE|CUDA_EXPERT_GB|COLI_METAL)=' \
            "${legacy_config}"
    }
    service_unit_has_cpu_runtime_contract() {
        grep -Fqx \
            'UnsetEnvironment=COLI_CUDA COLI_GPU COLI_GPUS CUDA_DENSE CUDA_EXPERT_GB COLI_METAL' \
            "${legacy_unit}"
    }
    write_config() {
        render_config >"${legacy_config}"
    }
    install_service_unit() {
        render_service_unit "${legacy_unit}"
    }
    export COLI_GPU=none
    ensure_cpu_runtime_contract
    [[ -z "${COLI_GPU+x}" ]]
)
! config_file_has_gpu_backend_settings "${legacy_config}" ||
    fail "legacy configuration migration retained a GPU backend selector"
service_unit_file_has_cpu_runtime_contract "${legacy_unit}" ||
    fail "legacy service migration did not add CPU environment cleanup"

ldd() {
    printf '\tlibgomp.so.1 => /lib/libgomp.so.1\n'
}
assert_cpu_only_engine "${SOURCE_DIR}/c/colibri"

if (
    ldd() {
        printf '\tlibamdhip64.so => /opt/rocm/lib/libamdhip64.so\n'
    }
    assert_cpu_only_engine "${SOURCE_DIR}/c/colibri"
) >/dev/null 2>&1; then
    fail "ROCm-linked engine was accepted"
fi

if (
    ldd() {
        printf '\tlibcudart.so => /usr/local/cuda/lib64/libcudart.so\n'
    }
    assert_cpu_only_engine "${SOURCE_DIR}/c/colibri"
) >/dev/null 2>&1; then
    fail "CUDA-linked engine was accepted"
fi

if grep -R -nE 'export COLI_GPU=none|printf .COLI_GPU=none' \
    "${REPOSITORY_ROOT}/colibri.sh" \
    "${REPOSITORY_ROOT}/README.md" \
    "${REPOSITORY_ROOT}/docs"; then
    fail "legacy COLI_GPU=none instructions remain"
fi

status_function="$(
    sed -n '/^command_status() {/,/^command_logs() {/p' \
        "${REPOSITORY_ROOT}/colibri.sh"
)"
! grep -Fq 'status --all --quiet' <<<"${status_function}" ||
    fail "status still passes unsupported download-manager options"

printf 'cpu runtime contract tests: passed\n'
