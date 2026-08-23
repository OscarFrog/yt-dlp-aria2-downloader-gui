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

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for command_name in awk bash grep mktemp sleep sort tail; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required command is absent: %s\n' "${command_name}" >&2
            exit 127
        }
    done

    readonly LOG_FILE="${TEST_ROOT}/download.log"
    readonly RESULT_FILE="${TEST_ROOT}/result.txt"
    readonly CAPTURE_FILE="${TEST_ROOT}/progress.txt"
    readonly FINAL_FILE="${TEST_ROOT}/measured.mkv"
    : >"${LOG_FILE}"
    : >"${CAPTURE_FILE}"

    sleep 300 &
    WORKER_PID=$!
    bash "${MONITOR}" \
        "${LOG_FILE}" "${WORKER_PID}" "${RESULT_FILE}" video \
        "${TEST_ROOT}" >"${CAPTURE_FILE}" &
    MONITOR_PID=$!

    printf '%s\n' \
        'YTDLP_PLAN|media|22|22|' \
        'YTDLP_PROGRESS_V2|media|22|finished|1000|1000|0|0|0|100.0%|2MiB/s|00:00' \
        'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' \
        'FFMPEG_PROGRESS_DURATION|10000000' \
        'out_time_us=5000000' \
        >>"${LOG_FILE}"

    for _ in {1..100}; do
        if grep -Fq -- 'Remuxing the media into an MKV container' "${CAPTURE_FILE}" \
            && awk '/^[0-9]+$/ && $1 >= 95 && $1 <= 98 {found=1} END {exit !found}' \
                "${CAPTURE_FILE}"; then
            break
        fi
        sleep 0.05
    done
    awk '/^[0-9]+$/ && $1 >= 95 && $1 <= 98 {found=1} END {exit !found}' \
        "${CAPTURE_FILE}" || {
        printf 'FAIL: measured FFmpeg progress was not rendered.\n' >&2
        tail -n 40 -- "${CAPTURE_FILE}" >&2 || true
        exit 1
    }

    : >"${FINAL_FILE}"
    printf '%s\n' "${FINAL_FILE}" >"${RESULT_FILE}"
    kill -TERM -- "${WORKER_PID}" 2>/dev/null || true
    wait "${WORKER_PID}" 2>/dev/null || true
    WORKER_PID=''
    wait "${MONITOR_PID}"
    MONITOR_PID=''

    grep -Fqx -- '100' "${CAPTURE_FILE}" || {
        printf 'FAIL: measured FFmpeg scenario did not reach final 100 percent.\n' >&2
        exit 1
    }

    previous=-1
    while IFS= read -r value || [[ -n ${value} ]]; do
        [[ ${value} =~ ^[0-9]+$ ]] || continue
        ((value >= previous)) || {
            printf 'FAIL: measured progress decreased from %d to %d.\n' \
                "${previous}" "${value}" >&2
            exit 1
        }
        previous=${value}
    done <"${CAPTURE_FILE}"

    # Oversized numeric fields must be treated as unknown instead of overflowing
    # Bash arithmetic or terminating the monitor.
    overflow_dir="${TEST_ROOT}/overflow"
    mkdir -p -- "${overflow_dir}"
    overflow_log="${overflow_dir}/download.log"
    overflow_result="${overflow_dir}/result.txt"
    overflow_capture="${overflow_dir}/progress.txt"
    overflow_error="${overflow_dir}/monitor.err"
    overflow_final="${overflow_dir}/overflow.mkv"
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
    : >"${overflow_final}"
    printf '%s\n' "${overflow_final}" >"${overflow_result}"
    kill -TERM -- "${WORKER_PID}" 2>/dev/null || true
    wait "${WORKER_PID}" 2>/dev/null || true
    WORKER_PID=''
    wait "${MONITOR_PID}"
    MONITOR_PID=''
    grep -Fqx -- '100' "${overflow_capture}" || {
        printf 'FAIL: oversized-counter scenario did not complete.\n' >&2
        exit 1
    }
    [[ ! -s ${overflow_error} ]] || {
        printf 'FAIL: oversized counters produced a monitor diagnostic.\n' >&2
        cat -- "${overflow_error}" >&2
        exit 1
    }

    printf 'Measured FFmpeg progress integration passed.\n'

}

main "$@"
