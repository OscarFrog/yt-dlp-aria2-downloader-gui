#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-runtime.sh
# Purpose     : Qualify runtime admission, capabilities, and media validation errors.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    TEST_ROOT OUTPUT_DIR MOCK_RUNTIME_MANAGER_LOG \
    MANAGED_ENGINE_UNDER_TEST ASSERT_OUTPUT PROJECT_DIR \
    MOCK_ARIA2_ARG_LOG MOCK_ARG_LOG MOCK_NO_DENO_BIN \
    MOCK_BIN GUI_UNDER_TEST HOME_DIR \
    MOCK_GROUP

# Sourced by mock-integration.sh in the same Bash process. Helpers and tests
# share its PROJECT_DIR, private TEST_ROOT paths, command doubles and assertions;
# invocation remains under the entry point's options, traps and group dispatch.

test_mock_managed_runtime_attestation() {
    local deno_control_log="${TEST_ROOT}/managed-deno-control.log"
    local ytdlp_control_log="${TEST_ROOT}/managed-ytdlp-control.log"
    local -a runtime_manager_arguments=()

    # A managed launch consumes one runtime-manager attestation and must not
    # repeat the yt-dlp/Deno discovery commands already covered by that proof.
    prepare_argument_log 'managed-runtime-attestation'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    : >"${MOCK_RUNTIME_MANAGER_LOG}"
    : >"${ytdlp_control_log}"
    : >"${deno_control_log}"
    assert_status 0 'managed runtime attestation initializes the engine' \
        env -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
        -u YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE \
        MOCK_YTDLP_CONTROL_LOG="${ytdlp_control_log}" \
        MOCK_DENO_CONTROL_LOG="${deno_control_log}" \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=managed-attestation'
    read_arguments "${MOCK_RUNTIME_MANAGER_LOG}" runtime_manager_arguments
    assert_equals '2' "${#runtime_manager_arguments[@]}" \
        'managed runtime preparation argument count'
    assert_equals 'prepare' "${runtime_manager_arguments[0]}" \
        'managed runtime preparation command'
    assert_equals 'update' "${runtime_manager_arguments[1]}" \
        'managed runtime preparation action'
    [[ ! -s ${ytdlp_control_log} ]] \
        || fail 'managed engine repeated yt-dlp version/help discovery after attestation'
    [[ ! -s ${deno_control_log} ]] \
        || fail 'managed engine repeated Deno version discovery after attestation'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'managed-runtime-old-version'
    assert_status 1 'managed attestation cannot bypass the engine minimum version' \
        env -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
        YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0 \
        MOCK_MANAGED_YTDLP_VERSION=2026.06.08 \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        -- 'https://example.com/watch?v=managed-old-version'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'yt-dlp 2026.06.09 or later is required' \
        'managed runtime minimum-version diagnostic'

    prepare_argument_log 'managed-runtime-malformed-attestation'
    assert_status 69 'malformed managed runtime attestation is rejected' \
        env -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
        YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0 \
        MOCK_RUNTIME_ATTESTATION_MALFORMED=1 \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        -- 'https://example.com/watch?v=managed-malformed-attestation'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'managed runtime attestation is malformed or unsupported' \
        'malformed managed runtime attestation diagnostic'
}

test_mock_runtime_version_formats() {
    local compatible_ytdlp_version

    # Scenario group: runtime version and capability handling.
    for compatible_ytdlp_version in \
        '2026.06.09.20260727' \
        '2026.06.09-1.fc44' \
        '2026.06.09+custom'; do
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
        prepare_argument_log "version-${compatible_ytdlp_version//[^[:alnum:]]/_}"
        assert_status 0 "compatible yt-dlp version ${compatible_ytdlp_version}" \
            env MOCK_YTDLP_VERSION="${compatible_ytdlp_version}" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" \
            -- 'https://example.com/watch?v=version-suffix'
    done
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    assert_status 1 'unparseable yt-dlp version is rejected clearly' \
        env MOCK_YTDLP_VERSION=not-a-version \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=bad-version'
    assert_text_contains "${ASSERT_OUTPUT}" 'unable to parse the yt-dlp version' \
        'unparseable yt-dlp diagnostic'
}

test_mock_runtime_worker_failure() {
    local escalated_timeout_probe_result forbidden_source_name=''
    local invalid_probe_result timeout_probe_result

    forbidden_source_name=$(printf '\170\150\141\155\163\164\145\162')
    prepare_argument_log 'forbidden-external-diagnostic-redaction'
    assert_status 1 'forbidden external diagnostic is redacted' \
        env MOCK_PLAN_EXIT_STATUS=1 MOCK_FORBIDDEN_EXTERNAL_ERROR=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=redacted-external-diagnostic'
    assert_text_not_contains "${ASSERT_OUTPUT}" "${forbidden_source_name}" \
        'forbidden external source label is absent from engine diagnostics'
    assert_text_contains "${ASSERT_OUTPUT}" '[REDACTED_SOURCE]' \
        'forbidden external source label is replaced deterministically'

    prepare_argument_log 'immediate-worker-failure'
    assert_status 23 'an immediate yt-dlp failure preserves its real status' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_YTDLP_EXIT_STATUS=23 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=immediate-worker-failure'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Download failed with exit code 23.' \
        'immediate worker status diagnostic'

    prepare_argument_log 'ffprobe-validation-failure'
    invalid_probe_result="${TEST_ROOT}/invalid-probe-result.txt"
    assert_status 65 'a media file rejected by FFprobe is not published as success' \
        env MOCK_FFPROBE_EXIT_STATUS=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${invalid_probe_result}" \
        -- 'https://example.com/watch?v=invalid-probe'
    [[ ! -e ${invalid_probe_result} ]] \
        || fail 'A result file was published after FFprobe validation failed.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media file failed FFprobe validation' \
        'FFprobe failure diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: probe-error' \
        'FFprobe failure bounded reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'ffprobe-validation-timeout'
    timeout_probe_result="${TEST_ROOT}/timeout-probe-result.txt"
    assert_status 65 'an FFprobe timeout has a distinct validation reason' \
        env MOCK_FFPROBE_EXIT_STATUS=124 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${timeout_probe_result}" \
        -- 'https://example.com/watch?v=timeout-probe'
    [[ ! -e ${timeout_probe_result} ]] \
        || fail 'A result file was published after an FFprobe timeout.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: probe-timeout' \
        'FFprobe timeout bounded reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'ffprobe-validation-escalated-timeout'
    escalated_timeout_probe_result="${TEST_ROOT}/escalated-timeout-probe-result.txt"
    assert_status 65 'an escalated FFprobe timeout keeps the timeout reason' \
        env MOCK_FFPROBE_EXIT_STATUS=137 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${escalated_timeout_probe_result}" \
        -- 'https://example.com/watch?v=escalated-timeout-probe'
    [[ ! -e ${escalated_timeout_probe_result} ]] \
        || fail 'A result file was published after an escalated FFprobe timeout.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: probe-timeout' \
        'FFprobe escalated-timeout bounded reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_runtime_version_overflow() {
    local oversized_version_case

    # Fixed-width Bash arithmetic must never see unbounded external version
    # components. 2^64+1 wraps to 1 on common 64-bit Bash builds, so these
    # cases are a deterministic negative control for conversion-before-bound.
    for oversized_version_case in \
        '18446744073709551617.0.0' \
        '0000000000000000000018446744073709551617.0.0'; do
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
        prepare_argument_log "yt-version-overflow-${oversized_version_case//[^[:alnum:]]/_}"
        assert_status 0 "mathematically newer huge yt-dlp version ${oversized_version_case}" \
            env MOCK_YTDLP_VERSION="${oversized_version_case}" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" \
            -- 'https://example.com/watch?v=huge-version'
    done
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'aria2-version-overflow'
    assert_status 0 'mathematically newer huge aria2 version is accepted safely' \
        env MOCK_ARIA2_VERSION='18446744073709551617.0.0' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=huge-aria2-version'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'deno-version-overflow'
    assert_status 0 'mathematically newer huge Deno version is accepted safely' \
        env MOCK_DENO_VERSION='18446744073709551617.0.0' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://www.youtube.com/watch?v=huge-deno-version'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_runtime_media_validation() {
    local truncated_tail_result valid_tail_skew_result

    prepare_argument_log 'ffprobe-valid-av-tail-skew'
    valid_tail_skew_result="${TEST_ROOT}/valid-tail-skew-result.txt"
    rm -f -- "${valid_tail_skew_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"
    assert_status 0 \
        'video remains valid when audio reaches the declared tail after content video ends' \
        env MOCK_FFPROBE_VIDEO_TAIL_PTS='90.000000' \
        MOCK_FFPROBE_VIDEO_TAIL_DURATION='0.000000' \
        MOCK_FFPROBE_AUDIO_TAIL_PTS='119.500000' \
        MOCK_FFPROBE_AUDIO_TAIL_DURATION='0.500000' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --result-file "${valid_tail_skew_result}" \
        -- 'https://example.com/watch?v=valid-av-tail-skew'
    [[ -s ${valid_tail_skew_result} ]] \
        || fail 'Valid A/V tail-skew media did not publish a result file.'
    rm -f -- "${valid_tail_skew_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'ffprobe-tail-truncation'
    truncated_tail_result="${TEST_ROOT}/truncated-tail-result.txt"
    rm -f -- "${truncated_tail_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"
    assert_status 65 \
        'metadata-parseable media whose primary stream ends far before the declared duration is rejected' \
        env MOCK_FFPROBE_TAIL_PTS='90.000000' \
        MOCK_FFPROBE_TAIL_DURATION='0.000000' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --result-file "${truncated_tail_result}" \
        -- 'https://example.com/watch?v=truncated-tail'
    [[ ! -e ${truncated_tail_result} ]] \
        || fail 'Tail-truncated media published a result file.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media file failed FFprobe validation' \
        'tail-truncation validation diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: tail-inconsistent' \
        'tail-truncation bounded reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_runtime_dependencies() {
    local managed_deno_args managed_deno_output
    local -a managed_deno_arguments tls_transport_arguments

    prepare_argument_log 'aria2-gnutls-https-native-fallback'
    assert_status 0 'affected aria2 GnuTLS HTTPS uses native transport' \
        env MOCK_ARIA2_TLS_LIBRARY='GnuTLS/3.8.11' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=gnutls-native-fallback'
    [[ ! -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'Affected aria2 GnuTLS build received a direct HTTPS transfer.'
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    tls_transport_arguments=()
    read_arguments "${MOCK_ARG_LOG}" tls_transport_arguments
    assert_array_contains tls_transport_arguments '--load-info-json' \
        'affected aria2 GnuTLS build uses the frozen native yt-dlp plan'
    assert_array_not_contains tls_transport_arguments '--skip-download' \
        'affected aria2 GnuTLS build retains native yt-dlp transfer'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'aria2-fixed-gnutls-https-direct'
    assert_status 0 'fixed-generation aria2 GnuTLS permits direct HTTPS' \
        env MOCK_ARIA2_VERSION='1.38.0' \
        MOCK_ARIA2_TLS_LIBRARY='GnuTLS/3.8.11' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=gnutls-direct-fixed'
    [[ -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'Fixed-generation aria2 GnuTLS build did not use direct HTTPS.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'missing-required-ytdlp-capability'
    assert_status 1 'yt-dlp builds missing a consumed option fail early' \
        env MOCK_YTDLP_MISSING_AUDIO_QUALITY=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=missing-ytdlp-capability'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'this yt-dlp build does not support --audio-quality.' \
        'missing consumed yt-dlp capability diagnostic'

    assert_status 1 'old yt-dlp version is rejected' \
        env MOCK_YTDLP_VERSION=2026.06.08 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=old-yt-dlp'
    managed_deno_output="${TEST_ROOT}/managed-deno-output"
    managed_deno_args="${TEST_ROOT}/managed-deno-args.bin"
    mkdir -p -- "${managed_deno_output}"
    : >"${managed_deno_args}"
    assert_status 0 'YouTube accepts managed Deno outside PATH' \
        env PATH="${MOCK_NO_DENO_BIN}:/usr/bin:/bin" \
        YTDLP_ARIA2_DENO_BIN="${MOCK_BIN}/deno" \
        MOCK_ARG_LOG="${managed_deno_args}" \
        MOCK_OUTPUT_DIR="${managed_deno_output}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${managed_deno_output}" \
        -- 'https://www.youtube.com/watch?v=managed-deno-outside-path'
    # shellcheck disable=SC2034 # Accessed indirectly by name through read/assert helper APIs.
    managed_deno_arguments=()
    read_arguments "${managed_deno_args}" managed_deno_arguments
    assert_option_value managed_deno_arguments '--js-runtimes' \
        "deno:${MOCK_BIN}/deno" 'managed Deno absolute path outside PATH'
    assert_status 0 'generic extraction remains usable without Deno' \
        env MOCK_DENO_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=no-deno-generic'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    assert_status 1 'YouTube extraction requires Deno' \
        env MOCK_DENO_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://www.youtube.com/watch?v=no-deno-youtube'
    assert_status 1 'old Deno version is rejected' \
        env MOCK_DENO_VERSION=2.2.9 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://www.youtube.com/watch?v=old-deno'
    assert_status 1 'old aria2c version is rejected' \
        env MOCK_ARIA2_VERSION=1.36.0 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=old-aria2'
    assert_status 1 'minimum Deno prerelease is rejected' \
        env MOCK_DENO_VERSION=2.3.0-beta \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://www.youtube.com/watch?v=prerelease-deno'
    assert_status 1 'minimum aria2 prerelease is rejected' \
        env MOCK_ARIA2_VERSION=1.37.0-beta \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=prerelease-aria2'
    assert_status 1 'missing aria2c capability is rejected' \
        env MOCK_ARIA2_DESCRIPTION_ONLY=1 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=missing-aria2-option'
}

test_mock_runtime_progress_errors() {
    local monitor_bundle monitor_question_log monitor_text_info_log
    local progress_error_marker progress_error_question_log progress_error_started
    local progress_error_text_info_log progress_timeout_marker
    local progress_timeout_question_log progress_timeout_started
    local progress_timeout_text_info_log
    local previous_media previous_media_identity previous_media_sha256
    local previous_media_final_identity previous_media_final_sha256
    local progress_timeout_output progress_error_output monitor_output

    # Regression guard: a completed download in the shared destination must
    # neither prevent these workers from starting nor be removed by their tests.
    previous_media="${OUTPUT_DIR}/Mock media [abc123].webm"
    if [[ ! -e ${previous_media} && ! -L ${previous_media} ]]; then
        printf '%s\n' 'Earlier completed media' >"${previous_media}"
    fi
    [[ -f ${previous_media} && ! -L ${previous_media} ]] \
        || fail 'Progress error fixture requires a regular previous media file.'
    previous_media_identity=$(stat -c '%d:%i:%s:%y:%z' -- "${previous_media}")
    previous_media_sha256=$(sha256sum -- "${previous_media}")

    # Each failure is injected after startup, so give it a fresh destination
    # independently of completed media from earlier scenarios in this group.
    progress_timeout_output="${TEST_ROOT}/progress-timeout-output"
    progress_error_output="${TEST_ROOT}/progress-error-output"
    monitor_output="${TEST_ROOT}/progress-monitor-output"
    mkdir -- "${progress_timeout_output}" "${progress_error_output}" \
        "${monitor_output}"

    # Progress-dialog timeout and unexpected error terminate the worker group.
    # Synchronize the injected Zenity failure with a worker-start marker so the
    # termination assertion proves signal delivery, not scheduler ordering.
    progress_timeout_started="${TEST_ROOT}/progress-timeout-started"
    progress_timeout_marker="${TEST_ROOT}/progress-timeout-terminated"
    progress_timeout_question_log="${TEST_ROOT}/progress-timeout-question.bin"
    progress_timeout_text_info_log="${TEST_ROOT}/progress-timeout-text-info.bin"
    rm -f -- "${progress_timeout_question_log}" \
        "${progress_timeout_text_info_log}"
    prepare_argument_log 'progress-timeout'
    assert_status 1 'progress dialog timeout is propagated' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_OUTPUT_DIR="${progress_timeout_output}" \
        MOCK_LONG_DOWNLOAD=1 MOCK_ZENITY_PROGRESS_STATUS=5 \
        MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${progress_timeout_started}" \
        MOCK_TERMINATION_MARKER="${progress_timeout_marker}" \
        MOCK_QUESTION_ARGS_LOG="${progress_timeout_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${progress_timeout_text_info_log}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${progress_timeout_started}" 10 \
        'progress-timeout worker started before injected timeout'
    wait_for_file "${progress_timeout_marker}" 10 \
        'progress-timeout worker receives TERM'
    assert_diagnostic_question "${progress_timeout_question_log}" \
        'progress dialog timed out' \
        'progress-timeout diagnostic'
    [[ ! -s ${progress_timeout_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-timeout diagnostic log.'

    progress_error_started="${TEST_ROOT}/progress-error-started"
    progress_error_marker="${TEST_ROOT}/progress-error-terminated"
    progress_error_question_log="${TEST_ROOT}/progress-error-question.bin"
    progress_error_text_info_log="${TEST_ROOT}/progress-error-text-info.bin"
    rm -f -- "${progress_error_question_log}" \
        "${progress_error_text_info_log}"
    prepare_argument_log 'progress-error'
    assert_status 1 'unexpected progress dialog status is reported' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_OUTPUT_DIR="${progress_error_output}" \
        MOCK_LONG_DOWNLOAD=1 MOCK_ZENITY_PROGRESS_STATUS=42 \
        MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${progress_error_started}" \
        MOCK_TERMINATION_MARKER="${progress_error_marker}" \
        MOCK_QUESTION_ARGS_LOG="${progress_error_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${progress_error_text_info_log}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${progress_error_started}" 10 \
        'progress-error worker started before injected error'
    wait_for_file "${progress_error_marker}" 10 \
        'progress-error worker receives TERM'
    assert_diagnostic_question "${progress_error_question_log}" \
        'status 42' \
        'unexpected progress status diagnostic'
    [[ ! -s ${progress_error_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-error diagnostic log.'

    monitor_bundle="${TEST_ROOT}/progress-monitor-failure-bundle"
    mkdir -p -- "${monitor_bundle}"
    install -m 0755 -- "${PROJECT_DIR}/download-video-gui.sh" \
        "${PROJECT_DIR}/download-video.sh" "${monitor_bundle}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${monitor_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${monitor_bundle}/private-process-supervisor.py"
    cat >"${monitor_bundle}/progress-monitor.sh" <<'EOF_PROGRESS_MONITOR_FAILURE'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : progress-monitor.sh
# Purpose     : Fail deterministically for GUI diagnostic integration coverage.
# ==============================================================================

set -euo pipefail

printf '%s\n' 'Simulated progress monitor diagnostic.' >&2
exit 42
EOF_PROGRESS_MONITOR_FAILURE
    chmod 0755 -- "${monitor_bundle}/progress-monitor.sh"
    monitor_question_log="${TEST_ROOT}/progress-monitor-question.bin"
    monitor_text_info_log="${TEST_ROOT}/progress-monitor-text-info.bin"
    rm -f -- "${monitor_question_log}" "${monitor_text_info_log}"
    prepare_argument_log 'progress-monitor-failure'
    assert_status 1 'progress monitor failure exposes its diagnostic' \
        env MOCK_GUI_REAL="${monitor_bundle}/download-video-gui.sh" \
        MOCK_OUTPUT_DIR="${monitor_output}" \
        MOCK_QUESTION_ARGS_LOG="${monitor_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${monitor_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${monitor_question_log}" \
        'The progress monitor failed with status 42.' \
        'progress-monitor failure diagnostic'
    [[ ! -s ${monitor_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-monitor diagnostic log.'
    assert_no_test_processes 'progress-monitor failure left GUI descendants'
    previous_media_final_identity=$(stat -c '%d:%i:%s:%y:%z' -- "${previous_media}")
    previous_media_final_sha256=$(sha256sum -- "${previous_media}")
    assert_equals "${previous_media_identity}" \
        "${previous_media_final_identity}" \
        'progress errors preserve previous completed media identity'
    assert_equals "${previous_media_sha256}" \
        "${previous_media_final_sha256}" \
        'progress errors preserve previous completed media contents'
}

test_mock_runtime_missing_zenity() {
    local no_zenity_bin required_command required_command_path

    # Scenario: missing Zenity is a dependency error, not a graphical crash.
    no_zenity_bin="${TEST_ROOT}/no-zenity-bin"
    mkdir -p -- "${no_zenity_bin}"
    for required_command in \
        bash chmod date dirname grep mkdir mkfifo mktemp mv python3 realpath rm sed setsid sleep \
        stat tail timeout flock sha256sum; do
        required_command_path=$(command -v "${required_command}") \
            || fail "Required host command was not found: ${required_command}"
        ln -s -- "${required_command_path}" \
            "${no_zenity_bin}/${required_command}"
    done
    assert_status 127 'missing Zenity is reported before GUI startup' \
        env PATH="${no_zenity_bin}" HOME="${HOME_DIR}" \
        "${GUI_UNDER_TEST}"
    assert_text_contains "${ASSERT_OUTPUT}" 'required command "zenity" was not found' \
        'missing Zenity diagnostic'
}

run_mock_runtime_compat_group() {
    test_mock_managed_runtime_attestation
    test_mock_runtime_version_formats
    test_mock_runtime_version_overflow
    test_mock_runtime_dependencies
}

run_mock_runtime_validation_group() {
    test_mock_runtime_worker_failure
    test_mock_runtime_media_validation
    test_mock_runtime_progress_errors
    test_mock_runtime_missing_zenity
}

run_mock_runtime_group() {
    test_mock_managed_runtime_attestation
    test_mock_runtime_version_formats
    test_mock_runtime_worker_failure
    test_mock_runtime_version_overflow
    test_mock_runtime_media_validation
    test_mock_runtime_dependencies
    test_mock_runtime_progress_errors
    test_mock_runtime_missing_zenity
}

run_selected_mock_runtime_group() {
    case ${MOCK_GROUP} in
        all | runtime) run_mock_runtime_group ;;
        runtime-compat) run_mock_runtime_compat_group ;;
        runtime-validation) run_mock_runtime_validation_group ;;
        *) ;;
    esac
}
