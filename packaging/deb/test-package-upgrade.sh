#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/deb/test-package-upgrade.sh
# Purpose     : Validate Debian upgrades from the previous immutable release.
# ==============================================================================

set -Eeuo pipefail
umask 077

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'

package_installed=false

cleanup() {
    if [[ ${package_installed} == true ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove --yes \
            "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    package_runtime_fixture_cleanup
}

parse_deb_upgrade_arguments() {
    local version=''

    if (($# != 4)); then
        printf 'Usage: %s OLD.deb NEW.deb OLD_VERSION NEW_VERSION\n' \
            "${0##*/}" >&2
        exit 2
    fi
    readonly OLD_INPUT=$1
    readonly NEW_INPUT=$2
    readonly OLD_VERSION=$3
    readonly NEW_VERSION=$4

    for version in "${OLD_VERSION}" "${NEW_VERSION}"; do
        [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            printf 'Error: invalid package version: %s\n' "${version}" >&2
            exit 2
        }
    done
}

require_deb_upgrade_environment() {
    local command_name=''

    ((EUID == 0)) || {
        printf 'Error: DEB upgrade test must run as root.\n' >&2
        exit 77
    }
    for command_name in \
        apt-get desktop-file-validate dirname dpkg dpkg-query grep mkdir \
        mktemp realpath rm rmdir sha256sum tar; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' \
                "${command_name}" >&2
            exit 127
        }
    done
}

initialize_deb_upgrade_paths() {
    local script_parent=''

    if ! OLD_PACKAGE=$(realpath -e -- "${OLD_INPUT}"); then
        printf 'Error: unable to resolve previous DEB package: %s\n' \
            "${OLD_INPUT}" >&2
        exit 2
    fi
    readonly OLD_PACKAGE
    if ! NEW_PACKAGE=$(realpath -e -- "${NEW_INPUT}"); then
        printf 'Error: unable to resolve current DEB package: %s\n' \
            "${NEW_INPUT}" >&2
        exit 2
    fi
    readonly NEW_PACKAGE
    [[ -f ${OLD_PACKAGE} && ${OLD_PACKAGE} == *.deb ]] || {
        printf 'Error: previous package is not a regular DEB file: %s\n' \
            "${OLD_PACKAGE}" >&2
        exit 2
    }
    [[ -f ${NEW_PACKAGE} && ${NEW_PACKAGE} == *.deb ]] || {
        printf 'Error: current package is not a regular DEB file: %s\n' \
            "${NEW_PACKAGE}" >&2
        exit 2
    }

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

    script_parent=$(dirname -- "${BASH_SOURCE[0]}")
    SCRIPT_DIR=$(cd -- "${script_parent}" && pwd -P)
    readonly SCRIPT_DIR
    PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
    readonly PROJECT_DIR
    # shellcheck source=tests/lib/package-lifecycle.sh
    source "${PROJECT_DIR}/tests/lib/package-lifecycle.sh"
    # shellcheck source=tests/lib/package-runtime-preservation.sh
    source "${PROJECT_DIR}/tests/lib/package-runtime-preservation.sh"
}

validate_deb_upgrade_initial_state() {
    if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null \
        | grep -Fqx -- 'install ok installed'; then
        printf 'Error: %s must not be installed before the upgrade test.\n' \
            "${PACKAGE_NAME}" >&2
        exit 65
    fi
}

initialize_deb_upgrade_cleanup() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

assert_installed_deb_version() {
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
    assert_package_cli_version DEB "${expected_version}" "${stage}"
}

install_previous_deb() {
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${OLD_PACKAGE}"
    package_installed=true
    assert_installed_deb_version \
        "${OLD_VERSION}" 'previous package installation'
    assert_runtime_preserved 'installation of previous package'
}

upgrade_deb_package() {
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${NEW_PACKAGE}"
    assert_installed_deb_version "${NEW_VERSION}" 'package upgrade'
    assert_runtime_preserved 'package upgrade'
    assert_common_package_payload DEB
    [[ -x /usr/lib/yt-dlp-aria2-downloader/runtime-manager.sh ]] || {
        printf '%s\n' 'Error: upgraded DEB runtime manager is absent.' >&2
        exit 65
    }
}

remove_upgraded_deb() {
    local status=''

    DEBIAN_FRONTEND=noninteractive apt-get remove --yes "${PACKAGE_NAME}"
    package_installed=false
    assert_runtime_preserved 'final DEB package removal'

    dpkg --purge "${PACKAGE_NAME}"
    assert_runtime_preserved 'DEB remove-to-purge transition'

    status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null || true)
    [[ ${status} != 'install ok installed' ]] || {
        printf '%s\n' 'Error: DEB remains installed after upgrade/removal.' >&2
        exit 65
    }
    assert_package_paths_absent DEB 'upgrade removal' \
        '/usr/lib/yt-dlp-aria2-downloader' \
        "/usr/share/doc/${PACKAGE_NAME}"
}

main() {
    parse_deb_upgrade_arguments "$@"
    require_deb_upgrade_environment
    initialize_deb_upgrade_paths
    validate_deb_upgrade_initial_state
    initialize_deb_upgrade_cleanup
    package_runtime_fixture_prepare \
        "package-upgrade-preservation:${OLD_VERSION}->${NEW_VERSION}"
    install_previous_deb
    upgrade_deb_package
    remove_upgraded_deb

    printf 'DEB upgrade passed with user-runtime preservation: %s -> %s.\n' \
        "${OLD_VERSION}" "${NEW_VERSION}"
}

main "$@"
