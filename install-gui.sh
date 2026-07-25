#!/usr/bin/env bash

# SPDX-License-Identifier: MIT

set -Eeuo pipefail

if [[ -z ${HOME:-} && -z ${XDG_DATA_HOME:-} ]]; then
    printf 'Error: HOME or XDG_DATA_HOME must be defined.\n' >&2
    exit 1
fi

readonly APP_ID='yt-dlp-aria2-downloader'
readonly SCRIPT_NAME="${0##*/}"

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
    cat >"${DESKTOP_FILE}" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=yt-dlp aria2 downloader
Comment=Download a video or extract an audio track
Exec=${desktop_exec}
Icon=video-x-generic
Terminal=false
Categories=AudioVideo;
StartupNotify=true
EOF_DESKTOP
    chmod 644 -- "${DESKTOP_FILE}"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "${APPLICATION_DIR}" >/dev/null 2>&1 || true
    fi
    printf 'Launcher installed: %s\n' "${DESKTOP_FILE}"
    ;;
uninstall)
    rm -f -- "${DESKTOP_FILE}"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "${APPLICATION_DIR}" >/dev/null 2>&1 || true
    fi
    printf 'Launcher removed: %s\n' "${DESKTOP_FILE}"
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
