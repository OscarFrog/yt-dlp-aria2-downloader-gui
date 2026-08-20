#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
umask 077

if (($# != 4)); then
    printf 'Usage: %s OLD.rpm NEW.rpm OLD_VERSION NEW_VERSION\n' "${0##*/}" >&2
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
((EUID == 0)) || { printf 'Error: RPM upgrade test must run as root.\n' >&2; exit 77; }
for command_name in dnf realpath rpm; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done
old_package=$(realpath -e -- "${OLD_INPUT}")
new_package=$(realpath -e -- "${NEW_INPUT}")
[[ ${old_package} == *.rpm && ${new_package} == *.rpm ]] || exit 2
if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: %s must not be installed before the upgrade test.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi
installed=false
cleanup() {
    if [[ ${installed} == true ]]; then
        dnf remove --assumeyes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

dnf install --assumeyes --allowerasing --nogpgcheck \
    --setopt=install_weak_deps=False "${old_package}"
installed=true
old_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${old_version_output} == \
    "yt-dlp-aria2-downloader version ${OLD_VERSION}" ]]

dnf install --assumeyes --allowerasing --nogpgcheck \
    --setopt=install_weak_deps=False "${new_package}"
new_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${new_version_output} == \
    "yt-dlp-aria2-downloader version ${NEW_VERSION}" ]]
[[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]]
[[ -x /usr/libexec/yt-dlp-aria2-downloader/runtime-manager.sh ]]

dnf remove --assumeyes "${PACKAGE_NAME}"
installed=false
if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: RPM remains installed after upgrade/removal.\n' >&2
    exit 65
fi
for path in \
    /usr/libexec/yt-dlp-aria2-downloader \
    "/usr/share/doc/${PACKAGE_NAME}" \
    "/usr/share/licenses/${PACKAGE_NAME}"; do
    [[ ! -e ${path} && ! -L ${path} ]] || {
        printf 'Error: RPM upgrade/removal left a private path: %s\n' "${path}" >&2
        exit 65
    }
done
printf 'RPM upgrade passed: %s -> %s.\n' "${OLD_VERSION}" "${NEW_VERSION}"
