#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/mock-integration.sh
# Purpose     : Exercise engine and GUI behavior with hermetic command mocks.
# ==============================================================================

set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck disable=SC1090
source "${PROJECT_DIR}/tests/lib/assert.sh"

readonly -a MOCK_GROUPS=(
    engine
    engine-core
    engine-hls
    engine-staging
    gui
    gui-progress
    gui-state
    signals
    runtime
    runtime-compat
    runtime-validation
)

MOCK_GROUP='all'

mock_usage() {
    cat <<'EOF_USAGE'
Usage: tests/mock-integration.sh [--group GROUP | --list-groups]

Run every mock scenario by default. GROUP is one of:
  engine          Complete engine aggregate, in historical scenario order.
  engine-core     Core audio/video, result, and failure behavior.
  engine-hls      Authenticated YouTube HLS and remux behavior.
  engine-staging  Private aria2 staging and crash recovery behavior.
  gui             Complete GUI aggregate, in historical scenario order.
  gui-progress    GUI progress rendering, profiles, and completion behavior.
  gui-state       GUI configuration, file selection, logs, and state behavior.
  signals         CLI/GUI signal forwarding and cancellation behavior.
  runtime         Complete runtime/validation aggregate.
  runtime-compat  Runtime versions, capabilities, and dependencies.
  runtime-validation  Worker, media, progress-error, and GUI dependency validation.
EOF_USAGE
}

parse_mock_arguments() {
    while (($# > 0)); do
        case $1 in
            --group)
                (($# >= 2)) || test_error '--group requires one argument.'
                MOCK_GROUP=$2
                shift
                ;;
            --group=*)
                MOCK_GROUP=${1#--group=}
                ;;
            --list-groups)
                printf '%s\n' "${MOCK_GROUPS[@]}"
                exit 0
                ;;
            -h | --help)
                mock_usage
                exit 0
                ;;
            *)
                test_error "unknown mock-integration option: $1"
                ;;
        esac
        shift
    done

    if [[ ${MOCK_GROUP} == all ]]; then
        return 0
    fi

    local group
    for group in "${MOCK_GROUPS[@]}"; do
        [[ ${MOCK_GROUP} == "${group}" ]] && return 0
    done
    test_error "unknown mock-integration group: ${MOCK_GROUP}"
}

mock_group_enabled() {
    (($# == 1)) || return 2
    [[ ${MOCK_GROUP} == all || ${MOCK_GROUP} == "$1" ]]
}

parse_mock_arguments "$@"

for required_command in \
    awk bash cat chmod date dirname env grep head install ln mkdir mkfifo mktemp mv readlink \
    realpath rm setsid sleep stat timeout touch tr flock sha256sum wc python3 find ps; do
    require_test_command "${required_command}"
done
[[ -r /proc/self/cmdline ]] \
    || test_error 'mock integration tests require a readable Linux /proc filesystem.'
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
readonly MANAGED_ENGINE_DIR="${TEST_ROOT}/managed-engine"
readonly MANAGED_ENGINE_UNDER_TEST="${MANAGED_ENGINE_DIR}/download-video.sh"
readonly MOCK_RUNTIME_MANAGER_LOG="${TEST_ROOT}/runtime-manager-args.bin"
GUI_SCENARIO_TIMEOUT_SECONDS=${MOCK_GUI_SCENARIO_TIMEOUT_SECONDS:-30}
[[ ${GUI_SCENARIO_TIMEOUT_SECONDS} =~ ^[0-9]{1,3}$ ]] || test_error 'MOCK_GUI_SCENARIO_TIMEOUT_SECONDS must be an integer between 1 and 120.'
GUI_SCENARIO_TIMEOUT_SECONDS=$((10#${GUI_SCENARIO_TIMEOUT_SECONDS}))
((GUI_SCENARIO_TIMEOUT_SECONDS >= 1 && GUI_SCENARIO_TIMEOUT_SECONDS <= 120)) || test_error 'MOCK_GUI_SCENARIO_TIMEOUT_SECONDS must be between 1 and 120.'
readonly GUI_SCENARIO_TIMEOUT_SECONDS
readonly GUI_UNDER_TEST="${MOCK_BIN}/download-video-gui-under-test"
readonly GUI_SIGNAL_UNDER_TEST="${MOCK_BIN}/download-video-gui-signal-under-test"
readonly GUI_SIGNAL_REGISTRATION_UNDER_TEST="${MOCK_BIN}/gui-signal-registration-under-test"
readonly GUI_GROUP_DESCENDANT_UNDER_TEST="${MOCK_BIN}/gui-group-descendant-under-test"
readonly GUI_GROUP_CHILD_UNDER_TEST="${MOCK_BIN}/gui-group-child-under-test"
readonly CLI_SIGNAL_REGISTRATION_UNDER_TEST="${MOCK_BIN}/cli-signal-registration-under-test"
export MOCK_GUI_REAL="${PROJECT_DIR}/download-video-gui.sh"
export MOCK_GUI_SCENARIO_TIMEOUT_SECONDS=${GUI_SCENARIO_TIMEOUT_SECONDS}
mkdir -p -- \
    "${MOCK_BIN}" "${OUTPUT_DIR}" "${HOME_DIR}" "${RUNTIME_DIR}" \
    "${MANAGED_ENGINE_DIR}"
chmod 700 -- "${RUNTIME_DIR}"

install -m 0755 -- "${PROJECT_DIR}/download-video.sh" "${MANAGED_ENGINE_UNDER_TEST}"
install -m 0644 -- \
    "${PROJECT_DIR}/private-aria2-plan.py" \
    "${MANAGED_ENGINE_DIR}/private-aria2-plan.py"
cat >"${MANAGED_ENGINE_DIR}/runtime-manager.sh" <<'EOF_RUNTIME_MANAGER'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_RUNTIME_MANAGER_LOG:?}"
printf '%s\0' "$@" >"${MOCK_RUNTIME_MANAGER_LOG}"
if [[ ${MOCK_RUNTIME_MANAGER_BLOCK:-0} == 1 ]]; then
    : "${MOCK_RUNTIME_STARTED_MARKER:?}"
    : "${MOCK_RUNTIME_TERMINATION_MARKER:?}"
    handle_runtime_signal() {
        local signal_name=$1
        local signal_status=$2

        printf '%s\n' "${signal_name}" \
            >"${MOCK_RUNTIME_TERMINATION_MARKER}"
        exit "${signal_status}"
    }
    trap 'handle_runtime_signal HUP 129' HUP
    trap 'handle_runtime_signal INT 130' INT
    trap 'handle_runtime_signal TERM 143' TERM
    printf '%s\n' started >"${MOCK_RUNTIME_STARTED_MARKER}"
    while :; do
        sleep 1
    done
fi
if [[ ${MOCK_RUNTIME_ATTESTATION_MALFORMED:-0} == 1 ]]; then
    printf '%s\n' 'runtime-contract=unsupported'
    exit 0
fi
if (($# != 2)) || [[ $1 != prepare || ($2 != update && $2 != require) ]]; then
    exit 64
fi
printf 'runtime-contract=1\n'
printf 'yt-dlp-path=%s\n' "${MOCK_MANAGED_YTDLP_PATH:?}"
printf 'yt-dlp-version=%s\n' "${MOCK_MANAGED_YTDLP_VERSION:-2026.06.09}"
printf 'deno-path=%s\n' "${MOCK_MANAGED_DENO_PATH:?}"
printf 'deno-version=%s\n' "${MOCK_MANAGED_DENO_VERSION:-2.3.0}"
EOF_RUNTIME_MANAGER
chmod 0755 -- "${MANAGED_ENGINE_DIR}/runtime-manager.sh"

cat >"${GUI_UNDER_TEST}" <<'EOF_GUI_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_GUI_REAL:?}"
: "${MOCK_GUI_SCENARIO_TIMEOUT_SECONDS:?}"

status=0
timeout --foreground --signal=TERM --kill-after=2s \
    "${MOCK_GUI_SCENARIO_TIMEOUT_SECONDS}s" \
    "${MOCK_GUI_REAL}" "$@" || status=$?

case ${status} in
    124 | 137)
        printf 'FAIL: bounded GUI scenario timed out after %ss (status %d).\n' \
            "${MOCK_GUI_SCENARIO_TIMEOUT_SECONDS}" "${status}" >&2
        ;;
    *) ;;
esac

exit "${status}"
EOF_GUI_TIMEOUT
chmod 0755 -- "${GUI_UNDER_TEST}"

cat >"${GUI_SIGNAL_UNDER_TEST}" <<'EOF_GUI_SIGNAL'
#!/usr/bin/env python3
import os
import signal
import sys

gui_path = os.environ["MOCK_GUI_REAL"]
pid_file = os.environ["MOCK_GUI_SIGNAL_PID_FILE"]
pid_temporary = f"{pid_file}.tmp"

# A command backgrounded by a non-interactive Bash inherits SIGINT ignored.
# Reset the production-facing signals before exec so the GUI can install the
# same traps it receives from a desktop launcher or foreground terminal.
for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signal_number, signal.SIG_DFL)

descriptor = os.open(
    pid_temporary,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
    0o600,
)
with os.fdopen(descriptor, "w", encoding="ascii") as pid_stream:
    pid_stream.write(f"{os.getpid()}\n")
os.replace(pid_temporary, pid_file)
os.execvpe("bash", ["bash", gui_path, *sys.argv[1:]], os.environ)
EOF_GUI_SIGNAL
chmod 0755 -- "${GUI_SIGNAL_UNDER_TEST}"

cat >"${GUI_SIGNAL_REGISTRATION_UNDER_TEST}" <<'EOF_GUI_SIGNAL_REGISTRATION'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_GUI_SOURCE_COPY:?}"
: "${MOCK_WORKER_DEFERRED_STATUS_MARKER:?}"
: "${MOCK_WORKER_IDENTITY:?}"
: "${MOCK_WORKER_LAUNCH_STATE_MARKER:?}"
: "${MOCK_WORKER_PRE_REGISTRATION_MARKER:?}"

# The test creates this copy by removing the statically enforced final main
# invocation. This loads the production functions without entering the GUI.
# shellcheck disable=SC1090
source "${MOCK_GUI_SOURCE_COPY}"
trap cleanup EXIT

begin_signal_registration
WORKER_IDENTITY_TOKEN="${MOCK_WORKER_IDENTITY}.token"
YTDLP_ARIA2_GUI_WORKER_TOKEN="${WORKER_IDENTITY_TOKEN}" \
    bash -c 'exec -a "$1" sleep 30' bash "${MOCK_WORKER_IDENTITY}" &
printf '%s\n' "${SIGNAL_REGISTRATION_ACTIVE}" \
    >"${MOCK_WORKER_LAUNCH_STATE_MARKER}"
handle_gui_signal 143
WORKER_PID=$!
worker_start_time=''
# shellcheck disable=SC2310 # Fixture reproduces production identity registration before signal replay.
process_is_direct_child_of \
    "${WORKER_PID}" "${BASHPID}" worker_start_time true \
    || exit 70
WORKER_PID_START_TIME=${worker_start_time}
printf '%s\n' "${WORKER_PID}" >"${MOCK_WORKER_PRE_REGISTRATION_MARKER}"
printf '%s\n' "${DEFERRED_SIGNAL_STATUS}" \
    >"${MOCK_WORKER_DEFERRED_STATUS_MARKER}"
finish_signal_registration
exit 70
EOF_GUI_SIGNAL_REGISTRATION
chmod 0755 -- "${GUI_SIGNAL_REGISTRATION_UNDER_TEST}"

cat >"${GUI_GROUP_CHILD_UNDER_TEST}" <<'EOF_GUI_GROUP_CHILD'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_GROUP_CHILD_READY_MARKER:?}"
: "${MOCK_GROUP_TERMINATION_MARKER:?}"

handle_group_child_signal() {
    printf '%s\n' TERM >"${MOCK_GROUP_TERMINATION_MARKER}"
    exit 143
}

trap handle_group_child_signal TERM
trap '' HUP
printf '%s\n' "${BASHPID}" >"${MOCK_GROUP_CHILD_READY_MARKER}"
while :; do
    sleep 0.1
done
EOF_GUI_GROUP_CHILD
chmod 0755 -- "${GUI_GROUP_CHILD_UNDER_TEST}"

cat >"${GUI_GROUP_DESCENDANT_UNDER_TEST}" <<'EOF_GUI_GROUP_DESCENDANT'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_GUI_SOURCE_COPY:?}"
: "${MOCK_GROUP_CHILD_UNDER_TEST:?}"
: "${MOCK_GROUP_CHILD_READY_MARKER:?}"
: "${MOCK_GROUP_LEADER_RELEASE_MARKER:?}"
: "${MOCK_GROUP_TERMINATION_MARKER:?}"
: "${MOCK_WORKER_IDENTITY:?}"
: "${REAL_SETSID:?}"

# Load the production GUI supervision functions without entering main.
# shellcheck disable=SC1090
source "${MOCK_GUI_SOURCE_COPY}"
trap cleanup EXIT

WORKER_IDENTITY_TOKEN="${MOCK_WORKER_IDENTITY}.token"
begin_signal_registration
YTDLP_ARIA2_GUI_WORKER_TOKEN="${WORKER_IDENTITY_TOKEN}" \
    "${REAL_SETSID}" --wait bash -c '
        group_child=$1
        child_ready_marker=$2
        leader_release_marker=$3
        "${group_child}" &
        while [[ ! -s ${child_ready_marker} ]]; do
            sleep 0.01
        done
        while [[ ! -e ${leader_release_marker} ]]; do
            sleep 0.01
        done
        exit 0
    ' bash \
    "${MOCK_GROUP_CHILD_UNDER_TEST}" \
    "${MOCK_GROUP_CHILD_READY_MARKER}" \
    "${MOCK_GROUP_LEADER_RELEASE_MARKER}" &
WORKER_PID=$!
worker_start_time=''
# shellcheck disable=SC2310 # Fixture captures the same direct-child identity as production.
process_is_direct_child_of \
    "${WORKER_PID}" "${BASHPID}" worker_start_time true \
    || exit 70
WORKER_PID_START_TIME=${worker_start_time}
finish_signal_registration

for _ in {1..100}; do
    [[ -s ${MOCK_GROUP_CHILD_READY_MARKER} ]] || {
        sleep 0.01
        continue
    }
    # shellcheck disable=SC2310 # Group publication is deliberately recovered from /proc.
    if recover_worker_pgid "${WORKER_PID}"; then
        break
    fi
    sleep 0.01
done
[[ -n ${WORKER_PGID} ]] || exit 70
: >"${MOCK_GROUP_LEADER_RELEASE_MARKER}"

group_reauthenticated=false
for _ in {1..100}; do
    # shellcheck disable=SC2310 # The regression requires inherited-token identity after leader exit.
    if ! worker_pid_is_current true && worker_group_is_current; then
        group_reauthenticated=true
        break
    fi
    sleep 0.02
done
[[ ${group_reauthenticated} == true ]] || exit 70

# shellcheck disable=SC2310 # The regression requires complete authenticated shutdown.
stop_worker || exit 70
[[ -s ${MOCK_GROUP_TERMINATION_MARKER} ]] || exit 70
exit 0
EOF_GUI_GROUP_DESCENDANT
chmod 0755 -- "${GUI_GROUP_DESCENDANT_UNDER_TEST}"

cat >"${CLI_SIGNAL_REGISTRATION_UNDER_TEST}" <<'EOF_CLI_SIGNAL_REGISTRATION'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_CLI_SOURCE_COPY:?}"
: "${MOCK_WORKER_DEFERRED_STATUS_MARKER:?}"
: "${MOCK_WORKER_IDENTITY:?}"
: "${MOCK_WORKER_LAUNCH_STATE_MARKER:?}"
: "${MOCK_WORKER_PRE_REGISTRATION_MARKER:?}"
: "${MOCK_WORKER_SIGNAL_NAME:?}"
: "${MOCK_WORKER_SIGNAL_STATUS:?}"

# Load the production engine functions without entering main.
# shellcheck disable=SC1090
source "${MOCK_CLI_SOURCE_COPY}"
trap cleanup EXIT

begin_signal_registration
bash -c 'exec -a "$1" sleep 30' bash "${MOCK_WORKER_IDENTITY}" &
printf '%s\n' "${SIGNAL_REGISTRATION_ACTIVE}" \
    >"${MOCK_WORKER_LAUNCH_STATE_MARKER}"
request_shutdown "${MOCK_WORKER_SIGNAL_NAME}" \
    "${MOCK_WORKER_SIGNAL_STATUS}"
DOWNLOAD_WORKER_PID=$!
# shellcheck disable=SC2310 # Fixture reproduces production identity registration before signal replay.
process_is_direct_child_of \
    "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
    DOWNLOAD_WORKER_START_TIME true \
    || exit 70
printf '%s\n' "${DOWNLOAD_WORKER_PID}" \
    >"${MOCK_WORKER_PRE_REGISTRATION_MARKER}"
printf '%s\n' "${DEFERRED_SIGNAL_STATUS}" \
    >"${MOCK_WORKER_DEFERRED_STATUS_MARKER}"
finish_signal_registration
stop_download_worker || true
exit "${REQUESTED_EXIT_STATUS:-70}"
EOF_CLI_SIGNAL_REGISTRATION
chmod 0755 -- "${CLI_SIGNAL_REGISTRATION_UNDER_TEST}"

cat >"${MOCK_BIN}/yt-dlp" <<'EOF_YTDLP'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${YTDLP_NO_PLUGINS:-} != 1 ]]; then
    printf 'yt-dlp plugins were not disabled by the wrapper.\n' >&2
    exit 67
fi

probe_operation=''
probe_ignore_config=false
probe_no_plugin_dirs=false
probe_no_update=false
for argument in "$@"; do
    case ${argument} in
        --ignore-config) probe_ignore_config=true ;;
        --no-plugin-dirs) probe_no_plugin_dirs=true ;;
        --no-update) probe_no_update=true ;;
        --version | --help) probe_operation=${argument} ;;
        *) ;;
    esac
done

if [[ -n ${probe_operation} ]]; then
    [[ ${probe_ignore_config} == true &&
        ${probe_no_plugin_dirs} == true &&
        ${probe_no_update} == true ]] || {
        printf 'yt-dlp probe isolation options are incomplete.\n' >&2
        exit 68
    }
fi

if [[ ${probe_operation} == '--version' ]]; then
    if [[ -n ${MOCK_YTDLP_CONTROL_LOG:-} ]]; then
        printf '%s\n' --version >>"${MOCK_YTDLP_CONTROL_LOG}"
    fi
    [[ ${LC_ALL:-} == C ]] || { printf 'localized yt-dlp version output\n'; exit 65; }
    if [[ -n ${MOCK_YTDLP_VERSION_DELAY_SECONDS:-} ]]; then
        sleep "${MOCK_YTDLP_VERSION_DELAY_SECONDS}"
    fi
    printf '%s\n' "${MOCK_YTDLP_VERSION:-2026.06.09}"
    exit 0
fi
if [[ ${probe_operation} == '--help' ]]; then
    if [[ -n ${MOCK_YTDLP_CONTROL_LOG:-} ]]; then
        printf '%s\n' --help >>"${MOCK_YTDLP_CONTROL_LOG}"
    fi
    [[ ${LC_ALL:-} == C ]] || { printf 'localized yt-dlp help output\n'; exit 65; }
    printf '%s\n' \
        '--js-runtimes' \
        '--remote-components' \
        '--break-match-filters FILTER' \
        '--no-update' \
        '--cookies-from-browser BROWSER[:PROFILE]' \
        '--extractor-args KEY:ARGS' \
        '-O, --print [WHEN:]TEMPLATE' \
        '--progress-template' \
        '--progress-delta SECONDS' \
        '--print-to-file' \
        '--cookies FILE' \
        '--dump-single-json' \
        '--load-info-json FILE' \
        '--no-clean-info-json' \
        '--skip-download' \
        '--parse-metadata [WHEN:]FROM:TO' \
        '--fixup POLICY' \
        '--downloader-args' \
        '--no-overwrites' \
        '--no-post-overwrites' \
        '--batch-file FILE' \
        '--socket-timeout SECONDS' \
        '--retries RETRIES' \
        '--fragment-retries RETRIES' \
        '--ignore-config' \
        '--no-plugin-dirs' \
        '--extractor-retries RETRIES' \
        '--retry-sleep [TYPE:]EXPR' \
        '--no-playlist' \
        '--embed-metadata' \
        '--output TEMPLATE' \
        '--continue' \
        '--downloader [PROTO:]NAME' \
        '--concurrent-fragments N' \
        '--format FORMAT' \
        '--merge-output-format FORMAT' \
        '--remux-video FORMAT' \
        '--extract-audio' \
        '--audio-format FORMAT' \
        '--newline' \
        '--progress' \
        '--color STREAM:POLICY'
    if [[ ${MOCK_YTDLP_MISSING_AUDIO_QUALITY:-0} != 1 ]]; then
        printf '%s\n' '--audio-quality QUALITY'
    fi
    exit 0
fi

: "${MOCK_ARG_LOG:?}"
: "${MOCK_PLAN_ARG_LOG:?}"
: "${MOCK_POST_CALL_LOG:?}"
: "${MOCK_PLAN_CALL_LOG:?}"

dump_single_json=false
for argument in "$@"; do
    if [[ ${argument} == '--dump-single-json' ]]; then
        dump_single_json=true
        break
    fi
done

if [[ ${dump_single_json} == true ]]; then
    printf 'call\n' >>"${MOCK_PLAN_CALL_LOG}"
    printf '%s\0' "$@" >"${MOCK_PLAN_ARG_LOG}"
else
    printf 'call\n' >>"${MOCK_POST_CALL_LOG}"
    printf '%s\0' "$@" >"${MOCK_ARG_LOG}"
fi

batch_file=''
batch_previous=''
for argument in "$@"; do
    if [[ ${batch_previous} == '--batch-file' ]]; then
        batch_file=${argument}
        batch_previous=''
        continue
    fi
    if [[ ${argument} == '--batch-file' ]]; then
        batch_previous='--batch-file'
    fi
done
if [[ -n ${batch_file} && -n ${MOCK_URL_SEEN_LOG:-} ]]; then
    batch_url=''
    IFS= read -r batch_url <"${batch_file}"
    printf '%s\n' "${batch_url}" >"${MOCK_URL_SEEN_LOG}"
fi

plan_youtube_hls=false
youtube_hls_source_ext=${MOCK_YOUTUBE_HLS_SOURCE_EXT:-mp4}
case ${youtube_hls_source_ext} in
    mp4 | mkv) ;;
    *)
        printf 'Invalid mock YouTube HLS source extension: %s\n' \
            "${youtube_hls_source_ext}" >&2
        exit 64
        ;;
esac

for argument in "$@"; do
    case ${argument} in
        --dump-single-json)
            dump_single_json=true
            ;;
        --cookies-from-browser)
            plan_youtube_hls=true
            ;;
        *)
            ;;
    esac
done

if [[ ${dump_single_json} == true ]]; then
    if [[ ${MOCK_PLAN_EXIT_STATUS:-0} != 0 ]]; then
        if [[ ${MOCK_FORBIDDEN_EXTERNAL_ERROR:-0} == 1 ]]; then
            forbidden_source_name=$(printf '\170\150\141\155\163\164\145\162')
            printf 'Simulated %s extractor failure.\n' \
                "${forbidden_source_name}" >&2
        fi
        printf 'Simulated yt-dlp planning failure.\n' >&2
        exit "${MOCK_PLAN_EXIT_STATUS}"
    fi

    if [[ ${plan_youtube_hls} == true ]]; then
        plan_filename="${MOCK_OUTPUT_DIR}/Mock media [abc123].${youtube_hls_source_ext}"
        plan_protocol='m3u8_native'
        plan_url='https://example.invalid/mock-manifest.m3u8'
        plan_ext=${youtube_hls_source_ext}
    else
        plan_filename="${MOCK_OUTPUT_DIR}/Mock media [abc123].webm"
        plan_protocol='http'
        plan_url='https://example.invalid/mock-media.webm'
        plan_ext='webm'
    fi

    if [[ -n ${MOCK_PLAN_PROTOCOL:-} ]]; then
        plan_protocol=${MOCK_PLAN_PROTOCOL}
    fi

    printf \
        '{"requested_downloads":[{"filename":"%s","format_id":"mock","ext":"%s","protocol":"%s","url":"%s","http_headers":{"User-Agent":"mock-agent"}}]}\n' \
        "${plan_filename}" \
        "${plan_ext}" \
        "${plan_protocol}" \
        "${plan_url}"

    exit 0
fi

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
load_info_json=false
previous=''
for argument in "$@"; do
    case ${argument} in
    --no-overwrites) no_overwrites=true ;;
    --no-post-overwrites) no_post_overwrites=true ;;
    --load-info-json) load_info_json=true ;;
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

if [[ ${load_info_json} != true ]]; then
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
fi

if [[ ${MOCK_LONG_DOWNLOAD:-0} == 1 ]]; then
    # A single process installs its handlers before either startup jitter or
    # readiness publication, so a signal cannot terminate an interrupted Bash
    # child before the fixture records delivery.
    exec python3 -c '
import signal
import sys
import time

termination_marker = sys.argv[1]
started_marker = sys.argv[2]
startup_delay = float(sys.argv[3])


def terminate(signal_number, _frame):
    if termination_marker:
        with open(termination_marker, "w", encoding="utf-8") as marker:
            marker.write("terminated")
    raise SystemExit(128 + signal_number)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
time.sleep(startup_delay)
if started_marker:
    with open(started_marker, "w", encoding="utf-8") as marker:
        marker.write("started")
while True:
    signal.pause()
' "${MOCK_TERMINATION_MARKER:-}" \
        "${MOCK_STARTED_MARKER:-}" \
        "${MOCK_WORKER_START_JITTER_SECONDS:-0}"
fi

if [[ ${MOCK_EXIT_WITH_LIVE_DESCENDANT:-0} == 1 ]]; then
    bash -c '
        set -euo pipefail
        trap "" HUP INT
        if [[ ${MOCK_DESCENDANT_IGNORE_TERM:-0} == 1 ]]; then
            trap "" TERM
        else
            trap '\''printf terminated >"${MOCK_DESCENDANT_TERMINATION_MARKER:?}"; exit 143'\'' TERM
        fi
        printf "%s\n" "$$" >"${MOCK_DESCENDANT_STARTED_MARKER:?}"
        sleep 86400
    ' </dev/null >/dev/null 2>&1 &
    exit "${MOCK_DESCENDANT_PARENT_STATUS:-23}"
fi

if [[ ${load_info_json} != true ]]; then
    if [[ -z ${progress_ready_marker} ]]; then
        # Scenarios that must observe intermediate progress synchronize through
        # explicit marker files. Other scenarios need only a minimal scheduling
        # window; a production-sized polling delay adds no coverage here.
        sleep 0.05
    fi

    if [[ ${MOCK_ARIA_NO_PERCENT:-0} == 1 ]]; then
        printf '\r[#a1b2c3 10.0MiB/0B CN:1 DL:2.00MiB]\r'
    elif [[ ${MOCK_ARIA_ONLY:-0} == 1 ]]; then
        printf '\r[#a1b2c3 10.0MiB/10.0MiB(100%%) CN:1 DL:2.00MiB ETA:0s]\r'
    else
        printf 'YTDLP_PROGRESS|downloading|100.0%%|2.00MiB/s|00:00\n'
    fi
fi

printf 'YTDLP_POSTPROCESS|processing|FFmpegExtractAudio\n'
if [[ -n ${postprocess_ready_marker} ]]; then
    wait_for_marker "${postprocess_ready_marker}" 'post-processing progress'
elif [[ ${MOCK_LATE_PROGRESS:-0} == 1 ]]; then
    sleep 0.8
fi

if [[ ${MOCK_LATE_PROGRESS:-0} == 1 ]]; then
    printf 'YTDLP_PROGRESS|downloading| 12.0%%|512.00KiB/s|00:09\n'
    sleep 0.05
elif [[ -z ${postprocess_ready_marker} ]]; then
    sleep 0.05
fi

if [[ ${youtube_hls_mode} == true ]]; then
    output_path="${MOCK_OUTPUT_DIR}/Mock media [abc123].${youtube_hls_source_ext}"
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
    if [[ ${MOCK_BOUNDARY_LOG:-0} == 1 ]]; then
        boundary_padding=$(head -c 65536 -- /dev/zero | tr '\0' X)
        boundary_line="https://example.invalid/private?padding=${boundary_padding}BOUNDARY_SECRET"$'\n'
        trailer=$'https://example.invalid/private?token=COMPLETE_SECRET\nFINAL_MARKER\n'
        failure_line=$'Simulated yt-dlp failure.\n'
        filler_size=$((8388608 + 16384 \
            - ${#boundary_line} - ${#trailer} - ${#failure_line}))
        printf '%s' "${boundary_line}"
        head -c "${filler_size}" -- /dev/zero | tr '\0' Y
        printf '%s' "${trailer}"
    fi
    if [[ ${MOCK_FAILURE_DIAGNOSTIC_URL:-0} == 1 ]]; then
        printf '%s\n' \
            'https://example.invalid/private?token=UNSANITIZED_DIAGNOSTIC_SECRET'
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
if [[ ${MOCK_RESULT_TARGET_MISSING:-0} == 1 ]]; then
    # With the private aria2 pipeline, the direct-transfer component has
    # already been committed before yt-dlp POST starts. Remove it explicitly
    # to simulate a result path whose target disappeared before final
    # validation.
    rm -f -- "${output_path}"
else
    printf '%s\n' 'mock media payload' >"${output_path}"
fi
if [[ -n ${result_file} && ${MOCK_SKIP_RESULT_FILE:-0} != 1 ]]; then
    if [[ ${MOCK_PREPEND_STALE_RESULT:-0} == 1 ]]; then
        printf '%s\n' "${MOCK_OUTPUT_DIR}/stale-result.webm" >>"${result_file}"
    fi
    printf '%s\n' "${output_path}" >>"${result_file}"
    if [[ ${MOCK_REPLACE_RESULT_RECORD_AFTER_WRITE:-0} == 1 ]]; then
        result_record_path=$(readlink -- "${result_file}")
        if [[ ${result_record_path##*/} != .yt-dlp-result.* ]]; then
            printf 'Unexpected private result-record target: %s\n' \
                "${result_record_path}" >&2
            exit 70
        fi
        result_record_backup="${result_record_path}.authenticated-backup"
        "${REAL_MV:?}" -T -- \
            "${result_record_path}" "${result_record_backup}"
        printf '%s\n' 'foreign result-record replacement' \
            >"${result_record_path}"
        chmod 600 -- "${result_record_path}"
        rm -f -- "${result_record_backup}"
        printf '%s\n' "${result_record_path}" \
            >"${MOCK_REPLACED_RESULT_RECORD_PATH:?}"
    fi
fi
EOF_YTDLP
chmod +x "${MOCK_BIN}/yt-dlp"

cat >"${MOCK_BIN}/aria2c" <<'EOF_ARIA2'
#!/usr/bin/env bash
set -euo pipefail

case ${1:-} in
--version)
    [[ ${LC_ALL:-} == C ]] || { printf 'aria2 versión localizada\n'; exit 65; }
    printf 'aria2 version %s\n' "${MOCK_ARIA2_VERSION:-1.37.0}"
    if [[ -n ${MOCK_ARIA2_TLS_LIBRARY:-} ]]; then
        printf 'Libraries: %s\n' "${MOCK_ARIA2_TLS_LIBRARY}"
    fi
    ;;
--help=#all)
    [[ ${LC_ALL:-} == C ]] || { printf 'ayuda aria2 localizada\n'; exit 65; }
    printf '%s\n' \
        '--file-allocation=<METHOD>' \
        '--no-conf[=true|false]' \
        '-i, --input-file=FILE' \
        '-d, --dir=DIR' \
        '--load-cookies=FILE' \
        '--allow-overwrite[=true|false]' \
        '--auto-file-renaming[=true|false]'
    printf '%s\n' '-j, --max-concurrent-downloads=<N>'
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
    : "${MOCK_ARIA2_ARG_LOG:?}"
    printf '%s\0' "$@" >"${MOCK_ARIA2_ARG_LOG}"

    if [[ ${MOCK_ARIA2_EXIT_STATUS:-0} != 0 ]]; then
        printf '%s\n' \
            'Simulated aria2 failure for https://secret.example/private.' >&2
        exit "${MOCK_ARIA2_EXIT_STATUS}"
    fi

    input_file=''
    download_dir=''
    cookie_file=''

    for argument in "$@"; do
        case ${argument} in
            --input-file=*)
                input_file=${argument#*=}
                ;;
            --dir=*)
                download_dir=${argument#*=}
                ;;
            --load-cookies=*)
                cookie_file=${argument#*=}
                ;;
            *)
                ;;
        esac
    done

    if [[ -n ${cookie_file} ]]; then
        if [[ ! -f ${cookie_file} || -L ${cookie_file} ]]; then
            printf 'Unsafe aria2 cookie file: %s\n' "${cookie_file}" >&2
            exit 69
        fi
        cookie_mode=$(stat -c '%a' -- "${cookie_file}") || exit 69
        if [[ ${cookie_mode} != 600 ]]; then
            printf 'Unsafe aria2 cookie-file mode %s: %s\n' \
                "${cookie_mode}" "${cookie_file}" >&2
            exit 69
        fi
    fi

    if [[ -z ${input_file} || -z ${download_dir} ]]; then
        printf 'Unexpected aria2c mock invocation: %q\n' "$*" >&2
        exit 64
    fi

    if [[ ${MOCK_ARIA_NO_PERCENT:-0} == 1 ]]; then
        printf '\r[#a1b2c3 4.0MiB/0B CN:8 DL:1.00MiB]\r'
    else
        printf '\r[#a1b2c3 4.0MiB/10.0MiB(40%%) CN:8 DL:1.00MiB ETA:6s]\r'
    fi

    # Keep the intermediate aria2 state observable until the GUI progress
    # monitor has consumed it. Restrict this synchronization to scenarios
    # explicitly exercising aria2 progress so native/yt-dlp progress tests
    # cannot deadlock here.
    if [[ -n ${MOCK_PROGRESS_CAPTURE:-} &&
        (${MOCK_ARIA_ONLY:-0} == 1 || ${MOCK_ARIA_NO_PERCENT:-0} == 1) ]]; then
        progress_ready_marker="${MOCK_PROGRESS_CAPTURE}.progress-ready"
        progress_seen=false

        for ((attempt = 0; attempt < 100; attempt++)); do
            if [[ -f ${progress_ready_marker} ]]; then
                progress_seen=true
                break
            fi
            sleep 0.1
        done

        if [[ ${progress_seen} != true ]]; then
            printf 'Timed out waiting for aria2 progress marker: %s\n' \
                "${progress_ready_marker}" >&2
            exit 66
        fi
    fi

    if [[ ${MOCK_LONG_DOWNLOAD:-0} == 1 ]]; then
        sleep "${MOCK_WORKER_START_JITTER_SECONDS:-0}"
        # Publish readiness only after the long-running process has installed
        # its handlers. A Bash trap at the head of a pipeline can otherwise
        # exit from an interrupted child without running the trap body.
        exec python3 -c '
import signal
import sys

termination_marker = sys.argv[1]
started_marker = sys.argv[2]


def terminate(signal_number, _frame):
    if termination_marker:
        with open(termination_marker, "w", encoding="utf-8") as marker:
            marker.write("terminated")
    raise SystemExit(128 + signal_number)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
if started_marker:
    with open(started_marker, "w", encoding="utf-8") as marker:
        marker.write("started")
while True:
    signal.pause()
' "${MOCK_TERMINATION_MARKER:-}" "${MOCK_STARTED_MARKER:-}"
    fi

    while IFS= read -r input_line || [[ -n ${input_line} ]]; do
        case ${input_line} in
            '  out='*)
                output_name=${input_line#'  out='}
                printf '%s\n' 'mock aria2 media payload' \
                    >"${download_dir}/${output_name}"
                ;;
            *)
                ;;
        esac
    done <"${input_file}"

    if [[ ${MOCK_REPLACE_ARIA2_INPUT_BEFORE_EXIT:-0} == 1 ]]; then
        input_replacement="${input_file}.replacement"
        printf '%s\n' 'foreign aria2 input replacement' \
            >"${input_replacement}"
        chmod 600 -- "${input_replacement}"
        mv -Tf -- "${input_replacement}" "${input_file}"
    fi
    if [[ ${MOCK_REPLACE_ARIA2_MANIFEST_BEFORE_EXIT:-0} == 1 ]]; then
        manifest_path="${download_dir}/manifest.json"
        manifest_replacement="${manifest_path}.replacement"
        cp -- "${manifest_path}" "${manifest_replacement}"
        rm -f -- "${manifest_path}"
        mv -T -- "${manifest_replacement}" "${manifest_path}"
        chmod 600 -- "${manifest_path}"
    fi

    if [[ ${MOCK_ARIA_NO_PERCENT:-0} == 1 ]]; then
        printf '\r[#a1b2c3 10.0MiB/0B CN:1 DL:2.00MiB]\r'
    else
        printf '\r[#a1b2c3 10.0MiB/10.0MiB(100%%) CN:1 DL:2.00MiB ETA:0s]\r'
    fi
    ;;
esac
EOF_ARIA2
chmod +x "${MOCK_BIN}/aria2c"

cat >"${MOCK_BIN}/deno" <<'EOF_DENO'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${MOCK_DENO_CONTROL_LOG:-} ]]; then
    printf '%s\n' --version >>"${MOCK_DENO_CONTROL_LOG}"
fi
if [[ ${MOCK_DENO_UNAVAILABLE:-0} == 1 ]]; then
    exit 127
fi
[[ ${LC_ALL:-} == C ]] || { printf 'salida Deno localizada\n'; exit 65; }
printf 'deno %s (stable, release, x86_64-unknown-linux-gnu)\n' \
    "${MOCK_DENO_VERSION:-2.3.0}"
printf 'v8 0.0.0\n'
printf 'typescript 0.0.0\n'
EOF_DENO
chmod +x "${MOCK_BIN}/deno"

cat >"${MOCK_BIN}/ffmpeg" <<'EOF_FFMPEG'
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
    trap 'printf terminated >"${MOCK_FFMPEG_TERMINATION_MARKER:?}"; exit 143' TERM INT
    sleep "${MOCK_FFMPEG_START_JITTER_SECONDS:-0}"
    if [[ -n ${MOCK_FFMPEG_STARTED_MARKER:-} ]]; then
        printf started >"${MOCK_FFMPEG_STARTED_MARKER}"
    fi
    while true; do
        sleep 0.1
    done
fi
if [[ ${MOCK_FFMPEG_EXIT_STATUS:-0} != 0 ]]; then
    printf 'Simulated FFmpeg remux failure.\n' >&2
    exit "${MOCK_FFMPEG_EXIT_STATUS}"
fi
output_path=${!#}
if [[ -z ${output_path} || ${output_path} != /* || ${output_path} == -* ]]; then
    printf 'Invalid FFmpeg mock output path: %s\n' "${output_path}" >&2
    exit 64
fi
output_parent=${output_path%/*}
[[ -d ${output_parent} ]] || {
    printf 'FFmpeg mock output directory is absent: %s\n' "${output_parent}" >&2
    exit 64
}
printf '%s\n' 'mock remuxed media payload' >"${output_path}"
if [[ ${MOCK_REPLACE_HLS_REMUX_AFTER_WRITE:-0} == 1 ]]; then
    rm -f -- "${output_path}"
    printf '%s\n' 'foreign HLS remux replacement' >"${output_path}"
    chmod 600 -- "${output_path}"
fi
EOF_FFMPEG
chmod +x "${MOCK_BIN}/ffmpeg"

cat >"${MOCK_BIN}/ffprobe" <<'EOF_FFPROBE'
#!/usr/bin/env bash
set -euo pipefail

case ${1:-} in
-version | --version)
    printf 'ffprobe mock version 1.0\n'
    exit 0
    ;;
esac

selector=''
duration_probe=false
timeline_probe=false
summary_probe=false
tail_probe=false
show_packets=false
media_path=''
probe_previous=''
for argument in "$@"; do
    media_path=${argument}

    case ${argument} in
        format=duration)
            duration_probe=true
            ;;
        format=start_time,duration)
            timeline_probe=true
            ;;
        format=start_time,duration:stream=codec_type:stream_disposition=attached_pic)
            summary_probe=true
            ;;
        packet=pts_time,dts_time,duration_time)
            tail_probe=true
            ;;
        -show_packets)
            show_packets=true
            ;;
        *) ;;
    esac

    if [[ ${probe_previous} == '-select_streams' ]]; then
        selector=${argument}
        probe_previous=''
        continue
    fi
    if [[ ${argument} == '-select_streams' ]]; then
        probe_previous='-select_streams'
    fi
done

# Preserve the pre-existing oracle: the generic argument log represents the
# structural stream probe, not the later VAL-001 timeline/tail probes.
if [[ -n ${MOCK_FFPROBE_ARG_LOG:-} &&
    ${timeline_probe} != true && ${tail_probe} != true ]]; then
    printf '%s\0' "$@" >"${MOCK_FFPROBE_ARG_LOG}"
fi

if [[ ${MOCK_FFPROBE_COVER_ART_ONLY:-0} == 1 ]]; then
    case ${selector} in
        v:0 | a:0)
            printf '0\n'
            exit 0
            ;;
        V:0)
            exit 0
            ;;
        *) ;;
    esac
fi
if [[ ${MOCK_FFPROBE_MISSING_AUDIO:-0} == 1 && ${selector} == 'a:0' ]]; then
    exit 0
fi
if [[ ${MOCK_FFPROBE_EXIT_STATUS:-0} != 0 ]]; then
    printf 'Simulated FFprobe validation failure.\n' >&2
    exit "${MOCK_FFPROBE_EXIT_STATUS}"
fi
if [[ ${summary_probe} == true ]]; then
    ffprobe_audio_mode=false
    stream_json=''

    if [[ -f ${MOCK_ARG_LOG:-} ]]; then
        while IFS= read -r -d '' ffprobe_mode_argument; do
            if [[ ${ffprobe_mode_argument} == '--extract-audio' ]]; then
                ffprobe_audio_mode=true
                break
            fi
        done <"${MOCK_ARG_LOG}"
    fi

    if [[ ${MOCK_FFPROBE_EMPTY:-0} != 1 ]]; then
        if [[ ${MOCK_FFPROBE_COVER_ART_ONLY:-0} == 1 ]]; then
            stream_json='{"codec_type":"video","disposition":{"attached_pic":1}}'
        elif [[ ${ffprobe_audio_mode} != true ||
            ${MOCK_FFPROBE_CONTENT_VIDEO:-0} == 1 ]]; then
            stream_json='{"codec_type":"video","disposition":{"attached_pic":0}}'
        fi

        if [[ ${MOCK_FFPROBE_MISSING_AUDIO:-0} != 1 ]]; then
            if [[ -n ${stream_json} ]]; then
                stream_json+=','
            fi
            stream_json+='{"codec_type":"audio","disposition":{"attached_pic":0}}'
        fi
    fi

    printf '{"streams":[%s],"format":{"start_time":"%s","duration":"%s"}}\n' \
        "${stream_json}" \
        "${MOCK_FFPROBE_START_TIME:-0.000000}" \
        "${MOCK_FFPROBE_TIMELINE_DURATION:-120.000000}"
    exit 0
fi
if [[ ${timeline_probe} == true ]]; then
    printf '{"format":{"start_time":"%s","duration":"%s"}}\n' \
        "${MOCK_FFPROBE_START_TIME:-0.000000}" \
        "${MOCK_FFPROBE_TIMELINE_DURATION:-120.000000}"
    exit 0
fi
if [[ ${tail_probe} == true ]]; then
    [[ ${show_packets} == true ]] || {
        printf '%s\n' 'VAL-001 tail probe omitted -show_packets.' >&2
        exit 64
    }

    tail_pts=${MOCK_FFPROBE_TAIL_PTS:-119.500000}
    tail_dts=${MOCK_FFPROBE_TAIL_DTS:-${tail_pts}}
    tail_duration=${MOCK_FFPROBE_TAIL_DURATION:-0.500000}

    case ${selector} in
        V:0)
            tail_pts=${MOCK_FFPROBE_VIDEO_TAIL_PTS:-${tail_pts}}
            tail_dts=${MOCK_FFPROBE_VIDEO_TAIL_DTS:-${tail_pts}}
            tail_duration=${MOCK_FFPROBE_VIDEO_TAIL_DURATION:-${tail_duration}}
            ;;
        a:0)
            tail_pts=${MOCK_FFPROBE_AUDIO_TAIL_PTS:-${tail_pts}}
            tail_dts=${MOCK_FFPROBE_AUDIO_TAIL_DTS:-${tail_pts}}
            tail_duration=${MOCK_FFPROBE_AUDIO_TAIL_DURATION:-${tail_duration}}
            ;;
        *) ;;
    esac

    printf '{"packets":[{"pts_time":"%s","dts_time":"%s","duration_time":"%s"}]}\n' \
        "${tail_pts}" "${tail_dts}" "${tail_duration}"
    exit 0
fi
if [[ ${duration_probe} == true ]]; then
    if [[ ${MOCK_FFPROBE_DURATION_EMPTY:-0} == 1 ]]; then
        exit 0
    fi
    if [[ ${MOCK_FFPROBE_MKV_DURATION_EMPTY:-0} == 1 &&
        ${media_path} == *.mkv ]]; then
        exit 0
    fi

    if [[ ${media_path} == *.mkv ]]; then
        printf '%s\n' "${MOCK_FFPROBE_MKV_DURATION:-120.000000}"
    else
        printf '%s\n' "${MOCK_FFPROBE_DURATION:-120.000000}"
    fi
    exit 0
fi
if [[ ${selector} == 'V:0' && ${MOCK_FFPROBE_CONTENT_VIDEO:-0} != 1 ]]; then
    ffprobe_audio_mode=false

    if [[ -f ${MOCK_ARG_LOG:-} ]]; then
        while IFS= read -r -d '' ffprobe_mode_argument; do
            if [[ ${ffprobe_mode_argument} == '--extract-audio' ]]; then
                ffprobe_audio_mode=true
                break
            fi
        done <"${MOCK_ARG_LOG}"
    fi

    if [[ ${ffprobe_audio_mode} == true ]]; then
        exit 0
    fi
fi

if [[ ${MOCK_FFPROBE_EMPTY:-0} != 1 ]]; then
    printf '0\n'
fi
EOF_FFPROBE
chmod +x "${MOCK_BIN}/ffprobe"

REAL_ENV=$(command -v env)
REAL_LN=$(command -v ln)
REAL_MV=$(command -v mv)
REAL_SED=$(command -v sed)
REAL_SETSID=$(command -v setsid)
export REAL_ENV REAL_LN REAL_MV REAL_SED REAL_SETSID
cat >"${MOCK_BIN}/env" <<'EOF_ENV'
#!/usr/bin/env bash
set -euo pipefail

if (($# >= 3)) \
    && [[ $1 == '--ignore-signal=HUP' &&
        $2 == '--ignore-signal=INT' &&
        $3 == '--ignore-signal=TERM' ]]; then
    exec "${REAL_ENV:?}" "$@"
fi

if (($# == 6)) \
    && [[ $1 == '--default-signal=HUP' &&
        $2 == '--default-signal=INT' &&
        $3 == '--default-signal=TERM' &&
        $4 == bash && $5 == -c && $6 == 'exit 0' ]]; then
    exec "${REAL_ENV:?}" "$@"
fi

if [[ -n ${MOCK_ENV_DELAY_MARKER:-} ]]; then
    : "${MOCK_ENV_CONTINUE_MARKER:?}"
    printf '%s\n' started >"${MOCK_ENV_DELAY_MARKER}"
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -e ${MOCK_ENV_CONTINUE_MARKER} ]] && break
        sleep 0.1
    done
    [[ -e ${MOCK_ENV_CONTINUE_MARKER} ]] || exit 125
fi

exec "${REAL_ENV:?}" "$@"
EOF_ENV
chmod +x "${MOCK_BIN}/env"

cat >"${MOCK_BIN}/ln" <<'EOF_LN'
#!/usr/bin/env bash
set -euo pipefail

destination=${!#}
source_path=${@: -2:1}
remux_backup=''
if [[ ${source_path} == /proc/[1-9]*/fd/[0-9]* &&
    ${destination} == *.mkv && ! -e ${destination} ]]; then
    if [[ ${MOCK_HLS_PUBLISH_COLLISION:-0} == 1 ]]; then
        printf '%s\n' 'preserve racing MKV destination' >"${destination}"
    fi
    if [[ ${MOCK_REPLACE_HLS_REMUX_DURING_PUBLISH:-0} == 1 ]]; then
        remux_path=$(readlink -- "${source_path}")
        if [[ ${remux_path##*/} != .yt-dlp-remux.*.mkv ]]; then
            printf 'Unexpected HLS remux descriptor target: %s\n' \
                "${remux_path}" >&2
            exit 70
        fi
        remux_backup="${remux_path}.verified-backup"
        "${REAL_MV:?}" -T -- "${remux_path}" "${remux_backup}"
        printf '%s\n' 'foreign HLS publication replacement' >"${remux_path}"
        chmod 600 -- "${remux_path}"
    fi
fi
link_status=0
if [[ ${MOCK_HLS_HARDLINK_UNAVAILABLE:-0} == 1 &&
    ${source_path} == /proc/[1-9]*/fd/[0-9]* &&
    ${destination} == *.mkv ]]; then
    link_status=95
elif [[ ${MOCK_RESULT_HARDLINK_UNAVAILABLE:-0} == 1 &&
    ${source_path} == /proc/[1-9]*/fd/[0-9]* &&
    ${destination##*/} == result-hardlink-fallback.txt ]]; then
    link_status=95
else
    "${REAL_LN:?}" "$@" || link_status=$?
fi
if ((link_status == 0)) && [[ -n ${remux_backup} ]]; then
    rm -f -- "${remux_backup}"
fi
if ((link_status == 0)) \
    && [[ ${MOCK_BLOCK_AFTER_RESULT_PUBLICATION:-0} == 1 &&
        ${source_path} == /proc/[1-9]*/fd/[0-9]* &&
        ${destination##*/} == result.txt ]]; then
    : "${MOCK_RESULT_PUBLICATION_MARKER:?}"
    printf '%s\n' published >"${MOCK_RESULT_PUBLICATION_MARKER}"
    trap 'exit 143' TERM INT
    while true; do
        sleep 0.1
    done
fi
exit "${link_status}"
EOF_LN
chmod +x "${MOCK_BIN}/ln"

cat >"${MOCK_BIN}/mv" <<'EOF_MV'
#!/usr/bin/env bash
set -euo pipefail

destination=${!#}
source_path=${@: -2:1}
if [[ (${destination} == */pgid || ${destination##*/} == .worker-pgid.*) &&
    ${MOCK_DELAY_PGID_PUBLISH:-0} == 1 ]]; then
    trap 'printf terminated >"${MOCK_PGID_DELAY_TERMINATION_MARKER:?}"; exit 143' TERM INT
    if [[ -n ${MOCK_PGID_DELAY_STARTED_MARKER:-} ]]; then
        printf '%s\n' "$$" >"${MOCK_PGID_DELAY_STARTED_MARKER}"
    fi
    if [[ -n ${MOCK_PGID_DELAY_CONTINUE_MARKER:-} ]]; then
        for ((attempt = 0; attempt < 100; attempt++)); do
            [[ -e ${MOCK_PGID_DELAY_CONTINUE_MARKER} ]] && break
            sleep 0.1
        done
        [[ -e ${MOCK_PGID_DELAY_CONTINUE_MARKER} ]] || exit 125
    else
        sleep "${MOCK_PGID_PUBLISH_DELAY_SECONDS:-6}"
    fi
fi
exec "${REAL_MV:?}" "$@"
EOF_MV
chmod +x "${MOCK_BIN}/mv"

cat >"${MOCK_BIN}/sed" <<'EOF_SED'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${MOCK_SANITIZATION_FAILURE:-0} == 1 ]]; then
    for argument in "$@"; do
        case ${argument} in
            */log-snapshot.* | */log-truncated.*)
                printf '%s\n' 'Simulated diagnostic sanitization failure.' >&2
                exit 75
                ;;
            *) ;;
        esac
    done
fi

if [[ ${MOCK_PIPELINE_REDACTOR_FAILURE:-0} == 1 ]]; then
    for argument in "$@"; do
        case ${argument} in
            *'[REDACTED_SOURCE]'* | *'[REDACTED_URL]'*)
                printf '%s\n' 'Simulated pipeline redactor failure.' >&2
                exit 75
                ;;
            *) ;;
        esac
    done
fi

exec "${REAL_SED:?}" "$@"
EOF_SED
chmod +x "${MOCK_BIN}/sed"

cat >"${MOCK_BIN}/setsid" <<'EOF_SETSID'
#!/usr/bin/env bash
set -euo pipefail

if (($# == 1)) && [[ $1 == '--help' ]]; then
    exec "${REAL_SETSID:?}" "$@"
fi
if [[ -n ${MOCK_SETSID_START_STATUS:-} ]]; then
    if [[ ${MOCK_SETSID_SILENT_FAILURE:-0} != 1 ]]; then
        printf '%s\n' 'Simulated worker session startup failure.' >&2
    fi
    exit "${MOCK_SETSID_START_STATUS}"
fi
if [[ -n ${MOCK_SETSID_LOG:-} ]]; then
    printf 'call\n' >>"${MOCK_SETSID_LOG}"
fi
sleep "${MOCK_SETSID_START_JITTER_SECONDS:-0}"
exec "${REAL_SETSID:?}" "$@"
EOF_SETSID
chmod +x "${MOCK_BIN}/setsid"

cat >"${MOCK_BIN}/zenity" <<'EOF_ZENITY'
#!/usr/bin/env bash
set -euo pipefail

wait_for_mock_worker_start() {
    local attempt=0
    local worker_start_marker=${MOCK_STARTED_MARKER:-}

    [[ ${MOCK_ZENITY_WAIT_FOR_WORKER_START:-0} == 1 ]] || return 0
    if [[ -z ${worker_start_marker} ]]; then
        printf '%s\n' \
            'MOCK_ZENITY_WAIT_FOR_WORKER_START requires MOCK_STARTED_MARKER.' >&2
        exit 64
    fi
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -f ${worker_start_marker} ]] && return 0
        sleep 0.1
    done
    printf 'Timed out waiting for mock worker startup: %s\n' \
        "${worker_start_marker}" >&2
    exit 66
}

block_for_signal() {
    local mode=$1

    [[ ${MOCK_ZENITY_BLOCK_MODE:-} == "${mode}" ]] || return 0
    : "${MOCK_ZENITY_STARTED_MARKER:?}"
    : "${MOCK_ZENITY_TERMINATION_MARKER:?}"

    wait_for_mock_worker_start
    trap 'printf HUP >"${MOCK_ZENITY_TERMINATION_MARKER}"; exit 129' HUP
    trap 'printf INT >"${MOCK_ZENITY_TERMINATION_MARKER}"; exit 130' INT
    trap 'printf TERM >"${MOCK_ZENITY_TERMINATION_MARKER}"; exit 143' TERM
    printf '%s\n' "${BASHPID}" >"${MOCK_ZENITY_STARTED_MARKER}"
    while true; do
        sleep 0.1
    done
}

emit_mock_file_error() {
    local file_error_output=''

    if [[ -n ${MOCK_ZENITY_FILE_ERROR_BYTES:-} ]]; then
        printf -v file_error_output '%*s' \
            "${MOCK_ZENITY_FILE_ERROR_BYTES}" ''
        printf 'file chooser failed for https://secret.example/%s\n' \
            "${file_error_output// /X}" >&2
    else
        printf '%s\n' \
            "${MOCK_ZENITY_FILE_ERROR:-simulated file chooser failure}" >&2
    fi
}

case " $* " in
    *' --entry '*)
        block_for_signal entry
        if [[ ${MOCK_CANCEL_ENTRY_AFTER_NEW_DOWNLOAD:-0} == 1 &&
            -n ${MOCK_NEW_DOWNLOAD_ONCE_MARKER:-} &&
            -e ${MOCK_NEW_DOWNLOAD_ONCE_MARKER} ]]; then
            exit 1
        fi
        if [[ ${MOCK_INVALID_URL_THEN_CANCEL:-0} == 1 ]]; then
            : "${MOCK_ENTRY_ATTEMPT_MARKER:?}"
            if [[ ! -e ${MOCK_ENTRY_ATTEMPT_MARKER} ]]; then
                : >"${MOCK_ENTRY_ATTEMPT_MARKER}"
                printf '%s\n' 'not-a-valid-url'
                exit 0
            fi
            exit 1
        fi
        if [[ -n ${MOCK_ZENITY_ENTRY_STATUS:-} ]]; then
            if [[ -n ${MOCK_ZENITY_ENTRY_ERROR:-} ]]; then
                printf '%s\n' "${MOCK_ZENITY_ENTRY_ERROR}" >&2
            fi
            exit "${MOCK_ZENITY_ENTRY_STATUS}"
        fi
        if [[ -n ${MOCK_ZENITY_ENTRY_OUTPUT_BYTES:-} ]]; then
            printf -v entry_output '%*s' \
                "${MOCK_ZENITY_ENTRY_OUTPUT_BYTES}" ''
            printf '%s' "${entry_output// /X}"
            exit 0
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
            emit_mock_file_error
            exit "${MOCK_ZENITY_FILE_STATUS_WITH_FILENAME}"
        fi
        if [[ -n ${MOCK_ZENITY_FILE_STATUS:-} ]]; then
            emit_mock_file_error
            exit "${MOCK_ZENITY_FILE_STATUS}"
        fi
        printf '%s\n' "${MOCK_OUTPUT_DIR}"
        ;;
    *' --progress '*)
        block_for_signal progress
        if [[ -n ${MOCK_ZENITY_PROGRESS_STATUS:-} ]]; then
            IFS= read -r _ || true

            # For timeout/error signal tests, do not let the mock progress dialog
            # fail before the long-running worker has installed its TERM trap.
            # This turns the termination marker into a deterministic assertion
            # instead of an assertion on process-scheduling order.
            wait_for_mock_worker_start

            exit "${MOCK_ZENITY_PROGRESS_STATUS}"
        fi
        if [[ ${MOCK_CANCEL_AFTER_EOF:-0} == 1 ]]; then
            cat >/dev/null
            sleep "${MOCK_CANCEL_AFTER_EOF_JITTER_SECONDS:-0}"
            exit 1
        fi
        if [[ ${MOCK_CANCEL:-0} == 1 ]]; then
            IFS= read -r _ || true
            wait_for_mock_worker_start
            sleep "${MOCK_CANCEL_JITTER_SECONDS:-0}"
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
        block_for_signal question
        if [[ -n ${MOCK_QUESTION_ARGS_LOG:-} ]]; then
            printf '%s\0' "$@" >"${MOCK_QUESTION_ARGS_LOG}"
        fi
        if [[ -n ${MOCK_NEW_DOWNLOAD_ONCE_MARKER:-} &&
            " $* " == *'The download is complete.'* &&
            ! -e ${MOCK_NEW_DOWNLOAD_ONCE_MARKER} ]]; then
            : >"${MOCK_NEW_DOWNLOAD_ONCE_MARKER}"
            printf '%s' 'New download'
            exit 1
        fi
        if [[ -n ${MOCK_COMPLETION_QUESTION_STATUS:-} &&
            " $* " == *'The download is complete.'* ]]; then
            if [[ -n ${MOCK_COMPLETION_QUESTION_ERROR:-} ]]; then
                printf '%s\n' "${MOCK_COMPLETION_QUESTION_ERROR}" >&2
            fi
            exit "${MOCK_COMPLETION_QUESTION_STATUS}"
        fi
        printf '%s' "${MOCK_QUESTION_OUTPUT:-}"
        exit "${MOCK_QUESTION_STATUS:-1}"
        ;;
    *' --info '*)
        if [[ -n ${MOCK_INFO_ARGS_LOG:-} ]]; then
            printf '%s\0' "$@" >"${MOCK_INFO_ARGS_LOG}"
        fi
        exit 0
        ;;
    *' --text-info '*)
        block_for_signal text-info
        if [[ -n ${MOCK_TEXT_INFO_ARGS_LOG:-} ]]; then
            printf '%s\0' "$@" >"${MOCK_TEXT_INFO_ARGS_LOG}"
        fi
        if [[ -n ${MOCK_TEXT_INFO_CONTENT_CAPTURE:-} ]]; then
            diagnostic_file=''
            for argument in "$@"; do
                case ${argument} in
                    --filename=*) diagnostic_file=${argument#--filename=} ;;
                    *) ;;
                esac
            done
            [[ -n ${diagnostic_file} && -f ${diagnostic_file} ]] || exit 66
            cp -- "${diagnostic_file}" "${MOCK_TEXT_INFO_CONTENT_CAPTURE}"
        fi
        exit "${MOCK_TEXT_INFO_STATUS:-0}"
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
        printf 'Unexpected Zenity mock invocation:' >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        exit 98
        ;;
esac
EOF_ZENITY
chmod +x "${MOCK_BIN}/zenity"

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
    (($# == 4)) || return 2
    local scenario=$1
    local requested_url=$2
    local youtube_expected=$3
    local label=$4
    # shellcheck disable=SC2034 # Read indirectly through nameref helpers.
    local -a profile_arguments=()

    prepare_argument_log "${scenario}"
    assert_status 0 "${label} GUI run" \
        env MOCK_ZENITY_ENTRY_VALUE="${requested_url}" \
        MOCK_PROFILE='Audio track (native format)' \
        "${GUI_UNDER_TEST}"
    read_arguments "${LIST_ARGS_LOG}" profile_arguments
    assert_array_contains profile_arguments 'Complete video (MKV)' \
        "${label} complete-video profile"
    assert_array_contains profile_arguments 'Audio track (native format)' \
        "${label} audio profile"
    if [[ ${youtube_expected} == true ]]; then
        assert_array_contains profile_arguments \
            'YouTube video - Firefox cookies (HLS/MKV)' \
            "${label} YouTube HLS profile"
    else
        assert_array_not_contains profile_arguments \
            'YouTube video - Firefox cookies (HLS/MKV)' \
            "${label} excludes YouTube HLS"
    fi
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
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

wait_for_worker_registration_cleanup() {
    local timeout=$1
    local label=$2
    local deadline=$((SECONDS + timeout))
    local registration_path=''

    while ((SECONDS < deadline)); do
        if ! registration_path=$(find \
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader" \
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

        cmdline=$(tr '\0' ' ' 2>/dev/null <"${cmdline_file}") || continue
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
            cmdline=$(tr '\0' ' ' 2>/dev/null <"/proc/${pid}/cmdline" || true)
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

    runtime_lock_dir="${XDG_RUNTIME_DIR}/yt-dlp-aria2-downloader"
    [[ -d ${runtime_lock_dir} && ! -L ${runtime_lock_dir} ]] \
        || fail 'The engine did not create a private XDG runtime lock directory.'
    assert_path_mode "${runtime_lock_dir}" 700 \
        'XDG runtime lock-directory permissions'
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
        'destination already exists: Mock media [abc123].webm' \
        'existing media collision helper diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media destination already exists; refusing to overwrite it.' \
        'existing media collision engine diagnostic'
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
    [[ ! -e ${hls_collision_result} ]] \
        || fail 'An HLS target collision published a result file.'
    [[ -f "${OUTPUT_DIR}/Mock media [abc123].mp4" ]] \
        || fail 'An HLS target collision did not retain the repaired MP4.'
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
    prepare_argument_log 'retained-hls-remux-survives-stale-cleanup'
    assert_status 0 'explicitly retained HLS remux survives stale cleanup' \
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
    assert_status 13 'shared non-sticky output ancestor is rejected' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${unsafe_output_dir}" \
        -- 'https://example.com/watch?v=unsafe-output-parent'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'owned by another user or is shared without sticky-bit protection' \
        'unsafe output ancestor diagnostic'
    assert_directory_empty "${unsafe_output_dir}" \
        'unsafe output ancestor creates no transfer state'
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
        env MOCK_ARIA2_EXIT_STATUS=29 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=aria2-producer-status'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Download failed with exit code 29.' \
        'aria2 producer status diagnostic'
    assert_text_not_contains "${ASSERT_OUTPUT}" \
        'https://secret.example/private' \
        'aria2 producer diagnostic remains redacted'

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
}

test_mock_engine_private_staging() {
    local active_file_log active_file_pid active_file_plan active_file_replacement
    local active_file_result active_file_staging active_file_started
    local active_file_status active_file_termination_marker
    local ambiguous_marked attempt candidate candidate_ambiguous candidate_pgid
    local candidate_pid crash_log crash_pgid crash_pid crash_result
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
        active_file_staging=$(find "${OUTPUT_DIR}" \
            -mindepth 1 -maxdepth 1 -type d \
            -name '.yt-dlp-aria2.????????' -print -quit 2>/dev/null || true)
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
        'preserving ambiguous active private aria2 staging directory' \
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
        successful_mutation_staging=$(find "${OUTPUT_DIR}" \
            -mindepth 1 -maxdepth 1 -type d \
            -name '.yt-dlp-aria2.????????' -print -quit 2>/dev/null || true)
        [[ -n ${successful_mutation_staging} &&
            -f ${successful_mutation_staging}/${successful_mutation_file} ]] \
            || fail "Replaced aria2 ${successful_mutation_name} inode was removed."
        [[ ! -e ${successful_mutation_staging}/plan.json &&
            ! -e ${successful_mutation_staging}/cookies.txt ]] \
            || fail "Replaced aria2 ${successful_mutation_name} retained other secrets."
        assert_text_contains "${ASSERT_OUTPUT}" \
            'preserving ambiguous active private aria2 staging directory' \
            "replaced aria2 ${successful_mutation_name} preservation diagnostic"
        rm -rf -- "${successful_mutation_staging}"
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    done

    # The conservative replacement protection must not turn ordinary owned
    # staging into a leak: a normal successful transaction still cleans it.
    prepare_argument_log 'private-staging-normal-cleanup'
    assert_status 0 'owned active private staging is cleaned normally' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        -- 'https://example.com/watch?v=private-staging-normal-cleanup'

    owned_staging_leftover=$(find "${OUTPUT_DIR}" \
        -mindepth 1 -maxdepth 1 -type d \
        -name '.yt-dlp-aria2.????????' -print -quit 2>/dev/null || true)

    [[ -z ${owned_staging_leftover} ]] \
        || fail 'A normal transaction left owned private aria2 staging behind.'

    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    # Regression guard: a non-interceptable crash must leave a recoverable
    # owner-marked private staging directory, and the next run may remove only
    # candidates whose ownership and structure are unambiguous.
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

    prepare_argument_log 'private-staging-recovery'
    assert_status 0 'abandoned private staging recovery' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        --mode audio \
        -- 'https://example.com/watch?v=private-staging-recovery'

    [[ ! -e ${crash_staging} ]] \
        || fail 'Owner-marked crash staging was not recovered.'
    [[ ! -e ${legacy_exact} ]] \
        || fail 'Exact legacy staging fingerprint was not recovered.'
    [[ -d ${ambiguous_marked} ]] \
        || fail 'Ambiguous marked staging was deleted.'
    [[ ! -e ${ambiguous_marked}/plan.json &&
        ! -e ${ambiguous_marked}/cookies.txt &&
        ! -e ${ambiguous_marked}/aria2.input &&
        ! -e ${ambiguous_marked}/manifest.json ]] \
        || fail 'Ambiguous marked staging retained authenticated transfer metadata.'
    [[ -f ${ambiguous_marked}/foreign.txt ]] \
        || fail 'Ambiguous marked staging recovery removed an unknown artifact.'
    [[ -d ${invalid_mode} ]] \
        || fail 'Invalid-mode staging was deleted.'
    [[ -L ${symlink_candidate} && -f ${staging_symlink_target}/sentinel ]] \
        || fail 'Staging symlink or its target was modified.'
    [[ -d ${cross_candidate} ]] \
        || fail 'A different output directory was cleaned cross-destination.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'preserving ambiguous private aria2 staging directory' \
        'ambiguous staging preservation diagnostic'

    rm -rf -- \
        "${ambiguous_marked}" \
        "${invalid_mode}" \
        "${symlink_candidate}" \
        "${staging_symlink_target}" \
        "${other_output}"
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
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
    test_mock_engine_private_staging
}

run_mock_engine_group() {
    run_mock_engine_core_group
    run_mock_engine_hls_group
    run_mock_engine_staging_group
}

run_selected_mock_engine_group() {
    case ${MOCK_GROUP} in
        all | engine) run_mock_engine_group ;;
        engine-core) run_mock_engine_core_group ;;
        engine-hls) run_mock_engine_hls_group ;;
        engine-staging) run_mock_engine_staging_group ;;
        *) ;;
    esac
}

test_mock_gui_aria_progress() {
    local aria_unknown_capture gui_aria2_arguments_text gui_url_seen_log
    local trimmed_gui_url
    local -a gui_arguments gui_aria2_arguments

    # Scenario: aria2 GUI progress with an unknown total size.
    trimmed_gui_url='https://example.com/watch?v=trimmed'
    gui_url_seen_log="${TEST_ROOT}/gui-private-url-seen.txt"
    prepare_argument_log 'gui-aria-percent'
    MOCK_ZENITY_ENTRY_VALUE="  ${trimmed_gui_url}  " \
        MOCK_URL_SEEN_LOG="${gui_url_seen_log}" \
        MOCK_ARIA_ONLY=1 \
        MOCK_PROGRESS_CAPTURE="${PROGRESS_CAPTURE}" \
        "${GUI_UNDER_TEST}"
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
    local config_file profile_case removed_profile_label requested_url scenario
    local -a false_youtube_cases incompatible_default_arguments list_arguments
    local -a video_gui_arguments youtube_cases youtube_hls_default_arguments
    local -a youtube_hls_gui_arguments

    youtube_cases=(
        'gui-profile-youtube-root|https://youtube.com/watch?v=profile-root'
        'gui-profile-youtube-subdomain|https://media.youtube.com/watch?v=profile-subdomain'
        'gui-profile-youtu-be|https://youtu.be/profile-short'
        'gui-profile-youtu-be-subdomain|https://media.youtu.be/profile-short-subdomain'
        'gui-profile-nocookie|https://youtube-nocookie.com/embed/profile-nocookie'
        'gui-profile-nocookie-subdomain|https://media.youtube-nocookie.com/embed/profile-nocookie-subdomain'
        'gui-profile-normalized-host|https://WWW.YOUTUBE.COM.:443/watch?v=profile-normalized'
    )
    for profile_case in "${youtube_cases[@]}"; do
        IFS='|' read -r scenario requested_url <<<"${profile_case}"
        assert_gui_profile_menu "${scenario}" "${requested_url}" true \
            "recognized YouTube URL ${requested_url}"
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
        'gui-profile-false-suffix|https://youtube.com.example.org/video'
        'gui-profile-false-short-suffix|https://youtu.be.example.org/video'
        'gui-profile-false-nocookie-suffix|https://youtube-nocookie.com.example.org/video'
        'gui-profile-false-path|https://example.org/youtube.com/video'
    )
    for profile_case in "${false_youtube_cases[@]}"; do
        IFS='|' read -r scenario requested_url <<<"${profile_case}"
        assert_gui_profile_menu "${scenario}" "${requested_url}" false \
            "non-YouTube URL ${requested_url}"
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
    cd -- "${relative_tmp_cwd}"
    prepare_argument_log 'relative-tmpdir-fallback'
    assert_status 0 'relative TMPDIR falls back outside the launcher cwd' \
        env PATH="${mktemp_probe_bin}:${PATH}" \
        TMPDIR='relative-tmp' \
        MOCK_REAL_MKTEMP="${real_mktemp}" \
        MOCK_MKTEMP_ARGUMENT_LOG="${mktemp_probe_log}" \
        MOCK_ZENITY_ENTRY_STATUS=1 \
        "${GUI_UNDER_TEST}"
    cd -- "${original_directory}"
    read_arguments "${mktemp_probe_log}" mktemp_probe_arguments
    assert_array_contains mktemp_probe_arguments '--tmpdir=/tmp' \
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
    assert_array_contains mktemp_probe_arguments '--tmpdir=/tmp' \
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
    assert_status 0 'current-user sticky TMPDIR remains supported' \
        env PATH="${mktemp_probe_bin}:${PATH}" \
        TMPDIR="${sticky_tmp_dir}" \
        MOCK_REAL_MKTEMP="${real_mktemp}" \
        MOCK_MKTEMP_ARGUMENT_LOG="${mktemp_probe_log}" \
        MOCK_ZENITY_ENTRY_STATUS=1 \
        "${GUI_UNDER_TEST}"
    read_arguments "${mktemp_probe_log}" mktemp_probe_arguments
    assert_array_contains mktemp_probe_arguments \
        "--tmpdir=${sticky_tmp_dir}" \
        'sticky TMPDIR is passed to mktemp'
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

run_mock_gui_state_group() {
    test_mock_gui_config_recovery
    test_mock_gui_file_selection
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

test_mock_signal_cli_leader_exit_descendant() {
    local cli_engine_pid cli_engine_status descendant_pid descendant_signal_log
    local descendant_started_marker descendant_termination_marker

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
    rm -f -- \
        "${descendant_started_marker}" \
        "${descendant_termination_marker}" \
        "${descendant_signal_log}"
    prepare_argument_log 'cli-leader-exit-resistant-descendant'
    env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_EXIT_WITH_LIVE_DESCENDANT=1 \
        MOCK_DESCENDANT_IGNORE_TERM=1 \
        MOCK_DESCENDANT_STARTED_MARKER="${descendant_started_marker}" \
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
    kill -TERM -- "${cli_engine_pid}"
    sleep 0.05
    kill -TERM -- "${cli_engine_pid}"
    cli_engine_status=0
    wait "${cli_engine_pid}" || cli_engine_status=$?
    assert_equals 143 "${cli_engine_status}" \
        'CLI resistant descendant repeated-TERM status'
    if kill -0 -- "${descendant_pid}" 2>/dev/null; then
        fail 'Repeated TERM left the signal-resistant descendant alive.'
    fi
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

test_mock_signal_cli_pre_env_registration() {
    local cli_engine_pid cli_engine_status continue_marker delay_marker
    local elapsed_milliseconds mode runtime_signal_log signal_finished_at
    local signal_started_at
    local -a registration_leftovers=()
    local -a session_modes=(false true)

    # Interpose immediately before GNU env restores dispositions. SIGINT sent
    # in this exact post-fork window must remain deferred until the child has
    # published post-env readiness, rather than being lost as an inherited
    # ignored signal and requiring the ten-second KILL escalation.
    printf '%s\n' 'Mock scenario: cli-signal-pre-env-registration'
    for mode in "${session_modes[@]}"; do
        delay_marker="${TEST_ROOT}/pre-env-${mode}-delayed"
        continue_marker="${TEST_ROOT}/pre-env-${mode}-continue"
        runtime_signal_log="${TEST_ROOT}/pre-env-${mode}.log"

        /usr/bin/env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
            MOCK_ENV_DELAY_MARKER="${delay_marker}" \
            MOCK_ENV_CONTINUE_MARKER="${continue_marker}" \
            MOCK_RUNTIME_MANAGER_BLOCK=1 \
            MOCK_RUNTIME_STARTED_MARKER="${TEST_ROOT}/pre-env-${mode}-runtime-started" \
            MOCK_RUNTIME_TERMINATION_MARKER="${TEST_ROOT}/pre-env-${mode}-runtime-terminated" \
            YTDLP_ARIA2_SUPERVISED_SESSION="${mode}" \
            "${MANAGED_ENGINE_UNDER_TEST}" \
            --output-dir "${OUTPUT_DIR}" \
            -- "https://example.com/watch?v=pre-env-${mode}" \
            >"${runtime_signal_log}" 2>&1 &
        cli_engine_pid=$!
        wait_for_file "${delay_marker}" 10 \
            "pre-env ${mode} launch delay"
        signal_started_at=$(date +%s%3N)
        kill -INT -- "${cli_engine_pid}"
        : >"${continue_marker}"
        cli_engine_status=0
        wait "${cli_engine_pid}" || cli_engine_status=$?
        signal_finished_at=$(date +%s%3N)
        elapsed_milliseconds=$((signal_finished_at - signal_started_at))
        assert_equals 130 "${cli_engine_status}" \
            "pre-env ${mode} SIGINT exit status"
        ((elapsed_milliseconds < 5000)) \
            || fail "Pre-env ${mode} SIGINT handling took ${elapsed_milliseconds}ms."
        assert_no_test_processes \
            "pre-env ${mode} SIGINT left descendants"
        shopt -s nullglob
        registration_leftovers=(
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader"/.worker-pgid.*
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader"/.worker-ready.*
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
        runtime_signal_log="${TEST_ROOT}/pre-env-escalate-${mode}.log"

        /usr/bin/env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
            MOCK_ENV_DELAY_MARKER="${delay_marker}" \
            MOCK_ENV_CONTINUE_MARKER="${continue_marker}" \
            MOCK_RUNTIME_MANAGER_BLOCK=1 \
            MOCK_RUNTIME_STARTED_MARKER="${TEST_ROOT}/pre-env-escalate-${mode}-runtime-started" \
            MOCK_RUNTIME_TERMINATION_MARKER="${TEST_ROOT}/pre-env-escalate-${mode}-runtime-terminated" \
            YTDLP_ARIA2_SUPERVISED_SESSION="${mode}" \
            "${MANAGED_ENGINE_UNDER_TEST}" \
            --output-dir "${OUTPUT_DIR}" \
            -- "https://example.com/watch?v=pre-env-escalate-${mode}" \
            >"${runtime_signal_log}" 2>&1 &
        cli_engine_pid=$!
        wait_for_file "${delay_marker}" 10 \
            "pre-env escalation ${mode} launch delay"
        signal_started_at=$(date +%s%3N)
        kill -INT -- "${cli_engine_pid}"
        sleep 0.05
        kill -INT -- "${cli_engine_pid}"
        cli_engine_status=0
        wait "${cli_engine_pid}" || cli_engine_status=$?
        signal_finished_at=$(date +%s%3N)
        elapsed_milliseconds=$((signal_finished_at - signal_started_at))
        assert_equals 130 "${cli_engine_status}" \
            "pre-env escalation ${mode} preserves first SIGINT status"
        ((elapsed_milliseconds < 2000)) \
            || fail "Pre-env escalation ${mode} took ${elapsed_milliseconds}ms."
        shopt -s nullglob
        registration_leftovers=(
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader"/.worker-pgid.*
            "${RUNTIME_DIR}/yt-dlp-aria2-downloader"/.worker-ready.*
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
        bash -c '
            set -euo pipefail
            source "${MOCK_CLI_SOURCE_COPY}"
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
    test_mock_signal_cli_download
    test_mock_signal_cli_leader_exit_descendant
    test_mock_signal_cli_worker_registration
    test_mock_signal_cli_runtime_preparation
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
    test_mock_signal_gui_foreground_group_registration
    test_mock_signal_gui_blocked_progress
    test_mock_signal_gui_cancellation
    test_mock_signal_gui_startup_error
    test_mock_signal_zenity_status
}

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
    assert_array_contains tls_transport_arguments '--batch-file' \
        'affected aria2 GnuTLS build retains native yt-dlp URL transport'
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
        MOCK_QUESTION_ARGS_LOG="${monitor_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${monitor_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${monitor_question_log}" \
        'The progress monitor failed with status 42.' \
        'progress-monitor failure diagnostic'
    [[ ! -s ${monitor_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-monitor diagnostic log.'
    assert_no_test_processes 'progress-monitor failure left GUI descendants'
}

test_mock_runtime_missing_zenity() {
    local no_zenity_bin required_command required_command_path

    # Scenario: missing Zenity is a dependency error, not a graphical crash.
    no_zenity_bin="${TEST_ROOT}/no-zenity-bin"
    mkdir -p -- "${no_zenity_bin}"
    for required_command in \
        bash chmod date dirname grep mkdir mkfifo mktemp mv realpath rm sed setsid sleep \
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

report_mock_integration_completion() {
    if [[ ${MOCK_GROUP} == all ]]; then
        printf 'Mock integration tests passed.\n'
    else
        printf 'Mock integration group passed: %s.\n' "${MOCK_GROUP}"
    fi
}

main() {
    initialize_mock_integration

    run_selected_mock_engine_group
    run_selected_mock_gui_group
    # shellcheck disable=SC2310 # Group predicates intentionally drive execution.
    if mock_group_enabled signals; then
        run_mock_signal_group
    fi
    run_selected_mock_runtime_group

    report_mock_integration_completion
}

main "$@"
