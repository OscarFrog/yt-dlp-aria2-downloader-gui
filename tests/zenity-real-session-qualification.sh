#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/zenity-real-session-qualification.sh
# Purpose     : Record a controlled end-to-end qualification with real Zenity.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
readonly GUI="${PROJECT_DIR}/download-video-gui.sh"

SESSION_ROOT=''
GUI_PID=''
GUI_SID=''
WATCHER_PID=''
EVIDENCE_DIR=''
HARNESS_PHASE='startup'

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    return 65
}

usage() {
    cat <<'EOF_USAGE'
Usage: tests/zenity-real-session-qualification.sh SCENARIO [EVIDENCE_DIR]

SCENARIO is one of:
  success
  error
  cancel-transfer
  cancel-ffmpeg
  cancel-success-race
  new-download
  open-folder
  signal-entry
  signal-progress

This is deliberately a controlled real-GUI protocol, not a Zenity mock. The
operator performs the visible interactions while the harness records versions,
process topology, exit status, privacy checks, and residual descendants.
EOF_USAGE
}

record_harness_signal() {
    local signal_name=$1
    local exit_status=$2

    if [[ -n ${EVIDENCE_DIR} && -d ${EVIDENCE_DIR} ]]; then
        {
            printf 'harness_signal=%s\n' "${signal_name}"
            printf 'harness_phase=%s\n' "${HARNESS_PHASE}"
            printf 'harness_signal_exit_status=%d\n' "${exit_status}"
        } >>"${EVIDENCE_DIR}/scenario.txt" 2>/dev/null || true
    fi

    exit "${exit_status}"
}

cleanup() {
    local cleanup_status=$?

    trap - EXIT HUP INT TERM

    if [[ -n ${EVIDENCE_DIR} && -d ${EVIDENCE_DIR} ]]; then
        {
            printf 'harness_exit_status=%d\n' "${cleanup_status}"
            printf 'harness_final_phase=%s\n' "${HARNESS_PHASE}"
        } >>"${EVIDENCE_DIR}/scenario.txt" 2>/dev/null || true
    fi

    if [[ -n ${WATCHER_PID} ]]; then
        kill -TERM -- "${WATCHER_PID}" 2>/dev/null || true
        wait "${WATCHER_PID}" 2>/dev/null || true
    fi
    if [[ -n ${GUI_SID} && ${GUI_SID} =~ ^[1-9][0-9]*$ ]]; then
        kill -TERM -- "-${GUI_SID}" 2>/dev/null || true
    elif [[ -n ${GUI_PID} ]]; then
        kill -TERM -- "${GUI_PID}" 2>/dev/null || true
    fi
    if [[ -n ${GUI_PID} ]]; then
        wait "${GUI_PID}" 2>/dev/null || true
    fi
    if [[ -n ${SESSION_ROOT} ]]; then
        rm -rf -- "${SESSION_ROOT}" || true
    fi
}

relevant_processes() {
    local uid=$1

    ps -u "${uid}" -o pid=,comm=,args= \
        | awk '
            $2 != "awk" && $2 != "grep" && $2 != "ps" &&
            ($0 ~ /(^|[[:space:]\/])(yt-dlp|aria2c|ffmpeg|ffprobe|deno)([[:space:]]|$)/ ||
             $0 ~ /(download-video\.sh|progress-monitor\.sh)/) {
                print $1 "|" $2
            }
        ' \
        | LC_ALL=C sort -u
}

watch_process_topology() {
    local uid=$1
    local gui_pid=$2
    local gui_sid=$3
    local topology_file=$4
    local leak_file=$5

    local topology_timestamp
    local privacy_timestamp

    while kill -0 -- "${gui_pid}" 2>/dev/null; do
        topology_timestamp=$(date --iso-8601=ns)
        privacy_timestamp=$(date --iso-8601=seconds)
        printf -- '--- %s ---\n' "${topology_timestamp}" >>"${topology_file}"
        ps -u "${uid}" -o pid=,ppid=,pgid=,sid=,comm= \
            | awk -v target_sid="${gui_sid}" '$4 == target_sid { print }' \
                >>"${topology_file}" || true

        ps -u "${uid}" -o pid=,ppid=,pgid=,sid=,comm=,args= \
            | awk -v target_sid="${gui_sid}" -v timestamp="${privacy_timestamp}" '
                $4 == target_sid &&
                $5 != "awk" && $5 != "grep" && $5 != "ps" &&
                ($0 ~ /(^|[[:space:]\/])(yt-dlp|aria2c|ffmpeg|ffprobe|deno)([[:space:]]|$)/ ||
                 $0 ~ /(download-video\.sh|progress-monitor\.sh)/) &&
                $0 ~ /https?:\/\// {
                    print timestamp " potential-url-in-argv pid=" $1 " comm=" $5
                }
            ' >>"${leak_file}" || true

        sleep 0.2
    done
}

print_scenario_instructions() {
    local scenario=$1
    local output_dir=$2

    printf '\nReal Zenity qualification scenario: %s\n' "${scenario}"
    printf 'When the folder chooser appears, select exactly:\n  %s\n\n' "${output_dir}"

    case ${scenario} in
        success)
            printf '%s\n' \
                'Use a valid downloadable URL and let the operation finish normally.' \
                'Confirm that the success dialog corresponds to a real final file.'
            ;;
        error)
            printf '%s\n' \
                'Use https://127.0.0.1:9/qualification-failure as the URL.' \
                'Confirm that the failure is reported as an error and never as success.'
            ;;
        cancel-transfer)
            printf '%s\n' \
                'Use a valid source large enough to keep the transfer active.' \
                'Cancel from the Zenity progress dialog while data is transferring.'
            ;;
        cancel-ffmpeg)
            printf '%s\n' \
                'Use a source/profile that reaches FFmpeg merge/remux.' \
                'Cancel from the progress dialog while FFmpeg is active.'
            ;;
        cancel-success-race)
            printf '%s\n' \
                'Use a short valid source and cancel as close as practical to completion.' \
                'Repeat this harness 10 times; a valid completed result must not become a false failure.'
            ;;
        new-download)
            printf '%s\n' \
                'Complete one valid download, choose New download, then complete or cancel the second flow.' \
                'Confirm that the second flow starts cleanly without stale state.'
            ;;
        open-folder)
            printf '%s\n' \
                'Complete one valid download and use Open folder from the success dialog.' \
                'Confirm that the selected destination folder opens.'
            ;;
        signal-entry)
            printf '%s\n' \
                'Leave the initial URL entry dialog open without entering a URL.' \
                'Return to this terminal and type SIGNAL when prompted.' \
                'Confirm that the entry dialog closes immediately with no residual window.'
            ;;
        signal-progress)
            printf '%s\n' \
                'Use a valid source large enough to keep the transfer active.' \
                'Wait until the progress dialog is visibly updating.' \
                'Return to this terminal and type SIGNAL when prompted.' \
                'Confirm that the progress dialog closes immediately with no residual window.'
            ;;
        *)
            printf 'FAIL: unsupported Zenity qualification scenario: %s\n' \
                "${scenario}" >&2
            return 65
            ;;
    esac
}

record_environment() {
    local evidence_dir=$1
    local os_id=${ID:-unknown}
    local os_version=${VERSION_ID:-unknown}
    local timestamp
    local zenity_version
    local ffmpeg_version='absent'
    local ffprobe_version='absent'
    local aria2_version='absent'

    timestamp=$(date --iso-8601=seconds)
    zenity_version=$(zenity --version 2>&1 | awk 'NR == 1 { first = $0 } END { print first }')
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg_version=$(ffmpeg -hide_banner -version | awk 'NR == 1 { first = $0 } END { print first }')
    fi
    if command -v ffprobe >/dev/null 2>&1; then
        ffprobe_version=$(ffprobe -hide_banner -version | awk 'NR == 1 { first = $0 } END { print first }')
    fi
    if command -v aria2c >/dev/null 2>&1; then
        aria2_version=$(aria2c --version | awk 'NR == 1 { first = $0 } END { print first }')
    fi

    {
        printf 'timestamp=%s\n' "${timestamp}"
        printf 'os_id=%s\n' "${os_id}"
        printf 'os_version=%s\n' "${os_version}"
        printf 'desktop=%s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
        printf 'session_type=%s\n' "${XDG_SESSION_TYPE:-unknown}"
        printf 'zenity=%s\n' "${zenity_version}"
        printf 'ffmpeg=%s\n' "${ffmpeg_version}"
        printf 'ffprobe=%s\n' "${ffprobe_version}"
        printf 'aria2=%s\n' "${aria2_version}"
    } >"${evidence_dir}/environment.txt"
}
assert_no_residual_processes() {
    local uid=$1
    local gui_sid=$2
    local evidence_dir=$3
    local current_file="${evidence_dir}/processes-after.txt"
    local residual_file="${evidence_dir}/residual-processes.txt"
    local attempt

    : >"${current_file}"
    : >"${residual_file}"

    for ((attempt = 0; attempt < 50; attempt++)); do
        ps -u "${uid}" -o pid=,sid=,comm= \
            | awk -v target_sid="${gui_sid}" '
                $2 == target_sid {
                    print $1 "|" $3
                }
            ' >"${current_file}" || true

        if [[ ! -s ${current_file} ]]; then
            : >"${residual_file}"
            return 0
        fi
        sleep 0.1
    done

    cp -- "${current_file}" "${residual_file}"
    fail_test \
        "download-related processes in GUI session ${gui_sid} remained after the GUI exited."
}

main() {
    local scenario=${1:-}
    local requested_evidence=${2:-}
    local uid
    local evidence_dir
    local output_dir
    local baseline_file
    local leak_file
    local session_id_file
    local actual_sid=''
    local actual_pgid=''
    local attempt
    local topology_file
    local raw_gui_stdout
    local raw_gui_stderr
    local gui_status=0
    local answer=''
    local state_url_hits=0
    local state_file_count=0
    local state_dir_count=0
    local state_log_count=0
    local evidence_timestamp=''
    local diagnostic_file
    local command_name

    case ${scenario} in
        success | error | cancel-transfer | cancel-ffmpeg | cancel-success-race | new-download | open-folder | signal-entry | signal-progress)
            ;;
        -h | --help | '')
            usage
            [[ -n ${scenario} ]] && return 0
            return 64
            ;;
        *)
            usage >&2
            fail_test "unknown scenario: ${scenario}."
            ;;
    esac

    for command_name in awk bash cp date find grep id mktemp ps realpath setsid sleep sort wc zenity; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            fail_test "required command is absent: ${command_name}."
        fi
    done
    if [[ ! -x ${GUI} ]]; then
        fail_test "GUI launcher is not executable: ${GUI}."
    fi
    if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
        fail_test 'no graphical DISPLAY or WAYLAND_DISPLAY is available.'
    fi

    # /etc/os-release is OS-controlled metadata and is used only to scope this
    # release gate to the two distributions covered by this qualification.
    # shellcheck disable=SC1091
    source /etc/os-release
    case ${ID:-}:${VERSION_ID:-} in
        fedora:44 | ubuntu:24.04) ;;
        *)
            fail_test \
                "real Zenity qualification requires Fedora 44 or Ubuntu 24.04; got ${ID:-unknown} ${VERSION_ID:-unknown}."
            ;;
    esac

    trap cleanup EXIT
    trap 'record_harness_signal HUP 129' HUP
    trap 'record_harness_signal INT 130' INT
    trap 'record_harness_signal TERM 143' TERM

    SESSION_ROOT=$(mktemp -d)
    output_dir="${SESSION_ROOT}/selected-output"
    mkdir -p -- "${output_dir}"

    if [[ -n ${requested_evidence} ]]; then
        mkdir -p -- "${requested_evidence}"
        evidence_dir=$(realpath -e -- "${requested_evidence}")
        EVIDENCE_DIR=${evidence_dir}
    else
        evidence_timestamp=$(date +%Y%m%dT%H%M%S)
        evidence_dir="${PROJECT_DIR}/qualification-evidence/zenity/${evidence_timestamp}-${scenario}"
        mkdir -p -- "${evidence_dir}"
        EVIDENCE_DIR=${evidence_dir}
    fi
    chmod 700 -- "${evidence_dir}"

    uid=$(id -u)
    baseline_file="${evidence_dir}/processes-before.txt"
    leak_file="${evidence_dir}/privacy-findings.txt"
    topology_file="${evidence_dir}/process-topology.txt"
    raw_gui_stdout="${SESSION_ROOT}/gui.stdout"
    raw_gui_stderr="${SESSION_ROOT}/gui.stderr"
    session_id_file="${SESSION_ROOT}/gui.sid"
    : >"${leak_file}"
    : >"${topology_file}"

    relevant_processes "${uid}" >"${baseline_file}"
    record_environment "${evidence_dir}"
    printf 'scenario=%s\n' "${scenario}" >"${evidence_dir}/scenario.txt"

    print_scenario_instructions "${scenario}" "${output_dir}"
    printf '\nEvidence directory: %s\n' "${evidence_dir}"
    printf 'Start the GUI now and perform the scenario exactly as described.\n\n'

    HARNESS_PHASE='launching-gui'
    set +e
    # The single-quoted child program is intentionally expanded by the child
    # Bash launched via `bash -c`, not by this qualification harness.
    # shellcheck disable=SC2016
    XDG_CONFIG_HOME="${SESSION_ROOT}/config" \
        XDG_STATE_HOME="${SESSION_ROOT}/state" \
        setsid --wait \
        bash -c '
            session_id_file=$1
            shift
            printf "%s\n" "$$" >"${session_id_file}" || exit 125
            exec "$@"
        ' bash "${session_id_file}" bash "${GUI}" \
        >"${raw_gui_stdout}" \
        2>"${raw_gui_stderr}" &
    GUI_PID=$!
    set -e

    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s ${session_id_file} ]] && break
        kill -0 -- "${GUI_PID}" 2>/dev/null \
            || fail_test 'GUI launcher exited before publishing its session identity.'
        sleep 0.05
    done
    [[ -s ${session_id_file} ]] \
        || fail_test 'GUI session identity was not published within 5 seconds.'

    IFS= read -r GUI_SID <"${session_id_file}" \
        || fail_test 'unable to read the GUI session identity.'
    [[ ${GUI_SID} =~ ^[1-9][0-9]*$ ]] \
        || fail_test "invalid GUI session identity: ${GUI_SID}."

    actual_sid=$(ps -o sid= -p "${GUI_SID}" 2>/dev/null) \
        || fail_test 'unable to verify the published GUI session identity.'
    actual_sid=${actual_sid//[[:space:]]/}
    actual_pgid=$(ps -o pgid= -p "${GUI_SID}" 2>/dev/null) \
        || fail_test 'unable to verify the published GUI process group.'
    actual_pgid=${actual_pgid//[[:space:]]/}
    [[ ${actual_sid} == "${GUI_SID}" && ${actual_pgid} == "${GUI_SID}" ]] \
        || fail_test \
            "published GUI identity is not the session/process-group leader: sid=${actual_sid} pgid=${actual_pgid} expected=${GUI_SID}."

    {
        printf 'gui_launcher_pid=%s\n' "${GUI_PID}"
        printf 'gui_session_id=%s\n' "${GUI_SID}"
        printf 'gui_process_group_id=%s\n' "${actual_pgid}"
    } >>"${evidence_dir}/scenario.txt"

    watch_process_topology \
        "${uid}" "${GUI_PID}" "${GUI_SID}" "${topology_file}" "${leak_file}" &
    WATCHER_PID=$!

    case ${scenario} in
        signal-entry | signal-progress)
            printf '\nType SIGNAL only when the requested Zenity dialog is visibly active: '
            if ! IFS= read -r answer; then
                fail_test 'operator input ended before external signal confirmation.'
            fi
            [[ ${answer} == SIGNAL ]] \
                || fail_test 'operator did not confirm the external signal point.'
            printf 'external_gui_signal=TERM\n' \
                >>"${evidence_dir}/scenario.txt"
            kill -TERM -- "${GUI_SID}" \
                || fail_test 'unable to send TERM to the GUI PID.'
            ;;
        *) ;;
    esac

    HARNESS_PHASE='waiting-gui'
    set +e
    wait "${GUI_PID}"
    gui_status=$?
    set -e
    GUI_PID=''

    HARNESS_PHASE='post-gui'

    kill -TERM -- "${WATCHER_PID}" 2>/dev/null || true
    wait "${WATCHER_PID}" 2>/dev/null || true
    WATCHER_PID=''

    printf 'gui_exit_status=%d\n' "${gui_status}" >>"${evidence_dir}/scenario.txt"

    case ${scenario} in
        signal-entry | signal-progress)
            ((gui_status == 143)) \
                || fail_test \
                    "externally signaled GUI exited with status ${gui_status}, expected 143."
            ;;
        *) ;;
    esac

    assert_no_residual_processes "${uid}" "${GUI_SID}" "${evidence_dir}"

    if [[ -d ${SESSION_ROOT}/state ]]; then
        state_url_hits=$(
            { grep -RIlE -- 'https?://' "${SESSION_ROOT}/state" 2>/dev/null || true; } \
                | wc -l
        )
    fi
    for diagnostic_file in "${raw_gui_stdout}" "${raw_gui_stderr}"; do
        if grep -qE -- 'https?://' "${diagnostic_file}" 2>/dev/null; then
            printf 'potential-url-in-gui-diagnostic file=%s\n' \
                "${diagnostic_file##*/}" >>"${leak_file}"
        fi
    done
    if ((state_url_hits > 0)); then
        printf 'potential-url-in-retained-state files=%d\n' "${state_url_hits}" >>"${leak_file}"
    fi
    if [[ -s ${leak_file} ]]; then
        fail_test 'a potential sensitive URL exposure was detected; raw diagnostics were not retained.'
    fi

    # Only diagnostics proven not to contain URL-like data may leave the private
    # session directory. A failed privacy assertion therefore cannot persist the
    # leaked URL inside the qualification evidence itself.
    cp -a -- "${raw_gui_stdout}" "${evidence_dir}/gui.stdout"
    cp -a -- "${raw_gui_stderr}" "${evidence_dir}/gui.stderr"

    printf '\nGUI process exited with status %d.\n' "${gui_status}"
    printf 'No new download-related descendant remains and no URL exposure was detected by the harness.\n'
    printf 'Did the visible Zenity behavior satisfy the scenario instructions with no false success/failure or blocking? [yes/no] '
    if ! IFS= read -r answer; then
        printf 'operator_verdict=FAIL_EOF
' >>"${evidence_dir}/scenario.txt"
        fail_test 'operator verdict input ended before a yes/no answer was provided.'
    fi
    case ${answer} in
        y | Y | yes | YES | Yes | oui | OUI | Oui)
            printf 'operator_verdict=PASS\n' >>"${evidence_dir}/scenario.txt"
            ;;
        *)
            printf 'operator_verdict=FAIL\n' >>"${evidence_dir}/scenario.txt"
            fail_test 'operator did not confirm the real Zenity behavior.'
            ;;
    esac

    # Retain only whitelisted metadata about isolated application state.
    # The state tree itself may contain diagnostics or future sensitive fields
    # that are not covered by the URL-only privacy detector above.
    if [[ -d ${SESSION_ROOT}/state ]]; then
        state_file_count=$(
            find "${SESSION_ROOT}/state" -type f -print | wc -l
        )
        state_dir_count=$(
            find "${SESSION_ROOT}/state" -type d -print | wc -l
        )
        state_log_count=$(
            find "${SESSION_ROOT}/state" -type f -name 'download-*.log' -print | wc -l
        )
        {
            printf 'state_present=yes
'
            printf 'state_file_count=%d
' "${state_file_count}"
            printf 'state_directory_count=%d
' "${state_dir_count}"
            printf 'retained_download_log_count=%d
' "${state_log_count}"
        } >"${evidence_dir}/isolated-state-summary.txt"
    else
        printf 'state_present=no
' >"${evidence_dir}/isolated-state-summary.txt"
    fi

    HARNESS_PHASE='completed'
    printf 'Real Zenity scenario %s passed. Evidence: %s\n' \
        "${scenario}" "${evidence_dir}"
}

main "$@"
