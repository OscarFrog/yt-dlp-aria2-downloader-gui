#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/install-tree.sh
# Purpose     : Assemble the packaged application tree under a staging DESTDIR.
# ==============================================================================

set -Eeuo pipefail
umask 022

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

if (($# != 3)); then
    printf 'Usage: %s DESTDIR VERSION PRIVATE_DIR\n' "${0##*/}" >&2
    exit 2
fi
readonly DESTDIR="$1" VERSION="$2" PRIVATE_DIR="$3"
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
[[ ${DESTDIR} == /* ]] || {
    printf 'Error: DESTDIR must be absolute.\n' >&2
    exit 2
}
# valid_private_dir is an explicit predicate; failure is handled below.
# shellcheck disable=SC2310
valid_private_dir "${PRIVATE_DIR}" || {
    printf 'Error: invalid PRIVATE_DIR.\n' >&2
    exit 2
}
[[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Error: invalid version.\n' >&2
    exit 2
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR PROJECT_DIR
readonly PRIVATE_TARGET="${DESTDIR}${PRIVATE_DIR}"
readonly BIN_DIR="${DESTDIR}/usr/bin"
readonly APPLICATIONS_DIR="${DESTDIR}/usr/share/applications"
readonly ICON_DIR="${DESTDIR}/usr/share/icons/hicolor/scalable/apps"
readonly DOC_DIR="${DESTDIR}/usr/share/doc/${PACKAGE_NAME}"

for required_file in download-video.sh download-video-gui.sh progress-monitor.sh runtime-manager.sh \
    private-aria2-plan.py packaging/package-user-cleanup.sh \
    README.md README.fr.md CHANGELOG.md packaging/yt-dlp-aria2-downloader.desktop \
    packaging/icons/yt-dlp-aria2-downloader.svg packaging/keys/yt-dlp-public.key; do
    [[ -f ${PROJECT_DIR}/${required_file} ]] || {
        printf 'Error: required packaging input is absent: %s\n' "${required_file}" >&2
        exit 66
    }
done

install -d -m 0755 -- "${PRIVATE_TARGET}" "${BIN_DIR}" "${APPLICATIONS_DIR}" "${ICON_DIR}" "${DOC_DIR}"
install -m 0755 -- "${PROJECT_DIR}/download-video.sh" "${PROJECT_DIR}/download-video-gui.sh" \
    "${PROJECT_DIR}/progress-monitor.sh" "${PROJECT_DIR}/runtime-manager.sh" \
    "${PROJECT_DIR}/packaging/package-user-cleanup.sh" "${PRIVATE_TARGET}/"
install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
    "${PRIVATE_TARGET}/private-aria2-plan.py"
install -d -m 0755 -- "${PRIVATE_TARGET}/keys"
install -m 0644 -- "${PROJECT_DIR}/packaging/keys/yt-dlp-public.key" \
    "${PRIVATE_TARGET}/keys/yt-dlp-public.key"
install -m 0644 -- "${PROJECT_DIR}/README.md" "${PROJECT_DIR}/README.fr.md" \
    "${PROJECT_DIR}/CHANGELOG.md" "${DOC_DIR}/"
install -m 0644 -- "${PROJECT_DIR}/packaging/yt-dlp-aria2-downloader.desktop" \
    "${APPLICATIONS_DIR}/yt-dlp-aria2-downloader.desktop"
install -m 0644 -- "${PROJECT_DIR}/packaging/icons/yt-dlp-aria2-downloader.svg" \
    "${ICON_DIR}/yt-dlp-aria2-downloader.svg"

relative_private="../${PRIVATE_DIR#/usr/}"
ln -s -- "${relative_private}/download-video.sh" "${BIN_DIR}/yt-dlp-aria2-downloader"
ln -s -- "${relative_private}/download-video-gui.sh" "${BIN_DIR}/yt-dlp-aria2-downloader-gui"
printf 'Installed package tree for version %s under %s\n' "${VERSION}" "${DESTDIR}"
