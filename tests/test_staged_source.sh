#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
readonly REPOSITORY_ROOT

if [[ "${1:-}" == "build-failure-worker" ]]; then
    # shellcheck source=../colibri.sh
    source "${REPOSITORY_ROOT}/colibri.sh"
    SOURCE_DIR="${TEST_SOURCE_DIR}"
    STAGED_SOURCE_DIR=""
    prepare_staged_source "test-ref" "0"
    FAIL_STAGED_BUILD=1 build_colibri "${STAGED_SOURCE_DIR}"
    exit 0
fi

if [[ "${1:-}" == "activation-worker" ]]; then
    # shellcheck source=../colibri.sh
    source "${REPOSITORY_ROOT}/colibri.sh"
    SOURCE_DIR="${TEST_SOURCE_DIR}"
    STAGED_SOURCE_DIR=""
    sudo() {
        [[ "${1:-}" == "systemctl" && "${2:-}" == "is-active" ]] && return 1
        return 1
    }

    old_inode="$(stat -c '%i' "${SOURCE_DIR}")"
    prepare_staged_source "test-ref" "0"
    build_colibri "${STAGED_SOURCE_DIR}"
    staged_inode="$(stat -c '%i' "${STAGED_SOURCE_DIR}")"
    [[ "${old_inode}" != "${staged_inode}" ]]

    activate_staged_source
    [[ "$(stat -c '%i' "${SOURCE_DIR}")" == "${staged_inode}" ]]
    [[ -d "${ACTIVATION_PREVIOUS_SOURCE}/.git" ]]
    [[ "$(stat -c '%i' "${ACTIVATION_PREVIOUS_SOURCE}")" == "${old_inode}" ]]

    rollback_activated_source
    [[ "$(stat -c '%i' "${SOURCE_DIR}")" == "${old_inode}" ]]
    [[ -d "${ACTIVATION_PREVIOUS_SOURCE}/.git" ]]
    exit 0
fi

fixture_root="$(mktemp -d)"
trap 'rm -rf -- "${fixture_root}"' EXIT
export HOME="${fixture_root}/home"
export TEST_SOURCE_DIR="${fixture_root}/upstream"
mkdir -p -- "${HOME}" "${TEST_SOURCE_DIR}/c"

cat >"${TEST_SOURCE_DIR}/.gitignore" <<'EOF'
/c/coli
/c/colibri
EOF

cat >"${TEST_SOURCE_DIR}/c/setup.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${FAIL_STAGED_BUILD:-0}" == "1" ]]; then
    exit 23
fi
printf 'generated build configuration\n' >.build-config
printf '#!/usr/bin/env bash\nexit 0\n' >coli
printf '#!/usr/bin/env bash\nexit 0\n' >colibri
chmod +x coli colibri
EOF
chmod +x "${TEST_SOURCE_DIR}/c/setup.sh"

git -C "${TEST_SOURCE_DIR}" init -q
git -C "${TEST_SOURCE_DIR}" config user.name "Colibri Setup Test"
git -C "${TEST_SOURCE_DIR}" config user.email "colibri-setup-test@example.invalid"
git -C "${TEST_SOURCE_DIR}" add .gitignore c/setup.sh
git -C "${TEST_SOURCE_DIR}" commit -qm "fixture"
git -C "${TEST_SOURCE_DIR}" remote add origin \
    "https://github.com/JustVugg/colibri.git"

live_inode="$(stat -c '%i' "${TEST_SOURCE_DIR}")"
if "${BASH}" "${BASH_SOURCE[0]}" build-failure-worker \
    >"${fixture_root}/failure.log" 2>&1; then
    printf 'staged-source test: expected staged build failure\n' >&2
    exit 1
fi
[[ "$(stat -c '%i' "${TEST_SOURCE_DIR}")" == "${live_inode}" ]]
[[ -z "$(find "${fixture_root}" -maxdepth 1 -name '.upstream.stage.*' -print -quit)" ]]
git -C "${TEST_SOURCE_DIR}" diff --quiet
git -C "${TEST_SOURCE_DIR}" diff --cached --quiet

"${BASH}" "${BASH_SOURCE[0]}" activation-worker

printf 'staged source tests: passed\n'
