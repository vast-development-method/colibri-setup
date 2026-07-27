#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

FIXTURE_ROOT="$(mktemp -d)"
readonly FIXTURE_ROOT
trap 'rm -rf -- "${FIXTURE_ROOT}"' EXIT

mkdir -p -- "${FIXTURE_ROOT}/primary" "${FIXTURE_ROOT}/mirror"
for filename in \
    config.json \
    tokenizer.json \
    model-00001.safetensors \
    out-mtp-1
do
    printf '%s\n' "${filename}" >"${FIXTURE_ROOT}/primary/${filename}"
    cp -- \
        "${FIXTURE_ROOT}/primary/${filename}" \
        "${FIXTURE_ROOT}/mirror/${filename}"
done

"${REPOSITORY_ROOT}/scripts/mirror_model.sh" verify \
    "${FIXTURE_ROOT}/primary" \
    "${FIXTURE_ROOT}/mirror"

"${REPOSITORY_ROOT}/scripts/mirror_model.sh" verify \
    "${FIXTURE_ROOT}/primary" \
    "${FIXTURE_ROOT}/mirror" \
    --full-verify

printf 'mirror tests: passed\n'
