#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

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
    awk desktop-file-validate dpkg-deb du git install mktemp realpath stat; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
project_dir=$(cd -- "${script_dir}/../.." && pwd -P)
readonly project_dir
mkdir -p -- "${OUTPUT_DIR}"
output_dir=$(realpath -m -- "${OUTPUT_DIR}")
readonly output_dir

work_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "${work_dir}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

root="${work_dir}/root"
mkdir -p -- "${root}/DEBIAN"
bash "${project_dir}/packaging/install-tree.sh" \
    "${root}" "${VERSION}" '/usr/lib/yt-dlp-aria2-downloader'
install -m 0644 -- "${project_dir}/LICENSE" \
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
Depends: bash (>= 4.4), coreutils, grep, util-linux, aria2 (>= 1.37.0), ffmpeg, zenity
Recommends: yt-dlp
Suggests: deno, firefox | firefox-esr
Homepage: https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui
Description: Zenity interface and Bash engine for yt-dlp and aria2
 Download one complete MKV video, an authenticated YouTube HLS video, or the
 best native audio track with yt-dlp, aria2c, FFmpeg, and Zenity on GNU/Linux.
EOF_CONTROL
chmod 0644 -- "${root}/DEBIAN/control"

package_path="${output_dir}/${PACKAGE_NAME}_${VERSION}-${PACKAGE_REVISION}_all.deb"
rm -f -- "${package_path}"
source_date_epoch=${SOURCE_DATE_EPOCH:-}
if [[ -z ${source_date_epoch} ]]; then
    source_date_epoch=$(git -C "${project_dir}" show -s --format=%ct HEAD)
fi
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
engine_mode=$(stat -c '%a' -- \
    "${extracted}/usr/lib/yt-dlp-aria2-downloader/download-video.sh")
[[ ${engine_mode} == 755 ]]

printf 'DEB package created: %s\n' "${package_path}"
