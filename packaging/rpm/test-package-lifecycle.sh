#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/rpm/test-package-lifecycle.sh
# Purpose     : Validate RPM package installation and removal behavior.
# ==============================================================================

set -Eeuo pipefail
umask 077

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly PRIVATE_DIR='/usr/libexec/yt-dlp-aria2-downloader'

WORK_DIR=''
package_installed=false
package_files=()

cleanup() {
    if [[ ${package_installed} == true ]]; then
        dnf remove --assumeyes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    if [[ -n ${WORK_DIR} ]]; then
        rm -rf -- "${WORK_DIR}" || true
    fi
}

parse_rpm_lifecycle_arguments() {
    if (($# != 2)); then
        printf 'Usage: %s PACKAGE.rpm VERSION\n' "${0##*/}" >&2
        exit 2
    fi

    readonly PACKAGE_INPUT=$1
    readonly VERSION=$2
    [[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
        exit 2
    }
}

require_rpm_lifecycle_environment() {
    local command_name=''

    ((EUID == 0)) || {
        printf 'Error: the RPM lifecycle test must run as root.\n' >&2
        exit 77
    }
    for command_name in \
        cpio desktop-file-validate dirname dnf find grep mkdir mktemp \
        realpath rm rpm rpm2cpio sort; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' \
                "${command_name}" >&2
            exit 127
        }
    done
}

initialize_rpm_lifecycle_paths() {
    local script_parent=''

    if ! PACKAGE_PATH=$(realpath -e -- "${PACKAGE_INPUT}"); then
        printf 'Error: unable to resolve RPM package: %s\n' \
            "${PACKAGE_INPUT}" >&2
        exit 2
    fi
    readonly PACKAGE_PATH
    [[ -f ${PACKAGE_PATH} && ${PACKAGE_PATH} == *.rpm ]] || {
        printf 'Error: not a regular RPM package: %s\n' "${PACKAGE_PATH}" >&2
        exit 2
    }

    script_parent=$(dirname -- "${BASH_SOURCE[0]}")
    SCRIPT_DIR=$(cd -- "${script_parent}" && pwd -P)
    readonly SCRIPT_DIR
    PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
    readonly PROJECT_DIR
    # shellcheck source=tests/lib/package-lifecycle.sh
    source "${PROJECT_DIR}/tests/lib/package-lifecycle.sh"
}

validate_rpm_dependencies() {
    local package_requires=''
    local required_dependency=''

    package_requires=$(rpm -qpR -- "${PACKAGE_PATH}")
    for required_dependency in \
        'aria2 >= 1.37.0' \
        'python3 >= 3.10' \
        'ffmpeg' \
        'curl' \
        'gnupg2' \
        'unzip'; do
        if ! grep -Fqx -- "${required_dependency}" <<<"${package_requires}"; then
            printf 'Error: RPM dependency is missing or too weak: %s\n' \
                "${required_dependency}" >&2
            exit 65
        fi
    done
}

validate_rpm_initial_state() {
    if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
        printf 'Error: %s is already installed.\n' "${PACKAGE_NAME}" >&2
        exit 65
    fi
}

initialize_rpm_lifecycle_workspace() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    WORK_DIR=$(mktemp -d)
    readonly WORK_DIR
}

inspect_rpm_payload() {
    local package_list_file="${WORK_DIR}/package-files"

    mkdir -p -- "${WORK_DIR}/root"
    (
        cd -- "${WORK_DIR}/root"
        rpm2cpio "${PACKAGE_PATH}" | cpio -idm --quiet
    )
    find "${WORK_DIR}/root" \
        \( -type f -o -type l \) \
        -printf '/%P\n' | LC_ALL=C sort >"${package_list_file}"
    mapfile -t package_files <"${package_list_file}"
    ((${#package_files[@]} > 0)) || {
        printf 'Error: the RPM payload contains no files.\n' >&2
        exit 65
    }
}

assert_installed_rpm() {
    local stage=$1

    if ! rpm -q "${PACKAGE_NAME}" >/dev/null; then
        printf 'Error: RPM is not installed during %s.\n' "${stage}" >&2
        return 65
    fi
    assert_package_cli_version RPM "${VERSION}" "${stage}"
}

assert_rpm_private_payload() {
    assert_common_package_payload RPM
    [[ -x ${PRIVATE_DIR}/runtime-manager.sh ]] || {
        printf 'Error: packaged RPM runtime manager is absent.\n' >&2
        return 65
    }
    [[ -f ${PRIVATE_DIR}/keys/yt-dlp-public.key &&
        ! -L ${PRIVATE_DIR}/keys/yt-dlp-public.key ]] || {
        printf 'Error: packaged RPM signing key is absent or unsafe.\n' >&2
        return 65
    }
}

assert_rpm_payload_absent() {
    local stage=$1

    assert_package_paths_absent RPM "${stage}" \
        "${package_files[@]}" \
        "${PRIVATE_DIR}" \
        "/usr/share/doc/${PACKAGE_NAME}" \
        "/usr/share/licenses/${PACKAGE_NAME}"
}

install_initial_rpm() {
    dnf install --assumeyes --allowerasing --nogpgcheck \
        --setopt=install_weak_deps=False \
        "${PACKAGE_PATH}"
    package_installed=true
    assert_installed_rpm 'initial installation'
    assert_rpm_private_payload
}

remove_rpm() {
    local stage=$1

    dnf remove --assumeyes "${PACKAGE_NAME}"
    package_installed=false
    if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
        printf 'Error: RPM remains installed after %s.\n' "${stage}" >&2
        exit 65
    fi
    assert_rpm_payload_absent "${stage}"
}

reinstall_and_remove_rpm() {
    dnf install --assumeyes --allowerasing --nogpgcheck \
        --setopt=install_weak_deps=False "${PACKAGE_PATH}"
    package_installed=true
    assert_installed_rpm 'reinstallation'
    remove_rpm 'reinstall/removal'
}

main() {
    parse_rpm_lifecycle_arguments "$@"
    require_rpm_lifecycle_environment
    initialize_rpm_lifecycle_paths
    validate_rpm_dependencies
    validate_rpm_initial_state
    initialize_rpm_lifecycle_workspace
    inspect_rpm_payload
    install_initial_rpm
    remove_rpm 'initial removal'
    reinstall_and_remove_rpm

    printf 'RPM lifecycle and reinstall passed for %s.\n' "${VERSION}"
}

main "$@"
