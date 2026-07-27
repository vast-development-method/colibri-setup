#!/usr/bin/env bash

set -Eeuo pipefail

readonly ADDRESS=${1:-}
readonly ATTEMPTS=${COLIBRI_BIND_WAIT_ATTEMPTS:-90}
readonly INTERVAL=${COLIBRI_BIND_WAIT_INTERVAL:-2}

if [[ -z "${ADDRESS}" ]]; then
    printf 'Usage: %s <local-address>\n' "$0" >&2
    exit 2
fi

if [[ ! "${ATTEMPTS}" =~ ^[0-9]+$ || ! "${INTERVAL}" =~ ^[0-9]+$ ]]; then
    printf 'Wait settings must be non-negative integers.\n' >&2
    exit 2
fi

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    if ip -o addr show 2>/dev/null |
        awk '{sub(/\/.*/, "", $4); print $4}' |
        grep -Fqx -- "${ADDRESS}"; then
        exit 0
    fi
    sleep "${INTERVAL}"
done

printf 'Configured bind address did not appear on this host: %s\n' "${ADDRESS}" >&2
exit 1
