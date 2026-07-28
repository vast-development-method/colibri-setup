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
    printf '32\n'
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

# Custom allocations cannot bypass the 80% ceiling.
TEST_TOTAL_RAM="62"
TEST_AVAILABLE_RAM="50"
CUSTOM_RAM="41"
CUSTOM_CTX="8192"
CUSTOM_WORKERS="8"
if (resolve_profile custom >/dev/null 2>&1); then
    printf 'profile test: unsafe custom RAM budget was accepted\n' >&2
    exit 1
fi

CUSTOM_RAM="40"
resolve_profile custom
[[ "${RAM_GB}" == "40" ]] || {
    printf 'profile test: safe custom RAM budget was rejected\n' >&2
    exit 1
}

printf 'profile tests: passed\n'
