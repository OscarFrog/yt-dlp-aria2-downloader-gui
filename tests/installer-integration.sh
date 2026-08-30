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
    mktemp mv python3 readlink realpath rm rmdir sed setsid sleep stat; do
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

assert_no_install_temporary_files_at() {
    local data_home=$1
    local label=$2
    local application_dir="${data_home}/applications"
    local launcher_dir="${data_home}/yt-dlp-aria2-downloader"
    local -a leftovers=()

    shopt -s nullglob
    leftovers=(
        "${application_dir}"/.yt-dlp-aria2-downloader.*.tmp
        "${application_dir}"/.yt-dlp-aria2-downloader.*.desktop
        "${application_dir}"/.yt-dlp-aria2-downloader.*.backup
        "${launcher_dir}"/.install.*
        "${launcher_dir}"/.launch.*.backup
        "${launcher_dir}"/.validate.*.desktop
        "${data_home}/icons/hicolor/scalable/apps"/.yt-dlp-aria2-downloader.*.tmp
        "${data_home}/icons/hicolor/scalable/apps"/.yt-dlp-aria2-downloader.*.backup
    )
    shopt -u nullglob

    if ((${#leftovers[@]} != 0)); then
        printf 'FAIL: %s\n' "${label}" >&2
        printf 'Temporary installation artifact remained: %s\n' \
            "${leftovers[@]}" >&2
        exit 1
    fi
}

assert_no_install_temporary_files() {
    local label=$1

    assert_no_install_temporary_files_at "${DATA_HOME}" "${label}"
}

assert_no_launcher_leaves_at() {
    local data_home=$1
    local label=$2

    if [[ -e ${data_home}/applications/yt-dlp-aria2-downloader.desktop ||
        -L ${data_home}/applications/yt-dlp-aria2-downloader.desktop ||
        -e ${data_home}/yt-dlp-aria2-downloader/launch ||
        -L ${data_home}/yt-dlp-aria2-downloader/launch ||
        -e ${data_home}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ||
        -L ${data_home}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]]; then
        fail "${label}: a managed launcher leaf remained"
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
    cp -- \
        "${PROJECT_DIR}/install-gui.sh" \
        "${PROJECT_DIR}/private-launcher-manager.py" \
        "${COPIED_PROJECT}/"
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
    local shared_data_home shared_victim

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

    assert_status 1 'filesystem root XDG_DATA_HOME is rejected' \
        env XDG_DATA_HOME=/ \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" \
        'refusing the filesystem root as XDG data home' \
        'filesystem-root XDG data diagnostic'

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

    shared_data_home="${TEST_ROOT}/group-writable-data"
    shared_victim="${shared_data_home}/applications/yt-dlp-aria2-downloader.desktop"
    mkdir -p -- "${shared_data_home}/applications"
    touch -- "${shared_victim}"
    chmod 0777 -- "${shared_data_home}"
    assert_status 1 'group-writable XDG data root is rejected' \
        env XDG_DATA_HOME="${shared_data_home}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" \
        'writable by group or other users' \
        'group-writable XDG data diagnostic'
    [[ -f ${shared_victim} ]] \
        || fail 'Unsafe shared XDG rejection modified a victim file.'
    chmod 0700 -- "${shared_data_home}"

    # The validator is optional at runtime, but skipping it must be explicit.
    no_validator_bin="${TEST_ROOT}/no-validator-bin"
    mkdir -p -- "${no_validator_bin}"
    for required_command in bash cat dirname python3 realpath; do
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
    local component_data=''
    local component_parent="${TEST_ROOT}/uninstall-component-parent"
    local component_victim="${TEST_ROOT}/uninstall-component-victim"
    local data_home_link="${TEST_ROOT}/uninstall-data-home-link"
    local data_home_victim="${TEST_ROOT}/uninstall-data-home-victim"
    local icons_data="${TEST_ROOT}/uninstall-icons-link"
    local icons_victim="${TEST_ROOT}/uninstall-icons-victim"
    local launcher_data="${TEST_ROOT}/uninstall-launcher-link"
    local launcher_victim="${TEST_ROOT}/uninstall-launcher-victim"
    local scalable_data="${TEST_ROOT}/uninstall-scalable-link"
    local scalable_victim="${TEST_ROOT}/uninstall-scalable-victim"

    mkdir -p -- \
        "${data_home_victim}/applications" \
        "${data_home_victim}/yt-dlp-aria2-downloader/.install.stale" \
        "${data_home_victim}/icons/hicolor/scalable/apps"
    touch -- \
        "${data_home_victim}/applications/yt-dlp-aria2-downloader.desktop" \
        "${data_home_victim}/yt-dlp-aria2-downloader/launch" \
        "${data_home_victim}/yt-dlp-aria2-downloader/.install.stale/keep" \
        "${data_home_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
    ln -s -- "${data_home_victim}" "${data_home_link}"
    assert_status 1 'uninstall rejects a symlinked XDG data root' \
        env XDG_DATA_HOME="${data_home_link}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" \
        'refusing a symbolic-link installation directory' \
        'symlinked XDG data root uninstall diagnostic'
    [[ -f ${data_home_victim}/applications/yt-dlp-aria2-downloader.desktop &&
        -f ${data_home_victim}/yt-dlp-aria2-downloader/launch &&
        -f ${data_home_victim}/yt-dlp-aria2-downloader/.install.stale/keep &&
        -f ${data_home_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]] \
        || fail 'Uninstall modified a symlinked XDG data root target.'

    component_data="${component_parent}/linked/data"
    mkdir -p -- \
        "${component_parent}" \
        "${component_victim}/data/applications" \
        "${component_victim}/data/yt-dlp-aria2-downloader/.install.stale" \
        "${component_victim}/data/icons/hicolor/scalable/apps"
    touch -- \
        "${component_victim}/data/applications/yt-dlp-aria2-downloader.desktop" \
        "${component_victim}/data/yt-dlp-aria2-downloader/launch" \
        "${component_victim}/data/yt-dlp-aria2-downloader/.install.stale/keep" \
        "${component_victim}/data/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
    ln -s -- "${component_victim}" "${component_parent}/linked"
    assert_status 1 'uninstall rejects a symlinked XDG parent component' \
        env XDG_DATA_HOME="${component_data}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    assert_text_contains "${ASSERT_OUTPUT}" \
        'refusing a symbolic-link installation directory' \
        'symlinked XDG parent component uninstall diagnostic'
    [[ -f ${component_victim}/data/applications/yt-dlp-aria2-downloader.desktop &&
        -f ${component_victim}/data/yt-dlp-aria2-downloader/launch &&
        -f ${component_victim}/data/yt-dlp-aria2-downloader/.install.stale/keep &&
        -f ${component_victim}/data/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]] \
        || fail 'Uninstall modified a symlinked XDG parent-component target.'

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

test_installer_uninstall_anchor_race() {
    local race_data_home="${TEST_ROOT}/uninstall-anchor-race-data"
    local race_saved_home="${TEST_ROOT}/uninstall-anchor-race-saved"
    local race_victim="${TEST_ROOT}/uninstall-anchor-race-victim"

    mkdir -p -- \
        "${race_data_home}/applications" \
        "${race_data_home}/yt-dlp-aria2-downloader/.install.0123456789abcdef01234567" \
        "${race_data_home}/icons/hicolor/scalable/apps" \
        "${race_victim}/applications" \
        "${race_victim}/yt-dlp-aria2-downloader/.install.stale" \
        "${race_victim}/icons/hicolor/scalable/apps"
    touch -- \
        "${race_data_home}/applications/yt-dlp-aria2-downloader.desktop" \
        "${race_data_home}/yt-dlp-aria2-downloader/launch" \
        "${race_data_home}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg" \
        "${race_victim}/applications/yt-dlp-aria2-downloader.desktop" \
        "${race_victim}/yt-dlp-aria2-downloader/launch" \
        "${race_victim}/yt-dlp-aria2-downloader/.install.stale/keep" \
        "${race_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
    ln -s -- \
        "${COPIED_PROJECT}/download-video-gui.sh" \
        "${race_data_home}/yt-dlp-aria2-downloader/.install.0123456789abcdef01234567/launch"

    assert_status 0 'uninstall stays on anchored descriptors after root replacement' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${race_data_home}" \
        "${race_saved_home}" \
        "${race_victim}" <<'PYTHON_ANCHOR_RACE'
import importlib.util
import os
import pathlib
import sys

helper_path, data_home, saved_home, victim = sys.argv[1:]
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def replace_data_home() -> None:
    os.rename(data_home, saved_home)
    os.symlink(victim, data_home)


try:
    module.uninstall_launcher(data_home, after_anchor=replace_data_home)
except module.LauncherError as error:
    if "changed during the launcher transaction" not in str(error):
        raise
else:
    raise SystemExit(1)

saved_root = pathlib.Path(saved_home)
if not (saved_root / "applications/yt-dlp-aria2-downloader.desktop").is_file():
    raise SystemExit(1)
if not (saved_root / "yt-dlp-aria2-downloader/launch").is_file():
    raise SystemExit(1)
if (
    saved_root
    / "yt-dlp-aria2-downloader/.install.0123456789abcdef01234567"
).exists():
    raise SystemExit(1)
if not (
    saved_root / "icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
).is_file():
    raise SystemExit(1)
PYTHON_ANCHOR_RACE

    [[ -f ${race_victim}/applications/yt-dlp-aria2-downloader.desktop &&
        -f ${race_victim}/yt-dlp-aria2-downloader/launch &&
        -f ${race_victim}/yt-dlp-aria2-downloader/.install.stale/keep &&
        -f ${race_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]] \
        || fail 'Anchored uninstall modified the replacement XDG victim.'
}

test_installer_install_anchor_race() {
    local race_data_home="${TEST_ROOT}/install-anchor-race-data"
    local race_saved_home="${TEST_ROOT}/install-anchor-race-saved"
    local race_victim="${TEST_ROOT}/install-anchor-race-victim"

    mkdir -p -- \
        "${race_victim}/applications" \
        "${race_victim}/yt-dlp-aria2-downloader" \
        "${race_victim}/icons/hicolor/scalable/apps"
    touch -- \
        "${race_victim}/applications/yt-dlp-aria2-downloader.desktop" \
        "${race_victim}/yt-dlp-aria2-downloader/launch" \
        "${race_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"

    assert_status 0 'install stays on anchored descriptors after root replacement' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${race_data_home}" \
        "${race_saved_home}" \
        "${race_victim}" \
        "${COPIED_PROJECT}/download-video-gui.sh" <<'PYTHON_INSTALL_ANCHOR_RACE'
import importlib.util
import os
import pathlib
import sys

helper_path, data_home, saved_home, victim, launcher_target = sys.argv[1:]
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def replace_data_home() -> None:
    os.rename(data_home, saved_home)
    os.symlink(victim, data_home)


try:
    module.install_launcher(
        data_home,
        launcher_target,
        str(pathlib.Path(helper_path).parent / "missing-icon.svg"),
        after_anchor=replace_data_home,
    )
except module.LauncherError as error:
    if "changed during the launcher transaction" not in str(error):
        raise
else:
    raise SystemExit(1)

saved_root = pathlib.Path(saved_home)
for managed_leaf in (
    saved_root / "applications/yt-dlp-aria2-downloader.desktop",
    saved_root / "yt-dlp-aria2-downloader/launch",
    saved_root / "icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg",
):
    if managed_leaf.exists() or managed_leaf.is_symlink():
        raise SystemExit(1)
PYTHON_INSTALL_ANCHOR_RACE

    [[ -f ${race_victim}/applications/yt-dlp-aria2-downloader.desktop &&
        ! -s ${race_victim}/applications/yt-dlp-aria2-downloader.desktop &&
        -f ${race_victim}/yt-dlp-aria2-downloader/launch &&
        ! -L ${race_victim}/yt-dlp-aria2-downloader/launch &&
        -f ${race_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg &&
        ! -s ${race_victim}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg ]] \
        || fail 'Anchored install modified the replacement XDG victim.'
}

test_installer_install_branch_races() {
    assert_status 0 'install detects every managed directory replacement' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/install-branch-races" \
        "${COPIED_PROJECT}/download-video-gui.sh" <<'PYTHON_INSTALL_BRANCH_RACES'
import importlib.util
import os
import pathlib
import sys

helper_path, test_root_raw, launcher_target = sys.argv[1:]
test_root = pathlib.Path(test_root_raw)
test_root.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def replacement_paths(data_home: pathlib.Path, branch: str) -> tuple[pathlib.Path, str]:
    if branch == "applications":
        return data_home / "applications", module.DESKTOP_NAME
    if branch == "launcher":
        return data_home / module.APP_ID, "launch"
    return data_home / "icons/hicolor/scalable/apps", module.ICON_NAME


for branch in ("applications", "launcher", "icons"):
    data_home = test_root / branch

    def replace_branch(
        branch_name: str = branch, root: pathlib.Path = data_home
    ) -> None:
        original, victim_name = replacement_paths(root, branch_name)
        saved = root / f".saved-{branch_name}"
        os.rename(original, saved)
        os.mkdir(original, mode=0o700)
        (original / victim_name).touch(mode=0o600)

    try:
        module.install_launcher(
            str(data_home),
            launcher_target,
            str(test_root / "missing-icon.svg"),
            after_anchor=replace_branch,
        )
    except module.LauncherError as error:
        if "managed launcher directory" not in str(error):
            raise
    else:
        raise SystemExit(1)

    replacement, victim_name = replacement_paths(data_home, branch)
    victim = replacement / victim_name
    if not victim.is_file() or victim.is_symlink() or victim.stat().st_size != 0:
        raise SystemExit(1)
PYTHON_INSTALL_BRANCH_RACES
}

test_installer_concurrent_transactions() {
    assert_status 0 'installer transactions serialize on the anchored data root' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/installer-concurrent-data" \
        "${COPIED_PROJECT}/download-video-gui.sh" <<'PYTHON_CONCURRENT_TRANSACTIONS'
import importlib.util
import pathlib
import sys
import threading

helper_path, data_home, launcher_target = sys.argv[1:]
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

install_published = threading.Event()
release_install = threading.Event()
uninstall_lock_attempted = threading.Event()
uninstall_finished = threading.Event()
failures = []
original_flock = module.fcntl.flock
original_validate = module.validate_managed_path_identities


def observing_flock(descriptor: int, operation: int) -> None:
    if threading.current_thread().name == "uninstall-transaction":
        uninstall_lock_attempted.set()
    original_flock(descriptor, operation)


def pausing_validate(*args: object, **kwargs: object) -> None:
    if threading.current_thread().name == "install-transaction":
        install_published.set()
        if not release_install.wait(10):
            raise RuntimeError("timed out releasing the install transaction")
    original_validate(*args, **kwargs)


def run_install() -> None:
    try:
        module.install_launcher(
            data_home,
            launcher_target,
            str(pathlib.Path(data_home) / "missing-icon.svg"),
        )
    except BaseException as error:
        failures.append(error)


def run_uninstall() -> None:
    try:
        module.uninstall_launcher(data_home)
    except BaseException as error:
        failures.append(error)
    finally:
        uninstall_finished.set()


module.fcntl.flock = observing_flock
module.validate_managed_path_identities = pausing_validate
install_thread = threading.Thread(target=run_install, name="install-transaction")
uninstall_thread = threading.Thread(target=run_uninstall, name="uninstall-transaction")
try:
    install_thread.start()
    if not install_published.wait(10):
        raise RuntimeError("install transaction did not reach final validation")
    uninstall_thread.start()
    if not uninstall_lock_attempted.wait(10):
        raise RuntimeError("uninstall transaction did not attempt the shared lock")
    if uninstall_finished.wait(0.25):
        raise RuntimeError("uninstall bypassed the active install transaction")
finally:
    release_install.set()
    install_thread.join(10)
    uninstall_thread.join(10)
    module.validate_managed_path_identities = original_validate
    module.fcntl.flock = original_flock

if install_thread.is_alive() or uninstall_thread.is_alive() or failures:
    raise SystemExit(1)

data_root = pathlib.Path(data_home)
for leaf in (
    data_root / "applications" / module.DESKTOP_NAME,
    data_root / module.APP_ID / "launch",
    data_root / "icons/hicolor/scalable/apps" / module.ICON_NAME,
):
    if leaf.exists() or leaf.is_symlink():
        raise SystemExit(1)
PYTHON_CONCURRENT_TRANSACTIONS
}

test_installer_transaction_rollbacks() {
    assert_status 0 'installer rolls back partial publication and removal' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/installer-rollback" <<'PYTHON_TRANSACTION_ROLLBACKS'
import errno
import importlib.util
import inspect
import os
import pathlib
import runpy
import signal
import stat
import sys

helper_path, test_root_raw = sys.argv[1:]
test_root = pathlib.Path(test_root_raw)
test_root.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# The asynchronous handler must remain flag-only. Changing dispositions from
# inside the callback races with the wrapper's concurrent internal TERM and can
# make CPython emit an otherwise ignored signal-handler traceback.
original_signal_setter = module.signal.signal


def reject_signal_disposition_change(*_args: object, **_kwargs: object) -> None:
    raise RuntimeError("shutdown callback changed a signal disposition")


module.signal.signal = reject_signal_disposition_change
try:
    module.request_shutdown(signal.SIGHUP, None)
    module.request_shutdown(signal.SIGTERM, None)
finally:
    module.signal.signal = original_signal_setter
if module._pending_shutdown_signal != signal.SIGHUP:
    raise RuntimeError("repeated shutdown callback replaced the first signal")
module._pending_shutdown_signal = None

module._shutdown_delivery_safe = True
try:
    try:
        module.request_shutdown(signal.SIGHUP, None)
    except module.LauncherInterruptedError as error:
        if error.exit_status != 128 + signal.SIGHUP:
            raise RuntimeError("immediate callback changed signal status") from error
    else:
        raise RuntimeError("first immediate callback did not terminate")
    module.request_shutdown(signal.SIGTERM, None)
    if module._pending_shutdown_signal != signal.SIGHUP:
        raise RuntimeError("late repeated callback replaced the first signal")
finally:
    module._shutdown_delivery_safe = False
    module._pending_shutdown_signal = None


def write_executable(path: pathlib.Path, marker: str) -> None:
    path.write_text(f"#!/usr/bin/env bash\n# {marker}\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


old_target = test_root / "old-gui.sh"
new_target = test_root / "new-gui.sh"
old_icon = test_root / "old-icon.svg"
new_icon = test_root / "new-icon.svg"
write_executable(old_target, "old")
write_executable(new_target, "new")
old_icon.write_bytes(b"<svg><title>old</title></svg>\n")
new_icon.write_bytes(b"<svg><title>new</title></svg>\n")

invalid_data_home = os.fsencode(str(test_root)) + b"/invalid-utf8-\xff"
invalid_path_result = module.subprocess.run(
    [
        os.fsencode(sys.executable),
        os.fsencode(helper_path),
        b"install",
        b"--data-home",
        invalid_data_home,
        b"--launcher-target",
        os.fsencode(new_target),
        b"--icon-source",
        os.fsencode(new_icon),
    ],
    stdout=module.subprocess.PIPE,
    stderr=module.subprocess.PIPE,
    check=False,
)
if invalid_path_result.returncode != module.EXIT_VALIDATION:
    raise RuntimeError("non-UTF-8 XDG path did not return a validation status")
if b"valid UTF-8" not in invalid_path_result.stderr:
    raise RuntimeError("non-UTF-8 XDG path did not report a stable diagnostic")
if b"Traceback (most recent call last)" in invalid_path_result.stderr:
    raise RuntimeError("non-UTF-8 XDG path emitted a Python traceback")
if os.path.lexists(invalid_data_home):
    raise RuntimeError("non-UTF-8 XDG rejection mutated the data path")


def path_state(path: pathlib.Path) -> tuple[object, ...]:
    if not os.path.lexists(path):
        return ("absent",)
    path_stat = path.lstat()
    if stat.S_ISLNK(path_stat.st_mode):
        return ("symlink", os.readlink(path))
    if stat.S_ISREG(path_stat.st_mode):
        return ("file", stat.S_IMODE(path_stat.st_mode), path.read_bytes())
    return ("other", stat.S_IFMT(path_stat.st_mode))


def launcher_state(data_home: pathlib.Path) -> tuple[tuple[object, ...], ...]:
    return (
        path_state(data_home / "applications" / module.DESKTOP_NAME),
        path_state(data_home / module.APP_ID / "launch"),
        path_state(data_home / "icons/hicolor/scalable/apps" / module.ICON_NAME),
    )


def assert_no_private_artifacts(data_home: pathlib.Path) -> None:
    directories = (
        data_home / "applications",
        data_home / module.APP_ID,
        data_home / "icons/hicolor/scalable/apps",
    )
    for directory in directories:
        if not directory.exists():
            continue
        for child in directory.iterdir():
            if (
                child.name.startswith(".install.")
                or child.name.startswith(".launch.")
                or child.name.endswith(".backup")
                or (
                    child.name.startswith(f".{module.APP_ID}.")
                    and child.name != module.DESKTOP_NAME
                )
            ):
                raise RuntimeError(f"private transaction artifact remained: {child}")


def fail_install_publication(
    data_home: pathlib.Path,
    launcher_target: pathlib.Path,
    icon_source: pathlib.Path,
    failure_step: int,
) -> None:
    original_replace = module.os.replace
    publication_count = 0

    def failing_replace(*args: object, **kwargs: object) -> None:
        nonlocal publication_count
        destination = args[1]
        if destination in {"launch", module.ICON_NAME, module.DESKTOP_NAME}:
            publication_count += 1
            if publication_count == failure_step:
                raise OSError(errno.EIO, "injected publication failure")
        original_replace(*args, **kwargs)

    module.os.replace = failing_replace
    try:
        module.install_launcher(
            str(data_home), str(launcher_target), str(icon_source)
        )
    except OSError as error:
        if error.errno != errno.EIO:
            raise
    else:
        raise SystemExit(1)
    finally:
        module.os.replace = original_replace


for failure_step in (1, 2, 3):
    data_home = test_root / f"fresh-{failure_step}"
    state_before = launcher_state(data_home)
    fail_install_publication(data_home, new_target, new_icon, failure_step)
    if launcher_state(data_home) != state_before:
        raise RuntimeError(f"fresh install rollback mismatch at step {failure_step}")
    assert_no_private_artifacts(data_home)

for failure_step in (1, 2, 3):
    data_home = test_root / f"reinstall-{failure_step}"
    module.install_launcher(str(data_home), str(old_target), str(old_icon))
    state_before = launcher_state(data_home)
    fail_install_publication(data_home, new_target, new_icon, failure_step)
    if launcher_state(data_home) != state_before:
        raise RuntimeError(f"reinstall rollback mismatch at step {failure_step}")
    assert_no_private_artifacts(data_home)

for failure_step in (1, 2, 3):
    data_home = test_root / f"uninstall-{failure_step}"
    module.install_launcher(str(data_home), str(old_target), str(old_icon))
    state_before = launcher_state(data_home)
    original_unlink = module.os.unlink
    removal_count = [0]

    def failing_unlink(*args: object, **kwargs: object) -> None:
        target_name = args[0]
        if target_name in {module.DESKTOP_NAME, "launch", module.ICON_NAME}:
            removal_count[0] += 1
            if removal_count[0] == failure_step:
                raise OSError(errno.EIO, "injected removal failure")
        original_unlink(*args, **kwargs)

    module.os.unlink = failing_unlink
    try:
        module.uninstall_launcher(str(data_home))
    except OSError as error:
        if error.errno != errno.EIO:
            raise
    else:
        raise SystemExit(1)
    finally:
        module.os.unlink = original_unlink
    if launcher_state(data_home) != state_before:
        raise RuntimeError(f"uninstall rollback mismatch at step {failure_step}")
    assert_no_private_artifacts(data_home)


def expect_interrupted_install(
    data_home: pathlib.Path,
    signal_number: int,
    install_call: object,
) -> None:
    state_before = launcher_state(data_home)
    module.install_shutdown_signal_handlers()
    try:
        install_call()
    except module.LauncherInterruptedError as error:
        if error.exit_status != 128 + signal_number:
            raise RuntimeError("incorrect interrupted-install status") from error
    else:
        raise RuntimeError("installer interruption was not propagated")
    if launcher_state(data_home) != state_before:
        raise RuntimeError("interrupted install did not restore its prior state")
    assert_no_private_artifacts(data_home)


module.shutil.which = lambda _name: None
for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    data_home = test_root / f"signal-publication-{signal_number}"
    original_replace = module.os.replace
    signal_injected = False

    def signal_after_publication(*args: object, **kwargs: object) -> None:
        global signal_injected
        original_replace(*args, **kwargs)
        if args[1] == "launch" and not signal_injected:
            signal_injected = True
            os.kill(os.getpid(), signal_number)

    module.os.replace = signal_after_publication
    try:
        expect_interrupted_install(
            data_home,
            signal_number,
            lambda: module.install_launcher(
                str(data_home), str(new_target), str(new_icon)
            ),
        )
    finally:
        module.os.replace = original_replace
    if not signal_injected:
        raise RuntimeError("publication signal was not injected")

# Resource names must be registered atomically even when the signal arrives
# after the allocating syscall but before its Python caller resumes.
data_home = test_root / "signal-post-open"
original_open = module.os.open
signal_injected = False


def signal_after_temporary_open(*args: object, **kwargs: object) -> int:
    global signal_injected
    descriptor = original_open(*args, **kwargs)
    flags = args[1]
    if flags & os.O_CREAT and flags & os.O_EXCL and not signal_injected:
        signal_injected = True
        os.kill(os.getpid(), signal.SIGTERM)
    return descriptor


module.os.open = signal_after_temporary_open
try:
    expect_interrupted_install(
        data_home,
        signal.SIGTERM,
        lambda: module.install_launcher(
            str(data_home), str(new_target), str(new_icon)
        ),
    )
finally:
    module.os.open = original_open
if not signal_injected:
    raise RuntimeError("post-open signal was not injected")

data_home = test_root / "signal-post-link"
module.install_shutdown_signal_handlers()
module.install_launcher(str(data_home), str(old_target), str(old_icon))
state_before = launcher_state(data_home)
original_link = module.os.link
signal_injected = False


def signal_after_backup_link(*args: object, **kwargs: object) -> None:
    global signal_injected
    original_link(*args, **kwargs)
    if not signal_injected:
        signal_injected = True
        os.kill(os.getpid(), signal.SIGTERM)


module.os.link = signal_after_backup_link
try:
    expect_interrupted_install(
        data_home,
        signal.SIGTERM,
        lambda: module.install_launcher(
            str(data_home), str(new_target), str(new_icon)
        ),
    )
finally:
    module.os.link = original_link
if not signal_injected:
    raise RuntimeError("post-link signal was not injected")
if launcher_state(data_home) != state_before:
    raise RuntimeError("post-link interruption changed the installed launcher")

# Popen itself is a registration boundary: an interruption after fork but
# before the process object returns must still kill and reap the validator.
validator = test_root / "blocking-validator.sh"
validator.write_text(
    "#!/usr/bin/env bash\n"
    "trap '' HUP INT TERM\n"
    "while :; do sleep 1; done\n",
    encoding="utf-8",
)
validator.chmod(0o755)
module.shutil.which = lambda _name: str(validator)
real_popen = module.subprocess.Popen
validator_processes = []


def signal_before_popen_returns(*args: object, **kwargs: object) -> object:
    process = real_popen(*args, **kwargs)
    validator_processes.append(process)
    os.kill(os.getpid(), signal.SIGTERM)
    return process


module.subprocess.Popen = signal_before_popen_returns
data_home = test_root / "signal-popen-registration"
try:
    expect_interrupted_install(
        data_home,
        signal.SIGTERM,
        lambda: module.install_launcher(
            str(data_home), str(new_target), str(new_icon)
        ),
    )
finally:
    module.subprocess.Popen = real_popen
if not validator_processes or any(
    process.poll() is None for process in validator_processes
):
    raise RuntimeError("interrupted validator was not reaped")

# A signal at the first bytecode of the validator's finally block must not
# escape before its already-forked child is killed, reaped, and disconnected.
validator_finally_source, validator_start_line = inspect.getsourcelines(
    module.validate_desktop_file
)
validator_finally_line = next(
    validator_start_line + index
    for index, line in enumerate(validator_finally_source)
    if line.strip() == "if process is not None:"
)
validator_processes = []
validator_finally_hit = False
original_select = module.select.select


def capture_validator(*args: object, **kwargs: object) -> object:
    process = real_popen(*args, **kwargs)
    validator_processes.append(process)
    return process


def force_validator_finally(*_args: object, **_kwargs: object) -> object:
    raise RuntimeError("injected validator read failure")


def signal_at_validator_finally(
    frame: object, event: str, _argument: object
) -> object:
    global validator_finally_hit
    if (
        getattr(frame, "f_code", None) is module.validate_desktop_file.__code__
        and event == "line"
        and getattr(frame, "f_lineno", None) == validator_finally_line
        and not validator_finally_hit
    ):
        validator_finally_hit = True
        sys.settrace(None)
        os.kill(os.getpid(), signal.SIGHUP)
        os.kill(os.getpid(), signal.SIGTERM)
        return None
    return signal_at_validator_finally


module.subprocess.Popen = capture_validator
module.select.select = force_validator_finally
data_home = test_root / "signal-validator-finally"
sys.settrace(signal_at_validator_finally)
try:
    expect_interrupted_install(
        data_home,
        signal.SIGHUP,
        lambda: module.install_launcher(
            str(data_home), str(new_target), str(new_icon)
        ),
    )
finally:
    sys.settrace(None)
    module.select.select = original_select
    module.subprocess.Popen = real_popen
if not validator_finally_hit:
    raise RuntimeError("validator-finally signal was not injected")
if not validator_processes or any(
    process.poll() is None for process in validator_processes
):
    raise RuntimeError("validator-finally interruption leaked its child")

# Final validation is the transaction commit point. A signal at the first
# cleanup bytecode may leave the complete new state, but never a subset or any
# private stage/backup artifact.
module.shutil.which = lambda _name: None
install_source, install_start_line = inspect.getsourcelines(module.install_launcher)
install_cleanup_line = next(
    install_start_line + index + 1
    for index, line in enumerate(install_source[:-1])
    if line.strip() == "finally:"
    and install_source[index + 1].strip() == "with defer_shutdown_interruptions():"
)
install_finally_hit = False


def signal_at_install_finally(
    frame: object, event: str, _argument: object
) -> object:
    global install_finally_hit
    if (
        getattr(frame, "f_code", None) is module.install_launcher.__code__
        and event == "line"
        and getattr(frame, "f_lineno", None) == install_cleanup_line
        and not install_finally_hit
    ):
        install_finally_hit = True
        sys.settrace(None)
        os.kill(os.getpid(), signal.SIGHUP)
        os.kill(os.getpid(), signal.SIGTERM)
        return None
    return signal_at_install_finally


data_home = test_root / "signal-install-finally"
module.install_shutdown_signal_handlers()
sys.settrace(signal_at_install_finally)
try:
    module.install_launcher(str(data_home), str(new_target), str(new_icon))
except module.LauncherInterruptedError as error:
    if error.exit_status != 128 + signal.SIGHUP:
        raise RuntimeError("install-finally did not preserve first signal") from error
else:
    raise RuntimeError("install-finally interruption was not propagated")
finally:
    sys.settrace(None)
if not install_finally_hit:
    raise RuntimeError("install-finally signal was not injected")
expected_installed_state = (
    ("file", 0o644, module.build_desktop_content(str(data_home))),
    ("symlink", str(new_target)),
    ("file", 0o644, new_icon.read_bytes()),
)
if launcher_state(data_home) != expected_installed_state:
    raise RuntimeError("install-finally interruption left a partial commit")
assert_no_private_artifacts(data_home)

uninstall_source, uninstall_start_line = inspect.getsourcelines(
    module.uninstall_launcher
)
uninstall_cleanup_line = next(
    uninstall_start_line + index + 1
    for index, line in enumerate(uninstall_source[:-1])
    if line.strip() == "finally:"
    and uninstall_source[index + 1].strip()
    == "with defer_shutdown_interruptions():"
)
uninstall_finally_hit = False


def signal_at_uninstall_finally(
    frame: object, event: str, _argument: object
) -> object:
    global uninstall_finally_hit
    if (
        getattr(frame, "f_code", None) is module.uninstall_launcher.__code__
        and event == "line"
        and getattr(frame, "f_lineno", None) == uninstall_cleanup_line
        and not uninstall_finally_hit
    ):
        uninstall_finally_hit = True
        sys.settrace(None)
        os.kill(os.getpid(), signal.SIGINT)
        os.kill(os.getpid(), signal.SIGTERM)
        return None
    return signal_at_uninstall_finally


module.install_shutdown_signal_handlers()
sys.settrace(signal_at_uninstall_finally)
try:
    module.uninstall_launcher(str(data_home))
except module.LauncherInterruptedError as error:
    if error.exit_status != 128 + signal.SIGINT:
        raise RuntimeError("uninstall-finally did not preserve first signal") from error
else:
    raise RuntimeError("uninstall-finally interruption was not propagated")
finally:
    sys.settrace(None)
if not uninstall_finally_hit:
    raise RuntimeError("uninstall-finally signal was not injected")
if launcher_state(data_home) != (("absent",), ("absent",), ("absent",)):
    raise RuntimeError("uninstall-finally interruption left a partial commit")
assert_no_private_artifacts(data_home)

# A signal recorded while main() prints a translated diagnostic must override
# that diagnostic status, and a later catchable signal must not replace it.
class FailingArguments:
    action = "uninstall"
    data_home = str(test_root / "signal-diagnostic")


class FailingParser:
    @staticmethod
    def parse_args() -> FailingArguments:
        return FailingArguments()


def fail_main_uninstall(_data_home: str) -> None:
    raise module.LauncherError("injected diagnostic failure")


real_print = print
diagnostic_signal_injected = False


def signal_during_diagnostic(*args: object, **kwargs: object) -> None:
    global diagnostic_signal_injected
    real_print(*args, **kwargs)
    if (
        args
        and str(args[0]).startswith("Error: injected diagnostic failure")
        and not diagnostic_signal_injected
    ):
        diagnostic_signal_injected = True
        os.kill(os.getpid(), signal.SIGHUP)
        os.kill(os.getpid(), signal.SIGTERM)


original_parser_builder = module.build_argument_parser
original_uninstall = module.uninstall_launcher
module.build_argument_parser = lambda: FailingParser()
module.uninstall_launcher = fail_main_uninstall
module.print = signal_during_diagnostic
try:
    diagnostic_status = module.main()
finally:
    module.build_argument_parser = original_parser_builder
    module.uninstall_launcher = original_uninstall
    del module.print
if not diagnostic_signal_injected:
    raise RuntimeError("diagnostic signal was not injected")
if diagnostic_status != 128 + signal.SIGHUP:
    raise RuntimeError("diagnostic return masked or replaced the first signal")

# After all work is complete, main switches to immediate delivery. A shim that
# sends the first signal immediately after that switch exercises the final
# call-to-return window without relying on version-specific opcode tracing.
class SuccessfulArguments:
    action = "uninstall"
    data_home = str(test_root / "signal-main-return")


class SuccessfulParser:
    @staticmethod
    def parse_args() -> SuccessfulArguments:
        return SuccessfulArguments()


immediate_delivery_hit = False
original_enable_immediate_delivery = module.enable_immediate_shutdown_delivery


def signal_after_immediate_delivery() -> None:
    global immediate_delivery_hit
    original_enable_immediate_delivery()
    immediate_delivery_hit = True
    os.kill(os.getpid(), signal.SIGTERM)


module.build_argument_parser = lambda: SuccessfulParser()
module.uninstall_launcher = lambda _data_home: None
module.enable_immediate_shutdown_delivery = signal_after_immediate_delivery
try:
    main_return_status = module.main()
finally:
    module.build_argument_parser = original_parser_builder
    module.uninstall_launcher = original_uninstall
    module.enable_immediate_shutdown_delivery = original_enable_immediate_delivery
if not immediate_delivery_hit:
    raise RuntimeError("immediate-delivery signal was not injected")
if main_return_status != 128 + signal.SIGTERM:
    raise RuntimeError("main final return window lost the shutdown signal")

# The process entrypoint catches the still-later window on main's actual return
# event and converts it to SystemExit with the same conventional signal status.
entrypoint_signal_hit = False
entrypoint_data_home = test_root / "signal-entrypoint-return"
helper_resolved = pathlib.Path(helper_path).resolve()


def signal_at_entrypoint_return(
    frame: object, event: str, _argument: object
) -> object:
    global entrypoint_signal_hit
    if (
        event == "return"
        and getattr(getattr(frame, "f_code", None), "co_name", None) == "main"
        and pathlib.Path(frame.f_code.co_filename).resolve() == helper_resolved
        and not entrypoint_signal_hit
    ):
        entrypoint_signal_hit = True
        sys.settrace(None)
        os.kill(os.getpid(), signal.SIGTERM)
        return None
    return signal_at_entrypoint_return


saved_argv = sys.argv[:]
sys.argv = [
    str(helper_resolved),
    "uninstall",
    "--data-home",
    str(entrypoint_data_home),
]
sys.settrace(signal_at_entrypoint_return)
try:
    try:
        runpy.run_path(str(helper_resolved), run_name="__main__")
    except SystemExit as error:
        entrypoint_status = error.code
    else:
        raise RuntimeError("launcher entrypoint did not terminate with SystemExit")
finally:
    sys.settrace(None)
    sys.argv = saved_argv
if not entrypoint_signal_hit:
    raise RuntimeError("entrypoint return signal was not injected")
if entrypoint_status != 128 + signal.SIGTERM:
    raise RuntimeError("entrypoint return lost the shutdown signal")

# Descriptor-close diagnostics are secondary to the transaction error.
module.shutil.which = lambda _name: None
data_home = test_root / "close-failure"
module.install_shutdown_signal_handlers()
original_close = module.os.close
close_failure_enabled = False
close_failure_injected = False


def failing_close(descriptor: int) -> None:
    global close_failure_injected
    original_close(descriptor)
    if close_failure_enabled and not close_failure_injected:
        close_failure_injected = True
        raise OSError(errno.EIO, "injected close failure")


def fail_after_anchor() -> None:
    global close_failure_enabled
    close_failure_enabled = True
    raise module.LauncherError("primary anchored failure")


module.os.close = failing_close
try:
    module.install_launcher(
        str(data_home),
        str(new_target),
        str(new_icon),
        after_anchor=fail_after_anchor,
    )
except module.LauncherError as error:
    if str(error) != "primary anchored failure":
        raise RuntimeError("descriptor close masked the primary failure") from error
else:
    raise RuntimeError("primary anchored failure was not propagated")
finally:
    module.os.close = original_close
if not close_failure_injected:
    raise RuntimeError("descriptor-close failure was not injected")
PYTHON_TRANSACTION_ROLLBACKS
}

test_installer_signal_supervision() {
    local data_home decoy_pid decoy_survived=false index installer_source_copy
    local launcher_pid launcher_status registration_status=0 signal_log signal_name
    local stale_status=0
    local python_shim_bin real_python validator_bin validator_pid validator_started
    local -a signal_names=(HUP INT TERM)
    local -a signal_statuses=(129 130 143)

    # A PID retained across a completed wait must never authorize signaling a
    # same-UID process that is not a direct child of the installer wrapper.
    installer_source_copy="${TEST_ROOT}/install-gui-source-only.sh"
    sed '$d' "${COPIED_PROJECT}/install-gui.sh" >"${installer_source_copy}"
    chmod 0600 -- "${installer_source_copy}"
    sleep 30 &
    decoy_pid=$!
    # shellcheck disable=SC2016 # Variables belong to the nested source probe.
    bash -c '
        set -euo pipefail
        source "$1"
        INSTALLER_HELPER_PID=$2
        INSTALLER_REQUESTED_SIGNAL=TERM
        terminate_installer_helper_if_child || true
    ' bash "${installer_source_copy}" "${decoy_pid}" || registration_status=$?
    # shellcheck disable=SC2016 # Variables belong to the nested source probe.
    bash -c '
        set -euo pipefail
        source "$1"
        INSTALLER_HELPER_PID=$2
        request_installer_shutdown TERM 143
        exit 99
    ' bash "${installer_source_copy}" "${decoy_pid}" || stale_status=$?
    if kill -0 -- "${decoy_pid}" 2>/dev/null; then
        decoy_survived=true
    fi
    kill -TERM -- "${decoy_pid}" 2>/dev/null || true
    wait "${decoy_pid}" 2>/dev/null || true
    assert_equals 0 "${registration_status}" \
        'installer ignores a deferred signal for a retained non-child PID'
    assert_equals 143 "${stale_status}" \
        'installer rejects a retained non-child helper PID'
    [[ ${decoy_survived} == true ]] \
        || fail 'Installer signaled a retained non-child PID.'

    validator_bin="${TEST_ROOT}/signal-validator-bin"
    mkdir -p -- "${validator_bin}"
    cat >"${validator_bin}/desktop-file-validate" <<'EOF_SIGNAL_VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
trap '' HUP INT TERM
printf '%s\n' "$$" >"${MOCK_VALIDATOR_STARTED_MARKER:?}"
while :; do
    sleep 1
done
EOF_SIGNAL_VALIDATOR
    chmod +x -- "${validator_bin}/desktop-file-validate"

    # A signal sent only to the public Bash wrapper must reach the helper,
    # interrupt validation, reap the validator, and leave no partial state.
    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        data_home="${TEST_ROOT}/installer-wrapper-signal-${signal_name}"
        validator_started="${TEST_ROOT}/installer-validator-${signal_name}.pid"
        signal_log="${TEST_ROOT}/installer-wrapper-signal-${signal_name}.log"
        env --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            PATH="${validator_bin}:${PATH}" \
            XDG_DATA_HOME="${data_home}" \
            MOCK_VALIDATOR_STARTED_MARKER="${validator_started}" \
            bash "${COPIED_PROJECT}/install-gui.sh" install \
            >"${signal_log}" 2>&1 &
        launcher_pid=$!
        for _attempt in {1..100}; do
            [[ -s ${validator_started} ]] && break
            sleep 0.05
        done
        [[ -s ${validator_started} ]] \
            || fail "Installer ${signal_name} validator did not start."
        IFS= read -r validator_pid <"${validator_started}"
        kill "-${signal_name}" -- "${launcher_pid}"
        launcher_status=0
        wait "${launcher_pid}" || launcher_status=$?
        assert_equals "${signal_statuses[index]}" "${launcher_status}" \
            "installer wrapper ${signal_name} status"
        for _attempt in {1..40}; do
            ! kill -0 -- "${validator_pid}" 2>/dev/null && break
            sleep 0.05
        done
        ! kill -0 -- "${validator_pid}" 2>/dev/null \
            || fail "Installer ${signal_name} left its validator alive."
        assert_no_launcher_leaves_at "${data_home}" \
            "installer wrapper ${signal_name} rollback"
        assert_no_install_temporary_files_at "${data_home}" \
            "installer wrapper ${signal_name} cleanup"
        if grep -Fq 'Traceback (most recent call last)' "${signal_log}"; then
            cat -- "${signal_log}" >&2 || true
            fail "Installer ${signal_name} emitted a Python traceback."
        fi
    done

    # Bash starts asynchronous children with SIGINT ignored. A delayed python3
    # shim makes that startup window deterministic: the wrapper must translate
    # INT to an internal TERM instead of letting the helper install afterward.
    python_shim_bin="${TEST_ROOT}/signal-python-shim-bin"
    real_python=$(command -v python3)
    mkdir -p -- "${python_shim_bin}"
    cat >"${python_shim_bin}/python3" <<'EOF_SIGNAL_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
delay_pid=''
terminate_delay() {
    if [[ -n ${delay_pid} ]]; then
        kill -TERM -- "${delay_pid}" 2>/dev/null || true
        wait "${delay_pid}" 2>/dev/null || true
    fi
    exit 143
}
trap terminate_delay TERM
printf '%s\n' "$$" >"${MOCK_PYTHON_STARTED_MARKER:?}"
sleep 0.8 &
delay_pid=$!
wait "${delay_pid}"
delay_pid=''
trap - TERM
exec "${REAL_PYTHON:?}" "$@"
EOF_SIGNAL_PYTHON
    chmod +x -- "${python_shim_bin}/python3"
    data_home="${TEST_ROOT}/installer-pre-python-INT"
    validator_started="${TEST_ROOT}/installer-python-shim-INT.pid"
    signal_log="${TEST_ROOT}/installer-pre-python-INT.log"
    env --default-signal=HUP \
        --default-signal=INT \
        --default-signal=TERM \
        PATH="${python_shim_bin}:${PATH}" \
        XDG_DATA_HOME="${data_home}" \
        REAL_PYTHON="${real_python}" \
        MOCK_PYTHON_STARTED_MARKER="${validator_started}" \
        bash "${COPIED_PROJECT}/install-gui.sh" install \
        >"${signal_log}" 2>&1 &
    launcher_pid=$!
    for _attempt in {1..100}; do
        [[ -s ${validator_started} ]] && break
        sleep 0.05
    done
    [[ -s ${validator_started} ]] \
        || fail 'Installer delayed python3 shim did not start.'
    kill -INT -- "${launcher_pid}"
    launcher_status=0
    wait "${launcher_pid}" || launcher_status=$?
    assert_equals 130 "${launcher_status}" \
        'installer pre-Python INT status'
    assert_no_launcher_leaves_at "${data_home}" \
        'installer pre-Python INT cancellation'
    assert_no_install_temporary_files_at "${data_home}" \
        'installer pre-Python INT cleanup'
    if grep -Fq 'Launcher installed:' "${signal_log}"; then
        fail 'Installer completed after pre-Python INT cancellation.'
    fi

    # The same guarantee applies when the signal reaches the wrapper and helper
    # together through their complete foreground process group.
    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        data_home="${TEST_ROOT}/installer-group-signal-${signal_name}"
        validator_started="${TEST_ROOT}/installer-group-validator-${signal_name}.pid"
        signal_log="${TEST_ROOT}/installer-group-signal-${signal_name}.log"
        setsid --wait env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            PATH="${validator_bin}:${PATH}" \
            XDG_DATA_HOME="${data_home}" \
            MOCK_VALIDATOR_STARTED_MARKER="${validator_started}" \
            bash "${COPIED_PROJECT}/install-gui.sh" install \
            >"${signal_log}" 2>&1 &
        launcher_pid=$!
        for _attempt in {1..100}; do
            [[ -s ${validator_started} ]] && break
            sleep 0.05
        done
        [[ -s ${validator_started} ]] \
            || fail "Installer group-signal ${signal_name} validator did not start."
        IFS= read -r validator_pid <"${validator_started}"
        kill "-${signal_name}" -- "-${launcher_pid}"
        launcher_status=0
        wait "${launcher_pid}" || launcher_status=$?
        assert_equals "${signal_statuses[index]}" "${launcher_status}" \
            "installer foreground-group ${signal_name} status"
        for _attempt in {1..40}; do
            ! kill -0 -- "${validator_pid}" 2>/dev/null && break
            sleep 0.05
        done
        ! kill -0 -- "${validator_pid}" 2>/dev/null \
            || fail "Installer foreground-group ${signal_name} left its validator alive."
        assert_no_launcher_leaves_at "${data_home}" \
            "installer foreground-group ${signal_name} rollback"
        assert_no_install_temporary_files_at "${data_home}" \
            "installer foreground-group ${signal_name} cleanup"
        if grep -Fq 'Traceback (most recent call last)' "${signal_log}"; then
            cat -- "${signal_log}" >&2 || true
            fail "Installer foreground-group ${signal_name} emitted a Python traceback."
        fi
    done
}

test_installer_final_revalidation() {
    assert_status 0 'installer revalidates visible root and launcher target last' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/installer-final-revalidation" <<'PYTHON_FINAL_REVALIDATION'
import importlib.util
import os
import pathlib
import sys

helper_path, test_root_raw = sys.argv[1:]
test_root = pathlib.Path(test_root_raw)
test_root.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def write_target(path: pathlib.Path) -> None:
    path.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


def assert_no_launcher(data_home: pathlib.Path) -> None:
    for leaf in (
        data_home / "applications" / module.DESKTOP_NAME,
        data_home / module.APP_ID / "launch",
        data_home / "icons/hicolor/scalable/apps" / module.ICON_NAME,
    ):
        if leaf.exists() or leaf.is_symlink():
            raise RuntimeError(f"managed leaf survived a rejected transaction: {leaf}")


launcher_target = test_root / "gui.sh"
write_target(launcher_target)
data_home = test_root / "late-root"
saved_home = test_root / "late-root-saved"
original_validate_root = module.validate_data_home_path_identity
validation_count = 0


def replace_after_first_final_root_check(path: str, descriptor: int) -> None:
    global validation_count
    original_validate_root(path, descriptor)
    validation_count += 1
    if validation_count == 2:
        os.rename(path, saved_home)
        os.mkdir(path, mode=0o700)


module.validate_data_home_path_identity = replace_after_first_final_root_check
try:
    module.install_launcher(
        str(data_home), str(launcher_target), str(test_root / "missing-icon.svg")
    )
except module.LauncherError as error:
    if "changed during the launcher transaction" not in str(error):
        raise
else:
    raise SystemExit(1)
finally:
    module.validate_data_home_path_identity = original_validate_root
assert_no_launcher(saved_home)
assert_no_launcher(data_home)

data_home = test_root / "late-uninstall-root"
saved_home = test_root / "late-uninstall-root-saved"
module.install_launcher(
    str(data_home), str(launcher_target), str(test_root / "missing-icon.svg")
)
validation_count = 0
module.validate_data_home_path_identity = replace_after_first_final_root_check
try:
    module.uninstall_launcher(str(data_home))
except module.LauncherError as error:
    if "changed during the launcher transaction" not in str(error):
        raise
else:
    raise SystemExit(1)
finally:
    module.validate_data_home_path_identity = original_validate_root
if not (
    (saved_home / "applications" / module.DESKTOP_NAME).is_file()
    and (saved_home / module.APP_ID / "launch").is_symlink()
    and (
        saved_home / "icons/hicolor/scalable/apps" / module.ICON_NAME
    ).is_file()
):
    raise SystemExit(1)
assert_no_launcher(data_home)

data_home = test_root / "removed-target"
launcher_target = test_root / "removed-target-gui.sh"
write_target(launcher_target)
original_validate_desktop = module.validate_desktop_file


def remove_target_after_desktop_validation(
    applications_fd: int, temporary_name: str
) -> None:
    original_validate_desktop(applications_fd, temporary_name)
    launcher_target.unlink()


module.validate_desktop_file = remove_target_after_desktop_validation
try:
    module.install_launcher(
        str(data_home), str(launcher_target), str(test_root / "missing-icon.svg")
    )
except module.LauncherError as error:
    if "launcher target changed during the transaction" not in str(error):
        raise
else:
    raise SystemExit(1)
finally:
    module.validate_desktop_file = original_validate_desktop
assert_no_launcher(data_home)

data_home = test_root / "late-removed-target"
launcher_target = test_root / "late-removed-target-gui.sh"
write_target(launcher_target)
original_validate_managed = module.validate_managed_path_identities


def remove_target_after_managed_validation(*args: object, **kwargs: object) -> None:
    original_validate_managed(*args, **kwargs)
    launcher_target.unlink()


module.validate_managed_path_identities = remove_target_after_managed_validation
try:
    module.install_launcher(
        str(data_home), str(launcher_target), str(test_root / "missing-icon.svg")
    )
except module.LauncherError as error:
    if "launcher target changed during the transaction" not in str(error):
        raise
else:
    raise SystemExit(1)
finally:
    module.validate_managed_path_identities = original_validate_managed
assert_no_launcher(data_home)

missing_target_data = test_root / "missing-target-data"
try:
    module.install_launcher(
        str(missing_target_data),
        str(test_root / "never-created-gui.sh"),
        str(test_root / "missing-icon.svg"),
    )
except module.LauncherError as error:
    if "launcher target is absent or unsafe" not in str(error):
        raise
else:
    raise SystemExit(1)
if missing_target_data.exists():
    raise SystemExit(1)

original_cwd = os.getcwd()
missing_branches_data = test_root / "missing-branches-data"
missing_branches_data.mkdir(mode=0o700)
directory_decoy_cwd = test_root / "directory-decoy-cwd"
(directory_decoy_cwd / "launch").mkdir(parents=True, mode=0o700)
try:
    os.chdir(directory_decoy_cwd)
    module.uninstall_launcher(str(missing_branches_data))
finally:
    os.chdir(original_cwd)
if not (directory_decoy_cwd / "launch").is_dir():
    raise SystemExit(1)

rollback_decoy_data = test_root / "rollback-decoy-data"
rollback_decoy_data.mkdir(mode=0o700)
rollback_decoy_cwd = test_root / "rollback-decoy-cwd"
rollback_decoy_cwd.mkdir(mode=0o700)
original_validate_managed = module.validate_managed_path_identities


def create_cwd_decoy_then_fail(*_args: object, **_kwargs: object) -> None:
    pathlib.Path("launch").write_text("preserve\n", encoding="utf-8")
    raise module.LauncherError("injected final validation failure")


module.validate_managed_path_identities = create_cwd_decoy_then_fail
try:
    os.chdir(rollback_decoy_cwd)
    try:
        module.uninstall_launcher(str(rollback_decoy_data))
    except module.LauncherError as error:
        if "injected final validation failure" not in str(error):
            raise
    else:
        raise SystemExit(1)
finally:
    os.chdir(original_cwd)
    module.validate_managed_path_identities = original_validate_managed
if (rollback_decoy_cwd / "launch").read_text(encoding="utf-8") != "preserve\n":
    raise SystemExit(1)
if any(rollback_decoy_cwd.glob(".launch.*.backup")):
    raise SystemExit(1)
PYTHON_FINAL_REVALIDATION
}

test_installer_allocation_failure_cleanup() {
    assert_status 0 'installer allocations clean up every partial stage' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/installer-allocation-failures" \
        "${COPIED_PROJECT}/download-video-gui.sh" <<'PYTHON_ALLOCATION_FAILURES'
import errno
import importlib.util
import os
import pathlib
import sys

helper_path, test_root_raw, launcher_target = sys.argv[1:]
test_root = pathlib.Path(test_root_raw)
test_root.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def assert_no_staging(data_home: pathlib.Path) -> None:
    applications = data_home / "applications"
    launcher = data_home / module.APP_ID
    icons = data_home / "icons/hicolor/scalable/apps"
    leftovers = []
    if applications.exists():
        leftovers.extend(
            path for path in applications.iterdir() if path.name.startswith(f".{module.APP_ID}.")
        )
    if launcher.exists():
        leftovers.extend(path for path in launcher.iterdir() if path.name.startswith(".install."))
    if icons.exists():
        leftovers.extend(path for path in icons.iterdir() if path.name.startswith(f".{module.APP_ID}."))
    if leftovers:
        raise SystemExit(1)


data_home = test_root / "second-file"
original_create = module.create_temporary_file
create_count = 0


def fail_second_file(*args: object, **kwargs: object) -> str:
    global create_count
    create_count += 1
    if create_count == 2:
        raise OSError(errno.ENOSPC, "injected second-file failure")
    return original_create(*args, **kwargs)


module.create_temporary_file = fail_second_file
try:
    module.install_launcher(
        str(data_home), launcher_target, str(test_root / "missing-icon.svg")
    )
except OSError as error:
    if error.errno != errno.ENOSPC:
        raise
else:
    raise SystemExit(1)
finally:
    module.create_temporary_file = original_create
assert_no_staging(data_home)

data_home = test_root / "staging-open"
original_open_child = module.open_child_directory


def fail_staging_open(
    parent_fd: int,
    name: str,
    display_path: str,
    *,
    create: bool,
    missing_ok: bool = False,
) -> int | None:
    if name.startswith(".install."):
        raise module.LauncherError("injected staging-open failure")
    return original_open_child(
        parent_fd,
        name,
        display_path,
        create=create,
        missing_ok=missing_ok,
    )


module.open_child_directory = fail_staging_open
try:
    module.install_launcher(
        str(data_home), launcher_target, str(test_root / "missing-icon.svg")
    )
except module.LauncherError as error:
    if "injected staging-open failure" not in str(error):
        raise
else:
    raise SystemExit(1)
finally:
    module.open_child_directory = original_open_child
assert_no_staging(data_home)

data_home = test_root / "first-write"
original_write = module.os.write


def fail_first_write(_descriptor: int, _content: object) -> int:
    raise OSError(errno.ENOSPC, "injected write failure")


module.os.write = fail_first_write
try:
    module.install_launcher(
        str(data_home), launcher_target, str(test_root / "missing-icon.svg")
    )
except OSError as error:
    if error.errno != errno.ENOSPC:
        raise
else:
    raise SystemExit(1)
finally:
    module.os.write = original_write
assert_no_staging(data_home)
PYTHON_ALLOCATION_FAILURES
}

test_installer_bounded_dependencies() {
    assert_status 0 'installer bounds locks validators and cleanup diagnostics' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/installer-bounded-dependencies" <<'PYTHON_BOUNDED_DEPENDENCIES'
import contextlib
import errno
import importlib.util
import io
import os
import pathlib
import sys
import time

helper_path, test_root_raw = sys.argv[1:]
test_root = pathlib.Path(test_root_raw)
test_root.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

fifo_path = test_root / "non-regular-input.fifo"
os.mkfifo(fifo_path, mode=0o700)
for operation, expected_diagnostic in (
    (
        lambda: module.open_launcher_target(str(fifo_path)),
        "launcher target is not a regular executable file",
    ),
    (
        lambda: module.read_bounded_regular_file(str(fifo_path), "icon source"),
        "icon source is not a regular non-symlink file",
    ),
):
    started = time.monotonic()
    try:
        operation()
    except module.LauncherError as error:
        if expected_diagnostic not in str(error):
            raise
    else:
        raise SystemExit(1)
    if time.monotonic() - started >= 1:
        raise SystemExit(1)

lock_root = test_root / "lock-root"
lock_root.mkdir(mode=0o700)
lock_fd = os.open(lock_root, module.directory_open_flags())
original_flock = module.fcntl.flock
original_lock_timeout = module.LOCK_TIMEOUT_SECONDS


def always_busy(_descriptor: int, _operation: int) -> None:
    raise BlockingIOError(errno.EAGAIN, "injected busy lock")


module.fcntl.flock = always_busy
module.LOCK_TIMEOUT_SECONDS = 0.05
started = time.monotonic()
try:
    module.lock_data_home(lock_fd, str(lock_root))
except module.TemporaryLauncherError as error:
    if "timed out waiting" not in str(error):
        raise
else:
    raise SystemExit(1)
finally:
    module.LOCK_TIMEOUT_SECONDS = original_lock_timeout
    module.fcntl.flock = original_flock
    os.close(lock_fd)
if time.monotonic() - started >= 1:
    raise SystemExit(1)

applications = test_root / "applications"
applications.mkdir(mode=0o700)
temporary_name = ".desktop-under-test"
(applications / temporary_name).write_text("[Desktop Entry]\n", encoding="utf-8")
applications_fd = os.open(applications, module.directory_open_flags())
original_which = module.shutil.which
original_validator_timeout = module.VALIDATOR_TIMEOUT_SECONDS


class ReapedValidator:
    pid = 424242
    stdout = None
    returncode = 0

    @staticmethod
    def poll() -> int:
        return 0

    @staticmethod
    def wait(*, timeout: float) -> int:
        return 0


original_popen = module.subprocess.Popen
original_shutdown_requested = module.shutdown_requested
original_killpg = module.os.killpg
stale_group_signals: list[tuple[int, int]] = []
module.shutil.which = lambda _name: "/already-reaped-validator"
module.subprocess.Popen = lambda *_args, **_kwargs: ReapedValidator()
module.shutdown_requested = lambda: True
module.os.killpg = lambda pid, sig: stale_group_signals.append((pid, sig))
try:
    module.validate_desktop_file(applications_fd, temporary_name)
finally:
    module.os.killpg = original_killpg
    module.shutdown_requested = original_shutdown_requested
    module.subprocess.Popen = original_popen
    module.shutil.which = original_which
if stale_group_signals:
    raise RuntimeError("validator cleanup signaled an already-reaped process group")

timeout_marker = test_root / "validator-timeout.pid"
timeout_validator = test_root / "validator-timeout.py"
timeout_validator.write_text(
    f"#!{sys.executable}\n"
    "import os\n"
    "import time\n"
    f"open({str(timeout_marker)!r}, 'w', encoding='ascii').write(str(os.getpid()))\n"
    "time.sleep(30)\n",
    encoding="utf-8",
)
timeout_validator.chmod(0o755)
module.shutil.which = lambda _name: str(timeout_validator)
module.VALIDATOR_TIMEOUT_SECONDS = 0.2
started = time.monotonic()
try:
    module.validate_desktop_file(applications_fd, temporary_name)
except module.TemporaryLauncherError as error:
    if "ten-second safety limit" not in str(error):
        raise
else:
    raise SystemExit(1)
if time.monotonic() - started >= 2:
    raise SystemExit(1)
validator_pid = int(timeout_marker.read_text(encoding="ascii"))
try:
    os.kill(validator_pid, 0)
except ProcessLookupError:
    pass
else:
    raise SystemExit(1)

output_validator = test_root / "validator-output.py"
output_validator.write_text(
    f"#!{sys.executable}\n"
    "import os\n"
    "os.write(1, b'x' * 131072)\n"
    "raise SystemExit(9)\n",
    encoding="utf-8",
)
output_validator.chmod(0o755)
module.shutil.which = lambda _name: str(output_validator)
module.VALIDATOR_TIMEOUT_SECONDS = 2
validator_diagnostic = io.StringIO()
try:
    with contextlib.redirect_stderr(validator_diagnostic):
        module.validate_desktop_file(applications_fd, temporary_name)
except module.ReportedLauncherError:
    pass
else:
    raise SystemExit(1)
diagnostic = validator_diagnostic.getvalue()
if "validator output truncated at 64 KiB" not in diagnostic or len(diagnostic) > 70000:
    raise SystemExit(1)
module.VALIDATOR_TIMEOUT_SECONDS = original_validator_timeout
module.shutil.which = original_which
os.close(applications_fd)

partial_root = test_root / "partial-file"
partial_root.mkdir(mode=0o700)
partial_fd = os.open(partial_root, module.directory_open_flags())
original_write = module.os.write
original_unlink = module.os.unlink


def fail_write(_descriptor: int, _content: object) -> int:
    raise OSError(errno.ENOSPC, "injected primary write failure")


def fail_partial_unlink(name: str, *args: object, **kwargs: object) -> None:
    if name.startswith(".probe."):
        raise OSError(errno.EACCES, "injected secondary cleanup failure")
    original_unlink(name, *args, **kwargs)


module.os.write = fail_write
module.os.unlink = fail_partial_unlink
cleanup_diagnostic = io.StringIO()
try:
    with contextlib.redirect_stderr(cleanup_diagnostic):
        module.create_temporary_file(partial_fd, ".probe.", ".tmp", b"content")
except OSError as error:
    if error.errno != errno.ENOSPC:
        raise
else:
    raise SystemExit(1)
finally:
    module.os.unlink = original_unlink
    module.os.write = original_write
    os.close(partial_fd)
if "unable to remove a partial launcher temporary file" not in cleanup_diagnostic.getvalue():
    raise SystemExit(1)
partial_files = list(partial_root.iterdir())
if len(partial_files) != 1:
    raise SystemExit(1)
partial_files[0].unlink()
PYTHON_BOUNDED_DEPENDENCIES
}

test_installer_stale_mount_boundaries() {
    assert_status 0 'stale cleanup preserves unverified mount boundaries' \
        python3 - \
        "${COPIED_PROJECT}/private-launcher-manager.py" \
        "${TEST_ROOT}/installer-stale-mounts" \
        "${COPIED_PROJECT}/download-video-gui.sh" <<'PYTHON_STALE_MOUNTS'
import importlib.util
import os
import pathlib
import sys

helper_path, test_root_raw, launcher_target = sys.argv[1:]
test_root = pathlib.Path(test_root_raw)
test_root.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("private_launcher_manager", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit(70)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def make_stage(launcher: pathlib.Path, stage_name: str) -> pathlib.Path:
    stage = launcher / stage_name
    stage.mkdir(parents=True, mode=0o700)
    (stage / "launch").symlink_to(launcher_target)
    return stage


launcher = test_root / "different-mount"
stage = make_stage(launcher, ".install.0123456789abcdef01234567")
launcher_fd = os.open(launcher, module.directory_open_flags())
parent_identity = os.fstat(launcher_fd)
original_mount_id = module.descriptor_mount_id


def mismatched_mount_id(descriptor: int) -> int:
    identity = os.fstat(descriptor)
    if (
        identity.st_dev == parent_identity.st_dev
        and identity.st_ino == parent_identity.st_ino
    ):
        return 100
    return 101


module.descriptor_mount_id = mismatched_mount_id
try:
    module.remove_stale_artifacts(None, launcher_fd, None)
finally:
    module.descriptor_mount_id = original_mount_id
    os.close(launcher_fd)
if not (stage / "launch").is_symlink():
    raise SystemExit(1)

launcher = test_root / "unknown-mount"
stage = make_stage(launcher, ".install.Ab12Cd34")
launcher_fd = os.open(launcher, module.directory_open_flags())
module.descriptor_mount_id = lambda _descriptor: None
try:
    module.remove_stale_artifacts(None, launcher_fd, None)
finally:
    module.descriptor_mount_id = original_mount_id
    os.close(launcher_fd)
if not (stage / "launch").is_symlink():
    raise SystemExit(1)
PYTHON_STALE_MOUNTS
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

    # Scenario: uninstall removes only exact current/legacy temporary namespaces
    # and preserves close names or impossible directory types.
    mkdir -p -- \
        "${LAUNCHER_DIR}/.install.Ab12Cd34" \
        "${LAUNCHER_DIR}/.install.0123456789abcdef01234567" \
        "${LAUNCHER_DIR}/.install.personal" \
        "${LAUNCHER_DIR}/.validate.Ab12Cd34.desktop" \
        "${LAUNCHER_DIR}/.launch.fedcbafedcbafedcbafedcba.backup" \
        "${APPLICATION_DIR}/.yt-dlp-aria2-downloader.abcdefabcdefabcdefabcdef.desktop" \
        "${APPLICATION_DIR}/.yt-dlp-aria2-downloader.Zy98Xw76.tmp" \
        "${APPLICATION_DIR}/.yt-dlp-aria2-downloader.fedcbafedcbafedcbafedcba.backup" \
        "${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.abcdefabcdefabcdefabcdef.tmp" \
        "${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.fedcbafedcbafedcbafedcba.backup"
    : >"${LAUNCHER_DIR}/.install.personal/keep"
    : >"${LAUNCHER_DIR}/.validate.Ab12Cd34.desktop/keep"
    : >"${LAUNCHER_DIR}/.launch.fedcbafedcbafedcbafedcba.backup/keep"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.abcdefabcdefabcdefabcdef.desktop/keep"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.Zy98Xw76.tmp/keep"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.fedcbafedcbafedcbafedcba.backup/keep"
    : >"${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.abcdefabcdefabcdefabcdef.tmp/keep"
    : >"${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.fedcbafedcbafedcbafedcba.backup/keep"
    : >"${LAUNCHER_DIR}/.validate.Zy98Xw76.desktop"
    : >"${LAUNCHER_DIR}/.launch.0123456789abcdef01234567.backup"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.Ab12Cd34.tmp"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.0123456789abcdef01234567.desktop"
    : >"${APPLICATION_DIR}/.yt-dlp-aria2-downloader.0123456789abcdef01234567.backup"
    : >"${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.Ab12Cd34.tmp"
    : >"${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.0123456789abcdef01234567.tmp"
    : >"${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.0123456789abcdef01234567.backup"
    assert_status 0 'uninstall cleans stale installer artifacts' \
        env XDG_DATA_HOME="${DATA_HOME}" \
        bash "${COPIED_PROJECT}/install-gui.sh" uninstall
    [[ ! -e ${LAUNCHER_DIR}/.install.Ab12Cd34 &&
        ! -e ${LAUNCHER_DIR}/.install.0123456789abcdef01234567 &&
        ! -e ${LAUNCHER_DIR}/.validate.Zy98Xw76.desktop &&
        ! -e ${LAUNCHER_DIR}/.launch.0123456789abcdef01234567.backup &&
        ! -e ${APPLICATION_DIR}/.yt-dlp-aria2-downloader.Ab12Cd34.tmp &&
        ! -e ${APPLICATION_DIR}/.yt-dlp-aria2-downloader.0123456789abcdef01234567.desktop &&
        ! -e ${APPLICATION_DIR}/.yt-dlp-aria2-downloader.0123456789abcdef01234567.backup &&
        ! -e ${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.Ab12Cd34.tmp &&
        ! -e ${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.0123456789abcdef01234567.tmp &&
        ! -e ${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.0123456789abcdef01234567.backup ]] \
        || fail 'An exact stale installer artifact remained.'
    local preserved_decoy
    for preserved_decoy in \
        "${LAUNCHER_DIR}/.install.personal/keep" \
        "${LAUNCHER_DIR}/.validate.Ab12Cd34.desktop/keep" \
        "${LAUNCHER_DIR}/.launch.fedcbafedcbafedcbafedcba.backup/keep" \
        "${APPLICATION_DIR}/.yt-dlp-aria2-downloader.abcdefabcdefabcdefabcdef.desktop/keep" \
        "${APPLICATION_DIR}/.yt-dlp-aria2-downloader.Zy98Xw76.tmp/keep" \
        "${APPLICATION_DIR}/.yt-dlp-aria2-downloader.fedcbafedcbafedcbafedcba.backup/keep" \
        "${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.abcdefabcdefabcdefabcdef.tmp/keep" \
        "${DATA_HOME}/icons/hicolor/scalable/apps/.yt-dlp-aria2-downloader.fedcbafedcbafedcbafedcba.backup/keep"; do
        [[ -f ${preserved_decoy} ]] \
            || fail "Stale cleanup removed the decoy: ${preserved_decoy}"
    done

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
    test_installer_uninstall_anchor_race
    test_installer_install_anchor_race
    test_installer_install_branch_races
    test_installer_concurrent_transactions
    test_installer_transaction_rollbacks
    test_installer_signal_supervision
    test_installer_final_revalidation
    test_installer_allocation_failure_cleanup
    test_installer_bounded_dependencies
    test_installer_stale_mount_boundaries
    test_installer_uninstall_lifecycle
    printf 'Installer integration tests passed.\n'
}

main "$@"
