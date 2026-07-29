#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"

for required_command in bash grep head mkdir mktemp rm sleep sort stdbuf tail timeout tr wc; do
    require_test_command "${required_command}"
done

readonly MONITOR="${PROJECT_DIR}/progress-monitor.sh"
assert_readable_file "${MONITOR}" 'progress monitor'

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ACTIVE_WORKER=''
ACTIVE_MONITOR=''

stop_active_processes() {
    if [[ -n ${ACTIVE_MONITOR} ]]; then
        kill -- "${ACTIVE_MONITOR}" 2>/dev/null || true
        wait "${ACTIVE_MONITOR}" 2>/dev/null || true
        ACTIVE_MONITOR=''
    fi
    if [[ -n ${ACTIVE_WORKER} ]]; then
        kill -- "${ACTIVE_WORKER}" 2>/dev/null || true
        wait "${ACTIVE_WORKER}" 2>/dev/null || true
        ACTIVE_WORKER=''
    fi
}
trap 'stop_active_processes; rm -rf -- "${TEST_ROOT}" || true' EXIT

wait_for_text() {
    local file=$1
    local text=$2
    local label=$3
    local attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [[ -r ${file} ]] && grep -Fq -- "${text}" "${file}"; then
            return 0
        fi
        sleep 0.05
    done
    fail "${label}: timed out waiting for '${text}' in ${file}"
}

start_scenario() {
    local name=$1
    local profile=$2

    SCENARIO_DIR="${TEST_ROOT}/${name}"
    LOG_FILE="${SCENARIO_DIR}/download.log"
    RESULT_FILE="${SCENARIO_DIR}/result.txt"
    CAPTURE_FILE="${SCENARIO_DIR}/progress.txt"
    mkdir -p -- "${SCENARIO_DIR}"
    : >"${LOG_FILE}"
    : >"${CAPTURE_FILE}"

    sleep 30 &
    ACTIVE_WORKER=$!
    bash "${MONITOR}" \
        "${LOG_FILE}" "${ACTIVE_WORKER}" "${RESULT_FILE}" "${profile}" \
        >"${CAPTURE_FILE}" &
    ACTIVE_MONITOR=$!
    wait_for_text "${CAPTURE_FILE}" 'Analyzing the webpage...' \
        "${name} monitor startup"
}

finish_success() {
    local requested_path=$1
    local final_path="${SCENARIO_DIR}/${requested_path##*/}"
    local monitor_status=0

    : >"${final_path}"
    printf '%s\n' "${final_path}" >"${RESULT_FILE}"
    kill -- "${ACTIVE_WORKER}" 2>/dev/null || true
    wait "${ACTIVE_WORKER}" 2>/dev/null || true
    ACTIVE_WORKER=''
    wait "${ACTIVE_MONITOR}" || monitor_status=$?
    ACTIVE_MONITOR=''
    assert_equals '0' "${monitor_status}" 'successful monitor exit status'
    assert_file_has_line "${CAPTURE_FILE}" '100' 'successful progress reaches 100%'
}

finish_failure() {
    local monitor_status=0

    kill -- "${ACTIVE_WORKER}" 2>/dev/null || true
    wait "${ACTIVE_WORKER}" 2>/dev/null || true
    ACTIVE_WORKER=''
    wait "${ACTIVE_MONITOR}" || monitor_status=$?
    ACTIVE_MONITOR=''
    assert_equals '0' "${monitor_status}" 'incomplete monitor exit status'
    assert_file_has_no_line "${CAPTURE_FILE}" '100' 'failed progress never reaches 100%'
}

max_percentage() {
    grep -E '^[0-9]+$' "$1" | sort -n | tail -n 1 || true
}

# Closing the Zenity side of the pipe must end the monitor normally instead of
# leaking a SIGPIPE status to the GUI pipeline.
pipe_scenario_dir="${TEST_ROOT}/closed-progress-pipe"
pipe_log="${pipe_scenario_dir}/download.log"
pipe_result="${pipe_scenario_dir}/result.txt"
mkdir -p -- "${pipe_scenario_dir}"
: >"${pipe_log}"
sleep 30 &
pipe_worker=$!
pipe_status=0
set +e
# The positional parameters are intentionally expanded by the inner Bash.
# shellcheck disable=SC2016
timeout --signal=TERM --kill-after=1s 5s \
    bash -o pipefail -c '
        bash "$1" "$2" "$3" "$4" video | head -n 2 >/dev/null
    ' bash "${MONITOR}" "${pipe_log}" "${pipe_worker}" "${pipe_result}"
pipe_status=$?
set -e
kill -- "${pipe_worker}" 2>/dev/null || true
wait "${pipe_worker}" 2>/dev/null || true
assert_equals '0' "${pipe_status}" 'closed progress pipe exits normally'

# Direct video transfer handled by aria2c.
start_scenario direct-aria-video video
printf '%s\n' 'YTDLP_PLAN|media|18|18|' >>"${LOG_FILE}"
printf '\r[#a1b2c3 4MiB/10MiB(40%%) CN:8 DL:1MiB ETA:6s]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" '40% (aria2c)' 'direct aria percentage'
assert_file_has_no_line "${CAPTURE_FILE}" '100' 'aria local percentage is not global completion'
finish_success '/tmp/direct-video.mkv'

# aria2c fallback without a YTDLP_PLAN record. This is the compatibility path
# used by legacy or incomplete event streams and must still update Zenity.
start_scenario aria-without-plan-audio audio
printf '\r[#a1b2c3 4MiB/10MiB(40%%) CN:8 DL:1MiB ETA:6s]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" '40% (aria2c)' 'aria fallback percentage'
assert_file_has_line "${CAPTURE_FILE}" '39' \
    'aria fallback percentage maps into the global phase'
finish_success '/tmp/aria-fallback-audio.webm'

# Direct native audio transfer.
start_scenario direct-audio audio
printf '%s\n' \
    'YTDLP_PLAN|media|251|251|' \
    'YTDLP_PROGRESS_V2|media|251|downloading|250|1000|0|0|0|25.0%|500KiB/s|00:06' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the audio track - 25%' \
    'native audio percentage'
printf '%s\n' \
    'YTDLP_PROGRESS_V2|media|251|finished|1000|1000|0|0|0|100.0%|1MiB/s|00:00' \
    >>"${LOG_FILE}"
finish_success '/tmp/audio.webm'

# One file downloaded directly by yt-dlp.
start_scenario native-single video
printf '%s\n' \
    'YTDLP_PLAN|media|22|22|' \
    'YTDLP_PROGRESS_V2|media|22|downloading|600|1000|0|0|0|60.0%|2MiB/s|00:03' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 60%' \
    'native direct percentage'
finish_success '/tmp/native.mp4'

# Fragmented HLS without a reliable byte total.
start_scenario hls-fragments video
printf '%s\n' \
    'YTDLP_PLAN|media|hls-720|hls-720|' \
    'YTDLP_PROGRESS_V2|media|hls-720|downloading|0|0|0|3|10||1MiB/s|00:07' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 30%' \
    'HLS fragment percentage'
finish_success '/tmp/hls.mkv'

# yt-dlp may report a tiny HLS manifest/bootstrap record as 100% at fragment
# 0/N. It must remain at the beginning of the global transfer phase.
start_scenario hls-bootstrap-record video
printf '%s\n' \
    'YTDLP_PLAN|media|96-21|96-21|' \
    'YTDLP_PROGRESS_V2|media|96-21|downloading|1024|0|1024|0|473|100.0%|2KiB/s|Unknown' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 0%' \
    'HLS bootstrap record is ignored'
bootstrap_max=$(max_percentage "${CAPTURE_FILE}")
[[ ${bootstrap_max} =~ ^[0-9]+$ ]] || fail 'HLS bootstrap capture has no numeric progress'
((bootstrap_max <= 5)) || fail 'HLS fragment 0/N must not advance the transfer phase'
printf '%s\n' \
    'YTDLP_PROGRESS_V2|media|96-21|downloading|23528240|0|1000442128|10|473|2.4%|24MiB/s|00:30' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 2%' \
    'HLS media fragments advance normally after bootstrap'
finish_success '/tmp/hls-bootstrap.mkv'

# Fragmented DASH with an estimated size.
start_scenario dash-fragments video
printf '%s\n' \
    'YTDLP_PLAN|media|dash-1080|dash-1080|' \
    'YTDLP_PROGRESS_V2|media|dash-1080|downloading|400|0|1000|4|10||2MiB/s|00:05' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 40%' \
    'DASH estimated-byte percentage'
finish_success '/tmp/dash.mkv'

# Separate video and audio streams: the first local 100% must stay below global completion.
start_scenario composite-video-audio video
printf '%s\n' 'YTDLP_PLAN|media|137+140|137|140' >>"${LOG_FILE}"
printf '\r[#aaa111 10MiB/10MiB(100%%) CN:8 DL:2MiB ETA:0s]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading item 1/2 - 100%' \
    'first composite item completion'
first_max=$(max_percentage "${CAPTURE_FILE}")
[[ ${first_max} =~ ^[0-9]+$ ]] || fail 'composite capture has no numeric progress'
((first_max < 90)) || fail 'first stream must not fill the global download range'
printf '\r[#bbb222 1MiB/10MiB(10%%) CN:8 DL:1MiB ETA:9s]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 10%' \
    'second composite item progress'
printf '\r[#bbb222 10MiB/10MiB(100%%) CN:8 DL:2MiB ETA:0s]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 100%' \
    'second composite item completion'
assert_file_has_no_line "${CAPTURE_FILE}" '100' 'composite downloads do not complete before merge'
printf '%s\n' 'YTDLP_POSTPROCESS|started|FFmpegMerger' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Merging the video and audio streams...' \
    'MKV merge phase'
finish_success '/tmp/composite.mkv'

# Mixed composite path: one stream is native and the next is handled by aria2c.
start_scenario mixed-native-aria video
printf '%s\n' \
    'YTDLP_PLAN|media|hls-720+140|hls-720|140' \
    'YTDLP_PROGRESS_V2|media|hls-720|finished|1000|1000|0|10|10|100.0%|2MiB/s|00:00' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading item 1/2 - 100%' \
    'mixed native item completion'
printf '\r[#d00d42 5MiB/10MiB(50%%) CN:8 DL:1MiB ETA:5s]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 50% (aria2c)' \
    'mixed aria item association'
finish_success '/tmp/mixed.mkv'

# The authenticated HLS path first repairs MPEG-TS-in-MP4 and then performs
# the final stream-copy remux into MKV.
start_scenario hls-fixup-remux video
printf '%s\n' \
    'YTDLP_PLAN|media|96-21|96-21|' \
    'YTDLP_PROGRESS_V2|media|96-21|finished|1000|1000|0|0|0|100.0%|2MiB/s|00:00' \
    'YTDLP_POSTPROCESS|started|FixupM3u8' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Repairing the downloaded media...' \
    'HLS MPEG-TS-in-MP4 fixup phase'
printf '%s\n' 'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Remuxing the media into an MKV container...' \
    'HLS final MKV remux phase'
finish_success '/tmp/hls-fixed.mkv'

# Remuxing and audio extraction are represented as indeterminate finalization phases.
start_scenario remux-mkv video
printf '%s\n' \
    'YTDLP_PLAN|media|18|18|' \
    'YTDLP_PROGRESS_V2|media|18|finished|1000|1000|0|0|0|100.0%|2MiB/s|00:00' \
    'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Remuxing the media into an MKV container...' \
    'MKV remux phase'
assert_file_has_no_line "${CAPTURE_FILE}" '100' 'remux phase stays below 100%'
finish_success '/tmp/remux.mkv'

start_scenario extract-audio audio
printf '%s\n' \
    'YTDLP_PLAN|media|18|18|' \
    'YTDLP_POSTPROCESS|started|FFmpegExtractAudio' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Extracting the native audio track...' \
    'audio extraction phase'
finish_success '/tmp/extracted.opus'

# Unknown total: the progress bar must move while remaining bounded.
start_scenario unknown-size video
printf '%s\n' 'YTDLP_PLAN|media|18|18|' >>"${LOG_FILE}"
printf '\r[#c0ffee 4MiB/0B CN:8 DL:1MiB]\r' >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'size unknown (aria2c)' 'unknown-size fallback'
sleep 0.8
unknown_values=$(grep -E '^[0-9]+$' "${CAPTURE_FILE}" | sort -u | wc -l)
((unknown_values >= 2)) || fail 'unknown-size progress must remain animated'
finish_success '/tmp/unknown.mkv'

# A late download line must not replace an active post-processing phase.
start_scenario late-progress video
printf '%s\n' \
    'YTDLP_PLAN|media|18|18|' \
    'YTDLP_POSTPROCESS|started|FFmpegMetadata' \
    'YTDLP_PROGRESS_V2|media|18|downloading|100|1000|0|0|0|10.0%|1MiB/s|00:09' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Writing media metadata...' 'late-progress phase'
assert_file_not_contains "${CAPTURE_FILE}" 'Downloading the media - 10%' \
    'late download output is ignored after post-processing starts'
finish_success '/tmp/late.mkv'

# Download and post-processing failures never emit a completed percentage.
start_scenario download-error video
printf '%s\n' \
    'YTDLP_PLAN|media|18|18|' \
    'YTDLP_PROGRESS_V2|media|18|downloading|500|1000|0|0|0|50.0%|1MiB/s|00:05' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 50%' 'download error setup'
finish_failure

start_scenario postprocess-error video
printf '%s\n' \
    'YTDLP_PLAN|media|18|18|' \
    'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' \
    >>"${LOG_FILE}"
wait_for_text "${CAPTURE_FILE}" 'Remuxing the media into an MKV container...' \
    'post-process error setup'
finish_failure

# A published path whose target file is absent is not successful completion.
start_scenario missing-final-file video
printf '%s\n' "${SCENARIO_DIR}/missing-output.mkv" >"${RESULT_FILE}"
finish_failure

printf '%s\n' 'Progress-monitor integration tests passed.'
