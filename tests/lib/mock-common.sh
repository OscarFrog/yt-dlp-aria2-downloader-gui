#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-common.sh
# Purpose     : Share mock assertions, process cleanup, and isolated environment setup.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    PROJECT_DIR OUTPUT_DIR GUI_UNDER_TEST LIST_ARGS_LOG \
    RUNTIME_DIR TEST_OWNER_BASHPID HOME_DIR \
    MOCK_BIN TEST_ROOT TEST_ROOT_FD TEST_ROOT_IDENTITY

# Sourced by mock-integration.sh in the same Bash process. Helpers and tests
# share its PROJECT_DIR, private TEST_ROOT paths, command doubles and assertions;
# invocation remains under the entry point's options, traps and group dispatch.

prepare_argument_log() {
    local scenario=$1

    # Keep CI logs useful: if a scenario blocks, the final emitted name shows
    # exactly which test was running.
    printf 'Mock scenario: %s\n' "${scenario}"

    MOCK_ARG_LOG="${TEST_ROOT}/yt-dlp-post-args-${scenario}.bin"
    MOCK_PLAN_ARG_LOG="${TEST_ROOT}/yt-dlp-plan-args-${scenario}.bin"
    MOCK_ARIA2_ARG_LOG="${TEST_ROOT}/aria2-args-${scenario}.bin"
    MOCK_POST_CALL_LOG="${TEST_ROOT}/yt-dlp-post-calls-${scenario}.log"
    MOCK_PLAN_CALL_LOG="${TEST_ROOT}/yt-dlp-plan-calls-${scenario}.log"
    export MOCK_ARG_LOG MOCK_PLAN_ARG_LOG MOCK_ARIA2_ARG_LOG
    export MOCK_POST_CALL_LOG MOCK_PLAN_CALL_LOG
    : >"${MOCK_ARG_LOG}"
    : >"${MOCK_PLAN_ARG_LOG}"
    : >"${MOCK_ARIA2_ARG_LOG}"
    : >"${MOCK_POST_CALL_LOG}"
    : >"${MOCK_PLAN_CALL_LOG}"
}

read_arguments() {
    local file=$1
    local output_array=$2
    local -n output_ref=${output_array}
    output_ref=()
    [[ -f ${file} ]] || fail "Argument log is missing: ${file}"
    [[ -s ${file} ]] || fail "Argument log is empty: ${file}"
    # shellcheck disable=SC2034 # Assigned through a nameref to the caller array.
    mapfile -d '' -t output_ref <"${file}"
}

assert_array_contains() {
    local array_name=$1
    local expected=$2
    local label=$3
    local -n array_ref=${array_name}
    local value

    for value in "${array_ref[@]}"; do
        [[ ${value} == "${expected}" ]] && return 0
    done
    fail "${label}: missing array element: ${expected}"
}

assert_array_contains_prefix() {
    local array_name=$1
    local expected_prefix=$2
    local label=$3
    local -n array_ref=${array_name}
    local value

    for value in "${array_ref[@]}"; do
        [[ ${value} == "${expected_prefix}"* ]] && return 0
    done

    fail "${label}: missing array element with prefix: ${expected_prefix}"
}

assert_array_not_contains() {
    local array_name=$1
    local unexpected=$2
    local label=$3
    local -n array_ref=${array_name}
    local value

    for value in "${array_ref[@]}"; do
        [[ ${value} != "${unexpected}" ]] \
            || fail "${label}: unexpected array element: ${unexpected}"
    done
}

assert_diagnostic_question() {
    (($# == 3)) || return 2
    local arguments_text=''
    local question_log=$1
    local expected_message=$2
    local label=$3
    local -a question_arguments=()

    read_arguments "${question_log}" question_arguments
    assert_array_contains question_arguments '--question' \
        "${label} uses a question dialog"
    assert_array_contains question_arguments '--ok-label=View log' \
        "${label} View log action"
    assert_array_contains question_arguments '--cancel-label=Close' \
        "${label} Close action"
    arguments_text=$(printf '%s\n' "${question_arguments[@]}")
    assert_text_contains "${arguments_text}" "${expected_message}" \
        "${label} user-facing message"
    assert_text_contains "${arguments_text}" 'Select View log to inspect' \
        "${label} identifies the available diagnostic action"
}

assert_retained_log_identity_footer() {
    (($# == 2)) || return 2
    local retained_log=$1
    local label=$2
    local actual_footer=''
    local expected_footer=''
    local resolved_log=''
    local retained_name=''

    resolved_log=$(realpath -e -- "${retained_log}") \
        || fail "${label}: unable to resolve retained log: ${retained_log}"
    retained_name=${resolved_log##*/}
    printf -v expected_footer '%s\n%s\n%s\n%s\n%s\n%s' \
        '============================================================' \
        'Diagnostic log information' \
        '============================================================' \
        "Log file name: ${retained_name}" \
        "Log full path: ${resolved_log}" \
        '============================================================'
    actual_footer=$(tail -n 6 -- "${retained_log}") \
        || fail "${label}: unable to read retained-log footer."
    assert_equals "${expected_footer}" "${actual_footer}" \
        "${label} exact terminal identity footer"
    assert_file_not_contains "${retained_log}" 'live-download-log.' \
        "${label} excludes the live temporary log"
    assert_file_not_contains "${retained_log}" 'log-snapshot.' \
        "${label} excludes the temporary snapshot"
    assert_file_not_contains "${retained_log}" 'log-truncated.' \
        "${label} excludes the temporary truncation file"
    assert_file_not_contains "${retained_log}" '/yt-dlp-gui.' \
        "${label} excludes the temporary GUI session"
}

assert_no_retained_log_staging() {
    (($# == 2)) || return 2
    local log_dir=$1
    local label=$2
    local staging_file=''

    for staging_file in "${log_dir}"/.download-*.log.part; do
        [[ -e ${staging_file} || -L ${staging_file} ]] || continue
        fail "${label}: retained-log staging file remains: ${staging_file}"
    done
}

assert_gui_profile_menu() {
    (($# == 5 || $# == 7)) || return 2
    local scenario=$1
    local requested_url=$2
    local youtube_expected=$3
    local label=$4
    local profile_bundle=$5
    local remembered_profile=${6:-audio}
    local expected_profile=${7:-audio}
    local expected_mode=${expected_profile}
    local expected_hls=false
    local expected_argument_count=9
    local video_label='Complete video (MKV)'
    local selected_label=''
    local row_start=-1 row_index selected_count=0
    local config_file="${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"
    local url_file=''
    local engine_arguments_log="${TEST_ROOT}/profile-engine-arguments.bin"
    local engine_acknowledgement_log="${TEST_ROOT}/profile-engine-acknowledgement.bin"
    local file_selection_log="${TEST_ROOT}/profile-destination.bin"
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    local -a engine_arguments=() profile_arguments=()
    local -a engine_acknowledgement=() profile_rows=()

    if [[ ${youtube_expected} == true ]]; then
        video_label='YouTube video - Firefox cookies (HLS/MKV)'
    fi
    if [[ ${expected_profile} == youtube-hls ]]; then
        expected_mode=video
        expected_hls=true
        expected_argument_count=10
    fi
    mkdir -p -- "${config_file%/*}"
    if [[ ${remembered_profile} == missing ]]; then
        rm -f -- "${config_file}"
    else
        printf 'output_dir=%s\nprofile=%s\n' "${OUTPUT_DIR}" "${remembered_profile}" \
            >"${config_file}"
        chmod 600 -- "${config_file}"
    fi

    prepare_argument_log "${scenario}"
    : >"${file_selection_log}"
    : >"${engine_arguments_log}"
    : >"${engine_acknowledgement_log}"
    assert_status 73 "${label} GUI-to-engine handoff stops before PLAN" \
        env MOCK_ZENITY_ENTRY_VALUE="${requested_url}" \
        MOCK_USE_DEFAULT_PROFILE=1 \
        MOCK_GUI_REAL="${profile_bundle}/download-video-gui.sh" \
        MOCK_PROFILE_ENGINE_SOURCE="${profile_bundle}/engine-source.sh" \
        MOCK_PROFILE_ENGINE_ARGUMENTS="${engine_arguments_log}" \
        MOCK_PROFILE_ENGINE_ACKNOWLEDGEMENT="${engine_acknowledgement_log}" \
        MOCK_FILE_SELECTION_ARGS_LOG="${file_selection_log}" \
        "${GUI_UNDER_TEST}"
    read_arguments "${LIST_ARGS_LOG}" profile_arguments
    for row_index in "${!profile_arguments[@]}"; do
        if [[ ${profile_arguments[row_index]} == TRUE ||
            ${profile_arguments[row_index]} == FALSE ]]; then
            row_start=${row_index}
            break
        fi
    done
    ((row_start >= 0)) || fail "${label}: no radiolist rows."
    profile_rows=("${profile_arguments[@]:row_start}")
    assert_equals 4 "${#profile_rows[@]}" "${label} exactly two radiolist rows"
    assert_equals "${video_label}" "${profile_rows[1]}" "${label} video profile"
    assert_equals 'Audio track (native format)' "${profile_rows[3]}" "${label} audio profile"
    for row_index in 0 2; do
        case ${profile_rows[row_index]} in
            TRUE)
                ((selected_count += 1))
                selected_label=${profile_rows[row_index + 1]}
                ;;
            FALSE) ;;
            *) fail "${label}: invalid radiolist selection state." ;;
        esac
    done
    assert_equals 1 "${selected_count}" "${label} exactly one default selection"
    if [[ ${expected_profile} == audio ]]; then
        assert_equals 'Audio track (native format)' "${selected_label}" \
            "${label} remembered audio selection"
    else
        assert_equals "${video_label}" "${selected_label}" \
            "${label} compatible video selection"
    fi
    if [[ ${youtube_expected} == true ]]; then
        assert_array_not_contains profile_arguments 'Complete video (MKV)' \
            "${label} excludes generic complete video"
    else
        assert_array_not_contains profile_arguments \
            'YouTube video - Firefox cookies (HLS/MKV)' \
            "${label} excludes YouTube HLS"
    fi
    [[ -s ${file_selection_log} ]] \
        || fail "${label}: the real GUI did not select a destination."
    read_arguments "${engine_arguments_log}" engine_arguments
    read_arguments "${engine_acknowledgement_log}" engine_acknowledgement
    assert_equals 11 "${#engine_acknowledgement[@]}" \
        "${label} engine acknowledgement field count"
    assert_equals "${requested_url}" "${engine_acknowledgement[0]}" \
        "${label} real GUI URL-file transfer"
    assert_equals "${youtube_expected}" "${engine_acknowledgement[1]}" \
        "${label} real engine host classification"
    assert_equals "${expected_mode}" "${engine_acknowledgement[2]}" "${label} engine mode"
    assert_equals "${OUTPUT_DIR}" "${engine_acknowledgement[3]}" \
        "${label} engine destination"
    assert_equals true "${engine_acknowledgement[4]}" "${label} machine progress"
    assert_equals "${expected_hls}" "${engine_acknowledgement[5]}" "${label} HLS profile"
    url_file=${engine_acknowledgement[6]}
    [[ ${url_file} == "${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}/yt-dlp-gui."*/url.txt ]] \
        || fail "${label}: the URL file was not created in the real GUI session."
    assert_equals "${url_file%/*}/result.txt" "${engine_acknowledgement[7]}" \
        "${label} result-file argument"
    assert_equals true "${engine_acknowledgement[8]}" \
        "${label} supervised GUI worker"
    assert_equals 600 "${engine_acknowledgement[9]}" "${label} private URL-file mode"
    assert_equals 700 "${engine_acknowledgement[10]}" "${label} private session mode"
    assert_equals "${expected_argument_count}" "${#engine_arguments[@]}" \
        "${label} engine argument count"
    assert_option_value engine_arguments --url-file "${url_file}" \
        "${label} real GUI URL-file argument"
    assert_option_value engine_arguments --output-dir "${OUTPUT_DIR}" \
        "${label} real GUI destination argument"
    assert_option_value engine_arguments --mode "${expected_mode}" "${label} real GUI mode argument"
    if [[ ${expected_hls} == true ]]; then
        assert_array_contains engine_arguments --youtube-hls-firefox \
            "${label} real GUI HLS argument"
    else
        assert_array_not_contains engine_arguments --youtube-hls-firefox \
            "${label} excludes the HLS argument"
    fi
    assert_option_value engine_arguments --result-file "${url_file%/*}/result.txt" \
        "${label} real GUI result-file argument"
    assert_array_contains engine_arguments --machine-progress \
        "${label} real GUI machine-progress argument"
    assert_array_not_contains engine_arguments "${requested_url}" \
        "${label} URL absent from engine argv"
    assert_file_has_line "${config_file}" \
        "profile=${expected_profile}" "${label} real GUI profile persistence"
    [[ ! -e ${url_file%/*} && ! -L ${url_file%/*} ]] \
        || fail "${label}: the private GUI session was not cleaned up."
    [[ ! -s ${MOCK_PLAN_ARG_LOG} &&
        ! -s ${MOCK_ARG_LOG} && ! -s ${MOCK_ARIA2_ARG_LOG} &&
        ! -s ${MOCK_PLAN_CALL_LOG} && ! -s ${MOCK_POST_CALL_LOG} ]] \
        || fail "${label}: the engine sentinel started the download pipeline."
    assert_no_test_processes "${label}: GUI-to-engine handoff left a process"
}

assert_option_value() {
    local array_name=$1
    local option=$2
    local expected_value=$3
    local label=$4
    local desired_occurrence=${5:-1}
    local -n array_ref=${array_name}
    local occurrence=0
    local index

    for ((index = 0; index < ${#array_ref[@]}; index++)); do
        if [[ ${array_ref[index]} == "${option}" ]]; then
            ((occurrence += 1))
            if ((occurrence == desired_occurrence)); then
                ((index + 1 < ${#array_ref[@]})) \
                    || fail "${label}: ${option} has no following value"
                assert_equals "${expected_value}" "${array_ref[index + 1]}" "${label}"
                return 0
            fi
        fi
    done

    fail "${label}: occurrence ${desired_occurrence} of ${option} was not found"
}

wait_for_file() {
    local path=$1
    local timeout=$2
    local label=$3
    local deadline=$((SECONDS + timeout))

    while ((SECONDS < deadline)); do
        [[ -f ${path} ]] && return 0
        sleep 0.1
    done

    fail "${label}: file did not appear within ${timeout}s: ${path}"
}

read_mock_process_start_time() {
    (($# == 2)) || return 2
    local output_variable=$1
    local pid=$2
    local process_stat=''
    local process_start_time=''
    local process_state=''
    local -a process_fields=()

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 2
    IFS= read -r process_stat 2>/dev/null <"/proc/${pid}/stat" || return 1
    read -r -a process_fields <<<"${process_stat##*) }"
    ((${#process_fields[@]} >= 20)) || return 1
    process_state=${process_fields[0]}
    process_start_time=${process_fields[19]}
    [[ ${process_state} != Z && ${process_state} != X &&
        ${process_start_time} =~ ^[1-9][0-9]*$ ]] || return 1
    printf -v "${output_variable}" '%s' "${process_start_time}"
}

wait_for_mock_process_to_stop() {
    (($# == 4)) || return 2
    local pid=$1
    local expected_start_time=$2
    local timeout=$3
    local label=$4
    local deadline=$((SECONDS + timeout))
    local observation_status=0

    while ((SECONDS < deadline)); do
        if python3 -I -B - "${PROJECT_DIR}/tests/process-observer.py" \
            "${pid}" "${expected_start_time}" <<'PY_MOCK_STOP'
import importlib.util
from pathlib import Path
import sys

helper, pid, expected = sys.argv[1:]
spec = importlib.util.spec_from_file_location('mock_stop_observer', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    for attempt in range(2):
        try:
            row = module.process_row(Path(f'/proc/{pid}/stat'))
            break
        except FileNotFoundError:
            sys.exit(0)
        except (ProcessLookupError, InterruptedError):
            if attempt:
                raise
    if row['start'] != int(expected) or module.threads_are_quiescent(int(pid), row):
        sys.exit(0)
    sys.exit(1)
except (OSError, ValueError, IndexError):
    sys.exit(70)
PY_MOCK_STOP
        then
            return 0
        else
            observation_status=$?
        fi
        ((observation_status == 1)) || fail "${label}: process observation is incomplete"
        sleep 0.1
    done

    fail "${label}: process identity remained live for ${timeout}s: ${pid}"
}

wait_for_worker_registration_cleanup() {
    local timeout=$1
    local label=$2
    local deadline=$((SECONDS + timeout))
    local registration_path=''

    while ((SECONDS < deadline)); do
        if ! registration_path=$(find \
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}" \
            -mindepth 1 -maxdepth 1 \
            \( -name '.worker-pgid.*' -o -name '.worker-ready.*' \) \
            -print -quit); then
            fail "${label}: unable to inspect worker registration paths"
        fi
        [[ -z ${registration_path} ]] && return 0
        sleep 0.01
    done

    fail "${label}: registration path remains: ${registration_path}"
}

assert_directory_empty() {
    local directory=$1
    local label=$2
    local unexpected_path=''

    unexpected_path=$(find "${directory}" -mindepth 1 -maxdepth 1 \
        -print -quit)
    [[ -z ${unexpected_path} ]] \
        || fail "${label}: unexpected path remains: ${unexpected_path}"
}

proc_children_fallback_is_observable() {
    local probe_pid
    local children_file="/proc/${BASHPID}/task/${BASHPID}/children"
    local children=''

    (
        # This asynchronous probe must not inherit the test suite's EXIT trap.
        # Otherwise, terminating the probe removes the complete TEST_ROOT.
        trap - EXIT HUP INT TERM
        exec sleep 5
    ) &
    probe_pid=$!
    if [[ -r ${children_file} ]] \
        && { IFS= read -r children <"${children_file}" || [[ -n ${children} ]]; } \
        && [[ " ${children} " == *" ${probe_pid} "* ]]; then
        kill -TERM -- "${probe_pid}" 2>/dev/null || true
        wait "${probe_pid}" 2>/dev/null || true
        return 0
    fi

    kill -TERM -- "${probe_pid}" 2>/dev/null || true
    wait "${probe_pid}" 2>/dev/null || true
    return 1
}

find_test_processes() {
    local observations=''
    local pid start_time
    local -a previous_identities=("${TEST_PROCESS_IDENTITIES[@]:-}")

    if ! observations=$(
        python3 -I -B - \
            "${PROJECT_DIR}/tests/process-observer.py" \
            "${YTDLP_ARIA2_MOCK_PROCESS_TOKEN:?mock process token is absent}" \
            "${TEST_OWNER_BASHPID:-$$}" "${BASHPID}" \
            "${previous_identities[@]}" <<'PY_MOCK_OBSERVATION'
import importlib.util
import os
import sys

helper, token, owner, caller, *previous = sys.argv[1:]
spec = importlib.util.spec_from_file_location('mock_process_observer', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    observed = module.Observer(token, marker_name='YTDLP_ARIA2_MOCK_PROCESS_TOKEN', allow_external=False)
    rows = module.snapshot()
    excluded = {int(owner), int(caller), os.getpid()}
    for pid in excluded:
        if pid in rows:
            observed.known.add((pid, rows[pid]['start']))
    for identity in previous:
        if identity:
            pid, start = identity.split(':')
            observed.known.add((int(pid), int(start)))
    state = observed.sample()
    for pid, row in state['live'].items():
        if int(pid) not in excluded:
            print(pid, row['start'])
except (OSError, ValueError, IndexError):
    print('FAIL: mock process observation is incomplete.', file=sys.stderr)
    sys.exit(70)
PY_MOCK_OBSERVATION
    ); then
        return 70
    fi
    TEST_PROCESS_PIDS=()
    TEST_PROCESS_IDENTITIES=()
    while read -r pid start_time; do
        [[ -n ${pid} ]] || continue
        [[ ${pid} =~ ^[1-9][0-9]*$ && ${start_time} =~ ^[1-9][0-9]*$ ]] || return 70
        TEST_PROCESS_PIDS+=("${pid}")
        TEST_PROCESS_IDENTITIES+=("${pid}:${start_time}")
    done <<<"${observations}"
}

signal_test_processes() {
    local requested_signal=$1
    python3 -I -B - \
        "${PROJECT_DIR}/tests/process-observer.py" \
        "${YTDLP_ARIA2_MOCK_PROCESS_TOKEN:?mock process token is absent}" \
        "${requested_signal}" "${TEST_PROCESS_IDENTITIES[@]:-}" <<'PY_MOCK_SIGNAL'
import importlib.util
import os
from pathlib import Path
import signal
import sys

helper, token, requested, *identities = sys.argv[1:]
spec = importlib.util.spec_from_file_location('mock_signal_observer', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
marker = b'YTDLP_ARIA2_MOCK_PROCESS_TOKEN=' + token.encode()
failed = False
for identity in identities:
    if not identity:
        continue
    pid, start = map(int, identity.split(':'))
    descriptor = None
    try:
        descriptor = os.pidfd_open(pid)
        row = module.process_row(Path(f'/proc/{pid}/stat'))
        if row['start'] != start or module.threads_are_quiescent(pid, row):
            continue
        # A numeric identity alone never authorizes rescue of an unmarked task.
        if not module.token_process_is_live(pid, marker):
            if module.same_process(pid, row):
                failed = True
            continue
        if not module.same_process(pid, row):
            continue
        signal.pidfd_send_signal(descriptor, getattr(signal, 'SIG' + requested))
    except (FileNotFoundError, ProcessLookupError):
        pass
    except (OSError, ValueError, IndexError):
        failed = True
    finally:
        if descriptor is not None:
            os.close(descriptor)
if failed:
    print('FAIL: mock rescue could not authenticate every live identity.', file=sys.stderr)
    sys.exit(70)
PY_MOCK_SIGNAL
}

assert_no_test_processes() {
    local label=$1
    local attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        find_test_processes || fail "${label}: process observation is incomplete"
        ((${#TEST_PROCESS_PIDS[@]} == 0)) && return 0
        sleep 0.1
    done

    printf 'FAIL: %s\n' "${label}" >&2
    printf 'Leaked mock process identity: %s\n' "${TEST_PROCESS_IDENTITIES[@]}" >&2
    cleanup_test_processes || true
    exit 1
}

cleanup_test_processes() {
    local attempt

    find_test_processes || return 70
    ((${#TEST_PROCESS_PIDS[@]} > 0)) || return 0
    signal_test_processes TERM || return 70
    sleep 0.2
    find_test_processes || return 70
    signal_test_processes KILL || return 70
    for ((attempt = 0; attempt < 20; attempt++)); do
        find_test_processes || return 70
        ((${#TEST_PROCESS_PIDS[@]} == 0)) && return 0
        sleep 0.05
    done
    return 70
}

create_mock_test_root() {
    local visible_identity held_identity current_identity

    TEST_ROOT=$(mktemp -d) || return 70
    # Keep the admitted inode alive until cleanup; a pathname alone cannot
    # distinguish our directory from a replacement at the same location.
    if [[ ${TEST_ROOT} != /* || ${TEST_ROOT} == / || -L ${TEST_ROOT} ]] \
        || ! visible_identity=$(stat -c '%d:%i:%u:%a' -- "${TEST_ROOT}") \
        || ! exec {TEST_ROOT_FD}<"${TEST_ROOT}" \
        || ! held_identity=$(stat -Lc '%d:%i:%u:%a' -- "/proc/self/fd/${TEST_ROOT_FD}") \
        || ! current_identity=$(stat -c '%d:%i:%u:%a' -- "${TEST_ROOT}") \
        || [[ ${visible_identity} != "${held_identity}" ||
            ${current_identity} != "${held_identity}" ||
            ${held_identity} != *":${EUID}:700" || ! -d ${TEST_ROOT} || -L ${TEST_ROOT} ]]; then
        printf '%s\n' 'TEST ERROR: cannot authenticate the private test root; preserving it.' >&2
        return 70
    fi
    TEST_ROOT_IDENTITY=${held_identity%:*:*}
}

remove_owned_mock_test_root() {
    # Python 3.10 supports fd-safe rmtree, but not its later dir_fd argument.
    # Only this child changes cwd, anchoring every recursive operation to the
    # retained root. Refuse ambiguous roots before touching their contents.
    python3 -I -B - "${TEST_ROOT}" "${TEST_ROOT_IDENTITY}" "${TEST_ROOT_FD}" <<'PY_MOCK_ROOT_CLEANUP'
import os
import shutil
import stat
import sys


def remove_owned_root(path, identity, descriptor):
    expected = tuple(int(part) for part in identity.split(":"))
    if len(expected) != 2 or not os.path.isabs(path) or path == "/":
        raise ValueError("invalid root identity")
    root_fd = int(descriptor)
    held = os.fstat(root_fd)
    if (held.st_dev, held.st_ino) != expected or not stat.S_ISDIR(held.st_mode):
        raise ValueError("root descriptor mismatch")
    if held.st_uid != os.geteuid() or stat.S_IMODE(held.st_mode) != 0o700:
        raise ValueError("root ownership mismatch")
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError("fd-safe cleanup unavailable")
    parent, name = os.path.split(path)
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        def require_visible_root():
            visible = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if not stat.S_ISDIR(visible.st_mode) or (visible.st_dev, visible.st_ino) != expected:
                raise ValueError("visible root mismatch")

        require_visible_root()
        os.fchdir(root_fd)
        for child in os.listdir(root_fd):
            entry = os.stat(child, dir_fd=root_fd, follow_symlinks=False)
            if stat.S_ISDIR(entry.st_mode):
                shutil.rmtree(child)
            else:
                os.unlink(child, dir_fd=root_fd)
        # The traversal never follows a replacement of the root pathname.
        # This final check/rmdir is not an atomic same-UID adversary boundary.
        require_visible_root()
        os.rmdir(name, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)


try:
    remove_owned_root(*sys.argv[1:])
except (OSError, ValueError):
    print("TEST ERROR: test-root cleanup refused; preserving ambiguous or remaining files.", file=sys.stderr)
    sys.exit(70)
PY_MOCK_ROOT_CLEANUP
}

cleanup_test_root() {
    local status=$?

    trap - EXIT HUP INT TERM

    # Only the Bash process that created TEST_ROOT may remove it. A shell copy
    # used by a subshell, timeout wrapper, or asynchronous probe must never
    # destroy the complete test workspace when that copy exits.
    if [[ ${BASHPID} != "${TEST_OWNER_BASHPID}" ]]; then
        exit "${status}"
    fi

    # Before mock initialization no process registry exists yet.
    if [[ ${1:-processes} == processes ]]; then
        if ! cleanup_test_processes; then
            printf '%s\n' 'TEST ERROR: test-process shutdown unconfirmed; preserving the test root.' >&2
            if ((status == 0)); then
                status=70
            fi
            exec {TEST_ROOT_FD}<&-
            exit "${status}"
        fi
    fi
    if ! remove_owned_mock_test_root; then
        if ((status == 0)); then
            status=70
        fi
    fi
    exec {TEST_ROOT_FD}<&-
    exit "${status}"
}

count_logs() (
    local log_dir="${XDG_STATE_HOME}/yt-dlp-aria2-downloader"
    local -a logs=()

    if [[ ! -d ${log_dir} ]]; then
        printf '0\n'
        return 0
    fi

    shopt -s nullglob
    logs=("${log_dir}"/download-*.log)
    printf '%d\n' "${#logs[@]}"
)

test_mock_cleanup_owner_guard() {
    printf '%s\n' 'Mock scenario: cleanup-owner-guard'
    (
        trap cleanup_test_root EXIT
        :
    )
    [[ -d ${TEST_ROOT} ]] \
        || fail 'A non-owner Bash process removed the complete test root.'
}

initialize_mock_integration() {
    local managed_mock mocked_command resolved_mock

    trap cleanup_test_root EXIT

    TEST_PROCESS_PIDS=()

    export HOME="${HOME_DIR}"
    export XDG_CONFIG_HOME="${HOME_DIR}/.config"
    export XDG_STATE_HOME="${HOME_DIR}/.local/state"
    export XDG_DATA_HOME="${HOME_DIR}/.local/share"
    export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
    export MOCK_OUTPUT_DIR="${OUTPUT_DIR}"
    export MOCK_LIST_ARGS_LOG="${LIST_ARGS_LOG}"
    export MOCK_RUNTIME_MANAGER_LOG
    export MOCK_MANAGED_YTDLP_PATH="${MOCK_BIN}/yt-dlp"
    export MOCK_MANAGED_DENO_PATH="${MOCK_BIN}/deno"
    export PATH="${MOCK_BIN}:/usr/bin:/bin"
    export YTDLP_ARIA2_SKIP_RUNTIME_UPDATE=1
    export YTDLP_ARIA2_YTDLP_BIN="${MOCK_BIN}/yt-dlp"
    export YTDLP_ARIA2_DENO_BIN="${MOCK_BIN}/deno"

    readonly MOCK_NO_DENO_BIN="${TEST_ROOT}/bin-no-deno"
    mkdir -p -- "${MOCK_NO_DENO_BIN}"
    for managed_mock in yt-dlp aria2c zenity env ffmpeg ffprobe ln mv sed setsid; do
        ln -s -- "${MOCK_BIN}/${managed_mock}" "${MOCK_NO_DENO_BIN}/${managed_mock}"
    done

    for mocked_command in yt-dlp aria2c deno zenity env ffmpeg ffprobe ln mv sed setsid; do
        resolved_mock=$(command -v "${mocked_command}")
        assert_equals "${MOCK_BIN}/${mocked_command}" "${resolved_mock}" \
            "${mocked_command} mock selection"
    done
}
