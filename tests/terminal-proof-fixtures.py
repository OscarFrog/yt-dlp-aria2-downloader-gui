# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/terminal-proof-fixtures.py.

Provide inert dependency models for the qualification CLIs' terminal verdicts.
The real main functions, assertions, exports, and entry points are exercised;
these synthetic observations do not qualify Linux, media tools, or GUI events.
"""

import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
from unittest import mock


def run_zenity(target, case, workspace, scenario_evidence, window_event):
    """Run the unchanged CLI with inert tools and explicit observer samples.

    These witnesses exercise verdict composition, not Linux, media, or GUI
    behavior. Validators, main, export, and the actual CLI exit remain real.
    """
    import types

    root = workspace / 'private'
    root.mkdir(mode=0o700)
    exported = workspace / 'exported'
    notices = []
    current = {'label': None}
    processes = {}
    active = set()
    snapshot = {'start': 41, 'state': 'S', 'parent': 100, 'group': 100, 'session': 100}
    real_read = Path.read_text
    real_write_json = None
    real_export = None

    def note(kind, **details):
        notices.append(dict(kind=kind, **details))
        (workspace / 'harness-events.json').write_text(json.dumps(notices))

    def label_row(label):
        if label.startswith('cancel-success-race-'):
            side = 'before-publication' if int(label.rsplit('-', 1)[1]) < 5 else 'after-publication'
            return scenario_evidence('cancel-success-race', label, side)
        return scenario_evidence(label)

    def events_for(label):
        rows = copy.deepcopy(label_row(label)['events'])
        if label.startswith('cancel-success-race-') and int(label.rsplit('-', 1)[1]) >= 5:
            rows.append(window_event('race-publication-barrier', 3_400_000_000))
        for row in rows:
            if 'screenshot' in row:
                row['screenshot_sha256'] = hashlib.sha256(b'pixels').hexdigest()
        return rows

    class Process:
        def __init__(self, _args, **kwargs):
            env = kwargs['env']
            self.label = env['FIXTURE_LABEL']
            self.env = env
            self.pid = 1000 + len(processes)
            self.returncode = None
            self.cancelled = False
            self.row = label_row(self.label)
            processes[self.label] = self
            current['label'] = self.label
            active.add(self.label)
            (root / 'window-101-1.ppm').write_bytes(b'pixels')
            if 'FIXTURE_SLOW_REMUX' in env:
                Path(env['FIXTURE_SLOW_REMUX']).write_text('70000')
            note('launch', label=self.label)

        def released(self):
            return current['gates'][self.label].is_set()

        def publish_if_expected(self):
            if self.row['output_present'] and self.released():
                Path(self.env['FIXTURE_EXPECTED_FINAL']).write_bytes(b'media')

        def poll(self):
            self.publish_if_expected()
            scenario = self.env['FIXTURE_SCENARIO']
            if self.returncode is not None:
                return self.returncode
            if scenario == 'error':
                self.returncode = 3
            elif scenario in ('success', 'new-download', 'open-folder') and self.released():
                self.returncode = 0
            return self.returncode

        def send_signal(self, _number):
            self.returncode = 143
            note('parent-signal', label=self.label)

        def terminate(self):
            self.returncode = 143
            note('parent-rescue', label=self.label)

        def kill(self):
            self.returncode = -9
            note('parent-kill', label=self.label)

        def wait(self, timeout=None):
            status = self.poll()
            if status is None:
                raise AssertionError('Synthetic parent remains active at wait')
            return status

    class Session:
        def __init__(self, _root):
            self.env = {}

        def wait_window(self, _label, _kind):
            return None

        def mapped_windows(self):
            label = current['label']
            if label is None:
                return []
            process = processes[label]
            if label == 'open-folder' and not (root / (label + '.viewer-release')).exists():
                return [{'title': 'output 100% $ é'}]
            if label.startswith('cancel-success-race-') and not process.cancelled:
                return [{'title': f'qualification:{label}:progress'}]
            return []

        def progress_action(self, label, _action):
            process = processes[label]
            process.cancelled = True
            process.returncode = process.row['status']

        def close(self):
            note('session-closed')
            if case in ('cleanup-error', 'earlier-and-cleanup'):
                raise OSError(errno.EIO, 'synthetic cleanup failure')

    class Result:
        def __init__(self, final, _observer):
            self.final = final
            self.label = current['label']

        def refresh(self):
            row = processes[self.label].row
            if row['output_present']:
                self.final.write_bytes(b'media')
            return dict(result_discovered=row['result_discovered'],
                        result_published=row['result_published'])

        def close(self):
            note('result-closed', label=self.label)

    class Watch:
        def __init__(self, _observer, path, result):
            self.label = current['label']
            self.result = result
            self.path = path
            self.error = None
            self.last = None
            self.finished = 0

        def sample(self):
            label = self.label
            process = processes[label]
            live = {}
            scenario = process.env['FIXTURE_SCENARIO']
            if (scenario in ('cancel-ffmpeg', 'cancel-success-race') and
                    not process.cancelled and process.row['status'] != 0):
                live['70000'] = dict(snapshot)
            if label == 'open-folder' and not (root / (label + '.viewer-release')).exists():
                live['70000'] = dict(snapshot)
            value = dict(monotonic_ns=6_000_000_000, live=live, zombies=[], url_in_argv=[])
            value.update(self.result.refresh())
            self.last = value
            return copy.deepcopy(value)

        def result_state(self):
            return self.result.refresh()

        def check(self):
            if self.error:
                raise OSError(errno.EACCES, 'synthetic attributed observation error')

        def finish(self):
            self.finished += 1
            value = self.sample()
            value['live'] = {}
            label = self.label
            first = label == 'success'
            note('finish', label=label, number=self.finished)
            if first and self.finished == 1 and case in ('earlier-url', 'earlier-and-cleanup'):
                value['url_in_argv'] = [(70000, 41)]
            if first and self.finished > 1:
                if case == 'systemexit-observation':
                    raise SystemExit(0)
                if case in ('eacces', 'eio', 'identity-error'):
                    number = {'eio': errno.EIO, 'eacces': errno.EACCES, 'identity-error': errno.ESRCH}[case]
                    self.error = 'ObservationError'
                    raise OSError(number, 'synthetic attributed observation error')
                if case == 'missing':
                    return None
                if case == 'empty':
                    return {}
                if case == 'null-fields':
                    value['live'] = value['url_in_argv'] = None
                if case in ('final-url', 'url-and-cleanup', 'final-url-write', 'url-and-systemexit-cleanup'):
                    value['url_in_argv'] = [(70000, 41)]
                if case in ('final-live', 'invalid-identity', 'final-live-write'):
                    value['live'] = {'70000': dict(snapshot)}
                    if case == 'invalid-identity':
                        value['live']['70000']['start'] = 'wrong'
            self.last = copy.deepcopy(value)
            return value

    class Server:
        def __init__(self, *_args, **_kwargs):
            self.server_port = 19000

        def serve_forever(self):
            raise AssertionError('No network server may execute in a terminal witness')

        def shutdown(self):
            note('server-shutdown')
            if case == 'url-and-systemexit-cleanup':
                raise SystemExit(0)
            if case == 'url-and-cleanup':
                raise OSError(errno.EIO, 'synthetic cleanup failure')

        def server_close(self):
            note('server-closed')

    class Thread:
        def __init__(self, *_args, **_kwargs):
            pass

        def start(self):
            note('inert-server-thread')

    class Gate:
        def __init__(self):
            self.value = False

        def set(self):
            self.value = True
            if current['label'] in processes and 'gates' in current:
                processes[current['label']].publish_if_expected()

        def is_set(self):
            return self.value

    def read(path, *args, **kwargs):
        if path == Path('/etc/os-release'):
            return 'ID=ubuntu\nVERSION_ID=24.04\n'
        if str(path).startswith('/proc/'):
            if str(path) == '/proc/70000/comm':
                return 'ffmpeg\n'
            raise AssertionError('Unexpected procfs read in a terminal witness')
        return real_read(path, *args, **kwargs)

    def install(frame):
        nonlocal real_write_json, real_export
        namespace = frame.f_globals
        real_write_json = namespace['write_json']
        real_export = namespace['export_evidence']

        def prepare(destination, _environment):
            real_write_json(destination / 'tools.json', {})

        def handler(_routes, selected, _events):
            nonlocal active
            active = selected
            return object

        def run(_args, **_kwargs):
            return subprocess.CompletedProcess(_args, 0, stdout='synthetic tool 1\n', stderr='')

        def load(name, _filename):
            if name == 'autonomous_observer':
                return types.SimpleNamespace(Observer=lambda _token: None,
                                             process_row=lambda _path: dict(snapshot))
            return types.SimpleNamespace(Session=Session)

        final_write_failed = False

        def checked_write(path, value):
            nonlocal final_write_failed
            if case in ('final-url-write', 'final-live-write') and path.name == 'success.final-before-rescue.json':
                raise OSError(errno.EIO, 'synthetic terminal evidence failure')
            result = real_write_json(path, value)
            if (case == 'export-final-write' and path == exported / 'summary.json' and
                    isinstance(value, dict) and value.get('passed') is True and not final_write_failed):
                final_write_failed = True
                raise OSError(errno.EIO, 'synthetic final verdict write failure')
            return result

        def export(source, destination, summary):
            note('export', passed=summary['passed'])
            if case == 'export-error':
                raise OSError(errno.EIO, 'synthetic export failure')
            return real_export(source, destination, summary)

        def sleep(_seconds):
            raise AssertionError('Synthetic fixture failed to satisfy its bounded predicate')

        # Save the real main's local gate map when the first wait is reached;
        # this is fixture state, not a change to control flow or the verdict.
        original_wait = namespace['wait_until']

        def wait(predicate, message, watch=None, timeout=20):
            caller = sys._getframe(1)
            current['gates'] = caller.f_locals['gates']
            return original_wait(predicate, message, watch, timeout)

        def events(_path, label, complete=False):
            return events_for(label)

        def which(name):
            return '/synthetic/' + name

        def close(handle):
            if handle != 70000:
                os.close(handle)

        namespace.update(
            source_identity=lambda: {'source': 'synthetic fixture'},
            prepare_runtime=prepare, load_module=load,
            ResultWitness=Result, Watch=Watch, read_events=events,
            decoded_hash=lambda _path, _ffmpeg: 'media-digest',
            make_media_handler=handler, wait_until=wait, export_evidence=export,
            write_json=checked_write,
            tempfile=types.SimpleNamespace(mkdtemp=lambda **_kwargs: str(root)),
            subprocess=types.SimpleNamespace(Popen=Process, run=run, STDOUT=subprocess.STDOUT,
                                            CalledProcessError=subprocess.CalledProcessError,
                                            TimeoutExpired=subprocess.TimeoutExpired),
            shutil=types.SimpleNamespace(which=which, copyfileobj=shutil.copyfileobj),
            http=types.SimpleNamespace(server=types.SimpleNamespace(ThreadingHTTPServer=Server)),
            threading=types.SimpleNamespace(Thread=Thread, Event=Gate),
            time=types.SimpleNamespace(monotonic=time.monotonic, monotonic_ns=lambda: 6_000_000_000,
                                       sleep=sleep),
            os=types.SimpleNamespace(**{**vars(os), 'environ': {'PATH': '/usr/bin:/bin'},
                                       'pidfd_open': lambda _pid: 70000, 'close': close}),
            signal=types.SimpleNamespace(**{**vars(signal), 'pidfd_send_signal':
                                           lambda _handle, _number: note('identity-rescue')}),
        )

    def trace(frame, what, _arg):
        if what == 'call' and frame.f_code.co_name == 'main' and Path(frame.f_code.co_filename) == target:
            install(frame)
            sys.settrace(None)
        return trace

    def returned(frame, what, value):
        if what == 'return' and frame.f_code.co_name == 'main' and Path(frame.f_code.co_filename) == target:
            (root / 'main-return.json').write_text(json.dumps({'returned': value}))

    # The target's entry point is executed verbatim. SystemExit propagates to
    # this child interpreter; the parent observes its real returncode.
    sys.argv = [str(target), '--evidence-dir', str(exported)]
    with mock.patch.object(Path, 'read_text', read):
        sys.settrace(trace)
        sys.setprofile(returned)
        try:
            runpy.run_path(str(target), run_name='__main__')
        finally:
            sys.settrace(None)
            sys.setprofile(None)


def run_multi(source, case, root):
    source = Path(source).resolve()
    root = Path(root).resolve()
    root.mkdir(mode=0o700)
    evidence = root / 'evidence'
    evidence.mkdir(mode=0o700)
    coord = root / 'coord'
    coord.mkdir(mode=0o700)
    binary = root / 'tool'
    binary.write_bytes(b'synthetic-tool')
    processes = {}
    server = None
    child_pid = 900001
    child_start = 222
    child_state = 'S'
    staging = root / '.yt-dlp-aria2.synthetic'
    staging.mkdir(mode=0o700)
    (staging / 'input.download').write_bytes(b'synthetic')
    orig_read_text = Path.read_text
    orig_iterdir = Path.iterdir
    orig_readlink = os.readlink
    orig_write_text = Path.write_text


    def row(pid, state='S', start=111):
        return dict(parent=800000, group=pid, session=pid, state=state, start=start)


    def state(live=None, leaks=None):
        return dict(monotonic_ns=100, live=live or {}, zombies=[], url_in_argv=leaks or [])


    class Server:
        def __init__(self, address, handler):
            nonlocal server
            self.server_port = 19001
            values = dict(zip(handler.do_GET.__code__.co_freevars,
                              (cell.cell_contents for cell in handler.do_GET.__closure__)))
            self.values = values
            server = self
        def serve_forever(self):
            raise AssertionError('Synthetic server must not execute')
        def shutdown(self):
            if case == 'url-and-systemexit-cleanup':
                raise SystemExit(0)
            if case in ('cleanup-error', 'initial-and-cleanup'):
                raise OSError(errno.EIO, 'synthetic cleanup error')
        def server_close(self):
            pass


    class Thread:
        def __init__(self, *args, **kwargs):
            pass
        def start(self):
            pass


    class Event:
        def __init__(self):
            self.open = False
        def is_set(self):
            return self.open
        def set(self):
            self.open = True
            for process in list(processes.values()):
                if server.values['gates'].get(process.label) is self:
                    process.release()
        def wait(self, timeout=None):
            return self.open


    class Process:
        def __init__(self, args, *, env, **kwargs):
            self.label = env['FIXTURE_LABEL']
            self.pid = 810000 + len(processes)
            self.env = env
            self.returncode = None
            self.seed = json.loads(Path(env['FIXTURE_SEED']).read_text())
            self.output = Path(env['FIXTURE_OUTPUT'])
            self.final = self.output / (self.seed['title'] + ' [' + self.seed['id'] + '].mkv')
            self.cancel_pending = False
            processes[self.label] = self
            server.values['active'].add(self.label)
            if self.label in ('conflict-other-url', 'conflict-other-profile', 'truncated-other') or self.label.startswith('old-before-new-'):
                self.returncode = 75
            if self.label == 'stopping-contender':
                Path(env['FIXTURE_PLAN_GATE'] + '.ready').write_text('synthetic ready')
                self.returncode = 75
            if self.label == 'cycle2-A':
                (self.output / (self.label + '.part')).write_bytes(b'resume witness')
            info = self.output.stat()
            bucket = coord / ('resources-' + hashlib.sha256(str((info.st_dev, info.st_ino)).encode()).hexdigest())
            bucket.mkdir(exist_ok=True)
            (bucket / 'synthetic.resume.json').write_text('{"active": false}')
        def poll(self):
            return self.returncode
        def release(self):
            if self.returncode is not None:
                return
            if self.env.get('FIXTURE_SLOW_REMUX'):
                Path(self.env['FIXTURE_SLOW_REMUX']).write_text('900002')
                return
            self.final.write_bytes(server.values['media'][self.label].read_bytes())
            self.returncode = 0
            server.values['active'].discard(self.label)
        def send_signal(self, number):
            if self.label == 'stopping-owner' and child_state == 'T':
                self.cancel_pending = True
                return
            self.returncode = 143
            server.values['active'].discard(self.label)
        def wait(self, timeout=None):
            if self.returncode is None:
                raise AssertionError('Synthetic parent did not stop')
            return self.returncode


    class Observer:
        def __init__(self, token):
            self.process = next(reversed(processes.values()))
            self.known = {self.process.pid: 111}
            self.external = set()
            self.error = None
            self.leaks = set()
            self.finished_samples = 0
        def sample(self):
            p = self.process
            # Normal scenario state is deterministic; no OS process is represented.
            if p.returncode is None:
                if p.label == 'stopping-owner':
                    return state({str(child_pid): row(child_pid, child_state, child_start)})
                return state({str(p.pid): row(p.pid)})
            self.finished_samples += 1
            final = self.finished_samples >= 2
            selected = p.label == 'cycle0-A'
            if selected and not final and case == 'previous-url':
                return state(leaks=[[p.pid, 111]])
            if selected and not final and case == 'previous-incomplete':
                return {'live': {}, 'url_in_argv': []}
            if selected and final:
                if case in ('final-live', 'identity-mismatch', 'final-live-write'):
                    return state({str(p.pid): row(p.pid)})
                if case in ('final-url', 'url-and-systemexit-cleanup'):
                    return state(leaks=[[p.pid, 111]])
                if case == 'systemexit-observation':
                    raise SystemExit(0)
                if case in ('eacces', 'eio'):
                    raise OSError(errno.EACCES if case == 'eacces' else errno.EIO,
                                  'synthetic observation error')
                if case == 'missing':
                    return None
                if case == 'empty':
                    return {}
            return state()


    def read_text(path, *args, **kwargs):
        if str(path).startswith('/proc/'):
            if str(path) == '/proc/900002/comm':
                return 'ffmpeg\n'
            if str(path) == '/proc/900001/comm':
                return 'aria2c\n'
            raise AssertionError('Unexpected procfs access in inert model')
        return orig_read_text(path, *args, **kwargs)


    def write_text(path, *args, **kwargs):
        if case == 'final-live-write' and path.name == 'cycle0-A.final-before-rescue.json':
            raise OSError(errno.EIO, 'synthetic terminal evidence failure')
        return orig_write_text(path, *args, **kwargs)


    def iterdir(path):
        if str(path).startswith('/proc/'):
            if str(path) == '/proc/900001/fd':
                return iter([Path('/proc/900001/fd/9')])
            raise AssertionError('Unexpected procfs inventory in inert model')
        return orig_iterdir(path)


    def readlink(path, *args, **kwargs):
        if str(path) == '/proc/900001/fd/9':
            return str(staging / 'input.download')
        if str(path).startswith('/proc/'):
            raise AssertionError('Unexpected procfs link access')
        return orig_readlink(path, *args, **kwargs)


    def snapshot():
        rows = {child_pid: row(child_pid, child_state, child_start)}
        for process in processes.values():
            rows[process.pid] = row(process.pid, start=112 if case == 'identity-mismatch' else 111)
        return rows


    def pidfd_signal(fd, number):
        nonlocal child_state
        if number == signal.SIGSTOP:
            child_state = 'T'
        elif number == signal.SIGCONT:
            child_state = 'S'
            process = processes['stopping-owner']
            if process.cancel_pending:
                process.returncode = 143
                (staging / 'input.download').unlink()
                staging.rmdir()
        else:
            raise AssertionError('Unexpected synthetic pidfd signal')


    def kill(pid, number):
        if pid not in {p.pid for p in processes.values()}:
            raise AssertionError('Foreign synthetic target')
        with (root / 'rescue-record.jsonl').open('a') as stream:
            stream.write(json.dumps({'pid': pid, 'signal': number}) + '\n')


    def flock(fd, operation):
        if 'new-before-old' in processes and processes['new-before-old'].poll() is None:
            raise BlockingIOError(errno.EWOULDBLOCK, 'synthetic lock busy')


    def check_output(args, **kwargs):
        if args[0] == 'stat':
            return 'syntheticfs\n'
        if args[-1] == '--version':
            return '2026.6.9\n' if 'deno' not in str(args[0]) else 'deno 2.0.0\n'
        if args[-1] == 'coordination-roots':
            return str(coord) + '\n'
        if args[0] == 'ffmpeg' and '-i' in args:
            return Path(args[args.index('-i') + 1]).read_bytes()
        raise AssertionError('Unexpected synthetic check_output')


    def run(args, **kwargs):
        if args[0] != 'ffmpeg':
            raise AssertionError('Unexpected synthetic subprocess.run')
        Path(args[-1]).write_bytes(str(args[args.index('-i') + 1]).encode())
        return SimpleNamespace(returncode=0)


    def trace(frame, event, arg):
        if event == 'call' and frame.f_code.co_filename == str(source) and frame.f_code.co_name == 'main':
            # Dependency injection only: the main body, assertions, finally and
            # actual __main__ entry point all execute without control-flow edits.
            values = frame.f_globals
            values['fixture_roots'] = lambda: (root, evidence)
            values['wait_until'] = lambda predicate, message, timeout=20: values['require'](predicate(), message)
            values['observer_module'].Observer = Observer
            values['observer_module'].snapshot = snapshot
            if case in ('initial-error', 'initial-and-cleanup'):
                values['record_fixture_environment'] = lambda *args: (_ for _ in ()).throw(OSError(errno.EIO, 'synthetic initial'))
            if case == 'export-error':
                original_export = values['preserve_fixture_evidence']
                def failing_export(*args):
                    original_export(*args)
                    raise OSError(errno.EIO, 'synthetic export')
                values['preserve_fixture_evidence'] = failing_export
            sys.settrace(None)
            return None
        return trace


    def returned(frame, event, value):
        if event == 'return' and frame.f_code.co_name == 'main' and frame.f_code.co_filename == str(source):
            (root / 'main-return.json').write_text(json.dumps({'returned': value}))

    # All substituted identities/events are inert data. Any unexpected process I/O
    # raises, rather than falling through to the host.
    with mock.patch.dict(os.environ, {'YTDLP_REAL_BINARY': str(binary), 'YTDLP_QUALIFY_ZENITY_EVENTS': '0'}, clear=False), \
         mock.patch('http.server.ThreadingHTTPServer', Server), \
         mock.patch('threading.Thread', Thread), mock.patch('threading.Event', Event), \
         mock.patch('subprocess.Popen', Process), mock.patch('subprocess.run', run), \
         mock.patch('subprocess.check_output', check_output), \
         mock.patch('shutil.which', lambda name: str(binary) if name != 'deno' else str(root / 'deno')), \
         mock.patch.object(Path, 'read_text', read_text), mock.patch.object(Path, 'write_text', write_text), \
         mock.patch.object(Path, 'iterdir', iterdir), \
         mock.patch('os.readlink', readlink), mock.patch('fcntl.flock', flock), \
         mock.patch('os.kill', kill), mock.patch('os.pidfd_open', lambda pid: os.open('/dev/null', os.O_RDONLY)), \
         mock.patch('signal.pidfd_send_signal', pidfd_signal):
        (root / 'deno').write_bytes(b'synthetic deno')
        os.environ.pop('YTDLP_LEGACY_ENGINE', None)
        sys.settrace(trace)
        sys.setprofile(returned)
        try:
            runpy.run_path(str(source), run_name='__main__')
        finally:
            sys.settrace(None)
            sys.setprofile(None)
