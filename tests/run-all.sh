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
if [[ ! -f ${PROJECT_FILES} || -L ${PROJECT_FILES} || ! -r ${PROJECT_FILES} ]]; then
    printf 'Error: required project file list is not a readable regular file: %s\n' \
        "${PROJECT_FILES}" >&2
    exit 66
fi
# Resolve this source relative to tests/run-all.sh for ShellCheck.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/project-files.sh
source "${PROJECT_FILES}"

for array_name in PRODUCTION_SHELL_FILES PACKAGING_SHELL_FILES TEST_SHELL_FILES DEVELOPMENT_SHELL_FILES; do
    if ! array_declaration=$(declare -p "${array_name}" 2>/dev/null) \
        || [[ ! ${array_declaration} =~ ^declare[[:space:]]+-([^[:space:]]+)[[:space:]] ]]; then
        printf 'Error: %s is not an indexed array in %s.\n' \
            "${array_name}" "${PROJECT_FILES}" >&2
        exit 65
    fi
    array_attributes=${BASH_REMATCH[1]}
    if [[ ${array_attributes} != *a* || ${array_attributes} == *A* ]]; then
        printf 'Error: %s is not an indexed array in %s.\n' \
            "${array_name}" "${PROJECT_FILES}" >&2
        exit 65
    fi
    declare -n array_ref="${array_name}"
    for array_entry in "${array_ref[@]}"; do
        if [[ -z ${array_entry} ]]; then
            printf 'Error: %s contains an empty shell-file entry.\n' \
                "${array_name}" >&2
            exit 65
        fi
        if [[ ${array_entry} == -* ]]; then
            printf 'Error: %s contains an option-like shell-file entry: %s\n' \
                "${array_name}" "${array_entry}" >&2
            exit 65
        fi
    done
    unset -n array_ref
done
if ((${#PRODUCTION_SHELL_FILES[@]} == 0 || \
    ${#PACKAGING_SHELL_FILES[@]} == 0 || \
    ${#TEST_SHELL_FILES[@]} == 0 || \
    ${#DEVELOPMENT_SHELL_FILES[@]} == 0)); then
    printf 'Error: project-files.sh returned an empty shell-file list.\n' >&2
    exit 65
fi

CURRENT_CHILD_PID=''

run_child() {
    local status=0

    "$@" &
    CURRENT_CHILD_PID=$!
    wait "${CURRENT_CHILD_PID}" || status=$?
    CURRENT_CHILD_PID=''
    return "${status}"
}

handle_signal() {
    local signal_name=$1
    local exit_status=$2

    trap - HUP INT TERM

    if [[ -n ${CURRENT_CHILD_PID} ]]; then
        kill "-${signal_name}" -- "${CURRENT_CHILD_PID}" 2>/dev/null || true
        for _ in {1..50}; do
            if ! kill -0 -- "${CURRENT_CHILD_PID}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        if kill -0 -- "${CURRENT_CHILD_PID}" 2>/dev/null; then
            kill -KILL -- "${CURRENT_CHILD_PID}" 2>/dev/null || true
        fi
        wait "${CURRENT_CHILD_PID}" 2>/dev/null || true
        CURRENT_CHILD_PID=''
    fi

    exit "${exit_status}"
}

trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

cd -- "${PROJECT_DIR}"

for command_name in shellcheck sleep; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Error: required validation command is absent: %s\n' \
            "${command_name}" >&2
        exit 127
    fi
done

printf '=== ShellCheck version ===\n'
shellcheck --version

printf '\n=== shfmt validation ===\n'
run_child bash -- ./scripts/check-shell-format.sh

printf '\n=== Static validation ===\n'
run_child bash -- ./test-static.sh

printf '\n=== Production ShellCheck ===\n'
run_child shellcheck -x -o all -- "${PRODUCTION_SHELL_FILES[@]}"

printf '\n=== Packaging ShellCheck ===\n'
run_child shellcheck -x -o all -- "${PACKAGING_SHELL_FILES[@]}"

printf '\n=== Test-suite ShellCheck ===\n'
# -x follows sourced project helpers; -o all keeps the same strict optional
# checks for production and test scripts.
run_child shellcheck -x -o all -- "${TEST_SHELL_FILES[@]}"

printf '\n=== Development tooling ShellCheck ===\n'
run_child shellcheck -x -o all -- "${DEVELOPMENT_SHELL_FILES[@]}"

printf '\n=== Runtime-manager integration ===\n'
run_child bash -- ./tests/runtime-manager-integration.sh

printf '\n=== Runtime-manager hardening integration ===\n'
run_child bash -- ./tests/runtime-manager-hardening-integration.sh

printf '\n=== Mock integration ===\n'
run_child bash -- ./tests/mock-integration.sh

printf '\n=== Private aria2 plan integration ===\n'
run_child bash -- ./tests/private-aria2-plan-integration.sh

printf '\n=== Private aria2 authentication/header integration ===\n'
run_child bash -- ./tests/aria2-auth-headers-integration.sh

printf '\n=== Progress monitor integration ===\n'
run_child bash -- ./tests/progress-monitor-integration.sh

printf '\n=== Measured FFmpeg progress integration ===\n'
run_child bash -- ./tests/ffmpeg-progress-integration.sh

printf '\n=== Installer integration ===\n'
run_child bash -- ./tests/installer-integration.sh

printf '\n=== Packaging integration ===\n'
run_child bash -- ./tests/packaging-integration.sh

printf '\n=== Package user cleanup integration ===\n'
run_child bash -- ./tests/package-user-cleanup-integration.sh

printf '\nAll validation suites passed.\n'
