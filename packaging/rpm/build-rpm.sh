#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/rpm/build-rpm.sh
# Purpose     : Build the Fedora RPM package.
# ==============================================================================

set -Eeuo pipefail
umask 022

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'

work_dir=''

cleanup() {
    if [[ -n ${work_dir} ]]; then
        rm -rf -- "${work_dir}"
    fi
}

parse_rpm_build_arguments() {
    if (($# < 1 || $# > 2)); then
        printf 'Usage: %s VERSION [OUTPUT_DIR]\n' "${0##*/}" >&2
        exit 2
    fi

    readonly VERSION=$1
    readonly OUTPUT_DIR=${2:-dist}
    [[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
        exit 2
    }
}

require_rpm_build_commands() {
    local command_name=''

    for command_name in \
        basename cp cpio desktop-file-validate dirname find git gzip mkdir \
        mktemp realpath rm rpm rpm2cpio rpmbuild; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' \
                "${command_name}" >&2
            exit 127
        }
    done
}

initialize_rpm_build_paths() {
    local script_parent=''

    script_parent=$(dirname -- "${BASH_SOURCE[0]}")
    SCRIPT_DIR=$(cd -- "${script_parent}" && pwd -P)
    readonly SCRIPT_DIR
    PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
    readonly PROJECT_DIR
}

validate_rpm_source_tree() {
    local source_status=''
    local source_version_output=''
    local source_version=''

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
}

initialize_rpm_output_directory() {
    mkdir -p -- "${OUTPUT_DIR}"
    RESOLVED_OUTPUT_DIR=$(realpath -m -- "${OUTPUT_DIR}")
    readonly RESOLVED_OUTPUT_DIR
}

initialize_rpm_workspace() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    work_dir=$(mktemp -d)
    readonly work_dir
}

prepare_rpmbuild_tree() {
    local output_variable=$1
    local prepared_topdir="${work_dir}/rpmbuild"

    mkdir -p -- \
        "${prepared_topdir}/BUILD" "${prepared_topdir}/BUILDROOT" \
        "${prepared_topdir}/RPMS" "${prepared_topdir}/SOURCES" \
        "${prepared_topdir}/SPECS" "${prepared_topdir}/SRPMS"
    printf -v "${output_variable}" '%s' "${prepared_topdir}"
}

build_rpm_payload() {
    local topdir=$1

    git -C "${PROJECT_DIR}" archive \
        --format=tar.gz \
        --prefix="${PACKAGE_NAME}-${VERSION}/" \
        --output="${topdir}/SOURCES/${PACKAGE_NAME}-${VERSION}.tar.gz" \
        HEAD
    cp -- "${PROJECT_DIR}/packaging/rpm/${PACKAGE_NAME}.spec" \
        "${topdir}/SPECS/"

    rpmbuild -bb \
        --define "_topdir ${topdir}" \
        --define "_rpmformat 4" \
        --define "project_version ${VERSION}" \
        "${topdir}/SPECS/${PACKAGE_NAME}.spec"
}

publish_rpm_artifact() {
    local topdir=$1
    local output_variable=$2
    local rpm_list_file="${work_dir}/rpm-files"
    local rpm_name=''
    local published_rpm=''
    local -a rpm_files=()

    find "${topdir}/RPMS" -type f -name '*.rpm' -print >"${rpm_list_file}"
    mapfile -t rpm_files <"${rpm_list_file}"
    ((${#rpm_files[@]} == 1)) || {
        printf 'Error: expected one RPM, found %d.\n' \
            "${#rpm_files[@]}" >&2
        exit 65
    }
    rpm_name=$(basename -- "${rpm_files[0]}")
    published_rpm="${RESOLVED_OUTPUT_DIR}/${rpm_name}"
    cp -- "${rpm_files[0]}" "${published_rpm}"
    printf -v "${output_variable}" '%s' "${published_rpm}"
}

validate_rpm_artifact() {
    local rpm_path=$1
    local package_format=''
    local extracted="${work_dir}/extracted"
    local packaged_version=''

    if ! package_format=$(
        LC_ALL=C rpm -qp --qf '%{rpmformat}\n' -- "${rpm_path}"
    ); then
        printf 'Error: unable to determine the generated RPM package format.\n' >&2
        exit 65
    fi

    if [[ ${package_format} != 4 ]]; then
        printf 'Error: generated RPM uses unexpected package format: %s\n' \
            "${package_format}" >&2
        printf 'Expected RPM package format: 4\n' >&2
        exit 65
    fi

    rpm -qpi -- "${rpm_path}"
    rpm -qpl -- "${rpm_path}"
    rpm -qpR -- "${rpm_path}"

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
}

main() {
    local topdir=''
    local rpm_path=''

    parse_rpm_build_arguments "$@"
    require_rpm_build_commands
    initialize_rpm_build_paths
    validate_rpm_source_tree
    initialize_rpm_output_directory
    initialize_rpm_workspace
    prepare_rpmbuild_tree topdir
    build_rpm_payload "${topdir}"
    publish_rpm_artifact "${topdir}" rpm_path
    validate_rpm_artifact "${rpm_path}"
}

main "$@"
