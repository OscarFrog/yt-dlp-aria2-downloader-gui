#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/git-inspect.sh
# Purpose     : Provide fixed read-only Git inspections for unattended agents.
# ==============================================================================

set -euo pipefail
umask 077

usage() {
    printf '%s\n' \
        'Usage: scripts/git-inspect.sh status|diff|diff-staged|diff-check|inventory'
}

main() {
    (($# == 1)) || {
        usage >&2
        exit 2
    }
    local action=$1
    local env_binary=''
    local git_binary=''
    local project_dir=''
    local script_source=${BASH_SOURCE[0]}
    local script_dir=''
    local -a git_prefix=()

    for env_binary in /usr/bin/env /bin/env; do
        [[ -f ${env_binary} && -x ${env_binary} ]] && break
        env_binary=''
    done
    for git_binary in /usr/bin/git /bin/git; do
        [[ -f ${git_binary} && -x ${git_binary} ]] && break
        git_binary=''
    done
    if [[ -z ${env_binary} || -z ${git_binary} ]]; then
        printf 'Error: trusted system env and Git executables are required.\n' >&2
        exit 127
    fi
    [[ ${script_source} == */* ]] || {
        printf 'Error: invoke this helper through its repository path.\n' >&2
        exit 2
    }
    script_dir=$(cd -- "${script_source%/*}" && pwd -P)
    project_dir=$(cd -- "${script_dir}/.." && pwd -P)

    # Start Git with a closed environment so inherited trace destinations,
    # repository redirections, loaders, helpers, and configuration injection
    # cannot turn inspection into a write. The action parser accepts no
    # user-provided revision, path, option, helper, or output filename.
    git_prefix=(
        "${env_binary}"
        -i
        HOME=/nonexistent
        PATH=/usr/bin:/bin
        LC_ALL=C
        GIT_OPTIONAL_LOCKS=0
        GIT_PAGER=
        GIT_EXTERNAL_DIFF=
        GIT_ATTR_NOSYSTEM=1
        GIT_CONFIG_NOSYSTEM=1
        "${git_binary}"
        -c core.fsmonitor=false
        -c diff.external=
        -C "${project_dir}"
    )

    case ${action} in
        status)
            "${git_prefix[@]}" status \
                --short --branch --untracked-files=all
            ;;
        diff)
            "${git_prefix[@]}" diff \
                --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --
            ;;
        diff-staged)
            "${git_prefix[@]}" diff --cached \
                --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --
            ;;
        diff-check)
            "${git_prefix[@]}" diff \
                --no-ext-diff --no-textconv --check --
            "${git_prefix[@]}" diff --cached \
                --no-ext-diff --no-textconv --check --
            ;;
        inventory)
            "${git_prefix[@]}" ls-files \
                --cached --others --exclude-standard --
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
