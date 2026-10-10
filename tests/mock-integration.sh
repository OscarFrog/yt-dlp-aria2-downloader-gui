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
    engine-network
    gui
    gui-progress
    gui-state
    signals
    stress-signals
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
  engine-staging  Private aria2 staging and crash-residue preservation.
  engine-network  CIFS classification, local workspaces and publication cleanup.
  gui             Complete GUI aggregate, in historical scenario order.
  gui-progress    GUI progress rendering, profiles, and completion behavior.
  gui-state       GUI configuration, file selection, logs, and state behavior.
  signals         CLI/GUI signal forwarding and cancellation behavior.
  stress-signals  Signal scenarios plus network and progress-error cancellation.
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

enable_mock_child_subreaping() {
    local inherited_signal_traps=''

    if [[ ${YTDLP_ARIA2_MOCK_SUBREAPER_PID:-} == "${BASHPID}" ]]; then
        unset YTDLP_ARIA2_MOCK_SUBREAPER_PID
        return 0
    fi

    # Keep the harness PID and signal topology while making Bash reap orphaned
    # fixture children itself, independently of a container's PID 1 behavior.
    inherited_signal_traps=$(trap -p PIPE XFSZ)
    exec python3 -I -c '
import ctypes
import os
import signal
import sys

try:
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "unable to enable mock child subreaping")
    # Python ignores these by default; retain the original exec dispositions.
    for name in ("SIGPIPE", "SIGXFSZ"):
        if f"trap -- \x27\x27 {name}" not in sys.argv[1].splitlines():
            signal.signal(getattr(signal, name), signal.SIG_DFL)
    environment = os.environ.copy()
    environment["YTDLP_ARIA2_MOCK_SUBREAPER_PID"] = str(os.getpid())
    os.execve(sys.argv[2], sys.argv[2:], environment)
except OSError as error:
    print(f"Error: mock child-subreaper startup failed: {error}", file=sys.stderr)
    sys.exit(70)
' "${inherited_signal_traps}" "${BASH}" "${PROJECT_DIR}/tests/mock-integration.sh" "$@"
}

parse_mock_arguments "$@"

for required_command in \
    awk bash cat chmod date dirname env grep head install ln mkdir mkfifo mktemp mv readlink \
    realpath rm setsid sleep stat timeout touch tr flock sha256sum wc python3 find ps; do
    require_test_command "${required_command}"
done
[[ -r /proc/self/cmdline ]] \
    || test_error 'mock integration tests require a readable Linux /proc filesystem.'
enable_mock_child_subreaping "$@"
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

# Libraries declare caller globals and functions without initializing state.
# Keep fixture creation in this Bash process
# after the PID-preserving subreaper bootstrap and before PATH/HOME overrides.
# shellcheck source=tests/lib/mock-fixtures.sh
source "${PROJECT_DIR}/tests/lib/mock-fixtures.sh"
# shellcheck source=tests/lib/mock-common.sh
source "${PROJECT_DIR}/tests/lib/mock-common.sh"
# shellcheck source=tests/lib/mock-engine.sh
source "${PROJECT_DIR}/tests/lib/mock-engine.sh"
# shellcheck source=tests/lib/mock-gui.sh
source "${PROJECT_DIR}/tests/lib/mock-gui.sh"
# shellcheck source=tests/lib/mock-signals.sh
source "${PROJECT_DIR}/tests/lib/mock-signals.sh"
# shellcheck source=tests/lib/mock-runtime.sh
source "${PROJECT_DIR}/tests/lib/mock-runtime.sh"

create_mock_fixtures

run_mock_stress_signal_group() {
    run_mock_signal_group
    test_mock_engine_network_signals
    test_mock_runtime_progress_errors
    # Private staging replacements and crashes synchronize on a started worker
    # before changing its filesystem or signaling it. Startup jitter cannot
    # change those prescribed states; the complete suite covers them once.
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
    if [[ ${MOCK_GROUP} == stress-signals ]]; then
        run_mock_stress_signal_group
    fi
    run_selected_mock_runtime_group

    report_mock_integration_completion
}

main "$@"
