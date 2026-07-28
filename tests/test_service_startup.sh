#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

# shellcheck source=../colibri.sh
source "${REPOSITORY_ROOT}/colibri.sh"
trap - ERR EXIT

fixture_root="$(mktemp -d)"
cleanup() {
    rm -rf -- "${fixture_root}"
}
trap cleanup EXIT

fail() {
    printf 'service-startup test: %s\n' "$*" >&2
    exit 1
}

TEST_MODE="stable"
TEST_ACTIVE="0"
TEST_RESTARTS="0"
TEST_STOP_MARKER="${fixture_root}/stopped"
COLIBRI_STARTUP_GUARD_SECONDS="3"
export COLIBRI_STARTUP_GUARD_SECONDS

sleep() {
    :
}

systemctl() {
    local action=${1:-}
    shift || true

    case "${action}" in
        reset-failed)
            return 0
            ;;
        show)
            printf '%s\n' "${TEST_RESTARTS}"
            ;;
        start | restart)
            case "${TEST_MODE}" in
                stable)
                    TEST_ACTIVE="1"
                    ;;
                immediate-exit)
                    TEST_ACTIVE="0"
                    ;;
                restart-loop)
                    TEST_ACTIVE="1"
                    TEST_RESTARTS=$((TEST_RESTARTS + 1))
                    ;;
                command-failure)
                    return 5
                    ;;
                *)
                    return 6
                    ;;
            esac
            ;;
        is-active)
            [[ "${TEST_ACTIVE}" == "1" ]]
            ;;
        stop)
            TEST_ACTIVE="0"
            : >"${TEST_STOP_MARKER}"
            ;;
        status)
            printf 'mock colibri.service status\n'
            ;;
        *)
            fail "unexpected systemctl action: ${action} $*"
            ;;
    esac
}

journalctl() {
    printf 'mock journal: engine exited before READY\n'
}

sudo() {
    "$@"
}

checked_service_operation start
[[ "${TEST_ACTIVE}" == "1" ]] ||
    fail "stable service was not left active"
[[ ! -e "${TEST_STOP_MARKER}" ]] ||
    fail "stable service was stopped"

TEST_MODE="immediate-exit"
TEST_ACTIVE="0"
rm -f -- "${TEST_STOP_MARKER}"
if (
    trap - ERR EXIT
    checked_service_operation start
) >/dev/null 2>&1; then
    fail "immediate process exit was reported as a successful start"
fi
[[ -e "${TEST_STOP_MARKER}" ]] ||
    fail "immediate startup failure did not stop the service"

TEST_MODE="restart-loop"
TEST_ACTIVE="0"
TEST_RESTARTS="0"
rm -f -- "${TEST_STOP_MARKER}"
if (
    trap - ERR EXIT
    checked_service_operation start
) >/dev/null 2>&1; then
    fail "automatic restart was reported as a successful start"
fi
[[ -e "${TEST_STOP_MARKER}" ]] ||
    fail "restart-loop detection did not stop the service"

TEST_MODE="command-failure"
TEST_ACTIVE="0"
rm -f -- "${TEST_STOP_MARKER}"
if (
    trap - ERR EXIT
    checked_service_operation start
) >/dev/null 2>&1; then
    fail "systemctl command failure was reported as success"
fi

logical_cpu_count() {
    printf '32\n'
}

total_ram_gb() {
    printf '62\n'
}

available_ram_gb() {
    printf '50\n'
}

write_config() {
    : >"${fixture_root}/profile-config-written"
}

install_service_unit() {
    : >"${fixture_root}/profile-unit-written"
}

TEST_MODE="stable"
TEST_ACTIVE="0"
PROFILE="performance"
RAM_GB="48"
CTX="8192"
PIPE_WORKERS="12"
PIN_GB="14"
MAX_QUEUE="4"
DIRECT="1"
URING="0"
PILOT="0"
PILOT_REAL="0"
export PROFILE RAM_GB CTX PIPE_WORKERS PIN_GB MAX_QUEUE
export DIRECT URING PILOT PILOT_REAL
refresh_profile_before_start
[[ "${RAM_GB}" == "40" ]] ||
    fail "stopped service did not adapt to the current 80% availability ceiling"
[[ -e "${fixture_root}/profile-config-written" ]] ||
    fail "adapted profile was not persisted"
[[ -e "${fixture_root}/profile-unit-written" ]] ||
    fail "adapted profile did not refresh the service unit"

TEST_ACTIVE="1"
RAM_GB="48"
refresh_profile_before_start
[[ "${RAM_GB}" == "48" ]] ||
    fail "active service RAM was incorrectly recalculated against its own usage"

PROFILE="custom"
RAM_GB="50"
if (
    trap - ERR EXIT
    refresh_profile_before_start
) >/dev/null 2>&1; then
    fail "custom profile above 80% of installed RAM was accepted"
fi

printf 'service startup guard tests: passed\n'
