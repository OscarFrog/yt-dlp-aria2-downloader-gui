#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly project_dir

project_files="${project_dir}/tests/lib/project-files.sh"
readonly project_files
if [[ ! -r ${project_files} ]]; then
    printf 'Error: required project file list is not readable: %s\n' \
        "${project_files}" >&2
    exit 66
fi
# Resolve this source relative to tests/run-all.sh for ShellCheck.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/project-files.sh
source "${project_files}"

for array_name in PRODUCTION_SHELL_FILES PACKAGING_SHELL_FILES TEST_SHELL_FILES; do
    if ! array_declaration=$(declare -p "${array_name}" 2>/dev/null) ||
        [[ ${array_declaration} != 'declare -a '* ]]; then
        printf 'Error: %s is not an indexed array in %s.\n' \
            "${array_name}" "${project_files}" >&2
        exit 65
    fi
done
if ((${#PRODUCTION_SHELL_FILES[@]} == 0 ||
    ${#PACKAGING_SHELL_FILES[@]} == 0 ||
    ${#TEST_SHELL_FILES[@]} == 0)); then
    printf 'Error: project-files.sh returned an empty shell-file list.\n' >&2
    exit 65
fi

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
bash -- ./test-static.sh

printf '\n=== Production ShellCheck ===\n'
shellcheck -o all "${PRODUCTION_SHELL_FILES[@]}"

printf '\n=== Packaging ShellCheck ===\n'
shellcheck -x -o all "${PACKAGING_SHELL_FILES[@]}"

printf '\n=== Test-suite ShellCheck ===\n'
# -x follows sourced project helpers; -o all keeps the same strict optional
# checks for production and test scripts.
shellcheck -x -o all "${TEST_SHELL_FILES[@]}"

printf '\n=== Mock integration ===\n'
bash -- ./tests/mock-integration.sh

printf '\n=== Progress monitor integration ===\n'
bash -- ./tests/progress-monitor-integration.sh

printf '\n=== Measured FFmpeg progress integration ===\n'
bash -- ./tests/ffmpeg-progress-integration.sh

printf '\n=== Installer integration ===\n'
bash -- ./tests/installer-integration.sh

printf '\n=== Packaging integration ===\n'
bash -- ./tests/packaging-integration.sh

printf '\nAll validation suites passed.\n'
