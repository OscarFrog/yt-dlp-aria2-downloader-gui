#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/run-all.sh
# Purpose     : Run profiled, timed, and optionally parallel local validation.
# ==============================================================================

set -euo pipefail
# Bash forces SIGINT/SIGQUIT to be ignored for asynchronous commands when job
# control is disabled. The shared runner restores dispositions before creating
# one dedicated session for every validation child.
set +m

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly PROJECT_DIR

PROJECT_FILES="${PROJECT_DIR}/tests/lib/project-files.sh"
TEST_RUNNER_LIBRARY="${PROJECT_DIR}/tests/lib/test-runner.sh"
readonly PROJECT_FILES TEST_RUNNER_LIBRARY

for required_library in "${PROJECT_FILES}" "${TEST_RUNNER_LIBRARY}"; do
    if [[ ! -f ${required_library} || -L ${required_library} ||
        ! -r ${required_library} ]]; then
        printf 'Error: required test library is not a readable regular file: %s\n' \
            "${required_library}" >&2
        exit 66
    fi
done

# Resolve these sources relative to tests/run-all.sh for ShellCheck.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/project-files.sh
source "${PROJECT_FILES}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/test-runner.sh
source "${TEST_RUNNER_LIBRARY}"

readonly -a FULL_SUITE_IDS=(
    runtime-manager
    run-all-signal
    runtime-manager-hardening
    mock-engine-core
    mock-engine-hls
    mock-engine-staging
    mock-gui-progress
    mock-gui-state
    mock-signals
    mock-runtime-compat
    mock-runtime-validation
    private-aria2-plan
    aria2-auth-headers
    progress-monitor
    ffmpeg-progress
    installer
    install-fedora-auth
    packaging
    package-user-cleanup
    test-runner
)

# The fast profile is an explicit developer feedback loop. The default full
# profile remains the release-equivalent local contract.
readonly -a FAST_SUITE_IDS=(
    runtime-manager
    private-aria2-plan
    progress-monitor
    ffmpeg-progress
    installer
    install-fedora-auth
    packaging
    package-user-cleanup
    test-runner
)

declare -Ar SUITE_LABELS=(
    ['runtime-manager']='Runtime-manager integration'
    ['run-all-signal']='run-all signal/descendant integration'
    ['runtime-manager-hardening']='Runtime-manager hardening integration'
    ['mock-engine-core']='Mock engine core/storage integration'
    ['mock-engine-hls']='Mock engine YouTube HLS integration'
    ['mock-engine-staging']='Mock engine private-staging integration'
    ['mock-gui-progress']='Mock GUI progress/profile integration'
    ['mock-gui-state']='Mock GUI configuration/state integration'
    ['mock-signals']='Mock signal/cancellation integration'
    ['mock-runtime-compat']='Mock runtime compatibility integration'
    ['mock-runtime-validation']='Mock runtime/media validation integration'
    ['private-aria2-plan']='Private aria2 plan integration'
    ['aria2-auth-headers']='Private aria2 authentication/header integration'
    ['progress-monitor']='Progress monitor integration'
    ['ffmpeg-progress']='Measured FFmpeg progress integration'
    ['installer']='Installer integration'
    ['install-fedora-auth']='Fedora bootstrap authentication integration'
    ['packaging']='Packaging integration'
    ['package-user-cleanup']='Package user cleanup integration'
    ['test-runner']='Test-runner integration'
)

declare -Ar SUITE_PATHS=(
    ['runtime-manager']='./tests/runtime-manager-integration.sh'
    ['run-all-signal']='./tests/run-all-signal-integration.sh'
    ['runtime-manager-hardening']='./tests/runtime-manager-hardening-integration.sh'
    ['mock-engine-core']='./tests/mock-integration.sh'
    ['mock-engine-hls']='./tests/mock-integration.sh'
    ['mock-engine-staging']='./tests/mock-integration.sh'
    ['mock-gui-progress']='./tests/mock-integration.sh'
    ['mock-gui-state']='./tests/mock-integration.sh'
    ['mock-signals']='./tests/mock-integration.sh'
    ['mock-runtime-compat']='./tests/mock-integration.sh'
    ['mock-runtime-validation']='./tests/mock-integration.sh'
    ['private-aria2-plan']='./tests/private-aria2-plan-integration.sh'
    ['aria2-auth-headers']='./tests/aria2-auth-headers-integration.sh'
    ['progress-monitor']='./tests/progress-monitor-integration.sh'
    ['ffmpeg-progress']='./tests/ffmpeg-progress-integration.sh'
    ['installer']='./tests/installer-integration.sh'
    ['install-fedora-auth']='./tests/install-fedora-authentication-integration.sh'
    ['packaging']='./tests/packaging-integration.sh'
    ['package-user-cleanup']='./tests/package-user-cleanup-integration.sh'
    ['test-runner']='./tests/test-runner-integration.sh'
)

declare -Ar SUITE_GROUP_ARGUMENTS=(
    ['mock-engine-core']='engine-core'
    ['mock-engine-hls']='engine-hls'
    ['mock-engine-staging']='engine-staging'
    ['mock-gui-progress']='gui-progress'
    ['mock-gui-state']='gui-state'
    ['mock-signals']='signals'
    ['mock-runtime-compat']='runtime-compat'
    ['mock-runtime-validation']='runtime-validation'
)

PROFILE='full'
PROFILE_WAS_EXPLICIT=false
JOBS=${YTDLP_ARIA2_TEST_JOBS:-1}
LIST_ONLY=false

INTEGRATION_SUITE_IDS=()
INTEGRATION_SUITE_LOGS=()
INTEGRATION_SUITE_COMPLETIONS=()
INTEGRATION_SUITE_STARTS=()
INTEGRATION_SUITE_ENDS=()
INTEGRATION_SUITE_STATUSES=()
INTEGRATION_SLOT_SUITE_INDEX=()

usage() {
    cat <<'EOF_USAGE'
Usage: tests/run-all.sh [OPTIONS]

Run the complete validation contract by default.

Options:
  --fast              Run static validation and the fast integration profile.
  --full              Run the complete validation profile (default).
  --jobs N            Run up to N independent validations concurrently (1..32).
  --list              List integration suites and profile membership, then exit.
  -h, --help          Show this help text.

Environment:
  YTDLP_ARIA2_TEST_JOBS  Default validation concurrency when --jobs is absent.
EOF_USAGE
}

select_profile() {
    (($# == 1)) || return 2
    local requested=$1

    if [[ ${PROFILE_WAS_EXPLICIT} == true && ${PROFILE} != "${requested}" ]]; then
        printf 'Error: --fast and --full are mutually exclusive.\n' >&2
        return 2
    fi
    PROFILE=${requested}
    PROFILE_WAS_EXPLICIT=true
}

validate_jobs() {
    (($# == 1)) || return 2
    local candidate=$1

    if [[ ! ${candidate} =~ ^[0-9]+$ ]] \
        || ((10#${candidate} < 1 || 10#${candidate} > 32)); then
        printf 'Error: test concurrency must be an integer from 1 through 32: %s\n' \
            "${candidate}" >&2
        return 2
    fi
    JOBS=$((10#${candidate}))
}

parse_arguments() {
    while (($# > 0)); do
        case $1 in
            --fast)
                select_profile fast
                ;;
            --full)
                select_profile full
                ;;
            --jobs)
                if (($# < 2)); then
                    printf 'Error: --jobs requires one integer argument.\n' >&2
                    return 2
                fi
                validate_jobs "$2"
                shift
                ;;
            --jobs=*)
                validate_jobs "${1#--jobs=}"
                ;;
            --list)
                LIST_ONLY=true
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                if (($# > 0)); then
                    printf 'Error: unexpected positional argument: %s\n' "$1" >&2
                    return 2
                fi
                break
                ;;
            -*)
                printf 'Error: unknown option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'Error: unexpected positional argument: %s\n' "$1" >&2
                return 2
                ;;
        esac
        shift
    done

    validate_jobs "${JOBS}"
}

suite_is_fast() {
    (($# == 1)) || return 2
    local requested=$1
    local suite_id

    for suite_id in "${FAST_SUITE_IDS[@]}"; do
        [[ ${suite_id} == "${requested}" ]] && return 0
    done
    return 1
}

list_suites() {
    local suite_id
    local fast

    printf '%-30s %-5s %s\n' 'SUITE' 'FAST' 'DESCRIPTION'
    for suite_id in "${FULL_SUITE_IDS[@]}"; do
        fast='no'
        # Predicate failure means the suite belongs only to the full profile.
        # shellcheck disable=SC2310
        if suite_is_fast "${suite_id}"; then
            fast='yes'
        fi
        printf '%-30s %-5s %s\n' \
            "${suite_id}" "${fast}" "${SUITE_LABELS[${suite_id}]}"
    done
}

validate_shell_file_arrays() {
    local array_name
    local array_declaration
    local array_attributes
    local array_entry

    for array_name in PRODUCTION_SHELL_FILES PACKAGING_SHELL_FILES TEST_SHELL_FILES DEVELOPMENT_SHELL_FILES; do
        if ! array_declaration=$(declare -p "${array_name}" 2>/dev/null) \
            || [[ ! ${array_declaration} =~ ^declare[[:space:]]+-([^[:space:]]+)[[:space:]] ]]; then
            printf 'Error: %s is not an indexed array in %s.\n' \
                "${array_name}" "${PROJECT_FILES}" >&2
            return 65
        fi
        array_attributes=${BASH_REMATCH[1]}
        if [[ ${array_attributes} != *a* || ${array_attributes} == *A* ]]; then
            printf 'Error: %s is not an indexed array in %s.\n' \
                "${array_name}" "${PROJECT_FILES}" >&2
            return 65
        fi
        declare -n array_ref="${array_name}"
        for array_entry in "${array_ref[@]}"; do
            if [[ -z ${array_entry} || ${array_entry} == -* ]]; then
                printf 'Error: %s contains an invalid shell-file entry: %s\n' \
                    "${array_name}" "${array_entry}" >&2
                return 65
            fi
        done
        unset -n array_ref
    done

    if ((${#PRODUCTION_SHELL_FILES[@]} == 0 || \
        ${#PACKAGING_SHELL_FILES[@]} == 0 || \
        ${#TEST_SHELL_FILES[@]} == 0 || \
        ${#DEVELOPMENT_SHELL_FILES[@]} == 0)); then
        printf 'Error: project-files.sh returned an empty shell-file list.\n' >&2
        return 65
    fi
}

validate_suite_manifest() {
    local suite_id
    local suite_path
    local -A seen=()

    for suite_id in "${FULL_SUITE_IDS[@]}"; do
        if [[ -n ${seen[${suite_id}]:-} ]]; then
            printf 'Error: duplicate validation suite identifier: %s\n' \
                "${suite_id}" >&2
            return 65
        fi
        seen[${suite_id}]=1

        if [[ -z ${SUITE_LABELS[${suite_id}]:-} ||
            -z ${SUITE_PATHS[${suite_id}]:-} ]]; then
            printf 'Error: incomplete validation suite manifest entry: %s\n' \
                "${suite_id}" >&2
            return 65
        fi
        suite_path="${PROJECT_DIR}/${SUITE_PATHS[${suite_id}]#./}"
        if [[ ! -f ${suite_path} || -L ${suite_path} || ! -r ${suite_path} ]]; then
            printf 'Error: suite path is not a readable regular file: %s\n' \
                "${SUITE_PATHS[${suite_id}]}" >&2
            return 66
        fi
    done

    for suite_id in "${FAST_SUITE_IDS[@]}"; do
        if [[ -z ${seen[${suite_id}]:-} ]]; then
            printf 'Error: fast profile references an unknown suite: %s\n' \
                "${suite_id}" >&2
            return 65
        fi
    done
}

run_timed_step() {
    (($# >= 2)) || return 2
    local label=$1
    shift
    local start_ms
    local end_ms
    local duration
    local status=0

    start_ms=$(test_runner_now_ms)
    printf '\n=== %s ===\n' "${label}"
    # A nonzero child status is measured and reported before it is returned.
    # shellcheck disable=SC2310
    test_runner_run_child "$@" || status=$?
    end_ms=$(test_runner_now_ms)
    test_runner_format_duration "$((end_ms - start_ms))" duration

    if ((status == 0)); then
        printf '%s: PASS (%s)\n' "${label}" "${duration}"
    else
        printf '%s: FAIL (status %d, %s)\n' \
            "${label}" "${status}" "${duration}" >&2
    fi
    return "${status}"
}

run_shellcheck_validations() {
    local -a labels=(
        'Production ShellCheck'
        'Packaging ShellCheck'
        'Test-suite ShellCheck'
        'Development tooling ShellCheck'
    )
    local -a array_names=(
        PRODUCTION_SHELL_FILES
        PACKAGING_SHELL_FILES
        TEST_SHELL_FILES
        DEVELOPMENT_SHELL_FILES
    )
    local -a logs=() completions=() starts=() ends=() statuses=()
    local static_jobs=${JOBS}
    local batch_start batch_size slot index status end_ms duration
    local first_failure=0

    ((static_jobs <= ${#labels[@]})) || static_jobs=${#labels[@]}
    printf '\nStarting ShellCheck validations (jobs: %d)\n' "${static_jobs}"

    for ((batch_start = 0; batch_start < ${#labels[@]}; batch_start += static_jobs)); do
        batch_size=$((static_jobs))
        if ((batch_start + batch_size > ${#labels[@]})); then
            batch_size=$((${#labels[@]} - batch_start))
        fi

        for ((slot = 0; slot < batch_size; slot++)); do
            index=$((batch_start + slot))
            logs[index]="${TEST_RUNNER_LOG_DIR}/shellcheck-${index}.log"
            completions[index]="${TEST_RUNNER_LOG_DIR}/shellcheck-${index}.completed"
            starts[index]=$(test_runner_now_ms)
            declare -n shell_files_ref="${array_names[${index}]}"
            test_runner_start_timed_child \
                "${slot}" "${logs[${index}]}" "${completions[${index}]}" \
                shellcheck -x -o all -- "${shell_files_ref[@]}"
            unset -n shell_files_ref
        done

        for ((slot = 0; slot < batch_size; slot++)); do
            index=$((batch_start + slot))
            status=0
            # Nonzero ShellCheck statuses are buffered and reported in category order.
            # shellcheck disable=SC2310
            test_runner_wait_child "${slot}" || status=$?
            statuses[index]=${status}
            # Missing completion metadata falls back to the observed reap time.
            # shellcheck disable=SC2310
            if ! test_runner_read_completion "${completions[${index}]}" end_ms; then
                end_ms=$(test_runner_now_ms)
            fi
            ends[index]=${end_ms}
        done
    done

    for index in "${!labels[@]}"; do
        status=${statuses[${index}]}
        test_runner_format_duration "$((ends[index] - starts[index]))" duration
        printf '\n=== %s ===\n' "${labels[${index}]}"
        cat -- "${logs[${index}]}"
        if ((status == 0)); then
            printf '%s: PASS (%s)\n' "${labels[${index}]}" "${duration}"
        else
            printf '%s: FAIL (status %d, %s)\n' \
                "${labels[${index}]}" "${status}" "${duration}" >&2
            ((first_failure != 0)) || first_failure=${status}
        fi
        rm -f -- "${logs[${index}]}" "${completions[${index}]}"
    done

    ((first_failure == 0)) || return "${first_failure}"
}

run_static_validation() {
    printf '=== ShellCheck version ===\n'
    shellcheck --version

    run_timed_step 'shfmt validation' \
        bash -- ./scripts/check-shell-format.sh
    run_timed_step 'Static validation' bash -- ./test-static.sh
    run_shellcheck_validations
}

initialize_integration_schedule() {
    if [[ ${PROFILE} == fast ]]; then
        INTEGRATION_SUITE_IDS=("${FAST_SUITE_IDS[@]}")
    else
        INTEGRATION_SUITE_IDS=("${FULL_SUITE_IDS[@]}")
    fi

    INTEGRATION_SUITE_LOGS=()
    INTEGRATION_SUITE_COMPLETIONS=()
    INTEGRATION_SUITE_STARTS=()
    INTEGRATION_SUITE_ENDS=()
    INTEGRATION_SUITE_STATUSES=()
    INTEGRATION_SLOT_SUITE_INDEX=()
}

start_integration_suite() {
    (($# == 2)) || return 2
    local suite_index=$1
    local slot=$2
    local suite_id=${INTEGRATION_SUITE_IDS[${suite_index}]}
    local label=${SUITE_LABELS[${suite_id}]}
    local log_file="${TEST_RUNNER_LOG_DIR}/${suite_id}.log"
    local completion_file="${TEST_RUNNER_LOG_DIR}/${suite_id}.completed"
    local group_argument=${SUITE_GROUP_ARGUMENTS[${suite_id}]:-}
    local -a suite_command=(bash -- "${SUITE_PATHS[${suite_id}]}")

    if [[ -n ${group_argument} ]]; then
        suite_command+=(--group "${group_argument}")
    fi
    INTEGRATION_SUITE_STARTS[suite_index]=$(test_runner_now_ms)
    INTEGRATION_SUITE_LOGS[suite_index]=${log_file}
    INTEGRATION_SUITE_COMPLETIONS[suite_index]=${completion_file}
    INTEGRATION_SLOT_SUITE_INDEX[slot]=${suite_index}

    printf 'Starting: %s\n' "${label}"
    test_runner_start_timed_child \
        "${slot}" "${log_file}" "${completion_file}" \
        "${suite_command[@]}"
}

collect_completed_integration_suite() {
    local completed_slot=''
    local suite_index=''
    local end_ms=''
    local status=0

    # Nonzero child statuses are recorded and reported after every scheduled
    # suite has been reaped.
    # shellcheck disable=SC2310
    test_runner_wait_any completed_slot || status=$?
    suite_index=${INTEGRATION_SLOT_SUITE_INDEX[${completed_slot}]}
    # A missing record falls back to the conservative observed completion time.
    # shellcheck disable=SC2310
    if ! test_runner_read_completion \
        "${INTEGRATION_SUITE_COMPLETIONS[${suite_index}]}" end_ms; then
        end_ms=$(test_runner_now_ms)
    fi
    INTEGRATION_SUITE_ENDS[suite_index]=${end_ms}
    INTEGRATION_SUITE_STATUSES[suite_index]=${status}
    unset 'INTEGRATION_SLOT_SUITE_INDEX[completed_slot]'
}

report_integration_suites() {
    local suite_index=''
    local suite_id=''
    local label=''
    local duration=''
    local status=0
    local first_failure=0

    for suite_index in "${!INTEGRATION_SUITE_IDS[@]}"; do
        suite_id=${INTEGRATION_SUITE_IDS[${suite_index}]}
        label=${SUITE_LABELS[${suite_id}]}
        status=${INTEGRATION_SUITE_STATUSES[${suite_index}]}
        test_runner_format_duration \
            "$((INTEGRATION_SUITE_ENDS[suite_index] - INTEGRATION_SUITE_STARTS[suite_index]))" \
            duration

        printf '\n=== %s ===\n' "${label}"
        cat -- "${INTEGRATION_SUITE_LOGS[${suite_index}]}"
        if ((status == 0)); then
            printf '%s: PASS (%s)\n' "${label}" "${duration}"
        else
            printf '%s: FAIL (status %d, %s)\n' \
                "${label}" "${status}" "${duration}" >&2
            if ((first_failure == 0)); then
                first_failure=${status}
            fi
        fi
        rm -f -- \
            "${INTEGRATION_SUITE_LOGS[${suite_index}]}" \
            "${INTEGRATION_SUITE_COMPLETIONS[${suite_index}]}"
    done

    ((first_failure == 0)) || return "${first_failure}"
}

run_integration_suites() {
    local next_index=0
    local active_count=0
    local slot=0

    initialize_integration_schedule
    while ((next_index < ${#INTEGRATION_SUITE_IDS[@]} || active_count > 0)); do
        for ((slot = 0; slot < JOBS; slot++)); do
            ((next_index < ${#INTEGRATION_SUITE_IDS[@]})) || break
            [[ -z ${INTEGRATION_SLOT_SUITE_INDEX[${slot}]+x} ]] || continue

            start_integration_suite "${next_index}" "${slot}"
            next_index=$((next_index + 1))
            active_count=$((active_count + 1))
        done

        if ((active_count > 0)); then
            collect_completed_integration_suite
            active_count=$((active_count - 1))
        fi
    done

    report_integration_suites
}

main() {
    local total_start_ms
    local total_end_ms
    local total_duration

    parse_arguments "$@"
    validate_shell_file_arrays
    validate_suite_manifest

    if [[ ${LIST_ONLY} == true ]]; then
        list_suites
        return 0
    fi

    for command_name in bash cat mktemp python3 rm shellcheck sleep; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            printf 'Error: required validation command is absent: %s\n' \
                "${command_name}" >&2
            return 127
        fi
    done

    cd -- "${PROJECT_DIR}"
    test_runner_initialize
    trap test_runner_cleanup EXIT
    trap 'test_runner_handle_signal HUP 129' HUP
    trap 'test_runner_handle_signal INT 130' INT
    trap 'test_runner_handle_signal TERM 143' TERM

    total_start_ms=$(test_runner_now_ms)
    printf 'Validation profile: %s (validation jobs: %d)\n\n' \
        "${PROFILE}" "${JOBS}"
    run_static_validation
    run_integration_suites
    total_end_ms=$(test_runner_now_ms)
    test_runner_format_duration \
        "$((total_end_ms - total_start_ms))" total_duration

    printf '\nAll %s validation suites passed in %s.\n' \
        "${PROFILE}" "${total_duration}"
}

main "$@"
