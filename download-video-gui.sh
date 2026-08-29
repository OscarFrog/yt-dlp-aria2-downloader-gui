#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : download-video-gui.sh
# Purpose     : Provide the Zenity interface and supervise one download session.
# ==============================================================================

set -euo pipefail
umask 077

readonly APP_NAME='yt-dlp aria2 downloader'
readonly PROFILE_LABEL_VIDEO='Complete video (MKV)'
readonly PROFILE_LABEL_YOUTUBE_HLS='YouTube video - Firefox cookies (HLS/MKV)'
readonly PROFILE_LABEL_AUDIO='Audio track (native format)'
readonly PROGRESS_DIALOG_WIDTH=700
readonly LOG_RETENTION_DAYS=15
readonly LOG_MAX_BYTES=8388608
readonly ZENITY_CAPTURE_MAX_BYTES=65536
readonly GUI_CHILD_TERM_ATTEMPTS=10
readonly GUI_CHILD_KILL_ATTEMPTS=10
readonly PGID_WAIT_ATTEMPTS=50
readonly WORKER_TERM_ATTEMPTS=30
readonly WORKER_KILL_ATTEMPTS=20

APP_DIALOG_TITLE=${APP_NAME}
CONFIG_DIR=''
STATE_DIR=''
CONFIG_FILE=''
WORKER_PID=''
WORKER_PGID=''
TEMP_DIR=''
CLEANUP_DONE=false
DEFERRED_SIGNAL_STATUS=''
SIGNAL_REGISTRATION_ACTIVE=false
ZENITY_STATUS=0
ZENITY_ERROR=''
ZENITY_PID=''
ZENITY_CAPTURE_DIR=''
PROGRESS_MONITOR_PID=''
PROGRESS_PIPE=''
RUNTIME_TMPDIR=''
WAITED_WORKER_STATUS=''
WORKER_STATUS=''
LOG_FILE=''
LOG_RETAINED=false
LOG_TIMESTAMP=''

initialize_gui_paths() {
    local config_home=''
    local state_home=''

    if [[ -z ${HOME:-} ]]; then
        printf 'Error: the HOME environment variable is not defined.\n' >&2
        exit 1
    fi
    if [[ ${HOME} != /* ]]; then
        printf 'Error: the HOME environment variable must be an absolute path.\n' >&2
        exit 1
    fi

    config_home=${XDG_CONFIG_HOME:-${HOME}/.config}
    state_home=${XDG_STATE_HOME:-${HOME}/.local/state}
    if [[ ${config_home} != /* ]]; then
        config_home="${HOME}/.config"
    fi
    if [[ ${state_home} != /* ]]; then
        state_home="${HOME}/.local/state"
    fi

    CONFIG_DIR="${config_home}/yt-dlp-aria2-downloader"
    STATE_DIR="${state_home}/yt-dlp-aria2-downloader"
    CONFIG_FILE="${CONFIG_DIR}/gui.conf"
    readonly CONFIG_DIR STATE_DIR CONFIG_FILE
}

resolve_runtime_tmpdir() {
    local output_variable=$1
    local candidate=${TMPDIR:-/tmp}

    if [[ ! -d ${candidate} || ! -w ${candidate} || ! -x ${candidate} ]]; then
        candidate=/tmp
    fi
    if [[ ! -d ${candidate} || ! -w ${candidate} || ! -x ${candidate} ]]; then
        return 1
    fi

    printf -v "${output_variable}" '%s' "${candidate}" || return 1
    return 0
}

handle_gui_signal() {
    local status=$1

    if [[ ${SIGNAL_REGISTRATION_ACTIVE} == true ||
        -n ${DEFERRED_SIGNAL_STATUS} ]]; then
        if [[ -z ${DEFERRED_SIGNAL_STATUS} ]]; then
            DEFERRED_SIGNAL_STATUS=${status}
        fi
        return 0
    fi

    exit "${status}"
}

begin_signal_registration() {
    SIGNAL_REGISTRATION_ACTIVE=true
}

finish_signal_registration() {
    SIGNAL_REGISTRATION_ACTIVE=false
    if [[ -n ${DEFERRED_SIGNAL_STATUS} ]]; then
        exit "${DEFERRED_SIGNAL_STATUS}"
    fi
}

show_error() {
    local ignored_output=''
    local message=$1

    run_zenity_capture ignored_output --error \
        --title="${APP_DIALOG_TITLE}" \
        --text="${message}" \
        --no-markup \
        --width=520
    if ((ZENITY_STATUS != 0)); then
        printf 'Error: %s\n' "${message}" >&2
    fi

    return 0
}

run_zenity_capture() {
    local output_variable=$1
    shift
    local capture_size=''
    local error_file=''
    local output_file=''
    local output=''
    local restore_errexit=false
    local status=0

    ZENITY_ERROR=''

    ZENITY_CAPTURE_DIR=$(mktemp -d \
        --tmpdir="${RUNTIME_TMPDIR}" zenity-capture.XXXXXXXX) || {
        ZENITY_STATUS=70
        ZENITY_ERROR='Unable to create the temporary Zenity capture directory.'
        printf -v "${output_variable}" '%s' ''
        return 0
    }
    output_file="${ZENITY_CAPTURE_DIR}/stdout"
    error_file="${ZENITY_CAPTURE_DIR}/stderr"
    if ! : >"${output_file}" || ! : >"${error_file}"; then
        rm -rf -- "${ZENITY_CAPTURE_DIR}" || true
        ZENITY_CAPTURE_DIR=''
        ZENITY_STATUS=70
        ZENITY_ERROR='Unable to create the temporary Zenity capture files.'
        printf -v "${output_variable}" '%s' ''
        return 0
    fi

    begin_signal_registration
    zenity "$@" >"${output_file}" 2>"${error_file}" &
    ZENITY_PID=$!
    finish_signal_registration

    if [[ $- == *e* ]]; then
        restore_errexit=true
    fi
    set +e
    wait "${ZENITY_PID}"
    status=$?
    if [[ ${restore_errexit} == true ]]; then
        set -e
    fi
    ZENITY_PID=''

    if [[ -s ${error_file} ]]; then
        ZENITY_ERROR=$(tail -c "${ZENITY_CAPTURE_MAX_BYTES}" \
            -- "${error_file}" 2>/dev/null || true)
    fi
    if ! capture_size=$(stat -c '%s' -- "${output_file}" 2>/dev/null) \
        || [[ ! ${capture_size} =~ ^[0-9]+$ ]]; then
        status=70
        ZENITY_ERROR='Unable to inspect Zenity output.'
    elif ((capture_size > ZENITY_CAPTURE_MAX_BYTES)); then
        status=70
        ZENITY_ERROR='Zenity output exceeded the 64 KiB capture limit.'
    else
        output=$(<"${output_file}")
    fi
    rm -rf -- "${ZENITY_CAPTURE_DIR}" || true
    ZENITY_CAPTURE_DIR=''

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
        if [[ -e ./${script_source} ]]; then
            script_source="./${script_source}"
        else
            script_source=$(type -P -- "${script_source}") || return 1
        fi
    fi

    script_path=$(realpath -e -- "${script_source}") || return 1
    script_dir=$(dirname -- "${script_path}") || return 1
    printf -v "${output_variable}" '%s' "${script_dir}" || return 1
    return 0
}

recover_worker_pgid() {
    local worker_pid=$1
    local children_file="/proc/${worker_pid}/task/${worker_pid}/children"
    local children=''
    local candidate
    local -a child_pids=()

    [[ -r ${children_file} ]] || return 1
    if ! { IFS= read -r children <"${children_file}" || [[ -n ${children} ]]; } 2>/dev/null; then
        return 1
    fi
    read -r -a child_pids <<<"${children}"

    for candidate in "${child_pids[@]}"; do
        [[ ${candidate} =~ ^[1-9][0-9]*$ ]] || continue
        if kill -0 -- "-${candidate}" 2>/dev/null; then
            WORKER_PGID=${candidate}
            return 0
        fi
    done

    return 1
}

process_is_running() {
    local pid=$1
    local process_stat=''
    local process_state=''

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 -- "${pid}" 2>/dev/null || return 1

    # kill -0 also succeeds for a zombie. A zombie has already terminated and
    # must not keep the progress producer alive while Bash is waiting to reap it.
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

gui_child_is_running() {
    local pid=$1
    local process_fields=''
    local process_parent=''
    local process_stat=''
    local process_state=''

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ ! -r /proc/${pid}/stat ]]; then
        return 1
    fi
    if ! { IFS= read -r process_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
        return 1
    fi
    process_fields=${process_stat##*) }
    read -r process_state process_parent _ <<<"${process_fields}"
    [[ ${process_parent} == "${BASHPID}" &&
        ${process_state} != Z && ${process_state} != X ]]
}

signal_gui_children() {
    local signal_name=$1
    local child_pid=''

    for child_pid in "${ZENITY_PID}" "${PROGRESS_MONITOR_PID}"; do
        [[ -n ${child_pid} ]] || continue
        # Only signal a still-running direct child. An exited/reaped PID must
        # never be allowed to target an unrelated process after PID reuse.
        # shellcheck disable=SC2310 # Predicate used to guard signal delivery.
        if gui_child_is_running "${child_pid}"; then
            kill "-${signal_name}" -- "${child_pid}" 2>/dev/null || true
        fi
    done
}

gui_children_are_running() {
    # shellcheck disable=SC2310 # Both predicates intentionally probe liveness.
    if [[ -n ${ZENITY_PID} ]] && gui_child_is_running "${ZENITY_PID}"; then
        return 0
    fi
    # shellcheck disable=SC2310 # Both predicates intentionally probe liveness.
    if [[ -n ${PROGRESS_MONITOR_PID} ]] \
        && gui_child_is_running "${PROGRESS_MONITOR_PID}"; then
        return 0
    fi
    return 1
}

reap_gui_children() {
    local child_pid=''

    for child_pid in "${ZENITY_PID}" "${PROGRESS_MONITOR_PID}"; do
        [[ -n ${child_pid} ]] || continue
        set +e
        wait "${child_pid}" 2>/dev/null
        set -e
    done
    ZENITY_PID=''
    PROGRESS_MONITOR_PID=''
}

stop_gui_children() {
    local attempt

    signal_gui_children TERM
    for ((attempt = 0; attempt < GUI_CHILD_TERM_ATTEMPTS; attempt++)); do
        # shellcheck disable=SC2310 # This is the bounded shutdown predicate.
        if ! gui_children_are_running; then
            reap_gui_children
            return 0
        fi
        sleep 0.1
    done

    signal_gui_children KILL
    for ((attempt = 0; attempt < GUI_CHILD_KILL_ATTEMPTS; attempt++)); do
        # shellcheck disable=SC2310 # This is the bounded shutdown predicate.
        if ! gui_children_are_running; then
            reap_gui_children
            return 0
        fi
        sleep 0.1
    done

    return 1
}

worker_tree_alive() {
    if [[ -n ${WORKER_PGID} ]] \
        && kill -0 -- "-${WORKER_PGID}" 2>/dev/null; then
        return 0
    fi
    if [[ -n ${WORKER_PID} ]]; then
        process_is_running "${WORKER_PID}"
        return
    fi
    return 1
}

signal_worker_tree() {
    local signal_name=$1
    local children_file
    local children=''
    local candidate
    local signaled_target=false
    local group_signal_succeeded=false
    local -a child_pids=()

    if [[ -z ${WORKER_PGID} && -n ${WORKER_PID} ]]; then
        # A missing PGID is expected while the setsid child is not yet visible.
        # shellcheck disable=SC2310
        recover_worker_pgid "${WORKER_PID}" || true
    fi

    # Snapshot direct children before signaling anything. If the setsid
    # supervisor exits during shutdown, its /proc children entry disappears.
    if [[ -n ${WORKER_PID} ]]; then
        children_file="/proc/${WORKER_PID}/task/${WORKER_PID}/children"
        if [[ -r ${children_file} ]]; then
            children=''
            if { IFS= read -r children <"${children_file}" || [[ -n ${children} ]]; } 2>/dev/null; then
                read -r -a child_pids <<<"${children}"
            fi
        fi
    fi

    # Do not treat a successful existence probe as successful delivery.
    # kill itself is the authoritative, race-free result.
    if [[ -n ${WORKER_PGID} ]]; then
        if kill "-${signal_name}" -- "-${WORKER_PGID}" 2>/dev/null; then
            signaled_target=true
            group_signal_succeeded=true
        else
            WORKER_PGID=''
        fi
    fi

    # Target each direct child as a process group and then as an individual PID.
    # This remains effective if PGID publication was stale or the group signal
    # raced with process creation.
    for candidate in "${child_pids[@]}"; do
        [[ ${candidate} =~ ^[1-9][0-9]*$ ]] || continue

        if [[ ${group_signal_succeeded} == true &&
            ${candidate} == "${WORKER_PGID}" ]]; then
            continue
        fi

        if kill "-${signal_name}" -- "-${candidate}" 2>/dev/null \
            || kill "-${signal_name}" -- "${candidate}" 2>/dev/null; then
            signaled_target=true
        fi
    done

    # For TERM, keep setsid --wait alive when a child was reached so it can reap
    # the child and propagate its status. For KILL, stop the supervisor as the
    # final bounded fallback so the caller's wait cannot block indefinitely.
    if [[ ${signal_name} == KILL || ${signaled_target} == false ]] \
        && [[ -n ${WORKER_PID} ]]; then
        kill "-${signal_name}" -- "${WORKER_PID}" 2>/dev/null || true
    fi
}

wait_for_worker_exit() {
    local attempts=$1
    local attempt
    local status=0
    local supervisor_alive=false
    local group_alive=false

    for ((attempt = 0; attempt < attempts; attempt++)); do
        supervisor_alive=false
        group_alive=false

        if [[ -n ${WORKER_PID} ]]; then
            # process_is_running returns false for a terminated zombie, at
            # which point wait can reap the direct supervisor without blocking.
            # shellcheck disable=SC2310
            if process_is_running "${WORKER_PID}"; then
                supervisor_alive=true
            else
                set +e
                wait "${WORKER_PID}" 2>/dev/null
                status=$?
                set -e
                if [[ -z ${WAITED_WORKER_STATUS} ]]; then
                    WAITED_WORKER_STATUS=${status}
                fi
                WORKER_PID=''
            fi
        fi

        # The setsid supervisor can disappear before a grandchild. Retain the
        # PGID until the complete process group is gone so TERM/KILL can still
        # reach surviving yt-dlp, aria2c, FFmpeg, or Deno descendants.
        if [[ -n ${WORKER_PGID} ]]; then
            if kill -0 -- "-${WORKER_PGID}" 2>/dev/null; then
                group_alive=true
            else
                WORKER_PGID=''
            fi
        fi

        if [[ ${supervisor_alive} == false && ${group_alive} == false ]]; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

stop_worker() {
    # worker_tree_alive is a predicate: status 1 means nothing remains.
    # shellcheck disable=SC2310
    if ! worker_tree_alive; then
        # shellcheck disable=SC2310
        wait_for_worker_exit 1 || true
        return 0
    fi

    signal_worker_tree TERM
    # wait_for_worker_exit is a bounded predicate with explicit status handling.
    # shellcheck disable=SC2310
    if wait_for_worker_exit "${WORKER_TERM_ATTEMPTS}"; then
        return 0
    fi

    signal_worker_tree KILL
    wait_for_worker_exit "${WORKER_KILL_ATTEMPTS}"
}

retain_sanitized_log() {
    local forbidden_source_name=''
    local retained_file=''

    [[ ${LOG_RETAINED} == false ]] || return 0
    [[ -n ${LOG_FILE} && -f ${LOG_FILE} && ! -L ${LOG_FILE} ]] || return 0
    [[ -d ${STATE_DIR} && ! -L ${STATE_DIR} ]] || return 0

    retained_file=$(mktemp \
        --tmpdir="${STATE_DIR}" \
        --suffix='.log' \
        "download-${LOG_TIMESTAMP:-unknown}-XXXXXX") || {
        printf 'Warning: unable to create a sanitized diagnostic log.\n' >&2
        return 0
    }
    forbidden_source_name=$(printf '\170\150\141\155\163\164\145\162')
    if ! tail -c "${LOG_MAX_BYTES}" -- "${LOG_FILE}" 2>/dev/null \
        | sed -E \
            -e 's#https?://[^[:space:]]+#[REDACTED_URL]#g' \
            -e "s/${forbidden_source_name}/[REDACTED_SOURCE]/gI" \
            >"${retained_file}"; then
        rm -f -- "${retained_file}" || true
        printf 'Warning: unable to sanitize the diagnostic log.\n' >&2
        return 0
    fi
    if ! chmod 600 -- "${retained_file}"; then
        rm -f -- "${retained_file}" || true
        printf 'Warning: unable to secure the sanitized diagnostic log.\n' >&2
        return 0
    fi
    rm -f -- "${LOG_FILE}" || true
    LOG_FILE=${retained_file}
    LOG_RETAINED=true
    return 0
}

cleanup() {
    local status=$?

    # Cleanup is a short critical section. Ignore additional termination
    # signals so a second signal cannot interrupt worker shutdown midway.
    trap - EXIT
    trap '' HUP INT TERM

    if [[ ${CLEANUP_DONE} == true ]]; then
        exit "${status}"
    fi
    CLEANUP_DONE=true

    # Close every registered dialog and progress producer first so no GUI child
    # can delay worker cancellation or keep a private capture file open.
    signal_gui_children TERM

    if [[ -n ${WORKER_PID} || -n ${WORKER_PGID} ]]; then
        # stop_worker reaps the supervisor and retains control of a surviving
        # process group until every descendant has exited.
        # shellcheck disable=SC2310
        if ! stop_worker; then
            printf 'Warning: the worker group did not terminate after SIGKILL; cleanup will continue.\n' >&2
            WORKER_PID=''
            WORKER_PGID=''
        fi
    fi

    if [[ -n ${ZENITY_PID} || -n ${PROGRESS_MONITOR_PID} ]]; then
        # shellcheck disable=SC2310 # Failure is reported after bounded KILL.
        if ! stop_gui_children; then
            printf 'Warning: a GUI child did not terminate after SIGKILL.\n' >&2
        fi
    fi

    retain_sanitized_log

    if [[ -n ${ZENITY_CAPTURE_DIR} && -d ${ZENITY_CAPTURE_DIR} ]]; then
        rm -rf -- "${ZENITY_CAPTURE_DIR}" || true
    fi
    ZENITY_CAPTURE_DIR=''

    if [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} ]]; then
        rm -rf -- "${TEMP_DIR}" || true
    fi

    exit "${status}"
}

load_settings() {
    local key
    local value

    LAST_OUTPUT_DIR=''
    LAST_PROFILE='video'

    if [[ ! -r ${CONFIG_FILE} ]]; then
        return 0
    fi

    while IFS='=' read -r key value || [[ -n ${key}${value} ]]; do
        key=${key%$'\r'}
        value=${value%$'\r'}

        case ${key} in
            output_dir)
                LAST_OUTPUT_DIR=${value}
                ;;
            profile)
                case ${value} in
                    video | youtube-hls | audio)
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

    if [[ -L ${CONFIG_DIR} ]]; then
        return 1
    fi
    mkdir -p -- "${CONFIG_DIR}" || return 1
    [[ ! -L ${CONFIG_DIR} ]] || return 1
    chmod 700 -- "${CONFIG_DIR}" 2>/dev/null || true

    temporary_file=$(mktemp --tmpdir="${CONFIG_DIR}" gui.conf.XXXXXX) || return 1
    if ! {
        printf 'output_dir=%s\n' "${output_dir}"
        printf 'profile=%s\n' "${profile}"
    } >"${temporary_file}"; then
        rm -f -- "${temporary_file}" || true
        return 1
    fi
    if ! chmod 600 -- "${temporary_file}"; then
        rm -f -- "${temporary_file}" || true
        return 1
    fi
    if ! mv -Tf -- "${temporary_file}" "${CONFIG_FILE}"; then
        rm -f -- "${temporary_file}" || true
        return 1
    fi
}

prune_old_logs() {
    local current_time
    local cutoff
    local log_file
    local modified_time

    if ! current_time=$(date +%s); then
        printf 'Warning: unable to determine the current time for log cleanup.\n' >&2
        return 0
    fi
    if [[ ! ${current_time} =~ ^[0-9]+$ ]]; then
        printf 'Warning: invalid current time returned during log cleanup.\n' >&2
        return 0
    fi

    cutoff=$((current_time - LOG_RETENTION_DAYS * 24 * 60 * 60))

    for log_file in "${STATE_DIR}"/download-*.log; do
        # Remove only regular logs created by this application. Symlinks and
        # unrelated files in the state directory are deliberately ignored.
        [[ -f ${log_file} && ! -L ${log_file} ]] || continue

        if ! modified_time=$(stat -c '%Y' -- "${log_file}" 2>/dev/null); then
            printf 'Warning: unable to inspect retained log: %s\n' \
                "${log_file}" >&2
            continue
        fi
        if [[ ! ${modified_time} =~ ^[0-9]+$ ]]; then
            printf 'Warning: invalid timestamp for retained log: %s\n' \
                "${log_file}" >&2
            continue
        fi

        if ((modified_time <= cutoff)) \
            && ! rm -f -- "${log_file}"; then
            printf 'Warning: unable to remove expired log: %s\n' \
                "${log_file}" >&2
        fi
    done

    return 0
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
    local entered_authority=''
    local capture_status

    run_zenity_capture entered_url --entry \
        --title="${APP_DIALOG_TITLE}" \
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

    if [[ ! ${entered_url} =~ ^https?://[^[:space:]]+$ ]]; then
        show_error "The URL must start with http:// or https://."
        return 2
    fi
    entered_authority=${entered_url#*://}
    entered_authority=${entered_authority%%/*}
    entered_authority=${entered_authority%%\?*}
    entered_authority=${entered_authority%%\#*}
    if [[ ${entered_authority} == *@* ]]; then
        show_error 'URLs containing user information are not accepted.'
        return 2
    fi

    printf -v "${output_variable}" '%s' "${entered_url}" || return 70
    return 0
}

select_profile() {
    local output_variable=$1
    local default_video=FALSE
    local default_youtube_hls=FALSE
    local default_audio=FALSE
    local selected
    local capture_status
    local selected_profile

    case ${LAST_PROFILE} in
        video) default_video=TRUE ;;
        youtube-hls) default_youtube_hls=TRUE ;;
        audio) default_audio=TRUE ;;
        *) default_video=TRUE ;;
    esac

    run_zenity_capture selected --list \
        --radiolist \
        --title="${APP_DIALOG_TITLE}" \
        --text='Choose the output type:' \
        --column='Select' \
        --column='Profile' \
        --hide-header \
        --print-column=2 \
        --ok-label='Continue' \
        --cancel-label='Cancel' \
        --width=620 \
        --height=305 \
        "${default_video}" "${PROFILE_LABEL_VIDEO}" \
        "${default_youtube_hls}" "${PROFILE_LABEL_YOUTUBE_HLS}" \
        "${default_audio}" "${PROFILE_LABEL_AUDIO}"
    capture_status=${ZENITY_STATUS}

    if ((capture_status != 0)); then
        return "${capture_status}"
    fi

    case ${selected} in
        "${PROFILE_LABEL_VIDEO}") selected_profile='video' ;;
        "${PROFILE_LABEL_YOUTUBE_HLS}") selected_profile='youtube-hls' ;;
        "${PROFILE_LABEL_AUDIO}") selected_profile='audio' ;;
        *) return 2 ;;
    esac

    printf -v "${output_variable}" '%s' "${selected_profile}" || return 70
    return 0
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
    printf -v "${output_variable}" '%s' "${resolved_dir}" || return 70
    return 0
}

trim_field() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "${value}"
}

wait_for_worker_pgid() {
    local pgid_file=$1
    local worker_pid=$2
    local attempt
    local candidate=''

    for ((attempt = 0; attempt < PGID_WAIT_ATTEMPTS; attempt++)); do
        if [[ -f ${pgid_file} ]]; then
            candidate=''
            if { IFS= read -r candidate <"${pgid_file}"; } 2>/dev/null \
                && [[ ${candidate} =~ ^[1-9][0-9]*$ ]] \
                && kill -0 -- "-${candidate}" 2>/dev/null; then
                WORKER_PGID=${candidate}
                return 0
            fi
        fi

        # Linux exposes the direct child created by setsid --fork. This fallback
        # prevents a delayed or failed PGID-file publication from making the GUI
        # lose control of the download process group.
        # A failed probe is normal until the setsid child becomes visible.
        # shellcheck disable=SC2310
        if recover_worker_pgid "${worker_pid}"; then
            return 0
        fi

        # process_is_running is deliberately used as a probe.
        # shellcheck disable=SC2310
        if ! process_is_running "${worker_pid}"; then
            return 1
        fi

        sleep 0.1
    done

    return 1
}

# Validate host capabilities and resolve the adjacent production scripts.
initialize_gui_environment() {
    local command_name
    local required_option
    local setsid_help
    local resolve_status
    local version_output=''
    local version_value=''

    initialize_gui_paths

    for command_name in bash chmod date dirname grep mkdir mkfifo mktemp mv realpath rm sed setsid sleep stat tail zenity; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            printf 'Error: required command "%s" was not found.\n' \
                "${command_name}" >&2
            exit 127
        fi
    done

    setsid_help=$(LC_ALL=C setsid --help 2>&1) || {
        printf 'Error: unable to inspect setsid capabilities.\n' >&2
        exit 127
    }
    for required_option in --fork --wait; do
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|$)" \
            <<<"${setsid_help}"; then
            printf 'Error: this version of setsid does not support %s.\n' \
                "${required_option}" >&2
            exit 127
        fi
    done

    # shellcheck disable=SC2310 # Both preferred and fallback paths are checked.
    if ! resolve_runtime_tmpdir RUNTIME_TMPDIR; then
        printf '%s\n' 'Error: no usable temporary directory is available.' >&2
        exit 1
    fi
    readonly RUNTIME_TMPDIR

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
    readonly PROGRESS_MONITOR="${SCRIPT_DIR}/progress-monitor.sh"

    if [[ ! -x ${DOWNLOAD_SCRIPT} ]]; then
        show_error 'download-video.sh is missing or not executable.'
        exit 1
    fi
    if [[ ! -r ${PROGRESS_MONITOR} ]]; then
        show_error 'progress-monitor.sh is missing or not readable.'
        exit 1
    fi

    if version_output=$("${DOWNLOAD_SCRIPT}" --version 2>/dev/null); then
        version_value=${version_output##* }
        if [[ ${version_value} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            APP_DIALOG_TITLE="${APP_NAME} — v${version_value}"
        fi
    fi
    readonly APP_DIALOG_TITLE

    load_settings
}

# Collect and persist one valid URL/profile/destination request.
collect_download_request() {
    local status
    local settings_status

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
            0) break ;;
            1) exit 0 ;;
            2) continue ;;
            5)
                show_error 'The URL entry dialog timed out.'
                exit 1
                ;;
            *)
                show_error 'Zenity could not display the URL entry dialog.'
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
            0) break ;;
            1) exit 0 ;;
            2)
                show_error 'The selected profile is invalid.'
                continue
                ;;
            5)
                show_error 'The profile selection dialog timed out.'
                exit 1
                ;;
            *)
                show_error 'Zenity could not display the profile selection dialog.'
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
            0) break ;;
            1) exit 0 ;;
            2) continue ;;
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
                    show_error 'Zenity could not display the folder selection dialog.'
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
}

# Create the private session state and build the engine command.
prepare_gui_session() {
    if [[ -L ${STATE_DIR} ]]; then
        show_error "The application state path must not be a symbolic link.

Path: ${STATE_DIR}"
        exit 1
    fi
    if ! mkdir -p -- "${STATE_DIR}"; then
        show_error "Unable to create the application state directory.

Path: ${STATE_DIR}"
        exit 1
    fi
    chmod 700 -- "${STATE_DIR}" 2>/dev/null || true
    prune_old_logs
    if ! TEMP_DIR=$(mktemp -d --tmpdir="${RUNTIME_TMPDIR}" yt-dlp-gui.XXXXXXXX); then
        show_error 'Unable to create the temporary working directory.'
        exit 1
    fi
    if ! LOG_TIMESTAMP=$(date '+%Y%m%d-%H%M%S'); then
        show_error 'Unable to determine the timestamp for the diagnostic log.'
        exit 1
    fi
    if ! LOG_FILE=$(mktemp \
        --tmpdir="${TEMP_DIR}" \
        'live-download-log.XXXXXXXX'); then
        show_error 'Unable to create the private live diagnostic log.'
        exit 1
    fi
    readonly RESULT_FILE="${TEMP_DIR}/result.txt"
    readonly PGID_FILE="${TEMP_DIR}/pgid"
    PROGRESS_PIPE="${TEMP_DIR}/progress.pipe"
    readonly PROGRESS_PIPE
    if ! mkfifo -m 600 -- "${PROGRESS_PIPE}"; then
        show_error 'Unable to create the private progress pipe.'
        exit 1
    fi
    if ! chmod 600 -- "${LOG_FILE}"; then
        show_error 'Unable to secure the private live diagnostic log.'
        exit 1
    fi

    readonly URL_FILE="${TEMP_DIR}/url.txt"
    if ! printf '%s\n' "${URL}" >"${URL_FILE}" \
        || ! chmod 600 -- "${URL_FILE}"; then
        show_error 'Unable to create the private URL transfer file.'
        exit 1
    fi
    URL=''

    PROGRESS_PROFILE=''
    COMMAND=(
        "${DOWNLOAD_SCRIPT}"
        --output-dir "${OUTPUT_DIR}"
        --machine-progress
        --result-file "${RESULT_FILE}"
        --url-file "${URL_FILE}"
    )

    case ${PROFILE} in
        video)
            COMMAND+=(--mode video)
            PROGRESS_PROFILE='video'
            ;;
        youtube-hls)
            COMMAND+=(--mode video --youtube-hls-firefox)
            PROGRESS_PROFILE='video'
            ;;
        audio)
            COMMAND+=(--mode audio)
            PROGRESS_PROFILE='audio'
            ;;
        *)
            show_error "The internal profile '${PROFILE}' is invalid."
            exit 2
            ;;
    esac
}

# Start the isolated engine session and require a controllable process group.
start_download_worker() {
    local pgid_status

    # shellcheck disable=SC2016 # Expanded by the intentionally nested shell.
    YTDLP_ARIA2_SUPERVISED_SESSION=true LC_ALL=C setsid --fork --wait bash -c '
        pgid_file=$1
        shift
        pgid_temporary="${pgid_file}.tmp"
        printf "%s\n" "$$" >"${pgid_temporary}" || exit 125
        mv -Tf -- "${pgid_temporary}" "${pgid_file}" || exit 125
        exec "$@"
    ' bash "${PGID_FILE}" "${COMMAND[@]}" >"${LOG_FILE}" 2>&1 &
    WORKER_PID=$!

    set +e
    wait_for_worker_pgid "${PGID_FILE}" "${WORKER_PID}"
    pgid_status=$?
    set -e
    if ((pgid_status != 0)); then
        # shellcheck disable=SC2310
        if ! stop_worker; then
            printf 'Warning: the failed worker could not be reaped after SIGKILL.\n' >&2
            WORKER_PID=''
            WORKER_PGID=''
        fi
        retain_sanitized_log
        show_error "The download could not start."$'\n\n'"Log: ${LOG_FILE}"
        exit 1
    fi
}

# Run the progress pipeline, map dialog outcomes, and reap the engine worker.
run_progress_dialog() {
    local ignored_output=''
    local monitor_status=0
    local zenity_status=0
    local worker_status=''

    begin_signal_registration
    zenity --progress \
        --title="${APP_DIALOG_TITLE}" \
        --text='Initializing...' \
        --percentage=0 \
        --auto-close \
        --cancel-label='Cancel' \
        --width="${PROGRESS_DIALOG_WIDTH}" <"${PROGRESS_PIPE}" &
    ZENITY_PID=$!
    bash "${PROGRESS_MONITOR}" \
        "${LOG_FILE}" "${WORKER_PID}" "${RESULT_FILE}" \
        "${PROGRESS_PROFILE}" "${OUTPUT_DIR}" >"${PROGRESS_PIPE}" &
    PROGRESS_MONITOR_PID=$!
    finish_signal_registration

    set +e
    wait "${ZENITY_PID}"
    zenity_status=$?
    set -e
    ZENITY_PID=''

    set +e
    wait "${PROGRESS_MONITOR_PID}"
    monitor_status=$?
    set -e
    PROGRESS_MONITOR_PID=''

    # Zenity closing its input is normal; other monitor failures are technical.
    if ((monitor_status != 0)); then
        # shellcheck disable=SC2310
        if ! stop_worker; then
            printf 'Warning: the worker could not be reaped after a monitor failure.\n' >&2
            WORKER_PID=''
            WORKER_PGID=''
        fi
        retain_sanitized_log
        show_error "The progress monitor failed with status ${monitor_status}."$'\n\n'"Log: ${LOG_FILE}"
        exit 1
    fi
    if ((zenity_status != 0)); then
        # shellcheck disable=SC2310
        if stop_worker; then
            worker_status=${WAITED_WORKER_STATUS:-143}
        else
            printf 'Warning: the canceled worker did not terminate after SIGKILL.\n' >&2
            worker_status=143
            WORKER_PID=''
            WORKER_PGID=''
        fi

        if ((zenity_status == 1 && worker_status == 0)); then
            zenity_status=0
        elif ((zenity_status == 1)); then
            run_zenity_capture ignored_output --info \
                --title="${APP_DIALOG_TITLE}" \
                --text='The download was canceled.' \
                --no-markup \
                --width=420
            exit 130
        elif ((zenity_status == 5)); then
            show_error 'The progress dialog timed out; the download was stopped.'
            exit 1
        else
            show_error "The progress dialog exited with status ${zenity_status}."
            exit 1
        fi
    fi

    if [[ -z ${worker_status} ]]; then
        # shellcheck disable=SC2310
        if wait_for_worker_exit 100; then
            worker_status=${WAITED_WORKER_STATUS}
        else
            # shellcheck disable=SC2310
            if ! stop_worker; then
                printf 'Warning: the worker did not terminate after the progress dialog closed.\n' >&2
                WORKER_PID=''
                WORKER_PGID=''
            fi
            retain_sanitized_log
            show_error "The worker did not terminate cleanly."$'\n\n'"Log: ${LOG_FILE}"
            exit 1
        fi
    fi

    WORKER_STATUS=${worker_status}
}

# Resolve the final result and prove that it belongs to the selected directory.
resolve_confirmed_final_path() {
    (($# == 1)) || return 2
    local output_name=$1
    local candidate=''
    local result_path=''
    local resolved=''

    if [[ -s ${RESULT_FILE} ]]; then
        while IFS= read -r result_path || [[ -n ${result_path} ]]; do
            if [[ -n ${result_path} ]]; then
                candidate=${result_path}
            fi
        done <"${RESULT_FILE}"
    fi

    if [[ -n ${candidate} ]]; then
        resolved=$(realpath -e -- "${candidate}" 2>/dev/null || true)
    fi
    [[ -n ${resolved} && -f ${resolved} ]] || return 1
    [[ ${OUTPUT_DIR} == / || ${resolved} == "${OUTPUT_DIR}"/* ]] || return 1

    printf -v "${output_name}" '%s' "${resolved}"
}

# Present the successful result and handle open-folder/new-download actions.
show_success_dialog() {
    (($# == 1)) || return 2
    local final_path=$1
    local success_text='The download is complete.'
    local log_notice=''
    local success_action=''
    local success_status

    success_text+=$'\n\nFile: '
    success_text+="${final_path}"
    if rm -f -- "${LOG_FILE}"; then
        LOG_FILE=''
    else
        retain_sanitized_log
        log_notice=$'\n\nWarning: the successful-download log could not be deleted.\nLog: '
        log_notice+="${LOG_FILE}"
    fi
    success_text+="${log_notice}"

    run_zenity_capture success_action --question \
        --title="${APP_DIALOG_TITLE}" \
        --text="${success_text}" \
        --no-markup \
        --extra-button='New download' \
        --ok-label='Open folder' \
        --cancel-label='Close' \
        --width=700
    success_status=${ZENITY_STATUS}

    if [[ ${success_action} == 'New download' ]]; then
        # exec does not run EXIT cleanup; remove the completed private session.
        if [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} ]]; then
            rm -rf -- "${TEMP_DIR}"
        fi
        TEMP_DIR=''
        exec bash "${SCRIPT_DIR}/download-video-gui.sh"
    fi

    case ${success_status} in
        0)
            if command -v xdg-open >/dev/null 2>&1; then
                xdg-open "${OUTPUT_DIR}" >/dev/null 2>&1 &
            fi
            ;;
        1) ;;
        5)
            show_error 'The completion dialog timed out.'
            ;;
        *)
            if [[ -n ${ZENITY_ERROR} ]]; then
                show_error "Zenity could not display the completion dialog.

Technical details:
${ZENITY_ERROR}"
            else
                show_error 'Zenity could not display the completion dialog.'
            fi
            ;;
    esac
}

# Convert the worker status into a confirmed success dialog or retained failure.
handle_worker_result() {
    local confirmed_path=''
    # shellcheck disable=SC2034 # Assigned indirectly by run_zenity_capture.
    local ignored_output=''
    # shellcheck disable=SC2034 # Assigned indirectly by run_zenity_capture.
    local question_output=''

    if ((WORKER_STATUS == 0)); then
        # shellcheck disable=SC2310 # Failure produces a user-facing diagnostic.
        if ! resolve_confirmed_final_path confirmed_path; then
            retain_sanitized_log
            show_error "The downloader completed, but the final media file could not be confirmed inside the selected destination folder."$'\n\n'"Log: ${LOG_FILE}"
            exit 1
        fi
        show_success_dialog "${confirmed_path}"
        return 0
    fi

    retain_sanitized_log
    run_zenity_capture question_output --question \
        --title='Download failed' \
        --text="The download failed with status ${WORKER_STATUS}.

View the log?" \
        --no-markup \
        --ok-label='View log' \
        --cancel-label='Close' \
        --width=540
    if ((ZENITY_STATUS == 0)); then
        run_zenity_capture ignored_output --text-info \
            --title="Sanitized diagnostic log - ${APP_NAME}" \
            --filename="${LOG_FILE}" \
            --width=950 \
            --height=650
    fi
    exit "${WORKER_STATUS}"
}

main() {
    trap cleanup EXIT
    trap 'handle_gui_signal 129' HUP
    trap 'handle_gui_signal 130' INT
    trap 'handle_gui_signal 143' TERM

    initialize_gui_environment
    collect_download_request
    prepare_gui_session
    start_download_worker
    run_progress_dialog
    handle_worker_result

}

main "$@"
