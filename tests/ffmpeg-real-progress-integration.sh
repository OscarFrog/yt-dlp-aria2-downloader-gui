#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise progress-monitor.sh with real FFmpeg -progress pipe:1 output.

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
readonly MONITOR="${PROJECT_DIR}/progress-monitor.sh"

for command_name in awk ffmpeg ffprobe grep mktemp sleep tail; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 77
    }
done

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
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for run in 1 2 3; do
    run_dir="${TEST_ROOT}/run-${run}"
    mkdir -p -- "${run_dir}"
    input="${run_dir}/input.mp4"
    output="${run_dir}/output.mkv"
    log_file="${run_dir}/download.log"
    result_file="${run_dir}/result.txt"
    capture_file="${run_dir}/progress.txt"
    error_file="${run_dir}/ffmpeg.err"
    : >"${log_file}"
    : >"${capture_file}"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=10' \
        -f lavfi -i 'sine=frequency=1000:sample_rate=44100' \
        -t 2 -shortest -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a aac "${input}"

    duration_us=$(
        ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "${input}" |
            awk '{printf "%.0f\n", $1 * 1000000}'
    )
    [[ ${duration_us} =~ ^[1-9][0-9]*$ ]] || {
        printf 'FAIL: unable to determine real FFmpeg input duration.\n' >&2
        exit 65
    }

    (
        printf '%s\n' \
            'YTDLP_PLAN|media|22|22|' \
            'YTDLP_PROGRESS_V2|media|22|finished|1000|1000|0|0|0|100.0%|2MiB/s|00:00' \
            'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer' \
            "FFMPEG_PROGRESS_DURATION|${duration_us}" >>"${log_file}"

        ffmpeg -hide_banner -loglevel warning -nostdin -nostats \
            -stats_period 0.25 -progress pipe:1 -re -i "${input}" \
            -map 0 -dn -ignore_unknown -c copy -y "${output}" \
            >>"${log_file}" 2>>"${error_file}"

        ffprobe -v error -select_streams v:0 \
            -show_entries stream=index -of csv=p=0 "${output}" |
            grep -Eq '^[0-9]+$'
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=index -of csv=p=0 "${output}" |
            grep -Eq '^[0-9]+$'

        # Leave a deliberate window proving global 100 is gated by result-file
        # publication rather than FFmpeg's own progress=end record.
        sleep 0.4
        printf '%s\n' "${output}" >"${result_file}"
    ) &
    WORKER_PID=$!

    bash "${MONITOR}" \
        "${log_file}" "${WORKER_PID}" "${result_file}" video \
        "${run_dir}" >"${capture_file}" &
    MONITOR_PID=$!

    for _ in {1..200}; do
        if grep -Fq -- 'progress=end' "${log_file}"; then
            break
        fi
        sleep 0.05
    done
    grep -Fq -- 'progress=end' "${log_file}" || {
        printf 'FAIL: FFmpeg never emitted progress=end on run %d.\n' "${run}" >&2
        tail -n 40 -- "${log_file}" >&2 || true
        exit 65
    }
    grep -Eq '^out_time_us=[0-9]+$' "${log_file}" || {
        printf 'FAIL: FFmpeg out_time_us was not captured on run %d.\n' "${run}" >&2
        exit 65
    }
    if [[ ! -e ${result_file} ]] && grep -Fxq -- '100' "${capture_file}"; then
        printf 'FAIL: global 100 appeared before result-file publication on run %d.\n' \
            "${run}" >&2
        exit 65
    fi

    wait "${WORKER_PID}"
    WORKER_PID=''
    wait "${MONITOR_PID}"
    MONITOR_PID=''

    grep -Fxq -- '100' "${capture_file}" || {
        printf 'FAIL: final 100 is absent on run %d.\n' "${run}" >&2
        exit 65
    }

    previous=-1
    while IFS= read -r value || [[ -n ${value} ]]; do
        [[ ${value} =~ ^[0-9]+$ ]] || continue
        ((value >= 0 && value <= 100)) || {
            printf 'FAIL: progress %d is out of bounds on run %d.\n' \
                "${value}" "${run}" >&2
            exit 65
        }
        ((value >= previous)) || {
            printf 'FAIL: progress decreased from %d to %d on run %d.\n' \
                "${previous}" "${value}" "${run}" >&2
            exit 65
        }
        previous=${value}
    done <"${capture_file}"
done

printf 'Real FFmpeg progress integration passed (3/3).\n'
