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

[[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
    exit 2
}

for command_name in \
    basename cp cpio desktop-file-validate find git gzip mkdir mktemp \
    realpath rm rpm rpm2cpio rpmbuild; do
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

topdir="${work_dir}/rpmbuild"
mkdir -p -- \
    "${topdir}/BUILD" "${topdir}/BUILDROOT" "${topdir}/RPMS" \
    "${topdir}/SOURCES" "${topdir}/SPECS" "${topdir}/SRPMS"

git -C "${project_dir}" archive \
    --format=tar.gz \
    --prefix="${PACKAGE_NAME}-${VERSION}/" \
    --output="${topdir}/SOURCES/${PACKAGE_NAME}-${VERSION}.tar.gz" \
    HEAD
cp -- "${project_dir}/packaging/rpm/${PACKAGE_NAME}.spec" \
    "${topdir}/SPECS/"

rpmbuild -bb \
    --define "_topdir ${topdir}" \
    --define "project_version ${VERSION}" \
    "${topdir}/SPECS/${PACKAGE_NAME}.spec"

rpm_list_file="${work_dir}/rpm-files"
find "${topdir}/RPMS" -type f -name '*.rpm' -print >"${rpm_list_file}"
mapfile -t rpm_files <"${rpm_list_file}"
((${#rpm_files[@]} == 1)) || {
    printf 'Error: expected one RPM, found %d.\n' "${#rpm_files[@]}" >&2
    exit 65
}
rpm_path="${output_dir}/$(basename -- "${rpm_files[0]}")"
cp -- "${rpm_files[0]}" "${rpm_path}"

rpm -qpi -- "${rpm_path}"
rpm -qpl -- "${rpm_path}"
rpm -qpR -- "${rpm_path}"

extracted="${work_dir}/extracted"
mkdir -p -- "${extracted}"
(
    cd -- "${extracted}"
    rpm2cpio "${rpm_path}" | cpio -idm --quiet
)
packaged_version=$(
    "${extracted}/usr/bin/yt-dlp-aria2-downloader" --version
)
[[ ${packaged_version} == "yt-dlp-aria2-downloader version ${VERSION}" ]]
desktop-file-validate --no-hints \
    "${extracted}/usr/share/applications/yt-dlp-aria2-downloader.desktop"
[[ -f ${extracted}/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]]

printf 'RPM package created: %s\n' "${rpm_path}"
