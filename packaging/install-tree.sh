#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 022

usage() {
    printf 'Usage: %s DESTDIR VERSION PRIVATE_DIR\n' "${0##*/}" >&2
}

if (($# != 3)); then
    usage
    exit 2
fi

readonly DESTDIR=$1
readonly VERSION=$2
readonly PRIVATE_DIR=$3
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'

[[ ${DESTDIR} == /* ]] || {
    printf 'Error: DESTDIR must be absolute: %s\n' "${DESTDIR}" >&2
    exit 2
}
[[ ${PRIVATE_DIR} == /usr/* && ${PRIVATE_DIR} != */../* ]] || {
    printf 'Error: PRIVATE_DIR must be an absolute path below /usr: %s\n' \
        "${PRIVATE_DIR}" >&2
    exit 2
}
[[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
    exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly project_dir

readonly private_target="${DESTDIR}${PRIVATE_DIR}"
readonly bin_dir="${DESTDIR}/usr/bin"
readonly applications_dir="${DESTDIR}/usr/share/applications"
readonly doc_dir="${DESTDIR}/usr/share/doc/${PACKAGE_NAME}"

for required_file in \
    download-video.sh download-video-gui.sh progress-monitor.sh \
    README.md README.fr.md CHANGELOG.md \
    packaging/yt-dlp-aria2-downloader.desktop; do
    [[ -f ${project_dir}/${required_file} ]] || {
        printf 'Error: required packaging input is absent: %s\n' \
            "${required_file}" >&2
        exit 66
    }
done

install -d -m 0755 -- \
    "${private_target}" "${bin_dir}" "${applications_dir}" "${doc_dir}"
install -m 0755 -- \
    "${project_dir}/download-video.sh" \
    "${project_dir}/download-video-gui.sh" \
    "${project_dir}/progress-monitor.sh" \
    "${private_target}/"
install -m 0644 -- \
    "${project_dir}/README.md" \
    "${project_dir}/README.fr.md" \
    "${project_dir}/CHANGELOG.md" \
    "${doc_dir}/"
install -m 0644 -- \
    "${project_dir}/packaging/yt-dlp-aria2-downloader.desktop" \
    "${applications_dir}/yt-dlp-aria2-downloader.desktop"

relative_private="../${PRIVATE_DIR#/usr/}"
ln -s -- \
    "${relative_private}/download-video.sh" \
    "${bin_dir}/yt-dlp-aria2-downloader"
ln -s -- \
    "${relative_private}/download-video-gui.sh" \
    "${bin_dir}/yt-dlp-aria2-downloader-gui"

printf 'Installed package tree for version %s under %s\n' \
    "${VERSION}" "${DESTDIR}"
