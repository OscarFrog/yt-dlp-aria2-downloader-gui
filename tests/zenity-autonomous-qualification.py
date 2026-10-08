# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/zenity-autonomous-qualification.py.

Qualify real Zenity outcomes with isolated synthetic media, observed window
events and process identities; reject missing evidence before any fixture rescue.
"""

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

PROJECT = Path(__file__).resolve().parent.parent
ORDINARY = ('success', 'error', 'cancel-transfer', 'cancel-ffmpeg',
            'signal-entry', 'signal-progress', 'new-download', 'open-folder')
SCENARIOS = ORDINARY + ('cancel-success-race',)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, PROJECT / 'tests' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_scenario(row):
    """Check only explicit observations; absent data never means quiescence."""
    required = {'scenario', 'label', 'status', 'events', 'output_present', 'output_verified',
                'observer_error', 'final_live', 'final_windows', 'url_in_argv', 'stage',
                'closure_ns', 'exit_ns', 'diagnostics_clean', 'state_clean',
                'result_discovered', 'result_published', 'partial_retained'}
    require(isinstance(row, dict) and required <= row.keys(), 'Incomplete scenario evidence')
    scenario, events = row['scenario'], row['events']
    require(scenario in SCENARIOS, 'Unknown scenario')
    require(isinstance(row['label'], str) and bool(row['label']), 'Missing scenario label')
    require(type(row['status']) is int, 'Missing collected GUI status')
    require(isinstance(events, list) and bool(events), 'Missing dialog evidence')
    for key in ('output_present', 'output_verified', 'observer_error',
                'result_discovered', 'result_published', 'partial_retained'):
        require(type(row[key]) is bool, 'Invalid boolean evidence')
    require(row['partial_retained'] == (row['output_present'] and not row['result_published']),
            'Unconfirmed retained media evidence is contradictory')
    require(scenario == 'signal-entry' or row['result_discovered'], 'GUI result-file boundary was not observed')
    require(not row['observer_error'], 'Process observation failed')
    require(row['diagnostics_clean'] is True and row['state_clean'] is True,
            'Potential URL exposure in GUI diagnostics or retained state')
    require(isinstance(row['final_live'], dict) and not row['final_live'], 'Live process residue')
    require(isinstance(row['final_windows'], list) and not row['final_windows'], 'Mapped window residue')
    require(isinstance(row['url_in_argv'], list) and not row['url_in_argv'], 'URL argument exposure')
    require(isinstance(row['stage'], dict), 'Missing stage witness')
    for key in ('transfer_active', 'ffmpeg_active'):
        require(type(row['stage'].get(key)) is bool, 'Missing stage witness')
    require(type(row['exit_ns']) is int and row['exit_ns'] > 0, 'Missing terminal timestamp')
    if row['closure_ns'] is not None:
        require(type(row['closure_ns']) is int and
                0 < row['closure_ns'] <= row['exit_ns'] <= row['closure_ns'] + 10_000_000_000,
                'Semantic shutdown exceeded ten seconds')
    if scenario.startswith(('cancel-', 'signal-')):
        require(row['closure_ns'] is not None, 'Missing closure timestamp')
    for event in events:
        require(isinstance(event, dict) and type(event.get('monotonic_ns')) is int and
                event['monotonic_ns'] > 0, 'Invalid event identity')
        require(event.get('event') != 'adapter-failed-before-rescue', 'Event adapter failed')
    mapped = [event for event in events if event.get('event') == 'window-mapped']
    for event in events:
        if event.get('event') in ('window-mapped', 'folder-mapped', 'progress-rendered'):
            require(event.get('real_window') is True and type(event.get('window')) is int and
                    event['window'] > 0, 'Missing real window identity')
            require(isinstance(event.get('screenshot'), str) and
                    re.fullmatch(r'window-[0-9]+-[0-9]+[.]ppm', event['screenshot']) and
                    isinstance(event.get('screenshot_sha256'), str) and
                    re.fullmatch(r'[0-9a-f]{64}', event['screenshot_sha256']), 'Missing captured window pixels')
            require(all(type(event.get(key)) is int and 1 <= event[key] <= 4096
                        for key in ('width', 'height')), 'Invalid captured window geometry')
    success = [event for event in mapped if event.get('classification') == 'success']
    errors = [event for event in mapped if event.get('classification') == 'error']
    progress = [event for event in events if event.get('event') == 'progress-value']
    values = [event.get('value') for event in progress]
    require(all(type(value) is int and 0 <= value <= 100 for value in values), 'Invalid progress value')
    require(values == sorted(values), 'Displayed progress moved backwards')
    if scenario != 'signal-entry':
        require(any(event.get('dialog') == 'progress' for event in mapped), 'No real progress window')
        require(bool(values), 'No observed progress protocol')
    if row['status'] == 0 and scenario != 'signal-entry':
        require(row['result_published'] and row['output_present'] and row['output_verified'],
                'Success without the published GUI result and verified media')
        require(bool(success) and not errors, 'Success lacks an unambiguous real completion dialog')
        require(all(event.get('displayed_path_exact') is True and
                    isinstance(event.get('displayed_path_sha256'), str) and
                    re.fullmatch(r'[0-9a-f]{64}', event['displayed_path_sha256'])
                    for event in success), 'Success displayed an unbound media path')
    else:
        require(not row['result_published'], 'Failure contradicts the published GUI result')
        require(not row['output_verified'] or row['output_present'], 'Verified media has no path')
        require(not success, 'False success dialog')
    if scenario in ('success', 'new-download', 'open-folder'):
        require(row['status'] == 0, 'Successful scenario failed')
    elif scenario == 'error':
        # The direct aria2 transport preserves its resource-not-found status;
        # this controlled HTTP 404 must not pass as another preflight failure.
        require(row['status'] == 3 and bool(errors), 'Error scenario did not report the expected media failure')
        require(not row['output_present'], 'Controlled HTTP failure unexpectedly produced media')
        require(any(event.get('event') == 'http-error-response' and event.get('status') == 404 and
                    event['monotonic_ns'] < errors[0]['monotonic_ns'] for event in events),
                'Error scenario never reached its controlled HTTP failure')
    elif scenario.startswith('signal-'):
        require(row['status'] == 143 and not errors, 'Signal produced a false result')
        kind = 'entry' if scenario == 'signal-entry' else 'progress'
        if scenario == 'signal-entry':
            require(not row['output_present'] and not row['result_discovered'],
                    'Initial-entry signal unexpectedly launched media work')
        require(any(event.get('dialog') == kind and event['monotonic_ns'] < row['closure_ns']
                    for event in mapped), 'Signal window was not mapped before closure')
        if scenario == 'signal-progress':
            require(row['stage']['transfer_active'] and len(set(values)) >= 2,
                    'Signal preceded observable transfer progress')
            require(any(event.get('event') == 'progress-rendered' and
                        5 <= event.get('value', 0) < 99 and event['monotonic_ns'] < row['closure_ns']
                        for event in events), 'Signal preceded visibly rendered transfer progress')
    elif scenario in ('cancel-transfer', 'cancel-ffmpeg'):
        require(row['status'] == 130 and not errors, 'Cancellation produced a false result')
        stage = 'transfer_active' if scenario == 'cancel-transfer' else 'ffmpeg_active'
        require(row['stage'][stage], 'Cancellation missed its active stage')
        if scenario == 'cancel-transfer':
            require(any(event.get('event') == 'progress-rendered' and
                        5 <= event.get('value', 0) < 99 and event['monotonic_ns'] < row['closure_ns']
                        for event in events), 'Cancellation preceded visibly rendered transfer progress')
        require(any(event.get('action') == 'cancel' and event.get('real_window') is True
                    for event in events), 'No real Cancel action')
    elif scenario == 'cancel-success-race':
        attempts = [event for event in events if event.get('event') == 'race-attempt']
        require(len(attempts) == 1 and type(attempts[0].get('mapped')) is bool and
                type(attempts[0].get('action_after_complete')) is bool, 'Missing completion race attempt')
        attempt = attempts[0]
        side = row.get('race_side')
        require(side in ('before-publication', 'after-publication'), 'Missing publication race side')
        threshold = 97 if side == 'before-publication' else 100
        require(any(event['value'] >= threshold and event['monotonic_ns'] <= attempt['monotonic_ns']
                    for event in progress), 'Race attempt was not near completion')
        require(row['status'] in (0, 130) and not errors, 'Completion race produced a false failure')
        require(attempt['mapped'] and not attempt['action_after_complete'], 'Race skipped a real action')
        if side == 'before-publication':
            require(row['status'] == 130 and attempt.get('result_published') is False and
                    attempt.get('ffmpeg_active') is True, 'Race missed active remux before publication')
        else:
            require(row['status'] == 0 and attempt.get('final_present') is True and
                    attempt.get('result_published') is True and attempt.get('final_verified') is True,
                    'Published completion was misclassified')
        require(any(event.get('action') == 'cancel' and event.get('real_window') is True and
                    event['monotonic_ns'] >= attempt['monotonic_ns'] for event in events),
                'Race never attempted a real Cancel action')
    if scenario == 'new-download':
        selected = [event for event in events if event.get('event') == 'dialog-result' and
                    event.get('selected_action') == 'new-download']
        entries = [event for event in mapped if event.get('dialog') == 'entry']
        require(len(selected) == 1 and type(selected[0].get('status')) is int and
                selected[0]['status'] in (0, 1) and len(entries) == 1 and
                success[0]['monotonic_ns'] < selected[0]['monotonic_ns'] < entries[0]['monotonic_ns'],
                'New download did not causally open a fresh real entry')
        require(any(event.get('event') == 'dialog-result' and event.get('dialog') == 'entry' and
                    event.get('status') == 1 and event['monotonic_ns'] > entries[0]['monotonic_ns']
                    for event in events), 'Second entry did not cancel cleanly')
    if scenario == 'open-folder':
        folders = [event for event in events if event.get('event') == 'folder-mapped']
        closed = [event for event in events if event.get('event') == 'folder-closed']
        exited = [event for event in events if event.get('event') == 'folder-gui-exited']
        selected = [event for event in events if event.get('event') == 'dialog-result' and
                    event.get('selected_action') == 'open-folder']
        require(len(folders) == 1 and folders[0].get('destination_exact') is True and
                folders[0].get('real_window') is True and folders[0].get('location_property_exact') is True,
                'Selected destination was not visibly opened')
        require(len(selected) == 1 and selected[0].get('status') == 0 and
                success[0]['monotonic_ns'] < selected[0]['monotonic_ns'] < folders[0]['monotonic_ns'],
                'Selected folder lacks a causal Open folder button action')
        require(len(exited) == 1 and exited[0].get('viewer_alive') is True and
                exited[0]['monotonic_ns'] >= row['exit_ns'] and
                folders[0]['monotonic_ns'] < exited[0]['monotonic_ns'],
                'Selected folder did not survive GUI exit')
        require(len(closed) == 1 and type(closed[0].get('viewer_status')) is int and
                closed[0]['viewer_status'] == 0 and closed[0]['monotonic_ns'] > exited[0]['monotonic_ns'],
                'Isolated file manager did not close after GUI exit')


def validate_evidence(evidence):
    require(isinstance(evidence, dict) and type(evidence.get('schema')) is int and evidence['schema'] == 1 and
            isinstance(evidence.get('scenarios'), list), 'Invalid qualification schema')
    rows = evidence['scenarios']
    require(len(rows) == 18, 'All eight ordinary cases and ten races are required')
    for row in rows:
        validate_scenario(row)
    require(len({row['label'] for row in rows}) == 18, 'Repeated invocation label')
    require(all(sum(row['scenario'] == name for row in rows) == 1 for name in ORDINARY) and
            sum(row['scenario'] == 'cancel-success-race' for row in rows) == 10,
            'Incomplete scenario matrix')
    require(all(sum(row.get('race_side') == side for row in rows
                    if row['scenario'] == 'cancel-success-race') == 5
                for side in ('before-publication', 'after-publication')), 'Both publication race sides need five trials')


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def source_identity():
    inventory = subprocess.check_output([str(PROJECT / 'scripts/git-inspect.sh'), 'inventory'],
                                        cwd=PROJECT, env={'PATH': '/usr/bin:/bin'}, text=True, timeout=10)
    names = inventory.splitlines()
    require(names and len(names) == len(set(names)), 'Source inventory is empty or ambiguous')
    result = {}
    for name in names:
        path = PROJECT / name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts and
                path.is_file() and not path.is_symlink(), 'Source inventory contains an unsupported path')
        result[name] = dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                           mode=stat.S_IMODE(path.stat().st_mode))
    return result


def inspect_private_state(path):
    """Reject incomplete inventories instead of treating unreadable state as clean."""
    def scan(directory):
        clean = True
        with os.scandir(directory) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode),
                        'Unexpected retained-state file type')
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if stat.S_ISDIR(info.st_mode):
                    flags |= os.O_DIRECTORY
                child = os.open(entry.name, flags, dir_fd=directory)
                try:
                    opened = os.fstat(child)
                    require((opened.st_dev, opened.st_ino, opened.st_mode) ==
                            (info.st_dev, info.st_ino, info.st_mode), 'Retained state changed during inventory')
                    if stat.S_ISDIR(opened.st_mode):
                        clean = scan(child) and clean
                    else:
                        tail = b''
                        while True:
                            chunk = os.read(child, 65536)
                            if not chunk:
                                break
                            data = tail + chunk
                            if re.search(rb'https?://', data, re.IGNORECASE):
                                clean = False
                            tail = data[-7:]
                        after = os.fstat(child)
                        require((opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) ==
                                (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                                'Retained state changed during privacy inspection')
                finally:
                    os.close(child)
        return clean

    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(directory)
        require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
                'Retained-state root is not private')
        return scan(directory)
    finally:
        os.close(directory)


def privacy_evidence(root, raw):
    """Never copy an uninspected raw GUI diagnostic into exported evidence."""
    payload = raw.read_bytes()
    diagnostics_clean = re.search(rb'https?://', payload, re.IGNORECASE) is None
    state_clean = inspect_private_state(root / 'state')
    if diagnostics_clean and state_clean:
        destination = root / (raw.stem + '.log')
        with destination.open('xb') as stream:
            stream.write(payload)
    # Raw data remains private while the GUI runs. Even failing diagnostic
    # bytes must not be retained as a purported qualification artifact.
    raw.unlink()
    return diagnostics_clean, state_clean


def export_evidence(root, evidence, summary):
    """Publish a passing verdict only after every selected artifact was copied."""
    provisional = dict(summary, passed=False)
    locations = (root,) if root == evidence else (root, evidence)
    try:
        for directory in locations:
            write_json(directory / 'summary.json', provisional)
        for path in sorted(root.iterdir()):
            if (path.name == 'summary.json' or path.suffix not in ('.json', '.jsonl', '.log', '.ppm')
                    or '.seed.' in path.name):
                continue
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode), 'Evidence artifact is not a regular file')
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as source:
                opened = os.fstat(source.fileno())
                require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino),
                        'Evidence artifact changed before export')
                if path.suffix == '.log':
                    require(not re.search(rb'https?://', source.read(), re.IGNORECASE),
                            'Potential URL exposure prevents evidence export')
                    source.seek(0)
                if root != evidence:
                    target = evidence / path.name
                    with target.open('xb') as destination:
                        shutil.copyfileobj(source, destination)
                    target.chmod(0o600)
        for directory in locations:
            write_json(directory / 'summary.json', summary)
    except BaseException:
        failed = dict(provisional, failure=summary.get('failure') or 'Qualification evidence export failed.')
        for directory in locations:
            try:
                write_json(directory / 'summary.json', failed)
            except Exception:
                # A truncated/absent report is preferable to a stale PASS if
                # storage cannot record the failure. The caller still fails.
                try:
                    (directory / 'summary.json').unlink(missing_ok=True)
                except OSError:
                    pass
        raise


def read_events(path, label, complete=False):
    if not path.exists():
        return []
    rows = []
    # Each writer appends one bounded line. Ignore only its currently partial
    # final line; final observation after child exit requires a complete file.
    content = path.read_bytes()
    require(not complete or not content or content.endswith(b'\n'), 'Truncated final dialog evidence')
    lines = content.splitlines(keepends=True)
    for line in lines:
        if not line.endswith(b'\n'):
            continue
        row = json.loads(line)
        if row.get('title', '').startswith('qualification:' + label + ':') or row.get('label') == label:
            rows.append(row)
    return rows


class ResultWitness:
    """Observe the GUI's real atomic result through its attributed engine argv.

    A native remux may retain a final-named partial. Only the separate published
    result record authenticates successful media; a pathname is not that record.
    """
    def __init__(self, expected_final, observer_module):
        self.expected_final = Path(expected_final)
        self.observer_module = observer_module
        self.parent_fd = None
        self.parent_identity = None
        self.result_path = None
        self.published_ns = None
        self.record_sha256 = None

    def observe(self, state):
        engine = os.fsencode(PROJECT / 'download-video.sh')
        for pid, identity in state['live'].items():
            try:
                current = self.observer_module.process_row(Path(f'/proc/{pid}/stat'))
                if current['start'] != identity['start']:
                    continue
                argv = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                current = self.observer_module.process_row(Path(f'/proc/{pid}/stat'))
                if current['start'] != identity['start'] or engine not in argv or b'--result-file' not in argv:
                    continue
                index = argv.index(b'--result-file')
                require(index + 1 < len(argv) and bool(argv[index + 1]), 'Missing observed result-file argument')
                candidate = Path(os.fsdecode(argv[index + 1]))
                require(candidate.is_absolute() and candidate.name == 'result.txt' and
                        candidate.parent.resolve() == candidate.parent, 'Unsafe observed GUI result path')
                if self.result_path is not None:
                    require(candidate == self.result_path, 'GUI changed its result-file boundary')
                    continue
                handle = os.open(candidate.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    info = os.fstat(handle)
                    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
                            'GUI result parent is not private')
                    self.parent_identity = (info.st_dev, info.st_ino)
                    self.parent_fd, handle = handle, None
                    self.result_path = candidate
                finally:
                    if handle is not None:
                        os.close(handle)
            except (FileNotFoundError, ProcessLookupError):
                # A vanished attributed engine does not manufacture a result;
                # successful scenarios still require explicit prior admission.
                continue
        return self.refresh()

    def refresh(self):
        if self.parent_fd is not None:
            try:
                handle = os.open('result.txt', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=self.parent_fd)
            except FileNotFoundError:
                pass
            else:
                try:
                    info = os.fstat(handle)
                    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
                            stat.S_IMODE(info.st_mode) == 0o600 and 0 < info.st_size <= 4096,
                            'Invalid published GUI result identity')
                    payload = os.read(handle, 4097)
                    require(payload == os.fsencode(self.expected_final) + b'\n',
                            'Published GUI result does not name the selected media')
                    after = os.fstat(handle)
                    require((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) ==
                            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                            'Published GUI result changed during observation')
                    require(self.expected_final.is_file() and not self.expected_final.is_symlink(),
                            'Published GUI result lacks regular media')
                    if self.published_ns is None:
                        self.published_ns = time.monotonic_ns()
                        self.record_sha256 = hashlib.sha256(payload).hexdigest()
                finally:
                    os.close(handle)
        return dict(result_discovered=self.result_path is not None,
                    result_published=self.published_ns is not None,
                    published_ns=self.published_ns, record_sha256=self.record_sha256)

    def close(self):
        if self.parent_fd is not None:
            os.close(self.parent_fd)
            self.parent_fd = None


class Watch:
    """Keep observing the inherited marker, including between driver waits."""
    def __init__(self, observer, path, result):
        self.observer = observer
        self.result = result
        self.path = path
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.error = None
        self.last = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def sample(self):
        with self.lock:
            state = self.observer.sample()
            state.update(self.result.observe(state))
            self.last = state
            with self.path.open('a') as stream:
                stream.write(json.dumps(state) + '\n')
            return state

    def run(self):
        while not self.stop.is_set():
            try:
                self.sample()
            except Exception as error:
                self.error = type(error).__name__
                return
            self.stop.wait(.05)

    def check(self):
        require(self.error is None, 'Continuous process observation failed')

    def result_state(self):
        with self.lock:
            return self.result.refresh()

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=10)
        require(not self.thread.is_alive(), 'Observer thread did not stop')
        self.check()
        # This read begins after the caller collected the GUI exit status.
        return self.sample()


def wait_until(predicate, message, watch=None, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if watch:
            watch.check()
        result = predicate()
        if result:
            return result
        time.sleep(.02)
    raise ValueError(message)


def decoded_hash(path, ffmpeg):
    data = subprocess.check_output([ffmpeg, '-v', 'error', '-nostdin', '-i', str(path),
                                    '-map', '0:v:0', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                                   timeout=20, stderr=subprocess.PIPE)
    return hashlib.sha256(data).hexdigest()


def prepare_runtime(root, shared):
    real = os.environ.get('YTDLP_REAL_BINARY')
    asset = 'yt-dlp_linux_aarch64' if os.uname().machine == 'aarch64' else 'yt-dlp_linux'
    installed = Path.home() / '.local/share/yt-dlp-aria2-downloader/runtime/yt-dlp/current' / asset
    if not real:
        real = str(installed.resolve()) if installed.is_file() else shutil.which('yt-dlp')
    deno = shutil.which('deno')
    require(real and deno, 'Real yt-dlp and Deno are required')
    # Probe and run a copied executable under the private HOME; no personal
    # preferences, plugin directories or runtime updater are exercised.
    target = root / 'real-yt-dlp'
    shutil.copy2(real, target)
    version = subprocess.check_output([str(target), '--ignore-config', '--no-plugin-dirs', '--version'],
                                      text=True, env=shared, timeout=20).strip()
    deno_version = subprocess.check_output([deno, '--version'], text=True, env=shared,
                                           timeout=20).split()[1]
    require(version and '/' not in version and deno_version and '/' not in deno_version,
            'Invalid runtime version')
    runtime = root / 'data/yt-dlp-aria2-downloader/runtime'
    yt_dir, deno_dir = runtime / 'yt-dlp' / version, runtime / 'deno' / deno_version
    yt_dir.mkdir(parents=True, mode=0o700)
    deno_dir.mkdir(parents=True, mode=0o700)
    shutil.copy2(deno, deno_dir / 'deno')
    (yt_dir.parent / 'current').symlink_to(version)
    (deno_dir.parent / 'current').symlink_to(deno_version)
    shim = yt_dir / asset
    shim.write_text('''#!/usr/bin/python3
import os, sys
args = sys.argv[1:]
if '--batch-file' in args:
    index = args.index('--batch-file'); del args[index:index+2]
    args += ['--load-info-json', os.environ['FIXTURE_SEED']]
os.execv(os.environ['FIXTURE_REAL_YTDLP'], [os.environ['FIXTURE_REAL_YTDLP'], *args])
''')
    shim.chmod(0o700)
    shared['FIXTURE_REAL_YTDLP'] = str(target)
    write_json(root / 'tools.json', dict(yt_dlp=version, deno=deno_version,
                                       yt_dlp_sha256=hashlib.sha256(target.read_bytes()).hexdigest()))


def make_media_handler(routes, active, event_log):
    """Resolve exact HTTP targets to trusted, preconstructed fixture records."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            # Request data selects a prepared record; filenames and labels
            # come exclusively from fixture preparation, never from the URL.
            route = routes.get(self.path)
            if route is None:
                self.send_error(404)
                return
            label, source, gate, failure_path, fail_http = route
            if fail_http:
                with event_log.open('a') as stream:
                    stream.write(json.dumps(dict(event='http-error-response', label=label,
                                                 monotonic_ns=time.monotonic_ns(), status=404)) + '\n')
                self.send_error(404)
                return
            content = source.read_bytes()
            start = 0
            if self.headers.get('Range'):
                start = int(self.headers['Range'].split('=')[1].split('-')[0])
            self.send_response(206 if start else 200)
            self.send_header('Content-Length', str(len(content) - start))
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            if start:
                self.send_header('Content-Range', f'bytes {start}-{len(content)-1}/{len(content)}')
            self.end_headers()
            try:
                prefix = min(256 * 1024, (len(content) - start) // 2)
                self.wfile.write(content[start:start + prefix])
                self.wfile.flush()
                active.add(label)
                if not gate.wait(30):
                    write_json(failure_path, {'barrier_timeout': True})
                    return
                self.wfile.write(content[start + prefix:])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                active.discard(label)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='zenity-autonomous-', dir='/tmp'))
    evidence = args.evidence_dir.resolve() if args.evidence_dir else root
    if evidence != root:
        evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    print(f'Evidence: {evidence}\nPrivate fixture: {root}', flush=True)
    observer_module = load_module('autonomous_observer', 'process-observer.py')
    events_module = load_module('autonomous_events', 'zenity-x11-events.py')
    rows, children, gates, active, routes = [], [], {}, set(), {}
    session = None
    server = None
    passed = False
    failure = None

    def interrupted(number, _frame):
        raise InterruptedError(f'Qualification interrupted by signal {number}')

    old_handlers = {number: signal.signal(number, interrupted)
                    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}

    try:
        os_release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                          if '=' in line)
        distro = tuple(os_release.get(key, '').strip('"') for key in ('ID', 'VERSION_ID'))
        require(distro in (('fedora', '44'), ('ubuntu', '24.04')),
                'Real Zenity qualification requires Fedora 44 or Ubuntu 24.04')
        identity = source_identity()
        write_json(root / 'source-identity.json', identity)
        for name in ('home', 'config', 'state', 'data', 'cache', 'runtime', 'bin',
                     'private-diagnostics', 'output 100% $ é'):
            (root / name).mkdir(mode=0o700)
        output = root / 'output 100% $ é'
        shared = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
                      XDG_STATE_HOME=str(root / 'state'), XDG_DATA_HOME=str(root / 'data'),
                      XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                      PYTHONNOUSERSITE='1', LC_ALL='C.UTF-8', GSK_RENDERER='cairo', FIXTURE_AUTONOMOUS='1',
                      FIXTURE_OUTPUT=str(output), FIXTURE_DIALOG_LOG_DIR=str(root))
        for key in tuple(shared):
            if key.startswith('YTDLP_') or key in ('PYTHONPATH', 'PYTHONHOME', 'BASH_ENV', 'ENV',
                                                  'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN',
                                                  'GITHUB_ENTERPRISE_TOKEN'):
                shared.pop(key)
        shared.update(YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE='0', YTDLP_DISABLE_REMOTE_EJS='1')
        ffmpeg = shutil.which('ffmpeg')
        require(ffmpeg and shutil.which('aria2c') and shutil.which('ffprobe'), 'Real media tools are required')
        prepare_runtime(root, shared)
        session = events_module.Session(root)
        shared.update(session.env)
        versions = json.loads((root / 'tools.json').read_text())
        for name, flag in (('zenity', '--version'), ('aria2c', '--version'), ('ffmpeg', '-version'),
                           ('ffprobe', '-version'), ('nautilus', '--version')):
            executable = shutil.which(name)
            require(executable is not None, 'A required graphical/media tool is absent')
            completed = subprocess.run([executable, flag], env=shared, capture_output=True,
                                       text=True, check=True, timeout=10)
            versions[name] = completed.stdout.splitlines()[0]
        write_json(root / 'tools.json', versions)
        event_path = PROJECT / 'tests/zenity-x11-events.py'
        zenity = root / 'bin/zenity'
        zenity.write_text('#!/usr/bin/python3\nimport os, sys\n' +
                          f'os.execv(sys.executable, [sys.executable, "-I", "-B", {str(event_path)!r}, *sys.argv[1:]])\n')
        zenity.chmod(0o700)
        opener = root / 'bin/xdg-open'
        opener.write_text('#!/usr/bin/python3\nimport os, sys\n' +
                          f'os.execv(sys.executable, [sys.executable, "-I", "-B", {str(event_path)!r}, '
                          '"--autonomous-open-folder", *sys.argv[1:]])\n')
        opener.chmod(0o700)
        slow = root / 'bin/ffmpeg'
        slow.write_text('''#!/usr/bin/python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
if os.environ.get('FIXTURE_SLOW_REMUX') and '-i' in args and any(a.endswith('.mkv') for a in args):
    Path(os.environ['FIXTURE_SLOW_REMUX']).write_text(str(os.getpid()))
    args.insert(args.index('-i'), '-re')
os.execv(os.environ['FIXTURE_REAL_FFMPEG'], [os.environ['FIXTURE_REAL_FFMPEG'], *args])
''')
        slow.chmod(0o700)
        shared.update(PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'], FIXTURE_REAL_FFMPEG=ffmpeg)
        source = root / 'source.mp4'
        subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i',
                        'color=c=blue:s=160x90:r=10,noise=alls=20:allf=t+u:all_seed=7',
                        '-f', 'lavfi', '-i', 'sine=frequency=880', '-t', '4', '-c:v', 'libx264',
                        '-preset', 'ultrafast', '-crf', '0', '-c:a', 'aac', '-movflags', '+faststart',
                        str(source)], check=True, timeout=20, env=shared)
        expected_hash = decoded_hash(source, ffmpeg)
        write_json(root / 'environment.json', dict(python=sys.version, kernel=os.uname().release,
                   os_release=Path('/etc/os-release').read_text(), display_isolated=True, renderer='cairo'))
        handler = make_media_handler(routes, active, root / 'dialog-events.jsonl')
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{server.server_port}'
        matrix = [(name, name) for name in ORDINARY]
        matrix += [('cancel-success-race', f'cancel-success-race-{index:02}') for index in range(10)]
        for scenario, label in matrix:
            print(f'Running {label}', flush=True)
            gates[label] = threading.Event()
            routes['/' + label + '.mp4'] = (label, source, gates[label],
                                           root / (label + '.barrier-failed.json'), scenario == 'error')
            seed = root / (label + '.seed.json')
            write_json(seed, dict(id=label, title=label, extractor='generic', extractor_key='Generic',
                                 webpage_url=base + '/request/' + label, duration=4,
                                 formats=[dict(format_id='av', url=base + '/' + label + '.mp4',
                                               ext='mp4', protocol='http', vcodec='h264', acodec='aac')]))
            token = os.urandom(24).hex()
            race_side = ('before-publication' if int(label.rsplit('-', 1)[1]) < 5 else 'after-publication') \
                if scenario == 'cancel-success-race' else None
            final = output / f'{label} [{label}].mkv'
            env = dict(shared, FIXTURE_LABEL=label, FIXTURE_SCENARIO=scenario, FIXTURE_SEED=str(seed),
                       FIXTURE_URL=base + '/request/' + label, YTDLP_QUALIFICATION_TOKEN=token,
                       FIXTURE_EXPECTED_FINAL=str(final))
            if race_side:
                env['FIXTURE_RACE_SIDE'] = race_side
            if scenario in ('cancel-ffmpeg', 'cancel-success-race'):
                env['FIXTURE_SLOW_REMUX'] = str(root / (label + '.remux'))
            raw = root / 'private-diagnostics' / (label + '.raw')
            with raw.open('wb') as log:
                process = subprocess.Popen(['bash', str(PROJECT / 'download-video-gui.sh')],
                                           env=env, stdout=log, stderr=subprocess.STDOUT)
            watch = Watch(observer_module.Observer(token), root / (label + '.topology.jsonl'),
                          ResultWitness(final, observer_module))
            children.append((label, process, watch))
            stage = dict(transfer_active=False, ffmpeg_active=False)
            closure = None
            dialog_file = root / 'dialog-events.jsonl'

            def observed(complete=False):
                return read_events(dialog_file, label, complete)

            def still_running():
                require(process.poll() is None, 'GUI exited before the requested stage')
                return True

            if scenario == 'signal-entry':
                session.wait_window(label, 'entry')
                wait_until(lambda: any(event.get('event') == 'window-mapped' and event.get('dialog') == 'entry'
                                       for event in observed()), 'Entry pixels were not captured', watch, timeout=10)
                closure = time.monotonic_ns()
                process.send_signal(signal.SIGTERM)
            elif scenario != 'error':
                wait_until(lambda: still_running() and label in active, 'Transfer barrier not reached', watch)
                stage['transfer_active'] = True
                session.wait_window(label, 'progress')
                if scenario in ('signal-progress', 'cancel-transfer'):
                    wait_until(lambda: len({event['value'] for event in observed()
                                            if event.get('event') == 'progress-value'}) >= 2,
                               'Mapped progress did not update during transfer', watch, timeout=10)
                    wait_until(lambda: any(event.get('event') == 'progress-rendered' and
                                           5 <= event.get('value', 0) < 99 for event in observed()),
                               'Transfer progress pixels were not captured', watch, timeout=10)
                    closure = time.monotonic_ns()
                    if scenario == 'signal-progress':
                        process.send_signal(signal.SIGTERM)
                    else:
                        session.progress_action(label, 'cancel')
                else:
                    gates[label].set()
                if scenario == 'cancel-ffmpeg':
                    marker = root / (label + '.remux')
                    wait_until(marker.exists, 'Real remux was not reached', watch)
                    pid = int(marker.read_text())
                    wait_until(lambda: Path(f'/proc/{pid}/comm').read_text().strip() == 'ffmpeg',
                               'FFmpeg did not exec', watch)
                    require(str(pid) in watch.sample()['live'], 'Real FFmpeg is not an attributed live consumer')
                    stage['ffmpeg_active'] = True
                    closure = time.monotonic_ns()
                    session.progress_action(label, 'cancel')
                if scenario == 'cancel-success-race':
                    threshold = 97 if race_side == 'before-publication' else 100
                    wait_until(lambda: any(event.get('event') == 'progress-value' and event['value'] >= threshold
                                            for event in observed()), 'Near-completion progress not reached', watch)
                    ffmpeg_active = False
                    if race_side == 'before-publication':
                        pid = int((root / (label + '.remux')).read_text())
                        ffmpeg_active = (str(pid) in watch.sample()['live'] and
                                         Path(f'/proc/{pid}/comm').read_text().strip() == 'ffmpeg')
                        result = watch.result_state()
                        require(ffmpeg_active and result['result_discovered'] and not result['result_published'],
                                'Pre-publication race missed live unconfirmed remux')
                    else:
                        wait_until(lambda: any(event.get('event') == 'race-publication-barrier' for event in observed()),
                                   'Published media did not reach its dialog barrier', watch, timeout=10)
                        require(final.is_file() and decoded_hash(final, ffmpeg) == expected_hash,
                                'Post-publication race lacks verified media')
                        require(watch.result_state()['result_published'],
                                'Post-publication race lacks the GUI result record')
                    mapped = any(window['title'] == f'qualification:{label}:progress'
                                 for window in session.mapped_windows())
                    require(mapped, 'Publication race lost its actual progress window')
                    closure = time.monotonic_ns()
                    with dialog_file.open('a') as stream:
                        stream.write(json.dumps(dict(event='race-attempt', monotonic_ns=closure,
                                                     label=label, mapped=mapped,
                                                     action_after_complete=False, final_present=final.is_file(),
                                                     final_verified=race_side == 'after-publication',
                                                     result_published=watch.result_state()['result_published'],
                                                     ffmpeg_active=ffmpeg_active)) + '\n')
                    session.progress_action(label, 'cancel')
            wait_until(lambda: process.poll() is not None, 'GUI did not terminate', watch,
                       timeout=10 if closure is not None else 30)
            exited = time.monotonic_ns()
            present = final.is_file()
            verified = False
            if present:
                try:
                    verified = decoded_hash(final, ffmpeg) == expected_hash
                except subprocess.CalledProcessError:
                    # Native local remuxing intentionally preserves partial
                    # media on cancellation; it has no published GUI result.
                    pass
            # The viewer is intentionally external; its own bounded driver must
            # prove both the selected location and normal closure before PASS.
            if scenario == 'open-folder':
                wait_until(lambda: any(event.get('event') == 'folder-mapped' for event in observed()),
                           'Selected folder viewer did not map', watch, timeout=10)
                require(any(window['title'] == output.name for window in session.mapped_windows()),
                        'Selected folder did not survive GUI cleanup')
                viewer_state = watch.sample()
                require(bool(viewer_state['live']), 'Selected folder viewer is no longer alive')
                with dialog_file.open('a') as stream:
                    stream.write(json.dumps(dict(event='folder-gui-exited', monotonic_ns=time.monotonic_ns(),
                                                 label=label, viewer_alive=True)) + '\n')
                (root / (label + '.viewer-release')).touch(mode=0o600)
                wait_until(lambda: any(event.get('event') == 'folder-closed' for event in observed()),
                           'Selected folder viewer did not close', watch, timeout=10)
                wait_until(lambda: not watch.sample()['live'], 'Selected folder descendants did not stop',
                           watch, timeout=10)
            state = watch.finish()
            diagnostics_clean, state_clean = privacy_evidence(root, raw)
            row = dict(scenario=scenario, label=label, status=process.returncode, events=observed(complete=True),
                       output_present=present, output_verified=verified, observer_error=watch.error is not None,
                       final_live=state['live'], final_windows=session.mapped_windows(),
                       url_in_argv=state['url_in_argv'], stage=stage, closure_ns=closure, exit_ns=exited,
                       race_side=race_side, diagnostics_clean=diagnostics_clean, state_clean=state_clean)
            row.update(result_discovered=state['result_discovered'], result_published=state['result_published'],
                       partial_retained=present and not state['result_published'])
            write_json(root / (label + '.before-rescue.json'), row)
            rows.append(row)
            validate_scenario(row)
            for event in row['events']:
                if 'screenshot' in event:
                    image = root / event['screenshot']
                    require(image.is_file() and not image.is_symlink() and
                            hashlib.sha256(image.read_bytes()).hexdigest() == event['screenshot_sha256'],
                            'Captured pixel evidence changed or is absent')
            require(not (root / (label + '.barrier-failed.json')).exists(), 'Transfer barrier expired')
            gates[label].set()
            print(f'PASS: {label}', flush=True)
        validate_evidence(dict(schema=1, scenarios=rows))
        require(source_identity() == identity, 'Candidate source changed during qualification')
        passed = True
    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
        print('FAIL: ' + failure, file=sys.stderr, flush=True)
    finally:
        # Preserve the application verdict before rescue. Cleanup may turn PASS
        # into FAIL, but can never erase an earlier observation failure.
        def record_cleanup(path, value):
            nonlocal passed
            try:
                write_json(path, value)
            except Exception as error:
                passed = False
                print('FAIL: cleanup evidence write failed (' + type(error).__name__ + ')',
                      file=sys.stderr, flush=True)

        for number in old_handlers:
            signal.signal(number, signal.SIG_IGN)
        record_cleanup(root / 'summary.json', dict(schema=1, passed=passed, failure=failure, scenarios=rows))
        for label, process, watch in children:
            try:
                try:
                    state = watch.finish()
                except Exception as error:
                    passed = False
                    record_cleanup(root / (label + '.observer-error.json'), {'category': type(error).__name__})
                    # Last observations grant no passing verdict. They may
                    # identify fixture processes for individually revalidated
                    # rescue when a later ambient procfs inventory has failed.
                    state = watch.last or {'live': {}}
                record_cleanup(root / (label + '.final-before-rescue.json'), state)
                if state['live'] or process.poll() is None:
                    passed = False
                    record_cleanup(root / (label + '.rescue.json'), dict(label=label,
                                   monotonic_ns=time.monotonic_ns(), event='failure-before-rescue'))
                    if process.poll() is None:
                        process.terminate()
                    for pid, identity in state['live'].items():
                        handle = None
                        try:
                            handle = os.pidfd_open(int(pid))
                            current = observer_module.process_row(Path(f'/proc/{pid}/stat'))
                            if current and current['start'] == identity['start']:
                                signal.pidfd_send_signal(handle, signal.SIGKILL)
                        except (ProcessLookupError, FileNotFoundError):
                            pass
                        except Exception as error:
                            passed = False
                            record_cleanup(root / (label + '.identity-cleanup-error.json'),
                                           {'category': type(error).__name__})
                        finally:
                            if handle is not None:
                                os.close(handle)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        # Popen still owns this unreaped direct child; it is
                        # safe to rescue even if no observer sample succeeded.
                        process.kill()
                        process.wait(timeout=10)
            except Exception as error:
                passed = False
                record_cleanup(root / (label + '.cleanup-error.json'), {'category': type(error).__name__})
            finally:
                # Rescue remains possible even if a malformed snapshot or a
                # failed pidfd interrupted the per-identity rescue above.
                if process.poll() is None:
                    passed = False
                    try:
                        process.kill()
                        process.wait(timeout=10)
                    except Exception as error:
                        record_cleanup(root / (label + '.parent-cleanup-error.json'),
                                       {'category': type(error).__name__})
                try:
                    watch.result.close()
                except Exception as error:
                    passed = False
                    record_cleanup(root / (label + '.result-cleanup-error.json'),
                                   {'category': type(error).__name__})
        for gate in gates.values():
            gate.set()
        try:
            if server:
                server.shutdown()
                server.server_close()
        except Exception as error:
            passed = False
            record_cleanup(root / 'server-cleanup-error.json', {'category': type(error).__name__})
        finally:
            if session:
                try:
                    session.close()
                except Exception as error:
                    passed = False
                    record_cleanup(root / 'session-cleanup-error.json', {'category': type(error).__name__})
        for raw in (root / 'private-diagnostics').glob('*.raw'):
            try:
                raw.unlink()
            except Exception as error:
                passed = False
                record_cleanup(root / 'diagnostic-cleanup-error.json', {'category': type(error).__name__})
        record_cleanup(root / 'summary.json', dict(schema=1, passed=passed, failure=failure, scenarios=rows))
        try:
            export_evidence(root, evidence, dict(schema=1, passed=passed, failure=failure, scenarios=rows))
        except Exception as error:
            passed = False
            print('FAIL: evidence export failed (' + type(error).__name__ + ')', file=sys.stderr, flush=True)
        finally:
            for number, handler in old_handlers.items():
                signal.signal(number, handler)
    print('PASS: autonomous Zenity qualification' if passed else 'FAIL: autonomous Zenity qualification', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
