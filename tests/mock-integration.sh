#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"
for required_command in \
    awk bash cat chmod date dirname env grep ln mkdir mktemp mv readlink \
    realpath rm setsid sleep stat timeout touch tr flock sha256sum wc; do
    require_test_command "${required_command}"
done
[[ -r /proc/self/cmdline ]] ||
    test_error 'mock integration tests require a readable Linux /proc filesystem.'
TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
readonly TEST_OWNER_BASHPID=${BASHPID}
trap '
    if [[ ${BASHPID} == "${TEST_OWNER_BASHPID}" ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

readonly MOCK_BIN="${TEST_ROOT}/bin"
readonly OUTPUT_DIR="${TEST_ROOT}/output dir %"
readonly HOME_DIR="${TEST_ROOT}/home"
readonly RUNTIME_DIR="${TEST_ROOT}/runtime"
readonly PROGRESS_CAPTURE="${TEST_ROOT}/gui-progress-aria.txt"
readonly YTDLP_PROGRESS_CAPTURE="${TEST_ROOT}/gui-progress-ytdlp.txt"
readonly LIST_ARGS_LOG="${TEST_ROOT}/zenity-list-args.bin"
mkdir -p -- "${MOCK_BIN}" "${OUTPUT_DIR}" "${HOME_DIR}" "${RUNTIME_DIR}"
chmod 700 -- "${RUNTIME_DIR}"

cat > "${MOCK_BIN}/yt-dlp" <<'EOF_YTDLP'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${YTDLP_NO_PLUGINS:-} != 1 ]]; then
    printf 'yt-dlp plugins were not disabled by the wrapper.\n' >&2
    exit 67
fi

if (($# == 1)) && [[ $1 == '--version' ]]; then
    [[ ${LC_ALL:-} == C ]] || { printf 'localized yt-dlp version output\n'; exit 65; }
    printf '%s\n' "${MOCK_YTDLP_VERSION:-2026.06.09}"
    exit 0
fi
if (($# == 1)) && [[ $1 == '--help' ]]; then
    [[ ${LC_ALL:-} == C ]] || { printf 'localized yt-dlp help output\n'; exit 65; }
    printf '%s\n' \
        '--js-runtimes' \
        '--remote-components' \
        '--cookies-from-browser BROWSER[:PROFILE]' \
        '--extractor-args KEY:ARGS' \
        '-O, --print [WHEN:]TEMPLATE' \
        '--progress-template' \
        '--print-to-file' \
        '--fixup POLICY' \
        '--downloader-args' \
        '--no-overwrites' \
        '--no-post-overwrites'
    exit 0
fi

: "${MOCK_ARG_LOG:?}"
printf '%s\0' "$@" > "${MOCK_ARG_LOG}"

wait_for_marker() {
    local marker=$1
    local label=$2
    local attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [[ -f ${marker} ]]; then
            return 0
        fi
        sleep 0.1
    done

    printf 'Timed out waiting for %s marker: %s\n' \
        "${label}" "${marker}" >&2
    exit 66
}

progress_ready_marker=''
postprocess_ready_marker=''
if [[ -n ${MOCK_PROGRESS_CAPTURE:-} ]]; then
    progress_ready_marker="${MOCK_PROGRESS_CAPTURE}.progress-ready"
    postprocess_ready_marker="${MOCK_PROGRESS_CAPTURE}.postprocess-ready"
    rm -f -- "${progress_ready_marker}" "${postprocess_ready_marker}"
fi

result_file=''
youtube_hls_mode=false
no_overwrites=false
no_post_overwrites=false
previous=''
for argument in "$@"; do
    case ${argument} in
    --no-overwrites) no_overwrites=true ;;
    --no-post-overwrites) no_post_overwrites=true ;;
    *) ;;
    esac
    if [[ ${argument} == '--cookies-from-browser' ]]; then
        youtube_hls_mode=true
    fi
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

if [[ ${MOCK_ARIA_NO_PERCENT:-0} == 1 ]]; then
    printf '\r[#a1b2c3 4.0MiB/0B CN:8 DL:1.00MiB]\r'
elif [[ ${MOCK_ARIA_ONLY:-0} == 1 ]]; then
    printf '\r[#a1b2c3 4.0MiB/10.0MiB(40%%) CN:8 DL:1.00MiB ETA:6s]\r'
else
    printf 'YTDLP_PROGRESS|downloading| 12.5%%|1.00MiB/s|00:07\n'
fi
if [[ -n ${progress_ready_marker} ]]; then
    wait_for_marker "${progress_ready_marker}" 'initial progress'
fi

if [[ ${MOCK_LONG_DOWNLOAD:-0} == 1 ]]; then
    if [[ -n ${MOCK_STARTED_MARKER:-} ]]; then
        printf started >"${MOCK_STARTED_MARKER}"
    fi
    trap 'printf terminated > "${MOCK_TERMINATION_MARKER:?}"; exit 143' TERM INT
    while true; do
        sleep 0.1
    done
fi

if [[ -z ${progress_ready_marker} ]]; then
    sleep 0.8
fi
if [[ ${MOCK_ARIA_NO_PERCENT:-0} == 1 ]]; then
    printf '\r[#a1b2c3 10.0MiB/0B CN:1 DL:2.00MiB]\r'
elif [[ ${MOCK_ARIA_ONLY:-0} == 1 ]]; then
    printf '\r[#a1b2c3 10.0MiB/10.0MiB(100%%) CN:1 DL:2.00MiB ETA:0s]\r'
else
    printf 'YTDLP_PROGRESS|downloading|100.0%%|2.00MiB/s|00:00\n'
fi
printf 'YTDLP_POSTPROCESS|processing|FFmpegExtractAudio\n'
if [[ -n ${postprocess_ready_marker} ]]; then
    wait_for_marker "${postprocess_ready_marker}" 'post-processing progress'
elif [[ ${MOCK_LATE_PROGRESS:-0} == 1 ]]; then
    sleep 0.8
fi

if [[ ${MOCK_LATE_PROGRESS:-0} == 1 ]]; then
    printf 'YTDLP_PROGRESS|downloading| 12.0%%|512.00KiB/s|00:09\n'
    sleep 0.8
elif [[ -z ${postprocess_ready_marker} ]]; then
    sleep 0.2
fi

if [[ ${youtube_hls_mode} == true ]]; then
    output_path="${MOCK_OUTPUT_DIR}/Mock media [abc123].mp4"
    printf 'YTDLP_POSTPROCESS|started|FixupM3u8\n'
else
    output_path="${MOCK_OUTPUT_DIR}/Mock media [abc123].webm"
fi
if [[ ${MOCK_RESULT_OUTSIDE_OUTPUT:-0} == 1 ]]; then
    output_path=${MOCK_OUTSIDE_RESULT_PATH:?}
fi
if [[ ${MOCK_YTDLP_EXIT_STATUS:-0} != 0 ]]; then
    if [[ ${MOCK_WRITE_RESULT_BEFORE_FAILURE:-0} == 1 && -n ${result_file} ]]; then
        printf '%s\n' "${output_path}" >> "${result_file}"
    fi
    printf 'Simulated yt-dlp failure.\n' >&2
    exit "${MOCK_YTDLP_EXIT_STATUS}"
fi

if [[ ${MOCK_ENFORCE_NO_OVERWRITE:-0} == 1 && -e ${output_path} ]]; then
    if [[ ${no_overwrites} != true || ${no_post_overwrites} != true ]]; then
        printf 'The wrapper omitted an explicit no-overwrite policy.\n' >&2
        : >"${output_path}"
        exit 68
    fi
    printf 'Simulated refusal to overwrite an existing final media file.\n' >&2
    exit 1
fi
if [[ ${MOCK_RESULT_TARGET_MISSING:-0} != 1 ]]; then
    printf '%s\n' 'mock media payload' >"${output_path}"
fi
if [[ -n ${result_file} && ${MOCK_SKIP_RESULT_FILE:-0} != 1 ]]; then
    if [[ ${MOCK_PREPEND_STALE_RESULT:-0} == 1 ]]; then
        printf '%s\n' "${MOCK_OUTPUT_DIR}/stale-result.webm" >>"${result_file}"
    fi
    printf '%s\n' "${output_path}" >>"${result_file}"
fi
EOF_YTDLP
chmod +x "${MOCK_BIN}/yt-dlp"

cat > "${MOCK_BIN}/aria2c" <<'EOF_ARIA2'
#!/usr/bin/env bash
set -euo pipefail

case ${1:-} in
--version)
    [[ ${LC_ALL:-} == C ]] || { printf 'aria2 versión localizada\n'; exit 65; }
    printf 'aria2 version %s\n' "${MOCK_ARIA2_VERSION:-1.37.0}"
    ;;
--help=#all)
    [[ ${LC_ALL:-} == C ]] || { printf 'ayuda aria2 localizada\n'; exit 65; }
    printf '%s\n' \
        '--file-allocation=<METHOD>' \
        '--no-conf[=true|false]'
    if [[ ${MOCK_ARIA2_NO_NETRC_UNAVAILABLE:-0} != 1 ]]; then
        printf '%s\n' '-n, --no-netrc[=true|false]'
    fi
    printf '%s\n' \
        '--enable-color[=true|false]' \
        '--truncate-console-readout[=true|false]' \
        '--summary-interval=<SEC>' \
        '--show-console-readout[=true|false]'
    if [[ ${MOCK_ARIA2_DESCRIPTION_ONLY:-0} == 1 ]]; then
        printf '%s\n' 'Description mentioning --stderr without defining it.'
    else
        printf '%s\n' '--stderr[=true|false]'
    fi
    ;;
*)
    printf 'Unexpected aria2c mock invocation: %q\n' "$*" >&2
    exit 64
    ;;
esac
EOF_ARIA2
chmod +x "${MOCK_BIN}/aria2c"

cat > "${MOCK_BIN}/deno" <<'EOF_DENO'
#!/usr/bin/env bash
set -euo pipefail
[[ ${LC_ALL:-} == C ]] || { printf 'salida Deno localizada\n'; exit 65; }
printf 'deno %s\n' "${MOCK_DENO_VERSION:-2.3.0}"
printf 'v8 0.0.0\n'
printf 'typescript 0.0.0\n'
EOF_DENO
chmod +x "${MOCK_BIN}/deno"

cat > "${MOCK_BIN}/ffmpeg" <<'EOF_FFMPEG'
#!/usr/bin/env bash
set -euo pipefail

case ${1:-} in
-version | --version)
    printf 'ffmpeg mock version 1.0\n'
    exit 0
    ;;
esac

if [[ -n ${MOCK_FFMPEG_ARG_LOG:-} ]]; then
    printf '%s\0' "$@" >"${MOCK_FFMPEG_ARG_LOG}"
fi
if [[ ${MOCK_LONG_FFMPEG:-0} == 1 ]]; then
    if [[ -n ${MOCK_FFMPEG_STARTED_MARKER:-} ]]; then
        printf started >"${MOCK_FFMPEG_STARTED_MARKER}"
    fi
    trap 'printf terminated >"${MOCK_FFMPEG_TERMINATION_MARKER:?}"; exit 143' TERM INT
    while true; do
        sleep 0.1
    done
fi
if [[ ${MOCK_FFMPEG_EXIT_STATUS:-0} != 0 ]]; then
    printf 'Simulated FFmpeg remux failure.\n' >&2
    exit "${MOCK_FFMPEG_EXIT_STATUS}"
fi
output_path=${!#}
printf '%s\n' 'mock remuxed media payload' >"${output_path}"
EOF_FFMPEG
chmod +x "${MOCK_BIN}/ffmpeg"

cat > "${MOCK_BIN}/ffprobe" <<'EOF_FFPROBE'
#!/usr/bin/env bash
set -euo pipefail

case ${1:-} in
-version | --version)
    printf 'ffprobe mock version 1.0\n'
    exit 0
    ;;
esac

if [[ -n ${MOCK_FFPROBE_ARG_LOG:-} ]]; then
    printf '%s\0' "$@" >"${MOCK_FFPROBE_ARG_LOG}"
fi
if [[ ${MOCK_FFPROBE_EXIT_STATUS:-0} != 0 ]]; then
    printf 'Simulated FFprobe validation failure.\n' >&2
    exit "${MOCK_FFPROBE_EXIT_STATUS}"
fi
if [[ ${MOCK_FFPROBE_EMPTY:-0} != 1 ]]; then
    printf '0\n'
fi
EOF_FFPROBE
chmod +x "${MOCK_BIN}/ffprobe"

REAL_MV=$(command -v mv)
REAL_SETSID=$(command -v setsid)
export REAL_MV REAL_SETSID
cat >"${MOCK_BIN}/mv" <<'EOF_MV'
#!/usr/bin/env bash
set -euo pipefail

destination=${!#}
if [[ ${destination} == */pgid && ${MOCK_DELAY_PGID_PUBLISH:-0} == 1 ]]; then
    trap 'printf terminated >"${MOCK_PGID_DELAY_TERMINATION_MARKER:?}"; exit 143' TERM INT
    sleep 6
fi
exec "${REAL_MV:?}" "$@"
EOF_MV
chmod +x "${MOCK_BIN}/mv"

cat >"${MOCK_BIN}/setsid" <<'EOF_SETSID'
#!/usr/bin/env bash
set -euo pipefail

if (($# == 1)) && [[ $1 == '--help' ]]; then
    exec "${REAL_SETSID:?}" "$@"
fi
if [[ -n ${MOCK_SETSID_START_STATUS:-} ]]; then
    exit "${MOCK_SETSID_START_STATUS}"
fi
if [[ -n ${MOCK_SETSID_LOG:-} ]]; then
    printf 'call\n' >>"${MOCK_SETSID_LOG}"
fi
exec "${REAL_SETSID:?}" "$@"
EOF_SETSID
chmod +x "${MOCK_BIN}/setsid"

cat > "${MOCK_BIN}/zenity" <<'EOF_ZENITY'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
    *' --entry '*)
        if [[ -n ${MOCK_ZENITY_ENTRY_STATUS:-} ]]; then
            exit "${MOCK_ZENITY_ENTRY_STATUS}"
        fi
        printf '%s\n' \
            "${MOCK_ZENITY_ENTRY_VALUE:-https://example.com/watch?v=abc123}"
        ;;
    *' --list '*)
        if [[ -n ${MOCK_LIST_ARGS_LOG:-} ]]; then
            printf '%s\0' "$@" > "${MOCK_LIST_ARGS_LOG}"
        fi
        if [[ ${MOCK_USE_DEFAULT_PROFILE:-0} == 1 ]]; then
            previous=''
            for argument in "$@"; do
                if [[ ${previous} == TRUE ]]; then
                    printf '%s\n' "${argument}"
                    exit 0
                fi
                case ${argument} in
                    TRUE | FALSE) previous=${argument} ;;
                    *) previous='' ;;
                esac
            done
            exit 2
        fi
        printf '%s\n' "${MOCK_PROFILE:-Audio track (native format)}"
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
        if [[ ${MOCK_CANCEL_AFTER_EOF:-0} == 1 ]]; then
            cat >/dev/null
            exit 1
        fi
        if [[ ${MOCK_CANCEL:-0} == 1 ]]; then
            IFS= read -r _ || true
            exit 1
        fi

        progress_line=''
        expected_progress=''
        progress_ready_marker=''
        postprocess_ready_marker=''
        progress_marker_written=false

        if [[ -n ${MOCK_PROGRESS_CAPTURE:-} ]]; then
            : >"${MOCK_PROGRESS_CAPTURE}"
            progress_ready_marker="${MOCK_PROGRESS_CAPTURE}.progress-ready"
            postprocess_ready_marker="${MOCK_PROGRESS_CAPTURE}.postprocess-ready"

            if [[ ${MOCK_ARIA_NO_PERCENT:-0} == 1 ]]; then
                expected_progress='# Downloading the audio track - size unknown (aria2c) - 1.00MiB'
            elif [[ ${MOCK_ARIA_ONLY:-0} == 1 ]]; then
                expected_progress='# Downloading the audio track - 40% (aria2c) - 1.00MiB - 6s remaining'
            else
                expected_progress='# Downloading the audio track - 12% - 1.00MiB/s - 00:07 remaining'
            fi
        fi

        while IFS= read -r progress_line; do
            if [[ -n ${MOCK_PROGRESS_CAPTURE:-} ]]; then
                printf '%s\n' "${progress_line}" >>"${MOCK_PROGRESS_CAPTURE}"
            fi

            if [[ ${progress_marker_written} == false &&
                -n ${progress_ready_marker} &&
                ${progress_line} == "${expected_progress}" ]]; then
                : >"${progress_ready_marker}"
                progress_marker_written=true
            fi

            if [[ -n ${postprocess_ready_marker} &&
                ${progress_line} == '# Extracting the native audio track...' ]]; then
                : >"${postprocess_ready_marker}"
            fi
        done
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

prepare_argument_log() {
    local scenario=$1

    # Keep CI logs useful: if a scenario blocks, the final emitted name shows
    # exactly which test was running.
    printf 'Mock scenario: %s\n' "${scenario}"

    MOCK_ARG_LOG="${TEST_ROOT}/yt-dlp-args-${scenario}.bin"
    export MOCK_ARG_LOG
    : >"${MOCK_ARG_LOG}"
}

read_arguments() {
    local file=$1
    local output_array=$2
    local -n output_ref=${output_array}
    output_ref=()
    [[ -f ${file} ]] || fail "Argument log is missing: ${file}"
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

assert_array_not_contains() {
    local array_name=$1
    local unexpected=$2
    local label=$3
    local -n array_ref=${array_name}
    local value

    for value in "${array_ref[@]}"; do
        [[ ${value} != "${unexpected}" ]] ||
            fail "${label}: unexpected array element: ${unexpected}"
    done
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
                ((index + 1 < ${#array_ref[@]})) ||
                    fail "${label}: ${option} has no following value"
                assert_equals "${expected_value}" "${array_ref[index + 1]}" "${label}"
                return 0
            fi
        fi
    done

    fail "${label}: occurrence ${desired_occurrence} of ${option} was not found"
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
    if [[ -r ${children_file} ]] &&
        { IFS= read -r children <"${children_file}" || [[ -n ${children} ]]; } &&
        [[ " ${children} " == *" ${probe_pid} "* ]]; then
        kill -TERM -- "${probe_pid}" 2>/dev/null || true
        wait "${probe_pid}" 2>/dev/null || true
        return 0
    fi

    kill -TERM -- "${probe_pid}" 2>/dev/null || true
    wait "${probe_pid}" 2>/dev/null || true
    return 1
}

find_test_processes() {
    local cmdline_file
    local pid
    local cmdline
    TEST_PROCESS_PIDS=()

    for cmdline_file in /proc/[0-9]*/cmdline; do
        [[ -r ${cmdline_file} ]] || continue
        pid=${cmdline_file#/proc/}
        pid=${pid%/cmdline}
        [[ ${pid} =~ ^[1-9][0-9]*$ ]] || continue
        [[ ${pid} != "$$" && ${pid} != "${BASHPID}" ]] || continue

        cmdline=$(tr '\0' ' ' <"${cmdline_file}" 2>/dev/null) || continue
        [[ ${cmdline} == *"${TEST_ROOT}"* ]] || continue
        TEST_PROCESS_PIDS+=("${pid}")
    done
}

assert_no_test_processes() {
    local label=$1
    local attempt
    local pid
    local cmdline=''

    for ((attempt = 0; attempt < 50; attempt++)); do
        find_test_processes
        ((${#TEST_PROCESS_PIDS[@]} == 0)) && return 0
        sleep 0.1
    done

    printf 'FAIL: %s\n' "${label}" >&2
    for pid in "${TEST_PROCESS_PIDS[@]}"; do
        if [[ -r /proc/${pid}/cmdline ]]; then
            cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
        else
            cmdline='<unavailable>'
        fi
        printf 'Leaked process %s: %s\n' "${pid}" "${cmdline}" >&2
        kill -TERM -- "${pid}" 2>/dev/null || true
    done

    sleep 0.2
    for pid in "${TEST_PROCESS_PIDS[@]}"; do
        kill -KILL -- "${pid}" 2>/dev/null || true
    done
    exit 1
}

cleanup_test_processes() {
    local pid

    set +e
    find_test_processes
    for pid in "${TEST_PROCESS_PIDS[@]}"; do
        kill -TERM -- "${pid}" 2>/dev/null || true
    done
    sleep 0.2
    find_test_processes
    for pid in "${TEST_PROCESS_PIDS[@]}"; do
        kill -KILL -- "${pid}" 2>/dev/null || true
    done
    set -e
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

    cleanup_test_processes
    if [[ -n ${TEST_ROOT:-} && ${TEST_ROOT} == /* && ${TEST_ROOT} != / ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
    exit "${status}"
}

trap cleanup_test_root EXIT

# Exercise the ownership guard explicitly. This subshell installs the same
# cleanup trap, but it must not remove the parent suite's workspace.
printf '%s\n' 'Mock scenario: cleanup-owner-guard'
(
    trap cleanup_test_root EXIT
    :
)
[[ -d ${TEST_ROOT} ]] ||
    fail 'A non-owner Bash process removed the complete test root.'

TEST_PROCESS_PIDS=()

export HOME="${HOME_DIR}"
export XDG_CONFIG_HOME="${HOME_DIR}/.config"
export XDG_STATE_HOME="${HOME_DIR}/.local/state"
export XDG_DATA_HOME="${HOME_DIR}/.local/share"
export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
export MOCK_OUTPUT_DIR="${OUTPUT_DIR}"
export MOCK_LIST_ARGS_LOG="${LIST_ARGS_LOG}"
export PATH="${MOCK_BIN}:/usr/bin:/bin"

for mocked_command in yt-dlp aria2c deno zenity ffmpeg ffprobe mv setsid; do
    resolved_mock=$(command -v "${mocked_command}")
    assert_equals "${MOCK_BIN}/${mocked_command}" "${resolved_mock}" \
        "${mocked_command} mock selection"
done

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
LC_ALL=C touch -d '16 days ago' -- \
    "${old_retained_log}" "${unrelated_old_file}" "${symlink_target}"
LC_ALL=C touch -d '14 days ago' -- "${recent_retained_log}"
ln -s -- "${symlink_target}" "${symlink_log}"

prepare_argument_log 'log-retention'
env XDG_STATE_HOME="${rotation_state_home}" \
    XDG_CONFIG_HOME="${rotation_config_home}" \
    MOCK_USE_DEFAULT_PROFILE=1 \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_no_test_processes 'log-retention GUI run left worker processes'

[[ ! -e ${old_retained_log} ]] ||
    fail 'A retained diagnostic log older than 15 days was not removed.'
[[ -f ${recent_retained_log} ]] ||
    fail 'A retained diagnostic log newer than 15 days was removed.'
[[ -f ${unrelated_old_file} ]] ||
    fail 'Log cleanup removed an unrelated old file.'
[[ -L ${symlink_log} ]] ||
    fail 'Log cleanup removed a symbolic link matching the log pattern.'
[[ -f ${symlink_target} ]] ||
    fail 'Log cleanup removed the target of a symbolic link.'

# Engine audio mode: quoting, locale stabilization, option/value pairing, and
# result-path reporting.
prepare_argument_log 'audio-engine'
result_file="${TEST_ROOT}/engine-%-result.txt"
ffprobe_argument_log="${TEST_ROOT}/ffprobe-audio-args.bin"
injection_marker="${TEST_ROOT}/must-not-exist"
malicious_url="https://example.com/watch?v=abc123&x=\$(touch\$IFS${injection_marker})"
assert_status 0 'audio engine succeeds under a hostile inherited locale' \
    env LC_ALL=fr_FR.UTF-8 LANG=fr_FR.UTF-8 \
    MOCK_FFPROBE_ARG_LOG="${ffprobe_argument_log}" \
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
assert_option_value ffprobe_arguments '-select_streams' 'a:0' \
    'audio result FFprobe stream validation'
[[ ! -e ${injection_marker} ]] || fail 'The URL was interpreted as shell code.'

arguments=()
read_arguments "${MOCK_ARG_LOG}" arguments
assert_array_contains arguments '--ignore-config' 'yt-dlp ignores user configuration'
assert_array_contains arguments '--no-playlist' 'yt-dlp disables playlists'
assert_array_contains arguments '--no-overwrites' 'yt-dlp final-file overwrite protection'
assert_array_contains arguments '--no-post-overwrites' 'yt-dlp post-processing overwrite protection'
assert_array_not_contains arguments '--supervised-session' 'internal session option isolation'
assert_option_value arguments '--remote-components' 'ejs:npm' 'EJS remote component selector'
assert_option_value arguments '--format' 'ba/b' 'audio format selector'
assert_array_contains arguments '--extract-audio' 'audio extraction postprocessor'
assert_option_value arguments '--audio-format' 'best' 'audio output format'
assert_option_value arguments '--audio-quality' '0' 'fallback conversion quality'
assert_option_value arguments '--downloader' 'aria2c' 'default external downloader' 1
assert_option_value arguments '--downloader' 'dash,m3u8:native' \
    'fragmented-stream native downloader' 2
assert_option_value arguments '--downloader-args' \
    'aria2c:-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --no-netrc=true --console-log-level=warn --enable-color=false --truncate-console-readout=false --summary-interval=1 --show-console-readout=true --stderr=false' \
    'aria2 machine-progress arguments'
assert_array_not_contains arguments '--machine-progress' \
    'internal wrapper option isolation'
for forbidden_audio_format in mp3 m4a opus; do
    assert_array_not_contains arguments "${forbidden_audio_format}" \
        "removed audio format ${forbidden_audio_format}"
done
assert_array_contains arguments "${malicious_url}" 'URL preserved as one argument'
expected_output_template="${OUTPUT_DIR//%/%%}/%(title).160B [%(id).64B].%(ext)s"
assert_option_value arguments '--output' "${expected_output_template}" \
    'absolute escaped output template'
assert_array_not_contains arguments '--paths' 'legacy path option is absent'


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
assert_option_value aria_without_netrc_arguments '--downloader-args' \
    'aria2c:-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --console-log-level=warn --enable-color=false --truncate-console-readout=false --summary-interval=1 --show-console-readout=true --stderr=false' \
    'aria2 arguments omit unsupported optional netrc capability'

runtime_lock_dir="${XDG_RUNTIME_DIR}/yt-dlp-aria2-downloader"
[[ -d ${runtime_lock_dir} && ! -L ${runtime_lock_dir} ]] ||
    fail 'The engine did not create a private XDG runtime lock directory.'
runtime_lock_mode=$(stat -c '%a' -- "${runtime_lock_dir}")
assert_equals '700' "${runtime_lock_mode}" 'XDG runtime lock-directory permissions'
shopt -s nullglob
runtime_lock_files=("${runtime_lock_dir}"/*.lock)
shopt -u nullglob
((${#runtime_lock_files[@]} > 0)) ||
    fail 'The engine did not create a destination lock file.'
for runtime_lock_file in "${runtime_lock_files[@]}"; do
    [[ -f ${runtime_lock_file} && ! -L ${runtime_lock_file} ]] ||
        fail "Unsafe runtime lock entry: ${runtime_lock_file}"
    runtime_lock_mode=$(stat -c '%a' -- "${runtime_lock_file}")
    assert_equals '600' "${runtime_lock_mode}" 'destination lock-file permissions'
done

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
[[ ! -e ${missing_target_result} ]] || \
    fail 'An invalid result path was published.'


# Positional separator behavior.
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

# Engine video mode.
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
assert_option_value arguments '--downloader-args' \
    'aria2c:-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --no-netrc=true --console-log-level=warn --enable-color=false --truncate-console-readout=false --summary-interval=0' \
    'ordinary CLI aria2 arguments'
assert_text_not_contains "$(printf '%s\n' "${arguments[@]}")" \
    '--show-console-readout=true' 'machine progress disabled in ordinary CLI mode'


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
    'Simulated refusal to overwrite an existing final media file.' \
    'existing media collision diagnostic'
rm -f -- "${existing_audio_path}"

# Explicit authenticated YouTube HLS profile.
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
assert_option_value youtube_hls_arguments '--format' \
    '(bv*+ba/b)[protocol^=m3u8]' 'YouTube HLS format selector'
assert_option_value youtube_hls_arguments '--fixup' 'force' \
    'YouTube HLS MPEG-TS fixup policy'
assert_option_value youtube_hls_arguments '--downloader' 'dash,m3u8:native' \
    'YouTube HLS native downloader' 2
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
[[ -f "${OUTPUT_DIR}/Mock media [abc123].mkv" ]] ||
    fail 'The custom YouTube HLS remux did not create the MKV file.'
[[ ! -e "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] ||
    fail 'The repaired YouTube HLS MP4 intermediate was not removed.'
# shellcheck disable=SC2034 # Read indirectly through nameref helpers.
youtube_hls_ffmpeg_arguments=()
read_arguments "${youtube_hls_ffmpeg_args}" youtube_hls_ffmpeg_arguments
assert_option_value youtube_hls_ffmpeg_arguments '-c' 'copy' \
    'YouTube HLS final remux uses stream copy'
assert_array_contains youtube_hls_ffmpeg_arguments \
    "${OUTPUT_DIR}/Mock media [abc123].mp4" \
    'YouTube HLS remux reads the fixed MP4 intermediate'

hls_existing_target="${OUTPUT_DIR}/Mock media [abc123].mkv"
printf 'preserve existing MKV\n' >"${hls_existing_target}"
hls_collision_result="${TEST_ROOT}/youtube-hls-collision-result.txt"
prepare_argument_log 'youtube-hls-existing-target'
assert_status 13 'YouTube HLS refuses to overwrite an existing MKV' \
    "${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" --mode video \
    --youtube-hls-firefox \
    --result-file "${hls_collision_result}" \
    -- 'https://www.youtube.com/watch?v=youtube-hls-collision'
assert_file_has_line "${hls_existing_target}" 'preserve existing MKV' \
    'existing YouTube HLS MKV is preserved'
assert_text_contains "${ASSERT_OUTPUT}" \
    'final MKV already exists; refusing to overwrite it' \
    'existing YouTube HLS MKV diagnostic'
[[ ! -e ${hls_collision_result} ]] ||
    fail 'An HLS target collision published a result file.'
[[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] ||
    fail 'An HLS target collision did not retain the repaired MP4.'
rm -f -- "${hls_existing_target}" "${OUTPUT_DIR}/Mock media [abc123].mp4"

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
[[ ! -e ${youtube_hls_failed_result} ]] ||
    fail 'A failed YouTube HLS remux published a result file.'
[[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] ||
    fail 'A failed YouTube HLS remux did not preserve the fixed MP4 intermediate.'
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
((${#youtube_hls_path_files[@]} == 0)) ||
    fail 'The YouTube HLS CLI run left an internal result-path file.'
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

# Clear engine error paths before yt-dlp download invocation.
prepare_argument_log 'invalid-output'
assert_status 1 'nonexistent output directory is rejected' \
    "${PROJECT_DIR}/download-video.sh" \
    --output-dir "${TEST_ROOT}/does-not-exist" \
    -- 'https://example.com/watch?v=bad-output'
assert_text_contains "${ASSERT_OUTPUT}" 'destination directory does not exist' \
    'nonexistent output diagnostic'

assert_status 13 'missing result-file parent is rejected' \
    "${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" \
    --result-file "${TEST_ROOT}/missing-parent/result.txt" \
    -- 'https://example.com/watch?v=bad-result-parent'
assert_text_contains "${ASSERT_OUTPUT}" 'result-file directory is not writable' \
    'missing result parent diagnostic'

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
    env MOCK_YTDLP_EXIT_STATUS=7 MOCK_WRITE_RESULT_BEFORE_FAILURE=1 \
    "${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" \
    --result-file "${atomic_result_file}" \
    -- 'https://example.com/watch?v=atomic-result'
[[ ! -e ${atomic_result_file} ]] ||
    fail 'A failed engine run published a stale or partial result file.'


# A second engine instance targeting the same canonical destination must fail
# before yt-dlp can manipulate shared .part, merge, or remux files.
# Use the exact runtime lock directory selected by the engine. Locking the
# historical /tmp fallback would exercise a different inode whenever the
# validated XDG_RUNTIME_DIR is available.
lock_root="${XDG_RUNTIME_DIR}/yt-dlp-aria2-downloader"
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
flock --unlock "${held_lock_fd}"
exec {held_lock_fd}>&-

# GUI progress from aria2c, including an unknown total size.
trimmed_gui_url='https://example.com/watch?v=trimmed'
prepare_argument_log 'gui-aria-percent'
MOCK_ZENITY_ENTRY_VALUE="  ${trimmed_gui_url}  " \
MOCK_ARIA_ONLY=1 \
MOCK_PROGRESS_CAPTURE="${PROGRESS_CAPTURE}" \
    "${PROJECT_DIR}/download-video-gui.sh"
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
assert_option_value gui_arguments '--downloader-args' \
    'aria2c:-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true --no-netrc=true --console-log-level=warn --enable-color=false --truncate-console-readout=false --summary-interval=1 --show-console-readout=true --stderr=false' \
    'machine-progress aria2 readout remains visible on stdout'
assert_array_contains gui_arguments "${trimmed_gui_url}" 'trimmed GUI URL'
assert_array_not_contains gui_arguments "  ${trimmed_gui_url}  " \
    'untrimmed GUI URL is absent'

prepare_argument_log 'gui-aria-unknown-size'
aria_unknown_capture="${TEST_ROOT}/gui-progress-aria-unknown.txt"
MOCK_ARIA_NO_PERCENT=1 \
MOCK_PROGRESS_CAPTURE="${aria_unknown_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_file_contains "${aria_unknown_capture}" \
    '# Downloading the audio track - size unknown (aria2c) - 1.00MiB' \
    'aria2 progress without a known total size'

# shellcheck disable=SC2034 # Read indirectly through nameref helpers.
list_arguments=()
read_arguments "${LIST_ARGS_LOG}" list_arguments
for expected_profile_label in \
    'Complete video (MKV)' \
    'YouTube video - Firefox cookies (HLS/MKV)' \
    'Audio track (native format)'; do
    assert_array_contains list_arguments "${expected_profile_label}" \
        "GUI profile label ${expected_profile_label}"
done
for removed_profile_label in 'Audio - MP3' 'Audio - M4A' 'Audio - Opus'; do
    assert_array_not_contains list_arguments "${removed_profile_label}" \
        "removed GUI profile ${removed_profile_label}"
done

prepare_argument_log 'gui-ytdlp-progress'
MOCK_PROGRESS_CAPTURE="${YTDLP_PROGRESS_CAPTURE}" \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_file_has_line "${YTDLP_PROGRESS_CAPTURE}" '15' \
    'yt-dlp progress maps into the global download phase'
assert_file_contains "${YTDLP_PROGRESS_CAPTURE}" \
    '# Downloading the audio track - 12% - 1.00MiB/s - 00:07 remaining' \
    'yt-dlp progress message'

prepare_argument_log 'gui-video'
MOCK_PROFILE='Complete video (MKV)' \
    "${PROJECT_DIR}/download-video-gui.sh"
# shellcheck disable=SC2034 # Read indirectly through nameref helpers.
video_gui_arguments=()
read_arguments "${MOCK_ARG_LOG}" video_gui_arguments
assert_option_value video_gui_arguments '--format' 'bv*+ba/b' \
    'GUI video format selection'
assert_array_not_contains video_gui_arguments 'ba/b' \
    'GUI video run does not use audio-only selector'

prepare_argument_log 'gui-youtube-hls'
MOCK_PROFILE='YouTube video - Firefox cookies (HLS/MKV)' \
MOCK_ZENITY_ENTRY_VALUE='https://www.youtube.com/watch?v=gui-youtube-hls' \
    "${PROJECT_DIR}/download-video-gui.sh"
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
    "${PROJECT_DIR}/download-video-gui.sh"
# shellcheck disable=SC2034 # Read indirectly through nameref helpers.
youtube_hls_default_arguments=()
read_arguments "${MOCK_ARG_LOG}" youtube_hls_default_arguments
assert_option_value youtube_hls_default_arguments '--cookies-from-browser' 'firefox' \
    'persisted GUI YouTube HLS profile'
rm -f -- "${OUTPUT_DIR}/Mock media [abc123].mkv"

# Post-processing progress must never regress.
prepare_argument_log 'gui-late-progress'
late_progress_capture="${TEST_ROOT}/gui-progress-late.txt"
MOCK_LATE_PROGRESS=1 \
MOCK_PROGRESS_CAPTURE="${late_progress_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
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

# Legacy and malformed configuration recovery.
cat >"${config_file}" <<EOF_OLD_CONFIG
output_dir=${OUTPUT_DIR}
profile=audio-mp3
EOF_OLD_CONFIG
prepare_argument_log 'legacy-profile'
MOCK_USE_DEFAULT_PROFILE=1 "${PROJECT_DIR}/download-video-gui.sh"
assert_file_has_line "${config_file}" 'profile=audio' 'legacy profile migration'

cat >"${config_file}" <<'EOF_BAD_CONFIG'
malformed line
unknown=value
profile=invalid
EOF_BAD_CONFIG
prepare_argument_log 'malformed-config'
MOCK_USE_DEFAULT_PROFILE=1 "${PROJECT_DIR}/download-video-gui.sh"
assert_file_has_line "${config_file}" 'profile=video' \
    'malformed configuration falls back to video'

printf 'output_dir=%s\nprofile=audio' "${OUTPUT_DIR}" >"${config_file}"
prepare_argument_log 'config-without-final-newline'
MOCK_USE_DEFAULT_PROFILE=1 "${PROJECT_DIR}/download-video-gui.sh"
assert_file_has_line "${config_file}" 'profile=audio' \
    'configuration final line without newline is loaded'

printf 'output_dir=%s\r\nprofile=audio\r\n' \
    "${OUTPUT_DIR}" >"${config_file}"
prepare_argument_log 'config-crlf'
MOCK_USE_DEFAULT_PROFILE=1 "${PROJECT_DIR}/download-video-gui.sh"
assert_file_has_line "${config_file}" 'profile=audio' \
    'CRLF configuration values are normalized when loaded'


# Relative XDG configuration/state paths are invalid and must fall back to HOME.
relative_config_dir="${PROJECT_DIR}/relative-config-home"
relative_state_dir="${PROJECT_DIR}/relative-state-home"
rm -rf -- "${relative_config_dir}" "${relative_state_dir}"
prepare_argument_log 'relative-xdg-home-fallback'
env XDG_CONFIG_HOME='relative-config-home' \
    XDG_STATE_HOME='relative-state-home' \
    MOCK_USE_DEFAULT_PROFILE=1 \
    "${PROJECT_DIR}/download-video-gui.sh"
[[ ! -e ${relative_config_dir} && ! -e ${relative_state_dir} ]] ||
    fail 'The GUI used a relative XDG configuration or state path.'
assert_file_has_line \
    "${HOME}/.config/yt-dlp-aria2-downloader/gui.conf" \
    "output_dir=${OUTPUT_DIR}" \
    'relative XDG homes fall back to HOME'

# File chooser fallback after a GTK/Zenity initial-directory failure.
file_selection_args_log="${TEST_ROOT}/file-selection-args.bin"
: >"${file_selection_args_log}"
prepare_argument_log 'file-selection-fallback'
MOCK_ZENITY_FILE_STATUS_WITH_FILENAME=255 \
MOCK_ZENITY_FILE_ERROR='simulated initial-folder failure' \
MOCK_FILE_SELECTION_ARGS_LOG="${file_selection_args_log}" \
    "${PROJECT_DIR}/download-video-gui.sh" >/dev/null
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

# Diagnostic log policy.
logs_before=$(count_logs)
prepare_argument_log 'inconsistent-result'
assert_status 1 'missing final path is reported as a failed GUI run' \
    env MOCK_SKIP_RESULT_FILE=1 "${PROJECT_DIR}/download-video-gui.sh"
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
[[ ${log_record_found} == true ]] ||
    fail 'No retained inconsistent-run log contains the post-processing record.'

outside_result_path="${TEST_ROOT}/outside-result.webm"
logs_before=$(count_logs)
prepare_argument_log 'result-outside-output-dir'
assert_status 1 'GUI rejects a result outside the selected destination folder' \
    env MOCK_RESULT_OUTSIDE_OUTPUT=1 \
    MOCK_OUTSIDE_RESULT_PATH="${outside_result_path}" \
    "${PROJECT_DIR}/download-video-gui.sh"
logs_after=$(count_logs)
assert_equals "$((logs_before + 1))" "${logs_after}" \
    'an outside-directory result retains one diagnostic log'
[[ -f ${outside_result_path} ]] ||
    fail 'The outside-directory mock result was not created.'
rm -f -- "${outside_result_path}"

logs_before=$(count_logs)
prepare_argument_log 'failed-download'
assert_status 7 'failed GUI download status is propagated' \
    env MOCK_YTDLP_EXIT_STATUS=7 "${PROJECT_DIR}/download-video-gui.sh"
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
[[ ${failure_record_found} == true ]] ||
    fail 'No retained log contains the simulated failure.'

# Initialization failures must be visible when the GUI is launched without a terminal.
blocked_state_home="${TEST_ROOT}/blocked-state-home"
: >"${blocked_state_home}"
state_error_capture="${TEST_ROOT}/state-init-error.txt"
prepare_argument_log 'state-directory-error'
assert_status 1 'state-directory creation failure is reported in the GUI' \
    env XDG_STATE_HOME="${blocked_state_home}" \
    MOCK_USE_DEFAULT_PROFILE=1 \
    MOCK_ERROR_CAPTURE="${state_error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_file_contains "${state_error_capture}" \
    'Unable to create the application state directory.' \
    'state-directory GUI diagnostic'


# A signal sent only to the CLI wrapper PID must reach the isolated yt-dlp
# process group and must not leave aria2c/FFmpeg-style descendants behind.
cli_started_marker="${TEST_ROOT}/cli-worker-started"
cli_termination_marker="${TEST_ROOT}/cli-worker-terminated"
cli_signal_log="${TEST_ROOT}/cli-signal.log"
prepare_argument_log 'cli-signal-forwarding'
env MOCK_LONG_DOWNLOAD=1 \
    MOCK_STARTED_MARKER="${cli_started_marker}" \
    MOCK_TERMINATION_MARKER="${cli_termination_marker}" \
    "${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" --mode audio \
    -- 'https://example.com/watch?v=cli-signal' \
    >"${cli_signal_log}" 2>&1 &
cli_engine_pid=$!
wait_for_file "${cli_started_marker}" 10 'CLI worker startup'
kill -TERM -- "${cli_engine_pid}"
cli_engine_status=0
wait "${cli_engine_pid}" || cli_engine_status=$?
assert_equals '143' "${cli_engine_status}" 'CLI TERM exit status'
wait_for_file "${cli_termination_marker}" 10 'CLI child process receives TERM'
assert_no_test_processes 'CLI signal forwarding left worker processes'


# A signal sent only to the CLI wrapper during the custom HLS FFmpeg remux must
# reach FFmpeg and preserve the requested shell exit status.
ffmpeg_started_marker="${TEST_ROOT}/ffmpeg-worker-started"
ffmpeg_termination_marker="${TEST_ROOT}/ffmpeg-worker-terminated"
ffmpeg_signal_log="${TEST_ROOT}/ffmpeg-signal.log"
prepare_argument_log 'cli-ffmpeg-signal-forwarding'
env MOCK_LONG_FFMPEG=1 \
    MOCK_FFMPEG_STARTED_MARKER="${ffmpeg_started_marker}" \
    MOCK_FFMPEG_TERMINATION_MARKER="${ffmpeg_termination_marker}" \
    "${PROJECT_DIR}/download-video.sh" \
    --output-dir "${OUTPUT_DIR}" --mode video \
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

# The GUI owns exactly one setsid session; the engine must reuse it.
single_session_log="${TEST_ROOT}/single-session-setsid.log"
prepare_argument_log 'single-session-gui'
assert_status 0 'GUI and engine use one shared process session' \
    env MOCK_SETSID_LOG="${single_session_log}" \
    "${PROJECT_DIR}/download-video-gui.sh"
single_session_calls=$(wc -l <"${single_session_log}")
assert_equals '1' "${single_session_calls}" \
    'one setsid invocation per GUI download'

# User cancellation terminates the complete process group.
termination_marker="${TEST_ROOT}/terminated"
prepare_argument_log 'cancel-process-group'
assert_status_split 130 'cancellation terminates the process group' \
    timeout --signal=TERM --kill-after=2s 15s \
    env MOCK_LONG_DOWNLOAD=1 MOCK_CANCEL=1 \
    MOCK_TERMINATION_MARKER="${termination_marker}" \
    "${PROJECT_DIR}/download-video-gui.sh"
wait_for_file "${termination_marker}" 10 'worker group receives TERM'
assert_no_test_processes 'ordinary cancellation left worker processes'

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
        "${PROJECT_DIR}/download-video-gui.sh"
    wait_for_file "${pgid_delay_marker}" 10 'delayed PGID worker receives TERM'
    assert_no_test_processes 'delayed-PGID cancellation left worker processes'
else
    printf '%s\n' 'Mock scenario: delayed-pgid-publication (skipped: procfs child visibility unavailable)'
fi

# A Cancel response received after a successful worker exit must be reported as
# success, not as a misleading cancellation.
prepare_argument_log 'cancel-after-worker-success'
assert_status 0 'late cancellation does not hide completed download' \
    env MOCK_CANCEL_AFTER_EOF=1 "${PROJECT_DIR}/download-video-gui.sh"
assert_no_test_processes 'late-cancel success left worker processes'

# A failed PGID publication uses actual newline characters in the error dialog.
pgid_error_capture="${TEST_ROOT}/pgid-start-error.txt"
prepare_argument_log 'failed-pgid-publication'
assert_status 1 'failed PGID publication is reported' \
    env MOCK_SETSID_START_STATUS=75 MOCK_ERROR_CAPTURE="${pgid_error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
pgid_error_text=$(<"${pgid_error_capture}")
assert_text_contains "${pgid_error_text}" \
    $'The download could not start.\n\nLog:' \
    'startup error uses real newlines'
assert_text_not_contains "${pgid_error_text}" '\\n\\nLog:' \
    'startup error has no literal newline escapes'

# Zenity dialog status mapping.
error_capture="${TEST_ROOT}/zenity-errors.txt"
assert_status 1 'URL entry timeout is reported' \
    env MOCK_ZENITY_ENTRY_STATUS=5 MOCK_ERROR_CAPTURE="${error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_file_contains "${error_capture}" 'URL entry dialog timed out' \
    'URL timeout dialog'

: >"${error_capture}"
assert_status 1 'unexpected Zenity entry error is reported' \
    env MOCK_ZENITY_ENTRY_STATUS=42 MOCK_ERROR_CAPTURE="${error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_file_contains "${error_capture}" 'Zenity could not display' \
    'Zenity entry error dialog'

# Runtime versions and capabilities.
for compatible_ytdlp_version in \
    '2026.06.09.20260727' \
    '2026.06.09-1.fc44' \
    '2026.06.09+custom'; do
    prepare_argument_log "version-${compatible_ytdlp_version//[^[:alnum:]]/_}"
    assert_status 0 "compatible yt-dlp version ${compatible_ytdlp_version}" \
        env MOCK_YTDLP_VERSION="${compatible_ytdlp_version}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=version-suffix'
done

assert_status 1 'unparseable yt-dlp version is rejected clearly' \
    env MOCK_YTDLP_VERSION=not-a-version \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=bad-version'
assert_text_contains "${ASSERT_OUTPUT}" 'unable to parse the yt-dlp version' \
    'unparseable yt-dlp diagnostic'

prepare_argument_log 'immediate-worker-failure'
assert_status 23 'an immediate yt-dlp failure preserves its real status' \
    env MOCK_YTDLP_EXIT_STATUS=23 \
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
[[ ! -e ${invalid_probe_result} ]] || \
    fail 'A result file was published after FFprobe validation failed.'
assert_text_contains "${ASSERT_OUTPUT}" \
    'final media file failed FFprobe validation' \
    'FFprobe failure diagnostic'

assert_status 1 'old yt-dlp version is rejected' \
    env MOCK_YTDLP_VERSION=2026.06.08 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=old-yt-dlp'
assert_status 1 'old Deno version is rejected' \
    env MOCK_DENO_VERSION=2.2.9 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=old-deno'
assert_status 1 'old aria2c version is rejected' \
    env MOCK_ARIA2_VERSION=1.36.0 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=old-aria2'
assert_status 1 'minimum Deno prerelease is rejected' \
    env MOCK_DENO_VERSION=2.3.0-beta \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=prerelease-deno'
assert_status 1 'minimum aria2 prerelease is rejected' \
    env MOCK_ARIA2_VERSION=1.37.0-beta \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=prerelease-aria2'
assert_status 1 'missing aria2c capability is rejected' \
    env MOCK_ARIA2_DESCRIPTION_ONLY=1 \
    "${PROJECT_DIR}/download-video.sh" \
    -- 'https://example.com/watch?v=missing-aria2-option'

# Progress-dialog timeout and unexpected error terminate the worker group.
progress_timeout_marker="${TEST_ROOT}/progress-timeout-terminated"
progress_timeout_errors="${TEST_ROOT}/progress-timeout-errors.txt"
prepare_argument_log 'progress-timeout'
assert_status 1 'progress dialog timeout is propagated' \
    env MOCK_LONG_DOWNLOAD=1 MOCK_ZENITY_PROGRESS_STATUS=5 \
    MOCK_TERMINATION_MARKER="${progress_timeout_marker}" \
    MOCK_ERROR_CAPTURE="${progress_timeout_errors}" \
    "${PROJECT_DIR}/download-video-gui.sh"
wait_for_file "${progress_timeout_marker}" 10 \
    'progress-timeout worker receives TERM'
assert_file_contains "${progress_timeout_errors}" 'progress dialog timed out' \
    'progress-timeout diagnostic'

progress_error_marker="${TEST_ROOT}/progress-error-terminated"
progress_error_capture="${TEST_ROOT}/progress-error-errors.txt"
prepare_argument_log 'progress-error'
assert_status 1 'unexpected progress dialog status is reported' \
    env MOCK_LONG_DOWNLOAD=1 MOCK_ZENITY_PROGRESS_STATUS=42 \
    MOCK_TERMINATION_MARKER="${progress_error_marker}" \
    MOCK_ERROR_CAPTURE="${progress_error_capture}" \
    "${PROJECT_DIR}/download-video-gui.sh"
wait_for_file "${progress_error_marker}" 10 \
    'progress-error worker receives TERM'
assert_file_contains "${progress_error_capture}" 'status 42' \
    'unexpected progress status diagnostic'

# Missing Zenity is a dependency error, not a graphical crash.
no_zenity_bin="${TEST_ROOT}/no-zenity-bin"
mkdir -p -- "${no_zenity_bin}"
for required_command in bash chmod date dirname grep mkdir mktemp mv realpath rm setsid sleep stat flock sha256sum; do
    required_command_path=$(command -v "${required_command}") ||
        fail "Required host command was not found: ${required_command}"
    ln -s -- "${required_command_path}" \
        "${no_zenity_bin}/${required_command}"
done
assert_status 127 'missing Zenity is reported before GUI startup' \
    env PATH="${no_zenity_bin}" HOME="${HOME_DIR}" \
    "${PROJECT_DIR}/download-video-gui.sh"
assert_text_contains "${ASSERT_OUTPUT}" 'required command "zenity" was not found' \
    'missing Zenity diagnostic'

printf 'Mock integration tests passed.\n'
