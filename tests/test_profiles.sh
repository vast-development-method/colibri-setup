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

total_ram_gb() {
    printf '%s\n' "${TEST_TOTAL_RAM}"
}

assert_profile() {
    local total_ram=$1
    local profile=$2
    local expected_ram=$3

    TEST_TOTAL_RAM="${total_ram}"
    resolve_profile "${profile}"

    if [[ "${RAM_GB}" != "${expected_ram}" ]]; then
        printf \
            'profile test: %s on %s GiB selected %s GiB; expected %s GiB\n' \
            "${profile}" \
            "${total_ram}" \
            "${RAM_GB}" \
            "${expected_ram}" >&2
        exit 1
    fi
}

# The production CPU/NVMe performance plan deliberately tops out at 44 GiB.
# This leaves sufficient headroom on the target 64 GiB host for the dashboard,
# operating system and Colibri runtime allocations checked by upstream doctor.
assert_profile 62 performance 44
assert_profile 62 experimental 44

# Smaller hosts retain the proportional calculation rather than being raised
# to the production cap.
assert_profile 48 performance 38

# The other presets retain their existing behavior.
assert_profile 62 balanced 43
assert_profile 62 conservative 31

printf 'profile tests: passed\n'
