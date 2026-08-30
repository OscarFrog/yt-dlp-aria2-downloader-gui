#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : install-gui.sh
# Purpose     : Install or remove the per-user desktop launcher and icon.
# ==============================================================================

set -euo pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly SCRIPT_NAME="${0##*/}"
INSTALLER_HELPER_PID=''
INSTALLER_HELPER_REGISTRATION_ACTIVE=false
INSTALLER_REQUESTED_SIGNAL=''
INSTALLER_REQUESTED_EXIT_STATUS=''

usage() {
    cat <<EOF_USAGE
Usage:
  ${SCRIPT_NAME} install
  ${SCRIPT_NAME} uninstall
EOF_USAGE
}

resolve_script_dir() {
    local output_variable=$1
    local source=${BASH_SOURCE[0]}
    local path
    local script_dir

    if [[ ${source} != */* ]]; then
        if [[ -e ./${source} ]]; then
            source="./${source}"
        else
            source=$(type -P -- "${source}") || return 1
        fi
    fi
    path=$(realpath -e -- "${source}") || return 1
    script_dir=$(dirname -- "${path}") || return 1
    printf -v "${output_variable}" '%s' "${script_dir}" || return 1
    return 0
}

validate_install_environment() {
    if [[ -z ${HOME:-} && -z ${XDG_DATA_HOME:-} ]]; then
        printf 'Error: HOME or XDG_DATA_HOME must be defined.\n' >&2
        exit 1
    fi
}

require_installer_commands() {
    local command_name=''

    for command_name in cat dirname python3 realpath; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            printf 'Error: required command "%s" was not found.\n' \
                "${command_name}" >&2
            exit 127
        fi
    done
}

validate_install_arguments() {
    if (($# != 1)); then
        usage >&2
        exit 2
    fi
}

initialize_install_paths() {
    local resolve_status=0
    local data_home=''

    set +e
    resolve_script_dir SCRIPT_DIR
    resolve_status=$?
    set -e
    if ((resolve_status != 0)); then
        printf 'Error: unable to resolve the script directory.\n' >&2
        exit 1
    fi
    readonly SCRIPT_DIR
    readonly GUI_SCRIPT="${SCRIPT_DIR}/download-video-gui.sh"
    readonly ICON_SOURCE="${SCRIPT_DIR}/packaging/icons/${APP_ID}.svg"
    readonly PRIVATE_LAUNCHER_HELPER="${SCRIPT_DIR}/private-launcher-manager.py"

    data_home=${XDG_DATA_HOME:-${HOME}/.local/share}
    if [[ ${data_home} != /* ]]; then
        printf 'Error: XDG_DATA_HOME must resolve to an absolute path: %s\n' \
            "${data_home}" >&2
        exit 1
    fi
    if [[ ${data_home} == / ]]; then
        printf 'Error: refusing the filesystem root as XDG data home.\n' >&2
        exit 1
    fi
    readonly DATA_HOME=${data_home}
    readonly LAUNCHER_LINK="${DATA_HOME}/${APP_ID}/launch"
}

validate_launcher_target() {
    if [[ ! -x ${GUI_SCRIPT} ]]; then
        printf 'Error: %s is absent or not executable.\n' "${GUI_SCRIPT}" >&2
        exit 1
    fi

    if [[ ${LAUNCHER_LINK} == *'%'* || ${LAUNCHER_LINK} == *'='* ||
        ${LAUNCHER_LINK} == *$'\n'* || ${LAUNCHER_LINK} == *$'\r'* ]]; then
        printf 'Error: the XDG data path cannot be represented safely in a desktop Exec key: %s\n' \
            "${LAUNCHER_LINK}" >&2
        exit 1
    fi

}

validate_private_launcher_helper() {
    if [[ -L ${PRIVATE_LAUNCHER_HELPER} ||
        ! -f ${PRIVATE_LAUNCHER_HELPER} ||
        ! -r ${PRIVATE_LAUNCHER_HELPER} ]]; then
        printf 'Error: private launcher helper is missing or unsafe: %s\n' \
            "${PRIVATE_LAUNCHER_HELPER}" >&2
        return 1
    fi
}

installer_helper_is_direct_child() {
    local pid=$1
    local process_fields=''
    local process_parent=''
    local process_stat=''

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r /proc/${pid}/stat ]] || return 1
    if ! { IFS= read -r process_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
        return 1
    fi
    process_fields=${process_stat##*) }
    read -r _ process_parent _ <<<"${process_fields}"
    [[ ${process_parent} == "${BASHPID}" ]]
}

terminate_installer_helper_if_child() {
    [[ -n ${INSTALLER_HELPER_PID} ]] || return 1
    # shellcheck disable=SC2310 # Direct-child validation is an expected predicate.
    installer_helper_is_direct_child "${INSTALLER_HELPER_PID}" || return 1

    # A background child may inherit SIGINT ignored before Python installs its
    # handlers. TERM is the reliable internal cancellation signal; the wrapper
    # still returns the caller's original conventional status.
    kill -TERM -- "${INSTALLER_HELPER_PID}" 2>/dev/null || true
    return 0
}

request_installer_shutdown() {
    local signal_name=$1
    local exit_status=$2

    # The first request owns the conventional status. Repeated catchable
    # signals remain ignored while the Python helper completes its rollback.
    if [[ -n ${INSTALLER_REQUESTED_EXIT_STATUS} ]]; then
        return 0
    fi
    INSTALLER_REQUESTED_SIGNAL=${signal_name}
    INSTALLER_REQUESTED_EXIT_STATUS=${exit_status}

    if [[ ${INSTALLER_HELPER_REGISTRATION_ACTIVE} == true ]]; then
        return 0
    fi
    # shellcheck disable=SC2310 # Absence of a live child is an expected race.
    if terminate_installer_helper_if_child; then
        return 0
    fi
    exit "${exit_status}"
}

run_private_launcher_helper() {
    local helper_status=0

    INSTALLER_HELPER_REGISTRATION_ACTIVE=true
    python3 "${PRIVATE_LAUNCHER_HELPER}" "$@" &
    INSTALLER_HELPER_PID=$!
    INSTALLER_HELPER_REGISTRATION_ACTIVE=false

    if [[ -n ${INSTALLER_REQUESTED_SIGNAL} ]]; then
        # shellcheck disable=SC2310 # The helper may already have exited.
        terminate_installer_helper_if_child || true
    fi

    while true; do
        helper_status=0
        wait "${INSTALLER_HELPER_PID}" || helper_status=$?
        # shellcheck disable=SC2310 # A non-child means wait already reaped it.
        if ! installer_helper_is_direct_child "${INSTALLER_HELPER_PID}"; then
            break
        fi
    done
    INSTALLER_HELPER_PID=''

    if [[ -n ${INSTALLER_REQUESTED_EXIT_STATUS} ]]; then
        return "${INSTALLER_REQUESTED_EXIT_STATUS}"
    fi
    if ((helper_status != 0)); then
        return 1
    fi
    return 0
}

install_launcher() {
    validate_launcher_target
    validate_private_launcher_helper
    run_private_launcher_helper install \
        --data-home "${DATA_HOME}" \
        --launcher-target "${GUI_SCRIPT}" \
        --icon-source "${ICON_SOURCE}"
}

uninstall_launcher() {
    validate_private_launcher_helper
    run_private_launcher_helper uninstall \
        --data-home "${DATA_HOME}"
}

dispatch_install_action() {
    case $1 in
        install) install_launcher ;;
        uninstall) uninstall_launcher ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main() {
    trap 'request_installer_shutdown HUP 129' HUP
    trap 'request_installer_shutdown INT 130' INT
    trap 'request_installer_shutdown TERM 143' TERM

    validate_install_environment
    require_installer_commands
    validate_install_arguments "$@"
    initialize_install_paths
    dispatch_install_action "$1"
}

main "$@"
