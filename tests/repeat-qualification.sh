#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/repeat-qualification.sh
# Purpose     : Run independent qualification repetitions concurrently and in order.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
readonly TEST_RUNNER_LIBRARY="${PROJECT_DIR}/tests/lib/test-runner.sh"

if [[ ! -f ${TEST_RUNNER_LIBRARY} || -L ${TEST_RUNNER_LIBRARY} ||
    ! -r ${TEST_RUNNER_LIBRARY} ]]; then
    printf 'Error: test-runner library is not a readable regular file: %s\n' \
        "${TEST_RUNNER_LIBRARY}" >&2
    exit 66
fi

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/test-runner.sh
source "${TEST_RUNNER_LIBRARY}"

LABEL='Qualification iteration'
RUNS=3
JOBS=3
REPEAT_COMMAND=()
ITERATION_LOGS=()
ITERATION_COMPLETIONS=()
ITERATION_STARTS=()
ITERATION_ENDS=()
ITERATION_STATUSES=()
SLOT_ITERATIONS=()

usage() {
    cat <<'EOF_USAGE'
Usage: tests/repeat-qualification.sh [OPTIONS] -- COMMAND [ARGUMENT...]

Run identical, independent qualification commands concurrently while replaying
their output in deterministic iteration order.

Options:
  --label TEXT  Heading used for each iteration.
  --runs N      Number of repetitions (1..100, default: 3).
  --jobs N      Maximum concurrent repetitions (1..32, default: 3).
  -h, --help    Show this help text.

Each child receives YTDLP_ARIA2_REPEAT_ITERATION and
YTDLP_ARIA2_REPEAT_TOTAL in its environment.
EOF_USAGE
}

normalize_count() {
    (($# == 4)) || return 2
    local raw_value=$1
    local maximum=$2
    local label=$3
    local output_name=$4
    local normalized_value

    if [[ ! ${raw_value} =~ ^[0-9]+$ ]]; then
        printf 'Error: %s must be an integer from 1 through %d: %s\n' \
            "${label}" "${maximum}" "${raw_value}" >&2
        return 2
    fi
    normalized_value=$((10#${raw_value}))
    if ((normalized_value < 1 || normalized_value > maximum)); then
        printf 'Error: %s must be an integer from 1 through %d: %s\n' \
            "${label}" "${maximum}" "${raw_value}" >&2
        return 2
    fi
    printf -v "${output_name}" '%d' "${normalized_value}"
}

parse_arguments() {
    local raw_runs=${RUNS}
    local raw_jobs=${YTDLP_ARIA2_REPEAT_JOBS:-${JOBS}}

    while (($# > 0)); do
        case $1 in
            --label)
                (($# >= 2)) || {
                    printf 'Error: --label requires one argument.\n' >&2
                    return 2
                }
                LABEL=$2
                shift
                ;;
            --label=*)
                LABEL=${1#--label=}
                ;;
            --runs)
                (($# >= 2)) || {
                    printf 'Error: --runs requires one argument.\n' >&2
                    return 2
                }
                raw_runs=$2
                shift
                ;;
            --runs=*)
                raw_runs=${1#--runs=}
                ;;
            --jobs)
                (($# >= 2)) || {
                    printf 'Error: --jobs requires one argument.\n' >&2
                    return 2
                }
                raw_jobs=$2
                shift
                ;;
            --jobs=*)
                raw_jobs=${1#--jobs=}
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                REPEAT_COMMAND=("$@")
                break
                ;;
            *)
                printf 'Error: unknown repeat-qualification option: %s\n' "$1" >&2
                return 2
                ;;
        esac
        shift
    done

    normalize_count "${raw_runs}" 100 'repetition count' RUNS
    normalize_count "${raw_jobs}" 32 'repetition concurrency' JOBS
    ((JOBS <= RUNS)) || JOBS=${RUNS}
    if [[ -z ${LABEL} || ${LABEL} == *$'\n'* || ${LABEL} == *$'\r'* ||
        ${#LABEL} -gt 160 ]]; then
        printf 'Error: --label must be one non-empty line of at most 160 characters.\n' >&2
        return 2
    fi
    if ((${#REPEAT_COMMAND[@]} == 0)); then
        printf 'Error: no qualification command was provided after --.\n' >&2
        return 2
    fi
}

cleanup() {
    local status=$?

    trap - EXIT HUP INT TERM
    test_runner_cleanup
    exit "${status}"
}

start_iteration() {
    (($# == 2)) || return 2
    local iteration=$1
    local slot=$2
    local log_file="${TEST_RUNNER_LOG_DIR}/repeat-${iteration}.log"
    local completion_file="${TEST_RUNNER_LOG_DIR}/repeat-${iteration}.completed"

    ITERATION_LOGS[iteration]=${log_file}
    ITERATION_COMPLETIONS[iteration]=${completion_file}
    ITERATION_STARTS[iteration]=$(test_runner_now_ms)
    SLOT_ITERATIONS[slot]=${iteration}

    test_runner_start_timed_child \
        "${slot}" "${log_file}" "${completion_file}" \
        env \
        YTDLP_ARIA2_REPEAT_ITERATION="${iteration}" \
        YTDLP_ARIA2_REPEAT_TOTAL="${RUNS}" \
        "${REPEAT_COMMAND[@]}"
}

collect_iteration() {
    local completed_slot=''
    local iteration
    local end_ms
    local status=0

    # Child failure is recorded and reported after every active repetition has
    # been reaped.
    # shellcheck disable=SC2310
    test_runner_wait_any completed_slot || status=$?
    iteration=${SLOT_ITERATIONS[${completed_slot}]}
    # Missing completion metadata falls back to the observed reap time.
    # shellcheck disable=SC2310
    if ! test_runner_read_completion \
        "${ITERATION_COMPLETIONS[${iteration}]}" end_ms; then
        end_ms=$(test_runner_now_ms)
    fi
    ITERATION_ENDS[iteration]=${end_ms}
    ITERATION_STATUSES[iteration]=${status}
    unset 'SLOT_ITERATIONS[completed_slot]'
}

report_iterations() {
    local iteration
    local duration
    local status=0
    local first_failure=0

    for ((iteration = 1; iteration <= RUNS; iteration++)); do
        status=${ITERATION_STATUSES[${iteration}]}
        test_runner_format_duration \
            "$((ITERATION_ENDS[iteration] - ITERATION_STARTS[iteration]))" \
            duration
        printf '\n=== %s %d/%d ===\n' "${LABEL}" "${iteration}" "${RUNS}"
        cat -- "${ITERATION_LOGS[${iteration}]}"
        if ((status == 0)); then
            printf '%s %d/%d: PASS (%s)\n' \
                "${LABEL}" "${iteration}" "${RUNS}" "${duration}"
        else
            printf '%s %d/%d: FAIL (status %d, %s)\n' \
                "${LABEL}" "${iteration}" "${RUNS}" "${status}" "${duration}" >&2
            ((first_failure != 0)) || first_failure=${status}
        fi
        rm -f -- \
            "${ITERATION_LOGS[${iteration}]}" \
            "${ITERATION_COMPLETIONS[${iteration}]}"
    done

    ((first_failure == 0)) || return "${first_failure}"
}

run_repetitions() {
    local next_iteration=1
    local active_count=0
    local slot

    while ((next_iteration <= RUNS || active_count > 0)); do
        for ((slot = 0; slot < JOBS; slot++)); do
            ((next_iteration <= RUNS)) || break
            [[ -z ${SLOT_ITERATIONS[${slot}]+x} ]] || continue
            start_iteration "${next_iteration}" "${slot}"
            ((next_iteration += 1))
            ((active_count += 1))
        done

        if ((active_count > 0)); then
            collect_iteration
            active_count=$((active_count - 1))
        fi
    done

    report_iterations
}

main() {
    local command_name

    parse_arguments "$@"
    for command_name in cat env mktemp python3 rm sleep; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required repeat-runner command is absent: %s\n' \
                "${command_name}" >&2
            return 127
        }
    done

    trap cleanup EXIT
    trap 'test_runner_handle_signal HUP 129' HUP
    trap 'test_runner_handle_signal INT 130' INT
    trap 'test_runner_handle_signal TERM 143' TERM
    test_runner_initialize
    run_repetitions
}

main "$@"
