# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui private-process-supervisor.py.

Bound a timed command's private session while retaining its leader identity.
The caller supervises this process in its own session; no daemon or subreaper.
"""

import argparse
import os
from pathlib import Path
import signal
import sys
import time


def session_alive(session):
    """Presence is independent of signaling authority; zombies cannot use FDs."""
    previous = None
    for observation in range(2):
        members = set()
        for path in Path('/proc').glob('[0-9]*/stat'):
            try:
                fields = path.read_text().rsplit(') ', 1)[1].split()
                if int(fields[3]) == session:
                    if fields[0] not in ('Z', 'X'):
                        return True
                    members.add((path, fields[19]))
            except FileNotFoundError:
                continue
            except (OSError, ValueError, IndexError):
                # Incomplete observation cannot grant permission to return/cleanup.
                return True
        if observation and members != previous:
            return True
        previous = members
    return False


def signal_session(session, number):
    """The unreaped direct child pins this private SID, including subgroups."""
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields = path.read_text().rsplit(') ', 1)[1].split()
            if int(fields[3]) != session or fields[0] in ('Z', 'X'):
                continue
            current = path.read_text().rsplit(') ', 1)[1].split()
            if current[19] == fields[19] and int(current[3]) == session:
                os.kill(int(path.parent.name), number)
        except (OSError, ValueError, IndexError):
            # Failure grants neither disappearance nor cleanup permission.
            continue


def supervise(command, seconds, grace):
    requested = 0
    count = 0
    force_requested = False

    def remember(number, _frame):
        nonlocal requested, count
        if not requested:
            requested = number
        count += 1

    def force(_number, _frame):
        nonlocal force_requested
        if requested:
            force_requested = True

    signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    for number in signals:
        signal.signal(number, remember)
    # Outer supervisors escalate a non-leaf with CONT, which cannot kill an
    # ordinary waiting parent. Duplicate graceful delivery from GUI and engine
    # must not shorten the command's TERM grace period.
    signal.signal(signal.SIGCONT, force)
    # Block only the fork/registration window. The command's new session keeps
    # terminal/outer-group signals from racing its restoration of dispositions.
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    ready_read, ready_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(ready_read)
            os.setsid()
            for number in (*signals, signal.SIGPIPE, signal.SIGCONT):
                signal.signal(number, signal.SIG_DFL)
            os.write(ready_write, b'1')
            os.close(ready_write)
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
            os.execvp(command[0], command)
        except OSError:
            os._exit(127)
    os.close(ready_write)
    os.read(ready_read, 1)
    os.close(ready_read)
    session = pid
    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    deadline = time.monotonic() + seconds
    escalation = None
    timed_out = False
    sent_count = 0
    killed = False
    while True:
        # WNOWAIT pins the direct child's PID even after early leader exit.
        # A pinned session leader authenticates signaling its private session;
        # numeric SID membership alone is never signaling authority here.
        leader = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        alive = session_alive(session)
        if leader is not None and not alive:
            _, status = os.waitpid(pid, 0)
            if requested:
                return 128 + requested
            if timed_out:
                return 137 if killed else 124
            result = os.waitstatus_to_exitcode(status)
            return result if result >= 0 else 128 - result
        now = time.monotonic()
        delivery = None
        if requested and sent_count != count:
            delivery = requested
            sent_count = count
            if escalation is None:
                escalation = now + grace
        elif escalation is None and now >= deadline:
            timed_out = True
            delivery = signal.SIGTERM
            escalation = now + grace
        if escalation is not None and (now >= escalation or force_requested):
            delivery = signal.SIGKILL
        if delivery is not None:
            try:
                signal_session(session, delivery)
            except ProcessLookupError:
                pass
            if delivery == signal.SIGKILL:
                killed = True
        # If KILL cannot stop an uninterruptible consumer, stay alive and keep
        # inherited resource reservations. Returning would authorize cleanup.
        time.sleep(0.02)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--grace', type=float, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not (0 < args.timeout < 86400 and 0 < args.grace <= 60):
        parser.error('a bounded positive timeout, grace and command are required')
    return supervise(command, args.timeout, args.grace)


if __name__ == '__main__':
    sys.exit(main())
