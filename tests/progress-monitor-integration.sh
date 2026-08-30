#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/progress-monitor-integration.sh
# Purpose     : Validate progress parsing, weighting and completion semantics.
# ==============================================================================

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"

for required_command in bash grep head mkdir mktemp rm sed sleep sort tail timeout tr wc; do
    require_test_command "${required_command}"
done

readonly MONITOR="${PROJECT_DIR}/progress-monitor.sh"
assert_readable_file "${MONITOR}" 'progress monitor'

read_monitor_integer_constant() {
    local name=$1
    local value=''

    [[ ${name} =~ ^[A-Z][A-Z0-9_]*$ ]] \
        || fail "invalid progress-monitor constant name: ${name}"
    value=$(
        sed -n \
            "s/^[[:space:]]*readonly ${name}=\\([0-9][0-9]*\\)$/\\1/p" \
            "${MONITOR}"
    )
    [[ ${value} =~ ^[0-9]+$ ]] \
        || fail "unable to read one integer progress-monitor constant: ${name}"
    printf '%d' "$((10#${value}))"
}

map_download_to_zenity() {
    local download_percent=$1

    printf '%d' "$((\
    DOWNLOAD_START_VALUE + \
    download_percent * (DOWNLOAD_END_VALUE - DOWNLOAD_START_VALUE) / 100))"
}

video_audio_fallback_percent() {
    local video_percent=$1
    local audio_percent=$2

    printf '%d' "$(((\
    video_percent * VIDEO_FALLBACK_WEIGHT_VALUE + \
    audio_percent * AUDIO_FALLBACK_WEIGHT_VALUE) / (\
    VIDEO_FALLBACK_WEIGHT_VALUE + AUDIO_FALLBACK_WEIGHT_VALUE)))"
}

DOWNLOAD_START_VALUE=$(read_monitor_integer_constant DOWNLOAD_START)
readonly DOWNLOAD_START_VALUE
DOWNLOAD_END_VALUE=$(read_monitor_integer_constant DOWNLOAD_END)
readonly DOWNLOAD_END_VALUE
VIDEO_FALLBACK_WEIGHT_VALUE=$(
    read_monitor_integer_constant VIDEO_STREAM_FALLBACK_WEIGHT
)
readonly VIDEO_FALLBACK_WEIGHT_VALUE
AUDIO_FALLBACK_WEIGHT_VALUE=$(
    read_monitor_integer_constant AUDIO_STREAM_FALLBACK_WEIGHT
)
readonly AUDIO_FALLBACK_WEIGHT_VALUE
assert_equals '100' \
    "$((VIDEO_FALLBACK_WEIGHT_VALUE + AUDIO_FALLBACK_WEIGHT_VALUE))" \
    'video/audio fallback weights form one complete download phase'

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}" || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Most scenarios validate parsing/state transitions rather than the production
# 400 ms idle-poll cadence. Exercise those scenarios against an otherwise
# identical temporary copy with a shorter poll interval. The busy-loop/rate
# control below still uses the unmodified production monitor.
FAST_MONITOR="${TEST_ROOT}/progress-monitor-fast.sh"
readonly FAST_MONITOR

fast_poll_count=$(
    grep -Fxc -- '            sleep 0.4' "${MONITOR}" || true
)
assert_equals '1' "${fast_poll_count}" \
    'production progress monitor has one expected idle-poll sleep'

short_poll_count_before=$(
    grep -Fxc -- '            sleep 0.05' "${MONITOR}" || true
)

sed \
    's/^            sleep 0[.]4$/            sleep 0.05/' \
    "${MONITOR}" >"${FAST_MONITOR}"

fast_poll_count_after=$(
    grep -Fxc -- '            sleep 0.4' "${FAST_MONITOR}" || true
)
short_poll_count_after=$(
    grep -Fxc -- '            sleep 0.05' "${FAST_MONITOR}" || true
)

assert_equals '0' "${fast_poll_count_after}" \
    'fast progress monitor contains no production idle-poll sleep'
assert_equals "$((short_poll_count_before + 1))" "${short_poll_count_after}" \
    'fast progress monitor changes exactly one idle-poll sleep'

bash -n "${FAST_MONITOR}" \
    || fail 'generated fast progress monitor is not valid Bash'

# Per-scenario state shared by start_scenario and finish_*.
SCENARIO_DIR=''
LOG_FILE=''
RESULT_FILE=''
CAPTURE_FILE=''
ACTIVE_WORKER=''
ACTIVE_MONITOR=''
WAITED_PROCESS_STATUS=''

process_is_running() {
    local pid=$1
    local process_stat=''
    local process_state=''

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 -- "${pid}" 2>/dev/null || return 1
    if [[ -r /proc/${pid}/stat ]]; then
        if ! { IFS= read -r process_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
            return 0
        fi
        process_state=${process_stat##*) }
        process_state=${process_state%% *}
        [[ ${process_state} != Z && ${process_state} != X ]]
        return
    fi
    return 0
}

wait_for_process_exit() {
    local pid=$1
    local label=$2
    local attempts=${3:-300}
    local attempt
    local status=0

    WAITED_PROCESS_STATUS=''
    for ((attempt = 0; attempt < attempts; attempt++)); do
        # shellcheck disable=SC2310 # Predicate failure means the child exited.
        if ! process_is_running "${pid}"; then
            wait "${pid}" 2>/dev/null || status=$?
            WAITED_PROCESS_STATUS=${status}
            return 0
        fi
        sleep 0.05
    done

    kill -TERM -- "${pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
        # shellcheck disable=SC2310
        if ! process_is_running "${pid}"; then
            wait "${pid}" 2>/dev/null || true
            fail "${label}: process timed out and required SIGTERM"
        fi
        sleep 0.05
    done
    kill -KILL -- "${pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
        # shellcheck disable=SC2310
        if ! process_is_running "${pid}"; then
            wait "${pid}" 2>/dev/null || true
            fail "${label}: process timed out and required SIGKILL"
        fi
        sleep 0.05
    done
    fail "${label}: process did not exit after SIGKILL"
}

stop_process_bounded() {
    local pid=$1
    local attempt

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 0
    kill -TERM -- "${pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
        # shellcheck disable=SC2310
        process_is_running "${pid}" || {
            wait "${pid}" 2>/dev/null || true
            return 0
        }
        sleep 0.05
    done
    kill -KILL -- "${pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
        # shellcheck disable=SC2310
        if ! process_is_running "${pid}"; then
            wait "${pid}" 2>/dev/null || true
            return 0
        fi
        sleep 0.05
    done
    fail "process ${pid} did not exit after SIGKILL"
}

stop_active_processes() {
    if [[ -n ${ACTIVE_MONITOR} ]]; then
        stop_process_bounded "${ACTIVE_MONITOR}"
        ACTIVE_MONITOR=''
    fi
    if [[ -n ${ACTIVE_WORKER} ]]; then
        stop_process_bounded "${ACTIVE_WORKER}"
        ACTIVE_WORKER=''
    fi
}

wait_for_text() {
    local file=$1
    local text=$2
    local label=$3
    local attempts=${4:-300}
    local attempt
    local diagnostic=''

    for ((attempt = 0; attempt < attempts; attempt++)); do
        if [[ -r ${file} ]] && grep -Fq -- "${text}" "${file}"; then
            return 0
        fi
        sleep 0.05
    done
    diagnostic=$(tail -n 50 -- "${file}" 2>/dev/null || true)
    fail "${label}: timed out waiting for '${text}' in ${file}"$'\n'"${diagnostic}"
}

wait_for_numeric_occurrences() {
    local file=$1
    local value=$2
    local expected=$3
    local label=$4
    local attempt
    local count=0

    for ((attempt = 0; attempt < 300; attempt++)); do
        count=$(grep -Fxc -- "${value}" "${file}" 2>/dev/null || true)
        if [[ ${count} =~ ^[0-9]+$ ]] && ((count >= expected)); then
            return 0
        fi
        sleep 0.05
    done
    fail "${label}: expected ${expected} occurrences of ${value}; found ${count}"
}

wait_for_line_count_at_least() {
    local file=$1
    local expected=$2
    local label=$3
    local attempt
    local count=0

    for ((attempt = 0; attempt < 300; attempt++)); do
        if [[ -r ${file} ]]; then
            count=$(wc -l <"${file}") || count=0
        else
            count=0
        fi

        [[ ${count} =~ ^[0-9]+$ ]] || count=0
        if ((count >= expected)); then
            return 0
        fi

        sleep 0.05
    done

    fail "${label}: expected at least ${expected} lines; found ${count}"
}

wait_for_distinct_numeric_values() {
    local file=$1
    local expected=$2
    local label=$3
    local attempt
    local count=0

    for ((attempt = 0; attempt < 300; attempt++)); do
        count=$(
            grep -E '^[0-9]+$' "${file}" 2>/dev/null \
                | sort -u \
                | wc -l
        ) || count=0

        [[ ${count} =~ ^[0-9]+$ ]] || count=0
        if ((count >= expected)); then
            return 0
        fi
        sleep 0.05
    done

    fail "${label}: expected ${expected} distinct numeric values; found ${count}"
}

start_scenario() {
    local name=$1
    local profile=$2
    local monitor=${3:-${FAST_MONITOR}}

    SCENARIO_DIR="${TEST_ROOT}/${name}"
    LOG_FILE="${SCENARIO_DIR}/download.log"
    RESULT_FILE="${SCENARIO_DIR}/result.txt"
    CAPTURE_FILE="${SCENARIO_DIR}/progress.txt"
    mkdir -p -- "${SCENARIO_DIR}"
    : >"${LOG_FILE}"
    : >"${CAPTURE_FILE}"

    sleep 300 &
    ACTIVE_WORKER=$!
    bash "${monitor}" \
        "${LOG_FILE}" "${ACTIVE_WORKER}" "${RESULT_FILE}" "${profile}" \
        "${SCENARIO_DIR}" >"${CAPTURE_FILE}" &
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
    stop_process_bounded "${ACTIVE_WORKER}"
    ACTIVE_WORKER=''
    wait_for_process_exit "${ACTIVE_MONITOR}" 'successful monitor exit'
    monitor_status=${WAITED_PROCESS_STATUS}
    ACTIVE_MONITOR=''
    assert_equals '0' "${monitor_status}" 'successful monitor exit status'
    assert_file_has_line "${CAPTURE_FILE}" '100' 'successful progress reaches 100%'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'successful progress'
}

finish_failure() {
    local monitor_status=0

    stop_process_bounded "${ACTIVE_WORKER}"
    ACTIVE_WORKER=''
    wait_for_process_exit "${ACTIVE_MONITOR}" 'incomplete monitor exit'
    monitor_status=${WAITED_PROCESS_STATUS}
    ACTIVE_MONITOR=''
    assert_equals '0' "${monitor_status}" 'incomplete monitor exit status'
    assert_file_has_no_line "${CAPTURE_FILE}" '100' 'failed progress never reaches 100%'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'incomplete progress'
}

max_percentage() {
    grep -E '^[0-9]+$' "$1" | sort -n | tail -n 1 || true
}

assert_percentages_never_decrease() {
    local file=$1
    local label=$2
    local previous=-1
    local current=''
    local line_number=0
    local numeric_count=0

    while IFS= read -r current || [[ -n ${current} ]]; do
        line_number=$((line_number + 1))
        [[ ${current} =~ ^[0-9]+$ ]] || continue
        numeric_count=$((numeric_count + 1))

        if ((previous >= 0 && current < previous)); then
            fail "${label}: progress decreased from ${previous} to ${current} at capture line ${line_number}"
        fi
        previous=${current}
    done <"${file}"

    if ((numeric_count == 0)); then
        fail "${label}: no numeric progress values were captured"
    fi
}

test_monitor_reader_lifecycle() {
    local partial_capture_lines pipe_log pipe_result pipe_scenario_dir
    local pipe_status pipe_worker reader_value_count

    # Closing the Zenity side of the pipe must end the monitor normally instead of
    # leaking a SIGPIPE status to the GUI pipeline.
    pipe_scenario_dir="${TEST_ROOT}/closed-progress-pipe"
    pipe_log="${pipe_scenario_dir}/download.log"
    pipe_result="${pipe_scenario_dir}/result.txt"
    mkdir -p -- "${pipe_scenario_dir}"
    : >"${pipe_log}"
    sleep 300 &
    ACTIVE_WORKER=$!
    pipe_worker=${ACTIVE_WORKER}
    pipe_status=0
    set +e
    # The positional parameters are intentionally expanded by the inner Bash.
    # shellcheck disable=SC2016
    timeout --signal=TERM --kill-after=1s 5s \
        bash -o pipefail -c '
            bash "$1" "$2" "$3" "$4" video "$5" | head -n 2 >/dev/null
        ' bash "${MONITOR}" "${pipe_log}" "${pipe_worker}" "${pipe_result}" \
        "${pipe_scenario_dir}"
    pipe_status=$?
    set -e
    stop_process_bounded "${pipe_worker}"
    ACTIVE_WORKER=''
    assert_equals '0' "${pipe_status}" \
        "closed progress pipe exits normally (status ${pipe_status})"

    # A partial record must be retained until its terminating newline arrives.
    start_scenario partial-progress-record audio
    printf '%s' 'YTDLP_PROGRESS_V2|media|251|downloa' >>"${LOG_FILE}"

    partial_capture_lines=$(wc -l <"${CAPTURE_FILE}")
    wait_for_line_count_at_least \
        "${CAPTURE_FILE}" "$((partial_capture_lines + 2))" \
        'partial record remains buffered across a monitor cycle'

    assert_file_not_contains \
        "${CAPTURE_FILE}" 'Downloading the audio track - 25%' \
        'unterminated partial record is not processed'

    printf '%s\n' 'ding|250|1000|0|0|0|25.0%|500KiB/s|00:06' >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the audio track - 25%' \
        'partial progress record is reconstructed'
    finish_success '/tmp/partial-record.webm'

    # An oversized logical record may end in the same 64 KiB read as a valid
    # machine record. Discard only the oversized record; never the valid record
    # that follows its newline.
    start_scenario oversized-record-recovery audio
    {
        head -c 1048577 /dev/zero | tr '\0' 'X'
        printf '\n%s\n' \
            'YTDLP_PROGRESS_V2|media|251|downloading|250|1000|0|0|0|25.0%|500KiB/s|00:06'
    } >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the audio track - 25%' \
        'valid progress after oversized record is preserved'
    finish_success '/tmp/oversized-record-recovery.webm'

    # Removing the log path while the worker is alive must not create a busy loop.
    # The already-open descriptor remains safe, but no new records can arrive.
    start_scenario reader-unavailable video "${MONITOR}"
    wait_for_text "${CAPTURE_FILE}" 'Analyzing the webpage...' \
        'reader opens the progress log before its path is removed'
    rm -f -- "${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" \
        'Progress information is unavailable; the download continues...' \
        'missing progress log diagnostic'
    sleep 1
    reader_value_count=$(grep -Ec '^[0-9]+$' "${CAPTURE_FILE}" || true)
    [[ ${reader_value_count} =~ ^[0-9]+$ ]] || reader_value_count=0
    ((reader_value_count <= 8)) \
        || fail "missing progress log produced an unbounded loop: ${reader_value_count} values"
    finish_failure

    # Records appended immediately before worker exit must be drained from the
    # regular log file before the monitor performs final result verification.
    start_scenario final-log-drain video
    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|downloading|750|1000|0|0|0|75.0%|2MiB/s|00:01' \
        >>"${LOG_FILE}"
    finish_success '/tmp/final-log-drain.mkv'
    assert_file_contains "${CAPTURE_FILE}" 'Downloading the media - 75%' \
        'final log bytes are drained after worker exit'
}

test_monitor_planning_progress() {
    local fallback_video_complete fallback_video_internal
    local generic_three_expected generic_three_max
    local metadata_capture_lines metadata_download_max metadata_preprocess_max
    local private_after_second_max private_first_max

    fallback_video_internal=$(video_audio_fallback_percent 100 0)
    fallback_video_complete=$(map_download_to_zenity \
        "${fallback_video_internal}")

    # Regression guard: --parse-metadata creates a MetadataParser postprocessor
    # at yt-dlp's pre_process stage. The generic postprocess progress hook fires
    # before before_dl/YTDLP_PLAN. It must not move the global Zenity bar into
    # the 92..98 final post-processing phase.
    start_scenario metadata-preprocess-before-download video
    printf '%s\n' \
        'YTDLP_POSTPROCESS|started|MetadataParser' \
        'YTDLP_POSTPROCESS|finished|MetadataParser' \
        >>"${LOG_FILE}"

    metadata_capture_lines=$(wc -l <"${CAPTURE_FILE}")
    wait_for_line_count_at_least \
        "${CAPTURE_FILE}" "$((metadata_capture_lines + 2))" \
        'MetadataParser pre-process records cross a monitor cycle'

    metadata_preprocess_max=$(max_percentage "${CAPTURE_FILE}")
    if [[ ! ${metadata_preprocess_max} =~ ^[0-9]+$ ]] \
        || ((metadata_preprocess_max > 3)); then
        fail "MetadataParser pre_process advanced Zenity before download: ${metadata_preprocess_max}"
    fi

    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|downloading|110|1000|0|0|0|11.0%|10.24MiB/s|00:31' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 11%' \
        'download progress after MetadataParser pre_process'
    metadata_download_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals '14' "${metadata_download_max}" \
        '11 percent media progress maps to 14 percent global progress'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'MetadataParser pre_process regression'
    finish_success '/tmp/metadata-preprocess-before-download.mkv'

    # Regression guard: the private direct PLAN pass knows the transfer count,
    # but that count was not forwarded to the monitor. With two direct items,
    # the first completed aria2 item could therefore look like 100% of all
    # known bytes and jump the global bar to 90% before item 2 appeared.
    start_scenario private-direct-aria-plan video
    {
        printf '%s\n' 'ARIA2_PLAN|2'
        printf '\r[#a1b2c3 10MiB/10MiB(100%%) CN:8 DL:2MiB ETA:0s]\r'
    } >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" '100% (aria2c)' \
        'private direct first aria item'
    private_first_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${fallback_video_complete}" "${private_first_max}" \
        'first private video item uses the two-stream fallback weight'
    printf '\r[#d4e5f6 2MiB/10MiB(20%%) CN:8 DL:1MiB ETA:8s]\r' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 20% (aria2c)' \
        'private direct second aria item'
    private_after_second_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${fallback_video_complete}" "${private_after_second_max}" \
        'real-byte weighting cannot regress the prior fallback display'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'private direct aria progress'
    finish_success '/tmp/private-direct-aria-plan.mkv'

    # A combined direct video is one transfer item, not the old video fallback
    # assumption of two streams.
    start_scenario private-direct-combined-video video
    printf '%s\n' 'ARIA2_PLAN|1' >>"${LOG_FILE}"
    printf '\r[#a1b2c3 4MiB/10MiB(40%%) CN:8 DL:1MiB ETA:6s]\r' >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 40% (aria2c)' \
        'combined direct video uses the exact private transfer count'
    finish_success '/tmp/private-direct-combined-video.mkv'

    # More than two planned transfers retain the generic equal-item fallback.
    start_scenario private-direct-three-items video
    {
        printf '%s\n' 'ARIA2_PLAN|3'
        printf '\r[#a1b2c3 10MiB/10MiB(100%%) CN:8 DL:2MiB ETA:0s]\r'
    } >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 1/3 - 100% (aria2c)' \
        'generic three-item direct plan'
    generic_three_expected=$(map_download_to_zenity "$((100 / 3))")
    generic_three_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${generic_three_expected}" "${generic_three_max}" \
        'three-item plan does not receive the video/audio fallback'
    finish_success '/tmp/private-direct-three-items.mkv'
}

test_monitor_direct_transfer_progress() {
    local weighted_max

    # Scenario: direct video transfer handled by aria2c.
    start_scenario direct-aria-video video
    printf '%s\n' 'YTDLP_PLAN|media|18|18|' >>"${LOG_FILE}"
    printf '\r[#a1b2c3 4MiB/10MiB(40%%) CN:8 DL:1MiB ETA:6s]\r' >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" '40% (aria2c)' 'direct aria percentage'
    assert_file_has_no_line "${CAPTURE_FILE}" '100' 'aria local percentage is not global completion'
    finish_success '/tmp/direct-video.mkv'

    # Two direct aria2 streams with very different sizes must be aggregated by
    # transferred bytes instead of averaging their local percentages equally.
    start_scenario aria-weighted-video video
    {
        printf '%s\n' 'YTDLP_PLAN|media||137|140'
        printf '\r[#a1b2c3 900.0MiB/1000.0MiB(90%%) CN:8 DL:8MiB ETA:12s]\r'
        printf '\r[#d4e5f6 1.0MiB/10.0MiB(10%%) CN:2 DL:1MiB ETA:9s]\r'
    } >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 10% (aria2c)' \
        'second aria stream is rendered'
    weighted_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals '80' "${weighted_max}" 'aria progress is weighted by transferred bytes'
    finish_success '/tmp/aria-weighted-video.mkv'

    # aria2c fallback without a YTDLP_PLAN record. This is the compatibility path
    # used by legacy or incomplete event streams and must still update Zenity.
    start_scenario aria-without-plan-audio audio
    printf '\r[#a1b2c3 4MiB/10MiB(40%%) CN:8 DL:1MiB ETA:6s]\r' >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" '40% (aria2c)' 'aria fallback percentage'
    assert_file_has_line "${CAPTURE_FILE}" '39' \
        'aria fallback percentage maps into the global phase'
    finish_success '/tmp/aria-fallback-audio.webm'

    # Scenario: direct native audio transfer.
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
}

test_monitor_native_transfer_progress() {
    local bootstrap_max

    # Scenario: one file downloaded directly by yt-dlp.
    start_scenario native-single video
    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|downloading|600|1000|0|0|0|60.0%|2MiB/s|00:03' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 60%' \
        'native direct percentage'
    finish_success '/tmp/native.mp4'

    # Scenario: fragmented HLS without a reliable byte total.
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

    # An unknown-size transfer may animate within a narrow range, but every
    # percentage sent to Zenity must remain greater than or equal to the previous
    # one. The former triangular pulse regressed within a few ticks.
    start_scenario unknown-size-monotonic video
    printf '%s\n' \
        'YTDLP_PLAN|media|unknown-size|unknown-size|' \
        'YTDLP_PROGRESS_V2|media|unknown-size|downloading|0|0|0|0|0|||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the media - size unknown' \
        'unknown-size monotonic phase'
    wait_for_numeric_occurrences "${CAPTURE_FILE}" 7 1 \
        'unknown-size progress reaches its bounded plateau'
    finish_success '/tmp/unknown-size.mkv'

    # A long remux must move only forward through the post-processing envelope.
    # Waiting here makes the regression deterministic: the former bounded pulse
    # reached its upper bound and then emitted smaller percentages.
    start_scenario postprocess-monotonic video
    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|finished|1000|1000|0|0|0|100.0%|2MiB/s|00:00' \
        'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" \
        'Remuxing the media into an MKV container...' \
        'long remux monotonic phase'
    wait_for_numeric_occurrences "${CAPTURE_FILE}" 98 3 \
        'post-processing progress remains at its upper plateau'
    finish_success '/tmp/postprocess-monotonic.mkv'

    # Scenario: fragmented DASH with an estimated size.
    start_scenario dash-fragments video
    printf '%s\n' \
        'YTDLP_PLAN|media|dash-1080|dash-1080|' \
        'YTDLP_PROGRESS_V2|media|dash-1080|downloading|400|0|1000|4|10||2MiB/s|00:05' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the media - 40%' \
        'DASH estimated-byte percentage'
    finish_success '/tmp/dash.mkv'
}

test_monitor_video_audio_weighting() {
    local audio_half_expected audio_half_internal audio_half_max
    local download_complete_expected download_complete_max
    local known_audio_half_expected known_audio_half_max
    local known_video_complete_expected known_video_complete_max
    local transition_max video_complete_expected video_complete_internal
    local video_complete_max

    video_complete_internal=$(video_audio_fallback_percent 100 0)
    video_complete_expected=$(map_download_to_zenity \
        "${video_complete_internal}")
    audio_half_internal=$(video_audio_fallback_percent 100 50)
    audio_half_expected=$(map_download_to_zenity "${audio_half_internal}")
    download_complete_expected=$(map_download_to_zenity 100)

    # Regression guard: when neither stream has a reliable total yet, the
    # explicit full-video plan reserves 80% for video and 20% for audio.
    start_scenario native-video-audio-unknown-sizes video
    printf '%s\n' \
        'YTDLP_PLAN|media|137+140|137|140' \
        'YTDLP_PROGRESS_V2|media|137|finished|0|0|0|0|0|100.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 1/2 - 100%' \
        'unknown-size video completion'
    video_complete_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${video_complete_expected}" "${video_complete_max}" \
        'completed unknown-size video occupies its fallback share'

    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|140|downloading|0|0|0|0|0|50.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 50%' \
        'unknown-size audio midpoint'
    audio_half_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${audio_half_expected}" "${audio_half_max}" \
        'audio midpoint advances the final half of its fallback share'

    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|140|finished|0|0|0|0|0|100.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 100%' \
        'unknown-size audio completion'
    download_complete_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${download_complete_expected}" "${download_complete_max}" \
        'both unknown-size streams fill only the download phase'
    assert_file_has_no_line "${CAPTURE_FILE}" '100' \
        'two-stream transfer completion is not final media completion'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'unknown-size video/audio fallback'
    finish_success '/tmp/native-video-audio-unknown-sizes.mkv'

    # Once both totals are known, byte weighting takes priority over 80/20.
    # A 900-byte video plus 100-byte audio is 90% complete at audio byte zero.
    start_scenario native-video-audio-known-sizes video
    printf '%s\n' \
        'YTDLP_PLAN|media|137+140|137|140' \
        'YTDLP_PROGRESS_V2|media|137|finished|900|900|0|0|0|100.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 1/2 - 100%' \
        'known-size video completion before audio total'
    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|140|downloading|0|100|0|0|0|0.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 0%' \
        'known-size audio start'
    known_video_complete_expected=$(map_download_to_zenity \
        "$((900 * 100 / (900 + 100)))")
    known_video_complete_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals \
        "${known_video_complete_expected}" "${known_video_complete_max}" \
        'known 900/100 byte totals override the 80/20 fallback'

    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|140|downloading|50|100|0|0|0|50.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 50%' \
        'known-size audio midpoint'
    known_audio_half_expected=$(map_download_to_zenity \
        "$((950 * 100 / (900 + 100)))")
    known_audio_half_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals \
        "${known_audio_half_expected}" "${known_audio_half_max}" \
        'known byte weighting tracks audio bytes exactly'

    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|140|finished|100|100|0|0|0|100.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 100%' \
        'known-size audio completion'
    download_complete_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${download_complete_expected}" "${download_complete_max}" \
        'known-size streams fill the download phase'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'known-size video/audio weighting'
    finish_success '/tmp/native-video-audio-known-sizes.mkv'

    # If late totals reveal that the real byte ratio is below the earlier 80/20
    # approximation, the stable display holds its prior value instead of moving
    # backward. It resumes once the real transfer catches up.
    start_scenario native-video-audio-weight-transition video
    printf '%s\n' \
        'YTDLP_PLAN|media|137+140|137|140' \
        'YTDLP_PROGRESS_V2|media|137|finished|0|0|0|0|0|100.0%||Unknown' \
        'YTDLP_PROGRESS_V2|media|140|downloading|0|900|0|0|0|0.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 0%' \
        'transition starts from the fallback display'
    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|137|finished|100|100|0|0|0|100.0%|1MiB/s|Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" \
        'Downloading item 1/2 - 100% - 1MiB/s' \
        'late video total enables real-byte weighting'
    transition_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${video_complete_expected}" "${transition_max}" \
        'lower real-byte estimate cannot regress the fallback display'
    assert_percentages_never_decrease \
        "${CAPTURE_FILE}" 'fallback-to-byte-weight transition'

    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|140|finished|900|900|0|0|0|100.0%||Unknown' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading item 2/2 - 100%' \
        'transition completes after audio transfer'
    download_complete_max=$(max_percentage "${CAPTURE_FILE}")
    assert_equals "${download_complete_expected}" "${download_complete_max}" \
        'real-byte transition eventually reaches the download boundary'
    finish_success '/tmp/native-video-audio-weight-transition.mkv'
}

test_monitor_composite_and_postprocess_progress() {
    local first_max

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

    # Scenario: mixed composite path with native and aria2c-managed streams.
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

    # Scenario: authenticated HLS first repairs MPEG-TS-in-MP4, then performs
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

    # Scenario: remuxing and audio extraction remain indeterminate finalization phases.
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
    wait_for_distinct_numeric_values "${CAPTURE_FILE}" 2 \
        'unknown-size progress remains animated'
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
}

test_monitor_failure_and_input_hardening() {
    local hostile_id hostile_marker

    # Negative control: download and post-processing failures never emit completion.
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

    # Untrusted yt-dlp identifiers must never become Bash syntax or array
    # subscripts. Invalid identifiers fall back to an internal opaque item key.
    start_scenario hostile-format-identifier audio
    hostile_marker="${TEST_ROOT}/hostile-format-id-executed"
    # shellcheck disable=SC2016
    # This command substitution is deliberately kept literal as an attack payload.
    hostile_id='$(touch$IFS'"${hostile_marker}"')'
    printf '%s\n' \
        "YTDLP_PLAN|media|${hostile_id}|${hostile_id}|" \
        "YTDLP_PROGRESS_V2|media|${hostile_id}|downloading|250|1000|0|0|0|25.0%|500KiB/s|00:06" \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the audio track - 25%' \
        'hostile format identifier uses an internal progress key'
    [[ ! -e ${hostile_marker} ]] \
        || fail 'A hostile format identifier was evaluated as shell syntax.'
    finish_success '/tmp/hostile-format-id.webm'

    # Negative control: extra protocol delimiters are rejected instead of shifting fields.
    start_scenario malformed-delimited-record audio
    printf '%s\n' \
        'YTDLP_PROGRESS_V2|media|bad|identifier|downloading|250|1000|0|0|0|25.0%|500KiB/s|00:06' \
        'YTDLP_PROGRESS_V2|media|251|downloading|500|1000|0|0|0|50.0%|1MiB/s|00:03' \
        >>"${LOG_FILE}"
    wait_for_text "${CAPTURE_FILE}" 'Downloading the audio track - 50%' \
        'malformed delimited progress record is ignored'
    finish_success '/tmp/malformed-delimiter.webm'

    # Negative control: a published path without a target file is not completion.
    start_scenario missing-final-file video
    printf '%s\n' "${SCENARIO_DIR}/missing-output.mkv" >"${RESULT_FILE}"
    finish_failure
}

main() {
    trap 'stop_active_processes; rm -rf -- "${TEST_ROOT}" || true' EXIT

    test_monitor_reader_lifecycle
    test_monitor_planning_progress
    test_monitor_direct_transfer_progress
    test_monitor_native_transfer_progress
    test_monitor_video_audio_weighting
    test_monitor_composite_and_postprocess_progress
    test_monitor_failure_and_input_hardening
    printf '%s\n' 'Progress-monitor integration tests passed.'
}

main "$@"
