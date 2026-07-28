#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly project_dir

# shellcheck disable=SC1090
source "${project_dir}/tests/lib/project-files.sh"

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd -- "${project_dir}"

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'Error: shellcheck is required to run the complete validation suite.\n' >&2
    exit 127
fi

printf '=== ShellCheck version ===\n'
shellcheck --version

printf '\n=== Static validation ===\n'
./test-static.sh

printf '\n=== Production ShellCheck ===\n'
shellcheck -o all "${PRODUCTION_SHELL_FILES[@]}"

printf '\n=== Test-suite ShellCheck ===\n'
# -x follows sourced project helpers; -o all keeps the same strict optional
# checks for production and test scripts.
shellcheck -x -o all "${TEST_SHELL_FILES[@]}"

printf '\n=== Mock integration ===\n'
./tests/mock-integration.sh

printf '\n=== Installer integration ===\n'
./tests/installer-integration.sh

printf '\nAll validation suites passed.\n'
