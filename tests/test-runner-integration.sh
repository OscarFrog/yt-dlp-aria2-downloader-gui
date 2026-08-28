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

    printf 'Test-runner integration passed.\n'
}

main "$@"
