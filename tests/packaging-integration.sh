#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly project_dir
# Resolve the assertion library relative to this test script.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${script_dir}/lib/assert.sh"

for command_name in desktop-file-validate readlink stat; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

version_output=$("${project_dir}/download-video.sh" --version)
version=${version_output##* }
[[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Invalid project version: ${version}"

root=$(mktemp -d)
cleanup() {
    rm -rf -- "${root}"
}
trap cleanup EXIT HUP INT TERM

bash "${project_dir}/packaging/install-tree.sh" \
    "${root}" "${version}" '/usr/lib/yt-dlp-aria2-downloader'

private_dir="${root}/usr/lib/yt-dlp-aria2-downloader"
for executable in download-video.sh download-video-gui.sh progress-monitor.sh; do
    [[ -x ${private_dir}/${executable} && ! -L ${private_dir}/${executable} ]] ||
        fail "Missing packaged executable: ${executable}"
    mode=$(stat -c '%a' -- "${private_dir}/${executable}")
    assert_equals '755' "${mode}" "${executable} permissions"
done

cli_link_target=$(readlink -- \
    "${root}/usr/bin/yt-dlp-aria2-downloader")
gui_link_target=$(readlink -- \
    "${root}/usr/bin/yt-dlp-aria2-downloader-gui")
packaged_version=$(
    "${root}/usr/bin/yt-dlp-aria2-downloader" --version
)
assert_equals '../lib/yt-dlp-aria2-downloader/download-video.sh' \
    "${cli_link_target}" 'packaged CLI symlink target'
assert_equals '../lib/yt-dlp-aria2-downloader/download-video-gui.sh' \
    "${gui_link_target}" 'packaged GUI symlink target'
assert_equals "yt-dlp-aria2-downloader version ${version}" \
    "${packaged_version}" 'packaged CLI version'

desktop_file="${root}/usr/share/applications/yt-dlp-aria2-downloader.desktop"
desktop-file-validate --no-hints "${desktop_file}"
assert_file_contains "${desktop_file}" \
    'Exec=/usr/bin/yt-dlp-aria2-downloader-gui' 'system desktop Exec'
assert_file_contains "${desktop_file}" \
    'TryExec=/usr/bin/yt-dlp-aria2-downloader-gui' 'system desktop TryExec'
assert_file_contains "${desktop_file}" \
    'Icon=yt-dlp-aria2-downloader' 'dedicated packaged icon name'

icon_file="${root}/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
[[ -f ${icon_file} && ! -L ${icon_file} ]] ||
    fail 'Missing packaged application icon.'
icon_mode=$(stat -c '%a' -- "${icon_file}")
assert_equals '644' "${icon_mode}" 'packaged icon permissions'

for document in README.md README.fr.md CHANGELOG.md; do
    document_path="${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/${document}"
    [[ -f ${document_path} && ! -L ${document_path} ]] ||
        fail "Missing packaged document: ${document}"
    mode=$(stat -c '%a' -- "${document_path}")
    assert_equals '644' "${mode}" "${document} permissions"
done

[[ ! -e ${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/tests ]] ||
    fail 'Package tree contains the test suite.'
[[ ! -e ${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/docs ]] ||
    fail 'Package tree contains obsolete screenshots.'
[[ ! -e ${private_dir}/install-gui.sh ]] ||
    fail 'System package contains the source-tree launcher installer.'

printf 'Packaging integration tests passed.\n'
