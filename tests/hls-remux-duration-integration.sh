#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/hls-remux-duration-integration.sh
# Purpose     : Validate HLS remux duration consistency and failure handling.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR

for command_name in cp ffmpeg ffprobe find grep mktemp realpath setsid stat timeout truncate; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 77
    }
done

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
MOCK_BIN="${TEST_ROOT}/bin"
RUNTIME_DIR="${TEST_ROOT}/runtime"
mkdir -p -- "${MOCK_BIN}" "${RUNTIME_DIR}" "${TEST_ROOT}/source"
chmod 700 -- "${RUNTIME_DIR}"

cleanup() {
    trap - EXIT HUP INT TERM
    rm -rf -- "${TEST_ROOT}" || true
}

run_case() {
    local label=$1
    local media_source=$2
    local expected_status=$3
    local expected_failure_mkv=${4:-false}
    local output_dir="${TEST_ROOT}/output-${label}"
    local result_file="${TEST_ROOT}/${label}.result"
    mkdir -p -- "${output_dir}"
    rm -f -- "${result_file}"
    export MOCK_OUTPUT_DIR="${output_dir}"
    export MOCK_MEDIA_SOURCE="${media_source}"

    set +e
    bash "${PROJECT_DIR}/download-video.sh" \
        --mode video \
        --youtube-hls-firefox \
        --output-dir "${output_dir}" \
        --result-file "${result_file}" \
        'https://www.youtube.com/watch?v=abc123'
    status=$?
    set -e

    if ((status != expected_status)); then
        printf 'FAIL: %s returned %d instead of %d.\n' \
            "${label}" "${status}" "${expected_status}" >&2
        exit 65
    fi

    if ((expected_status == 0)); then
        [[ -s ${result_file} ]] || {
            printf 'FAIL: valid HLS remux did not publish a result.\n' >&2
            exit 65
        }
        final_file=$(<"${result_file}")
        [[ -f ${final_file} ]] || {
            printf 'FAIL: valid HLS final MKV is absent.\n' >&2
            exit 65
        }
        ffprobe -v error -select_streams v:0 \
            -show_entries stream=index -of csv=p=0 "${final_file}" \
            | grep -Eq '^[0-9]+$'
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=index -of csv=p=0 "${final_file}" \
            | grep -Eq '^[0-9]+$'
        if find "${output_dir}" -maxdepth 1 -type f -name '*.mp4' -print -quit \
            | grep -q .; then
            printf 'FAIL: successful HLS remux retained its repaired intermediate.\n' >&2
            exit 65
        fi
    else
        [[ ! -e ${result_file} ]] || {
            printf 'FAIL: invalid HLS media published a success result.\n' >&2
            exit 65
        }
        if [[ ${expected_failure_mkv} == true ]]; then
            find "${output_dir}" -maxdepth 1 -type f -name '*.mkv' -print -quit \
                | grep -q . || {
                printf 'FAIL: late HLS validation failure did not retain its diagnostic MKV.\n' >&2
                exit 65
            }
        elif find "${output_dir}" -maxdepth 1 -type f -name '*.mkv' -print -quit \
            | grep -q .; then
            printf 'FAIL: duration-rejected HLS media published a final MKV.\n' >&2
            exit 65
        fi
        find "${output_dir}" -maxdepth 1 -type f -name '*.mp4' -print -quit \
            | grep -q . || {
            printf 'FAIL: repaired HLS intermediate was not retained for diagnosis.\n' >&2
            exit 65
        }
    fi
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=25' \
        -f lavfi -i 'sine=frequency=1000:sample_rate=48000' \
        -t 8 -shortest -c:v mpeg4 -q:v 5 -c:a aac -movflags +faststart \
        "${TEST_ROOT}/source/full.mp4"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=25' \
        -f lavfi -i 'sine=frequency=1200:sample_rate=48000' \
        -t 1.2 -shortest -c:v mpeg4 -q:v 5 -c:a aac -movflags +faststart \
        "${TEST_ROOT}/source/short.mp4"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=25' \
        -f lavfi -i 'sine=frequency=1400:sample_rate=48000' \
        -t 2 -shortest -c:v mpeg4 -q:v 5 -c:a aac -movflags +faststart \
        -output_ts_offset 5 \
        "${TEST_ROOT}/source/nonzero-ts.mp4"

    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=160x90:rate=25' \
        -t 8 -c:v mpeg4 -q:v 5 -an \
        "${TEST_ROOT}/source/video-only.mp4"

    cp -- "${TEST_ROOT}/source/full.mp4" "${TEST_ROOT}/source/truncated.mp4"
    source_size=$(stat -c '%s' -- "${TEST_ROOT}/source/truncated.mp4")
    truncate -s "$((source_size * 60 / 100))" \
        "${TEST_ROOT}/source/truncated.mp4"

    source_duration=$(
        ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "${TEST_ROOT}/source/truncated.mp4"
    )
    [[ ${source_duration} == 8.* ]] || {
        printf 'FAIL: truncated fixture no longer reproduces FFprobe duration retention.\n' >&2
        exit 65
    }

    cat >"${MOCK_BIN}/yt-dlp" <<'EOF_YTDLP'
#!/usr/bin/env bash
set -Eeuo pipefail
if (($# == 1)) && [[ $1 == '--version' ]]; then
    printf '2026.8.19\n'
    exit 0
fi
if (($# == 1)) && [[ $1 == '--help' ]]; then
    printf '%s\n' \
        '--js-runtimes' \
        '--cookies FILE' \
        '--cookies-from-browser BROWSER[:PROFILE]' \
        '--extractor-args KEY:ARGS' \
        '-O, --print [WHEN:]TEMPLATE' \
        '--progress-template TEMPLATE' \
        '--print-to-file TEMPLATE FILE' \
        '--parse-metadata [WHEN:]FROM:TO' \
        '--fixup POLICY' \
        '--downloader-args NAME:ARGS' \
        '--batch-file FILE' \
        '--socket-timeout SECONDS' \
        '--retries RETRIES' \
        '--fragment-retries RETRIES' \
        '--extractor-retries RETRIES' \
        '--retry-sleep EXPR' \
        '--no-overwrites' \
        '--no-post-overwrites' \
        '--break-match-filters FILTER' \
        '--no-update' \
        '--skip-download' \
        '--no-clean-info-json' \
        '--dump-single-json' \
        '--load-info-json FILE'
    exit 0
fi

dump_single_json=false
result_file=''
previous=''
for argument in "$@"; do
    if [[ ${argument} == '--dump-single-json' ]]; then
        dump_single_json=true
    fi
    if [[ ${previous} == '--print-to-file' ]]; then
        previous='print-template'
        continue
    fi
    if [[ ${previous} == 'print-template' ]]; then
        result_file=${argument//%%/%}
        previous=''
        continue
    fi
    if [[ ${argument} == '--print-to-file' ]]; then
        previous='--print-to-file'
    fi
done

if [[ ${dump_single_json} == true ]]; then
    printf \
        '{"requested_downloads":[{"filename":"%s","format_id":"mock-hls","ext":"mp4","protocol":"m3u8_native","url":"https://example.invalid/mock-manifest.m3u8","http_headers":{"User-Agent":"mock-agent"}}]}\n' \
        "${MOCK_OUTPUT_DIR:?}/Mock HLS [abc123].mp4"
    exit 0
fi

[[ -n ${result_file} ]] || {
    printf 'Mock yt-dlp did not receive --print-to-file.\n' >&2
    exit 64
}

output_path="${MOCK_OUTPUT_DIR:?}/Mock HLS [abc123].mp4"
cp -- "${MOCK_MEDIA_SOURCE:?}" "${output_path}"
printf '%s\n' "${output_path}" >"${result_file}"
printf 'YTDLP_POSTPROCESS|finished|FixupM3u8\n'
EOF_YTDLP
    chmod 700 -- "${MOCK_BIN}/yt-dlp"

    cat >"${MOCK_BIN}/deno" <<'EOF_DENO'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'deno 2.3.0 (stable, release, x86_64-unknown-linux-gnu)\n'
printf 'v8 0.0.0\n'
printf 'typescript 0.0.0\n'
EOF_DENO
    chmod 700 -- "${MOCK_BIN}/deno"

    cat >"${MOCK_BIN}/aria2c" <<'EOF_ARIA2'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
--version)
    printf 'aria2 version 1.37.0\n'
    ;;
--help=#all)
    printf '%s\n' \
        '--file-allocation=<METHOD>' \
        '--no-conf[=true|false]' \
        '--input-file=FILE' \
        '--dir=DIR' \
        '--load-cookies=FILE' \
        '--allow-overwrite[=true|false]' \
        '--auto-file-renaming[=true|false]' \
        '--enable-color[=true|false]' \
        '--truncate-console-readout[=true|false]' \
        '--summary-interval=<SEC>' \
        '--show-console-readout[=true|false]' \
        '--stderr[=true|false]' \
        '--no-netrc[=true|false]'
    ;;
*)
    printf 'Unexpected aria2c transfer in HLS remux validation test.\n' >&2
    exit 64
    ;;
esac
EOF_ARIA2
    chmod 700 -- "${MOCK_BIN}/aria2c"

    export PATH="${MOCK_BIN}:${PATH}"
    export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
    export YTDLP_ARIA2_SKIP_RUNTIME_UPDATE=1
    export YTDLP_ARIA2_YTDLP_BIN="${MOCK_BIN}/yt-dlp"
    export YTDLP_ARIA2_DENO_BIN="${MOCK_BIN}/deno"
    export YTDLP_DISABLE_REMOTE_EJS=1

    # Positive controls: normal, very short, and non-zero-timestamp inputs ensure
    # the duration guard does not reject benign remux differences.
    run_case valid "${TEST_ROOT}/source/full.mp4" 0
    run_case short "${TEST_ROOT}/source/short.mp4" 0
    run_case nonzero-ts "${TEST_ROOT}/source/nonzero-ts.mp4" 0

    # Regression guard: FFmpeg can exit 0 and retain both streams while losing
    # ~40% of duration. The engine must return EX_DATAERR (65) and publish no result.
    run_case truncated "${TEST_ROOT}/source/truncated.mp4" 65

    # Regression guard: FFmpeg stream-copy succeeds and duration remains coherent,
    # but final video validation fails because audio is absent. The repaired source
    # must survive this late failure; only a globally successful run may remove it.
    run_case video-only-validation-failure \
        "${TEST_ROOT}/source/video-only.mp4" 65 true

    printf 'HLS remux duration validation passed.\n'

}

main "$@"
