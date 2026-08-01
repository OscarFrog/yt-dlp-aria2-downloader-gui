#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

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

for command_name in desktop-file-validate dnf grep realpath rpm; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

package_path=$(realpath -e -- "${PACKAGE_INPUT}")
readonly package_path
[[ ${package_path} == *.rpm ]] || {
    printf 'Error: not an RPM package: %s\n' "${package_path}" >&2
    exit 2
}

if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: %s is already installed.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi

package_installed=false
cleanup() {
    if [[ ${package_installed} == true ]]; then
        dnf remove --assumeyes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

dnf install --assumeyes --allowerasing --nogpgcheck \
    --setopt=install_weak_deps=False \
    "${package_path}"
package_installed=true

rpm -q "${PACKAGE_NAME}"
[[ -x /usr/bin/yt-dlp-aria2-downloader ]]
[[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]]
[[ -f ${DESKTOP_FILE} ]]
[[ -f ${ICON_FILE} ]]

desktop-file-validate --no-hints "${DESKTOP_FILE}"
grep -Fqx -- 'Icon=yt-dlp-aria2-downloader' "${DESKTOP_FILE}"
grep -Fqx -- \
    'Exec=/usr/bin/yt-dlp-aria2-downloader-gui' "${DESKTOP_FILE}"

installed_version=$(
    /usr/bin/yt-dlp-aria2-downloader --version
)
[[ ${installed_version} == \
    "yt-dlp-aria2-downloader version ${VERSION}" ]]

dnf remove --assumeyes "${PACKAGE_NAME}"
package_installed=false

if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: RPM remains installed after removal.\n' >&2
    exit 65
fi

for removed_path in \
    /usr/bin/yt-dlp-aria2-downloader \
    /usr/bin/yt-dlp-aria2-downloader-gui \
    "${DESKTOP_FILE}" \
    "${ICON_FILE}"; do
    [[ ! -e ${removed_path} && ! -L ${removed_path} ]] || {
        printf 'Error: package removal left a file behind: %s\n' \
            "${removed_path}" >&2
        exit 65
    }
done

printf 'RPM install/remove lifecycle passed for version %s.\n' "${VERSION}"
