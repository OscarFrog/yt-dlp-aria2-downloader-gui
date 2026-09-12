#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/test-runner-integration.sh
# Purpose     : Verify test-runner diagnosis, timing, concurrency, and statuses.
# ==============================================================================

set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/project-files.sh
source "${SCRIPT_DIR}/lib/project-files.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/test-runner.sh
source "${SCRIPT_DIR}/lib/test-runner.sh"

cleanup() {
    trap - EXIT HUP INT TERM
    test_runner_cleanup
}

test_startup_signal_registration_stress() {
    python3 - "${SCRIPT_DIR}/lib/test-runner.sh" <<'PY_STARTUP_STRESS'
import os
import pathlib
import signal
import subprocess
import tempfile

library = pathlib.Path(__import__("sys").argv[1])
fixture = r'''
set -u
set -T
source "$1"
marker=$2
registration_gate=$3
signal_sent_gate=$4
unregistered_signal_gate=$5
runner_pid=$BASHPID

_test_runner_exec_child() {
    local attempt=0

    printf '%s\n' "$BASHPID" >"${marker}"
    for ((attempt = 0; attempt < 2000; attempt++)); do
        [[ -e ${registration_gate} ]] && break
        sleep 0.001
    done
    [[ -e ${registration_gate} ]] || exit 70
    kill -INT -- "${runner_pid}" || exit 71
    : >"${signal_sent_gate}"
    exec sleep 30
}

# Keep this stress focused on launch registration and make every iteration
# fast. The production termination implementation has separate integration
# coverage for process-group signaling and escalation.
test_runner_terminate_children() {
    local _signal_name=$1
    local slot=''
    local pid=''
    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        kill -KILL -- "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        unset 'TEST_RUNNER_CHILD_PIDS[slot]'
        unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
        unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
        unset 'TEST_RUNNER_CHILD_TOKENS[slot]'
        unset 'TEST_RUNNER_CHILD_START_TIMES[slot]'
    done
}

startup_debug_gate() {
    local attempt=0

    if [[ ${BASH_COMMAND} == 'child_pid=$!' ]]; then
        : >"${registration_gate}"
        for ((attempt = 0; attempt < 2000; attempt++)); do
            # Bash 5.2 may retain the pending INT until this DEBUG trap
            # returns. Wait for the sender's acknowledgement instead of
            # requiring the nested signal trap to have run already.
            [[ -e ${signal_sent_gate} ]] && return 0
            sleep 0.001 || true
        done
        return 70
    fi
}

startup_signal_handler() {
    # Prove that INT was observed while the child arrays were still incomplete;
    # a later, ordinary signal would not exercise startup deferral.
    if [[ ${TEST_RUNNER_STARTING_CHILD} == true &&
        -z ${TEST_RUNNER_CHILD_PIDS[0]:-} ]]; then
        : >"${unregistered_signal_gate}"
    fi
    test_runner_handle_signal INT 130
}

trap startup_debug_gate DEBUG
trap startup_signal_handler INT
trap 'test_runner_handle_signal TERM 143' TERM
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
exit 99
'''


def running(pid: int, token: pathlib.Path) -> bool:
    stat_path = pathlib.Path(f"/proc/{pid}/stat")
    try:
        fields = stat_path.read_text(encoding="ascii").split()
    except OSError:
        return False
    if len(fields) >= 3 and fields[2] == "Z":
        return False

    # A busy parallel suite can recycle a released PID before this controller
    # observes it. Match an inherited identity token so cleanup never mistakes
    # an unrelated replacement process for the supervised fixture.
    expected = f"YTDLP_ARIA2_TEST_CHILD_TOKEN={token}".encode()
    try:
        environment = pathlib.Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    return expected in environment.split(b"\0")


with tempfile.TemporaryDirectory(prefix="runner-startup-stress-") as temp_dir:
    root = pathlib.Path(temp_dir)
    for iteration in range(30):
        marker = root / f"child-{iteration}.pid"
        registration_gate = root / f"registration-{iteration}.ready"
        signal_sent_gate = root / f"signal-sent-{iteration}.ready"
        unregistered_signal_gate = root / f"signal-unregistered-{iteration}.ready"
        fixture_env = os.environ.copy()
        fixture_env["YTDLP_ARIA2_TEST_CHILD_TOKEN"] = str(marker)
        process = subprocess.Popen(
            [
                "bash",
                "-c",
                fixture,
                "bash",
                str(library),
                str(marker),
                str(registration_gate),
                str(signal_sent_gate),
                str(unregistered_signal_gate),
            ],
            env=fixture_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            _, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            _, stderr = process.communicate()
            raise AssertionError(
                f"startup signal iteration {iteration} timed out: "
                f"{stderr.decode(errors='replace')}"
            ) from error
        child_pid = 0
        if marker.exists():
            child_pid = int(marker.read_text(encoding="ascii").strip())
        try:
            if process.returncode != 130:
                raise AssertionError(
                    f"startup signal iteration {iteration} returned "
                    f"{process.returncode}, expected first-signal status 130: "
                    f"{stderr.decode(errors='replace')}"
                )
            if not child_pid:
                raise AssertionError(
                    f"startup signal iteration {iteration} published no child PID"
                )
            if not unregistered_signal_gate.exists():
                raise AssertionError(
                    f"startup signal iteration {iteration} was not observed "
                    "before child-array registration"
                )
            if running(child_pid, marker):
                raise AssertionError(
                    f"startup signal iteration {iteration} left child {child_pid}"
                )
        finally:
            if child_pid and running(child_pid, marker):
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
PY_STARTUP_STRESS
}

test_startup_signal_final_transition() {
    python3 - "${SCRIPT_DIR}/lib/test-runner.sh" <<'PY_FINAL_TRANSITION'
import os
import pathlib
import signal
import subprocess
import tempfile

library = pathlib.Path(__import__("sys").argv[1])
fixture = r'''
set -u
set -T
source "$1"
marker=$2
runner_pid=$BASHPID
final_gate_fired=false

_test_runner_exec_child() {
    printf '%s\n' "$BASHPID" >"${marker}"
    exec sleep 30
}

test_runner_terminate_children() {
    local _signal_name=$1
    local slot=''
    local pid=''
    for slot in "${!TEST_RUNNER_CHILD_PIDS[@]}"; do
        pid=${TEST_RUNNER_CHILD_PIDS[${slot}]}
        kill -KILL -- "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        unset 'TEST_RUNNER_CHILD_PIDS[slot]'
        unset 'TEST_RUNNER_CHILD_PGIDS[slot]'
        unset 'TEST_RUNNER_CHILD_COMPLETIONS[slot]'
        unset 'TEST_RUNNER_CHILD_TOKENS[slot]'
        unset 'TEST_RUNNER_CHILD_START_TIMES[slot]'
    done
}

final_transition_gate() {
    local attempt=0

    if [[ ${final_gate_fired} == false &&
        ${BASH_COMMAND} == 'TEST_RUNNER_STARTING_CHILD=false' &&
        -z ${TEST_RUNNER_DEFERRED_SIGNAL} ]]; then
        final_gate_fired=true
        for ((attempt = 0; attempt < 100; attempt++)); do
            [[ -s ${marker} ]] && break
            sleep 0.001
        done
        [[ -s ${marker} ]] || return 70
        kill -TERM -- "${runner_pid}"
    fi
}

trap final_transition_gate DEBUG
trap 'test_runner_handle_signal TERM 143' TERM
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
exit 99
'''


def running(pid: int, token: pathlib.Path) -> bool:
    stat_path = pathlib.Path(f"/proc/{pid}/stat")
    try:
        fields = stat_path.read_text(encoding="ascii").split()
    except OSError:
        return False
    if len(fields) >= 3 and fields[2] == "Z":
        return False

    expected = f"YTDLP_ARIA2_TEST_CHILD_TOKEN={token}".encode()
    try:
        environment = pathlib.Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    return expected in environment.split(b"\0")


with tempfile.TemporaryDirectory(prefix="runner-final-transition-") as temp_dir:
    marker = pathlib.Path(temp_dir) / "child.pid"
    fixture_env = os.environ.copy()
    fixture_env["YTDLP_ARIA2_TEST_CHILD_TOKEN"] = str(marker)
    result = subprocess.run(
        ["bash", "-c", fixture, "bash", str(library), str(marker)],
        env=fixture_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    child_pid = int(marker.read_text(encoding="ascii").strip())
    try:
        if result.returncode != 143:
            raise AssertionError(
                "final-transition signal returned "
                f"{result.returncode}, expected 143: "
                f"{result.stderr.decode(errors='replace')}"
            )
        if running(child_pid, marker):
            raise AssertionError(
                f"final-transition signal left child {child_pid}"
            )
    finally:
        if running(child_pid, marker):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
PY_FINAL_TRANSITION
}

test_parallel_repeat_runner() {
    local barrier_root="${TEST_RUNNER_LOG_DIR}/repeat-barrier"

    assert_status 64 'repeat runner rejects an invalid termination grace override' \
        env YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=0 \
        bash "${SCRIPT_DIR}/repeat-qualification.sh" \
        --runs 1 --jobs 1 -- bash -c 'exit 0'

    assert_status 2 'repeat runner rejects run-count overflow before arithmetic' \
        bash "${SCRIPT_DIR}/repeat-qualification.sh" \
        --runs 18446744073709551617 --jobs 1 -- bash -c 'exit 0'
    assert_status 2 'repeat runner rejects job-count overflow before arithmetic' \
        bash "${SCRIPT_DIR}/repeat-qualification.sh" \
        --runs 1 --jobs 18446744073709551617 -- bash -c 'exit 0'
    assert_status 0 'repeat runner preserves leading-zero count support' \
        bash "${SCRIPT_DIR}/repeat-qualification.sh" \
        --runs 0001 --jobs 0001 -- bash -c 'exit 0'

    mkdir -p -- "${barrier_root}"
    # The nested Bash child, not this test shell, expands the repeat metadata.
    # shellcheck disable=SC2016
    assert_status_split 17 'parallel repeat runner preserves ordered failures' \
        timeout --signal=TERM --kill-after=1s 5s \
        bash "${SCRIPT_DIR}/repeat-qualification.sh" \
        --label 'Synthetic repeat' --runs 3 --jobs 3 -- \
        bash -c '
            set -euo pipefail
            root=$1
            iteration=${YTDLP_ARIA2_REPEAT_ITERATION:?}
            total=${YTDLP_ARIA2_REPEAT_TOTAL:?}
            : >"${root}/started-${iteration}"
            for _ in {1..200}; do
                if [[ -e ${root}/started-1 &&
                    -e ${root}/started-2 &&
                    -e ${root}/started-3 ]]; then
                    break
                fi
                sleep 0.01
            done
            [[ -e ${root}/started-1 &&
                -e ${root}/started-2 &&
                -e ${root}/started-3 ]]
            printf "child=%s/%s\n" "${iteration}" "${total}"
            [[ ${iteration} != 2 ]] || exit 17
        ' bash "${barrier_root}"

    assert_text_contains "${ASSERT_STDOUT}" 'child=1/3' \
        'repeat runner reports first child output'
    assert_text_contains "${ASSERT_STDOUT}" 'child=2/3' \
        'repeat runner reports failing child output'
    assert_text_contains "${ASSERT_STDOUT}" 'child=3/3' \
        'repeat runner reports last child output'
    assert_text_contains "${ASSERT_STDERR}" \
        'Synthetic repeat 2/3: FAIL (status 17,' \
        'repeat runner reports the exact child failure'
}

test_ffmpeg_cancellation_group_registration() {
    python3 - "${SCRIPT_DIR}/ffmpeg-generation-compatibility.sh" <<'PY_FFMPEG_GROUP'
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
entrypoint = 'main "$@"\n'
if not source.endswith(entrypoint):
    raise AssertionError("FFmpeg qualification entrypoint changed")
fixture = r'''
source "$1"
TEST_ROOT=$2
trap cleanup EXIT
trap 'exit 143' TERM
REAL_SETSID=$3
GATE="${TEST_ROOT}/parent-group-observed"

# Fixture generation is irrelevant to group ownership; the actual session
# launches a bounded external process through the real setsid executable.
ffmpeg() { :; }
setsid() {
    for _ in {1..200}; do
        if [[ -e ${GATE} ]]; then
            exec "${REAL_SETSID}" "$@"
        fi
        sleep 0.01
    done
    exit 71
}
ps() {
    # Publish the first real PGID observation before allowing setsid to run.
    command ps "$@" || return
    : >"${GATE}"
}
qualify_ffmpeg_cancellation
printf 'qualified safely\n'
'''
with tempfile.TemporaryDirectory(prefix="ffmpeg-group-regression-") as directory:
    root = pathlib.Path(directory)
    functions = root / "functions.sh"
    functions.write_text(source[:-len(entrypoint)], encoding="utf-8")
    mock_bin = root / "bin"
    mock_bin.mkdir()
    mock_ffmpeg = mock_bin / "ffmpeg"
    mock_ffmpeg.write_text("#!/bin/sh\nexec sleep 2\n", encoding="ascii")
    mock_ffmpeg.chmod(0o700)
    case = root / "case"
    case.mkdir()
    environment = dict(os.environ, PATH=f"{mock_bin}:{os.environ['PATH']}")
    process = subprocess.Popen(
        ["bash", "-c", fixture, "bash", str(functions), str(case),
         shutil.which("setsid")],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=10)
        if process.returncode != 0 or stdout != b"qualified safely\n":
            raise AssertionError(
                f"qualification signaled its caller group: {process.returncode}; "
                + stderr.decode(errors="replace")
            )
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
PY_FFMPEG_GROUP
}

test_recycled_child_identity_guard() {
    local runner_library="${SCRIPT_DIR}/lib/test-runner.sh"
    local sleep_path=''

    sleep_path=$(command -v -- sleep) \
        || fail 'recycled-child guard could not resolve sleep'
    python3 - "${runner_library}" "${sleep_path}" <<'PY_RECYCLED_CHILD'
import os
import signal
import subprocess
import sys

library, sleep_path = sys.argv[1:]
decoy = subprocess.Popen([sleep_path, "30"], start_new_session=True)
fixture = r'''
set -euo pipefail
source "$1"
decoy_pid=$2

# Model a completed child slot whose numeric PID and PGID have since been
# recycled by an unrelated process without the registered identities.
set_decoy_slot() {
    TEST_RUNNER_CHILD_PIDS[0]=${decoy_pid}
    TEST_RUNNER_CHILD_PGIDS[0]=${decoy_pid}
    TEST_RUNNER_CHILD_COMPLETIONS[0]=''
    TEST_RUNNER_CHILD_TOKENS[0]='expected-original-child-token'
    TEST_RUNNER_CHILD_START_TIMES[0]=1
}

set_decoy_slot
status=0
test_runner_wait_any completed_slot 2>/dev/null || status=$?
[[ ${completed_slot} == 0 ]]
((status != 0))
[[ ${#TEST_RUNNER_CHILD_PIDS[@]} == 0 ]]

set_decoy_slot
TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=1

test_runner_terminate_children TERM
[[ ${#TEST_RUNNER_CHILD_PIDS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_PGIDS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_COMPLETIONS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_TOKENS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_START_TIMES[@]} == 0 ]]
'''

try:
    result = subprocess.run(
        ["bash", "-c", fixture, "bash", library, str(decoy.pid)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            "recycled-child fixture failed: "
            + result.stderr.decode(errors="replace")
        )
    if decoy.poll() is not None:
        raise AssertionError(
            "test runner signaled a process that did not match the retained "
            "child identity"
        )
finally:
    if decoy.poll() is None:
        try:
            os.killpg(decoy.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    decoy.wait(timeout=5)
PY_RECYCLED_CHILD
}

test_delayed_child_identity_handshake() {
    local runner_library="${SCRIPT_DIR}/lib/test-runner.sh"

    if ! bash -s -- "${runner_library}" <<'BASH_DELAYED_IDENTITY'; then
set -euo pipefail
source "$1"

# The input is a function definition produced by this trusted shell itself;
# rename only its declaration so the fixture can insert a deterministic delay.
eval "$(
    declare -f test_runner_read_start_time \
        | sed '1s/^test_runner_read_start_time /_test_runner_original_read_start_time /'
)"
test_runner_read_start_time() {
    sleep 0.35
    _test_runner_original_read_start_time "$@"
}

trap 'test_runner_cleanup' EXIT
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
[[ ${TEST_RUNNER_CHILD_START_TIMES[0]:-} =~ ^[1-9][0-9]*$ ]]

shopt -s nullglob
identity_files=("${TEST_RUNNER_LOG_DIR}"/child-*.identity)
shopt -u nullglob
((${#identity_files[@]} == 0))

test_runner_wait_child 0
test_runner_cleanup
trap - EXIT
BASH_DELAYED_IDENTITY
        fail 'runner accepted or leaked a delayed child identity handshake'
    fi
}

test_partial_child_identity_handshake() {
    local runner_library="${SCRIPT_DIR}/lib/test-runner.sh"

    if ! bash -s -- "${runner_library}" <<'BASH_PARTIAL_IDENTITY'; then
set -euo pipefail
source "$1"

# These definitions are emitted by this trusted shell and renamed only at
# their declarations so the fixture can expose the handoff race exactly.
eval "$(
    declare -f test_runner_read_active_child_start_time \
        | sed '1s/^test_runner_read_active_child_start_time /_test_runner_original_read_active_child_start_time /'
)"
eval "$(
    declare -f test_runner_read_child_identity \
        | sed '1s/^test_runner_read_child_identity /_test_runner_original_read_child_identity /'
)"

identity_read_attempts=0
test_runner_read_child_identity() {
    identity_read_attempts=$((identity_read_attempts + 1))
    if ((identity_read_attempts == 1)); then
        return 1
    fi
    _test_runner_original_read_child_identity "$@"
}

test_runner_read_active_child_start_time() {
    sleep 0.2
    _test_runner_original_read_active_child_start_time "$@"
}

_test_runner_launch_child() {
    local child_token=$1
    local identity_file=$2
    local launcher_pid=${BASHPID}
    local launcher_start_time=''
    shift 2

    export YTDLP_ARIA2_TEST_RUNNER_CHILD_TOKEN=${child_token}
    test_runner_read_start_time launcher_start_time "${launcher_pid}" \
        || return 70
    : >"${identity_file}"
    sleep 0.05
    printf '%s %s\n' "${launcher_pid}" "${launcher_start_time}" \
        >"${identity_file}"
}

trap 'test_runner_cleanup' EXIT
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
[[ ${TEST_RUNNER_CHILD_START_TIMES[0]:-} =~ ^[1-9][0-9]*$ ]]
test_runner_wait_child 0
test_runner_cleanup
trap - EXIT
BASH_PARTIAL_IDENTITY
        fail 'runner lost a child identity after observing a partial handoff'
    fi
}

test_pre_identity_stopped_launcher_signal() {
    python3 - "${SCRIPT_DIR}/lib/test-runner.sh" <<'PY_STOPPED_IDENTITY'
import os
import pathlib
import signal
import subprocess
import tempfile
import time

library = pathlib.Path(__import__("sys").argv[1])
fixture = r'''
set -u
source "$1"
marker=$2

_test_runner_launch_child() {
    printf '%s\n' "$BASHPID" >"${marker}"
    kill -STOP -- "$BASHPID"
    return 70
}

trap 'test_runner_handle_signal TERM 143' TERM
TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=2
test_runner_initialize
test_runner_start_child 0 '' bash -c 'exit 0'
exit 99
'''


def running(pid: int, identity_token: str) -> bool:
    try:
        stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text(
            encoding="ascii"
        ).split()
    except OSError:
        return False
    if len(stat_fields) >= 3 and stat_fields[2] == "Z":
        return False
    expected = f"YTDLP_ARIA2_STOPPED_IDENTITY_TOKEN={identity_token}".encode()
    try:
        environment = pathlib.Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    return expected in environment.split(b"\0")


with tempfile.TemporaryDirectory(prefix="runner-stopped-identity-") as temp_dir:
    root = pathlib.Path(temp_dir)
    marker = root / "launcher.pid"
    identity_token = str(root / "identity")
    environment = os.environ.copy()
    environment["YTDLP_ARIA2_STOPPED_IDENTITY_TOKEN"] = identity_token
    runner = subprocess.Popen(
        ["bash", "-c", fixture, "bash", str(library), str(marker)],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    child_pid = 0
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if marker.exists() and marker.stat().st_size:
                child_pid = int(marker.read_text(encoding="ascii").strip())
                break
            if runner.poll() is not None:
                raise AssertionError(
                    "runner exited before the stopped launcher published its PID"
                )
            time.sleep(0.01)
        if not child_pid:
            raise AssertionError("stopped launcher did not publish its PID")

        runner.send_signal(signal.SIGTERM)
        _, stderr = runner.communicate(timeout=5)
        if runner.returncode != 143:
            raise AssertionError(
                f"runner returned {runner.returncode}, expected 143: "
                + stderr.decode(errors="replace")
            )
        if running(child_pid, identity_token):
            raise AssertionError(
                "runner left a launcher stopped before identity publication"
            )
    finally:
        if runner.poll() is None:
            runner.kill()
            runner.wait(timeout=5)
        if child_pid and running(child_pid, identity_token):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
PY_STOPPED_IDENTITY
}

test_signal_resistant_sanitized_child() {
    local runner_library="${SCRIPT_DIR}/lib/test-runner.sh"
    local sleep_path=''

    sleep_path=$(command -v -- sleep) \
        || fail 'signal-resistant fixture could not resolve sleep'
    python3 - "${runner_library}" "${sleep_path}" <<'PY_SIGNAL_RESISTANT'
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

library, sleep_path = sys.argv[1:]
fixture = r'''
set -euo pipefail
source "$1"
marker=$2
sleep_path=$3

trap 'test_runner_cleanup' EXIT
test_runner_initialize
TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=2
test_runner_start_child 0 '' \
    env -u YTDLP_ARIA2_TEST_RUNNER_CHILD_TOKEN \
    bash -c \
    'trap "" HUP INT TERM; printf "%s\n" "$BASHPID" >"$1"; exec "$2" 30' \
    bash "${marker}" "${sleep_path}"

[[ ${TEST_RUNNER_CHILD_START_TIMES[0]:-} =~ ^[1-9][0-9]*$ ]]
for _ in {1..200}; do
    [[ -s ${marker} ]] && break
    sleep 0.001
done
[[ -s ${marker} ]]

test_runner_terminate_children TERM
[[ ${#TEST_RUNNER_CHILD_PIDS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_PGIDS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_COMPLETIONS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_TOKENS[@]} == 0 ]]
[[ ${#TEST_RUNNER_CHILD_START_TIMES[@]} == 0 ]]
test_runner_cleanup
trap - EXIT
'''


def running(pid: int, identity_token: str) -> bool:
    stat_path = pathlib.Path(f"/proc/{pid}/stat")
    try:
        stat_fields = stat_path.read_text(encoding="ascii").split()
    except OSError:
        return False
    if len(stat_fields) >= 3 and stat_fields[2] == "Z":
        return False
    expected = f"YTDLP_ARIA2_STUBBORN_FIXTURE_TOKEN={identity_token}".encode()
    try:
        environment = pathlib.Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    return expected in environment.split(b"\0")


with tempfile.TemporaryDirectory(prefix="runner-signal-resistant-") as temp_dir:
    root = pathlib.Path(temp_dir)
    marker = root / "child.pid"
    identity_token = str(root / "identity")
    environment = os.environ.copy()
    environment["YTDLP_ARIA2_STUBBORN_FIXTURE_TOKEN"] = identity_token
    child_pid = 0
    try:
        result = subprocess.run(
            ["bash", "-c", fixture, "bash", library, str(marker), sleep_path],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        if marker.exists():
            child_pid = int(marker.read_text(encoding="ascii").strip())
        if result.returncode != 0:
            raise AssertionError(
                "signal-resistant fixture failed: "
                + result.stderr.decode(errors="replace")
            )
        deadline = time.monotonic() + 2
        while child_pid and running(child_pid, identity_token):
            if time.monotonic() >= deadline:
                raise AssertionError(
                    "test runner lost KILL escalation after the child removed "
                    "its runner token"
                )
            time.sleep(0.02)
    finally:
        if child_pid and running(child_pid, identity_token):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
PY_SIGNAL_RESISTANT
}

test_monitor_runner_session_handoff() {
    python3 -B - "${SCRIPT_DIR}" <<'PY_MONITOR_HANDOFF'
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

scripts = Path(sys.argv[1])
library = scripts / "lib/test-runner.sh"
fatal_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
first_fatal_signal = None


class Interrupted(BaseException):
    def __init__(self, number):
        self.number = number


def interrupted(number, _frame):
    global first_fatal_signal
    if first_fatal_signal is None:
        first_fatal_signal = number
    raise Interrupted(first_fatal_signal)


for fatal_signal in fatal_signals:
    signal.signal(fatal_signal, interrupted)
if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "test subreaper unavailable")


def identity(pid):
    try:
        value = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except FileNotFoundError:
        return None
    fields = value[value.rfind(") ") + 2:].split()
    return (pid, int(fields[19]), fields[0], int(fields[1]),
            int(fields[2]), int(fields[3]))


def still_owned(record):
    current = identity(record[0])
    return current if current and current[:2] == record[:2] else None


def wait_marker(path, process):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size:
            return path.read_text(encoding="ascii").split()
        if process.poll() is not None:
            raise AssertionError(f"monitor runner exited before {path.name}")
        time.sleep(0.005)
    raise AssertionError(f"monitor runner did not publish {path.name}")


def stop(process, records):
    if process is None:
        return
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, fatal_signals)
    try:
        # Retain direct-child identities before interrupting the nested runner.
        # Its private-session children must also be cleaned if its own handler
        # is the behavior broken by a negative control.
        if process.poll() is None:
            try:
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text()
            except FileNotFoundError:
                children = ""
            for child in children.split():
                record = identity(int(child))
                if record and record[3] == process.pid:
                    records.append(record)
            process.terminate()
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        for record in records:
            current = still_owned(record)
            if current and current[2] != "Z":
                try:
                    if current[0] == current[4] == current[5]:
                        os.killpg(current[0], signal.SIGKILL)
                    else:
                        os.kill(current[0], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=3)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                child, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if child == 0:
                time.sleep(0.005)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


mode_observer = r'''
set -euo pipefail
set +m
source() {
    builtin source "$@"
    if [[ $1 == */lib/test-runner.sh ]]; then
        test_runner_initialize() {
            [[ $- == *m* ]] || exit 91
            printf 'monitor active\n'
            exit 0
        }
    fi
}
source "$@"
'''

runner = r'''
set -Eeuo pipefail
set -m
umask 077
source "$1"
test_runner_initialize
trap test_runner_cleanup EXIT
trap 'test_runner_handle_signal HUP 129' HUP
trap 'test_runner_handle_signal INT 130' INT
trap 'test_runner_handle_signal TERM 143' TERM
test_runner_start_child 0 '' python3 "$2" "$3" "$4"
if [[ $4 == long ]]; then
    if test_runner_pid_has_group_identity \
        "${TEST_RUNNER_CHILD_PIDS[0]}" "${TEST_RUNNER_CHILD_PGIDS[0]}" \
        "${TEST_RUNNER_CHILD_TOKENS[0]}" "${TEST_RUNNER_CHILD_START_TIMES[0]}"; then
        printf 'accepted\n' >"$3/group-identity"
    else
        printf 'refused\n' >"$3/group-identity"
    fi
fi
status=0
test_runner_wait_child 0 || status=$?
exit "$status"
'''

fixture_source = '''import os
from pathlib import Path
import sys
import time
root = Path(sys.argv[1])
(root / "fixture").write_text(f"{os.getpid()} {os.getpgrp()} {os.getsid(0)}")
if sys.argv[2] == "long":
    time.sleep(8)
else:
    print("fixed-output", flush=True)
    raise SystemExit(int(sys.argv[2]))
'''

source = library.read_text(encoding="utf-8")
gate_definition = '''
def monitor_handoff_gate(stage):
    from pathlib import Path
    root = Path(os.environ["MONITOR_HANDOFF_ROOT"])
    if os.environ["MONITOR_HANDOFF_STAGE"] != stage:
        return
    (root / "gate").write_text(f"{os.getpid()} {os.getpgrp()} {os.getsid(0)}")
    deadline = time.monotonic() + 5
    while not (root / "release").exists():
        if time.monotonic() >= deadline:
            os._exit(70)
        time.sleep(0.005)

'''
anchor = "previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, managed_signals)\n"
before = "    if os.getpgrp() == os.getpid():\n"
after = "    os.setsid()\n"
for fragment in (anchor, before, after):
    if source.count(fragment) != 1:
        raise AssertionError("supervisor handoff instrumentation anchor changed")
gated_source = source.replace(anchor, anchor + gate_definition)
gated_source = gated_source.replace(before, '    monitor_handoff_gate("before")\n' + before)
gated_source = gated_source.replace(after, '    monitor_handoff_gate("after")\n' + after)

try:
    with tempfile.TemporaryDirectory(prefix="runner-monitor-handoff-") as directory:
        root = Path(directory)
        fixture = root / "fixture.py"
        fixture.write_text(fixture_source, encoding="ascii")
        gated_library = root / "gated-library.sh"
        gated_library.write_text(gated_source, encoding="utf-8")
        # The actual entry points stop before initialization launches children.
        # A present inert ShellCheck command also permits this observation on a
        # host where only the focused runner suite's dependencies are installed.
        mock_bin = root / "bin"
        mock_bin.mkdir()
        mock_shellcheck = mock_bin / "shellcheck"
        mock_shellcheck.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        mock_shellcheck.chmod(0o700)
        environment = dict(os.environ, PATH=f"{mock_bin}:{os.environ['PATH']}")
        for entrypoint, arguments in (
            ("run-all.sh", ["--jobs", "1"]),
            ("repeat-qualification.sh", ["--runs", "1", "--jobs", "1", "--", "true"]),
        ):
            result = subprocess.run(
                ["bash", "-c", mode_observer, "monitor-mode-observer",
                 str(scripts / entrypoint), *arguments],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=5, check=False,
            )
            if result.returncode != 0 or result.stdout != b"monitor active\n" or result.stderr:
                raise AssertionError(f"{entrypoint} did not enable monitor mode before initialization")

        cases = [("0", None), ("7", None)] + [
            (stage, fatal) for stage in ("before", "after") for fatal in fatal_signals
        ]
        for index, (stage, fatal) in enumerate(cases):
            case = root / str(index)
            case.mkdir()
            environment = dict(os.environ, TMPDIR=str(case),
                               YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS="10",
                               MONITOR_HANDOFF_ROOT=str(case), MONITOR_HANDOFF_STAGE=stage)
            process = None
            records = []
            try:
                # Defer fatal handlers across creation and cleanup registration.
                previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, fatal_signals)
                try:
                    process = subprocess.Popen(
                        ["bash", "-c", runner, "monitor-handoff-runner",
                         str(gated_library if fatal else library), str(fixture),
                         str(case), "long" if fatal else stage],
                        env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        start_new_session=True,
                        # This single-threaded controller blocks only its own
                        # registration window, not the nested runner's signals.
                        preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask),
                    )
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                if fatal:
                    pid, pgid, sid = map(int, wait_marker(case / "gate", process))
                    record = identity(pid)
                    if record is None:
                        raise AssertionError("gated supervisor disappeared")
                    records.append(record)
                    if stage == "before" and not (pid == pgid and pid != sid):
                        raise AssertionError("monitor launcher did not precede its dedicated session")
                    if stage == "after" and not (pid != pgid and pgid == sid == process.pid):
                        raise AssertionError("monitor launcher did not rejoin its parent group")
                    if wait_marker(case / "group-identity", process) != ["refused"]:
                        raise AssertionError("pre-session process group authenticated as a private session")
                    process.send_signal(fatal)
                    deadline = time.monotonic() + 0.8
                    while time.monotonic() < deadline:
                        status = Path(f"/proc/{pid}/status").read_text(encoding="ascii")
                        pending = [line.split()[1] for line in status.splitlines()
                                   if line.startswith(("SigPnd:", "ShdPnd:"))]
                        if any(int(mask, 16) & (1 << (fatal - 1)) for mask in pending):
                            break
                        time.sleep(0.005)
                    else:
                        raise AssertionError("first fatal signal did not reach the gated supervisor")
                    (case / "release").touch()
                    expected = 128 + fatal
                else:
                    expected = int(stage)
                stdout, stderr = process.communicate(timeout=4)
                if process.returncode != expected or stderr:
                    raise AssertionError(f"monitor case {index} changed status or emitted stderr")
                if stdout != (b"" if fatal else b"fixed-output\n"):
                    raise AssertionError("monitor mode changed command output")
                if (case / "fixture").exists():
                    command_pid, final_pgid, final_sid = map(
                        int, (case / "fixture").read_text(encoding="ascii").split()
                    )
                    command_record = identity(command_pid)
                    if command_record:
                        records.append(command_record)
                    if final_pgid != final_sid or final_pgid == command_pid:
                        raise AssertionError("command did not run in its supervisor's private session")
                    if fatal and final_pgid != pid:
                        raise AssertionError("session creation replaced the authenticated supervisor PID")
                for record in records:
                    current = still_owned(record)
                    if current and current[2] != "Z":
                        raise AssertionError("monitor cancellation left an original child alive")
            finally:
                (case / "release").touch()
                stop(process, records)
except Interrupted as error:
    raise SystemExit(128 + error.number)

print("Monitor-mode entry points, identity handoff, output and fatal signals passed.")
PY_MONITOR_HANDOFF
}

test_mock_process_scan_contract() {
    python3 -B - "${SCRIPT_DIR}/mock-integration.sh" <<'PY_PROCESS_SCAN'
import ctypes
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
match = re.search(r"^find_test_processes\(\) \{\n.*?^\}\n", source, re.M | re.S)
if match is None:
    raise AssertionError("unable to extract actual mock process scanner")
function = match.group()


def scan(token, implementation=function, prefix=""):
    command = "set -euo pipefail\n" + implementation + prefix + '''
TEST_ROOT=$1
find_test_processes
if ((${#TEST_PROCESS_PIDS[@]})); then
    printf '%s\\n' "${TEST_PROCESS_PIDS[@]}"
fi
'''
    result = subprocess.run(["bash", "-c", command, "scan-fixture", token],
                            capture_output=True, text=True, timeout=10, check=True)
    return set(result.stdout.splitlines())


with tempfile.TemporaryDirectory(prefix="mock-process-scan-") as directory:
    root = Path(directory)
    token = str(root / "needle space é\nend")
    proc = root / "proc"
    proc.mkdir()
    payloads = {
        "9900000101": b"python\0" + os.fsencode(token) + b"\0",
        "9900000102": b"python\0prefix" + os.fsencode(token) + b"suffix\0",
        "9900000103": b"python\0" + os.fsencode(token).replace(b" ", b"\0", 1) + b"\0",
        "9900000104": b"python\0foreign\0",
        "9900000105": b"",
        "9900000106": b"python\0" + os.fsencode(token) + b"\0",
    }
    for pid, payload in payloads.items():
        (proc / pid).mkdir()
        (proc / pid / "cmdline").write_bytes(payload)
    (proc / "9900000107").mkdir()  # A process whose cmdline disappeared.
    (proc / "9900000106/cmdline").chmod(0)
    expected = {"9900000101", "9900000102", "9900000103"}
    if os.access(proc / "9900000106/cmdline", os.R_OK):
        expected.add("9900000106")  # A root qualification may still read mode 000.
    fake_scan = function.replace("/proc/", str(proc) + "/")
    if scan(token, fake_scan) != expected:
        raise AssertionError("mock scanner changed NUL/space/newline or global-token semantics")
    if scan(token + "foreign", fake_scan):
        raise AssertionError("foreign process was selected")

    # Remove cmdline between the readable probe and the builtin read.
    disappearing = '''
set -T
trap 'if [[ ${BASH_COMMAND} == mapfile* ]]; then command rm -f -- "${cmdline_file}"; fi' DEBUG
'''
    if scan(token, fake_scan, disappearing):
        raise AssertionError("disappeared process remained in the scan")

    children = []
    try:
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", token])
        children.append(child)
        foreign = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "foreign"])
        children.append(foreign)
        if scan(token) != {str(child.pid)}:
            raise AssertionError("live witness missing or unrelated process selected")
    finally:
        for process in children:
            process.terminate()
        for process in children:
            process.wait(timeout=5)
    if scan(token):
        raise AssertionError("reaped witness remained in the scan")

    # Adopt the witness after its launcher exits so this regression can reap
    # its own orphan without relying on the host's PID 1.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "unable to enable fixture subreaping")
    orphan = 0
    try:
        launcher = '''import os, time
child = os.fork()
if child:
    print(child, flush=True)
else:
    os.close(1)
    os.close(2)
    time.sleep(60)
'''
        result = subprocess.run([sys.executable, "-c", launcher, token],
                                capture_output=True, text=True, timeout=5, check=True)
        orphan = int(result.stdout)
        if scan(token) != {str(orphan)}:
            raise AssertionError("global scanner lost the witness after its leader exited")
    finally:
        if orphan:
            os.kill(orphan, signal.SIGTERM)
            os.waitpid(orphan, 0)
        libc.prctl(36, 0, 0, 0, 0)
print("Mock process scan: argv boundaries, disappearance, foreign processes and orphan witness passed.")
PY_PROCESS_SCAN
}

test_run_all_manifest_execution() {
    local manifest_root="${TEST_RUNNER_LOG_DIR}/run-all-manifest"
    local mock_bin="${manifest_root}/bin"
    local failure_root="${manifest_root}/ordered-failures"
    local invocation_root=''
    local profile=''
    local jobs=''
    local real_bash=''

    real_bash=$(command -v -- bash) \
        || fail 'run-all manifest test could not resolve Bash'
    mkdir -p -- "${mock_bin}"
    cat >"${mock_bin}/bash" <<'EOF_MANIFEST_BASH'
#!/bin/bash
set -euo pipefail

: "${RUN_ALL_MANIFEST_LOG_DIR:?}"
record=$(mktemp \
    --tmpdir="${RUN_ALL_MANIFEST_LOG_DIR}" \
    'bash.XXXXXXXX.bin')
printf '%s\0' "$@" >"${record}"
if [[ ${RUN_ALL_MANIFEST_FAILURE_MODE:-} == ordered ]]; then
    case " $* " in
        *' ./tests/test-runner-integration.sh '*)
            sleep 0.2
            exit 17
            ;;
        *' ./tests/runtime-manager-integration.sh '*)
            exit 23
            ;;
    esac
fi
EOF_MANIFEST_BASH
    cat >"${mock_bin}/shellcheck" <<'EOF_MANIFEST_SHELLCHECK'
#!/bin/bash
set -euo pipefail

if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'ShellCheck - synthetic manifest fixture' 'version: 0.10.0'
    exit 0
fi
: "${RUN_ALL_MANIFEST_LOG_DIR:?}"
record=$(mktemp \
    --tmpdir="${RUN_ALL_MANIFEST_LOG_DIR}" \
    'shellcheck.XXXXXXXX.bin')
printf '%s\0' "$@" >"${record}"
EOF_MANIFEST_SHELLCHECK
    cat >"${mock_bin}/python3" <<'EOF_MANIFEST_PYTHON'
#!/bin/bash
set -euo pipefail

# Keep the Python session supervisor real; only scheduled suite entry points
# are inert, just like the Bash suite commands above.
if [[ ${1:-} == -B && ${2:-} == ./tests/*-integration.py ]]; then
    : "${RUN_ALL_MANIFEST_LOG_DIR:?}"
    record=$(mktemp --tmpdir="${RUN_ALL_MANIFEST_LOG_DIR}" 'python.XXXXXXXX.bin')
    printf '%s\0' "$@" >"${record}"
    if [[ ${RUN_ALL_MANIFEST_FAILURE_MODE:-} == python-ordered ]]; then
        case $2 in
            ./tests/shfmt-version-handoff-integration.py)
                sleep 0.2
                exit 19
                ;;
            ./tests/release-docs-integration.py) exit 29 ;;
        esac
    fi
    exit 0
fi
exec /usr/bin/python3 "$@"
EOF_MANIFEST_PYTHON
    chmod 0755 -- "${mock_bin}/bash" "${mock_bin}/shellcheck" "${mock_bin}/python3"

    for profile in fast full; do
        for jobs in 1 4; do
            invocation_root="${manifest_root}/${profile}-${jobs}"
            mkdir -p -- "${invocation_root}"
            assert_status 0 "run-all executes the exact ${profile} manifest" \
                env \
                PATH="${mock_bin}:/usr/bin:/bin" \
                RUN_ALL_MANIFEST_LOG_DIR="${invocation_root}" \
                "${real_bash}" "${SCRIPT_DIR}/run-all.sh" \
                "--${profile}" --jobs "${jobs}"

            python3 - \
                "${profile}" "${invocation_root}" -- \
                "${ALL_SHELL_FILES[@]}" <<'PY_MANIFEST'
import collections
import pathlib
import sys

profile = sys.argv[1]
root = pathlib.Path(sys.argv[2])
if sys.argv[3] != "--":
    raise AssertionError("missing shell-inventory separator")
expected_shell_files = sys.argv[4:]

static_bash_commands = [
    ("--", "./scripts/check-shell-format.sh"),
    ("--", "./test-static.sh", "--source-only"),
]
full_suite_commands = [
    ("--", "./tests/mock-integration.sh", "--group", "signals"),
    ("--", "./tests/test-runner-integration.sh"),
    ("--", "./tests/runtime-manager-hardening-integration.sh"),
    ("--", "./tests/mock-integration.sh", "--group", "engine-core"),
    ("--", "./tests/progress-monitor-integration.sh"),
    ("--", "./tests/run-all-signal-integration.sh"),
    ("--", "./tests/runtime-manager-integration.sh"),
    ("--", "./tests/mock-integration.sh", "--group", "engine-hls"),
    ("--", "./tests/mock-integration.sh", "--group", "engine-staging"),
    ("--", "./tests/mock-integration.sh", "--group", "engine-network"),
    ("--", "./tests/mock-integration.sh", "--group", "gui-state"),
    ("--", "./tests/mock-integration.sh", "--group", "gui-progress"),
    ("--", "./tests/mock-integration.sh", "--group", "runtime-compat"),
    ("--", "./tests/mock-integration.sh", "--group", "runtime-validation"),
    ("--", "./tests/private-aria2-plan-integration.sh"),
    ("--", "./tests/aria2-auth-headers-integration.sh"),
    ("--", "./tests/install-fedora-authentication-integration.sh"),
    ("--", "./tests/ffmpeg-progress-integration.sh"),
    ("--", "./tests/installer-integration.sh"),
    ("--", "./tests/package-user-cleanup-integration.sh"),
    ("--", "./tests/packaging-integration.sh"),
]
fast_suite_commands = [
    ("--", "./tests/mock-integration.sh", "--group", "engine-network"),    ("--", "./tests/test-runner-integration.sh"),
    ("--", "./tests/runtime-manager-integration.sh"),
    ("--", "./tests/private-aria2-plan-integration.sh"),
    ("--", "./tests/progress-monitor-integration.sh"),
    ("--", "./tests/ffmpeg-progress-integration.sh"),
    ("--", "./tests/installer-integration.sh"),
    ("--", "./tests/install-fedora-authentication-integration.sh"),
    ("--", "./tests/packaging-integration.sh"),
    ("--", "./tests/package-user-cleanup-integration.sh"),
]


def read_record(path: pathlib.Path) -> tuple[str, ...]:
    payload = path.read_bytes()
    if not payload.endswith(b"\0"):
        raise AssertionError(f"unterminated argv record: {path.name}")
    return tuple(
        field.decode("utf-8", errors="strict")
        for field in payload[:-1].split(b"\0")
    )


actual_bash = collections.Counter(
    read_record(path) for path in root.glob("bash.*.bin")
)
expected_suites = (
    fast_suite_commands if profile == "fast" else full_suite_commands
)
expected_bash = collections.Counter(static_bash_commands + expected_suites)
if actual_bash != expected_bash:
    raise AssertionError(
        f"{profile} Bash manifest mismatch: "
        f"actual={actual_bash!r} expected={expected_bash!r}"
    )

expected_python = collections.Counter(
    ("-B", f"./tests/{name}-integration.py")
    for name in ("shfmt-version-handoff", "release-docs", "push-version",
                 "ci-validation", "source-archive", "shfmt-bootstrap")
)
actual_python = collections.Counter(
    read_record(path) for path in root.glob("python.*.bin")
)
if actual_python != expected_python:
    raise AssertionError(
        f"{profile} Python manifest mismatch: "
        f"actual={actual_python!r} expected={expected_python!r}"
    )

shellcheck_records = [
    read_record(path) for path in root.glob("shellcheck.*.bin")
]
if len(shellcheck_records) != 4:
    raise AssertionError(
        f"expected four ShellCheck inventories, got {len(shellcheck_records)}"
    )
actual_shell_files = []
for record in shellcheck_records:
    if record[:4] != ("-x", "-o", "all", "--"):
        raise AssertionError(f"invalid ShellCheck argv: {record!r}")
    actual_shell_files.extend(record[4:])
if collections.Counter(actual_shell_files) != collections.Counter(
    expected_shell_files
):
    raise AssertionError("ShellCheck inventories omit or duplicate shell files")
if len(actual_shell_files) != len(set(actual_shell_files)):
    raise AssertionError("ShellCheck inventories overlap")
PY_MANIFEST
        done
    done

    mkdir -p -- "${failure_root}"
    assert_status 17 \
        'run-all preserves the first manifest failure after inverse completion' \
        env \
        PATH="${mock_bin}:/usr/bin:/bin" \
        RUN_ALL_MANIFEST_LOG_DIR="${failure_root}" \
        RUN_ALL_MANIFEST_FAILURE_MODE=ordered \
        "${real_bash}" "${SCRIPT_DIR}/run-all.sh" \
        --fast --jobs 4

    assert_status 19 \
        'run-all preserves Python manifest failure order and the static barrier' \
        env \
        PATH="${mock_bin}:/usr/bin:/bin" \
        RUN_ALL_MANIFEST_LOG_DIR="${failure_root}" \
        RUN_ALL_MANIFEST_FAILURE_MODE=python-ordered \
        "${real_bash}" "${SCRIPT_DIR}/run-all.sh" \
        --fast --jobs 4
    assert_text_not_contains "${ASSERT_OUTPUT}" 'Starting: Runtime-manager integration' \
        'failed Python validation prevents the integration phase'
}

test_run_all_doctor_contract() {
    local doctor_mock_bin="${TEST_RUNNER_LOG_DIR}/doctor-bin"
    local offline_shfmt_root="${TEST_RUNNER_LOG_DIR}/offline-shfmt-cache"
    local project_dir=${SCRIPT_DIR%/*}
    local doctor_output=''
    local project_has_git_metadata=false
    local aria2_probe_mode=''
    local command_name=''
    local command_path=''
    local managed_shfmt=''
    local managed_shfmt_version_dir=''
    local managed_shfmt_root=''
    local real_aria2=''
    local real_git=''
    local real_python=''
    local run_all="${SCRIPT_DIR}/run-all.sh"
    local -a doctor_required_commands=(
        aria2c
        awk
        bash
        cat
        chmod
        cmp
        cp
        date
        desktop-file-validate
        diff
        dirname
        env
        find
        flock
        grep
        head
        install
        ln
        mkdir
        mktemp
        mv
        ps
        readlink
        realpath
        rm
        rmdir
        sed
        setsid
        sha256sum
        shellcheck
        sleep
        sort
        stat
        stdbuf
        tail
        timeout
        touch
        tr
        uname
        wc
    )

    real_python=$(command -v -- python3) \
        || fail 'doctor test could not resolve the real python3 interpreter'
    real_aria2=$(command -v -- aria2c) \
        || fail 'doctor test could not resolve the real aria2c executable'
    if [[ -e ${SCRIPT_DIR}/../.git || -L ${SCRIPT_DIR}/../.git ]]; then
        project_has_git_metadata=true
        real_git=$(command -v -- git) \
            || fail 'doctor test could not resolve the real git executable'
    fi
    managed_shfmt=$(bash -- \
        "${SCRIPT_DIR}/../scripts/dev-tools/ensure-shfmt.sh") \
        || fail 'doctor test could not resolve the managed shfmt executable'
    managed_shfmt_version_dir=${managed_shfmt%/*}
    managed_shfmt_root=${managed_shfmt_version_dir%/*}
    [[ ${managed_shfmt_root} == /* ]] \
        || fail 'doctor test resolved a non-absolute shfmt cache root'

    mkdir -p -- "${doctor_mock_bin}"
    cat >"${doctor_mock_bin}/aria2c" <<'EOF_MOCK_ARIA2'
#!/usr/bin/env bash
set -euo pipefail

case ${DOCTOR_MOCK_ARIA2_MODE:-normal} in
    control)
        printf 'aria2 version \001control\n'
        ;;
    flood)
        while :; do
            printf '%4096s' ''
        done
        ;;
    stall)
        sleep 30
        ;;
    normal)
        exec "${DOCTOR_REAL_ARIA2:?}" "$@"
        ;;
    *)
        exit 64
        ;;
esac
EOF_MOCK_ARIA2
    cat >"${doctor_mock_bin}/curl" <<'EOF_MOCK_CURL'
#!/usr/bin/env bash
exit "${DOCTOR_MOCK_CURL_STATUS:-0}"
EOF_MOCK_CURL
    cat >"${doctor_mock_bin}/git" <<'EOF_MOCK_GIT'
#!/usr/bin/env bash
if [[ ${DOCTOR_MOCK_GIT_STATUS:-0} != 0 ]]; then
    exit "${DOCTOR_MOCK_GIT_STATUS}"
fi
if [[ -n ${DOCTOR_EXPECTED_SAFE_DIRECTORY:-} ]]; then
    safe_directory_found=false
    for argument in "$@"; do
        if [[ ${argument} == "safe.directory=${DOCTOR_EXPECTED_SAFE_DIRECTORY}" ]]; then
            safe_directory_found=true
            break
        fi
    done
    [[ ${safe_directory_found} == true ]] || exit 78
fi
exec "${DOCTOR_REAL_GIT:?}" "$@"
EOF_MOCK_GIT
    cat >"${doctor_mock_bin}/python3" <<'EOF_MOCK_PYTHON'
#!/usr/bin/env bash
if [[ $* == *'platform.python_version()'* ]]; then
    printf '3.10.0\n'
    exit "${DOCTOR_MOCK_PYTHON_VERSION_STATUS:-0}"
fi
if [[ $* == *'import socket;'* ]]; then
    exit "${DOCTOR_MOCK_LOOPBACK_STATUS:-0}"
fi
exec "${DOCTOR_REAL_PYTHON:?}" "$@"
EOF_MOCK_PYTHON
    chmod 0755 -- \
        "${doctor_mock_bin}/aria2c" \
        "${doctor_mock_bin}/curl" \
        "${doctor_mock_bin}/git" \
        "${doctor_mock_bin}/python3"
    for command_name in "${doctor_required_commands[@]}"; do
        [[ ! -e ${doctor_mock_bin}/${command_name} ]] || continue
        command_path=$(command -v -- "${command_name}") \
            || fail "doctor test could not resolve required command: ${command_name}"
        ln -s -- "${command_path}" "${doctor_mock_bin}/${command_name}"
    done

    assert_status 0 'doctor emits a ready JSON report' \
        env \
        DOCTOR_EXPECTED_SAFE_DIRECTORY="${project_dir}" \
        DOCTOR_REAL_ARIA2="${real_aria2}" \
        DOCTOR_REAL_GIT="${real_git}" \
        DOCTOR_REAL_PYTHON="${real_python}" \
        PATH="${doctor_mock_bin}:${PATH}" \
        SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
        "${run_all}" --doctor --json
    doctor_output=${ASSERT_OUTPUT}
    if ! python3 - "${doctor_output}" <<'PY_READY_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["schema_version"] == 1
assert report["ready"] is True
assert report["required"]["failed"] == 0
assert checks["python-version"]["status"] == "pass"
assert checks["loopback-bind"]["status"] == "pass"
assert checks["external-https"]["status"] == "pass"
assert checks["shfmt-cache"]["status"] == "pass"
assert checks["shfmt-ready"]["status"] == "pass"
assert checks["repository-state"]["status"] == "pass"
PY_READY_DOCTOR
        fail 'doctor ready report is invalid or incomplete'
    fi

    assert_status 0 'doctor keeps external HTTPS optional' \
        env \
        DOCTOR_MOCK_CURL_STATUS=1 \
        DOCTOR_REAL_ARIA2="${real_aria2}" \
        DOCTOR_REAL_GIT="${real_git}" \
        DOCTOR_REAL_PYTHON="${real_python}" \
        PATH="${doctor_mock_bin}:${PATH}" \
        SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
        "${run_all}" --doctor --json
    doctor_output=${ASSERT_OUTPUT}
    if ! python3 - "${doctor_output}" <<'PY_OFFLINE_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is True
missing_checks = [
    item for item in report["checks"]
    if item["level"] == "optional" and item["status"] == "missing"
]
assert report["optional"]["missing"] == len(missing_checks)
assert report["optional"]["missing"] >= 1
assert checks["external-https"]["status"] == "missing"
PY_OFFLINE_DOCTOR
        fail 'doctor optional-network report is invalid'
    fi

    assert_status 69 'doctor fails closed when loopback binding is blocked' \
        env \
        DOCTOR_MOCK_LOOPBACK_STATUS=1 \
        DOCTOR_REAL_ARIA2="${real_aria2}" \
        DOCTOR_REAL_GIT="${real_git}" \
        DOCTOR_REAL_PYTHON="${real_python}" \
        PATH="${doctor_mock_bin}:${PATH}" \
        SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
        "${run_all}" --doctor --json
    doctor_output=${ASSERT_OUTPUT}
    if ! python3 - "${doctor_output}" <<'PY_BLOCKED_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is False
assert report["required"]["failed"] == 1
assert checks["loopback-bind"]["status"] == "fail"
PY_BLOCKED_DOCTOR
        fail 'doctor blocked-loopback report is invalid'
    fi

    assert_status 69 'doctor rejects an unusable shfmt cache target' \
        env \
        DOCTOR_REAL_ARIA2="${real_aria2}" \
        DOCTOR_REAL_GIT="${real_git}" \
        DOCTOR_REAL_PYTHON="${real_python}" \
        PATH="${doctor_mock_bin}:${PATH}" \
        SHFMT_TOOL_ROOT=/dev/null \
        "${run_all}" --doctor --json
    doctor_output=${ASSERT_OUTPUT}
    if ! python3 - "${doctor_output}" <<'PY_UNUSABLE_SHFMT_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is False
assert checks["shfmt-cache"]["status"] == "unavailable"
assert checks["shfmt-ready"]["status"] == "fail"
PY_UNUSABLE_SHFMT_DOCTOR
        fail 'doctor unusable-shfmt report is invalid'
    fi

    [[ ! -e ${offline_shfmt_root} ]] \
        || fail 'doctor offline shfmt fixture unexpectedly exists before diagnosis'
    assert_status 69 'doctor requires HTTPS when verified shfmt is absent' \
        env \
        DOCTOR_MOCK_CURL_STATUS=1 \
        DOCTOR_REAL_ARIA2="${real_aria2}" \
        DOCTOR_REAL_GIT="${real_git}" \
        DOCTOR_REAL_PYTHON="${real_python}" \
        PATH="${doctor_mock_bin}:${PATH}" \
        SHFMT_TOOL_ROOT="${offline_shfmt_root}" \
        "${run_all}" --doctor --json
    doctor_output=${ASSERT_OUTPUT}
    if ! python3 - "${doctor_output}" <<'PY_OFFLINE_SHFMT_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is False
assert checks["external-https"]["status"] == "missing"
assert checks["shfmt-ready"]["status"] == "fail"
PY_OFFLINE_SHFMT_DOCTOR
        fail 'doctor offline-shfmt report is invalid'
    fi
    [[ ! -e ${offline_shfmt_root} ]] \
        || fail 'doctor populated the managed shfmt cache during diagnosis'

    if [[ ${project_has_git_metadata} == true ]]; then
        assert_status 69 'doctor requires usable Git inside a Git checkout' \
            env \
            DOCTOR_MOCK_GIT_STATUS=127 \
            DOCTOR_REAL_ARIA2="${real_aria2}" \
            DOCTOR_REAL_GIT="${real_git}" \
            DOCTOR_REAL_PYTHON="${real_python}" \
            PATH="${doctor_mock_bin}:${PATH}" \
            SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
            "${run_all}" --doctor --json
        doctor_output=${ASSERT_OUTPUT}
        if ! python3 - "${doctor_output}" <<'PY_UNUSABLE_GIT_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is False
assert checks["repository-state"]["level"] == "required"
assert checks["repository-state"]["status"] == "fail"
PY_UNUSABLE_GIT_DOCTOR
            fail 'doctor unusable-Git report is invalid'
        fi
    else
        assert_status 0 'doctor does not require Git in a source archive' \
            env \
            DOCTOR_MOCK_GIT_STATUS=127 \
            DOCTOR_REAL_ARIA2="${real_aria2}" \
            DOCTOR_REAL_GIT="${real_git}" \
            DOCTOR_REAL_PYTHON="${real_python}" \
            PATH="${doctor_mock_bin}:${PATH}" \
            SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
            "${run_all}" --doctor --json
        doctor_output=${ASSERT_OUTPUT}
        if ! python3 - "${doctor_output}" <<'PY_ARCHIVE_GIT_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is True
assert checks["repository-state"]["level"] == "info"
assert checks["repository-state"]["status"] == "pass"
assert "source-archive" in checks["repository-state"]["detail"]
PY_ARCHIVE_GIT_DOCTOR
            fail 'doctor source-archive Git report is invalid'
        fi
    fi

    assert_status 0 'doctor JSON escapes non-standard C0 control characters' \
        env \
        DOCTOR_MOCK_ARIA2_MODE=control \
        DOCTOR_REAL_ARIA2="${real_aria2}" \
        DOCTOR_REAL_GIT="${real_git}" \
        DOCTOR_REAL_PYTHON="${real_python}" \
        PATH="${doctor_mock_bin}:${PATH}" \
        SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
        "${run_all}" --doctor --json
    doctor_output=${ASSERT_OUTPUT}
    if ! python3 - "${doctor_output}" <<'PY_CONTROL_JSON_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert checks["version:aria2c"]["detail"] == "aria2 version \x01control"
PY_CONTROL_JSON_DOCTOR
        fail 'doctor C0-control JSON report is invalid'
    fi

    for aria2_probe_mode in flood stall; do
        assert_status 0 "doctor bounds ${aria2_probe_mode} version output" \
            timeout --signal=TERM --kill-after=1s 8s \
            env \
            DOCTOR_MOCK_ARIA2_MODE="${aria2_probe_mode}" \
            DOCTOR_REAL_ARIA2="${real_aria2}" \
            DOCTOR_REAL_GIT="${real_git}" \
            DOCTOR_REAL_PYTHON="${real_python}" \
            PATH="${doctor_mock_bin}:${PATH}" \
            SHFMT_TOOL_ROOT="${managed_shfmt_root}" \
            "${run_all}" --doctor --json
        doctor_output=${ASSERT_OUTPUT}
        if ! python3 - "${doctor_output}" <<'PY_BOUNDED_VERSION_DOCTOR'; then
import json
import sys

report = json.loads(sys.argv[1])
checks = {item["id"]: item for item in report["checks"]}
assert report["ready"] is True
assert checks["version:aria2c"]["status"] == "unavailable"
PY_BOUNDED_VERSION_DOCTOR
            fail "doctor ${aria2_probe_mode} version report is invalid"
        fi
    done
}

main() {
    local duration=''
    local first_log
    local second_log
    local first_completion
    local second_completion
    local first_end_ms=''
    local second_end_ms=''
    local completed_slot=''
    local failure_log
    local failure_completion
    local status=0

    for command_name in bash cat chmod env ln mkdir mktemp ps python3 rm sed setsid sleep timeout tr; do
        require_test_command "${command_name}"
    done

    trap cleanup EXIT
    trap 'return 129' HUP
    trap 'return 130' INT
    trap 'return 143' TERM
    test_runner_initialize

    test_runner_format_duration 1234 duration
    assert_equals '1.234s' "${duration}" 'millisecond duration formatting'

    # A signal delivered in the launch/registration critical section must be
    # retained for replay instead of running cleanup against incomplete arrays.
    TEST_RUNNER_STARTING_CHILD=true
    test_runner_handle_signal TERM 143
    assert_equals 'TERM' "${TEST_RUNNER_DEFERRED_SIGNAL}" \
        'startup signal is deferred until child registration'
    assert_equals '143' "${TEST_RUNNER_DEFERRED_STATUS}" \
        'deferred startup signal preserves its exit status'
    test_runner_handle_signal INT 130
    assert_equals 'TERM' "${TEST_RUNNER_DEFERRED_SIGNAL}" \
        'first startup signal remains authoritative'
    TEST_RUNNER_STARTING_CHILD=false
    test_runner_handle_signal INT 130
    assert_equals 'TERM' "${TEST_RUNNER_DEFERRED_SIGNAL}" \
        'first deferred signal remains authoritative after registration'
    assert_equals '143' "${TEST_RUNNER_DEFERRED_STATUS}" \
        'later signal cannot replace deferred exit status'
    TEST_RUNNER_DEFERRED_SIGNAL=''
    TEST_RUNNER_DEFERRED_STATUS=''

    failure_log="${TEST_RUNNER_LOG_DIR}/failure.log"
    test_runner_start_child 0 "${failure_log}" bash -c \
        'printf "%s\n" expected-failure; exit 17'
    status=0
    # The synthetic failure is the value under test.
    # shellcheck disable=SC2310
    test_runner_wait_child 0 || status=$?
    assert_equals '17' "${status}" 'child status preservation'
    assert_file_has_line "${failure_log}" 'expected-failure' \
        'failed child buffered output'

    first_log="${TEST_RUNNER_LOG_DIR}/first.log"
    second_log="${TEST_RUNNER_LOG_DIR}/second.log"
    first_completion="${TEST_RUNNER_LOG_DIR}/first.completed"
    second_completion="${TEST_RUNNER_LOG_DIR}/second.completed"
    test_runner_start_timed_child \
        0 "${first_log}" "${first_completion}" bash -c \
        'sleep 0.2; printf "%s\n" first'
    test_runner_start_timed_child \
        1 "${second_log}" "${second_completion}" bash -c \
        'printf "%s\n" second'
    test_runner_wait_any completed_slot
    assert_equals '1' "${completed_slot}" \
        'wait-any returns the first completed child slot'
    test_runner_wait_any completed_slot
    assert_equals '0' "${completed_slot}" \
        'wait-any returns the remaining child slot'

    test_runner_read_completion "${first_completion}" first_end_ms
    test_runner_read_completion "${second_completion}" second_end_ms
    ((second_end_ms < first_end_ms)) \
        || fail 'parallel child completion order was not recorded accurately'

    assert_file_has_line "${first_log}" first 'first concurrent child output'
    assert_file_has_line "${second_log}" second 'second concurrent child output'

    failure_completion="${TEST_RUNNER_LOG_DIR}/timed-failure.completed"
    test_runner_start_timed_child \
        2 "${failure_log}" "${failure_completion}" bash -c 'exit 23'
    status=0
    # The synthetic wait-any failure is the value under test.
    # shellcheck disable=SC2310
    test_runner_wait_any completed_slot || status=$?
    assert_equals '2' "${completed_slot}" \
        'wait-any releases a failed child slot'
    assert_equals '23' "${status}" \
        'wait-any preserves a failed child status'

    assert_equals '0' "${#TEST_RUNNER_CHILD_PIDS[@]}" \
        'all concurrent child slots are released'
    assert_equals '0' "${#TEST_RUNNER_CHILD_PGIDS[@]}" \
        'all concurrent process-group slots are released'
    assert_equals '0' "${#TEST_RUNNER_CHILD_COMPLETIONS[@]}" \
        'all concurrent completion slots are released'
    assert_equals '0' "${#TEST_RUNNER_CHILD_TOKENS[@]}" \
        'all concurrent child-token slots are released'
    assert_equals '0' "${#TEST_RUNNER_CHILD_START_TIMES[@]}" \
        'all concurrent child start-time slots are released'

    test_startup_signal_registration_stress
    test_startup_signal_final_transition
    test_parallel_repeat_runner
    test_ffmpeg_cancellation_group_registration
    test_recycled_child_identity_guard
    test_delayed_child_identity_handshake
    test_partial_child_identity_handshake
    test_pre_identity_stopped_launcher_signal
    test_signal_resistant_sanitized_child
    test_monitor_runner_session_handoff
    test_mock_process_scan_contract
    test_run_all_manifest_execution
    test_run_all_doctor_contract

    printf 'Test-runner integration passed.\n'
}

main "$@"
