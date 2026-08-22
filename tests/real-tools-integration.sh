#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Hermetic integration using real yt-dlp, aria2c, FFmpeg, and FFprobe.

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR

for command_name in aria2c bash cp ffmpeg ffprobe grep mktemp python3 realpath sed sleep; do
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
REAL_ARIA2=$(command -v aria2c)
readonly REAL_ARIA2

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

mkdir -p -- \
    "${TEST_ROOT}/web/hls" \
    "${TEST_ROOT}/web/dash" \
    "${TEST_ROOT}/output" \
    "${TEST_ROOT}/runtime" \
    "${TEST_ROOT}/shim"
chmod 700 -- "${TEST_ROOT}/runtime"

ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'testsrc2=size=160x90:rate=10' \
    -f lavfi -i 'sine=frequency=1000:sample_rate=44100' \
    -t 3 -shortest -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -g 10 -keyint_min 10 -sc_threshold 0 \
    -c:a aac -movflags +faststart \
    "${TEST_ROOT}/web/av.mp4"

ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'testsrc2=size=160x90:rate=10' \
    -t 1 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -an \
    "${TEST_ROOT}/web/video-only.mp4"

ffmpeg -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'sine=frequency=880:sample_rate=44100' \
    -t 2 -c:a aac -b:a 128k \
    "${TEST_ROOT}/web/audio.m4a"

ffmpeg -hide_banner -loglevel error -nostdin \
    -i "${TEST_ROOT}/web/av.mp4" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy -c:a copy \
    -f hls -hls_time 1 -hls_list_size 0 \
    -hls_segment_filename "${TEST_ROOT}/web/hls/segment-%03d.ts" \
    "${TEST_ROOT}/web/hls/stream.m3u8"

ffmpeg -hide_banner -loglevel error -nostdin \
    -i "${TEST_ROOT}/web/av.mp4" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy -c:a copy \
    -seg_duration 1 -use_template 1 -use_timeline 1 \
    -adaptation_sets 'id=0,streams=v id=1,streams=a' \
    -f dash "${TEST_ROOT}/web/dash/stream.mpd"

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
    exit 65
}
PORT=$(<"${TEST_ROOT}/port")
readonly PORT

ARIA2_INVOCATION_LOG="${TEST_ROOT}/aria2-invocations.bin"
export ARIA2_INVOCATION_LOG REAL_ARIA2
: >"${ARIA2_INVOCATION_LOG}"

cat >"${TEST_ROOT}/shim/aria2c" <<'EOF_ARIA2_SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
--version | --help=#all)
    exec "${REAL_ARIA2:?}" "$@"
    ;;
esac
printf '%s\0' "$@" >>"${ARIA2_INVOCATION_LOG:?}"
exec "${REAL_ARIA2:?}" "$@"
EOF_ARIA2_SHIM
chmod 700 -- "${TEST_ROOT}/shim/aria2c"
export PATH="${TEST_ROOT}/shim:${PATH}"

export XDG_RUNTIME_DIR="${TEST_ROOT}/runtime"
export YTDLP_ARIA2_SKIP_RUNTIME_UPDATE=1
YTDLP_ARIA2_YTDLP_BIN=$(command -v yt-dlp)
export YTDLP_ARIA2_YTDLP_BIN
export YTDLP_DISABLE_REMOTE_EJS=1

assert_media_streams() {
    local media_path=$1
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=index -of csv=p=0 "${media_path}" |
        grep -Eq '^[0-9]+$'
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=index -of csv=p=0 "${media_path}" |
        grep -Eq '^[0-9]+$'
}

RUN_FINAL_FILE=''
run_engine() {
    local mode=$1
    local scenario=$2
    local url=$3
    local scenario_dir="${TEST_ROOT}/output/${scenario}"
    local result_file="${TEST_ROOT}/${scenario}.result"

    RUN_FINAL_FILE=''
    mkdir -p -- "${scenario_dir}"
    rm -f -- "${result_file}"
    bash "${PROJECT_DIR}/download-video.sh" \
        --mode "${mode}" \
        --output-dir "${scenario_dir}" \
        --result-file "${result_file}" \
        "${url}" >"${TEST_ROOT}/${scenario}.stdout"
    [[ -s ${result_file} ]] || {
        printf 'FAIL: %s did not publish a result file.\n' "${scenario}" >&2
        return 65
    }
    IFS= read -r RUN_FINAL_FILE <"${result_file}" || return 65
    [[ -n ${RUN_FINAL_FILE} ]] || return 65
}

assert_native_fragment_routing() {
    local engine=$1
    grep -Fq -- "--downloader 'dash,m3u8:native'" "${engine}"
}

# shellcheck disable=SC2310 # Predicate failure is the assertion result.
assert_native_fragment_routing "${PROJECT_DIR}/download-video.sh" || {
    printf 'FAIL: native DASH/HLS routing invariant is absent.\n' >&2
    exit 65
}

# Direct HTTP must cross the real aria2c boundary.
: >"${ARIA2_INVOCATION_LOG}"
run_engine video direct "http://127.0.0.1:${PORT}/av.mp4"
direct_final=${RUN_FINAL_FILE}
[[ -f ${direct_final} ]] || {
    printf 'FAIL: direct HTTP result is absent.\n' >&2
    exit 65
}
assert_media_streams "${direct_final}"
[[ -s ${ARIA2_INVOCATION_LOG} ]] || {
    printf 'FAIL: direct HTTP transfer did not invoke real aria2c.\n' >&2
    exit 65
}

# Audio mode must remain valid and preserve AAC when no conversion is needed.
: >"${ARIA2_INVOCATION_LOG}"
source_audio_codec=$(
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of csv=p=0 \
        "${TEST_ROOT}/web/audio.m4a"
)
run_engine audio audio "http://127.0.0.1:${PORT}/audio.m4a"
audio_final=${RUN_FINAL_FILE}
[[ -f ${audio_final} ]] || {
    printf 'FAIL: audio result is absent.\n' >&2
    exit 65
}
final_audio_codec=$(
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of csv=p=0 "${audio_final}"
)
[[ ${final_audio_codec} == "${source_audio_codec}" ]] || {
    printf 'FAIL: audio codec changed from %s to %s.\n' \
        "${source_audio_codec}" "${final_audio_codec}" >&2
    exit 65
}
[[ -s ${ARIA2_INVOCATION_LOG} ]] || {
    printf 'FAIL: direct audio transfer did not invoke real aria2c.\n' >&2
    exit 65
}

# HLS fragments must stay on yt-dlp's native downloader.
: >"${ARIA2_INVOCATION_LOG}"
run_engine video hls "http://127.0.0.1:${PORT}/hls/stream.m3u8"
hls_final=${RUN_FINAL_FILE}
[[ -f ${hls_final} ]] || {
    printf 'FAIL: HLS result is absent.\n' >&2
    exit 65
}
assert_media_streams "${hls_final}"
[[ ! -s ${ARIA2_INVOCATION_LOG} ]] || {
    printf 'FAIL: aria2c was invoked for native HLS fragments.\n' >&2
    exit 65
}

# DASH fragments must stay on yt-dlp's native downloader.
: >"${ARIA2_INVOCATION_LOG}"
run_engine video dash "http://127.0.0.1:${PORT}/dash/stream.mpd"
dash_final=${RUN_FINAL_FILE}
[[ -f ${dash_final} ]] || {
    printf 'FAIL: DASH result is absent.\n' >&2
    exit 65
}
assert_media_streams "${dash_final}"
[[ ! -s ${ARIA2_INVOCATION_LOG} ]] || {
    printf 'FAIL: aria2c was invoked for native DASH fragments.\n' >&2
    exit 65
}

# Existing structural validation remains part of real-tool qualification.
rm -f -- "${TEST_ROOT}/video-only.result"
set +e
bash "${PROJECT_DIR}/download-video.sh" \
    --mode video \
    --output-dir "${TEST_ROOT}/output" \
    --result-file "${TEST_ROOT}/video-only.result" \
    "http://127.0.0.1:${PORT}/video-only.mp4"
video_only_status=$?
set -e
if ((video_only_status != 65)); then
    printf 'FAIL: missing-audio validation returned %d instead of 65.\n' \
        "${video_only_status}" >&2
    exit 65
fi
[[ ! -e ${TEST_ROOT}/video-only.result ]] || {
    printf 'FAIL: invalid video-only media published a result file.\n' >&2
    exit 65
}

# Mutation proof: deleting the protocol-specific override must be detected.
mutated_engine="${TEST_ROOT}/download-video-mutated.sh"
cp -- "${PROJECT_DIR}/download-video.sh" "${mutated_engine}"
sed -i "/--downloader 'dash,m3u8:native'/d" "${mutated_engine}"
# shellcheck disable=SC2310 # Predicate success means the mutation escaped detection.
if assert_native_fragment_routing "${mutated_engine}"; then
    printf 'FAIL: routing mutation was not detected.\n' >&2
    exit 65
fi

printf 'Real-tool direct/audio/HLS/DASH integration passed.\n'
