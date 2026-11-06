# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/lib/run-all-hup-observer.py.

Observe the Python-HUP runner fixture through bounded private source copies.
No production or shared-runner hooks are installed by this test helper.
"""

import fcntl
import json
import os
from pathlib import Path
import re
import select
import struct
import sys
import termios
import time


TRACE_HELPER = r'''
_RUN_ALL_HUP_TRACE_NORMAL=0
_RUN_ALL_HUP_TRACE_CRITICAL=0

# This fixture-only observer uses builtins: it must not replace $! or spawn a
# foreground child inside the runner's registration/signal critical sections.
_run_all_hup_trace() {
    local event=${1:-unavailable}
    local signal_name=${2:-none}
    local target=${3:-0}
    local observed_status=${4:-0}
    local uptime=''
    local unused=''
    local starting=${TEST_RUNNER_STARTING_CHILD:-false}
    local deferred=${TEST_RUNNER_DEFERRED_SIGNAL:-none}

    case ${event} in
        child | startup | startup_closed | wait | waited | poll)
            ((_RUN_ALL_HUP_TRACE_NORMAL <= 64)) || return 0
            ((_RUN_ALL_HUP_TRACE_NORMAL < 64)) || event=normal_limit
            _RUN_ALL_HUP_TRACE_NORMAL=$((_RUN_ALL_HUP_TRACE_NORMAL + 1))
            ;;
        trap | deferred | guard | transmit | cleanup)
            ((_RUN_ALL_HUP_TRACE_CRITICAL <= 16)) || return 0
            ((_RUN_ALL_HUP_TRACE_CRITICAL < 16)) || event=critical_limit
            _RUN_ALL_HUP_TRACE_CRITICAL=$((_RUN_ALL_HUP_TRACE_CRITICAL + 1))
            ;;
        *) return 0 ;;
    esac
    case ${signal_name} in none | HUP | INT | TERM | KILL) ;; *) return 0 ;; esac
    case ${deferred} in none | HUP | INT | TERM) ;; *) return 0 ;; esac
    [[ ${starting} == true || ${starting} == false ]] || return 0
    [[ ${target} =~ ^-?[0-9]{1,10}$ ]] || return 0
    [[ ${observed_status} =~ ^[0-9]{1,3}$ ]] || return 0
    ((10#${observed_status} <= 255)) || return 0
    if ! { IFS=' ' read -r uptime unused </proc/uptime; } 2>/dev/null; then
        event=clock_unavailable
        uptime=0.00
    fi
    if [[ ! ${uptime} =~ ^[0-9]{1,12}\.[0-9]{2}$ ]]; then
        event=clock_unavailable
        uptime=0.00
    fi
    # The parent creates this regular file inside its owner-only fixture root.
    # An unavailable observer is reported by the controller, never as raw text.
    { printf '%s %s %s %s %s %s %s %s\n' "${event}" "${uptime}" "${BASHPID}" \
        "${starting}" "${deferred}" "${signal_name}" "${target}" "${observed_status}" \
        >>"${RUN_ALL_HUP_TRACE_FILE}"; } 2>/dev/null || true
    return 0
}
'''

INSERTIONS = (
    ("    child_pid=$!\n", "    child_pid=$!\n    _run_all_hup_trace child none \"${child_pid}\"\n"),
    ("test_runner_finish_start_transition() {\n", "test_runner_finish_start_transition() {\n    _run_all_hup_trace startup\n"),
    ("        TEST_RUNNER_STARTING_CHILD=false\n        TEST_RUNNER_DEFERRED_SIGNAL=''",
     "        TEST_RUNNER_STARTING_CHILD=false\n        _run_all_hup_trace startup_closed\n        TEST_RUNNER_DEFERRED_SIGNAL=''"),
    ("        TEST_RUNNER_STARTING_CHILD=false\n        # A trap may have run",
     "        TEST_RUNNER_STARTING_CHILD=false\n        _run_all_hup_trace startup_closed\n        # A trap may have run"),
    ("test_runner_wait_any() {\n", "test_runner_wait_any() {\n    _run_all_hup_trace poll\n"),
    ('    wait "${pid}" || status=$?\n',
     '    _run_all_hup_trace wait none "${pid}"\n    wait "${pid}" || status=$?\n    _run_all_hup_trace waited none "${pid}" "${status}"\n'),
    ("test_runner_handle_signal() {\n", "test_runner_handle_signal() {\n    _run_all_hup_trace trap \"${1:-none}\"\n"),
    ("        TEST_RUNNER_DEFERRED_STATUS=${exit_status}\n", "        TEST_RUNNER_DEFERRED_STATUS=${exit_status}\n        _run_all_hup_trace deferred \"${signal_name}\"\n"),
    ("    trap '' HUP INT TERM\n    test_runner_terminate_children", "    trap '' HUP INT TERM\n    _run_all_hup_trace guard \"${signal_name}\"\n    test_runner_terminate_children"),
    ('    kill "-${signal_name}" -- "${signal_target}" 2>/dev/null || return\n',
     '    _run_all_hup_trace transmit "${signal_name}" "${signal_target}"\n    kill "-${signal_name}" -- "${signal_target}" 2>/dev/null || return\n'),
    ("test_runner_cleanup() {\n", "test_runner_cleanup() {\n    _run_all_hup_trace cleanup\n"),
)
EVENTS = frozenset(("child", "startup", "startup_closed", "wait", "waited", "poll", "trap", "deferred", "guard",
                    "transmit", "cleanup", "normal_limit", "critical_limit", "clock_unavailable"))


def replace_once(source: str, old: str, new: str) -> str:
    """Refuse an evolved source instead of silently instrumenting another site."""
    if source.count(old) != 1:
        raise ValueError("unsupported fixture source")
    return source.replace(old, new, 1)


def read_bounded(path: Path, limit: int) -> bytes:
    with path.open("rb") as handle:
        value = handle.read(limit + 1)
    if len(value) > limit:
        raise ValueError("observation limit")
    return value


def process_identity(pid: int) -> dict:
    fields = read_bounded(Path(f"/proc/{pid}/stat"), 4096).decode("ascii").rsplit(") ", 1)[1].split()
    if (len(fields) < 20 or not re.fullmatch(r"[A-Za-z]", fields[0])
            or not all(re.fullmatch(r"[0-9]{1,20}", fields[index]) for index in (1, 2, 3, 19))):
        raise ValueError("invalid identity")
    return dict(pid=pid, state=fields[0], ppid=int(fields[1]), pgid=int(fields[2]),
                sid=int(fields[3]), starttime=int(fields[19]))


def process_state(pid: int) -> dict:
    """Recheck identity around metadata; observation never grants signal authority."""
    result = {"pid": pid}
    try:
        result = process_identity(pid)
        status = read_bounded(Path(f"/proc/{pid}/status"), 16384).decode("ascii")
        result["signals"] = {}
        for name in ("SigIgn", "SigBlk", "SigPnd", "ShdPnd", "SigCgt"):
            match = re.search(rf"^{name}:\s*([0-9a-fA-F]{{1,16}})$", status, re.M)
            result["signals"][name] = match.group(1) if match else "unavailable"
        result["fds"] = {}
        for descriptor in (0, 1, 2):
            try:
                target = os.readlink(f"/proc/{pid}/fd/{descriptor}")
                match = re.fullmatch(r"pipe:\[([0-9]{1,20})\]", target)
                result["fds"][str(descriptor)] = {"kind": "pipe", "inode": int(match.group(1))} if match else {
                    "kind": "null" if target == "/dev/null" else "file_or_other"}
            except FileNotFoundError:
                result["fds"][str(descriptor)] = {"kind": "closed_or_exited"}
            except OSError:
                result["fds"][str(descriptor)] = {"kind": "inaccessible"}
        current = process_identity(pid)
        if current["starttime"] != result["starttime"]:
            return {"pid": pid, "state": "identity_changed"}
    except FileNotFoundError:
        return {"pid": pid, "state": "absent"}
    except PermissionError:
        return {"pid": pid, "state": "inaccessible"}
    except (OSError, ValueError, UnicodeError, IndexError):
        return {"pid": pid, "state": "unavailable"}
    return result


class HupObserver:
    """Own one bounded observation for the existing Python-HUP scenario only."""

    def __init__(self, project: Path, test_root: Path):
        self.origin = time.monotonic_ns()
        self.records = []
        self.errors = []
        self.pid = 0
        self.watched = ()
        self.identities = {}
        self.root = test_root / "python-hup-observation"
        self.root.mkdir(mode=0o700)
        self.trace_path = self.root / "events"
        self.trace_path.touch(mode=0o600, exist_ok=False)
        self.runner_path = self.root / "run-all.sh"
        self.library_path = self.root / "test-runner.sh"
        uptime = read_bounded(Path("/proc/uptime"), 128).decode("ascii").split()[0]
        if not re.fullmatch(r"[0-9]{1,12}\.[0-9]{2}", uptime):
            raise ValueError("clock unavailable")
        self.uptime_origin_ms = int(uptime.replace(".", "")) * 10
        runner = read_bounded(project / "tests/run-all.sh", 131072).decode("utf-8")
        runner = replace_once(runner,
                              'SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)',
                              'SCRIPT_DIR="${RUN_ALL_HUP_PROJECT_DIR:?}/tests"')
        runner = replace_once(runner, 'TEST_RUNNER_LIBRARY="${PROJECT_DIR}/tests/lib/test-runner.sh"',
                              'TEST_RUNNER_LIBRARY="${RUN_ALL_HUP_LIBRARY:?}"')
        library = read_bounded(project / "tests/lib/test-runner.sh", 65536).decode("utf-8")
        for old, new in INSERTIONS:
            library = replace_once(library, old, new)
        self.runner_path.write_text(runner, encoding="utf-8")
        self.library_path.write_text(library + "\n" + TRACE_HELPER, encoding="utf-8")
        self.runner_path.chmod(0o600)
        self.library_path.chmod(0o600)
        self.environment = {"RUN_ALL_HUP_PROJECT_DIR": str(project),
                            "RUN_ALL_HUP_LIBRARY": str(self.library_path),
                            "RUN_ALL_HUP_TRACE_FILE": str(self.trace_path)}

    def mark(self, event: str, runner, *pids: int) -> None:
        if event not in {"created", "ready", "hup_sent", "wait_finished", "timeout", "failed"} or len(self.records) >= 8:
            return
        record = {"event": event, "elapsed_ms": (time.monotonic_ns() - self.origin) // 1_000_000,
                  "returncode": runner.returncode}
        self.pid = runner.pid
        if event == "ready":
            parent = process_state(pids[0]).get("ppid", 0) if pids else 0
            self.watched = tuple(dict.fromkeys((runner.pid, parent, *pids)))[:4]
        if event in {"ready", "wait_finished", "timeout", "failed"}:
            states = []
            for pid in self.watched:
                if pid <= 0:
                    continue
                state = process_state(pid)
                if event == "ready" and "starttime" in state:
                    self.identities[pid] = state["starttime"]
                elif "starttime" in state:
                    expected = self.identities.get(pid)
                    if expected is None:
                        state = {"pid": pid, "state": "identity_unregistered"}
                    elif state["starttime"] != expected:
                        state = {"pid": pid, "state": "identity_changed"}
                states.append(state)
            record["processes"] = states
            if runner.stderr is not None:
                try:
                    if runner.stderr.closed:
                        record["stderr_pipe"] = {"state": "closed"}
                        self.records.append(record)
                        return
                    fd = runner.stderr.fileno()
                    poller = select.poll()
                    poller.register(fd, select.POLLIN | select.POLLHUP)
                    record["stderr_pipe"] = {
                        "pending": struct.unpack("i", fcntl.ioctl(fd, termios.FIONREAD, struct.pack("i", 0)))[0],
                        "capacity": fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ),
                        "hup": any(mask & select.POLLHUP for _, mask in poller.poll(0)),
                    }
                except (OSError, ValueError):
                    record["stderr_pipe"] = {"state": "unavailable"}
        self.records.append(record)

    def trace(self) -> list[dict]:
        events = []
        try:
            content = read_bounded(self.trace_path, 16384).decode("ascii")
            for line in content.splitlines():
                fields = line.split()
                if (len(fields) != 8 or fields[0] not in EVENTS
                        or not re.fullmatch(r"[0-9]{1,12}\.[0-9]{2}", fields[1])
                        or not re.fullmatch(r"[0-9]{1,10}", fields[2]) or int(fields[2]) != self.pid
                        or fields[3] not in {"true", "false"} or fields[4] not in {"none", "HUP", "INT", "TERM"}
                        or fields[5] not in {"none", "HUP", "INT", "TERM", "KILL"}
                        or not re.fullmatch(r"-?[0-9]{1,10}", fields[6])
                        or not re.fullmatch(r"[0-9]{1,3}", fields[7]) or int(fields[7]) > 255 or len(events) >= 82):
                    raise ValueError("invalid observation")
                events.append({"event": fields[0], "elapsed_ms": int(fields[1].replace(".", "")) * 10 - self.uptime_origin_ms,
                               "starting": fields[3] == "true", "deferred": fields[4],
                               "signal": fields[5], "target": int(fields[6]), "status": int(fields[7])})
        except (OSError, ValueError, UnicodeError):
            self.errors = ["trace_unavailable"]
            return []
        if not events:
            self.errors = ["trace_unavailable"]
        return events

    def complete(self) -> bool:
        events = self.trace()
        names = {item["event"] for item in events}
        return (not self.errors and not names.intersection({"clock_unavailable", "critical_limit"})
                and {"child", "startup", "startup_closed", "waited", "trap", "guard", "transmit", "cleanup"}.issubset(names))

    def report(self) -> None:
        events = self.trace()
        payload = {"schema": 1, "scenario": "python-hup", "records": self.records,
                   "bash_events": events, "diagnostic_errors": self.errors,
                   "clocks": "relative monotonic controller milliseconds; relative proc-uptime Bash milliseconds"}
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=True)
        if len(encoded) > 32768:
            encoded = '{"schema":1,"scenario":"python-hup","diagnostic_errors":["report_limit"]}'
        print("Python-HUP diagnostic: " + encoded, file=sys.stderr, flush=True)


def check_contract(project: Path, test_root: Path) -> None:
    """Keep privacy/bounds/identity negative controls in the existing test task."""
    import contextlib
    import io
    from unittest import mock

    control_root = test_root / "hup-observer-controls"
    control_root.mkdir(mode=0o700)
    observer = HupObserver(project, control_root)
    observer.pid = os.getpid()
    uptime = (observer.uptime_origin_ms + 10) / 1000
    required = ("child", "startup", "startup_closed", "waited", "trap", "guard", "transmit", "cleanup")
    valid = "".join(f"{event} {uptime:.2f} {observer.pid} false none HUP 1 129\n" for event in required)
    observer.trace_path.write_text(valid, encoding="ascii")
    if not observer.complete() or any(path.stat().st_mode & 0o777 != 0o600 for path in (
            observer.trace_path, observer.runner_path, observer.library_path)):
        raise AssertionError("Python-HUP diagnostic positive control failed")

    sentinel = b"SYNTHETIC-PRIVATE-HUP-OBSERVER-CANARY"
    for value in (b"", sentinel, b"\xff" + sentinel, b"x" * 16385,
                  valid.encode() * 11, valid.replace(" 129\n", " 999\n").encode()):
        observer.errors = []
        observer.trace_path.write_bytes(value)
        if observer.complete():
            raise AssertionError("Python-HUP diagnostic accepted invalid observation")
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            observer.report()
        encoded = output.getvalue()
        payload = json.loads(encoded.split(": ", 1)[1])
        if (sentinel.decode() in encoded or len(encoded) > 32768
                or payload["diagnostic_errors"] != ["trace_unavailable"]):
            raise AssertionError("Python-HUP diagnostic privacy/bound control failed")

    module = sys.modules[__name__]
    with mock.patch.object(module, "read_bounded", side_effect=PermissionError):
        observer.errors = []
        if observer.complete() or process_state(1) != {"pid": 1, "state": "inaccessible"}:
            raise AssertionError("Python-HUP diagnostic lost observation denial")
    with mock.patch.object(module, "read_bounded", side_effect=FileNotFoundError):
        if process_state(1) != {"pid": 1, "state": "absent"}:
            raise AssertionError("Python-HUP diagnostic lost confirmed absence")
    identities = [dict(pid=1, state="S", ppid=2, pgid=3, sid=3, starttime=start) for start in (10, 11)]
    with mock.patch.object(module, "process_identity", side_effect=identities), \
            mock.patch.object(module, "read_bounded", return_value=b"SigIgn:\t0000\n"), \
            mock.patch.object(os, "readlink", return_value="/private/" + sentinel.decode()):
        if process_state(1) != {"pid": 1, "state": "identity_changed"}:
            raise AssertionError("Python-HUP diagnostic accepted mixed process identities")
    for source in ("missing", "duplicate duplicate"):
        try:
            replace_once(source, "duplicate", "replacement")
        except ValueError:
            continue
        raise AssertionError("Python-HUP diagnostic accepted source drift")
