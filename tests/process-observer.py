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
    rows = {}
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            rows[int(path.parent.name)] = process_row(path)
        except (OSError, ValueError, IndexError):
            continue
    return rows


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
                environment = Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
                marked = self.marker in environment
                if marked and b'YTDLP_QUALIFICATION_EXTERNAL=1' in environment:
                    self.external.add(key)
            except OSError:
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
                argv = Path(f'/proc/{pid}/cmdline').read_bytes().lower()
                # Revalidate after reading argv; a reused PID is not evidence.
                current = process_row(Path(f'/proc/{pid}/stat'))
                if current and current['start'] == row['start'] and (
                    b'http://' in argv or b'https://' in argv
                ):
                    self.leaks.add(key)
            except (OSError, ValueError, IndexError):
                pass
        return {
            'monotonic_ns': time.monotonic_ns(),
            'live': {str(pid): row for pid, row in selected.items()
                     if row['state'] not in ('Z', 'X')},
            'zombies': [pid for pid, row in selected.items() if row['state'] == 'Z'],
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
            state = observer.sample()
            log.write(json.dumps(state) + '\n')
            log.flush()
            temporary = args.evidence / '.processes-current.tmp'
            temporary.write_text(json.dumps(state))
            os.replace(temporary, args.evidence / 'processes-current.json')
            if args.stop.exists():
                return
            time.sleep(0.05)


if __name__ == '__main__':
    main()
