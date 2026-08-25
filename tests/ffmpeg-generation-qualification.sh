#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/ffmpeg-generation-qualification.sh
# Purpose     : Reuse the real-tool suite against one FFmpeg/FFprobe generation.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    return 65
}

main() {
    local expected=${EXPECTED_FFMPEG_VERSION:-}
    local iteration
    local resolved_ffmpeg
    local resolved_ffprobe
    local ffmpeg_line
    local ffprobe_line
    local ytdlp_version
    local aria2_line
    local command_name

    if [[ -z ${expected} ]]; then
        fail_test 'EXPECTED_FFMPEG_VERSION must name the generation under qualification.'
    fi

    for command_name in aria2c awk bash ffmpeg ffprobe timeout yt-dlp; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            fail_test "required command is absent: ${command_name}."
        fi
    done

    resolved_ffmpeg=$(ffmpeg -hide_banner -version | awk 'NR == 1 { print $3; exit }')
    resolved_ffprobe=$(ffprobe -hide_banner -version | awk 'NR == 1 { print $3; exit }')
    [[ -n ${resolved_ffmpeg} ]] \
        || fail_test 'unable to resolve the FFmpeg version from ffmpeg -version.'
    [[ -n ${resolved_ffprobe} ]] \
        || fail_test 'unable to resolve the FFprobe version from ffprobe -version.'
    case ${resolved_ffmpeg} in
        "${expected}" | "${expected}"-* | "${expected}"+* | "${expected}"~*) ;;
        *) fail_test "resolved FFmpeg ${resolved_ffmpeg} does not match ${expected}." ;;
    esac
    case ${resolved_ffprobe} in
        "${expected}" | "${expected}"-* | "${expected}"+* | "${expected}"~*) ;;
        *) fail_test "resolved FFprobe ${resolved_ffprobe} does not match ${expected}." ;;
    esac

    ffmpeg_line=$(ffmpeg -hide_banner -version | awk 'NR == 1 { first = $0 } END { print first }')
    ffprobe_line=$(ffprobe -hide_banner -version | awk 'NR == 1 { first = $0 } END { print first }')
    ytdlp_version=$(yt-dlp --version)
    aria2_line=$(aria2c --version | awk 'NR == 1 { first = $0 } END { print first }')

    printf '=== FFmpeg generation qualification ===\n'
    printf 'Expected generation: %s\n' "${expected}"
    printf '%s\n' "${ffmpeg_line}"
    printf '%s\n' "${ffprobe_line}"
    printf 'yt-dlp: %s\n' "${ytdlp_version}"
    printf '%s\n' "${aria2_line}"

    for iteration in 1 2 3; do
        printf '\n=== real-tool routing iteration %d/3 ===\n' "${iteration}"
        timeout --signal=TERM --kill-after=10s 8m \
            bash "${PROJECT_DIR}/tests/real-tools-integration.sh"
    done

    printf '\n=== FFmpeg progress qualification ===\n'
    timeout --signal=TERM --kill-after=10s 8m \
        bash "${PROJECT_DIR}/tests/ffmpeg-real-progress-integration.sh"

    for iteration in 1 2 3; do
        printf '\n=== HLS duration iteration %d/3 ===\n' "${iteration}"
        timeout --signal=TERM --kill-after=10s 5m \
            bash "${PROJECT_DIR}/tests/hls-remux-duration-integration.sh"
    done

    printf '\n=== Generation-sensitive compatibility fixtures ===\n'
    EXPECTED_FFMPEG_VERSION=${expected} \
        timeout --signal=TERM --kill-after=10s 8m \
        bash "${PROJECT_DIR}/tests/ffmpeg-generation-compatibility.sh"

    printf '\nFFmpeg generation %s qualification passed.\n' "${expected}"
}

main "$@"
