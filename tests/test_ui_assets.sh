#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

# shellcheck source=../colibri.sh
source "${REPOSITORY_ROOT}/colibri.sh"

node_version_supports_colibri_web "v20.19.0"
node_version_supports_colibri_web "20.20.1"
node_version_supports_colibri_web "v22.12.0"
node_version_supports_colibri_web "v24.1.0"
! node_version_supports_colibri_web "v18.19.1"
! node_version_supports_colibri_web "v20.18.3"
! node_version_supports_colibri_web "v22.11.0"
! node_version_supports_colibri_web "not-a-version"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "${fixture_root}"' EXIT
! any_path_exists "${fixture_root}/absent-a" "${fixture_root}/absent-b"
touch "${fixture_root}/present"
any_path_exists "${fixture_root}/absent" "${fixture_root}/present"

SOURCE_DIR="${fixture_root}/upstream"
mkdir -p -- "${SOURCE_DIR}/web/dist"
printf 'fixture\n' >"${SOURCE_DIR}/web/dist/index.html"

UI_MODE="colibri-web"
apply_ui_asset_mode
[[ -f "${SOURCE_DIR}/web/dist/index.html" ]]

UI_MODE="api-only"
apply_ui_asset_mode
[[ ! -e "${SOURCE_DIR}/web/dist" ]]

mkdir -p -- "${SOURCE_DIR}/web/dist"
printf 'fixture\n' >"${SOURCE_DIR}/web/dist/index.html"
# The sourced helper consumes this cross-file global.
# shellcheck disable=SC2034
UI_MODE="open-webui"
apply_ui_asset_mode
[[ ! -e "${SOURCE_DIR}/web/dist" ]]

printf 'UI asset-mode tests: passed\n'
