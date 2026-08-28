#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/real-tools-integration.sh
# Purpose     : Exercise real yt-dlp, aria2c, FFmpeg and FFprobe on local media.
# ==============================================================================

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
PORT=''
ARIA2_INVOCATION_LOG=''
RUN_FINAL_FILE=''
REAL_DIRECT_FINAL=''
REAL_SOURCE_OPUS_CODEC=''

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${SERVER_PID} ]]; then
        kill -TERM -- "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
}

assert_media_streams() {
    local media_path=$1
    local video_index=''
    local audio_index=''

    video_index=$(
        ffprobe -v error -select_streams V:0 \
            -show_entries stream=index -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect content video stream: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ ${video_index} =~ ^[0-9]+$ ]] || {
        printf 'FAIL: media has no content video stream: %s\n' \
            "${media_path}" >&2
        return 65
    }

    audio_index=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=index -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect audio stream: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ ${audio_index} =~ ^[0-9]+$ ]] || {
        printf 'FAIL: media has no audio stream: %s\n' \
            "${media_path}" >&2
        return 65
    }

    ffmpeg -hide_banner -loglevel error -xerror -nostdin \
        -i "${media_path}" \
        -map 0:V:0 -map 0:a:0 -t 0.5 -f null - \
        >/dev/null 2>&1 || {
        printf 'FAIL: media streams are present but not decodable: %s\n' \
            "${media_path}" >&2
        return 65
    }
}

assert_audio_only_codec() {
    local media_path=$1
    local expected_codec=$2
    local actual_codec
    local video_index=''

    actual_codec=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect audio codec: %s\n' "${media_path}" >&2
        return 65
    }
    [[ ${actual_codec} == "${expected_codec}" ]] || {
        printf 'FAIL: audio codec changed from %s to %s.\n' \
            "${expected_codec}" "${actual_codec}" >&2
        return 65
    }
    video_index=$(
        ffprobe -v error -select_streams v:0 \
            -show_entries stream=index -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect audio-result video streams: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ -z ${video_index} ]] || {
        printf 'FAIL: audio result unexpectedly retained a video stream.\n' >&2
        return 65
    }
}

assert_audio_cover_codec() {
    local media_path=$1
    local expected_codec=$2
    local actual_codec
    local cover_index=''
    local content_video_index=''
    local attached_pic=''

    actual_codec=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect cover-art audio codec: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ ${actual_codec} == "${expected_codec}" ]] || {
        printf 'FAIL: cover-art audio codec changed from %s to %s.\n' \
            "${expected_codec}" "${actual_codec}" >&2
        return 65
    }

    cover_index=$(
        ffprobe -v error -select_streams v:0 \
            -show_entries stream=index -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect cover-art video attachment: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ ${cover_index} =~ ^[0-9]+$ ]] || {
        printf 'FAIL: cover-art audio result has no video attachment.\n' >&2
        return 65
    }

    content_video_index=$(
        ffprobe -v error -select_streams V:0 \
            -show_entries stream=index -of csv=p=0 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect cover-art content video: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ -z ${content_video_index} ]] || {
        printf 'FAIL: cover-art audio result unexpectedly contains content video.\n' >&2
        return 65
    }

    attached_pic=$(
        ffprobe -v error -select_streams v:0 \
            -show_entries stream_disposition=attached_pic \
            -of default=noprint_wrappers=1:nokey=1 "${media_path}"
    ) || {
        printf 'FAIL: unable to inspect cover-art disposition: %s\n' \
            "${media_path}" >&2
        return 65
    }
    [[ ${attached_pic} == 1 ]] || {
        printf 'FAIL: video attachment is not marked attached_pic.\n' >&2
        return 65
    }
}

run_engine() {
    local mode=$1
    local scenario=$2
    local url=$3
    local engine=${4:-"${PROJECT_DIR}/download-video.sh"}
    local scenario_dir="${TEST_ROOT}/output/${scenario}"
    local result_file="${TEST_ROOT}/${scenario}.result"
    local output_file="${TEST_ROOT}/${scenario}.stdout"
    local engine_status=0

    RUN_FINAL_FILE=''
    mkdir -p -- "${scenario_dir}"
    rm -f -- "${result_file}" "${output_file}"
    set +e
    bash "${engine}" \
        --mode "${mode}" \
        --output-dir "${scenario_dir}" \
        --result-file "${result_file}" \
        "${url}" >"${output_file}" 2>&1
    engine_status=$?
    set -e
    if ((engine_status != 0)); then
        printf 'FAIL: %s engine returned status %d.\n' \
            "${scenario}" "${engine_status}" >&2
        sed -n '1,160p' -- "${output_file}" >&2 || true
        return 65
    fi
    [[ -s ${result_file} ]] || {
        printf 'FAIL: %s did not publish a result file.\n' "${scenario}" >&2
        return 65
    }
    if ! IFS= read -r RUN_FINAL_FILE <"${result_file}"; then
        printf 'FAIL: %s published an unreadable result file.\n' "${scenario}" >&2
        return 65
    fi
    [[ -n ${RUN_FINAL_FILE} ]] || {
        printf 'FAIL: %s published an empty result path.\n' "${scenario}" >&2
        return 65
    }
}

assert_native_fragment_routing() {
    local engine=$1
    grep -Fq -- "--downloader 'dash,m3u8:native'" "${engine}"
}

prepare_real_tool_fixtures() {
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
        -f lavfi -i 'sine=frequency=660:sample_rate=48000' \
        -t 2 -c:a libopus -b:a 96k \
        "${TEST_ROOT}/web/audio-opus.webm"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'color=c=blue:s=32x32' \
        -frames:v 1 -c:v mjpeg -update 1 \
        "${TEST_ROOT}/web/cover.jpg"

    # Use MP3/ID3 APIC deliberately for this validator regression fixture.
    # yt-dlp's metadata postprocessor treats M4A as audio-only and invokes FFmpeg
    # with -vn, which removes an attached picture before final validation. MP3 is a
    # common audio format, so --audio-format best does not reconvert it, while the
    # metadata postprocessor maps/copies all streams and preserves the cover.
    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'sine=frequency=550:sample_rate=44100' \
        -t 2 -c:a libmp3lame -b:a 96k \
        "${TEST_ROOT}/web/audio-cover-base.mp3"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -i "${TEST_ROOT}/web/audio-cover-base.mp3" \
        -i "${TEST_ROOT}/web/cover.jpg" \
        -map 0:a:0 -map 1:v:0 -c copy \
        -id3v2_version 3 \
        -metadata:s:v title='Album cover' \
        -metadata:s:v comment='Cover (front)' \
        -disposition:v:0 attached_pic \
        "${TEST_ROOT}/web/audio-cover.mp3"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -i "${TEST_ROOT}/web/av.mp4" \
        -i "${TEST_ROOT}/web/cover.jpg" \
        -map 0:v:0 -map 0:a:0 -map 1:v:0 -c copy \
        -disposition:v:0 0 -disposition:v:1 attached_pic -movflags +faststart \
        "${TEST_ROOT}/web/av-cover.mp4"

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

    # shellcheck disable=SC2310 # Predicate failure is the assertion result.
    assert_native_fragment_routing "${PROJECT_DIR}/download-video.sh" || {
        printf 'FAIL: native DASH/HLS routing invariant is absent.\n' >&2
        exit 65
    }
}

test_real_direct_audio_scenarios() {
    local audio_final combined_final combined_source_codec cover_final
    local opus_final source_audio_codec source_cover_codec

    # Scenario: direct HTTP must cross the real aria2c boundary.
    : >"${ARIA2_INVOCATION_LOG}"
    run_engine video direct "http://127.0.0.1:${PORT}/av.mp4"
    REAL_DIRECT_FINAL=${RUN_FINAL_FILE}
    [[ -f ${REAL_DIRECT_FINAL} ]] || {
        printf 'FAIL: direct HTTP result is absent.\n' >&2
        exit 65
    }
    assert_media_streams "${REAL_DIRECT_FINAL}"
    [[ -s ${ARIA2_INVOCATION_LOG} ]] || {
        printf 'FAIL: direct HTTP transfer did not invoke real aria2c.\n' >&2
        exit 65
    }

    # Scenario: audio mode remains valid and preserves AAC when no conversion is needed.
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
    assert_audio_only_codec "${audio_final}" "${source_audio_codec}"
    [[ -s ${ARIA2_INVOCATION_LOG} ]] || {
        printf 'FAIL: direct audio transfer did not invoke real aria2c.\n' >&2
        exit 65
    }

    # Scenario: Opus/WebM audio-only preserves the source codec without forced conversion.
    : >"${ARIA2_INVOCATION_LOG}"
    REAL_SOURCE_OPUS_CODEC=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name -of csv=p=0 \
            "${TEST_ROOT}/web/audio-opus.webm"
    )
    [[ ${REAL_SOURCE_OPUS_CODEC} == opus ]] || {
        printf 'FAIL: generated Opus fixture has unexpected codec: %s.\n' \
            "${REAL_SOURCE_OPUS_CODEC}" >&2
        exit 65
    }
    run_engine audio audio-opus "http://127.0.0.1:${PORT}/audio-opus.webm"
    opus_final=${RUN_FINAL_FILE}
    [[ -f ${opus_final} ]] || {
        printf 'FAIL: Opus audio result is absent.\n' >&2
        exit 65
    }
    assert_audio_only_codec "${opus_final}" "${REAL_SOURCE_OPUS_CODEC}"
    [[ -s ${ARIA2_INVOCATION_LOG} ]] || {
        printf 'FAIL: direct Opus transfer did not invoke real aria2c.\n' >&2
        exit 65
    }

    # Scenario: the ba/b fallback extracts audio from combined A/V, removes video,
    # and preserves AAC when yt-dlp can do so without transcoding.
    : >"${ARIA2_INVOCATION_LOG}"
    combined_source_codec=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name -of csv=p=0 \
            "${TEST_ROOT}/web/av.mp4"
    )
    run_engine audio audio-combined "http://127.0.0.1:${PORT}/av.mp4"
    combined_final=${RUN_FINAL_FILE}
    [[ -f ${combined_final} ]] || {
        printf 'FAIL: combined-source audio result is absent.\n' >&2
        exit 65
    }
    assert_audio_only_codec "${combined_final}" "${combined_source_codec}"
    [[ -s ${ARIA2_INVOCATION_LOG} ]] || {
        printf 'FAIL: combined direct transfer did not invoke real aria2c.\n' >&2
        exit 65
    }

    # Scenario: attached-cover audio is valid; v:0 sees the cover while V:0 sees no
    # content-video stream, and the final result retains that distinction.
    source_cover_codec=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name -of csv=p=0 \
            "${TEST_ROOT}/web/audio-cover.mp3"
    )
    assert_audio_cover_codec "${TEST_ROOT}/web/audio-cover.mp3" "${source_cover_codec}"
    : >"${ARIA2_INVOCATION_LOG}"
    run_engine audio audio-cover "http://127.0.0.1:${PORT}/audio-cover.mp3"
    cover_final=${RUN_FINAL_FILE}
    [[ -f ${cover_final} ]] || {
        printf 'FAIL: attached-cover audio result is absent.\n' >&2
        exit 65
    }
    assert_audio_cover_codec "${cover_final}" "${source_cover_codec}"
    [[ -s ${ARIA2_INVOCATION_LOG} ]] || {
        printf 'FAIL: attached-cover direct audio did not invoke real aria2c.\n' >&2
        exit 65
    }
}

test_real_media_validation_mutations() {
    local extract_audio_count mutated_cover_dir mutated_cover_engine
    local mutated_cover_result mutated_cover_status mutated_no_extract_cover_dir
    local mutated_no_extract_cover_result mutated_no_extract_cover_status
    local mutated_no_extract_dir mutated_no_extract_engine mutated_no_extract_result
    local mutated_no_extract_status val001_audio_index val001_full_packets
    local val001_log val001_mutant val001_output_dir val001_result val001_status
    local val001_truncated val001_truncated_packets val001_video_index

    # Mutation tests execute temporary copies of the engine. Keep the private
    # aria2 planning helper beside those copies so direct HTTP reaches the
    # intended mutated validation logic instead of failing dependency discovery.
    cp -- "${PROJECT_DIR}/private-aria2-plan.py" "${TEST_ROOT}/private-aria2-plan.py"
    chmod 644 -- "${TEST_ROOT}/private-aria2-plan.py"

    # VAL-001 regression: create a clean physical truncation that still exposes
    # both expected streams and retains fewer content-video packets. A temporary
    # engine injects it immediately before final validation. The production
    # packet-tail consistency gate must reject it and withhold the result-file.
    val001_truncated="${TEST_ROOT}/val001-truncated.mkv"
    python3 - "${REAL_DIRECT_FINAL}" "${val001_truncated}" <<'PY_VAL001_TRUNCATE'
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = source.read_bytes()
if len(payload) < 1024:
    raise SystemExit("VAL-001 source fixture is unexpectedly small")
target.write_bytes(payload[: max(1, len(payload) // 2)])
PY_VAL001_TRUNCATE

    val001_video_index=$(
        ffprobe -v error -select_streams V:0 \
            -show_entries stream=index -of csv=p=0 "${val001_truncated}" 2>/dev/null
    ) || true
    val001_audio_index=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=index -of csv=p=0 "${val001_truncated}" 2>/dev/null
    ) || true
    val001_full_packets=$(
        ffprobe -v error -select_streams V:0 -count_packets \
            -show_entries stream=nb_read_packets -of csv=p=0 "${REAL_DIRECT_FINAL}"
    )
    val001_truncated_packets=$(
        ffprobe -v error -select_streams V:0 -count_packets \
            -show_entries stream=nb_read_packets -of csv=p=0 \
            "${val001_truncated}" 2>/dev/null
    ) || true

    [[ ${val001_video_index} =~ ^[0-9]+$ &&
        ${val001_audio_index} =~ ^[0-9]+$ &&
        ${val001_full_packets} =~ ^[0-9]+$ &&
        ${val001_truncated_packets} =~ ^[0-9]+$ &&
        ${val001_truncated_packets} -lt ${val001_full_packets} ]] || {
        printf '%s\n' \
            'FAIL: VAL-001 clean-truncation fixture is not structurally suitable.' >&2
        exit 65
    }

    val001_mutant="${TEST_ROOT}/download-video-val001-mutant.sh"
    cp -- "${PROJECT_DIR}/download-video.sh" "${val001_mutant}"
    python3 - "${val001_mutant}" <<'PY_VAL001_MUTATE'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "    emit_machine_postprocess started MediaValidation\n"
if text.count(needle) != 1:
    raise SystemExit(
        f"VAL-001 mutation expected one validation anchor; found {text.count(needle)}"
    )
injection = """    if [[ -n ${VAL001_REPLACEMENT:-} ]]; then
        cp -- "${VAL001_REPLACEMENT}" "${final_media_path}" || {
            error 'VAL-001 fixture injection failed.'
            exit 70
        }
    fi

"""
path.write_text(text.replace(needle, injection + needle, 1), encoding="utf-8")
PY_VAL001_MUTATE
    chmod 700 -- "${val001_mutant}"

    val001_output_dir="${TEST_ROOT}/output/val001-tail"
    val001_result="${TEST_ROOT}/val001-tail.result"
    val001_log="${TEST_ROOT}/val001-tail.stdout"
    mkdir -p -- "${val001_output_dir}"
    val001_status=0
    VAL001_REPLACEMENT="${val001_truncated}" \
        bash "${val001_mutant}" \
        --mode video \
        --output-dir "${val001_output_dir}" \
        --result-file "${val001_result}" \
        "http://127.0.0.1:${PORT}/av.mp4" \
        >"${val001_log}" 2>&1 || val001_status=$?

    if ((val001_status != 65)); then
        printf 'FAIL: VAL-001 mutant returned %d instead of 65.\n' \
            "${val001_status}" >&2
        sed -n '1,160p' -- "${val001_log}" >&2 || true
        exit 65
    fi
    [[ ! -e ${val001_result} ]] || {
        printf '%s\n' \
            'FAIL: VAL-001 clean truncation published a result-file.' >&2
        exit 65
    }
    grep -Fq -- 'the final media file failed FFprobe validation:' \
        "${val001_log}" || {
        printf '%s\n' \
            'FAIL: VAL-001 clean truncation failed for an unexpected reason.' >&2
        sed -n '1,160p' -- "${val001_log}" >&2 || true
        exit 65
    }
    printf '%s\n' \
        'Expected regression detected: metadata-parseable clean truncation was rejected.'

    # Mutation test: change only the final audio validator's V:0 selector to v:0
    # in a temporary engine copy. The valid attached-cover fixture must then be
    # rejected, proving this test kills that regression.
    mutated_cover_engine="${TEST_ROOT}/download-video-cover-mutated.sh"
    cp -- "${PROJECT_DIR}/download-video.sh" "${mutated_cover_engine}"
    python3 - "${mutated_cover_engine}" <<'PY_COVER_MUTATION'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

function_start = next(
    (
        index
        for index, line in enumerate(lines)
        if line.rstrip("\n") == "validate_final_media_file() {"
    ),
    None,
)
if function_start is None:
    raise SystemExit("validate_final_media_file function is absent")

function_end = next(
    (
        index
        for index in range(function_start + 1, len(lines))
        if lines[index].rstrip("\n") == "}"
    ),
    None,
)
if function_end is None:
    raise SystemExit("validate_final_media_file function end is absent")

audio_start = next(
    (
        index
        for index in range(function_start + 1, function_end)
        if lines[index].strip() == "audio)"
    ),
    None,
)
if audio_start is None:
    raise SystemExit("audio validation branch is absent")

audio_end = next(
    (
        index
        for index in range(audio_start + 1, function_end)
        if lines[index].strip() == ";;"
    ),
    None,
)
if audio_end is None:
    raise SystemExit("audio validation branch end is absent")

old_selector = 'probe_stream stream_present "${final_path}" \'V:0\''
new_selector = 'probe_stream stream_present "${final_path}" \'v:0\''

matches = [
    index
    for index in range(audio_start, audio_end + 1)
    if old_selector in lines[index]
]
if len(matches) != 1:
    raise SystemExit(
        "expected exactly one V:0 validator inside the audio branch; "
        f"found {len(matches)}"
    )

selector_index = matches[0]
lines[selector_index] = lines[selector_index].replace(
    old_selector,
    new_selector,
    1,
)

path.write_text("".join(lines), encoding="utf-8")
PY_COVER_MUTATION
    mutated_cover_dir="${TEST_ROOT}/output/audio-cover-mutated"
    mutated_cover_result="${TEST_ROOT}/audio-cover-mutated.result"
    mkdir -p -- "${mutated_cover_dir}"
    rm -f -- "${mutated_cover_result}"
    set +e
    bash "${mutated_cover_engine}" \
        --mode audio \
        --output-dir "${mutated_cover_dir}" \
        --result-file "${mutated_cover_result}" \
        "http://127.0.0.1:${PORT}/audio-cover.mp3" \
        >"${TEST_ROOT}/audio-cover-mutated.stdout" 2>&1
    mutated_cover_status=$?
    set -e
    if ((mutated_cover_status != 65)); then
        printf 'FAIL: V:0 -> v:0 cover mutation returned %d instead of 65.\n' \
            "${mutated_cover_status}" >&2
        exit 65
    fi
    [[ ! -e ${mutated_cover_result} ]] || {
        printf 'FAIL: V:0 -> v:0 cover mutation published a result-file.\n' >&2
        exit 65
    }
    printf 'Expected mutation detected: v:0 rejected attached cover art.\n'

    # Mutation test: remove --extract-audio from a temporary engine copy. The
    # combined A/V source then remains A/V, and final validation must reject it
    # with EX_DATAERR instead of publishing an audio success result.
    mutated_no_extract_engine="${TEST_ROOT}/download-video-no-extract-mutated.sh"
    cp -- "${PROJECT_DIR}/download-video.sh" "${mutated_no_extract_engine}"
    extract_audio_count=$(grep -Ec '^[[:space:]]*--extract-audio[[:space:]]*$' \
        "${mutated_no_extract_engine}" || true)
    if [[ ${extract_audio_count} != 1 ]]; then
        printf 'FAIL: no-extract mutation expected one target; found %s.\n' \
            "${extract_audio_count}" >&2
        exit 65
    fi
    sed -i '/^[[:space:]]*--extract-audio[[:space:]]*$/d' "${mutated_no_extract_engine}"
    if grep -Eq '^[[:space:]]*--extract-audio[[:space:]]*$' "${mutated_no_extract_engine}"; then
        printf 'FAIL: unable to create the no-extract audio mutation.\n' >&2
        exit 65
    fi
    mutated_no_extract_dir="${TEST_ROOT}/output/audio-no-extract-mutated"
    mutated_no_extract_result="${TEST_ROOT}/audio-no-extract-mutated.result"
    mkdir -p -- "${mutated_no_extract_dir}"
    rm -f -- "${mutated_no_extract_result}"
    set +e
    bash "${mutated_no_extract_engine}" \
        --mode audio \
        --output-dir "${mutated_no_extract_dir}" \
        --result-file "${mutated_no_extract_result}" \
        "http://127.0.0.1:${PORT}/av.mp4" \
        >"${TEST_ROOT}/audio-no-extract-mutated.stdout" 2>&1
    mutated_no_extract_status=$?
    set -e
    if ((mutated_no_extract_status != 65)); then
        printf 'FAIL: unextracted A/V audio mutation returned %d instead of 65.\n' \
            "${mutated_no_extract_status}" >&2
        exit 65
    fi
    [[ ! -e ${mutated_no_extract_result} ]] || {
        printf 'FAIL: unextracted A/V audio mutation published a result-file.\n' >&2
        exit 65
    }
    grep -Fq -- 'the final media file failed FFprobe validation:' \
        "${TEST_ROOT}/audio-no-extract-mutated.stdout" || {
        printf 'FAIL: audio-no-extract-mutated failed for an unexpected reason.\n' >&2
        sed -n '1,120p' -- "${TEST_ROOT}/audio-no-extract-mutated.stdout" >&2 || true
        exit 65
    }

    # Negative control: an attached cover must not hide a real content-video
    # stream. Reuse the no-extract mutant so A/V+cover reaches final validation.
    mutated_no_extract_cover_dir="${TEST_ROOT}/output/audio-no-extract-cover-mutated"
    mutated_no_extract_cover_result="${TEST_ROOT}/audio-no-extract-cover-mutated.result"
    mkdir -p -- "${mutated_no_extract_cover_dir}"
    rm -f -- "${mutated_no_extract_cover_result}"
    set +e
    bash "${mutated_no_extract_engine}" \
        --mode audio \
        --output-dir "${mutated_no_extract_cover_dir}" \
        --result-file "${mutated_no_extract_cover_result}" \
        "http://127.0.0.1:${PORT}/av-cover.mp4" \
        >"${TEST_ROOT}/audio-no-extract-cover-mutated.stdout" 2>&1
    mutated_no_extract_cover_status=$?
    set -e
    if ((mutated_no_extract_cover_status != 65)); then
        printf 'FAIL: unextracted A/V+cover mutation returned %d instead of 65.\n' \
            "${mutated_no_extract_cover_status}" >&2
        exit 65
    fi
    [[ ! -e ${mutated_no_extract_cover_result} ]] || {
        printf 'FAIL: unextracted A/V+cover mutation published a result-file.\n' >&2
        exit 65
    }
    grep -Fq -- 'the final media file failed FFprobe validation:' \
        "${TEST_ROOT}/audio-no-extract-cover-mutated.stdout" || {
        printf 'FAIL: audio-no-extract-cover-mutated failed for an unexpected reason.\n' >&2
        sed -n '1,120p' -- "${TEST_ROOT}/audio-no-extract-cover-mutated.stdout" >&2 || true
        exit 65
    }
}

test_real_fragment_routing_and_mutations() {
    local dash_final hls_final mutated_audio_codec mutated_audio_engine
    local mutated_audio_final mutated_engine mutation_diagnostic mutation_status
    local video_only_status

    # Scenario: HLS fragments stay on yt-dlp's native downloader.
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

    # Scenario: DASH fragments stay on yt-dlp's native downloader.
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

    # Contract check: structural validation remains part of real-tool qualification.
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

    # Mutation test: deleting the protocol-specific override must be detected.
    mutated_engine="${TEST_ROOT}/download-video-mutated.sh"
    cp -- "${PROJECT_DIR}/download-video.sh" "${mutated_engine}"
    sed -i "/--downloader 'dash,m3u8:native'/d" "${mutated_engine}"
    # shellcheck disable=SC2310 # Predicate success means the mutation escaped detection.
    if assert_native_fragment_routing "${mutated_engine}"; then
        printf 'FAIL: routing mutation was not detected.\n' >&2
        exit 65
    fi

    # Mutation test: forcing MP3 in a temporary engine copy must be caught by the
    # Opus codec-preservation assertion. The repository source is never changed.
    mutated_audio_engine="${TEST_ROOT}/download-video-audio-mutated.sh"
    cp -- "${PROJECT_DIR}/download-video.sh" "${mutated_audio_engine}"
    python3 - "${mutated_audio_engine}" <<'PY_FORCE_MP3'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "--audio-format best"
count = text.count(needle)
if count != 1:
    raise SystemExit(
        f"forced-MP3 mutation expected exactly one {needle!r}; found {count}"
    )
path.write_text(text.replace(needle, "--audio-format mp3", 1), encoding="utf-8")
PY_FORCE_MP3
    grep -Fq -- '--audio-format mp3' "${mutated_audio_engine}" || {
        printf 'FAIL: unable to create the forced-MP3 audio mutation.\n' >&2
        exit 65
    }
    : >"${ARIA2_INVOCATION_LOG}"
    run_engine audio audio-opus-mutated \
        "http://127.0.0.1:${PORT}/audio-opus.webm" "${mutated_audio_engine}"
    mutated_audio_final=${RUN_FINAL_FILE}
    mutation_diagnostic="${TEST_ROOT}/audio-mutation.expected.stderr"
    set +e
    assert_audio_only_codec \
        "${mutated_audio_final}" "${REAL_SOURCE_OPUS_CODEC}" \
        2>"${mutation_diagnostic}"
    mutation_status=$?
    set -e
    if ((mutation_status == 0)); then
        printf 'FAIL: forced-MP3 mutation escaped the Opus preservation test.\n' >&2
        exit 65
    fi
    mutated_audio_codec=$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name -of csv=p=0 \
            "${mutated_audio_final}"
    )
    [[ ${mutated_audio_codec} == mp3 ]] || {
        printf 'FAIL: forced-MP3 mutation did not produce MP3 as expected; got %s.\n' \
            "${mutated_audio_codec}" >&2
        exit 65
    }
    grep -Fq -- 'audio codec changed from opus to mp3' "${mutation_diagnostic}" || {
        printf 'FAIL: forced-MP3 mutation failed for an unexpected reason.\n' >&2
        sed -n '1,120p' -- "${mutation_diagnostic}" >&2 || true
        exit 65
    }
    printf 'Expected mutation detected: forced MP3 was rejected by Opus preservation.\n'
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    prepare_real_tool_fixtures
    test_real_direct_audio_scenarios
    test_real_media_validation_mutations
    test_real_fragment_routing_and_mutations
    printf 'Real-tool direct/audio/Opus/fallback/cover/HLS/DASH integration passed.\n'
}

main "$@"
