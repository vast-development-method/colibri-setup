#!/usr/bin/env bash

set -Eeuo pipefail

readonly UPSTREAM_URL="https://github.com/JustVugg/colibri.git"
readonly UPSTREAM_COMMIT="81f08a09e5651ce52616dc720f68810f9021c0be"
readonly REPETITIONS="${COLIBRI_CONTRACT_REPETITIONS:-20}"

fail() {
    printf 'upstream-contract test: %s\n' "$*" >&2
    exit 1
}

[[ "${REPETITIONS}" =~ ^[1-9][0-9]*$ ]] ||
    fail "COLIBRI_CONTRACT_REPETITIONS must be a positive integer"

fixture_root="$(mktemp -d)"
cleanup() {
    rm -rf -- "${fixture_root}"
}
trap cleanup EXIT

if [[ -n "${COLIBRI_UPSTREAM_TEST_DIR:-}" ]]; then
    upstream_dir="${COLIBRI_UPSTREAM_TEST_DIR}"
else
    upstream_dir="${fixture_root}/upstream"
    git clone --no-checkout --filter=blob:none "${UPSTREAM_URL}" "${upstream_dir}"
    git -C "${upstream_dir}" checkout --detach "${UPSTREAM_COMMIT}"
fi

[[ "$(git -C "${upstream_dir}" rev-parse HEAD)" == "${UPSTREAM_COMMIT}" ]] ||
    fail "upstream checkout is not the pinned v1.1.1 commit"

(
    cd -- "${upstream_dir}/c"
    ARCH=native CUDA=0 CUDA_DLL=0 HIP=0 METAL=0 ./setup.sh
)

engine="${upstream_dir}/c/colibri"
[[ -x "${engine}" ]] || fail "pinned upstream CPU engine was not built"
if ldd "${engine}" 2>/dev/null | grep -Eq 'libcudart|libamdhip64'; then
    fail "pinned upstream fixture unexpectedly linked a GPU runtime"
fi

model_dir="${fixture_root}/incomplete-model"
mkdir -p -- "${model_dir}"
legacy_stderr="${fixture_root}/legacy.stderr"
clean_stderr="${fixture_root}/clean.stderr"

for ((iteration = 1; iteration <= REPETITIONS; iteration++)); do
    if SNAP="${model_dir}" \
        COLI_NO_OMP_TUNE=1 \
        COLI_GPU=none \
        "${engine}" 8 \
        >"${fixture_root}/legacy.stdout" \
        2>"${legacy_stderr}"; then
        fail "legacy GPU selector unexpectedly succeeded on repetition ${iteration}"
    fi
    grep -Fq \
        'CUDA was requested, but this binary is CPU-only' \
        "${legacy_stderr}" ||
        fail "legacy selector did not reproduce the production failure on repetition ${iteration}"

    if env \
        -u COLI_CUDA \
        -u COLI_GPU \
        -u COLI_GPUS \
        -u CUDA_DENSE \
        -u CUDA_EXPERT_GB \
        -u COLI_METAL \
        SNAP="${model_dir}" \
        COLI_NO_OMP_TUNE=1 \
        "${engine}" 8 \
        >"${fixture_root}/clean.stdout" \
        2>"${clean_stderr}"; then
        fail "incomplete fixture model unexpectedly loaded on repetition ${iteration}"
    fi
    if grep -Fq 'CUDA was requested' "${clean_stderr}"; then
        fail "sanitized CPU environment requested CUDA on repetition ${iteration}"
    fi
done

omp_stderr="${fixture_root}/omp.stderr"
if env \
    -u COLI_CUDA \
    -u COLI_GPU \
    -u COLI_GPUS \
    -u CUDA_DENSE \
    -u CUDA_EXPERT_GB \
    -u COLI_METAL \
    SNAP="${model_dir}" \
    "${engine}" 8 \
    >"${fixture_root}/omp.stdout" \
    2>"${omp_stderr}"; then
    fail "incomplete fixture model unexpectedly loaded during OMP test"
fi
grep -Fq '[OMP] hot-thread tuning: re-exec once' "${omp_stderr}" ||
    fail "sanitized CPU environment no longer preserves upstream OMP auto-tuning"
! grep -Fq 'CUDA was requested' "${omp_stderr}" ||
    fail "OMP-tuned clean environment requested CUDA"

printf 'upstream CPU contract: passed %s repetitions at %s\n' \
    "${REPETITIONS}" "${UPSTREAM_COMMIT}"
