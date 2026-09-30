# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/ci-validation-diagnostics.py.

Read bounded aggregate CI counters and selected runner log events. This optional
source-only observer never controls, enumerates or inspects workload processes.
"""

import argparse
import json
import os
import re
import stat
import sys
import time


LOG_NAMES = ("mock-gui-state.log", "packaging.log")
# Exact fixture vocabulary: a plausible-looking alphanumeric token is not a
# scenario name and must not become public diagnostic data.
SCENARIOS = frozenset("""
config-byte-limit config-crlf config-device-symlink-fallback config-fifo-fallback
config-line-limit config-overlong-fallback config-oversized-fallback
config-without-final-newline failed-download file-selection-fallback
file-selection-oversized-diagnostic gui-final-probe-diagnostic
gui-independent-inside-result gui-independent-outside-result
gui-missing-final-result-validation gui-runtime-preparation-diagnostic
gui-sanitization-failure hostile-state-directory inconsistent-result
invalid-url-without-diagnostic legacy-profile malformed-config
missing-home-default-output-directory missing-home-startup relative-home-startup
relative-tmpdir-fallback relative-xdg-home-fallback result-outside-output-dir
retained-log-boundary-redaction retained-log-bounded-whitespace-only
retained-log-oversized-single-line retained-log-whitespace-only
state-directory-error sticky-tmpdir-accepted unsafe-home-fallback-refused
unsafe-tmpdir-fallback unsafe-xdg-home-fallback
""".split())
PAYLOAD_NAMES = frozenset(("private-process-supervisor.py", "private-aria2-plan.py",
                           "download-video.sh", "runtime-manager.sh"))
MAX_SECONDS = 330
MAX_SAMPLES = 331
MAX_READ = 8192
MAX_LOG_BYTES = 1024 * 1024
MAX_LINE = 512
COUNTERS = (
    "/proc/stat", "/proc/loadavg",
    *(f"/proc/pressure/{kind}" for kind in ("cpu", "memory", "io")),
    *(f"/sys/fs/cgroup/{name}" for name in (
        "cpu.max", "cpu.stat", "cpu.pressure", "cpuset.cpus.effective",
        "memory.current", "memory.events", "io.stat")),
)
OPEN_READ = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


def private_directory(path):
    """Open an absolute private directory without following any path symlink."""
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
        raise ValueError("invalid private directory")
    parts = path.split("/")[1:]
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ValueError("invalid private directory components")
    descriptor = os.open("/", OPEN_READ | os.O_DIRECTORY)
    try:
        for part in parts:
            child = os.open(part, OPEN_READ | os.O_DIRECTORY, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        metadata = os.fstat(descriptor)
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise ValueError("directory is not private and owned")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def private_file(directory, name):
    descriptor = os.open(name, OPEN_READ, dir_fd=directory)
    try:
        metadata = os.fstat(descriptor)
        # Atomic publication links logs.pending to logs.json before removing
        # logs.pending. Only that rendezvous may temporarily have two links.
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_nlink not in ((1, 2) if name == "logs.json" else (1,))):
            raise ValueError("file is not private, regular and owned")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def publish(directory, logs):
    """Publish the runner's directory identity once, before starting children."""
    target = private_directory(directory)
    source = None
    try:
        source = private_directory(logs)
        metadata = os.fstat(source)
        # Early empty files let the observer retain their inodes across normal
        # runner cleanup. Later log redirections reuse these same regular files.
        for name in LOG_NAMES:
            descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=source)
            os.close(descriptor)
        payload = json.dumps({"directory": logs, "device": metadata.st_dev,
                              "inode": metadata.st_ino}).encode()
        if len(payload) > MAX_READ:
            raise ValueError("rendezvous exceeds bound")
        descriptor = os.open("logs.pending", os.O_WRONLY | os.O_CREAT | os.O_EXCL
                             | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=target)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
        os.link("logs.pending", "logs.json", src_dir_fd=target,
                dst_dir_fd=target, follow_symlinks=False)
        os.unlink("logs.pending", dir_fd=target)
    finally:
        if source is not None:
            os.close(source)
        os.close(target)


def counter(path):
    """Retain aggregate fields only, including explicit unavailable readings."""
    try:
        descriptor = os.open(path, OPEN_READ)
        try:
            data = os.read(descriptor, MAX_READ + 1)
        finally:
            os.close(descriptor)
        # /proc/stat contains per-CPU rows too: only the aggregate first row is
        # needed. loadavg's last field is a PID, so never retain that field.
        if path == "/proc/stat":
            data = data.split(b"\n", 1)[0]
        elif path == "/proc/loadavg":
            data = b" ".join(data.split()[:3])
        if len(data) > MAX_READ:
            return {"error": "size_bound"}
        return {"value": data.decode("ascii", errors="strict").strip()}
    except (OSError, UnicodeError) as error:
        return {"error": type(error).__name__, "errno": getattr(error, "errno", None)}


def selected_line(line):
    """Output fixed vocabulary or a constrained fixture name, never raw errors."""
    if line.startswith(b"Mock scenario: "):
        name = line[len(b"Mock scenario: "):].decode("ascii", errors="replace")
        return "Mock scenario: " + name if name in SCENARIOS else None
    if line == b"Packaging integration tests passed.":
        return "packaging-passed"
    payload = re.fullmatch(rb"Payload ([a-z0-9.-]+): [0-9a-f]{64}", line)
    if payload and payload[1].decode("ascii") in PAYLOAD_NAMES:
        return "installed-payload-checked"
    if line.startswith(b"Installed helper contract passed: "):
        return "installed-helper-contract-passed"
    if line.startswith(b"FAIL:"):
        return "failure-diagnostic-present"
    return None


class LogReader:
    """Keep exactly two read descriptors; never reopen a replaced log inode."""

    def __init__(self, directory):
        self.directory = directory
        self.logs = {}
        self.attached = False

    def close(self):
        for record in self.logs.values():
            os.close(record["fd"])
        self.logs.clear()

    def attach(self):
        if self.attached:
            return
        try:
            descriptor = private_file(self.directory, "logs.json")
        except FileNotFoundError:
            return
        try:
            payload = os.read(descriptor, MAX_READ + 1)
        finally:
            os.close(descriptor)
        if len(payload) > MAX_READ:
            raise ValueError("rendezvous exceeds bound")
        record = json.loads(payload)
        if (not isinstance(record, dict) or set(record) != {"directory", "device", "inode"}
                or type(record["device"]) is not int or type(record["inode"]) is not int):
            raise ValueError("invalid rendezvous")
        source = private_directory(record["directory"])
        try:
            metadata = os.fstat(source)
            if (metadata.st_dev, metadata.st_ino) != (record["device"], record["inode"]):
                raise ValueError("runner directory identity changed")
            for name in LOG_NAMES:
                descriptor = private_file(source, name)
                self.logs[name] = {"fd": descriptor, "bytes": 0, "pending": b"",
                                   "discard": False, "last_event": None}
            self.attached = True
        finally:
            os.close(source)

    def sample(self, final=False):
        self.attach()
        result = {}
        for name, record in self.logs.items():
            events = []
            # One chunk per ordinary tick; after command completion, drain to
            # EOF or the total byte bound, including already unlinked inodes.
            # Neither EOF nor a quiet log is proof that a process has stopped.
            while True:
                payload = os.read(record["fd"], min(MAX_READ, MAX_LOG_BYTES - record["bytes"]))
                record["bytes"] += len(payload)
                for piece in payload.splitlines(keepends=True):
                    record["pending"] += piece
                    if len(record["pending"]) > MAX_LINE:
                        record["pending"] = b""
                        record["discard"] = True
                    if piece.endswith(b"\n"):
                        if not record["discard"]:
                            event = selected_line(record["pending"].rstrip(b"\r\n"))
                            if event is not None:
                                events.append(event)
                                record["last_event"] = event
                        record["pending"] = b""
                        record["discard"] = False
                if not final or not payload or record["bytes"] == MAX_LOG_BYTES:
                    break
            result[name] = {"bytes_read": record["bytes"], "events": events,
                            "last_event": record["last_event"],
                            "size_bound": record["bytes"] == MAX_LOG_BYTES}
        return result


def observe(directory):
    descriptor = private_directory(directory)
    reader = LogReader(descriptor)
    started = time.monotonic()
    try:
        for sample in range(MAX_SAMPLES):
            now = time.monotonic()
            try:
                finished = private_file(descriptor, "done")
            except FileNotFoundError:
                done = False
            else:
                os.close(finished)
                done = True
            logs = reader.sample(final=done)
            limited = any(record["size_bound"] for record in logs.values())
            complete = done and reader.attached and not limited
            expired = now - started >= MAX_SECONDS or sample == MAX_SAMPLES - 1
            row = {"sample": sample, "monotonic_ns": time.monotonic_ns(),
                   "elapsed_seconds": now - started, "observer_cpu_seconds": time.process_time(),
                   "affinity": sorted(os.sched_getaffinity(0)), "cpu_count": os.cpu_count(),
                   "counter_scope": "host aggregates and visible cgroup mount root; not task CPU",
                   "counters": {path: counter(path) for path in COUNTERS},
                   "logs_attached": reader.attached, "logs": logs,
                   "done": done, "expired": expired, "complete": complete}
            print(json.dumps(row, separators=(",", ":")), flush=True)
            if done:
                return 0 if complete else 65
            if limited:
                return 65
            if expired:
                return 70
            time.sleep(max(0, min(1, started + sample + 1 - time.monotonic())))
        return 70
    finally:
        reader.close()
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("publish", "observe"))
    parser.add_argument("directory")
    parser.add_argument("logs", nargs="?")
    args = parser.parse_args()
    if (args.operation == "publish") != (args.logs is not None):
        parser.error("publish requires logs; observe accepts only directory")
    try:
        if args.operation == "publish":
            publish(args.directory, args.logs)
            return 0
        return observe(args.directory)
    except (OSError, ValueError, RecursionError) as error:
        # Do not leak filenames, fixture text or arbitrary exception messages.
        print(json.dumps({"diagnostic_error": type(error).__name__,
                          "errno": getattr(error, "errno", None)}), flush=True)
        return 65


if __name__ == "__main__":
    sys.exit(main())
