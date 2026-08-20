#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Hermetic integration using real yt-dlp, aria2c, FFmpeg, and FFprobe.

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR

for command_name in aria2c ffmpeg ffprobe grep mktemp python3 realpath sleep; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 77
    }
done
command -v yt-dlp >/dev/null 2>&1 || {
    printf 'Error: required command is absent: yt-dlp\n' >&2
    exit 77
}

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
SERVER_PID=''

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${SERVER_PID} ]]; then
        kill -TERM -- "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "${TEST_ROOT}/web" "${TEST_ROOT}/output" "${TEST_ROOT}/runtime"
chmod 700 -- "${TEST_ROOT}/runtime"

ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'testsrc2=size=160x90:rate=10' \
    -f lavfi -i 'sine=frequency=1000:sample_rate=44100' \
    -t 2 -shortest -c:v mpeg4 -q:v 5 -c:a aac \
    "${TEST_ROOT}/web/av.mp4"
ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'testsrc2=size=160x90:rate=10' \
    -t 1 -c:v mpeg4 -q:v 5 -an \
    "${TEST_ROOT}/web/video-only.mp4"

cat >"${TEST_ROOT}/server.py" <<'PY_SERVER'
import http.server
import pathlib
import socketserver
import sys

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *args):
        return

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

class Server(socketserver.TCPServer):
    allow_reuse_address = True

with Server(
    ("127.0.0.1", 0),
    lambda *args, **kwargs: Handler(*args, directory=str(root), **kwargs),
) as server:
    port_file.write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()
PY_SERVER

python3 "${TEST_ROOT}/server.py" \
    "${TEST_ROOT}/web" "${TEST_ROOT}/port" &
SERVER_PID=$!
for _ in {1..100}; do
    [[ -s ${TEST_ROOT}/port ]] && break
    sleep 0.05
done
[[ -s ${TEST_ROOT}/port ]] || {
    printf 'FAIL: local HTTP server did not publish its port.\n' >&2
    exit 1
}
PORT=$(<"${TEST_ROOT}/port")
readonly PORT

export XDG_RUNTIME_DIR="${TEST_ROOT}/runtime"
export YTDLP_ARIA2_SKIP_RUNTIME_UPDATE=1
YTDLP_ARIA2_YTDLP_BIN=$(command -v yt-dlp)
export YTDLP_ARIA2_YTDLP_BIN
export YTDLP_DISABLE_REMOTE_EJS=1

RESULT_FILE="${TEST_ROOT}/result.txt"
bash "${PROJECT_DIR}/download-video.sh" \
    --mode video \
    --output-dir "${TEST_ROOT}/output" \
    --result-file "${RESULT_FILE}" \
    "http://127.0.0.1:${PORT}/av.mp4"
FINAL_FILE=$(<"${RESULT_FILE}")
readonly FINAL_FILE
[[ -f ${FINAL_FILE} ]] || {
    printf 'FAIL: real-tool result file is absent.\n' >&2
    exit 1
}
ffprobe -v error -select_streams v:0 \
    -show_entries stream=index -of csv=p=0 "${FINAL_FILE}" |
    grep -Eq '^[0-9]+$'
ffprobe -v error -select_streams a:0 \
    -show_entries stream=index -of csv=p=0 "${FINAL_FILE}" |
    grep -Eq '^[0-9]+$'

rm -f -- "${RESULT_FILE}"
set +e
bash "${PROJECT_DIR}/download-video.sh" \
    --mode video \
    --output-dir "${TEST_ROOT}/output" \
    --result-file "${RESULT_FILE}" \
    "http://127.0.0.1:${PORT}/video-only.mp4"
video_only_status=$?
set -e
if ((video_only_status != 65)); then
    printf 'FAIL: missing-audio validation returned %d instead of 65.\n' \
        "${video_only_status}" >&2
    exit 1
fi
[[ ! -e ${RESULT_FILE} ]] || {
    printf 'FAIL: invalid video-only media published a result file.\n' >&2
    exit 1
}

printf 'Real-tool integration passed.\n'
