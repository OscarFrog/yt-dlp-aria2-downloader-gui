# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/multi-instance-real.py.

Qualify shared-destination GUI/CLI transfers with real media tools and local
barriers. Zenity responses are scripted; this does not qualify desktop gestures.
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


def main():
    root = Path(tempfile.mkdtemp(prefix='shared-destination-real-'))
    print(f'Evidence: {root}', flush=True)
    events = []
    processes = []
    gates = {}
    active = set()
    media = {}
    expected_final = {}
    succeeded = False

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
        zenity.write_text('''#!/usr/bin/python3
import os, sys
args = sys.argv[1:]
if '--version' in args: print('4.2.2')
elif '--entry' in args: print(os.environ['FIXTURE_URL'])
elif '--file-selection' in args: print(os.environ['FIXTURE_OUTPUT'])
elif '--list' in args: print('Complete video (MKV)')
elif '--progress' in args:
    for line in sys.stdin: pass
elif '--question' in args: sys.exit(1)
''')
        zenity.chmod(0o700)
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
                      FIXTURE_OUTPUT=str(output))
        for key in ('YTDLP_ARIA2_YTDLP_BIN', 'YTDLP_ARIA2_DENO_BIN', 'YTDLP_ARIA2_SUPERVISED_SESSION',
                    'YTDLP_ARIA2_SKIP_RUNTIME_UPDATE'):
            shared.pop(key, None)
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
                       YTDLP_QUALIFICATION_TOKEN=token)
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

        def finish(entry, expected_status=0):
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
            if expected_status == 0:
                final = expected_final[process.pid]
                require(final.is_file(), f'{label} did not publish directly in the selected directory')
                require(decoded_hash(final) == expected[index], f'{label} produced the wrong media content')

        def wait_active(entry):
            label, p, obs, _ = entry
            wait_until(lambda: label in active or p.poll() is not None, f'{label} never reached transfer barrier')
            require(p.poll() is None, f'{label} exited before transfer: {root / (label + ".log")}')
            obs.sample()

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
        consumers = [(int(pid), row) for pid, row in live.items()
                     if Path(f'/proc/{pid}/comm').read_text().strip() == 'aria2c']
        require(len(consumers) == 1, 'real aria2 consumer was not observed')
        pid, identity = consumers[0]
        staging = [Path(os.readlink(fd)).parent for fd in Path(f'/proc/{pid}/fd').iterdir()
                   if '/.yt-dlp-aria2.' in os.readlink(fd) and os.readlink(fd).endswith('.download')]
        require(staging, 'aria2 did not retain an open staging media descriptor')
        os.kill(pid, signal.SIGSTOP)
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
        os.kill(pid, signal.SIGCONT)
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
        lock_root = Path(subprocess.check_output(['python3', str(PROJECT / 'private-aria2-plan.py'),
                                                  'private-root', '--no-runtime'], env=shared, text=True).strip())
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
        info = output.stat()
        bucket = lock_root / ('resources-' + hashlib.sha256(str((info.st_dev, info.st_ino)).encode()).hexdigest())
        records = list(bucket.glob('*.resume.json'))
        require(records and all(not json.loads(path.read_text())['active'] for path in records),
                'completed cycles accumulated an active reservation')
        require(not any(event[2] == 'barrier-timeout' for event in events), 'a transfer barrier expired')
        require(external.read_text() == 'untouched external witness', 'external witness changed')
        current = external.stat()
        require((original.st_dev, original.st_ino, original.st_mtime_ns, original.st_ctime_ns) ==
                (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_ctime_ns), 'external identity changed')
        succeeded = True
        print('PASS: real shared-destination GUI/GUI, GUI/CLI, CLI conflicts, transfer/remux cancellation, D relaunch and decoded contents.', flush=True)
    finally:
        # The verdict/evidence is written before any rescue. Never turn rescue
        # into a passing application result or delete uncertain application state.
        (root / 'events.json').write_text(json.dumps(events, indent=2))
        for entry in processes:
            label, process, obs, _ = entry
            state = obs.sample()
            (root / f'{label}.final-before-rescue.json').write_text(json.dumps(state))
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
        print('Qualification passed.' if succeeded else 'Qualification FAILED; evidence preserved.', flush=True)


if __name__ == '__main__':
    main()
