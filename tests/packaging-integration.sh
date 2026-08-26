#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/packaging-integration.sh
# Purpose     : Validate the staged package install tree.
# ==============================================================================

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly PROJECT_DIR
# Resolve the assertion library relative to this test script.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

for command_name in desktop-file-validate readlink stat; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

version_output=$("${PROJECT_DIR}/download-video.sh" --version)
version=${version_output##* }
[[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "Invalid project version: ${version}"

root=$(mktemp -d)

cleanup() {
    rm -rf -- "${root}"
}

main() {
    local invalid_private_dir=''
    local invalid_root=''
    local alternate_root=''
    local alternate_cli_link_target=''

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for invalid_private_dir in \
        '/usr/' \
        '/usr/.' \
        '/usr/..' \
        '/usr//lib/yt-dlp-aria2-downloader' \
        '/usr/lib/yt-dlp-aria2-downloader/' \
        '/usr/lib/../lib/yt-dlp-aria2-downloader' \
        '/opt/yt-dlp-aria2-downloader' \
        'usr/lib/yt-dlp-aria2-downloader'; do
        invalid_root="${root}/invalid-${RANDOM}-${RANDOM}"
        if bash "${PROJECT_DIR}/packaging/install-tree.sh" \
            "${invalid_root}" "${version}" "${invalid_private_dir}" \
            >/dev/null 2>&1; then
            fail "install-tree accepted unsafe PRIVATE_DIR: ${invalid_private_dir}"
        fi
        [[ ! -e ${invalid_root} ]] \
            || fail "Rejected PRIVATE_DIR created a staging tree: ${invalid_private_dir}"
    done

    alternate_root="${root}/libexec-case"
    bash "${PROJECT_DIR}/packaging/install-tree.sh" \
        "${alternate_root}" "${version}" \
        '/usr/libexec/yt-dlp-aria2-downloader' >/dev/null
    alternate_cli_link_target=$(readlink -- \
        "${alternate_root}/usr/bin/yt-dlp-aria2-downloader")
    assert_equals '../libexec/yt-dlp-aria2-downloader/download-video.sh' \
        "${alternate_cli_link_target}" \
        'packaged CLI libexec symlink target'

    bash "${PROJECT_DIR}/packaging/install-tree.sh" \
        "${root}" "${version}" '/usr/lib/yt-dlp-aria2-downloader'

    private_dir="${root}/usr/lib/yt-dlp-aria2-downloader"
    for executable in \
        download-video.sh \
        download-video-gui.sh \
        progress-monitor.sh \
        runtime-manager.sh \
        package-user-cleanup.sh; do
        [[ -x ${private_dir}/${executable} && ! -L ${private_dir}/${executable} ]] \
            || fail "Missing packaged executable: ${executable}"
        mode=$(stat -c '%a' -- "${private_dir}/${executable}")
        assert_equals '755' "${mode}" "${executable} permissions"
    done

    private_aria2_helper="${private_dir}/private-aria2-plan.py"
    [[ -f ${private_aria2_helper} &&
        ! -L ${private_aria2_helper} &&
        ! -x ${private_aria2_helper} ]] \
        || fail 'Missing or unsafe packaged private aria2 helper.'
    helper_mode=$(stat -c '%a' -- "${private_aria2_helper}")
    assert_equals '644' "${helper_mode}" \
        'private-aria2-plan.py permissions'

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
    [[ -f ${icon_file} && ! -L ${icon_file} ]] \
        || fail 'Missing packaged application icon.'
    icon_mode=$(stat -c '%a' -- "${icon_file}")
    assert_equals '644' "${icon_mode}" 'packaged icon permissions'

    for document in README.md README.fr.md CHANGELOG.md; do
        document_path="${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/${document}"
        [[ -f ${document_path} && ! -L ${document_path} ]] \
            || fail "Missing packaged document: ${document}"
        mode=$(stat -c '%a' -- "${document_path}")
        assert_equals '644' "${mode}" "${document} permissions"
    done

    [[ ! -e ${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/tests ]] \
        || fail 'Package tree contains the test suite.'
    [[ ! -e ${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/docs ]] \
        || fail 'Package tree contains obsolete screenshots.'
    [[ ! -e ${private_dir}/install-gui.sh ]] \
        || fail 'System package contains the source-tree launcher installer.'
    key_file="${private_dir}/keys/yt-dlp-public.key"
    [[ -f ${key_file} && ! -L ${key_file} ]] \
        || fail 'Package tree is missing the yt-dlp signing key.'
    key_mode=$(stat -c '%a' -- "${key_file}")
    assert_equals '644' "${key_mode}" 'packaged yt-dlp signing-key permissions'

    printf 'Packaging integration tests passed.\n'

}

main "$@"
