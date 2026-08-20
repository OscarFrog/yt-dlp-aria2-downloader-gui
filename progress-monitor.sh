#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# ============================================================================
# Name        : progress-monitor.sh
# Version     : 2.1.24
# Date        : 2026-08-20
# Description : Convert downloader events into a unified Zenity progress stream.
# ============================================================================

set -euo pipefail
export LC_ALL=C

cleanup() {
    exec 3<&- 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 0' PIPE

readonly DOWNLOAD_START=5
readonly DOWNLOAD_END=90
readonly POSTPROCESS_START=92
readonly POSTPROCESS_END=98
readonly VERIFY_PERCENT=99
readonly MAX_PENDING_CHARS=1048576
readonly MAX_SAFE_COUNTER=9000000000000000

usage() {
    printf 'Usage: %s LOG_FILE WORKER_PID RESULT_FILE PROFILE OUTPUT_DIR\n' "${0##*/}" >&2
}

if (($# != 5)); then
    usage
    exit 2
fi

readonly LOG_FILE=$1
readonly WORKER_PID=$2
readonly RESULT_FILE=$3
readonly PROFILE=$4
OUTPUT_DIR=$5

if ! OUTPUT_DIR=$(realpath -e -- "${OUTPUT_DIR}" 2>/dev/null) ||
    [[ ! -d ${OUTPUT_DIR} ]]; then
    printf 'Error: invalid output directory: %s\n' "$5" >&2
    exit 2
fi
readonly OUTPUT_DIR

if [[ ! ${WORKER_PID} =~ ^[1-9][0-9]*$ ]]; then
    printf 'Error: invalid worker PID: %s\n' "${WORKER_PID}" >&2
    exit 2
fi
case ${PROFILE} in
video | audio) ;;
*)
    printf 'Error: invalid profile: %s\n' "${PROFILE}" >&2
    exit 2
    ;;
esac
if [[ ! -f ${LOG_FILE} || ! -r ${LOG_FILE} ]]; then
    printf 'Error: progress log is missing or unreadable: %s\n' "${LOG_FILE}" >&2
    exit 66
fi

process_is_running() {
    local pid=$1
    local process_stat=''
    local process_state=''

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

trim_field() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "${value}"
}

is_unknown_field() {
    case ${1:-} in
    '' | NA | N/A | Unknown | unknown | None | null) return 0 ;;
    *) return 1 ;;
    esac
}

sanitize_integer() {
    local value=${1:-0}
    if [[ ${value} =~ ^[0-9]{1,16}$ ]] &&
        ((10#${value} <= MAX_SAFE_COUNTER)); then
        printf '%d' "$((10#${value}))"
    else
        printf '0'
    fi
}

parse_aria_size() {
    local value=${1:-}
    local whole
    local fraction
    local unit
    local multiplier=1
    local bytes
    local fractional_bytes

    if [[ ! ${value} =~ ^([0-9]{1,16})([.]([0-9]{1,3}))?(B|KiB|Ki|MiB|Mi|GiB|Gi|TiB|Ti)?$ ]]; then
        printf '0'
        return 0
    fi

    whole=$((10#${BASH_REMATCH[1]}))
    fraction=${BASH_REMATCH[3]:-0}
    unit=${BASH_REMATCH[4]:-}
    case ${unit} in
    '' | B) multiplier=1 ;;
    Ki | KiB) multiplier=1024 ;;
    Mi | MiB) multiplier=1048576 ;;
    Gi | GiB) multiplier=1073741824 ;;
    Ti | TiB) multiplier=1099511627776 ;;
    *) printf '0'; return 0 ;;
    esac

    if ((whole > MAX_SAFE_COUNTER / multiplier)); then
        printf '0'
        return 0
    fi
    bytes=$((whole * multiplier))

    fraction="${fraction}000"
    fraction=${fraction:0:3}
    fractional_bytes=$((10#${fraction} * multiplier / 1000))
    if ((fractional_bytes > MAX_SAFE_COUNTER - bytes)); then
        bytes=${MAX_SAFE_COUNTER}
    else
        bytes=$((bytes + fractional_bytes))
    fi
    printf '%d' "${bytes}"
}

saturating_add() {
    local left=$1
    local right=$2
    if ((right > MAX_SAFE_COUNTER - left)); then
        printf '%d' "${MAX_SAFE_COUNTER}"
    else
        printf '%d' "$((left + right))"
    fi
}

sanitize_percent() {
    local value
    local integer_part

    value=$(trim_field "${1:-}")
    value=${value%%%}
    value=$(trim_field "${value}")
    if [[ ${value} =~ ^([0-9]{1,3})([.][0-9]{1,6})?$ ]]; then
        integer_part=${BASH_REMATCH[1]}
        value=$((10#${integer_part}))
        if ((value > 100)); then
            value=100
        fi
        printf '%d' "${value}"
    else
        printf '%d' '-1'
    fi
}

emit_progress() {
    local percent=$1
    local message=$2

    printf '%d\n' "${percent}" 2>/dev/null || return 1
    printf '# %s\n' "${message}" 2>/dev/null || return 1
}

postprocess_message() {
    case ${1:-} in
    *Merger*) printf '%s' 'Merging the video and audio streams...' ;;
    *Remux*) printf '%s' 'Remuxing the media into an MKV container...' ;;
    *ExtractAudio*) printf '%s' 'Extracting the native audio track...' ;;
    *Metadata*) printf '%s' 'Writing media metadata...' ;;
    *EmbedSubtitle*) printf '%s' 'Embedding subtitles...' ;;
    *Fixup*) printf '%s' 'Repairing the downloaded media...' ;;
    *) printf '%s' 'Finalizing the media file...' ;;
    esac
}

bounded_advance() {
    local minimum=$1
    local maximum=$2
    local current=$3

    if ((current < minimum)); then
        current=${minimum}
    elif ((current < maximum)); then
        current=$((current + 1))
    fi

    printf '%d' "${current}"
}

declare -A ITEM_PERCENT=()
declare -A ITEM_DOWNLOADED=()
declare -A ITEM_TOTAL=()
declare -A ITEM_INDEX=()
declare -A ARIA_GID_ITEM=()
declare -A ARIA_KEY_ASSIGNED=()

declare -a PLANNED_KEYS=()
declare -a PLANNED_FORMAT_IDS=()
declare -a NATIVE_FORMAT_IDS=()
declare -a NATIVE_FORMAT_KEYS=()

planned_items=0
seen_items=0
aria_items=0
stable_percent=0
display_percent=0
message='Analyzing the webpage...'
phase='analyzing'
postprocessor=''
ffmpeg_duration_us=0
ffmpeg_out_time_us=0
last_line=''
RESOLVED_KEY=''
SANITIZED_IDENTIFIER=''

register_item() {
    local key=$1
    local index=${2:-0}

    if [[ -z ${ITEM_INDEX[${key}]+x} ]]; then
        ((seen_items += 1))
        if ((index <= 0)); then
            index=${seen_items}
        fi
        ITEM_INDEX[${key}]=${index}
        ITEM_PERCENT[${key}]=0
        ITEM_DOWNLOADED[${key}]=0
        ITEM_TOTAL[${key}]=0
    fi
}

sanitize_identifier() {
    local value=${1:-}

    SANITIZED_IDENTIFIER=''
    if ((${#value} <= 128)) &&
        [[ ${value} =~ ^[A-Za-z0-9_.:+-]+$ ]]; then
        SANITIZED_IDENTIFIER=${value}
    fi
}

set_plan() {
    local combined_id=$1
    local first_id=$2
    local second_id=$3
    local key
    local slot=0

    PLANNED_KEYS=()
    PLANNED_FORMAT_IDS=()

    sanitize_identifier "${first_id}"
    first_id=${SANITIZED_IDENTIFIER}
    sanitize_identifier "${second_id}"
    second_id=${SANITIZED_IDENTIFIER}
    sanitize_identifier "${combined_id}"
    combined_id=${SANITIZED_IDENTIFIER}

    if [[ -n ${first_id} ]]; then
        ((slot += 1))
        PLANNED_KEYS+=("plan:${slot}")
        PLANNED_FORMAT_IDS+=("${first_id}")
    fi
    if [[ -n ${second_id} ]]; then
        ((slot += 1))
        PLANNED_KEYS+=("plan:${slot}")
        PLANNED_FORMAT_IDS+=("${second_id}")
    fi
    if ((${#PLANNED_KEYS[@]} == 0)); then
        PLANNED_KEYS=('plan:1')
        PLANNED_FORMAT_IDS=("${combined_id}")
    fi

    planned_items=${#PLANNED_KEYS[@]}
    for key in "${PLANNED_KEYS[@]}"; do
        register_item "${key}" "$(( ${#ITEM_INDEX[@]} + 1 ))"
    done
    phase='downloading'
    if ((stable_percent < DOWNLOAD_START)); then
        stable_percent=${DOWNLOAD_START}
    fi
}

resolve_native_key() {
    local format_id=$1
    local index
    local key

    RESOLVED_KEY=''
    sanitize_identifier "${format_id}"
    format_id=${SANITIZED_IDENTIFIER}

    if [[ -n ${format_id} ]]; then
        for index in "${!PLANNED_KEYS[@]}"; do
            key=${PLANNED_KEYS[index]}
            if [[ ${PLANNED_FORMAT_IDS[index]} == "${format_id}" ]] &&
                (( ${ITEM_PERCENT[${key}]:-0} < 100 )); then
                RESOLVED_KEY=${key}
                return 0
            fi
        done
        for index in "${!PLANNED_KEYS[@]}"; do
            if [[ ${PLANNED_FORMAT_IDS[index]} == "${format_id}" ]]; then
                RESOLVED_KEY=${PLANNED_KEYS[index]}
                return 0
            fi
        done
        for index in "${!NATIVE_FORMAT_IDS[@]}"; do
            if [[ ${NATIVE_FORMAT_IDS[index]} == "${format_id}" ]]; then
                RESOLVED_KEY=${NATIVE_FORMAT_KEYS[index]}
                return 0
            fi
        done
    fi

    for key in "${PLANNED_KEYS[@]}"; do
        if (( ${ITEM_PERCENT[${key}]:-0} < 100 )); then
            RESOLVED_KEY=${key}
            return 0
        fi
    done

    if [[ -z ${format_id} && ${#NATIVE_FORMAT_KEYS[@]} -gt 0 ]]; then
        RESOLVED_KEY=${NATIVE_FORMAT_KEYS[-1]}
        return 0
    fi

    RESOLVED_KEY="native:$((seen_items + 1))"
    NATIVE_FORMAT_IDS+=("${format_id}")
    NATIVE_FORMAT_KEYS+=("${RESOLVED_KEY}")
}

resolve_aria_key() {
    local gid=$1
    local index
    local key=''
    local candidate

    RESOLVED_KEY=''
    if [[ -n ${ARIA_GID_ITEM[${gid}]+x} ]]; then
        RESOLVED_KEY=${ARIA_GID_ITEM[${gid}]}
        return 0
    fi

    ((aria_items += 1))
    index=${aria_items}

    # aria2c does not expose yt-dlp's format identifier. Associate each new GID
    # with the first planned stream that has not already been assigned to aria2c
    # and is not known to be complete through the native downloader.
    for candidate in "${PLANNED_KEYS[@]}"; do
        if [[ -z ${ARIA_KEY_ASSIGNED[${candidate}]+x} ]] &&
            (( ${ITEM_PERCENT[${candidate}]:-0} < 100 )); then
            key=${candidate}
            break
        fi
    done
    if [[ -z ${key} ]]; then
        for candidate in "${PLANNED_KEYS[@]}"; do
            if [[ -z ${ARIA_KEY_ASSIGNED[${candidate}]+x} ]]; then
                key=${candidate}
                break
            fi
        done
    fi
    if [[ -z ${key} ]]; then
        key="aria:${gid}"
    fi

    ARIA_GID_ITEM[${gid}]=${key}
    ARIA_KEY_ASSIGNED[${key}]=1
    register_item "${key}" "${ITEM_INDEX[${key}]:-${index}}"
    RESOLVED_KEY=${key}
}

calculate_download_percent() {
    local key
    local item_count=${planned_items}
    local sum_percent=0
    local sum_downloaded=0
    local sum_total=0
    local all_totals_known=true
    local value

    if ((item_count <= 0)); then
        item_count=${seen_items}
    fi
    if ((item_count <= 0)); then
        printf '%d' 0
        return 0
    fi

    if ((${#PLANNED_KEYS[@]} > 0)); then
        for key in "${PLANNED_KEYS[@]}"; do
            value=${ITEM_PERCENT[${key}]:-0}
            sum_percent=$(saturating_add "${sum_percent}" "${value}")
            value=${ITEM_TOTAL[${key}]:-0}
            if ((value <= 0)); then
                all_totals_known=false
            else
                sum_total=$(saturating_add "${sum_total}" "${value}")
                sum_downloaded=$(saturating_add "${sum_downloaded}" "${ITEM_DOWNLOADED[${key}]:-0}")
            fi
        done
    else
        for key in "${!ITEM_PERCENT[@]}"; do
            sum_percent=$(saturating_add "${sum_percent}" "${ITEM_PERCENT[${key}]}")
            value=${ITEM_TOTAL[${key}]:-0}
            if ((value <= 0)); then
                all_totals_known=false
            else
                sum_total=$(saturating_add "${sum_total}" "${value}")
                sum_downloaded=$(saturating_add "${sum_downloaded}" "${ITEM_DOWNLOADED[${key}]:-0}")
            fi
        done
    fi

    if [[ ${all_totals_known} == true ]] && ((sum_total > 0)); then
        if ((sum_downloaded >= sum_total)); then
            value=100
        elif ((sum_total <= MAX_SAFE_COUNTER / 100)); then
            value=$((sum_downloaded * 100 / sum_total))
        else
            value=$((sum_downloaded / (sum_total / 100 + 1)))
        fi
    else
        value=$((sum_percent / item_count))
    fi
    if ((value > 100)); then
        value=100
    fi
    printf '%d' "${value}"
}

update_stable_download_display() {
    local global_percent
    local candidate

    global_percent=$(calculate_download_percent)
    candidate=$((DOWNLOAD_START + global_percent * (DOWNLOAD_END - DOWNLOAD_START) / 100))
    if ((candidate > DOWNLOAD_END)); then
        candidate=${DOWNLOAD_END}
    fi
    if ((candidate > stable_percent)); then
        stable_percent=${candidate}
    fi
}

format_download_message() {
    local key=$1
    local source=$2
    local percent=$3
    local speed=${4:-}
    local eta=${5:-}
    local index=${ITEM_INDEX[${key}]:-1}
    local total=${planned_items}
    local text

    if ((total <= 0)); then
        total=${seen_items}
    fi
    if ((total > 1)); then
        text="Downloading item ${index}/${total}"
    elif [[ ${PROFILE} == audio ]]; then
        text='Downloading the audio track'
    else
        text='Downloading the media'
    fi
    if ((percent >= 0)); then
        text+=" - ${percent}%"
    else
        text+=' - size unknown'
    fi
    if [[ ${source} == aria2 ]]; then
        text+=' (aria2c)'
    fi
    # Unknown speed is intentionally omitted.
    # shellcheck disable=SC2310
    if ! is_unknown_field "${speed}"; then
        text+=" - ${speed}"
    fi
    # Unknown ETA is intentionally omitted.
    # shellcheck disable=SC2310
    if ! is_unknown_field "${eta}"; then
        text+=" - ${eta} remaining"
    fi
    printf '%s' "${text}"
}

handle_plan() {
    local _prefix=$1
    local _media_id=$2
    local combined_id=$3
    local first_id=$4
    local second_id=$5

    set_plan "${combined_id}" "${first_id}" "${second_id}"
    message='Preparing the selected media streams...'
}

handle_v2_progress() {
    local _prefix=$1
    local _media_id=$2
    local format_id=$3
    local status=$4
    local downloaded_text=$5
    local total_text=$6
    local estimate_text=$7
    local fragment_index_text=$8
    local fragment_count_text=$9
    local percent_text=${10}
    local speed=${11}
    local eta=${12}
    local key
    local downloaded
    local total
    local estimate
    local fragment_index
    local fragment_count
    local percent

    if [[ ${phase} == postprocessing || ${phase} == verifying ]]; then
        return 0
    fi
    phase='downloading'
    resolve_native_key "${format_id}"
    key=${RESOLVED_KEY}
    register_item "${key}"

    downloaded=$(sanitize_integer "${downloaded_text}")
    total=$(sanitize_integer "${total_text}")
    estimate=$(sanitize_integer "${estimate_text}")
    fragment_index=$(sanitize_integer "${fragment_index_text}")
    fragment_count=$(sanitize_integer "${fragment_count_text}")
    percent=$(sanitize_percent "${percent_text}")

    if ((fragment_count > 1 && fragment_index == 0)) &&
        [[ ${status} != finished ]]; then
        # yt-dlp's native HLS downloader can emit a tiny manifest/bootstrap
        # record as 100% before fragment 1/N starts. It is not media progress.
        downloaded=0
        total=0
        percent=0
    else
        if ((total <= 0 && estimate > 0)); then
            total=${estimate}
        fi
        if ((total > 0)); then
            percent=$((downloaded * 100 / total))
        elif ((fragment_count > 0)); then
            percent=$((fragment_index * 100 / fragment_count))
        fi
    fi
    if [[ ${status} == finished ]]; then
        percent=100
        if ((total > 0)); then
            downloaded=${total}
        fi
    fi
    if ((percent > 100)); then
        percent=100
    fi
    if ((percent >= 0 && percent > ${ITEM_PERCENT[${key}]:-0})); then
        ITEM_PERCENT[${key}]=${percent}
    fi
    if ((downloaded > ${ITEM_DOWNLOADED[${key}]:-0})); then
        ITEM_DOWNLOADED[${key}]=${downloaded}
    fi
    if ((total > 0)); then
        ITEM_TOTAL[${key}]=${total}
    fi

    update_stable_download_display
    message=$(format_download_message "${key}" native "${percent}" "${speed}" "${eta}")
}

handle_legacy_progress() {
    local _prefix=$1
    local _status=$2
    local percent_text=$3
    local speed=$4
    local eta=$5
    local key
    local percent

    if [[ ${phase} == postprocessing || ${phase} == verifying ]]; then
        return 0
    fi
    phase='downloading'
    resolve_native_key ''
    key=${RESOLVED_KEY}
    register_item "${key}"
    if ((planned_items <= 0)); then
        planned_items=1
        PLANNED_KEYS=("${key}")
    fi
    percent=$(sanitize_percent "${percent_text}")
    if ((percent >= 0 && percent > ${ITEM_PERCENT[${key}]:-0})); then
        ITEM_PERCENT[${key}]=${percent}
    fi
    update_stable_download_display
    message=$(format_download_message "${key}" native "${percent}" "${speed}" "${eta}")
}

handle_aria_progress() {
    local line=$1
    local gid
    local key
    local percent=-1
    local speed=''
    local eta=''
    local downloaded_text=''
    local total_text=''
    local downloaded=0
    local total=0

    if [[ ${phase} == postprocessing || ${phase} == verifying ]]; then
        return 0
    fi
    if [[ ! ${line} =~ ^\[#([[:xdigit:]]+)[[:space:]] ]]; then
        return 0
    fi
    gid=${BASH_REMATCH[1]}
    resolve_aria_key "${gid}"
    key=${RESOLVED_KEY}
    phase='downloading'
    if ((planned_items <= 0)); then
        if [[ ${PROFILE} == video ]]; then
            planned_items=2
        else
            planned_items=1
        fi
    fi

    if [[ ${line} =~ [[:space:]]([^/[:space:]]+)/([^()[:space:]]+)\(([0-9]{1,3})%\) ]]; then
        downloaded_text=${BASH_REMATCH[1]}
        total_text=${BASH_REMATCH[2]}
        percent=$((10#${BASH_REMATCH[3]}))
        downloaded=$(parse_aria_size "${downloaded_text}")
        total=$(parse_aria_size "${total_text}")
    elif [[ ${line} =~ \(([0-9]{1,3})%\) ]]; then
        percent=$((10#${BASH_REMATCH[1]}))
    fi

    if ((percent > 100)); then
        percent=100
    fi
    if ((percent >= 0 && percent > ${ITEM_PERCENT[${key}]:-0})); then
        ITEM_PERCENT[${key}]=${percent}
    fi
    if ((downloaded > ${ITEM_DOWNLOADED[${key}]:-0})); then
        ITEM_DOWNLOADED[${key}]=${downloaded}
    fi
    if ((total > 0)); then
        ITEM_TOTAL[${key}]=${total}
    fi

    if [[ ${line} == *' DL:'* ]]; then
        speed=${line##* DL:}
        speed=${speed%% *}
        speed=${speed%%]*}
    elif [[ ${line} == *' SPD:'* ]]; then
        speed=${line##* SPD:}
        speed=${speed%% *}
        speed=${speed%%]*}
    fi
    if [[ ${line} == *' ETA:'* ]]; then
        eta=${line##* ETA:}
        eta=${eta%%]*}
        eta=${eta%% *}
    fi

    update_stable_download_display
    message=$(format_download_message "${key}" aria2 "${percent}" "${speed}" "${eta}")
}

handle_ffmpeg_duration() {
    local _prefix=$1
    local duration_text=${2:-0}

    ffmpeg_duration_us=$(sanitize_integer "${duration_text}")
    ffmpeg_out_time_us=0
    phase='postprocessing'
    postprocessor='FFmpegVideoRemuxer'
    if ((stable_percent < POSTPROCESS_START)); then
        stable_percent=${POSTPROCESS_START}
    fi
    message='Remuxing the media into an MKV container...'
}

handle_ffmpeg_progress() {
    local value_text=$1
    local value
    local candidate

    [[ ${phase} == postprocessing ]] || return 0
    ((ffmpeg_duration_us > 0)) || return 0
    value=$(sanitize_integer "${value_text}")
    ((value > ffmpeg_out_time_us)) || return 0
    ffmpeg_out_time_us=${value}
    if ((value >= ffmpeg_duration_us)); then
        candidate=${POSTPROCESS_END}
    elif ((ffmpeg_duration_us <= MAX_SAFE_COUNTER / 100)); then
        candidate=$((POSTPROCESS_START + value * (POSTPROCESS_END - POSTPROCESS_START) / ffmpeg_duration_us))
    else
        candidate=$((POSTPROCESS_START + value / (ffmpeg_duration_us / (POSTPROCESS_END - POSTPROCESS_START) + 1)))
    fi
    if ((candidate > POSTPROCESS_END)); then
        candidate=${POSTPROCESS_END}
    fi
    if ((candidate > stable_percent)); then
        stable_percent=${candidate}
    fi
}

handle_postprocess() {
    local _prefix=$1
    local _status=$2
    local processor=${3:-}

    phase='postprocessing'
    postprocessor=${processor}
    if ((stable_percent < POSTPROCESS_START)); then
        stable_percent=${POSTPROCESS_START}
    fi
    message=$(postprocess_message "${postprocessor}")
}

process_line() {
    local line=$1
    local -a fields=()

    [[ -n ${line} ]] || return 0
    [[ ${line} != "${last_line}" ]] || return 0
    last_line=${line}

    case ${line} in
    YTDLP_PLAN\|*)
        IFS='|' read -r -a fields <<<"${line}"
        ((${#fields[@]} <= 5)) || return 0
        while ((${#fields[@]} < 5)); do fields+=(''); done
        handle_plan "${fields[@]:0:5}"
        ;;
    YTDLP_PROGRESS_V2\|*)
        IFS='|' read -r -a fields <<<"${line}"
        ((${#fields[@]} <= 12)) || return 0
        while ((${#fields[@]} < 12)); do fields+=(''); done
        handle_v2_progress "${fields[@]:0:12}"
        ;;
    YTDLP_PROGRESS\|*)
        IFS='|' read -r -a fields <<<"${line}"
        ((${#fields[@]} <= 5)) || return 0
        while ((${#fields[@]} < 5)); do fields+=(''); done
        handle_legacy_progress "${fields[@]:0:5}"
        ;;
    YTDLP_POSTPROCESS\|*)
        IFS='|' read -r -a fields <<<"${line}"
        ((${#fields[@]} <= 3)) || return 0
        while ((${#fields[@]} < 3)); do fields+=(''); done
        handle_postprocess "${fields[@]:0:3}"
        ;;
    FFMPEG_PROGRESS_DURATION\|*)
        IFS='|' read -r -a fields <<<"${line}"
        ((${#fields[@]} == 2)) || return 0
        handle_ffmpeg_duration "${fields[@]:0:2}"
        ;;
    out_time_us=*)
        handle_ffmpeg_progress "${line#out_time_us=}"
        ;;
    \[#*)
        handle_aria_progress "${line}"
        ;;
    *)
        ;;
    esac
}

result_file_confirms_output() {
    local candidate=''
    local final_path=''
    local resolved_path=''

    [[ -s ${RESULT_FILE} ]] || return 1
    while IFS= read -r candidate || [[ -n ${candidate} ]]; do
        if [[ -n ${candidate} ]]; then
            final_path=${candidate}
        fi
    done <"${RESULT_FILE}"

    [[ -n ${final_path} ]] || return 1
    resolved_path=$(realpath -e -- "${final_path}" 2>/dev/null) || return 1
    [[ -f ${resolved_path} ]] || return 1
    [[ ${OUTPUT_DIR} == / || ${resolved_path} == "${OUTPUT_DIR}"/* ]]
}

render_tick() {
    local rendered=${stable_percent}

    case ${phase} in
    analyzing)
        rendered=$(bounded_advance 0 3 "${display_percent}")
        ;;
    downloading)
        if [[ ${message} == *'size unknown'* ]]; then
            rendered=$(bounded_advance \
                "${stable_percent}" \
                "$((stable_percent + 2 > DOWNLOAD_END ? DOWNLOAD_END : stable_percent + 2))" \
                "${display_percent}")
        fi
        ;;
    postprocessing)
        if ((ffmpeg_duration_us > 0)); then
            rendered=${stable_percent}
        else
            rendered=$(bounded_advance \
                "${POSTPROCESS_START}" "${POSTPROCESS_END}" "${display_percent}")
        fi
        ;;
    verifying)
        rendered=${VERIFY_PERCENT}
        ;;
    *)
        ;;
    esac
    if ((rendered < display_percent)); then
        rendered=${display_percent}
    fi
    if ((rendered > VERIFY_PERCENT)); then
        rendered=${VERIFY_PERCENT}
    fi
    display_percent=${rendered}
    emit_progress "${display_percent}" "${message}"
}

# Read the regular log file directly through a persistent descriptor. Bash's
# read -N returns all bytes currently available at EOF, including a partial
# record, so no asynchronous tail/tr pipeline or timed-read fragment can be
# lost. Carriage-return console updates are normalized in memory.
if ! exec 3<"${LOG_FILE}"; then
    printf 'Error: unable to open progress log: %s\n' "${LOG_FILE}" >&2
    exit 66
fi

pending_data=''
consume_log_data() {
    local chunk=$1
    local line

    pending_data+=${chunk}
    if ((${#pending_data} > MAX_PENDING_CHARS)); then
        pending_data=''
        message='Progress information contained an oversized record; the download continues...'
        return 0
    fi
    pending_data=${pending_data//$'\r'/$'\n'}
    while [[ ${pending_data} == *$'\n'* ]]; do
        line=${pending_data%%$'\n'*}
        pending_data=${pending_data#*$'\n'}
        process_line "${line}"
    done
}

while true; do
    chunk=''
    read_status=0
    IFS= read -r -N 65536 chunk <&3 || read_status=$?
    if [[ -n ${chunk} ]]; then
        consume_log_data "${chunk}"
    fi

    # A regular file reports status 1 at its current EOF. That is expected
    # while the worker is still appending; poll at a bounded rate rather than
    # spinning. Any other read failure is surfaced but does not abort the
    # download worker.
    if ((read_status != 0 && read_status != 1)); then
        message='Progress information is unavailable; the download continues...'
    elif [[ ! -r ${LOG_FILE} ]]; then
        message='Progress information is unavailable; the download continues...'
    fi

    # process_is_running is deliberately used as a liveness predicate.
    # shellcheck disable=SC2310
    if ! process_is_running "${WORKER_PID}"; then
        # The worker has stopped, but it may have appended bytes after the read
        # at the top of this iteration. Drain the regular file to its final EOF
        # before processing a last unterminated record.
        while true; do
            chunk=''
            IFS= read -r -N 65536 chunk <&3 || true
            [[ -n ${chunk} ]] || break
            consume_log_data "${chunk}"
        done
        if [[ -n ${pending_data} ]]; then
            process_line "${pending_data}"
            pending_data=''
        fi
        # A closed Zenity pipe ends the monitor normally.
        # shellcheck disable=SC2310
        render_tick || exit 0
        break
    fi

    # A closed Zenity pipe ends the monitor normally.
    # shellcheck disable=SC2310
    render_tick || exit 0
    if [[ -z ${chunk} ]]; then
        sleep 0.4
    fi
done

# The atomic result file is necessary but not sufficient: confirm that its
# final path names an actual regular file before presenting 100 percent.
# shellcheck disable=SC2310 # Predicate failure is the expected incomplete case.
if result_file_confirms_output; then
    phase='verifying'
    message='Verifying the final media file...'
    emit_progress "${VERIFY_PERCENT}" "${message}" || exit 0
    emit_progress 100 'Download complete.' || exit 0
else
    emit_progress "${display_percent}" 'Download ended before the final file was confirmed.' || exit 0
fi
