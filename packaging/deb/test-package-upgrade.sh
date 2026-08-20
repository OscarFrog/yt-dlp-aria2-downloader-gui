#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
umask 077

if (($# != 4)); then
    printf 'Usage: %s OLD.deb NEW.deb OLD_VERSION NEW_VERSION\n' "${0##*/}" >&2
    exit 2
fi
readonly OLD_INPUT=$1 NEW_INPUT=$2 OLD_VERSION=$3 NEW_VERSION=$4
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
for version in "${OLD_VERSION}" "${NEW_VERSION}"; do
    [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Error: invalid package version: %s\n' "${version}" >&2
        exit 2
    }
done
((EUID == 0)) || { printf 'Error: DEB upgrade test must run as root.\n' >&2; exit 77; }
for command_name in apt-get dpkg-query grep realpath; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done
old_package=$(realpath -e -- "${OLD_INPUT}")
new_package=$(realpath -e -- "${NEW_INPUT}")
[[ ${old_package} == *.deb && ${new_package} == *.deb ]] || exit 2
if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null |
    grep -Fqx -- 'install ok installed'; then
    printf 'Error: %s must not be installed before the upgrade test.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi
installed=false
cleanup() {
    if [[ ${installed} == true ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove --yes \
            "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

DEBIAN_FRONTEND=noninteractive apt-get install --yes "${old_package}"
installed=true
old_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${old_version_output} == \
    "yt-dlp-aria2-downloader version ${OLD_VERSION}" ]]
DEBIAN_FRONTEND=noninteractive apt-get install --yes "${new_package}"
new_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${new_version_output} == \
    "yt-dlp-aria2-downloader version ${NEW_VERSION}" ]]
[[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]]
[[ -x /usr/lib/yt-dlp-aria2-downloader/runtime-manager.sh ]]
DEBIAN_FRONTEND=noninteractive apt-get remove --yes "${PACKAGE_NAME}"
installed=false
status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null || true)
[[ ${status} != 'install ok installed' ]]
for path in "/usr/lib/yt-dlp-aria2-downloader" "/usr/share/doc/${PACKAGE_NAME}"; do
    [[ ! -e ${path} && ! -L ${path} ]] || {
        printf 'Error: DEB upgrade/removal left a private path: %s\n' "${path}" >&2
        exit 65
    }
done
printf 'DEB upgrade passed: %s -> %s.\n' "${OLD_VERSION}" "${NEW_VERSION}"
