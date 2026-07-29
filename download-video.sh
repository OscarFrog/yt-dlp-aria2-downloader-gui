#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# ============================================================================
# Name        : download-video.sh
# Version     : 2.1.12
# Date        : 2026-07-29
# Description : Download one complete MKV video or the best native audio track.
# ============================================================================

set -euo pipefail

readonly VERSION="2.1.12"
readonly MIN_YT_DLP_VERSION="2026.06.09"
readonly MIN_ARIA2_VERSION="1.37.0"
readonly MIN_DENO_VERSION="2.3.0"
readonly SCRIPT_NAME="${0##*/}"

VERSION_AT_LEAST=false
VERSION_PARSE_VALID=false
RESULT_FILE_TMP=''
INTERNAL_PATH_FILE_TMP=''
HLS_REMUX_TMP=''

cleanup() {
    local status=$?

    trap - EXIT HUP INT TERM
    if [[ -n ${RESULT_FILE_TMP} ]]; then
        rm -f -- "${RESULT_FILE_TMP}" || true
    fi
    if [[ -n ${INTERNAL_PATH_FILE_TMP} ]]; then
        rm -f -- "${INTERNAL_PATH_FILE_TMP}" || true
    fi
    if [[ -n ${HLS_REMUX_TMP} ]]; then
        rm -f -- "${HLS_REMUX_TMP}" || true
    fi
    exit "${status}"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<EOF_USAGE
Usage:
  ${SCRIPT_NAME} [OPTIONS] VIDEO_URL

Options:
  -o, --output-dir DIR       Destination directory.
  -m, --mode MODE            video or audio (default: video).
                             video: complete best-quality video in MKV.
                             audio: best available audio track; preserve the
                                    source codec/container whenever possible.
      --machine-progress     Emit stable YTDLP_PLAN and progress records.
      --youtube-hls-firefox  For YouTube video mode, use Firefox cookies and
                             web_safari HLS formats before remuxing to MKV.
      --result-file FILE     Write the final media path to FILE.
  -h, --help                 Display this help.
  -V, --version              Display the version.

Examples:
  ${SCRIPT_NAME} 'https://example.com/video'
  ${SCRIPT_NAME} --output-dir "${HOME}/Videos" 'https://example.com/video'
  ${SCRIPT_NAME} --mode audio --output-dir "${HOME}/Music" 'https://example.com/video'
EOF_USAGE
}

error() {
    printf 'Error: %s\n' "$*" >&2
}

compare_versions() {
    local current=$1
    local minimum=$2
    local current_major
    local current_minor
    local current_patch
    local current_suffix=''
    local current_is_prerelease=false
    local minimum_major
    local minimum_minor
    local minimum_patch

    VERSION_AT_LEAST=false
    VERSION_PARSE_VALID=false

    # Installed versions may contain a suffix; the configured minimum below
    # must remain a strict three-component version.
    if [[ ! ${current} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        return 0
    fi
    current_major=$((10#${BASH_REMATCH[1]}))
    current_minor=$((10#${BASH_REMATCH[2]}))
    current_patch=$((10#${BASH_REMATCH[3]}))
    current_suffix=${current#"${BASH_REMATCH[0]}"}
    if [[ ${current_suffix} =~ ^-(alpha|beta|pre|preview|rc)([.0-9-]|$) ]]; then
        current_is_prerelease=true
    fi

    if [[ ! ${minimum} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        return 0
    fi
    minimum_major=$((10#${BASH_REMATCH[1]}))
    minimum_minor=$((10#${BASH_REMATCH[2]}))
    minimum_patch=$((10#${BASH_REMATCH[3]}))
    VERSION_PARSE_VALID=true

    if [[ ${current_is_prerelease} == true ]] &&
        ((current_major == minimum_major &&
            current_minor == minimum_minor &&
            current_patch == minimum_patch)); then
        return 0
    fi

    if ((current_major > minimum_major || (\
        current_major == minimum_major && current_minor > minimum_minor) || (\
        current_major == minimum_major && current_minor == minimum_minor && \
        current_patch >= minimum_patch))); then
        VERSION_AT_LEAST=true
    fi
}

check_runtime_compatibility() {
    local yt_dlp_version
    local deno_name
    local deno_version
    local deno_output
    local _
    local yt_dlp_help
    local aria2_version_line
    local aria2_version
    local aria2_help
    local required_option

    if ! yt_dlp_version=$(LC_ALL=C yt-dlp --version 2>/dev/null); then
        error 'unable to determine the yt-dlp version.'
        return 1
    fi
    yt_dlp_version=${yt_dlp_version%%$'\n'*}
    compare_versions "${yt_dlp_version}" "${MIN_YT_DLP_VERSION}"
    if [[ ${VERSION_PARSE_VALID} != true ]]; then
        error "unable to parse the yt-dlp version: ${yt_dlp_version:-unknown}."
        return 1
    fi
    if [[ ${VERSION_AT_LEAST} != true ]]; then
        error "yt-dlp ${MIN_YT_DLP_VERSION} or later is required; found ${yt_dlp_version}."
        return 1
    fi

    if ! deno_output=$(LC_ALL=C deno --version 2>/dev/null); then
        error 'unable to determine the Deno version.'
        return 1
    fi
    IFS=' ' read -r deno_name deno_version _ <<<"${deno_output%%$'\n'*}"
    if [[ ${deno_name} != deno || -z ${deno_version} ]]; then
        error "unable to parse the Deno version: ${deno_output%%$'\n'*}."
        return 1
    fi
    compare_versions "${deno_version}" "${MIN_DENO_VERSION}"
    if [[ ${VERSION_PARSE_VALID} != true ]]; then
        error "unable to parse the Deno version: ${deno_version}."
        return 1
    fi
    if [[ ${VERSION_AT_LEAST} != true ]]; then
        error "Deno ${MIN_DENO_VERSION} or later is required; found ${deno_version}."
        return 1
    fi

    if ! yt_dlp_help=$(LC_ALL=C yt-dlp --help 2>&1); then
        error 'unable to inspect yt-dlp capabilities.'
        return 1
    fi
    for required_option in \
        --js-runtimes \
        --remote-components \
        --cookies-from-browser \
        --extractor-args \
        --print \
        --progress-template \
        --print-to-file \
        --fixup \
        --downloader-args; do
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^,[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|$)" <<<"${yt_dlp_help}"; then
            error "this yt-dlp build does not support ${required_option}."
            return 1
        fi
    done

    if ! aria2_version_line=$(LC_ALL=C aria2c --version 2>/dev/null); then
        error 'unable to determine the aria2c version.'
        return 1
    fi
    aria2_version_line=${aria2_version_line%%$'\n'*}
    if [[ ! ${aria2_version_line} =~ ^aria2[[:space:]]+version[[:space:]]+([^[:space:]]+) ]]; then
        error "unable to parse the aria2c version: ${aria2_version_line:-unknown}."
        return 1
    fi
    aria2_version=${BASH_REMATCH[1]}
    compare_versions "${aria2_version}" "${MIN_ARIA2_VERSION}"
    if [[ ${VERSION_PARSE_VALID} != true ]]; then
        error "unable to parse the aria2c version: ${aria2_version}."
        return 1
    fi
    if [[ ${VERSION_AT_LEAST} != true ]]; then
        error "aria2c ${MIN_ARIA2_VERSION} or later is required; found ${aria2_version}."
        return 1
    fi

    if ! aria2_help=$(LC_ALL=C aria2c --help=#all 2>&1); then
        error 'unable to inspect aria2c capabilities.'
        return 1
    fi
    for required_option in \
        --file-allocation \
        --no-conf \
        --enable-color \
        --truncate-console-readout \
        --summary-interval \
        --show-console-readout \
        --stderr; do
        if ! grep -Eq -- "^[[:space:]]*${required_option}([=[:space:]]|\[|$)" <<<"${aria2_help}"; then
            error "this aria2c build does not support ${required_option}."
            return 1
        fi
    done
}

require_value() {
    local option_name=$1
    local option_value=${2-}

    if [[ -z ${option_value} ]]; then
        error "option ${option_name} requires a value."
        exit 2
    fi
}

normalize_path_record() {
    local record_file=$1
    local candidate=''
    local final_path=''

    [[ -f ${record_file} ]] || return 1
    while IFS= read -r candidate || [[ -n ${candidate} ]]; do
        if [[ -n ${candidate} ]]; then
            final_path=${candidate}
        fi
    done <"${record_file}"

    [[ -n ${final_path} && -f ${final_path} ]] || return 1
    printf '%s\n' "${final_path}" >"${record_file}" || return 2
    return 0
}

OUTPUT_DIR=''
MODE='video'
MACHINE_PROGRESS=false
YOUTUBE_HLS_FIREFOX=false
RESULT_FILE=''
URL=''
POSITIONAL_ARGUMENTS=()

while (($# > 0)); do
    case $1 in
    -h | --help)
        usage
        exit 0
        ;;
    -V | --version)
        printf '%s version %s\n' "${SCRIPT_NAME}" "${VERSION}"
        exit 0
        ;;
    -o | --output-dir)
        require_value "$1" "${2-}"
        OUTPUT_DIR=$2
        shift 2
        ;;
    --output-dir=*)
        OUTPUT_DIR=${1#*=}
        require_value '--output-dir' "${OUTPUT_DIR}"
        shift
        ;;
    -m | --mode)
        require_value "$1" "${2-}"
        MODE=$2
        shift 2
        ;;
    --mode=*)
        MODE=${1#*=}
        require_value '--mode' "${MODE}"
        shift
        ;;
    --machine-progress)
        MACHINE_PROGRESS=true
        shift
        ;;
    --youtube-hls-firefox)
        YOUTUBE_HLS_FIREFOX=true
        shift
        ;;
    --result-file)
        require_value "$1" "${2-}"
        RESULT_FILE=$2
        shift 2
        ;;
    --result-file=*)
        RESULT_FILE=${1#*=}
        require_value '--result-file' "${RESULT_FILE}"
        shift
        ;;
    --)
        shift
        POSITIONAL_ARGUMENTS+=("$@")
        break
        ;;
    -*)
        error "unknown option: $1"
        usage >&2
        exit 2
        ;;
    *)
        POSITIONAL_ARGUMENTS+=("$1")
        shift
        ;;
    esac
done

if ((${#POSITIONAL_ARGUMENTS[@]} == 0)); then
    error 'a video URL is required.'
    usage >&2
    exit 2
fi
if ((${#POSITIONAL_ARGUMENTS[@]} != 1)); then
    error 'exactly one video URL is required.'
    usage >&2
    exit 2
fi
URL=${POSITIONAL_ARGUMENTS[0]}

if [[ ${URL} == *$'\n'* || ${URL} == *$'\r'* ]]; then
    error 'the URL must not contain line breaks.'
    exit 2
fi

if [[ ! ${URL} =~ ^https?://[^[:space:]]+$ ]]; then
    error 'provide a URL beginning with http:// or https://.'
    exit 2
fi

case ${MODE} in
video | audio) ;;
*)
    error '--mode must be video or audio.'
    exit 2
    ;;
esac

if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
    if [[ ${MODE} != video ]]; then
        error '--youtube-hls-firefox is available only with --mode video.'
        exit 2
    fi

    youtube_authority=${URL#*://}
    youtube_authority=${youtube_authority%%/*}
    youtube_authority=${youtube_authority%%\?*}
    youtube_authority=${youtube_authority%%\#*}
    youtube_authority=${youtube_authority##*@}
    youtube_host=${youtube_authority%%:*}
    youtube_host=${youtube_host,,}
    youtube_host=${youtube_host%.}

    case ${youtube_host} in
    youtube.com | *.youtube.com | youtu.be | *.youtu.be | \
        youtube-nocookie.com | *.youtube-nocookie.com) ;;
    *)
        error '--youtube-hls-firefox requires a YouTube URL.'
        exit 2
        ;;
    esac
fi

for command_name in yt-dlp aria2c ffmpeg realpath deno grep mktemp mv rm; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        error "required command \"${command_name}\" was not found."
        exit 127
    fi
done

# Keep this as a simple command: placing it in an if/|| context would disable
# errexit inside the function body under Bash's documented rules.
check_runtime_compatibility

if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR=${PWD}
fi

if [[ ${OUTPUT_DIR} == *$'\n'* || ${OUTPUT_DIR} == *$'\r'* ]]; then
    error 'the destination path must not contain line breaks.'
    exit 2
fi

if [[ ! -d ${OUTPUT_DIR} ]]; then
    error "destination directory does not exist: ${OUTPUT_DIR}"
    exit 1
fi

if ! OUTPUT_DIR=$(realpath -e -- "${OUTPUT_DIR}"); then
    error 'unable to resolve the destination directory.'
    exit 1
fi
readonly OUTPUT_DIR

# --output is an yt-dlp output template. Escape literal percent signs from the
# real destination path so directories containing '%' are handled correctly.
OUTPUT_DIR_TEMPLATE=${OUTPUT_DIR//%/%%}
readonly OUTPUT_DIR_TEMPLATE

if [[ ! -w ${OUTPUT_DIR} || ! -x ${OUTPUT_DIR} ]]; then
    error "destination directory is not writable: ${OUTPUT_DIR}"
    exit 13
fi

if [[ -n ${RESULT_FILE} ]]; then
    if [[ ${RESULT_FILE} == *$'\n'* || ${RESULT_FILE} == *$'\r'* ]]; then
        error 'the result-file path must not contain line breaks.'
        exit 2
    fi

    result_parent=${RESULT_FILE%/*}
    if [[ ${result_parent} == "${RESULT_FILE}" ]]; then
        result_parent='.'
    elif [[ -z ${result_parent} ]]; then
        result_parent='/'
    fi

    if [[ ! -d ${result_parent} || ! -w ${result_parent} || ! -x ${result_parent} ]]; then
        error 'the result-file directory is not writable.'
        exit 13
    fi

    if ! rm -f -- "${RESULT_FILE}"; then
        error 'unable to remove the previous result file.'
        exit 13
    fi

    if ! RESULT_FILE_TMP=$(mktemp \
        --tmpdir="${result_parent}" \
        '.yt-dlp-result.XXXXXXXX'); then
        error 'unable to create the temporary result file.'
        exit 13
    fi
fi

if [[ ${YOUTUBE_HLS_FIREFOX} == true && -z ${RESULT_FILE_TMP} ]]; then
    if ! INTERNAL_PATH_FILE_TMP=$(mktemp \
        --tmpdir="${OUTPUT_DIR}" \
        '.yt-dlp-path.XXXXXXXX'); then
        error 'unable to create the internal result-path file.'
        exit 13
    fi
fi

printf '%s version %s\n' "${SCRIPT_NAME}" "${VERSION}"
printf 'Download directory: %s\n' "${OUTPUT_DIR}"
printf 'Mode: %s\n' "${MODE}"
if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
    printf '%s\n' 'YouTube access: Firefox cookies with web_safari HLS'
fi

ARIA2_ARGUMENTS='-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --console-log-level=warn --enable-color=false --truncate-console-readout=false'
if [[ ${MACHINE_PROGRESS} == true ]]; then
    # yt-dlp does not currently expose aria2c transfer progress through its
    # own progress hooks. yt-dlp captures stderr from external downloaders and
    # normally replays it only on failure, so aria2c's periodic readout must
    # remain on stdout to reach the GUI log during a successful transfer.
    ARIA2_ARGUMENTS+=' --summary-interval=1 --show-console-readout=true --stderr=false'
else
    ARIA2_ARGUMENTS+=' --summary-interval=0'
fi
readonly ARIA2_ARGUMENTS

YT_DLP_OPTIONS=(
    --ignore-config
    --no-playlist
    --js-runtimes deno
    --remote-components ejs:npm
    --embed-metadata
    --output "${OUTPUT_DIR_TEMPLATE}/%(title).150s [%(id)s].%(ext)s"
    --continue
    --progress-delta 1
    # Use aria2c for direct transfers, but retain yt-dlp's native downloader for
    # fragmented DASH and HLS streams. Multiple --downloader rules are additive.
    --downloader aria2c
    --downloader 'dash,m3u8:native'
    --downloader-args "aria2c:${ARIA2_ARGUMENTS}"
    --concurrent-fragments 8
)

if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
    # This explicit profile reads the authenticated Firefox session and asks
    # YouTube's web_safari client for HLS formats. Current yt-dlp guidance notes
    # that these HLS URLs do not require a GVS PO Token at this time.
    YT_DLP_OPTIONS+=(
        --cookies-from-browser firefox
        --extractor-args 'youtube:player_client=web_safari'
        --fixup force
    )
fi

if [[ ${MODE} == 'video' ]]; then
    # Keep both container options. --merge-output-format covers separate
    # video/audio streams, while --remux-video covers the combined-format fallback.
    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        VIDEO_FORMAT='(bv*+ba/b)[protocol^=m3u8]'
    else
        VIDEO_FORMAT='bv*+ba/b'
    fi
    YT_DLP_OPTIONS+=(--format "${VIDEO_FORMAT}")
    # The authenticated HLS profile must let yt-dlp run FixupM3u8 before this
    # wrapper performs its final MKV remux. Scheduling VideoRemuxer here would
    # make yt-dlp treat the fixup as redundant and skip it.
    if [[ ${YOUTUBE_HLS_FIREFOX} != true ]]; then
        YT_DLP_OPTIONS+=(
            --merge-output-format mkv
            --remux-video mkv
        )
    fi
else
    # Match the dedicated download-audio.sh behavior: select the best
    # audio-only stream, fall back to the best combined stream when necessary,
    # extract audio, and preserve the source codec/container whenever possible.
    YT_DLP_OPTIONS+=(
        --format 'ba/b'
        --extract-audio
        --audio-format best
        --audio-quality 0
    )
fi

if [[ ${MACHINE_PROGRESS} == true ]]; then
    YT_DLP_OPTIONS+=(
        --newline
        --progress
        --color never
        --print 'before_dl:YTDLP_PLAN|%(id|unknown)s|%(format_id|unknown)s|%(requested_formats.0.format_id|)s|%(requested_formats.1.format_id|)s'
        --progress-template 'download:YTDLP_PROGRESS_V2|%(info.id|unknown)s|%(info.format_id|unknown)s|%(progress.status|unknown)s|%(progress.downloaded_bytes|0)s|%(progress.total_bytes|0)s|%(progress.total_bytes_estimate|0)s|%(progress.fragment_index|0)s|%(progress.fragment_count|0)s|%(progress._percent_str|)s|%(progress._speed_str|)s|%(progress._eta_str|)s'
        --progress-template 'postprocess:YTDLP_POSTPROCESS|%(progress.status)s|%(progress.postprocessor)s'
    )
fi

PATH_RECORD_TMP=${RESULT_FILE_TMP:-${INTERNAL_PATH_FILE_TMP}}
if [[ -n ${PATH_RECORD_TMP} ]]; then
    # The FILE argument is itself an output template, so literal % characters
    # in the temporary path must be doubled.
    path_record_template=${PATH_RECORD_TMP//%/%%}
    YT_DLP_OPTIONS+=(
        --print-to-file 'after_move:%(filepath)s' "${path_record_template}"
    )
fi

if yt-dlp "${YT_DLP_OPTIONS[@]}" -- "${URL}"; then
    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        hls_source_path=''
        candidate_path=''
        while IFS= read -r candidate_path || [[ -n ${candidate_path} ]]; do
            if [[ -n ${candidate_path} ]]; then
                hls_source_path=${candidate_path}
            fi
        done <"${PATH_RECORD_TMP}"

        if [[ -z ${hls_source_path} || ! -f ${hls_source_path} ]]; then
            error 'yt-dlp did not publish the repaired HLS file path.'
            exit 1
        fi

        hls_source_dir=${hls_source_path%/*}
        if [[ ${hls_source_dir} == "${hls_source_path}" ]]; then
            hls_source_dir='.'
        fi
        hls_source_name=${hls_source_path##*/}
        hls_source_stem=${hls_source_name%.*}
        if [[ ${hls_source_stem} == "${hls_source_name}" ]]; then
            hls_source_stem=${hls_source_name}
        fi
        hls_final_path="${hls_source_dir}/${hls_source_stem}.mkv"

        if [[ ${MACHINE_PROGRESS} == true ]]; then
            printf '%s\n' 'YTDLP_POSTPROCESS|started|FFmpegVideoRemuxer'
        fi
        if ! HLS_REMUX_TMP=$(mktemp \
            --tmpdir="${hls_source_dir}" \
            --suffix='.mkv' \
            '.yt-dlp-remux.XXXXXXXX'); then
            error 'unable to create the temporary MKV file.'
            exit 13
        fi

        ffmpeg_status=0
        ffmpeg \
            -hide_banner \
            -loglevel warning \
            -i "${hls_source_path}" \
            -map 0 \
            -dn \
            -ignore_unknown \
            -c copy \
            -y \
            "${HLS_REMUX_TMP}" || ffmpeg_status=$?
        if ((ffmpeg_status != 0)); then
            error "unable to remux the repaired HLS file into MKV (FFmpeg status ${ffmpeg_status})."
            exit "${ffmpeg_status}"
        fi

        if ! mv -f -- "${HLS_REMUX_TMP}" "${hls_final_path}"; then
            error 'unable to publish the final MKV file.'
            exit 13
        fi
        HLS_REMUX_TMP=''
        if [[ ${hls_source_path} != "${hls_final_path}" ]] &&
            ! rm -f -- "${hls_source_path}"; then
            printf 'Warning: unable to remove the repaired HLS intermediate: %s\n' \
                "${hls_source_path}" >&2
        fi
        if ! printf '%s\n' "${hls_final_path}" >"${PATH_RECORD_TMP}"; then
            error 'unable to record the final MKV path.'
            exit 13
        fi
    fi

    if [[ -n ${PATH_RECORD_TMP} ]]; then
        set +e
        normalize_path_record "${PATH_RECORD_TMP}"
        path_record_status=$?
        set -e
        case ${path_record_status} in
        0) ;;
        1)
            error 'yt-dlp did not report a valid final media path.'
            exit 1
            ;;
        *)
            error 'unable to normalize the final media path record.'
            exit 13
            ;;
        esac
    fi

    if [[ -n ${RESULT_FILE} ]]; then
        if ! mv -f -- "${RESULT_FILE_TMP}" "${RESULT_FILE}"; then
            error 'unable to publish the result file.'
            exit 13
        fi
        RESULT_FILE_TMP=''
    elif [[ -n ${INTERNAL_PATH_FILE_TMP} ]]; then
        if ! rm -f -- "${INTERNAL_PATH_FILE_TMP}"; then
            error 'unable to remove the internal result-path file.'
            exit 13
        fi
        INTERNAL_PATH_FILE_TMP=''
    fi
    printf '\nDownload completed successfully.\n'
else
    status=$?
    printf '\nDownload failed with exit code %d.\n' "${status}" >&2
    exit "${status}"
fi
