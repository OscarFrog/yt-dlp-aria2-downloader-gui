#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/installer-integration.sh
# Purpose     : Validate desktop installer and launcher lifecycle behavior.
# ==============================================================================

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"

for required_command in \
    bash cat chmod cmp cp desktop-file-validate diff dirname env grep ln mkdir \
    mktemp mv readlink realpath rm rmdir sleep stat; do
    require_test_command "${required_command}"
done

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}" || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

readonly PROJECT_SUFFIX=$'Project space % $ ` quote" backslash\\ equals= apostrophe\' test'
readonly COPIED_PROJECT="${TEST_ROOT}/${PROJECT_SUFFIX}"
readonly DATA_SUFFIX=$'Data space $ ` quote" backslash\\ apostrophe\' test'
readonly DATA_HOME="${TEST_ROOT}/${DATA_SUFFIX}"
readonly APPLICATION_DIR="${DATA_HOME}/applications"
readonly DESKTOP_FILE="${APPLICATION_DIR}/yt-dlp-aria2-downloader.desktop"
readonly LAUNCHER_DIR="${DATA_HOME}/yt-dlp-aria2-downloader"
readonly LAUNCHER_LINK="${LAUNCHER_DIR}/launch"
readonly ICON_FILE="${DATA_HOME}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
readonly EXEC_MARKER="${TEST_ROOT}/gio-launch-marker"

assert_no_install_temporary_files() {
    local label=$1
    local -a leftovers=()

    shopt -s nullglob
    leftovers=(
        "${APPLICATION_DIR}"/.yt-dlp-aria2-downloader.*.tmp
        "${LAUNCHER_DIR}"/.install.*
        "${LAUNCHER_DIR}"/.validate.*.desktop
    )
    shopt -u nullglob

    if ((${#leftovers[@]} != 0)); then
        printf 'FAIL: %s\n' "${label}" >&2
        printf 'Temporary installation artifact remained: %s\n' \
            "${leftovers[@]}" >&2
        exit 1
    fi
}

write_fake_gui() {
    local path=$1

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf "printf '%%s\\\\n' \"\$0\" >%q\n" "${EXEC_MARKER}"
    } >"${path}"
    chmod +x -- "${path}"
}

test_installer_initial_installation() {
    local actual_exec expected_exec gio_deadline gio_timeout

    [[ -x ${PROJECT_DIR}/install-gui.sh ]] \
        || fail 'install-gui.sh is not executable in the source tree.'

    mkdir -p -- "${COPIED_PROJECT}"
    cp -- "${PROJECT_DIR}/install-gui.sh" "${COPIED_PROJECT}/"
    write_fake_gui "${COPIED_PROJECT}/download-video-gui.sh"
    chmod +x -- "${COPIED_PROJECT}/install-gui.sh"

    # shellcheck disable=SC2016 # $1 and $2 are expanded by the child bash.
    assert_status 0 'install desktop launcher from hostile project path' \
        bash -c '
            set -euo pipefail
            umask 077
            export XDG_DATA_HOME="$1"
            exec bash "$2" install
        ' bash "${DATA_HOME}" "${COPIED_PROJECT}/install-gui.sh"

    [[ -f ${DESKTOP_FILE} ]] || fail 'The desktop launcher was not created.'
    [[ -L ${LAUNCHER_LINK} ]] || fail 'The stable launcher link was not created.'
    assert_link_target \
        "${LAUNCHER_LINK}" \
        "${COPIED_PROJECT}/download-video-gui.sh" \
        'stable launcher link target'

    expected_exec='Exec="'
    expected_exec+="${TEST_ROOT}/Data space "
    expected_exec+='\\$'
    expected_exec+=' '
    expected_exec+='\\`'
    expected_exec+=' quote'
    expected_exec+='\\"'
    expected_exec+=' backslash'
    expected_exec+="\\\\\\\\"
    expected_exec+=" apostrophe' test/yt-dlp-aria2-downloader/launch\""
    actual_exec=$(grep -m1 '^Exec=' -- "${DESKTOP_FILE}") \
        || fail 'The installed desktop file has no Exec line.'
    assert_equals "${expected_exec}" "${actual_exec}" \
        'desktop Exec line uses specification-compliant escaping'

    assert_file_has_line "${DESKTOP_FILE}" 'Terminal=false' \
        'desktop terminal setting'
    assert_file_has_no_line "${DESKTOP_FILE}" 'Terminal=true' \
        'desktop terminal is never enabled'
    assert_file_has_line "${DESKTOP_FILE}" 'Categories=AudioVideo;' \
        'desktop category'
    assert_file_has_line "${DESKTOP_FILE}" \
        'Comment=Download a video or extract an audio track' \
        'English desktop comment'
    assert_file_has_line "${DESKTOP_FILE}" \
        'Comment[fr]=Télécharger une vidéo ou extraire une piste audio' \
        'French desktop comment'
    assert_file_has_line "${DESKTOP_FILE}" 'Icon=yt-dlp-aria2-downloader' \
        'dedicated per-user desktop icon name'
    [[ -f ${ICON_FILE} && ! -L ${ICON_FILE} ]] \
        || fail 'The dedicated per-user application icon was not installed.'
    assert_path_mode "${ICON_FILE}" 644 \
        'per-user application icon permissions'

    assert_status 0 'installed launcher passes desktop-file-validate' \
        desktop-file-validate --no-hints "${DESKTOP_FILE}"

    assert_path_mode "${DESKTOP_FILE}" 644 'installed launcher permissions'
    assert_path_mode "${LAUNCHER_DIR}" 700 \
        'private launcher-directory permissions'
    assert_no_install_temporary_files 'temporary cleanup after installation'

    if command -v gio >/dev/null 2>&1; then
        gio_timeout=${GIO_LAUNCH_TIMEOUT:-20}
        [[ ${gio_timeout} =~ ^[1-9][0-9]*$ ]] \
            || fail "GIO_LAUNCH_TIMEOUT must be a positive integer: ${gio_timeout}"
        gio_timeout=$((10#${gio_timeout}))
        rm -f -- "${EXEC_MARKER}"
        assert_status 0 'GLib launches the installed desktop entry' \
            gio launch "${DESKTOP_FILE}"
        gio_deadline=$((SECONDS + gio_timeout))
        while ((SECONDS < gio_deadline)); do
            [[ -s ${EXEC_MARKER} ]] && break
            sleep 0.1
        done
        [[ -s ${EXEC_MARKER} ]] \
            || fail "gio did not launch the stable launcher link within ${gio_timeout}s."
        assert_equals \
            "${LAUNCHER_LINK}" \
            "$(<"${EXEC_MARKER}")" \
            'GLib launches the exact stable path'
    fi
}

test_installer_reinstallation() {
    local VALIDATION_MOCK_BIN
    local launcher_snapshot launcher_target_after_failed_validation
    local launcher_target_before

    # A normal reinstall must remain deterministic and leave no temporary files.
    launcher_snapshot="${TEST_ROOT}/launcher-before-reinstall.desktop"
    cp -- "${DESKTOP_FILE}" "${launcher_snapshot}"
    assert_status 0 'reinstall existing desktop launcher' \
        env XDG_DATA_HOME="${DATA_HOME}" \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    cmp -s -- "${launcher_snapshot}" "${DESKTOP_FILE}" || {
        diff -u -- "${launcher_snapshot}" "${DESKTOP_FILE}" >&2 || true
        fail 'A normal reinstall changed the deterministic desktop entry.'
    }
    assert_no_install_temporary_files 'temporary cleanup after reinstall'

    # A failed validation must not replace the existing launcher or stable link.
    readonly VALIDATION_MOCK_BIN="${TEST_ROOT}/validation-mock-bin"
    mkdir -p -- "${VALIDATION_MOCK_BIN}"
    cat >"${VALIDATION_MOCK_BIN}/desktop-file-validate" <<'EOF_VALIDATE'
#!/usr/bin/env bash
printf 'MOCK_VALIDATE_INVOKED:%s\n' "${*: -1}" >&2
exit 9
EOF_VALIDATE
    chmod +x -- "${VALIDATION_MOCK_BIN}/desktop-file-validate"
    launcher_target_before=$(readlink -- "${LAUNCHER_LINK}")
    assert_status 1 'failed validation is normalized' \
        env PATH="${VALIDATION_MOCK_BIN}:${PATH}" XDG_DATA_HOME="${DATA_HOME}" \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'MOCK_VALIDATE_INVOKED:' \
        'validation mock invocation marker'
    assert_text_contains "${ASSERT_OUTPUT}" 'status 9' \
        'validation status diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" 'previously installed launcher' \
        'failed validation preservation diagnostic'
    cmp -s -- "${launcher_snapshot}" "${DESKTOP_FILE}" \
        || fail 'Failed validation replaced the existing desktop entry.'
    launcher_target_after_failed_validation=$(
        readlink -- "${LAUNCHER_LINK}"
    )
    assert_equals \
        "${launcher_target_before}" \
        "${launcher_target_after_failed_validation}" \
        'failed validation preserves the stable launcher link'
    assert_no_install_temporary_files 'temporary cleanup after failed validation'
}

test_installer_failure_modes() {
    local MISSING_PROJECT
    local conflict_data_home conflict_launcher_link no_validator_bin
    local no_validator_data required_command required_command_path

    # Scenario group: explicit installation failures.
    readonly MISSING_PROJECT="${TEST_ROOT}/missing-gui-project"
    mkdir -p -- "${MISSING_PROJECT}"
    cp -- "${PROJECT_DIR}/install-gui.sh" "${MISSING_PROJECT}/"
    chmod +x -- "${MISSING_PROJECT}/install-gui.sh"
    assert_status 1 'installation rejects a missing GUI script' \
        env XDG_DATA_HOME="${TEST_ROOT}/missing-data" \
        bash "${MISSING_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'absent or not executable' \
        'missing GUI diagnostic'

    write_fake_gui "${MISSING_PROJECT}/download-video-gui.sh"
    chmod -x -- "${MISSING_PROJECT}/download-video-gui.sh"
    assert_status 1 'installation rejects a non-executable GUI script' \
        env XDG_DATA_HOME="${TEST_ROOT}/nonexec-data" \
        bash "${MISSING_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'absent or not executable' \
        'non-executable GUI diagnostic'

    assert_status 1 'relative XDG_DATA_HOME is rejected' \
        env XDG_DATA_HOME='relative-data-home' \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'must resolve to an absolute path' \
        'relative XDG data diagnostic'

    assert_status 1 'unrepresentable XDG percent path is rejected' \
        env XDG_DATA_HOME="${TEST_ROOT}/data%home" \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'cannot be represented safely' \
        'unrepresentable XDG path diagnostic'

    conflict_data_home="${TEST_ROOT}/conflict-data"
    conflict_launcher_link="${conflict_data_home}/yt-dlp-aria2-downloader/launch"
    mkdir -p -- "${conflict_launcher_link}"
    assert_status 1 'launcher path directory conflict is rejected' \
        env XDG_DATA_HOME="${conflict_data_home}" \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" \
        'already exists and is not a symbolic link' \
        'launcher path conflict diagnostic'
    [[ -d ${conflict_launcher_link} ]] \
        || fail 'The conflicting launcher directory was modified.'

    assert_status 1 'XDG data path line breaks are rejected' \
        env XDG_DATA_HOME="${TEST_ROOT}"$'/broken\npath' \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'cannot be represented safely' \
        'XDG line-break diagnostic'

    # The validator is optional at runtime, but skipping it must be explicit.
    no_validator_bin="${TEST_ROOT}/no-validator-bin"
    mkdir -p -- "${no_validator_bin}"
    for required_command in bash cat chmod dirname ln mkdir mktemp mv readlink realpath rm rmdir; do
        required_command_path=$(command -v "${required_command}") \
            || fail "Required host command was not found: ${required_command}"
        ln -s -- "${required_command_path}" \
            "${no_validator_bin}/${required_command}"
    done
    no_validator_data="${TEST_ROOT}/no-validator-data"
    assert_status 0 'installation reports skipped optional validation' \
        env PATH="${no_validator_bin}" XDG_DATA_HOME="${no_validator_data}" \
        bash "${COPIED_PROJECT}/install-gui.sh" install
    assert_text_contains "${ASSERT_OUTPUT}" 'validation was skipped' \
        'missing validator note'
}

test_installer_uninstall_symlink_boundaries() {
    local applications_data="${TEST_ROOT}/uninstall-applications-link"
    local applications_victim="${TEST_ROOT}/uninstall-applications-victim"
    local icons_data="${TEST_ROOT}/uninstall-icons-link"
    local icons_victim="${TEST_ROOT}/uninstall-icons-victim"
    local launcher_data="${TEST_ROOT}/uninstall-launcher-link"
    local launcher_victim="${TEST_ROOT}/uninstall-launcher-victim"
    local scalable_data="${TEST_ROOT}/uninstall-scalable-link"
    local scalable_victim="${TEST_ROOT}/uninstall-scalable-victim"

    mkdir -p -- "${applications_data}" "${applications_victim}"
    touch -- \
        "${applications_victim}/yt-dlp-aria2-downloader.desktop" \
        "${applications_victim}/keep"
    ln -s -- "${applications_victim}" "${applications_data}/applications"
    assert_status 1 'uninstall rejects a symlinked applications directory' \
        env XDG_DATA_HOME="${applications_data}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" \
        'refusing a symbolic-link installation directory' \
        'symlinked applications uninstall diagnostic'
    [[ -f ${applications_victim}/yt-dlp-aria2-downloader.desktop &&
        -f ${applications_victim}/keep ]] \
        || fail 'Uninstall modified a symlinked applications target.'

    mkdir -p -- "${launcher_data}" "${launcher_victim}/.install.stale"
    touch -- "${launcher_victim}/launch" "${launcher_victim}/keep"
    ln -s -- "${launcher_victim}" \
        "${launcher_data}/yt-dlp-aria2-downloader"
    assert_status 1 'uninstall rejects a symlinked launcher directory' \
        env XDG_DATA_HOME="${launcher_data}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    [[ -f ${launcher_victim}/launch && -d ${launcher_victim}/.install.stale &&
        -f ${launcher_victim}/keep ]] \
        || fail 'Uninstall modified a symlinked launcher target.'

    mkdir -p -- \
        "${scalable_data}/icons/hicolor/scalable" "${scalable_victim}"
    touch -- \
        "${scalable_victim}/yt-dlp-aria2-downloader.svg" \
        "${scalable_victim}/keep"
    ln -s -- "${scalable_victim}" \
        "${scalable_data}/icons/hicolor/scalable/apps"
    assert_status 1 'uninstall rejects a symlinked icon leaf directory' \
        env XDG_DATA_HOME="${scalable_data}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    [[ -f ${scalable_victim}/yt-dlp-aria2-downloader.svg &&
        -f ${scalable_victim}/keep ]] \
        || fail 'Uninstall modified a symlinked icon leaf target.'

    mkdir -p -- "${icons_data}" "${icons_victim}/hicolor/scalable/apps"
    touch -- \
        "${icons_victim}/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg" \
        "${icons_victim}/keep"
    ln -s -- "${icons_victim}" "${icons_data}/icons"
    assert_status 1 'uninstall rejects a symlinked intermediate icon directory' \
        env XDG_DATA_HOME="${icons_data}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    [[ -f ${icons_victim}/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg &&
        -f ${icons_victim}/keep ]] \
        || fail 'Uninstall modified a symlinked intermediate icon target.'
}

test_installer_uninstall_lifecycle() {
    assert_status 0 'uninstall existing launcher' \
        env XDG_DATA_HOME="${DATA_HOME}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" 'Launcher removed:' \
        'existing launcher removal message'
    [[ ! -e ${DESKTOP_FILE} ]] || fail 'The desktop launcher was not removed.'
    [[ ! -e ${LAUNCHER_LINK} && ! -L ${LAUNCHER_LINK} ]] \
        || fail 'The stable launcher link was not removed.'
    [[ ! -e ${ICON_FILE} && ! -L ${ICON_FILE} ]] \
        || fail 'The dedicated per-user application icon was not removed.'

    # Scenario: uninstall removes known temporary artifacts left by an unclean stop.
    mkdir -p -- "${LAUNCHER_DIR}/.install.stale"
    : >"${LAUNCHER_DIR}/.validate.stale.desktop"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.stale.tmp"
    assert_status 0 'uninstall cleans stale installer artifacts' \
        env XDG_DATA_HOME="${DATA_HOME}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    [[ ! -d ${LAUNCHER_DIR} ]] || fail 'The private launcher directory remained.'
    [[ ! -e ${APPLICATION_DIR}/.yt-dlp-aria2-downloader.stale.tmp ]] \
        || fail 'A stale desktop-entry temporary file remained.'

    assert_status 0 'repeat uninstall without launcher' \
        env XDG_DATA_HOME="${DATA_HOME}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" 'No launcher is installed at:' \
        'idempotent uninstall message'
}

main() {
    test_installer_initial_installation
    test_installer_reinstallation
    test_installer_failure_modes
    test_installer_uninstall_symlink_boundaries
    test_installer_uninstall_lifecycle
    printf 'Installer integration tests passed.\n'
}

main "$@"
