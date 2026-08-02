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

for command_name in \
    cpio desktop-file-validate dnf find grep mktemp realpath rm \
    rpm rpm2cpio sort; do
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

work_dir=$(mktemp -d)
readonly work_dir
package_installed=false
cleanup() {
    if [[ ${package_installed} == true ]]; then
        dnf remove --assumeyes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${work_dir}" || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "${work_dir}/root"
(
    cd -- "${work_dir}/root"
    rpm2cpio "${package_path}" | cpio -idm --quiet
)
package_list_file="${work_dir}/package-files"
find "${work_dir}/root" \
    \( -type f -o -type l \) \
    -printf '/%P\n' | LC_ALL=C sort >"${package_list_file}"
mapfile -t package_files <"${package_list_file}"
((${#package_files[@]} > 0)) || {
    printf 'Error: the RPM payload contains no files.\n' >&2
    exit 65
}

dnf install --assumeyes --allowerasing --nogpgcheck \
    --setopt=install_weak_deps=False \
    "${package_path}"
package_installed=true

rpm -q "${PACKAGE_NAME}"
installed_version=$(
    /usr/bin/yt-dlp-aria2-downloader --version
)
[[ ${installed_version} == \
    "yt-dlp-aria2-downloader version ${VERSION}" ]]
[[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]]
[[ -f ${DESKTOP_FILE} && ! -L ${DESKTOP_FILE} ]]
[[ -f ${ICON_FILE} && ! -L ${ICON_FILE} ]]
desktop-file-validate --no-hints "${DESKTOP_FILE}"
grep -Fqx -- 'Icon=yt-dlp-aria2-downloader' "${DESKTOP_FILE}"
for runtime_command in yt-dlp aria2c ffmpeg ffprobe; do
    command -v "${runtime_command}" >/dev/null 2>&1 || {
        printf 'Error: package dependency command is absent: %s\n' \
            "${runtime_command}" >&2
        exit 65
    }
done

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

printf 'RPM lifecycle passed for %s.\n' "${VERSION}"
