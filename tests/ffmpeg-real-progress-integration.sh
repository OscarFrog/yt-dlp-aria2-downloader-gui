#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/ffmpeg-real-progress-integration.sh
# Purpose     : Validate real FFmpeg progress parsing and global progress bounds.
# ==============================================================================

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
WAIT_SECONDS=${FFMPEG_REAL_PROGRESS_WAIT_SECONDS:-20}
[[ ${WAIT_SECONDS} =~ ^[0-9]{1,3}$ ]] || {
    printf 'Error: FFMPEG_REAL_PROGRESS_WAIT_SECONDS must be an integer between 1 and 120.\n' >&2
    exit 64
}
WAIT_SECONDS=$((10#${WAIT_SECONDS}))
((WAIT_SECONDS >= 1 && WAIT_SECONDS <= 120)) || {
    printf 'Error: FFMPEG_REAL_PROGRESS_WAIT_SECONDS must be between 1 and 120.\n' >&2
    exit 64
}
readonly WAIT_SECONDS

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

create_real_ffmpeg_fixture() {
    local input=$1

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=10' \
        -f lavfi -i 'sine=frequency=1000:sample_rate=44100' \
        -t 0.75 -shortest -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a aac "${input}"
}

probe_duration_us() {
    local input=$1
    local duration_us

    duration_us=$(
        ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "${input}" \
            | awk '{printf "%.0f\n", $1 * 1000000}'
    )
    [[ ${duration_us} =~ ^[1-9][0-9]*$ ]] || {
        printf 'FAIL: unable to determine real FFmpeg input duration.\n' >&2
        exit 65
    }
    printf '%s\n' "${duration_us}"
}

run_real_ffmpeg_worker() {
    local run=$1
    local input=$2
    local output=$3
    local log_file=$4
    local error_file=$5
    local ready_file=$6
    local allow_file=$7
    local result_file=$8
    local duration_us=$9
    local publish_deadline

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
        -show_entries stream=index -of csv=p=0 "${output}" \
        | grep -Eq '^[0-9]+$' || {
        printf 'FAIL: real FFmpeg output has no video stream on run %d.\n' \
            "${run}" >&2
        exit 65
    }
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=index -of csv=p=0 "${output}" \
        | grep -Eq '^[0-9]+$' || {
        printf 'FAIL: real FFmpeg output has no audio stream on run %d.\n' \
            "${run}" >&2
        exit 65
    }

    : >"${ready_file}"
    publish_deadline=$((SECONDS + WAIT_SECONDS))
    while [[ ! -e ${allow_file} ]] && ((SECONDS < publish_deadline)); do
        sleep 0.05
    done
    [[ -e ${allow_file} ]] || {
        printf 'FAIL: publication handshake timed out on run %d.\n' \
            "${run}" >&2
        exit 65
    }
    printf '%s\n' "${output}" >"${result_file}"
}

wait_for_worker_barrier() {
    local run=$1
    local log_file=$2
    local ready_file=$3
    local error_file=$4
    local log_deadline=$((SECONDS + WAIT_SECONDS))

    while ((SECONDS < log_deadline)); do
        if grep -Fq -- 'progress=end' "${log_file}" && [[ -e ${ready_file} ]]; then
            break
        fi
        sleep 0.05
    done
    grep -Fq -- 'progress=end' "${log_file}" || {
        printf 'FAIL: FFmpeg never emitted progress=end on run %d within %ds.\n' \
            "${run}" "${WAIT_SECONDS}" >&2
        tail -n 40 -- "${log_file}" >&2 || true
        exit 65
    }
    [[ -e ${ready_file} ]] || {
        printf 'FAIL: FFmpeg worker never reached publication barrier on run %d.\n' \
            "${run}" >&2
        tail -n 40 -- "${error_file}" >&2 || true
        exit 65
    }
    grep -Eq '^out_time_us=[0-9]+$' "${log_file}" || {
        printf 'FAIL: FFmpeg out_time_us was not captured on run %d.\n' "${run}" >&2
        exit 65
    }
}

wait_for_prepublication_progress() {
    local run=$1
    local capture_file=$2
    local result_file=$3
    local capture_deadline=$((SECONDS + WAIT_SECONDS))

    while ((SECONDS < capture_deadline)); do
        if awk '/^[0-9]+$/ && $1 >= 95 && $1 <= 98 {found=1} END {exit !found}' \
            "${capture_file}"; then
            break
        fi
        sleep 0.05
    done
    awk '/^[0-9]+$/ && $1 >= 95 && $1 <= 98 {found=1} END {exit !found}' \
        "${capture_file}" || {
        printf 'FAIL: monitor did not render FFmpeg progress before publication on run %d.\n' \
            "${run}" >&2
        tail -n 40 -- "${capture_file}" >&2 || true
        exit 65
    }
    [[ ! -e ${result_file} ]] || {
        printf 'FAIL: worker published result before handshake release on run %d.\n' \
            "${run}" >&2
        exit 65
    }
    if grep -Fxq -- '100' "${capture_file}"; then
        printf 'FAIL: global 100 appeared before result-file publication on run %d.\n' \
            "${run}" >&2
        exit 65
    fi
}

assert_real_progress_history() {
    local run=$1
    local capture_file=$2
    local previous=-1
    local value

    grep -Fxq -- '100' "${capture_file}" || {
        printf 'FAIL: final 100 is absent on run %d.\n' "${run}" >&2
        exit 65
    }
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
}

test_real_ffmpeg_progress_run() {
    local run=$1
    local input=$2
    local duration_us=$3
    local run_dir="${TEST_ROOT}/run-${run}"
    local output="${run_dir}/output.mkv"
    local log_file="${run_dir}/download.log"
    local result_file="${run_dir}/result.txt"
    local capture_file="${run_dir}/progress.txt"
    local error_file="${run_dir}/ffmpeg.err"
    local ready_file="${run_dir}/ready-to-publish"
    local allow_file="${run_dir}/allow-publish"

    mkdir -p -- "${run_dir}"
    : >"${log_file}"
    : >"${capture_file}"

    run_real_ffmpeg_worker \
        "${run}" "${input}" "${output}" "${log_file}" "${error_file}" \
        "${ready_file}" "${allow_file}" "${result_file}" "${duration_us}" &
    WORKER_PID=$!

    bash "${MONITOR}" \
        "${log_file}" "${WORKER_PID}" "${result_file}" video \
        "${run_dir}" >"${capture_file}" &
    MONITOR_PID=$!

    wait_for_worker_barrier "${run}" "${log_file}" "${ready_file}" "${error_file}"
    wait_for_prepublication_progress "${run}" "${capture_file}" "${result_file}"

    : >"${allow_file}"
    wait "${WORKER_PID}"
    WORKER_PID=''
    wait "${MONITOR_PID}"
    MONITOR_PID=''
    assert_real_progress_history "${run}" "${capture_file}"
}

main() {
    local input="${TEST_ROOT}/input.mp4"
    local duration_us
    local run

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # The three stability runs consume the same immutable input. Building and
    # probing that fixture once preserves three independent FFmpeg/monitor
    # executions without repeating unrelated setup work.
    create_real_ffmpeg_fixture "${input}"
    duration_us=$(probe_duration_us "${input}")
    for run in 1 2 3; do
        test_real_ffmpeg_progress_run "${run}" "${input}" "${duration_us}"
    done

    printf 'Real FFmpeg progress integration passed (3/3).\n'
}

main "$@"
