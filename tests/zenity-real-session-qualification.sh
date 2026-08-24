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
    if [[ -n ${GUI_PID} ]]; then
        if kill -0 -- "-${GUI_PID}" 2>/dev/null; then
            kill -TERM -- "-${GUI_PID}" 2>/dev/null || true
        else
            kill -TERM -- "${GUI_PID}" 2>/dev/null || true
        fi
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
    local topology_file=$3
    local leak_file=$4

    local topology_timestamp
    local privacy_timestamp

    while kill -0 -- "${gui_pid}" 2>/dev/null; do
        topology_timestamp=$(date --iso-8601=ns)
        privacy_timestamp=$(date --iso-8601=seconds)
        printf -- '--- %s ---\n' "${topology_timestamp}" >>"${topology_file}"
        ps -u "${uid}" -o pid=,ppid=,pgid=,sid=,comm= >>"${topology_file}" || true

        ps -u "${uid}" -o pid=,comm=,args= \
            | awk -v timestamp="${privacy_timestamp}" '
                $2 != "awk" && $2 != "grep" && $2 != "ps" &&
                ($0 ~ /(^|[[:space:]\/])(yt-dlp|aria2c|ffmpeg|ffprobe|deno)([[:space:]]|$)/ ||
                 $0 ~ /(download-video\.sh|progress-monitor\.sh)/) &&
                $0 ~ /https?:\/\// {
                    print timestamp " potential-url-in-argv pid=" $1 " comm=" $2
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
    local baseline_file=$2
    local evidence_dir=$3
    local current_file="${evidence_dir}/processes-after.txt"
    local residual_file="${evidence_dir}/residual-processes.txt"

    relevant_processes "${uid}" >"${current_file}"

    awk -F'|' '
        NR == FNR { baseline[$1] = 1; next }
        !baseline[$1] { print }
    ' "${baseline_file}" "${current_file}" >"${residual_file}"

    if [[ -s ${residual_file} ]]; then
        fail_test 'download-related processes remained after the GUI exited.'
    fi
}

main() {
    local scenario=${1:-}
    local requested_evidence=${2:-}
    local uid
    local evidence_dir
    local output_dir
    local baseline_file
    local leak_file
    local topology_file
    local raw_gui_stdout
    local raw_gui_stderr
    local gui_status=0
    local answer=''
    local state_url_hits=0
    local evidence_timestamp=''
    local diagnostic_file
    local command_name

    case ${scenario} in
        success | error | cancel-transfer | cancel-ffmpeg | cancel-success-race | new-download | open-folder)
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

    for command_name in awk bash cp date grep id mktemp ps realpath setsid sleep sort wc zenity; do
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
    # release-gate protocol to the two distributions named by the audit.
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
    XDG_CONFIG_HOME="${SESSION_ROOT}/config" \
        XDG_STATE_HOME="${SESSION_ROOT}/state" \
        setsid --wait \
        bash "${GUI}" \
        >"${raw_gui_stdout}" \
        2>"${raw_gui_stderr}" &
    GUI_PID=$!
    set -e

    watch_process_topology \
        "${uid}" "${GUI_PID}" "${topology_file}" "${leak_file}" &
    WATCHER_PID=$!

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

    sleep 1
    assert_no_residual_processes "${uid}" "${baseline_file}" "${evidence_dir}"

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
    IFS= read -r answer
    case ${answer} in
        y | Y | yes | YES | Yes | oui | OUI | Oui)
            printf 'operator_verdict=PASS\n' >>"${evidence_dir}/scenario.txt"
            ;;
        *)
            printf 'operator_verdict=FAIL\n' >>"${evidence_dir}/scenario.txt"
            fail_test 'operator did not confirm the real Zenity behavior.'
            ;;
    esac

    cp -a -- "${SESSION_ROOT}/state" "${evidence_dir}/isolated-state" 2>/dev/null || true
    HARNESS_PHASE='completed'
    printf 'Real Zenity scenario %s passed. Evidence: %s\n' \
        "${scenario}" "${evidence_dir}"
}

main "$@"
