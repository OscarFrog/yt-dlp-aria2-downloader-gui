#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/ffmpeg-generation-compatibility.sh
# Purpose     : Qualify FFmpeg/FFprobe generation-sensitive media invariants.
# ==============================================================================

set -Eeuo pipefail
umask 077

TEST_ROOT=''
FFMPEG_PID=''
FFMPEG_PGID=''

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    return 65
}

cleanup() {
    trap - EXIT HUP INT TERM

    if [[ -n ${FFMPEG_PGID} ]]; then
        kill -KILL -- "-${FFMPEG_PGID}" 2>/dev/null || true
    elif [[ -n ${FFMPEG_PID} ]]; then
        kill -KILL -- "${FFMPEG_PID}" 2>/dev/null || true
    fi
    if [[ -n ${FFMPEG_PID} ]]; then
        wait "${FFMPEG_PID}" 2>/dev/null || true
    fi
    if [[ -n ${TEST_ROOT} ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
}

command_version() {
    set -e
    local command_name=$1
    "${command_name}" -hide_banner -version | awk 'NR == 1 { print $3; exit }'
}

assert_expected_versions() {
    local expected=${EXPECTED_FFMPEG_VERSION:-}
    local ffmpeg_version
    local ffprobe_version

    ffmpeg_version=$(command_version ffmpeg)
    ffprobe_version=$(command_version ffprobe)

    if [[ -z ${ffmpeg_version} || -z ${ffprobe_version} ]]; then
        fail_test 'unable to resolve FFmpeg/FFprobe versions.'
    fi

    if [[ -n ${expected} ]]; then
        case ${ffmpeg_version} in
            "${expected}" | "${expected}"-* | "${expected}"+* | "${expected}"~*) ;;
            *) fail_test "FFmpeg ${ffmpeg_version} does not match expected ${expected}." ;;
        esac
        case ${ffprobe_version} in
            "${expected}" | "${expected}"-* | "${expected}"+* | "${expected}"~*) ;;
            *) fail_test "FFprobe ${ffprobe_version} does not match expected ${expected}." ;;
        esac
    fi

    printf 'FFmpeg version: %s\n' "${ffmpeg_version}"
    printf 'FFprobe version: %s\n' "${ffprobe_version}"
}

stream_count() {
    set -e
    local media_path=$1
    local stream_selector=$2

    ffprobe -v error \
        -select_streams "${stream_selector}" \
        -show_entries stream=index \
        -of csv=p=0 \
        "${media_path}" \
        | awk 'NF { count++ } END { print count + 0 }'
}

frame_count() {
    set -e
    local media_path=$1

    ffprobe -v error \
        -count_frames \
        -select_streams v:0 \
        -show_entries stream=nb_read_frames \
        -of default=noprint_wrappers=1:nokey=1 \
        "${media_path}"
}

media_duration() {
    set -e
    local media_path=$1

    ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "${media_path}"
}

assert_duration_close() {
    local source_duration=$1
    local final_duration=$2
    local tolerance=$3

    if ! awk -v source="${source_duration}" -v final="${final_duration}" -v tolerance="${tolerance}" '
        BEGIN {
            delta = source - final
            if (delta < 0) {
                delta = -delta
            }
            exit(delta <= tolerance ? 0 : 1)
        }
    '; then
        fail_test \
            "remux duration delta exceeds ${tolerance}s: source=${source_duration}, final=${final_duration}."
    fi
}

qualify_multistream_remux() {
    local source="${TEST_ROOT}/multi-stream.mp4"
    local final="${TEST_ROOT}/multi-stream.mkv"
    local video_count
    local audio_count

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=25' \
        -f lavfi -i 'sine=frequency=700:sample_rate=48000' \
        -f lavfi -i 'sine=frequency=1200:sample_rate=48000' \
        -t 2 \
        -map 0:v:0 -map 1:a:0 -map 2:a:0 \
        -c:v mpeg4 -q:v 5 -c:a aac \
        "${source}"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -i "${source}" \
        -map 0 -dn -ignore_unknown -c copy \
        "${final}"

    video_count=$(stream_count "${final}" v)
    audio_count=$(stream_count "${final}" a)

    if [[ ${video_count} != 1 ]]; then
        fail_test "multi-stream remux retained ${video_count} video streams instead of 1."
    fi
    if [[ ${audio_count} != 2 ]]; then
        fail_test "multi-stream remux retained ${audio_count} audio streams instead of 2."
    fi
}

qualify_vfr_remux() {
    local source="${TEST_ROOT}/vfr-source.mkv"
    local final="${TEST_ROOT}/vfr-final.mkv"
    local source_frames
    local final_frames
    local source_duration
    local final_duration

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=30:duration=3' \
        -vf "select='not(mod(n,2))+not(mod(n,5))'" \
        -fps_mode vfr \
        -c:v mpeg4 -q:v 5 -an \
        "${source}"

    source_frames=$(frame_count "${source}")
    if [[ ! ${source_frames} =~ ^[1-9][0-9]*$ ]]; then
        fail_test 'unable to count VFR source frames.'
    fi
    if ((source_frames >= 90)); then
        fail_test 'VFR fixture did not drop frames as intended.'
    fi

    ffmpeg -hide_banner -loglevel error -nostdin \
        -i "${source}" \
        -map 0 -dn -ignore_unknown -c copy \
        "${final}"

    final_frames=$(frame_count "${final}")
    if [[ ${final_frames} != "${source_frames}" ]]; then
        fail_test "VFR remux changed frame count from ${source_frames} to ${final_frames}."
    fi

    source_duration=$(media_duration "${source}")
    final_duration=$(media_duration "${final}")
    if [[ ! ${source_duration} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        fail_test 'unable to determine VFR source duration.'
    fi
    if [[ ! ${final_duration} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        fail_test 'unable to determine VFR final duration.'
    fi
    assert_duration_close "${source_duration}" "${final_duration}" 0.25
}

qualify_ffmpeg_cancellation() {
    local source="${TEST_ROOT}/cancel-source.mkv"
    local output="${TEST_ROOT}/cancel-output.mkv"
    local pgid=''
    local wait_status=0

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=10' \
        -f lavfi -i 'sine=frequency=1000:sample_rate=44100' \
        -t 2 -shortest \
        -c:v mpeg4 -q:v 5 -c:a aac \
        "${source}"

    setsid ffmpeg -hide_banner -loglevel error -nostdin \
        -re -stream_loop -1 -i "${source}" \
        -map 0 -c copy -f matroska "${output}" \
        >/dev/null 2>&1 &
    FFMPEG_PID=$!

    for _ in {1..50}; do
        pgid=$(ps -o pgid= -p "${FFMPEG_PID}" 2>/dev/null | tr -d '[:space:]')
        if [[ ${pgid} =~ ^[1-9][0-9]*$ ]] \
            && kill -0 -- "-${pgid}" 2>/dev/null; then
            FFMPEG_PGID=${pgid}
            break
        fi
        sleep 0.1
    done

    if [[ -z ${FFMPEG_PGID} ]]; then
        fail_test 'FFmpeg cancellation fixture did not expose a process group.'
    fi

    kill -TERM -- "-${FFMPEG_PGID}"

    for _ in {1..50}; do
        if ! kill -0 -- "-${FFMPEG_PGID}" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    if kill -0 -- "-${FFMPEG_PGID}" 2>/dev/null; then
        fail_test 'FFmpeg process group survived SIGTERM.'
    fi

    set +e
    wait "${FFMPEG_PID}"
    wait_status=$?
    set -e
    FFMPEG_PID=''
    FFMPEG_PGID=''

    if ((wait_status == 0)); then
        fail_test 'cancelled FFmpeg unexpectedly reported success.'
    fi
}

main() {
    local command_name

    for command_name in awk ffmpeg ffprobe mktemp ps setsid sleep tr; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            fail_test "required command is absent: ${command_name}."
        fi
    done

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    TEST_ROOT=$(mktemp -d)
    readonly TEST_ROOT

    assert_expected_versions
    qualify_multistream_remux
    qualify_vfr_remux
    qualify_ffmpeg_cancellation

    printf 'FFmpeg generation compatibility qualification passed.\n'
}

main "$@"
