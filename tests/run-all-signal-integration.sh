#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/run-all-signal-integration.sh
# Purpose     : Verify run-all interruption terminates complete child process groups.
# ==============================================================================

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR PROJECT_DIR
TEST_ROOT=''
REAL_BASH=$(command -v bash)
REAL_SLEEP=$(command -v sleep)
readonly REAL_BASH REAL_SLEEP

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${TEST_ROOT} ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
}

main() {
    local mock_bin

    for command_name in bash chmod mktemp python3 rm sleep; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required test command is absent: %s\n' \
                "${command_name}" >&2
            return 127
        }
    done

    TEST_ROOT=$(mktemp -d)
    trap cleanup EXIT
    trap 'return 129' HUP
    trap 'return 130' INT
    trap 'return 143' TERM

    mock_bin="${TEST_ROOT}/bin"
    mkdir -p -- "${mock_bin}"

    cat >"${mock_bin}/shellcheck" <<'EOF_SHELLCHECK'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'ShellCheck - synthetic run-all signal fixture'
fi
exit 0
EOF_SHELLCHECK
    chmod 0755 -- "${mock_bin}/shellcheck"

    cat >"${mock_bin}/bash" <<'EOF_BASH_MOCK'
#!/bin/bash
set -Eeuo pipefail
: "${REAL_BASH:?}"
: "${REAL_SLEEP:?}"

if [[ ${MOCK_IGNORE_SIGNALS:-0} == 1 ]]; then
    trap '' HUP INT TERM
fi

if [[ " $* " == *' ./tests/runtime-manager-integration.sh '* ]]; then
    : "${MOCK_IMMEDIATE_MARKER:?}"
    : "${MOCK_DESCENDANT_MARKER:?}"
    printf '%s\n' "$$" >"${MOCK_IMMEDIATE_MARKER}"
    "${REAL_BASH}" -c '
        marker=$1
        sleep_bin=$2
        ignore_signals=$3
        if [[ ${ignore_signals} == 1 ]]; then
            trap "" HUP INT TERM
        fi
        printf "%s\n" "$$" >"${marker}"
        exec "${sleep_bin}" 60
    ' bash         "${MOCK_DESCENDANT_MARKER}"         "${REAL_SLEEP}"         "${MOCK_IGNORE_SIGNALS:-0}" &
    wait "$!"
fi

exit 0
EOF_BASH_MOCK
    chmod 0755 -- "${mock_bin}/bash"

    env \
        REAL_BASH="${REAL_BASH}" \
        REAL_SLEEP="${REAL_SLEEP}" \
        PROJECT_DIR="${PROJECT_DIR}" \
        TEST_ROOT="${TEST_ROOT}" \
        MOCK_BIN="${mock_bin}" \
        python3 <<'PY_CONTROLLER'
import os
import pathlib
import signal
import subprocess
import time

project_dir = pathlib.Path(os.environ["PROJECT_DIR"])
test_root = pathlib.Path(os.environ["TEST_ROOT"])
mock_bin = pathlib.Path(os.environ["MOCK_BIN"])
real_bash = os.environ["REAL_BASH"]
real_sleep = os.environ["REAL_SLEEP"]


def running(pid: int, identity_token: str) -> bool:
    stat_path = pathlib.Path(f"/proc/{pid}/stat")
    try:
        fields = stat_path.read_text(encoding="ascii").split()
    except FileNotFoundError:
        return False
    if len(fields) >= 3 and fields[2] == "Z":
        return False
    expected = f"YTDLP_ARIA2_RUN_ALL_SIGNAL_TOKEN={identity_token}".encode()
    try:
        environment = pathlib.Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    return expected in environment.split(b"\0")


def wait_marker(path: pathlib.Path, runner: subprocess.Popen[bytes]) -> int:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size:
            return int(path.read_text(encoding="ascii").strip())
        if runner.poll() is not None:
            raise AssertionError(
                f"run-all exited before marker {path.name}: {runner.returncode}"
            )
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for marker {path}")


def wait_gone(pid: int, identity_token: str) -> bool:
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if not running(pid, identity_token):
            return True
        time.sleep(0.05)
    return not running(pid, identity_token)


def wait_signal_guard(runner: subprocess.Popen[bytes]) -> None:
    """Wait until run-all has made its fatal-signal cleanup non-reentrant."""
    required_mask = sum(
        1 << (signal_number - 1)
        for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    )
    status_path = pathlib.Path(f"/proc/{runner.pid}/status")
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if runner.poll() is not None:
            raise AssertionError(
                f"run-all exited before arming its signal guard: {runner.returncode}"
            )
        try:
            status_lines = status_path.read_text(encoding="ascii").splitlines()
        except FileNotFoundError:
            time.sleep(0.01)
            continue
        ignored_line = next(
            (line for line in status_lines if line.startswith("SigIgn:")), ""
        )
        if ignored_line:
            ignored_mask = int(ignored_line.split()[1], 16)
            if ignored_mask & required_mask == required_mask:
                return
        time.sleep(0.01)
    raise AssertionError("run-all did not arm its fatal-signal guard in time")


def terminate_if_needed(pid: int, identity_token: str) -> None:
    if not running(pid, identity_token):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


for name, sig, expected in (
    ("hup", signal.SIGHUP, 129),
    ("int", signal.SIGINT, 130),
    ("term", signal.SIGTERM, 143),
):
    immediate_marker = test_root / f"{name}-immediate.pid"
    descendant_marker = test_root / f"{name}-descendant.pid"
    identity_token = str(test_root / f"{name}-identity")
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{mock_bin}:/usr/bin:/bin",
            "REAL_BASH": real_bash,
            "REAL_SLEEP": real_sleep,
            # The production runner retains its five-second grace period. This
            # integration needs only enough time to observe signal delivery;
            # one second still exercises the deliberate KILL escalation.
            "YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS": "10",
            "MOCK_IMMEDIATE_MARKER": str(immediate_marker),
            "MOCK_DESCENDANT_MARKER": str(descendant_marker),
            "YTDLP_ARIA2_RUN_ALL_SIGNAL_TOKEN": identity_token,
        }
    )

    runner = subprocess.Popen(
        [real_bash, str(project_dir / "tests/run-all.sh"), "--jobs", "4"],
        cwd=project_dir,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    immediate_pid = 0
    descendant_pid = 0
    try:
        immediate_pid = wait_marker(immediate_marker, runner)
        descendant_pid = wait_marker(descendant_marker, runner)
        os.kill(runner.pid, sig)
        try:
            return_code = runner.wait(timeout=10)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f"run-all did not terminate for {name}") from exc

        stderr = (runner.stderr.read() if runner.stderr else b"").decode(
            "utf-8", errors="replace"
        )
        if return_code != expected:
            raise AssertionError(
                f"run-all {name} returned {return_code}, expected {expected}: {stderr}"
            )
        if not wait_gone(immediate_pid, identity_token):
            raise AssertionError(
                f"run-all {name} left immediate suite process {immediate_pid}"
            )
        if not wait_gone(descendant_pid, identity_token):
            raise AssertionError(
                f"run-all {name} left descendant process {descendant_pid}"
            )
    finally:
        if runner.poll() is None:
            runner.kill()
            runner.wait(timeout=5)
        if immediate_pid:
            terminate_if_needed(immediate_pid, identity_token)
        if descendant_pid:
            terminate_if_needed(descendant_pid, identity_token)

# A second fatal signal during the grace period must not interrupt cleanup.
# The synthetic child and descendant ignore TERM/INT so run-all must reach its
# KILL escalation after the second signal arrives.
immediate_marker = test_root / "reentrant-immediate.pid"
descendant_marker = test_root / "reentrant-descendant.pid"
identity_token = str(test_root / "reentrant-identity")
env = os.environ.copy()
env.update(
    {
        "PATH": f"{mock_bin}:/usr/bin:/bin",
        "REAL_BASH": real_bash,
        "REAL_SLEEP": real_sleep,
        "YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS": "10",
        "MOCK_IMMEDIATE_MARKER": str(immediate_marker),
        "MOCK_DESCENDANT_MARKER": str(descendant_marker),
        "MOCK_IGNORE_SIGNALS": "1",
        "YTDLP_ARIA2_RUN_ALL_SIGNAL_TOKEN": identity_token,
    }
)

runner = subprocess.Popen(
    [real_bash, str(project_dir / "tests/run-all.sh"), "--jobs", "4"],
    cwd=project_dir,
    env=env,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
)
immediate_pid = 0
descendant_pid = 0
try:
    immediate_pid = wait_marker(immediate_marker, runner)
    descendant_pid = wait_marker(descendant_marker, runner)
    os.kill(runner.pid, signal.SIGINT)
    # Signal emission order is not proof of Bash trap-dispatch order under
    # load. Observe the non-reentrant guard installed by the first handler,
    # then deliver the second signal during the bounded cleanup grace period.
    wait_signal_guard(runner)
    os.kill(runner.pid, signal.SIGTERM)
    try:
        return_code = runner.wait(timeout=10)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(
            "run-all did not finish cleanup after repeated signals"
        ) from exc

    stderr = (runner.stderr.read() if runner.stderr else b"").decode(
        "utf-8", errors="replace"
    )
    if return_code != 130:
        raise AssertionError(
            f"run-all repeated-signal cleanup returned {return_code}, "
            f"expected 130: {stderr}"
        )
    if not wait_gone(immediate_pid, identity_token):
        raise AssertionError(
            f"run-all repeated-signal cleanup left immediate process "
            f"{immediate_pid}"
        )
    if not wait_gone(descendant_pid, identity_token):
        raise AssertionError(
            f"run-all repeated-signal cleanup left descendant "
            f"{descendant_pid}"
        )
finally:
    if runner.poll() is None:
        runner.kill()
        runner.wait(timeout=5)
    if immediate_pid:
        terminate_if_needed(immediate_pid, identity_token)
    if descendant_pid:
        terminate_if_needed(descendant_pid, identity_token)

# Generic os.execvp OSError handling is defensive hardening. Do not qualify it with an ENOEXEC text fixture: POSIX execvp falls back to a shell interpreter for that case.

print("run-all signal/descendant integration passed.")
PY_CONTROLLER
}

main "$@"
