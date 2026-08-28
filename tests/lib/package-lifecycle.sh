#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/package-lifecycle.sh
# Purpose     : Share package lifecycle payload and removal assertions.
# ==============================================================================

readonly PACKAGE_DESKTOP_FILE='/usr/share/applications/yt-dlp-aria2-downloader.desktop'
readonly PACKAGE_ICON_FILE='/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg'

assert_package_cli_version() {
    local package_kind=$1
    local expected_version=$2
    local stage=$3
    local reported_version=''

    if ! reported_version=$(/usr/bin/yt-dlp-aria2-downloader --version); then
        printf 'Error: %s executable failed during %s.\n' \
            "${package_kind}" "${stage}" >&2
        return 65
    fi
    if [[ ${reported_version} != "yt-dlp-aria2-downloader version ${expected_version}" ]]; then
        printf 'Error: %s executable reports an unexpected version during %s: %s\n' \
            "${package_kind}" "${stage}" "${reported_version}" >&2
        return 65
    fi
    return 0
}

assert_common_package_payload() {
    local package_kind=$1
    local runtime_command=''

    [[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]] || {
        printf 'Error: %s GUI launcher is absent.\n' "${package_kind}" >&2
        return 65
    }
    [[ -f ${PACKAGE_DESKTOP_FILE} && ! -L ${PACKAGE_DESKTOP_FILE} ]] || {
        printf 'Error: %s desktop file is absent or unsafe.\n' \
            "${package_kind}" >&2
        return 65
    }
    [[ -f ${PACKAGE_ICON_FILE} && ! -L ${PACKAGE_ICON_FILE} ]] || {
        printf 'Error: %s icon is absent or unsafe.\n' "${package_kind}" >&2
        return 65
    }
    desktop-file-validate --no-hints "${PACKAGE_DESKTOP_FILE}"
    grep -Fqx -- 'Icon=yt-dlp-aria2-downloader' "${PACKAGE_DESKTOP_FILE}"

    for runtime_command in \
        aria2c ffmpeg ffprobe python3 curl gpg unzip flock timeout; do
        command -v "${runtime_command}" >/dev/null 2>&1 || {
            printf 'Error: %s dependency command is absent: %s\n' \
                "${package_kind}" "${runtime_command}" >&2
            return 65
        }
    done
    return 0
}

assert_package_paths_absent() {
    local package_kind=$1
    local stage=$2
    local path=''
    shift 2

    for path in "$@"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: %s left a package path during %s: %s\n' \
                "${package_kind}" "${stage}" "${path}" >&2
            return 65
        }
    done
    return 0
}
