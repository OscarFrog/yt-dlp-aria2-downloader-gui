#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# ============================================================================
# Name        : install-gui.sh
# Version     : 2.1.12
# Date        : 2026-07-29
# Description : Install or remove the per-user desktop launcher.
# ============================================================================

set -euo pipefail
umask 077

if [[ -z ${HOME:-} && -z ${XDG_DATA_HOME:-} ]]; then
    printf 'Error: HOME or XDG_DATA_HOME must be defined.\n' >&2
    exit 1
fi

readonly APP_ID='yt-dlp-aria2-downloader'
readonly SCRIPT_NAME="${0##*/}"

TEMP_DESKTOP_FILE=''
TEMP_LAUNCHER_DIR=''
TEMP_VALIDATION_FILE=''

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
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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


for command_name in cat chmod dirname ln mkdir mktemp mv readlink realpath rm rmdir; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Error: required command "%s" was not found.\n' \
            "${command_name}" >&2
        exit 127
    fi
done

if (($# != 1)); then
    usage >&2
    exit 2
fi

# Capture the status explicitly. Calling the function in an if or || list
# would disable errexit inside its body under Bash's documented rules.
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


remove_stale_install_artifacts() {
    local -a artifacts=()

    shopt -s nullglob
    artifacts=(
        "${APPLICATION_DIR}/.${APP_ID}."*.tmp
        "${LAUNCHER_DIR}/.install."*
        "${LAUNCHER_DIR}/.validate."*.desktop
    )
    shopt -u nullglob

    if ((${#artifacts[@]} > 0)); then
        rm -rf -- "${artifacts[@]}"
    fi
}

case $1 in
install)
    if [[ ! -x ${GUI_SCRIPT} ]]; then
        printf 'Error: %s is absent or not executable.\n' "${GUI_SCRIPT}" >&2
        exit 1
    fi

    # A literal percent in a quoted Exec path is handled inconsistently by
    # desktop implementations, and '=' is forbidden in the executable path.
    # The project itself may contain these characters because Exec targets the
    # stable launcher link below; only the XDG launcher path must be representable.
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

    mkdir -p -- "${APPLICATION_DIR}" "${LAUNCHER_DIR}"
    chmod 700 -- "${LAUNCHER_DIR}"

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
Icon=video-x-generic
Terminal=false
Categories=AudioVideo;
StartupNotify=true
EOF_DESKTOP
    chmod 644 -- "${TEMP_DESKTOP_FILE}"

    if command -v desktop-file-validate >/dev/null 2>&1; then
        # desktop-file-validate requires a filename ending in .desktop.
        # Keep that temporary copy in the private launcher directory rather
        # than in applications/, so menu scanners never see an incomplete
        # desktop entry before the final atomic publication.
        TEMP_VALIDATION_FILE=$(mktemp \
            --tmpdir="${LAUNCHER_DIR}" \
            '.validate.XXXXXXXX.desktop')
        cat -- "${TEMP_DESKTOP_FILE}" >"${TEMP_VALIDATION_FILE}"

        validation_status=0
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

    TEMP_LAUNCHER_DIR=$(mktemp -d \
        --tmpdir="${LAUNCHER_DIR}" \
        '.install.XXXXXXXX')
    ln -s -- "${GUI_SCRIPT}" "${TEMP_LAUNCHER_DIR}/launch"
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

    mv -Tf -- "${TEMP_DESKTOP_FILE}" "${DESKTOP_FILE}"
    TEMP_DESKTOP_FILE=''
    printf 'Launcher installed: %s\n' "${DESKTOP_FILE}"
    printf 'Launcher target:    %s\n' "${GUI_SCRIPT}"
    printf 'Reinstall the launcher if the project directory is moved.\n'
    ;;
uninstall)
    launcher_removed=false
    if [[ -e ${DESKTOP_FILE} || -L ${DESKTOP_FILE} ]]; then
        rm -f -- "${DESKTOP_FILE}"
        printf 'Launcher removed: %s\n' "${DESKTOP_FILE}"
        launcher_removed=true
    fi
    if [[ -e ${LAUNCHER_LINK} || -L ${LAUNCHER_LINK} ]]; then
        rm -f -- "${LAUNCHER_LINK}"
        launcher_removed=true
    fi
    remove_stale_install_artifacts
    rmdir -- "${LAUNCHER_DIR}" 2>/dev/null || true

    if [[ ${launcher_removed} == false ]]; then
        printf 'No launcher is installed at: %s\n' "${DESKTOP_FILE}"
    fi
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
