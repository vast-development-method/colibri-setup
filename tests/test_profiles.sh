#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

# shellcheck source=../colibri.sh
source "${REPOSITORY_ROOT}/colibri.sh"

logical_cpu_count() {
    printf '%s\n' "${TEST_CPUS:-32}"
}

TEST_TOTAL_RAM=""
TEST_AVAILABLE_RAM=""

total_ram_gb() {
    printf '%s\n' "${TEST_TOTAL_RAM}"
}

available_ram_gb() {
    printf '%s\n' "${TEST_AVAILABLE_RAM}"
}

assert_profile() {
    local total_ram=$1
    local available_ram=$2
    local profile=$3
    local expected_ram=$4

    TEST_TOTAL_RAM="${total_ram}"
    TEST_AVAILABLE_RAM="${available_ram}"
    resolve_profile "${profile}"

    if [[ "${RAM_GB}" != "${expected_ram}" ]]; then
        printf \
            'profile test: %s on %s GiB total/%s GiB available selected %s GiB; expected %s GiB\n' \
            "${profile}" "${total_ram}" "${available_ram}" "${RAM_GB}" "${expected_ram}" >&2
        exit 1
    fi
}

# An idle 64 GB-class host scales each profile from hardware capacity.
assert_profile 62 60 performance 48
assert_profile 62 60 experimental 48
assert_profile 62 60 balanced 43
assert_profile 62 60 conservative 31

# Current availability is an additional hard ceiling for every profile.
assert_profile 62 55 performance 44
assert_profile 62 50 performance 40
assert_profile 128 40 performance 32
assert_profile 128 40 balanced 32
assert_profile 128 40 conservative 32

# Smaller hosts retain proportional sizing under the same safety contract.
assert_profile 48 46 performance 36
assert_profile 48 46 balanced 33
assert_profile 48 46 conservative 24

# Custom allocations use explicit validated inputs and cannot bypass the
# 80% ceiling. This avoids exporting mutable profile state into subprocesses.
TEST_TOTAL_RAM="62"
TEST_AVAILABLE_RAM="50"
if (resolve_profile custom 41 8192 8 >/dev/null 2>&1); then
    printf 'profile test: unsafe custom RAM budget was accepted\n' >&2
    exit 1
fi

resolve_profile custom 40 8192 8
[[ "${RAM_GB}" == "40" ]] || {
    printf 'profile test: safe custom RAM budget was rejected\n' >&2
    exit 1
}

for TEST_CPUS in 1 2 4 8 32 64; do
    for TEST_TOTAL_RAM in 32 48 62 64 96 128; do
        for available_percent in 80 90 100; do
            TEST_AVAILABLE_RAM="$((TEST_TOTAL_RAM * available_percent / 100))"
            for profile in conservative balanced performance experimental; do
                resolve_profile "${profile}"
                total_ceiling="$((TEST_TOTAL_RAM * 80 / 100))"
                available_ceiling="$((TEST_AVAILABLE_RAM * 80 / 100))"
                ((RAM_GB <= total_ceiling)) || {
                    printf 'profile property: %s exceeded installed-RAM ceiling\n' "${profile}" >&2
                    exit 1
                }
                ((RAM_GB <= available_ceiling)) || {
                    printf 'profile property: %s exceeded available-RAM ceiling\n' "${profile}" >&2
                    exit 1
                }
                ((PIPE_WORKERS >= 1 && PIPE_WORKERS <= TEST_CPUS)) || {
                    printf 'profile property: %s selected invalid worker count\n' "${profile}" >&2
                    exit 1
                }
            done
        done
    done
done
unset TEST_CPUS

printf 'profile tests: passed\n'
