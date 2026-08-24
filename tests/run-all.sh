#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/run-all.sh
# Purpose     : Run the complete local validation suite.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly PROJECT_DIR

PROJECT_FILES="${PROJECT_DIR}/tests/lib/project-files.sh"
readonly PROJECT_FILES
if [[ ! -r ${PROJECT_FILES} ]]; then
    printf 'Error: required project file list is not readable: %s\n' \
        "${PROJECT_FILES}" >&2
    exit 66
fi
# Resolve this source relative to tests/run-all.sh for ShellCheck.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/project-files.sh
source "${PROJECT_FILES}"

for array_name in PRODUCTION_SHELL_FILES PACKAGING_SHELL_FILES TEST_SHELL_FILES DEVELOPMENT_SHELL_FILES; do
    if ! array_declaration=$(declare -p "${array_name}" 2>/dev/null) \
        || [[ ${array_declaration} != 'declare -a '* ]]; then
        printf 'Error: %s is not an indexed array in %s.\n' \
            "${array_name}" "${PROJECT_FILES}" >&2
        exit 65
    fi
done
if ((${#PRODUCTION_SHELL_FILES[@]} == 0 || \
    ${#PACKAGING_SHELL_FILES[@]} == 0 || \
    ${#TEST_SHELL_FILES[@]} == 0 || \
    ${#DEVELOPMENT_SHELL_FILES[@]} == 0)); then
    printf 'Error: project-files.sh returned an empty shell-file list.\n' >&2
    exit 65
fi

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd -- "${PROJECT_DIR}"

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'Error: shellcheck is required to run the complete validation suite.\n' >&2
    exit 127
fi

printf '=== ShellCheck version ===\n'
shellcheck --version

printf '\n=== shfmt validation ===\n'
bash -- ./scripts/check-shell-format.sh

printf '\n=== Static validation ===\n'
bash -- ./test-static.sh

printf '\n=== Production ShellCheck ===\n'
shellcheck -x -o all "${PRODUCTION_SHELL_FILES[@]}"

printf '\n=== Packaging ShellCheck ===\n'
shellcheck -x -o all "${PACKAGING_SHELL_FILES[@]}"

printf '\n=== Test-suite ShellCheck ===\n'
# -x follows sourced project helpers; -o all keeps the same strict optional
# checks for production and test scripts.
shellcheck -x -o all "${TEST_SHELL_FILES[@]}"

printf '\n=== Development tooling ShellCheck ===\n'
shellcheck -x -o all "${DEVELOPMENT_SHELL_FILES[@]}"

printf '\n=== Runtime-manager integration ===\n'
bash -- ./tests/runtime-manager-integration.sh

printf '\n=== Runtime-manager hardening integration ===\n'
bash -- ./tests/runtime-manager-hardening-integration.sh

printf '\n=== Mock integration ===\n'
bash -- ./tests/mock-integration.sh

printf '\n=== Private aria2 plan integration ===\n'
bash -- ./tests/private-aria2-plan-integration.sh

printf '\n=== Progress monitor integration ===\n'
bash -- ./tests/progress-monitor-integration.sh

printf '\n=== Measured FFmpeg progress integration ===\n'
bash -- ./tests/ffmpeg-progress-integration.sh

printf '\n=== Installer integration ===\n'
bash -- ./tests/installer-integration.sh

printf '\n=== Packaging integration ===\n'
bash -- ./tests/packaging-integration.sh

printf '\n=== Package user cleanup integration ===\n'
bash -- ./tests/package-user-cleanup-integration.sh

printf '\nAll validation suites passed.\n'
