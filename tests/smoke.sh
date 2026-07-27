#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

cd "${REPOSITORY_ROOT}"

[[ -x colibri.sh ]] || {
    printf 'smoke: colibri.sh is missing or not executable\n' >&2
    exit 1
}

[[ -x scripts/download_model.sh ]] || {
    printf 'smoke: scripts/download_model.sh is missing or not executable\n' >&2
    exit 1
}

help_output="$(./colibri.sh --help)"

for command in \
    install \
    configure \
    upgrade \
    start stop restart enable disable status logs \
    doctor plan test \
    profile \
    model \
    ui \
    open-webui \
    hf-token \
    api-key \
    uninstall \
    cli
do
    if ! grep -Eq "(^|[[:space:]])${command}([[:space:]]|$)" \
        <<<"${help_output}"; then
        printf 'smoke: help does not document command: %s\n' "${command}" >&2
        exit 1
    fi
done

grep -Fq '11435' <<<"${help_output}" || {
    printf 'smoke: help does not report the default port\n' >&2
    exit 1
}

for mode in open-webui colibri-web api-only; do
    grep -Fq "${mode}" <<<"${help_output}" || {
        printf 'smoke: help does not report UI mode: %s\n' "${mode}" >&2
        exit 1
    }
done

grep -Fq 'Model weights are NEVER deleted.' <<<"${help_output}" || {
    printf 'smoke: help does not guarantee model preservation\n' >&2
    exit 1
}

grep -Fq 'model verify [REPO] [DEST]' <<<"${help_output}" || {
    printf 'smoke: help does not document model checksum verification\n' >&2
    exit 1
}

grep -Fq 'model repair [REPO] [DEST] [--yes]' <<<"${help_output}" || {
    printf 'smoke: help does not document selective model repair\n' >&2
    exit 1
}

if grep -nE \
    '\brm[[:space:]].*(\$\{?MODEL_DIR|\$\{?MIRROR_DIR)' \
    colibri.sh
then
    printf 'smoke: colibri.sh contains a model-directory removal command\n' >&2
    exit 1
fi

download_help="$(scripts/download_model.sh start --help)"

grep -Fq 'HF_TOKEN' <<<"${download_help}" || {
    printf 'smoke: download help does not explain HF_TOKEN\n' >&2
    exit 1
}

grep -Fq 'screen' <<<"${download_help}" || {
    printf 'smoke: download help does not explain GNU Screen\n' >&2
    exit 1
}

printf 'smoke: passed (help-only; no service or model operations executed)\n'
