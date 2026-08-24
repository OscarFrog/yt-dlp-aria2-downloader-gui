#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/deb/build-deb.sh
# Purpose     : Build the architecture-independent Debian package.
# ==============================================================================

set -Eeuo pipefail
umask 022

if (($# < 1 || $# > 2)); then
    printf 'Usage: %s VERSION [OUTPUT_DIR]\n' "${0##*/}" >&2
    exit 2
fi

readonly VERSION=$1
readonly OUTPUT_DIR=${2:-dist}
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly PACKAGE_REVISION='1'

[[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
    exit 2
}

for command_name in \
    awk bash cat chmod date desktop-file-validate dirname dpkg-deb du git \
    install mkdir mktemp realpath rm stat; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' \
            "${command_name}" >&2
        exit 127
    }
done

script_parent=$(dirname -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "${script_parent}" && pwd -P)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly PROJECT_DIR

source_status=''
if ! source_status=$(
    git -C "${PROJECT_DIR}" status --porcelain=v1 --untracked-files=normal
); then
    printf 'Error: unable to inspect the package source worktree.\n' >&2
    exit 65
fi
if [[ -n ${source_status} ]]; then
    printf '%s\n' \
        'Error: package sources contain uncommitted changes.' >&2
    printf '%s\n' \
        'Commit the intended release changes before building a package.' >&2
    exit 65
fi

source_version_output=''
if ! source_version_output=$("${PROJECT_DIR}/download-video.sh" --version); then
    printf 'Error: unable to read the source-tree version.\n' >&2
    exit 65
fi
source_version=${source_version_output##* }
if [[ ${source_version} != "${VERSION}" ]]; then
    printf 'Error: source version does not match requested package version.\n' >&2
    printf 'Source:    %s\n' "${source_version_output}" >&2
    printf 'Requested: %s\n' "${VERSION}" >&2
    exit 65
fi

mkdir -p -- "${OUTPUT_DIR}"
RESOLVED_OUTPUT_DIR=$(realpath -m -- "${OUTPUT_DIR}")
readonly RESOLVED_OUTPUT_DIR

work_dir=$(mktemp -d)

cleanup() {
    rm -rf -- "${work_dir}"
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    root="${work_dir}/root"
    mkdir -p -- "${root}/DEBIAN"
    bash "${PROJECT_DIR}/packaging/install-tree.sh" \
        "${root}" "${VERSION}" '/usr/lib/yt-dlp-aria2-downloader'
    install -m 0644 -- "${PROJECT_DIR}/LICENSE" \
        "${root}/usr/share/doc/${PACKAGE_NAME}/copyright"

    installed_size=$(du -sk -- "${root}/usr" | awk '{print $1}')
    cat >"${root}/DEBIAN/control" <<EOF_CONTROL
Package: ${PACKAGE_NAME}
Version: ${VERSION}-${PACKAGE_REVISION}
Section: utils
Priority: optional
Architecture: all
Maintainer: OscarFrog <151366285+OscarFrog@users.noreply.github.com>
Installed-Size: ${installed_size}
Depends: bash (>= 4.4), coreutils, curl, findutils, grep, sed, util-linux, aria2 (>= 1.37.0), python3 (>= 3.10), ffmpeg, gnupg, unzip, zenity, hicolor-icon-theme
Suggests: firefox | firefox-esr
Homepage: https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui
Description: Zenity interface and Bash engine for yt-dlp and aria2
 Download one complete MKV video or the best native audio track with managed
 verified yt-dlp and Deno runtimes, aria2c, FFmpeg, and Zenity on GNU/Linux.
EOF_CONTROL
    chmod 0644 -- "${root}/DEBIAN/control"

    for maintainer_script in postinst prerm postrm; do
        install -m 0755 -- \
            "${PROJECT_DIR}/packaging/deb/${maintainer_script}" \
            "${root}/DEBIAN/${maintainer_script}"
    done

    package_path="${RESOLVED_OUTPUT_DIR}/${PACKAGE_NAME}_${VERSION}-${PACKAGE_REVISION}_all.deb"
    rm -f -- "${package_path}"

    source_date_epoch=${SOURCE_DATE_EPOCH:-}
    if [[ -z ${source_date_epoch} ]]; then
        source_date_epoch=$(git -C "${PROJECT_DIR}" show -s --format=%ct HEAD)
    fi
    [[ ${source_date_epoch} =~ ^[0-9]+$ ]] || {
        printf 'Error: invalid SOURCE_DATE_EPOCH: %s\n' \
            "${source_date_epoch}" >&2
        exit 65
    }
    readonly source_date_epoch

    SOURCE_DATE_EPOCH=${source_date_epoch} \
        dpkg-deb --root-owner-group --build "${root}" "${package_path}"

    dpkg-deb --info "${package_path}"
    dpkg-deb --contents "${package_path}"

    extracted="${work_dir}/extracted"
    dpkg-deb --extract "${package_path}" "${extracted}"
    packaged_version=$(
        "${extracted}/usr/bin/yt-dlp-aria2-downloader" --version
    )
    [[ ${packaged_version} == "yt-dlp-aria2-downloader version ${VERSION}" ]]
    desktop-file-validate --no-hints \
        "${extracted}/usr/share/applications/yt-dlp-aria2-downloader.desktop"
    [[ -f ${extracted}/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]]
    [[ -x ${extracted}/usr/lib/yt-dlp-aria2-downloader/runtime-manager.sh ]]
    [[ -x ${extracted}/usr/lib/yt-dlp-aria2-downloader/package-user-cleanup.sh ]]
    [[ -f ${extracted}/usr/lib/yt-dlp-aria2-downloader/keys/yt-dlp-public.key ]]
    engine_mode=$(stat -c '%a' -- \
        "${extracted}/usr/lib/yt-dlp-aria2-downloader/download-video.sh")
    [[ ${engine_mode} == 755 ]]

    printf 'DEB package created: %s\n' "${package_path}"

}

main "$@"
