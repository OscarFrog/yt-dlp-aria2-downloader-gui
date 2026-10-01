# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/multi-instance-real.py.

Qualify shared-destination GUI/CLI transfers with real media tools and local
barriers. Zenity responses are scripted unless the optional isolated X11 event
adapter is selected; neither mode claims human gestures.
"""

import fcntl
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('observer', PROJECT / 'tests/process-observer.py')
observer_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer_module)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_until(predicate, message, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError(message)


def decoded_hash(path):
    data = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path),
                                    '-map', '0:v:0', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
    return hashlib.sha256(data).hexdigest()


def fixture_roots():
    # The runner's artifact directory may have shared, non-sticky ancestors.
    # Keep application HOME/XDG/media under the ordinary safe local /tmp root;
    # export only qualification evidence to the caller's requested TMPDIR.
    root = Path(tempfile.mkdtemp(prefix='shared-destination-real-', dir='/tmp'))
    evidence = root
    if Path(tempfile.gettempdir()).resolve() != Path('/tmp').resolve():
        evidence = Path(tempfile.mkdtemp(prefix='shared-destination-real-'))
    return root, evidence


def record_fixture_environment(root, evidence):
    chains = {}
    for name, path in (('workspace', root), ('evidence', evidence)):
        rows = []
        for ancestor in (path, *path.parents):
            info = ancestor.lstat()
            rows.append(dict(path=str(ancestor), uid=info.st_uid, gid=info.st_gid,
                             mode=oct(stat.S_IMODE(info.st_mode)), device=info.st_dev,
                             symlink=stat.S_ISLNK(info.st_mode),
                             filesystem=subprocess.check_output(
                                 ['stat', '-f', '--format=%T', '--', str(ancestor)], text=True).strip()))
        chains[name] = rows
    (root / 'fixture-environment.log').write_text(json.dumps(dict(
        python=sys.version, uid=os.getuid(), display_present=bool(os.environ.get('DISPLAY')),
        wayland_present=bool(os.environ.get('WAYLAND_DISPLAY')), ancestors=chains), indent=2) + '\n')
    (root / 'fixture-environment.log').chmod(0o600)


def preserve_fixture_evidence(root, evidence, labels):
    if root == evidence:
        return
    names = {'fixture-environment.log', 'fixture-tools.log', 'events.json',
             'events-xwayland.log', 'events-bus.log', 'dialog-events.jsonl', 'fixture-cleanup.jsonl'}
    names.update(label + suffix for label in labels for suffix in
                 ('.log', '.dialogs.log', '.status.log', '.before-rescue.json', '.final-before-rescue.json'))
    for name in sorted(names):
        path = root / name
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        require(stat.S_ISREG(info.st_mode), 'fixture evidence must be a regular non-symlink file')
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as source:
            opened = os.fstat(source.fileno())
            require(stat.S_ISREG(opened.st_mode) and (opened.st_dev, opened.st_ino) ==
                    (info.st_dev, info.st_ino), 'fixture evidence identity changed before export')
            with os.fdopen(os.open(evidence / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                   os.O_NOFOLLOW, 0o600), 'wb') as target:
                shutil.copyfileobj(source, target)


def write_scripted_zenity(path):
    program = '''import hashlib, json, os, re, sys, time
from pathlib import Path
os.umask(0o077)
args = sys.argv[1:]
label = os.environ['FIXTURE_LABEL']
if not re.fullmatch(r'[A-Za-z0-9_-]+', label):
    sys.exit(70)
kind = next((name for name in ('version', 'entry', 'file-selection', 'list', 'progress',
                              'question', 'error', 'info', 'text-info') if '--' + name in args), 'unknown')
dialog_text = next((value[7:] for value in args if value.startswith('--text=')), '')
is_error = kind == 'error' or (kind == 'question' and '--ok-label=View log' in args)
# Preserve only known application diagnostics, never arbitrary arguments,
# URLs, headers, diagnostic-file contents or user-entered values.
safe_errors = {
    'No safe application configuration directory is available.',
    'No safe application state directory is available.',
    'Unable to inspect setsid capabilities.',
    'This version of setsid does not support --wait.',
    'download-video.sh is missing or not executable.',
    'progress-monitor.sh is missing or not readable.',
    'The path must not contain line breaks.',
    'The selected folder is not writable.',
    'Unable to create the temporary working directory.',
    'Unable to create the private live diagnostic log.',
    'Unable to create the private progress pipe.',
    'The download is complete.',
}
dialog_error = None
if is_error:
    first_line = dialog_text.splitlines()[0] if dialog_text else ''
    if first_line in safe_errors or re.fullmatch(r"Required command '[a-zA-Z0-9_-]+' was not found[.]", first_line):
        dialog_error = first_line
    elif re.fullmatch(r'The download failed with status [0-9]+[.]', first_line):
        dialog_error = first_line
    else:
        dialog_error = '[REDACTED_UNRECOGNIZED_DIALOG_TEXT]'
def record(event, status=None):
    row = dict(monotonic_ns=time.monotonic_ns(), label=label, event=event, dialog=kind,
               status=status, dialog_error=dialog_error)
    if is_error:
        row['dialog_error_sha256'] = hashlib.sha256(dialog_text.encode()).hexdigest()
    target = Path(os.environ['FIXTURE_DIALOG_LOG_DIR']) / (label + '.dialogs.log')
    fd = os.open(target, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, (json.dumps(row) + '\\n').encode())
    finally:
        os.close(fd)
record('dialog-opened')
try:
    status = 0
    if kind == 'version': print('4.2.2')
    elif kind == 'entry': print(os.environ['FIXTURE_URL'])
    elif kind == 'file-selection': print(os.environ['FIXTURE_OUTPUT'])
    elif kind == 'list': print('Complete video (MKV)')
    elif kind == 'progress':
        for line in sys.stdin: pass
    elif kind == 'question': status = 1
    elif kind not in ('error', 'info', 'text-info'):
        raise RuntimeError('Unsupported scripted dialog')
    record('dialog-result', status)
except Exception:
    record('fixture-adapter-failed', 70)
    sys.exit(70)
sys.exit(status)
'''
    # Even a trace-opening failure must not become Zenity's ordinary Cancel.
    path.write_text('#!/usr/bin/python3\nimport sys\ntry:\n' +
                    ''.join('    ' + line for line in program.splitlines(keepends=True)) +
                    '\nexcept Exception:\n    sys.stderr.write("Scripted Zenity fixture failed\\n")\n    sys.exit(70)\n')
    path.chmod(0o700)


def main():
    root, evidence = fixture_roots()
    print(f'Evidence: {evidence}', flush=True)
    if root != evidence:
        print(f'Private fixture: {root}', flush=True)
    events = []
    processes = []
    gates = {}
    active = set()
    media = {}
    expected_final = {}
    succeeded = False
    dialogs = None

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            label = self.path.split('/')[-1].split('.')[0]
            if label not in media:
                self.send_error(404)
                return
            content = media[label].read_bytes()
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
                prefix_size = min(256 * 1024, (len(content) - start) // 2)
                self.wfile.write(content[start:start + prefix_size])
                self.wfile.flush()
                active.add(label)
                events.append((time.monotonic_ns(), label, 'bytes-served-barrier'))
                if not gates[label].wait(60):
                    events.append((time.monotonic_ns(), label, 'barrier-timeout'))
                    self.close_connection = True
                    return
                self.wfile.write(content[start + prefix_size:])
                self.wfile.flush()
                events.append((time.monotonic_ns(), label, 'transfer-released'))
            except (BrokenPipeError, ConnectionResetError):
                events.append((time.monotonic_ns(), label, 'connection-closed'))
            finally:
                active.discard(label)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}'
    try:
        record_fixture_environment(root, evidence)
        for name in ('home', 'config', 'state', 'data', 'cache', 'runtime', 'bin', 'output 100% $ é'):
            (root / name).mkdir(mode=0o700)
        output = root / 'output 100% $ é'
        external = output / 'outside-witness.txt'
        external.write_text('untouched external witness')
        original = external.stat()
        real_ytdlp = os.environ.get('YTDLP_REAL_BINARY') or shutil.which('yt-dlp')
        require(real_ytdlp, 'yt-dlp is required')
        real_deno = shutil.which('deno')
        require(real_deno, 'Deno is required')
        # Prefer the already installed standalone runtime when available; do not
        # download, update or execute personal configuration in this qualification.
        installed = Path.home() / '.local/share/yt-dlp-aria2-downloader/runtime/yt-dlp/current/yt-dlp_linux'
        if not os.environ.get('YTDLP_REAL_BINARY') and installed.is_file():
            real_ytdlp = str(installed.resolve())
        version = subprocess.check_output([real_ytdlp, '--ignore-config', '--no-plugin-dirs', '--version'], text=True).strip()
        deno_version = subprocess.check_output([real_deno, '--version'], text=True).split()[1]
        with Path(real_ytdlp).open('rb') as binary:
            kind = 'ELF' if binary.read(4) == b'\x7fELF' else 'script-or-other'
        (root / 'fixture-tools.log').write_text(json.dumps(dict(
            yt_dlp_version=version, yt_dlp_kind=kind, deno_version=deno_version)) + '\n')
        (root / 'fixture-tools.log').chmod(0o600)
        runtime = root / 'data/yt-dlp-aria2-downloader/runtime'
        yt_dir = runtime / 'yt-dlp' / version
        deno_dir = runtime / 'deno' / deno_version
        yt_dir.mkdir(parents=True, mode=0o700)
        deno_dir.mkdir(parents=True, mode=0o700)
        shutil.copy2(real_deno, deno_dir / 'deno')
        (yt_dir.parent / 'current').symlink_to(version)
        (deno_dir.parent / 'current').symlink_to(deno_version)
        shim = yt_dir / ('yt-dlp_linux_aarch64' if os.uname().machine == 'aarch64' else 'yt-dlp_linux')
        shim.write_text('''#!/usr/bin/python3
import os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
real = os.environ['FIXTURE_REAL_YTDLP']
if '--batch-file' in args:
    index = args.index('--batch-file'); del args[index:index+2]
    args += ['--load-info-json', os.environ['FIXTURE_SEED']]
if '--dump-single-json' in args and os.environ.get('FIXTURE_PLAN_GATE'):
    result = subprocess.run([real, *args], stdout=subprocess.PIPE)
    Path(os.environ['FIXTURE_PLAN_GATE'] + '.ready').write_text('ready')
    while not Path(os.environ['FIXTURE_PLAN_GATE']).exists(): time.sleep(.01)
    sys.stdout.buffer.write(result.stdout)
    sys.exit(result.returncode)
os.execv(real, [real, *args])
''')
        shim.chmod(0o700)
        zenity = root / 'bin/zenity'
        write_scripted_zenity(zenity)
        if os.environ.get('YTDLP_QUALIFY_ZENITY_EVENTS') == '1':
            event_path = PROJECT / 'tests/zenity-x11-events.py'
            event_spec = importlib.util.spec_from_file_location('zenity_events', event_path)
            event_module = importlib.util.module_from_spec(event_spec)
            event_spec.loader.exec_module(event_module)
            dialogs = event_module.Session(root)
            zenity.write_text('#!/usr/bin/python3\nimport os, sys\n'
                              f'os.execv(sys.executable, [sys.executable, "-I", "-B", {str(event_path)!r}, *sys.argv[1:]])\n')
        ffmpeg = root / 'bin/ffmpeg'
        ffmpeg.write_text('''#!/usr/bin/python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
if os.environ.get('FIXTURE_SLOW_REMUX') and '-i' in args and any(a.endswith('.mkv') for a in args):
    Path(os.environ['FIXTURE_SLOW_REMUX']).write_text(str(os.getpid()))
    args.insert(args.index('-i'), '-re')
os.execv(os.environ['FIXTURE_REAL_FFMPEG'], [os.environ['FIXTURE_REAL_FFMPEG'], *args])
''')
        ffmpeg.chmod(0o700)
        shared = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
                      XDG_STATE_HOME=str(root / 'state'), XDG_DATA_HOME=str(root / 'data'),
                      XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                      PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                      YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE='0', YTDLP_DISABLE_REMOTE_EJS='1',
                      FIXTURE_REAL_YTDLP=real_ytdlp, FIXTURE_REAL_FFMPEG=shutil.which('ffmpeg'),
                      FIXTURE_OUTPUT=str(output), FIXTURE_DIALOG_LOG_DIR=str(root))
        if dialogs is not None:
            shared.update(dialogs.env)
        for key in ('YTDLP_ARIA2_YTDLP_BIN', 'YTDLP_ARIA2_DENO_BIN', 'YTDLP_ARIA2_SUPERVISED_SESSION',
                    'YTDLP_ARIA2_SKIP_RUNTIME_UPDATE'):
            shared.pop(key, None)
        lock_root = Path(subprocess.check_output(['python3', str(PROJECT / 'private-aria2-plan.py'),
                                                  'private-root', '--no-runtime'], env=shared, text=True).strip())
        info = output.stat()
        bucket = lock_root / ('resources-' + hashlib.sha256(str((info.st_dev, info.st_ino)).encode()).hexdigest())
        # A new directory may reuse an old inode. Retained records from earlier
        # incarnations must remain intact, not count as activity of this fixture.
        initial_records = {}
        for path in bucket.glob('*.resume.json'):
            payload = path.read_bytes()
            initial_records[path.name] = (hashlib.sha256(payload).hexdigest(), json.loads(payload)['active'])

        for index, color in enumerate(('red', 'green', 'blue', 'yellow')):
            path = root / f'source-{index}.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-f', 'lavfi', '-i',
                            f'color=c={color}:s=160x90:r=10,noise=alls=20:allf=t+u:all_seed={index + 1}', '-f', 'lavfi', '-i',
                            f'sine=frequency={440 + index * 220}', '-t', '4', '-c:v', 'libx264',
                            '-preset', 'ultrafast', '-crf', '0', '-c:a', 'aac', '-movflags', '+faststart', str(path)], check=True)
        expected = [decoded_hash(root / f'source-{i}.mp4') for i in range(4)]
        require(len(set(expected)) == 4, 'source content witnesses are not distinct')

        def launch(label, index=0, *, gui=False, title=None, ident=None, native=False, slow=False,
                   plan_gate=False, destination=None, request_label=None, mode='video', alternate_runtime=False,
                   engine=None):
            media[label] = root / f'source-{index}.mp4'
            gates.setdefault(label, threading.Event())
            seed = root / f'{label}.json'
            seed.write_text(json.dumps({'id': ident or label, 'title': title or label,
                'extractor': 'generic', 'extractor_key': 'Generic', 'webpage_url': base + '/request/' + label,
                'duration': 4, 'formats': [{'format_id': 'av', 'url': base + '/' + label + '.mp4',
                'ext': 'mp4', 'protocol': 'http', 'vcodec': 'h264', 'acodec': 'aac',
                'http_headers': {'X-Native-Fixture': '1'} if native else {}}]}))
            seed.chmod(0o600)
            token = os.urandom(24).hex()
            env = dict(shared, FIXTURE_SEED=str(seed), FIXTURE_URL=base + '/request/' + (request_label or label),
                       YTDLP_QUALIFICATION_TOKEN=token, FIXTURE_LABEL=label)
            if slow:
                env['FIXTURE_SLOW_REMUX'] = str(root / f'{label}.remux')
            if plan_gate:
                env['FIXTURE_PLAN_GATE'] = str(root / f'{label}.plan-gate')
            if alternate_runtime:
                alternate = root / 'alternate-runtime'
                alternate.mkdir(mode=0o700, exist_ok=True)
                env['XDG_RUNTIME_DIR'] = str(alternate)
            result = root / f'{label}.result'
            args = ['bash', str(engine or PROJECT / ('download-video-gui.sh' if gui else 'download-video.sh'))]
            if not gui:
                url_file = root / f'{label}.url'
                url_file.write_text(env['FIXTURE_URL'] + '\n'); url_file.chmod(0o600)
                args += ['--url-file', str(url_file), '--output-dir', str(destination or output),
                         '--result-file', str(result), '--mode', mode]
            log = (root / f'{label}.log').open('wb')
            process = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT)
            log.close()
            obs = observer_module.Observer(token)
            entry = (label, process, obs, index)
            processes.append(entry)
            expected_final[process.pid] = output / f'{title or label} [{ident or label}].mkv'
            events.append((time.monotonic_ns(), label, 'launched'))
            return entry

        def finish(entry, expected_status=0, *, check_media=True):
            label, process, obs, index = entry
            wait_until(lambda: process.poll() is not None, f'{label} did not terminate', 30)
            events.append((time.monotonic_ns(), label, 'parent-exited'))
            state = obs.sample()
            (root / f'{label}.before-rescue.json').write_text(json.dumps(state))
            require(process.returncode == expected_status,
                    f'{label} status {process.returncode}, expected {expected_status}; see {root / (label + ".log")}')
            require(not state['live'], f'{label} left live descendants before rescue')
            require(not state['url_in_argv'], f'{label} exposed synthetic URL in process arguments')
            events.append((time.monotonic_ns(), label, 'consumers-observed-quiescent'))
            if expected_status == 0 and check_media:
                final = expected_final[process.pid]
                require(final.is_file(), f'{label} did not publish directly in the selected directory')
                require(decoded_hash(final) == expected[index], f'{label} produced the wrong media content')

        def wait_active(entry):
            label, p, obs, _ = entry
            wait_until(lambda: label in active or p.poll() is not None, f'{label} never reached transfer barrier')
            require(p.poll() is None,
                    f'{label} exited before transfer (status {p.returncode}); '
                    f'see {evidence / (label + ".log")} and {evidence / (label + ".dialogs.log")}')
            obs.sample()

        if dialogs is not None:
            for label in ('entry-window-close', 'entry-cancel'):
                finish(launch(label, gui=True), check_media=False)
                outcomes = [json.loads(line) for line in (root / 'dialog-events.jsonl').read_text().splitlines()]
                require(any(row.get('event') == 'dialog-result' and row['status'] == 1
                            and row['title'] == f'qualification:{label}:entry' for row in outcomes),
                        f'{label} did not return a real dialog cancellation result')
                require(not any(row.get('event') == 'adapter-failed-before-rescue' for row in outcomes),
                        'event injection failed before the graphical verdict')

        # GUI/GUI and GUI/CLI share every HOME/XDG/runtime root, plus destination.
        for cycle, modes in enumerate(((True, True, True), (True, False, True), (False, False, False))):
            a, b, c = [launch(f'cycle{cycle}-{letter}', i, gui=modes[i], slow=cycle == 1 and i == 0,
                              native=cycle == 2 and i == 0)
                       for i, letter in enumerate('ABC')]
            for item in (a, b, c):
                wait_active(item)
            require(all(item[0] in active for item in (a, b, c)), 'transfers did not overlap')
            if cycle == 2:
                wait_until(lambda: any(p.stat().st_size for p in output.glob(a[0] + '*.part')),
                           'native transfer did not flush its owned partial before cancellation')
            if cycle == 1:
                gates[a[0]].set()
                wait_until(lambda: (root / f'{a[0]}.remux').exists(), 'real remux was not reached')
                ffpid = int((root / f'{a[0]}.remux').read_text())
                wait_until(lambda: Path(f'/proc/{ffpid}/comm').read_text().strip() == 'ffmpeg', 'FFmpeg did not exec')
            events.append((time.monotonic_ns(), a[0], 'closure-request'))
            if dialogs is not None and cycle < 2:
                dialogs.progress_action(a[0], 'window-close' if cycle == 0 else 'cancel')
                finish(a, 130)
            else:
                a[1].send_signal(signal.SIGTERM)
                finish(a, 143)
            require(b[1].poll() is None and c[1].poll() is None, 'closing A interrupted B/C')
            d = launch(f'cycle{cycle}-D', 3, gui=False)
            wait_active(d)
            for item in (b, c, d):
                gates[item[0]].set()
            for item in (b, c, d):
                finish(item)
            gates[a[0]].set()
            if cycle == 2:
                partials = list(output.glob(a[0] + '*.part'))
                require(partials and any(p.stat().st_size for p in partials), 'native cancellation left no resume witness')
                resumed = launch('native-resumed', 0, title=a[0], ident=a[0], request_label=a[0], native=True)
                wait_active(resumed)
                gates[resumed[0]].set()
                finish(resumed)

        if dialogs is not None:
            restarted = launch('new-download', gui=True)
            wait_active(restarted)
            gates[restarted[0]].set()
            finish(restarted)
            require((root / 'new-download.new-download').is_file(),
                    'real completion dialog did not restart the GUI')
            dialog_events = [json.loads(line) for line in (root / 'dialog-events.jsonl').read_text().splitlines()]
            require(any(row['title'] == 'qualification:new-download:entry'
                        and row.get('event') == 'dialog-result' and row['status'] == 1
                        for row in dialog_events),
                    'New download did not present a new real entry dialog')

        # Distinct URLs with identical reserved filenames conflict in two CLIs;
        # a path alias and a different XDG_RUNTIME_DIR still use the same inode.
        first = launch('conflict-owner', title='same target', ident='same')
        wait_active(first)
        alias = root / 'destination-alias'; alias.symlink_to(output, target_is_directory=True)
        contender = launch('conflict-other-url', title='same target', ident='same', destination=alias, alternate_runtime=True)
        finish(contender, 75)
        # Video plans MKV and audio plans the native input name, but both would
        # modify the same MP4. Distinct final names must not bypass exclusion.
        audio_conflict = launch('conflict-other-profile', title='same target', ident='same', mode='audio')
        finish(audio_conflict, 75)
        require(first[1].poll() is None, 'conflict touched the reservation owner')
        first[1].send_signal(signal.SIGTERM)
        finish(first, 143)
        gates[first[0]].set()
        # A later independent CLI is admitted after completed cleanup.
        again = launch('after-conflict', 2)
        wait_active(again); gates[again[0]].set(); finish(again)

        # Keep a real aria2 consumer stopped with an open staging FD while the
        # GUI starts closing. The competitor is planned before the signal so
        # its reservation probe runs inside the ordinary escalation deadline.
        owner = launch('stopping-owner', gui=True, title='stop owner', ident='stop')
        independent = launch('stopping-independent', 1)
        wait_active(owner); wait_active(independent)
        contender = launch('stopping-contender', title='stop owner', ident='stop', plan_gate=True)
        gate = root / 'stopping-contender.plan-gate'
        wait_until(lambda: gate.with_suffix('.plan-gate.ready').exists(), 'conflict plan did not reach barrier')
        live = owner[2].sample()['live']
        consumers = []
        for candidate, row in live.items():
            try:
                command = Path(f'/proc/{candidate}/comm').read_text().strip()
            except FileNotFoundError:
                # Short-lived siblings can exit after the observer snapshot.
                # The actual barrier consumer must still be found uniquely.
                continue
            if command == 'aria2c':
                consumers.append((int(candidate), row))
        require(len(consumers) == 1, 'real aria2 consumer was not observed')
        pid, identity = consumers[0]
        staging = [Path(os.readlink(fd)).parent for fd in Path(f'/proc/{pid}/fd').iterdir()
                   if '/.yt-dlp-aria2.' in os.readlink(fd) and os.readlink(fd).endswith('.download')]
        require(staging, 'aria2 did not retain an open staging media descriptor')
        consumer_handle = os.pidfd_open(pid)
        try:
            require(observer_module.snapshot().get(pid, {}).get('start') == identity['start'],
                    'aria2 identity changed before the cancellation barrier')
            signal.pidfd_send_signal(consumer_handle, signal.SIGSTOP)
        finally:
            os.close(consumer_handle)
        wait_until(lambda: observer_module.snapshot().get(pid, {}).get('state') == 'T', 'aria2 did not stop at barrier')
        events.append((time.monotonic_ns(), owner[0], 'consumer-stopped-with-open-fd'))
        owner[1].send_signal(signal.SIGTERM)
        events.append((time.monotonic_ns(), owner[0], 'closure-request'))
        gate.touch()
        finish(contender, 75)
        require(observer_module.snapshot().get(pid, {}).get('start') == identity['start'], 'consumer escaped the cancellation barrier')
        require(all(path.is_dir() for path in staging), 'staging removed while real aria2 still holds its media FD')
        require(owner[1].poll() is None, 'GUI reported closure with a stopped live consumer')
        require(independent[1].poll() is None, 'independent request was interrupted')
        events.append((time.monotonic_ns(), owner[0], 'reservation-refused-before-last-access'))
        consumer_handle = os.pidfd_open(pid)
        try:
            require(observer_module.snapshot().get(pid, {}).get('start') == identity['start'],
                    'aria2 identity changed before releasing the cancellation barrier')
            signal.pidfd_send_signal(consumer_handle, signal.SIGCONT)
        finally:
            os.close(consumer_handle)
        finish(owner, 143)
        require(all(not path.exists() for path in staging), 'confirmed aria2 shutdown retained active staging')
        events.append((time.monotonic_ns(), owner[0], 'staging-cleaned'))
        gates[owner[0]].set()
        fresh = launch('stopping-relaunch', title='stop owner', ident='stop')
        wait_active(fresh)
        gates[fresh[0]].set(); gates[independent[0]].set()
        finish(fresh); finish(independent)

        # Exact historical inode, both launch orders. No old executable is
        # patched or credited with the new supervisor's guarantees.
        legacy_key = hashlib.sha256((str(output.resolve()) + '\0').encode()).hexdigest()
        legacy = (lock_root / (legacy_key + '.lock')).open('a')
        fcntl.flock(legacy, fcntl.LOCK_EX | fcntl.LOCK_NB)
        rejected = launch('old-before-new', 1)
        finish(rejected, 75)
        legacy.close()
        new = launch('new-before-old', 3)
        wait_active(new)
        with (lock_root / (legacy_key + '.lock')).open('a') as legacy:
            try:
                fcntl.flock(legacy, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError('old exclusive protocol bypassed a new active writer')
        gates[new[0]].set(); finish(new)
        if os.environ.get('YTDLP_LEGACY_ENGINE'):
            legacy_engine = Path(os.environ['YTDLP_LEGACY_ENGINE']).resolve(strict=True)
            old = launch('legacy-real-first', 0, engine=legacy_engine)
            wait_active(old)
            blocked = launch('new-behind-legacy-real', 1)
            finish(blocked, 75)
            gates[old[0]].set(); finish(old)
            current = launch('current-before-legacy-real', 2)
            wait_active(current)
            blocked = launch('legacy-real-behind-current', 3, engine=legacy_engine)
            finish(blocked, 75)
            gates[current[0]].set(); finish(current)
        truncated = launch('truncated-owner', title='é' * 90 + 'one', ident='long')
        wait_active(truncated)
        equivalent = launch('truncated-other', title='é' * 90 + 'two', ident='long')
        finish(equivalent, 75)
        truncated[1].send_signal(signal.SIGTERM)
        finish(truncated, 143); gates[truncated[0]].set()
        changed_records = []
        final_digests = {}
        for path in bucket.glob('*.resume.json'):
            payload = path.read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            final_digests[path.name] = digest
            if initial_records.get(path.name, (None, False))[0] != digest:
                changed_records.append(json.loads(payload))
        require(changed_records and all(not row['active'] for row in changed_records),
                'completed cycles accumulated an active reservation')
        require(all(final_digests.get(name) == digest for name, (digest, active) in initial_records.items() if active),
                'fixture changed or removed an older active checkpoint')
        require(not any(event[2] == 'barrier-timeout' for event in events), 'a transfer barrier expired')
        require(external.read_text() == 'untouched external witness', 'external witness changed')
        current = external.stat()
        require((original.st_dev, original.st_ino, original.st_mtime_ns, original.st_ctime_ns) ==
                (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_ctime_ns), 'external identity changed')
        if dialogs is not None:
            outcomes = [json.loads(line) for line in (root / 'dialog-events.jsonl').read_text().splitlines()]
            require(not any(row.get('event') == 'adapter-failed-before-rescue' for row in outcomes),
                    'an event adapter failure cannot be converted into a passing graphical verdict')
        else:
            for label, *_ in processes:
                trace = root / (label + '.dialogs.log')
                if trace.exists():
                    outcomes = [json.loads(line) for line in trace.read_text().splitlines()]
                    require(not any(row['dialog_error'] or row['event'] == 'fixture-adapter-failed'
                                    for row in outcomes), f'{label} displayed an unexpected fixture error')
        succeeded = True
        print('PASS: real shared-destination GUI/GUI, GUI/CLI, CLI conflicts, transfer/remux cancellation, D relaunch and decoded contents.', flush=True)
    finally:
        # The verdict/evidence is written before any rescue. Never turn rescue
        # into a passing application result or delete uncertain application state.
        try:
            (root / 'events.json').write_text(json.dumps(events, indent=2))
            for entry in processes:
                label, process, obs, _ = entry
                state = obs.sample()
                (root / f'{label}.final-before-rescue.json').write_text(json.dumps(state))
                (root / f'{label}.status.log').write_text(json.dumps(dict(
                    monotonic_ns=time.monotonic_ns(), label=label, parent_status=process.poll(),
                    event='parent-status-before-rescue')) + '\n')
                (root / f'{label}.status.log').chmod(0o600)
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                for pid, row in state['live'].items():
                    current = observer_module.snapshot().get(int(pid))
                    if current and current['start'] == row['start']:
                        try:
                            os.kill(int(pid), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                if process.poll() is None:
                    process.wait(timeout=10)
            for gate in gates.values():
                gate.set()
            server.shutdown(); server.server_close()
            if dialogs is not None:
                dialogs.close()
        finally:
            preserve_fixture_evidence(root, evidence, [entry[0] for entry in processes])
        print('Qualification passed.' if succeeded else 'Qualification FAILED; evidence preserved.', flush=True)


if __name__ == '__main__':
    main()
