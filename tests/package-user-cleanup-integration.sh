#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/package-user-cleanup-integration.sh
# Purpose     : Validate safe cleanup of package-owned per-user data.
# ==============================================================================

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR PROJECT_DIR
readonly HELPER="${PROJECT_DIR}/packaging/package-user-cleanup.sh"
readonly APP_ID='yt-dlp-aria2-downloader'
readonly SENTINEL='.package-runtime-owner-v1'
readonly MARKER='.package-runtime-data-home-v1'

root=''

# Resolve the assertion library relative to this test script.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

cleanup() {
    if [[ -n ${root} ]]; then
        rm -rf -- "${root}" || true
    fi
}

assert_absent() {
    local path=$1
    [[ ! -e ${path} && ! -L ${path} ]] \
        || fail "path should have been removed: ${path}"
}

assert_present() {
    local path=$1
    [[ -e ${path} || -L ${path} ]] \
        || fail "path should have been preserved: ${path}"
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

require_cleanup_test_environment() {
    local command_name=''

    for command_name in bash chmod grep ln mkdir mktemp rm stat touch; do
        require_test_command "${command_name}"
    done
    [[ -x ${HELPER} ]] || fail "cleanup helper is not executable: ${HELPER}"
}

initialize_cleanup_test_workspace() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    root=$(mktemp -d)
    readonly root
}

test_valid_custom_xdg_cleanup() {
    local home="${root}/home-valid"
    local default_data="${home}/.local/share"
    local custom_data="${root}/custom-valid"
    local app_root="${default_data}/${APP_ID}"
    local marker="${app_root}/${MARKER}"
    local removed=''

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
    ln -s -- "${PROJECT_DIR}/download-video-gui.sh" "${app_root}/launch"

    bash "${HELPER}" --user-home "${home}"

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
    [[ -L ${app_root}/launch ]] \
        || fail 'portable launch link was removed unexpectedly'
    [[ -f ${home}/yt-dlp-aria2-downloader-gui-NOTES.txt ]] \
        || fail 'similarly named unrelated file was removed unexpectedly'
}

test_forged_marker_preservation() {
    local home="${root}/home-forged-marker"
    local default_data="${home}/.local/share"
    local marker="${default_data}/${APP_ID}/${MARKER}"
    local foreign_data="${root}/foreign-data"

    mkdir -p \
        "${default_data}/${APP_ID}/runtime/default" \
        "${foreign_data}/${APP_ID}/runtime/valuable"
    touch "${foreign_data}/${APP_ID}/runtime/valuable/keep"
    printf '%s\n' "${foreign_data}" >"${marker}"
    chmod 600 -- "${marker}"

    bash "${HELPER}" --user-home "${home}"
    assert_absent "${default_data}/${APP_ID}/runtime"
    assert_present "${foreign_data}/${APP_ID}/runtime/valuable/keep"
}

test_multiline_marker_rejection() {
    local home="${root}/home-multiline"
    local default_data="${home}/.local/share"
    local marker="${default_data}/${APP_ID}/${MARKER}"
    local custom_data="${root}/custom-multiline"

    mkdir -p \
        "${default_data}/${APP_ID}" \
        "${custom_data}/${APP_ID}/runtime/valuable"
    touch "${custom_data}/${APP_ID}/runtime/valuable/keep"
    write_valid_sentinel "${custom_data}" "${home}"
    printf '%s\n%s\n' \
        "${custom_data}" "${root}/unexpected-second-line" >"${marker}"
    chmod 600 -- "${marker}"

    bash "${HELPER}" --user-home "${home}"
    assert_present "${custom_data}/${APP_ID}/runtime/valuable/keep"
}

test_symlinked_sentinel_rejection() {
    local home="${root}/home-symlink-sentinel"
    local default_data="${home}/.local/share"
    local marker="${default_data}/${APP_ID}/${MARKER}"
    local custom_data="${root}/custom-symlink-sentinel"
    local external_sentinel="${root}/external-sentinel"

    mkdir -p \
        "${default_data}/${APP_ID}" \
        "${custom_data}/${APP_ID}/runtime/valuable"
    touch "${custom_data}/${APP_ID}/runtime/valuable/keep"
    printf 'app=%s\nuid=%s\nhome=%s\ndata=%s\n' \
        "${APP_ID}" "${EUID}" "${home}" "${custom_data}" \
        >"${external_sentinel}"
    chmod 600 -- "${external_sentinel}"
    ln -s -- "${external_sentinel}" \
        "${custom_data}/${APP_ID}/${SENTINEL}"
    printf '%s\n' "${custom_data}" >"${marker}"
    chmod 600 -- "${marker}"

    bash "${HELPER}" --user-home "${home}"
    assert_present "${custom_data}/${APP_ID}/runtime/valuable/keep"
}

test_terminal_runtime_symlink() {
    local home="${root}/home-terminal-symlink"
    local default_data="${home}/.local/share"
    local protected="${root}/protected-runtime-target"

    mkdir -p "${default_data}/${APP_ID}" "${protected}"
    touch "${protected}/keep"
    ln -s -- "${protected}" "${default_data}/${APP_ID}/runtime"

    bash "${HELPER}" --user-home "${home}"
    assert_absent "${default_data}/${APP_ID}/runtime"
    assert_present "${protected}/keep"
}

test_control_character_marker() {
    local home="${root}/home-control-marker"
    local default_data="${home}/.local/share"
    local marker="${default_data}/${APP_ID}/${MARKER}"
    local control_candidate="${root}/control"$'\033'"candidate"
    local control_output=''
    local control_status=0

    mkdir -p "${default_data}/${APP_ID}"
    printf '%s\n' "${control_candidate}" >"${marker}"
    chmod 600 -- "${marker}"

    control_output=$(bash "${HELPER}" --user-home "${home}" 2>&1) \
        || control_status=$?
    if ((control_status != 0)); then
        printf 'FAIL: control-character marker cleanup returned %d.\n' \
            "${control_status}" >&2
        printf '%s\n' "${control_output}" >&2
        exit 65
    fi
    [[ ${control_output} != *$'\033'* ]] \
        || fail 'cleanup reflected an ESC control character from a marker into diagnostics'
    [[ ${control_output} == *'ignoring invalid or multi-line runtime location marker:'* ]] \
        || fail 'cleanup did not diagnose a control-character marker as invalid'
}

test_unavailable_home() {
    bash "${HELPER}" --user-home "${root}/does-not-exist"
}

test_oversized_marker() {
    local home="${root}/home-oversized-marker"
    local default_data="${home}/.local/share"
    local marker="${default_data}/${APP_ID}/${MARKER}"
    local custom_data="${root}/custom-oversized-marker"
    local oversized_marker=''

    mkdir -p \
        "${default_data}/${APP_ID}" \
        "${custom_data}/${APP_ID}/runtime/valuable"
    touch "${custom_data}/${APP_ID}/runtime/valuable/keep"
    printf -v oversized_marker '%*s' 5000 ''
    printf '%s\n' "${oversized_marker}" >"${marker}"
    chmod 600 -- "${marker}"

    bash "${HELPER}" --user-home "${home}"
    assert_present "${custom_data}/${APP_ID}/runtime/valuable/keep"
}

test_foreign_owned_home_rejection() {
    local foreign_home="${root}/foreign-owned-home"
    local foreign_output=''
    local foreign_status=0

    if ((EUID != 0)) || ! command -v chown >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "${foreign_home}/.local/share/${APP_ID}/runtime/valuable"
    touch "${foreign_home}/.local/share/${APP_ID}/runtime/valuable/keep"
    chown -R 65534:65534 "${foreign_home}"
    foreign_output=$(bash "${HELPER}" --user-home "${foreign_home}" 2>&1) \
        || foreign_status=$?
    [[ ${foreign_status} == 77 ]] \
        || fail "root cross-user --user-home returned ${foreign_status}, expected 77"
    grep -Fq 'not owned by effective uid' <<<"${foreign_output}" \
        || fail 'root cross-user --user-home diagnostic is missing'
    assert_present "${foreign_home}/.local/share/${APP_ID}/runtime/valuable/keep"
    chown -R 0:0 "${foreign_home}"
}

test_symlinked_foreign_home_rejection() {
    local foreign_target="${root}/foreign-owned-home-target"
    local foreign_link_home="${root}/foreign-owned-home-link"
    local foreign_output=''
    local foreign_status=0

    if ((EUID != 0)) || ! command -v chown >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p \
        "${foreign_target}/.local/share/${APP_ID}/runtime/valuable"
    touch "${foreign_target}/.local/share/${APP_ID}/runtime/valuable/keep"
    chown -R 65534:65534 "${foreign_target}"
    ln -s -- "${foreign_target}" "${foreign_link_home}"
    foreign_output=$(bash "${HELPER}" --user-home "${foreign_link_home}" 2>&1) \
        || foreign_status=$?
    [[ ${foreign_status} == 77 ]] \
        || fail "root cross-user symlinked --user-home returned ${foreign_status}, expected 77"
    grep -Fq 'not owned by effective uid' <<<"${foreign_output}" \
        || fail 'root cross-user symlinked --user-home diagnostic is missing'
    assert_present \
        "${foreign_target}/.local/share/${APP_ID}/runtime/valuable/keep"
    chown -R 0:0 "${foreign_target}"
}

main() {
    require_cleanup_test_environment
    initialize_cleanup_test_workspace
    test_valid_custom_xdg_cleanup
    test_forged_marker_preservation
    test_multiline_marker_rejection
    test_symlinked_sentinel_rejection
    test_terminal_runtime_symlink
    test_control_character_marker
    test_unavailable_home
    test_oversized_marker
    test_foreign_owned_home_rejection
    test_symlinked_foreign_home_rejection

    printf 'Package user cleanup integration tests passed.\n'
}

main "$@"
