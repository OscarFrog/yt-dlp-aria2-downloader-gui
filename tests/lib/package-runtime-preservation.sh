#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/package-runtime-preservation.sh
# Purpose     : Share package-upgrade runtime preservation fixtures and assertions.
# ==============================================================================

# RUNTIME_ROOT is a required caller-provided absolute path.
# shellcheck disable=SC2154

PACKAGE_RUNTIME_ROOT_CREATED=false
PACKAGE_RUNTIME_PARENT_CREATED=false
PACKAGE_RUNTIME_PROBE_DIR=''
PACKAGE_RUNTIME_BASELINE=''

runtime_tree_snapshot() {
    local runtime_parent=''
    local runtime_name=''
    local digest=''

    [[ -n ${RUNTIME_ROOT:-} && ${RUNTIME_ROOT} == /* ]] || return 1
    runtime_parent=${RUNTIME_ROOT%/*}
    runtime_name=${RUNTIME_ROOT##*/}

    digest=$(
        set -o pipefail
        tar \
            --sort=name \
            --mtime='UTC 1970-01-01' \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            --format=gnu \
            -cf - \
            -C "${runtime_parent}" \
            "${runtime_name}" \
            | sha256sum
    ) || return 1

    printf '%s\n' "${digest%% *}"
}

package_runtime_fixture_cleanup() {
    local runtime_parent=''

    [[ -n ${RUNTIME_ROOT:-} && ${RUNTIME_ROOT} == /* ]] || return 0
    runtime_parent=${RUNTIME_ROOT%/*}

    if [[ -n ${PACKAGE_RUNTIME_PROBE_DIR} &&
        ${PACKAGE_RUNTIME_PROBE_DIR} == "${RUNTIME_ROOT}/.package-runtime-preservation."* &&
        (-e ${RUNTIME_ROOT} || -L ${RUNTIME_ROOT}) ]]; then
        if [[ -d ${RUNTIME_ROOT} && ! -L ${RUNTIME_ROOT} ]]; then
            rm -rf -- "${PACKAGE_RUNTIME_PROBE_DIR}" || true
        else
            printf 'Warning: refusing to clean package runtime probe through unsafe runtime root: %s\n' \
                "${RUNTIME_ROOT}" >&2
        fi
    fi
    PACKAGE_RUNTIME_PROBE_DIR=''

    if [[ ${PACKAGE_RUNTIME_ROOT_CREATED} == true ]]; then
        rmdir -- "${RUNTIME_ROOT}" >/dev/null 2>&1 || true
    fi
    if [[ ${PACKAGE_RUNTIME_PARENT_CREATED} == true ]]; then
        rmdir -- "${runtime_parent}" >/dev/null 2>&1 || true
    fi

    PACKAGE_RUNTIME_ROOT_CREATED=false
    PACKAGE_RUNTIME_PARENT_CREATED=false
    PACKAGE_RUNTIME_BASELINE=''
}

package_runtime_fixture_prepare() {
    local sentinel_text=$1
    local runtime_parent=''

    if [[ -z ${RUNTIME_ROOT:-} || ${RUNTIME_ROOT} != /* ]]; then
        printf 'Error: RUNTIME_ROOT must be an absolute path.\n' >&2
        return 64
    fi

    runtime_parent=${RUNTIME_ROOT%/*}
    if [[ -L ${runtime_parent} ]]; then
        printf 'Error: refusing runtime fixture through symlinked parent: %s\n' \
            "${runtime_parent}" >&2
        return 65
    fi
    if [[ -e ${RUNTIME_ROOT} || -L ${RUNTIME_ROOT} ]]; then
        if [[ ! -d ${RUNTIME_ROOT} || -L ${RUNTIME_ROOT} ]]; then
            printf 'Error: unsafe pre-existing runtime root: %s\n' \
                "${RUNTIME_ROOT}" >&2
            return 65
        fi
    else
        if [[ ! -e ${runtime_parent} && ! -L ${runtime_parent} ]]; then
            PACKAGE_RUNTIME_PARENT_CREATED=true
        fi
        mkdir -p -- "${RUNTIME_ROOT}" || {
            printf 'Error: unable to create runtime preservation fixture root: %s\n' \
                "${RUNTIME_ROOT}" >&2
            return 65
        }
        PACKAGE_RUNTIME_ROOT_CREATED=true
    fi

    PACKAGE_RUNTIME_PROBE_DIR=$(mktemp -d \
        "${RUNTIME_ROOT}/.package-runtime-preservation.XXXXXX") || {
        printf '%s\n' \
            'Error: unable to create runtime preservation probe.' >&2
        package_runtime_fixture_cleanup
        return 65
    }

    if ! printf '%s\n' "${sentinel_text}" \
        >"${PACKAGE_RUNTIME_PROBE_DIR}/sentinel"; then
        printf '%s\n' \
            'Error: unable to write runtime preservation sentinel.' >&2
        package_runtime_fixture_cleanup
        return 65
    fi

    if ! PACKAGE_RUNTIME_BASELINE=$(runtime_tree_snapshot); then
        printf '%s\n' \
            'Error: unable to create baseline runtime snapshot.' >&2
        package_runtime_fixture_cleanup
        return 65
    fi

    return 0
}

assert_runtime_preserved() {
    local stage=$1
    local current_digest=''

    if [[ ! -d ${RUNTIME_ROOT} || -L ${RUNTIME_ROOT} ]]; then
        printf 'Error: runtime root disappeared or became unsafe during %s.\n' \
            "${stage}" >&2
        return 65
    fi

    if ! current_digest=$(runtime_tree_snapshot); then
        printf 'Error: unable to snapshot runtime tree during %s.\n' \
            "${stage}" >&2
        return 65
    fi

    if [[ -z ${PACKAGE_RUNTIME_BASELINE} ||
        ${current_digest} != "${PACKAGE_RUNTIME_BASELINE}" ]]; then
        printf 'Error: per-user runtime tree changed during %s.\n' \
            "${stage}" >&2
        return 65
    fi

    return 0
}

assert_runtime_removed() {
    local stage=$1

    if [[ -e ${RUNTIME_ROOT} || -L ${RUNTIME_ROOT} ]]; then
        printf 'Error: per-user runtime remains after %s: %s\n' \
            "${stage}" "${RUNTIME_ROOT}" >&2
        return 65
    fi

    return 0
}
