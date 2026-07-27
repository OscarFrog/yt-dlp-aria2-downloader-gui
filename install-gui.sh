#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

set -Eeuo pipefail

if [[ -z ${HOME:-} && -z ${XDG_DATA_HOME:-} ]]; then
    printf 'Error: HOME or XDG_DATA_HOME must be defined.\n' >&2
    exit 1
fi

readonly APP_ID='yt-dlp-aria2-downloader'
readonly SCRIPT_NAME="${0##*/}"

TEMP_DESKTOP_FILE=''

cleanup() {
    if [[ -n ${TEMP_DESKTOP_FILE} ]]; then
        rm -f -- "${TEMP_DESKTOP_FILE}"
    fi
}

trap cleanup EXIT

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
        source=$(type -P -- "${source}") || return 1
    fi
    path=$(realpath -e -- "${source}") || return 1
    script_dir=$(dirname -- "${path}") || return 1
    printf -v "${output_variable}" '%s' "${script_dir}"
}

quote_desktop_exec_path() {
    local value=$1

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//\`/\\\`}
    value=${value//\$/\\\$}
    value=${value//%/%%}
    printf '"%s"' "${value}"
}

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
readonly APPLICATION_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
readonly DESKTOP_FILE="${APPLICATION_DIR}/${APP_ID}.desktop"

case $1 in
install)
    if [[ ! -x ${GUI_SCRIPT} ]]; then
        printf 'Error: %s is absent or not executable.\n' "${GUI_SCRIPT}" >&2
        exit 1
    fi

    mkdir -p -- "${APPLICATION_DIR}"
    desktop_exec=$(quote_desktop_exec_path "${GUI_SCRIPT}")
    TEMP_DESKTOP_FILE=$(mktemp \
        --tmpdir="${APPLICATION_DIR}" \
        --suffix='.desktop' \
        ".${APP_ID}.XXXXXX")
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
        desktop-file-validate "${TEMP_DESKTOP_FILE}"
    fi
    mv -f -- "${TEMP_DESKTOP_FILE}" "${DESKTOP_FILE}"
    TEMP_DESKTOP_FILE=''
    printf 'Launcher installed: %s\n' "${DESKTOP_FILE}"
    ;;
uninstall)
    if [[ -e ${DESKTOP_FILE} ]]; then
        rm -f -- "${DESKTOP_FILE}"
        printf 'Launcher removed: %s\n' "${DESKTOP_FILE}"
    else
        printf 'No launcher is installed at: %s\n' "${DESKTOP_FILE}"
    fi
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
