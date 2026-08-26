#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/run-all.sh
# Purpose     : Run the complete local validation suite.
# ==============================================================================

set -euo pipefail
# Bash forces SIGINT/SIGQUIT to be ignored for asynchronous commands when job
# control is disabled. run_child therefore uses a tiny Python trampoline that
# restores those signal dispositions before creating a dedicated session.
set +m

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
CURRENT_CHILD_PGID=''

run_child() {
    local status=0

    python3 - "$@" <<'PY_CHILD' &
import os
import signal
import sys

# Bash starts asynchronous commands with SIGINT/SIGQUIT ignored when job
# control is disabled. A non-interactive shell started in that state cannot
# subsequently trap those signals, so restore them before exec.
for signal_name in ("SIGINT", "SIGQUIT", "SIGPIPE", "SIGXFSZ", "SIGXFZ"):
    signal_number = getattr(signal, signal_name, None)
    if signal_number is not None:
        signal.signal(signal_number, signal.SIG_DFL)

os.setsid()

try:
    os.execvp(sys.argv[1], sys.argv[1:])
except FileNotFoundError:
    os._exit(127)
except PermissionError:
    os._exit(126)
PY_CHILD

    CURRENT_CHILD_PID=$!
    CURRENT_CHILD_PGID=${CURRENT_CHILD_PID}

    # Wait briefly for os.setsid() to publish the new process group. This keeps
    # signal delivery deterministic even if interruption races with startup.
    for _ in {1..50}; do
        if kill -0 -- "-${CURRENT_CHILD_PGID}" 2>/dev/null; then
            break
        fi
        kill -0 -- "${CURRENT_CHILD_PID}" 2>/dev/null || break
        sleep 0.01
    done

    wait "${CURRENT_CHILD_PID}" || status=$?
    CURRENT_CHILD_PID=''
    CURRENT_CHILD_PGID=''
    return "${status}"
}

handle_signal() {
    local signal_name=$1
    local exit_status=$2

    trap - HUP INT TERM

    if [[ -n ${CURRENT_CHILD_PID} ]]; then
        if [[ -n ${CURRENT_CHILD_PGID} ]]; then
            for _ in {1..20}; do
                if kill -0 -- "-${CURRENT_CHILD_PGID}" 2>/dev/null; then
                    break
                fi
                kill -0 -- "${CURRENT_CHILD_PID}" 2>/dev/null || break
                sleep 0.01
            done
        fi

        if [[ -n ${CURRENT_CHILD_PGID} ]] \
            && kill -0 -- "-${CURRENT_CHILD_PGID}" 2>/dev/null; then
            kill "-${signal_name}" -- "-${CURRENT_CHILD_PGID}" 2>/dev/null || true
        else
            kill "-${signal_name}" -- "${CURRENT_CHILD_PID}" 2>/dev/null || true
        fi

        for _ in {1..50}; do
            if [[ -n ${CURRENT_CHILD_PGID} ]] \
                && kill -0 -- "-${CURRENT_CHILD_PGID}" 2>/dev/null; then
                sleep 0.1
                continue
            fi
            if ! kill -0 -- "${CURRENT_CHILD_PID}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        if [[ -n ${CURRENT_CHILD_PGID} ]] \
            && kill -0 -- "-${CURRENT_CHILD_PGID}" 2>/dev/null; then
            kill -KILL -- "-${CURRENT_CHILD_PGID}" 2>/dev/null || true
        elif kill -0 -- "${CURRENT_CHILD_PID}" 2>/dev/null; then
            kill -KILL -- "${CURRENT_CHILD_PID}" 2>/dev/null || true
        fi

        wait "${CURRENT_CHILD_PID}" 2>/dev/null || true
        CURRENT_CHILD_PID=''
        CURRENT_CHILD_PGID=''
    fi

    exit "${exit_status}"
}

trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

cd -- "${PROJECT_DIR}"

for command_name in python3 shellcheck sleep; do
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

printf '\n=== run-all signal/descendant integration ===\n'
run_child bash -- ./tests/run-all-signal-integration.sh

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
