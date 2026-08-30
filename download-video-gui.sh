#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : download-video-gui.sh
# Purpose     : Provide the Zenity interface and supervise one download session.
# ==============================================================================

set -euo pipefail
# Keep asynchronous children in this shell's process group until an explicit
# setsid call. This guarantees that the isolated worker launch does not fork.
set +m
umask 077

readonly APP_NAME='yt-dlp aria2 downloader'
readonly PROFILE_LABEL_VIDEO='Complete video (MKV)'
readonly PROFILE_LABEL_YOUTUBE_HLS='YouTube video - Firefox cookies (HLS/MKV)'
readonly PROFILE_LABEL_AUDIO='Audio track (native format)'
readonly PROGRESS_DIALOG_WIDTH=700
readonly LOG_RETENTION_DAYS=15
readonly LOG_MAX_BYTES=8388608
readonly LOG_IDENTITY_SEPARATOR='============================================================'
readonly LOG_IDENTITY_TITLE='Diagnostic log information'
readonly ZENITY_CAPTURE_MAX_BYTES=65536
readonly GUI_CHILD_TERM_ATTEMPTS=10
readonly GUI_CHILD_KILL_ATTEMPTS=10
readonly CONFIG_MAX_BYTES=65536
readonly CONFIG_MAX_LINES=128
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
ZENITY_DIAGNOSTIC_DIR=''
PROGRESS_MONITOR_PID=''
PROGRESS_PIPE=''
PROGRESS_MONITOR_ERROR_FILE=''
PROGRESS_DIALOG_ERROR_FILE=''
RUNTIME_TMPDIR=''
WAITED_WORKER_STATUS=''
WORKER_STATUS=''
LOG_FILE=''
LOG_RETAINED=false
LOG_RETENTION_ATTEMPTED=false
LOG_TIMESTAMP=''

initialize_gui_paths() {
    local config_home=''
    local state_home=''

    if [[ -z ${HOME:-} ]]; then
        show_error 'The HOME environment variable is not defined.'
        exit 1
    fi
    if [[ ${HOME} != /* ]]; then
        show_error 'The HOME environment variable must be an absolute path.'
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
        --ok-label='Close' \
        --width=520
    if ((ZENITY_STATUS != 0)); then
        printf 'Error: %s\n' "${message}" >&2
    fi

    return 0
}

show_zenity_error() {
    local message=$1
    local diagnostic_dir=''
    local diagnostic_file=''
    local diagnostic_text=${ZENITY_ERROR}
    local forbidden_source_name=''

    if [[ -z ${diagnostic_text} ]]; then
        show_error "${message}"
        return 0
    fi

    begin_signal_registration
    if ! ZENITY_DIAGNOSTIC_DIR=$(mktemp -d \
        --tmpdir="${RUNTIME_TMPDIR}" zenity-diagnostic.XXXXXXXX); then
        ZENITY_DIAGNOSTIC_DIR=''
        finish_signal_registration
        show_error "${message}"$'\n\n''A safe diagnostic could not be prepared.'
        return 0
    fi
    finish_signal_registration
    diagnostic_dir=${ZENITY_DIAGNOSTIC_DIR}
    diagnostic_file="${diagnostic_dir}/diagnostic.txt"
    forbidden_source_name=$(printf '\170\150\141\155\163\164\145\162')
    if ! chmod 700 -- "${diagnostic_dir}" \
        || ! printf '%s\n' "${diagnostic_text}" \
        | LC_ALL=C sed -E \
            -e 's#https?://[^[:space:]]+#[REDACTED_URL]#g' \
            -e "s/${forbidden_source_name}/[REDACTED_SOURCE]/gI" \
            | tail -c "${ZENITY_CAPTURE_MAX_BYTES}" \
                >"${diagnostic_file}" \
        || ! chmod 600 -- "${diagnostic_file}"; then
        # shellcheck disable=SC2310 # Removal failure is reported internally; preserve the safe fallback dialog.
        remove_temporary_zenity_diagnostic || true
        show_error "${message}"$'\n\n''A safe diagnostic could not be prepared.'
        return 0
    fi

    show_diagnostic_dialog \
        "${APP_DIALOG_TITLE}" \
        "${message}" \
        temporary \
        "${diagnostic_dir}" \
        "${diagnostic_file}"
    # shellcheck disable=SC2310 # Removal failure is reported internally; preserve the original Zenity error flow.
    remove_temporary_zenity_diagnostic || true
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

    # With monitor mode disabled, the direct worker becomes the new session
    # leader without an intermediate setsid supervisor.
    if kill -0 -- "-${worker_pid}" 2>/dev/null; then
        WORKER_PGID=${worker_pid}
        return 0
    fi

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
        if [[ ${process_state} != Z && ${process_state} != X ]]; then
            return 0
        fi
        return 1
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
        # shellcheck disable=SC2310 # Expected failure means the worker exited.
        if process_is_running "${WORKER_PID}"; then
            return 0
        fi
        return 1
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

    # Snapshot direct children before signaling anything. If the session leader
    # exits during shutdown, its /proc children entry disappears.
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

    # Avoid a redundant direct TERM after a group member was reached. For KILL,
    # stop the registered leader as the final bounded fallback so the caller's
    # wait cannot block indefinitely.
    if [[ ${signal_name} == KILL || ${signaled_target} == false ]] \
        && [[ -n ${WORKER_PID} ]]; then
        kill "-${signal_name}" -- "${WORKER_PID}" 2>/dev/null || true
    fi
}

wait_for_worker_exit() {
    local attempts=$1
    local attempt
    local status=0
    local worker_alive=false
    local group_alive=false

    for ((attempt = 0; attempt < attempts; attempt++)); do
        worker_alive=false
        group_alive=false

        if [[ -n ${WORKER_PID} ]]; then
            # process_is_running returns false for a terminated zombie, at
            # which point wait can reap the direct worker without blocking.
            # shellcheck disable=SC2310
            if process_is_running "${WORKER_PID}"; then
                worker_alive=true
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

        # The session leader can disappear before a descendant. Retain the PGID
        # until the complete process group is gone so TERM/KILL can still reach
        # surviving yt-dlp, aria2c, FFmpeg, or Deno descendants.
        if [[ -n ${WORKER_PGID} ]]; then
            if kill -0 -- "-${WORKER_PGID}" 2>/dev/null; then
                group_alive=true
            else
                WORKER_PGID=''
            fi
        fi

        if [[ ${worker_alive} == false && ${group_alive} == false ]]; then
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

write_retained_log_identity() {
    (($# == 2)) || return 2
    local LC_ALL=C
    local output_file=$1
    local final_log_path=$2
    local final_log_name=${final_log_path##*/}

    [[ ${final_log_path} == /* &&
        ! ${final_log_path} =~ [[:cntrl:]] &&
        ${final_log_name} == download-*.log ]] || return 1
    [[ -f ${output_file} && ! -L ${output_file} ]] || return 1

    printf '\n%s\n%s\n%s\nLog file name: %s\nLog full path: %s\n%s\n' \
        "${LOG_IDENTITY_SEPARATOR}" \
        "${LOG_IDENTITY_TITLE}" \
        "${LOG_IDENTITY_SEPARATOR}" \
        "${final_log_name}" \
        "${final_log_path}" \
        "${LOG_IDENTITY_SEPARATOR}" >"${output_file}"
}

validate_private_state_directory() {
    (($# == 1)) || return 2
    local LC_ALL=C
    local output_variable=$1
    local canonical_metadata=''
    local canonical_state=''
    local state_device=''
    local state_inode=''
    local state_metadata=''
    local state_mode=''
    local state_owner=''

    [[ -d ${STATE_DIR} && ! -L ${STATE_DIR} &&
        -r ${STATE_DIR} && -w ${STATE_DIR} && -x ${STATE_DIR} ]] || return 1
    [[ ! ${STATE_DIR} =~ [[:cntrl:]] ]] || return 1
    state_metadata=$(stat -c '%d:%i:%u:%a' \
        -- "${STATE_DIR}" 2>/dev/null) || return 1
    IFS=: read -r state_device state_inode state_owner state_mode \
        <<<"${state_metadata}"
    [[ -n ${state_device} && -n ${state_inode} ]] || return 1
    [[ ${state_owner} == "${EUID}" && ${state_mode} == 700 ]] || return 1
    canonical_state=$(realpath -e -- "${STATE_DIR}" 2>/dev/null) || return 1
    [[ ${canonical_state} == /* && ! ${canonical_state} =~ [[:cntrl:]] &&
        -d ${canonical_state} && ! -L ${canonical_state} ]] || return 1
    canonical_metadata=$(stat -c '%d:%i:%u:%a' \
        -- "${canonical_state}" 2>/dev/null) || return 1
    [[ ${canonical_metadata} == "${state_metadata}" ]] || return 1

    printf -v "${output_variable}" '%s' "${canonical_state}" || return 1
    return 0
}

retained_log_identity_matches() {
    (($# == 2)) || return 2
    local candidate_file=$1
    local final_log_path=$2
    local actual_identity=''
    local expected_identity=''
    local identity_size=''
    local identities_match=false

    [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} && ! -L ${TEMP_DIR} ]] || return 1
    actual_identity=$(mktemp \
        --tmpdir="${TEMP_DIR}" log-identity-actual.XXXXXX) || return 1
    expected_identity=$(mktemp \
        --tmpdir="${TEMP_DIR}" log-identity-expected.XXXXXX) || {
        rm -f -- "${actual_identity}" || true
        return 1
    }
    # shellcheck disable=SC2310 # Failure is converted to a false predicate.
    if write_retained_log_identity \
        "${expected_identity}" "${final_log_path}" \
        && identity_size=$(stat -c '%s' -- "${expected_identity}" 2>/dev/null) \
        && [[ ${identity_size} =~ ^[0-9]+$ ]] \
        && ((identity_size > 0 && identity_size < LOG_MAX_BYTES)) \
        && tail -c "${identity_size}" -- "${candidate_file}" \
            >"${actual_identity}" 2>/dev/null; then
        if python3 -I -S - "${expected_identity}" "${actual_identity}" <<'PY_LOG_IDENTITY_COMPARE'; then
import sys

try:
    with open(sys.argv[1], "rb") as expected_file:
        expected_identity = expected_file.read()
    with open(sys.argv[2], "rb") as actual_file:
        actual_identity = actual_file.read()
except OSError:
    raise SystemExit(1) from None
raise SystemExit(0 if expected_identity == actual_identity else 1)
PY_LOG_IDENTITY_COMPARE
            identities_match=true
        fi
    fi
    rm -f -- "${actual_identity}" "${expected_identity}" || true
    [[ ${identities_match} == true ]]
}

validate_retained_log_candidate() {
    (($# == 2)) || return 2
    local output_variable=$1
    local candidate_file=$2
    local log_mode=''
    local log_owner=''
    local log_size=''
    local resolved_log=''
    local resolved_log_name=''
    local resolved_log_parent=''
    local resolved_state=''

    # shellcheck disable=SC2310 # Failure is the candidate rejection path.
    validate_private_state_directory resolved_state || return 1
    [[ -s ${candidate_file} && -f ${candidate_file} &&
        ! -L ${candidate_file} && -r ${candidate_file} ]] || return 1
    log_owner=$(stat -c '%u' -- "${candidate_file}" 2>/dev/null) || return 1
    log_mode=$(stat -c '%a' -- "${candidate_file}" 2>/dev/null) || return 1
    log_size=$(stat -c '%s' -- "${candidate_file}" 2>/dev/null) || return 1
    [[ ${log_owner} == "${EUID}" && ${log_mode} == 600 ]] || return 1
    [[ ${log_size} =~ ^[0-9]{1,10}$ ]] || return 1
    ((10#${log_size} <= LOG_MAX_BYTES)) || return 1

    resolved_log=$(realpath -e -- "${candidate_file}" 2>/dev/null) || return 1
    resolved_log_parent=${resolved_log%/*}
    resolved_log_name=${resolved_log##*/}
    [[ ${resolved_log_parent} == "${resolved_state}" &&
        ${resolved_log_name} == download-*.log ]] || return 1
    # shellcheck disable=SC2310 # Failure is the candidate rejection path.
    retained_log_identity_matches "${resolved_log}" "${resolved_log}" \
        || return 1

    printf -v "${output_variable}" '%s' "${resolved_log}" || return 1
    return 0
}

validate_temporary_diagnostic_candidate() {
    (($# == 3)) || return 2
    local output_variable=$1
    local diagnostic_dir=$2
    local candidate_file=$3
    local candidate_mode=''
    local candidate_owner=''
    local candidate_size=''
    local directory_metadata=''
    local directory_mode=''
    local directory_owner=''
    local resolved_candidate=''
    local resolved_directory=''

    [[ -d ${diagnostic_dir} && ! -L ${diagnostic_dir} ]] || return 1
    directory_metadata=$(stat -c '%u:%a' \
        -- "${diagnostic_dir}" 2>/dev/null) || return 1
    IFS=: read -r directory_owner directory_mode \
        <<<"${directory_metadata}"
    [[ ${directory_owner} == "${EUID}" && ${directory_mode} == 700 ]] \
        || return 1
    resolved_directory=$(realpath -e -- "${diagnostic_dir}" 2>/dev/null) \
        || return 1

    [[ -s ${candidate_file} && -f ${candidate_file} &&
        ! -L ${candidate_file} && -r ${candidate_file} ]] || return 1
    candidate_owner=$(stat -c '%u' -- "${candidate_file}" 2>/dev/null) \
        || return 1
    candidate_mode=$(stat -c '%a' -- "${candidate_file}" 2>/dev/null) \
        || return 1
    candidate_size=$(stat -c '%s' -- "${candidate_file}" 2>/dev/null) \
        || return 1
    [[ ${candidate_owner} == "${EUID}" && ${candidate_mode} == 600 &&
        ${candidate_size} =~ ^[0-9]{1,8}$ ]] || return 1
    ((10#${candidate_size} <= ZENITY_CAPTURE_MAX_BYTES)) || return 1
    resolved_candidate=$(realpath -e -- "${candidate_file}" 2>/dev/null) \
        || return 1
    [[ ${resolved_candidate%/*} == "${resolved_directory}" ]] || return 1

    printf -v "${output_variable}" '%s' "${resolved_candidate}" || return 1
    return 0
}

resolve_viewable_diagnostic() {
    (($# == 4)) || return 2
    local output_variable=$1
    local diagnostic_kind=$2
    local diagnostic_dir=$3
    local candidate_file=$4

    case ${diagnostic_kind} in
        retained)
            validate_retained_log_candidate \
                "${output_variable}" "${candidate_file}"
            ;;
        temporary)
            validate_temporary_diagnostic_candidate \
                "${output_variable}" "${diagnostic_dir}" "${candidate_file}"
            ;;
        *) return 2 ;;
    esac
}

view_diagnostic_file() {
    (($# == 4)) || return 2
    local diagnostic_kind=$1
    local diagnostic_dir=$2
    local candidate_file=$3
    local viewer_title=$4
    local ignored_output=''
    local viewable_file=''

    # Revalidate immediately before every viewer invocation. A private live log
    # is never an acceptable fallback when sanitization or retention failed.
    # shellcheck disable=SC2310 # Failure selects the safe user-facing fallback.
    if ! resolve_viewable_diagnostic \
        viewable_file "${diagnostic_kind}" \
        "${diagnostic_dir}" "${candidate_file}" \
        || [[ -z ${viewable_file} ]]; then
        show_error 'The diagnostic is no longer available.'
        return 0
    fi

    run_zenity_capture ignored_output --text-info \
        --title="${viewer_title}" \
        --filename="${viewable_file}" \
        --ok-label='Close' \
        --width=950 \
        --height=650
    case ${ZENITY_STATUS} in
        0 | 1) ;;
        5) show_error 'The diagnostic viewer timed out.' ;;
        *) show_error 'The diagnostic viewer could not be opened.' ;;
    esac
    return 0
}

show_diagnostic_dialog() {
    (($# == 5)) || return 2
    local title=$1
    local message=$2
    local diagnostic_kind=$3
    local diagnostic_dir=$4
    local candidate_file=$5
    local ignored_output=''
    local notice='More information is available in the private diagnostic.'
    local viewable_file=''

    if [[ ${diagnostic_kind} == retained ]]; then
        notice='More information is available in the sanitized diagnostic log.'
    fi
    # shellcheck disable=SC2310 # Failure must never expose an unsafe file.
    if ! resolve_viewable_diagnostic \
        viewable_file "${diagnostic_kind}" \
        "${diagnostic_dir}" "${candidate_file}" \
        || [[ -z ${viewable_file} ]]; then
        show_error "${message}"$'\n\n''A safe diagnostic could not be prepared.'
        return 0
    fi

    run_zenity_capture ignored_output --question \
        --title="${title}" \
        --text="${message}

${notice}" \
        --no-markup \
        --ok-label='View log' \
        --cancel-label='Close' \
        --width=560
    case ${ZENITY_STATUS} in
        0)
            view_diagnostic_file \
                "${diagnostic_kind}" "${diagnostic_dir}" \
                "${viewable_file}" \
                "Diagnostic - ${APP_NAME}"
            ;;
        1) ;;
        *)
            printf 'Error: %s\n' "${message}" >&2
            printf '%s\n' \
                'Warning: the diagnostic dialog could not be displayed.' >&2
            ;;
    esac
    return 0
}

retain_sanitized_log_impl() {
    local final_log_name=''
    local final_log_path=''
    local final_log_identity=''
    local forbidden_source_name=''
    local identity_size=''
    local identity_snapshot=''
    local log_snapshot=''
    local mv_status=0
    local payload_limit=0
    local published_log=''
    local retained_fd=''
    local retained_file=''
    local retained_file_identity=''
    local retained_file_mode=''
    local retained_file_owner=''
    local retained_file_size=''
    local final_payload_snapshot=''
    local sanitized_snapshot=''
    local sanitization_input=''
    local snapshot_size=''
    local source_identity_after=''
    local state_identity=''
    local state_identity_after=''
    local truncated_snapshot=''
    local resolved_state=''
    local -a retention_files=()

    [[ ${LOG_RETAINED} == false &&
        ${LOG_RETENTION_ATTEMPTED} == false ]] || return 0
    [[ -n ${LOG_FILE} && -s ${LOG_FILE} && -f ${LOG_FILE} &&
        ! -L ${LOG_FILE} ]] || return 0
    LOG_RETENTION_ATTEMPTED=true
    # shellcheck disable=SC2310 # Failure keeps the private live log unexposed.
    validate_private_state_directory resolved_state || return 0
    state_identity=$(stat -c '%d:%i' -- "${resolved_state}" 2>/dev/null) \
        || return 0

    log_snapshot=$(mktemp --tmpdir="${TEMP_DIR}" log-snapshot.XXXXXX) || {
        printf 'Warning: unable to create a private diagnostic snapshot.\n' >&2
        return 0
    }
    retention_files+=("${log_snapshot}")
    truncated_snapshot=$(mktemp --tmpdir="${TEMP_DIR}" log-truncated.XXXXXX) || {
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to create a private diagnostic snapshot.\n' >&2
        return 0
    }
    retention_files+=("${truncated_snapshot}")
    sanitized_snapshot=$(mktemp --tmpdir="${TEMP_DIR}" log-sanitized.XXXXXX) || {
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to create a private sanitized snapshot.\n' >&2
        return 0
    }
    retention_files+=("${sanitized_snapshot}")
    identity_snapshot=$(mktemp --tmpdir="${TEMP_DIR}" log-identity.XXXXXX) || {
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to create private log identity metadata.\n' >&2
        return 0
    }
    retention_files+=("${identity_snapshot}")
    if ! tail -c "$((LOG_MAX_BYTES + 1))" -- "${LOG_FILE}" \
        >"${log_snapshot}" 2>/dev/null; then
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to snapshot the diagnostic log.\n' >&2
        return 0
    fi
    if ! snapshot_size=$(stat -c '%s' -- "${log_snapshot}" 2>/dev/null) \
        || [[ ! ${snapshot_size} =~ ^[0-9]+$ ]]; then
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to inspect the diagnostic snapshot.\n' >&2
        return 0
    fi

    sanitization_input=${log_snapshot}
    if ((snapshot_size > LOG_MAX_BYTES)); then
        # The retained window may begin inside a secret-bearing URL. Discard
        # its first potentially partial line before redaction so no orphaned
        # URL suffix can evade a matcher that starts at the URL scheme.
        if ! tail -c "${LOG_MAX_BYTES}" -- "${log_snapshot}" \
            | sed '1d' >"${truncated_snapshot}"; then
            rm -f -- "${retention_files[@]}" || true
            printf 'Warning: unable to bound the diagnostic snapshot.\n' >&2
            return 0
        fi
        sanitization_input=${truncated_snapshot}
    fi

    forbidden_source_name=$(printf '\170\150\141\155\163\164\145\162')
    if ! LC_ALL=C sed -E \
        -e 's#https?://[^[:space:]]+#[REDACTED_URL]#g' \
        -e "s/${forbidden_source_name}/[REDACTED_SOURCE]/gI" \
        -- "${sanitization_input}" >"${sanitized_snapshot}"; then
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to sanitize the diagnostic log.\n' >&2
        return 0
    fi
    if [[ ! -s ${sanitized_snapshot} ]] \
        || ! LC_ALL=C grep -q '[^[:space:]]' -- "${sanitized_snapshot}"; then
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: the sanitized diagnostic payload has no useful content.\n' >&2
        return 0
    fi

    # Revalidate the state directory immediately before creating the staging
    # object that will later be published atomically.
    # shellcheck disable=SC2310 # Failure preserves ambiguous external state.
    if ! validate_private_state_directory resolved_state \
        || ! state_identity_after=$(stat -c '%d:%i' \
            -- "${resolved_state}" 2>/dev/null) \
        || [[ ${state_identity_after} != "${state_identity}" ]]; then
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: the diagnostic state directory changed during retention.\n' >&2
        return 0
    fi

    retained_file=$(mktemp \
        --tmpdir="${resolved_state}" \
        ".download-${LOG_TIMESTAMP:-unknown}-XXXXXXXX.log.part") || {
        rm -f -- "${retention_files[@]}" || true
        printf 'Warning: unable to create a sanitized diagnostic staging file.\n' >&2
        return 0
    }
    retained_file_identity=$(stat -c '%d:%i' \
        -- "${retained_file}" 2>/dev/null) || {
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to identify the diagnostic staging file.\n' >&2
        return 0
    }
    retained_file_owner=$(stat -c '%u' -- "${retained_file}" 2>/dev/null) \
        || retained_file_owner=''
    retained_file_mode=$(stat -c '%a' -- "${retained_file}" 2>/dev/null) \
        || retained_file_mode=''
    if [[ ! -f ${retained_file} || -L ${retained_file} ||
        ${retained_file_owner} != "${EUID}" ||
        ${retained_file_mode} != 600 ]]; then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: the diagnostic staging file is not private.\n' >&2
        return 0
    fi
    final_log_name=${retained_file##*/}
    final_log_name=${final_log_name#.}
    final_log_name=${final_log_name%.part}
    final_log_path="${resolved_state}/${final_log_name}"
    if [[ ${final_log_name} != download-*.log ||
        -e ${final_log_path} || -L ${final_log_path} ]]; then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to reserve a unique final diagnostic name.\n' >&2
        return 0
    fi

    # shellcheck disable=SC2310 # Failure selects the fail-closed cleanup path.
    if ! write_retained_log_identity \
        "${identity_snapshot}" "${final_log_path}"; then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to write final diagnostic log identity.\n' >&2
        return 0
    fi
    if ! identity_size=$(stat -c '%s' -- "${identity_snapshot}" 2>/dev/null) \
        || [[ ! ${identity_size} =~ ^[0-9]+$ ]] \
        || ((identity_size <= 0 || identity_size >= LOG_MAX_BYTES)); then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: invalid final diagnostic log identity size.\n' >&2
        return 0
    fi
    payload_limit=$((LOG_MAX_BYTES - identity_size))
    final_payload_snapshot=$(mktemp \
        --tmpdir="${TEMP_DIR}" log-final-payload.XXXXXX) || {
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to create the final diagnostic payload.\n' >&2
        return 0
    }
    retention_files+=("${final_payload_snapshot}")
    if ! tail -c "${payload_limit}" -- "${sanitized_snapshot}" \
        >"${final_payload_snapshot}" \
        || [[ ! -s ${final_payload_snapshot} ]] \
        || ! LC_ALL=C grep -q '[^[:space:]]' \
            -- "${final_payload_snapshot}"; then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: the bounded diagnostic payload has no useful content.\n' >&2
        return 0
    fi
    if ! exec {retained_fd}>"${retained_file}"; then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to open the diagnostic staging file.\n' >&2
        return 0
    fi
    if ! tail -c "${payload_limit}" -- "${final_payload_snapshot}" \
        >&"${retained_fd}" \
        || ! tail -c "${identity_size}" -- "${identity_snapshot}" \
            >&"${retained_fd}"; then
        exec {retained_fd}>&-
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to assemble the sanitized diagnostic log.\n' >&2
        return 0
    fi
    if ! exec {retained_fd}>&-; then
        rm -f -- "${retained_file}" "${retention_files[@]}" || true
        printf 'Warning: unable to close the diagnostic staging file.\n' >&2
        return 0
    fi
    rm -f -- "${retention_files[@]}" || true

    final_log_identity=$(stat -c '%d:%i' -- "${retained_file}" 2>/dev/null) \
        || final_log_identity=''
    retained_file_owner=$(stat -c '%u' -- "${retained_file}" 2>/dev/null) \
        || retained_file_owner=''
    retained_file_mode=$(stat -c '%a' -- "${retained_file}" 2>/dev/null) \
        || retained_file_mode=''
    retained_file_size=$(stat -c '%s' -- "${retained_file}" 2>/dev/null) \
        || retained_file_size=''
    # shellcheck disable=SC2310 # Failure rejects the staging candidate.
    if [[ ! -s ${retained_file} || ! -f ${retained_file} ||
        -L ${retained_file} ||
        ${final_log_identity} != "${retained_file_identity}" ||
        ${retained_file_owner} != "${EUID}" ||
        ${retained_file_mode} != 600 ||
        ! ${retained_file_size} =~ ^[0-9]{1,10}$ ]] \
        || ((10#${retained_file_size:-0} > LOG_MAX_BYTES)) \
        || ! retained_log_identity_matches \
            "${retained_file}" "${final_log_path}"; then
        rm -f -- "${retained_file}" || true
        printf 'Warning: the assembled diagnostic log failed validation.\n' >&2
        return 0
    fi

    # Revalidate the directory after assembly, then publish the completed inode
    # atomically. The source and destination identities are authoritative even
    # if mv reports interruption after completing the rename.
    # shellcheck disable=SC2310 # Failure preserves ambiguous external state.
    if ! validate_private_state_directory resolved_state \
        || ! state_identity_after=$(stat -c '%d:%i' \
            -- "${resolved_state}" 2>/dev/null) \
        || [[ ${state_identity_after} != "${state_identity}" ]]; then
        source_identity_after=$(stat -c '%d:%i' \
            -- "${retained_file}" 2>/dev/null) || source_identity_after=''
        if [[ ${source_identity_after} == "${retained_file_identity}" ]]; then
            rm -f -- "${retained_file}" || true
        fi
        printf 'Warning: the state directory changed before log publication.\n' >&2
        return 0
    fi

    mv -Tn -- "${retained_file}" "${final_log_path}" || mv_status=$?
    source_identity_after=$(stat -c '%d:%i' \
        -- "${retained_file}" 2>/dev/null) || source_identity_after=''
    final_log_identity=$(stat -c '%d:%i' \
        -- "${final_log_path}" 2>/dev/null) || final_log_identity=''
    if [[ -z ${source_identity_after} &&
        ${final_log_identity} == "${retained_file_identity}" ]]; then
        : # Publication completed; mv status is advisory after the mutation.
    else
        if [[ ${source_identity_after} == "${retained_file_identity}" ]]; then
            rm -f -- "${retained_file}" || true
        fi
        if [[ ${final_log_identity} == "${retained_file_identity}" ]]; then
            rm -f -- "${final_log_path}" || true
        fi
        printf 'Warning: unable to publish the sanitized diagnostic log atomically.\n' >&2
        if ((mv_status != 0)); then
            printf 'Warning: log publication command exited with status %d.\n' \
                "${mv_status}" >&2
        fi
        return 0
    fi

    # shellcheck disable=SC2310 # Failure removes only our identified inode.
    if [[ ${final_log_identity} != "${retained_file_identity}" ]] \
        || ! validate_retained_log_candidate \
            published_log "${final_log_path}"; then
        if [[ ${final_log_identity} == "${retained_file_identity}" ]]; then
            rm -f -- "${final_log_path}" || true
        fi
        printf 'Warning: the published diagnostic log failed final validation.\n' >&2
        return 0
    fi

    if ! rm -f -- "${LOG_FILE}"; then
        printf 'Warning: unable to remove the private live diagnostic log.\n' >&2
    fi
    LOG_FILE=${published_log}
    LOG_RETAINED=true
    return 0
}

retain_sanitized_log() {
    if [[ ${CLEANUP_DONE} == true ]]; then
        retain_sanitized_log_impl
        return 0
    fi
    begin_signal_registration
    retain_sanitized_log_impl
    finish_signal_registration
}

validated_retained_log_path() {
    (($# == 1)) || return 2
    local output_variable=$1

    [[ ${LOG_RETAINED} == true && -n ${LOG_FILE} ]] || return 1
    validate_retained_log_candidate "${output_variable}" "${LOG_FILE}"
}

view_retained_log() {
    view_diagnostic_file \
        retained '' "${LOG_FILE}" \
        "Sanitized diagnostic log - ${APP_NAME}"
    return 0
}

show_error_with_log() {
    (($# == 2)) || return 2
    local title=$1
    local message=$2
    local retained_log=''

    retain_sanitized_log
    # shellcheck disable=SC2310 # Failure must never expose the private live log.
    if ! validated_retained_log_path retained_log \
        || [[ -z ${retained_log} ]]; then
        show_error "${message}"$'\n\n''A safe diagnostic log could not be prepared.'
        return 0
    fi

    show_diagnostic_dialog \
        "${title}" "${message}" retained '' "${retained_log}"
    return 0
}

append_session_diagnostic() {
    (($# == 2)) || return 2
    local source_file=$1
    local label=$2
    local append_failed=false
    local diagnostic_snapshot=''
    local source_size=''

    [[ ${LOG_RETAINED} == false ]] || return 0
    [[ -n ${LOG_FILE} && -f ${LOG_FILE} && ! -L ${LOG_FILE} ]] || return 0
    [[ -f ${source_file} && ! -L ${source_file} && -s ${source_file} ]] \
        || return 0

    source_size=$(stat -c '%s' -- "${source_file}" 2>/dev/null) || return 0
    [[ ${source_size} =~ ^[0-9]+$ ]] || return 0
    diagnostic_snapshot=$(mktemp \
        --tmpdir="${TEMP_DIR}" session-diagnostic.XXXXXXXX) || return 0
    if ((source_size > ZENITY_CAPTURE_MAX_BYTES)); then
        # A retained tail can start inside a line. Discard that partial line
        # before it joins the live log and passes through URL sanitization.
        if ! tail -c "$((ZENITY_CAPTURE_MAX_BYTES + 1))" \
            -- "${source_file}" \
            | sed '1d' >"${diagnostic_snapshot}"; then
            rm -f -- "${diagnostic_snapshot}"
            printf 'Warning: unable to bound a private session diagnostic.\n' >&2
            return 0
        fi
    elif ! tail -c "${ZENITY_CAPTURE_MAX_BYTES}" \
        -- "${source_file}" >"${diagnostic_snapshot}"; then
        rm -f -- "${diagnostic_snapshot}"
        printf 'Warning: unable to copy a private session diagnostic.\n' >&2
        return 0
    fi

    if ! printf '\n%s\n' "${label}" >>"${LOG_FILE}"; then
        append_failed=true
    elif ! tail -c "${ZENITY_CAPTURE_MAX_BYTES}" \
        -- "${diagnostic_snapshot}" >>"${LOG_FILE}"; then
        append_failed=true
    elif ! printf '\n' >>"${LOG_FILE}"; then
        append_failed=true
    fi
    rm -f -- "${diagnostic_snapshot}"
    if [[ ${append_failed} == true ]]; then
        printf 'Warning: unable to append a private session diagnostic.\n' >&2
    fi
    return 0
}

remove_temporary_zenity_diagnostic() {
    local diagnostic_dir=${ZENITY_DIAGNOSTIC_DIR}
    local registered=false
    local removed=false

    [[ -n ${diagnostic_dir} ]] || return 0
    [[ ${diagnostic_dir} == /* && ${diagnostic_dir} != / &&
        ${diagnostic_dir##*/} == zenity-diagnostic.* ]] || {
        printf 'Warning: refusing to remove an invalid Zenity diagnostic path.\n' >&2
        return 1
    }

    if [[ ${CLEANUP_DONE} != true ]]; then
        begin_signal_registration
        registered=true
    fi
    if rm -rf -- "${diagnostic_dir}"; then
        ZENITY_DIAGNOSTIC_DIR=''
        removed=true
    else
        printf 'Warning: unable to remove the private Zenity diagnostic.\n' >&2
    fi
    if [[ ${registered} == true ]]; then
        finish_signal_registration
    fi
    [[ ${removed} == true ]]
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
        # stop_worker reaps the session leader and retains control of a
        # surviving process group until every descendant has exited.
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

    # shellcheck disable=SC2310 # EXIT cleanup remains best-effort after an internally reported removal failure.
    remove_temporary_zenity_diagnostic || true

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
    local candidate_output_dir=''
    local candidate_profile='video'
    local config_size=''
    local key=''
    local line_count=0
    local value=''

    LAST_OUTPUT_DIR=''
    LAST_PROFILE='video'

    if [[ -L ${CONFIG_DIR} || -L ${CONFIG_FILE} ||
        ! -f ${CONFIG_FILE} || ! -r ${CONFIG_FILE} ]]; then
        return 0
    fi
    if ! config_size=$(stat -c '%s' -- "${CONFIG_FILE}" 2>/dev/null) \
        || [[ ! ${config_size} =~ ^[0-9]+$ ]] \
        || ((config_size > CONFIG_MAX_BYTES)); then
        return 0
    fi

    while IFS='=' read -r key value || [[ -n ${key}${value} ]]; do
        ((line_count += 1))
        if ((line_count > CONFIG_MAX_LINES)); then
            return 0
        fi
        key=${key%$'\r'}
        value=${value%$'\r'}

        case ${key} in
            output_dir)
                candidate_output_dir=${value}
                ;;
            profile)
                case ${value} in
                    video | youtube-hls | audio)
                        candidate_profile=${value}
                        ;;
                    audio-mp3 | audio-m4a | audio-opus)
                        # Migrate settings written by versions 2.0.x.
                        candidate_profile='audio'
                        ;;
                    *)
                        candidate_profile='video'
                        ;;
                esac
                ;;
            *) ;; # Ignore settings added by future versions.
        esac
    done <"${CONFIG_FILE}"

    LAST_OUTPUT_DIR=${candidate_output_dir}
    LAST_PROFILE=${candidate_profile}
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
    local current_time=''
    local cutoff=0
    local file_identity=''
    local file_identity_after=''
    local file_mode=''
    local file_name=''
    local file_owner=''
    local log_file=''
    local modified_time=''
    local resolved_state=''
    local state_identity=''
    local state_identity_after=''

    # shellcheck disable=SC2310 # Failure preserves all existing state.
    if ! validate_private_state_directory resolved_state; then
        printf 'Warning: refusing to prune an untrusted state directory.\n' >&2
        return 0
    fi
    state_identity=$(stat -c '%d:%i' -- "${resolved_state}" 2>/dev/null) || {
        printf 'Warning: unable to identify the state directory for log cleanup.\n' >&2
        return 0
    }

    if ! current_time=$(date +%s); then
        printf 'Warning: unable to determine the current time for log cleanup.\n' >&2
        return 0
    fi
    if [[ ! ${current_time} =~ ^[0-9]+$ ]]; then
        printf 'Warning: invalid current time returned during log cleanup.\n' >&2
        return 0
    fi

    cutoff=$((current_time - LOG_RETENTION_DAYS * 24 * 60 * 60))

    for log_file in \
        "${resolved_state}"/download-*.log \
        "${resolved_state}"/.download-*.log.part; do
        [[ -f ${log_file} && ! -L ${log_file} ]] || continue
        file_name=${log_file##*/}
        case ${file_name} in
            download-*.log)
                # Compatibility: releases before atomic publication used a
                # broader final basename. Ownership and identity checks below
                # retain the previous 15-day cleanup without trusting links.
                ;;
            .download-*.log.part)
                [[ ${file_name} =~ ^\.download-[0-9]{8}-[0-9]{6}-[[:alnum:]]{8}\.log\.part$ ]] \
                    || continue
                ;;
            *) continue ;;
        esac

        file_identity=$(stat -c '%d:%i' -- "${log_file}" 2>/dev/null) \
            || file_identity=''
        file_owner=$(stat -c '%u' -- "${log_file}" 2>/dev/null) \
            || file_owner=''
        file_mode=$(stat -c '%a' -- "${log_file}" 2>/dev/null) \
            || file_mode=''
        if [[ -z ${file_identity} || ${file_owner} != "${EUID}" ||
            ${file_mode} != 600 ]]; then
            printf 'Warning: preserving an ambiguous retained log: %s\n' \
                "${log_file}" >&2
            continue
        fi
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

        if ((modified_time <= cutoff)); then
            # Revalidate both the containing directory and target inode after
            # the observation window. Preserve anything replaced or ambiguous.
            # shellcheck disable=SC2310 # Failure preserves external state.
            if ! validate_private_state_directory resolved_state \
                || ! state_identity_after=$(stat -c '%d:%i' \
                    -- "${resolved_state}" 2>/dev/null) \
                || [[ ${state_identity_after} != "${state_identity}" ]]; then
                printf 'Warning: state changed during log cleanup; stopping.\n' >&2
                return 0
            fi
            file_identity_after=$(stat -c '%d:%i' \
                -- "${log_file}" 2>/dev/null) || file_identity_after=''
            if [[ ${file_identity_after} != "${file_identity}" ]]; then
                printf 'Warning: preserving a replaced retained log: %s\n' \
                    "${log_file}" >&2
                continue
            fi
            if ! rm -f -- "${log_file}"; then
                printf 'Warning: unable to remove expired log: %s\n' \
                    "${log_file}" >&2
            fi
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

url_is_youtube() {
    (($# == 1)) || return 2
    local requested_url=$1
    local url_authority=''
    local url_host=''

    url_authority=${requested_url#*://}
    url_authority=${url_authority%%/*}
    url_authority=${url_authority%%\?*}
    url_authority=${url_authority%%\#*}
    [[ ${url_authority} != *@* ]] || return 1

    url_host=${url_authority%%:*}
    url_host=${url_host,,}
    url_host=${url_host%.}
    case ${url_host} in
        youtube.com | *.youtube.com | youtu.be | *.youtu.be | \
            youtube-nocookie.com | *.youtube-nocookie.com)
            return 0
            ;;
        *) return 1 ;;
    esac
}

select_profile() {
    local output_variable=$1
    local is_youtube=$2
    local default_video=FALSE
    local default_youtube_hls=FALSE
    local default_audio=FALSE
    local selected
    local capture_status
    local selected_profile
    local -a profile_rows=()

    [[ ${is_youtube} == true || ${is_youtube} == false ]] || return 2

    case ${LAST_PROFILE} in
        video) default_video=TRUE ;;
        youtube-hls)
            if [[ ${is_youtube} == true ]]; then
                default_youtube_hls=TRUE
            else
                default_video=TRUE
            fi
            ;;
        audio) default_audio=TRUE ;;
        *) default_video=TRUE ;;
    esac

    profile_rows=(
        "${default_video}" "${PROFILE_LABEL_VIDEO}"
    )
    if [[ ${is_youtube} == true ]]; then
        profile_rows+=(
            "${default_youtube_hls}" "${PROFILE_LABEL_YOUTUBE_HLS}"
        )
    fi
    profile_rows+=(
        "${default_audio}" "${PROFILE_LABEL_AUDIO}"
    )

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
        "${profile_rows[@]}"
    capture_status=${ZENITY_STATUS}

    if ((capture_status != 0)); then
        return "${capture_status}"
    fi

    case ${selected} in
        "${PROFILE_LABEL_VIDEO}") selected_profile='video' ;;
        "${PROFILE_LABEL_YOUTUBE_HLS}")
            [[ ${is_youtube} == true ]] || return 2
            selected_profile='youtube-hls'
            ;;
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

        # Linux exposes either the no-fork session leader or, for compatibility,
        # a direct child created by an older setsid topology. This fallback keeps
        # a delayed PGID publication from hiding the download process group.
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
    local setsid_help
    local resolve_status
    local version_output=''
    local version_value=''

    # Establish the minimal capture stack first. Once it is available, later
    # startup failures remain visible from a desktop launcher without creating
    # an artificial diagnostic log.
    for command_name in mktemp rm stat tail zenity; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            printf 'Error: required command "%s" was not found.\n' \
                "${command_name}" >&2
            exit 127
        fi
    done

    # shellcheck disable=SC2310 # Both preferred and fallback paths are checked.
    if ! resolve_runtime_tmpdir RUNTIME_TMPDIR; then
        printf '%s\n' 'Error: no usable temporary directory is available.' >&2
        exit 1
    fi
    readonly RUNTIME_TMPDIR

    initialize_gui_paths

    for command_name in bash chmod date dirname grep mkdir mkfifo mv python3 realpath sed setsid sleep; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            show_error "Required command '${command_name}' was not found."
            exit 127
        fi
    done

    setsid_help=$(LC_ALL=C setsid --help 2>&1) || {
        show_error 'Unable to inspect setsid capabilities.'
        exit 127
    }
    if ! grep -Eq -- \
        '^[[:space:]]*(-[^[:space:]]+,[[:space:]]+)?--wait([=[:space:]]|$)' \
        <<<"${setsid_help}"; then
        show_error 'This version of setsid does not support --wait.'
        exit 127
    fi

    set +e
    resolve_script_dir SCRIPT_DIR
    resolve_status=$?
    set -e
    if ((resolve_status != 0)); then
        show_error 'Unable to determine the script directory.'
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
    local is_youtube=false
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
                show_zenity_error 'Zenity could not display the URL entry dialog.'
                exit 1
                ;;
        esac
    done

    # Keep the menu preventive while the engine remains the authoritative
    # validator for direct CLI and defense-in-depth use.
    # shellcheck disable=SC2310 # Predicate status is the classification result.
    if url_is_youtube "${URL}"; then
        is_youtube=true
    fi

    while true; do
        set +e
        select_profile PROFILE "${is_youtube}"
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
                show_zenity_error 'Zenity could not display the profile selection dialog.'
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
                show_zenity_error 'Zenity could not display the folder selection dialog.'
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
    local validated_state=''

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
    if ! chmod 700 -- "${STATE_DIR}" 2>/dev/null; then
        show_error "Unable to secure the application state directory.

Path: ${STATE_DIR}"
        exit 1
    fi
    # shellcheck disable=SC2310 # Failure is a fatal pre-session trust check.
    if ! validate_private_state_directory validated_state \
        || [[ -z ${validated_state} ]]; then
        show_error "The application state directory is not private or is not owned by the current user.

Path: ${STATE_DIR}"
        exit 1
    fi
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
    PROGRESS_MONITOR_ERROR_FILE="${TEMP_DIR}/progress-monitor.stderr"
    PROGRESS_DIALOG_ERROR_FILE="${TEMP_DIR}/progress-dialog.stderr"
    if ! : >"${PROGRESS_MONITOR_ERROR_FILE}" \
        || ! : >"${PROGRESS_DIALOG_ERROR_FILE}" \
        || ! chmod 600 -- \
            "${PROGRESS_MONITOR_ERROR_FILE}" \
            "${PROGRESS_DIALOG_ERROR_FILE}"; then
        show_error 'Unable to create the private progress diagnostics.'
        exit 1
    fi
    readonly PROGRESS_MONITOR_ERROR_FILE PROGRESS_DIALOG_ERROR_FILE

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

    begin_signal_registration
    # shellcheck disable=SC2016 # Expanded by the intentionally nested shell.
    YTDLP_ARIA2_SUPERVISED_SESSION=true LC_ALL=C setsid --wait bash -c '
        pgid_file=$1
        shift
        pgid_temporary="${pgid_file}.tmp"
        printf "%s\n" "$$" >"${pgid_temporary}" || exit 125
        mv -Tf -- "${pgid_temporary}" "${pgid_file}" || exit 125
        exec "$@"
    ' bash "${PGID_FILE}" "${COMMAND[@]}" >"${LOG_FILE}" 2>&1 &
    WORKER_PID=$!
    finish_signal_registration

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
        show_error_with_log \
            'Download failed' \
            'The download could not start.'
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
        --width="${PROGRESS_DIALOG_WIDTH}" \
        <"${PROGRESS_PIPE}" 2>"${PROGRESS_DIALOG_ERROR_FILE}" &
    ZENITY_PID=$!
    bash "${PROGRESS_MONITOR}" \
        "${LOG_FILE}" "${WORKER_PID}" "${RESULT_FILE}" \
        "${PROGRESS_PROFILE}" "${OUTPUT_DIR}" \
        >"${PROGRESS_PIPE}" 2>"${PROGRESS_MONITOR_ERROR_FILE}" &
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
        append_session_diagnostic \
            "${PROGRESS_MONITOR_ERROR_FILE}" \
            'Progress monitor diagnostic:'
        show_error_with_log \
            'Download failed' \
            "The progress monitor failed with status ${monitor_status}."
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
                --ok-label='Close' \
                --width=420
            : "${ignored_output}"
            exit 130
        elif ((zenity_status == 5)); then
            append_session_diagnostic \
                "${PROGRESS_DIALOG_ERROR_FILE}" \
                'Progress dialog diagnostic:'
            show_error_with_log \
                'Download failed' \
                'The progress dialog timed out; the download was stopped.'
            exit 1
        else
            append_session_diagnostic \
                "${PROGRESS_DIALOG_ERROR_FILE}" \
                'Progress dialog diagnostic:'
            show_error_with_log \
                'Download failed' \
                "The progress dialog exited with status ${zenity_status}."
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
            show_error_with_log \
                'Download failed' \
                'The worker did not terminate cleanly.'
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
    local retained_log=''
    local success_action=''
    local success_status
    local -a success_dialog_arguments=()

    success_text+=$'\n\nFile: '
    success_text+="${final_path}"
    if rm -f -- "${LOG_FILE}"; then
        LOG_FILE=''
    else
        retain_sanitized_log
        log_notice=$'\n\nWarning: the successful-download log could not be deleted.'
    fi
    success_text+="${log_notice}"

    success_dialog_arguments=(
        --question
        --title="${APP_DIALOG_TITLE}"
        --text="${success_text}"
        --no-markup
        --extra-button='New download'
        --ok-label='Open folder'
        --cancel-label='Close'
        --width=700
    )
    # shellcheck disable=SC2310 # Availability controls the optional action.
    if validated_retained_log_path retained_log \
        && [[ -n ${retained_log} ]]; then
        success_dialog_arguments+=(--extra-button='View log')
    fi
    while true; do
        run_zenity_capture success_action "${success_dialog_arguments[@]}"
        success_status=${ZENITY_STATUS}

        if [[ ${success_action} == 'View log' ]]; then
            view_retained_log
            success_action=''
            continue
        fi
        if [[ ${success_action} == 'New download' ]]; then
            # exec does not run EXIT cleanup; remove the completed private
            # session before starting a fresh GUI lifecycle.
            if [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} ]]; then
                rm -rf -- "${TEMP_DIR}"
            fi
            TEMP_DIR=''
            exec bash "${SCRIPT_DIR}/download-video-gui.sh"
        fi
        break
    done

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
            show_zenity_error 'Zenity could not display the completion dialog.'
            ;;
    esac
}

# Convert the worker status into a confirmed success dialog or retained failure.
handle_worker_result() {
    local confirmed_path=''

    if ((WORKER_STATUS == 0)); then
        # shellcheck disable=SC2310 # Failure produces a user-facing diagnostic.
        if ! resolve_confirmed_final_path confirmed_path; then
            show_error_with_log \
                'Download failed' \
                'The downloader completed, but the final media file could not be confirmed inside the selected destination folder.'
            exit 1
        fi
        show_success_dialog "${confirmed_path}"
        return 0
    fi

    show_error_with_log \
        'Download failed' \
        "The download failed with status ${WORKER_STATUS}."
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
