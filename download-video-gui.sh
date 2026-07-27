#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# ============================================================================
# Name        : download-video-gui.sh
# Version     : 2.1.8
# Date        : 2026-07-27
# Description : Two-choice Zenity GUI for complete MKV video or native audio.
# ============================================================================

set -Eeuo pipefail
umask 077

if [[ -z ${HOME:-} ]]; then
    printf 'Error: the HOME environment variable is not defined.\n' >&2
    exit 1
fi

readonly APP_NAME='yt-dlp aria2 downloader'
readonly PROFILE_LABEL_VIDEO='Complete video (MKV)'
readonly PROFILE_LABEL_AUDIO='Audio track (native format)'
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/yt-dlp-aria2-downloader"
readonly STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/yt-dlp-aria2-downloader"
readonly CONFIG_FILE="${CONFIG_DIR}/gui.conf"

WORKER_PID=''
WORKER_PGID=''
TEMP_DIR=''
CLEANUP_DONE=false
ZENITY_STATUS=0
ZENITY_ERROR=''

show_error() {
    local message=$1

    if ! zenity --error \
        --title="${APP_NAME}" \
        --text="${message}" \
        --no-markup \
        --width=520; then
        printf 'Error: %s\n' "${message}" >&2
    fi

    return 0
}

run_zenity_capture() {
    local output_variable=$1
    shift
    local output=''
    local status
    local error_file

    ZENITY_ERROR=''

    error_file=$(mktemp --tmpdir="${TMPDIR:-/tmp}" zenity-error.XXXXXXXX) || {
        ZENITY_STATUS=70
        ZENITY_ERROR='Unable to create the temporary Zenity diagnostic file.'
        printf -v "${output_variable}" '%s' ''
        return 0
    }

    if output=$(zenity "$@" 2>"${error_file}"); then
        status=0
    else
        status=$?
    fi

    if [[ -s ${error_file} ]]; then
        ZENITY_ERROR=$(<"${error_file}")
    fi
    rm -f -- "${error_file}"

    case ${status} in
    0 | 1 | 5)
        ZENITY_STATUS=${status}
        ;;
    *)
        ZENITY_STATUS=70
        if [[ -z ${ZENITY_ERROR} ]]; then
            ZENITY_ERROR="Zenity exited with status ${status}."
        fi
        ;;
    esac

    printf -v "${output_variable}" '%s' "${output}"
    return 0
}

resolve_script_dir() {
    local output_variable=$1
    local script_source=${BASH_SOURCE[0]}
    local script_path
    local script_dir

    if [[ ${script_source} != */* ]]; then
        script_source=$(type -P -- "${script_source}") || return 1
    fi

    script_path=$(realpath -e -- "${script_source}") || return 1
    script_dir=$(dirname -- "${script_path}") || return 1
    printf -v "${output_variable}" '%s' "${script_dir}"
}

stop_worker_group() {
    local attempt

    if [[ -z ${WORKER_PGID} ]] ||
        ! kill -0 -- "-${WORKER_PGID}" 2>/dev/null; then
        return 0
    fi

    kill -TERM -- "-${WORKER_PGID}" 2>/dev/null || true

    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! kill -0 -- "-${WORKER_PGID}" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done

    kill -KILL -- "-${WORKER_PGID}" 2>/dev/null || true
}

cleanup() {
    local status=$?

    if [[ ${CLEANUP_DONE} == true ]]; then
        return
    fi
    CLEANUP_DONE=true

    if [[ -n ${WORKER_PID} ]] && kill -0 "${WORKER_PID}" 2>/dev/null; then
        stop_worker_group
        wait "${WORKER_PID}" 2>/dev/null || true
    fi

    if [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi

    return "${status}"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

load_settings() {
    local key
    local value

    LAST_OUTPUT_DIR=''
    LAST_PROFILE='video'

    if [[ ! -r ${CONFIG_FILE} ]]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        case ${key} in
        output_dir)
            LAST_OUTPUT_DIR=${value}
            ;;
        profile)
            case ${value} in
            video | audio)
                LAST_PROFILE=${value}
                ;;
            audio-mp3 | audio-m4a | audio-opus)
                # Migrate settings written by versions 2.0.x.
                LAST_PROFILE='audio'
                ;;
            *)
                LAST_PROFILE='video'
                ;;
            esac
            ;;
        *) ;; # Ignore settings added by future versions.
        esac
    done <"${CONFIG_FILE}"
}

save_settings() {
    local output_dir=$1
    local profile=$2
    local temporary_file

    mkdir -p -- "${CONFIG_DIR}" || return 1
    chmod 700 -- "${CONFIG_DIR}" 2>/dev/null || true

    temporary_file=$(mktemp --tmpdir="${CONFIG_DIR}" gui.conf.XXXXXX) || return 1
    {
        printf 'output_dir=%s\n' "${output_dir}"
        printf 'profile=%s\n' "${profile}"
    } >"${temporary_file}"
    chmod 600 -- "${temporary_file}"
    mv -f -- "${temporary_file}" "${CONFIG_FILE}"
}

default_output_dir() {
    local candidate=''

    if command -v xdg-user-dir >/dev/null 2>&1; then
        candidate=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
        if [[ -z ${candidate} || ! -d ${candidate} ]]; then
            candidate=$(xdg-user-dir VIDEOS 2>/dev/null || true)
        fi
    fi

    if [[ -z ${candidate} || ! -d ${candidate} ]]; then
        if [[ -d ${HOME}/Downloads ]]; then
            candidate=${HOME}/Downloads
        elif [[ -d ${HOME}/Videos ]]; then
            candidate=${HOME}/Videos
        else
            candidate=${HOME}
        fi
    fi

    printf '%s\n' "${candidate}"
}

select_url() {
    local output_variable=$1
    local entered_url
    local capture_status

    run_zenity_capture entered_url --entry \
        --title="${APP_NAME}" \
        --text="Paste the video URL to download:" \
        --ok-label='Continue' \
        --cancel-label='Cancel' \
        --width=700
    capture_status=${ZENITY_STATUS}

    if ((capture_status != 0)); then
        return "${capture_status}"
    fi

    entered_url=$(trim_field "${entered_url}")

    if [[ ${entered_url} == *$'\n'* || ${entered_url} == *$'\r'* ]]; then
        show_error "The URL must not contain line breaks."
        return 2
    fi

    if [[ ! ${entered_url} =~ ^https?://.+ ]]; then
        show_error "The URL must start with http:// or https://."
        return 2
    fi

    printf -v "${output_variable}" '%s' "${entered_url}"
}

select_profile() {
    local output_variable=$1
    local default_video=FALSE
    local default_audio=FALSE
    local selected
    local capture_status
    local selected_profile

    case ${LAST_PROFILE} in
    video) default_video=TRUE ;;
    audio) default_audio=TRUE ;;
    *) default_video=TRUE ;;
    esac

    run_zenity_capture selected --list \
        --radiolist \
        --title="${APP_NAME}" \
        --text='Choose the output type:' \
        --column='Select' \
        --column='Profile' \
        --hide-header \
        --print-column=2 \
        --ok-label='Continue' \
        --cancel-label='Cancel' \
        --width=560 \
        --height=240 \
        "${default_video}" "${PROFILE_LABEL_VIDEO}" \
        "${default_audio}" "${PROFILE_LABEL_AUDIO}"
    capture_status=${ZENITY_STATUS}

    if ((capture_status != 0)); then
        return "${capture_status}"
    fi

    case ${selected} in
    "${PROFILE_LABEL_VIDEO}") selected_profile='video' ;;
    "${PROFILE_LABEL_AUDIO}") selected_profile='audio' ;;
    *) return 2 ;;
    esac

    printf -v "${output_variable}" '%s' "${selected_profile}"
}

select_output_dir() {
    local output_variable=$1
    local initial_dir=$2
    local selected_dir
    local resolved_dir
    local capture_status
    local first_error=''

    run_zenity_capture selected_dir --file-selection \
        --directory \
        --title='Choose the destination folder' \
        --filename="${initial_dir%/}/"
    capture_status=${ZENITY_STATUS}

    # Some Zenity/GTK combinations fail only when an initial folder is
    # supplied with --filename. Retry without preselection so the download
    # remains usable instead of aborting on a file-chooser regression.
    if ((capture_status == 70)); then
        first_error=${ZENITY_ERROR}
        run_zenity_capture selected_dir --file-selection \
            --directory \
            --title='Choose the destination folder'
        capture_status=${ZENITY_STATUS}

        if ((capture_status == 70)) && [[ -n ${first_error} ]]; then
            ZENITY_ERROR="${first_error}"$'\n'"${ZENITY_ERROR}"
        fi
    fi

    if ((capture_status != 0)); then
        return "${capture_status}"
    fi

    if [[ ${selected_dir} == *$'\n'* || ${selected_dir} == *$'\r'* ]]; then
        show_error 'The path must not contain line breaks.'
        return 2
    fi

    if [[ ! -d ${selected_dir} || ! -w ${selected_dir} || ! -x ${selected_dir} ]]; then
        show_error "The selected folder is not writable."
        return 2
    fi

    if ! resolved_dir=$(realpath -e -- "${selected_dir}"); then
        show_error 'The selected folder could not be resolved. It may have been removed or may contain an invalid symbolic link.'
        return 2
    fi
    printf -v "${output_variable}" '%s' "${resolved_dir}"
}

trim_field() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "${value}"
}

monitor_progress() {
    local log_file=$1
    local worker_pid=$2
    local recent=''
    local line=''
    local previous_line=''
    local percent_text=''
    local speed=''
    local eta=''
    local percent_number=0
    local candidate_percent=0
    local display_percent=0
    local message='Analyzing the webpage...'
    local postprocessing=false
    local _

    while kill -0 "${worker_pid}" 2>/dev/null; do
        # aria2c refreshes its console line with carriage returns. Converting
        # them to newlines lets us compare its readout with yt-dlp's structured
        # progress records and retain whichever appeared last in the log.
        recent=$(tail -c 65536 -- "${log_file}" 2>/dev/null |
            tr '\r' '\n' || true)
        line=$(printf '%s\n' "${recent}" |
            grep -aE '^(YTDLP_PROGRESS\||\[#.*\([0-9]{1,3}%\).*(DL|SPD):)' |
            tail -n 1 || true)

        if [[ ${postprocessing} == false ]] &&
            grep -aq '^YTDLP_POSTPROCESS|' <<<"${recent}"; then
            postprocessing=true
        fi

        if [[ ${postprocessing} == true ]]; then
            display_percent=99
            message='Finalizing the file...'
        elif [[ -n ${line} && ${line} != "${previous_line}" ]]; then
            previous_line=${line}
            percent_number=''

            if [[ ${line} == YTDLP_PROGRESS\|* ]]; then
                IFS='|' read -r _ _ percent_text speed eta <<<"${line}"

                percent_text=$(trim_field "${percent_text}")
                speed=$(trim_field "${speed}")
                eta=$(trim_field "${eta}")
                percent_number=${percent_text%%%}
                percent_number=$(trim_field "${percent_number}")
                message="Download: ${percent_text:-in progress}"
            else
                percent_text=''
                speed=''
                eta=''

                if [[ ${line} =~ \(([0-9]{1,3})%\) ]]; then
                    percent_number=${BASH_REMATCH[1]}
                    percent_text="${percent_number}%"
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

                message="aria2 download: ${percent_text:-in progress}"
            fi

            if [[ ${percent_number} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                candidate_percent=${percent_number%%.*}
                if ((candidate_percent > 98)); then
                    candidate_percent=98
                elif ((candidate_percent < 0)); then
                    candidate_percent=0
                fi
                if ((candidate_percent > display_percent)); then
                    display_percent=${candidate_percent}
                fi
            fi

            if [[ -n ${speed} && ${speed} != 'NA' && ${speed} != 'Unknown' ]]; then
                message+=" - ${speed}"
            fi
            if [[ -n ${eta} && ${eta} != 'NA' && ${eta} != 'Unknown' ]]; then
                message+=" - ${eta} remaining"
            fi
        fi

        printf '%d\n' "${display_percent}" || return 0
        printf '# %s\n' "${message}" || return 0
        sleep 0.4
    done

    printf '100\n' || true
    printf '# Finalizing the file...\n' || true
}

wait_for_worker_pgid() {
    local pgid_file=$1
    local worker_pid=$2
    local attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        if [[ -s ${pgid_file} ]]; then
            read -r WORKER_PGID <"${pgid_file}"
            if [[ ${WORKER_PGID} =~ ^[1-9][0-9]*$ ]]; then
                return 0
            fi
            return 1
        fi

        if ! kill -0 "${worker_pid}" 2>/dev/null; then
            return 1
        fi

        sleep 0.1
    done

    return 1
}

for command_name in zenity realpath dirname mktemp setsid tail grep tr; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Error: required command "%s" was not found.\n' \
            "${command_name}" >&2
        exit 127
    fi
done

SETSID_HELP=$(LC_ALL=C setsid --help 2>&1) || {
    printf 'Error: unable to inspect setsid capabilities.\n' >&2
    exit 127
}
readonly SETSID_HELP
for required_option in --fork --wait; do
    if ! grep -Eq -- \
        "^[[:space:]]*(-[^[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|$)" \
        <<<"${SETSID_HELP}"; then
        printf 'Error: this version of setsid does not support %s.\n' \
            "${required_option}" >&2
        exit 127
    fi
done

set +e
resolve_script_dir SCRIPT_DIR
resolve_status=$?
set -e
if ((resolve_status != 0)); then
    printf 'Error: unable to determine the script directory.\n' >&2
    exit 1
fi
readonly SCRIPT_DIR
readonly DOWNLOAD_SCRIPT="${SCRIPT_DIR}/download-video.sh"

if [[ ! -x ${DOWNLOAD_SCRIPT} ]]; then
    show_error 'download-video.sh is missing or not executable.'
    exit 1
fi

load_settings

URL=''
PROFILE=''
OUTPUT_DIR=''

if [[ -z ${LAST_OUTPUT_DIR} || ! -d ${LAST_OUTPUT_DIR} ]]; then
    LAST_OUTPUT_DIR=$(default_output_dir)
fi

while true; do
    set +e
    select_url URL
    status=$?
    set -e

    case ${status} in
    0)
        break
        ;;
    1)
        exit 0
        ;;
    2)
        continue
        ;;
    5)
        show_error "The URL entry dialog timed out."
        exit 1
        ;;
    *)
        show_error "Zenity could not display the URL entry dialog."
        exit 1
        ;;
    esac
done

while true; do
    set +e
    select_profile PROFILE
    status=$?
    set -e

    case ${status} in
    0)
        break
        ;;
    1)
        exit 0
        ;;
    2)
        show_error 'The selected profile is invalid.'
        continue
        ;;
    5)
        show_error 'The profile selection dialog timed out.'
        exit 1
        ;;
    *)
        show_error "Zenity could not display the profile selection dialog."
        exit 1
        ;;
    esac
done

while true; do
    set +e
    select_output_dir OUTPUT_DIR "${LAST_OUTPUT_DIR}"
    status=$?
    set -e

    case ${status} in
    0)
        break
        ;;
    1)
        exit 0
        ;;
    2)
        continue
        ;;
    5)
        show_error 'The folder selection dialog timed out.'
        exit 1
        ;;
    *)
        if [[ -n ${ZENITY_ERROR} ]]; then
            show_error "Zenity could not display the folder selection dialog.

Technical details:
${ZENITY_ERROR}"
        else
            show_error "Zenity could not display the folder selection dialog."
        fi
        exit 1
        ;;
    esac
done

set +e
save_settings "${OUTPUT_DIR}" "${PROFILE}"
settings_status=$?
set -e
if ((settings_status != 0)); then
    printf 'Warning: GUI settings could not be saved.\n' >&2
fi

mkdir -p -- "${STATE_DIR}"
chmod 700 -- "${STATE_DIR}" 2>/dev/null || true
TEMP_DIR=$(mktemp -d --tmpdir="${TMPDIR:-/tmp}" yt-dlp-gui.XXXXXXXX)
log_timestamp=$(date '+%Y%m%d-%H%M%S')
LOG_FILE=$(mktemp \
    --tmpdir="${STATE_DIR}" \
    --suffix='.log' \
    "download-${log_timestamp}-XXXXXX")
readonly LOG_FILE
readonly RESULT_FILE="${TEMP_DIR}/result.txt"
readonly PGID_FILE="${TEMP_DIR}/pgid"
: >"${LOG_FILE}"
chmod 600 -- "${LOG_FILE}"

COMMAND=(
    "${DOWNLOAD_SCRIPT}"
    --output-dir "${OUTPUT_DIR}"
    --machine-progress
    --result-file "${RESULT_FILE}"
)

case ${PROFILE} in
video)
    COMMAND+=(--mode video)
    ;;
audio)
    COMMAND+=(--mode audio)
    ;;
*)
    show_error "The internal profile '${PROFILE}' is invalid."
    exit 2
    ;;
esac

COMMAND+=(-- "${URL}")

# shellcheck disable=SC2016  # Variables are expanded by the intentionally nested shell.
LC_ALL=C setsid --fork --wait bash -c '
    pgid_file=$1
    shift
    printf "%s\n" "$$" > "${pgid_file}" || exit 125
    exec "$@"
' bash "${PGID_FILE}" "${COMMAND[@]}" >"${LOG_FILE}" 2>&1 &
WORKER_PID=$!

set +e
wait_for_worker_pgid "${PGID_FILE}" "${WORKER_PID}"
pgid_status=$?
set -e
if ((pgid_status != 0)); then
    wait "${WORKER_PID}" 2>/dev/null || true
    show_error "The download could not start.\n\nLog: ${LOG_FILE}"
    exit 1
fi

set +e
monitor_progress "${LOG_FILE}" "${WORKER_PID}" | zenity --progress \
    --title="${APP_NAME}" \
    --text='Initializing...' \
    --percentage=0 \
    --auto-close \
    --time-remaining \
    --cancel-label='Cancel' \
    --width=560
pipeline_status=("${PIPESTATUS[@]}")
set -e

# monitor_progress may finish with status 141 when Zenity closes its input
# pipe. Only Zenity's status determines cancellation, timeout, or dialog error.
zenity_status=${pipeline_status[1]:-1}
if ((zenity_status != 0)); then
    stop_worker_group
    set +e
    wait "${WORKER_PID}"
    set -e
    WORKER_PID=''

    if ((zenity_status == 1)); then
        zenity --info \
            --title="${APP_NAME}" \
            --text='The download was canceled.' \
            --no-markup \
            --width=420 || true
        exit 130
    fi

    if ((zenity_status == 5)); then
        show_error "The progress dialog timed out; the download was stopped."
        exit 1
    fi

    show_error "The progress dialog exited with status ${zenity_status}."
    exit 1
fi

set +e
wait "${WORKER_PID}"
worker_status=$?
set -e
WORKER_PID=''

if ((worker_status == 0)); then
    final_path=''
    result_path=''
    if [[ -s ${RESULT_FILE} ]]; then
        while IFS= read -r result_path || [[ -n ${result_path} ]]; do
            if [[ -n ${result_path} ]]; then
                final_path=${result_path}
            fi
        done <"${RESULT_FILE}"
    fi

    success_text='The download is complete.'
    log_notice=''
    if [[ -n ${final_path} && -f ${final_path} ]]; then
        success_text+=$'\n\nFile: '
        success_text+="${final_path}"

        if ! rm -f -- "${LOG_FILE}"; then
            log_notice=$'\n\nWarning: the successful-download log could not be deleted.\nLog: '
            log_notice+="${LOG_FILE}"
        fi
    else
        log_notice=$'\n\nWarning: the final media file could not be confirmed.\nThe diagnostic log was retained: '
        log_notice+="${LOG_FILE}"
    fi
    success_text+="${log_notice}"

    success_action=''
    run_zenity_capture success_action --question \
        --title="${APP_NAME}" \
        --text="${success_text}" \
        --no-markup \
        --extra-button='New download' \
        --ok-label='Open folder' \
        --cancel-label='Close' \
        --width=700
    success_status=${ZENITY_STATUS}

    if [[ ${success_action} == 'New download' ]]; then
        # exec does not run the EXIT trap. WORKER_PID is already empty, and the
        # completed download's temporary directory must be removed explicitly.
        # Its log was deleted only when the final media file was confirmed.
        if [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} ]]; then
            rm -rf -- "${TEMP_DIR}"
        fi
        TEMP_DIR=''

        exec "${SCRIPT_DIR}/download-video-gui.sh"
    fi

    case ${success_status} in
    0)
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "${OUTPUT_DIR}" >/dev/null 2>&1 &
        fi
        ;;
    1)
        # Close button or window close action.
        ;;
    5)
        show_error 'The completion dialog timed out.'
        ;;
    *)
        if [[ -n ${ZENITY_ERROR} ]]; then
            show_error "Zenity could not display the completion dialog.

Technical details:
${ZENITY_ERROR}"
        else
            show_error "Zenity could not display the completion dialog."
        fi
        ;;
    esac
else
    if zenity --question \
        --title="Download failed" \
        --text="The download failed with status ${worker_status}.

View the log?" \
        --no-markup \
        --ok-label='View log' \
        --cancel-label='Close' \
        --width=540; then
        zenity --text-info \
            --title="Log - ${APP_NAME} - may contain private URLs" \
            --filename="${LOG_FILE}" \
            --width=950 \
            --height=650
    fi
    exit "${worker_status}"
fi
