#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-engine.sh
# Purpose     : Qualify engine transport, media, staging, and destination contracts.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    TEST_ROOT GUI_UNDER_TEST OUTPUT_DIR \
    PROJECT_DIR MOCK_PLAN_CALL_LOG MOCK_POST_CALL_LOG \
    MOCK_ARG_LOG MOCK_ARIA2_ARG_LOG MOCK_PLAN_ARG_LOG \
    ASSERT_STDOUT ASSERT_STDERR ASSERT_OUTPUT \
    TEST_PROCESS_PIDS MOCK_BIN MOCK_GROUP

# Sourced by mock-integration.sh in the same Bash process. Helpers and tests
# share its PROJECT_DIR, private TEST_ROOT paths, command doubles and assertions;
# invocation remains under the entry point's options, traps and group dispatch.

test_mock_engine_log_retention() {
    local old_retained_log recent_retained_log rotation_config_home
    local rotation_log_dir rotation_state_home symlink_log symlink_target
    local unrelated_old_file

    # Retained diagnostic logs older than 15 days are removed at GUI startup.
    # Newer logs, unrelated files, and symbolic links must remain untouched.
    rotation_state_home="${TEST_ROOT}/rotation-state"
    rotation_config_home="${TEST_ROOT}/rotation-config"
    rotation_log_dir="${rotation_state_home}/yt-dlp-aria2-downloader"
    old_retained_log="${rotation_log_dir}/download-old.log"
    recent_retained_log="${rotation_log_dir}/download-recent.log"
    unrelated_old_file="${rotation_log_dir}/unrelated-old.txt"
    symlink_target="${rotation_log_dir}/symlink-target.txt"
    symlink_log="${rotation_log_dir}/download-symlink.log"

    mkdir -p -- "${rotation_log_dir}" "${rotation_config_home}"
    : >"${old_retained_log}"
    : >"${recent_retained_log}"
    : >"${unrelated_old_file}"
    : >"${symlink_target}"
    chmod 600 -- "${old_retained_log}" "${recent_retained_log}"
    LC_ALL=C touch -d '16 days ago' -- \
        "${old_retained_log}" "${unrelated_old_file}" "${symlink_target}"
    LC_ALL=C touch -d '14 days ago' -- "${recent_retained_log}"
    ln -s -- "${symlink_target}" "${symlink_log}"

    prepare_argument_log 'log-retention'
    env XDG_STATE_HOME="${rotation_state_home}" \
        XDG_CONFIG_HOME="${rotation_config_home}" \
        MOCK_USE_DEFAULT_PROFILE=1 \
        "${GUI_UNDER_TEST}"
    assert_no_test_processes 'log-retention GUI run left worker processes'

    [[ ! -e ${old_retained_log} ]] \
        || fail 'A retained diagnostic log older than 15 days was not removed.'
    [[ -f ${recent_retained_log} ]] \
        || fail 'A retained diagnostic log newer than 15 days was removed.'
    [[ -f ${unrelated_old_file} ]] \
        || fail 'Log cleanup removed an unrelated old file.'
    [[ -L ${symlink_log} ]] \
        || fail 'Log cleanup removed a symbolic link matching the log pattern.'
    [[ -f ${symlink_target} ]] \
        || fail 'Log cleanup removed the target of a symbolic link.'

    # The log-retention scenario exercises GUI/log lifecycle only. Remove its
    # successful media artifact before subsequent engine scenarios reuse the
    # shared output directory. The private aria2 commit path intentionally
    # refuses to overwrite an existing destination.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_engine_audio_downloads() {
    local aria2_arguments_text arguments_text content_video_result
    local expected_output_template ffprobe_argument_log forbidden_audio_format
    local injection_marker malicious_url missing_target_result normalized_result
    local normalized_result_file plan_call_count post_call_count result_file
    local runtime_lock_dir runtime_lock_file url_file url_seen_log
    local -a arguments aria2_arguments aria_without_netrc_arguments
    local -a aria_without_netrc_direct_arguments ffprobe_arguments plan_arguments
    local -a runtime_lock_files

    # Scenario: audio mode covers quoting, locale stabilization, option/value pairing,
    # and result-path reporting.
    prepare_argument_log 'audio-engine'
    result_file="${TEST_ROOT}/engine-%-result.txt"
    ffprobe_argument_log="${TEST_ROOT}/ffprobe-audio-args.bin"
    url_seen_log="${TEST_ROOT}/private-url-seen.txt"
    injection_marker="${TEST_ROOT}/must-not-exist"
    malicious_url="https://example.com/watch?v=abc123&x=\$(touch\$IFS${injection_marker})"
    assert_status 0 'audio engine succeeds under a hostile inherited locale' \
        env LC_ALL=fr_FR.UTF-8 LANG=fr_FR.UTF-8 \
        MOCK_FFPROBE_ARG_LOG="${ffprobe_argument_log}" \
        MOCK_URL_SEEN_LOG="${url_seen_log}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        --machine-progress \
        --result-file "${result_file}" \
        -- "${malicious_url}"
    assert_file_has_line "${result_file}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm" 'engine result path'
    # shellcheck disable=SC2034 # Read indirectly through nameref assertion helpers.
    ffprobe_arguments=()
    read_arguments "${ffprobe_argument_log}" ffprobe_arguments
    assert_option_value ffprobe_arguments '-show_entries' \
        'format=start_time,duration:stream=codec_type:stream_disposition=attached_pic' \
        'audio result uses the combined FFprobe media summary'
    [[ ! -e ${injection_marker} ]] || fail 'The URL was interpreted as shell code.'

    plan_call_count=$(wc -l <"${MOCK_PLAN_CALL_LOG}")
    post_call_count=$(wc -l <"${MOCK_POST_CALL_LOG}")
    assert_equals '1' "${plan_call_count}" 'audio engine performs one yt-dlp PLAN invocation'
    assert_equals '1' "${post_call_count}" 'audio engine performs one yt-dlp POST invocation'

    arguments=()
    read_arguments "${MOCK_ARG_LOG}" arguments
    arguments_text=$(printf '%s\n' "${arguments[@]}")
    assert_text_not_contains "${arguments_text}" 'http://' \
        'yt-dlp POST argv contains no HTTP URL'
    assert_text_not_contains "${arguments_text}" 'https://' \
        'yt-dlp POST argv contains no HTTPS URL'
    assert_array_contains arguments '--ignore-config' 'yt-dlp ignores user configuration'
    assert_array_contains arguments '--no-plugin-dirs' 'yt-dlp clears plugin directories'
    assert_array_contains arguments '--no-update' 'yt-dlp cannot self-update'
    assert_array_contains arguments '--no-playlist' 'yt-dlp disables playlists'
    assert_array_contains arguments '--no-overwrites' 'yt-dlp final-file overwrite protection'
    assert_array_contains arguments '--no-post-overwrites' 'yt-dlp post-processing overwrite protection'
    assert_option_value arguments '--parse-metadata' ':(?P<meta_purl>)' \
        'embedded purl URL metadata is cleared' 1
    assert_option_value arguments '--parse-metadata' ':(?P<meta_comment>)' \
        'embedded comment URL metadata is cleared' 2
    assert_array_not_contains arguments '--supervised-session' 'internal session option isolation'
    assert_array_not_contains arguments '--remote-components' 'generic extraction avoids remote EJS'
    assert_option_value arguments '--format' 'ba/b' 'audio format selector'
    assert_array_contains arguments '--extract-audio' 'audio extraction postprocessor'
    assert_option_value arguments '--audio-format' 'best' 'audio output format'
    assert_option_value arguments '--audio-quality' '0' 'fallback conversion quality'
    assert_option_value arguments '--downloader' 'dash,m3u8:native' \
        'fragmented DASH/HLS streams remain on the native yt-dlp downloader'
    assert_array_not_contains arguments 'aria2c' \
        'yt-dlp no longer receives aria2c as an external downloader'
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    aria2_arguments=()
    read_arguments "${MOCK_ARIA2_ARG_LOG}" aria2_arguments

    assert_array_contains_prefix aria2_arguments '--input-file=' \
        'private aria2 input-file argument'
    assert_array_contains_prefix aria2_arguments '--dir=' \
        'private aria2 staging directory argument'
    assert_array_contains_prefix aria2_arguments '--load-cookies=' \
        'private aria2 cookie-file argument'
    assert_array_contains aria2_arguments '--summary-interval=1' \
        'machine-progress aria2 summary interval'
    assert_array_contains aria2_arguments '--max-concurrent-downloads=1' \
        'machine-progress aria2 keeps one observable transfer item active at a time'
    assert_array_contains aria2_arguments '--show-console-readout=true' \
        'machine-progress aria2 console readout'
    assert_array_contains aria2_arguments '--stderr=false' \
        'machine-progress aria2 progress remains on stdout'

    aria2_arguments_text=$(printf '%s\n' "${aria2_arguments[@]}")
    assert_text_not_contains "${aria2_arguments_text}" 'http://' \
        'aria2 argv contains no HTTP URL'
    assert_text_not_contains "${aria2_arguments_text}" 'https://' \
        'aria2 argv contains no HTTPS URL'
    assert_array_not_contains arguments '--machine-progress' \
        'internal wrapper option isolation'
    for forbidden_audio_format in mp3 m4a opus; do
        assert_array_not_contains arguments "${forbidden_audio_format}" \
            "removed audio format ${forbidden_audio_format}"
    done
    assert_array_not_contains arguments "${malicious_url}" \
        'private URL is absent from yt-dlp arguments'
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    plan_arguments=()
    read_arguments "${MOCK_PLAN_ARG_LOG}" plan_arguments

    assert_array_contains plan_arguments '--batch-file' \
        'yt-dlp PLAN receives a private URL batch file'
    assert_array_contains plan_arguments '--dump-single-json' \
        'yt-dlp PLAN emits the private transfer plan'
    assert_array_contains plan_arguments '--skip-download' \
        'yt-dlp PLAN performs extraction without downloading'

    assert_array_not_contains arguments '--batch-file' \
        'yt-dlp POST no longer receives the source URL batch file'
    assert_array_contains arguments '--load-info-json' \
        'yt-dlp POST resumes from the private info JSON'
    assert_file_has_line "${url_seen_log}" "${malicious_url}" \
        'private URL batch file preserves the exact URL'
    expected_output_template="${OUTPUT_DIR//%/%%}/%(title).160B [%(id).64B].%(ext)s"
    assert_option_value arguments '--output' "${expected_output_template}" \
        'absolute escaped output template'
    assert_array_not_contains arguments '--paths' 'legacy path option is absent'

    # Audio-mode final validation must reject a real content-video stream even
    # when the audio stream remains present.
    # The preceding successful audio-engine scenario leaves its media
    # artifact in the shared mock output directory. The next scenario must
    # start from a clean destination so it can reach FFprobe validation.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'machine-output-channel-contract'
    assert_status_split 0 'machine output keeps human banners on stderr' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --machine-progress \
        -- 'https://example.com/watch?v=machine-output-channel-contract'
    assert_text_not_contains "${ASSERT_STDOUT}" \
        "${SCRIPT_NAME:-download-video.sh} version" \
        'machine stdout excludes the human version banner'
    assert_text_not_contains "${ASSERT_STDOUT}" \
        'Download completed successfully.' \
        'machine stdout excludes the human completion banner'
    assert_text_contains "${ASSERT_STDERR}" \
        'download-video.sh version' \
        'machine stderr contains the human version banner'
    assert_text_contains "${ASSERT_STDERR}" \
        'Download completed successfully.' \
        'machine stderr contains the human completion banner'
    assert_text_contains "${ASSERT_STDOUT}" 'ARIA2_PLAN|1' \
        'machine stdout retains transfer records'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'audio-content-video-validation'
    content_video_result="${TEST_ROOT}/audio-content-video-result.txt"
    rm -f -- "${content_video_result}"
    assert_status 65 'audio mode rejects a retained content-video stream' \
        env MOCK_FFPROBE_CONTENT_VIDEO=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${content_video_result}" \
        -- 'https://example.com/watch?v=audio-content-video'
    [[ ! -e ${content_video_result} ]] \
        || fail 'Audio mode published a result-file while content video remained.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'the final media file failed FFprobe validation:' \
        'audio content-video rejection diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: unexpected-content-video' \
        'audio content-video bounded reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    # A distro build may omit the optional netrc feature entirely. Such a build
    # must remain usable and must not receive an unsupported --no-netrc argument.
    prepare_argument_log 'aria2-without-netrc-capability'
    assert_status 0 'aria2 build without optional netrc support remains usable' \
        env MOCK_ARIA2_NO_NETRC_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --machine-progress \
        -- 'https://example.com/watch?v=aria2-without-netrc'
    # shellcheck disable=SC2034 # Read indirectly through nameref assertion helpers.
    aria_without_netrc_arguments=()
    read_arguments "${MOCK_ARG_LOG}" aria_without_netrc_arguments
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    aria_without_netrc_direct_arguments=()
    read_arguments \
        "${MOCK_ARIA2_ARG_LOG}" \
        aria_without_netrc_direct_arguments

    assert_array_not_contains \
        aria_without_netrc_direct_arguments \
        '--no-netrc=true' \
        'aria2 arguments omit unsupported optional netrc capability'

    runtime_lock_dir="/tmp/yt-dlp-aria2-downloader-${EUID}"
    [[ -d ${runtime_lock_dir} && ! -L ${runtime_lock_dir} ]] \
        || fail 'The engine did not create the stable private destination lock directory.'
    assert_path_mode "${runtime_lock_dir}" 700 \
        'stable destination lock-directory permissions'
    shopt -s nullglob
    runtime_lock_files=("${runtime_lock_dir}"/*.lock)
    shopt -u nullglob
    ((${#runtime_lock_files[@]} > 0)) \
        || fail 'The engine did not create a destination lock file.'
    for runtime_lock_file in "${runtime_lock_files[@]}"; do
        [[ -f ${runtime_lock_file} && ! -L ${runtime_lock_file} ]] \
            || fail "Unsafe runtime lock entry: ${runtime_lock_file}"
        assert_path_mode "${runtime_lock_file}" 600 \
            'destination lock-file permissions'
    done

    # The preceding successful direct-transfer scenario leaves its
    # media artifact in the shared mock output directory. Remove only that
    # completed artifact so result-path-normalization can exercise its own
    # result-file semantics without weakening the no-overwrite policy.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'result-path-normalization'
    normalized_result_file="${TEST_ROOT}/normalized-result.txt"
    assert_status 0 'result path record is normalized to one valid line' \
        env MOCK_PREPEND_STALE_RESULT=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${normalized_result_file}" \
        -- 'https://example.com/watch?v=result-normalization'
    normalized_result=$(<"${normalized_result_file}")
    assert_equals "${OUTPUT_DIR}/Mock media [abc123].webm" \
        "${normalized_result}" 'normalized result path content'

    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    missing_target_result="${TEST_ROOT}/missing-target-result.txt"
    prepare_argument_log 'missing-result-target'
    assert_status 1 'a result path whose target is absent is rejected' \
        env MOCK_RESULT_TARGET_MISSING=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${missing_target_result}" \
        -- 'https://example.com/watch?v=missing-result-target'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'yt-dlp did not report a valid final media path inside the destination directory.' \
        'missing or outside result target diagnostic'
    [[ ! -e ${missing_target_result} ]] \
        || fail 'An invalid result path was published.'

    # Scenario: positional separator handling.
    prepare_argument_log 'terminal-separator'
    assert_status 0 'terminal -- is accepted' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        'https://example.com/watch?v=terminal-separator' --
    assert_status 2 'two URLs split by -- are rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        'https://example.com/a' -- 'https://example.com/b'
    assert_text_contains "${ASSERT_OUTPUT}" 'exactly one video URL is required.' \
        'duplicate URL after -- diagnostic'

    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    url_file="${TEST_ROOT}/private-url-input.txt"
    printf '%s\n' 'https://example.com/watch?v=private-url-mode' >"${url_file}"
    chmod 0644 -- "${url_file}"
    assert_status 2 'URL file rejects group/other access' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --url-file "${url_file}"
    assert_text_contains "${ASSERT_OUTPUT}" \
        'URL file must not be accessible by group or other users.' \
        'URL file permission diagnostic'

    chmod 0600 -- "${url_file}"
    prepare_argument_log 'private-url-file-mode'
    assert_status 0 'private owner-only URL file is accepted' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --url-file "${url_file}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    assert_status 2 'a positional URL rejects a raw BEL control byte' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- $'https://example.com/\007private-control-token'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'the URL must not contain control characters.' \
        'URL control-character diagnostic'
    assert_text_not_contains "${ASSERT_OUTPUT}" 'private-control-token' \
        'URL rejection does not echo private input'
    assert_status 2 'a positional URL rejects a raw DEL control byte' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- $'https://example.com/\177private-control-token'

    printf '%s\n' $'https://example.com/\033private-control-token' >"${url_file}"
    assert_status 2 'a private URL file rejects a raw ESC control byte' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --url-file "${url_file}"
    assert_text_contains "${ASSERT_OUTPUT}" \
        'the URL must not contain control characters.' \
        'private URL file control-character diagnostic'

    printf 'https://example.com/\0private-control-token\n' >"${url_file}"
    assert_status 2 'a private URL file rejects a raw NUL control byte' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --url-file "${url_file}"
    assert_text_contains "${ASSERT_OUTPUT}" \
        'the URL must not contain control characters.' \
        'private URL file NUL diagnostic'
    assert_text_not_contains "${ASSERT_OUTPUT}" 'private-control-token' \
        'NUL rejection does not echo private input'

    # Reject raw control bytes without narrowing valid Unicode or encoded URL data.
    printf '%s\n' 'https://exemple.fr/été?q=東京&encoded=%07' >"${url_file}"
    prepare_argument_log 'unicode-private-url-file'
    assert_status 0 'Unicode and percent-encoded URL bytes remain accepted' \
        env MOCK_URL_SEEN_LOG="${url_seen_log}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio --url-file "${url_file}"
    assert_file_has_line "${url_seen_log}" \
        'https://exemple.fr/été?q=東京&encoded=%07' \
        'private URL batch preserves Unicode and percent encoding'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_engine_video_downloads() {
    local existing_audio_path
    local -a arguments video_aria2_arguments

    # Scenario: video mode.
    # The preceding successful direct-transfer scenario leaves the
    # shared mock media artifact behind. Remove only that completed artifact
    # so video-engine starts with a clean destination and can exercise the
    # video-specific pipeline.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'video-engine'
    assert_status 0 'video engine invocation' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        -- 'https://example.com/watch?v=video'
    arguments=()
    read_arguments "${MOCK_ARG_LOG}" arguments
    assert_option_value arguments '--format' 'bv*+ba/b' 'video format selector'
    assert_option_value arguments '--merge-output-format' 'mkv' 'video merge container'
    assert_option_value arguments '--remux-video' 'mkv' 'video remux container'
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    video_aria2_arguments=()
    read_arguments "${MOCK_ARIA2_ARG_LOG}" video_aria2_arguments

    assert_array_contains video_aria2_arguments '--summary-interval=0' \
        'ordinary CLI aria2 summary interval'
    assert_array_not_contains video_aria2_arguments \
        '--show-console-readout=true' \
        'ordinary CLI aria2 console progress remains disabled'
    assert_text_not_contains "$(printf '%s\n' "${arguments[@]}")" \
        '--show-console-readout=true' 'machine progress disabled in ordinary CLI mode'

    # video-engine succeeds immediately before this validation scenario
    # and leaves its committed direct-transfer artifact in the shared mock
    # output directory. Remove only that completed artifact so the next run
    # can reach its intended FFprobe missing-audio validation.
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'video-missing-audio-validation'
    assert_status 65 'complete-video mode rejects a result without audio' \
        env MOCK_FFPROBE_MISSING_AUDIO=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        -- 'https://example.com/watch?v=video-without-audio'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media file failed FFprobe validation' \
        'missing-audio validation diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: missing-audio' \
        'missing-audio bounded reason'

    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'video-cover-art-only-validation'
    assert_status 65 'complete-video mode rejects audio plus attached cover art' \
        env MOCK_FFPROBE_COVER_ART_ONLY=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        -- 'https://example.com/watch?v=video-cover-art-only'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media file failed FFprobe validation' \
        'cover-art-only validation diagnostic'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    existing_audio_path="${OUTPUT_DIR}/Mock media [abc123].webm"
    printf '%s\n' 'preserve existing audio result' >"${existing_audio_path}"
    prepare_argument_log 'existing-media-no-overwrite'
    assert_status 1 'engine refuses to overwrite an existing final media file' \
        env MOCK_ENFORCE_NO_OVERWRITE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=existing-media'
    assert_file_has_line "${existing_audio_path}" 'preserve existing audio result' \
        'existing final media is preserved'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Destination: Mock media [abc123].webm' \
        'existing media collision helper diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media destination already exists; refusing to overwrite it.' \
        'existing media collision engine diagnostic'
    [[ ! -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'Existing media collision started an unnecessary aria2 transfer.'
    rm -f -- "${existing_audio_path}"
}

test_mock_engine_youtube_hls() {
    local hls_collision_result hls_existing_target hls_mkv_source_ffmpeg_args
    local hls_hardlink_fallback_result
    local hls_mkv_source_result hls_publish_collision_result
    local hls_publish_replacement_result hls_temp_replacement_result
    local oversized_hls_duration youtube_hls_failed_result
    local youtube_hls_ffmpeg_args youtube_hls_final_duration_result
    local youtube_hls_result youtube_hls_source_duration_result
    local -a youtube_hls_arguments youtube_hls_ffmpeg_arguments
    local -a hls_publish_collision_temps hls_publish_replacement_temps
    local -a hls_temp_replacement_temps
    local -a youtube_hls_path_files

    # Scenario: authenticated YouTube HLS profile.
    prepare_argument_log 'youtube-hls-engine'
    youtube_hls_result="${TEST_ROOT}/youtube-hls-result.txt"
    youtube_hls_ffmpeg_args="${TEST_ROOT}/youtube-hls-ffmpeg-args.bin"
    assert_status 0 'authenticated YouTube HLS engine invocation' \
        env MOCK_FFMPEG_ARG_LOG="${youtube_hls_ffmpeg_args}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox --machine-progress \
        --result-file "${youtube_hls_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls'
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    youtube_hls_arguments=()
    read_arguments "${MOCK_ARG_LOG}" youtube_hls_arguments
    assert_option_value youtube_hls_arguments '--cookies-from-browser' 'firefox' \
        'YouTube HLS Firefox cookies'
    assert_option_value youtube_hls_arguments '--extractor-args' \
        'youtube:player_client=web_safari' 'YouTube HLS player client'
    assert_array_not_contains youtube_hls_arguments '--remote-components' \
        'YouTube HLS uses bundled EJS instead of remote components'
    assert_option_value youtube_hls_arguments '--format' \
        '(bv*+ba/b)[protocol^=m3u8]' 'YouTube HLS format selector'
    assert_option_value youtube_hls_arguments '--fixup' 'force' \
        'YouTube HLS MPEG-TS fixup policy'
    assert_option_value youtube_hls_arguments '--downloader' 'dash,m3u8:native' \
        'YouTube HLS native downloader'
    assert_array_not_contains youtube_hls_arguments '--remux-video' \
        'yt-dlp remux is deferred until after HLS fixup'
    assert_array_not_contains youtube_hls_arguments '--merge-output-format' \
        'YouTube HLS combined stream does not request an early merge'
    assert_file_has_line "${youtube_hls_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'YouTube HLS result publishes the final MKV path'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'YTDLP_POSTPROCESS|finished|FFmpegVideoRemuxer' \
        'YouTube HLS remux emits a finished machine record'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].mkv" ]] \
        || fail 'The custom YouTube HLS remux did not create the MKV file.'
    [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] \
        || fail 'The repaired YouTube HLS MP4 intermediate was not removed.'
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    youtube_hls_ffmpeg_arguments=()
    read_arguments "${youtube_hls_ffmpeg_args}" youtube_hls_ffmpeg_arguments
    assert_option_value youtube_hls_ffmpeg_arguments '-c' 'copy' \
        'YouTube HLS final remux uses stream copy'
    assert_array_contains youtube_hls_ffmpeg_arguments \
        "${OUTPUT_DIR}/Mock media [abc123].mp4" \
        'YouTube HLS remux reads the fixed MP4 intermediate'

    rm -f -- \
        "${youtube_hls_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv"
    hls_hardlink_fallback_result="${TEST_ROOT}/youtube-hls-hardlink-fallback.txt"
    prepare_argument_log 'youtube-hls-hardlink-fallback'
    assert_status 0 'YouTube HLS supports filesystems without hard links' \
        env MOCK_HLS_HARDLINK_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        --result-file "${hls_hardlink_fallback_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-hardlink-fallback'
    assert_file_has_line "${hls_hardlink_fallback_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'HLS hard-link fallback publishes the final path'
    assert_file_has_line "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'mock remuxed media payload' \
        'HLS hard-link fallback publishes the verified remux'
    rm -f -- \
        "${hls_hardlink_fallback_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv"

    hls_existing_target="${OUTPUT_DIR}/Mock media [abc123].mkv"
    printf 'preserve existing MKV\n' >"${hls_existing_target}"
    hls_collision_result="${TEST_ROOT}/youtube-hls-collision-result.txt"
    prepare_argument_log 'youtube-hls-existing-target'
    assert_status 1 'YouTube HLS refuses an existing MKV before transfer' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        --result-file "${hls_collision_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-collision'
    assert_file_has_line "${hls_existing_target}" 'preserve existing MKV' \
        'existing YouTube HLS MKV is preserved'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media destination already exists; refusing to overwrite it' \
        'existing YouTube HLS MKV diagnostic'
    [[ ! -e ${hls_collision_result} ]] \
        || fail 'An HLS target collision published a result file.'
    [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mp4" && ! -s ${MOCK_POST_CALL_LOG} ]] \
        || fail 'An HLS target collision started a transfer before admission.'
    rm -f -- "${hls_existing_target}" "${OUTPUT_DIR}/Mock media [abc123].mp4"

    # yt-dlp can already expose the repaired HLS artifact with an MKV suffix.
    # Publish the verified remux under a distinct no-clobber name: shell `mv`
    # cannot atomically replace a path only when its inode still matches.
    prepare_argument_log 'youtube-hls-mkv-source'
    hls_mkv_source_result="${TEST_ROOT}/youtube-hls-mkv-source-result.txt"
    hls_mkv_source_ffmpeg_args="${TEST_ROOT}/youtube-hls-mkv-source-ffmpeg.bin"
    assert_status 0 'YouTube HLS remux accepts a transaction-owned MKV source' \
        env MOCK_YOUTUBE_HLS_SOURCE_EXT=mkv \
        MOCK_FFMPEG_ARG_LOG="${hls_mkv_source_ffmpeg_args}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        --result-file "${hls_mkv_source_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-mkv-source'
    assert_file_has_line "${hls_mkv_source_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].remuxed.mkv" \
        'transaction-owned MKV source result path'
    assert_file_has_line "${OUTPUT_DIR}/Mock media [abc123].remuxed.mkv" \
        'mock remuxed media payload' \
        'transaction-owned MKV source publishes a verified remux'
    [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mkv" ]] \
        || fail 'Validated transaction-owned MKV source was not removed.'
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    youtube_hls_ffmpeg_arguments=()
    read_arguments \
        "${hls_mkv_source_ffmpeg_args}" youtube_hls_ffmpeg_arguments
    assert_array_contains youtube_hls_ffmpeg_arguments \
        "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'YouTube HLS remux reads the transaction-owned MKV source'
    rm -f -- \
        "${hls_mkv_source_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].remuxed.mkv"

    # GNU mv -n reports success when a target appears during publication while
    # leaving the source in place. Preserve that already-verified remux instead
    # of deleting it from EXIT cleanup.
    prepare_argument_log 'youtube-hls-publication-race'
    hls_publish_collision_result="${TEST_ROOT}/youtube-hls-publication-race-result.txt"
    assert_status 13 'YouTube HLS publication race preserves the verified remux' \
        env MOCK_HLS_PUBLISH_COLLISION=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        --result-file "${hls_publish_collision_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-publication-race'
    assert_file_has_line "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'preserve racing MKV destination' \
        'racing YouTube HLS destination is not overwritten'
    shopt -s nullglob
    hls_publish_collision_temps=(
        "${OUTPUT_DIR}"/.yt-dlp-retained-remux.*.mkv
    )
    shopt -u nullglob
    assert_equals '1' "${#hls_publish_collision_temps[@]}" \
        'publication race retains one verified remux'
    assert_text_contains "${ASSERT_OUTPUT}" \
        "The verified remuxed MKV was retained at: ${hls_publish_collision_temps[0]}" \
        'publication race reports the retained remux path'
    touch -d '2 days ago' -- "${hls_publish_collision_temps[0]}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mkv"
    prepare_argument_log 'retained-hls-remux-survives-next-session'
    assert_status 0 'explicitly retained HLS remux survives the next session' \
        env MOCK_MEDIA_BASENAME='Independent media [def456]' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=retained-hls-remux'
    [[ -f ${hls_publish_collision_temps[0]} ]] \
        || fail 'A later session deleted an explicitly retained HLS remux.'
    [[ ! -e ${hls_publish_collision_result} ]] \
        || fail 'An HLS publication race published a result file.'
    rm -f -- \
        "${hls_publish_collision_result}" \
        "${hls_publish_collision_temps[@]}" \
        "${OUTPUT_DIR}/Independent media [def456].webm" \
        "${OUTPUT_DIR}/Mock media [abc123].webm" \
        "${OUTPUT_DIR}/Mock media [abc123].mp4" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv"

    # Mutation test: FFmpeg success cannot authorize a replacement inode for
    # validation, preservation, publication, or EXIT cleanup.
    prepare_argument_log 'youtube-hls-remux-temp-replacement'
    hls_temp_replacement_result="${TEST_ROOT}/youtube-hls-temp-replacement-result.txt"
    assert_status 13 'YouTube HLS rejects a replaced temporary remux inode' \
        env MOCK_REPLACE_HLS_REMUX_AFTER_WRITE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        --result-file "${hls_temp_replacement_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-temp-replacement'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'temporary HLS remux changed while FFmpeg was running' \
        'temporary HLS remux identity diagnostic'
    shopt -s nullglob
    hls_temp_replacement_temps=("${OUTPUT_DIR}"/.yt-dlp-remux.*.mkv)
    shopt -u nullglob
    assert_equals 1 "${#hls_temp_replacement_temps[@]}" \
        'one changed temporary HLS remux is preserved'
    assert_file_has_line "${hls_temp_replacement_temps[0]}" \
        'foreign HLS remux replacement' \
        'changed temporary HLS remux inode survives cleanup'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] \
        || fail 'Temporary remux replacement did not preserve the HLS source.'
    [[ ! -e ${hls_temp_replacement_result} ]] \
        || fail 'Temporary remux replacement published a result file.'
    rm -f -- \
        "${hls_temp_replacement_temps[@]}" \
        "${OUTPUT_DIR}/Mock media [abc123].mp4"

    # Mutation test: replace the temporary pathname after its descriptor has
    # been authenticated. Descriptor-linked publication must still select the
    # verified inode and must leave the injected replacement untouched.
    prepare_argument_log 'youtube-hls-remux-publication-replacement'
    hls_publish_replacement_result="${TEST_ROOT}/youtube-hls-publish-replacement-result.txt"
    assert_status 0 'YouTube HLS publishes the descriptor-bound remux inode' \
        env MOCK_REPLACE_HLS_REMUX_DURING_PUBLISH=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        --result-file "${hls_publish_replacement_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-publish-replacement'
    assert_file_has_line "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'mock remuxed media payload' \
        'descriptor-bound publication keeps the verified HLS remux inode'
    assert_file_has_line "${hls_publish_replacement_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv" \
        'descriptor-bound publication result path'
    shopt -s nullglob
    hls_publish_replacement_temps=("${OUTPUT_DIR}"/.yt-dlp-remux.*.mkv)
    shopt -u nullglob
    assert_equals 1 "${#hls_publish_replacement_temps[@]}" \
        'publication replacement remains under its injected temporary name'
    assert_file_has_line "${hls_publish_replacement_temps[0]}" \
        'foreign HLS publication replacement' \
        'publication does not move or remove the injected replacement'
    [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] \
        || fail 'Successful descriptor-bound publication retained the HLS source.'
    rm -f -- \
        "${hls_publish_replacement_result}" \
        "${hls_publish_replacement_temps[@]}" \
        "${OUTPUT_DIR}/Mock media [abc123].mkv"

    # 2^64+1 seconds must be rejected before Bash arithmetic. Converting first
    # wraps this value to 1 on a typical 64-bit shell and can turn an absurd
    # source duration into a plausible one-second value.
    for oversized_hls_duration in \
        '18446744073709551617.000000' \
        '0000000000000000000018446744073709551617.000000'; do
        prepare_argument_log "youtube-hls-duration-overflow-${oversized_hls_duration//[^[:alnum:]]/_}"
        oversized_duration_result="${TEST_ROOT}/youtube-hls-duration-overflow.result"
        rm -f -- "${oversized_duration_result}" \
            "${OUTPUT_DIR}/Mock media [abc123].mp4" \
            "${OUTPUT_DIR}/Mock media [abc123].mkv"
        assert_status 65 'oversized HLS source duration is rejected before arithmetic' \
            env MOCK_FFPROBE_DURATION="${oversized_hls_duration}" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" --mode video \
            --youtube-hls-firefox --machine-progress \
            --result-file "${oversized_duration_result}" \
            -- 'https://www.youtube.com/watch?v=youtube-hls-duration-overflow'
        assert_text_contains "${ASSERT_OUTPUT}" \
            'unable to determine the repaired HLS source duration' \
            'oversized HLS duration diagnostic'
        [[ ! -e ${oversized_duration_result} ]] \
            || fail 'Oversized HLS duration published a result file.'
        [[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] \
            || fail 'Oversized HLS duration did not retain the repaired source.'
        [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mkv" ]] \
            || fail 'Oversized HLS duration published an MKV.'
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mp4"
    done

    prepare_argument_log 'youtube-hls-source-duration-missing'
    youtube_hls_source_duration_result="${TEST_ROOT}/youtube-hls-source-duration-result.txt"
    rm -f -- "${youtube_hls_source_duration_result}"
    assert_status 65 'YouTube HLS refuses a remux with an unknown source duration' env MOCK_FFPROBE_DURATION_EMPTY=1 "${PROJECT_DIR}/download-video.sh" --output-dir "${OUTPUT_DIR}" --mode video --youtube-hls-firefox --machine-progress --result-file "${youtube_hls_source_duration_result}" -- 'https://www.youtube.com/watch?v=youtube-hls-source-duration'
    assert_text_contains "${ASSERT_OUTPUT}" 'unable to determine the repaired HLS source duration' 'unknown HLS source duration diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" 'YTDLP_POSTPROCESS|error|FFmpegVideoRemuxer' 'unknown HLS source duration machine error'
    [[ ! -e ${youtube_hls_source_duration_result} ]] || fail 'Unknown HLS source duration published a result file.'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] || fail 'Unknown HLS source duration did not retain the repaired MP4.'
    [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mkv" ]] || fail 'Unknown HLS source duration published an MKV.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mp4"

    prepare_argument_log 'youtube-hls-final-duration-missing'
    youtube_hls_final_duration_result="${TEST_ROOT}/youtube-hls-final-duration-result.txt"
    rm -f -- "${youtube_hls_final_duration_result}"
    assert_status 65 'YouTube HLS refuses an MKV with an unknown remuxed duration' env MOCK_FFPROBE_MKV_DURATION_EMPTY=1 "${PROJECT_DIR}/download-video.sh" --output-dir "${OUTPUT_DIR}" --mode video --youtube-hls-firefox --machine-progress --result-file "${youtube_hls_final_duration_result}" -- 'https://www.youtube.com/watch?v=youtube-hls-final-duration'
    assert_text_contains "${ASSERT_OUTPUT}" 'unable to determine the remuxed MKV duration' 'unknown remuxed MKV duration diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" 'YTDLP_POSTPROCESS|error|FFmpegVideoRemuxer' 'unknown remuxed MKV duration machine error'
    [[ ! -e ${youtube_hls_final_duration_result} ]] || fail 'Unknown remuxed MKV duration published a result file.'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] || fail 'Unknown remuxed MKV duration did not retain the repaired MP4.'
    [[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mkv" ]] || fail 'Unknown remuxed MKV duration published a final MKV.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mp4"

    prepare_argument_log 'youtube-hls-remux-failure'
    youtube_hls_failed_result="${TEST_ROOT}/youtube-hls-failed-result.txt"
    assert_status 9 'YouTube HLS remux failure is propagated' \
        env MOCK_FFMPEG_EXIT_STATUS=9 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox --machine-progress \
        --result-file "${youtube_hls_failed_result}" \
        -- 'https://www.youtube.com/watch?v=youtube-hls-failure'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'YTDLP_POSTPROCESS|error|FFmpegVideoRemuxer' \
        'YouTube HLS remux failure emits an error machine record'
    [[ ! -e ${youtube_hls_failed_result} ]] \
        || fail 'A failed YouTube HLS remux published a result file.'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] \
        || fail 'A failed YouTube HLS remux did not preserve the fixed MP4 intermediate.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mp4"

    prepare_argument_log 'youtube-hls-cli-no-result'
    assert_status 0 'YouTube HLS CLI invocation without a result file' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --youtube-hls-firefox \
        -- 'https://www.youtube.com/watch?v=youtube-hls-no-result'
    shopt -s nullglob
    youtube_hls_path_files=("${OUTPUT_DIR}"/.yt-dlp-path.*)
    shopt -u nullglob
    ((${#youtube_hls_path_files[@]} == 0)) \
        || fail 'The YouTube HLS CLI run left an internal result-path file.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mkv"

    assert_status 2 'YouTube HLS profile rejects audio mode' \
        "${PROJECT_DIR}/download-video.sh" \
        --mode audio --youtube-hls-firefox \
        -- 'https://www.youtube.com/watch?v=youtube-audio'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '--youtube-hls-firefox is available only with --mode video.' \
        'YouTube HLS audio-mode diagnostic'

    assert_status 2 'YouTube HLS profile rejects non-YouTube URLs' \
        "${PROJECT_DIR}/download-video.sh" \
        --mode video --youtube-hls-firefox \
        -- 'https://example.com/video'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '--youtube-hls-firefox requires a YouTube URL.' \
        'YouTube HLS URL diagnostic'
}

test_mock_engine_failure_paths() {
    local atomic_result_file existing_result_file held_lock_fd
    local lock_file lock_key lock_root
    local result_hardlink_fallback_file
    local replaced_result_file replaced_result_record replaced_result_record_path
    local unsafe_output_dir unsafe_output_parent
    local unsafe_result_parent
    local unsafe_runtime_dir unsafe_runtime_parent

    # Scenario group: engine failures before yt-dlp invocation.
    prepare_argument_log 'invalid-output'
    assert_status 1 'nonexistent output directory is rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${TEST_ROOT}/does-not-exist" \
        -- 'https://example.com/watch?v=bad-output'
    assert_text_contains "${ASSERT_OUTPUT}" 'destination directory does not exist' \
        'nonexistent output diagnostic'

    unsafe_output_parent="${TEST_ROOT}/unsafe-output-parent"
    unsafe_output_dir="${unsafe_output_parent}/destination"
    mkdir -p -- "${unsafe_output_dir}"
    chmod 0777 -- "${unsafe_output_parent}"
    chmod 0700 -- "${unsafe_output_dir}"
    prepare_argument_log 'shared-output-local-staging'
    assert_status 0 'shared non-sticky output ancestor uses local media staging' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${unsafe_output_dir}" \
        -- 'https://example.com/watch?v=unsafe-output-parent'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'requires local disk staging' \
        'shared output ancestor explicitly reports local media staging'
    [[ -s ${unsafe_output_dir}/'Mock media [abc123].webm' ]] \
        || fail 'Shared output ancestor did not receive the completed media.'
    rm -rf -- "${unsafe_output_parent}"

    unsafe_runtime_parent="${TEST_ROOT}/unsafe-runtime-parent"
    unsafe_runtime_dir="${unsafe_runtime_parent}/runtime"
    mkdir -p -- "${unsafe_runtime_dir}"
    chmod 0777 -- "${unsafe_runtime_parent}"
    chmod 0700 -- "${unsafe_runtime_dir}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    prepare_argument_log 'unsafe-runtime-fallback'
    assert_status 0 'unsafe XDG runtime ancestor uses the private /tmp fallback' \
        env XDG_RUNTIME_DIR="${unsafe_runtime_dir}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        -- 'https://example.com/watch?v=unsafe-runtime-parent'
    assert_directory_empty "${unsafe_runtime_dir}" \
        'unsafe XDG runtime directory receives no private engine state'
    rm -rf -- "${unsafe_runtime_parent}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    assert_status 13 'missing result-file parent is rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --result-file "${TEST_ROOT}/missing-parent/result.txt" \
        -- 'https://example.com/watch?v=bad-result-parent'
    assert_text_contains "${ASSERT_OUTPUT}" 'result-file directory is not writable' \
        'missing result parent diagnostic'

    unsafe_result_parent="${TEST_ROOT}/unsafe-result-parent"
    mkdir -p -- "${unsafe_result_parent}"
    chmod 0777 -- "${unsafe_result_parent}"
    assert_status 13 'shared non-sticky result-file ancestor is rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --result-file "${unsafe_result_parent}/result.txt" \
        -- 'https://example.com/watch?v=unsafe-result-parent'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'result-file directory or one of its ancestors is unsafe' \
        'unsafe result-file ancestor diagnostic'
    assert_directory_empty "${unsafe_result_parent}" \
        'unsafe result-file ancestor creates no private record'
    chmod 0700 -- "${unsafe_result_parent}"
    rmdir -- "${unsafe_result_parent}"

    assert_status 2 'result-file line breaks are rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --result-file "${TEST_ROOT}/bad"$'\n'"result.txt" \
        -- 'https://example.com/watch?v=bad-result-linebreak'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'result-file path must not contain line breaks' \
        'result-file line-break diagnostic'

    existing_result_file="${TEST_ROOT}/existing-result.txt"
    printf 'preserve this result\n' >"${existing_result_file}"
    prepare_argument_log 'existing-result-refusal'
    assert_status 13 'an existing result file is never overwritten' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --result-file "${existing_result_file}" \
        -- 'https://example.com/watch?v=existing-result'
    assert_file_has_line "${existing_result_file}" 'preserve this result' \
        'existing result content is preserved'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'result-file already exists; refusing to overwrite it' \
        'existing result refusal diagnostic'

    atomic_result_file="${TEST_ROOT}/atomic-result.txt"
    prepare_argument_log 'atomic-result-failure'
    assert_status 7 'failed engine run does not publish a result path' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_YTDLP_EXIT_STATUS=7 \
        MOCK_WRITE_RESULT_BEFORE_FAILURE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --result-file "${atomic_result_file}" \
        -- 'https://example.com/watch?v=atomic-result'
    [[ ! -e ${atomic_result_file} ]] \
        || fail 'A failed engine run published a stale or partial result file.'

    result_hardlink_fallback_file="${TEST_ROOT}/result-hardlink-fallback.txt"
    prepare_argument_log 'result-hardlink-fallback'
    assert_status 0 'result publication supports filesystems without hard links' \
        env MOCK_RESULT_HARDLINK_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${result_hardlink_fallback_file}" \
        -- 'https://example.com/watch?v=result-hardlink-fallback'
    assert_file_has_line "${result_hardlink_fallback_file}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm" \
        'result hard-link fallback publishes the verified path record'
    rm -f -- \
        "${result_hardlink_fallback_file}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"

    # Mutation test: replace the temporary record after yt-dlp has written it.
    # The descriptor-bound record remains authoritative for normalization,
    # validation, and no-clobber publication; the foreign pathname is preserved.
    replaced_result_file="${TEST_ROOT}/replaced-result-record.txt"
    replaced_result_record="${TEST_ROOT}/replaced-result-record-path.txt"
    prepare_argument_log 'replaced-result-record'
    assert_status 13 'an unlinked authenticated result inode fails closed' \
        env MOCK_REPLACE_RESULT_RECORD_AFTER_WRITE=1 \
        MOCK_REPLACED_RESULT_RECORD_PATH="${replaced_result_record}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${replaced_result_file}" \
        -- 'https://example.com/watch?v=replaced-result-record'
    [[ ! -e ${replaced_result_file} && ! -L ${replaced_result_file} ]] \
        || fail 'A replacement temporary record reached the public result path.'
    replaced_result_record_path=$(<"${replaced_result_record}")
    assert_file_has_line "${replaced_result_record_path}" \
        'foreign result-record replacement' \
        'foreign temporary result-record replacement is preserved'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'preserving a changed temporary path record' \
        'changed temporary result-record diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'private result-path pathname changed during publication' \
        'unlinked authenticated result-record refusal diagnostic'
    rm -f -- \
        "${replaced_result_file}" \
        "${replaced_result_record}" \
        "${replaced_result_record_path}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'aria2-producer-status'
    assert_status 29 'aria2 pipeline preserves the transport status' \
        env LC_ALL=C.utf8 MOCK_ARIA2_EXIT_STATUS=29 \
        MOCK_ARIA2_INVALID_UTF8_DIAGNOSTIC=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=aria2-producer-status'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Download failed with exit code 29.' \
        'aria2 producer status diagnostic'
    assert_text_not_contains "${ASSERT_OUTPUT}" \
        'https://secret.example/private' \
        'aria2 producer diagnostic remains redacted'
    assert_text_not_contains "${ASSERT_OUTPUT}" 'private-suffix-token' \
        'malformed UTF-8 cannot leave a private URL suffix unredacted'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Malformed diagnostic URL: [REDACTED_URL]' \
        'malformed UTF-8 URL is redacted under the inherited UTF-8 locale'
    assert_text_not_contains "${ASSERT_OUTPUT}" 'CaseSensitive' \
        'aria2 diagnostics redact every supported HTTP scheme casing'

    prepare_argument_log 'pipeline-redactor-status'
    assert_status 75 'a successful producer does not mask redactor failure' \
        env MOCK_PIPELINE_REDACTOR_FAILURE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=pipeline-redactor-status'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'format planning with exit code 75' \
        'redactor failure status diagnostic'

    prepare_argument_log 'pipeline-redactor-priority'
    assert_status 75 'redactor failure remains fatal when the producer also fails' \
        env MOCK_PLAN_EXIT_STATUS=23 MOCK_PIPELINE_REDACTOR_FAILURE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=pipeline-redactor-priority'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'format planning with exit code 75' \
        'redactor failure is not masked by a producer failure'

    # A second engine instance targeting the same canonical destination must fail
    # before yt-dlp can manipulate shared .part, merge, or remux files.
    # Destination locks are shared across all runtime-directory environments.
    lock_root="/tmp/yt-dlp-aria2-downloader-${EUID}"
    mkdir -p -- "${lock_root}"
    chmod 700 -- "${lock_root}"
    lock_key=$(printf '%s\0' "${OUTPUT_DIR}" | sha256sum)
    lock_key=${lock_key%% *}
    lock_file="${lock_root}/${lock_key}.lock"
    exec {held_lock_fd}>>"${lock_file}"
    chmod 600 -- "${lock_file}"
    flock --exclusive --nonblock "${held_lock_fd}"
    prepare_argument_log 'concurrent-output-lock'
    assert_status 75 'a concurrent writer to the same output directory is rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        -- 'https://example.com/watch?v=concurrent-output-lock'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'another download is already using the destination directory:' \
        'concurrent output lock diagnostic'
    assert_status 75 'the destination lock also excludes launches without XDG' \
        env -u XDG_RUNTIME_DIR \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=concurrent-output-lock-no-xdg'
    mkdir -m 700 -- "${TEST_ROOT}/alternate-runtime"
    assert_status 75 'the destination lock excludes another valid XDG root' \
        env XDG_RUNTIME_DIR="${TEST_ROOT}/alternate-runtime" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=concurrent-output-lock-other-xdg'
    flock --unlock "${held_lock_fd}"
    exec {held_lock_fd}>&-
}

mock_private_metadata_directory() {
    local argument previous=''
    local -a arguments=()
    mapfile -d '' -t arguments <"${MOCK_PLAN_ARG_LOG}"
    for argument in "${arguments[@]}"; do
        if [[ ${previous} == --cookies ]]; then
            printf '%s\n' "${argument%/*}"
            return 0
        fi
        previous=${argument}
    done
    return 1
}

test_mock_engine_private_staging() {
    local active_file_log active_file_pid active_file_plan active_file_replacement
    local active_file_result active_file_staging active_file_started
    local active_file_status active_file_termination_marker
    local ambiguous_marked attempt candidate candidate_ambiguous candidate_pgid
    local candidate_pid crash_log crash_pgid crash_pid crash_result crash_metadata
    local crash_staging crash_started crash_started_seen cross_candidate
    local invalid_mode legacy_exact other_output owned_staging_leftover
    local replacement_log replacement_original replacement_pid
    local replacement_result replacement_staging replacement_started
    local replacement_status replacement_termination_marker
    local successful_mutation_diagnostic successful_mutation_file
    local successful_mutation_name
    local successful_mutation_staging successful_mutation_variable
    local -a successful_mutation_cases=(input manifest)
    local sticky_output_dir sticky_output_parent sticky_staging_leftover
    local staging_symlink_target symlink_candidate test_pgid
    local successful_mode

    # A root- or current-user-owned sticky shared ancestor protects private
    # children from other UIDs and must remain a supported destination shape.
    sticky_output_parent="${TEST_ROOT}/sticky-output-parent"
    sticky_output_dir="${sticky_output_parent}/destination"
    mkdir -p -- "${sticky_output_dir}"
    chmod 1777 -- "${sticky_output_parent}"
    chmod 0700 -- "${sticky_output_dir}"
    prepare_argument_log 'private-staging-sticky-output-parent'
    assert_status 0 'sticky shared output ancestor permits private staging' \
        env MOCK_OUTPUT_DIR="${sticky_output_dir}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${sticky_output_dir}" \
        --mode audio \
        -- 'https://example.com/watch?v=sticky-output-parent'
    sticky_staging_leftover=$(find "${sticky_output_dir}" \
        -mindepth 1 -maxdepth 1 -type d \
        -name '.yt-dlp-aria2.????????' -print -quit 2>/dev/null)
    [[ -z ${sticky_staging_leftover} ]] \
        || fail 'Sticky shared output ancestor retained private staging.'
    rm -rf -- "${sticky_output_parent}"

    # Regression guard: active private staging cleanup must not follow a
    # pathname that has been replaced by a different filesystem object.
    replacement_started="${TEST_ROOT}/private-staging-replacement-started"
    replacement_result="${TEST_ROOT}/private-staging-replacement-result.txt"
    replacement_log="${TEST_ROOT}/private-staging-replacement.log"
    replacement_original="${TEST_ROOT}/private-staging-original"
    replacement_termination_marker="${TEST_ROOT}/private-staging-replacement-terminated"

    rm -f -- \
        "${replacement_started}" \
        "${replacement_result}" \
        "${replacement_log}" \
        "${replacement_termination_marker}"
    rm -rf -- "${replacement_original}"

    prepare_argument_log 'private-staging-active-replacement'

    env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_LONG_DOWNLOAD=1 \
        MOCK_STARTED_MARKER="${replacement_started}" \
        MOCK_TERMINATION_MARKER="${replacement_termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        --result-file "${replacement_result}" \
        -- 'https://example.com/watch?v=private-staging-active-replacement' \
        >"${replacement_log}" 2>&1 &
    replacement_pid=$!

    wait_for_file "${replacement_started}" 10 \
        'private staging replacement worker startup'

    replacement_staging=''
    for ((attempt = 0; attempt < 100; attempt++)); do
        replacement_staging=$(find "${OUTPUT_DIR}" \
            -mindepth 1 -maxdepth 1 -type d \
            -name '.yt-dlp-aria2.????????' -print -quit 2>/dev/null || true)
        [[ -n ${replacement_staging} ]] && break
        sleep 0.05
    done

    [[ -n ${replacement_staging} && -d ${replacement_staging} ]] \
        || fail 'Replacement scenario did not create private aria2 staging.'
    [[ -f ${replacement_staging}/.yt-dlp-aria2-owner-v1 ]] \
        || fail 'Replacement scenario staging ownership marker is missing.'

    # Move the transaction-owned directory away and create a different
    # directory at exactly the pathname retained by PRIVATE_ARIA2_STAGING.
    mv -- "${replacement_staging}" "${replacement_original}"

    mkdir -- "${replacement_staging}"
    chmod 700 -- "${replacement_staging}"

    printf '%s\n' 'yt-dlp-aria2-private-staging-v1' \
        >"${replacement_staging}/.yt-dlp-aria2-owner-v1"
    printf '%s\n' 'foreign replacement must survive active cleanup' \
        >"${replacement_staging}/foreign-sentinel"

    chmod 600 -- \
        "${replacement_staging}/.yt-dlp-aria2-owner-v1" \
        "${replacement_staging}/foreign-sentinel"

    # TERM drives the real engine shutdown/EXIT cleanup path. The worker was
    # synchronized above; no timing window or arbitrary production sleep is
    # required to reproduce the replacement condition.
    kill -TERM -- "${replacement_pid}" 2>/dev/null \
        || fail 'Unable to terminate private staging replacement worker.'

    replacement_status=0
    wait "${replacement_pid}" 2>/dev/null || replacement_status=$?

    assert_equals '143' "${replacement_status}" \
        'private staging replacement TERM exit status'
    wait_for_file "${replacement_termination_marker}" 10 \
        'private staging replacement worker receives TERM'
    assert_no_test_processes \
        'private staging replacement left worker processes'

    [[ -f ${replacement_staging}/foreign-sentinel ]] \
        || fail 'Active cleanup deleted the foreign replacement staging directory.'
    [[ -d ${replacement_original} ]] \
        || fail 'Active cleanup unexpectedly followed the moved original staging.'

    assert_file_contains "${replacement_log}" \
        'preserving ambiguous active private aria2 staging directory' \
        'active staging replacement preservation diagnostic'

    rm -rf -- \
        "${replacement_staging}" \
        "${replacement_original}"
    rm -f -- \
        "${replacement_started}" \
        "${replacement_result}" \
        "${replacement_log}" \
        "${replacement_termination_marker}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"

    # Replacing one identity-bound sensitive file inside the original staging
    # must preserve that replacement while still removing the remaining secret
    # metadata. Structural allowlisting alone must not erase the foreign inode.
    active_file_started="${TEST_ROOT}/private-staging-file-replacement-started"
    active_file_result="${TEST_ROOT}/private-staging-file-replacement-result.txt"
    active_file_log="${TEST_ROOT}/private-staging-file-replacement.log"
    active_file_termination_marker="${TEST_ROOT}/private-staging-file-replacement-terminated"
    rm -f -- \
        "${active_file_started}" \
        "${active_file_result}" \
        "${active_file_log}" \
        "${active_file_termination_marker}"

    prepare_argument_log 'private-staging-active-file-replacement'
    env MOCK_LONG_DOWNLOAD=1 \
        MOCK_STARTED_MARKER="${active_file_started}" \
        MOCK_TERMINATION_MARKER="${active_file_termination_marker}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        --result-file "${active_file_result}" \
        -- 'https://example.com/watch?v=private-staging-active-file-replacement' \
        >"${active_file_log}" 2>&1 &
    active_file_pid=$!

    wait_for_file "${active_file_started}" 10 \
        'private staging sensitive-file replacement worker startup'
    active_file_staging=''
    for ((attempt = 0; attempt < 100; attempt++)); do
        active_file_staging=$(mock_private_metadata_directory)
        [[ -n ${active_file_staging} ]] && break
        sleep 0.05
    done
    [[ -n ${active_file_staging} && -d ${active_file_staging} ]] \
        || fail 'Sensitive-file replacement staging was not created.'
    active_file_plan="${active_file_staging}/plan.json"
    [[ -f ${active_file_plan} && -f ${active_file_staging}/aria2.input &&
        -f ${active_file_staging}/manifest.json ]] \
        || fail 'Sensitive-file replacement metadata was not initialized.'

    active_file_replacement="${active_file_plan}.foreign-replacement"
    printf '%s\n' 'foreign allowlisted-name replacement must survive cleanup' \
        >"${active_file_replacement}"
    chmod 600 -- "${active_file_replacement}"
    mv -Tf -- "${active_file_replacement}" "${active_file_plan}"
    kill -TERM -- "${active_file_pid}" 2>/dev/null \
        || fail 'Unable to terminate sensitive-file replacement worker.'
    active_file_status=0
    wait "${active_file_pid}" 2>/dev/null || active_file_status=$?

    assert_equals '143' "${active_file_status}" \
        'private staging sensitive-file replacement TERM exit status'
    wait_for_file "${active_file_termination_marker}" 10 \
        'private staging sensitive-file replacement receives TERM'
    assert_file_contains "${active_file_plan}" \
        'foreign allowlisted-name replacement must survive cleanup' \
        'identity-changed private plan replacement'
    [[ ! -e ${active_file_staging}/cookies.txt &&
        ! -e ${active_file_staging}/aria2.input &&
        ! -e ${active_file_staging}/manifest.json ]] \
        || fail 'Sensitive-file replacement cleanup retained transaction secrets.'
    assert_file_contains "${active_file_log}" \
        'preserving ambiguous private aria2 authentication metadata' \
        'sensitive-file replacement preservation diagnostic'
    assert_no_test_processes \
        'private staging sensitive-file replacement left worker processes'
    rm -rf -- "${active_file_staging}"
    rm -f -- \
        "${active_file_started}" \
        "${active_file_result}" \
        "${active_file_log}" \
        "${active_file_termination_marker}"

    # Mutation tests: even after aria2 and commit report success, cleanup may
    # remove only the exact sensitive inode recorded at creation time.
    for successful_mutation_name in "${successful_mutation_cases[@]}"; do
        case ${successful_mutation_name} in
            input)
                successful_mutation_variable=MOCK_REPLACE_ARIA2_INPUT_BEFORE_EXIT
                successful_mutation_file=aria2.input
                successful_mutation_diagnostic='unable to remove the private aria2 input file'
                ;;
            manifest)
                successful_mutation_variable=MOCK_REPLACE_ARIA2_MANIFEST_BEFORE_EXIT
                successful_mutation_file=manifest.json
                successful_mutation_diagnostic='unable to remove the private aria2 transfer manifest'
                ;;
            *) fail "Unknown successful mutation case: ${successful_mutation_name}" ;;
        esac
        prepare_argument_log \
            "private-staging-success-${successful_mutation_name}-replacement"
        assert_status 13 \
            "successful transfer preserves replaced aria2 ${successful_mutation_name}" \
            env "${successful_mutation_variable}=1" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" \
            --mode audio \
            -- "https://example.com/watch?v=successful-${successful_mutation_name}-replacement"
        assert_text_contains "${ASSERT_OUTPUT}" \
            "${successful_mutation_diagnostic}" \
            "replaced aria2 ${successful_mutation_name} removal diagnostic"
        successful_mutation_staging=$(mock_private_metadata_directory)
        [[ -n ${successful_mutation_staging} &&
            -f ${successful_mutation_staging}/${successful_mutation_file} ]] \
            || fail "Replaced aria2 ${successful_mutation_name} inode was removed."
        [[ ! -e ${successful_mutation_staging}/plan.json &&
            ! -e ${successful_mutation_staging}/cookies.txt ]] \
            || fail "Replaced aria2 ${successful_mutation_name} retained other secrets."
        assert_text_contains "${ASSERT_OUTPUT}" \
            'preserving ambiguous private aria2 authentication metadata' \
            "replaced aria2 ${successful_mutation_name} preservation diagnostic"
        rm -rf -- "${successful_mutation_staging}"
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    done

    # The conservative replacement protection must not turn ordinary owned
    # staging into a leak: a normal successful transaction still cleans it.
    for successful_mode in audio video; do
        prepare_argument_log "private-staging-normal-cleanup-${successful_mode}"
        assert_status 0 "owned active ${successful_mode} staging is cleaned normally" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" \
            --mode "${successful_mode}" \
            -- 'https://example.com/watch?v=private-staging-normal-cleanup'
        # The mock reports WEBM for both modes; real-tool qualification also
        # checks the actual audio extraction and video remux outputs.
        [[ -s ${OUTPUT_DIR}/'Mock media [abc123].webm' ]] \
            || fail "Successful ${successful_mode} transaction did not publish its final media."
        assert_text_not_contains "${ASSERT_OUTPUT}" 'preserving ambiguous' \
            "normal ${successful_mode} cleanup has no ambiguity"

        owned_staging_leftover=$(find "${OUTPUT_DIR}" \
            -mindepth 1 -maxdepth 1 \
            -name '.yt-dlp-aria2.*' -print -quit)
        [[ -z ${owned_staging_leftover} ]] \
            || fail 'A normal transaction left owned private aria2 staging behind.'

        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    done

    # SIGKILL cannot run cleanup. A later session must preserve all legacy
    # residues because familiar names and markers do not authenticate the
    # previous session's identities or prove its descendants have stopped.
    crash_started="${TEST_ROOT}/private-staging-crash-started"
    crash_result="${TEST_ROOT}/private-staging-crash-result.txt"
    crash_log="${TEST_ROOT}/private-staging-crash.log"
    rm -f -- "${crash_started}" "${crash_result}" "${crash_log}"
    prepare_argument_log 'private-staging-crash'

    setsid env \
        YTDLP_ARIA2_SUPERVISED_SESSION=true \
        MOCK_LONG_DOWNLOAD=1 \
        MOCK_STARTED_MARKER="${crash_started}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        --result-file "${crash_result}" \
        -- 'https://example.com/watch?v=private-staging-crash' \
        >"${crash_log}" 2>&1 &
    crash_pid=$!

    crash_started_seen=false
    for ((attempt = 0; attempt < 200; attempt++)); do
        if [[ -f ${crash_started} ]]; then
            crash_started_seen=true
            break
        fi
        sleep 0.05
    done
    [[ ${crash_started_seen} == true ]] \
        || fail 'Private staging crash worker did not start.'

    crash_staging=''
    for ((attempt = 0; attempt < 100; attempt++)); do
        crash_staging=$(find "${OUTPUT_DIR}" \
            -mindepth 1 -maxdepth 1 -type d \
            -name '.yt-dlp-aria2.????????' -print -quit 2>/dev/null || true)
        [[ -n ${crash_staging} ]] && break
        sleep 0.05
    done
    [[ -n ${crash_staging} && -d ${crash_staging} ]] \
        || fail 'Crash scenario did not create a private aria2 staging directory.'
    [[ -f ${crash_staging}/.yt-dlp-aria2-owner-v1 ]] \
        || fail 'Crash staging ownership marker is missing.'

    crash_metadata=$(mock_private_metadata_directory)
    wait_for_worker_registration_cleanup 5 \
        'Crash worker readiness cleanup'

    # Do not derive the process group immediately after `setsid ... &`.
    # Before util-linux setsid(1) has created the new session, the asynchronous
    # launcher can still temporarily belong to this test shell's process group.
    # Resolve the unique non-test PGID only after the worker has published its
    # started/staging markers, and refuse to signal an ambiguous or self PGID.
    test_pgid=$(ps -o pgid= -p "$$") \
        || fail 'Unable to determine the mock integration process group.'
    test_pgid=${test_pgid//[[:space:]]/}
    [[ ${test_pgid} =~ ^[1-9][0-9]*$ ]] \
        || fail "Invalid mock integration PGID: ${test_pgid}"

    crash_pgid=''
    for ((attempt = 0; attempt < 100; attempt++)); do
        find_test_processes
        candidate_pgid=''
        candidate_ambiguous=false

        for candidate_pid in "${TEST_PROCESS_PIDS[@]}"; do
            candidate=$(
                ps -o pgid= -p "${candidate_pid}" 2>/dev/null
            ) || continue
            candidate=${candidate//[[:space:]]/}
            [[ ${candidate} =~ ^[1-9][0-9]*$ ]] || continue
            [[ ${candidate} != "${test_pgid}" ]] || continue

            if [[ -z ${candidate_pgid} ]]; then
                candidate_pgid=${candidate}
            elif [[ ${candidate_pgid} != "${candidate}" ]]; then
                candidate_ambiguous=true
                break
            fi
        done

        if [[ ${candidate_ambiguous} == false && -n ${candidate_pgid} ]]; then
            crash_pgid=${candidate_pgid}
            break
        fi
        sleep 0.05
    done

    [[ ${crash_pgid} =~ ^[1-9][0-9]*$ ]] \
        || fail 'Unable to resolve the private-staging crash process group.'
    [[ ${crash_pgid} != "${test_pgid}" ]] \
        || fail 'Refusing to SIGKILL the mock integration process group.'

    kill -KILL -- "-${crash_pgid}" 2>/dev/null \
        || kill -KILL -- "${crash_pid}" 2>/dev/null \
        || true
    wait "${crash_pid}" 2>/dev/null || true
    sleep 0.2

    [[ -d ${crash_staging} ]] \
        || fail 'SIGKILL unexpectedly ran private staging cleanup.'
    [[ ! -e ${crash_result} ]] \
        || fail 'SIGKILL crash published a result-file.'

    legacy_exact="${OUTPUT_DIR}/.yt-dlp-aria2.LEGACY01"
    ambiguous_marked="${OUTPUT_DIR}/.yt-dlp-aria2.AMBIG001"
    invalid_mode="${OUTPUT_DIR}/.yt-dlp-aria2.BADMODE1"
    staging_symlink_target="${TEST_ROOT}/private-staging-symlink-target"
    symlink_candidate="${OUTPUT_DIR}/.yt-dlp-aria2.SYMLINK1"
    other_output="${TEST_ROOT}/private-staging-other-output"
    cross_candidate="${other_output}/.yt-dlp-aria2.CROSS001"

    mkdir -p -- "${legacy_exact}" "${ambiguous_marked}" \
        "${invalid_mode}" "${staging_symlink_target}" "${cross_candidate}"
    chmod 700 -- "${legacy_exact}" "${ambiguous_marked}" \
        "${staging_symlink_target}" "${other_output}" "${cross_candidate}"
    chmod 755 -- "${invalid_mode}"

    printf '%s\n' '{}' >"${legacy_exact}/plan.json"
    printf '%s\n' '# Netscape HTTP Cookie File' >"${legacy_exact}/cookies.txt"
    chmod 600 -- "${legacy_exact}/plan.json" "${legacy_exact}/cookies.txt"

    printf '%s\n' 'yt-dlp-aria2-private-staging-v1' \
        >"${ambiguous_marked}/.yt-dlp-aria2-owner-v1"
    printf '%s\n' '{"url":"https://secret.example/private"}' \
        >"${ambiguous_marked}/plan.json"
    printf '%s\n' '# Netscape HTTP Cookie File' \
        >"${ambiguous_marked}/cookies.txt"
    printf '%s\n' \
        'https://secret.example/signed?token=do-not-retain' \
        '  header=Authorization: Bearer do-not-retain' \
        >"${ambiguous_marked}/aria2.input"
    printf '%s\n' \
        '{"output_dir":"/private/output","items":[]}' \
        >"${ambiguous_marked}/manifest.json"
    printf '%s\n' 'foreign payload' >"${ambiguous_marked}/foreign.txt"
    chmod 600 -- \
        "${ambiguous_marked}/.yt-dlp-aria2-owner-v1" \
        "${ambiguous_marked}/plan.json" \
        "${ambiguous_marked}/cookies.txt" \
        "${ambiguous_marked}/aria2.input" \
        "${ambiguous_marked}/manifest.json" \
        "${ambiguous_marked}/foreign.txt"

    printf '%s\n' 'yt-dlp-aria2-private-staging-v1' \
        >"${invalid_mode}/.yt-dlp-aria2-owner-v1"
    chmod 600 -- "${invalid_mode}/.yt-dlp-aria2-owner-v1"

    printf '%s\n' 'target must survive' >"${staging_symlink_target}/sentinel"
    ln -s -- "${staging_symlink_target}" "${symlink_candidate}"

    printf '%s\n' 'yt-dlp-aria2-private-staging-v1' \
        >"${cross_candidate}/.yt-dlp-aria2-owner-v1"
    chmod 600 -- "${cross_candidate}/.yt-dlp-aria2-owner-v1"

    prepare_argument_log 'private-staging-crash-reservation'
    assert_status 75 'uncertain crash keeps conflicting media reserved' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=private-staging-crash'
    [[ ! -s ${MOCK_POST_CALL_LOG} && ! -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'An unconfirmed crash allowed another transfer into its resources.'

    prepare_argument_log 'private-staging-preservation'
    assert_status 0 'abandoned private staging preservation' \
        env MOCK_MEDIA_BASENAME='Independent media [def456]' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        -- 'https://example.com/watch?v=private-staging-preservation'

    [[ -d ${crash_staging} ]] \
        || fail 'A previous-session marker incorrectly authorized crash cleanup.'
    [[ -d ${legacy_exact} ]] \
        || fail 'Legacy filenames incorrectly authorized deletion.'
    [[ -d ${ambiguous_marked} ]] \
        || fail 'Ambiguous marked staging was deleted.'
    [[ -f ${ambiguous_marked}/plan.json &&
        -f ${ambiguous_marked}/cookies.txt &&
        -f ${ambiguous_marked}/aria2.input &&
        -f ${ambiguous_marked}/manifest.json ]] \
        || fail 'Unauthenticated previous-session metadata was deleted automatically.'
    [[ -f ${ambiguous_marked}/foreign.txt ]] \
        || fail 'Abandoned marked staging inspection removed an unknown artifact.'
    [[ -d ${invalid_mode} ]] \
        || fail 'Invalid-mode staging was deleted.'
    [[ -L ${symlink_candidate} && -f ${staging_symlink_target}/sentinel ]] \
        || fail 'Staging symlink or its target was modified.'
    [[ -d ${cross_candidate} ]] \
        || fail 'A different output directory was cleaned cross-destination.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'preserving legacy staging for manual inspection' \
        'ambiguous staging preservation diagnostic'

    rm -rf -- \
        "${crash_staging}" \
        "${crash_metadata}" \
        "${legacy_exact}" \
        "${ambiguous_marked}" \
        "${invalid_mode}" \
        "${symlink_candidate}" \
        "${staging_symlink_target}" \
        "${other_output}"
    rm -f -- "${OUTPUT_DIR}/Independent media [def456].webm"
}

test_mock_engine_network_destination() {
    local scenario mode protocol network_output result_file phase_log final_path private_path
    local legacy_staging legacy_identity current_legacy_identity
    local final_entries filesystem_magic workspace_path
    local scenario_url='https://example.com/watch?v=network-fixture'
    local -a profile_arguments=()

    for scenario in direct-video direct-audio native-hls native-dash youtube-hls; do
        network_output="${TEST_ROOT}/network espace é % [${scenario}]"
        result_file="${TEST_ROOT}/network-${scenario}.result"
        phase_log="${TEST_ROOT}/network-${scenario}.phases"
        mkdir -- "${network_output}"
        chmod 0755 -- "${network_output}"
        legacy_staging="${network_output}/.yt-dlp-aria2.ABCDEFGH"
        mkdir -m 0755 -- "${legacy_staging}"
        printf '%s\n' 'yt-dlp-aria2-private-staging-v1' \
            >"${legacy_staging}/.yt-dlp-aria2-owner-v1"
        chmod 0755 -- "${legacy_staging}/.yt-dlp-aria2-owner-v1"
        legacy_identity=$(stat -c '%d:%i:%u:%a:%Y:%Z' -- \
            "${legacy_staging}" "${legacy_staging}/.yt-dlp-aria2-owner-v1")
        printf '%s\n' 'preexisting media' >"${network_output}/existing-media"
        filesystem_magic=0xfe534d42
        mode=video
        protocol=http
        profile_arguments=()
        scenario_url='https://example.com/watch?v=network-fixture'
        case ${scenario} in
            direct-audio)
                mode=audio
                filesystem_magic=0xff534d42
                ;;
            native-hls) protocol=m3u8_native ;;
            native-dash) protocol=http_dash_segments ;;
            youtube-hls)
                protocol=m3u8_native
                profile_arguments=(--youtube-hls-firefox)
                scenario_url='https://www.youtube.com/watch?v=network-fixture'
                ;;
            *) ;;
        esac
        prepare_argument_log "network-${scenario}"
        assert_status 0 "permissive media destination ${scenario}" \
            env MOCK_NETWORK_PERMISSIONS=1 \
            MOCK_NETWORK_FS_MAGIC="${filesystem_magic}" \
            MOCK_NETWORK_CHECK="${MOCK_BIN}/network-check.py" \
            MOCK_NETWORK_PHASE_LOG="${phase_log}" \
            MOCK_OUTPUT_DIR="${network_output}" \
            MOCK_NETWORK_DESTINATION="${network_output}" \
            MOCK_PLAN_PROTOCOL="${protocol}" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${network_output}" --mode "${mode}" \
            --result-file "${result_file}" "${profile_arguments[@]}" \
            -- "${scenario_url}"
        [[ -s ${result_file} ]] || fail "No final result for ${scenario}."
        IFS= read -r final_path <"${result_file}"
        [[ ${final_path%/*} == "${network_output}" && -s ${final_path} ]] \
            || fail "Final media was not published to the selected destination for ${scenario}."
        assert_file_has_line "${phase_log}" "filesystem:${filesystem_magic}" \
            'non-local classification uses the selected destination descriptor'
        current_legacy_identity=$(stat -c '%d:%i:%u:%a:%Y:%Z' -- \
            "${legacy_staging}" "${legacy_staging}/.yt-dlp-aria2-owner-v1")
        assert_equals "${legacy_identity}" "${current_legacy_identity}" \
            'a preexisting staging directory and marker are untouched'
        assert_file_has_line "${network_output}/existing-media" 'preexisting media' \
            'preexisting media survives network publication'
        # shellcheck disable=SC2312 # The mock entry point enables pipefail for this counting pipeline.
        final_entries=$(find "${network_output}" -mindepth 1 -maxdepth 1 -printf '.\n' | wc -l)
        assert_equals 3 "${final_entries}" \
            'destination contains only final media and the two preexisting entries'
        while IFS= read -r workspace_path; do
            [[ ! -e ${workspace_path} && ! -L ${workspace_path} ]] \
                || fail "Local media workspace survived successful ${scenario}."
        done <"${phase_log}.workspaces"
        assert_text_not_contains "${ASSERT_OUTPUT}" 'preserving ambiguous' \
            'normal network completion does not refuse active staging cleanup'
        while IFS= read -r private_path; do
            [[ ! -e ${private_path} ]] \
                || fail "Private metadata survived controlled completion for ${scenario}."
        done <"${phase_log}.paths"

        assert_file_has_line "${phase_log}" 'plan:private' \
            "private metadata during ${scenario} extraction"
        assert_file_not_contains "${phase_log}" 'leaked' \
            "secrets absent from destination during ${scenario}"
        env MOCK_NETWORK_PHASE_LOG="${phase_log}" \
            MOCK_OUTPUT_DIR="${network_output}" \
            python3 -I -B "${MOCK_BIN}/network-check.py" final
        assert_text_not_contains "${ASSERT_OUTPUT}" 'NETWORK_FIXTURE_' \
            "diagnostics contain no sentinel for ${scenario}"
        if [[ ${protocol} == http ]]; then
            assert_file_has_line "${phase_log}" 'aria2:private' \
                'direct aria2 metadata remains private while in use'
        fi
        assert_file_has_line "${phase_log}" 'native:private' \
            "yt-dlp transfer/postprocess metadata for ${scenario}"
    done
}

test_mock_engine_network_failures() {
    local scenario output result phases variable expected protocol workspace line
    local private_path failure_value
    local -a profile=()
    local -a remux_temps=()

    for scenario in plan aria2 native remux source-swap remux-swap; do
        output="${TEST_ROOT}/network-failure-${scenario}"
        result="${TEST_ROOT}/network-failure-${scenario}.result"
        phases="${TEST_ROOT}/network-failure-${scenario}.phases"
        mkdir -- "${output}"
        expected=23
        protocol=http
        profile=()
        case ${scenario} in
            plan) variable=MOCK_PLAN_EXIT_STATUS ;;
            aria2)
                variable=MOCK_ARIA2_EXIT_STATUS
                expected=29
                ;;
            native)
                variable=MOCK_YTDLP_EXIT_STATUS
                protocol=m3u8_native
                ;;
            remux)
                variable=MOCK_FFMPEG_EXIT_STATUS
                expected=9
                protocol=m3u8_native
                profile=(--youtube-hls-firefox)
                ;;
            source-swap)
                variable=MOCK_NETWORK_REPLACE_AT_PROBE
                expected=73
                ;;
            remux-swap)
                variable=MOCK_REPLACE_HLS_REMUX_AFTER_WRITE
                expected=13
                protocol=m3u8_native
                profile=(--youtube-hls-firefox)
                ;;
            *) fail "Unknown network failure scenario: ${scenario}" ;;
        esac
        failure_value=${expected}
        if [[ ${scenario} == remux-swap ]]; then
            failure_value=1
        fi
        prepare_argument_log "network-failure-${scenario}"
        assert_status "${expected}" "network ${scenario} preserves failure status" \
            env MOCK_NETWORK_PERMISSIONS=1 \
            MOCK_NETWORK_CHECK="${MOCK_BIN}/network-check.py" \
            MOCK_NETWORK_PHASE_LOG="${phases}" \
            MOCK_NETWORK_DESTINATION="${output}" MOCK_OUTPUT_DIR="${output}" \
            MOCK_PLAN_PROTOCOL="${protocol}" "${variable}=${failure_value}" \
            MOCK_NETWORK_MUTATION_MARKER="${phases}.mutation" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${output}" --mode video --result-file "${result}" \
            "${profile[@]}" -- 'https://www.youtube.com/watch?v=network-failure'
        [[ ! -e ${result} ]] || fail "Network ${scenario} published a failed result."
        assert_directory_empty "${output}" \
            "network ${scenario} leaves destination untouched on failure"
        if [[ -f ${phases}.paths ]]; then
            while IFS= read -r private_path; do
                [[ ! -e ${private_path} ]] \
                    || fail "Network ${scenario} retained private metadata."
            done <"${phases}.paths"
        fi
        if [[ ${scenario} == remux || ${scenario} == source-swap || ${scenario} == remux-swap ]]; then
            workspace=''
            while IFS= read -r line; do
                case ${line} in
                    'Local media workspace: '*) workspace=${line#*: } ;;
                    *) ;;
                esac
            done <<<"${ASSERT_OUTPUT}"
            if [[ ${scenario} == remux || ${scenario} == remux-swap ]]; then
                [[ -n ${workspace} && -s ${workspace}/'Mock media [abc123].mp4' ]] \
                    || fail 'A network remux failure lost the valid repaired HLS source.'
                if [[ ${scenario} == remux-swap ]]; then
                    shopt -s nullglob
                    remux_temps=("${workspace}"/.yt-dlp-remux.*.mkv)
                    shopt -u nullglob
                    assert_equals 1 "${#remux_temps[@]}" \
                        'network remux cleanup preserves the replaced temporary'
                    assert_file_has_line "${remux_temps[0]}" \
                        'foreign HLS remux replacement' \
                        'network parent cleanup preserves the foreign remux inode'
                fi
            else
                assert_text_contains "${ASSERT_OUTPUT}" \
                    'the validated local media changed before publication' \
                    'source replacement during FFprobe cannot become validated'
                assert_file_has_line "${workspace}/Mock media [abc123].webm" \
                    'foreign media substituted during FFprobe' \
                    'foreign replaced source is preserved after rejected publication'
            fi
            # This private directory was created by this exact fixture run and
            # deliberately preserved by the engine for recovery.
            rm -rf -- "${workspace}"
        fi
        assert_text_not_contains "${ASSERT_OUTPUT}" 'NETWORK_FIXTURE_' \
            "network ${scenario} diagnostics contain no secrets"
    done
}

test_mock_engine_network_signals() {
    local scenario output result phases marker termination protocol private_path
    local state_home log_dir
    local -a invocation=()
    local -a retained_logs=()

    for scenario in HUP INT TERM gui-direct gui-hls; do
        output="${TEST_ROOT}/network-cancel-${scenario}"
        result="${TEST_ROOT}/network-cancel-${scenario}.result"
        phases="${TEST_ROOT}/network-cancel-${scenario}.phases"
        marker="${TEST_ROOT}/network-cancel-${scenario}.started"
        termination="${TEST_ROOT}/network-cancel-${scenario}.terminated"
        mkdir -- "${output}"
        protocol=http
        case ${scenario} in
            INT | gui-hls) protocol=m3u8_native ;;
            TERM) protocol=http_dash_segments ;;
            *) ;;
        esac
        invocation=(
            env MOCK_NETWORK_PERMISSIONS=1
            MOCK_NETWORK_CHECK="${MOCK_BIN}/network-check.py"
            MOCK_NETWORK_PHASE_LOG="${phases}"
            MOCK_NETWORK_DESTINATION="${output}" MOCK_OUTPUT_DIR="${output}"
            MOCK_PLAN_PROTOCOL="${protocol}" MOCK_LONG_DOWNLOAD=1
            MOCK_STARTED_MARKER="${marker}"
            MOCK_TERMINATION_MARKER="${termination}"
        )
        prepare_argument_log "network-cancel-${scenario}"
        if [[ ${scenario} == gui-* ]]; then
            # Cancellation retains a sanitized diagnostic. Keep each fixture's
            # state separate from the later successful GUI scenarios.
            state_home="${TEST_ROOT}/network-cancel-${scenario}.state"
            log_dir="${state_home}/yt-dlp-aria2-downloader"
            assert_status 130 "network ${scenario} cancellation" \
                "${invocation[@]}" XDG_STATE_HOME="${state_home}" MOCK_CANCEL=1 \
                MOCK_USE_DEFAULT_PROFILE=1 \
                MOCK_ZENITY_WAIT_FOR_WORKER_START=1 "${GUI_UNDER_TEST}"
            shopt -s nullglob
            retained_logs=("${log_dir}"/download-*.log)
            shopt -u nullglob
            assert_equals 1 "${#retained_logs[@]}" \
                "network ${scenario} retains one cancellation diagnostic"
            assert_path_mode "${retained_logs[0]}" 600 \
                "network ${scenario} cancellation diagnostic mode"
            assert_file_not_contains "${retained_logs[0]}" 'NETWORK_FIXTURE_' \
                "network ${scenario} cancellation diagnostic contains no secrets"
            assert_retained_log_identity_footer "${retained_logs[0]}" \
                "network ${scenario} cancellation diagnostic"
            assert_no_retained_log_staging "${log_dir}" \
                "network ${scenario} cancellation diagnostic"
        else
            assert_status 0 "network ${scenario} signal supervision" \
                "${invocation[@]}" python3 "${MOCK_BIN}/network-signal.py" \
                "${scenario}" "${PROJECT_DIR}/download-video.sh" \
                "${output}" "${result}" "${TEST_ROOT}/network-cancel-${scenario}.log"
        fi
        [[ ! -e ${result} ]] || fail "Network ${scenario} cancellation published a result."
        assert_directory_empty "${output}" \
            "network ${scenario} leaves no remote partial media"
        assert_file_not_contains "${phases}" 'leaked' \
            "network ${scenario} private metadata during cancellation"
        while IFS= read -r private_path; do
            [[ ! -e ${private_path} ]] \
                || fail "Network ${scenario} retained private metadata."
        done <"${phases}.paths"
        assert_no_test_processes "network ${scenario} left descendants"
    done
}

test_mock_engine_network_cleanup_boundaries() {
    local source_copy="${TEST_ROOT}/cleanup-boundaries-source.sh"
    local harness="${TEST_ROOT}/cleanup-boundaries-harness.sh"
    local case_name workspace_record workspace_path
    local internal_record_log="${TEST_ROOT}/internal-record-replacement-path"
    local internal_record=''

    prepare_argument_log 'internal-record-replacement-after-download'
    assert_status 0 'CLI without result-file preserves an exchanged internal path record' \
        env MOCK_REPLACE_RESULT_RECORD_AFTER_WRITE=1 \
        MOCK_REPLACED_RESULT_RECORD_PATH="${internal_record_log}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=internal-record-replacement'
    IFS= read -r internal_record <"${internal_record_log}"
    assert_file_has_line "${internal_record}" 'foreign result-record replacement' \
        'parent metadata cleanup cannot erase a refused internal-record replacement'
    [[ ! -e ${internal_record%/*}/plan.json &&
        ! -e ${internal_record%/*}/cookies.txt &&
        ! -e ${internal_record%/*}/aria2.input &&
        ! -e ${internal_record%/*}/manifest.json ]] \
        || fail 'Preserved internal-record replacement retained authentication metadata.'
    rm -rf -- "${internal_record%/*}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    sed '$d' "${PROJECT_DIR}/download-video.sh" >"${source_copy}"
    cat >"${harness}" <<'EOF_NETWORK_CLEANUP_BOUNDARIES'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090 # The test supplies the current engine without main.
source "${1}"
readonly PRIVATE_ARIA2_HELPER=${2}
case_name=$3
workspace_record=$4
media_root=$(python3 "${PRIVATE_ARIA2_HELPER}" private-root --disk)
MEDIA_WORKSPACE=$(mktemp -d --tmpdir="${media_root}" '.fixture-media.XXXXXXXX')
OUTPUT_DIR=${MEDIA_WORKSPACE}
get_path_identity MEDIA_WORKSPACE_IDENTITY "${MEDIA_WORKSPACE}" directory
exec {MEDIA_WORKSPACE_FD}<"${MEDIA_WORKSPACE}"
printf '%s\n' "${MEDIA_WORKSPACE}" >"${workspace_record}"
case ${case_name} in
    staging-mode | marker-mode)
        PRIVATE_ARIA2_STAGING="${MEDIA_WORKSPACE}/.yt-dlp-aria2.ModeTest"
        mkdir -m 700 -- "${PRIVATE_ARIA2_STAGING}"
        exec {PRIVATE_ARIA2_STAGING_FD}<"${PRIVATE_ARIA2_STAGING}"
        get_path_identity PRIVATE_ARIA2_STAGING_IDENTITY \
            "${PRIVATE_ARIA2_STAGING}" directory
        printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
            >"${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
        if [[ ${case_name} == staging-mode ]]; then
            chmod 755 -- "${PRIVATE_ARIA2_STAGING}"
        else
            chmod 755 -- "${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
        fi
        ;;
    staging-file)
        PRIVATE_ARIA2_STAGING="${MEDIA_WORKSPACE}/.yt-dlp-aria2.Changed1"
        mkdir -m 700 -- "${PRIVATE_ARIA2_STAGING}"
        get_path_identity PRIVATE_ARIA2_STAGING_IDENTITY \
            "${PRIVATE_ARIA2_STAGING}" directory
        mv -- "${PRIVATE_ARIA2_STAGING}" "${PRIVATE_ARIA2_STAGING}.before-swap"
        printf '%s\n' 'foreign staging replacement' >"${PRIVATE_ARIA2_STAGING}"
        ;;
    repaired-source)
        HLS_SOURCE_TO_CLEAN="${MEDIA_WORKSPACE}/source.mp4"
        printf '%s\n' 'original repaired source' >"${HLS_SOURCE_TO_CLEAN}"
        get_path_identity HLS_SOURCE_TO_CLEAN_IDENTITY \
            "${HLS_SOURCE_TO_CLEAN}" regular-file
        mv -- "${HLS_SOURCE_TO_CLEAN}" "${HLS_SOURCE_TO_CLEAN}.before-swap"
        printf '%s\n' 'foreign repaired source' >"${HLS_SOURCE_TO_CLEAN}"
        remove_repaired_hls_source
        ;;
    *) exit 64 ;;
esac
trap cleanup EXIT
exit 7
EOF_NETWORK_CLEANUP_BOUNDARIES
    for case_name in staging-mode marker-mode staging-file repaired-source; do
        workspace_record="${TEST_ROOT}/cleanup-boundary-${case_name}.path"
        prepare_argument_log "network-cleanup-boundary-${case_name}"
        assert_status 7 "parent workspace preserves refused ${case_name} replacement" \
            bash "${harness}" "${source_copy}" \
            "${PROJECT_DIR}/private-aria2-plan.py" "${case_name}" "${workspace_record}"
        IFS= read -r workspace_path <"${workspace_record}"
        if [[ ${case_name} == staging-mode || ${case_name} == marker-mode ]]; then
            assert_file_has_line "${workspace_path}/.yt-dlp-aria2.ModeTest/.yt-dlp-aria2-owner-v1" \
                'yt-dlp-aria2-private-staging-v1' \
                'permissive active staging or marker is preserved'
            assert_text_contains "${ASSERT_OUTPUT}" \
                'preserving ambiguous active private aria2 staging directory' \
                'mode mismatch has an explicit cleanup diagnostic'
        elif [[ ${case_name} == staging-file ]]; then
            assert_file_has_line "${workspace_path}/.yt-dlp-aria2.Changed1" \
                'foreign staging replacement' \
                'regular-file staging replacement survives parent cleanup'
        else
            assert_file_has_line "${workspace_path}/source.mp4" \
                'foreign repaired source' \
                'cleared HLS fields cannot bypass persistent preservation'
            assert_file_has_line "${workspace_path}/source.mp4.before-swap" \
                'original repaired source' 'moved original source is preserved'
        fi
        rm -rf -- "${workspace_path}"
    done
}

test_mock_active_staging_inventory() {
    python3 -I -B - "${PROJECT_DIR}" "${TEST_ROOT}" <<'PY_STAGING_INVENTORY'
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile

project, test_root = map(Path, sys.argv[1:])
source = (project / "download-video.sh").read_text().rsplit('\nmain "$@"', 1)[0]

def snapshot(path):
    metadata = path.stat()
    return (metadata.st_dev, metadata.st_ino, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns,
            hashlib.sha256(path.read_bytes()).hexdigest())

for fault in ("nominal", "unknown", "empty-error", "partial-error", "divergence"):
    with tempfile.TemporaryDirectory(dir=test_root) as raw:
        root = Path(raw)
        output = root / "out"
        output.mkdir(mode=0o700)
        staging = output / ".yt-dlp-aria2.ABCDef12"
        staging.mkdir(mode=0o700)
        witness = staging / "foreign.txt"
        if fault in {"unknown", "empty-error", "partial-error"}:
            witness.write_bytes(b"MUST SURVIVE\n")
            witness.chmod(0o600)
            original = snapshot(witness)
        else:
            original = None
        harness = source + r'''
OUTPUT_DIR=$1
PRIVATE_ARIA2_STAGING=$2
get_path_identity PRIVATE_ARIA2_STAGING_IDENTITY "$2" directory
inventory_fault=$3
inventory_once=$4
printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" >"$2/${PRIVATE_ARIA2_STAGING_MARKER}"
chmod 600 "$2/${PRIVATE_ARIA2_STAGING_MARKER}"
printf '%s\n' 'owned media' >"$2/item-000.download"
chmod 600 "$2/item-000.download"
find() {
    if [[ ! -e ${inventory_once} ]]; then
        : >"${inventory_once}"
        case ${inventory_fault} in
            empty-error) return 1 ;;
            partial-error)
                printf '%s\0' "${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
                return 1
                ;;
            divergence)
                command find "$@" || return
                printf '%s\n' 'MUST SURVIVE' >"${PRIVATE_ARIA2_STAGING}/foreign.txt"
                chmod 600 "${PRIVATE_ARIA2_STAGING}/foreign.txt"
                return 0
                ;;
        esac
    fi
    command find "$@"
}
trap cleanup EXIT
exit 42
'''
        completed = subprocess.run(
            ["bash", "-s", "--", str(output), str(staging), fault, str(root / "once")],
            input=harness, text=True, capture_output=True, timeout=15,
        )
        assert completed.returncode == 42, (fault, completed.stderr)
        if fault == "nominal":
            assert not staging.exists(), completed.stderr
        else:
            assert witness.is_file(), (fault, "foreign file was deleted", completed.stderr)
            assert witness.read_bytes() == b"MUST SURVIVE\n", fault
            if original is not None:
                assert snapshot(witness) == original, (fault, "foreign identity or bytes changed")
            if fault != "divergence":
                assert (staging / "item-000.download").is_file(), (fault, "partial cleanup")
        print(f"Active staging inventory: {fault} preserves unvalidated entries.")
PY_STAGING_INVENTORY
}

run_mock_engine_core_group() {
    test_mock_cleanup_owner_guard
    test_mock_engine_log_retention
    test_mock_engine_audio_downloads
    test_mock_engine_video_downloads
    test_mock_engine_failure_paths
}

run_mock_engine_hls_group() {
    test_mock_engine_youtube_hls
}

run_mock_engine_staging_group() {
    test_mock_active_staging_inventory
    test_mock_engine_private_staging
}

run_mock_engine_group() {
    run_mock_engine_core_group
    run_mock_engine_hls_group
    run_mock_engine_staging_group
    test_mock_engine_network_destination
    test_mock_engine_network_failures
    test_mock_engine_network_signals
    test_mock_engine_network_cleanup_boundaries
}

run_selected_mock_engine_group() {
    case ${MOCK_GROUP} in
        all | engine) run_mock_engine_group ;;
        engine-core) run_mock_engine_core_group ;;
        engine-hls) run_mock_engine_hls_group ;;
        engine-staging) run_mock_engine_staging_group ;;
        engine-network)
            test_mock_engine_network_destination
            test_mock_engine_network_failures
            test_mock_engine_network_signals
            test_mock_engine_network_cleanup_boundaries
            ;;
        *) ;;
    esac
}
