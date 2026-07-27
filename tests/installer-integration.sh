#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

readonly COPIED_PROJECT="${TEST_ROOT}/Project space % test"
readonly DATA_HOME="${TEST_ROOT}/data"
readonly DESKTOP_FILE="${DATA_HOME}/applications/yt-dlp-aria2-downloader.desktop"
mkdir -p -- "${COPIED_PROJECT}"
cp -- "${PROJECT_DIR}/install-gui.sh" "${COPIED_PROJECT}/"
cp -- "${PROJECT_DIR}/download-video-gui.sh" "${COPIED_PROJECT}/"
chmod +x -- "${COPIED_PROJECT}/install-gui.sh" \
    "${COPIED_PROJECT}/download-video-gui.sh"

XDG_DATA_HOME="${DATA_HOME}" "${COPIED_PROJECT}/install-gui.sh" install >/dev/null

if [[ ! -f ${DESKTOP_FILE} ]]; then
    printf 'The desktop launcher was not created.\n' >&2
    exit 1
fi

expected_exec="Exec=\"${COPIED_PROJECT//%/%%}/download-video-gui.sh\""
grep -Fxq -- "${expected_exec}" "${DESKTOP_FILE}"
grep -Fxq -- 'Terminal=false' "${DESKTOP_FILE}"
grep -Fxq -- 'Categories=AudioVideo;' "${DESKTOP_FILE}"
grep -Fxq -- 'Comment=Download a video or extract an audio track' "${DESKTOP_FILE}"
grep -Fxq -- 'Comment[fr]=Télécharger une vidéo ou extraire une piste audio' \
    "${DESKTOP_FILE}"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "${DESKTOP_FILE}"
fi

XDG_DATA_HOME="${DATA_HOME}" "${COPIED_PROJECT}/install-gui.sh" uninstall >/dev/null
if [[ -e ${DESKTOP_FILE} ]]; then
    printf 'The desktop launcher was not removed.\n' >&2
    exit 1
fi

printf 'Installer integration tests passed.\n'
