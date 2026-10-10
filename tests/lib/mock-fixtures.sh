#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-fixtures.sh
# Purpose     : Create hermetic command doubles and private instrumented engine fixtures.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    PROJECT_DIR MANAGED_ENGINE_UNDER_TEST MANAGED_ENGINE_DIR \
    GUI_UNDER_TEST GUI_SIGNAL_UNDER_TEST GUI_SIGNAL_REGISTRATION_UNDER_TEST \
    GUI_GROUP_CHILD_UNDER_TEST GUI_GROUP_DESCENDANT_UNDER_TEST CLI_SIGNAL_REGISTRATION_UNDER_TEST \
    MOCK_BIN

# Called by mock-integration.sh after its subreaper/bootstrap and path setup,
# before initialize_mock_integration changes PATH and HOME. All fixture paths
# and GUI deadlines come from that entry point; REAL_* exports are shared with
# the generated command wrappers. Loading this library creates no fixtures.
create_mock_fixtures() {
    install -m 0755 -- "${PROJECT_DIR}/download-video.sh" "${MANAGED_ENGINE_UNDER_TEST}"
    # Observe return from the first deferred handler only in the private fixture.
    python3 -I -B - "${MANAGED_ENGINE_UNDER_TEST}" <<'PY_DEFERRED_SIGNAL_ACK'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
needle = "            DEFERRED_SIGNAL_NAME=${signal_name}\n"
if source.count(needle) != 1:
    raise SystemExit("expected one deferred-signal registration in the engine fixture")
# A marker published inside the INT trap becomes visible before that trap
# returns. Bash 4.4 can consume a second INT during the external mv without
# entering the handler again. Both registration polling loops run this probe
# only after the first handler has returned, retaining the same two-INT test.
acknowledgement = r'''        if [[ -n ${DEFERRED_SIGNAL_STATUS} &&
            -n ${MOCK_DEFERRED_SIGNAL_RETURNED_MARKER:-} &&
            ! -e ${MOCK_DEFERRED_SIGNAL_RETURNED_MARKER} ]]; then
            mock_trace_pre_env handler-return-observed
            printf '%s\n' "${DEFERRED_SIGNAL_STATUS}" \
                >"${MOCK_DEFERRED_SIGNAL_RETURNED_MARKER}.tmp"
            mv -Tf -- "${MOCK_DEFERRED_SIGNAL_RETURNED_MARKER}.tmp" \
                "${MOCK_DEFERRED_SIGNAL_RETURNED_MARKER}"
        fi
'''
registration_poll = "    for ((attempt = 0; attempt < 500; attempt++)); do\n"
if source.count(registration_poll) != 2:
    raise SystemExit("expected both engine registration polling loops")
source = source.replace(registration_poll, registration_poll + acknowledgement)
# Only the private pre-env fixture enables this bounded, builtin-only trace.
# Never record argv, environment contents, or private authentication tokens.
trace_function = r'''
mock_trace_pre_env() {
    [[ -n ${MOCK_PRE_ENV_TRACE:-} ]] || return 0
    local phase=$1
    local observed_time='' unused='' ready_state=absent pgid_state=absent
    MOCK_PRE_ENV_TRACE_COUNT=${MOCK_PRE_ENV_TRACE_COUNT:-0}
    ((MOCK_PRE_ENV_TRACE_COUNT < 96)) || return 0
    MOCK_PRE_ENV_TRACE_COUNT=$((MOCK_PRE_ENV_TRACE_COUNT + 1))
    read -r observed_time unused </proc/uptime || observed_time=unavailable
    [[ -z ${DOWNLOAD_READY_FILE} || ! -f ${DOWNLOAD_READY_FILE} ]] || ready_state=present
    [[ -z ${DOWNLOAD_PGID_FILE} || ! -f ${DOWNLOAD_PGID_FILE} ]] || pgid_state=present
    printf 'phase=%s monotonic=%s parent=%s active=%s deferred=%s deferred_status=%s escalation=%s shutdown=%s requested=%s pid=%s start=%s pgid=%s pgid_start=%s ready=%s pgid_file=%s\n' \
        "${phase}" "${observed_time}" "${BASHPID}" "${SIGNAL_REGISTRATION_ACTIVE}" \
        "${DEFERRED_SIGNAL_NAME}" "${DEFERRED_SIGNAL_STATUS}" \
        "${REGISTRATION_ESCALATION_REQUESTED}" "${SHUTDOWN_REQUESTED}" \
        "${REQUESTED_EXIT_STATUS}" "${DOWNLOAD_WORKER_PID}" \
        "${DOWNLOAD_WORKER_START_TIME}" "${DOWNLOAD_WORKER_PGID}" \
        "${DOWNLOAD_WORKER_PGID_START_TIME}" "${ready_state}" "${pgid_state}" \
        >>"${MOCK_PRE_ENV_TRACE}"
}

'''
source = source.replace("request_shutdown() {\n", trace_function + "request_shutdown() {\n", 1)
probes = (
    ("    local exit_status=$2\n\n    if [[ ${SIGNAL_REGISTRATION_ACTIVE}",
     "    local exit_status=$2\n\n    mock_trace_pre_env request-entry\n    if [[ ${SIGNAL_REGISTRATION_ACTIVE}", 1),
    (needle, needle + "            mock_trace_pre_env deferred-recorded\n", 1),
    ("    SIGNAL_REGISTRATION_ACTIVE=false\n",
     "    mock_trace_pre_env finish-entry\n    SIGNAL_REGISTRATION_ACTIVE=false\n", 1),
    ("            DOWNLOAD_WORKER_START_TIME true || DOWNLOAD_WORKER_START_TIME=''\n",
     "            DOWNLOAD_WORKER_START_TIME true || DOWNLOAD_WORKER_START_TIME=''\n"
     "        mock_trace_pre_env registered-child\n", 2),
    ("    local wait_status=0\n\n    for ((attempt = 0; attempt < attempts; attempt++)); do\n",
     "    local wait_status=0\n\n    mock_trace_pre_env wait-entry\n"
     "    for ((attempt = 0; attempt < attempts; attempt++)); do\n", 1),
    ('            wait "${DOWNLOAD_WORKER_PID}" 2>/dev/null || wait_status=$?\n',
     '            mock_trace_pre_env before-child-wait\n'
     '            wait "${DOWNLOAD_WORKER_PID}" 2>/dev/null || wait_status=$?\n', 1),
)
for before, after, expected in probes:
    if source.count(before) != expected:
        raise SystemExit("pre-env diagnostic probe no longer matches its engine transition")
    source = source.replace(before, after)
path.write_text(source, encoding="utf-8")
PY_DEFERRED_SIGNAL_ACK
    install -m 0644 -- \
        "${PROJECT_DIR}/private-aria2-plan.py" \
        "${MANAGED_ENGINE_DIR}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${MANAGED_ENGINE_DIR}/private-process-supervisor.py"
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

if [[ -n ${MOCK_OUTPUT_DIR:-} ]]; then
    output_previous=''
    for output_argument in "$@"; do
        if [[ ${output_previous} == --output ]]; then
            effective_template=${output_argument%/*}
            export MOCK_OUTPUT_DIR=${effective_template//%%/%}
            break
        fi
        output_previous=${output_argument}
    done
fi

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
        plan_filename="${MOCK_OUTPUT_DIR}/${MOCK_MEDIA_BASENAME:-Mock media [abc123]}.${youtube_hls_source_ext}"
        plan_protocol='m3u8_native'
        plan_url='https://example.invalid/mock-manifest.m3u8'
        plan_ext=${youtube_hls_source_ext}
    else
        plan_filename="${MOCK_OUTPUT_DIR}/${MOCK_MEDIA_BASENAME:-Mock media [abc123]}.webm"
        plan_protocol='http'
        plan_url='https://example.invalid/mock-media.webm'
        plan_ext='webm'
    fi

    if [[ -n ${MOCK_PLAN_PROTOCOL:-} ]]; then
        plan_protocol=${MOCK_PLAN_PROTOCOL}
    fi

    if [[ ${MOCK_NETWORK_PERMISSIONS:-0} == 1 ]]; then
        python3 -I -B "${MOCK_NETWORK_CHECK:?}" plan \
            "${plan_filename}" "${plan_ext}" "${plan_protocol}" "$@"
        exit 0
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

if [[ ${MOCK_NETWORK_PERMISSIONS:-0} == 1 ]]; then
    python3 -I -B "${MOCK_NETWORK_CHECK:?}" native "$@"
fi

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
skip_download=false
previous=''
for argument in "$@"; do
    case ${argument} in
    --no-overwrites) no_overwrites=true ;;
    --no-post-overwrites) no_post_overwrites=true ;;
    --skip-download) skip_download=true ;;
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

# Direct aria2 replay already has its native input. A frozen native plan also
# uses --load-info-json, but still performs its transfer and emits progress.
if [[ -f ${MOCK_OUTPUT_DIR}/${MOCK_MEDIA_BASENAME:-Mock media [abc123]}.webm ]]; then
    skip_download=true
fi
if [[ ${skip_download} != true ]]; then
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
    # Keep this fixture single-process so its published PID/start time covers
    # the complete resistant descendant rather than an untracked wait child.
    python3 -c '
import os
import signal
import sys

started_marker = sys.argv[1]
termination_marker = sys.argv[2]
term_marker = sys.argv[3]
resist_term = sys.argv[4] == "1"


def write_marker(path, value):
    if path:
        with open(path, "w", encoding="utf-8") as marker:
            marker.write(value)


def terminate(signal_number, _frame):
    write_marker(termination_marker, "terminated")
    raise SystemExit(128 + signal_number)


def observe_term(_signal_number, _frame):
    write_marker(term_marker, "received")


signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, observe_term if resist_term else terminate)
write_marker(started_marker, f"{os.getpid()}\n")
while True:
    signal.pause()
' "${MOCK_DESCENDANT_STARTED_MARKER:?}" \
        "${MOCK_DESCENDANT_TERMINATION_MARKER:-}" \
        "${MOCK_DESCENDANT_TERM_MARKER:-}" \
        "${MOCK_DESCENDANT_IGNORE_TERM:-0}" \
        </dev/null >/dev/null 2>&1 &
    exit "${MOCK_DESCENDANT_PARENT_STATUS:-23}"
fi

if [[ ${skip_download} != true ]]; then
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
    output_path="${MOCK_OUTPUT_DIR}/${MOCK_MEDIA_BASENAME:-Mock media [abc123]}.${youtube_hls_source_ext}"
    printf 'YTDLP_POSTPROCESS|started|FixupM3u8\n'
else
    output_path="${MOCK_OUTPUT_DIR}/${MOCK_MEDIA_BASENAME:-Mock media [abc123]}.webm"
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
        if [[ ${result_record_path##*/} != .yt-dlp-result.* &&
            ${result_record_path##*/} != .yt-dlp-path.* ]]; then
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

    if [[ ${MOCK_ARIA2_INVALID_UTF8_DIAGNOSTIC:-0} == 1 ]]; then
        printf 'Malformed diagnostic URL: https://secret.example/\377private-suffix-token\n' >&2
        for scheme in http https HTTP HTTPS hTtP hTtPs; do
            printf 'Scheme diagnostic: %s://secret.example/Token_%s_CaseSensitive\n' \
                "${scheme}" "${scheme}" >&2
        done
    fi

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

    if [[ ${MOCK_NETWORK_PERMISSIONS:-0} == 1 ]]; then
        python3 -I -B "${MOCK_NETWORK_CHECK:?}" aria2 "$@"
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
import time

termination_marker = sys.argv[1]
started_marker = sys.argv[2]
signal_diagnostic = sys.argv[3] == "1"


def terminate(signal_number, _frame):
    if signal_diagnostic:
        # Let an unprotected filter receive the group signal before writing.
        # A successful marker proves that the diagnostic pipe stayed open.
        time.sleep(0.1)
        sys.stdout.buffer.write(b"Final aria2 diagnostic: https://secret.example/cancel-token\n")
        sys.stdout.buffer.flush()
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
' "${MOCK_TERMINATION_MARKER:-}" "${MOCK_STARTED_MARKER:-}" \
            "${MOCK_ARIA2_SIGNAL_DIAGNOSTIC:-0}"
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
        manifest_path="${input_file%/*}/manifest.json"
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

if [[ ${MOCK_NETWORK_REPLACE_AT_PROBE:-0} != 0 && ${summary_probe} == true &&
    ! -e ${MOCK_NETWORK_MUTATION_MARKER:?} ]]; then
    mv -- "${media_path}" "${media_path}.before-swap"
    printf '%s\n' 'foreign media substituted during FFprobe' >"${media_path}"
    : >"${MOCK_NETWORK_MUTATION_MARKER}"
fi

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
        if [[ -n ${MOCK_FAKE_ENGINE_READY:-} ]]; then
            printf ready >"${MOCK_FAKE_ENGINE_READY}"
        fi
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

    cat >"${MOCK_BIN}/python3" <<'EOF_NETWORK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${MOCK_NETWORK_PERMISSIONS:-0} == 1 &&
    ${1##*/} == private-aria2-plan.py && ${2:-} == media-local-safe ]]; then
    # Run the production classifier with only the selected descriptor's
    # filesystem type simulated. This does not emulate SMB kernel I/O behavior.
    exec /usr/bin/python3 -I -B - "$@" <<'PY_NETWORK_FILESYSTEM'
import importlib.util
import os
import sys
from pathlib import Path

sys.argv = sys.argv[1:]
spec = importlib.util.spec_from_file_location("network_filesystem", sys.argv[0])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
destination = os.stat(os.environ["MOCK_NETWORK_DESTINATION"])
real_filesystem_type = module.filesystem_type


def network_filesystem_type(descriptor):
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) == (destination.st_dev, destination.st_ino):
        magic = int(os.environ.get("MOCK_NETWORK_FS_MAGIC", "0xfe534d42"), 16)
        with Path(os.environ["MOCK_NETWORK_PHASE_LOG"]).open("a") as log:
            log.write(f"filesystem:{magic:#x}\n")
        return magic
    return real_filesystem_type(descriptor)


module.filesystem_type = network_filesystem_type
raise SystemExit(module.main())
PY_NETWORK_FILESYSTEM
fi
exec /usr/bin/python3 "$@"
EOF_NETWORK_PYTHON
    chmod 0755 -- "${MOCK_BIN}/python3"

    cat >"${MOCK_BIN}/network-check.py" <<'PY_NETWORK_CHECK'
import json
import os
from pathlib import Path
import stat
import sys

phase, *arguments = sys.argv[1:]
output = Path(os.environ.get("MOCK_NETWORK_DESTINATION",
                             os.environ["MOCK_OUTPUT_DIR"])).resolve()
tokens = (b"NETWORK_FIXTURE_COOKIE_SECRET", b"NETWORK_FIXTURE_HEADER_SECRET",
          b"NETWORK_FIXTURE_SIGNED_SECRET")
private_paths = []
workspace = None


def option_value(option):
    for index, argument in enumerate(arguments):
        if argument == option and index + 1 < len(arguments):
            return arguments[index + 1]
        if argument.startswith(option + "="):
            return argument.partition("=")[2]
    return ""


if phase == "plan":
    filename, extension, protocol = arguments[:3]
    workspace = Path(filename).parent
    cookie = option_value("--cookies")
    if cookie:
        cookie_path = Path(cookie)
        cookie_path.write_text(
            "# Netscape HTTP Cookie File\n"
            "example.invalid\tFALSE\t/\tTRUE\t0\tsession\t"
            + tokens[0].decode() + "\n", encoding="utf-8")
        private_paths.append(cookie_path)
    plan = Path(os.readlink("/proc/self/fd/1"))
    private_paths.append(plan)
    # Model a share that exposes permissive modes even after chmod. Only
    # files on the simulated destination change; local private state does not.
    for path in private_paths:
        if path.is_relative_to(output):
            os.chmod(path, 0o666)
    json.dump({"requested_downloads": [{"filename": filename,
        "format_id": "mock", "ext": extension, "protocol": protocol,
        "url": "http://example.invalid/mock?token=" + tokens[2].decode(),
        "http_headers": {"User-Agent": "mock-agent " + tokens[1].decode()}}]},
        sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
else:
    for name in ("--load-cookies", "--cookies", "--input-file", "--load-info-json"):
        value = option_value(name)
        if value:
            private_paths.append(Path(value))
    if phase == "aria2":
        workspace = Path(option_value("--dir")).parent
    elif phase == "native":
        workspace = Path(option_value("--output")).parent

if workspace is not None:
    assert workspace.name.startswith(".media-work."), workspace
    assert not workspace.is_relative_to(output), workspace
    assert workspace.is_dir() and stat.S_IMODE(workspace.stat().st_mode) == 0o700
    with open(os.environ["MOCK_NETWORK_PHASE_LOG"] + ".workspaces", "a", encoding="utf-8") as log:
        log.write(str(workspace) + "\n")

leaked = False
for path in output.rglob("*"):
    if path.is_file() and not path.is_symlink():
        data = path.read_bytes()
        leaked |= any(token in data for token in tokens)
for path in private_paths:
    metadata = path.stat()
    if path.is_relative_to(output) or stat.S_IMODE(metadata.st_mode) & 0o077:
        leaked = True
for proc in Path("/proc").glob("[0-9]*/cmdline"):
    try:
        data = proc.read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
    leaked |= any(token in data for token in tokens)
with open(os.environ["MOCK_NETWORK_PHASE_LOG"], "a", encoding="utf-8") as log:
    log.write(phase + (":leaked\n" if leaked else ":private\n"))
if private_paths:
    with open(os.environ["MOCK_NETWORK_PHASE_LOG"] + ".paths", "a", encoding="utf-8") as log:
        for path in private_paths:
            log.write(str(path) + "\n")
if leaked and phase != "plan":
    raise SystemExit("network fixture detected exposed private metadata")
PY_NETWORK_CHECK

    cat >"${MOCK_BIN}/network-signal.py" <<'PY_NETWORK_SIGNAL'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

name, engine, output, result, log_path = sys.argv[1:]
started = Path(os.environ["MOCK_STARTED_MARKER"])
with open(log_path, "wb") as log:
    process = subprocess.Popen(
        [engine, "--output-dir", output, "--mode", "video", "--result-file", result,
         "--", "https://example.com/watch?v=network-signal"], stdout=log,
        stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 15
        while not started.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("network signal fixture worker did not become ready")
            time.sleep(0.05)
        competing = subprocess.run(
            [engine, "--output-dir", output, "--mode", "video",
             "--", "https://example.com/watch?v=network-competing"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        if competing.returncode != 75:
            raise RuntimeError("a second session acquired the active network destination")
        signum = getattr(signal, "SIG" + name)
        process.send_signal(signum)
        status = process.wait(timeout=15)
        if status != 128 + signum:
            raise RuntimeError(f"network signal {name} returned unexpected status {status}")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
PY_NETWORK_SIGNAL
}
