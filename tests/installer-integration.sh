#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

readonly COPIED_PROJECT="${TEST_ROOT}/Project space % test"
readonly DATA_HOME="${TEST_ROOT}/data"
readonly DESKTOP_FILE="${DATA_HOME}/applications/yt-dlp-aria2-downloader.desktop"

[[ -x ${PROJECT_DIR}/install-gui.sh ]] || fail 'install-gui.sh is not executable in the source tree.'
[[ -x ${PROJECT_DIR}/download-video-gui.sh ]] || fail 'download-video-gui.sh is not executable in the source tree.'

mkdir -p -- "${COPIED_PROJECT}"
cp -- "${PROJECT_DIR}/install-gui.sh" "${COPIED_PROJECT}/"
cp -- "${PROJECT_DIR}/download-video-gui.sh" "${COPIED_PROJECT}/"
chmod +x -- "${COPIED_PROJECT}/install-gui.sh" \
    "${COPIED_PROJECT}/download-video-gui.sh"

assert_status 0 'install desktop launcher' \
    env XDG_DATA_HOME="${DATA_HOME}" \
    "${COPIED_PROJECT}/install-gui.sh" install

[[ -f ${DESKTOP_FILE} ]] || fail 'The desktop launcher was not created.'

expected_exec="Exec=\"${COPIED_PROJECT//%/%%}/download-video-gui.sh\""
assert_file_contains "${DESKTOP_FILE}" "${expected_exec}" 'escaped desktop Exec path'
assert_file_contains "${DESKTOP_FILE}" 'Terminal=false' 'desktop terminal setting'
assert_file_contains "${DESKTOP_FILE}" 'Categories=AudioVideo;' 'desktop category'
assert_file_contains "${DESKTOP_FILE}" \
    'Comment=Download a video or extract an audio track' 'English desktop comment'
assert_file_contains "${DESKTOP_FILE}" \
    'Comment[fr]=Télécharger une vidéo ou extraire une piste audio' \
    'French desktop comment'

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "${DESKTOP_FILE}"
fi

if find "${DATA_HOME}/applications" -maxdepth 1 -type f \
    -name '.yt-dlp-aria2-downloader.*.desktop' -print -quit | grep -q .; then
    fail 'A temporary desktop file remained after installation.'
fi

# A failed validation must not replace the existing launcher, and the EXIT trap
# must remove the temporary file.
readonly VALIDATION_MOCK_BIN="${TEST_ROOT}/validation-mock-bin"
mkdir -p -- "${VALIDATION_MOCK_BIN}"
cat >"${VALIDATION_MOCK_BIN}/desktop-file-validate" <<'EOF_VALIDATE'
#!/usr/bin/env bash
exit 9
EOF_VALIDATE
chmod +x -- "${VALIDATION_MOCK_BIN}/desktop-file-validate"
launcher_checksum_before=$(sha256sum -- "${DESKTOP_FILE}")
assert_status 9 'failed validation status is preserved' \
    env PATH="${VALIDATION_MOCK_BIN}:${PATH}" XDG_DATA_HOME="${DATA_HOME}" \
    "${COPIED_PROJECT}/install-gui.sh" install
launcher_checksum_after=$(sha256sum -- "${DESKTOP_FILE}")
assert_equals "${launcher_checksum_before}" "${launcher_checksum_after}" \
    'failed validation must not replace the launcher'

if find "${DATA_HOME}/applications" -maxdepth 1 -type f \
    -name '.yt-dlp-aria2-downloader.*.desktop' -print -quit | grep -q .; then
    fail 'A temporary desktop file remained after failed validation.'
fi

assert_status 0 'uninstall existing launcher' \
    env XDG_DATA_HOME="${DATA_HOME}" \
    "${COPIED_PROJECT}/install-gui.sh" uninstall
assert_text_contains "${ASSERT_OUTPUT}" 'Launcher removed:' \
    'existing launcher removal message'
[[ ! -e ${DESKTOP_FILE} ]] || fail 'The desktop launcher was not removed.'

assert_status 0 'repeat uninstall without launcher' \
    env XDG_DATA_HOME="${DATA_HOME}" \
    "${COPIED_PROJECT}/install-gui.sh" uninstall
assert_text_contains "${ASSERT_OUTPUT}" 'No launcher is installed at:' \
    'idempotent uninstall message'

printf 'Installer integration tests passed.\n'
