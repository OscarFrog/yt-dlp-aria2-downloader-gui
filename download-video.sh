#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# ============================================================================
# Name        : download-video.sh
# Version     : 2.1.8
# Date        : 2026-07-27
# Description : Download one complete MKV video or the best native audio track.
# ============================================================================

set -Eeuo pipefail

readonly VERSION="2.1.8"
readonly MIN_YT_DLP_VERSION="2026.06.09"
readonly MIN_ARIA2_VERSION="1.37.0"
readonly MIN_DENO_VERSION="2.3.0"
readonly SCRIPT_NAME="${0##*/}"

VERSION_AT_LEAST=false
VERSION_PARSE_VALID=false

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
      --machine-progress     Emit stable YTDLP_PROGRESS records.
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

    if [[ ! ${minimum} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        return 0
    fi
    minimum_major=$((10#${BASH_REMATCH[1]}))
    minimum_minor=$((10#${BASH_REMATCH[2]}))
    minimum_patch=$((10#${BASH_REMATCH[3]}))
    VERSION_PARSE_VALID=true

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
        --progress-template \
        --print-to-file \
        --downloader-args; do
        if ! grep -Eq -- "^[[:space:]]*${required_option}([=[:space:]]|$)" <<<"${yt_dlp_help}"; then
            error "this yt-dlp build does not support ${required_option}."
            return 1
        fi
    done

    if ! aria2_version_line=$(LC_ALL=C aria2c --version 2>/dev/null); then
        error 'unable to determine the aria2c version.'
        return 1
    fi
    aria2_version_line=${aria2_version_line%%$'\n'*}
    if [[ ! ${aria2_version_line} =~ ^aria2[[:space:]]+version[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]]; then
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
        if ! grep -Eq -- "^[[:space:]]*${required_option}([=[:space:]\[]|$)" <<<"${aria2_help}"; then
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

resolve_script_dir() {
    local output_variable=$1
    local script_source=${BASH_SOURCE[0]}
    local script_path
    local script_dir

    if [[ ${script_source} != */* ]]; then
        if ! script_source=$(type -P -- "${script_source}"); then
            error 'unable to locate the script in PATH.'
            return 1
        fi
    fi

    if ! script_path=$(realpath -e -- "${script_source}"); then
        error 'unable to resolve the real script path.'
        return 1
    fi

    if ! script_dir=$(dirname -- "${script_path}"); then
        error 'unable to determine the script directory.'
        return 1
    fi

    printf -v "${output_variable}" '%s' "${script_dir}"
}

OUTPUT_DIR=''
MODE='video'
MACHINE_PROGRESS=false
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

if [[ ! ${URL} =~ ^https?://.+ ]]; then
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

for command_name in yt-dlp aria2c ffmpeg ffprobe realpath dirname deno grep; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        error "required command \"${command_name}\" was not found."
        exit 127
    fi
done

# Keep this as a simple command: placing it in an if/|| context would disable
# errexit inside the function body under Bash's documented rules.
check_runtime_compatibility

set +e
resolve_script_dir SCRIPT_DIR
resolve_status=$?
set -e
if ((resolve_status != 0)); then
    exit 1
fi
readonly SCRIPT_DIR

if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR=${SCRIPT_DIR}
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

    if ! : >"${RESULT_FILE}"; then
        error 'unable to initialize the result file.'
        exit 13
    fi
fi

printf '%s version %s\n' "${SCRIPT_NAME}" "${VERSION}"
printf 'Download directory: %s\n' "${OUTPUT_DIR}"
printf 'Mode: %s\n' "${MODE}"

ARIA2_ARGUMENTS='-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --console-log-level=warn --enable-color=false --truncate-console-readout=false'
if [[ ${MACHINE_PROGRESS} == true ]]; then
    # yt-dlp does not currently expose aria2c transfer progress through its
    # own progress hooks. Keep aria2c's documented console readout enabled so
    # the GUI can display the active HTTP(S) transfer percentage.
    ARIA2_ARGUMENTS+=' --summary-interval=1 --show-console-readout=true --stderr=true'
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

if [[ ${MODE} == 'video' ]]; then
    YT_DLP_OPTIONS+=(
        --format 'bv*+ba/b'
        --merge-output-format mkv
        --remux-video mkv
    )
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
        --progress-template 'download:YTDLP_PROGRESS|%(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s'
        --progress-template 'postprocess:YTDLP_POSTPROCESS|%(progress.status)s|%(progress.postprocessor)s'
    )
fi

if [[ -n ${RESULT_FILE} ]]; then
    # The FILE argument is itself an output template, so literal % characters
    # in the path must be doubled.
    result_file_template=${RESULT_FILE//%/%%}
    YT_DLP_OPTIONS+=(
        --print-to-file 'after_move:%(filepath)s' "${result_file_template}"
    )
fi

if yt-dlp "${YT_DLP_OPTIONS[@]}" -- "${URL}"; then
    printf '\nDownload completed successfully.\n'
else
    status=$?
    printf '\nDownload failed with exit code %d.\n' "${status}" >&2
    exit "${status}"
fi
