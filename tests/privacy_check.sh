#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

declare -a SEARCH_FILES=()

while IFS= read -r -d '' file; do
    SEARCH_FILES+=("${file}")
done < <(
    find "${REPOSITORY_ROOT}" \
        -path "${REPOSITORY_ROOT}/.git" -prune -o \
        -type f \
        ! -path "${REPOSITORY_ROOT}/tests/privacy_check.sh" \
        -print0
)

if ((${#SEARCH_FILES[@]} == 0)); then
    printf 'privacy check: no files found\n' >&2
    exit 1
fi

failed=0

private_ipv4_regex='(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
private_ipv4_matches="$(
    grep -nHE -- "${private_ipv4_regex}" "${SEARCH_FILES[@]}" || true
)"

if [[ -n "${private_ipv4_matches}" ]]; then
    printf 'privacy check: found a private IPv4 address:\n%s\n' \
        "${private_ipv4_matches}" >&2
    failed=1
fi

home_path_regex='(^|[^[:alnum:]_])/(home|Users)/[[:alnum:]_.-]+/'
home_path_matches="$(
    grep -nHE -- "${home_path_regex}" "${SEARCH_FILES[@]}" || true
)"

if [[ -n "${home_path_matches}" ]]; then
    printf 'privacy check: found a hard-coded user home path:\n%s\n' \
        "${home_path_matches}" >&2
    failed=1
fi

hardware_model_regex='(^|[^[:alnum:]_])(i[3579]-[0-9]{4,5}[A-Z]{0,3}|Ryzen[[:space:]]+[3579][[:space:]]+[0-9]{4,5}[A-Z]{0,3}|RTX[[:space:]]+[0-9]{4}([[:space:]][[:alpha:]]+)?|Radeon[[:space:]]+RX[[:space:]]+[0-9]{4}[[:alnum:]]*)([^[:alnum:]_]|$)'
hardware_model_matches="$(
    grep -niHE -- "${hardware_model_regex}" "${SEARCH_FILES[@]}" || true
)"

if [[ -n "${hardware_model_matches}" ]]; then
    printf 'privacy check: found a machine-specific CPU/GPU model:\n%s\n' \
        "${hardware_model_matches}" >&2
    failed=1
fi

# A private CI runner can add one exact sensitive string per line without
# committing that denylist to this repository.
if [[ -n "${COLIBRI_PRIVACY_DENYLIST_FILE:-}" ]]; then
    [[ -r "${COLIBRI_PRIVACY_DENYLIST_FILE}" ]] || {
        printf 'privacy check: denylist is not readable: %s\n' \
            "${COLIBRI_PRIVACY_DENYLIST_FILE}" >&2
        exit 1
    }

    while IFS= read -r sensitive_value; do
        [[ -n "${sensitive_value}" ]] || continue
        exact_matches="$(
            grep -nHIF -- "${sensitive_value}" "${SEARCH_FILES[@]}" || true
        )"
        if [[ -n "${exact_matches}" ]]; then
            printf 'privacy check: found an exact denylisted value:\n%s\n' \
                "${exact_matches}" >&2
            failed=1
        fi
    done <"${COLIBRI_PRIVACY_DENYLIST_FILE}"
fi

if ((failed != 0)); then
    exit 1
fi

printf 'privacy check: passed\n'
