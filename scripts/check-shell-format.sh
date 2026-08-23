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

    shfmt_binary=$(bash -- "${ensure_shfmt}")
    shfmt_version=$("${shfmt_binary}" --version)

    printf 'shfmt: %s\n' "${shfmt_version}"
    printf 'shfmt flags: -i 4 -ci -bn\n'
    printf 'shfmt simplification: disabled\n'

    cd -- "${project_dir}"
    "${shfmt_binary}" -d -i 4 -ci -bn -- "${ALL_SHELL_FILES[@]}"
}

main "$@"
