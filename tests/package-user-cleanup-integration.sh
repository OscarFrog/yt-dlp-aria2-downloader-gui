#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly script_dir project_dir
readonly helper="${project_dir}/packaging/package-user-cleanup.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 65
}

for command_name in bash ln mkdir mktemp rm touch; do
    command -v -- "${command_name}" >/dev/null 2>&1 ||
        fail "required command is absent: ${command_name}"
done

[[ -x ${helper} ]] || fail "cleanup helper is not executable: ${helper}"

root=$(mktemp -d)
readonly root
cleanup() {
    rm -rf -- "${root}" || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

home="${root}/home"
default_data="${home}/.local/share"
custom_data="${home}/custom-xdg-data"
app_root="${default_data}/yt-dlp-aria2-downloader"
marker="${app_root}/.package-runtime-data-home-v1"

mkdir -p \
    "${default_data}/yt-dlp-aria2-downloader/runtime/default-probe" \
    "${default_data}/yt-dlp-aria2-downloader-gui" \
    "${default_data}/applications" \
    "${default_data}/icons/hicolor/scalable/apps" \
    "${home}/.config/yt-dlp-aria2-downloader-gui" \
    "${home}/.config/autostart" \
    "${home}/.local/state/yt-dlp-aria2-downloader-gui" \
    "${home}/.cache/yt-dlp-aria2-downloader-gui" \
    "${custom_data}/yt-dlp-aria2-downloader/runtime/custom-probe" \
    "${custom_data}/yt-dlp-aria2-downloader-gui"

touch \
    "${default_data}/applications/yt-dlp-aria2-downloader-gui.desktop" \
    "${default_data}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader-gui.svg" \
    "${home}/.config/autostart/yt-dlp-aria2-downloader-gui.desktop" \
    "${home}/yt-dlp-aria2-downloader-gui-NOTES.txt"

printf '%s\n' "${custom_data}" >"${marker}"
ln -s -- "${project_dir}/download-video-gui.sh" "${app_root}/launch"

bash "${helper}" --user-home "${home}"

for removed in \
    "${default_data}/yt-dlp-aria2-downloader/runtime" \
    "${default_data}/yt-dlp-aria2-downloader-gui" \
    "${default_data}/applications/yt-dlp-aria2-downloader-gui.desktop" \
    "${default_data}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader-gui.svg" \
    "${home}/.config/yt-dlp-aria2-downloader-gui" \
    "${home}/.config/autostart/yt-dlp-aria2-downloader-gui.desktop" \
    "${home}/.local/state/yt-dlp-aria2-downloader-gui" \
    "${home}/.cache/yt-dlp-aria2-downloader-gui" \
    "${custom_data}/yt-dlp-aria2-downloader/runtime" \
    "${custom_data}/yt-dlp-aria2-downloader-gui" \
    "${marker}"; do
    [[ ! -e ${removed} && ! -L ${removed} ]] ||
        fail "cleanup left an allowlisted path: ${removed}"
done

[[ -L ${app_root}/launch ]] ||
    fail 'portable launch link was removed unexpectedly'
[[ -f ${home}/yt-dlp-aria2-downloader-gui-NOTES.txt ]] ||
    fail 'similarly named unrelated file was removed unexpectedly'

printf 'Package user cleanup integration tests passed.\n'
