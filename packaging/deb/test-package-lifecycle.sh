#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/deb/test-package-lifecycle.sh
# Purpose     : Validate Debian package installation and removal behavior.
# ==============================================================================

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
    apt-get desktop-file-validate dirname dpkg dpkg-deb dpkg-query find grep \
    mkdir mktemp realpath rm rmdir sha256sum sort tar; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

PACKAGE_PATH=$(realpath -e -- "${PACKAGE_INPUT}")
readonly PACKAGE_PATH
[[ -f ${PACKAGE_PATH} && ${PACKAGE_PATH} == *.deb ]] || {
    printf 'Error: not a regular DEB package: %s\n' "${PACKAGE_PATH}" >&2
    exit 2
}

package_depends=$(dpkg-deb --field "${PACKAGE_PATH}" Depends)
for required_dependency in \
    'aria2 (>= 1.37.0)' \
    'python3 (>= 3.10)' \
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
for forbidden_dependency in coreutils findutils grep sed util-linux; do
    if grep -Eq "(^|,)[[:space:]]*${forbidden_dependency}([[:space:](,]|$)" \
        <<<"${package_depends}"; then
        printf 'Error: DEB redundantly depends on Essential package: %s\n' \
            "${forbidden_dependency}" >&2
        exit 65
    fi
done
if [[ ${package_depends} == *'yt-dlp'* || ${package_depends} == *'deno'* ]]; then
    printf 'Error: DEB must use managed yt-dlp and Deno runtimes, not system package dependencies.\n' >&2
    exit 65
fi

if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null \
    | grep -Fqx -- 'install ok installed'; then
    printf 'Error: %s is already installed.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi

if [[ -z ${HOME:-} || ${HOME} != /* ]]; then
    printf 'Error: HOME must be an absolute path for the lifecycle test.\n' >&2
    exit 64
fi
DATA_HOME=${XDG_DATA_HOME:-${HOME}/.local/share}
if [[ ${DATA_HOME} != /* ]]; then
    DATA_HOME="${HOME}/.local/share"
fi
readonly DATA_HOME
RUNTIME_ROOT="${DATA_HOME}/yt-dlp-aria2-downloader/runtime"
readonly RUNTIME_ROOT

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR PROJECT_DIR
# shellcheck source=tests/lib/package-runtime-preservation.sh
source "${PROJECT_DIR}/tests/lib/package-runtime-preservation.sh"

WORK_DIR=$(mktemp -d)
readonly WORK_DIR
package_installed=false
package_files=()

cleanup() {
    if [[ ${package_installed} == true ]]; then
        DEBIAN_FRONTEND=noninteractive \
            apt-get remove --yes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    package_runtime_fixture_cleanup
    rm -rf -- "${WORK_DIR}" || true
}

assert_payload_absent() {
    local stage=$1
    local path=''

    for path in "${package_files[@]}"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: %s left a package file: %s\n' "${stage}" "${path}" >&2
            return 65
        }
    done
    for path in "${PRIVATE_DIR}" "/usr/share/doc/${PACKAGE_NAME}"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: %s left a private path: %s\n' "${stage}" "${path}" >&2
            return 65
        }
    done
    return 0
}

assert_installed_version() {
    local stage=$1
    local installed_status=''
    local installed_version=''

    installed_status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}")
    [[ ${installed_status} == 'install ok installed' ]] || {
        printf 'Error: DEB is not fully installed during %s: %s\n' \
            "${stage}" "${installed_status}" >&2
        return 65
    }
    installed_version=$(/usr/bin/yt-dlp-aria2-downloader --version)
    [[ ${installed_version} == "yt-dlp-aria2-downloader version ${VERSION}" ]] || {
        printf 'Error: DEB executable reports an unexpected version during %s: %s\n' \
            "${stage}" "${installed_version}" >&2
        return 65
    }
    return 0
}

main() {
    local package_list_file=''
    local control_dir=''
    local remaining_status=''
    local runtime_command=''
    local aria2_package_version=''
    local maintainer_script=''

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    package_runtime_fixture_prepare \
        "package-lifecycle-preservation:${VERSION}"

    dpkg-deb --extract "${PACKAGE_PATH}" "${WORK_DIR}/root"
    package_list_file="${WORK_DIR}/package-files"
    find "${WORK_DIR}/root" \
        \( -type f -o -type l \) \
        -printf '/%P\n' | LC_ALL=C sort >"${package_list_file}"
    mapfile -t package_files <"${package_list_file}"
    ((${#package_files[@]} > 0)) || {
        printf 'Error: the DEB payload contains no files.\n' >&2
        exit 65
    }

    control_dir="${WORK_DIR}/control"
    mkdir -p -- "${control_dir}"
    dpkg-deb --control "${PACKAGE_PATH}" "${control_dir}"
    for maintainer_script in postinst prerm postrm; do
        [[ ! -e ${control_dir}/${maintainer_script} &&
            ! -L ${control_dir}/${maintainer_script} ]] || {
            printf 'Error: DEB unexpectedly contains maintainer script: %s\n' \
                "${maintainer_script}" >&2
            exit 65
        }
    done

    DEBIAN_FRONTEND=noninteractive \
        apt-get install --yes "${PACKAGE_PATH}"
    package_installed=true
    assert_installed_version 'initial installation'
    assert_runtime_preserved 'initial DEB installation'
    [[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]] || {
        printf '%s\n' 'Error: packaged GUI launcher is absent.' >&2
        exit 65
    }
    [[ -f ${DESKTOP_FILE} && ! -L ${DESKTOP_FILE} ]] || {
        printf '%s\n' 'Error: packaged desktop file is absent or unsafe.' >&2
        exit 65
    }
    [[ -f ${ICON_FILE} && ! -L ${ICON_FILE} ]] || {
        printf '%s\n' 'Error: packaged icon is absent or unsafe.' >&2
        exit 65
    }
    desktop-file-validate --no-hints "${DESKTOP_FILE}"
    grep -Fqx -- 'Icon=yt-dlp-aria2-downloader' "${DESKTOP_FILE}"
    for runtime_command in aria2c ffmpeg ffprobe python3 curl gpg unzip flock timeout; do
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
    [[ ! -e ${PRIVATE_DIR}/package-user-cleanup.sh &&
        ! -L ${PRIVATE_DIR}/package-user-cleanup.sh ]] || {
        printf '%s\n' 'Error: DEB must not ship the RPM-only all-user cleanup helper.' >&2
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
    assert_runtime_preserved 'DEB remove'
    assert_payload_absent 'DEB remove'

    # Explicitly qualify the remove -> purge transition while preserving data
    # that belongs to the user rather than to dpkg's system payload.
    dpkg --purge "${PACKAGE_NAME}"
    assert_runtime_preserved 'DEB remove-to-purge transition'

    remaining_status=''
    if remaining_status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null); then
        [[ ${remaining_status} != 'install ok installed' ]] || {
            printf 'Error: DEB remains installed after purge.\n' >&2
            exit 65
        }
    fi

    # Reinstall the exact same package after removal/purge. This catches stale
    # package-manager state while preserving the per-user runtime fixture.
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${PACKAGE_PATH}"
    package_installed=true
    assert_installed_version 'reinstallation'
    assert_runtime_preserved 'DEB reinstallation'

    DEBIAN_FRONTEND=noninteractive apt-get purge --yes "${PACKAGE_NAME}"
    package_installed=false
    assert_runtime_preserved 'direct DEB purge'
    assert_payload_absent 'direct DEB purge'

    printf 'DEB lifecycle, purge, and reinstall passed for %s.\n' "${VERSION}"
}

main "$@"
