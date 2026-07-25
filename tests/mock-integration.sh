#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

readonly MOCK_BIN="${TEST_ROOT}/bin"
readonly OUTPUT_DIR="${TEST_ROOT}/output dir %"
readonly HOME_DIR="${TEST_ROOT}/home"
readonly ARG_LOG="${TEST_ROOT}/yt-dlp-args.bin"
readonly PROGRESS_CAPTURE="${TEST_ROOT}/gui-progress-aria.txt"
readonly YTDLP_PROGRESS_CAPTURE="${TEST_ROOT}/gui-progress-ytdlp.txt"
readonly LIST_ARGS_LOG="${TEST_ROOT}/zenity-list-args.bin"
mkdir -p -- "${MOCK_BIN}" "${OUTPUT_DIR}" "${HOME_DIR}"

cat > "${MOCK_BIN}/yt-dlp" <<'EOF_YTDLP'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${1:-} == '--version' ]]; then
    printf '%s\n' "${MOCK_YTDLP_VERSION:-2026.06.09}"
    exit 0
fi
if [[ ${1:-} == '--help' ]]; then
    printf '%s\n' \
        '--js-runtimes' \
        '--remote-components' \
        '--progress-template' \
        '--print-to-file' \
        '--downloader-args'
    exit 0
fi

: "${MOCK_ARG_LOG:?}"
printf '%s\0' "$@" > "${MOCK_ARG_LOG}"

result_file=''
previous=''
for argument in "$@"; do
    if [[ ${previous} == '--print-to-file' ]]; then
        previous='print-template'
        continue
    fi
    if [[ ${previous} == 'print-template' ]]; then
        result_file=${argument//%%/%}
        previous=''
        continue
    fi
    if [[ ${argument} == '--print-to-file' ]]; then
        previous='--print-to-file'
    fi
done

if [[ ${MOCK_ARIA_ONLY:-0} == 1 ]]; then
    printf '\r[#a1b2c3 4.0MiB/10.0MiB(40%%) CN:8 DL:1.00MiB ETA:6s]\r'
else
    printf 'YTDLP_PROGRESS|downloading| 12.5%%|1.00MiB/s|00:07\n'
fi

if [[ ${MOCK_LONG_DOWNLOAD:-0} == 1 ]]; then
    trap 'printf terminated > "${MOCK_TERMINATION_MARKER:?}"; exit 143' TERM INT
    while true; do
        sleep 1
    done
fi

sleep 0.8
if [[ ${MOCK_ARIA_ONLY:-0} == 1 ]]; then
    printf '\r[#a1b2c3 10.0MiB/10.0MiB(100%%) CN:1 DL:2.00MiB ETA:0s]\r'
else
    printf 'YTDLP_PROGRESS|downloading|100.0%%|2.00MiB/s|00:00\n'
fi
printf 'YTDLP_POSTPROCESS|processing|FFmpegExtractAudio\n'
sleep 0.2

if [[ -n ${result_file} ]]; then
    printf '%s\n' "${MOCK_OUTPUT_DIR}/Mock media [abc123].webm" >> "${result_file}"
fi
EOF_YTDLP
chmod +x "${MOCK_BIN}/yt-dlp"

cat > "${MOCK_BIN}/aria2c" <<'EOF_ARIA2'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == '--version' ]]; then
    printf 'aria2 version %s\n' "${MOCK_ARIA2_VERSION:-1.37.0}"
    exit 0
fi
if [[ ${1:-} == '--help=#all' ]]; then
    printf '%s\n' \
        '--file-allocation=<METHOD>' \
        '--no-conf[=true|false]' \
        '--enable-color[=true|false]' \
        '--truncate-console-readout[=true|false]' \
        '--summary-interval=<SEC>' \
        '--show-console-readout[=true|false]'
    if [[ ${MOCK_ARIA2_DESCRIPTION_ONLY:-0} == 1 ]]; then
        printf '%s\n' 'Description mentioning --stderr without defining it.'
    else
        printf '%s\n' '--stderr[=true|false]'
    fi
fi
EOF_ARIA2
chmod +x "${MOCK_BIN}/aria2c"

cat > "${MOCK_BIN}/deno" <<'EOF_DENO'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'deno %s\n' "${MOCK_DENO_VERSION:-2.3.0}"
printf 'v8 0.0.0\n'
printf 'typescript 0.0.0\n'
EOF_DENO
chmod +x "${MOCK_BIN}/deno"

for media_tool in ffmpeg ffprobe; do
    cat > "${MOCK_BIN}/${media_tool}" <<'EOF_MEDIA_TOOL'
#!/usr/bin/env bash
set -Eeuo pipefail

case ${1:-} in
    -version|--version)
        printf '%s mock version 1.0\n' "${0##*/}"
        ;;
    *)
        ;;
esac
EOF_MEDIA_TOOL
    chmod +x "${MOCK_BIN}/${media_tool}"
done

cat > "${MOCK_BIN}/zenity" <<'EOF_ZENITY'
#!/usr/bin/env bash
set -Eeuo pipefail

case " $* " in
    *' --entry '*)
        if [[ -n ${MOCK_ZENITY_ENTRY_STATUS:-} ]]; then
            exit "${MOCK_ZENITY_ENTRY_STATUS}"
        fi
        printf '%s\n' 'https://example.com/watch?v=abc123'
        ;;
    *' --list '*)
        if [[ -n ${MOCK_LIST_ARGS_LOG:-} ]]; then
            printf '%s\0' "$@" > "${MOCK_LIST_ARGS_LOG}"
        fi
        if [[ ${MOCK_USE_DEFAULT_PROFILE:-0} == 1 ]]; then
            previous=''
            for argument in "$@"; do
                if [[ ${previous} == TRUE ]]; then
                    printf '%s
' "${argument}"
                    exit 0
                fi
                case ${argument} in
                    TRUE | FALSE) previous=${argument} ;;
                    *) previous='' ;;
                esac
            done
            exit 2
        fi
        printf '%s
' "${MOCK_PROFILE:-Audio track (native format)}"
        ;;
    *' --file-selection '*)
        if [[ " $* " == *' --ok-label='* ]] \
            || [[ " $* " == *' --cancel-label='* ]]; then
            printf '%s\n' \
                'custom button labels are unsupported for file selection' >&2
            exit 2
        fi
        if [[ -n ${MOCK_FILE_SELECTION_ARGS_LOG:-} ]]; then
            printf '%s\0' "$@" >> "${MOCK_FILE_SELECTION_ARGS_LOG}"
        fi
        if [[ -n ${MOCK_ZENITY_FILE_STATUS_WITH_FILENAME:-} ]] \
            && [[ " $* " == *' --filename='* ]]; then
            printf '%s\n' \
                "${MOCK_ZENITY_FILE_ERROR:-simulated --filename failure}" >&2
            exit "${MOCK_ZENITY_FILE_STATUS_WITH_FILENAME}"
        fi
        if [[ -n ${MOCK_ZENITY_FILE_STATUS:-} ]]; then
            printf '%s\n' \
                "${MOCK_ZENITY_FILE_ERROR:-simulated file chooser failure}" >&2
            exit "${MOCK_ZENITY_FILE_STATUS}"
        fi
        printf '%s\n' "${MOCK_OUTPUT_DIR}"
        ;;
    *' --progress '*)
        if [[ -n ${MOCK_ZENITY_PROGRESS_STATUS:-} ]]; then
            IFS= read -r _ || true
            exit "${MOCK_ZENITY_PROGRESS_STATUS}"
        fi
        if [[ ${MOCK_CANCEL:-0} == 1 ]]; then
            IFS= read -r _ || true
            exit 1
        fi
        if [[ -n ${MOCK_PROGRESS_CAPTURE:-} ]]; then
            cat > "${MOCK_PROGRESS_CAPTURE}"
        else
            cat >/dev/null
        fi
        ;;
    *' --question '*)
        exit 1
        ;;
    *' --error '*)
        if [[ -n ${MOCK_ERROR_CAPTURE:-} ]]; then
            printf '%s\n' "$*" >> "${MOCK_ERROR_CAPTURE}"
            exit 0
        fi
        printf 'Unexpected error dialog: %s\n' "$*" >&2
        exit 99
        ;;
    *)
        exit 0
        ;;
esac
EOF_ZENITY
chmod +x "${MOCK_BIN}/zenity"

export HOME="${HOME_DIR}"
export XDG_CONFIG_HOME="${HOME_DIR}/.config"
export XDG_STATE_HOME="${HOME_DIR}/.local/state"
export XDG_DATA_HOME="${HOME_DIR}/.local/share"
export MOCK_ARG_LOG="${ARG_LOG}"
export MOCK_OUTPUT_DIR="${OUTPUT_DIR}"
export MOCK_LIST_ARGS_LOG="${LIST_ARGS_LOG}"
export PATH="${MOCK_BIN}:/usr/bin:/bin"

for media_tool in ffmpeg ffprobe; do
    resolved_media_tool=$(command -v "${media_tool}")
    if [[ ${resolved_media_tool} != "${MOCK_BIN}/${media_tool}" ]]; then
        printf 'The %s mock was not selected: %s\n' \
            "${media_tool}" "${resolved_media_tool}" >&2
        exit 1
    fi
done

result_file="${TEST_ROOT}/engine-%-result.txt"
injection_marker="${TEST_ROOT}/must-not-exist"
malicious_url="https://example.com/watch?v=abc123&x=\$(touch ${injection_marker})"
"${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" \
    --mode audio \
    --machine-progress \
    --result-file "${result_file}" \
    -- "${malicious_url}" >/dev/null

grep -Fxq -- "${OUTPUT_DIR}/Mock media [abc123].webm" "${result_file}"
if [[ -e ${injection_marker} ]]; then
    printf 'The URL was interpreted as shell code.\n' >&2
    exit 1
fi

mapfile -d '' -t arguments < "${ARG_LOG}"
joined=$(printf '%s\n' "${arguments[@]}")
for expected in \
    '--ignore-config' \
    '--no-playlist' \
    '--remote-components' \
    'ejs:npm' \
    '--format' \
    'ba/b' \
    '--extract-audio' \
    '--audio-format' \
    'best' \
    '--audio-quality' \
    '0' \
    'aria2c:-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --console-log-level=warn --enable-color=false --truncate-console-readout=false --summary-interval=1 --show-console-readout=true --stderr=true'; do
    if ! grep -Fxq -- "${expected}" <<< "${joined}"; then
        printf 'Missing yt-dlp argument: %s\n' "${expected}" >&2
        exit 1
    fi
done
if grep -Fxq -- '--machine-progress' <<< "${joined}"; then
    printf 'Internal wrapper option leaked to yt-dlp.\n' >&2
    exit 1
fi
for forbidden_audio_format in mp3 m4a opus; do
    if grep -Fxq -- "${forbidden_audio_format}" <<< "${joined}"; then
        printf 'A forced audio output format leaked to yt-dlp: %s\n' \
            "${forbidden_audio_format}" >&2
        exit 1
    fi
done
if ! grep -Fxq -- "${malicious_url}" <<< "${joined}"; then
    printf 'The URL was not preserved as one argument.\n' >&2
    exit 1
fi

expected_output_template="${OUTPUT_DIR//%/%%}/%(title).150s [%(id)s].%(ext)s"
if ! grep -Fxq -- "${expected_output_template}" <<< "${joined}"; then
    printf 'The absolute output template was not escaped correctly.\n' >&2
    exit 1
fi
if grep -Fxq -- '--paths' <<< "${joined}"; then
    printf 'The engine unexpectedly uses --paths instead of one absolute output template.\n' >&2
    exit 1
fi

"${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" \
    --mode video \
    -- 'https://example.com/watch?v=video' >/dev/null
mapfile -d '' -t arguments < "${ARG_LOG}"
joined=$(printf '%s\n' "${arguments[@]}")
for expected in \
    '--format' \
    'bv*+ba/b' \
    '--merge-output-format' \
    'mkv' \
    'aria2c:-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --console-log-level=warn --enable-color=false --truncate-console-readout=false --summary-interval=0'; do
    if ! grep -Fxq -- "${expected}" <<< "${joined}"; then
        printf 'Missing video-mode yt-dlp argument: %s\n' "${expected}" >&2
        exit 1
    fi
done
if grep -Fq -- '--show-console-readout=true' <<< "${joined}"; then
    printf 'aria2 machine progress was enabled in ordinary CLI mode.\n' >&2
    exit 1
fi

MOCK_ARIA_ONLY=1 MOCK_PROGRESS_CAPTURE="${PROGRESS_CAPTURE}" \
    "${PROJECT_DIR}/download-video-gui.sh"

grep -Fxq -- '40' "${PROGRESS_CAPTURE}"
grep -Fq -- '# aria2 download: 40% - 1.00MiB - 6s remaining' \
    "${PROGRESS_CAPTURE}"

mapfile -d '' -t list_arguments < "${LIST_ARGS_LOG}"
list_joined=$(printf '%s
' "${list_arguments[@]}")
for expected_profile_label in \
    'Complete video (MKV)' \
    'Audio track (native format)'; do
    grep -Fxq -- "${expected_profile_label}" <<< "${list_joined}"
done
for removed_profile_label in \
    'Audio - MP3' \
    'Audio - M4A' \
    'Audio - Opus'; do
    if grep -Fxq -- "${removed_profile_label}" <<< "${list_joined}"; then
        printf 'Removed GUI profile is still present: %s
' \
            "${removed_profile_label}" >&2
        exit 1
    fi
done

MOCK_PROGRESS_CAPTURE="${YTDLP_PROGRESS_CAPTURE}" \
    "${PROJECT_DIR}/download-video-gui.sh"
grep -Fxq -- '12' "${YTDLP_PROGRESS_CAPTURE}"
grep -Fq -- '# Download: 12.5% - 1.00MiB/s - 00:07 remaining' \
    "${YTDLP_PROGRESS_CAPTURE}"

grep -Fxq -- "output_dir=${OUTPUT_DIR}" \
    "${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"
grep -Fxq -- 'profile=audio' \
    "${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"

mapfile -t gui_logs < <(find "${XDG_STATE_HOME}/yt-dlp-aria2-downloader" \
    -maxdepth 1 -type f -name 'download-*.log' -print)
if (( ${#gui_logs[@]} != 2 )); then
    printf 'Expected two GUI logs, found %d.\n' "${#gui_logs[@]}" >&2
    exit 1
fi

cat > "${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf" <<EOF_OLD_CONFIG
output_dir=${OUTPUT_DIR}
profile=audio-mp3
EOF_OLD_CONFIG
MOCK_USE_DEFAULT_PROFILE=1 "${PROJECT_DIR}/download-video-gui.sh"
grep -Fxq -- 'profile=audio' \
    "${XDG_CONFIG_HOME}/yt-dlp-aria2-downloader/gui.conf"

file_selection_args_log="${TEST_ROOT}/file-selection-args.bin"
: > "${file_selection_args_log}"
MOCK_ZENITY_FILE_STATUS_WITH_FILENAME=255 \
MOCK_ZENITY_FILE_ERROR='simulated initial-folder failure' \
MOCK_FILE_SELECTION_ARGS_LOG="${file_selection_args_log}" \
    "${PROJECT_DIR}/download-video-gui.sh" >/dev/null

mapfile -d '' -t file_selection_arguments < "${file_selection_args_log}"
file_selection_calls=0
filename_attempts=0
for argument in "${file_selection_arguments[@]}"; do
    if [[ ${argument} == --file-selection ]]; then
        (( file_selection_calls += 1 ))
    elif [[ ${argument} == --filename=* ]]; then
        (( filename_attempts += 1 ))
    fi
done
if (( file_selection_calls != 2 || filename_attempts != 1 )); then
    printf 'Expected one failed preselected chooser and one fallback chooser; ' >&2
    printf 'got %d chooser calls and %d --filename arguments.\n' \
        "${file_selection_calls}" "${filename_attempts}" >&2
    exit 1
fi
for argument in "${file_selection_arguments[@]}"; do
    case ${argument} in
        --ok-label=* | --cancel-label=*)
            printf 'Unsupported custom button label leaked into file chooser: %s\n' \
                "${argument}" >&2
            exit 1
            ;;
        *)
            ;;
    esac
done

termination_marker="${TEST_ROOT}/terminated"
set +e
MOCK_LONG_DOWNLOAD=1 \
MOCK_CANCEL=1 \
MOCK_TERMINATION_MARKER="${termination_marker}" \
    "${PROJECT_DIR}/download-video-gui.sh"
cancel_status=$?
set -e

if (( cancel_status != 130 )); then
    printf 'Expected cancellation status 130, got %d.\n' "${cancel_status}" >&2
    exit 1
fi

for _ in {1..30}; do
    [[ -f ${termination_marker} ]] && break
    sleep 0.1
done

if [[ ! -f ${termination_marker} ]]; then
    printf 'The download process group did not receive TERM.\n' >&2
    exit 1
fi


error_capture="${TEST_ROOT}/zenity-errors.txt"
set +e
MOCK_ZENITY_ENTRY_STATUS=5 MOCK_ERROR_CAPTURE="${error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
zenity_timeout_status=$?
set -e
if (( zenity_timeout_status != 1 )); then
    printf 'Expected Zenity timeout status 1, got %d.\n' \
        "${zenity_timeout_status}" >&2
    exit 1
fi
grep -Fq -- "URL entry dialog timed out" "${error_capture}"

: > "${error_capture}"
set +e
MOCK_ZENITY_ENTRY_STATUS=42 MOCK_ERROR_CAPTURE="${error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
zenity_error_status=$?
set -e
if (( zenity_error_status != 1 )); then
    printf 'Expected Zenity error status 1, got %d.\n' \
        "${zenity_error_status}" >&2
    exit 1
fi
grep -Fq -- "Zenity could not display" "${error_capture}"

set +e
MOCK_YTDLP_VERSION=2026.06.08 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=old-yt-dlp' >/dev/null 2>&1
old_ytdlp_status=$?
set -e
if (( old_ytdlp_status != 1 )); then
    printf 'Expected old yt-dlp status 1, got %d.\n' "${old_ytdlp_status}" >&2
    exit 1
fi

set +e
MOCK_DENO_VERSION=2.2.9 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=old-deno' >/dev/null 2>&1
old_deno_status=$?
set -e
if (( old_deno_status != 1 )); then
    printf 'Expected old Deno status 1, got %d.\n' "${old_deno_status}" >&2
    exit 1
fi


set +e
MOCK_ARIA2_VERSION=1.36.0 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=old-aria2' >/dev/null 2>&1
old_aria2_status=$?
set -e
if (( old_aria2_status != 1 )); then
    printf 'Expected old aria2c status 1, got %d.\n' "${old_aria2_status}" >&2
    exit 1
fi

set +e
MOCK_ARIA2_DESCRIPTION_ONLY=1 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=missing-aria2-option' >/dev/null 2>&1
aria2_capability_status=$?
set -e
if (( aria2_capability_status != 1 )); then
    printf 'Expected missing aria2c option status 1, got %d.\n' \
        "${aria2_capability_status}" >&2
    exit 1
fi

progress_timeout_marker="${TEST_ROOT}/progress-timeout-terminated"
progress_timeout_errors="${TEST_ROOT}/progress-timeout-errors.txt"
set +e
MOCK_LONG_DOWNLOAD=1 \
MOCK_ZENITY_PROGRESS_STATUS=5 \
MOCK_TERMINATION_MARKER="${progress_timeout_marker}" \
MOCK_ERROR_CAPTURE="${progress_timeout_errors}" \
    "${PROJECT_DIR}/download-video-gui.sh"
progress_timeout_status=$?
set -e
if (( progress_timeout_status != 1 )); then
    printf 'Expected progress timeout status 1, got %d.\n' \
        "${progress_timeout_status}" >&2
    exit 1
fi
for _ in {1..30}; do
    [[ -f ${progress_timeout_marker} ]] && break
    sleep 0.1
done
[[ -f ${progress_timeout_marker} ]]
grep -Fq -- 'progress dialog timed out' "${progress_timeout_errors}"

progress_error_marker="${TEST_ROOT}/progress-error-terminated"
progress_error_capture="${TEST_ROOT}/progress-error-errors.txt"
set +e
MOCK_LONG_DOWNLOAD=1 \
MOCK_ZENITY_PROGRESS_STATUS=42 \
MOCK_TERMINATION_MARKER="${progress_error_marker}" \
MOCK_ERROR_CAPTURE="${progress_error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
progress_error_status=$?
set -e
if (( progress_error_status != 1 )); then
    printf 'Expected progress error status 1, got %d.\n' \
        "${progress_error_status}" >&2
    exit 1
fi
for _ in {1..30}; do
    [[ -f ${progress_error_marker} ]] && break
    sleep 0.1
done
[[ -f ${progress_error_marker} ]]
grep -Fq -- 'status 42' "${progress_error_capture}"

printf 'Mock integration tests passed.\n'
