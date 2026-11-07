# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-observer.py.

Observe one qualification's inherited marker and process identities, without
signaling or reaping the application. No arguments or environment are retained.
"""

import argparse
import errno
import json
import os
from pathlib import Path
import time


class ObservationError(OSError):
    """An attributed process could not be observed; no private data is kept."""


def current_process(pid):
    """Read one fresh identity, with a bounded retry for a stale proc handle."""
    path = Path(f'/proc/{pid}/stat')
    for attempt in range(2):
        try:
            return process_row(path)
        except FileNotFoundError:
            return None
        except (ProcessLookupError, InterruptedError):
            if attempt:
                raise
    raise AssertionError('unreachable identity retry')


def same_process(pid, row):
    """Confirm disappearance or replacement only through a fresh stat read."""
    current = current_process(pid)
    return current is not None and current['start'] == row['start']


def read_observation(path):
    """Retry an interrupted read once, without treating it as an empty file."""
    try:
        return path.read_bytes()
    except InterruptedError:
        return path.read_bytes()


def read_process_observation(pid, row, path):
    """Accept memory only from the same live task within the same thread group."""
    if not same_process(pid, row):
        raise ProcessLookupError(errno.ESRCH, 'observation group identity changed')
    before = process_row(path.with_name('stat'))
    if before['state'] in ('Z', 'X'):
        raise ProcessLookupError(errno.ESRCH, 'observation task has terminated')
    data = read_observation(path)
    after = process_row(path.with_name('stat'))
    if (after['start'] != before['start'] or after['state'] in ('Z', 'X')
            or not same_process(pid, row)):
        raise ProcessLookupError(errno.ESRCH, 'observation task identity changed')
    return data


def observation_failure(pid, row, error, *, current_presence_only=False):
    # Fresh exit evidence can explain a missing attribute, but cannot restore a
    # lost privacy interval after another read failure. Only the token predicate
    # asks solely about current presence rather than continuous observation.
    if current_presence_only or isinstance(error, (FileNotFoundError, ProcessLookupError)):
        try:
            current = current_process(pid)
            if current is None or current['start'] != row['start'] or threads_are_quiescent(pid, current):
                return
        except (OSError, ValueError, IndexError) as identity_error:
            error = identity_error
    number = getattr(error, 'errno', None)
    if not isinstance(number, int) or not 0 < number < 4096:
        number = errno.EIO
    raise ObservationError(number, 'attributed process observation is incomplete') from None


def token_process_is_live(pid, marker):
    """Observe a fixture token without granting authority after a read failure."""
    for attempt in range(2):
        try:
            row = process_row(Path(f'/proc/{pid}/stat'))
            break
        except FileNotFoundError:
            return False
        except (ProcessLookupError, InterruptedError):
            if attempt:
                raise
    if threads_are_quiescent(pid, row):
        return False
    pending = None
    inspected = False
    try:
        for path in observation_paths(pid, row, 'environ'):
            try:
                environment = read_process_observation(pid, row, path).split(b'\0')
            except (FileNotFoundError, ProcessLookupError) as error:
                # A dead group leader may have a live sibling with readable
                # memory. Visit that sibling before deciding observability.
                pending = error
                continue
            except OSError as error:
                observation_failure(pid, row, error, current_presence_only=True)
                continue
            if not same_process(pid, row):
                return False
            inspected = inspected or any(environment)
            if marker in environment:
                return True
        if pending is not None and not inspected:
            observation_failure(pid, row, pending, current_presence_only=True)
    except ObservationError:
        raise
    except (OSError, ValueError, IndexError) as error:
        observation_failure(pid, row, error, current_presence_only=True)
    return False


def process_row(path):
    # comm is an arbitrary byte string, possibly truncated inside UTF-8.
    # Keep identity parsing independent and let malformed fields/read errors fail.
    fields = path.read_text(encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
    return {'start': int(fields[19]), 'state': fields[0],
            'parent': int(fields[1]), 'group': int(fields[2]), 'session': int(fields[3])}


def snapshot():
    # glob can suppress an unreadable/missing procfs root into an empty match.
    # Failure to observe is a qualification error, never evidence of shutdown.
    paths = [entry / 'stat' for entry in Path('/proc').iterdir()
             if entry.name.isdecimal()]
    own_pid = os.getpid()
    if Path(f'/proc/{own_pid}/stat') not in paths:
        raise OSError('incomplete procfs inventory: observer is absent')
    rows = {}
    for path in paths:
        try:
            rows[int(path.parent.name)] = process_row(path)
        except FileNotFoundError:
            # A process may disappear between enumeration and its stat read.
            continue
        except ProcessLookupError:
            # A stat opened before exit can fail with ESRCH when read later.
            # Reopen once: a vanished pathname confirms disappearance, a live
            # replacement supplies a fresh identity, and repeated or different
            # errors still make the observation fail instead of proving a stop.
            try:
                rows[int(path.parent.name)] = process_row(path)
            except FileNotFoundError:
                continue
    if own_pid not in rows:
        raise OSError('incomplete procfs inventory: observer stat is absent')
    return rows


def observation_paths(pid, row, name):
    """Choose live tasks; an exited leader need not retain accessible memory."""
    current = current_process(pid)
    if current is None or current['start'] != row['start']:
        return
    if current['state'] not in ('Z', 'X'):
        yield Path(f'/proc/{pid}/{name}')
        # The leader can exit after selection. Revalidate before considering
        # siblings; memory readers also revalidate both identities themselves.
        current = current_process(pid)
        if current is None or current['start'] != row['start']:
            return
    if current['state'] in ('Z', 'X'):
        live = False
        for task in Path(f'/proc/{pid}/task').iterdir():
            if task.name.isdecimal() and task.name != str(pid):
                try:
                    identity = process_row(task / 'stat')
                except FileNotFoundError:
                    continue
                if identity['state'] in ('Z', 'X'):
                    continue
                live = True
                yield task / name
        if not live and not threads_are_quiescent(pid, current):
            raise OSError(errno.EIO, 'observation task inventory is incomplete')


def threads_are_quiescent(pid, row):
    """Classify the thread group independently of the production predicates."""
    if row['state'] not in ('Z', 'X'):
        return False
    previous = None
    try:
        for _ in range(2):
            tasks = set()
            for task in Path(f'/proc/{pid}/task').iterdir():
                state = process_row(task / 'stat')
                if state['state'] not in ('Z', 'X'):
                    return False
                tasks.add((task.name, state['start']))
            current = process_row(Path(f'/proc/{pid}/stat'))
            if current['start'] != row['start'] or current['state'] not in ('Z', 'X'):
                return False
            if not tasks or (previous is not None and tasks != previous):
                return False
            previous = tasks
    except (OSError, ValueError, IndexError):
        # Incomplete observation of an attributed task cannot grant quiescence.
        return False
    return True


class Observer:
    def __init__(self, token, *, marker_name='YTDLP_QUALIFICATION_TOKEN', allow_external=True):
        self.marker = marker_name.encode() + b'=' + token.encode()
        self.known = set()
        self.leaks = set()
        self.external = set()
        self.allow_external = allow_external
        self.error = None

    def sample(self):
        if self.error is not None:
            raise self.error
        try:
            return self._sample()
        except ObservationError as error:
            # A later disappearance cannot erase a gap in privacy observation.
            self.error = error
            raise

    def _sample(self):
        rows = snapshot()
        selected = {}
        environment_errors = {}
        # The independent launch marker finds a worker even if its immediate
        # parent disappeared between samples. Recorded PID/start identities
        # continue to work after exec clears the environment.
        for pid, row in rows.items():
            key = pid, row['start']
            marked = False
            try:
                for path in observation_paths(pid, row, 'environ'):
                    try:
                        environment = read_process_observation(pid, row, path).split(b'\0')
                    except OSError as error:
                        if pid not in environment_errors or isinstance(environment_errors[pid],
                                                                       (FileNotFoundError, ProcessLookupError)):
                            environment_errors[pid] = error
                        continue
                    if any(environment) and isinstance(environment_errors.get(pid),
                                                       (FileNotFoundError, ProcessLookupError)):
                        environment_errors.pop(pid, None)
                    if self.marker not in environment:
                        continue
                    current = process_row(Path(f'/proc/{pid}/stat'))
                    if current['start'] != row['start']:
                        break
                    marked = True
                    if self.allow_external and b'YTDLP_QUALIFICATION_EXTERNAL=1' in environment:
                        self.external.add(key)
                    break
            except (OSError, ValueError, IndexError) as error:
                if pid not in environment_errors or isinstance(environment_errors[pid],
                                                               (FileNotFoundError, ProcessLookupError)):
                    environment_errors[pid] = error
            if marked or key in self.known:
                selected[pid] = row
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid not in selected and row['parent'] in selected:
                    selected[pid] = row
                    changed = True
        # Only the harness's explicit xdg-open wrapper marks an intentionally
        # opened external application. It is not a supervised download worker.
        excluded = {pid for pid, row in rows.items() if (pid, row['start']) in self.external}
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid not in excluded and row['parent'] in excluded:
                    excluded.add(pid)
                    self.external.add((pid, row['start']))
                    changed = True
        selected = {pid: row for pid, row in selected.items() if pid not in excluded}
        for pid, row in selected.items():
            key = pid, row['start']
            self.known.add(key)
            if pid in environment_errors:
                observation_failure(pid, row, environment_errors[pid])
            pending = None
            inspected = False
            try:
                for path in observation_paths(pid, row, 'cmdline'):
                    try:
                        argv = read_process_observation(pid, row, path).lower()
                    except (FileNotFoundError, ProcessLookupError) as error:
                        pending = error
                        continue
                    except OSError as error:
                        observation_failure(pid, row, error)
                        continue
                    # Revalidate after reading argv; a reused PID is not evidence.
                    current = process_row(Path(f'/proc/{pid}/stat'))
                    if current['start'] != row['start']:
                        break
                    inspected = inspected or bool(argv)
                    if b'http://' in argv or b'https://' in argv:
                        self.leaks.add(key)
                        break
                if pending is not None and not inspected:
                    observation_failure(pid, row, pending)
            except ObservationError:
                raise
            except (OSError, ValueError, IndexError) as error:
                observation_failure(pid, row, error)
        quiescent = {pid for pid, row in selected.items() if threads_are_quiescent(pid, row)}
        return {
            'monotonic_ns': time.monotonic_ns(),
            'live': {str(pid): row for pid, row in selected.items() if pid not in quiescent},
            'zombies': [pid for pid, row in selected.items() if pid in quiescent and row['state'] == 'Z'],
            'url_in_argv': sorted(self.leaks),
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('token')
    parser.add_argument('evidence', type=Path)
    parser.add_argument('stop', type=Path)
    args = parser.parse_args()
    observer = Observer(args.token)
    with (args.evidence / 'process-topology.jsonl').open('a') as log:
        while True:
            # The terminal observation must start after the stop request, not
            # return a sample captured while the application was still exiting.
            stopping = args.stop.exists()
            state = observer.sample()
            log.write(json.dumps(state) + '\n')
            log.flush()
            temporary = args.evidence / '.processes-current.tmp'
            temporary.write_text(json.dumps(state))
            os.replace(temporary, args.evidence / 'processes-current.json')
            if stopping:
                return
            time.sleep(0.05)


if __name__ == '__main__':
    main()
