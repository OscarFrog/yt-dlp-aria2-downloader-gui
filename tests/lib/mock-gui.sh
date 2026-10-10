#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-gui.sh
# Purpose     : Qualify GUI progress, profiles, configuration, and diagnostic state.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    TEST_ROOT PROGRESS_CAPTURE GUI_UNDER_TEST \
    XDG_STATE_HOME OUTPUT_DIR MOCK_ARG_LOG \
    MOCK_ARIA2_ARG_LOG PROJECT_DIR LIST_ARGS_LOG \
    YTDLP_PROGRESS_CAPTURE XDG_CONFIG_HOME RUNTIME_DIR \
    ASSERT_OUTPUT MOCK_GROUP

# Sourced by mock-integration.sh in the same Bash process. Helpers and tests
# share its PROJECT_DIR, private TEST_ROOT paths, command doubles and assertions;
# invocation remains under the entry point's options, traps and group dispatch.

test_mock_gui_aria_progress() {
    local aria_unknown_capture gui_aria2_arguments_text gui_url_seen_log
    local trimmed_gui_url status=0
    local -a gui_arguments gui_aria2_arguments

    # Scenario: aria2 GUI progress with an unknown total size.
    trimmed_gui_url='https://example.com/watch?v=trimmed'
    gui_url_seen_log="${TEST_ROOT}/gui-private-url-seen.txt"
    prepare_argument_log 'gui-aria-percent'
    MOCK_ZENITY_ENTRY_VALUE="  ${trimmed_gui_url}  " \
        MOCK_URL_SEEN_LOG="${gui_url_seen_log}" \
        MOCK_ARIA_ONLY=1 \
        MOCK_PROGRESS_CAPTURE="${PROGRESS_CAPTURE}" \
        "${GUI_UNDER_TEST}" || status=$?
    if ((status != 0)); then
        # Keep only allowlisted failure categories before the private fixture's
        # cleanup removes its logs. Never print raw media requests or headers.
        python3 -I -B - "${XDG_STATE_HOME}" "${OUTPUT_DIR}" "${status}" <<'PY_GUI_FAILURE' || true
import json
import os
from pathlib import Path
import stat
import sys
import time

categories = {
    'legacy-lock': b'another download is already using the destination directory',
    'family-lock': b'media resources are currently reserved by another download',
    'active-checkpoint': b'media resources remain reserved after an unconfirmed shutdown',
    'foreign-input': b'media destination already exists or contains an ambiguous input',
}
observed = set()
logs_read = 0
root = Path(sys.argv[1]) / 'yt-dlp-aria2-downloader'
for path in sorted(root.glob('download-*.log'))[-4:]:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        continue
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 8 * 1024 * 1024:
            continue
        data = os.read(descriptor, 8 * 1024 * 1024)
        observed.update(label for label, marker in categories.items() if marker in data)
        logs_read += 1
    finally:
        os.close(descriptor)
try:
    info = Path(sys.argv[2]).stat()
    destination = [info.st_dev, info.st_ino]
except OSError as error:
    destination = {'unavailable_errno': error.errno}
print(json.dumps({'event': 'gui-aria-percent-failure-before-fixture-cleanup',
                  'monotonic_ns': time.monotonic_ns(), 'status': int(sys.argv[3]),
                  'destination': destination, 'logs_read': logs_read,
                  'categories': sorted(observed)}, sort_keys=True), flush=True)
PY_GUI_FAILURE
        return "${status}"
    fi
    assert_file_has_line "${PROGRESS_CAPTURE}" '39' 'aria2 progress maps into the global download phase'
    assert_file_contains "${PROGRESS_CAPTURE}" \
        '# Downloading the audio track - 40% (aria2c) - 1.00MiB - 6s remaining' \
        'aria2 progress message'
    assert_file_contains "${PROGRESS_CAPTURE}" '# Extracting the native audio track...' \
        'post-processing message'
    assert_file_not_contains "${PROGRESS_CAPTURE}" '# Completed' \
        'premature completion message is absent'

    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    gui_arguments=()
    read_arguments "${MOCK_ARG_LOG}" gui_arguments
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    gui_aria2_arguments=()
    read_arguments "${MOCK_ARIA2_ARG_LOG}" gui_aria2_arguments

    assert_array_contains_prefix gui_aria2_arguments '--input-file=' \
        'GUI private aria2 input-file argument'
    assert_array_contains gui_aria2_arguments '--summary-interval=1' \
        'GUI aria2 summary interval'
    assert_array_contains gui_aria2_arguments '--show-console-readout=true' \
        'machine-progress aria2 readout remains visible on stdout'
    assert_array_contains gui_aria2_arguments '--max-concurrent-downloads=1' \
        'GUI direct aria2 keeps one observable transfer item active at a time'
    assert_array_contains gui_aria2_arguments '--stderr=false' \
        'GUI aria2 progress remains on stdout'

    gui_aria2_arguments_text=$(printf '%s\n' "${gui_aria2_arguments[@]}")
    assert_text_not_contains "${gui_aria2_arguments_text}" 'http://' \
        'GUI aria2 argv contains no HTTP URL'
    assert_text_not_contains "${gui_aria2_arguments_text}" 'https://' \
        'GUI aria2 argv contains no HTTPS URL'
    assert_array_not_contains gui_arguments "${trimmed_gui_url}" \
        'trimmed GUI URL is absent from process arguments'
    assert_file_has_line "${gui_url_seen_log}" "${trimmed_gui_url}" \
        'trimmed GUI URL is transferred through the private batch file'
    assert_array_not_contains gui_arguments "  ${trimmed_gui_url}  " \
        'untrimmed GUI URL is absent'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'gui-aria-unknown-size'
    aria_unknown_capture="${TEST_ROOT}/gui-progress-aria-unknown.txt"
    MOCK_ARIA_NO_PERCENT=1 \
        MOCK_PROGRESS_CAPTURE="${aria_unknown_capture}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${aria_unknown_capture}" \
        '# Downloading the audio track - size unknown (aria2c) - 1.00MiB' \
        'aria2 progress without a known total size'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_gui_profiles() {
    local profile_bundle="${TEST_ROOT}/profile-engine-bundle"
    local config_file profile_case removed_profile_label requested_url scenario
    local remembered_profile expected_profile youtube_expected
    local -a false_youtube_cases incompatible_default_arguments list_arguments
    local -a video_gui_arguments youtube_cases youtube_hls_default_arguments
    local -a youtube_hls_gui_arguments

    # Preserve the real GUI, private URL file and supervised worker handoff for
    # every host case. Only the engine entrypoint stops after real validation;
    # the adjacent E2E cases retain transport, publication and success coverage.
    mkdir -m 700 -- "${profile_bundle}"
    install -m 0755 -- "${PROJECT_DIR}/download-video-gui.sh" \
        "${profile_bundle}/download-video-gui.sh"
    install -m 0644 -- "${PROJECT_DIR}/progress-monitor.sh" \
        "${profile_bundle}/progress-monitor.sh"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${profile_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${profile_bundle}/private-process-supervisor.py"
    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${profile_bundle}/engine-source.sh"
    cat >"${profile_bundle}/download-video.sh" <<'EOF_PROFILE_ENGINE'
#!/usr/bin/env bash
set -euo pipefail

source "${MOCK_PROFILE_ENGINE_SOURCE:?}"
parse_arguments "$@"
resolve_requested_url
validate_mode_selection
printf '%s\0' "$@" >"${MOCK_PROFILE_ENGINE_ARGUMENTS:?}"
printf '%s\0' "${URL}" "${IS_YOUTUBE_URL}" "${MODE}" "${OUTPUT_DIR}" \
    "${MACHINE_PROGRESS}" "${YOUTUBE_HLS_FIREFOX}" "${URL_FILE}" \
    "${RESULT_FILE}" "${YTDLP_ARIA2_SUPERVISED_SESSION:-}" \
    "$(stat -c '%a' -- "${URL_FILE}")" "$(stat -c '%a' -- "${URL_FILE%/*}")" \
    >"${MOCK_PROFILE_ENGINE_ACKNOWLEDGEMENT:?}"
# A dedicated nonzero status proves the GUI reaped this deliberate pre-PLAN
# stop without inventing a successful media publication or invoking transport.
exit 73
EOF_PROFILE_ENGINE
    chmod 600 -- "${profile_bundle}/engine-source.sh"
    chmod 755 -- "${profile_bundle}/download-video.sh"
    youtube_cases=(
        'gui-profile-youtube-root|https://youtube.com/watch?v=profile-root'
        'gui-profile-youtube-watch|https://www.youtube.com/watch?v=yqS_lW770e8'
        'gui-profile-youtube-subdomain|https://media.youtube.com/watch?v=profile-subdomain'
        'gui-profile-youtu-be|https://youtu.be/yqS_lW770e8?si=Y-P-vV5geLxBUoCc'
        'gui-profile-youtu-be-subdomain|https://media.youtu.be/profile-short-subdomain'
        'gui-profile-nocookie|https://youtube-nocookie.com/embed/profile-nocookie'
        'gui-profile-nocookie-subdomain|https://media.youtube-nocookie.com/embed/profile-nocookie-subdomain'
        'gui-profile-normalized-host|https://WWW.YOUTUBE.COM.:443/watch?v=profile-normalized'
    )
    for profile_case in "${youtube_cases[@]}"; do
        IFS='|' read -r scenario requested_url <<<"${profile_case}"
        assert_gui_profile_menu "${scenario}" "${requested_url}" true \
            "recognized YouTube URL ${requested_url}" "${profile_bundle}"
    done

    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    list_arguments=()
    read_arguments "${LIST_ARGS_LOG}" list_arguments
    for removed_profile_label in 'Audio - MP3' 'Audio - M4A' 'Audio - Opus'; do
        assert_array_not_contains list_arguments "${removed_profile_label}" \
            "removed GUI profile ${removed_profile_label}"
    done

    false_youtube_cases=(
        'gui-profile-generic|https://example.com/video'
        'gui-profile-false-name|https://notyoutube.com/video'
        'gui-profile-false-prefix|https://youtube.example.com/video'
        'gui-profile-false-suffix|https://youtube.com.example.org/watch?v=test'
        'gui-profile-false-short-suffix|https://youtu.be.example.org/video'
        'gui-profile-false-nocookie-suffix|https://youtube-nocookie.com.example.org/video'
        'gui-profile-false-path|https://example.org/youtube.com/video'
    )
    for profile_case in "${false_youtube_cases[@]}"; do
        IFS='|' read -r scenario requested_url <<<"${profile_case}"
        assert_gui_profile_menu "${scenario}" "${requested_url}" false \
            "non-YouTube URL ${requested_url}" "${profile_bundle}"
    done

    for youtube_expected in true false; do
        requested_url='https://www.youtube.com/watch?v=yqS_lW770e8'
        [[ ${youtube_expected} == true ]] || requested_url='https://example.com/video'
        for remembered_profile in video youtube-hls audio invalid missing; do
            expected_profile=video
            [[ ${youtube_expected} == false ]] || expected_profile=youtube-hls
            [[ ${remembered_profile} != audio ]] || expected_profile=audio
            assert_gui_profile_menu \
                "gui-profile-default-${youtube_expected}-${remembered_profile}" \
                "${requested_url}" "${youtube_expected}" \
                "YouTube=${youtube_expected} remembered=${remembered_profile}" \
                "${profile_bundle}" "${remembered_profile}" "${expected_profile}"
        done
    done

    prepare_argument_log 'gui-ytdlp-progress'
    MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_PROGRESS_CAPTURE="${YTDLP_PROGRESS_CAPTURE}" \
        "${GUI_UNDER_TEST}"
    assert_file_has_line "${YTDLP_PROGRESS_CAPTURE}" '15' \
        'yt-dlp progress maps into the global download phase'
    assert_file_contains "${YTDLP_PROGRESS_CAPTURE}" \
        '# Downloading the audio track - 12% - 1.00MiB/s - 00:07 remaining' \
        'yt-dlp progress message'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'gui-video'
    MOCK_PROFILE='Complete video (MKV)' \
        "${GUI_UNDER_TEST}"
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    video_gui_arguments=()
    read_arguments "${MOCK_ARG_LOG}" video_gui_arguments
    assert_option_value video_gui_arguments '--format' 'bv*+ba/b' \
        'GUI video format selection'
    assert_array_not_contains video_gui_arguments 'ba/b' \
        'GUI video run does not use audio-only selector'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'gui-youtube-hls'
    MOCK_PROFILE='YouTube video - Firefox cookies (HLS/MKV)' \
        MOCK_ZENITY_ENTRY_VALUE='https://www.youtube.com/watch?v=gui-youtube-hls' \
        "${GUI_UNDER_TEST}"
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    youtube_hls_gui_arguments=()
    read_arguments "${MOCK_ARG_LOG}" youtube_hls_gui_arguments
    assert_option_value youtube_hls_gui_arguments '--cookies-from-browser' 'firefox' \
        'GUI YouTube HLS Firefox cookies'
    assert_option_value youtube_hls_gui_arguments '--extractor-args' \
        'youtube:player_client=web_safari' 'GUI YouTube HLS player client'
    assert_option_value youtube_hls_gui_arguments '--format' \
        '(bv*+ba/b)[protocol^=m3u8]' 'GUI YouTube HLS format selector'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mkv"
    config_file="${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"
    assert_file_has_line "${config_file}" 'profile=youtube-hls' \
        'saved GUI YouTube HLS profile'

    prepare_argument_log 'gui-youtube-hls-default'
    MOCK_USE_DEFAULT_PROFILE=1 \
        MOCK_ZENITY_ENTRY_VALUE='https://youtu.be/gui-youtube-hls-default' \
        "${GUI_UNDER_TEST}"
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    youtube_hls_default_arguments=()
    read_arguments "${MOCK_ARG_LOG}" youtube_hls_default_arguments
    assert_option_value youtube_hls_default_arguments '--cookies-from-browser' 'firefox' \
        'persisted GUI YouTube HLS profile'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mkv"

    prepare_argument_log 'gui-incompatible-youtube-hls-default'
    assert_status 0 'non-YouTube URL replaces an incompatible persisted profile' \
        env MOCK_USE_DEFAULT_PROFILE=1 \
        MOCK_ZENITY_ENTRY_VALUE='https://vimeo.com/123456789' \
        "${GUI_UNDER_TEST}"
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    list_arguments=()
    read_arguments "${LIST_ARGS_LOG}" list_arguments
    assert_array_not_contains list_arguments \
        'YouTube video - Firefox cookies (HLS/MKV)' \
        'non-YouTube menu excludes the persisted YouTube HLS profile'
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    incompatible_default_arguments=()
    read_arguments "${MOCK_ARG_LOG}" incompatible_default_arguments
    assert_option_value incompatible_default_arguments '--format' 'bv*+ba/b' \
        'incompatible persisted profile falls back to complete video'
    assert_array_not_contains incompatible_default_arguments \
        '--cookies-from-browser' \
        'incompatible persisted profile does not enable Firefox cookies'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_gui_progress_completion() {
    local completion_error_log_dir completion_error_question_log
    local completion_error_state completion_timeout_log_dir
    local completion_timeout_question_log completion_timeout_state
    local config_file current_log_count late_progress_capture
    local new_download_bundle new_download_config new_download_marker
    local new_download_state new_download_tmp progress_check_status
    local renamed_gui
    local -a completion_error_logs=() completion_timeout_logs=()
    local -a new_download_logs=()

    # Regression guard: post-processing progress must never regress.
    prepare_argument_log 'gui-late-progress'
    late_progress_capture="${TEST_ROOT}/gui-progress-late.txt"
    MOCK_LATE_PROGRESS=1 \
        MOCK_PROGRESS_CAPTURE="${late_progress_capture}" \
        "${GUI_UNDER_TEST}"
    progress_check_status=0
    awk '
        $0 == "99" { finalizing_seen = 1; next }
        finalizing_seen && $0 ~ /^[0-9]+$/ && ($0 + 0) < 99 {
            regression_seen = 1
        }
        END {
            if (!finalizing_seen) exit 2
            if (regression_seen) exit 1
            exit 0
        }
    ' "${late_progress_capture}" || progress_check_status=$?
    case ${progress_check_status} in
        0) ;;
        1) fail 'Progress regressed after post-processing started.' ;;
        2) fail 'Post-processing progress value 99 was never emitted.' ;;
        *) fail "Unexpected progress-check status: ${progress_check_status}" ;;
    esac

    config_file="${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"
    assert_file_has_line "${config_file}" "output_dir=${OUTPUT_DIR}" \
        'saved GUI output directory'
    assert_file_has_line "${config_file}" 'profile=audio' 'saved GUI audio profile'
    current_log_count=$(count_logs)
    assert_equals '0' "${current_log_count}" \
        'confirmed successful GUI downloads must not retain logs'
    assert_no_retained_log_staging \
        "${XDG_STATE_HOME}/yt-dlp-aria2-downloader" \
        'confirmed successful GUI download'

    # A timeout after successful publication must keep the live diagnostic
    # until it has been sanitized and offered through the shared View log UI.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    completion_timeout_state="${TEST_ROOT}/completion-timeout-state"
    completion_timeout_log_dir="${completion_timeout_state}/yt-dlp-aria2-downloader"
    completion_timeout_question_log="${TEST_ROOT}/completion-timeout-question.bin"
    rm -f -- "${completion_timeout_question_log}"
    prepare_argument_log 'gui-completion-timeout'
    assert_status 0 \
        'completion-dialog timeout preserves the successful download' \
        env XDG_STATE_HOME="${completion_timeout_state}" \
        MOCK_COMPLETION_QUESTION_STATUS=5 \
        MOCK_QUESTION_ARGS_LOG="${completion_timeout_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${completion_timeout_question_log}" \
        'The completion dialog timed out.' \
        'completion-timeout retained diagnostic'
    shopt -s nullglob
    completion_timeout_logs=("${completion_timeout_log_dir}"/download-*.log)
    shopt -u nullglob
    assert_equals '1' "${#completion_timeout_logs[@]}" \
        'completion timeout retains one sanitized log'
    assert_path_mode "${completion_timeout_logs[0]}" 600 \
        'completion-timeout retained-log mode'
    assert_retained_log_identity_footer "${completion_timeout_logs[0]}" \
        'completion-timeout retained diagnostic'
    assert_no_retained_log_staging "${completion_timeout_log_dir}" \
        'completion-timeout retained diagnostic'

    # A technical failure of the completion dialog exposes its bounded Zenity
    # diagnostic and still retains the completed session log during EXIT cleanup.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    completion_error_state="${TEST_ROOT}/completion-error-state"
    completion_error_log_dir="${completion_error_state}/yt-dlp-aria2-downloader"
    completion_error_question_log="${TEST_ROOT}/completion-error-question.bin"
    rm -f -- "${completion_error_question_log}"
    prepare_argument_log 'gui-completion-error'
    assert_status 0 \
        'completion-dialog error preserves the successful download' \
        env XDG_STATE_HOME="${completion_error_state}" \
        MOCK_COMPLETION_QUESTION_STATUS=42 \
        MOCK_COMPLETION_QUESTION_ERROR='Simulated completion dialog failure.' \
        MOCK_QUESTION_ARGS_LOG="${completion_error_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${completion_error_question_log}" \
        'Zenity could not display the completion dialog.' \
        'completion-dialog technical diagnostic'
    shopt -s nullglob
    completion_error_logs=("${completion_error_log_dir}"/download-*.log)
    shopt -u nullglob
    assert_equals '1' "${#completion_error_logs[@]}" \
        'completion error retains one sanitized session log'
    assert_path_mode "${completion_error_logs[0]}" 600 \
        'completion-error retained-log mode'
    assert_retained_log_identity_footer "${completion_error_logs[0]}" \
        'completion-error retained diagnostic'
    assert_no_retained_log_staging "${completion_error_log_dir}" \
        'completion-error retained diagnostic'

    # New download re-execs the resolved source path. Exercise a deliberately
    # renamed installation and cancel the second lifecycle at its URL dialog.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    new_download_bundle="${TEST_ROOT}/renamed-gui-bundle"
    new_download_config="${TEST_ROOT}/renamed-gui-config"
    new_download_marker="${TEST_ROOT}/renamed-gui-second-cycle"
    new_download_state="${TEST_ROOT}/renamed-gui-state"
    new_download_tmp="${TEST_ROOT}/renamed-gui-tmp"
    renamed_gui="${new_download_bundle}/renamed-downloader-gui"
    mkdir -p -- \
        "${new_download_bundle}" \
        "${new_download_config}" \
        "${new_download_state}" \
        "${new_download_tmp}"
    install -m 0755 -- \
        "${PROJECT_DIR}/download-video-gui.sh" "${renamed_gui}"
    install -m 0755 -- \
        "${PROJECT_DIR}/download-video.sh" \
        "${PROJECT_DIR}/progress-monitor.sh" \
        "${new_download_bundle}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${new_download_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${new_download_bundle}/private-process-supervisor.py"
    prepare_argument_log 'gui-renamed-new-download'
    assert_status 0 'New download re-execs the resolved renamed GUI path' \
        env MOCK_GUI_REAL="${renamed_gui}" \
        XDG_CONFIG_HOME="${new_download_config}" \
        XDG_STATE_HOME="${new_download_state}" \
        TMPDIR="${new_download_tmp}" \
        MOCK_NEW_DOWNLOAD_ONCE_MARKER="${new_download_marker}" \
        MOCK_CANCEL_ENTRY_AFTER_NEW_DOWNLOAD=1 \
        "${GUI_UNDER_TEST}"
    [[ -f ${new_download_marker} ]] \
        || fail 'The renamed GUI never entered its second download lifecycle.'
    assert_directory_empty "${new_download_tmp}" \
        'renamed New download cleanup left temporary state'
    shopt -s nullglob
    new_download_logs=(
        "${new_download_state}/yt-dlp-aria2-downloader"/download-*.log
    )
    shopt -u nullglob
    assert_equals '0' "${#new_download_logs[@]}" \
        'renamed New download retains no successful-session log'
    assert_no_test_processes 'renamed New download left GUI descendants'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_gui_config_recovery() {
    local config_file config_line_count config_padding_bytes config_prefix_bytes
    local config_profile_suffix=$'\nprofile=audio\n'
    local config_size line_number relative_config_dir relative_state_dir
    local special_file_timeout_seconds=10

    # Scenario group: legacy and malformed configuration recovery.
    config_file="${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"
    mkdir -p -- "${config_file%/*}"
    cat >"${config_file}" <<EOF_OLD_CONFIG
output_dir=${OUTPUT_DIR}
profile=audio-mp3
EOF_OLD_CONFIG
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'legacy-profile'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=audio' 'legacy profile migration'

    cat >"${config_file}" <<'EOF_BAD_CONFIG'
malformed line
unknown=value
profile=invalid
EOF_BAD_CONFIG
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'malformed-config'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=video' \
        'malformed configuration falls back to video'

    printf 'output_dir=%s\nprofile=audio' "${OUTPUT_DIR}" >"${config_file}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'config-without-final-newline'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=audio' \
        'configuration final line without newline is loaded'

    printf 'output_dir=%s\r\nprofile=audio\r\n' \
        "${OUTPUT_DIR}" >"${config_file}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'config-crlf'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=audio' \
        'CRLF configuration values are normalized when loaded'

    rm -f -- "${config_file}" "${OUTPUT_DIR}/Mock media [abc123].webm"
    mkfifo -- "${config_file}"
    prepare_argument_log 'config-fifo-fallback'
    # Keep the read non-blocking contract bounded while leaving enough startup
    # headroom for the four-way full-suite and CI stress profiles.
    assert_status 0 'configuration FIFO is ignored without blocking the GUI' \
        env MOCK_GUI_SCENARIO_TIMEOUT_SECONDS="${special_file_timeout_seconds}" \
        MOCK_USE_DEFAULT_PROFILE=1 \
        "${GUI_UNDER_TEST}"
    [[ -f ${config_file} && ! -L ${config_file} ]] \
        || fail 'The saved GUI configuration did not replace the FIFO safely.'
    assert_file_has_line "${config_file}" 'profile=video' \
        'configuration FIFO falls back to the default profile'

    rm -f -- "${config_file}" "${OUTPUT_DIR}/Mock media [abc123].webm"
    ln -s -- /dev/zero "${config_file}"
    prepare_argument_log 'config-device-symlink-fallback'
    assert_status 0 'configuration device symlink is ignored without blocking the GUI' \
        env MOCK_GUI_SCENARIO_TIMEOUT_SECONDS="${special_file_timeout_seconds}" \
        MOCK_USE_DEFAULT_PROFILE=1 \
        "${GUI_UNDER_TEST}"
    [[ -f ${config_file} && ! -L ${config_file} ]] \
        || fail 'The saved GUI configuration did not replace the device symlink safely.'
    assert_file_has_line "${config_file}" 'profile=video' \
        'configuration device symlink falls back to the default profile'

    printf 'output_dir=%s\npadding=' "${OUTPUT_DIR}" >"${config_file}"
    config_prefix_bytes=$(stat -c '%s' -- "${config_file}")
    config_padding_bytes=$((65536 - config_prefix_bytes - \
        ${#config_profile_suffix}))
    # shellcheck disable=SC2312 # The mock entry point enables pipefail for the complete fixture write.
    head -c "${config_padding_bytes}" -- /dev/zero | tr '\0' X \
        >>"${config_file}"
    printf '%s' "${config_profile_suffix}" >>"${config_file}"
    config_size=$(stat -c '%s' -- "${config_file}")
    assert_equals '65536' "${config_size}" \
        'configuration byte-limit fixture size'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'config-byte-limit'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=audio' \
        'configuration at the byte limit is loaded'

    printf 'output_dir=%s\nprofile=audio\npadding=' \
        "${OUTPUT_DIR}" >"${config_file}"
    config_prefix_bytes=$(stat -c '%s' -- "${config_file}")
    config_padding_bytes=$((65537 - config_prefix_bytes))
    # shellcheck disable=SC2312 # The mock entry point enables pipefail for the complete fixture write.
    head -c "${config_padding_bytes}" -- /dev/zero | tr '\0' X \
        >>"${config_file}"
    config_size=$(stat -c '%s' -- "${config_file}")
    assert_equals '65537' "${config_size}" \
        'oversized configuration fixture size'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'config-oversized-fallback'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=video' \
        'oversized configuration falls back atomically'

    {
        printf 'output_dir=%s\n' "${OUTPUT_DIR}"
        for ((line_number = 1; line_number <= 126; line_number++)); do
            printf 'future_%03d=value\n' "${line_number}"
        done
        printf 'profile=audio\n'
    } >"${config_file}"
    config_line_count=$(wc -l <"${config_file}")
    assert_equals '128' "${config_line_count}" \
        'configuration line-limit fixture count'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'config-line-limit'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=audio' \
        'configuration at the line limit is loaded'

    {
        printf 'output_dir=%s\nprofile=audio\n' "${OUTPUT_DIR}"
        for ((line_number = 1; line_number <= 127; line_number++)); do
            printf 'future_%03d=value\n' "${line_number}"
        done
    } >"${config_file}"
    config_line_count=$(wc -l <"${config_file}")
    assert_equals '129' "${config_line_count}" \
        'overlong configuration fixture count'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'config-overlong-fallback'
    MOCK_USE_DEFAULT_PROFILE=1 "${GUI_UNDER_TEST}"
    assert_file_has_line "${config_file}" 'profile=video' \
        'overlong configuration falls back atomically'

    # Relative XDG configuration/state paths are invalid and must fall back to HOME.
    relative_config_dir="${PROJECT_DIR}/relative-config-home"
    relative_state_dir="${PROJECT_DIR}/relative-state-home"
    rm -rf -- "${relative_config_dir}" "${relative_state_dir}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'relative-xdg-home-fallback'
    env XDG_CONFIG_HOME='relative-config-home' \
        XDG_STATE_HOME='relative-state-home' \
        MOCK_USE_DEFAULT_PROFILE=1 \
        "${GUI_UNDER_TEST}"
    [[ ! -e ${relative_config_dir} && ! -e ${relative_state_dir} ]] \
        || fail 'The GUI used a relative XDG configuration or state path.'
    assert_file_has_line \
        "${HOME}/.config/yt-dlp-aria2-downloader/gui.conf" \
        "output_dir=${OUTPUT_DIR}" \
        'relative XDG homes fall back to HOME'
}

test_mock_gui_file_selection() {
    local argument file_selection_args_log file_selection_calls
    local filename_attempts oversized_capture oversized_diagnostic
    local missing_home missing_home_args_log missing_home_config
    local oversized_question_log oversized_size oversized_text_info_log
    local -a file_selection_arguments missing_home_arguments
    local -a oversized_text_info_arguments

    # Scenario: file chooser fallback after a GTK/Zenity initial-directory failure.
    file_selection_args_log="${TEST_ROOT}/file-selection-args.bin"
    : >"${file_selection_args_log}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'file-selection-fallback'
    MOCK_ZENITY_FILE_STATUS_WITH_FILENAME=255 \
        MOCK_ZENITY_FILE_ERROR='simulated initial-folder failure' \
        MOCK_FILE_SELECTION_ARGS_LOG="${file_selection_args_log}" \
        "${GUI_UNDER_TEST}" >/dev/null
    file_selection_arguments=()
    read_arguments "${file_selection_args_log}" file_selection_arguments
    file_selection_calls=0
    filename_attempts=0
    for argument in "${file_selection_arguments[@]}"; do
        if [[ ${argument} == --file-selection ]]; then
            ((file_selection_calls += 1))
        elif [[ ${argument} == --filename=* ]]; then
            ((filename_attempts += 1))
        fi
        case ${argument} in
            --ok-label=* | --cancel-label=*)
                fail "Unsupported custom button label leaked into file chooser: ${argument}"
                ;;
            *) ;;
        esac
    done
    assert_equals '2' "${file_selection_calls}" 'file chooser fallback call count'
    assert_equals '1' "${filename_attempts}" 'preselected file chooser attempt count'

    # If HOME itself does not exist and no configured download directory is
    # usable, the chooser must receive an existing absolute fallback.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    missing_home="${TEST_ROOT}/missing-default-output-home"
    missing_home_args_log="${TEST_ROOT}/missing-home-file-selection.bin"
    missing_home_config="${TEST_ROOT}/missing-home-config"
    [[ ! -e ${missing_home} ]] \
        || fail 'The missing-HOME output fallback fixture already exists.'
    : >"${missing_home_args_log}"
    prepare_argument_log 'missing-home-default-output-directory'
    assert_status 0 'nonexistent HOME uses an existing chooser fallback' \
        env HOME="${missing_home}" \
        XDG_CONFIG_HOME="${missing_home_config}" \
        MOCK_FILE_SELECTION_ARGS_LOG="${missing_home_args_log}" \
        "${GUI_UNDER_TEST}"
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    missing_home_arguments=()
    read_arguments "${missing_home_args_log}" missing_home_arguments
    assert_array_contains missing_home_arguments '--filename=/' \
        'nonexistent HOME file-chooser fallback'

    # Two bounded Zenity stderr captures can exceed the single diagnostic
    # limit when the chooser fallback also fails. Redact before retaining only
    # the final 64 KiB so an URL suffix cannot escape sanitization.
    oversized_question_log="${TEST_ROOT}/file-selection-oversized-question.bin"
    oversized_text_info_log="${TEST_ROOT}/file-selection-oversized-text-info.bin"
    oversized_capture="${TEST_ROOT}/file-selection-oversized-diagnostic.txt"
    rm -f -- "${oversized_question_log}" \
        "${oversized_text_info_log}" "${oversized_capture}"
    prepare_argument_log 'file-selection-oversized-diagnostic'
    assert_status 1 'two large file-chooser errors expose a bounded diagnostic' \
        env MOCK_ZENITY_FILE_STATUS_WITH_FILENAME=42 \
        MOCK_ZENITY_FILE_STATUS=42 \
        MOCK_ZENITY_FILE_ERROR_BYTES=40000 \
        MOCK_QUESTION_STATUS=0 \
        MOCK_QUESTION_ARGS_LOG="${oversized_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${oversized_text_info_log}" \
        MOCK_TEXT_INFO_CONTENT_CAPTURE="${oversized_capture}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${oversized_question_log}" \
        'Zenity could not display the folder selection dialog.' \
        'oversized file-chooser diagnostic'
    oversized_text_info_arguments=()
    read_arguments \
        "${oversized_text_info_log}" oversized_text_info_arguments
    oversized_diagnostic=''
    for argument in "${oversized_text_info_arguments[@]}"; do
        case ${argument} in
            --filename=*) oversized_diagnostic=${argument#--filename=} ;;
            *) ;;
        esac
    done
    [[ -n ${oversized_diagnostic} && ! -e ${oversized_diagnostic} ]] \
        || fail 'The oversized private Zenity diagnostic was not removed.'
    oversized_size=$(stat -c '%s' -- "${oversized_capture}") \
        || fail 'Unable to inspect the bounded Zenity diagnostic.'
    ((oversized_size > 0 && oversized_size <= 65536)) \
        || fail "Zenity diagnostic exceeded its bound: ${oversized_size}"
    assert_file_contains "${oversized_capture}" '[REDACTED_URL]' \
        'oversized file-chooser diagnostic redacts URL-like values'
    assert_file_not_contains "${oversized_capture}" 'secret.example' \
        'oversized file-chooser diagnostic hides the raw URL'
}

test_mock_gui_prune_metadata() {
    local scenario
    for scenario in old recent wide-mode symlink foreign-owner stat-failed invalid-time \
        inode-replaced mode-changed refreshed state-replaced ancestor-writable rm-failed; do
        assert_status 0 "GUI pruning preserves its metadata contract: ${scenario}" \
            bash -s -- "${PROJECT_DIR}/download-video-gui.sh" \
            "${TEST_ROOT}/gui-prune-${scenario}" "${scenario}" <<'EOF_PRUNE_METADATA'
set -euo pipefail
umask 077
source <(sed '/^main "\$@"$/d' "$1")
prune_root=$2
prune_case=$3
STATE_DIR="${prune_root}/state"
mkdir -p -- "${STATE_DIR}"
prune_leaf="${STATE_DIR}/download-fixture.log"
printf 'original log\n' >"${prune_leaf}"
touch -d '16 days ago' -- "${prune_leaf}"
case ${prune_case} in
    recent) touch -- "${prune_leaf}" ;;
    wide-mode) chmod 644 -- "${prune_leaf}" ;;
    symlink)
        mv -- "${prune_leaf}" "${prune_root}/original"
        ln -s -- "${prune_root}/original" "${prune_leaf}"
        ;;
esac
stat() {
    if [[ ${!#} != "${prune_leaf}" || -e ${prune_root}/observed ]]; then
        command stat "$@"
        return
    fi
    : >"${prune_root}/observed"
    case ${prune_case} in
        stat-failed) return 1 ;;
        foreign-owner)
            command stat -c "%d:%i:$((EUID + 1)):%a:%Y" -- "${prune_leaf}"
            return
            ;;
        invalid-time)
            command stat -c '%d:%i:%u:%a:99999999999999999999' -- "${prune_leaf}"
            return
            ;;
    esac
    command stat "$@"
    case ${prune_case} in
        inode-replaced)
            mv -- "${prune_leaf}" "${prune_root}/original"
            printf 'replacement log\n' >"${prune_leaf}"
            touch -d '16 days ago' -- "${prune_leaf}"
            ;;
        mode-changed) chmod 644 -- "${prune_leaf}" ;;
        refreshed) touch -- "${prune_leaf}" ;;
        state-replaced)
            mv -- "${STATE_DIR}" "${prune_root}/original-state"
            mkdir -- "${STATE_DIR}"
            printf 'replacement log\n' >"${prune_leaf}"
            ;;
        ancestor-writable) chmod 777 -- "${prune_root}" ;;
    esac
}
rm() {
    if [[ ${prune_case} == rm-failed && ${!#} == "${prune_leaf}" ]]; then
        return 1
    fi
    command rm "$@"
}
prune_old_logs
case ${prune_case} in
    old) [[ ! -e ${prune_leaf} ]] ;;
    symlink) [[ -L ${prune_leaf} && $(<"${prune_root}/original") == 'original log' ]] ;;
    inode-replaced | state-replaced) [[ $(<"${prune_leaf}") == 'replacement log' ]] ;;
    *) [[ -f ${prune_leaf} && $(<"${prune_leaf}") == 'original log' ]] ;;
esac
chmod 700 -- "${prune_root}"
EOF_PRUNE_METADATA
    done
}

test_mock_gui_diagnostic_logs() {
    local boundary_log_found boundary_question_log boundary_text_info_log
    local failure_question_log failure_record_found final_probe_question_log
    local final_result_bundle final_result_question_log final_result_text_info_log
    local inconsistent_question_log inconsistent_text_info_log log_dir log_mode
    local log_record_found log_size logs_after logs_before outside_question_log
    local outside_result_path retained_log runtime_question_log
    local sanitization_error_capture sanitization_question_log
    local sanitization_text_info_log single_line_bundle
    local single_line_error_capture
    local single_line_question_log single_line_text_info_log viewed_log
    local bounded_whitespace_error_capture bounded_whitespace_question_log
    local bounded_whitespace_text_info_log whitespace_error_capture
    local whitespace_question_log whitespace_text_info_log
    local -a failed_logs inconsistent_logs viewed_log_arguments

    # Scenario group: diagnostic log retention and cleanup.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    logs_before=$(count_logs)
    prepare_argument_log 'inconsistent-result'
    inconsistent_question_log="${TEST_ROOT}/inconsistent-result-question.bin"
    inconsistent_text_info_log="${TEST_ROOT}/inconsistent-result-text-info.bin"
    rm -f -- "${inconsistent_question_log}" "${inconsistent_text_info_log}"
    assert_status 1 'missing final path is reported as a failed GUI run' \
        env MOCK_SKIP_RESULT_FILE=1 \
        MOCK_QUESTION_ARGS_LOG="${inconsistent_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${inconsistent_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${inconsistent_question_log}" \
        'The download failed with status 1.' \
        'engine-missing-final-path diagnostic'
    [[ ! -s ${inconsistent_text_info_log} ]] \
        || fail 'Close unexpectedly opened the missing-final-path diagnostic log.'
    logs_after=$(count_logs)
    assert_equals "$((logs_before + 1))" "${logs_after}" \
        'an inconsistent run retains one new log'
    log_dir="${XDG_STATE_HOME}/yt-dlp-aria2-downloader"
    shopt -s nullglob
    inconsistent_logs=("${log_dir}"/download-*.log)
    shopt -u nullglob
    log_record_found=false
    for retained_log in "${inconsistent_logs[@]}"; do
        if grep -Fq -- 'YTDLP_POSTPROCESS|processing|' "${retained_log}"; then
            log_record_found=true
            break
        fi
    done
    [[ ${log_record_found} == true ]] \
        || fail 'No retained inconsistent-run log contains the post-processing record.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    outside_result_path="${TEST_ROOT}/outside-result.webm"
    logs_before=$(count_logs)
    prepare_argument_log 'result-outside-output-dir'
    outside_question_log="${TEST_ROOT}/outside-result-question.bin"
    rm -f -- "${outside_question_log}"
    assert_status 1 'GUI rejects a result outside the selected destination folder' \
        env MOCK_RESULT_OUTSIDE_OUTPUT=1 \
        MOCK_OUTSIDE_RESULT_PATH="${outside_result_path}" \
        MOCK_QUESTION_ARGS_LOG="${outside_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${outside_question_log}" \
        'The download failed with status 1.' \
        'engine-outside-final-path diagnostic'
    logs_after=$(count_logs)
    assert_equals "$((logs_before + 1))" "${logs_after}" \
        'an outside-directory result retains one diagnostic log'
    [[ -f ${outside_result_path} ]] \
        || fail 'The outside-directory mock result was not created.'
    rm -f -- "${outside_result_path}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    logs_before=$(count_logs)
    prepare_argument_log 'failed-download'
    failure_question_log="${TEST_ROOT}/failed-download-question.bin"
    rm -f -- "${failure_question_log}"
    assert_status 7 'failed GUI download status is propagated' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_YTDLP_EXIT_STATUS=7 \
        MOCK_QUESTION_ARGS_LOG="${failure_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${failure_question_log}" \
        'The download failed with status 7.' \
        'downloader-failure diagnostic'
    logs_after=$(count_logs)
    assert_equals "$((logs_before + 1))" "${logs_after}" \
        'a failed download retains one new log'
    shopt -s nullglob
    failed_logs=("${log_dir}"/download-*.log)
    shopt -u nullglob
    failure_record_found=false
    for retained_log in "${failed_logs[@]}"; do
        if grep -Fq -- 'Simulated yt-dlp failure.' "${retained_log}"; then
            failure_record_found=true
            break
        fi
    done
    [[ ${failure_record_found} == true ]] \
        || fail 'No retained log contains the simulated failure.'
    assert_retained_log_identity_footer "${retained_log}" \
        'ordinary retained diagnostic'
    assert_no_retained_log_staging "${log_dir}" \
        'ordinary failed GUI download'

    logs_before=$(count_logs)
    prepare_argument_log 'retained-log-boundary-redaction'
    boundary_question_log="${TEST_ROOT}/boundary-question.bin"
    boundary_text_info_log="${TEST_ROOT}/boundary-text-info.bin"
    rm -f -- "${boundary_question_log}" "${boundary_text_info_log}"
    assert_status 7 'boundary-crossing failed GUI download status is propagated' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_BOUNDARY_LOG=1 \
        MOCK_YTDLP_EXIT_STATUS=7 \
        MOCK_QUESTION_ARGS_LOG="${boundary_question_log}" \
        MOCK_QUESTION_STATUS=0 \
        MOCK_TEXT_INFO_ARGS_LOG="${boundary_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${boundary_question_log}" \
        'The download failed with status 7.' \
        'boundary-redaction diagnostic'
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    viewed_log_arguments=()
    read_arguments "${boundary_text_info_log}" viewed_log_arguments
    assert_array_contains viewed_log_arguments '--text-info' \
        'View log opens the Zenity text viewer'
    assert_array_contains viewed_log_arguments '--ok-label=Close' \
        'diagnostic viewer Close action'
    viewed_log=''
    for retained_log in "${viewed_log_arguments[@]}"; do
        case ${retained_log} in
            --filename=*) viewed_log=${retained_log#--filename=} ;;
            *) ;;
        esac
    done
    [[ -n ${viewed_log} ]] \
        || fail 'The diagnostic viewer did not receive a retained-log filename.'
    [[ ${viewed_log} == "${log_dir}"/download-*.log ]] \
        || fail "The diagnostic viewer escaped the private state directory: ${viewed_log}"
    [[ -f ${viewed_log} && ! -L ${viewed_log} ]] \
        || fail "The diagnostic viewer did not receive a regular retained log: ${viewed_log}"
    assert_path_mode "${viewed_log}" 600 \
        'diagnostic viewer retained-log mode'
    assert_file_contains "${viewed_log}" 'FINAL_MARKER' \
        'diagnostic viewer opens the current failure log'
    assert_file_contains "${viewed_log}" '[REDACTED_URL]' \
        'diagnostic viewer opens a sanitized log'
    assert_file_not_contains "${viewed_log}" 'COMPLETE_SECRET' \
        'diagnostic viewer never opens the raw failure log'
    assert_retained_log_identity_footer "${viewed_log}" \
        'truncated retained diagnostic'
    logs_after=$(count_logs)
    assert_equals "$((logs_before + 1))" "${logs_after}" \
        'a boundary-crossing failure retains one new log'
    shopt -s nullglob
    failed_logs=("${log_dir}"/download-*.log)
    shopt -u nullglob
    boundary_log_found=false
    for retained_log in "${failed_logs[@]}"; do
        if ! grep -Fq -- 'FINAL_MARKER' "${retained_log}"; then
            continue
        fi
        boundary_log_found=true
        assert_file_not_contains "${retained_log}" 'BOUNDARY_SECRET' \
            'partial URL at the retained boundary is discarded'
        assert_file_not_contains "${retained_log}" 'COMPLETE_SECRET' \
            'complete URL in retained diagnostics is redacted'
        assert_file_contains "${retained_log}" '[REDACTED_URL]' \
            'retained boundary fixture contains a URL redaction marker'
        log_size=$(stat -c '%s' -- "${retained_log}")
        ((log_size <= 8388608)) \
            || fail "Retained log exceeds 8 MiB: ${log_size} bytes."
        log_mode=$(stat -c '%a' -- "${retained_log}")
        assert_equals '600' "${log_mode}" 'retained boundary log mode'
    done
    [[ ${boundary_log_found} == true ]] \
        || fail 'No retained boundary-redaction log contains the final marker.'

    single_line_bundle="${TEST_ROOT}/single-line-diagnostic-bundle"
    mkdir -p -- "${single_line_bundle}"
    install -m 0755 -- "${PROJECT_DIR}/download-video-gui.sh" \
        "${PROJECT_DIR}/progress-monitor.sh" "${single_line_bundle}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${single_line_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${single_line_bundle}/private-process-supervisor.py"
    cat >"${single_line_bundle}/download-video.sh" <<'EOF_SINGLE_LINE_ENGINE'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : download-video.sh
# Purpose     : Emit one oversized line for GUI log-retention coverage.
# ==============================================================================

set -euo pipefail

if (($# == 1)) && [[ $1 == --version ]]; then
    printf '%s\n' 'yt-dlp-aria2-downloader-gui 9.9.9'
    exit 0
fi
sleep 0.2
if [[ ${MOCK_WHITESPACE_DIAGNOSTIC:-0} == 1 ]]; then
    printf '  \n\t\n'
    exit 7
fi
if [[ ${MOCK_BOUNDED_WHITESPACE_DIAGNOSTIC:-0} == 1 ]]; then
    printf 'X'
    head -c "$((8388608 - 1))" -- /dev/zero | tr '\0' ' '
    exit 7
fi
head -c "$((8388608 + 16384))" -- /dev/zero | tr '\0' Z
printf '%s' 'OVERSIZED_SINGLE_LINE_END'
exit 7
EOF_SINGLE_LINE_ENGINE
    chmod 0755 -- "${single_line_bundle}/download-video.sh"
    cat >"${single_line_bundle}/progress-monitor.sh" <<'EOF_SINGLE_LINE_MONITOR'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : progress-monitor.sh
# Purpose     : Keep retention coverage independent of progress parsing.
# ==============================================================================

set -euo pipefail

sleep 0.2
exit 0
EOF_SINGLE_LINE_MONITOR
    chmod 0755 -- "${single_line_bundle}/progress-monitor.sh"
    logs_before=$(count_logs)
    prepare_argument_log 'retained-log-oversized-single-line'
    single_line_error_capture="${TEST_ROOT}/single-line-error.txt"
    single_line_question_log="${TEST_ROOT}/single-line-question.bin"
    single_line_text_info_log="${TEST_ROOT}/single-line-text-info.bin"
    rm -f -- "${single_line_error_capture}" \
        "${single_line_question_log}" "${single_line_text_info_log}"
    assert_status 7 'oversized single-line diagnostic is not retained' \
        env MOCK_GUI_REAL="${single_line_bundle}/download-video-gui.sh" \
        MOCK_ERROR_CAPTURE="${single_line_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${single_line_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${single_line_text_info_log}" \
        "${GUI_UNDER_TEST}"
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'oversized single-line diagnostic publishes no footer-only log'
    assert_file_contains "${single_line_error_capture}" \
        'A safe diagnostic log could not be prepared.' \
        'oversized single-line safe fallback'
    [[ ! -s ${single_line_question_log} ]] \
        || fail 'Oversized single-line diagnostic incorrectly offered View log.'
    [[ ! -s ${single_line_text_info_log} ]] \
        || fail 'Oversized single-line diagnostic opened a log viewer.'
    assert_no_retained_log_staging "${log_dir}" \
        'oversized single-line diagnostic'

    logs_before=$(count_logs)
    prepare_argument_log 'retained-log-whitespace-only'
    whitespace_error_capture="${TEST_ROOT}/whitespace-error.txt"
    whitespace_question_log="${TEST_ROOT}/whitespace-question.bin"
    whitespace_text_info_log="${TEST_ROOT}/whitespace-text-info.bin"
    rm -f -- "${whitespace_error_capture}" \
        "${whitespace_question_log}" "${whitespace_text_info_log}"
    assert_status 7 'whitespace-only diagnostic is not retained' \
        env MOCK_GUI_REAL="${single_line_bundle}/download-video-gui.sh" \
        MOCK_WHITESPACE_DIAGNOSTIC=1 \
        MOCK_ERROR_CAPTURE="${whitespace_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${whitespace_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${whitespace_text_info_log}" \
        "${GUI_UNDER_TEST}"
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'whitespace-only diagnostic publishes no footer-only log'
    assert_file_contains "${whitespace_error_capture}" \
        'A safe diagnostic log could not be prepared.' \
        'whitespace-only diagnostic safe fallback'
    [[ ! -s ${whitespace_question_log} && ! -s ${whitespace_text_info_log} ]] \
        || fail 'Whitespace-only diagnostic exposed a log-viewing action.'
    assert_no_retained_log_staging "${log_dir}" \
        'whitespace-only diagnostic'

    logs_before=$(count_logs)
    prepare_argument_log 'retained-log-bounded-whitespace-only'
    bounded_whitespace_error_capture="${TEST_ROOT}/bounded-whitespace-error.txt"
    bounded_whitespace_question_log="${TEST_ROOT}/bounded-whitespace-question.bin"
    bounded_whitespace_text_info_log="${TEST_ROOT}/bounded-whitespace-text-info.bin"
    rm -f -- "${bounded_whitespace_error_capture}" \
        "${bounded_whitespace_question_log}" \
        "${bounded_whitespace_text_info_log}"
    assert_status 7 'bounded whitespace-only diagnostic is not retained' \
        env MOCK_GUI_REAL="${single_line_bundle}/download-video-gui.sh" \
        MOCK_BOUNDED_WHITESPACE_DIAGNOSTIC=1 \
        MOCK_ERROR_CAPTURE="${bounded_whitespace_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${bounded_whitespace_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${bounded_whitespace_text_info_log}" \
        "${GUI_UNDER_TEST}"
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'bounded whitespace-only diagnostic publishes no footer-only log'
    assert_file_contains "${bounded_whitespace_error_capture}" \
        'A safe diagnostic log could not be prepared.' \
        'bounded whitespace-only diagnostic safe fallback'
    [[ ! -s ${bounded_whitespace_question_log} &&
        ! -s ${bounded_whitespace_text_info_log} ]] \
        || fail 'Bounded whitespace-only diagnostic exposed a log-viewing action.'
    assert_no_retained_log_staging "${log_dir}" \
        'bounded whitespace-only diagnostic'

    final_result_bundle="${TEST_ROOT}/missing-final-result-bundle"
    mkdir -p -- "${final_result_bundle}"
    install -m 0755 -- "${PROJECT_DIR}/download-video-gui.sh" \
        "${PROJECT_DIR}/progress-monitor.sh" "${final_result_bundle}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${final_result_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${final_result_bundle}/private-process-supervisor.py"
    cat >"${final_result_bundle}/download-video.sh" <<'EOF_MISSING_FINAL_ENGINE'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : download-video.sh
# Purpose     : Return success without a result for GUI validation coverage.
# ==============================================================================

set -euo pipefail

if (($# == 1)) && [[ $1 == --version ]]; then
    printf '%s\n' 'yt-dlp-aria2-downloader-gui 9.9.9'
    exit 0
fi
if [[ -n ${MOCK_FAKE_ENGINE_FINAL:-} ]]; then
    while (($#)); do
        if [[ $1 == --result-file ]]; then
            printf '%s\n' "${MOCK_FAKE_ENGINE_FINAL}" >"$2"
            break
        fi
        shift
    done
    printf '%s\n' 'Independent fake engine returned success.'
    for _ in {1..500}; do
        [[ -s ${MOCK_FAKE_ENGINE_READY} ]] && exit 0
        sleep 0.01
    done
    exit 70
fi
printf '%s\n' 'Simulated worker success without a final result.'
sleep 0.2
exit 0
EOF_MISSING_FINAL_ENGINE
    chmod 0755 -- "${final_result_bundle}/download-video.sh"
    final_result_question_log="${TEST_ROOT}/missing-final-result-question.bin"
    final_result_text_info_log="${TEST_ROOT}/missing-final-result-text-info.bin"
    rm -f -- "${final_result_question_log}" "${final_result_text_info_log}"
    prepare_argument_log 'gui-missing-final-result-validation'
    assert_status 1 'GUI rejects successful worker without a confirmed final file' \
        env MOCK_GUI_REAL="${final_result_bundle}/download-video-gui.sh" \
        MOCK_QUESTION_ARGS_LOG="${final_result_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${final_result_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${final_result_question_log}" \
        'final media file could not be confirmed' \
        'GUI final-result validation diagnostic'
    [[ ! -s ${final_result_text_info_log} ]] \
        || fail 'Close unexpectedly opened the final-result diagnostic log.'

    outside_result_path="${TEST_ROOT}/independent-outside.webm"
    printf 'foreign independent media\n' >"${outside_result_path}"
    prepare_argument_log 'gui-independent-outside-result'
    assert_status 1 'GUI itself rejects a successful engine outside the destination' \
        env MOCK_GUI_REAL="${final_result_bundle}/download-video-gui.sh" \
        MOCK_FAKE_ENGINE_FINAL="${outside_result_path}" \
        MOCK_FAKE_ENGINE_READY="${TEST_ROOT}/outside-engine-ready" \
        MOCK_QUESTION_ARGS_LOG="${final_result_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${final_result_question_log}" \
        'final media file could not be confirmed' 'independent GUI containment refusal'
    assert_file_has_line "${outside_result_path}" 'foreign independent media' \
        'GUI preserves the outside media'
    printf 'independent valid media\n' >"${OUTPUT_DIR}/independent.webm"
    prepare_argument_log 'gui-independent-inside-result'
    assert_status 0 'GUI accepts a successful engine inside the destination' \
        env MOCK_GUI_REAL="${final_result_bundle}/download-video-gui.sh" \
        MOCK_FAKE_ENGINE_FINAL="${OUTPUT_DIR}/independent.webm" \
        MOCK_FAKE_ENGINE_READY="${TEST_ROOT}/inside-engine-ready" "${GUI_UNDER_TEST}"
    rm -- "${OUTPUT_DIR}/independent.webm" "${outside_result_path}"

    prepare_argument_log 'gui-final-probe-diagnostic'
    final_probe_question_log="${TEST_ROOT}/final-probe-question.bin"
    rm -f -- "${final_probe_question_log}"
    assert_status 65 'GUI media-validation failure exposes its diagnostic' \
        env MOCK_FFPROBE_EXIT_STATUS=1 \
        MOCK_QUESTION_ARGS_LOG="${final_probe_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${final_probe_question_log}" \
        'The download failed with status 65.' \
        'final-media-validation diagnostic'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'gui-runtime-preparation-diagnostic'
    runtime_question_log="${TEST_ROOT}/runtime-preparation-question.bin"
    rm -f -- "${runtime_question_log}"
    assert_status 1 'GUI runtime-preparation failure exposes its diagnostic' \
        env MOCK_YTDLP_VERSION=2026.06.08 \
        MOCK_YTDLP_VERSION_DELAY_SECONDS=0.5 \
        MOCK_QUESTION_ARGS_LOG="${runtime_question_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${runtime_question_log}" \
        'The download failed with status 1.' \
        'runtime-preparation diagnostic'

    logs_before=$(count_logs)
    prepare_argument_log 'gui-sanitization-failure'
    sanitization_error_capture="${TEST_ROOT}/sanitization-failure-error.txt"
    sanitization_question_log="${TEST_ROOT}/sanitization-failure-question.bin"
    sanitization_text_info_log="${TEST_ROOT}/sanitization-failure-text-info.bin"
    rm -f -- "${sanitization_error_capture}" \
        "${sanitization_question_log}" "${sanitization_text_info_log}"
    assert_status 7 'failed log sanitization never exposes the live diagnostic' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_YTDLP_EXIT_STATUS=7 \
        MOCK_FAILURE_DIAGNOSTIC_URL=1 \
        MOCK_SANITIZATION_FAILURE=1 \
        MOCK_ERROR_CAPTURE="${sanitization_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${sanitization_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${sanitization_text_info_log}" \
        "${GUI_UNDER_TEST}"
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'failed sanitization publishes no retained diagnostic log'
    assert_file_contains "${sanitization_error_capture}" \
        'A safe diagnostic log could not be prepared.' \
        'failed-sanitization safe fallback'
    assert_file_not_contains "${sanitization_error_capture}" \
        'UNSANITIZED_DIAGNOSTIC_SECRET' \
        'failed-sanitization fallback hides the raw diagnostic URL'
    [[ ! -s ${sanitization_question_log} ]] \
        || fail 'Failed sanitization still offered an unsafe View log action.'
    [[ ! -s ${sanitization_text_info_log} ]] \
        || fail 'Failed sanitization opened an unsafe diagnostic viewer.'
    if grep -R -Fq -- 'UNSANITIZED_DIAGNOSTIC_SECRET' "${log_dir}"; then
        fail 'A raw diagnostic URL escaped into the retained state directory.'
    fi
}

test_mock_gui_url_redaction_cases() {
    python3 -I -B - "${PROJECT_DIR}/download-video-gui.sh" "${TEST_ROOT}" <<'PY_GUI_URL_CASES'
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1]).read_text().rsplit('\nmain "$@"', 1)[0]
root = Path(sys.argv[2]) / "gui-url-cases"
root.mkdir(mode=0o700)
state = root / "state"
state.mkdir(mode=0o700)
live = root / "live"
live.mkdir(mode=0o700)
schemes = ("http", "https", "HTTP", "HTTPS", "hTtP", "hTtPs")
tokens = [f"PRIVATE_CASE_TOKEN_{index}" for index in range(len(schemes))]
log = live / "engine.log"
log.write_text("".join(f"diagnostic {scheme}://example.test/{token}\n"
                       for scheme, token in zip(schemes, tokens)))
log.chmod(0o600)
diagnostic = root / "zenity-diagnostic.txt"
program = source + r'''
STATE_DIR=$1
TEMP_DIR=$2
RUNTIME_TMPDIR=$2
LOG_FILE=$3
diagnostic_copy=$4
LOG_TIMESTAMP='case-test'
retain_sanitized_log_impl
[[ ${LOG_RETAINED} == true ]] || exit 71
show_diagnostic_dialog() { cp -- "$5" "${diagnostic_copy}"; }
ZENITY_ERROR=$(<"${LOG_FILE}")
show_zenity_error 'Expected diagnostic'
'''
result = subprocess.run(["bash", "-s", "--", str(state), str(live), str(log), str(diagnostic)],
                        input=program, text=True, capture_output=True, timeout=15)
if result.returncode:
    raise AssertionError(f"GUI redaction fixture failed: {result.returncode}: {result.stderr}")
retained = list(state.glob("download-*.log"))
if len(retained) != 1 or not diagnostic.is_file():
    raise AssertionError("GUI did not publish both diagnostic variants")
for path in [retained[0], diagnostic]:
    payload = path.read_text()
    if any(token in payload for token in tokens):
        raise AssertionError("GUI diagnostic retained a URL token with a supported scheme casing")
    if payload.count("[REDACTED_URL]") != len(schemes):
        raise AssertionError("GUI diagnostic did not mask every URL in the casing corpus")
    if path.stat().st_mode & 0o077:
        raise AssertionError("GUI diagnostic is accessible to other users")
PY_GUI_URL_CASES
}

test_mock_gui_state_initialization() {
    local blocked_state_home home_error_capture home_question_log
    local home_text_info_log hostile_error_capture hostile_old_log
    local hostile_question_log hostile_state_home hostile_state_target
    local hostile_text_info_log logs_after logs_before mktemp_probe_bin
    local mktemp_probe_log original_directory real_mktemp relative_tmp_cwd
    local relative_tmp_dir state_error_capture sticky_tmp_dir
    local unsafe_home_error_capture unsafe_home_parent unsafe_home_path
    local unsafe_tmp_dir unsafe_tmp_parent unsafe_xdg_config
    local unsafe_xdg_parent unsafe_xdg_state
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    local -a mktemp_probe_arguments=()

    # Initialization failures must be visible when the GUI is launched without a terminal.
    home_error_capture="${TEST_ROOT}/home-init-error.txt"
    home_question_log="${TEST_ROOT}/home-init-question.bin"
    home_text_info_log="${TEST_ROOT}/home-init-text-info.bin"
    rm -f -- "${home_error_capture}" "${home_question_log}" \
        "${home_text_info_log}"
    logs_before=$(count_logs)
    prepare_argument_log 'missing-home-startup'
    assert_status 1 'missing HOME is reported as a simple startup error' \
        env -u HOME \
        MOCK_ERROR_CAPTURE="${home_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${home_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${home_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${home_error_capture}" \
        'The HOME environment variable is not defined.' \
        'missing-HOME startup diagnostic'
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'missing HOME creates no retained diagnostic'
    [[ ! -s ${home_question_log} && ! -s ${home_text_info_log} ]] \
        || fail 'Missing HOME incorrectly exposed a diagnostic-log action.'

    rm -f -- "${home_error_capture}" "${home_question_log}" \
        "${home_text_info_log}"
    logs_before=$(count_logs)
    prepare_argument_log 'relative-home-startup'
    assert_status 1 'relative HOME is reported as a simple startup error' \
        env HOME='relative-home' \
        MOCK_ERROR_CAPTURE="${home_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${home_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${home_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${home_error_capture}" \
        'The HOME environment variable must be an absolute path.' \
        'relative-HOME startup diagnostic'
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'relative HOME creates no retained diagnostic'
    [[ ! -s ${home_question_log} && ! -s ${home_text_info_log} ]] \
        || fail 'Relative HOME incorrectly exposed a diagnostic-log action.'

    # TMPDIR is an inherited path input. A relative value must not redirect
    # private Zenity captures into the launcher's current working directory.
    mktemp_probe_bin="${TEST_ROOT}/relative-tmpdir-bin"
    mktemp_probe_log="${TEST_ROOT}/relative-tmpdir-mktemp.bin"
    relative_tmp_cwd="${TEST_ROOT}/relative-tmpdir-cwd"
    relative_tmp_dir="${relative_tmp_cwd}/relative-tmp"
    real_mktemp=$(command -v mktemp) \
        || fail 'Unable to resolve the real mktemp for TMPDIR coverage.'
    mkdir -p -- "${mktemp_probe_bin}" "${relative_tmp_dir}"
    cat >"${mktemp_probe_bin}/mktemp" <<'EOF_RELATIVE_TMPDIR_MKTEMP'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : mktemp
# Purpose     : Record GUI temporary-directory routing for integration tests.
# ==============================================================================

set -euo pipefail

: "${MOCK_MKTEMP_ARGUMENT_LOG:?}"
: "${MOCK_REAL_MKTEMP:?}"
printf '%s\0' "$@" >>"${MOCK_MKTEMP_ARGUMENT_LOG}"
exec "${MOCK_REAL_MKTEMP}" "$@"
EOF_RELATIVE_TMPDIR_MKTEMP
    chmod 0755 -- "${mktemp_probe_bin}/mktemp"
    : >"${mktemp_probe_log}"
    original_directory=${PWD}
    # shellcheck disable=SC2164 # The mock entry point runs these scenarios under errexit.
    cd -- "${relative_tmp_cwd}"
    prepare_argument_log 'relative-tmpdir-fallback'
    assert_status 0 'relative TMPDIR falls back outside the launcher cwd' \
        env PATH="${mktemp_probe_bin}:${PATH}" \
        TMPDIR='relative-tmp' \
        MOCK_REAL_MKTEMP="${real_mktemp}" \
        MOCK_MKTEMP_ARGUMENT_LOG="${mktemp_probe_log}" \
        MOCK_ZENITY_ENTRY_STATUS=1 \
        "${GUI_UNDER_TEST}"
    # shellcheck disable=SC2164 # The mock entry point runs these scenarios under errexit.
    cd -- "${original_directory}"
    read_arguments "${mktemp_probe_log}" mktemp_probe_arguments
    assert_array_contains mktemp_probe_arguments "--tmpdir=${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}" \
        'relative TMPDIR absolute fallback'
    assert_array_not_contains mktemp_probe_arguments '--tmpdir=relative-tmp' \
        'relative TMPDIR is never passed to mktemp'
    assert_directory_empty "${relative_tmp_dir}" \
        'relative TMPDIR launcher directory'

    # An absolute TMPDIR remains unsafe when any physical ancestor grants
    # shared writes without sticky-bit rename protection.
    unsafe_tmp_parent="${TEST_ROOT}/unsafe-tmpdir-parent"
    unsafe_tmp_dir="${unsafe_tmp_parent}/private-tmp"
    mkdir -p -- "${unsafe_tmp_dir}"
    chmod 0777 -- "${unsafe_tmp_parent}"
    chmod 0700 -- "${unsafe_tmp_dir}"
    : >"${mktemp_probe_log}"
    prepare_argument_log 'unsafe-tmpdir-fallback'
    assert_status 0 'non-sticky shared TMPDIR falls back to safe /tmp' \
        env PATH="${mktemp_probe_bin}:${PATH}" \
        TMPDIR="${unsafe_tmp_dir}" \
        MOCK_REAL_MKTEMP="${real_mktemp}" \
        MOCK_MKTEMP_ARGUMENT_LOG="${mktemp_probe_log}" \
        MOCK_ZENITY_ENTRY_STATUS=1 \
        "${GUI_UNDER_TEST}"
    read_arguments "${mktemp_probe_log}" mktemp_probe_arguments
    assert_array_contains mktemp_probe_arguments "--tmpdir=${RUNTIME_DIR}/yt-dlp-aria2-downloader-${EUID}" \
        'unsafe TMPDIR safe fallback'
    assert_array_not_contains mktemp_probe_arguments \
        "--tmpdir=${unsafe_tmp_dir}" \
        'unsafe TMPDIR is never passed to mktemp'
    assert_directory_empty "${unsafe_tmp_dir}" \
        'unsafe TMPDIR receives no private GUI state'

    sticky_tmp_dir="${TEST_ROOT}/sticky-tmpdir"
    mkdir -p -- "${sticky_tmp_dir}"
    chmod 1777 -- "${sticky_tmp_dir}"
    : >"${mktemp_probe_log}"
    prepare_argument_log 'sticky-tmpdir-accepted'
    assert_status 0 'private local root takes precedence over sticky TMPDIR' \
        env PATH="${mktemp_probe_bin}:${PATH}" \
        TMPDIR="${sticky_tmp_dir}" \
        MOCK_REAL_MKTEMP="${real_mktemp}" \
        MOCK_MKTEMP_ARGUMENT_LOG="${mktemp_probe_log}" \
        MOCK_ZENITY_ENTRY_STATUS=1 \
        "${GUI_UNDER_TEST}"
    read_arguments "${mktemp_probe_log}" mktemp_probe_arguments
    assert_array_not_contains mktemp_probe_arguments \
        "--tmpdir=${sticky_tmp_dir}" \
        'TMPDIR is not used as an unqualified private metadata root'
    assert_directory_empty "${sticky_tmp_dir}" \
        'sticky TMPDIR private state is cleaned'

    # Unsafe absolute XDG roots fall back to independently validated HOME
    # roots and never receive configuration, logs, or staging paths.
    unsafe_xdg_parent="${TEST_ROOT}/unsafe-xdg-parent"
    unsafe_xdg_config="${unsafe_xdg_parent}/config"
    unsafe_xdg_state="${unsafe_xdg_parent}/state"
    mkdir -p -- "${unsafe_xdg_parent}"
    chmod 0777 -- "${unsafe_xdg_parent}"
    rm -rf -- "${unsafe_xdg_config}" "${unsafe_xdg_state}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'unsafe-xdg-home-fallback'
    assert_status 0 'unsafe XDG roots fall back to safe HOME roots' \
        env XDG_CONFIG_HOME="${unsafe_xdg_config}" \
        XDG_STATE_HOME="${unsafe_xdg_state}" \
        MOCK_USE_DEFAULT_PROFILE=1 \
        "${GUI_UNDER_TEST}"
    [[ ! -e ${unsafe_xdg_config} && ! -e ${unsafe_xdg_state} ]] \
        || fail 'Unsafe XDG roots received private application state.'
    assert_file_has_line \
        "${HOME}/.config/yt-dlp-aria2-downloader/gui.conf" \
        "output_dir=${OUTPUT_DIR}" \
        'unsafe XDG roots use the safe HOME configuration fallback'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    # A fallback under HOME is not an escape hatch: when its existing parent
    # is shared and non-sticky, startup fails before creating private state.
    unsafe_home_parent="${TEST_ROOT}/unsafe-home-parent"
    unsafe_home_path="${unsafe_home_parent}/home"
    unsafe_home_error_capture="${TEST_ROOT}/unsafe-home-error.txt"
    mkdir -p -- "${unsafe_home_parent}"
    chmod 0777 -- "${unsafe_home_parent}"
    rm -rf -- "${unsafe_home_path}"
    rm -f -- "${unsafe_home_error_capture}"
    prepare_argument_log 'unsafe-home-fallback-refused'
    assert_status 1 'unsafe HOME fallback fails closed' \
        env HOME="${unsafe_home_path}" \
        XDG_CONFIG_HOME='relative-config-home' \
        XDG_STATE_HOME='relative-state-home' \
        MOCK_ERROR_CAPTURE="${unsafe_home_error_capture}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${unsafe_home_error_capture}" \
        'No safe application configuration directory is available.' \
        'unsafe HOME fallback diagnostic'
    [[ ! -e ${unsafe_home_path} ]] \
        || fail 'Unsafe HOME fallback created private application state.'

    blocked_state_home="${TEST_ROOT}/blocked-state-home"
    : >"${blocked_state_home}"
    state_error_capture="${TEST_ROOT}/state-init-error.txt"
    prepare_argument_log 'state-directory-error'
    assert_status 1 'state-directory creation failure is reported in the GUI' \
        env XDG_STATE_HOME="${blocked_state_home}" \
        MOCK_USE_DEFAULT_PROFILE=1 \
        MOCK_ERROR_CAPTURE="${state_error_capture}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${state_error_capture}" \
        'Unable to create the application state directory.' \
        'state-directory GUI diagnostic'

    hostile_state_home="${TEST_ROOT}/hostile-state-home"
    hostile_state_target="${TEST_ROOT}/hostile-state-target"
    hostile_old_log="${hostile_state_target}/download-hostile-old.log"
    hostile_error_capture="${TEST_ROOT}/hostile-state-error.txt"
    hostile_question_log="${TEST_ROOT}/hostile-state-question.bin"
    hostile_text_info_log="${TEST_ROOT}/hostile-state-text-info.bin"
    mkdir -p -- "${hostile_state_home}" "${hostile_state_target}"
    chmod 700 -- "${hostile_state_home}" "${hostile_state_target}"
    printf '%s\n' 'preserve hostile-state target' >"${hostile_old_log}"
    chmod 600 -- "${hostile_old_log}"
    LC_ALL=C touch -d '16 days ago' -- "${hostile_old_log}"
    ln -s -- "${hostile_state_target}" \
        "${hostile_state_home}/yt-dlp-aria2-downloader"
    rm -f -- "${hostile_error_capture}" "${hostile_question_log}" \
        "${hostile_text_info_log}"
    prepare_argument_log 'hostile-state-directory'
    assert_status 1 'symbolic-link state directory is rejected before pruning' \
        env XDG_STATE_HOME="${hostile_state_home}" \
        MOCK_ERROR_CAPTURE="${hostile_error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${hostile_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${hostile_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${hostile_error_capture}" \
        'The application state path must not be a symbolic link.' \
        'hostile state-directory diagnostic'
    [[ -f ${hostile_old_log} ]] \
        || fail 'Hostile state-directory target was pruned before validation.'
    [[ ! -s ${hostile_question_log} && ! -s ${hostile_text_info_log} ]] \
        || fail 'Hostile state-directory rejection exposed a diagnostic-log action.'
    assert_no_retained_log_staging "${hostile_state_target}" \
        'hostile state-directory rejection'
}

test_mock_gui_input_validation() {
    local entry_attempt_marker error_capture logs_after logs_before
    local question_log text_info_log

    # Trivial input validation has no session diagnostic and must not invent one.
    entry_attempt_marker="${TEST_ROOT}/invalid-url-entry-attempted"
    error_capture="${TEST_ROOT}/invalid-url-error.txt"
    question_log="${TEST_ROOT}/invalid-url-question.bin"
    text_info_log="${TEST_ROOT}/invalid-url-text-info.bin"
    rm -f -- "${entry_attempt_marker}" "${error_capture}" \
        "${question_log}" "${text_info_log}"
    logs_before=$(count_logs)
    prepare_argument_log 'invalid-url-without-diagnostic'
    assert_status 0 'invalid URL remains a simple input error before cancellation' \
        env MOCK_INVALID_URL_THEN_CANCEL=1 \
        MOCK_ENTRY_ATTEMPT_MARKER="${entry_attempt_marker}" \
        MOCK_ERROR_CAPTURE="${error_capture}" \
        MOCK_QUESTION_ARGS_LOG="${question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_file_contains "${error_capture}" \
        'The URL must start with http:// or https://.' \
        'invalid URL input diagnostic'
    logs_after=$(count_logs)
    assert_equals "${logs_before}" "${logs_after}" \
        'trivial URL validation creates no retained log'
    [[ ! -s ${question_log} ]] \
        || fail 'Trivial URL validation incorrectly offered View log.'
    [[ ! -s ${text_info_log} ]] \
        || fail 'Trivial URL validation incorrectly opened a log viewer.'
}

run_mock_gui_progress_group() {
    test_mock_gui_aria_progress
    test_mock_gui_profiles
    test_mock_gui_progress_completion
}

test_mock_gui_settings_signal_cleanup() {
    python3 -I -B - "${PROJECT_DIR}/download-video-gui.sh" <<'PY_SETTINGS_SIGNAL'
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
entrypoint = 'main "$@"\n'
if not source.endswith(entrypoint):
    raise AssertionError("GUI entrypoint changed")
fixture = r'''
source "$1"
CONFIG_DIR="$2/config"
CONFIG_FILE="${CONFIG_DIR}/gui.conf"
LAST_OUTPUT_DIR=$2
LAST_PROFILE=video
SIGNAL_UNDER_TEST=$3
trap cleanup EXIT
trap 'handle_gui_signal 129' HUP
trap 'handle_gui_signal 130' INT
trap 'handle_gui_signal 143' TERM
select_url() { printf -v "$1" '%s' 'https://example.invalid/video'; }
select_profile() { printf -v "$1" '%s' video; }
select_output_dir() { printf -v "$1" '%s' "${LAST_OUTPUT_DIR}"; }
chmod() {
    command chmod "$@" || return
    if [[ $1 == 600 && ${*: -1} == */gui.conf.* ]]; then
        kill -"${SIGNAL_UNDER_TEST}" "${BASHPID}"
    fi
}
collect_download_request
'''
with tempfile.TemporaryDirectory(prefix="gui-settings-signal-") as directory:
    root = pathlib.Path(directory)
    functions = root / "functions.sh"
    functions.write_text(source[:-len(entrypoint)], encoding="utf-8")
    for signal_name, expected_status in (("HUP", 129), ("INT", 130), ("TERM", 143)):
        case = root / signal_name
        case.mkdir()
        result = subprocess.run(
            ["bash", "-c", fixture, "bash", str(functions), str(case), signal_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        if result.returncode != expected_status:
            raise AssertionError(
                f"settings signal {signal_name} returned {result.returncode}: "
                + result.stderr.decode(errors="replace")
            )
        config_directory = case / "config"
        if list(config_directory.glob("gui.conf.*")):
            raise AssertionError(f"settings temporary leaked after {signal_name}")
        expected = f"output_dir={case}\nprofile=video\n"
        if (config_directory / "gui.conf").read_text(encoding="utf-8") != expected:
            raise AssertionError(f"settings commit was incomplete after {signal_name}")
PY_SETTINGS_SIGNAL
}

test_mock_gui_live_log_retention_unconfirmed_shutdown() {
    python3 -I -B - "${PROJECT_DIR}/download-video-gui.sh" "${TEST_ROOT}" <<'PY_LIVE_LOG_RETENTION'
import os
import pathlib
import select
import stat
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
entrypoint = 'main "$@"\n'
if not source.endswith(entrypoint):
    raise AssertionError("GUI entrypoint changed")
fixture = r'''
source "$1"
STATE_DIR="$2/state"
TEMP_DIR="$2/session"
LOG_FILE="${TEMP_DIR}/live-download-log.fixture"
LOG_TIMESTAMP=20260920-120000
trap cleanup EXIT
if [[ $3 == unconfirmed ]]; then
    WORKER_PID=$4
    # A live producer models a bounded shutdown whose completion is unknown.
    # Only that outcome is injected: retention and cleanup are production code.
    stop_worker() { return 1; }
    show_diagnostic_dialog() {
        local validated=''
        validated_retained_log_path validated
        [[ $5 == "${validated}" ]]
        printf '%s\n' "${validated}"
    }
    show_error_with_log 'Download failed' 'Worker shutdown remains unconfirmed.'
    printf 'LATE_GUI_CAPTURE\n' >"${TEMP_DIR}/late-monitor.stderr"
    append_session_diagnostic "${TEMP_DIR}/late-monitor.stderr" 'Late monitor diagnostic'
    exit 7
fi
# A retained point-in-time snapshot already exists. Once the real producer has
# been reaped, normal session cleanup is allowed without another retention.
LOG_RETENTION_ATTEMPTED=true
exit 0
'''
producer_source = r'''
import sys

with open(sys.argv[1], "a", encoding="utf-8") as live_log:
    live_log.write("INITIAL_DIAGNOSTIC https://secret.example/video?token=LIVE_SECRET\n")
    live_log.flush()
    print("ready", flush=True)
    for command in sys.stdin:
        if command.strip() == "stop":
            break
        live_log.write("LATE_PRODUCER_DIAGNOSTIC\n")
        live_log.flush()
        print("appended", flush=True)
'''


def expect_producer_ack(producer, expected):
    ready, _, _ = select.select([producer.stdout], [], [], 5)
    if not ready or producer.stdout.readline().strip() != expected:
        raise AssertionError(f"Live diagnostic producer did not acknowledge {expected!r}")


with tempfile.TemporaryDirectory(prefix="gui-live-log-", dir=sys.argv[2]) as directory:
    root = pathlib.Path(directory)
    functions = root / "functions.sh"
    functions.write_text(source[:-len(entrypoint)], encoding="utf-8")
    session = root / "session"
    session.mkdir(mode=0o700)
    state = root / "state"
    state.mkdir(mode=0o700)
    live_log = session / "live-download-log.fixture"
    live_log.touch(mode=0o600)
    live_identity = (live_log.stat().st_dev, live_log.stat().st_ino)
    producer = subprocess.Popen(
        [sys.executable, "-u", "-c", producer_source, str(live_log)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        expect_producer_ack(producer, "ready")
        result = subprocess.run(
            ["bash", "-c", fixture, "bash", str(functions), str(root),
             "unconfirmed", str(producer.pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
        if result.returncode != 7:
            raise AssertionError(
                f"Unconfirmed GUI cleanup returned {result.returncode}: {result.stderr}"
            )
        if "preserving active private GUI temporary files" not in result.stderr:
            raise AssertionError("GUI cleanup did not report unconfirmed shutdown")
        retained = pathlib.Path(result.stdout.strip())
        if retained.parent != state or retained == live_log:
            raise AssertionError(f"GUI diagnostic did not use a retained snapshot: {retained}")
        metadata = retained.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise AssertionError("Retained diagnostic snapshot is not a private regular file")
        if metadata.st_uid != os.geteuid():
            raise AssertionError("Retained diagnostic snapshot has an unexpected owner")
        payload = retained.read_text(encoding="utf-8")
        if "INITIAL_DIAGNOSTIC" not in payload or "[REDACTED_URL]" not in payload:
            raise AssertionError("Retained snapshot lost its useful sanitized diagnostic")
        if "secret.example" in payload or "LIVE_SECRET" in payload:
            raise AssertionError("Retained snapshot exposed a live diagnostic secret")
        if not session.is_dir() or producer.poll() is not None:
            raise AssertionError("Unconfirmed cleanup did not preserve the active session")
        producer.stdin.write("append\n")
        producer.stdin.flush()
        expect_producer_ack(producer, "appended")
        if not live_log.is_file():
            raise AssertionError(
                "Retention unlinked the live GUI log while its producer was still alive; "
                "the later diagnostic is no longer recoverable by its session path"
            )
        if (live_log.stat().st_dev, live_log.stat().st_ino) != live_identity:
            raise AssertionError("Retention replaced the active diagnostic inode")
        live_payload = live_log.read_text(encoding="utf-8")
        if "LATE_PRODUCER_DIAGNOSTIC" not in live_payload:
            raise AssertionError("The preserved live log lost the producer's later diagnostic")
        if "LATE_GUI_CAPTURE" not in live_payload:
            raise AssertionError("The preserved live log lost a later GUI diagnostic capture")
        if retained.read_text(encoding="utf-8") != payload:
            raise AssertionError("The live producer changed the retained point-in-time snapshot")
    finally:
        try:
            producer.communicate(input="stop\n" if producer.poll() is None else None, timeout=5)
        except subprocess.TimeoutExpired:
            producer.kill()
            producer.communicate(timeout=5)
        cleanup_result = subprocess.run(
            ["bash", "-c", fixture, "bash", str(functions), str(root), "confirmed"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
        if cleanup_result.returncode != 0 or session.exists():
            raise AssertionError(
                "Confirmed GUI shutdown did not clean its private session: "
                + cleanup_result.stderr
            )
    if not retained.is_file() or retained.read_text(encoding="utf-8") != payload:
        raise AssertionError("Normal GUI cleanup removed or changed the retained snapshot")
PY_LIVE_LOG_RETENTION
}

test_mock_gui_cleanup_unconfirmed_shutdown() {
    local source_copy="${TEST_ROOT}/gui-cleanup-source.sh"
    local fixture="${TEST_ROOT}/gui-cleanup-fixture.sh"
    local case_name session

    sed '$d' "${PROJECT_DIR}/download-video-gui.sh" >"${source_copy}"
    cat >"${fixture}" <<'EOF_GUI_CLEANUP_QUIESCENCE'
#!/usr/bin/env bash
set -euo pipefail
# Load the real cleanup function without entering the GUI main loop.
# shellcheck disable=SC1090
source "${MOCK_GUI_CLEANUP_SOURCE:?}"
signal_gui_children() { :; }
stop_worker() { return 1; }
stop_gui_children() { return 1; }
retain_sanitized_log() { printf 'unsafe retention\n' >"${TEMP_DIR}/retention"; }
TEMP_DIR=${MOCK_GUI_CLEANUP_SESSION:?}
case ${MOCK_GUI_CLEANUP_CASE:?} in
    worker) WORKER_PID=999999 ;;
    gui) ZENITY_PID=999999 ;;
esac
trap cleanup EXIT
exit 7
EOF_GUI_CLEANUP_QUIESCENCE
    for case_name in worker gui; do
        session="${TEST_ROOT}/gui-cleanup-unconfirmed-${case_name}"
        mkdir -- "${session}"
        printf '%s\n' 'active private state' >"${session}/sentinel"
        assert_status 7 "GUI preserves active private files after unconfirmed ${case_name} shutdown" \
            env MOCK_GUI_CLEANUP_SOURCE="${source_copy}" \
            MOCK_GUI_CLEANUP_SESSION="${session}" \
            MOCK_GUI_CLEANUP_CASE="${case_name}" bash "${fixture}"
        assert_file_has_line "${session}/sentinel" 'active private state' \
            "unconfirmed ${case_name} state is preserved"
        [[ ! -e ${session}/retention ]] \
            || fail 'GUI read a live producer log after unconfirmed shutdown.'
        assert_text_contains "${ASSERT_OUTPUT}" \
            'preserving active private GUI temporary files' \
            'unconfirmed shutdown preservation diagnostic'
    done
}

run_mock_gui_state_group() {
    test_mock_gui_url_redaction_cases
    test_mock_gui_live_log_retention_unconfirmed_shutdown
    test_mock_gui_cleanup_unconfirmed_shutdown
    test_mock_gui_config_recovery
    test_mock_gui_settings_signal_cleanup
    test_mock_gui_file_selection
    test_mock_gui_prune_metadata
    test_mock_gui_diagnostic_logs
    test_mock_gui_state_initialization
    test_mock_gui_input_validation
}

run_mock_gui_group() {
    run_mock_gui_progress_group
    run_mock_gui_state_group
}

run_selected_mock_gui_group() {
    case ${MOCK_GROUP} in
        all | gui) run_mock_gui_group ;;
        gui-progress) run_mock_gui_progress_group ;;
        gui-state) run_mock_gui_state_group ;;
        *) ;;
    esac
}
