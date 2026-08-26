#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/check-shell-format.sh
# Purpose     : Verify canonical shell formatting without modifying project files.
# ==============================================================================

set -euo pipefail

main() {
    local script_dir=''
    local project_dir=''
    local project_files=''
    local ensure_shfmt=''
    local shfmt_binary=''
    local shfmt_version=''
    local -a shfmt_flags=(-i 4 -ci -bn)

    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    project_dir=$(cd -- "${script_dir}/.." && pwd -P)
    project_files="${project_dir}/tests/lib/project-files.sh"
    ensure_shfmt="${project_dir}/scripts/dev-tools/ensure-shfmt.sh"

    [[ -r ${project_files} ]] || {
        printf 'Error: canonical shell-file list is not readable: %s\n' \
            "${project_files}" >&2
        exit 66
    }
    [[ -x ${ensure_shfmt} ]] || {
        printf 'Error: shfmt bootstrap is not executable: %s\n' \
            "${ensure_shfmt}" >&2
        exit 66
    }

    # Resolve the canonical inventory relative to this script for ShellCheck.
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../tests/lib/project-files.sh
    source "${project_files}"

    if ((${#ALL_SHELL_FILES[@]} == 0)); then
        printf 'Error: canonical shell-file list is empty.\n' >&2
        exit 65
    fi

    if ! shfmt_binary=$(bash -- "${ensure_shfmt}"); then
        printf 'Error: unable to resolve the managed shfmt binary.\n' >&2
        exit 65
    fi
    if [[ -z ${shfmt_binary} ||
        ${shfmt_binary} == *$'\n'* ||
        ${shfmt_binary} != /* ||
        -L ${shfmt_binary} ||
        ! -f ${shfmt_binary} ||
        ! -x ${shfmt_binary} ]]; then
        printf 'Error: shfmt bootstrap returned an invalid executable path.\n' >&2
        exit 65
    fi
    if ! shfmt_version=$("${shfmt_binary}" --version); then
        printf 'Error: the managed shfmt binary cannot report its version: %s\n' \
            "${shfmt_binary}" >&2
        exit 65
    fi

    printf 'shfmt: %s\n' "${shfmt_version}"
    printf 'shfmt flags: %s\n' "${shfmt_flags[*]}"
    printf 'shfmt simplification: disabled\n'

    cd -- "${project_dir}"
    "${shfmt_binary}" -d "${shfmt_flags[@]}" -- "${ALL_SHELL_FILES[@]}"
}

main "$@"
