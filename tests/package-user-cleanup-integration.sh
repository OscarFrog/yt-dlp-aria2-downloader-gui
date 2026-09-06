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

write_historical_portable_desktop() {
    local desktop_path=$1
    local exec_path=$2
    local icon_name=$3
    local comment_schema=$4

    mkdir -p -- "${desktop_path%/*}"
    {
        printf '%s\n' \
            '[Desktop Entry]' \
            'Type=Application' \
            'Version=1.0' \
            'Name=yt-dlp aria2 downloader'
        case ${comment_schema} in
            french)
                printf '%s\n' \
                    'Comment=Télécharger une vidéo ou extraire une piste audio'
                ;;
            english)
                printf '%s\n' \
                    'Comment=Download a video or extract an audio track'
                ;;
            bilingual)
                printf '%s\n' \
                    'Comment=Download a video or extract an audio track' \
                    'Comment[fr]=Télécharger une vidéo ou extraire une piste audio'
                ;;
            *) fail "unknown historical desktop comment schema: ${comment_schema}" ;;
        esac
        printf '%s\n' \
            "Exec=\"${exec_path}\"" \
            "Icon=${icon_name}" \
            'Terminal=false' \
            'Categories=AudioVideo;' \
            'StartupNotify=true'
    } >"${desktop_path}"
    chmod 644 -- "${desktop_path}"
}

write_portable_desktop() {
    local desktop_path=$1
    local data_home=$2
    local icon_name=$3

    write_historical_portable_desktop \
        "${desktop_path}" "${data_home}/${APP_ID}/launch" \
        "${icon_name}" bilingual
}

build_direct_target_with_byte_length() {
    local output_variable=$1
    local home=$2
    local target_length=$3
    local suffix='/download-video-gui.sh'
    local padding_length=0
    local padding=''
    local target=''
    local LC_ALL=C

    padding_length=$((target_length - ${#home} - 1 - ${#suffix}))
    ((padding_length > 0)) \
        || fail "unable to build a ${target_length}-byte target below: ${home}"
    printf -v padding '%*s' "${padding_length}" ''
    padding=${padding// /x}
    target="${home}/${padding}${suffix}"
    ((${#target} == target_length)) \
        || fail "direct target has ${#target} bytes instead of ${target_length}"
    printf -v "${output_variable}" '%s' "${target}"
}

require_cleanup_test_environment() {
    local command_name=''

    for command_name in \
        bash chmod cmp grep ln mkdir mktemp readlink rm sed stat touch; do
        require_test_command "${command_name}"
    done
    [[ -x ${HELPER} ]] || fail "cleanup helper is not executable: ${HELPER}"
}

test_legacy_portable_launcher_migration() {
    local home="${root}/home-launcher-migration"
    local data_home="${home}/.local/share"
    local desktop_path="${data_home}/applications/${APP_ID}.desktop"
    local launcher_dir="${data_home}/${APP_ID}"
    local launcher_target="${home}/portable-gui.sh"
    local retained_target=''

    mkdir -p -- "${launcher_dir}"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${launcher_target}"
    chmod 755 -- "${launcher_target}"
    ln -s -- "${launcher_target}" "${launcher_dir}/launch"
    write_portable_desktop \
        "${desktop_path}" "${data_home}" video-x-generic

    bash "${HELPER}" --user-home-migrate-launcher "${home}"

    assert_absent "${desktop_path}"
    assert_present "${launcher_dir}/launch"
    assert_present "${launcher_target}"
    retained_target=$(readlink -- "${launcher_dir}/launch")
    assert_equals "${launcher_target}" "${retained_target}" \
        'legacy launcher migration preserves the portable target link'
}

test_historical_direct_launcher_migration() {
    local schema=''
    local home=''
    local data_home=''
    local desktop_path=''
    local direct_target=''
    local desktop_size=''

    for schema in french english bilingual; do
        home="${root}/home-direct-${schema}"
        data_home="${home}/.local/share"
        desktop_path="${data_home}/applications/${APP_ID}.desktop"
        if [[ ${schema} == french ]]; then
            # The French-only schema contributes 221 bytes outside its Exec
            # target, so an 81-byte path recreates the reported 302-byte file.
            build_direct_target_with_byte_length direct_target "${home}" 81
        else
            direct_target="${home}/source-${schema}/download-video-gui.sh"
        fi
        write_historical_portable_desktop \
            "${desktop_path}" "${direct_target}" \
            video-x-generic "${schema}"

        if [[ ${schema} == french ]]; then
            desktop_size=$(stat -c '%s' -- "${desktop_path}")
            assert_equals 302 "${desktop_size}" \
                'French direct-Exec historical desktop fixture size'
        fi

        bash "${HELPER}" --user-home-migrate-launcher "${home}"
        assert_absent "${desktop_path}"
    done
}

test_direct_launcher_migration_rejects_ambiguous_exec() {
    local case_name=''
    local home=''
    local desktop_path=''
    local direct_target=''

    for case_name in wrong-basename noncanonical escaped-metacharacter; do
        home="${root}/home-ambiguous-direct-${case_name}"
        desktop_path="${home}/.local/share/applications/${APP_ID}.desktop"
        case ${case_name} in
            wrong-basename)
                direct_target="${home}/source/not-the-gui.sh"
                ;;
            noncanonical)
                direct_target="${home}/source/../download-video-gui.sh"
                ;;
            escaped-metacharacter)
                direct_target="${home}/source%%unsafe/download-video-gui.sh"
                ;;
            *) fail "unknown ambiguous direct-Exec case: ${case_name}" ;;
        esac
        write_historical_portable_desktop \
            "${desktop_path}" "${direct_target}" video-x-generic french

        bash "${HELPER}" --user-home-migrate-launcher "${home}"
        assert_present "${desktop_path}"
    done
}

test_launcher_migration_preserves_nonlegacy_candidates() {
    local current_home="${root}/home-current-launcher"
    local current_data="${current_home}/.local/share"
    local current_desktop="${current_data}/applications/${APP_ID}.desktop"
    local modified_home="${root}/home-modified-launcher"
    local modified_data="${modified_home}/.local/share"
    local modified_desktop="${modified_data}/applications/${APP_ID}.desktop"
    local mode_home="${root}/home-mode-modified-launcher"
    local mode_data="${mode_home}/.local/share"
    local mode_desktop="${mode_data}/applications/${APP_ID}.desktop"
    local symlink_home="${root}/home-symlink-launcher"
    local symlink_data="${symlink_home}/.local/share"
    local symlink_desktop="${symlink_data}/applications/${APP_ID}.desktop"
    local symlink_target="${root}/symlink-launcher-target.desktop"
    local directory_home="${root}/home-directory-launcher"
    local directory_desktop="${directory_home}/.local/share/applications/${APP_ID}.desktop"
    local outside_home="${root}/home-outside-direct-launcher"
    local outside_data="${outside_home}/.local/share"
    local outside_desktop="${outside_data}/applications/${APP_ID}.desktop"
    local outside_target="${root}/outside-source/download-video-gui.sh"

    write_portable_desktop \
        "${current_desktop}" "${current_data}" "${APP_ID}"
    bash "${HELPER}" --user-home-migrate-launcher "${current_home}"
    assert_present "${current_desktop}"

    write_portable_desktop \
        "${modified_desktop}" "${modified_data}" video-x-generic
    printf '%s\n' 'X-User-Modified=true' >>"${modified_desktop}"
    bash "${HELPER}" --user-home-migrate-launcher "${modified_home}"
    assert_present "${modified_desktop}"

    write_portable_desktop \
        "${mode_desktop}" "${mode_data}" video-x-generic
    chmod 600 -- "${mode_desktop}"
    bash "${HELPER}" --user-home-migrate-launcher "${mode_home}"
    assert_present "${mode_desktop}"

    write_portable_desktop \
        "${symlink_target}" "${symlink_data}" video-x-generic
    mkdir -p -- "${symlink_desktop%/*}"
    ln -s -- "${symlink_target}" "${symlink_desktop}"
    bash "${HELPER}" --user-home-migrate-launcher "${symlink_home}"
    assert_present "${symlink_desktop}"
    assert_present "${symlink_target}"

    mkdir -p -- "${directory_desktop}/keep"
    touch -- "${directory_desktop}/keep/value"
    bash "${HELPER}" --user-home-migrate-launcher "${directory_home}"
    assert_present "${directory_desktop}/keep/value"

    write_historical_portable_desktop \
        "${outside_desktop}" "${outside_target}" video-x-generic french
    bash "${HELPER}" --user-home-migrate-launcher "${outside_home}"
    assert_present "${outside_desktop}"
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
        "${default_data}/icons/hicolor/scalable/apps/${APP_ID}.svg" \
        "${home}/.config/autostart/yt-dlp-aria2-downloader-gui.desktop" \
        "${home}/yt-dlp-aria2-downloader-gui-NOTES.txt"
    printf '%s\n' "${custom_data}" >"${marker}"
    chmod 600 -- "${marker}"
    write_valid_sentinel "${custom_data}" "${home}"
    ln -s -- "${PROJECT_DIR}/download-video-gui.sh" "${app_root}/launch"
    write_portable_desktop \
        "${default_data}/applications/${APP_ID}.desktop" \
        "${default_data}" video-x-generic

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
    assert_present "${default_data}/applications/${APP_ID}.desktop"
    assert_present \
        "${default_data}/icons/hicolor/scalable/apps/${APP_ID}.svg"
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

test_numeric_identity_bounds() {
    local cleanup_source_copy="${root}/package-user-cleanup-source-only.sh"
    local invalid_home="${root}/invalid-numeric-id-home"
    local invalid_output=''
    local invalid_status=0

    sed '$d' "${HELPER}" >"${cleanup_source_copy}"
    chmod 0600 -- "${cleanup_source_copy}"
    mkdir -p -- "${invalid_home}/.local/share/${APP_ID}/runtime/valuable"
    touch -- "${invalid_home}/.local/share/${APP_ID}/runtime/valuable/keep"

    invalid_output=$(
        bash -c '
            set -euo pipefail
            source "$1"
            run_as_user 18446744073709551616 0 "$2"
        ' bash "${cleanup_source_copy}" "${invalid_home}" 2>&1
    ) || invalid_status=$?
    assert_equals 0 "${invalid_status}" \
        'overflowing numeric identity is skipped without aborting package cleanup'
    assert_text_contains "${invalid_output}" \
        'refusing invalid numeric uid/gid' \
        'overflowing numeric identity diagnostic'
    assert_present \
        "${invalid_home}/.local/share/${APP_ID}/runtime/valuable/keep"

    # shellcheck disable=SC2016 # Variables belong to the intentionally nested shell.
    assert_status 0 'maximum Linux UID/GID is accepted without arithmetic' \
        bash -c '
            set -euo pipefail
            source "$1"
            normalized=""
            normalize_linux_id normalized 0004294967294
            [[ ${normalized} == 4294967294 ]]
            ! normalize_linux_id normalized 4294967295
        ' bash "${cleanup_source_copy}"
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
    test_legacy_portable_launcher_migration
    test_historical_direct_launcher_migration
    test_direct_launcher_migration_rejects_ambiguous_exec
    test_launcher_migration_preserves_nonlegacy_candidates
    test_valid_custom_xdg_cleanup
    test_forged_marker_preservation
    test_multiline_marker_rejection
    test_symlinked_sentinel_rejection
    test_terminal_runtime_symlink
    test_control_character_marker
    test_unavailable_home
    test_oversized_marker
    test_numeric_identity_bounds
    test_foreign_owned_home_rejection
    test_symlinked_foreign_home_rejection

    printf 'Package user cleanup integration tests passed.\n'
}

main "$@"
