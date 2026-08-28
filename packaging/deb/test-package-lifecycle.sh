#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/deb/test-package-lifecycle.sh
# Purpose     : Validate Debian package installation and removal behavior.
# ==============================================================================

set -Eeuo pipefail
umask 077

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly PRIVATE_DIR='/usr/lib/yt-dlp-aria2-downloader'

WORK_DIR=''
package_installed=false
package_files=()

cleanup() {
    if [[ ${package_installed} == true ]]; then
        DEBIAN_FRONTEND=noninteractive \
            apt-get remove --yes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi
    package_runtime_fixture_cleanup
    if [[ -n ${WORK_DIR} ]]; then
        rm -rf -- "${WORK_DIR}" || true
    fi
}

parse_deb_lifecycle_arguments() {
    if (($# != 2)); then
        printf 'Usage: %s PACKAGE.deb VERSION\n' "${0##*/}" >&2
        exit 2
    fi

    readonly PACKAGE_INPUT=$1
    readonly VERSION=$2
    [[ ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Error: invalid package version: %s\n' "${VERSION}" >&2
        exit 2
    }
}

require_deb_lifecycle_environment() {
    local command_name=''

    ((EUID == 0)) || {
        printf 'Error: the DEB lifecycle test must run as root.\n' >&2
        exit 77
    }
    for command_name in \
        apt-get desktop-file-validate dirname dpkg dpkg-deb dpkg-query find \
        grep mkdir mktemp realpath rm rmdir sha256sum sort tar; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' \
                "${command_name}" >&2
            exit 127
        }
    done
}

initialize_deb_lifecycle_paths() {
    local script_parent=''

    if ! PACKAGE_PATH=$(realpath -e -- "${PACKAGE_INPUT}"); then
        printf 'Error: unable to resolve DEB package: %s\n' \
            "${PACKAGE_INPUT}" >&2
        exit 2
    fi
    readonly PACKAGE_PATH
    [[ -f ${PACKAGE_PATH} && ${PACKAGE_PATH} == *.deb ]] || {
        printf 'Error: not a regular DEB package: %s\n' "${PACKAGE_PATH}" >&2
        exit 2
    }

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

validate_deb_dependencies() {
    local package_depends=''
    local required_dependency=''
    local forbidden_dependency=''

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
        if grep -Eq \
            "(^|,)[[:space:]]*${forbidden_dependency}([[:space:](,]|$)" \
            <<<"${package_depends}"; then
            printf 'Error: DEB redundantly depends on Essential package: %s\n' \
                "${forbidden_dependency}" >&2
            exit 65
        fi
    done
    if [[ ${package_depends} == *'yt-dlp'* || ${package_depends} == *'deno'* ]]; then
        printf '%s\n' \
            'Error: DEB must use managed runtimes, not yt-dlp or Deno package dependencies.' >&2
        exit 65
    fi
}

validate_deb_initial_state() {
    if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null \
        | grep -Fqx -- 'install ok installed'; then
        printf 'Error: %s is already installed.\n' "${PACKAGE_NAME}" >&2
        exit 65
    fi
}

initialize_deb_lifecycle_workspace() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    WORK_DIR=$(mktemp -d)
    readonly WORK_DIR
}

inspect_deb_payload() {
    local package_list_file="${WORK_DIR}/package-files"
    local control_dir="${WORK_DIR}/control"
    local maintainer_script=''

    dpkg-deb --extract "${PACKAGE_PATH}" "${WORK_DIR}/root"
    find "${WORK_DIR}/root" \
        \( -type f -o -type l \) \
        -printf '/%P\n' | LC_ALL=C sort >"${package_list_file}"
    mapfile -t package_files <"${package_list_file}"
    ((${#package_files[@]} > 0)) || {
        printf 'Error: the DEB payload contains no files.\n' >&2
        exit 65
    }

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
}

assert_deb_payload_absent() {
    local stage=$1

    assert_package_paths_absent DEB "${stage}" \
        "${package_files[@]}" \
        "${PRIVATE_DIR}" \
        "/usr/share/doc/${PACKAGE_NAME}"
}

assert_installed_deb() {
    local stage=$1
    local installed_status=''

    installed_status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}")
    [[ ${installed_status} == 'install ok installed' ]] || {
        printf 'Error: DEB is not fully installed during %s: %s\n' \
            "${stage}" "${installed_status}" >&2
        return 65
    }
    assert_package_cli_version DEB "${VERSION}" "${stage}"
}

assert_deb_private_payload() {
    local aria2_package_version=''

    assert_common_package_payload DEB
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
}

install_initial_deb() {
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${PACKAGE_PATH}"
    package_installed=true
    assert_installed_deb 'initial installation'
    assert_runtime_preserved 'initial DEB installation'
    assert_deb_private_payload
}

remove_and_purge_deb() {
    local remaining_status=''

    DEBIAN_FRONTEND=noninteractive \
        apt-get remove --yes "${PACKAGE_NAME}"
    package_installed=false
    assert_runtime_preserved 'DEB remove'
    assert_deb_payload_absent 'remove'

    dpkg --purge "${PACKAGE_NAME}"
    assert_runtime_preserved 'DEB remove-to-purge transition'

    remaining_status=''
    if remaining_status=$(dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null); then
        [[ ${remaining_status} != 'install ok installed' ]] || {
            printf 'Error: DEB remains installed after purge.\n' >&2
            exit 65
        }
    fi
}

reinstall_and_purge_deb() {
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${PACKAGE_PATH}"
    package_installed=true
    assert_installed_deb 'reinstallation'
    assert_runtime_preserved 'DEB reinstallation'

    DEBIAN_FRONTEND=noninteractive apt-get purge --yes "${PACKAGE_NAME}"
    package_installed=false
    assert_runtime_preserved 'direct DEB purge'
    assert_deb_payload_absent 'direct purge'
}

main() {
    parse_deb_lifecycle_arguments "$@"
    require_deb_lifecycle_environment
    initialize_deb_lifecycle_paths
    validate_deb_dependencies
    validate_deb_initial_state
    initialize_deb_lifecycle_workspace
    package_runtime_fixture_prepare \
        "package-lifecycle-preservation:${VERSION}"
    inspect_deb_payload
    install_initial_deb
    remove_and_purge_deb
    reinstall_and_purge_deb

    printf 'DEB lifecycle, purge, and reinstall passed for %s.\n' "${VERSION}"
}

main "$@"
