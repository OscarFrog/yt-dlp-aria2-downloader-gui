#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/static/application-contracts.sh
# Purpose     : Validate engine, GUI and progress source contracts.
# ==============================================================================

# The caller supplies SCRIPT_DIR and the contains/not-contains/ordered-fragment
# assertions. Loading this library only defines the family; the public static
# entrypoint owns execution order, shell state and failure propagation.

test_static_application_contracts() {
    local mock_source
    local aria2_header_test_phase engine_phase gui_phase monitor_phase
    local ffmpeg_progress_test_phase ffmpeg_real_test_phase monitor_test_phase
    local hls_remux_test_phase private_plan_test_phase

    # shellcheck disable=SC2154 # The entrypoint sets readonly SCRIPT_DIR before sourcing this library.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'umask 077' \
        'engine restrictive umask'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'ARIA2_HTTPS_DIRECT_SAFE=false' \
        'affected aria2 GnuTLS HTTPS is forced to native transport'
    assert_file_contains "${SCRIPT_DIR}/private-aria2-plan.py" \
        'if url_scheme == "https" and not args.allow_https_direct:' \
        'private plan helper fails closed without HTTPS direct opt-in'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'the URL file must not be accessible by group or other users.' \
        'private URL-file permissions are enforced'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'Media validation reason: %s' \
        'final media failure exposes a bounded diagnostic reason'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'run_supervised_ytdlp() {' \
        'yt-dlp diagnostics pass through the closed privacy boundary'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        '[REDACTED_SOURCE]' \
        'retained GUI logs apply defense-in-depth source-label redaction'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'url_is_youtube() {' \
        'GUI uses a dedicated YouTube URL classifier'
    # shellcheck disable=SC2016 # Literal GUI-source assertions.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'url_host=${url_authority%%:*}' \
        'GUI YouTube classifier isolates the normalized host'
    # shellcheck disable=SC2016 # Literal GUI-source assertions.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'url_host=${url_host,,}' \
        'GUI YouTube classifier lowercases the host'
    # shellcheck disable=SC2016 # Literal GUI-source assertions.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'url_host=${url_host%.}' \
        'GUI YouTube classifier removes one DNS root dot'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'youtube.com | *.youtube.com | youtu.be | *.youtu.be' \
        'GUI YouTube classifier uses exact primary and short host suffixes'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'youtube-nocookie.com | *.youtube-nocookie.com)' \
        'GUI YouTube classifier uses the exact privacy host suffix'
    # shellcheck disable=SC2016 # Literal GUI-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'select_profile PROFILE "${is_youtube}"' \
        'GUI profile menu consumes the current URL classification'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--youtube-hls-firefox requires a YouTube URL.' \
        'engine keeps independent YouTube HLS URL validation'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'show_error_with_log() {' \
        'GUI centralizes errors with safe diagnostics'
    assert_file_fragments_ordered \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'simple GUI errors use a Close action' \
        'show_error() {' \
        "--ok-label='Close'" \
        '    return 0'
    # shellcheck disable=SC2016 # Literal GUI-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'python3 -I -S - "${expected_identity}"' \
        'retained-log identity comparison isolates Python startup'
    # shellcheck disable=SC2016 # Literal GUI-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'mv -Tn -- "${retained_file}" "${final_log_path}"' \
        'retained GUI logs use no-clobber atomic publication'
    assert_file_fragments_ordered \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'diagnostic dialogs require a sanitized retained log' \
        'show_error_with_log() {' \
        '    retain_sanitized_log' \
        'validated_retained_log_path retained_log' \
        '    show_diagnostic_dialog' \
        '    return 0'
    assert_file_fragments_ordered \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'all safe diagnostics use the shared View log and Close dialog' \
        'show_diagnostic_dialog() {' \
        'resolve_viewable_diagnostic' \
        "--ok-label='View log'" \
        "--cancel-label='Close'" \
        '            view_diagnostic_file'
    assert_file_fragments_ordered \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'Zenity technical failures expose a private bounded diagnostic' \
        'show_zenity_error() {' \
        'zenity-diagnostic.XXXXXXXX' \
        'show_diagnostic_dialog' \
        'temporary'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        "--cancel-label='Close'" \
        'GUI diagnostic dialogs provide a Close action'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        '--text-info' \
        'GUI opens sanitized diagnostics in a text viewer'
    assert_file_not_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'Log:' \
        'GUI never leaves a diagnostic path behind an OK-only error'
    assert_file_fragments_ordered \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'successful-download log viewing returns to the completion dialog' \
        'show_success_dialog() {' \
        '    while true; do' \
        "if [[ \${success_action} == 'View log' ]]" \
        '            view_retained_log' \
        '            continue' \
        '        break'
    assert_file_contains "${SCRIPT_DIR}/tests/lib/test-runner.sh" \
        'TEST_RUNNER_STARTING_CHILD=true' \
        'test runner marks the launch/registration critical section'
    # shellcheck disable=SC2016 # Literal library source.
    assert_file_contains "${SCRIPT_DIR}/tests/lib/test-runner.sh" \
        'TEST_RUNNER_DEFERRED_SIGNAL=${signal_name}' \
        'test runner preserves a signal delivered before registration'
    assert_file_contains "${SCRIPT_DIR}/tests/test-runner-integration.sh" \
        'for iteration in range(30):' \
        'test runner repeats startup-signal registration stress'
    assert_file_contains "${SCRIPT_DIR}/tests/test-runner-integration.sh" \
        'YTDLP_ARIA2_TEST_CHILD_TOKEN' \
        'test runner stress binds PID checks to fixture identity'
    for mock_source in "${SCRIPT_DIR}/tests/mock-integration.sh" \
        "${SCRIPT_DIR}"/tests/lib/mock-*.sh; do
        assert_file_not_contains "${mock_source}" \
            'timeout --preserve-status' \
            'GUI signal watchdog expiry remains distinguishable as status 124'
    done
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'readonly YTDLP_NO_PLUGINS=1' \
        'yt-dlp plugins disabled by default'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--no-overwrites' \
        'yt-dlp final-file overwrite protection'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--no-post-overwrites' \
        'yt-dlp post-processing overwrite protection'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '            setsid --wait env' \
        'CLI worker uses a no-fork session leader'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--ignore-signal=TERM' \
        'CLI registration leader ignores outer termination signals'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--default-signal=INT' \
        'CLI workers restore the inherited SIGINT disposition'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'wait_for_download_ready' \
        'CLI reused-session worker has a post-env readiness barrier'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'signal_download_worker "${signal_name}"' \
        'CLI signals relayed to worker group'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'python3 "${PRIVATE_ARIA2_HELPER}" private-root' \
        'engine uses the shared validated local private storage allocator'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '%(title).160B [%(id).64B].%(ext)s' \
        'byte-bounded output filename'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'run_supervised_command() {' \
        'generic long-running command supervisor'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'run_supervised_ytdlp "${YTDLP_BIN}"' \
        'yt-dlp uses its redacting supervisor'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'ARIA2_SUPPORTS_NO_NETRC=false' \
        'aria2 netrc support is detected as an optional capability'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then' \
        'aria2 receives no-netrc only when the build advertises it'
    for engine_phase in \
        check_ytdlp_runtime \
        check_deno_runtime \
        check_ytdlp_capabilities \
        check_aria2_runtime \
        check_aria2_capabilities \
        check_env_capabilities \
        check_setsid_capabilities \
        check_runtime_compatibility \
        parse_arguments \
        resolve_requested_url \
        validate_mode_selection \
        initialize_runtime_dependencies \
        prepare_output_directory \
        prepare_private_work_files \
        configure_download_options \
        plan_selected_transport \
        configure_download_reporting \
        execute_selected_transport \
        normalize_successful_path_record \
        validate_hls_duration_parity \
        publish_hls_remux_result \
        remux_hls_result \
        validate_and_publish_result \
        finalize_download; do
        assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
            "${engine_phase}() {" \
            "engine phase ${engine_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'validate_final_media_file() {' \
        'final media FFprobe validation'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'probe_media_summary() {' \
        'combined FFprobe media summary'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'stream_disposition=attached_pic' \
        'combined FFprobe summary distinguishes attached cover art'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'mv -nT -- "${HLS_REMUX_TMP}" "${final_path}"' \
        'HLS publication never treats the target as a directory'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'YTDLP_ARIA2_SUPERVISED_SESSION=true' \
        'GUI requests reuse of its single process session without a public option'
    # A worker must be protected before it is forked and remain protected until
    # its direct-child PID is registered. Reordering either boundary reopens a
    # signal window even if the individual calls remain present.
    # shellcheck disable=SC2016 # Ordered fragments are literal shell source.
    assert_file_fragments_ordered \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'GUI worker signal-registration boundaries' \
        'start_download_worker() {' \
        '    begin_signal_registration' \
        "        YTDLP_ARIA2_SUPERVISED_SESSION=true \\" \
        '        LC_ALL=C setsid --wait bash -c' \
        '    WORKER_PID=$!' \
        '        WORKER_PID_START_TIME=${worker_start_time}' \
        '    finish_signal_registration'
    for gui_phase in \
        initialize_gui_paths \
        initialize_gui_environment \
        collect_download_request \
        prepare_gui_session \
        start_download_worker \
        run_progress_dialog \
        resolve_confirmed_final_path \
        show_success_dialog \
        handle_worker_result; do
        assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
            "${gui_phase}() {" \
            "GUI phase ${gui_phase}"
    done
    for monitor_phase in \
        initialize_progress_inputs \
        initialize_progress_state \
        open_progress_log \
        drain_progress_log \
        monitor_worker_progress \
        report_progress_completion; do
        assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
            "${monitor_phase}() {" \
            "progress monitor phase ${monitor_phase}"
    done
    for monitor_test_phase in \
        test_monitor_reader_lifecycle \
        test_monitor_planning_progress \
        test_monitor_direct_transfer_progress \
        test_monitor_native_transfer_progress \
        test_monitor_composite_and_postprocess_progress \
        test_monitor_failure_and_input_hardening; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/progress-monitor-integration.sh" \
            "${monitor_test_phase}() {" \
            "progress monitor integration phase ${monitor_test_phase}"
    done
    for private_plan_test_phase in \
        test_private_plan_classification \
        test_private_plan_input_validation \
        test_private_plan_existing_destinations \
        test_private_plan_duplicate_staging_names \
        test_private_plan_publication_safety \
        test_private_plan_ownership \
        test_private_plan_protocol_metadata \
        test_private_plan_duplicate_headers \
        test_private_plan_rollback_safety; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/private-aria2-plan-integration.sh" \
            "${private_plan_test_phase}() {" \
            "private aria2 plan phase ${private_plan_test_phase}"
    done
    for aria2_header_test_phase in \
        prepare_aria2_header_servers \
        test_replay_safe_aria2_headers \
        test_unsafe_aria2_header_policy; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/aria2-auth-headers-integration.sh" \
            "${aria2_header_test_phase}() {" \
            "aria2 header integration phase ${aria2_header_test_phase}"
    done
    for ffmpeg_progress_test_phase in \
        test_measured_ffmpeg_progress \
        test_oversized_ffmpeg_counters; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/ffmpeg-progress-integration.sh" \
            "${ffmpeg_progress_test_phase}() {" \
            "simulated FFmpeg progress phase ${ffmpeg_progress_test_phase}"
    done
    for ffmpeg_real_test_phase in \
        create_real_ffmpeg_fixture \
        run_real_ffmpeg_worker \
        wait_for_worker_barrier \
        wait_for_prepublication_progress \
        assert_real_progress_history \
        test_real_ffmpeg_progress_run; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/ffmpeg-real-progress-integration.sh" \
            "${ffmpeg_real_test_phase}() {" \
            "real FFmpeg progress phase ${ffmpeg_real_test_phase}"
    done
    for hls_remux_test_phase in \
        prepare_hls_media_fixtures \
        prepare_hls_runtime_mocks \
        test_hls_remux_duration_cases; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/hls-remux-duration-integration.sh" \
            "${hls_remux_test_phase}() {" \
            "HLS remux duration phase ${hls_remux_test_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'PROFILE OUTPUT_DIR' \
        'progress monitor receives the canonical destination'
}
