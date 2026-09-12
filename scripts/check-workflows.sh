#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/check-workflows.sh
# Purpose     : Validate workflow syntax using the explicitly pinned actionlint.
# ==============================================================================

set -euo pipefail
umask 077

main() {
    local script_dir=''
    local project_dir=''
    local actionlint_binary=''
    local shellcheck_binary=''
    local version_output=''
    local workflow_file=''
    local -a workflow_files=()

    if (($# != 0)); then
        printf 'Usage: scripts/check-workflows.sh\n' >&2
        return 64
    fi
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    project_dir=$(cd -- "${script_dir}/.." && pwd -P)
    # Resolve the reviewed data-only pin relative to this validator.
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=dev-tools/actionlint-pin.env
    source "${script_dir}/dev-tools/actionlint-pin.env"

    if ! actionlint_binary=$(command -v actionlint) \
        || ! shellcheck_binary=$(command -v shellcheck); then
        printf 'Error: actionlint %s and ShellCheck must be installed; this check does not download tools.\n' \
            "${ACTIONLINT_VERSION}" >&2
        return 69
    fi
    if ! version_output=$("${actionlint_binary}" -version); then
        printf 'Error: actionlint could not report its version.\n' >&2
        return 69
    fi
    if [[ ${version_output%%$'\n'*} != "${ACTIONLINT_VERSION}" ]]; then
        printf 'Error: actionlint %s is required by scripts/dev-tools/actionlint-pin.env.\n' \
            "${ACTIONLINT_VERSION}" >&2
        return 69
    fi

    shopt -s nullglob
    workflow_files=("${project_dir}"/.github/workflows/*.yml "${project_dir}"/.github/workflows/*.yaml)
    if ((${#workflow_files[@]} == 0)); then
        printf 'Error: no workflow files were found.\n' >&2
        return 66
    fi
    for workflow_file in "${workflow_files[@]}"; do
        if [[ ! -f ${workflow_file} || -L ${workflow_file} ]]; then
            printf 'Error: workflows must be regular files, not symbolic links.\n' >&2
            return 65
        fi
    done

    printf 'actionlint: %s; ShellCheck enabled; %d workflows\n' \
        "${ACTIONLINT_VERSION}" "${#workflow_files[@]}"
    # Python linting is not a project dependency. Keep that optional integration
    # disabled consistently instead of changing coverage with the caller's PATH.
    exec "${actionlint_binary}" -color -pyflakes '' \
        -shellcheck "${shellcheck_binary}" "${workflow_files[@]}"
}

main "$@"
