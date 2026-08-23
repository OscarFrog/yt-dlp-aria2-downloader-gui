#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/rpm/test-package-lifecycle.sh
# Purpose     : Validate RPM package installation and removal behavior.
# ==============================================================================

set -Eeuo pipefail
umask 077

if (($# != 2)); then
    printf 'Usage: %s PACKAGE.rpm VERSION\n' "${0##*/}" >&2
    exit 2
fi

readonly PACKAGE_INPUT=$1
readonly VERSION=$2
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly DESKTOP_FILE='/usr/share/applications/yt-dlp-aria2-downloader.desktop'
readonly ICON_FILE='/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg'

[[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
    exit 2
}
((EUID == 0)) || {
    printf 'Error: the RPM lifecycle test must run as root.\n' >&2
    exit 77
}

for command_name in \
    cpio desktop-file-validate dnf find grep mktemp realpath rm \
    rpm rpm2cpio sort; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

PACKAGE_PATH=$(realpath -e -- "${PACKAGE_INPUT}")
readonly PACKAGE_PATH
[[ ${PACKAGE_PATH} == *.rpm ]] || {
    printf 'Error: not an RPM package: %s\n' "${PACKAGE_PATH}" >&2
    exit 2
}

package_requires=$(rpm -qpR -- "${PACKAGE_PATH}")
for required_dependency in \
    'aria2 >= 1.37.0' \
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

if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: %s is already installed.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi

WORK_DIR=$(mktemp -d)
readonly WORK_DIR
package_installed=false

cleanup() {
    if [[ ${package_installed} == true ]]; then
        dnf remove --assumeyes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${WORK_DIR}" || true
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mkdir -p -- "${WORK_DIR}/root"
    (
        cd -- "${WORK_DIR}/root"
        rpm2cpio "${PACKAGE_PATH}" | cpio -idm --quiet
    )
    package_list_file="${WORK_DIR}/package-files"
    find "${WORK_DIR}/root" \
        \( -type f -o -type l \) \
        -printf '/%P\n' | LC_ALL=C sort >"${package_list_file}"
    mapfile -t package_files <"${package_list_file}"
    ((${#package_files[@]} > 0)) || {
        printf 'Error: the RPM payload contains no files.\n' >&2
        exit 65
    }

    dnf install --assumeyes --allowerasing --nogpgcheck \
        --setopt=install_weak_deps=False \
        "${PACKAGE_PATH}"
    package_installed=true

    rpm -q "${PACKAGE_NAME}"
    installed_version=$(
        /usr/bin/yt-dlp-aria2-downloader --version
    )
    [[ ${installed_version} == "yt-dlp-aria2-downloader version ${VERSION}" ]]
    [[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]]
    [[ -f ${DESKTOP_FILE} && ! -L ${DESKTOP_FILE} ]]
    [[ -f ${ICON_FILE} && ! -L ${ICON_FILE} ]]
    desktop-file-validate --no-hints "${DESKTOP_FILE}"
    grep -Fqx -- 'Icon=yt-dlp-aria2-downloader' "${DESKTOP_FILE}"
    for runtime_command in aria2c ffmpeg ffprobe curl gpg unzip flock timeout; do
        command -v "${runtime_command}" >/dev/null 2>&1 || {
            printf 'Error: package dependency command is absent: %s\n' \
                "${runtime_command}" >&2
            exit 65
        }
    done
    [[ -x /usr/libexec/yt-dlp-aria2-downloader/runtime-manager.sh ]] || {
        printf 'Error: packaged runtime manager is absent.
    ' >&2
        exit 65
    }
    [[ -f /usr/libexec/yt-dlp-aria2-downloader/keys/yt-dlp-public.key &&
        ! -L /usr/libexec/yt-dlp-aria2-downloader/keys/yt-dlp-public.key ]] || {
        printf 'Error: packaged yt-dlp signing key is absent or unsafe.
    ' >&2
        exit 65
    }

    dnf remove --assumeyes "${PACKAGE_NAME}"
    package_installed=false

    if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
        printf 'Error: RPM remains installed after removal.\n' >&2
        exit 65
    fi
    for path in "${package_files[@]}"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: package removal left a file: %s\n' "${path}" >&2
            exit 65
        }
    done
    for private_path in \
        /usr/libexec/yt-dlp-aria2-downloader \
        "/usr/share/doc/${PACKAGE_NAME}" \
        "/usr/share/licenses/${PACKAGE_NAME}"; do
        [[ ! -e ${private_path} && ! -L ${private_path} ]] || {
            printf 'Error: package removal left a private path: %s\n' \
                "${private_path}" >&2
            exit 65
        }
    done

    # Reinstall the exact same RPM after complete removal to verify that no stale
    # package state prevents a deterministic second lifecycle.
    dnf install --assumeyes --allowerasing --nogpgcheck \
        --setopt=install_weak_deps=False "${PACKAGE_PATH}"
    package_installed=true
    installed_version=$(/usr/bin/yt-dlp-aria2-downloader --version)
    [[ ${installed_version} == "yt-dlp-aria2-downloader version ${VERSION}" ]]
    dnf remove --assumeyes "${PACKAGE_NAME}"
    package_installed=false
    for path in "${package_files[@]}"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: RPM reinstall/removal left a file: %s\n' "${path}" >&2
            exit 65
        }
    done
    for private_path in \
        /usr/libexec/yt-dlp-aria2-downloader \
        "/usr/share/doc/${PACKAGE_NAME}" \
        "/usr/share/licenses/${PACKAGE_NAME}"; do
        [[ ! -e ${private_path} && ! -L ${private_path} ]] || {
            printf 'Error: RPM reinstall/removal left a private path: %s\n' "${private_path}" >&2
            exit 65
        }
    done

    printf 'RPM lifecycle and reinstall passed for %s.\n' "${VERSION}"

}

main "$@"
