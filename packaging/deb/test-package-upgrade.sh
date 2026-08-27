#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/deb/test-package-upgrade.sh
# Purpose     : Validate Debian upgrades from the previous immutable release.
# ==============================================================================

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
((EUID == 0)) || {
    printf 'Error: DEB upgrade test must run as root.\n' >&2
    exit 77
}
for command_name in apt-get dirname dpkg dpkg-query grep mkdir mktemp realpath rm rmdir sha256sum tar; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done
old_package=$(realpath -e -- "${OLD_INPUT}")
new_package=$(realpath -e -- "${NEW_INPUT}")
if [[ ! -f ${old_package} || ${old_package} != *.deb ]]; then
    printf 'Error: old package is not a regular DEB file: %s\n' \
        "${old_package}" >&2
    exit 2
fi
if [[ ! -f ${new_package} || ${new_package} != *.deb ]]; then
    printf 'Error: new package is not a regular DEB file: %s\n' \
        "${new_package}" >&2
    exit 2
fi
if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null \
    | grep -Fqx -- 'install ok installed'; then
    printf 'Error: %s must not be installed before the upgrade test.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi
installed=false

if [[ -z ${HOME:-} || ${HOME} != /* ]]; then
    printf 'Error: HOME must be an absolute path for the upgrade test.\n' >&2
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

cleanup() {
    if [[ ${installed} == true ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove --yes \
            "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    package_runtime_fixture_cleanup
}

assert_installed_package_version() {
    local expected_version=$1
    local stage=$2
    local installed_package_version=''

    installed_package_version=$(dpkg-query -W -f='${Version}' "${PACKAGE_NAME}") || {
        printf 'Error: unable to read installed DEB version during %s.\n' \
            "${stage}" >&2
        return 65
    }
    if [[ ${installed_package_version} != "${expected_version}-1" ]]; then
        printf 'Error: unexpected installed DEB version during %s: %s (expected %s-1).\n' \
            "${stage}" "${installed_package_version}" "${expected_version}" >&2
        return 65
    fi
    return 0
}

main() {
    local old_version_output=''
    local new_version_output=''
    local status=''
    local path=''

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    package_runtime_fixture_prepare \
        "package-upgrade-preservation:${OLD_VERSION}->${NEW_VERSION}"

    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${old_package}"
    installed=true
    assert_installed_package_version "${OLD_VERSION}" 'previous package installation'
    assert_runtime_preserved 'installation of previous package'
    old_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
    [[ ${old_version_output} == "yt-dlp-aria2-downloader version ${OLD_VERSION}" ]] || {
        printf 'Error: previous DEB executable reports an unexpected version: %s\n' \
            "${old_version_output}" >&2
        exit 65
    }

    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${new_package}"
    assert_installed_package_version "${NEW_VERSION}" 'package upgrade'
    assert_runtime_preserved 'package upgrade'
    new_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
    [[ ${new_version_output} == "yt-dlp-aria2-downloader version ${NEW_VERSION}" ]] || {
        printf 'Error: upgraded DEB executable reports an unexpected version: %s\n' \
            "${new_version_output}" >&2
        exit 65
    }
    [[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]] || {
        printf '%s\n' 'Error: upgraded DEB GUI launcher is absent.' >&2
        exit 65
    }
    [[ -x /usr/lib/yt-dlp-aria2-downloader/runtime-manager.sh ]] || {
        printf '%s\n' 'Error: upgraded DEB runtime manager is absent.' >&2
        exit 65
    }

    DEBIAN_FRONTEND=noninteractive apt-get remove --yes "${PACKAGE_NAME}"
    installed=false
    assert_runtime_preserved 'final DEB package removal'

    dpkg --purge "${PACKAGE_NAME}"
    assert_runtime_preserved 'DEB remove-to-purge transition'

    status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null || true)
    [[ ${status} != 'install ok installed' ]] || {
        printf '%s\n' 'Error: DEB remains installed after upgrade/removal.' >&2
        exit 65
    }
    for path in "/usr/lib/yt-dlp-aria2-downloader" "/usr/share/doc/${PACKAGE_NAME}"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: DEB upgrade/removal left a private path: %s\n' "${path}" >&2
            exit 65
        }
    done
    printf 'DEB upgrade passed with user-runtime preservation: %s -> %s.\n' \
        "${OLD_VERSION}" "${NEW_VERSION}"
}

main "$@"
