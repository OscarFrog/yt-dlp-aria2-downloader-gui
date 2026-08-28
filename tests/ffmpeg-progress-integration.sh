#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/ffmpeg-progress-integration.sh
# Purpose     : Validate wrapper-managed FFmpeg progress integration.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
readonly MONITOR="${PROJECT_DIR}/progress-monitor.sh"
TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
WORKER_PID=''
MONITOR_PID=''
MONITOR_STATUS=0

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${MONITOR_PID} ]]; then
        kill -TERM -- "${MONITOR_PID}" 2>/dev/null || true
        wait "${MONITOR_PID}" 2>/dev/null || true
    fi
    if [[ -n ${WORKER_PID} ]]; then
        kill -TERM -- "${WORKER_PID}" 2>/dev/null || true
        wait "${WORKER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
}

require_test_commands() {
    local command_name
    for command_name in awk bash grep mktemp sleep tail; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' "${command_name}" >&2
            exit 127
        }
    done
}

parse_wait_seconds() {
    local wait_seconds=${FFMPEG_PROGRESS_WAIT_SECONDS:-10}
    [[ ${wait_seconds} =~ ^[0-9]{1,3}$ ]] || {
        printf 'Error: FFMPEG_PROGRESS_WAIT_SECONDS must be an integer between 1 and 120.\n' >&2
        exit 64
    }
    wait_seconds=$((10#${wait_seconds}))
    ((wait_seconds >= 1 && wait_seconds <= 120)) || {
        printf 'Error: FFMPEG_PROGRESS_WAIT_SECONDS must be between 1 and 120.\n' >&2
        exit 64
    }
    printf '%d\n' "${wait_seconds}"
}

finish_monitor_scenario() {
    local final_file=$1
    local result_file=$2

    : >"${final_file}"
    printf '%s\n' "${final_file}" >"${result_file}"
    kill -TERM -- "${WORKER_PID}" 2>/dev/null || true
    wait "${WORKER_PID}" 2>/dev/null || true
    WORKER_PID=''
    MONITOR_STATUS=0
    wait "${MONITOR_PID}" || MONITOR_STATUS=$?
    MONITOR_PID=''
}

assert_monotonic_progress() {
    local capture_file=$1
    local previous=-1
    local value

    while IFS= read -r value || [[ -n ${value} ]]; do
        [[ ${value} =~ ^[0-9]+$ ]] || continue
        ((value >= previous)) || {
            printf 'FAIL: measured progress decreased from %d to %d.\n' \
                "${previous}" "${value}" >&2
            exit 1
        }
        previous=${value}
    done <"${capture_file}"
}

test_measured_ffmpeg_progress() {
    local log_file="${TEST_ROOT}/download.log"
    local result_file="${TEST_ROOT}/result.txt"
    local capture_file="${TEST_ROOT}/progress.txt"
    local final_file="${TEST_ROOT}/measured.mkv"
    local wait_seconds
    local progress_deadline
    local monitor_status=0

    wait_seconds=$(parse_wait_seconds)
    : >"${log_file}"
    : >"${capture_file}"

    sleep 300 &
    WORKER_PID=$!
    bash "${MONITOR}" \
        "${log_file}" "${WORKER_PID}" "${result_file}" video \
        "${TEST_ROOT}" >"${capture_file}" &
    MONITOR_PID=$!

    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|finished|1000|1000|0|0|0|100.0%|2MiB/s|00:00' \
        'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' \
        'FFMPEG_PROGRESS_DURATION|10000000' \
        'out_time_us=5000000' \
        >>"${log_file}"

    progress_deadline=$((SECONDS + wait_seconds))
    while ((SECONDS < progress_deadline)); do
        if grep -Fq -- 'Remuxing the media into an MKV container' "${capture_file}" \
            && awk '/^[0-9]+$/ && $1 >= 95 && $1 <= 98 {found=1} END {exit !found}' \
                "${capture_file}"; then
            break
        fi
        sleep 0.05
    done
    grep -Fq -- 'Remuxing the media into an MKV container' "${capture_file}" || {
        printf 'FAIL: FFmpeg remux phase message was not rendered.\n' >&2
        tail -n 40 -- "${capture_file}" >&2 || true
        exit 1
    }
    awk '/^[0-9]+$/ && $1 >= 95 && $1 <= 98 {found=1} END {exit !found}' \
        "${capture_file}" || {
        printf 'FAIL: measured FFmpeg progress was not rendered.\n' >&2
        tail -n 40 -- "${capture_file}" >&2 || true
        exit 1
    }

    finish_monitor_scenario "${final_file}" "${result_file}"
    monitor_status=${MONITOR_STATUS}
    if ((monitor_status != 0)); then
        printf 'FAIL: progress monitor exited with status %d in measured scenario.\n' \
            "${monitor_status}" >&2
        exit 1
    fi

    grep -Fqx -- '100' "${capture_file}" || {
        printf 'FAIL: measured FFmpeg scenario did not reach final 100 percent.\n' >&2
        exit 1
    }
    assert_monotonic_progress "${capture_file}"
}

test_oversized_ffmpeg_counters() {
    local overflow_dir="${TEST_ROOT}/overflow"
    local overflow_log="${overflow_dir}/download.log"
    local overflow_result="${overflow_dir}/result.txt"
    local overflow_capture="${overflow_dir}/progress.txt"
    local overflow_error="${overflow_dir}/monitor.err"
    local overflow_final="${overflow_dir}/overflow.mkv"
    local monitor_status=0

    # Oversized numeric fields must be treated as unknown instead of overflowing
    # Bash arithmetic or terminating the monitor.
    mkdir -p -- "${overflow_dir}"
    : >"${overflow_log}"
    : >"${overflow_capture}"
    sleep 300 &
    WORKER_PID=$!
    bash "${MONITOR}" \
        "${overflow_log}" "${WORKER_PID}" "${overflow_result}" video \
        "${overflow_dir}" >"${overflow_capture}" 2>"${overflow_error}" &
    MONITOR_PID=$!
    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|downloading|999999999999999999999999999999999999|999999999999999999999999999999999999|0|0|0|999999999999999999999999.0%|Unknown|Unknown' \
        >>"${overflow_log}"
    sleep 0.5
    finish_monitor_scenario "${overflow_final}" "${overflow_result}"
    monitor_status=${MONITOR_STATUS}
    if ((monitor_status != 0)); then
        printf 'FAIL: progress monitor exited with status %d in oversized-counter scenario.\n' \
            "${monitor_status}" >&2
        cat -- "${overflow_error}" >&2 || true
        exit 1
    fi
    grep -Fqx -- '100' "${overflow_capture}" || {
        printf 'FAIL: oversized-counter scenario did not complete.\n' >&2
        exit 1
    }
    [[ ! -s ${overflow_error} ]] || {
        printf 'FAIL: oversized counters produced a monitor diagnostic.\n' >&2
        cat -- "${overflow_error}" >&2
        exit 1
    }
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    require_test_commands
    test_measured_ffmpeg_progress
    test_oversized_ffmpeg_counters
    printf 'Measured FFmpeg progress integration passed.\n'
}

main "$@"
