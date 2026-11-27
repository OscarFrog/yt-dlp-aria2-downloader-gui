#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : private-process-signals.sh
# Purpose     : Signal and retire processes with authenticated kernel identities.
# ==============================================================================

signal_owned_process() {
    python3 -I -B - "$@" <<'PY_SIGNAL_OWNED'
import os
from pathlib import Path
import signal
import sys

pid, start, session, name = sys.argv[1:]
descriptor = None
try:
    descriptor = os.pidfd_open(int(pid))
    fields = Path(f'/proc/{pid}/stat').read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
    if fields[19] != start or fields[3] != session:
        sys.exit(1)
    signal.pidfd_send_signal(descriptor, getattr(signal, 'SIG' + name))
except (AttributeError, OSError, ValueError, IndexError):
    sys.exit(1)
finally:
    if descriptor is not None:
        os.close(descriptor)
PY_SIGNAL_OWNED
}

# Keep an authenticated parent frozen while its same-session children stop.
# pidfds pin delivery; a child in a private SID keeps its supervisor alive.
escalate_owned_process() {
    python3 -I -B - "$@" <<'PY_ESCALATE_OWNED'
import os
from pathlib import Path
import signal
import sys
import time

def process_paths():
    """An explicit directory scan must fail, rather than silently match nothing."""
    paths = [entry / 'stat' for entry in Path('/proc').iterdir()
             if entry.name.isdecimal()]
    if Path(f'/proc/{os.getpid()}/stat') not in paths:
        raise OSError('incomplete process inventory')
    return paths


def process_quiescent(pid, start):
    """A zombie thread-group leader can still have running sibling threads."""
    previous = None
    for attempt in (0, 1):
        fields = Path(f'/proc/{pid}/stat').read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
        if fields[19] != str(start) or fields[0] not in ('Z', 'X'):
            return False
        tasks = set()
        for task in Path(f'/proc/{pid}/task').iterdir():
            row = (task / 'stat').read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
            if row[0] not in ('Z', 'X'):
                return False
            tasks.add((task.name, row[19]))
        if not tasks or (attempt and tasks != previous):
            return False
        previous = tasks
    return True


def process_fields(pid):
    return Path(f'/proc/{pid}/stat').read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()


def frozen_children(pid):
    previous_tasks = None
    children = set()
    for observation in range(2):
        tasks = set()
        for task in Path(f'/proc/{pid}/task').iterdir():
            fields = (task / 'stat').read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
            if fields[0] not in ('T', 't', 'Z', 'X'):
                raise ValueError('thread is not stopped')
            tasks.add((task.name, fields[19]))
            # Children belong to the thread that created them. A frozen parent
            # cannot create another thread or child between inspection and KILL.
            children.update(map(int, (task / 'children').read_text().split()))
        if not tasks or (observation and tasks != previous_tasks):
            raise ValueError('thread inventory changed')
        previous_tasks = tasks
    return children


def other_session_members_quiescent(pid, session):
    previous = None
    for observation in range(2):
        members = set()
        for path in process_paths():
            if path.parent.name == str(pid):
                continue
            try:
                fields = path.read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
            except FileNotFoundError:
                continue
            if int(fields[3]) == session:
                if not process_quiescent(path.parent.name, fields[19]):
                    return False
                members.add((path, fields[19]))
        if observation and members != previous:
            return False
        previous = members
    return True


def retire(pid, expected_start, expected_session):
    descriptor = os.pidfd_open(pid)
    stopped = False

    def identity():
        fields = process_fields(pid)
        if int(fields[19]) != expected_start or int(fields[3]) != expected_session:
            raise ValueError('identity changed')
        return fields[0]

    try:
        if identity() in ('Z', 'X') and process_quiescent(pid, expected_start):
            return True
        signal.pidfd_send_signal(descriptor, signal.SIGSTOP)
        stopped = True
        deadline = time.monotonic() + .05
        while True:
            state = identity()
            if state in ('T', 't', 'Z', 'X'):
                try:
                    children = frozen_children(pid)
                    break
                except ValueError:
                    # A dead main thread stays Z while its siblings finish the
                    # group stop. Use the same original stop deadline for them.
                    if time.monotonic() >= deadline:
                        raise
            if time.monotonic() >= deadline:
                return False
            time.sleep(.005)
        for child in children:
            try:
                fields = process_fields(child)
            except FileNotFoundError:
                continue
            if int(fields[3]) != expected_session:
                # A timed helper pins a different SID even after its direct
                # child becomes a zombie. Only that helper can finish its wait.
                return False
            if not process_quiescent(child, fields[19]):
                # Keep this parent frozen: otherwise a startup wrapper can
                # recreate a sleep between two outer escalation attempts.
                retire(child, int(fields[19]), expected_session)
        if children:
            for child in frozen_children(pid):
                try:
                    fields = process_fields(child)
                except FileNotFoundError:
                    continue
                if int(fields[3]) != expected_session or not process_quiescent(child, fields[19]):
                    return False
        if pid == expected_session and not other_session_members_quiescent(pid, expected_session):
            return False
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        stopped = False
        return True
    finally:
        if stopped:
            # A timed helper interprets CONT as force only after its first
            # graceful request; ordinary parents are simply allowed to resume.
            try:
                signal.pidfd_send_signal(descriptor, signal.SIGCONT)
            except OSError:
                pass
        os.close(descriptor)


try:
    retire(*map(int, sys.argv[1:]))
except (AttributeError, OSError, ValueError, IndexError, RecursionError):
    sys.exit(1)
PY_ESCALATE_OWNED
}
