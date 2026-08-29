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

TEMP_DESKTOP_FILE=''
TEMP_LAUNCHER_DIR=''
TEMP_VALIDATION_FILE=''
TEMP_ICON_FILE=''

cleanup() {
    if [[ -n ${TEMP_DESKTOP_FILE} ]]; then
        rm -f -- "${TEMP_DESKTOP_FILE}" || true
    fi
    if [[ -n ${TEMP_LAUNCHER_DIR} ]]; then
        rm -rf -- "${TEMP_LAUNCHER_DIR}" || true
    fi
    if [[ -n ${TEMP_VALIDATION_FILE} ]]; then
        rm -f -- "${TEMP_VALIDATION_FILE}" || true
    fi
    if [[ -n ${TEMP_ICON_FILE} ]]; then
        rm -f -- "${TEMP_ICON_FILE}" || true
    fi
}

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

quote_desktop_exec_path() {
    local value=$1

    # Desktop-entry string unescaping happens before Exec argument parsing.
    # Backslashes needed by Exec must therefore be escaped once more here.
    value=${value//\\/\\\\\\\\}
    value=${value//\"/\\\\\"}
    value=${value//\`/\\\\\`}
    value=${value//\$/\\\\\$}
    printf '"%s"' "${value}"
}

write_embedded_icon() {
    local destination=$1

    cat >"${destination}" <<'EOF_ICON'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg"
     width="256" height="256" viewBox="0 0 256 256">
  <title>yt-dlp aria2 downloader</title>
  <rect x="16" y="16" width="224" height="224" rx="48"
        fill="#2864dc"/>
  <path d="M83 68v92l78-46z" fill="#ffffff"/>
  <path d="M128 136v48m-24-24 24 24 24-24"
        fill="none" stroke="#ffffff" stroke-width="16"
        stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M88 204h80" fill="none" stroke="#ffffff"
        stroke-width="14" stroke-linecap="round"/>
</svg>
EOF_ICON
}

remove_stale_install_artifacts() {
    local -a artifacts=()

    shopt -s nullglob
    artifacts=(
        "${APPLICATION_DIR}/.${APP_ID}."*.tmp
        "${LAUNCHER_DIR}/.install."*
        "${LAUNCHER_DIR}/.validate."*.desktop
        "${ICON_DIR}/.${APP_ID}."*.tmp
    )
    shopt -u nullglob

    if ((${#artifacts[@]} > 0)); then
        rm -rf -- "${artifacts[@]}"
    fi
}

reject_symlink_directory() {
    local directory=$1

    if [[ -L ${directory} ]]; then
        printf 'Error: refusing a symbolic-link installation directory: %s\n' \
            "${directory}" >&2
        return 1
    fi
    return 0
}

validate_managed_directory_chain() {
    local directory=''

    for directory in \
        "${APPLICATION_DIR}" \
        "${LAUNCHER_DIR}" \
        "${DATA_HOME}/icons" \
        "${DATA_HOME}/icons/hicolor" \
        "${DATA_HOME}/icons/hicolor/scalable" \
        "${ICON_DIR}"; do
        reject_symlink_directory "${directory}"
    done
}

validate_install_environment() {
    if [[ -z ${HOME:-} && -z ${XDG_DATA_HOME:-} ]]; then
        printf 'Error: HOME or XDG_DATA_HOME must be defined.\n' >&2
        exit 1
    fi
}

require_installer_commands() {
    local command_name=''

    for command_name in cat chmod dirname ln mkdir mktemp mv readlink realpath rm rmdir; do
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

    data_home=${XDG_DATA_HOME:-${HOME}/.local/share}
    if [[ ${data_home} != /* ]]; then
        printf 'Error: XDG_DATA_HOME must resolve to an absolute path: %s\n' \
            "${data_home}" >&2
        exit 1
    fi
    readonly DATA_HOME=${data_home}
    readonly APPLICATION_DIR="${DATA_HOME}/applications"
    readonly LAUNCHER_DIR="${DATA_HOME}/${APP_ID}"
    readonly LAUNCHER_LINK="${LAUNCHER_DIR}/launch"
    readonly DESKTOP_FILE="${APPLICATION_DIR}/${APP_ID}.desktop"
    readonly ICON_DIR="${DATA_HOME}/icons/hicolor/scalable/apps"
    readonly ICON_FILE="${ICON_DIR}/${APP_ID}.svg"
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

    if [[ -e ${LAUNCHER_LINK} && ! -L ${LAUNCHER_LINK} ]]; then
        printf 'Error: the launcher path already exists and is not a symbolic link: %s\n' \
            "${LAUNCHER_LINK}" >&2
        exit 1
    fi
}

prepare_install_directories() {
    validate_managed_directory_chain
    mkdir -p -- "${APPLICATION_DIR}" "${LAUNCHER_DIR}" "${ICON_DIR}"
    chmod 700 -- "${LAUNCHER_DIR}"
    remove_stale_install_artifacts
}

write_desktop_entry() {
    local desktop_exec=''

    desktop_exec=$(quote_desktop_exec_path "${LAUNCHER_LINK}")
    TEMP_DESKTOP_FILE=$(mktemp \
        --tmpdir="${APPLICATION_DIR}" \
        ".${APP_ID}.XXXXXXXX.tmp")
    cat >"${TEMP_DESKTOP_FILE}" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=yt-dlp aria2 downloader
Comment=Download a video or extract an audio track
Comment[fr]=Télécharger une vidéo ou extraire une piste audio
Exec=${desktop_exec}
Icon=${APP_ID}
Terminal=false
Categories=AudioVideo;
StartupNotify=true
EOF_DESKTOP
    chmod 644 -- "${TEMP_DESKTOP_FILE}"
}

validate_desktop_entry() {
    local validation_status=0
    local validation_output=''

    if command -v desktop-file-validate >/dev/null 2>&1; then
        TEMP_VALIDATION_FILE=$(mktemp \
            --tmpdir="${LAUNCHER_DIR}" \
            '.validate.XXXXXXXX.desktop')
        cat -- "${TEMP_DESKTOP_FILE}" >"${TEMP_VALIDATION_FILE}"

        validation_output=$(desktop-file-validate \
            --no-hints \
            "${TEMP_VALIDATION_FILE}" 2>&1) || validation_status=$?
        if ((validation_status != 0)); then
            printf 'Error: the generated desktop launcher failed validation (status %d).\n' \
                "${validation_status}" >&2
            if [[ -n ${validation_output} ]]; then
                printf '%s\n' "${validation_output}" >&2
            fi
            printf 'The previously installed launcher, if any, was left unchanged.\n' >&2
            exit 1
        fi

        rm -f -- "${TEMP_VALIDATION_FILE}"
        TEMP_VALIDATION_FILE=''
    else
        printf 'Note: desktop-file-validate is unavailable; launcher validation was skipped.\n' >&2
    fi
}

prepare_launcher_assets() {
    TEMP_LAUNCHER_DIR=$(mktemp -d \
        --tmpdir="${LAUNCHER_DIR}" \
        '.install.XXXXXXXX')
    ln -s -- "${GUI_SCRIPT}" "${TEMP_LAUNCHER_DIR}/launch"

    TEMP_ICON_FILE=$(mktemp \
        --tmpdir="${ICON_DIR}" \
        ".${APP_ID}.XXXXXXXX.tmp")
    if [[ -f ${ICON_SOURCE} && ! -L ${ICON_SOURCE} ]]; then
        cat -- "${ICON_SOURCE}" >"${TEMP_ICON_FILE}"
    else
        # Keep source-tree installer tests and minimal portable copies usable.
        write_embedded_icon "${TEMP_ICON_FILE}"
    fi
    chmod 644 -- "${TEMP_ICON_FILE}"
}

publish_launcher() {
    local published_target=''

    mv -Tf -- "${TEMP_LAUNCHER_DIR}/launch" "${LAUNCHER_LINK}"
    rmdir -- "${TEMP_LAUNCHER_DIR}"
    TEMP_LAUNCHER_DIR=''

    if [[ ! -L ${LAUNCHER_LINK} || ! -x ${LAUNCHER_LINK} ]]; then
        printf 'Error: the published launcher link is missing or not executable.\n' >&2
        exit 1
    fi
    if ! published_target=$(readlink -- "${LAUNCHER_LINK}"); then
        printf 'Error: unable to read the published launcher link: %s\n' \
            "${LAUNCHER_LINK}" >&2
        exit 1
    fi
    if [[ ${published_target} != "${GUI_SCRIPT}" ]]; then
        printf 'Error: the published launcher target is incorrect: %s\n' \
            "${published_target}" >&2
        exit 1
    fi

    mv -Tf -- "${TEMP_ICON_FILE}" "${ICON_FILE}"
    TEMP_ICON_FILE=''
    mv -Tf -- "${TEMP_DESKTOP_FILE}" "${DESKTOP_FILE}"
    TEMP_DESKTOP_FILE=''
    printf 'Launcher installed: %s\n' "${DESKTOP_FILE}"
    printf 'Launcher target:    %s\n' "${GUI_SCRIPT}"
    printf 'Application icon:   %s\n' "${ICON_FILE}"
    printf 'Reinstall the launcher if the project directory is moved.\n'
}

install_launcher() {
    validate_launcher_target
    prepare_install_directories
    write_desktop_entry
    validate_desktop_entry
    prepare_launcher_assets
    publish_launcher
}

uninstall_launcher() {
    local launcher_removed=false

    # The same traversal boundary applies to removal: stale-artifact globs and
    # known leaf paths must never cross a symbolic-link directory.
    validate_managed_directory_chain

    if [[ -e ${DESKTOP_FILE} || -L ${DESKTOP_FILE} ]]; then
        rm -f -- "${DESKTOP_FILE}"
        printf 'Launcher removed: %s\n' "${DESKTOP_FILE}"
        launcher_removed=true
    fi
    if [[ -e ${LAUNCHER_LINK} || -L ${LAUNCHER_LINK} ]]; then
        rm -f -- "${LAUNCHER_LINK}"
        launcher_removed=true
    fi
    if [[ -e ${ICON_FILE} || -L ${ICON_FILE} ]]; then
        rm -f -- "${ICON_FILE}"
        launcher_removed=true
    fi
    remove_stale_install_artifacts
    rmdir -- "${LAUNCHER_DIR}" 2>/dev/null || true

    if [[ ${launcher_removed} == false ]]; then
        printf 'No launcher is installed at: %s\n' "${DESKTOP_FILE}"
    fi
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
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    validate_install_environment
    require_installer_commands
    validate_install_arguments "$@"
    initialize_install_paths
    dispatch_install_action "$1"
}

main "$@"
