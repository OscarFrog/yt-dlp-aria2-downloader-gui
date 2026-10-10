#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-signals.sh
# Purpose     : Qualify CLI and GUI signal registration, shutdown, and descendants.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    TEST_ROOT PROJECT_DIR OUTPUT_DIR \
    ASSERT_OUTPUT REAL_SETSID CLI_SIGNAL_REGISTRATION_UNDER_TEST \
    MOCK_RUNTIME_MANAGER_LOG MANAGED_ENGINE_UNDER_TEST RUNTIME_DIR \
    GUI_UNDER_TEST GUI_SIGNAL_UNDER_TEST GUI_SIGNAL_REGISTRATION_UNDER_TEST \
    GUI_GROUP_CHILD_UNDER_TEST GUI_GROUP_DESCENDANT_UNDER_TEST ASSERT_STDERR

# Sourced by mock-integration.sh in the same Bash process. Helpers and tests
# share its PROJECT_DIR, private TEST_ROOT paths, command doubles and assertions;
# invocation remains under the entry point's options, traps and group dispatch.

test_mock_signal_cli_download() {
    local cli_engine_pid cli_engine_status cli_signal_log cli_started_marker
    local cli_termination_marker

    # A signal sent only to the CLI wrapper PID must reach the isolated yt-dlp
    # process group and must not leave aria2c/FFmpeg-style descendants behind.
    cli_started_marker="${TEST_ROOT}/cli-worker-started"
    cli_termination_marker="${TEST_ROOT}/cli-worker-terminated"
    cli_signal_log="${TEST_ROOT}/cli-signal.log"
    prepare_argument_log 'cli-signal-forwarding'
    env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_LONG_DOWNLOAD=1 \
        MOCK_STARTED_MARKER="${cli_started_marker}" \
        MOCK_TERMINATION_MARKER="${cli_termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=cli-signal' \
        >"${cli_signal_log}" 2>&1 &
    cli_engine_pid=$!
    wait_for_file "${cli_started_marker}" 10 'CLI worker startup'
    wait_for_worker_registration_cleanup 5 \
        'CLI worker readiness cleanup'
    kill -TERM -- "${cli_engine_pid}"
    cli_engine_status=0
    wait "${cli_engine_pid}" || cli_engine_status=$?
    assert_equals '143' "${cli_engine_status}" 'CLI TERM exit status'
    wait_for_file "${cli_termination_marker}" 10 'CLI child process receives TERM'
    assert_no_test_processes 'CLI signal forwarding left worker processes'
}

test_mock_signal_cli_aria2_diagnostic() {
    local engine_pid engine_status signal_log started_marker termination_marker

    # Cooperative cancellation must drain aria2 diagnostics until its handler
    # completes. Closing either filter early would break the producer's pipe.
    started_marker="${TEST_ROOT}/aria2-signal-diagnostic-started"
    termination_marker="${TEST_ROOT}/aria2-signal-diagnostic-terminated"
    signal_log="${TEST_ROOT}/aria2-signal-diagnostic.log"
    prepare_argument_log 'aria2-signal-diagnostic'
    env MOCK_LONG_DOWNLOAD=1 MOCK_ARIA2_SIGNAL_DIAGNOSTIC=1 \
        MOCK_STARTED_MARKER="${started_marker}" \
        MOCK_TERMINATION_MARKER="${termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=aria2-signal-diagnostic' \
        >"${signal_log}" 2>&1 &
    engine_pid=$!
    wait_for_file "${started_marker}" 10 'aria2 diagnostic producer startup'
    wait_for_worker_registration_cleanup 5 'aria2 diagnostic worker readiness cleanup'
    kill -TERM -- "${engine_pid}"
    engine_status=0
    wait "${engine_pid}" || engine_status=$?
    assert_equals '143' "${engine_status}" 'aria2 diagnostic cancellation status'
    wait_for_file "${termination_marker}" 10 'aria2 diagnostic signal handler completion'
    assert_file_contains "${signal_log}" \
        'Final aria2 diagnostic: [REDACTED_URL]' \
        'aria2 signal diagnostic drains through both filters'
    assert_file_not_contains "${signal_log}" 'cancel-token' \
        'aria2 signal diagnostic remains private'
    assert_no_test_processes 'aria2 signal diagnostic left worker processes'
}

test_mock_signal_cleanup_requires_quiescence() {
    local source_copy="${TEST_ROOT}/download-video-cleanup-quiescence.sh"
    local fixture_script="${TEST_ROOT}/cleanup-quiescence-fixture.sh"
    local case_root diagnostic_log lock_file retained_lock_fd stop_status
    local fixture_status relative_path
    local -a active_paths=(
        worker.pgid worker.pgid.tmp worker.ready worker.ready.tmp
        runtime.attestation url.batch
        output/path.record output/remux.mkv
        output/.yt-dlp-aria2.AbcD1234/plan.json
        output/.yt-dlp-aria2.AbcD1234/item-001.download
    )

    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${source_copy}"
    chmod 0600 -- "${source_copy}"
    cat >"${fixture_script}" <<'EOF_CLEANUP_QUIESCENCE'
#!/usr/bin/env bash
set -euo pipefail

# Load the real cleanup and identity checks without starting a download.
# shellcheck disable=SC1090
source "$1"
fixture_root=$2
MOCK_STOP_STATUS=$3
OUTPUT_LOCK_FD=$4
OUTPUT_DIR="${fixture_root}/output"
mkdir -m 700 -- "${OUTPUT_DIR}"
DOWNLOAD_PGID_FILE="${fixture_root}/worker.pgid"
DOWNLOAD_READY_FILE="${fixture_root}/worker.ready"
RUNTIME_ATTESTATION_TMP="${fixture_root}/runtime.attestation"
YTDLP_BATCH_FILE_TMP="${fixture_root}/url.batch"
PATH_RECORD_TMP="${OUTPUT_DIR}/path.record"
HLS_REMUX_TMP="${OUTPUT_DIR}/remux.mkv"
PRIVATE_ARIA2_STAGING="${OUTPUT_DIR}/.yt-dlp-aria2.AbcD1234"
mkdir -m 700 -- "${PRIVATE_ARIA2_STAGING}"
PRIVATE_ARIA2_PLAN="${PRIVATE_ARIA2_STAGING}/plan.json"
for active_path in \
    "${DOWNLOAD_PGID_FILE}" "${DOWNLOAD_PGID_FILE}.tmp" \
    "${DOWNLOAD_READY_FILE}" "${DOWNLOAD_READY_FILE}.tmp" \
    "${RUNTIME_ATTESTATION_TMP}" "${YTDLP_BATCH_FILE_TMP}" \
    "${PATH_RECORD_TMP}" "${HLS_REMUX_TMP}" "${PRIVATE_ARIA2_PLAN}" \
    "${PRIVATE_ARIA2_STAGING}/item-001.download"; do
    printf 'active state\n' >"${active_path}"
done
printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
    >"${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
open_private_path_record "${PATH_RECORD_TMP}"
get_path_identity HLS_REMUX_TMP_IDENTITY "${HLS_REMUX_TMP}" regular-file
exec {HLS_REMUX_FD}<>"${HLS_REMUX_TMP}"
HLS_REMUX_FD_PATH="/proc/${BASHPID}/fd/${HLS_REMUX_FD}"
get_path_identity PRIVATE_ARIA2_STAGING_IDENTITY \
    "${PRIVATE_ARIA2_STAGING}" directory
get_path_identity PRIVATE_ARIA2_PLAN_IDENTITY \
    "${PRIVATE_ARIA2_PLAN}" regular-file

# Simulate the bounded wait result, without signaling any process or requiring
# an uninterruptible kernel I/O operation. Every cleanup operation stays real.
DOWNLOAD_WORKER_PID=${BASHPID}
stop_download_worker() {
    return "${MOCK_STOP_STATUS}"
}
trap cleanup EXIT
exit 42
EOF_CLEANUP_QUIESCENCE

    printf '%s\n' 'Mock scenario: cleanup-requires-worker-quiescence'
    for stop_status in 1 0; do
        case_root="${TEST_ROOT}/cleanup-quiescence-${stop_status}"
        diagnostic_log="${TEST_ROOT}/cleanup-quiescence-${stop_status}.log"
        mkdir -m 700 -- "${case_root}"
        lock_file="${case_root}/destination.lock"
        # Retain the same open file description as the cleanup subprocess.
        # Closing its copy must preserve our lock; explicit LOCK_UN clears it.
        exec {retained_lock_fd}>"${lock_file}"
        flock --exclusive "${retained_lock_fd}"
        fixture_status=0
        bash "${fixture_script}" "${source_copy}" \
            "${case_root}" "${stop_status}" "${retained_lock_fd}" \
            >"${diagnostic_log}" 2>&1 || fixture_status=$?
        assert_equals 42 "${fixture_status}" \
            "cleanup preserves exit status with stop status ${stop_status}"

        for relative_path in "${active_paths[@]}"; do
            if ((stop_status != 0)); then
                assert_file_has_line "${case_root}/${relative_path}" \
                    'active state' 'unconfirmed stop preserves active file bytes'
            else
                [[ ! -e ${case_root}/${relative_path} ]] \
                    || fail "Confirmed stop retained active state: ${relative_path}"
            fi
        done
        if ((stop_status != 0)); then
            assert_file_contains "${diagnostic_log}" 'Warning:' \
                'unconfirmed stop emits a warning'
            assert_file_contains "${diagnostic_log}" 'preserv' \
                'unconfirmed stop explains state preservation'
            if flock --exclusive --nonblock "${lock_file}" true; then
                fail 'Unconfirmed stop explicitly released the inherited destination lock.'
            fi
        else
            [[ ! -d ${case_root}/output/.yt-dlp-aria2.AbcD1234 ]] \
                || fail 'Confirmed stop retained the owned private staging directory.'
            [[ ! -s ${diagnostic_log} ]] \
                || fail 'Confirmed cleanup emitted an unexpected warning.'
            if flock --exclusive --nonblock "${lock_file}" true; then
                fail 'Cleanup explicitly unlocked a reservation still inherited by a consumer.'
            fi
        fi
        exec {retained_lock_fd}>&-
        flock --exclusive --nonblock "${lock_file}" true \
            || fail 'The reservation remained locked after the last descriptor closed.'
    done
}

test_mock_signal_unbound_directory_registration() {
    local source_copy="${TEST_ROOT}/download-video-unbound-directory-source.sh"
    local harness_path="${TEST_ROOT}/download-video-unbound-directory-harness.sh"
    local resource case_root expected_status created_path
    local -a deleted_replacements=()

    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${source_copy}"
    cat >"${harness_path}" <<'EOF_UNBOUND_DIRECTORY_HARNESS'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090 # The test passes the engine function-only copy.
source "$1"
readonly REGISTRATION_CASE_ROOT=$2
readonly REGISTRATION_RESOURCE=$3
readonly PRIVATE_ARIA2_HELPER=$4
readonly REGISTRATION_OWNER_BASHPID=${BASHPID}
OUTPUT_DIR="${REGISTRATION_CASE_ROOT}/output"
OUTPUT_LOCK_ROOT="${REGISTRATION_CASE_ROOT}/lock"
RESULT_FILE=''
MACHINE_PROGRESS=false
URL='https://example.invalid/registration'
mkdir -m 0700 -- "${OUTPUT_DIR}" "${OUTPUT_LOCK_ROOT}" \
    "${REGISTRATION_CASE_ROOT}/media-root"
trap cleanup EXIT

# Force only workspace selection; acquisition and cleanup use real descriptors
# and the production Python helper. The destination lock has no role here.
acquire_output_lock() { :; }
python3() {
    if [[ $1 == "${PRIVATE_ARIA2_HELPER}" ]]; then
        case ${2:-} in
            media-local-safe) return 1 ;;
            private-root)
                printf '%s\n' "${REGISTRATION_CASE_ROOT}/media-root"
                return 0
                ;;
        esac
    fi
    command python3 "$@"
}

replace_unbound_directory() {
    local candidate=''
    [[ ${BASHPID} == "${REGISTRATION_OWNER_BASHPID}" ]] || return 0
    case ${REGISTRATION_RESOURCE} in
        metadata)
            [[ -n ${PRIVATE_ARIA2_METADATA_FD} && -z ${PRIVATE_ARIA2_METADATA_IDENTITY} ]] \
                && candidate=${PRIVATE_ARIA2_METADATA}
            ;;
        staging)
            [[ -n ${PRIVATE_ARIA2_STAGING_FD} && -z ${PRIVATE_ARIA2_STAGING_IDENTITY} ]] \
                && candidate=${PRIVATE_ARIA2_STAGING}
            ;;
        workspace)
            [[ -n ${MEDIA_WORKSPACE_FD} && -z ${MEDIA_WORKSPACE_IDENTITY} ]] \
                && candidate=${MEDIA_WORKSPACE}
            ;;
    esac
    [[ -n ${candidate} ]] || return 0
    trap - DEBUG
    printf '%s\n' "${candidate}" >"${REGISTRATION_CASE_ROOT}/created-path"
    mv -- "${candidate}" "${REGISTRATION_CASE_ROOT}/original-directory"
    mkdir -m 0700 -- "${candidate}"
    printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
        >"${candidate}/${PRIVATE_ARIA2_STAGING_MARKER}"
    printf 'foreign replacement must survive\n' >"${candidate}/plan.json"
    # Do not interrupt here: the real path probe must first observe the new
    # inode, then reject its mismatch with the descriptor of the old inode.
}

set -T
trap replace_unbound_directory DEBUG
if [[ ${REGISTRATION_RESOURCE} == workspace ]]; then
    prepare_output_directory
else
    prepare_private_work_files
fi
printf 'FAIL: descriptor/path identity mismatch was accepted\n' >&2
exit 99
EOF_UNBOUND_DIRECTORY_HARNESS

    for resource in metadata workspace staging; do
        case_root="${TEST_ROOT}/unbound-directory-${resource}"
        mkdir -m 0700 -- "${case_root}"
        expected_status=73
        [[ ${resource} != staging ]] || expected_status=13
        printf 'Mock scenario: unbound-directory-%s\n' "${resource}"
        assert_status "${expected_status}" \
            "${resource} acquisition rejects mismatched descriptor and pathname" \
            timeout 10 bash "${harness_path}" "${source_copy}" "${case_root}" \
            "${resource}" "${PROJECT_DIR}/private-aria2-plan.py"
        IFS= read -r created_path <"${case_root}/created-path"
        if [[ ! -f ${created_path}/plan.json ]] \
            || [[ $(<"${created_path}/plan.json") != 'foreign replacement must survive' ]]; then
            printf 'Observed deletion of unbound %s replacement during cleanup.\n' "${resource}" >&2
            deleted_replacements+=("${resource}")
        fi
        [[ -d ${case_root}/original-directory ]] \
            || fail "The original ${resource} descriptor's directory was removed."
    done
    ((${#deleted_replacements[@]} == 0)) \
        || fail "Failed acquisition deleted unbound replacement directories: ${deleted_replacements[*]}"
}

test_mock_signal_private_media_registration() {
    local source_copy="${TEST_ROOT}/download-video-media-registration-source.sh"
    local harness_path="${TEST_ROOT}/download-video-media-registration-harness.sh"
    local resource checkpoint signal_name case_root created_path expected_status
    local -a checkpoints=()

    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${source_copy}"
    chmod 0600 -- "${source_copy}"
    cat >"${harness_path}" <<'EOF_MEDIA_REGISTRATION_HARNESS'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090 # The test passes the engine function-only copy.
source "$1"
readonly REGISTRATION_CASE_ROOT=$2
readonly REGISTRATION_RESOURCE=$3
readonly REGISTRATION_CHECKPOINT=$4
readonly REGISTRATION_SIGNAL=$5
readonly PRIVATE_ARIA2_HELPER=$6
readonly REGISTRATION_OWNER_BASHPID=${BASHPID}
OUTPUT_DIR="${REGISTRATION_CASE_ROOT}/output"
OUTPUT_LOCK_ROOT="${REGISTRATION_CASE_ROOT}/lock"
RESULT_FILE=''
MACHINE_PROGRESS=false
mkdir -m 0700 -- "${OUTPUT_DIR}" "${OUTPUT_LOCK_ROOT}"
URL='https://example.invalid/registration'

if [[ ${REGISTRATION_RESOURCE} == remux ]]; then
    printf 'repaired source must survive\n' >"${OUTPUT_DIR}/source.ts"
    PATH_RECORD_TMP="${REGISTRATION_CASE_ROOT}/path-record"
    printf '%s\n' "${OUTPUT_DIR}/source.ts" >"${PATH_RECORD_TMP}"
    open_private_path_record "${PATH_RECORD_TMP}"
fi

trap cleanup EXIT
trap 'request_shutdown HUP 129' HUP
trap 'request_shutdown INT 130' INT
trap 'request_shutdown TERM 143' TERM

inject_media_signal() {
    [[ ! -e ${REGISTRATION_CASE_ROOT}/injected ]] || return 0
    printf '%s\n' "${REGISTRATION_SIGNAL}" >"${REGISTRATION_CASE_ROOT}/injected"
    kill "-${REGISTRATION_SIGNAL}" -- "${REGISTRATION_OWNER_BASHPID}"
}

mktemp() {
    local created=''
    created=$(command mktemp "$@") || return
    if [[ ${created%/*} == "${OUTPUT_DIR}" &&
        (${created##*/} == .yt-dlp-aria2.* ||
            ${created##*/} == .yt-dlp-remux.*.mkv) ]]; then
        printf '%s\n' "${created}" >"${REGISTRATION_CASE_ROOT}/created-path"
        if [[ ${REGISTRATION_CHECKPOINT} == create ]]; then
            # Deliver after creation but before the command substitution has
            # returned the path to the engine's registration variable.
            inject_media_signal
        fi
    fi
    printf '%s\n' "${created}"
}

chmod() {
    local candidate=${!#}
    if [[ ${REGISTRATION_CHECKPOINT} == chmod-failure &&
        -f ${REGISTRATION_CASE_ROOT}/created-path &&
        ${candidate} == "$(<"${REGISTRATION_CASE_ROOT}/created-path")" ]]; then
        inject_media_signal
        return 1
    fi
    command chmod "$@"
}

stat() {
    local candidate=${!#}
    if [[ ${REGISTRATION_CHECKPOINT} == fd-failure && $1 == -Lc &&
        ((${REGISTRATION_RESOURCE} == staging &&
            -n ${PRIVATE_ARIA2_STAGING_FD} &&
            ${candidate} == "/proc/${BASHPID}/fd/${PRIVATE_ARIA2_STAGING_FD}") ||
            (${REGISTRATION_RESOURCE} == remux &&
                -n ${HLS_REMUX_FD_PATH} && ${candidate} == "${HLS_REMUX_FD_PATH}")) ]]; then
        inject_media_signal
        return 1
    fi
    command stat "$@"
}

replace_media_path() {
    if [[ ${REGISTRATION_RESOURCE} == staging ]]; then
        mv -- "${PRIVATE_ARIA2_STAGING}" "${REGISTRATION_CASE_ROOT}/original-staging"
        mkdir -m 0700 -- "${PRIVATE_ARIA2_STAGING}"
        # A plausible marker and allowed child cannot authenticate a changed
        # directory, even when its identity is observed after the FD opened.
        printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
            >"${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
        printf 'foreign replacement must survive\n' \
            >"${PRIVATE_ARIA2_STAGING}/item-001.download"
    else
        mv -- "${HLS_REMUX_TMP}" "${REGISTRATION_CASE_ROOT}/original-remux"
        printf 'foreign replacement must survive\n' >"${HLS_REMUX_TMP}"
    fi
}

inject_media_checkpoint() {
    local command_under_test=$1
    local matched=false
    local complete=false

    [[ ${BASHPID} == "${REGISTRATION_OWNER_BASHPID}" &&
        ! -e ${REGISTRATION_CASE_ROOT}/injected ]] || return 0
    if [[ ${REGISTRATION_RESOURCE} == staging ]]; then
        if [[ -n ${PRIVATE_ARIA2_STAGING_IDENTITY} &&
            -n ${PRIVATE_ARIA2_STAGING_FD} &&
            -f ${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER} ]]; then
            complete=true
        fi
        case ${REGISTRATION_CHECKPOINT} in
            chmod)
                [[ ${command_under_test} == 'exec {PRIVATE_ARIA2_STAGING_FD}'* ]] \
                    && matched=true
                ;;
            fd | replacement-before-identity)
                [[ -n ${PRIVATE_ARIA2_STAGING_FD} &&
                    -z ${PRIVATE_ARIA2_STAGING_IDENTITY} ]] && matched=true
                ;;
            identity)
                [[ -n ${PRIVATE_ARIA2_STAGING_IDENTITY} ]] && matched=true
                ;;
            marker)
                [[ ${command_under_test} == 'chmod 600 -- "${staging_marker_path}"' &&
                    ${staging_marker_path:-} == "${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}" ]] \
                    && matched=true
                ;;
            finish | replacement)
                [[ ${complete} == true &&
                    (${command_under_test} == finish_signal_registration ||
                        ${command_under_test} == PRIVATE_ARIA2_PLAN=*) ]] && matched=true
                ;;
        esac
    else
        [[ -n ${HLS_REMUX_TMP_IDENTITY} && -n ${HLS_REMUX_FD_PATH} ]] \
            && complete=true
        case ${REGISTRATION_CHECKPOINT} in
            chmod)
                [[ ${command_under_test} == 'get_path_identity HLS_REMUX_TMP_IDENTITY '* ]] \
                    && matched=true
                ;;
            identity)
                [[ -n ${HLS_REMUX_TMP_IDENTITY} && -z ${HLS_REMUX_FD} ]] && matched=true
                ;;
            fd)
                [[ -n ${HLS_REMUX_FD} && -z ${HLS_REMUX_FD_PATH} ]] && matched=true
                ;;
            replacement-before-fd)
                [[ ${command_under_test} == 'exec {HLS_REMUX_FD}'* ]] && matched=true
                ;;
            finish | replacement)
                [[ ${complete} == true &&
                    (${command_under_test} == finish_signal_registration ||
                        ${command_under_test} == run_supervised_command*) ]] && matched=true
                ;;
        esac
    fi
    [[ ${matched} == true ]] || return 0
    trap - DEBUG
    if [[ ${REGISTRATION_CHECKPOINT} == replacement* ]]; then
        replace_media_path
    fi
    inject_media_signal
}

# Only the duration probe is a stand-in. Acquisition, authentication, signal
# handlers and cleanup are loaded unchanged from the production engine.
probe_duration_microseconds() { printf -v "$1" '%s' 1000000; }
run_supervised_command() {
    printf 'FAIL: remux command started before signal replay\n' >&2
    exit 99
}
set -T
trap 'inject_media_checkpoint "${BASH_COMMAND}"' DEBUG
if [[ ${REGISTRATION_RESOURCE} == staging ]]; then
    prepare_private_work_files
else
    remux_hls_result
fi
printf 'FAIL: test did not inject a signal\n' >&2
exit 99
EOF_MEDIA_REGISTRATION_HARNESS
    chmod 0600 -- "${harness_path}"

    for resource in staging remux; do
        checkpoints=(create chmod identity fd finish replacement chmod-failure fd-failure)
        if [[ ${resource} == staging ]]; then
            checkpoints+=(marker replacement-before-identity)
        else
            checkpoints+=(replacement-before-fd)
        fi
        for checkpoint in "${checkpoints[@]}"; do
            for signal_name in HUP INT TERM; do
                case_root="${TEST_ROOT}/media-registration-${resource}-${checkpoint}-${signal_name}"
                mkdir -m 0700 -- "${case_root}"
                case ${signal_name} in
                    HUP) expected_status=129 ;;
                    INT) expected_status=130 ;;
                    TERM) expected_status=143 ;;
                    *) fail "Unsupported media-registration signal: ${signal_name}" ;;
                esac
                printf 'Mock scenario: media-registration-%s-%s-%s\n' \
                    "${resource}" "${checkpoint}" "${signal_name}"
                assert_status "${expected_status}" \
                    "${resource} ${checkpoint} acquisition preserves ${signal_name} status" \
                    timeout 10 bash "${harness_path}" "${source_copy}" "${case_root}" \
                    "${resource}" "${checkpoint}" "${signal_name}" \
                    "${PROJECT_DIR}/private-aria2-plan.py"
                assert_file_has_line "${case_root}/injected" "${signal_name}" \
                    'the requested acquisition signal was actually delivered'
                IFS= read -r created_path <"${case_root}/created-path"
                case ${checkpoint} in
                    replacement*)
                        if [[ ${resource} == staging ]]; then
                            assert_file_has_line "${created_path}/item-001.download" \
                                'foreign replacement must survive' \
                                'acquisition cleanup preserves a replaced staging directory'
                        else
                            assert_file_has_line "${created_path}" \
                                'foreign replacement must survive' \
                                'acquisition cleanup preserves a replaced remux inode'
                        fi
                        ;;
                    chmod-failure | fd-failure)
                        [[ -e ${created_path} ]] \
                            || fail "Failed authentication deleted ambiguous ${resource}: ${created_path}"
                        assert_text_contains "${ASSERT_OUTPUT}" 'preserving' \
                            'failed authentication reports conservative preservation'
                        ;;
                    *)
                        [[ ! -e ${created_path} && ! -L ${created_path} ]] \
                            || fail "Acquisition ${signal_name} stranded authenticated ${resource}: ${created_path}"
                        ;;
                esac
                assert_directory_empty "${case_root}/lock" \
                    'media acquisition signal cleans the authenticated metadata parent'
                if [[ ${resource} == remux ]]; then
                    assert_file_has_line "${case_root}/output/source.ts" \
                        'repaired source must survive' \
                        'remux acquisition cancellation preserves the repaired source'
                fi
            done
        done
    done
}

test_mock_signal_private_record_registration() {
    local source_copy="${TEST_ROOT}/download-video-record-registration-source.sh"
    local harness_path="${TEST_ROOT}/download-video-record-registration-harness.sh"
    local record_kind=''
    local checkpoint=''
    local case_root=''
    local expected_status=0
    local record_path=''
    local record_list=''
    local record_count=0
    local batch_path=''

    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${source_copy}"
    chmod 0600 -- "${source_copy}"
    cat >"${harness_path}" <<'EOF_RECORD_REGISTRATION_HARNESS'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090 # The test passes the engine function-only copy.
source "${1}"
readonly PRIVATE_ARIA2_HELPER=${5}
OUTPUT_DIR="${2}/output"
OUTPUT_LOCK_ROOT="${2}/lock"
RESULT_FILE=''
if [[ ${3} == external ]]; then
    RESULT_FILE="${2}/result/result.txt"
fi
URL='https://example.invalid/review'
mkdir -m 0700 -- "${OUTPUT_DIR}" "${OUTPUT_LOCK_ROOT}" "${2}/result"
checkpoint=${4}
readonly REGISTRATION_OWNER_BASHPID="${BASHPID}"
trap cleanup EXIT
trap 'request_shutdown HUP 129' HUP
trap 'request_shutdown TERM 143' TERM
set -T

inject_signal() {
    local matched=false
    local replacement=''

    [[ ${BASHPID} == "${REGISTRATION_OWNER_BASHPID}" ]] || return 0
    case ${checkpoint} in
        creation)
            if [[ ${BASH_COMMAND} == 'RESULT_FILE_TMP=$(mktemp'* ||
                ${BASH_COMMAND} == 'INTERNAL_PATH_FILE_TMP=$(mktemp'* ]]; then
                matched=true
            fi
            ;;
        alias)
            [[ ${BASH_COMMAND} == PATH_RECORD_TMP=* ]] && matched=true
            ;;
        open)
            [[ ${BASH_COMMAND} == 'open_private_path_record "${PATH_RECORD_TMP}"' ]] \
                && matched=true
            ;;
        descriptor)
            [[ ${BASH_COMMAND} == PATH_RECORD_FD_PATH=* ]] && matched=true
            ;;
        finish | repeat | replacement)
            if [[ ${BASH_COMMAND} == finish_signal_registration &&
                -n ${PATH_RECORD_IDENTITY} && -n ${PATH_RECORD_FD_PATH} ]]; then
                matched=true
            fi
            ;;
    esac
    [[ ${matched} == true ]] || return 0
    trap - DEBUG
    if [[ ${checkpoint} == replacement ]]; then
        replacement=$(mktemp --tmpdir="${PATH_RECORD_TMP%/*}" \
            '.foreign-record.XXXXXXXX')
        printf 'foreign replacement must survive\n' >"${replacement}"
        mv -f -- "${replacement}" "${PATH_RECORD_TMP}"
    fi
    if [[ ${checkpoint} == repeat ]]; then
        kill -HUP -- "${REGISTRATION_OWNER_BASHPID}"
    fi
    kill -TERM -- "${REGISTRATION_OWNER_BASHPID}"
}

trap inject_signal DEBUG
prepare_private_work_files
printf 'FAIL: test did not inject a signal\n' >&2
exit 99
EOF_RECORD_REGISTRATION_HARNESS
    chmod 0600 -- "${harness_path}"

    for record_kind in external internal; do
        for checkpoint in creation alias open descriptor finish repeat replacement; do
            case_root="${TEST_ROOT}/record-registration-${record_kind}-${checkpoint}"
            mkdir -m 0700 -- "${case_root}"
            expected_status=143
            if [[ ${checkpoint} == repeat ]]; then
                expected_status=129
            fi
            printf 'Mock scenario: record-registration-%s-%s\n' \
                "${record_kind}" "${checkpoint}"
            assert_status "${expected_status}" \
                "${record_kind} result-record ${checkpoint} registration signal" \
                bash "${harness_path}" "${source_copy}" "${case_root}" \
                "${record_kind}" "${checkpoint}" "${PROJECT_DIR}/private-aria2-plan.py"
            record_list="${case_root}/record-paths.bin"
            if ! find "${case_root}" -type f \
                \( -name '.yt-dlp-result.*' -o -name '.yt-dlp-path.*' \) \
                -print0 >"${record_list}"; then
                fail 'Unable to enumerate result records after initialization signal.'
            fi
            record_count=0
            while IFS= read -r -d '' record_path; do
                ((record_count += 1))
                [[ ${checkpoint} == replacement ]] \
                    || fail "Initialization signal stranded a result record: ${record_path}"
                assert_file_has_line "${record_path}" \
                    'foreign replacement must survive' \
                    'initialization cleanup preserves the replacement inode'
            done <"${record_list}"
            if [[ ${checkpoint} == replacement ]]; then
                assert_equals 1 "${record_count}" \
                    'initialization cleanup preserves exactly one replacement'
                assert_text_contains "${ASSERT_OUTPUT}" \
                    'preserving a changed temporary path record' \
                    'initialization replacement preservation diagnostic'
            else
                assert_equals 0 "${record_count}" \
                    'initialization signal removes every authenticated result record'
            fi
            if [[ ${record_kind} == internal && ${checkpoint} == replacement ]]; then
                # The internal record now lives in the private metadata tree.
                # Its replaced inode must preserve that parent while no URL
                # batch may have been created before deferred signal replay.
                batch_path=$(find "${case_root}/lock" -name '.url-batch.*' -print -quit) \
                    || fail 'Unable to inspect private state after the initialization signal.'
                [[ -z ${batch_path} ]] \
                    || fail 'Initialization signal proceeded to private URL creation.'
            else
                assert_directory_empty "${case_root}/lock" \
                    'initialization signal cleans the authenticated metadata tree'
            fi
        done
    done
}

test_mock_signal_cli_lost_group_leader() {
    # A vanished leader revokes signaling authority, not evidence that a live
    # descendant still owns the private files and inherited destination lock.
    python3 -I - "${PROJECT_DIR}" "${TEST_ROOT}" "${REAL_SETSID}" <<'PY_LOST_GROUP_LEADER'
import ctypes
import errno
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from unittest import mock

project, root = map(Path, sys.argv[1:3])
real_setsid = sys.argv[3]
requested_signal = None

def remember_signal(number, _frame):
    global requested_signal
    requested_signal = requested_signal or number

def check_interruption():
    if requested_signal:
        raise SystemExit(128 + requested_signal)

for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, remember_signal)

source = (project / "download-video.sh").read_text(encoding="utf-8")
entrypoint = 'main "$@"\n'
assert source.endswith(entrypoint)
absence_probe = source.split("<<'PY_GROUP_ABSENT'\n", 1)[1].split("\nPY_GROUP_ABSENT", 1)[0]
for outcome, expected_status in (
    (None, 1),
    (ProcessLookupError(errno.ESRCH, "fixture missing group"), 0),
    (PermissionError(errno.EPERM, "fixture permission denied"), 1),
    (OSError(errno.EIO, "fixture unexpected probe failure"), 1),
):
    with mock.patch.object(sys, "argv", ["group-absence-fixture", "424242"]), \
         mock.patch("os.kill", side_effect=outcome) as probe:
        try:
            exec(compile(absence_probe, "group-absence-fixture", "exec"), {})
        except SystemExit as result:
            assert result.code == expected_status, (outcome, result.code)
        else:
            raise AssertionError("group absence probe did not return its status")
        probe.assert_called_once_with(-424242, 0)
source_copy = root / "lost-leader-engine-functions.sh"
source_copy.write_text(source[:-len(entrypoint)], encoding="utf-8")
source_copy.chmod(0o600)

# Adopt the deliberately orphaned descendant so cleanup can reap it directly.
# Pipe EOF releases every fixture child even when an assertion fails early.
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "unable to enable child subreaping")

child_program = root / "lost-leader-child.py"
child_program.write_text(r'''
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
leader_release, descendant_release, lock_fd = map(int, sys.argv[2:5])
child = os.fork()
if child:
    os.close(descendant_release)
    os.read(leader_release, 1)
    os._exit(0)
os.close(leader_release)
with open(os.devnull, "wb", buffering=0) as sink:
    os.dup2(sink.fileno(), 1)
    os.dup2(sink.fileno(), 2)
os.fstat(lock_fd)
fields = Path("/proc/self/stat").read_text().rsplit(") ", 1)[1].split()
(root / "descendant").write_text(
    f"{os.getpid()} {os.getppid()} {os.getpgrp()} {os.getsid(0)} {fields[19]} {lock_fd}\n",
    encoding="ascii",
)
os.read(descendant_release, 1)
os._exit(0)
''', encoding="utf-8")
child_program.chmod(0o600)

wrapper = root / "lost-leader-wrapper.sh"
wrapper.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
fixture_root=$2
leader_release=$3
descendant_release=$4
observation_release=$5
fixture_mode=$6
setsid_binary=$7
python_binary=$8
child_program=$9
REUSE_CURRENT_SESSION=false
OUTPUT_LOCK_ROOT=${fixture_root}
YTDLP_BATCH_FILE_TMP="${fixture_root}/active.url"
printf 'active private state\n' >"${YTDLP_BATCH_FILE_TMP}"
exec {OUTPUT_LOCK_FD}>"${fixture_root}/destination.lock"
flock --exclusive "${OUTPUT_LOCK_FD}"
trap cleanup EXIT
trap 'exit 143' TERM
"${setsid_binary}" --wait "${python_binary}" "${child_program}" \
    "${fixture_root}" "${leader_release}" "${descendant_release}" \
    "${OUTPUT_LOCK_FD}" &
DOWNLOAD_WORKER_PID=$!
process_is_direct_child_of "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
    DOWNLOAD_WORKER_START_TIME true
for _ in {1..500}; do
    if [[ -s ${fixture_root}/descendant ]] \
        && process_is_session_group_leader "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
            DOWNLOAD_WORKER_PGID_START_TIME false; then
        break
    fi
    sleep 0.01
done
[[ -n ${DOWNLOAD_WORKER_PGID_START_TIME} ]]
if [[ ${fixture_mode} == unadopted ]]; then
    DOWNLOAD_WORKER_PGID_START_TIME=''
else
    DOWNLOAD_WORKER_PGID=${DOWNLOAD_WORKER_PID}
fi
DOWNLOAD_PGID_FILE="${fixture_root}/worker.pgid"
DOWNLOAD_READY_FILE="${fixture_root}/worker.ready"
printf '%s\n' "${DOWNLOAD_WORKER_PID}" >"${DOWNLOAD_PGID_FILE}"
printf '%s\n' "${DOWNLOAD_WORKER_PID}" >"${DOWNLOAD_READY_FILE}"
printf '%s\n' "${DOWNLOAD_WORKER_PID}" >"${fixture_root}/registered"
wait "${DOWNLOAD_WORKER_PID}"
[[ ! -e /proc/${DOWNLOAD_WORKER_PID}/stat ]]

# Record and reject every actual signaling attempt after authority is lost.
# Read-only kill -0 probes still consult the real kernel process table.
kill() {
    if [[ ${1:-} != -0 ]]; then
        printf '%s\n' "$*" >>"${fixture_root}/signal-attempts"
        return 1
    fi
    builtin kill "$@"
}
if [[ ${fixture_mode} == signal ]]; then
    signal_download_worker TERM
fi
wait_status=0
wait_for_download_exit 2 || wait_status=$?
printf '%s\n' "${wait_status}" >"${fixture_root}/wait-observed"
stop_status=0
stop_download_worker || stop_status=$?
printf '%s\n' "${stop_status}" >"${fixture_root}/stop-observed"
run_supervised_command bash -c 'printf started >"$1"' bash \
    "${fixture_root}/unexpected-command"
replacement_status=${DOWNLOAD_STATUS}
cleanup_status=0
(trap cleanup EXIT; exit 7) || cleanup_status=$?
printf '%s %s %s %s\n' "${wait_status}" "${stop_status}" \
    "${cleanup_status}" "${replacement_status}" >"${fixture_root}/observed"
IFS= read -r -u "${observation_release}" _ || true
wait_for_download_exit 30
printf 'quiescent\n' >"${fixture_root}/quiescent"
''', encoding="utf-8")
wrapper.chmod(0o700)

def process_fields(pid):
    return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()

def wait_for_record(path, process, count, *, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        check_interruption()
        try:
            fields = path.read_text(encoding="ascii").split()
        except FileNotFoundError:
            fields = []
        if len(fields) == count:
            return list(map(int, fields))
        if process.poll() is not None:
            stdout, stderr = process.communicate(timeout=2)
            raise AssertionError((path.name, process.returncode, stdout, stderr))
        time.sleep(0.01)
    raise AssertionError(f"fixture did not reach {path.name}")

def reap_descendant(pid, *, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            observed, _status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if observed == pid:
            return
        time.sleep(0.01)
    raise AssertionError("fixture descendant did not exit after pipe release")

for mode in ("wait", "signal", "unadopted"):
    case_root = root / f"lost-leader-{mode}"
    case_root.mkdir(mode=0o700)
    pipes = [os.pipe() for _ in range(3)]
    reads = [pair[0] for pair in pipes]
    writes = [pair[1] for pair in pipes]
    process = None
    descendant_pid = None
    try:
        process = subprocess.Popen(
            ["bash", str(wrapper), str(source_copy), str(case_root),
             *map(str, reads), mode, real_setsid, sys.executable, str(child_program)],
            pass_fds=tuple(reads), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        for descriptor in reads:
            os.close(descriptor)
        reads.clear()
        leader_pid, = wait_for_record(case_root / "registered", process, 1)
        descendant = wait_for_record(case_root / "descendant", process, 6)
        descendant_pid, parent_pid, pgid, sid, start_time, inherited_lock = descendant
        leader = process_fields(leader_pid)
        assert leader[0] not in {"Z", "X"}
        assert list(map(int, leader[1:4])) == [process.pid, leader_pid, leader_pid]
        assert (parent_pid, pgid, sid) == (leader_pid, leader_pid, leader_pid)
        original_child = process_fields(descendant_pid)
        assert int(original_child[19]) == start_time and original_child[0] not in {"Z", "X"}
        assert os.stat(f"/proc/{descendant_pid}/fd/{inherited_lock}").st_ino == (case_root / "destination.lock").stat().st_ino
        os.write(writes[0], b"x")
        # Stop and EXIT cleanup each perform a full bounded shutdown sequence
        # with procfs scans. Observe their boundaries rather than imposing one
        # shared deadline on both independent sequences.
        wait_for_record(case_root / "wait-observed", process, 1)
        wait_for_record(case_root / "stop-observed", process, 1)
        observed = wait_for_record(case_root / "observed", process, 4)
        wait_status, stop_status, cleanup_status, replacement_status = observed
        assert wait_status != 0, (mode, "lost leader made wait claim quiescence", observed)
        assert stop_status != 0, (mode, "lost leader made stop claim quiescence", observed)
        assert cleanup_status == 7, "cleanup replaced the original failure status"
        assert replacement_status == 125 and not (case_root / "unexpected-command").exists(), "a new command discarded unresolved group state"
        assert (case_root / "active.url").read_text() == "active private state\n", "cleanup removed live private state"
        for filename in ("worker.pgid", "worker.ready"):
            assert (case_root / filename).read_text() == f"{leader_pid}\n", "cleanup removed unresolved readiness state"
        assert not (case_root / "signal-attempts").exists(), "lost leader authorized an actual signal"
        child = process_fields(descendant_pid)
        assert child[0] not in {"Z", "X"} and int(child[19]) == start_time
        assert list(map(int, child[2:4])) == [leader_pid, leader_pid]
        with (case_root / "destination.lock").open("rb") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                assert error.errno in {errno.EACCES, errno.EAGAIN}
            else:
                raise AssertionError("unconfirmed cleanup explicitly unlocked the inherited file description")
        os.write(writes[1], b"x")
        reap_descendant(descendant_pid)
        descendant_pid = None
        os.write(writes[2], b"\n")
        stdout, stderr = process.communicate(timeout=10)
        check_interruption()
        assert process.returncode == 0, (mode, process.returncode, stdout, stderr)
        assert b"shutdown could not be confirmed" in stderr and b"preserving active temporary files" in stderr
        assert b"leader identity was lost" in stderr
        assert (case_root / "quiescent").read_text() == "quiescent\n"
        assert not (case_root / "active.url").exists(), "confirmed shutdown retained active private state"
        for filename in ("worker.pgid", "worker.ready"):
            assert not (case_root / filename).exists(), "confirmed shutdown retained readiness state"
    finally:
        for descriptor in reads + writes:
            os.close(descriptor)
        if process is not None:
            try:
                process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                # Popen still owns this unreaped direct child; never signal a
                # recycled numeric process group while unwinding a failed test.
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=5)
        if descendant_pid is not None:
            reap_descendant(descendant_pid)
        # Also reap a child whose readiness record was not reached on failure.
        cleanup_deadline = time.monotonic() + 5
        while True:
            try:
                adopted, _status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if adopted == 0:
                if time.monotonic() >= cleanup_deadline:
                    raise AssertionError("fixture cleanup left an adopted live child")
                time.sleep(0.01)
    check_interruption()
    print(f"Lost CLI group leader ({mode}): refusal, state/lock preservation and eventual quiescence passed.")
PY_LOST_GROUP_LEADER
}

test_mock_signal_transport_preserves_active_input() {
    # The transport caller must not unlink authentication inputs while its
    # supervisor still reports an unresolved worker or process group.
    python3 -I -B - "${PROJECT_DIR}" "${TEST_ROOT}" <<'PY_ACTIVE_TRANSPORT_INPUT'
import json
from pathlib import Path
import subprocess
import sys

project, root = map(Path, sys.argv[1:3])
source = (project / "download-video.sh").read_text(encoding="utf-8")
entrypoint = 'main "$@"\n'
assert source.endswith(entrypoint)
source_copy = root / "active-transport-engine-functions.sh"
source_copy.write_text(source[:-len(entrypoint)], encoding="utf-8")
source_copy.chmod(0o600)
wrapper = r'''
set -euo pipefail
source "$1"
fixture_root=$2
fixture_mode=$3
PRIVATE_ARIA2_HELPER=$4
PRIVATE_TRANSPORT=direct
MACHINE_PROGRESS=false
YOUTUBE_HLS_FIREFOX=false
ARIA2_HTTPS_DIRECT_SAFE=false
MODE=audio
OUTPUT_DIR="${fixture_root}/output"
FINAL_OUTPUT_DIR=${OUTPUT_DIR}
FINAL_OUTPUT_IDENTITY=$(stat -c '%d:%i' -- "${FINAL_OUTPUT_DIR}")
PRIVATE_ARIA2_STAGING="${OUTPUT_DIR}/.yt-dlp-aria2-test"
PRIVATE_ARIA2_METADATA="${fixture_root}/private"
PRIVATE_ARIA2_PLAN="${PRIVATE_ARIA2_METADATA}/plan.json"
PRIVATE_ARIA2_INPUT="${PRIVATE_ARIA2_METADATA}/aria2.input"
PRIVATE_ARIA2_MANIFEST="${PRIVATE_ARIA2_METADATA}/manifest.json"
PRIVATE_ARIA2_COOKIE_JAR="${PRIVATE_ARIA2_METADATA}/cookies.txt"
YTDLP_BATCH_FILE_TMP="${PRIVATE_ARIA2_METADATA}/url.txt"
ARIA2_DIRECT_OPTIONS=()
fixture_files=(
    "${PRIVATE_ARIA2_INPUT}" "${PRIVATE_ARIA2_MANIFEST}"
    "${PRIVATE_ARIA2_COOKIE_JAR}" "${YTDLP_BATCH_FILE_TMP}"
)
if [[ ${fixture_mode} == native-* ]]; then
    PRIVATE_TRANSPORT=native
    YTDLP_BIN=unused-native-fixture
    YT_DLP_OPTIONS=()
    fixture_files=("${PRIVATE_ARIA2_COOKIE_JAR}" "${YTDLP_BATCH_FILE_TMP}")
fi
record_unconfirmed_supervision() {
    sha256sum -- "${fixture_files[@]}" >"${fixture_root}/before.sha256"
    stat -c '%d:%i:%s:%y:%z' -- "${fixture_files[@]}" >"${fixture_root}/before.stat"
    DOWNLOAD_STATUS=125
    # Numeric sentinels model retained state only; no process is launched or
    # signaled by this caller-focused fixture.
    if [[ ${fixture_mode} == pid || ${fixture_mode} == native-pid ]]; then
        DOWNLOAD_WORKER_PID=424242
    else
        DOWNLOAD_WORKER_PGID=424242
    fi
}
run_supervised_command() {
    [[ ${PRIVATE_TRANSPORT} == direct ]]
    record_unconfirmed_supervision
}
run_supervised_ytdlp() {
    [[ ${PRIVATE_TRANSPORT} == native ]] || {
        printf 'unexpected native replay\n' >&2
        return 1
    }
    record_unconfirmed_supervision
}
execute_selected_transport
[[ ${DOWNLOAD_STATUS} == 125 ]]
if [[ ${PRIVATE_TRANSPORT} == direct ]]; then
    [[ -n ${PRIVATE_ARIA2_INPUT} && -n ${PRIVATE_ARIA2_INPUT_IDENTITY} ]]
    [[ -n ${PRIVATE_ARIA2_MANIFEST} && -n ${PRIVATE_ARIA2_MANIFEST_IDENTITY} ]]
else
    [[ ! -e ${PRIVATE_ARIA2_INPUT} && ! -e ${PRIVATE_ARIA2_MANIFEST} ]]
fi
[[ -n ${YTDLP_BATCH_FILE_TMP} ]]
if [[ ${fixture_mode} == pid || ${fixture_mode} == native-pid ]]; then
    [[ ${DOWNLOAD_WORKER_PID} == 424242 && -z ${DOWNLOAD_WORKER_PGID} ]]
else
    [[ ${DOWNLOAD_WORKER_PGID} == 424242 && -z ${DOWNLOAD_WORKER_PID} ]]
fi
sha256sum -- "${fixture_files[@]}" >"${fixture_root}/after.sha256"
stat -c '%d:%i:%s:%y:%z' -- "${fixture_files[@]}" >"${fixture_root}/after.stat"
cmp -- "${fixture_root}/before.sha256" "${fixture_root}/after.sha256"
cmp -- "${fixture_root}/before.stat" "${fixture_root}/after.stat"
'''
for mode in ("pid", "pgid", "native-pid", "native-pgid"):
    case_root = root / f"active-transport-{mode}"
    case_root.mkdir(mode=0o700)
    output = case_root / "output"
    output.mkdir(mode=0o700)
    (output / ".yt-dlp-aria2-test").mkdir(mode=0o700)
    private = case_root / "private"
    private.mkdir(mode=0o700)
    plan = {"requested_downloads": [{
        "filename": str(output / "audio.m4a"),
        "url": "http://example.invalid/audio",
        "protocol": "http",
        "http_headers": {"User-Agent": "private transport fixture"},
    }]}
    for name, content in (("plan.json", json.dumps(plan)),
                          ("cookies.txt", "# Netscape HTTP Cookie File\n"),
                          ("url.txt", "http://example.invalid/watch\n")):
        path = private / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)
    completed = subprocess.run(
        ["bash", "-c", wrapper, "active-transport-fixture", str(source_copy),
         str(case_root), mode, str(project / "private-aria2-plan.py")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=15,
    )
    assert completed.returncode == 0, (mode, completed.returncode, completed.stdout, completed.stderr)
    assert not (output / "audio.m4a").exists(), "unconfirmed transport published output"
    print(f"Unconfirmed transport ({mode}): private inputs and URL batch preserved unchanged.")
PY_ACTIVE_TRANSPORT_INPUT
}

test_mock_signal_cli_leader_exit_descendant() {
    local cli_engine_pid cli_engine_status descendant_pid descendant_signal_log
    local descendant_started_marker descendant_start_time descendant_term_marker
    local descendant_termination_marker elapsed_milliseconds
    local signal_finished_at signal_started_at

    # Regression guard: keep the authenticated session leader alive after the
    # primary command exits while a same-session descendant remains. The
    # retained leader prevents PGID reuse and authorizes a later wrapper signal.
    descendant_started_marker="${TEST_ROOT}/leader-exit-descendant-started"
    descendant_termination_marker="${TEST_ROOT}/leader-exit-descendant-terminated"
    descendant_signal_log="${TEST_ROOT}/leader-exit-descendant.log"
    rm -f -- \
        "${descendant_started_marker}" \
        "${descendant_termination_marker}" \
        "${descendant_signal_log}"
    prepare_argument_log 'cli-leader-exit-descendant'
    env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_EXIT_WITH_LIVE_DESCENDANT=1 \
        MOCK_DESCENDANT_STARTED_MARKER="${descendant_started_marker}" \
        MOCK_DESCENDANT_TERMINATION_MARKER="${descendant_termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=leader-exit-descendant' \
        >"${descendant_signal_log}" 2>&1 &
    cli_engine_pid=$!
    wait_for_file "${descendant_started_marker}" 10 \
        'leader-exit descendant startup'
    IFS= read -r descendant_pid <"${descendant_started_marker}"
    [[ ${descendant_pid} =~ ^[1-9][0-9]*$ ]] \
        || fail "Invalid leader-exit descendant PID: ${descendant_pid}"
    sleep 0.2
    kill -0 -- "${descendant_pid}" 2>/dev/null \
        || fail 'The leader-exit test descendant did not remain alive.'
    kill -0 -- "${cli_engine_pid}" 2>/dev/null \
        || fail 'The CLI released its worker group before quiescence.'
    kill -TERM -- "${cli_engine_pid}"
    cli_engine_status=0
    wait "${cli_engine_pid}" || cli_engine_status=$?
    assert_equals 143 "${cli_engine_status}" \
        'CLI leader-exit descendant TERM status'
    wait_for_file "${descendant_termination_marker}" 10 \
        'leader-exit descendant receives TERM'
    assert_no_test_processes \
        'leader-exit descendant signal left worker processes'

    # A signal-resistant descendant requires the repeated request to KILL the
    # still-authenticated group immediately; the first TERM must not destroy
    # the sentinel and leave the numeric PGID unauthenticated.
    descendant_term_marker="${TEST_ROOT}/leader-exit-resistant-descendant-term"
    rm -f -- \
        "${descendant_started_marker}" \
        "${descendant_term_marker}" \
        "${descendant_termination_marker}" \
        "${descendant_signal_log}"
    prepare_argument_log 'cli-leader-exit-resistant-descendant'
    env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_EXIT_WITH_LIVE_DESCENDANT=1 \
        MOCK_DESCENDANT_IGNORE_TERM=1 \
        MOCK_DESCENDANT_STARTED_MARKER="${descendant_started_marker}" \
        MOCK_DESCENDANT_TERM_MARKER="${descendant_term_marker}" \
        MOCK_DESCENDANT_TERMINATION_MARKER="${descendant_termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=leader-exit-resistant-descendant' \
        >"${descendant_signal_log}" 2>&1 &
    cli_engine_pid=$!
    wait_for_file "${descendant_started_marker}" 10 \
        'leader-exit resistant descendant startup'
    IFS= read -r descendant_pid <"${descendant_started_marker}"
    [[ ${descendant_pid} =~ ^[1-9][0-9]*$ ]] \
        || fail "Invalid resistant descendant PID: ${descendant_pid}"
    # shellcheck disable=SC2310 # Failure is converted to a fixture diagnostic.
    read_mock_process_start_time descendant_start_time "${descendant_pid}" \
        || fail 'Unable to capture the resistant descendant identity.'
    kill -TERM -- "${cli_engine_pid}"
    wait_for_file "${descendant_term_marker}" 10 \
        'leader-exit resistant descendant receives first TERM'
    signal_started_at=$(date +%s%3N)
    kill -TERM -- "${cli_engine_pid}"
    cli_engine_status=0
    wait "${cli_engine_pid}" || cli_engine_status=$?
    assert_equals 143 "${cli_engine_status}" \
        'CLI resistant descendant repeated-TERM status'
    wait_for_mock_process_to_stop \
        "${descendant_pid}" "${descendant_start_time}" 5 \
        'Repeated TERM left the signal-resistant descendant alive'
    signal_finished_at=$(date +%s%3N)
    elapsed_milliseconds=$((signal_finished_at - signal_started_at))
    ((elapsed_milliseconds < 5000)) \
        || fail "Repeated TERM escalation took ${elapsed_milliseconds}ms."
    assert_no_test_processes \
        'resistant descendant escalation left worker processes'
}

test_mock_signal_cli_worker_registration() {
    local cli_source_copy cli_status elapsed_milliseconds launched_worker_pid
    local index signal_finished_at signal_log signal_name signal_started_at
    local signal_status worker_identity
    local worker_deferred_status_marker worker_launch_state_marker
    local worker_registration_marker
    local -a signal_names=(HUP INT TERM)
    local -a signal_statuses=(129 130 143)

    # Exercise the production critical-section helpers in the vulnerable
    # source order: launch, receive a signal, publish $!, then finish registration.
    cli_source_copy="${TEST_ROOT}/download-video-source-only.sh"
    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${cli_source_copy}"
    chmod 0600 -- "${cli_source_copy}"
    printf '%s\n' 'Mock scenario: cli-signal-worker-registration'

    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        signal_status=${signal_statuses[index]}
        signal_log="${TEST_ROOT}/cli-worker-registration-${signal_name}.log"
        worker_launch_state_marker="${TEST_ROOT}/cli-worker-launch-state-${signal_name}"
        worker_deferred_status_marker="${TEST_ROOT}/cli-worker-deferred-status-${signal_name}"
        worker_identity="${TEST_ROOT}/cli-worker-pre-registration-child-${signal_name}"
        worker_registration_marker="${TEST_ROOT}/cli-worker-pre-registration-${signal_name}.pid"

        signal_started_at=$(date +%s%3N)
        cli_status=0
        timeout --signal=TERM --kill-after=2s 8s \
            env MOCK_CLI_SOURCE_COPY="${cli_source_copy}" \
            MOCK_WORKER_DEFERRED_STATUS_MARKER="${worker_deferred_status_marker}" \
            MOCK_WORKER_IDENTITY="${worker_identity}" \
            MOCK_WORKER_LAUNCH_STATE_MARKER="${worker_launch_state_marker}" \
            MOCK_WORKER_PRE_REGISTRATION_MARKER="${worker_registration_marker}" \
            MOCK_WORKER_SIGNAL_NAME="${signal_name}" \
            MOCK_WORKER_SIGNAL_STATUS="${signal_status}" \
            "${CLI_SIGNAL_REGISTRATION_UNDER_TEST}" >"${signal_log}" 2>&1 \
            || cli_status=$?
        signal_finished_at=$(date +%s%3N)
        elapsed_milliseconds=$((signal_finished_at - signal_started_at))
        assert_equals "${signal_status}" "${cli_status}" \
            "CLI worker pre-registration ${signal_name} is deferred and reaped"
        ((elapsed_milliseconds < 5000)) \
            || fail "CLI pre-registration ${signal_name} handling took ${elapsed_milliseconds}ms."
        assert_file_has_line "${worker_launch_state_marker}" true \
            "CLI ${signal_name} worker launch occurs inside signal-registration critical section"
        assert_file_has_line "${worker_deferred_status_marker}" \
            "${signal_status}" \
            "CLI worker pre-registration handler defers ${signal_name}"
        IFS= read -r launched_worker_pid <"${worker_registration_marker}"
        [[ ${launched_worker_pid} =~ ^[1-9][0-9]*$ ]] \
            || fail "Invalid CLI pre-registration worker PID: ${launched_worker_pid}"
        assert_no_test_processes \
            "CLI worker pre-registration ${signal_name} left descendants"
    done
}

test_mock_signal_cli_runtime_preparation() {
    local cli_engine_pid cli_engine_status elapsed_milliseconds index
    local runtime_signal_log runtime_started_marker runtime_termination_marker
    local signal_finished_at signal_name signal_started_at signal_status
    local -a signal_names=(HUP INT TERM)
    local -a signal_statuses=(129 130 143)

    # Managed runtime preparation is part of launch and must obey the same
    # signal-forwarding and bounded-reaping contract as the media worker.
    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        signal_status=${signal_statuses[index]}
        runtime_started_marker="${TEST_ROOT}/runtime-prepare-${signal_name}-started"
        runtime_termination_marker="${TEST_ROOT}/runtime-prepare-${signal_name}-terminated"
        runtime_signal_log="${TEST_ROOT}/runtime-prepare-${signal_name}.log"
        : >"${MOCK_RUNTIME_MANAGER_LOG}"
        env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
            MOCK_RUNTIME_MANAGER_BLOCK=1 \
            MOCK_RUNTIME_STARTED_MARKER="${runtime_started_marker}" \
            MOCK_RUNTIME_TERMINATION_MARKER="${runtime_termination_marker}" \
            "${MANAGED_ENGINE_UNDER_TEST}" \
            --output-dir "${OUTPUT_DIR}" \
            -- "https://example.com/watch?v=runtime-prepare-${signal_name}" \
            >"${runtime_signal_log}" 2>&1 &
        cli_engine_pid=$!
        wait_for_file "${runtime_started_marker}" 10 \
            "runtime preparation ${signal_name} startup"
        signal_started_at=$(date +%s%3N)
        kill "-${signal_name}" -- "${cli_engine_pid}"
        cli_engine_status=0
        wait "${cli_engine_pid}" || cli_engine_status=$?
        signal_finished_at=$(date +%s%3N)
        elapsed_milliseconds=$((signal_finished_at - signal_started_at))
        assert_equals "${signal_status}" "${cli_engine_status}" \
            "CLI runtime preparation ${signal_name} exit status"
        ((elapsed_milliseconds < 5000)) \
            || fail "CLI runtime preparation ${signal_name} took ${elapsed_milliseconds}ms."
        wait_for_file "${runtime_termination_marker}" 10 \
            "runtime manager receives ${signal_name}"
        assert_file_has_line "${runtime_termination_marker}" \
            "${signal_name}" \
            "runtime manager records ${signal_name}"
        assert_no_test_processes \
            "CLI runtime preparation ${signal_name} left descendants"
    done
}

# Observe this shell's child without stealing its wait status. Expiration is a
# test failure even if authenticated diagnostic cleanup subsequently succeeds.
wait_for_mock_pre_env_exit() {
    local observation=exit
    if [[ ${1:-} == --marker ]]; then
        observation=marker
        shift
    fi
    python3 -I -B - "${observation}" "$@" <<'PY_PRE_ENV_WAIT'
import itertools
import json
import os
from pathlib import Path
import re
import signal
import sys
import time

observation = sys.argv[1]
pid, expected_start, parent = map(int, sys.argv[2:5])
started, budget = map(float, sys.argv[5:7])
label, log_name = sys.argv[7:9]
marker_names = sys.argv[9:]
clock = lambda: time.clock_gettime(time.CLOCK_BOOTTIME)
deadline = started + budget


def process_info(target):
    # procfs inode ownership is diagnostic metadata, not process credentials or
    # identity: it can change on a live task and while that task is exiting.
    path = Path(f"/proc/{target}/stat")
    info = dict(pid=target, proc_owner="unavailable", state="unavailable",
                ppid="unavailable", pgid="unavailable", sid="unavailable", start="unavailable")
    try:
        info["proc_owner"] = path.stat().st_uid
    except OSError as error:
        info["owner_error"] = type(error).__name__
    try:
        with path.open("r") as source:
            record = source.read(4097)
        prefix, suffix = record.rsplit(") ", 1)
        fields = suffix.split()
        if (len(record) > 4096 or len(fields) < 20
                or int(prefix.split(" (", 1)[0]) != target
                or fields[0] not in ("R", "S", "D", "Z", "T", "t", "X", "x", "K", "W", "P", "I")
                or any(not fields[index].isdecimal() for index in (1, 2, 3, 19))):
            raise ValueError("invalid process record")
        info.update(state=fields[0], ppid=int(fields[1]), pgid=int(fields[2]),
                    sid=int(fields[3]), start=int(fields[19]))
        if info["start"] <= 0:
            raise ValueError("invalid process start time")
    except (FileNotFoundError, ProcessLookupError):
        return None
    except (OSError, ValueError, IndexError) as error:
        info["error"] = type(error).__name__
    return info


def matches(info):
    return (info is not None and "error" not in info
            and info["start"] == expected_start and info["ppid"] == parent)


def excerpt(path, limit, tail=False):
    try:
        with Path(path).open("rb") as source:
            if tail:
                source.seek(0, 2)
                source.seek(max(0, source.tell() - limit))
            return source.read(limit).decode("utf-8", "backslashreplace")
    except (OSError, ValueError) as error:
        return f"unavailable ({type(error).__name__})"


def report(reason, infos, limits=()):
    details = []
    capture_deadline = clock() + 1.0
    limits = list(limits)
    for info in infos[:32]:
        if clock() >= capture_deadline:
            limits.append("diagnostic-capture-budget-exhausted")
            break
        item = dict(info)
        for name in ("status", "wchan"):
            text = excerpt(f"/proc/{info['pid']}/{name}", 8192)
            item[name] = (text if text.startswith("unavailable (") else
                          [line for line in text.splitlines()
                           if line.startswith(("Uid:", "SigBlk:", "SigIgn:", "SigCgt:",
                                               "SigPnd:", "ShdPnd:"))]
                          if name == "status" else text[:128])
        details.append(item)
    markers = {}
    registration_root = Path(log_name).parent / "runtime" / f"yt-dlp-aria2-downloader-{os.getuid()}"
    try:
        registration_names = list(itertools.islice(registration_root.glob(".worker-*"), 8))
    except OSError as error:
        registration_names = []
        limits.append(f"registration-list-unavailable:{type(error).__name__}")
    for name in [*marker_names[:8], *registration_names]:
        if clock() >= capture_deadline:
            limits.append("diagnostic-marker-budget-exhausted")
            break
        path = Path(name)
        try:
            with path.open("rb") as source:
                raw = source.read(128)
            markers[path.name] = dict(content=raw.decode("ascii", "backslashreplace"))
            try:
                markers[path.name]["size"] = path.stat().st_size
            except OSError as error:
                markers[path.name]["size"] = f"unavailable ({type(error).__name__})"
        except FileNotFoundError:
            markers[path.name] = "absent"
        except OSError as error:
            markers[path.name] = f"unavailable ({type(error).__name__})"
    # Capture failures remain secondary data; they must not replace the first
    # failure or discard the other available log/trace and identity evidence.
    log = excerpt(log_name, 4096, tail=True)
    trace = excerpt(Path(log_name).with_suffix(".trace"), 16384)
    log = re.sub(r"https?://[^\s]+", "[REDACTED_URL]", log, flags=re.IGNORECASE)
    log = re.sub(r"(?im)^.*(?:authorization|cookie|password|secret|token|header).*$",
                 "[REDACTED_PRIVATE_DIAGNOSTIC]", log)
    print("PRE_ENV_DIAGNOSTIC " + json.dumps(dict(
        scenario=label, phase=reason, monotonic=clock(), elapsed=clock()-started,
        deadline=deadline, expected=dict(pid=pid, start=expected_start, ppid=parent),
        observer_uid=os.getuid(), kernel=os.uname().release,
        python=sys.version.split()[0],
        iteration=os.environ.get("MOCK_STRESS_ITERATION", "unavailable; see workflow iteration banner")[:80],
        processes=details, process_count=len(infos), limits=limits,
        initial_observation=current if current is not None else dict(pid=pid, state="absent"),
        initial_termination=("process-entry-absent" if current is None else
                     "terminal-state-observed" if current.get("state") in ("Z", "X")
                     else "not-established"),
        capture_budget_seconds=1, capture_overrun=max(0, clock()-capture_deadline),
        markers=markers, log=log, engine_trace=trace, parameters={name: os.environ.get(name, "unset")[:32]
        for name in ("MOCK_CANCEL_JITTER_SECONDS", "MOCK_CANCEL_AFTER_EOF_JITTER_SECONDS",
                     "MOCK_PGID_PUBLISH_DELAY_SECONDS", "MOCK_WORKER_START_JITTER_SECONDS",
                     "MOCK_FFMPEG_START_JITTER_SECONDS", "MOCK_SETSID_START_JITTER_SECONDS")})),
        file=sys.stderr, flush=True)


while True:
    current = process_info(pid)
    if current is None:
        if observation == "marker":
            report("engine-exited-before-marker", [])
            raise SystemExit(66)
        if clock() >= deadline:
            report("functional-deadline-expired-after-exit", [])
            raise SystemExit(124)
        break
    if "error" in current:
        report("process-record-unavailable-or-invalid", [current])
        raise SystemExit(65)
    if not matches(current):
        report("identity-rejected", [current])
        raise SystemExit(65)
    if current["state"] in ("Z", "X"):
        if observation == "marker":
            report("engine-exited-before-marker", [current])
            raise SystemExit(66)
        if clock() >= deadline:
            report("functional-deadline-expired-after-exit", [current])
            raise SystemExit(124)
        break
    if observation == "marker" and Path(marker_names[0]).is_file() and clock() < deadline:
        break
    if clock() >= deadline:
        # Discovery has a separate one-second budget and a 32-identity cap.
        # /proc I/O itself cannot promise a hard deadline under kernel stalls.
        handles = []
        limits = []

        def same_identity(info, fd=None):
            if fd is not None:
                try:
                    signal.pidfd_send_signal(fd, 0)
                except OSError as error:
                    limits.append(f"pidfd-check:{type(error).__name__}")
                    return False
            seen = process_info(info["pid"])
            if seen is not None and "error" in seen:
                limits.append(f"process-record:{info['pid']}:{seen['error']}")
            return seen is not None and "error" not in seen and all(seen[key] == info[key]
                                           for key in ("ppid", "start", "pgid", "sid"))

        def pin(info):
            try:
                fd = os.pidfd_open(info["pid"])
            except OSError as error:
                limits.append(f"pidfd-open:{type(error).__name__}")
                return None
            if same_identity(info, fd):
                return fd
            limits.append(f"pidfd-identity-not-confirmed:{info['pid']}")
            os.close(fd)
            return None

        def discover(until):
            index = 0
            known = {info["pid"] for _, info in handles}
            while index < len(handles) and len(handles) < 32 and clock() < until:
                owner_fd, owner = handles[index]
                index += 1
                if not same_identity(owner, owner_fd):
                    continue
                try:
                    path = Path(f"/proc/{owner['pid']}/task/{owner['pid']}/children")
                    with path.open("r") as source:
                        children = source.read(8193)
                except OSError as error:
                    limits.append(f"children-read:{type(error).__name__}")
                    continue
                if len(children) > 8192:
                    limits.append("children-record-truncated")
                    continue
                for child in children.split():
                    if len(handles) >= 32 or clock() >= until:
                        break
                    if not child.isdecimal() or int(child) in known:
                        continue
                    # The parent must remain the pinned original identity on
                    # both sides of this child's read and pidfd acquisition.
                    if not same_identity(owner, owner_fd):
                        break
                    info = process_info(int(child))
                    if info is None:
                        continue
                    if "error" in info:
                        limits.append(f"child-record:{info['pid']}:{info['error']}")
                        continue
                    if info["ppid"] != owner["pid"]:
                        continue
                    fd = pin(info)
                    if fd is None:
                        continue
                    if not same_identity(owner, owner_fd):
                        os.close(fd)
                        break
                    handles.append((fd, info))
                    known.add(info["pid"])
            if index < len(handles):
                limits.append("diagnostic-discovery-budget-or-identity-cap")

        try:
            root = process_info(pid)
            if matches(root):
                root_fd = pin(root)
                if root_fd is not None:
                    handles.append((root_fd, root))
            if root is not None and not matches(root):
                limits.append("root-identity-unavailable-before-cleanup")
            discover(clock() + 1.0)
            reason = ("publication-deadline-expired" if observation == "marker"
                      else "functional-deadline-expired")
            report(reason, [info for _, info in handles] or ([root] if root else []), limits)
            remaining = []
            for sig in (signal.SIGTERM, signal.SIGKILL):
                if sig == signal.SIGKILL:
                    # Traps may fork during TERM cleanup. Discover again only
                    # through still-authenticated parents, never adopted PIDs.
                    discover(clock() + 1.0)
                for fd, info in reversed(handles):
                    seen = process_info(info["pid"])
                    if seen is None or seen.get("state") in ("Z", "X"):
                        continue
                    if not same_identity(info, fd):
                        limits.append(f"signal-identity-uncertain:{info['pid']}")
                        continue
                    try:
                        signal.pidfd_send_signal(fd, sig)
                    except OSError as error:
                        limits.append(f"signal-{sig.name}:{info['pid']}:{type(error).__name__}")
                cleanup_deadline = clock() + (0.2 if sig == signal.SIGTERM else 2.0)
                while clock() < cleanup_deadline:
                    remaining = []
                    for _, info in handles:
                        seen = process_info(info["pid"])
                        if seen is not None and ("error" in seen or
                                (seen["start"] == info["start"] and seen["state"] not in ("Z", "X"))):
                            remaining.append(seen)
                    if not remaining:
                        break
                    time.sleep(0.01)
            report("cleanup-incomplete-or-uncertain" if remaining or limits
                   else "known-identities-stopped", remaining,
                   [*limits, "adoptions-after-parent-exit-not-observable"])
        finally:
            for fd, _ in handles:
                os.close(fd)
        # The real parent may reap only after /proc confirms termination.
        # Do not turn a timeout followed by status 130 into a passing test.
        raise SystemExit(124)
    time.sleep(min(0.01, max(0, deadline - clock())))

print(int((clock() - started) * 1000))
PY_PRE_ENV_WAIT
}

# Only the launching Bash parent can recover the real wait status. A missing
# or replaced proc entry also means that the original child cannot still run;
# an unreadable/incomplete record does not authorize an unbounded wait.
reap_mock_pre_env_child() {
    local child_pid=$1 child_start=$2 result_name=$3 label=$4 observer_status=$5
    local process_stat='' can_reap=false
    local -a process_fields=()
    local -n child_result="${result_name}"

    child_result=unavailable
    if [[ ! -d /proc/${child_pid} ]]; then
        can_reap=true
    elif IFS= read -r process_stat <"/proc/${child_pid}/stat"; then
        read -r -a process_fields <<<"${process_stat##*) }"
        if ((${#process_fields[@]} >= 20)) \
            && [[ ${process_fields[19]} =~ ^[0-9]+$ ]] \
            && { [[ ${process_fields[19]} != "${child_start}" ]] \
                || [[ ${process_fields[0]} == Z || ${process_fields[0]} == X ]]; }; then
            can_reap=true
        fi
    fi
    if [[ ${can_reap} == true ]]; then
        child_result=0
        wait "${child_pid}" || child_result=$?
    fi
    printf 'PRE_ENV_CHILD_STATUS scenario=%s pid=%s observer=%s child=%s wait_attempted=%s\n' \
        "${label}" "${child_pid}" "${observer_status}" "${child_result}" "${can_reap}"
}

wait_for_mock_pre_env_marker() {
    local child_pid=$1 child_start=$2 marker=$3 label=$4 log_name=$5
    local parent_pid=${BASHPID} started='' unused='' observer_status=0 child_status=''

    read -r started unused </proc/uptime
    # The returned duration is unused during preparation; retain diagnostics.
    # shellcheck disable=SC2310 # Preserve the observer's explicit failure status.
    wait_for_mock_pre_env_exit --marker \
        "${child_pid}" "${child_start}" "${parent_pid}" \
        "${started}" 10 "${label}" "${log_name}" "${marker}" \
        >/dev/null || observer_status=$?
    if ((observer_status != 0)); then
        reap_mock_pre_env_child "${child_pid}" "${child_start}" child_status \
            "${label}" "${observer_status}"
        fail "${label}: preparation observer failed with status ${observer_status}; child=${child_status}."
    fi
}

test_mock_pre_env_observer_controls() {
    local child_pid child_start child_status control expected_status observed_status
    local tested_start tested_parent release_status
    local ready release started unused elapsed observer_log worker_log
    local parent_pid=${BASHPID}
    local -a observer_options=()
    local -a controls=(success signal-status cached-status ordinary-error identity-rejection foreign-parent
        no-publication marker-absent engine-exited-before-marker)

    printf '%s\n' 'Mock scenario: pre-env-observer-negative-controls'
    # Exercise this exact observer with real children while replacing only the
    # procfs boundary. This covers kernel-dependent metadata without changing
    # /proc, dumpability or the production engine.
    python3 -I -B - "${PROJECT_DIR}/tests/lib/mock-signals.sh" <<'PY_PRE_ENV_PROCFS'
"""Exercise the real embedded observer; alter only selected procfs/read boundaries."""
import builtins
import contextlib
import ctypes
import json
import io
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

text = Path(sys.argv[1]).read_text()
selected_controls = set(sys.argv[2:])
source = text.split("<<'PY_PRE_ENV_WAIT'\n", 1)[1].split('\nPY_PRE_ENV_WAIT', 1)[0]
program = compile(source, 'actual-PY_PRE_ENV_WAIT', 'exec')
clock = lambda: time.clock_gettime(time.CLOCK_BOOTTIME)
real_path_open, real_path_stat = Path.open, Path.stat
real_open, real_pidfd_signal = builtins.open, signal.pidfd_send_signal
real_pidfd_open = os.pidfd_open
worker_source = '''import os,signal,sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))
descendant = os.fork() if len(sys.argv) > 2 else -1
if descendant == 0:
    os.read(int(sys.argv[2]), 1)
    os._exit(0)
print("ready", descendant, flush=True)
sys.stdin.readline()
sys.exit(int(sys.argv[1]))
'''


def proc_fields(pid):
    return Path('/proc/{}/stat'.format(pid)).read_text().rsplit(') ', 1)[1].split()


def await_terminal(worker):
    deadline = clock() + 2
    while clock() < deadline:
        if os.waitid(os.P_PID, worker.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT):
            return
        time.sleep(.005)
    raise AssertionError('controlled child did not terminate within two seconds')


def run_case(control, wanted, status=7):
    with tempfile.TemporaryDirectory(prefix='observer-control-') as directory:
        root = Path(directory)
        log = root / 'worker.log'
        log.write_text('bounded fixture diagnostic\n')
        log.with_suffix('.trace').write_text('separate fixture trace\n')
        worker_errors = (root / 'worker.stderr').open('w+')
        pipe = os.pipe() if control == 'leader-exit-descendant' else ()
        command = [sys.executable, '-c', worker_source, str(status)]
        if pipe:
            command.append(str(pipe[0]))
        worker = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=worker_errors, text=True, pass_fds=pipe[:1])
        if pipe:
            os.close(pipe[0])
        released = False
        def release():
            nonlocal released
            if not released:
                worker.stdin.write('continue\n')
                worker.stdin.flush()
                released = True
        signals, reads, states = [], [], []
        before, descendant_identity, descendant_reaped = None, None, False
        cleanup_fault = None
        try:
            assert select.select([worker.stdout], [], [], 2)[0], 'child readiness absent'
            readiness = worker.stdout.readline().split()
            assert len(readiness) == 2 and readiness[0] == 'ready', readiness
            if pipe:
                descendant_pid = int(readiness[1])
                descendant_fields = proc_fields(descendant_pid)
                assert int(descendant_fields[1]) == worker.pid
                descendant_identity = (descendant_pid, int(descendant_fields[19]))
            fields = proc_fields(worker.pid)
            expected_start, parent = int(fields[19]), os.getpid()
            before = expected_start
            proc_path = '/proc/{}/stat'.format(worker.pid)
            if control.startswith('terminal-owner') or control in ('disappeared-reaped', 'leader-exit-descendant'):
                release()
                await_terminal(worker)
                if control == 'disappeared-reaped':
                    assert worker.wait(timeout=1) == status
            if control == 'wrong-start':
                expected_start += 1
            if control == 'wrong-parent':
                parent += 1
            def owner_stat(path, *args, **kwargs):
                if str(path) == proc_path and control == 'owner-metadata-error':
                    raise OSError('controlled metadata error')
                result = real_path_stat(path, *args, **kwargs)
                if str(path) == proc_path and ('owner' in control):
                    values = list(result)
                    values[4] = os.getuid() + 1
                    return os.stat_result(values)
                return result
            def proc_open(path, *args, **kwargs):
                if control == 'capture-error' and str(path) == str(log):
                    raise PermissionError('controlled diagnostic read denial')
                if str(path) != proc_path:
                    return real_path_open(path, *args, **kwargs)
                reads.append(str(path))
                if control == 'unreadable-proc' or cleanup_fault == 'read-error':
                    raise PermissionError('controlled procfs read denial')
                with real_path_open(path, *args, **kwargs) as handle:
                    raw = handle.read()
                prefix, body = raw.rsplit(') ', 1)
                fields = body.split()
                states.append(fields[0])
                if control == 'truncated-proc':
                    return io.StringIO(prefix + ') ' + ' '.join(fields[:3]))
                if control == 'reused-start' or cleanup_fault == 'changed-start':
                    fields[19] = str(int(fields[19]) + 1)
                    return io.StringIO(prefix + ') ' + ' '.join(fields) + '\n')
                if control in ('live-owner-change', 'termination-during-read', 'owner-metadata-error') and not released:
                    release()
                    if control == 'termination-during-read':
                        await_terminal(worker)
                return io.StringIO(raw)
            def capture_open(path, *args, **kwargs):
                if control == 'capture-error' and str(path) == str(log):
                    raise PermissionError('controlled diagnostic read denial')
                return real_open(path, *args, **kwargs)
            def pin_open(target, *args, **kwargs):
                nonlocal cleanup_fault
                if control == 'pidfd-open-error':
                    raise PermissionError('controlled pidfd acquisition error')
                fd = real_pidfd_open(target, *args, **kwargs)
                if control in ('cleanup-record-error', 'pidfd-pin-race'):
                    cleanup_fault = 'read-error' if control == 'cleanup-record-error' else 'changed-start'
                return fd
            def observe_signal(fd, signum, *args, **kwargs):
                if signum:
                    fdinfo = Path('/proc/self/fdinfo/{}'.format(fd)).read_text()
                    pinned = int(next(line.split(':', 1)[1] for line in fdinfo.splitlines()
                                      if line.startswith('Pid:')))
                    if pinned == -1:
                        return real_pidfd_signal(fd, signum, *args, **kwargs)
                    signals.append((pinned, int(signum)))
                    assert control in ('expired-cleanup-130', 'capture-error'), signals
                    assert pinned == worker.pid, 'observer signaled a foreign process'
                return real_pidfd_signal(fd, signum, *args, **kwargs)
            duration = .05 if control in ('expired-cleanup-130', 'capture-error',
                'cleanup-record-error', 'pidfd-open-error', 'pidfd-pin-race') else 1
            arguments = ['observer', 'exit', str(worker.pid), str(expected_start), str(parent),
                         str(clock()), str(duration), control, str(log), str(root/'absent')]
            out, err = io.StringIO(), io.StringIO()
            observer_status, unexpected = 0, None
            namespace = {'__name__': '__main__'}
            with patch.object(Path, 'stat', owner_stat), patch.object(Path, 'open', proc_open), \
                    patch.object(builtins, 'open', capture_open), \
                    patch.object(signal, 'pidfd_send_signal', observe_signal), \
                    patch.object(os, 'pidfd_open', pin_open), \
                    patch.object(sys, 'argv', arguments), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    exec(program, namespace)
                except SystemExit as exc:
                    observer_status = int(exc.code or 0)
                except Exception as exc:
                    unexpected = repr(exc)
            if control in ('expired-cleanup-130', 'capture-error'):
                await_terminal(worker)
                child_status = worker.wait(timeout=1)
                assert child_status == 130, (control, child_status)
            else:
                if worker.returncode is None:
                    release()
                    await_terminal(worker)
                child_status = worker.wait(timeout=1)
                assert child_status == status, (control, child_status)
                assert not signals, (control, signals)
            assert unexpected is None, (control, unexpected, err.getvalue())
            assert observer_status == wanted, (control, observer_status, wanted, err.getvalue())
            if wanted:
                assert not out.getvalue(), (control, 'failure emitted success duration')
                reports = [json.loads(line.split(' ', 1)[1]) for line in err.getvalue().splitlines()
                           if line.startswith('PRE_ENV_DIAGNOSTIC ')]
                assert reports, (control, 'missing diagnostic')
                for report in reports:
                    assert {'expected', 'initial_observation', 'initial_termination', 'monotonic', 'deadline', 'kernel'} <= report.keys()
                    assert report['expected'] == dict(pid=worker.pid, start=expected_start, ppid=parent)
                    assert report['initial_observation']['proc_owner'] == os.getuid()
                if control in ('unreadable-proc', 'truncated-proc'):
                    assert 'error' in reports[0]['initial_observation']
                if control == 'capture-error':
                    assert 'PermissionError' in reports[0]['log']
                    assert reports[0]['engine_trace'] == 'separate fixture trace\n'
                if control in ('cleanup-record-error', 'pidfd-open-error', 'pidfd-pin-race'):
                    assert reports[-1]['phase'] == 'cleanup-incomplete-or-uncertain'
                    assert reports[-1]['limits']
            else:
                assert out.getvalue().strip().isdigit(), (control, out.getvalue())
            if 'owner' in control and control != 'owner-metadata-error':
                assert namespace['current']['proc_owner'] == os.getuid() + 1
            if control == 'owner-metadata-error':
                assert namespace['current']['proc_owner'] == 'unavailable'
                assert namespace['current']['owner_error'] == 'OSError'
            if descendant_identity:
                descendant_fields = proc_fields(descendant_pid)
                assert int(descendant_fields[19]) == descendant_identity[1]
                assert descendant_fields[0] not in ('Z', 'X'), 'leader success hid tree state'
                assert int(descendant_fields[1]) == os.getpid(), 'private subreaper did not adopt'
                os.write(pipe[1], b'x')
                until = clock() + 2
                while clock() < until:
                    found, child_wait = os.waitpid(descendant_pid, os.WNOHANG)
                    if found:
                        descendant_reaped = True
                        assert os.waitstatus_to_exitcode(child_wait) == 0
                        break
                    time.sleep(.005)
                assert descendant_reaped, 'descendant harvest deadline'
            worker_errors.seek(0)
            assert worker_errors.read() == '', 'unexpected child stderr'
            if control in ('live-owner-change', 'termination-during-read'):
                assert states and states[0] not in ('Z', 'X') and released, (control, states)
            print('PASS {} observer={} wait={} signals={} reads={}'.format(
                control, observer_status, child_status, len(signals), len(reads)))
        finally:
            if descendant_identity and not descendant_reaped:
                try:
                    fd = real_pidfd_open(descendant_identity[0])
                    try:
                        if int(proc_fields(descendant_identity[0])[19]) == descendant_identity[1]:
                            real_pidfd_signal(fd, signal.SIGKILL)
                    finally:
                        os.close(fd)
                except ProcessLookupError:
                    pass
            if worker.returncode is None:
                # Independent recovery: kernel handle plus fresh known start-time.
                try:
                    fd = os.pidfd_open(worker.pid)
                    try:
                        if before is not None and int(proc_fields(worker.pid)[19]) == before:
                            real_pidfd_signal(fd, signal.SIGKILL)
                    finally:
                        os.close(fd)
                except ProcessLookupError:
                    pass
                worker.wait(timeout=2)
            if descendant_identity and not descendant_reaped:
                until = clock() + 2
                while clock() < until:
                    try:
                        if os.waitpid(descendant_identity[0], os.WNOHANG)[0]:
                            descendant_reaped = True
                            break
                    except ChildProcessError:
                        break
                    time.sleep(.005)
                assert descendant_reaped, 'external descendant recovery not harvested'
            if pipe:
                os.close(pipe[1])
            worker_errors.close()
            worker.stdin.close()
            worker.stdout.close()


libc = ctypes.CDLL(None, use_errno=True)
previous_subreaper = ctypes.c_int()
assert libc.prctl(37, ctypes.byref(previous_subreaper), 0, 0, 0) == 0
assert libc.prctl(36, 1, 0, 0, 0) == 0
try:
    cases = (
        ('terminal-owner-130', 0, 130), ('terminal-owner-7', 0, 7),
        ('live-owner-change', 0, 7), ('wrong-start', 65, 7),
        ('wrong-parent', 65, 7), ('reused-start', 65, 7),
        ('termination-during-read', 0, 7), ('disappeared-reaped', 0, 7),
        ('unreadable-proc', 65, 7), ('truncated-proc', 65, 7),
        ('expired-cleanup-130', 124, 7), ('capture-error', 124, 7),
        ('owner-metadata-error', 0, 7), ('cleanup-record-error', 124, 7),
        ('pidfd-open-error', 124, 7), ('pidfd-pin-race', 124, 7),
        ('leader-exit-descendant', 0, 7))
    for name, expected, status in cases:
        if not selected_controls or name in selected_controls:
            run_case(name, expected, status)
finally:
    assert libc.prctl(36, previous_subreaper.value, 0, 0, 0) == 0
PY_PRE_ENV_PROCFS

    for control in "${controls[@]}"; do
        ready="${TEST_ROOT}/observer-${control}-ready"
        release="${TEST_ROOT}/observer-${control}-release"
        observer_log="${TEST_ROOT}/observer-${control}.log"
        worker_log="${TEST_ROOT}/observer-${control}-worker.log"
        expected_status=7
        [[ ${control} != success ]] || expected_status=0
        [[ ${control} != signal-status && ${control} != cached-status ]] || expected_status=130
        python3 -I -B - "${ready}" "${release}" "${expected_status}" \
            >"${worker_log}" 2>&1 <<'PY_PRE_ENV_CONTROL' &
from pathlib import Path
import signal
import sys
import time

ready, release = map(Path, sys.argv[1:3])
signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))
ready.touch()
while not release.exists():
    time.sleep(0.01)
raise SystemExit(int(sys.argv[3]))
PY_PRE_ENV_CONTROL
        child_pid=$!
        wait_for_file "${ready}" 3 "pre-env observer ${control} startup"
        # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
        read_mock_process_start_time child_start "${child_pid}" \
            || fail "Pre-env observer ${control}: child identity unavailable."
        read -r started unused </proc/uptime
        observed_status=0
        if [[ ${control} == identity-rejection || ${control} == foreign-parent ]]; then
            tested_start=${child_start}
            tested_parent=${parent_pid}
            if [[ ${control} == identity-rejection ]]; then
                tested_start=$((child_start + 1))
            else
                tested_parent=$((parent_pid + 1))
            fi
            # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
            elapsed=$(wait_for_mock_pre_env_exit \
                "${child_pid}" "${tested_start}" "${tested_parent}" \
                "${started}" 1 "${control}" "${worker_log}" "${ready}" \
                2>"${observer_log}") || observed_status=$?
            assert_equals 65 "${observed_status}" 'pre-env observer rejects unauthenticated identity'
            # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
            read_mock_process_start_time unused "${child_pid}" \
                || fail 'Pre-env observer signaled an unauthenticated child.'
            assert_equals "${child_start}" "${unused}" 'rejected identity remains alive'
            : >"${release}"
        elif [[ ${control} == no-publication || ${control} == marker-absent ]]; then
            observer_options=()
            [[ ${control} != marker-absent ]] || observer_options=(--marker)
            # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
            elapsed=$(wait_for_mock_pre_env_exit "${observer_options[@]}" \
                "${child_pid}" "${child_start}" "${parent_pid}" \
                "${started}" 0.05 "${control}" "${worker_log}" \
                "${TEST_ROOT}/never-published" 2>"${observer_log}") || observed_status=$?
            assert_equals 124 "${observed_status}" 'pre-env observer preserves expiration'
            assert_file_contains "${observer_log}" deadline-expired \
                'pre-env observer captures failure before cleanup'
            assert_file_contains "${observer_log}" '"never-published": "absent"' \
                'pre-env observer distinguishes absent readiness'
            expected_status=130
        elif [[ ${control} == engine-exited-before-marker ]]; then
            : >"${release}"
            # shellcheck disable=SC2310 # Premature termination must stay a failure.
            elapsed=$(wait_for_mock_pre_env_exit --marker \
                "${child_pid}" "${child_start}" "${parent_pid}" \
                "${started}" 1 "${control}" "${worker_log}" \
                "${TEST_ROOT}/never-published" 2>"${observer_log}") || observed_status=$?
            assert_equals 66 "${observed_status}" 'pre-env observer detects premature engine exit'
            assert_file_contains "${observer_log}" engine-exited-before-marker \
                'pre-env observer diagnoses absent publication after exit'
        else
            : >"${release}"
            # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
            elapsed=$(wait_for_mock_pre_env_exit \
                "${child_pid}" "${child_start}" "${parent_pid}" \
                "${started}" 1 "${control}" "${worker_log}" "${ready}" \
                2>"${observer_log}") || observed_status=$?
            assert_equals 0 "${observed_status}" 'pre-env observer only observes termination'
        fi
        if ((observed_status == 0)); then
            [[ ${elapsed} =~ ^[0-9]+$ ]] || fail 'Observer elapsed time is invalid.'
        else
            assert_equals '' "${elapsed}" 'failed observer never publishes a success duration'
        fi
        release_status=0
        if [[ ${control} == identity-rejection || ${control} == foreign-parent ]]; then
            read -r started unused </proc/uptime
            # The first observer failed while leaving this child untouched.
            # Bound its independently requested release before the parent reaps.
            # shellcheck disable=SC2310 # Capture secondary failure before reaping.
            wait_for_mock_pre_env_exit "${child_pid}" "${child_start}" "${parent_pid}" \
                "${started}" 1 "${control}-released" "${worker_log}" \
                >/dev/null || release_status=$?
        fi
        if [[ ${control} == cached-status ]]; then
            # Termination was observed above. Force a missing proc entry while
            # this launching Bash still retains the child's real wait status.
            child_status=0
            wait "${child_pid}" || child_status=$?
            assert_equals 130 "${child_status}" 'initial Bash reap preserves SIGINT status'
            [[ ! -e /proc/${child_pid}/stat ]] || fail 'Reaped control still has a proc entry.'
            read -r started unused </proc/uptime
            # shellcheck disable=SC2310 # A failed observation cannot discard the saved status.
            wait_for_mock_pre_env_exit "${child_pid}" "${child_start}" "${parent_pid}" \
                "${started}" 1 "${control}" "${worker_log}" \
                >/dev/null || release_status=$?
        fi
        reap_mock_pre_env_child "${child_pid}" "${child_start}" child_status \
            "${control}" "${observed_status}"
        assert_equals "${expected_status}" "${child_status}" \
            "pre-env observer ${control} retains the real child status"
        assert_equals 0 "${release_status}" \
            "pre-env observer ${control} bounded release observation"
    done
}

test_mock_signal_cli_pre_env_registration() {
    local cli_engine_pid cli_engine_start_time cli_engine_status continue_marker delay_marker
    local elapsed_milliseconds first_handler_returned_marker mode runtime_signal_log signal_finished_at
    local observer_status process_stat signal_started_at kernel_version
    local parent_pid=${BASHPID}
    local -a registration_leftovers=()
    local -a session_modes=(false true)

    # Interpose immediately before GNU env restores dispositions. SIGINT sent
    # in this exact post-fork window must remain deferred until the child has
    # published post-env readiness, rather than being lost as an inherited
    # ignored signal and requiring the ten-second KILL escalation.
    printf '%s\n' 'Mock scenario: cli-signal-pre-env-registration'
    kernel_version=$(uname -r)
    printf 'Pre-env environment: kernel=%s bash=%s\n' "${kernel_version}" "${BASH_VERSION}"
    for mode in "${session_modes[@]}"; do
        delay_marker="${TEST_ROOT}/pre-env-${mode}-delayed"
        continue_marker="${TEST_ROOT}/pre-env-${mode}-continue"
        runtime_signal_log="${TEST_ROOT}/pre-env-${mode}.log"

        "${REAL_SETSID}" --wait /usr/bin/env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
            MOCK_ENV_DELAY_MARKER="${delay_marker}" \
            MOCK_ENV_CONTINUE_MARKER="${continue_marker}" \
            MOCK_PRE_ENV_TRACE="${runtime_signal_log%.log}.trace" \
            MOCK_RUNTIME_MANAGER_BLOCK=1 \
            MOCK_RUNTIME_STARTED_MARKER="${TEST_ROOT}/pre-env-${mode}-runtime-started" \
            MOCK_RUNTIME_TERMINATION_MARKER="${TEST_ROOT}/pre-env-${mode}-runtime-terminated" \
            YTDLP_ARIA2_SUPERVISED_SESSION="${mode}" \
            "${MANAGED_ENGINE_UNDER_TEST}" \
            --output-dir "${OUTPUT_DIR}" \
            -- "https://example.com/watch?v=pre-env-${mode}" \
            >"${runtime_signal_log}" 2>&1 &
        cli_engine_pid=$!
        cli_engine_start_time=''
        # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
        read_mock_process_start_time cli_engine_start_time "${cli_engine_pid}" \
            || fail "Pre-env ${mode}: unable to authenticate the launched engine."
        wait_for_mock_pre_env_marker "${cli_engine_pid}" "${cli_engine_start_time}" \
            "${delay_marker}" "pre-env ${mode} launch delay" "${runtime_signal_log}"
        read -r signal_finished_at process_stat </proc/uptime
        printf 'Pre-env mode=%s phase=delay-observed monotonic=%s pid=%s start=%s\n' \
            "${mode}" "${signal_finished_at}" "${cli_engine_pid}" "${cli_engine_start_time}"
        read -r signal_started_at signal_finished_at </proc/uptime
        kill -INT -- "${cli_engine_pid}"
        : >"${continue_marker}"
        printf 'Pre-env mode=%s phase=first-int-sent-continue-published monotonic=%s\n' \
            "${mode}" "${signal_started_at}"
        observer_status=0
        # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
        elapsed_milliseconds=$(wait_for_mock_pre_env_exit \
            "${cli_engine_pid}" "${cli_engine_start_time}" "${parent_pid}" \
            "${signal_started_at}" 5 "pre-env-${mode}" "${runtime_signal_log}" \
            "${delay_marker}" "${continue_marker}" \
            "${TEST_ROOT}/pre-env-${mode}-runtime-started" \
            "${TEST_ROOT}/pre-env-${mode}-runtime-terminated") || observer_status=$?
        reap_mock_pre_env_child "${cli_engine_pid}" "${cli_engine_start_time}" \
            cli_engine_status "pre-env-${mode}" "${observer_status}"
        if ((observer_status != 0)); then
            fail "pre-env ${mode} observation failed with status ${observer_status}; child=${cli_engine_status}."
        fi
        assert_equals 130 "${cli_engine_status}" \
            "pre-env ${mode} SIGINT exit status"
        ((elapsed_milliseconds < 5000)) \
            || fail "Pre-env ${mode} SIGINT handling took ${elapsed_milliseconds}ms."
        assert_no_test_processes \
            "pre-env ${mode} SIGINT left descendants"
        shopt -s nullglob
        registration_leftovers=(
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}"/.worker-pgid.*
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}"/.worker-ready.*
        )
        shopt -u nullglob
        if ((${#registration_leftovers[@]} != 0)); then
            printf 'Registration file left after pre-env %s SIGINT: %s\n' \
                "${mode}" "${registration_leftovers[@]}" >&2
            fail "Pre-env ${mode} SIGINT left registration files."
        fi
    done

    # A repeated signal retains the first conventional status but escalates
    # immediately even when the child never reaches env or publishes readiness.
    for mode in "${session_modes[@]}"; do
        delay_marker="${TEST_ROOT}/pre-env-escalate-${mode}-delayed"
        continue_marker="${TEST_ROOT}/pre-env-escalate-${mode}-continue"
        first_handler_returned_marker="${TEST_ROOT}/pre-env-escalate-${mode}-first-handler-returned"
        runtime_signal_log="${TEST_ROOT}/pre-env-escalate-${mode}.log"

        "${REAL_SETSID}" --wait /usr/bin/env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
            MOCK_ENV_DELAY_MARKER="${delay_marker}" \
            MOCK_ENV_CONTINUE_MARKER="${continue_marker}" \
            MOCK_PRE_ENV_TRACE="${runtime_signal_log%.log}.trace" \
            MOCK_DEFERRED_SIGNAL_RETURNED_MARKER="${first_handler_returned_marker}" \
            MOCK_RUNTIME_MANAGER_BLOCK=1 \
            MOCK_RUNTIME_STARTED_MARKER="${TEST_ROOT}/pre-env-escalate-${mode}-runtime-started" \
            MOCK_RUNTIME_TERMINATION_MARKER="${TEST_ROOT}/pre-env-escalate-${mode}-runtime-terminated" \
            YTDLP_ARIA2_SUPERVISED_SESSION="${mode}" \
            "${MANAGED_ENGINE_UNDER_TEST}" \
            --output-dir "${OUTPUT_DIR}" \
            -- "https://example.com/watch?v=pre-env-escalate-${mode}" \
            >"${runtime_signal_log}" 2>&1 &
        cli_engine_pid=$!
        cli_engine_start_time=''
        # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
        read_mock_process_start_time cli_engine_start_time "${cli_engine_pid}" \
            || fail "Pre-env ${mode}: unable to authenticate the launched engine."
        wait_for_mock_pre_env_marker "${cli_engine_pid}" "${cli_engine_start_time}" \
            "${delay_marker}" "pre-env escalation ${mode} launch delay" "${runtime_signal_log}"
        read -r signal_finished_at process_stat </proc/uptime
        printf 'Pre-env mode=%s phase=escalation-delay-observed monotonic=%s pid=%s start=%s\n' \
            "${mode}" "${signal_finished_at}" "${cli_engine_pid}" "${cli_engine_start_time}"
        kill -INT -- "${cli_engine_pid}"
        # Standard signals can coalesce while pending. Confirm return from the
        # first handler before sending the second INT that requests escalation.
        wait_for_mock_pre_env_marker "${cli_engine_pid}" "${cli_engine_start_time}" \
            "${first_handler_returned_marker}" "pre-env escalation ${mode} first SIGINT handler return" \
            "${runtime_signal_log}"
        assert_file_has_line "${first_handler_returned_marker}" 130 \
            "pre-env escalation ${mode} first SIGINT is deferred"
        printf 'Pre-env mode=%s phase=first-handler-return-observed\n' "${mode}"
        # Measure escalation from its trigger, after the first-handler barrier.
        read -r signal_started_at signal_finished_at </proc/uptime
        kill -INT -- "${cli_engine_pid}"
        observer_status=0
        # shellcheck disable=SC2310 # Failure is explicitly preserved by this predicate.
        elapsed_milliseconds=$(wait_for_mock_pre_env_exit \
            "${cli_engine_pid}" "${cli_engine_start_time}" "${parent_pid}" \
            "${signal_started_at}" 2 "pre-env-escalate-${mode}" "${runtime_signal_log}" \
            "${delay_marker}" "${continue_marker}" \
            "${TEST_ROOT}/pre-env-escalate-${mode}-runtime-started" \
            "${TEST_ROOT}/pre-env-escalate-${mode}-runtime-terminated" \
            "${first_handler_returned_marker}") || observer_status=$?
        reap_mock_pre_env_child "${cli_engine_pid}" "${cli_engine_start_time}" \
            cli_engine_status "pre-env-escalate-${mode}" "${observer_status}"
        if ((observer_status != 0)); then
            fail "pre-env-escalate ${mode} observation failed with status ${observer_status}; child=${cli_engine_status}."
        fi
        assert_equals 130 "${cli_engine_status}" \
            "pre-env escalation ${mode} preserves first SIGINT status"
        ((elapsed_milliseconds < 2000)) \
            || fail "Pre-env escalation ${mode} took ${elapsed_milliseconds}ms."
        shopt -s nullglob
        registration_leftovers=(
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}"/.worker-pgid.*
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}"/.worker-ready.*
        )
        shopt -u nullglob
        if ((${#registration_leftovers[@]} != 0)); then
            printf 'Registration file left after pre-env escalation %s: %s\n' \
                "${mode}" "${registration_leftovers[@]}" >&2
            fail "Pre-env escalation ${mode} left registration files."
        fi
        assert_no_test_processes \
            "pre-env escalation ${mode} left descendants"
    done
}

test_mock_signal_registration_handoff() {
    local source_copy="${TEST_ROOT}/download-video-registration-handoff.sh"
    local handoff_status=0
    local late_first_status=0

    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${source_copy}"
    chmod 0600 -- "${source_copy}"
    printf '%s\n' 'Mock scenario: cli-signal-registration-handoff'
    # The DEBUG trap injects TERM after the critical-section flag is cleared.
    # HUP must already own the requested status at that exact handoff boundary.
    # shellcheck disable=SC2016 # Variables belong to the intentionally nested shell.
    bash -c '
        set -euo pipefail
        set -T
        source "$1"
        begin_signal_registration
        request_shutdown HUP 129

        inject_second_signal() {
            if [[ ${SIGNAL_REGISTRATION_ACTIVE} == false &&
                ${BASH_COMMAND} == "REGISTRATION_ESCALATION_REQUESTED=false" ]]; then
                trap - DEBUG
                request_shutdown TERM 143
            fi
        }

        trap inject_second_signal DEBUG
        finish_signal_registration
    ' bash "${source_copy}" || handoff_status=$?
    assert_equals 129 "${handoff_status}" \
        'registration handoff preserves the first HUP status'

    # Inject the first signal after finish_signal_registration has initialized
    # its local state but immediately before it closes the registration flag.
    # A stale early copy must not erase this late arrival.
    # shellcheck disable=SC2016 # Variables belong to the intentionally nested shell.
    bash -c '
        set -euo pipefail
        set -T
        source "$1"
        begin_signal_registration

        inject_late_first_signal() {
            if [[ ${BASH_COMMAND} == "SIGNAL_REGISTRATION_ACTIVE=false" ]]; then
                trap - DEBUG
                request_shutdown HUP 129
            fi
        }

        trap inject_late_first_signal DEBUG
        finish_signal_registration
    ' bash "${source_copy}" || late_first_status=$?
    assert_equals 129 "${late_first_status}" \
        'registration handoff preserves a late first HUP status'

    # Opening the barrier must not clear an escalation already requested after
    # the active flag became visible.
    # shellcheck disable=SC2016 # Variables belong to the intentionally nested shell.
    assert_status 0 'registration opening preserves immediate escalation' \
        bash -c '
            set -euo pipefail
            set -T
            source "$1"
            injected=false

            inject_opening_signals() {
                if [[ ${SIGNAL_REGISTRATION_ACTIVE} == true &&
                    ${injected} == false ]]; then
                    injected=true
                    trap - DEBUG
                    request_shutdown HUP 129
                    request_shutdown TERM 143
                fi
            }

            trap inject_opening_signals DEBUG
            begin_signal_registration
            trap - DEBUG
            [[ ${DEFERRED_SIGNAL_STATUS} == 129 &&
                ${REGISTRATION_ESCALATION_REQUESTED} == true ]]
        ' bash "${source_copy}"

    # A second trap may run between the two assignments that publish the first
    # deferred signal. The status is the ownership sentinel and must become
    # visible before the descriptive signal name.
    # shellcheck disable=SC2016 # Variables belong to the intentionally nested shell.
    assert_status 0 'deferred signal publication is reentrant-safe' \
        bash -c '
            set -euo pipefail
            set -T
            source "$1"
            begin_signal_registration
            injected=false

            inject_reentrant_signal() {
                if [[ ${injected} == false &&
                    ${BASH_COMMAND} == "DEFERRED_SIGNAL_NAME=\${signal_name}" ]]; then
                    injected=true
                    trap - DEBUG
                    request_shutdown TERM 143
                fi
            }

            trap inject_reentrant_signal DEBUG
            request_shutdown HUP 129
            trap - DEBUG
            [[ ${DEFERRED_SIGNAL_NAME} == HUP &&
                ${DEFERRED_SIGNAL_STATUS} == 129 &&
                ${REGISTRATION_ESCALATION_REQUESTED} == true ]]
        ' bash "${source_copy}"
}

test_mock_signal_cli_foreground_group_registration() {
    local continue_marker engine_pid engine_status index signal_log signal_name
    local marker_pgid marker_pid marker_sid started_marker termination_marker
    local process_fields worker_identity worker_pid
    local worker_parent worker_pgid worker_sid
    local -a signal_names=(HUP INT TERM)
    local -a signal_statuses=(129 130 143)

    # The autonomous engine and the command session deliberately occupy
    # different process groups. Block the command after setsid but before PGID
    # publication, then signal the complete outer foreground group.
    printf '%s\n' 'Mock scenario: cli-signal-foreground-group-registration'
    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        started_marker="${TEST_ROOT}/group-registration-${signal_name}-started"
        continue_marker="${TEST_ROOT}/group-registration-${signal_name}-continue"
        termination_marker="${TEST_ROOT}/group-registration-${signal_name}-terminated"
        worker_identity="${TEST_ROOT}/group-registration-${signal_name}-worker"
        signal_log="${TEST_ROOT}/group-registration-${signal_name}.log"
        prepare_argument_log "group-registration-${signal_name}"

        "${REAL_SETSID}" --wait env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            MOCK_DELAY_PGID_PUBLISH=1 \
            MOCK_PGID_DELAY_STARTED_MARKER="${started_marker}" \
            MOCK_PGID_DELAY_CONTINUE_MARKER="${continue_marker}" \
            MOCK_PGID_DELAY_TERMINATION_MARKER="${termination_marker}" \
            MOCK_WORKER_IDENTITY="${worker_identity}" \
            "${MANAGED_ENGINE_UNDER_TEST}" \
            --output-dir "${OUTPUT_DIR}" \
            -- "https://example.com/watch?v=group-registration-${signal_name}" \
            >"${signal_log}" 2>&1 &
        engine_pid=$!
        wait_for_file "${started_marker}" 10 \
            "foreground-group ${signal_name} registration barrier"
        IFS= read -r marker_pid <"${started_marker}"
        [[ ${marker_pid} =~ ^[1-9][0-9]*$ ]] \
            || fail "Invalid foreground-group marker PID: ${marker_pid}"
        process_fields=$(ps -o pgid=,sid= -p "${marker_pid}") \
            || fail "Unable to inspect foreground-group marker ${marker_pid}."
        read -r marker_pgid marker_sid <<<"${process_fields}"
        assert_equals "${marker_pgid}" "${marker_sid}" \
            "foreground-group ${signal_name} marker stays in the worker session"
        worker_pid=${marker_sid}
        process_fields=$(ps -o ppid=,pgid=,sid= -p "${worker_pid}") \
            || fail "Unable to inspect foreground-group worker ${worker_pid}."
        read -r worker_parent worker_pgid worker_sid <<<"${process_fields}"
        assert_equals "${engine_pid}" "${worker_parent}" \
            "foreground-group ${signal_name} worker remains a direct child"
        assert_equals "${worker_pid}" "${worker_pgid}" \
            "foreground-group ${signal_name} worker PID equals PGID"
        assert_equals "${worker_pid}" "${worker_sid}" \
            "foreground-group ${signal_name} worker PID equals SID"

        kill "-${signal_name}" -- "-${engine_pid}"
        : >"${continue_marker}"
        engine_status=0
        wait "${engine_pid}" || engine_status=$?
        assert_equals "${signal_statuses[index]}" "${engine_status}" \
            "foreground-group ${signal_name} preserves requested status"
        assert_no_test_processes \
            "foreground-group ${signal_name} left descendants"
    done

    # A repeated request escalates immediately while retaining the first
    # conventional status, even before the PGID marker is published.
    started_marker="${TEST_ROOT}/group-registration-repeat-started"
    termination_marker="${TEST_ROOT}/group-registration-repeat-terminated"
    worker_identity="${TEST_ROOT}/group-registration-repeat-worker"
    signal_log="${TEST_ROOT}/group-registration-repeat.log"
    prepare_argument_log 'group-registration-repeat'
    "${REAL_SETSID}" --wait env \
        --default-signal=HUP \
        --default-signal=INT \
        --default-signal=TERM \
        MOCK_DELAY_PGID_PUBLISH=1 \
        MOCK_PGID_PUBLISH_DELAY_SECONDS=30 \
        MOCK_PGID_DELAY_STARTED_MARKER="${started_marker}" \
        MOCK_PGID_DELAY_TERMINATION_MARKER="${termination_marker}" \
        MOCK_WORKER_IDENTITY="${worker_identity}" \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=group-registration-repeat' \
        >"${signal_log}" 2>&1 &
    engine_pid=$!
    wait_for_file "${started_marker}" 10 \
        'foreground-group repeated-signal registration barrier'
    kill -HUP -- "-${engine_pid}"
    sleep 0.05
    kill -TERM -- "-${engine_pid}"
    engine_status=0
    wait "${engine_pid}" || engine_status=$?
    assert_equals 129 "${engine_status}" \
        'foreground-group escalation preserves first HUP status'
    # Do not release the blocked publication helper: the repeated signal must
    # discover PID=PGID and kill the complete no-fork session by itself.
    assert_no_test_processes \
        'foreground-group repeated signals left descendants'
}

test_mock_signal_cli_pgid_discovery_race() {
    local cli_source_copy="${TEST_ROOT}/download-video-pgid-race-source-only.sh"
    local race_identity="${TEST_ROOT}/cli-pgid-discovery-race-child"
    local race_log="${TEST_ROOT}/cli-pgid-discovery-race.log"
    local race_status=0

    # Force TERM after the child has published its PGID but before the caller
    # accepts it. util-linux setsid then reports raw status 15; the engine must
    # retain the conventional requested status 143.
    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${cli_source_copy}"
    chmod 0600 -- "${cli_source_copy}"
    printf '%s\n' 'Mock scenario: cli-signal-pgid-discovery-race'
    # shellcheck disable=SC2016 # Variables belong to the intentionally nested shell.
    timeout --signal=TERM --kill-after=2s 8s \
        env MOCK_CLI_SOURCE_COPY="${cli_source_copy}" \
        MOCK_WORKER_IDENTITY="${race_identity}" \
        MOCK_PRIVATE_ARIA2_HELPER="${PROJECT_DIR}/private-aria2-plan.py" \
        bash -c '
            set -euo pipefail
            source "${MOCK_CLI_SOURCE_COPY}"
            readonly PRIVATE_ARIA2_HELPER=${MOCK_PRIVATE_ARIA2_HELPER}
            trap cleanup EXIT
            resolve_lock_root
            wait_for_download_pgid() {
                local attempt
                for ((attempt = 0; attempt < 100; attempt++)); do
                    if recover_download_pgid; then
                        request_shutdown TERM 143
                        return 0
                    fi
                    sleep 0.01
                done
                return 1
            }
            # shellcheck disable=SC2016
            run_supervised_command \
                bash -c '\''exec -a "$1" sleep 30'\'' bash \
                "${MOCK_WORKER_IDENTITY}"
            exit "${DOWNLOAD_STATUS}"
        ' >"${race_log}" 2>&1 || race_status=$?
    assert_equals 143 "${race_status}" \
        'CLI PGID-discovery TERM preserves requested status'
    assert_no_test_processes \
        'CLI PGID-discovery TERM left descendants'
}

test_mock_signal_cli_ffmpeg() {
    local ffmpeg_engine_pid ffmpeg_engine_status ffmpeg_signal_log
    local ffmpeg_started_marker ffmpeg_termination_marker

    # A signal sent only to the CLI wrapper during the custom HLS FFmpeg remux must
    # reach FFmpeg and preserve the requested shell exit status.
    ffmpeg_started_marker="${TEST_ROOT}/ffmpeg-worker-started"
    ffmpeg_termination_marker="${TEST_ROOT}/ffmpeg-worker-terminated"
    ffmpeg_signal_log="${TEST_ROOT}/ffmpeg-signal.log"
    prepare_argument_log 'cli-ffmpeg-signal-forwarding'
    mkdir -- "${TEST_ROOT}/cli-ffmpeg-output"
    env MOCK_LONG_FFMPEG=1 \
        MOCK_FFMPEG_STARTED_MARKER="${ffmpeg_started_marker}" \
        MOCK_FFMPEG_TERMINATION_MARKER="${ffmpeg_termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${TEST_ROOT}/cli-ffmpeg-output" --mode video \
        --youtube-hls-firefox \
        -- 'https://www.youtube.com/watch?v=cli-ffmpeg-signal' \
        >"${ffmpeg_signal_log}" 2>&1 &
    ffmpeg_engine_pid=$!
    wait_for_file "${ffmpeg_started_marker}" 15 'CLI FFmpeg worker startup'
    kill -TERM -- "${ffmpeg_engine_pid}"
    ffmpeg_engine_status=0
    wait "${ffmpeg_engine_pid}" || ffmpeg_engine_status=$?
    assert_equals '143' "${ffmpeg_engine_status}" 'CLI FFmpeg TERM exit status'
    wait_for_file "${ffmpeg_termination_marker}" 10 'CLI FFmpeg receives TERM'
    assert_no_test_processes 'CLI FFmpeg signal forwarding left worker processes'
}

test_mock_signal_gui_session() {
    local single_session_calls single_session_log

    # The GUI owns exactly one setsid session; the engine must reuse it.
    single_session_log="${TEST_ROOT}/single-session-setsid.log"
    : >"${single_session_log}"
    prepare_argument_log 'single-session-gui'
    assert_status 0 'GUI and engine use one shared process session' \
        env MOCK_SETSID_LOG="${single_session_log}" \
        "${GUI_UNDER_TEST}"
    single_session_calls=$(wc -l <"${single_session_log}")
    assert_equals '1' "${single_session_calls}" \
        'one setsid invocation per GUI download'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_signal_gui_blocked_entry() {
    local controller_pid elapsed_milliseconds gui_pid gui_status signal_finished_at
    local signal_log signal_pid_file signal_started_at signal_tmpdir
    local zenity_started_marker zenity_termination_marker

    # Regression guard: a signal sent only to the GUI while the entry dialog is
    # blocked must interrupt Bash's explicit wait and reap Zenity immediately.
    signal_tmpdir="${TEST_ROOT}/entry-signal-tmp"
    signal_pid_file="${TEST_ROOT}/entry-signal-gui.pid"
    signal_log="${TEST_ROOT}/entry-signal.log"
    zenity_started_marker="${TEST_ROOT}/entry-zenity-started"
    zenity_termination_marker="${TEST_ROOT}/entry-zenity-terminated"
    mkdir -p -- "${signal_tmpdir}"
    rm -f -- "${signal_pid_file}" "${signal_log}" \
        "${zenity_started_marker}" "${zenity_termination_marker}"
    prepare_argument_log 'gui-signal-blocked-entry'

    timeout --signal=TERM --kill-after=2s 8s \
        env TMPDIR="${signal_tmpdir}" \
        MOCK_GUI_SIGNAL_PID_FILE="${signal_pid_file}" \
        MOCK_ZENITY_BLOCK_MODE=entry \
        MOCK_ZENITY_STARTED_MARKER="${zenity_started_marker}" \
        MOCK_ZENITY_TERMINATION_MARKER="${zenity_termination_marker}" \
        "${GUI_SIGNAL_UNDER_TEST}" >"${signal_log}" 2>&1 &
    controller_pid=$!
    wait_for_file "${signal_pid_file}" 5 'blocked-entry GUI PID publication'
    wait_for_file "${zenity_started_marker}" 5 'blocked-entry Zenity startup'
    IFS= read -r gui_pid <"${signal_pid_file}"
    [[ ${gui_pid} =~ ^[1-9][0-9]*$ ]] \
        || fail "Invalid blocked-entry GUI PID: ${gui_pid}"

    signal_started_at=$(date +%s%3N)
    kill -TERM -- "${gui_pid}"
    gui_status=0
    wait "${controller_pid}" || gui_status=$?
    signal_finished_at=$(date +%s%3N)
    elapsed_milliseconds=$((signal_finished_at - signal_started_at))
    assert_equals '143' "${gui_status}" 'blocked-entry GUI TERM status'
    ((elapsed_milliseconds < 5000)) \
        || fail "Blocked-entry TERM handling took ${elapsed_milliseconds}ms."
    wait_for_file "${zenity_termination_marker}" 5 \
        'blocked-entry Zenity receives TERM'
    assert_file_contains "${zenity_termination_marker}" TERM \
        'blocked-entry Zenity termination signal'
    assert_directory_empty "${signal_tmpdir}" \
        'blocked-entry cleanup left private temporary state'
    assert_no_test_processes 'blocked-entry TERM left GUI descendants'
}

test_mock_signal_gui_zenity_diagnostic_cleanup() {
    local controller_pid diagnostic_mode gui_pid gui_status signal_log
    local signal_pid_file signal_tmpdir zenity_started_marker
    local zenity_termination_marker
    local -a diagnostic_modes=(question text-info)

    # A Zenity failure owns a private diagnostic until the error question and,
    # when selected, its viewer have both finished. TERM at either boundary
    # must remove that diagnostic through the normal GUI cleanup trap.
    for diagnostic_mode in "${diagnostic_modes[@]}"; do
        signal_tmpdir="${TEST_ROOT}/zenity-diagnostic-signal-${diagnostic_mode}"
        signal_pid_file="${TEST_ROOT}/zenity-diagnostic-signal-${diagnostic_mode}.pid"
        signal_log="${TEST_ROOT}/zenity-diagnostic-signal-${diagnostic_mode}.log"
        zenity_started_marker="${TEST_ROOT}/zenity-diagnostic-${diagnostic_mode}-started"
        zenity_termination_marker="${TEST_ROOT}/zenity-diagnostic-${diagnostic_mode}-terminated"
        mkdir -p -- "${signal_tmpdir}"
        rm -f -- "${signal_pid_file}" "${signal_log}" \
            "${zenity_started_marker}" "${zenity_termination_marker}"
        prepare_argument_log \
            "gui-signal-zenity-diagnostic-${diagnostic_mode}"

        timeout --signal=TERM --kill-after=2s 8s \
            env TMPDIR="${signal_tmpdir}" \
            MOCK_GUI_SIGNAL_PID_FILE="${signal_pid_file}" \
            MOCK_ZENITY_ENTRY_STATUS=42 \
            MOCK_ZENITY_ENTRY_ERROR='entry failed for https://secret.example/token' \
            MOCK_QUESTION_STATUS=0 \
            MOCK_ZENITY_BLOCK_MODE="${diagnostic_mode}" \
            MOCK_ZENITY_STARTED_MARKER="${zenity_started_marker}" \
            MOCK_ZENITY_TERMINATION_MARKER="${zenity_termination_marker}" \
            "${GUI_SIGNAL_UNDER_TEST}" >"${signal_log}" 2>&1 &
        controller_pid=$!
        wait_for_file "${signal_pid_file}" 5 \
            "Zenity diagnostic ${diagnostic_mode} GUI PID publication"
        wait_for_file "${zenity_started_marker}" 5 \
            "Zenity diagnostic ${diagnostic_mode} dialog startup"
        IFS= read -r gui_pid <"${signal_pid_file}"
        [[ ${gui_pid} =~ ^[1-9][0-9]*$ ]] \
            || fail "Invalid Zenity diagnostic GUI PID: ${gui_pid}"

        kill -TERM -- "${gui_pid}"
        gui_status=0
        wait "${controller_pid}" || gui_status=$?
        assert_equals 143 "${gui_status}" \
            "Zenity diagnostic ${diagnostic_mode} TERM status"
        wait_for_file "${zenity_termination_marker}" 5 \
            "Zenity diagnostic ${diagnostic_mode} receives TERM"
        assert_file_contains "${zenity_termination_marker}" TERM \
            "Zenity diagnostic ${diagnostic_mode} termination signal"
        assert_directory_empty "${signal_tmpdir}" \
            "Zenity diagnostic ${diagnostic_mode} cleanup left temporary state"
        assert_no_test_processes \
            "Zenity diagnostic ${diagnostic_mode} TERM left descendants"
    done
}

test_mock_signal_gui_worker_registration() {
    local elapsed_milliseconds gui_status
    local gui_source_copy launched_worker_pid signal_finished_at signal_log
    local signal_started_at
    local worker_deferred_status_marker worker_identity
    local worker_launch_state_marker worker_registration_marker

    # Use the production functions in the exact vulnerable order: create an
    # asynchronous child, handle TERM, then record $! and finish registration.
    # The source-order assertion separately binds this contract to the real
    # start_download_worker implementation.
    signal_log="${TEST_ROOT}/worker-registration-signal.log"
    gui_source_copy="${TEST_ROOT}/download-video-gui-source-only.sh"
    worker_launch_state_marker="${TEST_ROOT}/worker-launch-state"
    worker_deferred_status_marker="${TEST_ROOT}/worker-deferred-status"
    worker_identity="${TEST_ROOT}/worker-pre-registration-child"
    worker_registration_marker="${TEST_ROOT}/worker-pre-registration.pid"
    rm -f -- "${signal_log}" "${worker_deferred_status_marker}" \
        "${worker_launch_state_marker}" "${worker_registration_marker}"
    sed '$d' "${PROJECT_DIR}/download-video-gui.sh" >"${gui_source_copy}"
    chmod 0600 -- "${gui_source_copy}"
    printf '%s\n' 'Mock scenario: gui-signal-worker-registration'

    signal_started_at=$(date +%s%3N)
    gui_status=0
    timeout --signal=TERM --kill-after=2s 8s \
        env MOCK_GUI_SOURCE_COPY="${gui_source_copy}" \
        MOCK_WORKER_DEFERRED_STATUS_MARKER="${worker_deferred_status_marker}" \
        MOCK_WORKER_IDENTITY="${worker_identity}" \
        MOCK_WORKER_LAUNCH_STATE_MARKER="${worker_launch_state_marker}" \
        MOCK_WORKER_PRE_REGISTRATION_MARKER="${worker_registration_marker}" \
        "${GUI_SIGNAL_REGISTRATION_UNDER_TEST}" >"${signal_log}" 2>&1 \
        || gui_status=$?
    signal_finished_at=$(date +%s%3N)
    elapsed_milliseconds=$((signal_finished_at - signal_started_at))
    assert_equals 143 "${gui_status}" \
        'worker pre-registration TERM is deferred and reaped'
    ((elapsed_milliseconds < 5000)) \
        || fail "Worker pre-registration TERM handling took ${elapsed_milliseconds}ms."
    assert_file_has_line "${worker_launch_state_marker}" true \
        'worker launch occurs inside signal-registration critical section'
    assert_file_has_line "${worker_deferred_status_marker}" 143 \
        'worker pre-registration handler defers TERM'
    IFS= read -r launched_worker_pid <"${worker_registration_marker}"
    [[ ${launched_worker_pid} =~ ^[1-9][0-9]*$ ]] \
        || fail "Invalid pre-registration worker PID: ${launched_worker_pid}"
    assert_no_test_processes \
        'worker pre-registration TERM left GUI descendants'
}

test_mock_signal_gui_group_identity_after_leader_exit() {
    local child_ready_marker="${TEST_ROOT}/gui-group-child-ready"
    local gui_source_copy="${TEST_ROOT}/download-video-gui-group-source-only.sh"
    local leader_release_marker="${TEST_ROOT}/gui-group-leader-release"
    local signal_log="${TEST_ROOT}/gui-group-descendant-signal.log"
    local termination_marker="${TEST_ROOT}/gui-group-descendant-terminated"
    local worker_identity="${TEST_ROOT}/gui-group-descendant"

    # Regression guard: after Bash reaps the original session leader, one
    # inherited-token descendant must keep the group authenticated for TERM and
    # bounded reaping without granting authority to a recycled numeric PGID.
    rm -f -- \
        "${child_ready_marker}" \
        "${leader_release_marker}" \
        "${signal_log}" \
        "${termination_marker}"
    sed '$d' "${PROJECT_DIR}/download-video-gui.sh" >"${gui_source_copy}"
    chmod 0600 -- "${gui_source_copy}"
    printf '%s\n' 'Mock scenario: gui-group-identity-after-leader-exit'

    assert_status 0 \
        'token-authenticated descendants retain worker-group authority' \
        timeout --signal=TERM --kill-after=2s 8s \
        env MOCK_GUI_SOURCE_COPY="${gui_source_copy}" \
        MOCK_GROUP_CHILD_UNDER_TEST="${GUI_GROUP_CHILD_UNDER_TEST}" \
        MOCK_GROUP_CHILD_READY_MARKER="${child_ready_marker}" \
        MOCK_GROUP_LEADER_RELEASE_MARKER="${leader_release_marker}" \
        MOCK_GROUP_TERMINATION_MARKER="${termination_marker}" \
        MOCK_WORKER_IDENTITY="${worker_identity}" \
        "${GUI_GROUP_DESCENDANT_UNDER_TEST}"
    wait_for_file "${termination_marker}" 5 \
        'authenticated descendant receives TERM after leader exit'
    assert_file_has_line "${termination_marker}" TERM \
        'descendant termination signal after leader exit'
    assert_no_test_processes \
        'leader-exit group authentication left GUI descendants'
}

test_mock_signal_gui_untrusted_group_presence() {
    python3 -I -B - "${PROJECT_DIR}/download-video-gui.sh" "${TEST_ROOT}" <<'PY_GUI_UNTRUSTED_GROUP'
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys

libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "unable to adopt orphaned fixture processes")
source = Path(sys.argv[1]).read_text().rsplit('\nmain "$@"', 1)[0]
marker = Path(sys.argv[2]) / "gui-untrusted-group-child.pid"
program = source + r'''
marker=$1
WORKER_IDENTITY_TOKEN='fixture-private-token'
/usr/bin/setsid env YTDLP_ARIA2_GUI_WORKER_TOKEN="${WORKER_IDENTITY_TOKEN}" \
    bash -c 'env -u YTDLP_ARIA2_GUI_WORKER_TOKEN sleep 30 >/dev/null 2>&1 & printf "%s\n" "$!" >"$1"; wait' \
    bash "${marker}" &
WORKER_PID=$!
for _attempt in {1..100}; do
    [[ -s ${marker} ]] && break
    sleep 0.01
done
[[ -s ${marker} ]] || exit 70
process_is_direct_child_of "${WORKER_PID}" "${BASHPID}" WORKER_PID_START_TIME false
WORKER_PGID=${WORKER_PID}
process_is_session_group_leader "${WORKER_PID}" "${BASHPID}" WORKER_PGID_START_TIME false
original_pgid=${WORKER_PGID}
kill -TERM -- "${WORKER_PID}"
wait "${WORKER_PID}" 2>/dev/null || true
if worker_group_is_current; then exit 71; fi
if ! worker_tree_alive; then exit 72; fi
signal_worker_tree TERM
signal_worker_tree KILL
if wait_for_worker_exit 1; then exit 73; fi
[[ ${WORKER_PGID} == "${original_pgid}" ]] || exit 74
IFS= read -r descendant <"${marker}"
kill -0 -- "${descendant}" || exit 75
# A wrong recorded start time cannot turn an unrelated numeric group into
# signaling authority, but observed presence still forbids cleanup.
WORKER_PID=''
WORKER_PID_START_TIME=''
WORKER_PGID_START_TIME='1'
signal_worker_tree KILL
kill -0 -- "${descendant}" || exit 76
if wait_for_worker_exit 1; then exit 77; fi
# ESRCH, unlike the lost token, is positive proof of an absent numeric group.
WORKER_PGID=2147483647
if ! wait_for_worker_exit 1; then exit 78; fi
[[ -z ${WORKER_PGID} ]] || exit 79
'''
try:
    result = subprocess.run(["bash", "-s", "--", str(marker)], input=program,
                            text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise AssertionError(f"GUI lost-group observation failed: {result.returncode}: {result.stderr}")
finally:
    if marker.exists():
        child = int(marker.read_text())
        # As subreaper this controller owns the still-unreaped orphan, so its
        # PID cannot be recycled before this final cleanup signal.
        try:
            os.kill(child, signal.SIGKILL)
            os.waitpid(child, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
PY_GUI_UNTRUSTED_GROUP
}

test_mock_signal_gui_foreground_group_registration() {
    local continue_marker gui_pid gui_status index signal_log signal_name
    local process_fields
    local signal_pid_file signal_tmpdir started_marker termination_marker
    local marker_pgid marker_pid marker_sid worker_parent worker_pgid worker_pid
    local worker_sid
    local -a signal_names=(HUP INT TERM)
    local -a signal_statuses=(129 130 143)

    # Block the engine after it creates its session but before the GUI accepts
    # the PGID. A foreground-group signal must not strand that isolated engine.
    printf '%s\n' 'Mock scenario: gui-signal-foreground-group-registration'
    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        signal_tmpdir="${TEST_ROOT}/gui-group-registration-${signal_name}"
        signal_pid_file="${TEST_ROOT}/gui-group-registration-${signal_name}.pid"
        started_marker="${TEST_ROOT}/gui-group-registration-${signal_name}-started"
        continue_marker="${TEST_ROOT}/gui-group-registration-${signal_name}-continue"
        termination_marker="${TEST_ROOT}/gui-group-registration-${signal_name}-terminated"
        signal_log="${TEST_ROOT}/gui-group-registration-${signal_name}.log"
        mkdir -p -- "${signal_tmpdir}"
        prepare_argument_log "gui-group-registration-${signal_name}"

        "${REAL_SETSID}" --wait env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            TMPDIR="${signal_tmpdir}" \
            MOCK_GUI_SIGNAL_PID_FILE="${signal_pid_file}" \
            MOCK_DELAY_PGID_PUBLISH=1 \
            MOCK_PGID_DELAY_STARTED_MARKER="${started_marker}" \
            MOCK_PGID_DELAY_CONTINUE_MARKER="${continue_marker}" \
            MOCK_PGID_DELAY_TERMINATION_MARKER="${termination_marker}" \
            "${GUI_SIGNAL_UNDER_TEST}" >"${signal_log}" 2>&1 &
        gui_pid=$!
        wait_for_file "${signal_pid_file}" 5 \
            "GUI foreground-group ${signal_name} PID publication"
        wait_for_file "${started_marker}" 10 \
            "GUI foreground-group ${signal_name} worker barrier"
        IFS= read -r marker_pid <"${started_marker}"
        [[ ${marker_pid} =~ ^[1-9][0-9]*$ ]] \
            || fail "Invalid GUI foreground-group marker PID: ${marker_pid}"
        process_fields=$(ps -o pgid=,sid= -p "${marker_pid}") \
            || fail "Unable to inspect GUI foreground-group marker ${marker_pid}."
        read -r marker_pgid marker_sid <<<"${process_fields}"
        assert_equals "${marker_pgid}" "${marker_sid}" \
            "GUI foreground-group ${signal_name} marker stays in the worker session"
        worker_pid=${marker_sid}
        process_fields=$(ps -o ppid=,pgid=,sid= -p "${worker_pid}") \
            || fail "Unable to inspect GUI foreground-group worker ${worker_pid}."
        read -r worker_parent worker_pgid worker_sid <<<"${process_fields}"
        assert_equals "${gui_pid}" "${worker_parent}" \
            "GUI foreground-group ${signal_name} worker remains a direct child"
        assert_equals "${worker_pid}" "${worker_pgid}" \
            "GUI foreground-group ${signal_name} worker PID equals PGID"
        assert_equals "${worker_pid}" "${worker_sid}" \
            "GUI foreground-group ${signal_name} worker PID equals SID"

        kill "-${signal_name}" -- "-${gui_pid}"
        : >"${continue_marker}"
        gui_status=0
        wait "${gui_pid}" || gui_status=$?
        assert_equals "${signal_statuses[index]}" "${gui_status}" \
            "GUI foreground-group ${signal_name} preserves requested status"
        assert_directory_empty "${signal_tmpdir}" \
            "GUI foreground-group ${signal_name} left private state"
        assert_no_test_processes \
            "GUI foreground-group ${signal_name} left descendants"
    done
}

test_mock_signal_gui_blocked_progress() {
    local controller_pid elapsed_milliseconds expected_status gui_pid gui_status
    local index signal_finished_at signal_log signal_name signal_pid_file
    local shutdown_budget_milliseconds=6000
    local signal_started_at signal_tmpdir worker_started_marker
    local worker_termination_marker
    local zenity_started_marker zenity_termination_marker
    local -a expected_statuses=(129 130 143)
    local -a signal_names=(HUP INT TERM)

    # Regression guard: HUP, INT, and TERM sent only to the GUI during progress
    # must stop Zenity, the monitor, and the complete worker process group.
    for index in "${!signal_names[@]}"; do
        signal_name=${signal_names[index]}
        expected_status=${expected_statuses[index]}
        signal_tmpdir="${TEST_ROOT}/progress-signal-${signal_name}"
        signal_pid_file="${TEST_ROOT}/progress-signal-${signal_name}.pid"
        signal_log="${TEST_ROOT}/progress-signal-${signal_name}.log"
        worker_started_marker="${TEST_ROOT}/progress-worker-${signal_name}-started"
        worker_termination_marker="${TEST_ROOT}/progress-worker-${signal_name}-terminated"
        zenity_started_marker="${TEST_ROOT}/progress-zenity-${signal_name}-started"
        zenity_termination_marker="${TEST_ROOT}/progress-zenity-${signal_name}-terminated"
        mkdir -p -- "${signal_tmpdir}"
        rm -f -- "${signal_pid_file}" "${signal_log}" \
            "${worker_started_marker}" "${worker_termination_marker}" \
            "${zenity_started_marker}" "${zenity_termination_marker}" \
            "${OUTPUT_DIR}/Mock media [abc123].webm"
        prepare_argument_log "gui-signal-blocked-progress-${signal_name}"

        timeout --signal=TERM --kill-after=2s 8s \
            env TMPDIR="${signal_tmpdir}" \
            MOCK_GUI_SIGNAL_PID_FILE="${signal_pid_file}" \
            MOCK_PLAN_PROTOCOL='m3u8_native' \
            MOCK_LONG_DOWNLOAD=1 \
            MOCK_STARTED_MARKER="${worker_started_marker}" \
            MOCK_TERMINATION_MARKER="${worker_termination_marker}" \
            MOCK_ZENITY_BLOCK_MODE=progress \
            MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
            MOCK_ZENITY_STARTED_MARKER="${zenity_started_marker}" \
            MOCK_ZENITY_TERMINATION_MARKER="${zenity_termination_marker}" \
            "${GUI_SIGNAL_UNDER_TEST}" >"${signal_log}" 2>&1 &
        controller_pid=$!
        wait_for_file "${signal_pid_file}" 5 \
            "blocked-progress ${signal_name} GUI PID publication"
        wait_for_file "${worker_started_marker}" 10 \
            "blocked-progress ${signal_name} worker startup"
        wait_for_file "${zenity_started_marker}" 5 \
            "blocked-progress ${signal_name} Zenity startup"
        IFS= read -r gui_pid <"${signal_pid_file}"
        [[ ${gui_pid} =~ ^[1-9][0-9]*$ ]] \
            || fail "Invalid blocked-progress GUI PID: ${gui_pid}"

        signal_started_at=$(date +%s%3N)
        kill "-${signal_name}" -- "${gui_pid}"
        gui_status=0
        wait "${controller_pid}" || gui_status=$?
        signal_finished_at=$(date +%s%3N)
        elapsed_milliseconds=$((signal_finished_at - signal_started_at))
        assert_equals "${expected_status}" "${gui_status}" \
            "blocked-progress GUI ${signal_name} status"
        # Worker TERM/KILL polling can consume five seconds. Leave bounded CI
        # scheduling headroom while the independent eight-second watchdog
        # continues to distinguish a stalled cleanup path.
        ((elapsed_milliseconds < shutdown_budget_milliseconds)) \
            || fail "Blocked-progress ${signal_name} handling took ${elapsed_milliseconds}ms."
        wait_for_file "${worker_termination_marker}" 5 \
            "blocked-progress ${signal_name} worker receives TERM"
        wait_for_file "${zenity_termination_marker}" 5 \
            "blocked-progress ${signal_name} Zenity receives TERM"
        assert_file_contains "${zenity_termination_marker}" TERM \
            "blocked-progress ${signal_name} Zenity termination signal"
        assert_directory_empty "${signal_tmpdir}" \
            "blocked-progress ${signal_name} cleanup left temporary state"
        assert_no_test_processes \
            "blocked-progress ${signal_name} left GUI descendants"
    done
}

test_mock_signal_gui_cancellation() {
    local cancel_info_log cancel_monitor_bundle cancel_monitor_question_log
    local cancel_monitor_termination_marker cancel_monitor_worker_marker
    local published_cancel_info_log published_cancel_marker
    local published_cancel_question_log
    local pgid_delay_marker termination_marker worker_start_marker
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    local -a cancel_info_arguments=()
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    local -a published_cancel_question_arguments=()

    # Scenario: user cancellation terminates the complete process group.
    termination_marker="${TEST_ROOT}/terminated"
    worker_start_marker="${TEST_ROOT}/cancel-worker-started"
    rm -f -- "${termination_marker}" "${worker_start_marker}"
    prepare_argument_log 'cancel-process-group'
    assert_status_split 130 'cancellation terminates the process group' \
        timeout --signal=TERM --kill-after=2s 15s \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_LONG_DOWNLOAD=1 MOCK_CANCEL=1 \
        MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${worker_start_marker}" \
        MOCK_TERMINATION_MARKER="${termination_marker}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${termination_marker}" 10 'worker group receives TERM'
    assert_no_test_processes 'ordinary cancellation left worker processes'

    # Closing Zenity also closes the progress FIFO. A monitor terminated by the
    # resulting SIGPIPE must not turn an explicit user cancellation into a
    # technical progress-monitor failure.
    cancel_monitor_bundle="${TEST_ROOT}/cancel-sigpipe-monitor-bundle"
    mkdir -p -- "${cancel_monitor_bundle}"
    install -m 0755 -- \
        "${PROJECT_DIR}/download-video-gui.sh" \
        "${PROJECT_DIR}/download-video.sh" \
        "${cancel_monitor_bundle}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${cancel_monitor_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${cancel_monitor_bundle}/private-process-supervisor.py"
    cat >"${cancel_monitor_bundle}/progress-monitor.sh" <<'EOF_CANCEL_SIGPIPE_MONITOR'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : progress-monitor.sh
# Purpose     : Simulate the expected monitor status after Zenity cancellation.
# ==============================================================================

set -euo pipefail

printf '%s\n' '0'
exit 141
EOF_CANCEL_SIGPIPE_MONITOR
    chmod 0755 -- "${cancel_monitor_bundle}/progress-monitor.sh"
    cancel_info_log="${TEST_ROOT}/cancel-sigpipe-info.bin"
    cancel_monitor_question_log="${TEST_ROOT}/cancel-sigpipe-question.bin"
    cancel_monitor_termination_marker="${TEST_ROOT}/cancel-sigpipe-terminated"
    cancel_monitor_worker_marker="${TEST_ROOT}/cancel-sigpipe-worker-started"
    rm -f -- \
        "${cancel_info_log}" \
        "${cancel_monitor_question_log}" \
        "${cancel_monitor_termination_marker}" \
        "${cancel_monitor_worker_marker}"
    prepare_argument_log 'cancel-with-monitor-sigpipe'
    assert_status_split 130 \
        'monitor SIGPIPE does not mask an explicit cancellation' \
        env MOCK_GUI_REAL="${cancel_monitor_bundle}/download-video-gui.sh" \
        MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_LONG_DOWNLOAD=1 MOCK_CANCEL=1 \
        MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${cancel_monitor_worker_marker}" \
        MOCK_TERMINATION_MARKER="${cancel_monitor_termination_marker}" \
        MOCK_INFO_ARGS_LOG="${cancel_info_log}" \
        MOCK_QUESTION_ARGS_LOG="${cancel_monitor_question_log}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${cancel_monitor_termination_marker}" 10 \
        'monitor-SIGPIPE cancellation reaches the worker group'
    read_arguments "${cancel_info_log}" cancel_info_arguments
    assert_array_contains cancel_info_arguments '--info' \
        'monitor-SIGPIPE cancellation uses an information dialog'
    assert_array_contains cancel_info_arguments \
        '--text=The download was canceled.' \
        'monitor-SIGPIPE cancellation message'
    assert_array_contains cancel_info_arguments '--ok-label=Close' \
        'monitor-SIGPIPE cancellation Close action'
    [[ ! -s ${cancel_monitor_question_log} ]] \
        || fail 'Monitor SIGPIPE cancellation opened a failure diagnostic.'
    assert_text_not_contains "${ASSERT_STDERR}" \
        'The progress monitor failed' \
        'monitor-SIGPIPE cancellation diagnostic'
    assert_no_test_processes \
        'monitor-SIGPIPE cancellation left worker processes'

    # The private result record is the engine's atomic success boundary. A
    # cancel that arrives after its no-overwrite publication must not report a
    # contradiction while the confirmed media and result already exist.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    published_cancel_marker="${TEST_ROOT}/published-result-before-cancel"
    published_cancel_info_log="${TEST_ROOT}/published-result-cancel-info.bin"
    published_cancel_question_log="${TEST_ROOT}/published-result-cancel-question.bin"
    rm -f -- \
        "${published_cancel_marker}" \
        "${published_cancel_info_log}" \
        "${published_cancel_question_log}"
    prepare_argument_log 'cancel-after-result-publication'
    assert_status 0 'confirmed result publication wins the cancel race' \
        env MOCK_BLOCK_AFTER_RESULT_PUBLICATION=1 \
        MOCK_RESULT_PUBLICATION_MARKER="${published_cancel_marker}" \
        MOCK_CANCEL=1 MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${published_cancel_marker}" \
        MOCK_INFO_ARGS_LOG="${published_cancel_info_log}" \
        MOCK_QUESTION_ARGS_LOG="${published_cancel_question_log}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${published_cancel_marker}" 10 \
        'result record is published before cancellation'
    [[ ! -s ${published_cancel_info_log} ]] \
        || fail 'A confirmed published result was reported as canceled.'
    read_arguments \
        "${published_cancel_question_log}" \
        published_cancel_question_arguments
    assert_array_contains_prefix published_cancel_question_arguments \
        '--text=The download is complete.' \
        'published-result cancel race completion dialog'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].webm" ]] \
        || fail 'Published-result cancel race lost the confirmed media.'
    assert_no_test_processes \
        'published-result cancel race left worker processes'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    # Delayed PGID-file publication must still leave the GUI in control of the
    # setsid child group through the Linux /proc fallback. Some nested container
    # PID namespaces do not expose the shell's child PIDs through this procfs view;
    # skip only this environment-specific fallback test in that case.
    # This predicate determines whether the current procfs can exercise the fallback.
    # shellcheck disable=SC2310
    if proc_children_fallback_is_observable; then
        pgid_delay_marker="${TEST_ROOT}/pgid-delay-terminated"
        prepare_argument_log 'delayed-pgid-publication'
        assert_status_split 130 'cancellation works before PGID-file publication' \
            timeout --signal=TERM --kill-after=2s 15s \
            env MOCK_DELAY_PGID_PUBLISH=1 MOCK_CANCEL=1 \
            MOCK_PGID_DELAY_TERMINATION_MARKER="${pgid_delay_marker}" \
            "${GUI_UNDER_TEST}"
        wait_for_file "${pgid_delay_marker}" 10 'delayed PGID worker receives TERM'
        assert_no_test_processes 'delayed-PGID cancellation left worker processes'
    else
        printf '%s\n' 'Mock scenario: delayed-pgid-publication (skipped: procfs child visibility unavailable)'
    fi

    # A Cancel response received after a successful worker exit must be reported as
    # success, not as a misleading cancellation.
    prepare_argument_log 'cancel-after-worker-success'
    assert_status 0 'late cancellation does not hide completed download' \
        env MOCK_CANCEL_AFTER_EOF=1 "${GUI_UNDER_TEST}"
    assert_no_test_processes 'late-cancel success left worker processes'
}

test_mock_signal_gui_startup_error() {
    local logs_after logs_before pgid_question_log pgid_text_info_log
    local silent_error_capture silent_question_log silent_text_info_log

    # A worker that fails before PGID publication still exposes its safe diagnostic.
    pgid_question_log="${TEST_ROOT}/pgid-start-question.bin"
    pgid_text_info_log="${TEST_ROOT}/pgid-start-text-info.bin"
    rm -f -- "${pgid_question_log}" "${pgid_text_info_log}"
    prepare_argument_log 'failed-pgid-publication'
    assert_status 75 'failed worker startup status is preserved' \
        env MOCK_SETSID_START_STATUS=75 \
        MOCK_QUESTION_ARGS_LOG="${pgid_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${pgid_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${pgid_question_log}" \
        'The download process exited during startup with status 75.' \
        'worker-startup diagnostic'
    [[ ! -s ${pgid_text_info_log} ]] \
        || fail 'Close unexpectedly opened the worker-startup diagnostic log.'

    silent_error_capture="${TEST_ROOT}/silent-start-error.txt"
    silent_question_log="${TEST_ROOT}/silent-start-question.bin"
    silent_text_info_log="${TEST_ROOT}/silent-start-text-info.bin"
    rm -f -- "${silent_error_capture}" "${silent_question_log}" \
        "${silent_text_info_log}"
    logs_before=$(count_logs)
    prepare_argument_log 'silent-worker-start-failure'
    assert_status 75 'silent worker-start failure preserves its status' \
        env MOCK_SETSID_START_STATUS=75 \
        MOCK_SETSID_SILENT_FAILURE=1 \
        MOCK_ERROR_CAPTURE="${silent_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${silent_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${silent_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${silent_error_capture}" \
        'A safe diagnostic log could not be prepared.' \
        'silent-worker safe fallback'
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'silent worker-start failure retains no empty log'
    [[ ! -s ${silent_question_log} ]] \
        || fail 'Silent worker-start failure incorrectly offered View log.'
    [[ ! -s ${silent_text_info_log} ]] \
        || fail 'Silent worker-start failure incorrectly opened a log viewer.'
}

test_mock_signal_zenity_status() {
    local diagnostic_capture diagnostic_file error_capture
    local oversized_question_log oversized_text_info_log
    local unexpected_question_log unexpected_text_info_log
    local -a text_info_arguments=()

    # Scenario group: Zenity dialog status mapping.
    error_capture="${TEST_ROOT}/zenity-errors.txt"
    assert_status 1 'URL entry timeout is reported' \
        env MOCK_ZENITY_ENTRY_STATUS=5 MOCK_ERROR_CAPTURE="${error_capture}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${error_capture}" 'URL entry dialog timed out' \
        'URL timeout dialog'

    unexpected_question_log="${TEST_ROOT}/zenity-error-question.bin"
    unexpected_text_info_log="${TEST_ROOT}/zenity-error-text-info.bin"
    diagnostic_capture="${TEST_ROOT}/zenity-error-diagnostic.txt"
    rm -f -- "${unexpected_question_log}" \
        "${unexpected_text_info_log}" "${diagnostic_capture}"
    assert_status 1 'unexpected Zenity entry error is reported' \
        env MOCK_ZENITY_ENTRY_STATUS=42 \
        MOCK_ZENITY_ENTRY_ERROR='Zenity failed for https://secret.example/private-token' \
        MOCK_QUESTION_STATUS=0 \
        MOCK_QUESTION_ARGS_LOG="${unexpected_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${unexpected_text_info_log}" \
        MOCK_TEXT_INFO_CONTENT_CAPTURE="${diagnostic_capture}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${unexpected_question_log}" \
        'Zenity could not display the URL entry dialog.' \
        'Zenity entry error diagnostic'
    read_arguments "${unexpected_text_info_log}" text_info_arguments
    assert_array_contains text_info_arguments '--text-info' \
        'Zenity error opens the diagnostic viewer'
    diagnostic_file=''
    for argument in "${text_info_arguments[@]}"; do
        case ${argument} in
            --filename=*) diagnostic_file=${argument#--filename=} ;;
            *) ;;
        esac
    done
    [[ -n ${diagnostic_file} && ! -e ${diagnostic_file} ]] \
        || fail 'The private Zenity diagnostic was not removed after viewing.'
    assert_file_contains "${diagnostic_capture}" \
        '[REDACTED_URL]' \
        'Zenity viewer receives the correct private diagnostic'
    assert_file_not_contains "${diagnostic_capture}" \
        'secret.example' \
        'Zenity diagnostic redacts URL-like values'

    oversized_question_log="${TEST_ROOT}/zenity-oversized-question.bin"
    oversized_text_info_log="${TEST_ROOT}/zenity-oversized-text-info.bin"
    rm -f -- "${oversized_question_log}" "${oversized_text_info_log}"
    assert_status 1 'oversized Zenity entry output is rejected' \
        env MOCK_ZENITY_ENTRY_OUTPUT_BYTES=65537 \
        MOCK_QUESTION_STATUS=1 \
        MOCK_QUESTION_ARGS_LOG="${oversized_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${oversized_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${oversized_question_log}" \
        'Zenity could not display the URL entry dialog.' \
        'oversized Zenity output diagnostic'
    [[ ! -s ${oversized_text_info_log} ]] \
        || fail 'Close unexpectedly opened the oversized-output diagnostic.'
}

run_mock_signal_group() {
    python3 -B "${PROJECT_DIR}/tests/process-supervision-integration.py"
    test_mock_signal_unbound_directory_registration
    test_mock_signal_private_media_registration
    test_mock_signal_cli_lost_group_leader
    test_mock_signal_transport_preserves_active_input
    test_mock_signal_cli_download
    test_mock_signal_cli_aria2_diagnostic
    test_mock_signal_cleanup_requires_quiescence
    test_mock_signal_private_record_registration
    test_mock_signal_cli_leader_exit_descendant
    test_mock_signal_cli_worker_registration
    test_mock_signal_cli_runtime_preparation
    test_mock_pre_env_observer_controls
    test_mock_signal_cli_pre_env_registration
    test_mock_signal_registration_handoff
    test_mock_signal_cli_foreground_group_registration
    test_mock_signal_cli_pgid_discovery_race
    test_mock_signal_cli_ffmpeg
    test_mock_signal_gui_session
    test_mock_signal_gui_blocked_entry
    test_mock_signal_gui_zenity_diagnostic_cleanup
    test_mock_signal_gui_worker_registration
    test_mock_signal_gui_group_identity_after_leader_exit
    test_mock_signal_gui_untrusted_group_presence
    test_mock_signal_gui_foreground_group_registration
    test_mock_signal_gui_blocked_progress
    test_mock_signal_gui_cancellation
    test_mock_signal_gui_startup_error
    test_mock_signal_zenity_status
}
