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
    [[ -z ${TEST_RUNNER_LOG_DIR} ]] || return 70
    [[ ${TEST_RUNNER_STARTING_CHILD} == false ]] || return 70
    [[ -z ${TEST_RUNNER_DEFERRED_SIGNAL} ]] || return 70
    [[ -z ${TEST_RUNNER_DEFERRED_STATUS} ]] || return 70

    test_runner_validate_termination_poll_attempts || return
    TEST_RUNNER_LOG_DIR=$(mktemp -d) || return 70
}

# Replace the background Bash subshell with the Python session trampoline. If
# requested, retain a tiny supervisor that records the child's actual monotonic
# completion time before returning the same status.
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
os.setsid()

def exec_command():
    try:
        os.execvp(command[0], command)
    except FileNotFoundError:
        os._exit(127)
    except OSError:
        os._exit(126)

if not completion_path:
    exec_command()

try:
    child_pid = os.fork()
except OSError:
    os._exit(70)
if child_pid == 0:
    exec_command()

while True:
    try:
        _, wait_status = os.waitpid(child_pid, 0)
        break
    except InterruptedError:
        continue

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

# Start one command with an optional completion-time record.
_test_runner_start_child() {
    (($# >= 4)) || return 2
    local slot=$1
    local log_file=$2
    local completion_file=$3
    local child_pid=''
    local deferred_signal=''
    local deferred_status=''
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

    # Bash may dispatch a trapped signal after the asynchronous command has
    # started but before the following array assignments. Mark that narrow
    # region explicitly: the trap records the first signal, this function
    # registers the child, and only then is normal termination replayed.
    TEST_RUNNER_STARTING_CHILD=true
    if [[ -n ${log_file} ]]; then
        _test_runner_exec_child "${completion_file}" "$@" \
            >"${log_file}" 2>&1 &
    else
        _test_runner_exec_child "${completion_file}" "$@" &
    fi

    child_pid=$!
    TEST_RUNNER_CHILD_PIDS[slot]=${child_pid}
    TEST_RUNNER_CHILD_PGIDS[slot]=${child_pid}
    TEST_RUNNER_CHILD_COMPLETIONS[slot]=${completion_file}

    if [[ -n ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
        deferred_signal=${TEST_RUNNER_DEFERRED_SIGNAL}
        deferred_status=${TEST_RUNNER_DEFERRED_STATUS}
        # Close the final registration-to-replay window before exposing the
        # completed child arrays. A later fatal signal must never supersede the
        # first signal merely because the runner was descheduled here.
        trap '' HUP INT TERM
        TEST_RUNNER_STARTING_CHILD=false
        TEST_RUNNER_DEFERRED_SIGNAL=''
        TEST_RUNNER_DEFERRED_STATUS=''
        test_runner_handle_signal "${deferred_signal}" "${deferred_status}"
    else
        TEST_RUNNER_STARTING_CHILD=false
        # A trap may have run after the condition above was evaluated but
        # before STARTING_CHILD became false. Recheck after the transition: a
        # later signal observes false and enters the normal handler directly,
        # while a signal from that final narrow window is replayed here.
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
    return "${status}"
}

# Wait for the first completed child, release its slot, and return that slot in
# the named caller variable. Timed children publish a completion record before
# exiting; the process probe covers early supervisor failures without a record.
test_runner_wait_any() {
    (($# == 1)) || return 2
    local output_name=$1
    local ready_slot=''
    local completion_file=''
    local pid=''
    local status=0

    ((${#TEST_RUNNER_CHILD_PIDS[@]} > 0)) || return 70
    while :; do
        for ready_slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
            pid=${TEST_RUNNER_CHILD_PIDS[${ready_slot}]}
            completion_file=${TEST_RUNNER_CHILD_COMPLETIONS[${ready_slot}]:-}
            if [[ -n ${completion_file} &&
                (-e ${completion_file} || -L ${completion_file}) ]] \
                || ! kill -0 -- "${pid}" 2>/dev/null; then
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

# Signal every active child session, wait once for the shared grace period,
# then escalate remaining process groups to KILL and reap direct children.
test_runner_terminate_children() {
    (($# == 1)) || return 2
    local signal_name=$1
    local slot
    local pid
    local pgid
    local poll_attempt
    local any_alive=false

    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        pgid=${TEST_RUNNER_CHILD_PGIDS[${slot}]:-${pid}}

        # Wait briefly for os.setsid() to publish the new process group. This
        # keeps delivery deterministic when interruption races with startup.
        for _ in {1..20}; do
            if kill -0 -- "-${pgid}" 2>/dev/null; then
                break
            fi
            kill -0 -- "${pid}" 2>/dev/null || break
            sleep 0.01
        done

        if kill -0 -- "-${pgid}" 2>/dev/null; then
            kill "-${signal_name}" -- "-${pgid}" 2>/dev/null || true
        elif kill -0 -- "${pid}" 2>/dev/null; then
            kill "-${signal_name}" -- "${pid}" 2>/dev/null || true
        fi
    done

    for ((poll_attempt = 0; poll_attempt < TEST_RUNNER_TERMINATION_POLL_ATTEMPTS; poll_attempt++)); do
        any_alive=false
        for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
            pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
            pgid=${TEST_RUNNER_CHILD_PGIDS[${slot}]:-${pid}}
            if kill -0 -- "-${pgid}" 2>/dev/null \
                || kill -0 -- "${pid}" 2>/dev/null; then
                any_alive=true
                break
            fi
        done
        [[ ${any_alive} == true ]] || break
        sleep 0.1
    done

    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        pgid=${TEST_RUNNER_CHILD_PGIDS[${slot}]:-${pid}}
        if kill -0 -- "-${pgid}" 2>/dev/null; then
            kill -KILL -- "-${pgid}" 2>/dev/null || true
        elif kill -0 -- "${pid}" 2>/dev/null; then
            kill -KILL -- "${pid}" 2>/dev/null || true
        fi
        wait "${pid}" 2>/dev/null || true
        unset 'TEST_RUNNER_CHILD_PIDS[slot]'
        unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
        unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
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
