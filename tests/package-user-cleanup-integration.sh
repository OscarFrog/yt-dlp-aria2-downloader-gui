#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly script_dir project_dir
readonly helper="${project_dir}/packaging/package-user-cleanup.sh"
readonly APP_ID='yt-dlp-aria2-downloader'
readonly SENTINEL='.package-runtime-owner-v1'
readonly MARKER='.package-runtime-data-home-v1'

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 65
}

for command_name in bash ln mkdir mktemp rm stat touch; do
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

assert_absent() {
    local path=$1
    [[ ! -e ${path} && ! -L ${path} ]] ||
        fail "path should have been removed: ${path}"
}

assert_present() {
    local path=$1
    [[ -e ${path} || -L ${path} ]] ||
        fail "path should have been preserved: ${path}"
}

write_valid_sentinel() {
    local base=$1
    local home=$2
    local sentinel="${base}/${APP_ID}/${SENTINEL}"

    mkdir -p -- "${base}/${APP_ID}"
    chmod 700 -- "${base}/${APP_ID}"
    printf 'app=%s\nuid=%s\nhome=%s\ndata=%s\n' \
        "${APP_ID}" "${EUID}" "${home}" "${base}" >"${sentinel}"
    chmod 600 -- "${sentinel}"
}

# Case 1: valid custom XDG registration is cleaned, exact unrelated data and a
# portable launcher are preserved.
home="${root}/home-valid"
default_data="${home}/.local/share"
custom_data="${root}/custom-valid"
app_root="${default_data}/${APP_ID}"
marker="${app_root}/${MARKER}"

mkdir -p \
    "${default_data}/${APP_ID}/runtime/default-probe" \
    "${default_data}/yt-dlp-aria2-downloader-gui" \
    "${default_data}/applications" \
    "${default_data}/icons/hicolor/scalable/apps" \
    "${home}/.config/yt-dlp-aria2-downloader-gui" \
    "${home}/.config/autostart" \
    "${home}/.local/state/yt-dlp-aria2-downloader-gui" \
    "${home}/.cache/yt-dlp-aria2-downloader-gui" \
    "${custom_data}/${APP_ID}/runtime/custom-probe" \
    "${custom_data}/yt-dlp-aria2-downloader-gui"

touch \
    "${default_data}/applications/yt-dlp-aria2-downloader-gui.desktop" \
    "${default_data}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader-gui.svg" \
    "${home}/.config/autostart/yt-dlp-aria2-downloader-gui.desktop" \
    "${home}/yt-dlp-aria2-downloader-gui-NOTES.txt"

printf '%s\n' "${custom_data}" >"${marker}"
chmod 600 -- "${marker}"
write_valid_sentinel "${custom_data}" "${home}"
ln -s -- "${project_dir}/download-video-gui.sh" "${app_root}/launch"

bash "${helper}" --user-home "${home}"

for removed in \
    "${default_data}/${APP_ID}/runtime" \
    "${default_data}/yt-dlp-aria2-downloader-gui" \
    "${default_data}/applications/yt-dlp-aria2-downloader-gui.desktop" \
    "${default_data}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader-gui.svg" \
    "${home}/.config/yt-dlp-aria2-downloader-gui" \
    "${home}/.config/autostart/yt-dlp-aria2-downloader-gui.desktop" \
    "${home}/.local/state/yt-dlp-aria2-downloader-gui" \
    "${home}/.cache/yt-dlp-aria2-downloader-gui" \
    "${custom_data}/${APP_ID}/runtime" \
    "${custom_data}/yt-dlp-aria2-downloader-gui" \
    "${custom_data}/${APP_ID}/${SENTINEL}" \
    "${marker}"; do
    assert_absent "${removed}"
done

[[ -L ${app_root}/launch ]] ||
    fail 'portable launch link was removed unexpectedly'
[[ -f ${home}/yt-dlp-aria2-downloader-gui-NOTES.txt ]] ||
    fail 'similarly named unrelated file was removed unexpectedly'

# Case 2: a forged absolute marker cannot authorize deletion by itself, even
# though the candidate contains exactly the allowlisted runtime suffix.
home="${root}/home-forged-marker"
default_data="${home}/.local/share"
marker="${default_data}/${APP_ID}/${MARKER}"
foreign_data="${root}/foreign-data"

mkdir -p \
    "${default_data}/${APP_ID}/runtime/default" \
    "${foreign_data}/${APP_ID}/runtime/valuable"
touch "${foreign_data}/${APP_ID}/runtime/valuable/keep"
printf '%s\n' "${foreign_data}" >"${marker}"
chmod 600 -- "${marker}"

bash "${helper}" --user-home "${home}"
assert_absent "${default_data}/${APP_ID}/runtime"
assert_present "${foreign_data}/${APP_ID}/runtime/valuable/keep"

# Case 3: a multi-line marker is rejected even if the first path has a valid
# ownership sentinel.
home="${root}/home-multiline"
default_data="${home}/.local/share"
marker="${default_data}/${APP_ID}/${MARKER}"
custom_data="${root}/custom-multiline"

mkdir -p \
    "${default_data}/${APP_ID}" \
    "${custom_data}/${APP_ID}/runtime/valuable"
touch "${custom_data}/${APP_ID}/runtime/valuable/keep"
write_valid_sentinel "${custom_data}" "${home}"
printf '%s\n%s\n' "${custom_data}" "${root}/unexpected-second-line" >"${marker}"
chmod 600 -- "${marker}"

bash "${helper}" --user-home "${home}"
assert_present "${custom_data}/${APP_ID}/runtime/valuable/keep"

# Case 4: a symlinked sentinel never authorizes a custom data root.
home="${root}/home-symlink-sentinel"
default_data="${home}/.local/share"
marker="${default_data}/${APP_ID}/${MARKER}"
custom_data="${root}/custom-symlink-sentinel"
external_sentinel="${root}/external-sentinel"

mkdir -p \
    "${default_data}/${APP_ID}" \
    "${custom_data}/${APP_ID}/runtime/valuable"
touch "${custom_data}/${APP_ID}/runtime/valuable/keep"
printf 'app=%s\nuid=%s\nhome=%s\ndata=%s\n' \
    "${APP_ID}" "${EUID}" "${home}" "${custom_data}" >"${external_sentinel}"
chmod 600 -- "${external_sentinel}"
ln -s -- "${external_sentinel}" "${custom_data}/${APP_ID}/${SENTINEL}"
printf '%s\n' "${custom_data}" >"${marker}"
chmod 600 -- "${marker}"

bash "${helper}" --user-home "${home}"
assert_present "${custom_data}/${APP_ID}/runtime/valuable/keep"

# Case 5: rm of a terminal runtime symlink removes only the link, never the
# symlink target.
home="${root}/home-terminal-symlink"
default_data="${home}/.local/share"
protected="${root}/protected-runtime-target"

mkdir -p "${default_data}/${APP_ID}" "${protected}"
touch "${protected}/keep"
ln -s -- "${protected}" "${default_data}/${APP_ID}/runtime"

bash "${helper}" --user-home "${home}"
assert_absent "${default_data}/${APP_ID}/runtime"
assert_present "${protected}/keep"

# Unavailable homes are a non-destructive best-effort skip.
bash "${helper}" --user-home "${root}/does-not-exist"

printf 'Package user cleanup integration tests passed.\n'
