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
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        if fields[19] != str(start) or fields[0] not in ('Z', 'X'):
            return False
        tasks = set()
        for task in Path(f'/proc/{pid}/task').iterdir():
            row = (task / 'stat').read_text().rsplit(') ', 1)[1].split()
            if row[0] not in ('Z', 'X'):
                return False
            tasks.add((task.name, row[19]))
        if not tasks or (attempt and tasks != previous):
            return False
        previous = tasks
    return True


def session_alive(session):
    """Presence is independent of signaling authority and wait-status ownership."""
    previous = None
    try:
        for observation in range(2):
            members = set()
            for path in process_paths():
                try:
                    fields = path.read_text().rsplit(') ', 1)[1].split()
                except FileNotFoundError:
                    continue
                if int(fields[3]) == session:
                    if not process_quiescent(path.parent.name, fields[19]):
                        return True
                    members.add((path, fields[19]))
            if observation and members != previous:
                return True
            previous = members
    except (OSError, ValueError, IndexError):
        # An inaccessible root/task inventory is not an empty session.
        return True
    return False


def signal_session(session, number):
    """The unreaped direct child pins this private SID, including subgroups."""
    try:
        paths = process_paths()
    except OSError:
        return
    for path in paths:
        descriptor = None
        try:
            fields = path.read_text().rsplit(') ', 1)[1].split()
            if int(fields[3]) != session:
                continue
            # The SID anchor does not pin each member's numeric PID. Acquire
            # the signal handle before revalidating its observed membership.
            descriptor = os.pidfd_open(int(path.parent.name))
            current = path.read_text().rsplit(') ', 1)[1].split()
            if current[19] == fields[19] and int(current[3]) == session:
                signal.pidfd_send_signal(descriptor, number)
        except (AttributeError, OSError, ValueError, IndexError):
            # Failure grants neither disappearance nor cleanup permission.
            continue
        finally:
            if descriptor is not None:
                os.close(descriptor)


def check_capabilities():
    """Probe APIs and kernel permissions using only our own unreaped child."""
    for module, names in ((os, ('pidfd_open', 'waitid', 'WNOWAIT', 'WEXITED',
                               'WSTOPPED', 'waitstatus_to_exitcode')),
                          (signal, ('pidfd_send_signal', 'pthread_sigmask'))):
        if any(not hasattr(module, name) for name in names):
            raise OSError('required process supervision API is unavailable')
    process_paths()
    own = Path(f'/proc/{os.getpid()}/task/{os.getpid()}')
    (own / 'stat').read_text()
    (own / 'children').read_text()
    descriptor = None
    managed = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, managed)
    try:
        pid = os.fork()
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        raise
    if pid == 0:
        # This disposable probe never opens media or runtime resources.
        time.sleep(2)
        os._exit(0)
    try:
        descriptor = os.pidfd_open(pid)
        signal.pidfd_send_signal(descriptor, 0)
        signal.pidfd_send_signal(descriptor, signal.SIGSTOP)
        stopped = os.waitid(os.P_PID, pid, os.WSTOPPED | os.WNOWAIT)
        if stopped is None or stopped.si_code != os.CLD_STOPPED:
            raise OSError('unable to observe the supervision probe stop')
        if os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
            raise OSError('the stopped supervision probe unexpectedly exited')
        signal.pidfd_send_signal(descriptor, signal.SIGCONT)
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        exited = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
        if exited is None:
            raise OSError('unable to retain the supervision probe status')
    finally:
        # The direct child cannot be recycled before this sole parent reaps it.
        # This rescue is limited to the empty capability probe, never consumers.
        try:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def supervise(command, seconds, grace):
    try:
        check_capabilities()
    except (AttributeError, OSError, ValueError, IndexError):
        print('Error: required Linux process supervision capabilities are unavailable.', file=sys.stderr)
        return 69
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
        try:
            leader = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except (AttributeError, OSError):
            # A capability can fail after admission. Do not abandon the private
            # SID or its resources. Retry observation while retaining our child.
            leader = None
        alive = session_alive(session)
        if leader is None and not alive:
            try:
                fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
                # A failed waitid does not abandon the command. Complete SID
                # quiescence plus its pinned, terminated child permits waitpid.
                alive = not process_quiescent(pid, fields[19])
            except (OSError, ValueError, IndexError):
                alive = True
        if not alive:
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
    if sys.argv[1:] == ['--check-capabilities']:
        try:
            check_capabilities()
        except (AttributeError, OSError, ValueError, IndexError):
            print('Error: required Linux process supervision capabilities are unavailable.', file=sys.stderr)
            return 69
        return 0
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
