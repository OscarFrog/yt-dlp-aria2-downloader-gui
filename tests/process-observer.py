# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-observer.py.

Observe one qualification's inherited marker and process identities, without
signaling or reaping the application. No arguments or environment are retained.
"""

import argparse
import json
import os
from pathlib import Path
import time


def process_row(path):
    fields = path.read_text().rsplit(') ', 1)[1].split()
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
    """The main thread's proc entries can be empty while siblings still run."""
    yield Path(f'/proc/{pid}/{name}')
    if row['state'] in ('Z', 'X'):
        for task in Path(f'/proc/{pid}/task').iterdir():
            if task.name.isdecimal() and task.name != str(pid):
                yield task / name


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
    def __init__(self, token):
        self.marker = b'YTDLP_QUALIFICATION_TOKEN=' + token.encode()
        self.known = set()
        self.leaks = set()
        self.external = set()

    def sample(self):
        rows = snapshot()
        selected = {}
        # The independent launch marker finds a worker even if its immediate
        # parent disappeared between samples. Recorded PID/start identities
        # continue to work after exec clears the environment.
        for pid, row in rows.items():
            key = pid, row['start']
            marked = False
            try:
                for path in observation_paths(pid, row, 'environ'):
                    try:
                        environment = path.read_bytes().split(b'\0')
                    except OSError:
                        continue
                    if self.marker not in environment:
                        continue
                    current = process_row(Path(f'/proc/{pid}/stat'))
                    if current['start'] != row['start']:
                        break
                    marked = True
                    if b'YTDLP_QUALIFICATION_EXTERNAL=1' in environment:
                        self.external.add(key)
                    break
            except (OSError, ValueError, IndexError):
                pass
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
            try:
                for path in observation_paths(pid, row, 'cmdline'):
                    try:
                        argv = path.read_bytes().lower()
                    except OSError:
                        continue
                    # Revalidate after reading argv; a reused PID is not evidence.
                    current = process_row(Path(f'/proc/{pid}/stat'))
                    if current['start'] != row['start']:
                        break
                    if b'http://' in argv or b'https://' in argv:
                        self.leaks.add(key)
                        break
            except (OSError, ValueError, IndexError):
                pass
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
