#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/test-runner-integration.sh
# Purpose     : Verify test-runner timing, logging, concurrency, and statuses.
# ==============================================================================

set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/test-runner.sh
source "${SCRIPT_DIR}/lib/test-runner.sh"

cleanup() {
    trap - EXIT HUP INT TERM
    test_runner_cleanup
}

test_startup_signal_registration_stress() {
    python3 - "${SCRIPT_DIR}/lib/test-runner.sh" <<'PY_STARTUP_STRESS'
import os
import pathlib
import signal
import subprocess
import tempfile

library = pathlib.Path(__import__("sys").argv[1])
fixture = r'''
set -u
set -T
source "$1"
marker=$2
runner_pid=$BASHPID

_test_runner_exec_child() {
    printf '%s\n' "$BASHPID" >"${marker}"
    kill -INT -- "${runner_pid}"
    sleep 0.005
    kill -TERM -- "${runner_pid}" 2>/dev/null || true
    exec sleep 30
}

# Keep this stress focused on launch registration and make every iteration
# fast. The production termination implementation has separate integration
# coverage for process-group signaling and escalation.
test_runner_terminate_children() {
    local _signal_name=$1
    local slot=''
    local pid=''
    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        kill -KILL -- "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        unset 'TEST_RUNNER_CHILD_PIDS[slot]'
        unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
        unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
    done
}

startup_debug_gate() {
    if [[ ${BASH_COMMAND} == 'child_pid=$!' ]]; then
        sleep 0.02
    fi
}

trap startup_debug_gate DEBUG
trap 'test_runner_handle_signal INT 130' INT
trap 'test_runner_handle_signal TERM 143' TERM
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
exit 99
'''


def running(pid: int) -> bool:
    stat_path = pathlib.Path(f"/proc/{pid}/stat")
    try:
        fields = stat_path.read_text(encoding="ascii").split()
    except FileNotFoundError:
        return False
    return len(fields) < 3 or fields[2] != "Z"


with tempfile.TemporaryDirectory(prefix="runner-startup-stress-") as temp_dir:
    root = pathlib.Path(temp_dir)
    for iteration in range(30):
        marker = root / f"child-{iteration}.pid"
        result = subprocess.run(
            ["bash", "-c", fixture, "bash", str(library), str(marker)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        child_pid = 0
        if marker.exists():
            child_pid = int(marker.read_text(encoding="ascii").strip())
        try:
            if result.returncode != 130:
                raise AssertionError(
                    f"startup signal iteration {iteration} returned "
                    f"{result.returncode}, expected first-signal status 130: "
                    f"{result.stderr.decode(errors='replace')}"
                )
            if not child_pid:
                raise AssertionError(
                    f"startup signal iteration {iteration} published no child PID"
                )
            if running(child_pid):
                raise AssertionError(
                    f"startup signal iteration {iteration} left child {child_pid}"
                )
        finally:
            if child_pid and running(child_pid):
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
PY_STARTUP_STRESS
}

test_startup_signal_final_transition() {
    python3 - "${SCRIPT_DIR}/lib/test-runner.sh" <<'PY_FINAL_TRANSITION'
import os
import pathlib
import signal
import subprocess
import tempfile

library = pathlib.Path(__import__("sys").argv[1])
fixture = r'''
set -u
set -T
source "$1"
marker=$2
runner_pid=$BASHPID
final_gate_fired=false

_test_runner_exec_child() {
    printf '%s\n' "$BASHPID" >"${marker}"
    exec sleep 30
}

test_runner_terminate_children() {
    local _signal_name=$1
    local slot=''
    local pid=''
    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        kill -KILL -- "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        unset 'TEST_RUNNER_CHILD_PIDS[slot]'
        unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
        unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
    done
}

final_transition_gate() {
    local attempt=0

    if [[ ${final_gate_fired} == false &&
        ${BASH_COMMAND} == 'TEST_RUNNER_STARTING_CHILD=false' &&
        -z ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
        final_gate_fired=true
        for ((attempt = 0; attempt < 100; attempt++)); do
            [[ -s ${marker} ]] && break
            sleep 0.001
        done
        [[ -s ${marker} ]] || return 70
        kill -TERM -- "${runner_pid}"
    fi
}

trap final_transition_gate DEBUG
trap 'test_runner_handle_signal TERM 143' TERM
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
exit 99
'''


def running(pid: int) -> bool:
    stat_path = pathlib.Path(f"/proc/{pid}/stat")
    try:
        fields = stat_path.read_text(encoding="ascii").split()
    except FileNotFoundError:
        return False
    return len(fields) < 3 or fields[2] != "Z"


with tempfile.TemporaryDirectory(prefix="runner-final-transition-") as temp_dir:
    marker = pathlib.Path(temp_dir) / "child.pid"
    result = subprocess.run(
        ["bash", "-c", fixture, "bash", str(library), str(marker)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    child_pid = int(marker.read_text(encoding="ascii").strip())
    try:
        if result.returncode != 143:
            raise AssertionError(
                "final-transition signal returned "
                f"{result.returncode}, expected 143: "
                f"{result.stderr.decode(errors='replace')}"
            )
        if running(child_pid):
            raise AssertionError(
                f"final-transition signal left child {child_pid}"
            )
    finally:
        if running(child_pid):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
PY_FINAL_TRANSITION
}

main() {
    local duration=''
    local first_log
    local second_log
    local first_completion
    local second_completion
    local first_end_ms=''
    local second_end_ms=''
    local completed_slot=''
    local failure_log
    local failure_completion
    local status=0

    for command_name in bash mktemp python3 rm sleep; do
        require_test_command "${command_name}"
    done

    trap cleanup EXIT
    trap 'return 129' HUP
    trap 'return 130' INT
    trap 'return 143' TERM
    test_runner_initialize

    test_runner_format_duration 1234 duration
    assert_equals '1.234s' "${duration}" 'millisecond duration formatting'

    # A signal delivered in the launch/registration critical section must be
    # retained for replay instead of running cleanup against incomplete arrays.
    TEST_RUNNER_STARTING_CHILD=true
    test_runner_handle_signal TERM 143
    assert_equals 'TERM' "${TEST_RUNNER_DEFERRED_SIGNAL}" \
        'startup signal is deferred until child registration'
    assert_equals '143' "${TEST_RUNNER_DEFERRED_STATUS}" \
        'deferred startup signal preserves its exit status'
    test_runner_handle_signal INT 130
    assert_equals 'TERM' "${TEST_RUNNER_DEFERRED_SIGNAL}" \
        'first startup signal remains authoritative'
    TEST_RUNNER_STARTING_CHILD=false
    test_runner_handle_signal INT 130
    assert_equals 'TERM' "${TEST_RUNNER_DEFERRED_SIGNAL}" \
        'first deferred signal remains authoritative after registration'
    assert_equals '143' "${TEST_RUNNER_DEFERRED_STATUS}" \
        'later signal cannot replace deferred exit status'
    TEST_RUNNER_DEFERRED_SIGNAL=''
    TEST_RUNNER_DEFERRED_STATUS=''

    failure_log="${TEST_RUNNER_LOG_DIR}/failure.log"
    test_runner_start_child 0 "${failure_log}" bash -c \
        'printf "%s\n" expected-failure; exit 17'
    status=0
    # The synthetic failure is the value under test.
    # shellcheck disable=SC2310
    test_runner_wait_child 0 || status=$?
    assert_equals '17' "${status}" 'child status preservation'
    assert_file_has_line "${failure_log}" 'expected-failure' \
        'failed child buffered output'

    first_log="${TEST_RUNNER_LOG_DIR}/first.log"
    second_log="${TEST_RUNNER_LOG_DIR}/second.log"
    first_completion="${TEST_RUNNER_LOG_DIR}/first.completed"
    second_completion="${TEST_RUNNER_LOG_DIR}/second.completed"
    test_runner_start_timed_child \
        0 "${first_log}" "${first_completion}" bash -c \
        'sleep 0.2; printf "%s\n" first'
    test_runner_start_timed_child \
        1 "${second_log}" "${second_completion}" bash -c \
        'printf "%s\n" second'
    test_runner_wait_any completed_slot
    assert_equals '1' "${completed_slot}" \
        'wait-any returns the first completed child slot'
    test_runner_wait_any completed_slot
    assert_equals '0' "${completed_slot}" \
        'wait-any returns the remaining child slot'

    test_runner_read_completion "${first_completion}" first_end_ms
    test_runner_read_completion "${second_completion}" second_end_ms
    ((second_end_ms < first_end_ms)) \
        || fail 'parallel child completion order was not recorded accurately'

    assert_file_has_line "${first_log}" first 'first concurrent child output'
    assert_file_has_line "${second_log}" second 'second concurrent child output'

    failure_completion="${TEST_RUNNER_LOG_DIR}/timed-failure.completed"
    test_runner_start_timed_child \
        2 "${failure_log}" "${failure_completion}" bash -c 'exit 23'
    status=0
    # The synthetic wait-any failure is the value under test.
    # shellcheck disable=SC2310
    test_runner_wait_any completed_slot || status=$?
    assert_equals '2' "${completed_slot}" \
        'wait-any releases a failed child slot'
    assert_equals '23' "${status}" \
        'wait-any preserves a failed child status'

    assert_equals '0' "${#TEST_RUNNER_CHILD_PIDS[@]}" \
        'all concurrent child slots are released'
    assert_equals '0' "${#TEST_RUNNER_CHILD_PGIDS[@]}" \
        'all concurrent process-group slots are released'
    assert_equals '0' "${#TEST_RUNNER_CHILD_COMPLETIONS[@]}" \
        'all concurrent completion slots are released'

    test_startup_signal_registration_stress
    test_startup_signal_final_transition

    printf 'Test-runner integration passed.\n'
}

main "$@"
