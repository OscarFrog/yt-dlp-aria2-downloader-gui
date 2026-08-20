#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

if (($# != 2)); then
    printf 'Usage: %s PACKAGE.deb VERSION\n' "${0##*/}" >&2
    exit 2
fi

readonly PACKAGE_INPUT=$1
readonly VERSION=$2
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly DESKTOP_FILE='/usr/share/applications/yt-dlp-aria2-downloader.desktop'
readonly ICON_FILE='/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg'
readonly PRIVATE_DIR='/usr/lib/yt-dlp-aria2-downloader'

[[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
    exit 2
}
((EUID == 0)) || {
    printf 'Error: the DEB lifecycle test must run as root.\n' >&2
    exit 77
}

for command_name in \
    apt-get desktop-file-validate dpkg dpkg-deb dpkg-query find grep \
    mktemp realpath rm sort; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

package_path=$(realpath -e -- "${PACKAGE_INPUT}")
readonly package_path
[[ ${package_path} == *.deb ]] || {
    printf 'Error: not a DEB package: %s\n' "${package_path}" >&2
    exit 2
}

package_depends=$(dpkg-deb --field "${package_path}" Depends)
for required_dependency in \
    'aria2 (>= 1.37.0)' \
    'ffmpeg' \
    'curl' \
    'gnupg' \
    'unzip'; do
    if [[ ${package_depends} != *"${required_dependency}"* ]]; then
        printf 'Error: DEB dependency is missing or too weak: %s\n' \
            "${required_dependency}" >&2
        exit 65
    fi
done
if [[ ${package_depends} == *'yt-dlp'* || ${package_depends} == *'deno'* ]]; then
    printf 'Error: DEB must use managed yt-dlp and Deno runtimes, not system package dependencies.\n' >&2
    exit 65
fi

if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null |
    grep -Fqx -- 'install ok installed'; then
    printf 'Error: %s is already installed.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi

work_dir=$(mktemp -d)
readonly work_dir
package_installed=false
cleanup() {
    if [[ ${package_installed} == true ]]; then
        DEBIAN_FRONTEND=noninteractive \
            apt-get remove --yes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${work_dir}" || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

dpkg-deb --extract "${package_path}" "${work_dir}/root"
package_list_file="${work_dir}/package-files"
find "${work_dir}/root" \
    \( -type f -o -type l \) \
    -printf '/%P\n' | LC_ALL=C sort >"${package_list_file}"
mapfile -t package_files <"${package_list_file}"
((${#package_files[@]} > 0)) || {
    printf 'Error: the DEB payload contains no files.\n' >&2
    exit 65
}

DEBIAN_FRONTEND=noninteractive \
    apt-get install --yes "${package_path}"
package_installed=true

installed_status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}")
[[ ${installed_status} == 'install ok installed' ]]
installed_version=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${installed_version} == \
    "yt-dlp-aria2-downloader version ${VERSION}" ]]
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
[[ -x ${PRIVATE_DIR}/runtime-manager.sh ]] || {
    printf 'Error: packaged runtime manager is absent.\n' >&2
    exit 65
}
[[ -f ${PRIVATE_DIR}/keys/yt-dlp-public.key && ! -L ${PRIVATE_DIR}/keys/yt-dlp-public.key ]] || {
    printf 'Error: packaged yt-dlp public key is absent or unsafe.\n' >&2
    exit 65
}

aria2_package_version=$(dpkg-query -W -f='${Version}' aria2)
if ! dpkg --compare-versions "${aria2_package_version}" ge '1.37.0'; then
    printf 'Error: installed aria2 package is too old: %s\n' \
        "${aria2_package_version}" >&2
    exit 65
fi

DEBIAN_FRONTEND=noninteractive \
    apt-get remove --yes "${PACKAGE_NAME}"
package_installed=false

remaining_status=''
if remaining_status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null); then
    [[ ${remaining_status} != 'install ok installed' ]] || {
        printf 'Error: DEB remains installed after removal.\n' >&2
        exit 65
    }
fi

for path in "${package_files[@]}"; do
    [[ ! -e ${path} && ! -L ${path} ]] || {
        printf 'Error: package removal left a file: %s\n' "${path}" >&2
        exit 65
    }
done
for private_path in \
    "${PRIVATE_DIR}" \
    "/usr/share/doc/${PACKAGE_NAME}"; do
    [[ ! -e ${private_path} && ! -L ${private_path} ]] || {
        printf 'Error: package removal left a private path: %s\n' \
            "${private_path}" >&2
        exit 65
    }
done

printf 'DEB lifecycle passed for %s.\n' "${VERSION}"
