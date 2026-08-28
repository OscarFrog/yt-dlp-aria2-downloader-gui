#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/install-tree.sh
# Purpose     : Assemble the packaged application tree under a staging DESTDIR.
# ==============================================================================

set -Eeuo pipefail
umask 022

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'

valid_staging_dir() {
    local path=$1
    local rest=''
    local component=''

    [[ ${path} == /* &&
        ${path} != / &&
        ${path} != */ &&
        ${path} != *$'\n'* &&
        ${path} != *$'\r'* ]] || return 1

    rest=${path#/}
    while [[ -n ${rest} ]]; do
        if [[ ${rest} == */* ]]; then
            component=${rest%%/*}
            rest=${rest#*/}
        else
            component=${rest}
            rest=''
        fi

        [[ -n ${component} &&
            ${component} != . &&
            ${component} != .. ]] || return 1
    done

    return 0
}

valid_private_dir() {
    local path=$1
    local rest=''
    local component=''

    [[ ${path} == /usr/* &&
        ${path} != /usr/ &&
        ${path} != */ &&
        ${path} != *$'\n'* &&
        ${path} != *$'\r'* ]] || return 1

    rest=${path#/usr/}
    while [[ -n ${rest} ]]; do
        if [[ ${rest} == */* ]]; then
            component=${rest%%/*}
            rest=${rest#*/}
        else
            component=${rest}
            rest=''
        fi

        [[ -n ${component} &&
            ${component} != . &&
            ${component} != .. ]] || return 1
    done

    return 0
}

parse_install_tree_arguments() {
    if (($# != 3)); then
        printf 'Usage: %s DESTDIR VERSION PRIVATE_DIR\n' "${0##*/}" >&2
        exit 2
    fi

    readonly DESTDIR=$1
    readonly VERSION=$2
    readonly PRIVATE_DIR=$3
}

validate_install_tree_arguments() {
    # These predicates are intentionally handled as validation branches.
    # shellcheck disable=SC2310
    valid_staging_dir "${DESTDIR}" || {
        printf 'Error: DESTDIR must be an absolute canonical staging path.\n' >&2
        exit 2
    }
    # shellcheck disable=SC2310
    valid_private_dir "${PRIVATE_DIR}" || {
        printf 'Error: invalid PRIVATE_DIR.\n' >&2
        exit 2
    }
    [[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Error: invalid version.\n' >&2
        exit 2
    }
}

require_install_tree_commands() {
    local command_name=''

    for command_name in dirname install ln pwd; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' \
                "${command_name}" >&2
            exit 127
        }
    done
}

initialize_install_tree_paths() {
    local script_parent=''

    script_parent=$(dirname -- "${BASH_SOURCE[0]}")
    SCRIPT_DIR=$(cd -- "${script_parent}" && pwd -P)
    readonly SCRIPT_DIR
    PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
    readonly PROJECT_DIR

    PRIVATE_TARGET="${DESTDIR}${PRIVATE_DIR}"
    readonly PRIVATE_TARGET
    BIN_DIR="${DESTDIR}/usr/bin"
    readonly BIN_DIR
    APPLICATIONS_DIR="${DESTDIR}/usr/share/applications"
    readonly APPLICATIONS_DIR
    ICON_DIR="${DESTDIR}/usr/share/icons/hicolor/scalable/apps"
    readonly ICON_DIR
    DOC_DIR="${DESTDIR}/usr/share/doc/${PACKAGE_NAME}"
    readonly DOC_DIR
    MAN1_DIR="${DESTDIR}/usr/share/man/man1"
    readonly MAN1_DIR
}

validate_packaging_inputs() {
    local required_file=''

    for required_file in \
        download-video.sh \
        download-video-gui.sh \
        progress-monitor.sh \
        runtime-manager.sh \
        private-aria2-plan.py \
        packaging/package-user-cleanup.sh \
        README.md \
        README.fr.md \
        CHANGELOG.md \
        packaging/yt-dlp-aria2-downloader.desktop \
        packaging/icons/yt-dlp-aria2-downloader.svg \
        packaging/keys/yt-dlp-public.key \
        packaging/man/yt-dlp-aria2-downloader.1 \
        packaging/man/yt-dlp-aria2-downloader-gui.1; do
        [[ -f ${PROJECT_DIR}/${required_file} ]] || {
            printf 'Error: required packaging input is absent: %s\n' \
                "${required_file}" >&2
            exit 66
        }
    done
}

install_private_payload() {
    install -d -m 0755 -- "${PRIVATE_TARGET}" "${PRIVATE_TARGET}/keys"
    install -m 0755 -- \
        "${PROJECT_DIR}/download-video.sh" \
        "${PROJECT_DIR}/download-video-gui.sh" \
        "${PROJECT_DIR}/progress-monitor.sh" \
        "${PROJECT_DIR}/runtime-manager.sh" \
        "${PROJECT_DIR}/packaging/package-user-cleanup.sh" \
        "${PRIVATE_TARGET}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${PRIVATE_TARGET}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/packaging/keys/yt-dlp-public.key" \
        "${PRIVATE_TARGET}/keys/yt-dlp-public.key"
}

install_shared_payload() {
    install -d -m 0755 -- \
        "${APPLICATIONS_DIR}" "${ICON_DIR}" "${DOC_DIR}" "${MAN1_DIR}"
    install -m 0644 -- \
        "${PROJECT_DIR}/README.md" \
        "${PROJECT_DIR}/README.fr.md" \
        "${PROJECT_DIR}/CHANGELOG.md" \
        "${DOC_DIR}/"
    install -m 0644 -- \
        "${PROJECT_DIR}/packaging/yt-dlp-aria2-downloader.desktop" \
        "${APPLICATIONS_DIR}/yt-dlp-aria2-downloader.desktop"
    install -m 0644 -- \
        "${PROJECT_DIR}/packaging/icons/yt-dlp-aria2-downloader.svg" \
        "${ICON_DIR}/yt-dlp-aria2-downloader.svg"
    install -m 0644 -- \
        "${PROJECT_DIR}/packaging/man/yt-dlp-aria2-downloader.1" \
        "${PROJECT_DIR}/packaging/man/yt-dlp-aria2-downloader-gui.1" \
        "${MAN1_DIR}/"
}

install_package_launchers() {
    local relative_private="../${PRIVATE_DIR#/usr/}"

    install -d -m 0755 -- "${BIN_DIR}"
    ln -s -- "${relative_private}/download-video.sh" \
        "${BIN_DIR}/yt-dlp-aria2-downloader"
    ln -s -- "${relative_private}/download-video-gui.sh" \
        "${BIN_DIR}/yt-dlp-aria2-downloader-gui"
}

main() {
    parse_install_tree_arguments "$@"
    validate_install_tree_arguments
    require_install_tree_commands
    initialize_install_tree_paths
    validate_packaging_inputs
    install_private_payload
    install_shared_payload
    install_package_launchers

    printf 'Installed package tree for version %s under %s\n' \
        "${VERSION}" "${DESTDIR}"
}

main "$@"
