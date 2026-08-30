#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/test-runner.sh
# Purpose     : Supervise timed validation children and their process groups.
# ==============================================================================

# This sourced library deliberately leaves shell options and traps to its
# caller. Child commands run in dedicated sessions so a failing test, runner
# interruption, or timeout can terminate the supervised process group.

TEST_RUNNER_LOG_DIR=''
TEST_RUNNER_CHILD_PIDS=()
TEST_RUNNER_CHILD_PGIDS=()
TEST_RUNNER_CHILD_COMPLETIONS=()
TEST_RUNNER_CHILD_TOKENS=()
TEST_RUNNER_CHILD_START_TIMES=()
TEST_RUNNER_CHILD_SEQUENCE=0
TEST_RUNNER_STARTING_CHILD=false
TEST_RUNNER_DEFERRED_SIGNAL=''
TEST_RUNNER_DEFERRED_STATUS=''
TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=${YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS:-50}

# Validate the bounded grace-period override used by the runner's own signal
# integration test. Ordinary callers retain fifty 100 ms polls (five seconds).
test_runner_validate_termination_poll_attempts() {
    if [[ ! ${TEST_RUNNER_TERMINATION_POLL_ATTEMPTS} =~ ^[0-9]{1,3}$ ]]; then
        printf '%s\n' \
            'Error: test-runner termination poll attempts must be an integer from 1 through 600.' >&2
        return 64
    fi
    TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=$((10#${TEST_RUNNER_TERMINATION_POLL_ATTEMPTS}))
    if ((TEST_RUNNER_TERMINATION_POLL_ATTEMPTS < 1 || \
        TEST_RUNNER_TERMINATION_POLL_ATTEMPTS > 600)); then
        printf '%s\n' \
            'Error: test-runner termination poll attempts must be an integer from 1 through 600.' >&2
        return 64
    fi
}

# Return a monotonic timestamp in milliseconds.
test_runner_now_ms() {
    python3 - <<'PY_NOW'
import time

print(time.monotonic_ns() // 1_000_000)
PY_NOW
}

# Format a non-negative millisecond duration into the named caller variable.
test_runner_format_duration() {
    (($# == 2)) || return 2
    local runner_duration_ms=$1
    local runner_output_name=$2

    [[ ${runner_duration_ms} =~ ^[0-9]+$ ]] || return 2
    printf -v "${runner_output_name}" '%d.%03ds' \
        "$((runner_duration_ms / 1000))" "$((runner_duration_ms % 1000))"
}

# Create the private directory used for deterministic parallel-suite logs.
test_runner_initialize() {
    ((${#TEST_RUNNER_CHILD_PIDS[@]} == 0)) || return 70
    ((${#TEST_RUNNER_CHILD_PGIDS[@]} == 0)) || return 70
    ((${#TEST_RUNNER_CHILD_COMPLETIONS[@]} == 0)) || return 70
    ((${#TEST_RUNNER_CHILD_TOKENS[@]} == 0)) || return 70
    ((${#TEST_RUNNER_CHILD_START_TIMES[@]} == 0)) || return 70
    ((TEST_RUNNER_CHILD_SEQUENCE == 0)) || return 70
    [[ -z ${TEST_RUNNER_LOG_DIR} ]] || return 70
    [[ ${TEST_RUNNER_STARTING_CHILD} == false ]] || return 70
    [[ -z ${TEST_RUNNER_DEFERRED_SIGNAL} ]] || return 70
    [[ -z ${TEST_RUNNER_DEFERRED_STATUS} ]] || return 70

    test_runner_validate_termination_poll_attempts || return
    TEST_RUNNER_LOG_DIR=$(mktemp -d) || return 70
}

# Replace the background Bash subshell with a Python session supervisor. The
# supervisor retains the private identity while the command runs, records an
# optional monotonic completion time, and returns the command's exact status.
_test_runner_exec_child() {
    exec python3 - "$@" <<'PY_CHILD'
import os
import signal
import sys
import time

# Bash starts asynchronous commands with SIGINT/SIGQUIT ignored when job
# control is disabled. Restore inherited dispositions before the new session.
for signal_name in ("SIGINT", "SIGQUIT", "SIGPIPE", "SIGXFSZ"):
    signal_number = getattr(signal, signal_name, None)
    if signal_number is not None:
        signal.signal(signal_number, signal.SIG_DFL)

completion_path = sys.argv[1]
command = sys.argv[2:]
managed_signals = tuple(
    signal_number
    for signal_name in ("SIGHUP", "SIGINT", "SIGTERM")
    if (signal_number := getattr(signal, signal_name, None)) is not None
)
previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, managed_signals)
os.setsid()

def exec_command():
    for signal_number in managed_signals:
        signal.signal(signal_number, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    try:
        os.execvp(command[0], command)
    except FileNotFoundError:
        os._exit(127)
    except OSError:
        os._exit(126)

try:
    child_pid = os.fork()
except OSError:
    os._exit(70)
if child_pid == 0:
    exec_command()

termination_requested = False


def remember_termination(_signal_number, _frame):
    global termination_requested
    termination_requested = True


for signal_number in managed_signals:
    signal.signal(signal_number, remember_termination)
signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

while True:
    try:
        _, wait_status = os.waitpid(child_pid, 0)
        break
    except InterruptedError:
        continue

# If cancellation reached this session, keep the authenticated leader alive
# until every same-group descendant has exited. A signal-resistant command can
# clear its environment without making the runner lose KILL escalation.
if termination_requested:
    own_pid = os.getpid()
    own_pgid = os.getpgrp()
    while True:
        group_has_descendant = False
        try:
            process_entries = tuple(os.scandir("/proc"))
        except OSError:
            os._exit(70)
        for process_entry in process_entries:
            if not process_entry.name.isdigit() or int(process_entry.name) == own_pid:
                continue
            try:
                with open(
                    f"/proc/{process_entry.name}/stat", encoding="ascii"
                ) as process_file:
                    process_stat = process_file.read()
            except OSError:
                continue
            stat_end = process_stat.rfind(") ")
            if stat_end < 0:
                continue
            process_fields = process_stat[stat_end + 2 :].split()
            if len(process_fields) >= 3 and process_fields[2] == str(own_pgid):
                group_has_descendant = True
                break
        if not group_has_descendant:
            break
        time.sleep(0.05)

if completion_path:
    try:
        with open(completion_path, "x", encoding="ascii") as completion_file:
            completion_file.write(f"{time.monotonic_ns() // 1_000_000}\n")
    except OSError:
        os._exit(70)

if os.WIFEXITED(wait_status):
    os._exit(os.WEXITSTATUS(wait_status))
if os.WIFSIGNALED(wait_status):
    os._exit(min(128 + os.WTERMSIG(wait_status), 255))
os._exit(70)
PY_CHILD
}

# Export one private identity and publish the launcher start time only inside
# the asynchronous child before the overridable execution trampoline runs.
_test_runner_launch_child() {
    (($# >= 4)) || return 2
    local child_token=$1
    local identity_file=$2
    local launcher_pid=${BASHPID}
    local launcher_start_time=''
    shift 2

    export YTDLP_ARIA2_TEST_RUNNER_CHILD_TOKEN=${child_token}
    test_runner_read_start_time launcher_start_time "${launcher_pid}" \
        || return 70
    set -o noclobber
    if ! printf '%s %s\n' "${launcher_pid}" "${launcher_start_time}" \
        >"${identity_file}"; then
        set +o noclobber
        return 70
    fi
    set +o noclobber
    _test_runner_exec_child "$@"
}

# Read one complete launcher identity from the private handoff file. The file
# can be visible briefly before printf has published its full record.
test_runner_read_child_identity() {
    (($# == 3)) || return 2
    local output_name=$1
    local identity_file=$2
    local expected_pid=$3
    local identity_pid=''
    local identity_start_time=''
    local identity_trailing=''

    [[ ${expected_pid} =~ ^[1-9][0-9]*$ ]] || return 2
    [[ -f ${identity_file} && ! -L ${identity_file} ]] || return 1
    IFS=' ' read -r identity_pid identity_start_time identity_trailing \
        <"${identity_file}" || return 1
    [[ ${identity_pid} == "${expected_pid}" &&
        ${identity_start_time} =~ ^[1-9][0-9]*$ &&
        -z ${identity_trailing} ]] || return 1
    printf -v "${output_name}" '%s' "${identity_start_time}"
}

# Close the startup critical section and replay the first fatal signal if one
# arrived before child registration reached a stable final state.
test_runner_finish_start_transition() {
    local deferred_signal=''
    local deferred_status=''

    if [[ -n ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
        deferred_signal=${TEST_RUNNER_DEFERRED_SIGNAL}
        deferred_status=${TEST_RUNNER_DEFERRED_STATUS}
        # Close the final registration-to-replay window before exposing the
        # completed state. A later signal must not supersede the first request.
        trap '' HUP INT TERM
        TEST_RUNNER_STARTING_CHILD=false
        TEST_RUNNER_DEFERRED_SIGNAL=''
        TEST_RUNNER_DEFERRED_STATUS=''
        test_runner_handle_signal "${deferred_signal}" "${deferred_status}"
    else
        TEST_RUNNER_STARTING_CHILD=false
        # A trap may have run after the condition above was evaluated but
        # before STARTING_CHILD became false. Replay that final narrow window.
        if [[ -n ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
            deferred_signal=${TEST_RUNNER_DEFERRED_SIGNAL}
            deferred_status=${TEST_RUNNER_DEFERRED_STATUS}
            trap '' HUP INT TERM
            TEST_RUNNER_DEFERRED_SIGNAL=''
            TEST_RUNNER_DEFERRED_STATUS=''
            test_runner_handle_signal "${deferred_signal}" "${deferred_status}"
        fi
    fi
}

# Start one command with an optional completion-time record.
_test_runner_start_child() {
    (($# >= 4)) || return 2
    local slot=$1
    local log_file=$2
    local completion_file=$3
    local child_token=''
    local child_pid=''
    local child_start_time=''
    local identity_file=''
    local parent_observed_start_time=''
    local runner_pid=${BASHPID}
    shift 3

    [[ ${slot} =~ ^[0-9]+$ ]] || return 2
    (($# > 0)) || return 2
    [[ -z ${TEST_RUNNER_CHILD_PIDS[${slot}]:-} ]] || return 70
    if [[ -n ${completion_file} &&
        (-e ${completion_file} || -L ${completion_file}) ]]; then
        return 70
    fi
    [[ ${TEST_RUNNER_STARTING_CHILD} == false ]] || return 70
    [[ -z ${TEST_RUNNER_DEFERRED_SIGNAL} ]] || return 70
    [[ -z ${TEST_RUNNER_DEFERRED_STATUS} ]] || return 70

    TEST_RUNNER_CHILD_SEQUENCE=$((TEST_RUNNER_CHILD_SEQUENCE + 1))
    child_token="${TEST_RUNNER_LOG_DIR}:${slot}:${TEST_RUNNER_CHILD_SEQUENCE}"
    identity_file="${TEST_RUNNER_LOG_DIR}/child-${slot}-${TEST_RUNNER_CHILD_SEQUENCE}.identity"
    [[ ! -e ${identity_file} && ! -L ${identity_file} ]] || return 70

    # Bash may dispatch a trapped signal after the asynchronous command has
    # started but before the following array assignments. Mark that narrow
    # region explicitly: the trap records the first signal, this function
    # registers the child, and only then is normal termination replayed.
    TEST_RUNNER_STARTING_CHILD=true
    if [[ -n ${log_file} ]]; then
        _test_runner_launch_child \
            "${child_token}" "${identity_file}" "${completion_file}" "$@" \
            >"${log_file}" 2>&1 &
    else
        _test_runner_launch_child \
            "${child_token}" "${identity_file}" "${completion_file}" "$@" &
    fi

    child_pid=$!
    while :; do
        if test_runner_read_child_identity \
            child_start_time "${identity_file}" "${child_pid}"; then
            break
        fi
        if ! test_runner_read_active_child_start_time \
            parent_observed_start_time "${child_pid}" "${runner_pid}"; then
            # Once the launcher is no longer active, its writes are closed.
            # Re-read once so a record observed while still empty or partial
            # cannot turn a successfully launched command into status 70.
            test_runner_read_child_identity \
                child_start_time "${identity_file}" "${child_pid}" || true
            break
        fi
        # A fatal request cannot wait for a delayed child-side publication.
        # The same-snapshot PPID/start-time proof safely authenticates the
        # still-direct launcher until normal termination rechecks its identity.
        if [[ -n ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
            child_start_time=${parent_observed_start_time}
            break
        fi
        sleep 0.001
    done

    if [[ -z ${child_start_time} ]]; then
        wait "${child_pid}" 2>/dev/null || true
        rm -f -- "${identity_file}"
        test_runner_finish_start_transition
        return 70
    fi
    rm -f -- "${identity_file}"
    TEST_RUNNER_CHILD_PIDS[slot]=${child_pid}
    TEST_RUNNER_CHILD_PGIDS[slot]=${child_pid}
    TEST_RUNNER_CHILD_COMPLETIONS[slot]=${completion_file}
    TEST_RUNNER_CHILD_TOKENS[slot]=${child_token}
    TEST_RUNNER_CHILD_START_TIMES[slot]=${child_start_time}

    test_runner_finish_start_transition
}

# Start one command in a dedicated session and record it in the requested slot.
# When a log path is supplied, stdout and stderr are buffered there so parallel
# completion order cannot scramble the validation output.
test_runner_start_child() {
    (($# >= 3)) || return 2
    local slot=$1
    local log_file=$2
    shift 2

    _test_runner_start_child "${slot}" "${log_file}" '' "$@"
}

# Start a buffered child whose true completion timestamp is recorded separately
# from the later manifest-ordered wait and log replay.
test_runner_start_timed_child() {
    (($# >= 4)) || return 2
    local slot=$1
    local log_file=$2
    local completion_file=$3
    shift 3

    [[ -n ${completion_file} ]] || return 2
    _test_runner_start_child \
        "${slot}" "${log_file}" "${completion_file}" "$@"
}

# Read one completion record into a caller variable.
test_runner_read_completion() {
    (($# == 2)) || return 2
    local completion_file=$1
    local output_name=$2
    local -a records=()

    if [[ ! -f ${completion_file} || -L ${completion_file} ||
        ! -r ${completion_file} ]]; then
        return 70
    fi
    mapfile -t records <"${completion_file}"
    ((${#records[@]} == 1)) || return 70
    [[ ${records[0]} =~ ^[0-9]+$ ]] || return 70
    printf -v "${output_name}" '%s' "${records[0]}"
}

# Wait for one recorded child and release its supervision slot.
test_runner_wait_child() {
    (($# == 1)) || return 2
    local slot=$1
    local pid=${TEST_RUNNER_CHILD_PIDS[${slot}]:-}
    local status=0

    [[ -n ${pid} ]] || return 70
    wait "${pid}" || status=$?
    unset 'TEST_RUNNER_CHILD_PIDS[slot]'
    unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
    unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
    unset 'TEST_RUNNER_CHILD_TOKENS[slot]'
    unset 'TEST_RUNNER_CHILD_START_TIMES[slot]'
    return "${status}"
}

# Wait for the first completed child, release its slot, and return that slot in
# the named caller variable. Timed children publish a completion record before
# exiting; authenticated process identity covers early supervisor failures
# without trusting a recycled numeric PID.
test_runner_wait_any() {
    (($# == 1)) || return 2
    local output_name=$1
    local ready_slot=''
    local completion_file=''
    local status=0

    ((${#TEST_RUNNER_CHILD_PIDS[@]} > 0)) || return 70
    while :; do
        for ready_slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
            completion_file=${TEST_RUNNER_CHILD_COMPLETIONS[${ready_slot}]:-}
            if [[ -n ${completion_file} &&
                (-e ${completion_file} || -L ${completion_file}) ]] \
                || ! test_runner_slot_has_identity "${ready_slot}"; then
                status=0
                test_runner_wait_child "${ready_slot}" || status=$?
                printf -v "${output_name}" '%s' "${ready_slot}"
                return "${status}"
            fi
        done
        sleep 0.01
    done
}

# Run one foreground-visible command under the same session supervision used
# for buffered parallel suites.
test_runner_run_child() {
    (($# > 0)) || return 2
    local status=0

    test_runner_start_child 0 '' "$@" || return
    test_runner_wait_child 0 || status=$?
    return "${status}"
}

# Read Linux process start time into a caller variable. The value is stable for
# one PID lifetime and therefore distinguishes a later recycled PID.
test_runner_read_start_time() {
    (($# == 2)) || return 2
    local output_name=$1
    local pid=$2
    local process_stat=''
    local start_time=''
    local -a process_fields=()

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 2
    IFS= read -r process_stat 2>/dev/null <"/proc/${pid}/stat" || return 1
    process_stat=${process_stat##*) }
    read -r -a process_fields <<<"${process_stat}"
    ((${#process_fields[@]} >= 20)) || return 1
    start_time=${process_fields[19]}
    [[ ${start_time} =~ ^[1-9][0-9]*$ ]] || return 1
    printf -v "${output_name}" '%s' "${start_time}"
}

# Read the start time of a still-running direct child in the same /proc snapshot
# that proves its parent. A zombie or externally recycled PID cannot keep child
# registration open or gain fallback signaling authority.
test_runner_read_active_child_start_time() {
    (($# == 3)) || return 2
    local output_name=$1
    local pid=$2
    local expected_parent_pid=$3
    local process_stat=''
    local start_time=''
    local -a process_fields=()

    [[ ${pid} =~ ^[1-9][0-9]*$ &&
        ${expected_parent_pid} =~ ^[1-9][0-9]*$ ]] || return 2
    IFS= read -r process_stat 2>/dev/null <"/proc/${pid}/stat" || return 1
    process_stat=${process_stat##*) }
    read -r -a process_fields <<<"${process_stat}"
    ((${#process_fields[@]} >= 20)) || return 1
    [[ ${process_fields[0]} != Z &&
        ${process_fields[1]} == "${expected_parent_pid}" ]] || return 1
    start_time=${process_fields[19]}
    [[ ${start_time} =~ ^[1-9][0-9]*$ ]] || return 1
    printf -v "${output_name}" '%s' "${start_time}"
}

# Match a live PID to the start time captured immediately after launch.
test_runner_pid_has_start_time() {
    (($# == 2)) || return 2
    local pid=$1
    local expected_start_time=$2
    local observed_start_time=''

    [[ -n ${expected_start_time} ]] || return 1
    test_runner_read_start_time observed_start_time "${pid}" || return 1
    [[ ${observed_start_time} == "${expected_start_time}" ]]
}

# Match a live process to the private token inherited by one runner child.
# This prevents a recycled numeric PID from becoming a signaling authority.
test_runner_pid_has_token() {
    (($# == 2)) || return 2
    local pid=$1
    local expected_token=$2
    local environment_entry=''
    local environment_path="/proc/${pid}/environ"
    local expected_entry="YTDLP_ARIA2_TEST_RUNNER_CHILD_TOKEN=${expected_token}"

    [[ ${pid} =~ ^[1-9][0-9]*$ && -n ${expected_token} ]] || return 2
    [[ -r ${environment_path} ]] || return 1
    while IFS= read -r -d '' environment_entry; do
        if [[ ${environment_entry} == "${expected_entry}" ]]; then
            return 0
        fi
    done 2>/dev/null <"${environment_path}"
    return 1
}

# Match the original child identity to the supervised process group.
test_runner_pid_has_group_identity() {
    (($# == 4)) || return 2
    local pid=$1
    local pgid=$2
    local expected_token=$3
    local expected_start_time=$4
    local observed_start_time=''
    local process_stat=''
    local -a process_fields=()

    IFS= read -r process_stat 2>/dev/null <"/proc/${pid}/stat" || return 1
    process_stat=${process_stat##*) }
    read -r -a process_fields <<<"${process_stat}"
    ((${#process_fields[@]} >= 20)) || return 1
    [[ ${process_fields[2]} == "${pgid}" ]] || return 1
    observed_start_time=${process_fields[19]}
    [[ ${observed_start_time} =~ ^[1-9][0-9]*$ ]] || return 1

    if [[ -n ${expected_start_time} ]]; then
        [[ ${observed_start_time} == "${expected_start_time}" ]]
        return
    fi

    test_runner_pid_has_token "${pid}" "${expected_token}" || return 1
    # Recheck the same numeric PID after reading its environment, so a token
    # from an exited process cannot authenticate a replacement's group fields.
    test_runner_pid_has_group_identity \
        "${pid}" "${pgid}" '' "${observed_start_time}"
}

# Find any inherited-token member that still authenticates a child group after
# its original session leader has exited.
test_runner_group_has_token() {
    (($# == 2)) || return 2
    local pgid=$1
    local expected_token=$2
    local process_dir=''
    local process_pid=''

    [[ ${pgid} =~ ^[1-9][0-9]*$ && -n ${expected_token} ]] || return 2
    if test_runner_pid_has_group_identity \
        "${pgid}" "${pgid}" "${expected_token}" ''; then
        return 0
    fi
    for process_dir in /proc/[0-9]*; do
        [[ -d ${process_dir} ]] || continue
        process_pid=${process_dir##*/}
        [[ ${process_pid} != "${pgid}" ]] || continue
        if test_runner_pid_has_group_identity \
            "${process_pid}" "${pgid}" "${expected_token}" ''; then
            return 0
        fi
    done
    return 1
}

# Return success only while a slot still identifies its original process or
# one same-group descendant that inherited the private token.
test_runner_slot_has_identity() {
    (($# == 1)) || return 2
    local slot=$1
    local pid=${TEST_RUNNER_CHILD_PIDS[${slot}]:-}
    local pgid=${TEST_RUNNER_CHILD_PGIDS[${slot}]:-${pid}}
    local child_token=${TEST_RUNNER_CHILD_TOKENS[${slot}]:-}
    local child_start_time=${TEST_RUNNER_CHILD_START_TIMES[${slot}]:-}

    [[ -n ${pid} && -n ${pgid} ]] || return 1
    test_runner_pid_has_start_time "${pid}" "${child_start_time}" \
        || test_runner_pid_has_token "${pid}" "${child_token}" \
        || test_runner_group_has_token "${pgid}" "${child_token}"
}

# Reap slots whose authenticated process identity has disappeared before any
# fatal-signal path considers numeric PIDs or process groups.
test_runner_release_inactive_children() {
    local slot=''

    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        if ! test_runner_slot_has_identity "${slot}"; then
            test_runner_wait_child "${slot}" 2>/dev/null || true
        fi
    done
}

# Signal one slot only after the inherited token authenticates the current
# process-group or direct-child identity.
test_runner_signal_slot() {
    (($# == 2)) || return 2
    local slot=$1
    local signal_name=$2
    local pid=${TEST_RUNNER_CHILD_PIDS[${slot}]:-}
    local pgid=${TEST_RUNNER_CHILD_PGIDS[${slot}]:-${pid}}
    local child_token=${TEST_RUNNER_CHILD_TOKENS[${slot}]:-}
    local child_start_time=${TEST_RUNNER_CHILD_START_TIMES[${slot}]:-}

    [[ -n ${pid} && -n ${pgid} ]] || return 1
    if test_runner_pid_has_group_identity \
        "${pid}" "${pgid}" "${child_token}" "${child_start_time}" \
        || test_runner_group_has_token "${pgid}" "${child_token}"; then
        kill "-${signal_name}" -- "-${pgid}" 2>/dev/null
    elif test_runner_pid_has_token "${pid}" "${child_token}" \
        || test_runner_pid_has_start_time "${pid}" "${child_start_time}"; then
        kill "-${signal_name}" -- "${pid}" 2>/dev/null
    else
        return 1
    fi
}

# Signal every active child session, wait once for the shared grace period,
# then escalate remaining process groups to KILL and reap direct children.
test_runner_terminate_children() {
    (($# == 1)) || return 2
    local signal_name=$1
    local slot
    local pid
    local poll_attempt

    test_runner_release_inactive_children

    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}

        # Wait briefly for os.setsid() to publish the new process group. This
        # keeps delivery deterministic when interruption races with startup.
        for _ in {1..20}; do
            if test_runner_pid_has_group_identity \
                "${pid}" "${pid}" \
                "${TEST_RUNNER_CHILD_TOKENS[${slot}]}" \
                "${TEST_RUNNER_CHILD_START_TIMES[${slot}]}"; then
                break
            fi
            if ! test_runner_pid_has_token \
                "${pid}" "${TEST_RUNNER_CHILD_TOKENS[${slot}]}" \
                && ! test_runner_pid_has_start_time \
                    "${pid}" "${TEST_RUNNER_CHILD_START_TIMES[${slot}]}"; then
                break
            fi
            sleep 0.01
        done

        test_runner_signal_slot "${slot}" "${signal_name}" || true
    done

    for ((poll_attempt = 0; poll_attempt < TEST_RUNNER_TERMINATION_POLL_ATTEMPTS; poll_attempt++)); do
        test_runner_release_inactive_children
        ((${#TEST_RUNNER_CHILD_PIDS[@]} > 0)) || break
        sleep 0.1
    done

    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        test_runner_signal_slot "${slot}" KILL || true
        wait "${pid}" 2>/dev/null || true
        unset 'TEST_RUNNER_CHILD_PIDS[slot]'
        unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
        unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
        unset 'TEST_RUNNER_CHILD_TOKENS[slot]'
        unset 'TEST_RUNNER_CHILD_START_TIMES[slot]'
    done
}

# Finish active supervision and remove only the runner-owned scratch directory.
test_runner_cleanup() {
    if ((${#TEST_RUNNER_CHILD_PIDS[@]} > 0)); then
        test_runner_terminate_children TERM || true
    fi

    if [[ -n ${TEST_RUNNER_LOG_DIR} && -d ${TEST_RUNNER_LOG_DIR} &&
        ! -L ${TEST_RUNNER_LOG_DIR} ]]; then
        rm -rf -- "${TEST_RUNNER_LOG_DIR}" || true
    fi
    TEST_RUNNER_LOG_DIR=''
    TEST_RUNNER_CHILD_TOKENS=()
    TEST_RUNNER_CHILD_START_TIMES=()
    TEST_RUNNER_CHILD_SEQUENCE=0
    TEST_RUNNER_STARTING_CHILD=false
    TEST_RUNNER_DEFERRED_SIGNAL=''
    TEST_RUNNER_DEFERRED_STATUS=''
}

# Complete non-reentrant child cleanup and preserve the conventional signal
# exit status selected by the caller.
test_runner_handle_signal() {
    (($# == 2)) || return 2
    local signal_name=$1
    local exit_status=$2

    # Once a signal has been deferred, it remains authoritative even if child
    # registration has just transitioned to its completed state. This also
    # protects the few commands needed to install the non-reentrant trap guard
    # before replay.
    if [[ -n ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
        return 0
    fi
    if [[ ${TEST_RUNNER_STARTING_CHILD} == true ]]; then
        TEST_RUNNER_DEFERRED_SIGNAL=${signal_name}
        TEST_RUNNER_DEFERRED_STATUS=${exit_status}
        return 0
    fi

    trap '' HUP INT TERM
    test_runner_terminate_children "${signal_name}" || true
    test_runner_cleanup
    exit "${exit_status}"
}
