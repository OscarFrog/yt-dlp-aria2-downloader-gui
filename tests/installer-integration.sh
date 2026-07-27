#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}" || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

command -v desktop-file-validate >/dev/null 2>&1 ||
    fail 'desktop-file-validate is required for installer integration tests.'

readonly PROJECT_SUFFIX=$'Project space % $ ` quote" backslash\\ equals= apostrophe\' test'
readonly COPIED_PROJECT="${TEST_ROOT}/${PROJECT_SUFFIX}"
readonly DATA_SUFFIX=$'Data space $ ` quote" backslash\\ apostrophe\' test'
readonly DATA_HOME="${TEST_ROOT}/${DATA_SUFFIX}"
readonly APPLICATION_DIR="${DATA_HOME}/applications"
readonly DESKTOP_FILE="${APPLICATION_DIR}/yt-dlp-aria2-downloader.desktop"
readonly LAUNCHER_DIR="${DATA_HOME}/yt-dlp-aria2-downloader"
readonly LAUNCHER_LINK="${LAUNCHER_DIR}/launch"
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
        printf '%s\n' 'set -Eeuo pipefail'
        printf "printf '%%s\\\\n' \"\$0\" >%q\n" "${EXEC_MARKER}"
    } >"${path}"
    chmod +x -- "${path}"
}

[[ -x ${PROJECT_DIR}/install-gui.sh ]] ||
    fail 'install-gui.sh is not executable in the source tree.'

mkdir -p -- "${COPIED_PROJECT}"
cp -- "${PROJECT_DIR}/install-gui.sh" "${COPIED_PROJECT}/"
write_fake_gui "${COPIED_PROJECT}/download-video-gui.sh"
chmod +x -- "${COPIED_PROJECT}/install-gui.sh"

# shellcheck disable=SC2016 # $1 and $2 are expanded by the child bash.
assert_status 0 'install desktop launcher from hostile project path' \
    bash -c '
        umask 077
        export XDG_DATA_HOME=$1
        exec bash "$2" install
    ' bash "${DATA_HOME}" "${COPIED_PROJECT}/install-gui.sh"

[[ -f ${DESKTOP_FILE} ]] || fail 'The desktop launcher was not created.'
[[ -L ${LAUNCHER_LINK} ]] || fail 'The stable launcher link was not created.'
launcher_target=$(readlink -- "${LAUNCHER_LINK}")
assert_equals \
    "${COPIED_PROJECT}/download-video-gui.sh" \
    "${launcher_target}" \
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
actual_exec=$(grep -m1 '^Exec=' -- "${DESKTOP_FILE}")
assert_equals "${expected_exec}" "${actual_exec}" \
    'desktop Exec line uses specification-compliant escaping'

assert_file_has_line "${DESKTOP_FILE}" 'Terminal=false' \
    'desktop terminal setting'
assert_file_has_line "${DESKTOP_FILE}" 'Categories=AudioVideo;' \
    'desktop category'
assert_file_has_line "${DESKTOP_FILE}" \
    'Comment=Download a video or extract an audio track' \
    'English desktop comment'
assert_file_has_line "${DESKTOP_FILE}" \
    'Comment[fr]=Télécharger une vidéo ou extraire une piste audio' \
    'French desktop comment'

assert_status 0 'installed launcher passes desktop-file-validate' \
    desktop-file-validate --no-hints "${DESKTOP_FILE}"

launcher_mode=$(stat -c '%a' -- "${DESKTOP_FILE}")
assert_equals '644' "${launcher_mode}" 'installed launcher permissions'
launcher_dir_mode=$(stat -c '%a' -- "${LAUNCHER_DIR}")
assert_equals '700' "${launcher_dir_mode}" 'private launcher-directory permissions'
assert_no_install_temporary_files 'temporary cleanup after installation'

if command -v gio >/dev/null 2>&1; then
    rm -f -- "${EXEC_MARKER}"
    assert_status 0 'GLib launches the installed desktop entry' \
        gio launch "${DESKTOP_FILE}"
    for _ in {1..50}; do
        [[ -s ${EXEC_MARKER} ]] && break
        sleep 0.1
    done
    [[ -s ${EXEC_MARKER} ]] || fail 'gio did not launch the stable launcher link.'
    assert_equals \
        "${LAUNCHER_LINK}" \
        "$(<"${EXEC_MARKER}")" \
        'GLib launches the exact stable path'
fi

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
assert_status 9 'failed validation status is preserved' \
    env PATH="${VALIDATION_MOCK_BIN}:${PATH}" XDG_DATA_HOME="${DATA_HOME}" \
    bash "${COPIED_PROJECT}/install-gui.sh" install
assert_text_contains "${ASSERT_OUTPUT}" 'MOCK_VALIDATE_INVOKED:' \
    'validation mock invocation marker'
assert_text_contains "${ASSERT_OUTPUT}" 'previously installed launcher' \
    'failed validation preservation diagnostic'
cmp -s -- "${launcher_snapshot}" "${DESKTOP_FILE}" ||
    fail 'Failed validation replaced the existing desktop entry.'
launcher_target_after_failed_validation=$(
    readlink -- "${LAUNCHER_LINK}"
)
assert_equals \
    "${launcher_target_before}" \
    "${launcher_target_after_failed_validation}" \
    'failed validation preserves the stable launcher link'
assert_no_install_temporary_files 'temporary cleanup after failed validation'

# Explicit installation errors.
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

assert_status 0 'uninstall existing launcher' \
    env XDG_DATA_HOME="${DATA_HOME}" \
    bash "${COPIED_PROJECT}/install-gui.sh" uninstall
assert_text_contains "${ASSERT_OUTPUT}" 'Launcher removed:' \
    'existing launcher removal message'
[[ ! -e ${DESKTOP_FILE} ]] || fail 'The desktop launcher was not removed.'
[[ ! -e ${LAUNCHER_LINK} && ! -L ${LAUNCHER_LINK} ]] ||
    fail 'The stable launcher link was not removed.'

assert_status 0 'repeat uninstall without launcher' \
    env XDG_DATA_HOME="${DATA_HOME}" \
    bash "${COPIED_PROJECT}/install-gui.sh" uninstall
assert_text_contains "${ASSERT_OUTPUT}" 'No launcher is installed at:' \
    'idempotent uninstall message'

printf 'Installer integration tests passed.\n'
