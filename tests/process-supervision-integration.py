# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-supervision-integration.py.

Independent process observation and deterministic session/timeout regressions.
Rescue happens only after assertions; test subreaping is not application reaping.
"""

import ctypes
from contextlib import ExitStack, contextmanager
import importlib.util
import inspect
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('observer', PROJECT / 'tests/process-observer.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


@contextmanager
def denied_procfs_enumeration(error):
    """Deny the OS boundary, including pathlib's cached Python 3.10 accessor."""
    with ExitStack() as stack:
        for owner in (os, getattr(Path, '_accessor', None)):
            for name in ('scandir', 'listdir'):
                original = getattr(owner, name, None)
                if original is None:
                    continue

                def denied(path, original=original):
                    if os.fspath(path) == '/proc':
                        raise error
                    return original(path)

                stack.enter_context(mock.patch.object(owner, name, side_effect=denied))
        yield


class DisplayReadinessTests(unittest.TestCase):
    @staticmethod
    def helper():
        module_spec = importlib.util.spec_from_file_location(
            'zenity_events', PROJECT / 'tests/zenity-x11-events.py')
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        return module

    def check_fragmented_frame(self, read_number):
        import threading
        reader, writer = os.pipe()
        continuation = threading.Event()
        first_read = threading.Event()
        received = bytearray()
        writer_errors = []
        real_read, real_select = os.read, select.select

        def produce():
            try:
                os.write(writer, b'17')
                if not continuation.wait(3):
                    raise AssertionError('reader never requested the display terminator')
                os.write(writer, b'\n')
            except BaseException as error:
                writer_errors.append(error)

        def observe_read(fd, size):
            data = real_read(fd, size)
            if fd == reader:
                received.extend(data)
                if received == b'17':
                    first_read.set()
            return data

        def observe_select(readers, writers, exceptional, timeout=None):
            if reader in readers and first_read.is_set():
                continuation.set()
            return real_select(readers, writers, exceptional, timeout)

        producer = threading.Thread(target=produce)
        producer.start()
        try:
            with mock.patch.object(os, 'read', side_effect=observe_read), \
                    mock.patch.object(select, 'select', side_effect=observe_select):
                self.assertEqual(read_number(reader), b'17')
            self.assertTrue(continuation.is_set(),
                            'display number accepted before its newline was received')
            producer.join(3)
            self.assertFalse(producer.is_alive(), 'display producer did not finish')
            self.assertEqual(writer_errors, [])
        finally:
            os.close(reader)
            continuation.set()
            producer.join(3)
            os.close(writer)

    def test_display_number_waits_for_the_complete_frame(self):
        self.check_fragmented_frame(self.helper().read_display_number)

        def premature_read(fd):
            select.select([fd], [], [], 10)
            return os.read(fd, 32).strip()

        with self.assertRaisesRegex(AssertionError, 'accepted before its newline'):
            self.check_fragmented_frame(premature_read)

    def test_display_number_rejects_incomplete_and_invalid_frames(self):
        read_number = self.helper().read_display_number
        for payload in (b'', b'17', b'not-a-number\n', b'1' * 33 + b'\n'):
            with self.subTest(payload=payload):
                reader, writer = os.pipe()
                try:
                    os.write(writer, payload)
                    os.close(writer)
                    writer = None
                    with self.assertRaises(RuntimeError):
                        read_number(reader)
                finally:
                    os.close(reader)
                    if writer is not None:
                        os.close(writer)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='process-contract-')
        self.root = Path(self.temp.name)
        self.token = os.urandom(24).hex()
        self.observer = observer.Observer(self.token)
        self.processes = []
        ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)

    def tearDown(self):
        # Capture the production verdict before test-only intervention.
        state = self.observer.sample()
        # Rescue is independent of the oracle being mutation-tested. Select
        # only this fixture's exact inherited marker, then revalidate identity.
        rescue = dict(state['live'])
        for pid, row in observer.snapshot().items():
            try:
                marked = self.observer.marker in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
            except OSError:
                marked = False
            if marked:
                rescue[str(pid)] = row
        for pid, row in rescue.items():
            current = observer.snapshot().get(int(pid))
            if current and current['start'] == row['start']:
                try:
                    os.kill(int(pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    time.sleep(.02)
            except ChildProcessError:
                break
        self.temp.cleanup()

    def launch(self, argv):
        p = subprocess.Popen(argv, env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.processes.append(p)
        return p

    def wait_file(self, name, process):
        path = self.root / name
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_size:
                return path.read_text()
            if process.poll() is not None:
                self.fail(f'fixture exited before {name}: {process.communicate()}')
            time.sleep(.01)
        self.fail(f'fixture did not publish {name}')

    def finish(self, process, timeout=8):
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            # Test-only reaper service: zombies have already stopped; this
            # neither signals live processes nor claims application wait status.
            # Only our own adopted children can be harvested here. A global
            # procfs inventory adds unrelated races without reaping authority.
            owned = set()
            for task in Path(f'/proc/{os.getpid()}/task').iterdir():
                owned.update(map(int, (task / 'children').read_text().split()))
            registered = {pid for pid, _ in self.observer.known}
            tracked = {p.pid for p in self.processes}
            for pid in (owned & registered) - tracked:
                try:
                    row = observer.process_row(Path(f'/proc/{pid}/stat'))
                except FileNotFoundError:
                    continue
                if ((pid, row['start']) not in self.observer.known
                        or row['parent'] != os.getpid() or row['state'] != 'Z'):
                    continue
                # A zombie leader can still have live sibling threads. Our
                # unreaped direct child pins its identity through this wait.
                ended = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if ended is not None:
                    os.waitpid(pid, os.WNOHANG)
            time.sleep(.02)
        return process.communicate(timeout=max(.1, deadline - time.monotonic()))

    def child(self, *, resistant=False, slow=False, new_group=False):
        script = self.root / 'consumer.py'
        script.write_text('''import os, signal, time
from pathlib import Path
root = Path(__file__).parent
''' + ('os.setpgid(0, 0)\n' if new_group else '') + '''
fd = os.open(root / 'resource', os.O_RDWR | os.O_CREAT, 0o600)
def stop(number, frame):
    if (root / 'term').exists():
        return
    (root / 'term').write_text(str(time.monotonic_ns()))
''' + ('''    time.sleep(.4)
    if not (root / 'resource').exists():
        (root / 'early-cleanup').write_text('resource missing while consumer alive')
    (root / 'last-access').write_text(str(time.monotonic_ns()))
    raise SystemExit(0)
''' if slow else ('' if resistant else '    raise SystemExit(0)\n')) + '''signal.signal(signal.SIGTERM, stop)
(root / 'ready').write_text(str(os.getpid()))
while True:
    time.sleep(.02)
''')
        return script

    def supervisor_module(self):
        spec = importlib.util.spec_from_file_location(
            'process_supervisor', PROJECT / 'private-process-supervisor.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def thread_fixture(self):
        script = self.root / 'thread-consumer.py'
        script.write_text(r'''import ctypes, os, select, signal, sys, threading, time
from pathlib import Path
root = Path(sys.argv[1])
release = int(sys.argv[2])
if sys.argv[3] == 'orphan' and os.fork():
    os._exit(23)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
def worker():
    deadline = time.monotonic() + 3
    while Path('/proc/self/stat').read_text().rsplit(') ', 1)[1].split()[0] != 'Z':
        if time.monotonic() >= deadline: os._exit(90)
        time.sleep(.001)
    fd = os.open(root / 'thread-resource', os.O_WRONLY | os.O_CREAT, 0o600)
    (root / 'thread-ready').write_text(str(os.getpid()))
    if select.select([release], [], [], 3)[0]: os.read(release, 1)
    os.write(fd, b'access after barrier')
    os.close(fd)
    (root / 'thread-last-access').write_text(str(time.monotonic_ns()))
    os._exit(0)
threading.Thread(target=worker).start()
ctypes.CDLL(None).pthread_exit(None)
''')
        return script

    def test_timed_supervisor_retains_zombie_leader_live_thread(self):
        module = self.supervisor_module()
        script = self.thread_fixture()
        supervisor = PROJECT / 'private-process-supervisor.py'
        premature = self.root / 'premature-supervisor.py'
        source = supervisor.read_text()
        self.assertEqual(source.count('            delivery = signal.SIGKILL\n'), 1)
        premature.write_text(source.replace('            delivery = signal.SIGKILL\n',
                                             '            return 137\n'))
        cases = ((False, False, False), (True, False, False),
                 (False, True, False), (True, True, False), (False, True, True))
        for orphan, expire, mutant in cases:
            with self.subTest(orphan=orphan, expire=expire, premature_return=mutant):
                for name in ('thread-ready', 'thread-last-access'):
                    (self.root / name).unlink(missing_ok=True)
                read_end, write_end = os.pipe()
                process = subprocess.Popen(
                    [sys.executable, '-I', '-B', str(premature if mutant else supervisor),
                     '--timeout', '.3' if expire else '5', '--grace', '.1', '--',
                     sys.executable, '-I', '-B', str(script), str(self.root),
                     str(read_end), 'orphan' if orphan else 'direct'],
                    pass_fds=(read_end,), start_new_session=True,
                    env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.processes.append(process)
                os.close(read_end)
                descriptor = None
                try:
                    consumer = int(self.wait_file('thread-ready', process))
                    fields = Path(f'/proc/{consumer}/stat').read_text().rsplit(') ', 1)[1].split()
                    descriptor = os.pidfd_open(consumer)
                    current = Path(f'/proc/{consumer}/stat').read_text().rsplit(') ', 1)[1].split()
                    self.assertEqual((current[19], current[3]), (fields[19], fields[3]))
                    self.assertEqual(fields[0], 'Z')
                    readiness = select.poll()
                    readiness.register(descriptor, select.POLLIN)
                    self.assertEqual(readiness.poll(0), [], 'consumer stopped before its barrier')
                    self.assertTrue(module.session_alive(int(fields[3])))
                    time.sleep(.08)
                    self.assertIsNone(process.poll(), 'returned while sibling thread still owned its FD')
                    self.assertFalse((self.root / 'thread-last-access').exists())
                    if not expire:
                        os.write(write_end, b'R')
                    # Wait for the helper alone. communicate() first could hide
                    # an early return by waiting for its consumer's pipe EOF.
                    result = process.wait(timeout=5)
                    stop_events = readiness.poll(0)

                    def assert_stopped():
                        self.assertEqual(len(stop_events), 1,
                                         'supervisor returned while its consumer remained live')
                        fd, mask = stop_events[0]
                        self.assertEqual(fd, descriptor)
                        self.assertTrue(mask & select.POLLIN, stop_events)
                        self.assertFalse(mask & (select.POLLERR | select.POLLNVAL), stop_events)

                    if mutant:
                        # The negative verdict precedes rescue and draining the
                        # inherited pipe. No fixture reaping proves program exit.
                        with self.assertRaisesRegex(self.failureException, 'consumer remained live'):
                            assert_stopped()
                        self.assertFalse((self.root / 'thread-last-access').exists())
                        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                        os.waitpid(consumer, 0)
                    else:
                        assert_stopped()
                    out, err = process.communicate(timeout=5)
                    self.assertEqual(result, 137 if expire else (23 if orphan else 0), (out, err))
                    self.assertEqual((self.root / 'thread-last-access').exists(), not expire)
                finally:
                    if descriptor is not None:
                        os.close(descriptor)
                    os.close(write_end)

    def test_stale_foreign_proc_stat_remains_unknown_after_exit(self):
        module = self.supervisor_module()
        process = self.launch([sys.executable, '-I', '-B', '-c',
                               'import time; time.sleep(3)'])
        path = Path(f'/proc/{process.pid}/stat')
        # Opening before exit and reading after reap produces a real kernel
        # ESRCH, distinct from FileNotFoundError at open. No target-SID consumer
        # is involved; the conservative predicate still must report unknown.
        with path.open() as held:
            process.terminate()
            process.wait(timeout=3)
            with self.assertRaises(ProcessLookupError):
                held.read()
            with mock.patch.object(module, 'process_paths', return_value=[path]), \
                    mock.patch.object(Path, 'read_text', side_effect=lambda: held.read()):
                self.assertTrue(module.session_alive(-1))

    def test_observer_revalidates_proc_stat_after_esrch(self):
        import errno

        departed = self.launch([sys.executable, '-I', '-B', '-c',
                                'import time; time.sleep(3)'])
        departed_path = Path(f'/proc/{departed.pid}/stat')
        live = self.launch([sys.executable, '-I', '-B', '-c',
                           'import time; time.sleep(30)'])
        live_path = Path(f'/proc/{live.pid}/stat')
        original_identity = observer.process_row(departed_path)['start']
        live_identity = observer.process_row(live_path)['start']
        real_read = Path.read_text
        real_iterdir = Path.iterdir

        def participant_inventory(path):
            if path == Path('/proc'):
                return iter((Path(f'/proc/{os.getpid()}'), departed_path.parent, live_path.parent))
            return real_iterdir(path)

        with departed_path.open() as held:
            departed.terminate()
            self.assertEqual(departed.wait(timeout=3), -signal.SIGTERM)
            with self.assertRaises(ProcessLookupError) as disappeared:
                held.read()
            self.assertEqual(disappeared.exception.errno, errno.ESRCH)
            reads = []

            def stale_once(path, *args, **kwargs):
                if path == departed_path:
                    reads.append(path)
                    if len(reads) == 1:
                        return held.read()
                return real_read(path, *args, **kwargs)

            with mock.patch.object(Path, 'iterdir', participant_inventory), \
                    mock.patch.object(Path, 'read_text', stale_once):
                rows = observer.snapshot()
            self.assertEqual(len(reads), 2, 'stale stat was not revalidated exactly once')
            if departed.pid in rows:
                self.assertNotEqual(rows[departed.pid]['start'], original_identity,
                                    'departed identity was reported as live')
            self.assertIn(live.pid, rows, 'live participant lost after unrelated disappearance')

        # A transient read error cannot silently discard a still-live worker.
        # Repeated errors must retain the observation failure, not become EOF.
        for second_error in (None, ProcessLookupError(errno.ESRCH, 'still unknown'),
                             PermissionError(errno.EACCES, 'denied'), OSError(errno.EIO, 'unreadable')):
            with self.subTest(second_error=type(second_error).__name__):
                reads = []

                def live_read(path, *args, **kwargs):
                    if path == live_path:
                        reads.append(path)
                        if len(reads) == 1:
                            raise ProcessLookupError(errno.ESRCH, 'controlled transient read')
                        if second_error is not None:
                            raise second_error
                    return real_read(path, *args, **kwargs)

                with mock.patch.object(Path, 'iterdir', participant_inventory), \
                        mock.patch.object(Path, 'read_text', live_read):
                    if second_error is None:
                        rows = observer.snapshot()
                        self.assertEqual(rows[live.pid]['start'], live_identity,
                                         'revalidated live identity was lost')
                    else:
                        with self.assertRaises(type(second_error)) as refusal:
                            observer.snapshot()
                        self.assertIs(refusal.exception, second_error)
                self.assertEqual(len(reads), 2, 'observer retry was not bounded')

    def test_finish_reaps_only_revalidated_known_children(self):
        gates = set()

        def orphan(marked):
            read_end, write_end = os.pipe()
            gates.add(write_end)
            environment = dict(os.environ)
            environment.pop('YTDLP_QUALIFICATION_TOKEN', None)
            if marked:
                environment['YTDLP_QUALIFICATION_TOKEN'] = self.token
            launcher = subprocess.Popen(
                [sys.executable, '-I', '-B', '-c', '''import os,sys
child = os.fork()
if child:
    print(child, flush=True)
    os._exit(23)
os.read(int(sys.argv[1]), 1)
os._exit(7)
''', str(read_end)], pass_fds=(read_end,), start_new_session=True,
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.processes.append(launcher)
            os.close(read_end)
            self.assertTrue(select.select([launcher.stdout], [], [], 3)[0])
            pid = int(launcher.stdout.readline())
            self.assertEqual(launcher.wait(timeout=3), 23)
            return pid

        try:
            known = orphan(True)
            unrelated = orphan(False)
            sample = self.observer.sample()
            self.assertIn(str(known), sample['live'])
            self.assertNotIn(str(unrelated), sample['live'])
            unrelated_row = observer.process_row(Path(f'/proc/{unrelated}/stat'))
            # A numeric PID in the registry is insufficient: this deliberately
            # stale identity must not grant permission to harvest its status.
            self.observer.known.add((unrelated, unrelated_row['start'] + 1))
            for fd in tuple(gates):
                os.close(fd)
                gates.remove(fd)
            for pid in (known, unrelated):
                deadline = time.monotonic() + 3
                while os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                    self.assertLess(time.monotonic(), deadline, 'orphan failed to exit')
                    time.sleep(.005)

            managed = self.launch([sys.executable, '-I', '-B', '-c', 'raise SystemExit(31)'])
            managed_row = observer.process_row(Path(f'/proc/{managed.pid}/stat'))
            self.observer.known.add((managed.pid, managed_row['start']))
            deadline = time.monotonic() + 3
            while os.waitid(os.P_PID, managed.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                self.assertLess(time.monotonic(), deadline, 'managed child failed to exit')
                time.sleep(.005)
            waiter = self.launch([sys.executable, '-I', '-B', '-c', '''import sys,time
from pathlib import Path
deadline = time.monotonic() + 3
while Path('/proc/' + sys.argv[1]).exists():
    if time.monotonic() >= deadline: sys.exit(91)
    time.sleep(.005)
''', str(known)])
            real_read = Path.read_text

            def denied_known(path, *args, **kwargs):
                if path == Path(f'/proc/{known}/stat'):
                    raise PermissionError('known child stat denied')
                return real_read(path, *args, **kwargs)

            with mock.patch.object(Path, 'read_text', new=denied_known):
                with self.assertRaisesRegex(PermissionError, 'known child stat denied'):
                    self.finish(waiter)
            self.assertIsNotNone(os.waitid(os.P_PID, known, os.WEXITED | os.WNOHANG | os.WNOWAIT))

            foreign = self.launch([sys.executable, '-I', '-B', '-c', 'pass'])
            foreign_path = Path(f'/proc/{foreign.pid}/stat')
            real_iterdir = Path.iterdir
            stale_reads = 0
            with foreign_path.open() as held:
                self.assertEqual(foreign.wait(timeout=3), 0)

                def ambient_inventory(path):
                    entries = list(real_iterdir(path))
                    if path == Path('/proc'):
                        entries.insert(0, foreign_path.parent)
                    return iter(entries)

                def stale_stat(path, *args, **kwargs):
                    nonlocal stale_reads
                    if path == foreign_path:
                        stale_reads += 1
                        return held.read()
                    return real_read(path, *args, **kwargs)

                with mock.patch.object(Path, 'iterdir', new=ambient_inventory), \
                        mock.patch.object(Path, 'read_text', new=stale_stat):
                    # This is the former finish() enumeration, with a real
                    # open-before-exit/read-after-reap kernel ESRCH. No rescue.
                    with self.assertRaises(ProcessLookupError) as error:
                        observer.snapshot()
                    self.assertEqual(error.exception.errno, 3)
                    self.assertEqual(stale_reads, 2, 'snapshot retry was not bounded')
                    self.assertIsNotNone(os.waitid(os.P_PID, known, os.WEXITED | os.WNOHANG | os.WNOWAIT))
                    out, err = self.finish(waiter)
                    self.assertEqual(stale_reads, 2, 'finish inspected an unrelated process')
            self.assertEqual(waiter.returncode, 0, (out, err))
            self.assertEqual(managed.wait(timeout=3), 31, 'finish stole the managed Popen status')
            with self.assertRaises(ChildProcessError):
                os.waitid(os.P_PID, known, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            witness = os.waitid(os.P_PID, unrelated, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            self.assertIsNotNone(witness, 'finish stole an unrelated child status')
            self.assertEqual(witness.si_status, 7)
            # Harvest this deliberately excluded witness only after the verdict.
            self.assertEqual(os.waitpid(unrelated, 0)[1], 7 << 8)
        finally:
            for fd in gates:
                os.close(fd)

    def test_observer_detects_orphan_zombie_leader_live_thread(self):
        script = self.thread_fixture()
        read_end, write_end = os.pipe()
        unmarked_environment = dict(os.environ)
        unmarked_environment.pop('YTDLP_QUALIFICATION_TOKEN', None)
        unmarked_environment.pop('YTDLP_QUALIFICATION_EXTERNAL', None)
        unrelated = subprocess.Popen(
            [sys.executable, '-I', '-B', '-c',
             'import os,select,sys; fd=int(sys.argv[1]); select.select([fd],[],[],3); os.read(fd,1)',
             str(read_end), 'https://unrelated.invalid/observer-witness'],
            pass_fds=(read_end,), env=unmarked_environment, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        process = subprocess.Popen(
            [sys.executable, '-I', '-B', str(script), str(self.root), str(read_end),
             'orphan', 'https://fixture.invalid/thread-observer'],
            pass_fds=(read_end,), start_new_session=True,
            env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.extend((unrelated, process))
        os.close(read_end)
        try:
            self.assertEqual(process.wait(timeout=3), 23)
            self.assertFalse(Path(f'/proc/{process.pid}').exists())
            deadline = time.monotonic() + 2
            while not (self.root / 'thread-ready').exists():
                self.assertLess(time.monotonic(), deadline, 'thread readiness missing')
                time.sleep(.005)
            consumer = int((self.root / 'thread-ready').read_text())
            row = observer.process_row(Path(f'/proc/{consumer}/stat'))
            self.assertEqual(row['state'], 'Z')
            states = [observer.process_row(task / 'stat')['state']
                      for task in Path(f'/proc/{consumer}/task').iterdir()]
            self.assertTrue(any(state not in ('Z', 'X') for state in states))
            self.assertIsNone(os.waitid(os.P_PID, consumer, os.WEXITED | os.WNOHANG | os.WNOWAIT))

            def verdict(sample):
                self.assertIn(str(consumer), sample['live'], 'observer lost a live sibling thread')
                self.assertNotIn(consumer, sample['zombies'])
                self.assertIn((consumer, row['start']), sample['url_in_argv'])
                self.assertNotIn(str(unrelated.pid), sample['live'])
                self.assertFalse(any(pid == unrelated.pid for pid, _ in sample['url_in_argv']))
                self.assertIsNone(unrelated.poll(), 'observer changed an unrelated same-user process')
                self.assertFalse((self.root / 'thread-last-access').exists(), 'fixture barrier already released')

            # No observation of the launcher, or manually seeded PID identity:
            # discovery must still come from the exact inherited launch token.
            fresh = observer.Observer(self.token)
            verdict(fresh.sample())
            with mock.patch.object(observer, 'threads_are_quiescent',
                                   side_effect=lambda _pid, observed: observed['state'] in ('Z', 'X')):
                # Restore precisely the former classification, keeping token
                # discovery intact so rejection is about the live sibling.
                with self.assertRaisesRegex(self.failureException, 'observer lost a live sibling thread'):
                    verdict(observer.Observer(self.token).sample())

            verdict(fresh.sample())
            # All positive/negative verdicts precede release and test harvesting.
            os.close(write_end)
            write_end = None
            deadline = time.monotonic() + 2
            while os.waitid(os.P_PID, consumer, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                self.assertLess(time.monotonic(), deadline, 'consumer failed to exit after release')
                time.sleep(.005)
            stopped = fresh.sample()
            self.assertNotIn(str(consumer), stopped['live'])
            self.assertIn(consumer, stopped['zombies'])
            self.assertTrue((self.root / 'thread-last-access').exists())
            self.assertEqual(os.waitpid(consumer, 0)[1], 0)
            unrelated.communicate(timeout=3)
            process.communicate(timeout=3)
            self.assertEqual(unrelated.returncode, 0)
        finally:
            if write_end is not None:
                os.close(write_end)

    def test_observer_rejects_incomplete_procfs_inventory(self):
        for error in (PermissionError('procfs root denied'),
                      FileNotFoundError('procfs root missing'), OSError('procfs root I/O error')):
            with self.subTest(error=type(error).__name__), \
                    denied_procfs_enumeration(error):
                with self.assertRaisesRegex(OSError, 'procfs root'):
                    self.observer.sample()
        with mock.patch.object(Path, 'iterdir', return_value=iter(())):
            with self.assertRaisesRegex(OSError, 'observer is absent'):
                self.observer.sample()
        own_stat = Path(f'/proc/{os.getpid()}/stat')
        original_read = Path.read_text

        def missing_own_stat(path, *args, **kwargs):
            if path == own_stat:
                raise FileNotFoundError('observer stat missing')
            return original_read(path, *args, **kwargs)

        with mock.patch.object(Path, 'read_text', new=missing_own_stat):
            with self.assertRaisesRegex(OSError, 'observer stat is absent'):
                self.observer.sample()

    def test_observer_unreadable_stat_cannot_erase_known_identity(self):
        child = self.child()
        child.write_text(child.read_text().replace('while True:', "while not (root / 'release').exists():"))
        process = self.launch([sys.executable, '-I', '-B', str(child)])
        self.wait_file('ready', process)
        first = self.observer.sample()
        row = first['live'][str(process.pid)]
        key = (process.pid, row['start'])
        self.assertIn(key, self.observer.known)
        original_read = Path.read_text
        for failure in (PermissionError, OSError, IndexError):
            def unreadable(path, *args, **kwargs):
                if path == Path(f'/proc/{process.pid}/stat'):
                    if failure is IndexError:
                        return 'malformed proc stat'
                    raise failure('attributed stat unavailable')
                return original_read(path, *args, **kwargs)

            with self.subTest(error=failure.__name__), \
                    mock.patch.object(Path, 'read_text', new=unreadable):
                with self.assertRaises(failure):
                    self.observer.sample()
                # Even a first sample may not drop an unreadable process merely
                # because its inherited marker could not yet be inspected.
                with self.assertRaises(failure):
                    observer.Observer(self.token).sample()
                self.assertIn(key, self.observer.known)
            self.assertIsNone(process.poll(), 'observer interfered with the fixture')
            self.assertIn(str(process.pid), self.observer.sample()['live'])
        # A genuinely disappeared process is different from an unreadable one.
        (self.root / 'release').touch()
        process.communicate(timeout=3)
        self.assertEqual(process.returncode, 0)
        original_iterdir = Path.iterdir

        def stale_enumeration(path):
            entries = list(original_iterdir(path))
            if path == Path('/proc'):
                entries.append(Path(f'/proc/{process.pid}'))
            return iter(entries)

        with mock.patch.object(Path, 'iterdir', new=stale_enumeration):
            self.assertNotIn(str(process.pid), self.observer.sample()['live'])

    def test_observer_procfs_denial_rejects_stale_success_in_zenity_harness(self):
        (self.root / 'processes-current.json').write_text(json.dumps({'live': {}, 'url_in_argv': []}))
        wrapper = self.root / 'denied-observer.py'
        wrapper.write_text('''import os, runpy, sys
from contextlib import ExitStack, contextmanager
from pathlib import Path
from unittest import mock
''' + inspect.getsource(denied_procfs_enumeration) + '''
with denied_procfs_enumeration(PermissionError('procfs root denied')):
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name='__main__')
''')
        harness = self.root / 'harness-functions.sh'
        harness.write_text((PROJECT / 'tests/zenity-real-session-qualification.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        verdict = subprocess.run(['bash', '-c', '''source "$1"
"$3" -I -B "$2/denied-observer.py" "$4" "$5" "$2" "$2/stop" &
WATCHER_PID=$!
assert_no_residual_processes "$2" "$2/stop"
''', 'bash', str(harness), str(self.root), sys.executable,
                                  str(PROJECT / 'tests/process-observer.py'), self.token],
                                 capture_output=True, timeout=5)
        self.assertEqual(verdict.returncode, 1, 'Zenity harness accepted an incomplete observer inventory')
        self.assertIn(b'PermissionError: procfs root denied', verdict.stderr)
        self.assertNotIn(b'surviving qualification descendants', verdict.stderr)

    def test_engine_gui_detect_and_retire_zombie_main_thread(self):
        script = self.thread_fixture()
        real_iterdir, real_read = Path.iterdir, Path.read_text
        real_send = signal.pidfd_send_signal
        for filename, code in self.escalation_sources():
            guard = "        if identity() in ('Z', 'X') and process_quiescent(pid, expected_start):\n"
            self.assertEqual(code.count(guard), 1)
            mutant = code.replace(guard, "        if identity() in ('Z', 'X'):\n", 1)
            for label, source_code in (('correct', code), ('leader-only', mutant),
                                       ('foreign-esrch', code)):
                with self.subTest(target=filename, case=label):
                    # A failed predecessor may still finish its last access
                    # after its release pipe closes. Never reuse its paths.
                    case_root = self.root / f'{filename}-{label}'
                    case_root.mkdir()
                    read_end, write_end = os.pipe()
                    process = subprocess.Popen(
                        [sys.executable, '-I', '-B', str(script), str(case_root), str(read_end), 'direct'],
                        pass_fds=(read_end,), start_new_session=True,
                        env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token,
                                 YTDLP_ARIA2_GUI_WORKER_TOKEN=self.token),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.processes.append(process)
                    os.close(read_end)
                    descriptor = foreign = foreign_write = None
                    deliveries = []
                    foreign_race = False
                    try:
                        consumer = int(self.wait_file(
                            f'{case_root.name}/thread-ready', process))
                        fields = real_read(Path(f'/proc/{consumer}/stat')).rsplit(') ', 1)[1].split()
                        self.assertEqual(consumer, process.pid)
                        self.assertEqual(fields[0], 'Z')
                        descriptor = os.pidfd_open(consumer)
                        current = real_read(Path(f'/proc/{consumer}/stat')).rsplit(') ', 1)[1].split()
                        self.assertEqual((current[19], current[3]), (fields[19], fields[3]))
                        self.assertEqual(select.select([descriptor], [], [], 0)[0], [])
                        self.assertFalse((case_root / 'thread-last-access').exists())

                        def live_pipe():
                            live = []
                            for task in real_iterdir(Path(f'/proc/{consumer}/task')):
                                row = real_read(task / 'stat').rsplit(') ', 1)[1].split()
                                self.assertEqual(real_read(task / 'children').strip(), '',
                                                 'thread fixture unexpectedly forked')
                                if row[0] not in ('Z', 'X'):
                                    live.append(task)
                            self.assertTrue(live, 'fixture has no surviving sibling thread')
                            held = (live[0] / 'fd' / str(read_end)).stat()
                            release = os.fstat(write_end)
                            self.assertEqual((held.st_dev, held.st_ino),
                                             (release.st_dev, release.st_ino))

                        live_pipe()
                        source = (PROJECT / filename).read_text()
                        start = source.index('process_threads_are_quiescent() {')
                        name = ('download_group_has_live_member' if filename == 'download-video.sh'
                                else 'worker_group_has_live_member')
                        end = source.index('\n}\n', source.index(name + '() {')) + 3
                        setup = (f'DOWNLOAD_SESSION_ID={consumer}; DOWNLOAD_WORKER_PGID={consumer}\n'
                                 if filename == 'download-video.sh' else f'WORKER_PGID={consumer}\n')
                        result = subprocess.run(['bash', '-c', source[start:end] + '\n' + setup + name],
                                                capture_output=True, timeout=3)
                        self.assertEqual(result.returncode, 0, result.stderr)

                        if label == 'foreign-esrch':
                            foreign_read, foreign_write = os.pipe()
                            try:
                                foreign = subprocess.Popen(
                                    [sys.executable, '-I', '-B', '-c',
                                     'import os,sys; os.read(int(sys.argv[1]),1)', str(foreign_read)],
                                    pass_fds=(foreign_read,), start_new_session=True,
                                    env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                                self.processes.append(foreign)
                            finally:
                                os.close(foreign_read)
                            foreign_fields = real_read(Path(f'/proc/{foreign.pid}/stat')).rsplit(') ', 1)[1].split()
                            self.assertNotEqual(foreign_fields[3], fields[3])

                        def inventory(path):
                            if path != Path('/proc'):
                                return real_iterdir(path)
                            # Only the root inventory is bounded. This real
                            # fixture never forks; every task/child read remains
                            # real and must prove that the participant set is complete.
                            for task in real_iterdir(Path(f'/proc/{consumer}/task')):
                                self.assertEqual(real_read(task / 'children').strip(), '',
                                                 'fixture inventory omitted a child')
                            pids = [os.getpid(), consumer]
                            if foreign is not None:
                                pids.insert(0, foreign.pid)
                            return iter(Path(f'/proc/{pid}') for pid in pids)

                        def read(path, *args, **kwargs):
                            nonlocal foreign_write, foreign_race
                            if foreign is not None and path == Path(f'/proc/{foreign.pid}/stat'):
                                # A held stat fails with real ESRCH after reaping;
                                # production must retain its uncertainty veto.
                                with path.open() as held:
                                    os.close(foreign_write)
                                    foreign_write = None
                                    self.assertEqual(foreign.wait(timeout=3), 0)
                                    try:
                                        held.read()
                                    except ProcessLookupError as error:
                                        self.assertEqual(error.errno, 3)
                                        foreign_race = True
                                        raise
                                    self.fail('held foreign stat did not produce real ESRCH')
                            return real_read(path, *args, **kwargs)

                        def send(fd, number, *args):
                            real_send(fd, number, *args)
                            deliveries.append(number)

                        status = 0
                        with mock.patch.object(Path, 'iterdir', inventory), \
                                mock.patch.object(Path, 'read_text', read), \
                                mock.patch.object(signal, 'pidfd_send_signal', send), \
                                mock.patch.object(sys, 'argv', ['probe', str(consumer), fields[19], fields[3]]):
                            try:
                                exec(compile(source_code, filename, 'exec'), {})
                            except SystemExit as error:
                                status = error.code
                        # Observe actual kernel termination before wait/drain or
                        # release. Only a delivered KILL can need completion time;
                        # the leader-only mutant must fail immediately while its
                        # live thread still owns the barrier descriptor.
                        stopped = select.select(
                            [descriptor], [], [], 3 if signal.SIGKILL in deliveries else 0)[0]

                        def require_retired():
                            self.assertEqual(stopped, [descriptor],
                                             'retirement returned with a live zombie sibling')

                        if label == 'correct':
                            self.assertEqual(status, 0)
                            require_retired()
                            self.assertEqual(process.wait(timeout=3), -signal.SIGKILL)
                            self.assertFalse((case_root / 'thread-last-access').exists())
                        else:
                            self.assertEqual(stopped, [])
                            self.assertNotIn(signal.SIGKILL, deliveries)
                            live_pipe()
                            self.assertFalse((case_root / 'thread-last-access').exists())
                            if label == 'leader-only':
                                self.assertEqual(status, 0)
                                self.assertEqual(deliveries, [])
                                with self.assertRaisesRegex(self.failureException, 'live zombie sibling'):
                                    require_retired()
                            else:
                                self.assertEqual(status, 1)
                                self.assertTrue(foreign_race)
                                self.assertIn(signal.SIGSTOP, deliveries)
                                self.assertIn(signal.SIGCONT, deliveries)
                            # Release only after the live-FD and refusal verdicts.
                            # This marker is confined to this subcase's root.
                            os.close(write_end)
                            write_end = None
                            self.assertEqual(process.wait(timeout=3), 0)
                            self.assertTrue((case_root / 'thread-last-access').exists())
                    finally:
                        if write_end is not None:
                            os.close(write_end)
                        if foreign_write is not None:
                            os.close(foreign_write)
                        if descriptor is not None:
                            os.close(descriptor)

    def test_procfs_enumeration_failure_is_unknown(self):
        module = self.supervisor_module()
        namespaces = []
        for filename, code in self.escalation_sources():
            namespace = {}
            exec(compile(code.rsplit('\ntry:\n    retire', 1)[0], filename, 'exec'), namespace)
            namespaces.append(namespace)
        for error in (PermissionError('denied'), FileNotFoundError('missing'), OSError('I/O failure')):
            with self.subTest(error=type(error).__name__), denied_procfs_enumeration(error):
                # An impossible SID would be absent in a successful inventory;
                # failed enumeration must still report uncertainty/presence.
                self.assertTrue(module.session_alive(-1))
                for namespace in namespaces:
                    with self.assertRaises(OSError):
                        namespace['other_session_members_quiescent'](os.getpid(), os.getsid(0))

    def test_error_after_stop_resumes_the_authenticated_parent(self):
        child = self.child()
        for filename, code in self.escalation_sources():
            with self.subTest(target=filename):
                (self.root / 'ready').unlink(missing_ok=True)
                (self.root / 'term').unlink(missing_ok=True)
                process = self.launch([sys.executable, '-I', '-B', str(child)])
                self.wait_file('ready', process)
                fields = Path(f'/proc/{process.pid}/stat').read_text().rsplit(') ', 1)[1].split()
                real_read = Path.read_text
                real_send = signal.pidfd_send_signal
                sent = []

                def read(path, *args, **kwargs):
                    if str(path).startswith(f'/proc/{process.pid}/task/'):
                        raise PermissionError('task observation revoked after STOP')
                    return real_read(path, *args, **kwargs)

                def send(descriptor, number, *args):
                    real_send(descriptor, number, *args)
                    sent.append(number)

                with mock.patch.object(Path, 'read_text', read), \
                        mock.patch.object(signal, 'pidfd_send_signal', send), \
                        mock.patch.object(sys, 'argv', ['probe', str(process.pid), fields[19], fields[3]]):
                    with self.assertRaises(SystemExit) as result:
                        exec(compile(code, filename, 'exec'), {})
                self.assertEqual(result.exception.code, 1)
                self.assertEqual(sent, [signal.SIGSTOP, signal.SIGCONT])
                deadline = time.monotonic() + 1
                while Path(f'/proc/{process.pid}/stat').read_text().rsplit(') ', 1)[1].split()[0] in ('T', 't'):
                    self.assertLess(time.monotonic(), deadline, 'parent was left frozen')
                    time.sleep(.005)
                self.assertIsNone(process.poll())
                self.assertTrue((self.root / 'resource').exists())
                # The production verdict precedes ordinary fixture termination.
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0)

    def test_timed_signal_handle_survives_numeric_pid_reuse(self):
        module = self.supervisor_module()
        path = Path('/proc/42001/stat')
        fields = ['S', '12', '42000', '42000'] + ['0'] * 15 + ['777']
        state = {'reads': 0, 'replacement_signaled': False}

        def read(_path):
            state['reads'] += 1
            return '42001 (fixture) ' + ' '.join(fields)

        def pidfd_send(descriptor, number):
            self.assertEqual((descriptor, number), (900001, signal.SIGKILL))
            # The original exited after the second read. The handle remains
            # attached to that original, rather than its numeric replacement.
            self.assertEqual(state['reads'], 2)
            raise ProcessLookupError('original task exited')

        def numeric_send(_pid, _number):
            state['replacement_signaled'] = True

        with mock.patch.object(module, 'process_paths', return_value=[path]), \
                mock.patch.object(Path, 'read_text', read), \
                mock.patch.object(os, 'pidfd_open', return_value=900001), \
                mock.patch.object(os, 'close') as close, \
                mock.patch.object(signal, 'pidfd_send_signal', pidfd_send), \
                mock.patch.object(os, 'kill', numeric_send):
            module.signal_session(42000, signal.SIGKILL)
            self.assertFalse(state['replacement_signaled'], 'signaled an unrelated recycled PID')
            close.assert_called_once_with(900001)

    def test_capability_refusal_precedes_consumer_launch(self):
        module = self.supervisor_module()
        real_fork = os.fork
        for failure in ('api', 'open', 'send', 'continue', 'waitid', 'procfs'):
            with self.subTest(failure=failure):
                created = []

                def fork():
                    pid = real_fork()
                    if pid:
                        created.append(pid)
                    return pid

                real_send = signal.pidfd_send_signal

                def send(descriptor, number):
                    if failure == 'send' or (failure == 'continue' and number == signal.SIGCONT):
                        raise PermissionError('synthetic pidfd delivery refused')
                    return real_send(descriptor, number)

                with mock.patch.object(os, 'fork', fork), mock.patch.object(signal, 'pidfd_send_signal', send):
                    if failure == 'api':
                        context = mock.patch.object(os, 'pidfd_open')
                    elif failure == 'open':
                        context = mock.patch.object(os, 'pidfd_open', side_effect=PermissionError('denied'))
                    elif failure == 'waitid':
                        context = mock.patch.object(os, 'waitid', side_effect=PermissionError('denied'))
                    elif failure == 'procfs':
                        context = denied_procfs_enumeration(PermissionError('denied'))
                    else:
                        context = mock.patch.object(module, 'time', wraps=time)
                    with context:
                        if failure == 'api':
                            del os.pidfd_open
                        status = module.supervise([sys.executable, '-c',
                            'from pathlib import Path; Path("' + str(self.root / 'unexpected-consumer') + '").touch()'], 1, .1)
                self.assertEqual(status, 69)
                self.assertFalse((self.root / 'unexpected-consumer').exists())
                for pid in created:
                    self.assertFalse(Path(f'/proc/{pid}').exists(), 'capability probe was not reaped')

    def test_waitid_failure_after_admission_keeps_consumer_supervised(self):
        child = self.child(slow=True)
        wrapper = self.root / 'waitid-denied.py'
        wrapper.write_text('''import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('supervisor', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_check = module.check_capabilities
def check():
    real_check()
    def denied(*args): raise PermissionError('waitid revoked after admission')
    os.waitid = denied
module.check_capabilities = check
sys.exit(module.supervise([sys.executable, sys.argv[2]], 5, 1))
''')
        process = self.launch([sys.executable, '-I', '-B', str(wrapper),
                               str(PROJECT / 'private-process-supervisor.py'), str(child)])
        self.wait_file('ready', process)
        process.send_signal(signal.SIGTERM)
        self.wait_file('term', process)
        self.assertIsNone(process.poll())
        out, err = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 143, (out, err))
        self.assertTrue((self.root / 'last-access').exists())
        self.assertFalse((self.root / 'early-cleanup').exists())
        self.assertFalse(self.observer.sample()['live'])

    def test_group_quiescence_rejects_fork_after_enumeration(self):
        program = '''import os, sys
report, trigger, release = map(int, sys.argv[1:])
if os.fork():
    os._exit(23)
os.write(report, ("A " + str(os.getpid()) + "\\n").encode())
os.read(trigger, 1)
if os.fork():
    os._exit(0)
os.write(report, ("B " + str(os.getpid()) + "\\n").encode())
os.read(release, 1)
os._exit(0)
'''

        def fields(pid):
            return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()

        def record(fd, label):
            self.assertTrue(select.select([fd], [], [], 3)[0], f'no {label} readiness record')
            parts = os.read(fd, 100).split()
            self.assertEqual(len(parts), 2, parts)
            self.assertEqual(parts[0], label.encode())
            return int(parts[1])

        def assert_refuses_late_fork(code, filename, expected_inventories, *, session_probe=False):
            report_read, report_write = os.pipe()
            trigger_read, trigger_write = os.pipe()
            release_read, release_write = os.pipe()
            open_fds = {report_read, report_write, trigger_read, trigger_write,
                        release_read, release_write}
            try:
                process = subprocess.Popen(
                    [sys.executable, '-B', '-c', program, str(report_write),
                     str(trigger_read), str(release_read)],
                    env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                    pass_fds=(report_write, trigger_read, release_read),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                self.processes.append(process)
                for fd in (report_write, trigger_read, release_read):
                    os.close(fd)
                    open_fds.remove(fd)
                orphan = record(report_read, 'A')
                if session_probe:
                    # Match the timed helper's unreaped direct-child SID pin.
                    deadline = time.monotonic() + 3
                    while True:
                        leader = os.waitid(os.P_PID, process.pid,
                                           os.WEXITED | os.WNOHANG | os.WNOWAIT)
                        if leader is not None:
                            break
                        self.assertLess(time.monotonic(), deadline, 'leader did not exit')
                        time.sleep(.005)
                    self.assertEqual(leader.si_status, 23)
                else:
                    self.assertEqual(process.wait(timeout=3), 23)
                    self.assertFalse(Path(f'/proc/{process.pid}').exists(), 'leader must be gone')
                real_iterdir = Path.iterdir
                inventories = 0
                late_child = None

                def enumerate_then_fork(path):
                    nonlocal inventories, late_child
                    snapshot = list(real_iterdir(path))
                    if path != Path('/proc'):
                        return iter(snapshot)
                    # This oracle isolates its real, pinned fixture participants.
                    # Unrelated procfs failures have separate conservative-refusal
                    # coverage and must not mask the single-inventory mutant.
                    participants = {str(os.getpid()), str(process.pid), str(orphan), str(late_child)}
                    snapshot = [entry for entry in snapshot if entry.name in participants]
                    inventories += 1
                    if inventories == 1:
                        self.assertIn(Path(f'/proc/{orphan}'), snapshot)
                        # Only scheduling is controlled: freeze real directory
                        # entries, fork, then let production read real stat data.
                        os.write(trigger_write, b'F')
                        late_child = record(report_read, 'B')
                        self.assertNotIn(Path(f'/proc/{late_child}'), snapshot)
                        deadline = time.monotonic() + 3
                        while fields(orphan)[0] != 'Z':
                            self.assertLess(time.monotonic(), deadline, 'orphan did not exit')
                            time.sleep(.005)
                    elif inventories == 2:
                        self.assertIn(Path(f'/proc/{late_child}'), snapshot, 'late child absent from second real inventory')
                    return iter(snapshot)

                with mock.patch.object(Path, 'iterdir', enumerate_then_fork), \
                        mock.patch.object(sys, 'argv', ['probe', str(process.pid)]):
                    if session_probe:
                        namespace = {'__name__': 'supervision_probe'}
                        exec(compile(code, filename, 'exec'), namespace)
                        verdict = int(namespace['session_alive'](process.pid))
                    else:
                        try:
                            exec(compile(code, filename, 'exec'), {})
                        except SystemExit as result:
                            verdict = result.code
                        else:
                            self.fail('production group predicate did not exit')

                self.assertIsNotNone(late_child, 'production never reached the fork barrier')
                self.assertEqual(inventories, expected_inventories)
                zombie = fields(orphan)
                witness = fields(late_child)
                self.assertEqual(zombie[0], 'Z')
                self.assertEqual(int(zombie[1]), os.getpid(), 'test must retain the zombie')
                if session_probe:
                    self.assertEqual(fields(process.pid)[0], 'Z', 'session leader must stay pinned')
                self.assertNotIn(witness[0], ('Z', 'X'))
                self.assertEqual((int(witness[2]), int(witness[3])), (process.pid, process.pid))
                inherited = os.stat(f'/proc/{late_child}/fd/{release_read}')
                held_pipe = os.fstat(release_write)
                self.assertEqual((inherited.st_dev, inherited.st_ino),
                                 (held_pipe.st_dev, held_pipe.st_ino))
                os.kill(-process.pid, 0)
                self.assertNotEqual(verdict, 0, 'group predicate accepted a live late-fork child')
            finally:
                # EOF releases live fixtures only after the safety assertion.
                # tearDown reaps the deliberately retained orphan zombies.
                for fd in open_fds:
                    os.close(fd)

        for filename, marker in (('download-video.sh', 'PY_GROUP_ABSENT'),
                                 ('download-video-gui.sh', 'PY_GUI_GROUP_ABSENT')):
            source = (PROJECT / filename).read_text()
            opening = "<<'" + marker + "'\n"
            self.assertEqual(source.count(opening), 1)
            code = source.split(opening, 1)[1].split('\n' + marker, 1)[0]
            guard = '    repeated = []\n'
            witnesses = '    for path, start in zombies:\n'
            self.assertEqual(code.count(guard), 1)
            self.assertEqual(code.count(witnesses), 1)
            start, end = code.index(guard), code.index(witnesses)
            self.assertLess(start, end)
            mutant = code[:start] + code[end:]
            with self.subTest(target=filename, second_inventory=True):
                assert_refuses_late_fork(code, filename, 2)
            with self.subTest(target=filename, second_inventory=False):
                with self.assertRaisesRegex(self.failureException, 'accepted a live late-fork child'):
                    assert_refuses_late_fork(mutant, filename, 1)

        filename = 'private-process-supervisor.py'
        code = (PROJECT / filename).read_text()
        guard = 'for observation in range(2):'
        self.assertEqual(code.count(guard), 1)
        mutant = code.replace(guard, 'for observation in range(1):', 1)
        with self.subTest(target=filename, second_inventory=True):
            assert_refuses_late_fork(code, filename, 2, session_probe=True)
        with self.subTest(target=filename, second_inventory=False):
            with self.assertRaisesRegex(self.failureException, 'accepted a live late-fork child'):
                assert_refuses_late_fork(mutant, filename, 1, session_probe=True)

    def test_session_presence_refuses_unreadable_foreign_stat(self):
        import errno

        code = (PROJECT / 'private-process-supervisor.py').read_text()
        guard = '                except FileNotFoundError:\n                    continue'
        self.assertEqual(code.count(guard), 1)
        mutant = code.replace(
            guard, '                except (FileNotFoundError, ProcessLookupError):\n                    continue', 1)
        anchor = self.launch([sys.executable, '-B', '-c', 'import os; os._exit(23)'])
        deadline = time.monotonic() + 3
        while os.waitid(os.P_PID, anchor.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            self.assertLess(time.monotonic(), deadline, 'quiet SID anchor did not exit')
            time.sleep(.005)
        anchor_stat = Path(f'/proc/{anchor.pid}/stat')
        foreign_stat = Path(f'/proc/{os.getppid()}/stat')
        real_read_text = Path.read_text
        anchor_row = real_read_text(anchor_stat).rsplit(') ', 1)[1].split()
        foreign_row = real_read_text(foreign_stat).rsplit(') ', 1)[1].split()
        self.assertEqual(anchor_row[0], 'Z')
        self.assertNotEqual(int(foreign_row[3]), anchor.pid, 'foreign witness belongs to the fixture SID')

        def require_conservative_refusal(source, expected_reads):
            namespace = {'__name__': 'supervision_probe'}
            exec(compile(source, 'private-process-supervisor.py', 'exec'), namespace)
            # Both directory entries and the pinned zombie remain real. Fix the
            # view so another procfs refusal cannot mask the error-handling mutant.
            namespace['process_paths'] = lambda: [foreign_stat, anchor_stat]
            deadline = time.monotonic() + 3
            while not namespace['process_quiescent'](str(anchor.pid), anchor_row[19]):
                self.assertLess(time.monotonic(), deadline, 'SID anchor tasks did not become quiescent')
                time.sleep(.005)
            injected = []

            def unreadable(path, *args, **kwargs):
                if path == foreign_stat:
                    injected.append(path)
                    raise ProcessLookupError(errno.ESRCH, 'controlled unrelated procfs disappearance')
                return real_read_text(path, *args, **kwargs)

            with mock.patch.object(Path, 'read_text', unreadable):
                alive = namespace['session_alive'](anchor.pid)
            self.assertEqual(len(injected), expected_reads, 'foreign stat refusal was not exercised')
            self.assertTrue(alive, 'unreadable foreign stat was accepted as an absent session')

        require_conservative_refusal(code, 1)
        with self.assertRaisesRegex(self.failureException, 'unreadable foreign stat was accepted as an absent session'):
            require_conservative_refusal(mutant, 2)

    def test_bash_quiescence_rejects_fork_after_enumeration(self):
        producer = '''import os, sys
from pathlib import Path
root = Path(sys.argv[1])
report, trigger, release = map(int, sys.argv[2:])
if os.fork():
    os._exit(23)
(root / 'a').write_text(str(os.getpid()))
os.write(report, (str(os.getpid()) + "\\n").encode())
os.read(trigger, 1)
if os.fork():
    os._exit(0)
os.write(report, (str(os.getpid()) + "\\n").encode())
os.read(release, 1)
os._exit(0)
'''
        wrapper = '''#!/bin/bash
source "${ORACLE_ROOT}/definitions.sh"
set +e
read() {
    local oracle_path=${process_path:-${process_dir:-}/stat}
    local oracle_ack=''
    if [[ ${ORACLE_FIRED:-false} != true && $# == 2 && $1 == -r && $2 == process_stat &&
        -f ${ORACLE_ROOT}/a && ${oracle_path} == /proc/"$(<"${ORACLE_ROOT}/a")"/stat ]]; then
        ORACLE_FIRED=true
        # The caller's glob has expanded. Delay the real stat read until A
        # has forked B and become an unreaped zombie; never fabricate fields.
        printf 'barrier %s\\n' "$BASHPID" >&"$ORACLE_EVENTS_FD"
        builtin read -r -u "$ORACLE_ACK_FD" oracle_ack
    fi
    builtin read "$@"
}
if [[ $ORACLE_MODE == gui ]]; then
    WORKER_IDENTITY_TOKEN=bash-fork-oracle-token
    YTDLP_ARIA2_GUI_WORKER_TOKEN=$WORKER_IDENTITY_TOKEN setsid python3 \
        "$ORACLE_ROOT/producer.py" "$ORACLE_ROOT" "$ORACLE_REPORT_FD" \
        "$ORACLE_TRIGGER_FD" "$ORACLE_RELEASE_FD" &
else
    python3 "$ORACLE_ROOT/producer.py" "$ORACLE_ROOT" "$ORACLE_REPORT_FD" \
        "$ORACLE_TRIGGER_FD" "$ORACLE_RELEASE_FD" &
fi
command_pid=$!
command_status=0
wait "$command_pid" || command_status=$?
builtin read -r -u "$ORACLE_ACK_FD" oracle_begin
case $ORACLE_MODE in
    engine)
        REUSE_CURRENT_SESSION=true
        DOWNLOAD_SESSION_ID=$BASHPID
        DOWNLOAD_WORKER_PID=$command_pid
        DOWNLOAD_WORKER_START_TIME=''
        DOWNLOAD_WORKER_PGID=''
        status=0
        wait_for_download_exit 1 || status=$?
        printf 'verdict %s %s %s\\n' "$status" "$DOWNLOAD_SESSION_ID" "$DOWNLOAD_WORKER_PID" >&"$ORACLE_EVENTS_FD"
        ;;
    gui)
        WORKER_PID=$command_pid
        WORKER_PID_START_TIME=1
        WORKER_PGID=$command_pid
        WORKER_PGID_START_TIME=1
        status=0
        wait_for_worker_exit 1 || status=$?
        printf 'verdict %s %s %s\\n' "$status" "$WORKER_PGID" "$WORKER_PID" >&"$ORACLE_EVENTS_FD"
        ;;
    sentinel)
        sleep() {
            local oracle_ack=''
            printf 'verdict 1 %s\\n' "$$" >&"$ORACLE_EVENTS_FD"
            builtin read -r -u "$ORACLE_ACK_FD" oracle_ack
            command sleep "$@"
        }
        trap 'printf "exit %s\\n" "$?" >&"$ORACLE_EVENTS_FD"' EXIT
        source "$ORACLE_ROOT/sentinel.sh"
        ;;
esac
'''

        def record(fd):
            self.assertTrue(select.select([fd], [], [], 5)[0], 'Bash oracle barrier timed out')
            return os.read(fd, 256).decode().split()

        def fields(pid):
            return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()

        def assert_retains_child(mode, code):
            root = self.root / f'{mode}-{len(self.processes)}'
            root.mkdir()
            (root / 'producer.py').write_text(producer)
            (root / 'probe.sh').write_text(wrapper)
            (root / 'definitions.sh').write_text('' if mode == 'sentinel' else code)
            (root / 'sentinel.sh').write_text(code if mode == 'sentinel' else '')
            report_read, report_write = os.pipe()
            trigger_read, trigger_write = os.pipe()
            release_read, release_write = os.pipe()
            events_read, events_write = os.pipe()
            ack_read, ack_write = os.pipe()
            open_fds = {report_read, report_write, trigger_read, trigger_write,
                        release_read, release_write, events_read, events_write, ack_read, ack_write}
            process = None
            try:
                process = subprocess.Popen(
                    ['bash', str(root / 'probe.sh')],
                    env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token,
                             ORACLE_ROOT=str(root), ORACLE_MODE=mode,
                             ORACLE_REPORT_FD=str(report_write), ORACLE_TRIGGER_FD=str(trigger_read),
                             ORACLE_RELEASE_FD=str(release_read), ORACLE_EVENTS_FD=str(events_write),
                             ORACLE_ACK_FD=str(ack_read)),
                    pass_fds=(report_write, trigger_read, release_read, events_write, ack_read),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                self.processes.append(process)
                for fd in (report_write, trigger_read, release_read, events_write, ack_read):
                    os.close(fd)
                    open_fds.remove(fd)
                orphan = int(record(report_read)[0])
                # The departed leader can precede its child's readiness write.
                # Begin enumeration only after the witness has published it.
                os.write(ack_write, b'begin\n')
                barrier = record(events_read)
                self.assertEqual(barrier, ['barrier', str(process.pid)])
                os.write(trigger_write, b'F')
                late_child = int(record(report_read)[0])
                deadline = time.monotonic() + 3
                while fields(orphan)[0] != 'Z':
                    self.assertLess(time.monotonic(), deadline, 'A did not become a zombie')
                    time.sleep(.005)
                os.write(ack_write, b'read-stat\n')
                verdict = record(events_read)
                zombie = fields(orphan)
                witness = fields(late_child)
                self.assertEqual(zombie[0], 'Z')
                self.assertEqual(int(zombie[1]), os.getpid())
                self.assertNotIn(witness[0], ('Z', 'X'))
                self.assertEqual(witness[3], zombie[3])
                if mode != 'gui':
                    self.assertEqual(int(witness[3]), process.pid)
                inherited = os.stat(f'/proc/{late_child}/fd/{release_read}')
                held = os.fstat(release_write)
                self.assertEqual((inherited.st_dev, inherited.st_ino), (held.st_dev, held.st_ino))
                self.assertEqual(verdict[:2], ['verdict', '1'],
                                 'Bash completion accepted a live late-fork child')
                self.assertEqual(verdict[2], witness[3], 'completion discarded the observed SID')
                if mode != 'sentinel':
                    self.assertTrue(verdict[3].isdigit(), 'completion discarded its wait handle')
                # The sentinel must subsequently accept zombie-only presence,
                # retain the original command status, and exclude itself.
                os.close(release_write)
                open_fds.remove(release_write)
                deadline = time.monotonic() + 3
                while fields(late_child)[0] != 'Z':
                    self.assertLess(time.monotonic(), deadline, 'B did not release its descriptor')
                    time.sleep(.005)
                if mode == 'sentinel':
                    os.write(ack_write, b'continue\n')
                    self.assertEqual(record(events_read), ['exit', '23'])
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 23 if mode == 'sentinel' else 0)
            finally:
                # Preserve both zombies and the live FD until the verdict.
                for fd in open_fds:
                    os.close(fd)
                if process is not None:
                    process.communicate(timeout=5)

        engine = (PROJECT / 'download-video.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        gui = (PROJECT / 'download-video-gui.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        sentinel_start = engine.index('            while true; do\n',
                                      engine.index('# Stay alive as the authenticated session leader'))
        sentinel_end = engine.index('            exit "${command_status}"\n', sentinel_start)
        threads_start = engine.index('process_threads_are_quiescent() {')
        threads_end = engine.index('\n}\n', threads_start) + 3
        sentinel = engine[threads_start:threads_end] + engine[sentinel_start:sentinel_end] + 'exit "${command_status}"\n'
        for mode, code in (('engine', engine), ('gui', gui), ('sentinel', sentinel)):
            if mode == 'sentinel':
                start, end = 0, len(code)
            else:
                name = 'download_group_has_live_member' if mode == 'engine' else 'worker_group_has_live_member'
                start = code.index(name + '() {\n')
                end = code.index('\n}\n', start) + 3
            predicate = code[start:end]
            guard = 'for observation in 1 2; do'
            self.assertEqual(predicate.count(guard), 1)
            mutant = code[:start] + predicate.replace(guard, 'for observation in 1; do', 1) + code[end:]
            with self.subTest(target=mode, second_inventory=True):
                assert_retains_child(mode, code)
            with self.subTest(target=mode, second_inventory=False):
                with self.assertRaisesRegex(self.failureException, 'accepted a live late-fork child'):
                    assert_retains_child(mode, mutant)

    def test_shell_quiescence_rechecks_complete_inventory(self):
        # Exercise the actual Bash predicates against a private procfs model.
        # No live process is created or signaled by the modeled state change.
        engine = (PROJECT / 'download-video.sh').read_text()
        gui = (PROJECT / 'download-video-gui.sh').read_text()
        engine_probe = engine[engine.index('process_threads_are_quiescent() {'):
                              engine.index('download_group_is_absent() {')]
        engine_wait = engine[engine.index('wait_for_download_exit() {'):
                             engine.index('stop_download_worker() {')]
        gui_probe = gui[gui.index('process_threads_are_quiescent() {'):
                        gui.index('worker_group_is_absent() {')]
        gui_wait = gui[gui.index('worker_group_may_be_alive() {'):
                       gui.index('process_is_running() {', gui.index('worker_group_may_be_alive() {'))]
        sentinel_start = engine.index('            # Stay alive as the authenticated session leader')
        sentinel = engine[engine.index('            while true; do', sentinel_start):
                          engine.index('            exit "${command_status}"', sentinel_start)]
        threads_start = engine.index('process_threads_are_quiescent() {')
        threads_end = engine.index('\n}\n', threads_start) + 3
        sentinel = engine[threads_start:threads_end] + sentinel
        prologue = r'''set -euo pipefail
FIXTURE_ROOT=$1
mkdir -p "$FIXTURE_ROOT/900000001"
fixture_session=515151
[[ $2 != sentinel ]] || fixture_session=$$
write_state() {
    mkdir -p "$FIXTURE_ROOT/$1/task/$1"
    printf '%s (fixture) %s 0 %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345\n' \
        "$1" "$2" "$fixture_session" "$fixture_session" >"$FIXTURE_ROOT/$1/stat"
    cp "$FIXTURE_ROOT/$1/stat" "$FIXTURE_ROOT/$1/task/$1/stat"
}
write_state "$$" S
write_state 900000001 S
read() {
    if [[ ${*: -1} == process_stat &&
        ${process_path:-${process_dir:-}/stat} == "$FIXTURE_ROOT/900000001/stat" &&
        ! -e $FIXTURE_ROOT/changed ]]; then
        # The glob has already captured A. Before its stat is read, A becomes
        # a zombie and a live B appears outside that first inventory.
        mkdir -p "$FIXTURE_ROOT/900000002"
        write_state 900000002 S
        write_state 900000001 Z
        printf changed >"$FIXTURE_ROOT/changed"
    fi
    builtin read "$@"
}
'''
        cases = {
            'engine-reuse': (engine_probe, engine_wait + r'''
DOWNLOAD_FORCE_STOP=false
DOWNLOAD_WORKER_PID=''
DOWNLOAD_WORKER_PGID=''
DOWNLOAD_SESSION_ID=$fixture_session
status=0
wait_for_download_exit 1 || status=$?
printf '%s:%s\n' "$status" "$DOWNLOAD_SESSION_ID"
''', '1:515151'),
            'gui-current-leader': (gui_probe, gui_wait + r'''
WORKER_PGID=$fixture_session
worker_group_is_current() { return 0; }
status=0
worker_group_may_be_alive || status=$?
printf '%s\n' "$status"
''', '0'),
            'sentinel': (sentinel, '', 'held'),
        }
        for label, (probe, suffix, expected) in cases.items():
            self.assertEqual(probe.count('for observation in 1 2; do'), 1)
            for second_inventory in (True, False):
                with self.subTest(target=label, second_inventory=second_inventory):
                    code = probe if second_inventory else probe.replace(
                        'for observation in 1 2; do', 'for observation in 1; do', 1)
                    setup = prologue
                    if label == 'sentinel':
                        # A live modeled consumer must retain the sentinel.
                        # Stop this deterministic observation at its first wait.
                        setup += "sleep() { printf 'held\\n'; exit 64; }\n"
                    directory = self.root / (label + str(second_inventory))
                    directory.mkdir()
                    code = code.replace('/proc/', str(directory) + '/')
                    completed = subprocess.run(
                        ['bash', '-c', setup + code + suffix, 'bash', str(directory), label],
                        capture_output=True, text=True, timeout=5)
                    self.assertEqual(completed.stderr, '')
                    self.assertTrue((directory / 'changed').exists())
                    wanted_status = 64 if label == 'sentinel' and second_inventory else 0
                    self.assertEqual(completed.returncode, wanted_status, completed.stdout)
                    if second_inventory:
                        self.assertEqual(completed.stdout.strip(), expected,
                                         'live fixture escaped quiescence proof')
                    else:
                        self.assertNotEqual(completed.stdout.strip(), expected,
                                            'single-inventory mutation escaped the oracle')

    def escalation_sources(self):
        for filename in ('download-video.sh', 'download-video-gui.sh'):
            source = (PROJECT / filename).read_text()
            opening = "<<'PY_ESCALATE_OWNED'\n"
            self.assertEqual(source.count(opening), 1)
            yield filename, source.split(opening, 1)[1].split('\nPY_ESCALATE_OWNED', 1)[0]

    def escalation_case(self, code, filename, *, threaded=False,
                        foreign_stat_race=False, isolate_inventory=True):
        program = '''import os, sys, threading
report, trigger, release = map(int, sys.argv[1:4])
def fork_child():
    os.read(trigger, 1)
    if os.fork() == 0:
        os.setsid()
        os.write(report, (str(os.getpid()) + "\\n").encode())
        os.read(release, 1)
        os._exit(0)
    os.read(release, 1)
if sys.argv[4] == 'threaded':
    worker = threading.Thread(target=fork_child)
    worker.start()
    os.write(report, (str(worker.native_id) + "\\n").encode())
    os.read(release, 1)
    worker.join()
else:
    os.write(report, (str(os.getpid()) + "\\n").encode())
    fork_child()
'''
        report_read, report_write = os.pipe()
        trigger_read, trigger_write = os.pipe()
        release_read, release_write = os.pipe()
        open_fds = {report_read, report_write, trigger_read, trigger_write,
                    release_read, release_write}
        real_read = Path.read_text
        real_iterdir = Path.iterdir
        real_signal = signal.pidfd_send_signal
        deliveries = []
        reads = 0
        late_child = None
        foreign = None
        foreign_race_observed = False

        def fields(pid):
            return real_read(Path(f'/proc/{pid}/stat')).rsplit(') ', 1)[1].split()

        def record():
            self.assertTrue(select.select([report_read], [], [], 3)[0], 'fixture readiness timed out')
            return int(os.read(report_read, 100).strip())

        try:
            process = subprocess.Popen(
                [sys.executable, '-B', '-c', program, str(report_write), str(trigger_read),
                 str(release_read), 'threaded' if threaded else 'single'],
                env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                pass_fds=(report_write, trigger_read, release_read),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            self.processes.append(process)
            for fd in (report_write, trigger_read, release_read):
                os.close(fd)
                open_fds.remove(fd)
            thread_id = record()
            identity = fields(process.pid)
            main_children = Path(f'/proc/{process.pid}/task/{process.pid}/children')
            if foreign_stat_race:
                foreign_read, foreign_write = os.pipe()
                open_fds.update((foreign_read, foreign_write))
                foreign = subprocess.Popen(
                    [sys.executable, '-I', '-B', '-c',
                     'import os,sys; os.read(int(sys.argv[1]),1)', str(foreign_read)],
                    pass_fds=(foreign_read,), start_new_session=True,
                    env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.processes.append(foreign)
                os.close(foreign_read)
                open_fds.remove(foreign_read)
                self.assertNotEqual(int(fields(foreign.pid)[3]), int(identity[3]))
            if threaded:
                os.write(trigger_write, b'F')
                late_child = record()
                self.assertNotEqual(thread_id, process.pid)
                self.assertEqual(real_read(main_children).strip(), '')
                thread_children = Path(f'/proc/{process.pid}/task/{thread_id}/children')
                self.assertIn(str(late_child), real_read(thread_children).split())

            def fixture_inventory(path):
                if path != Path('/proc'):
                    return real_iterdir(path)
                if not isolate_inventory:
                    # Reproduce the former ambient inventory with the controlled
                    # foreign race first, before unrelated host churn can act.
                    foreign_path = Path(f'/proc/{foreign.pid}')
                    return iter([foreign_path] + [entry for entry in real_iterdir(path)
                                                   if entry != foreign_path])
                # This program has one parent and at most one reported child.
                # Root enumeration alone is scoped; all task, stat, children
                # and FD reads remain real, including the late child's new SID.
                expected_children = set() if late_child is None else {late_child}
                actual_children = set()
                for task in real_iterdir(Path(f'/proc/{process.pid}/task')):
                    actual_children.update(map(int, real_read(task / 'children').split()))
                self.assertEqual(actual_children, expected_children,
                                 'fixture inventory omitted an unreported child')
                pids = {os.getpid(), process.pid} | expected_children
                return iter(Path(f'/proc/{pid}') for pid in sorted(pids))

            def deliver(descriptor, number, *args):
                real_signal(descriptor, number, *args)
                deliveries.append(number)
                if number == signal.SIGSTOP:
                    # Let the real group stop finish before production's task
                    # scan; no task states or children lists are fabricated.
                    deadline = time.monotonic() + 3
                    while True:
                        states = [real_read(task / 'stat').rsplit(') ', 1)[1].split()[0]
                                  for task in Path(f'/proc/{process.pid}/task').iterdir()]
                        if states and all(state in ('T', 't') for state in states):
                            break
                        self.assertLess(time.monotonic(), deadline, 'target did not freeze')
                        time.sleep(.005)

            def read_then_release(path, *args, **kwargs):
                nonlocal reads, late_child, foreign_race_observed
                if foreign is not None and path == Path(f'/proc/{foreign.pid}/stat'):
                    # An open proc stat can yield ESRCH after actual exit/reap.
                    # Do not fabricate an errno or waive production's veto.
                    with path.open() as held:
                        os.close(foreign_write)
                        open_fds.remove(foreign_write)
                        self.assertEqual(foreign.wait(timeout=3), 0)
                        try:
                            held.read()
                        except ProcessLookupError as error:
                            self.assertEqual(error.errno, 3)
                            foreign_race_observed = True
                            raise
                        self.fail('foreign stat did not produce the required real ESRCH')
                value = real_read(path, *args, **kwargs)
                if not threaded and path == main_children:
                    reads += 1
                    if reads == 2:
                        self.assertEqual(value.strip(), '')
                        frozen = fields(process.pid)[0] in ('T', 't')
                        # Release startup after the final empty-children read.
                        # STOP must prevent this ready fork from running.
                        os.write(trigger_write, b'F')
                        if not frozen:
                            late_child = record()
                return value

            status = 0
            with mock.patch.object(Path, 'iterdir', fixture_inventory), \
                    mock.patch.object(signal, 'pidfd_send_signal', deliver), \
                    mock.patch.object(Path, 'read_text', read_then_release), \
                    mock.patch.object(sys, 'argv', ['probe', str(process.pid),
                                                   identity[19], identity[3]]):
                try:
                    exec(compile(code, filename, 'exec'), {})
                except SystemExit as result:
                    status = result.code

            if late_child is not None:
                witness = fields(late_child)
                self.assertNotIn(witness[0], ('Z', 'X'))
                self.assertEqual(int(witness[3]), late_child, 'child must own its private SID')
                inherited = os.stat(f'/proc/{late_child}/fd/{release_read}')
                held = os.fstat(release_write)
                self.assertEqual((inherited.st_dev, inherited.st_ino), (held.st_dev, held.st_ino))
            if foreign_stat_race:
                self.assertEqual(foreign_race_observed, not isolate_inventory)
            self.assertEqual(status, 0, f'escalation inventory failed: {status}')
            if threaded:
                self.assertNotIn(signal.SIGKILL, deliveries, 'escalation killed a worker-thread child owner')
                self.assertIn(signal.SIGCONT, deliveries)
                self.assertIsNone(process.poll())
                deadline = time.monotonic() + 3
                while fields(process.pid)[0] in ('T', 't'):
                    self.assertLess(time.monotonic(), deadline, 'non-leaf was left stopped')
                    time.sleep(.005)
            else:
                self.assertEqual(reads, 2)
                self.assertEqual(process.wait(timeout=3), -signal.SIGKILL)
                self.assertIsNone(late_child, 'unfrozen escalation let the startup child escape')
                self.assertTrue(select.select([report_read], [], [], 3)[0], 'fork child retained report FD')
                self.assertEqual(os.read(report_read, 100), b'', 'fork ran after the empty-children read')
        finally:
            # Release/reap only after the production verdict and live-FD oracle.
            for fd in open_fds:
                os.close(fd)

    def test_escalation_freezes_startup_fork(self):
        for filename, code in self.escalation_sources():
            with self.subTest(target=filename, freeze=True):
                self.escalation_case(code, filename)
            # Model the old check-then-KILL path, retaining both inventories.
            start = code.index('        signal.pidfd_send_signal(descriptor, signal.SIGSTOP)\n')
            end = code.index('        for child in children:\n', start)
            mutant = code[:start] + '        children = frozen_children(pid)\n' + code[end:]
            state_guard = "            if fields[0] not in ('T', 't', 'Z', 'X'):\n                raise ValueError('thread is not stopped')\n"
            self.assertEqual(mutant.count(state_guard), 1)
            mutant = mutant.replace(state_guard, '', 1)
            with self.subTest(target=filename, freeze=False):
                with self.assertRaisesRegex(self.failureException, 'startup child escape'):
                    self.escalation_case(mutant, filename)
            with self.subTest(target=filename, freeze=False, ambient_esrch=True):
                # The old oracle reports a conservative observation failure,
                # masking the actual escaped child (whose FD was checked first).
                with self.assertRaisesRegex(self.failureException, 'escalation inventory failed: 1'):
                    self.escalation_case(mutant, filename, foreign_stat_race=True,
                                         isolate_inventory=False)
            with self.subTest(target=filename, freeze=False, isolated_esrch=True):
                with self.assertRaisesRegex(self.failureException, 'startup child escape'):
                    self.escalation_case(mutant, filename, foreign_stat_race=True)

    def test_escalation_preserves_worker_thread_child_owner(self):
        for filename, code in self.escalation_sources():
            with self.subTest(target=filename, all_threads=True):
                self.escalation_case(code, filename, threaded=True)
            inventory = "for task in Path(f'/proc/{pid}/task').iterdir():"
            start = code.index('def frozen_children(')
            end = code.index('def other_session_members_quiescent(', start)
            body = code[start:end]
            self.assertEqual(body.count(inventory), 1)
            mutant = code[:start] + body.replace(inventory, "for task in [Path(f'/proc/{pid}/task/{pid}')]:", 1) + code[end:]
            with self.subTest(target=filename, all_threads=False):
                with self.assertRaisesRegex(self.failureException, 'worker-thread child owner'):
                    self.escalation_case(mutant, filename, threaded=True)

    def test_gui_kill_before_pgid_registration_preserves_child_owner(self):
        child = self.child(resistant=True)
        child.write_text(child.read_text().replace('while True:', "while not (root / 'release').exists():"))
        launcher = self.root / 'launcher.py'
        launcher.write_text('''import os, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
child = subprocess.Popen([sys.executable, str(root / 'consumer.py')], start_new_session=True)
(root / 'owner').write_text(str(os.getpid()))
child.wait()
''')
        source = self.root / 'gui-functions.sh'
        source.write_text((PROJECT / 'download-video-gui.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        wrapper = self.root / 'gui.sh'
        wrapper.write_text('''#!/bin/bash
source "$1"
FIXTURE_ROOT=$2
WORKER_ENGINE_SUPERVISION=true
# Hold registration at the real launch boundary while the direct child runs.
recover_worker_pgid() { return 1; }
python3 "$2/launcher.py" "$2" &
WORKER_PID=$!
process_is_direct_child_of "$WORKER_PID" "$BASHPID" WORKER_PID_START_TIME true
trap 'signal_worker_tree KILL; printf checked >"${FIXTURE_ROOT}/checked"' USR1
printf ready >"$2/gui-ready"
while [[ ! -e $2/release ]]; do sleep .01; done
wait "$WORKER_PID"
''')
        process = self.launch(['bash', str(wrapper), str(source), str(self.root)])
        self.wait_file('gui-ready', process)
        child_pid = int(self.wait_file('ready', process))
        owner_pid = int(self.wait_file('owner', process))
        process.send_signal(signal.SIGUSR1)
        self.wait_file('checked', process)
        current = observer.snapshot()
        self.assertIn(owner_pid, current, 'GUI killed the registered owner before PGID recovery')
        self.assertNotIn(current[owner_pid]['state'], ('Z', 'X', 'T', 't'))
        self.assertIn(child_pid, current)
        self.assertNotIn(current[child_pid]['state'], ('Z', 'X'))
        self.assertTrue(any(path.resolve() == self.root / 'resource'
                            for path in Path(f'/proc/{child_pid}/fd').iterdir()))
        (self.root / 'release').touch()
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertFalse(self.observer.sample()['live'])

    def test_observer_orphan_session_and_url(self):
        child = self.child()
        launcher = self.root / 'launcher.py'
        launcher.write_text('''import subprocess, sys, time
from pathlib import Path
subprocess.Popen([sys.executable, sys.argv[1], 'https://synthetic.invalid/observer'], start_new_session=True)
while not Path(sys.argv[1]).with_name('ready').exists(): time.sleep(.01)
''')
        p = self.launch([sys.executable, str(launcher), str(child)])
        self.wait_file('ready', p)
        p.wait(timeout=5)
        state = self.observer.sample()
        # Exercise the actual Zenity harness verdict, before any rescue. A
        # surviving new-session worker must turn the qualification red itself.
        (self.root / 'processes-current.json').write_text(json.dumps(state))
        harness = self.root / 'harness-functions.sh'
        harness.write_text((PROJECT / 'tests/zenity-real-session-qualification.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        verdict = subprocess.run(['bash', '-c', '''source "$1"
sleep .01 &
WATCHER_PID=$!
assert_no_residual_processes "$2" "$2/stop"
''', 'bash', str(harness), str(self.root)], capture_output=True)
        self.assertEqual(verdict.returncode, 65, 'Zenity harness accepted a surviving new-session worker before rescue')
        self.assertIn(b'surviving qualification descendants', verdict.stderr)
        self.assertTrue(state['live'], 'new-session orphan escaped observation before rescue')
        self.assertTrue(state['url_in_argv'], 'synthetic URL escaped the independent observer')
        self.assertNotIn(str(os.getpid()), state['live'])
        self.assertTrue(self.observer.sample()['live'], 'harness rescued the witness before its verdict')

    def test_timeout_early_leader_resistant_descendant_holding_pipe(self):
        child = self.child(resistant=True, new_group=True)
        launcher = self.root / 'launch.py'
        launcher.write_text('''import subprocess, sys, time
from pathlib import Path
subprocess.Popen([sys.executable, sys.argv[1]])
while not Path(sys.argv[1]).with_name('ready').exists(): time.sleep(.01)
''')
        p = self.launch([sys.executable, str(PROJECT / 'private-process-supervisor.py'),
                         '--timeout', '.3', '--grace', '.2', '--', sys.executable,
                         str(launcher), str(child)])
        self.wait_file('ready', p)
        self.observer.sample()
        p.communicate(timeout=5)
        self.assertEqual(p.returncode, 137)
        self.assertTrue((self.root / 'term').exists())
        self.assertFalse(self.observer.sample()['live'], 'timeout returned before last FD holder stopped')

    def test_observer_intentionally_opened_external_application(self):
        child = self.child()
        p = self.launch(['env', 'YTDLP_QUALIFICATION_EXTERNAL=1', sys.executable, str(child)])
        self.wait_file('ready', p)
        self.assertFalse(self.observer.sample()['live'])
        self.assertIsNone(p.poll(), 'observation must not signal the opened application')

    def test_runtime_probe_keeps_its_temporary_and_update_lock(self):
        child = self.child(slow=True, new_group=True)
        child.write_text(child.read_text().replace("root / 'resource'", "root / 'work' / 'resource'"))
        source = self.root / 'runtime-functions.sh'
        source.write_text((PROJECT / 'runtime-manager.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        launcher = self.root / 'launcher.py'
        launcher.write_text('''import subprocess, sys, time
from pathlib import Path
subprocess.Popen([sys.executable, sys.argv[1]])
while not Path(sys.argv[1]).with_name('ready').exists(): time.sleep(.01)
raise SystemExit(23)
''')
        wrapper = self.root / 'runtime.sh'
        wrapper.write_text('''#!/bin/bash
source "$1"
SCRIPT_DIR=$3
RUNTIME_ROOT=$2
trap cleanup_runtime_manager EXIT
trap 'request_runtime_shutdown 143' TERM
mkdir -m700 "$2/work"
register_runtime_temporary work "$2/work" directory
exec {LOCK_FD}>"$2/update.lock"
flock -x "$LOCK_FD"
capture_bounded_timed_output captured fixture .3 python3 "$2/launcher.py" "$2/consumer.py"
exit "$?"
''')
        p = self.launch(['bash', str(wrapper), str(source), str(self.root), str(PROJECT)])
        self.wait_file('ready', p)
        self.wait_file('term', p)
        self.assertTrue((self.root / 'work/resource').exists())
        import fcntl
        with (self.root / 'update.lock').open('a') as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        p.communicate(timeout=6)
        self.assertEqual(p.returncode, 124)
        self.assertTrue((self.root / 'last-access').exists())
        self.assertFalse((self.root / 'early-cleanup').exists())
        self.assertFalse((self.root / 'work').exists())
        self.assertFalse(self.observer.sample()['live'])

    def engine_case(self, reuse):
        child = self.child(slow=True)
        source = self.root / 'engine-functions.sh'
        source.write_text((PROJECT / 'download-video.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        wrapper = self.root / 'engine.sh'
        wrapper.write_text('''#!/bin/bash
source "$1"
OUTPUT_LOCK_ROOT=$2
REUSE_CURRENT_SESSION=$3
trap cleanup EXIT
trap 'request_shutdown TERM 143' TERM
exec {OUTPUT_LOCK_FD}>"$2/lock"
flock -x "$OUTPUT_LOCK_FD"
run_supervised_command bash -c 'python3 "$1" & while [[ ! -s $2/ready ]]; do sleep .01; done' bash "$2/consumer.py" "$2"
status=$DOWNLOAD_STATUS
# This marker represents the first resource mutation allowed by quiescence.
rm -- "$2/resource"
printf '%s\\n' "$status" >"$2/cleaned"
exit "$status"
''')
        p = self.launch(['bash', str(wrapper), str(source), str(self.root), str(reuse).lower()])
        self.wait_file('ready', p)
        self.observer.sample()
        # The producer wrapper exited; the consumer still owns its descriptor.
        time.sleep(.15)
        self.assertIsNone(p.poll(), 'wrapper exit incorrectly authorized engine cleanup')
        p.send_signal(signal.SIGTERM)
        self.wait_file('term', p)
        with (self.root / 'lock').open('a') as lock:
            import fcntl
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Leave adopted zombies untouched until AFTER the production verdict.
        # Their kernel group still exists, but they cannot hold files or FDs.
        p.communicate(timeout=8)
        self.assertEqual(p.returncode, 143)
        self.assertFalse((self.root / 'early-cleanup').exists())
        self.assertTrue((self.root / 'last-access').exists())
        self.assertFalse(self.observer.sample()['live'])

    def probe_case(self, gui):
        child = self.child(resistant=True, new_group=True)
        binary = self.root / 'ffprobe'
        binary.write_text('''#!/bin/bash
python3 "${0%/*}/consumer.py" &
while [[ ! -s ${0%/*}/ready ]]; do sleep .01; done
exit 23
''')
        binary.chmod(0o700)
        engine_source = self.root / 'engine-functions.sh'
        engine_code = (PROJECT / 'download-video.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        engine_source.write_text(engine_code)
        cont_traps = [line.strip() for line in engine_code.splitlines()
                      if line.strip().startswith('trap ') and line.endswith(' CONT')]
        self.assertEqual(len(cont_traps), 1)
        engine = self.root / 'engine.sh'
        engine.write_text('''#!/bin/bash
source "$1"
OUTPUT_LOCK_ROOT=$2
PRIVATE_ARIA2_METADATA=$2
PROCESS_SUPERVISOR=$3/private-process-supervisor.py
REUSE_CURRENT_SESSION=$4
export PATH="$2:$PATH"
trap 'status=$?; stop_download_worker || exit 125; rm -f -- "$PRIVATE_ARIA2_METADATA/probe.json"; exit "$status"' EXIT
trap 'request_shutdown TERM 143' TERM
@CONT_TRAP@
eval "$(declare -f signal_download_worker | sed '1s/signal_download_worker/observed_signal_download_worker/')"
signal_download_worker() {
    if [[ $1 == KILL ]]; then printf force >"${OUTPUT_LOCK_ROOT}/engine-force"; fi
    observed_signal_download_worker "$@"
}
capture_media_probe -v error -of json unused-media
exit "$?"
'''.replace('@CONT_TRAP@', cont_traps[0]))
        arguments = ['bash', str(engine), str(engine_source), str(self.root), str(PROJECT), str(gui).lower()]
        if gui:
            source = self.root / 'gui-functions.sh'
            source.write_text((PROJECT / 'download-video-gui.sh').read_text().rsplit('\nmain "$@"', 1)[0])
            wrapper = self.root / 'gui.sh'
            wrapper.write_text('''#!/bin/bash
source "$1"
FIXTURE_ROOT=$2
shift 2
WORKER_IDENTITY_TOKEN=probe-fixture-token
WORKER_ENGINE_SUPERVISION=true
# Reach real GUI escalation before the timed helper's own grace expires.
eval "$(declare -f wait_for_worker_exit | sed '1s/wait_for_worker_exit/observed_wait_for_worker_exit/')"
wait_for_worker_exit() { observed_wait_for_worker_exit 1; }
eval "$(declare -f signal_owned_process | sed '1s/signal_owned_process/observed_signal_owned_process/')"
signal_owned_process() {
    observed_signal_owned_process "$@" || return "$?"
    if [[ $4 == CONT && $1 == "${WORKER_PGID}" ]]; then
        printf delegated >"${FIXTURE_ROOT}/gui-force"
    fi
}
escalate_owned_process() {
    printf unexpected >"${FIXTURE_ROOT}/gui-froze-consumer"
    return 1
}
YTDLP_ARIA2_GUI_WORKER_TOKEN=$WORKER_IDENTITY_TOKEN setsid --wait "$@" &
WORKER_PID=$!
process_is_direct_child_of "$WORKER_PID" "$BASHPID" WORKER_PID_START_TIME true
while ! recover_worker_pgid "$WORKER_PID"; do
    process_is_running "$WORKER_PID" || exit 125
    sleep .01
done
trap 'stop_worker || exit 125; exit 143' TERM
wait "$WORKER_PID"
''')
            arguments = ['bash', str(wrapper), str(source), str(self.root), *arguments]
        p = self.launch(arguments)
        self.wait_file('ready', p)
        self.assertTrue((self.root / 'probe.json').exists())
        self.observer.sample()
        p.send_signal(signal.SIGTERM)
        p.communicate(timeout=8)
        self.assertEqual(p.returncode, 143)
        self.assertTrue((self.root / 'term').exists())
        self.assertFalse(self.observer.sample()['live'], 'timed FFprobe survived announced closure')
        self.assertFalse((self.root / 'probe.json').exists())
        if gui:
            self.assertTrue((self.root / 'gui-force').exists(), 'GUI did not delegate escalation')
            self.assertTrue((self.root / 'engine-force').exists(), 'engine CONT trap did not escalate')
            self.assertFalse((self.root / 'gui-froze-consumer').exists())

    def test_gui_closes_during_engine_timed_ffprobe(self):
        self.probe_case(True)

    def test_cli_closes_during_engine_timed_ffprobe(self):
        self.probe_case(False)

    def test_engine_gui_wrapper_exit_retains_resource_and_lock(self):
        self.engine_case(True)

    def test_engine_cli_wrapper_exit_retains_resource_and_lock(self):
        self.engine_case(False)

    def test_uncertain_stop_retains_legacy_lock_without_consumer_lock_fds(self):
        child = self.child(resistant=True)
        child.write_text(child.read_text().replace(
            "fd = os.open", "os.closerange(3, 1024)\nfd = os.open"
        ).replace('while True:', "while not (root / 'release').exists():"))
        source = self.root / 'engine-functions.sh'
        source.write_text((PROJECT / 'download-video.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        # Only checkpoint serialization is inert; real stop, retention, locks
        # and descriptor-bound cleanup operate on a real live consumer.
        (self.root / 'checkpoint.py').write_text('pass\n')
        wrapper = self.root / 'engine.sh'
        wrapper.write_text('''#!/bin/bash
source "$1"
OUTPUT_LOCK_ROOT=$2
REUSE_CURRENT_SESSION=true
RESOURCE_STATE_ACTIVE=true
RESOURCE_STATE_FILE=$2/state
RESOURCE_LOCK_ROOT=$2
PRIVATE_ARIA2_HELPER=$2/checkpoint.py
trap cleanup EXIT
trap 'request_shutdown TERM 143' TERM
exec 2>"$2/diagnostic"
exec {OUTPUT_LOCK_FD}>"$2/lock"
flock -s "$OUTPUT_LOCK_FD"
PATH_RECORD_TMP=$2/resource
printf active >"$PATH_RECORD_TMP"
open_private_path_record "$PATH_RECORD_TMP"
# Model a consumer that cannot currently be killed. Keep the production
# deadlines unchanged elsewhere; this fixture shortens only polling budgets.
eval "$(declare -f wait_for_download_exit | sed '1s/wait_for_download_exit/observed_wait_for_download_exit/')"
wait_for_download_exit() { observed_wait_for_download_exit 1; }
eval "$(declare -f escalate_owned_process | sed '1s/escalate_owned_process/observed_escalate_owned_process/')"
escalate_owned_process() {
    local consumer_pid
    consumer_pid=$(<"${OUTPUT_LOCK_ROOT}/ready")
    # The same failure must veto recursive retirement through its sentinel.
    if [[ $1 == "$consumer_pid" || $1 == "$DOWNLOAD_WORKER_PGID" ]]; then
        # Preserve the first completed observation while shutdown retries.
        if [[ ! -e ${OUTPUT_LOCK_ROOT}/blocked-escalation ]]; then
            printf '%s' "$consumer_pid" >"${OUTPUT_LOCK_ROOT}/blocked-escalation"
        fi
        return 1
    fi
    observed_escalate_owned_process "$@"
}
run_supervised_command bash -c 'python3 "$1" & while [[ ! -s $2/ready ]]; do sleep .01; done' bash "$2/consumer.py" "$2"
exit "$DOWNLOAD_STATUS"
''')
        p = self.launch(['bash', str(wrapper), str(source), str(self.root)])
        self.wait_file('ready', p)
        p.send_signal(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if 'retaining reservation descriptors' in (self.root / 'diagnostic').read_text():
                break
            self.assertIsNone(p.poll(), 'lock owner exited while consumer retained access')
            time.sleep(.02)
        else:
            self.fail('fixture did not reach uncertain shutdown')
        self.assertEqual((self.root / 'blocked-escalation').read_text(),
                         (self.root / 'ready').read_text())
        import fcntl
        with (self.root / 'lock').open('a') as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertTrue((self.root / 'resource').exists())
        with (self.root / 'independent-lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        (self.root / 'release').touch()
        p.communicate(timeout=5)
        self.assertEqual(p.returncode, 143)
        self.assertFalse((self.root / 'resource').exists())
        with (self.root / 'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertFalse(self.observer.sample()['live'])

    def test_cli_escalates_subgroup_before_retiring_sentinel(self):
        self.child(resistant=True)
        source = self.root / 'engine-functions.sh'
        source.write_text((PROJECT / 'download-video.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        wrapper = self.root / 'engine.sh'
        wrapper.write_text('''#!/bin/bash
source "$1"
OUTPUT_LOCK_ROOT=$2
REUSE_CURRENT_SESSION=false
trap cleanup EXIT
trap 'request_shutdown TERM 143' TERM
trap 'signal_download_worker KILL' USR1
kill() {
    builtin kill "$@"
    if [[ $1 == -KILL && ${3:-} == "-${DOWNLOAD_WORKER_PGID}" ]]; then
        # Let Bash reap the main sentinel before another authorization check.
        # Escalation of other groups must already have happened at this point.
        sleep .1
    fi
}
run_supervised_command python3 "$3" --timeout 30 --grace 20 -- python3 "$2/consumer.py"
exit "$DOWNLOAD_STATUS"
''')
        p = self.launch(['bash', str(wrapper), str(source), str(self.root),
                         str(PROJECT / 'private-process-supervisor.py')])
        self.wait_file('ready', p)
        self.observer.sample()
        p.send_signal(signal.SIGTERM)
        self.wait_file('term', p)
        p.send_signal(signal.SIGUSR1)
        out, err = self.finish(p)
        self.assertEqual(p.returncode, 143, (out, err))
        self.assertFalse(self.observer.sample()['live'], 'CLI lost subgroup authority before escalation')

    def test_gui_stops_timeout_subgroup_after_leader_exit(self):
        child = self.child(resistant=True)
        source = self.root / 'gui-functions.sh'
        source.write_text((PROJECT / 'download-video-gui.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        wrapper = self.root / 'gui.sh'
        wrapper.write_text('''#!/bin/bash
source "$1"
WORKER_IDENTITY_TOKEN=independent-worker-token
YTDLP_ARIA2_GUI_WORKER_TOKEN=$WORKER_IDENTITY_TOKEN setsid --wait bash -c '
    timeout --signal=TERM --kill-after=2s 20s python3 "$1" &
    while [[ ! -s $2/ready ]]; do sleep .01; done
    while [[ ! -e $2/release ]]; do sleep .01; done
' bash "$2/consumer.py" "$2" &
WORKER_PID=$!
process_is_direct_child_of "$WORKER_PID" "$BASHPID" WORKER_PID_START_TIME true
while [[ ! -s $2/ready ]]; do sleep .01; done
recover_worker_pgid "$WORKER_PID"
: >"$2/release"
wait "$WORKER_PID"
stop_worker
printf stopped >"$2/stopped"
''')
        p = self.launch(['bash', str(wrapper), str(source), str(self.root)])
        self.wait_file('ready', p)
        self.observer.sample()
        out, err = self.finish(p, 10)
        self.assertEqual(p.returncode, 0, (out, err))
        self.assertFalse(self.observer.sample()['live'], 'GUI claimed complete closure with a live timed probe')
        self.assertTrue((self.root / 'term').exists())


if __name__ == '__main__':
    unittest.main()
