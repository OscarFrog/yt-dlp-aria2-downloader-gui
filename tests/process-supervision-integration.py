# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-supervision-integration.py.

Independent process observation and deterministic session/timeout regressions.
Rescue happens only after assertions; test subreaping is not application reaping.
"""

import ast
import ctypes
import errno
import gc
from contextlib import ExitStack, contextmanager, redirect_stderr
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import weakref
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


@contextmanager
def unavailable_synthetic_pidfds():
    """Keep simulated procfs identities outside every real pidfd boundary."""
    synthetic_os = SimpleNamespace(
        getpid=os.getpid,
        pidfd_open=mock.Mock(side_effect=OSError(errno.ENOSYS, 'synthetic pidfd unavailable')),
        close=mock.Mock(side_effect=AssertionError('synthetic fixture has no owned pidfd')))
    synthetic_select = SimpleNamespace(
        POLLIN=select.POLLIN, POLLHUP=select.POLLHUP, POLLERR=select.POLLERR,
        POLLNVAL=select.POLLNVAL,
        poll=mock.Mock(side_effect=AssertionError('synthetic fixture has no pollable pidfd')))
    with mock.patch.object(observer, 'os', synthetic_os), \
            mock.patch.object(observer, 'select', synthetic_select, create=True):
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


class ObservationFailureTests(unittest.TestCase):
    def setUp(self):
        self.pid = 44444
        self.row = dict(start=12345, state='S', parent=1, group=44444, session=44444)
        self.token = 'synthetic-observation-test'
        self.marker = b'YTDLP_QUALIFICATION_TOKEN=' + self.token.encode()
        self.pidfd_boundary = ExitStack()
        self.pidfd_boundary.enter_context(unavailable_synthetic_pidfds())
        self.addCleanup(self.pidfd_boundary.close)

    @contextmanager
    def attribute_failure_transition(self, name, number, transition):
        state = {'row': dict(self.row), 'fail': False, 'failed_reads': 0}

        def snapshot():
            return {} if state['row'] is None else {self.pid: dict(state['row'])}

        def identity(_path):
            if state['row'] is None:
                raise FileNotFoundError(errno.ENOENT, 'synthetic disappeared identity')
            return dict(state['row'])

        def read(path):
            if state['fail'] and path.name == name:
                state['failed_reads'] += 1
                if transition == 'disappeared':
                    state['row'] = None
                elif transition == 'replaced':
                    state['row'] = dict(self.row, start=self.row['start'] + 1)
                elif transition == 'quiescent':
                    state['row'] = dict(self.row, state='Z')
                raise OSError(number, 'synthetic private failure text', '/synthetic/private/path')
            return self.marker + b'\0' if path.name == 'environ' else b'fixture\0'

        with mock.patch.object(observer, 'snapshot', side_effect=snapshot), \
                mock.patch.object(observer, 'process_row', side_effect=identity), \
                mock.patch.object(Path, 'iterdir', autospec=True, side_effect=lambda _path: iter([
                    Path(f'/proc/{self.pid}/task/{self.pid}')])), \
                mock.patch.object(Path, 'read_bytes', new=read):
            yield state

    def test_attribute_error_before_terminal_transition_remains_latched(self):
        for name in ('environ', 'cmdline'):
            for number in (errno.EACCES, errno.EIO, errno.EINTR):
                for transition in ('disappeared', 'replaced', 'quiescent', 'live'):
                    with self.subTest(attribute=name, errno=number, transition=transition):
                        observed = observer.Observer(self.token)
                        with self.attribute_failure_transition(name, number, transition) as state:
                            self.assertIn(str(self.pid), observed.sample()['live'])
                            self.assertIn((self.pid, self.row['start']), observed.known)
                            state['fail'] = True
                            with self.assertRaises(observer.ObservationError) as raised:
                                observed.sample()
                            self.assertEqual(state['failed_reads'], 2 if number == errno.EINTR else 1)
                            self.assertEqual(raised.exception.args, (
                                number, 'attributed process observation is incomplete'))
                            self.assertIsNone(raised.exception.filename)
                            self.assertIs(observed.error, raised.exception)
                            state['row'] = None
                            with self.assertRaises(observer.ObservationError) as repeated:
                                observed.sample()
                            self.assertIs(repeated.exception, raised.exception)

    def test_disappearance_errors_accept_confirmed_terminal_transition(self):
        for name in ('environ', 'cmdline'):
            for number in (errno.ENOENT, errno.ESRCH):
                for transition in ('disappeared', 'replaced', 'quiescent'):
                    with self.subTest(attribute=name, errno=number, transition=transition):
                        observed = observer.Observer(self.token)
                        with self.attribute_failure_transition(name, number, transition) as state:
                            self.assertIn(str(self.pid), observed.sample()['live'])
                            state['fail'] = True
                            observed.sample()
                            self.assertEqual(state['failed_reads'], 1)
                            self.assertIsNone(observed.error)
                            state['row'] = None
                            self.assertFalse(observed.sample()['live'])

    def test_presence_oracle_accepts_terminal_transition_after_read_error(self):
        for number in (errno.EACCES, errno.EIO, errno.EINTR):
            for transition in ('disappeared', 'replaced', 'quiescent'):
                with self.subTest(errno=number, transition=transition), \
                        self.attribute_failure_transition('environ', number, transition) as state:
                    self.assertTrue(observer.token_process_is_live(self.pid, self.marker))
                    state['fail'] = True
                    self.assertFalse(observer.token_process_is_live(self.pid, self.marker))

    def test_attributed_attribute_failure_stays_inconclusive(self):
        for name in ('environ', 'cmdline'):
            for number in (errno.EACCES, errno.EIO):
                with self.subTest(attribute=name, errno=number):
                    observed = observer.Observer(self.token)

                    def readable(path):
                        return self.marker + b'\0' if path.name == 'environ' else b'fixture\0'

                    def denied(path):
                        if path.name == name:
                            raise OSError(number, 'synthetic attribute failure')
                        return readable(path)

                    with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                            mock.patch.object(observer, 'process_row', return_value=self.row), \
                            mock.patch.object(Path, 'read_bytes', new=readable):
                        self.assertIn(str(self.pid), observed.sample()['live'])
                        with mock.patch.object(Path, 'read_bytes', new=denied):
                            with self.assertRaises(observer.ObservationError):
                                observed.sample()
                    # A lost interval must not disappear from the verdict when
                    # the fixture exits, even if the caller resumes sampling.
                    with mock.patch.object(observer, 'snapshot', return_value={}):
                        with self.assertRaises(observer.ObservationError):
                            observed.sample()

    def test_unattributed_foreign_environment_does_not_join_fixture(self):
        with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                mock.patch.object(observer, 'process_row', return_value=self.row), \
                mock.patch.object(Path, 'read_bytes', side_effect=PermissionError(errno.EACCES, 'foreign')):
            self.assertFalse(observer.Observer(self.token).sample()['live'])

    def test_sibling_disappearance_cannot_erase_an_earlier_permission_failure(self):
        paths = [Path(f'/proc/{self.pid}/task/{index}/environ') for index in (1, 2, 3)]
        for strong in (errno.EACCES, errno.EIO):
            for sequence in ((strong, errno.ESRCH), (errno.ESRCH, strong),
                             (strong, errno.ENOENT), (errno.ENOENT, strong)):
                with self.subTest(sequence=sequence):
                    observed = observer.Observer(self.token)
                    observed.known.add((self.pid, self.row['start']))

                    def read(path):
                        index = paths.index(path)
                        if index < 2:
                            raise OSError(sequence[index], 'synthetic sibling observation failure')
                        return self.marker + b'\0'

                    with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                            mock.patch.object(observer, 'process_row', return_value=self.row), \
                            mock.patch.object(observer, 'observation_paths', return_value=iter(paths)), \
                            mock.patch.object(Path, 'read_bytes', new=read):
                        with self.assertRaises(observer.ObservationError) as raised:
                            observed.sample()
                    self.assertEqual(raised.exception.errno, strong)
                    self.assertIs(observed.error, raised.exception)
        for strong in (errno.EACCES, errno.EIO):
            observed = observer.Observer(self.token)
            observed.known.add((self.pid, self.row['start']))

            def failed_enumeration(*_args):
                yield paths[0]
                raise ProcessLookupError(errno.ESRCH, 'synthetic task enumeration disappearance')

            with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                    mock.patch.object(observer, 'process_row', return_value=self.row), \
                    mock.patch.object(observer, 'observation_paths', new=failed_enumeration), \
                    mock.patch.object(Path, 'read_bytes', side_effect=OSError(strong, 'synthetic')):
                with self.assertRaises(observer.ObservationError) as raised:
                    observed.sample()
            self.assertEqual(raised.exception.errno, strong)

    def test_error_rechecks_quiescence_with_fresh_leader_state(self):
        current = dict(self.row, state='Z')
        with mock.patch.object(observer, 'process_row', return_value=current), \
                mock.patch.object(observer, 'threads_are_quiescent', return_value=True) as quiescent:
            observer.observation_failure(self.pid, self.row, ProcessLookupError(errno.ESRCH, 'stale'))
        quiescent.assert_called_once_with(self.pid, current)

    def test_failed_oracle_still_rescues_owned_child_and_preserves_unknown_root(self):
        # This existing witness creates its own child and verifies real rescue;
        # the other methods in this class use entirely simulated procfs PIDs.
        self.pidfd_boundary.close()
        for denied in (False, True):
            with self.subTest(terminal_observation_denied=denied):
                case = ProcessTests(methodName='test_mock_rescue_requires_token_and_current_start_identity')
                case.setUp()
                process = subprocess.Popen(['sleep', '30'],
                                           env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=case.token))
                case.processes.append(process)
                failure = observer.ObservationError(errno.EIO, 'synthetic latched failure')
                case.observer.error = failure
                try:
                    with ExitStack() as stack:
                        if denied:
                            stack.enter_context(mock.patch.object(
                                observer, 'snapshot', side_effect=PermissionError(errno.EACCES, 'injected')))
                        with self.assertRaises(observer.ObservationError) as raised:
                            case.tearDown()
                    self.assertIs(raised.exception, failure, 'cleanup erased the initial observation failure')
                    self.assertIsNotNone(process.poll(), 'failed observation prevented owned-child rescue')
                    self.assertTrue(case.root.exists(),
                                    'a later quiet sample must not erase an earlier observation gap')
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=3)
                    case.temp.cleanup()

    def test_unconfirmed_owned_process_survives_automatic_fixture_cleanup(self):
        def exercise():
            case = ProcessTests(methodName='test_mock_rescue_requires_token_and_current_start_identity')
            case.setUp()
            process = mock.Mock(spec=subprocess.Popen)
            process.poll.return_value = 0
            process.communicate.side_effect = subprocess.TimeoutExpired('synthetic owned pipe', 5)
            case.processes.append(process)
            with mock.patch.object(observer, 'snapshot', return_value={}):
                with self.assertRaises(subprocess.TimeoutExpired):
                    case.tearDown()
            self.assertFalse(case.temp._finalizer.alive, 'automatic cleanup still owns an uncertain fixture')
            return case.root, weakref.ref(case)

        root, reference = exercise()
        try:
            gc.collect()
            self.assertIsNone(reference(), 'the fixture lifetime probe did not collect its TestCase')
            self.assertTrue(root.is_dir(), 'automatic cleanup removed an unconfirmed fixture')
        finally:
            # The synthetic Popen never created a process or inherited an FD.
            shutil.rmtree(root)

    def test_token_oracle_rejects_unknown_and_confirms_disappearance(self):
        for number in (errno.EACCES, errno.EIO, errno.ESRCH):
            with self.subTest(errno=number), \
                    mock.patch.object(observer, 'process_row', return_value=self.row), \
                    mock.patch.object(Path, 'read_bytes', side_effect=OSError(number, 'injected')):
                with self.assertRaises(observer.ObservationError):
                    observer.token_process_is_live(self.pid, self.marker)
        for missing in (FileNotFoundError(errno.ENOENT, 'gone'),
                        ProcessLookupError(errno.ESRCH, 'stale')):
            with self.subTest(initial=type(missing).__name__), \
                    mock.patch.object(observer, 'process_row', side_effect=[missing, FileNotFoundError()]):
                self.assertFalse(observer.token_process_is_live(self.pid, self.marker))
        with mock.patch.object(observer, 'process_row', side_effect=[self.row, dict(self.row, start=54321)]), \
                mock.patch.object(Path, 'read_bytes', return_value=self.marker + b'\0'):
            self.assertFalse(observer.token_process_is_live(self.pid, self.marker))
        with mock.patch.object(observer, 'process_row', return_value=self.row), \
                mock.patch.object(Path, 'read_bytes', side_effect=[InterruptedError(errno.EINTR, 'interrupted'),
                                                                 self.marker + b'\0']):
            self.assertTrue(observer.token_process_is_live(self.pid, self.marker))
        with mock.patch.object(observer, 'process_row', return_value=self.row), \
                mock.patch.object(Path, 'read_bytes', side_effect=InterruptedError(errno.EINTR, 'persistent')):
            with self.assertRaises(observer.ObservationError):
                observer.token_process_is_live(self.pid, self.marker)

    def test_argv_failure_reaches_real_watch_and_scenario_validator(self):
        def load(name, relative):
            module_spec = importlib.util.spec_from_file_location(name, PROJECT / relative)
            module = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(module)
            return module

        driver = load('observation_driver', 'tests/zenity-autonomous-qualification.py')
        fixtures = load('observation_fixtures', 'tests/zenity-autonomous-integration.py')
        for number in (errno.EACCES, errno.EIO):
            with self.subTest(errno=number), tempfile.TemporaryDirectory() as temporary:
                watch = driver.Watch.__new__(driver.Watch)
                watch.observer = observer.Observer(self.token)
                watch.path = Path(temporary) / 'topology.jsonl'
                watch.lock = threading.Lock()
                watch.stop = threading.Event()
                watch.error = None
                watch.last = None
                watch.diagnostics = None
                watch.label = watch.path.name.removesuffix('.topology.jsonl')
                watch.context = threading.local()

                class Result:
                    def observe(self, _state):
                        watch.stop.set()
                        return {}

                watch.result = Result()

                def read(path):
                    if path.name == 'environ':
                        return self.marker + b'\0'
                    raise OSError(number, 'synthetic private observation failure')

                with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                        mock.patch.object(observer, 'process_row', return_value=self.row), \
                        mock.patch.object(Path, 'read_bytes', side_effect=read, autospec=True):
                    watch.run()
                self.assertEqual(watch.error, 'ObservationError')
                with self.assertRaisesRegex(ValueError, 'Continuous process observation failed'):
                    watch.check()
                evidence = fixtures.evidence()
                evidence['observer_error'] = watch.error is not None
                with self.assertRaisesRegex(ValueError, 'Process observation failed'):
                    driver.validate_scenario(evidence)

    def test_terminal_transition_failure_reaches_watch_finish_and_validator(self):
        def load(name, relative):
            module_spec = importlib.util.spec_from_file_location(name, PROJECT / relative)
            module = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(module)
            return module

        driver = load('transition_driver', 'tests/zenity-autonomous-qualification.py')
        fixtures = load('transition_fixtures', 'tests/zenity-autonomous-integration.py')
        for name in ('environ', 'cmdline'):
            for number in (errno.EACCES, errno.EIO):
                for transition in ('disappeared', 'replaced', 'quiescent'):
                    with self.subTest(attribute=name, errno=number, transition=transition), \
                            tempfile.TemporaryDirectory() as temporary, \
                            self.attribute_failure_transition(name, number, transition) as state:
                        watch = driver.Watch.__new__(driver.Watch)
                        watch.observer = observer.Observer(self.token)
                        watch.path = Path(temporary) / 'topology.jsonl'
                        watch.lock = threading.Lock()
                        watch.stop = threading.Event()
                        watch.error = None
                        watch.last = None
                        watch.diagnostics = None
                        watch.label = watch.path.name.removesuffix('.topology.jsonl')
                        watch.context = threading.local()

                        class Result:
                            def observe(self, _state):
                                if state['fail']:
                                    watch.stop.set()
                                else:
                                    state['fail'] = True
                                return {}

                        watch.result = Result()
                        watch.thread = threading.Thread(target=watch.run)
                        watch.thread.start()
                        watch.thread.join(timeout=3)
                        self.assertFalse(watch.thread.is_alive())
                        self.assertIn((self.pid, self.row['start']), watch.observer.known)
                        self.assertEqual(watch.error, 'ObservationError')
                        with self.assertRaisesRegex(ValueError, 'Continuous process observation failed'):
                            watch.check()
                        with self.assertRaisesRegex(ValueError, 'Continuous process observation failed'):
                            watch.finish()
                        state['row'] = None
                        with self.assertRaises(observer.ObservationError):
                            watch.observer.sample()
                        evidence = fixtures.evidence()
                        evidence['observer_error'] = watch.error is not None
                        with self.assertRaisesRegex(ValueError, 'Process observation failed'):
                            driver.validate_scenario(evidence)

    def test_each_runner_oracle_propagates_unreadable_environment(self):
        examined = 0
        for relative in ('tests/run-all-signal-integration.sh', 'tests/test-runner-integration.sh'):
            source = (PROJECT / relative).read_text()
            for match in re.finditer(r"<<'(?P<tag>PY_[A-Z_]+)'\n(?P<body>.*?)\n(?P=tag)(?:\n|$)",
                                     source, re.S):
                body = match['body']
                tree = ast.parse(body)
                function = next((node for node in tree.body
                                 if isinstance(node, ast.FunctionDef) and node.name == 'running'), None)
                if function is None:
                    continue
                examined += 1
                namespace = {'identity_observer': observer}
                exec(compile(ast.Module(body=[function], type_ignores=[]),
                             relative + ':' + match['tag'], 'exec'), namespace)
                token_name = re.search(r'YTDLP_ARIA2_[A-Z_]+TOKEN',
                                       ast.get_source_segment(body, function)).group()
                marker = (token_name + '=' + self.token).encode()
                with mock.patch.object(observer, 'process_row', return_value=self.row), \
                        mock.patch.object(Path, 'read_bytes', return_value=marker + b'\0'):
                    self.assertTrue(namespace['running'](self.pid, self.token))
                for number in (errno.EACCES, errno.EIO):
                    with self.subTest(file=relative, heredoc=match['tag'], errno=number), \
                            mock.patch.object(observer, 'process_row', return_value=self.row), \
                            mock.patch.object(Path, 'read_bytes', side_effect=OSError(number, 'injected')):
                        with self.assertRaises(observer.ObservationError):
                            namespace['running'](self.pid, self.token)
        self.assertEqual(examined, 5, 'a runner oracle escaped the failure matrix')


class ObservationMemoryTests(unittest.TestCase):
    def setUp(self):
        self.pid = 44444
        self.tid = 44445
        self.row = dict(start=12345, state='Z', parent=1, group=self.pid, session=self.pid)
        self.task = dict(self.row, start=12346, state='S')
        self.token = 'synthetic-thread-memory-test'
        self.marker = b'YTDLP_QUALIFICATION_TOKEN=' + self.token.encode()
        self.root = Path(f'/proc/{self.pid}')
        self.sibling = self.root / 'task' / str(self.tid)
        self.pidfd_boundary = ExitStack()
        self.pidfd_boundary.enter_context(unavailable_synthetic_pidfds())
        self.addCleanup(self.pidfd_boundary.close)

    def row_for(self, path):
        return dict(self.task if path.parent == self.sibling else self.row)

    def test_zombie_leader_memory_is_not_required_for_live_sibling(self):
        for number in (errno.EACCES, errno.EIO):
            with self.subTest(dead_leader_errno=number):
                reads = []

                def read(path):
                    reads.append(path)
                    if path.parent != self.sibling:
                        raise OSError(number, 'synthetic terminated-task memory')
                    return self.marker + b'\0' if path.name == 'environ' else b'https://example.invalid/synthetic\0'

                with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                        mock.patch.object(observer, 'process_row', side_effect=self.row_for), \
                        mock.patch.object(Path, 'iterdir', side_effect=lambda _path: iter([
                            self.root / 'task' / str(self.pid), self.sibling]), autospec=True), \
                        mock.patch.object(observer, 'read_observation', side_effect=read):
                    sample = observer.Observer(self.token).sample()
                    self.assertIn(str(self.pid), sample['live'])
                    self.assertIn((self.pid, self.row['start']), sample['url_in_argv'])
                    self.assertTrue(observer.token_process_is_live(self.pid, self.marker))
                self.assertTrue(reads)
                self.assertTrue(all(path.parent == self.sibling for path in reads),
                                'terminated task memory was read instead of the live sibling')

    def test_live_sibling_permission_and_io_errors_remain_blocking(self):
        for name in ('environ', 'cmdline'):
            for number in (errno.EACCES, errno.EIO):
                with self.subTest(attribute=name, errno=number):
                    observed = observer.Observer(self.token)
                    observed.known.add((self.pid, self.row['start']))

                    def read(path):
                        if path.name == name:
                            raise OSError(number, 'synthetic active-task memory refusal')
                        return self.marker + b'\0'

                    with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                            mock.patch.object(observer, 'process_row', side_effect=self.row_for), \
                            mock.patch.object(Path, 'iterdir', side_effect=lambda _path: iter([self.sibling]),
                                              autospec=True), \
                            mock.patch.object(observer, 'read_observation', side_effect=read):
                        with self.assertRaises(observer.ObservationError) as raised:
                            observed.sample()
                        self.assertEqual(raised.exception.errno, number)
                        self.assertIs(observed.error, raised.exception)
                        if name == 'environ':
                            with self.assertRaises(observer.ObservationError) as token_error:
                                observer.token_process_is_live(self.pid, self.marker)
                            self.assertEqual(token_error.exception.errno, number)

    def test_memory_read_revalidates_group_and_task_identity(self):
        for change in ('group-start', 'task-start', 'task-exit', 'task-disappears'):
            with self.subTest(change=change):
                rows = {'group': dict(self.row), 'task': dict(self.task)}

                def identity(path):
                    if path.parent == self.sibling:
                        if rows['task'] is None:
                            raise FileNotFoundError(errno.ENOENT, 'synthetic retired task')
                        return dict(rows['task'])
                    return dict(rows['group'])

                def read(_path):
                    if change == 'group-start':
                        rows['group']['start'] += 1
                    elif change == 'task-start':
                        rows['task']['start'] += 1
                    elif change == 'task-exit':
                        rows['task']['state'] = 'Z'
                    else:
                        rows['task'] = None
                    return self.marker + b'\0'

                with mock.patch.object(observer, 'process_row', side_effect=identity), \
                        mock.patch.object(observer, 'read_observation', side_effect=read) as memory:
                    with self.assertRaises((FileNotFoundError, ProcessLookupError)):
                        observer.read_process_observation(self.pid, self.row, self.sibling / 'environ')
                    memory.assert_called_once()

    def test_leader_exit_between_selection_and_read_uses_live_sibling(self):
        self.row['state'] = 'S'
        with mock.patch.object(observer, 'process_row', side_effect=self.row_for), \
                mock.patch.object(Path, 'iterdir', side_effect=lambda _path: iter([self.sibling]), autospec=True), \
                mock.patch.object(observer, 'read_observation', return_value=self.marker + b'\0') as memory:
            paths = observer.observation_paths(self.pid, self.row, 'environ')
            leader_path = next(paths)
            self.assertEqual(leader_path, self.root / 'environ')
            self.row['state'] = 'Z'
            with self.assertRaises(ProcessLookupError):
                observer.read_process_observation(self.pid, self.row, leader_path)
            memory.assert_not_called()
            sibling_path = next(paths)
            self.assertEqual(sibling_path, self.sibling / 'environ')
            self.assertEqual(observer.read_process_observation(self.pid, self.row, sibling_path),
                             self.marker + b'\0')

    def test_unknown_task_inventory_and_identity_cannot_prove_absence(self):
        for boundary in ('inventory', 'task-stat'):
            for number in (errno.EACCES, errno.EIO):
                with self.subTest(boundary=boundary, errno=number):
                    observed = observer.Observer(self.token)
                    observed.known.add((self.pid, self.row['start']))

                    def identity(path):
                        if boundary == 'task-stat' and path.parent == self.sibling:
                            raise OSError(number, 'synthetic task identity refusal')
                        return self.row_for(path)

                    def tasks(_path):
                        if boundary == 'inventory':
                            raise OSError(number, 'synthetic task inventory refusal')
                        return iter([self.sibling])

                    with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                            mock.patch.object(observer, 'process_row', side_effect=identity), \
                            mock.patch.object(Path, 'iterdir', side_effect=tasks, autospec=True), \
                            mock.patch.object(observer, 'read_observation') as memory:
                        with self.assertRaises(observer.ObservationError) as raised:
                            observed.sample()
                        self.assertEqual(raised.exception.errno, number)
                        memory.assert_not_called()
        observed = observer.Observer(self.token)
        observed.known.add((self.pid, self.row['start']))
        with mock.patch.object(observer, 'snapshot', return_value={self.pid: self.row}), \
                mock.patch.object(observer, 'process_row', side_effect=self.row_for), \
                mock.patch.object(Path, 'iterdir', side_effect=lambda _path: iter([]), autospec=True):
            with self.assertRaises(observer.ObservationError):
                observed.sample()


class ExitingSingletonTests(unittest.TestCase):
    """Exercise strict memory failure boundaries using two private processes and real pidfds."""

    def setUp(self):
        # The leader holds a real unmarked child and waits for the test to close stdin.
        helper = (
            "import os, subprocess, sys\n"
            "with subprocess.Popen(['/usr/bin/cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env={}) as child:\n"
            "    child.stdin.write(b'x'); child.stdin.flush()\n"
            "    if child.stdout.read(1) != b'x': sys.exit(9)\n"
            "    print(child.pid, flush=True)\n"
            "    sys.stdin.buffer.read(1)\n"
            "    child.stdin.close()\n"
            "    sys.exit(child.wait(timeout=3))\n"
        )
        self.token = 'owned-singleton-fixture'
        self.leader = subprocess.Popen([sys.executable, '-IB', '-c', helper],
                                       env={'YTDLP_QUALIFICATION_TOKEN': self.token},
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(self.release)
        self.assertTrue(select.select([self.leader.stdout], [], [], 3)[0])
        self.child = int(self.leader.stdout.readline())
        self.root = Path('/proc') / str(self.leader.pid)
        self.child_root = Path('/proc') / str(self.child)
        self.key = (self.leader.pid, observer.process_row(self.root / 'stat')['start'])

    def release(self):
        self.leader.stdin.close()
        try:
            self.assertEqual(self.leader.wait(timeout=5), 0)
        finally:
            self.leader.stdout.close()

    @contextmanager
    def transition(self, diagnostics, *, fault='open', number=errno.ESRCH, arguments=b'',
                   flags=4, threads=1, sibling_at=0, inventory_errno=0, leak_before=False):
        # The two known PIDs, their parentage and pidfd/fdinfo are genuine. Only the
        # irreversible exit window and its I/O faults are modelled at procfs boundaries.
        def snapshot():
            return {int(p.name): observer.process_row(p / 'stat') for p in (self.root, self.child_root)}

        task_dir = self.root / 'task'
        leader_task = task_dir / str(self.leader.pid)
        real_open, real_iterdir = Path.open, Path.iterdir
        evidence = {'inventories': 0, 'cmdline_reads': 0}
        exiting = False
        canary = b'synthetic\0https://fixture.invalid/observable\0'

        class Memory(io.BytesIO):
            def __init__(inner, kind, data):
                super().__init__(data)
                inner.kind = kind

            def read(inner, *args):
                if inner.kind == 'environ' and fault == 'read':
                    raise OSError(number, 'fixture read refusal')
                if inner.kind == 'cmdline':
                    evidence['cmdline_reads'] += 1
                return super().read(*args)

            def close(inner):
                super().close()
                if inner.kind == 'environ' and fault == 'close':
                    raise OSError(number, 'fixture close refusal')

        def opened(path, mode='r', *args, **kwargs):
            if exiting and path.name == 'stat' and path.parent in (self.root, leader_task):
                with real_open(path, 'rb') as stream:
                    prefix, sep, suffix = stream.read().rpartition(b') ')
                fields = suffix.split()
                fields[0] = b'R'
                fields[6] = str(int(fields[6]) | flags).encode()
                fields[17] = str(threads).encode()
                raw = prefix + sep + b' '.join(fields) + b'\n'
                return io.BytesIO(raw) if 'b' in mode else io.StringIO(os.fsdecode(raw))
            if path.parent in (self.root, leader_task):
                if path.name == 'environ' and exiting:
                    if fault in ('open', 'cmdline-missing'):
                        raise OSError(number, 'fixture open refusal')
                    return Memory('environ', b'')
                if path.name == 'cmdline':
                    if exiting:
                        if fault == 'cmdline-missing':
                            raise FileNotFoundError(errno.ENOENT, 'fixture arguments unavailable')
                        return Memory('cmdline', arguments)
                    if leak_before:
                        return io.BytesIO(canary)
            return real_open(path, mode, *args, **kwargs)

        def inventory(path):
            if exiting and path == task_dir:
                evidence['inventories'] += 1
                if inventory_errno:
                    raise OSError(inventory_errno, 'fixture task inventory refusal')
                if evidence['inventories'] == sibling_at:
                    # An unexpected entry inside this child's task directory; no
                    # lookup or signal may target an unrelated system process.
                    return iter([leader_task, task_dir / str(self.child)])
            return real_iterdir(path)

        observed = observer.Observer(self.token, diagnostics=diagnostics, identity_diagnostics=diagnostics)
        with mock.patch.object(observer, 'snapshot', snapshot), mock.patch.object(Path, 'open', opened), \
                mock.patch.object(Path, 'iterdir', inventory):
            initial = observed.sample()
            self.assertIn(str(self.leader.pid), initial['live'])
            self.assertIn(str(self.child), initial['live'])
            self.assertIn(self.key, observed.known)
            self.assertEqual(self.key in initial['url_in_argv'], leak_before)
            exiting = True
            yield observed, evidence

    def test_exiting_singleton_keeps_group_descendant_and_previous_leak(self):
        for diagnostics in (False, True):
            with self.subTest(diagnostics=diagnostics), self.transition(diagnostics, leak_before=True) as (obs, evidence):
                result = obs.sample()
                self.assertEqual(set(result['live']), {str(self.leader.pid), str(self.child)})
                self.assertNotIn(self.leader.pid, result['zombies'])
                self.assertIn(self.key, result['url_in_argv'])
                self.assertIsNone(obs.error)
                self.assertFalse(obs.diagnostics_incomplete)
                self.assertGreaterEqual(evidence['inventories'], 3)
                self.assertGreaterEqual(evidence['cmdline_reads'], 1)

    def test_exiting_singleton_rejects_uncertain_identity_memory_and_inventory(self):
        cases = [
            {'flags': 0}, {'threads': 2}, {'sibling_at': 1}, {'sibling_at': 2}, {'sibling_at': 3},
            {'inventory_errno': errno.EIO}, {'inventory_errno': errno.EACCES},
            {'number': errno.EACCES}, {'number': errno.EPERM}, {'number': errno.EIO},
            {'number': errno.ENOENT}, {'fault': 'read'}, {'fault': 'close'},
            {'fault': 'cmdline-missing'}, {'arguments': b'fixture\0'},
        ]
        for diagnostics in (False, True):
            for options in cases:
                with self.subTest(diagnostics=diagnostics, options=options), self.transition(diagnostics, **options) as (obs, _):
                    with self.assertRaises(observer.ObservationError) as initial:
                        obs.sample()
                    number = options.get('inventory_errno', options.get('number', errno.ESRCH))
                    self.assertEqual(initial.exception.errno, number)
                    if diagnostics:
                        packet = obs.identity_failure(initial.exception)
                        self.assertTrue(packet['complete'])
                        first, = [e for e in packet['events'] if e['first_failure']]
                        operation = {'read': 'attribute_read', 'close': 'attribute_close'}.get(
                            options.get('fault'), 'attribute_open')
                        if 'inventory_errno' in options:
                            operation = 'task_inventory'
                        self.assertEqual((first['operation'], first['primitive_errno']), (operation, number))
                        self.assertEqual(packet['events'][-1]['normalized_errno'], number)
                        if options.get('fault') == 'cmdline-missing':
                            self.assertTrue(any(e['operation'] == 'attribute_open' and e['primitive_errno'] == errno.ENOENT
                                                for e in packet['events'][1:]))
                    self.assertIs(obs.error, initial.exception)
                    with mock.patch.object(observer, 'snapshot', return_value={}), self.assertRaises(observer.ObservationError) as later:
                        obs.sample()
                    self.assertIs(later.exception, initial.exception)

    def test_exiting_singleton_rejects_and_records_nonempty_private_arguments(self):
        for diagnostics in (False, True):
            with self.subTest(diagnostics=diagnostics), self.transition(
                    diagnostics, arguments=b'https://fixture.invalid/synthetic\0') as (obs, evidence):
                with self.assertRaises(observer.ObservationError) as failure:
                    obs.sample()
                self.assertIs(obs.error, failure.exception)
                self.assertIn(self.key, obs.leaks)
                self.assertGreaterEqual(evidence['cmdline_reads'], 1)

    def test_exiting_singleton_rejects_unbound_ready_or_unobservable_pidfd(self):
        real_pidfd_open = os.pidfd_open
        for diagnostics in (False, True):
            for fault in ('foreign-fd', 'ready-before-argv', 'ready-after-argv', 'poll-error', 'pollnval'):
                with self.subTest(diagnostics=diagnostics, fault=fault), self.transition(diagnostics) as (obs, _):
                    descriptors = []
                    polls = []

                    def open_group(pid, flags=0):
                        self.assertEqual((pid, flags), (self.leader.pid, 0))
                        fd = real_pidfd_open(self.child if fault == 'foreign-fd' else pid, flags)
                        descriptors.append(fd)
                        return fd

                    def injected_poll(timeout):
                        self.assertEqual(timeout, 0)
                        self.assertEqual(len(descriptors), 1)
                        polls.append(timeout)
                        if fault == 'poll-error':
                            raise OSError(errno.EIO, 'fixture poll failure')
                        if fault == 'ready-after-argv' and len(polls) == 1:
                            return []
                        return [(descriptors[0], select.POLLNVAL if fault == 'pollnval' else select.POLLIN)]

                    poller = mock.Mock()
                    poller.poll.side_effect = injected_poll
                    with mock.patch.object(os, 'pidfd_open', new=open_group), \
                            mock.patch.object(select, 'poll', return_value=poller), \
                            self.assertRaises(observer.ObservationError) as failure:
                        obs.sample()
                    self.assertIs(obs.error, failure.exception)
                    self.assertEqual(len(descriptors), 1)
                    with self.assertRaises(OSError) as closed:
                        os.fstat(descriptors[0])
                    self.assertEqual(closed.exception.errno, errno.EBADF)
                    self.assertEqual(len(polls), {'foreign-fd': 0, 'ready-after-argv': 2}.get(fault, 1))

    def test_exiting_singleton_close_retains_initial_open_and_never_retries(self):
        real_open, real_close = os.pidfd_open, os.close
        for diagnostics in (False, True):
            with self.subTest(diagnostics=diagnostics), self.transition(diagnostics) as (obs, evidence):
                owned, closed = [], []

                def open_group(pid, flags):
                    self.assertEqual((pid, flags), (self.leader.pid, 0))
                    fd = real_open(pid, flags)
                    owned.append(fd)
                    return fd

                def close(fd):
                    if fd not in owned:
                        return real_close(fd)
                    closed.append(fd)
                    real_close(fd)
                    raise OSError(errno.EIO, 'fixture close after retiring memory')

                with mock.patch.object(os, 'pidfd_open', open_group), mock.patch.object(os, 'close', close):
                    with self.assertRaises(observer.ObservationError) as failure:
                        obs.sample()
                    self.assertIs(obs.error, failure.exception)
                    self.assertEqual(failure.exception.errno, errno.EIO)
                    with self.assertRaises(observer.ObservationError) as later:
                        obs.sample()
                    self.assertIs(later.exception, failure.exception)
                descriptor, = owned
                self.assertEqual(closed, [descriptor])
                self.assertGreaterEqual(evidence['inventories'], 3)
                self.assertGreaterEqual(evidence['cmdline_reads'], 1)
                with self.assertRaises(OSError) as invalid:
                    os.fstat(descriptor)
                self.assertEqual(invalid.exception.errno, errno.EBADF)
                if diagnostics:
                    packet = obs.identity_failure(failure.exception)
                    self.assertTrue(packet['complete'])
                    events = packet['events']
                    self.assertEqual([(e['operation'], e['primitive_errno']) for e in events if e['primitive_errno']],
                                     [('attribute_open', errno.ESRCH), ('pidfd_close', errno.EIO)])
                    self.assertEqual((events[-1]['operation'], events[-1]['normalized_errno']),
                                     ('error_normalization', errno.EIO))

    def test_only_separately_bound_zombie_group_can_certify_a_missing_inventory(self):
        real_pidfd_open = os.pidfd_open
        for early_succeeds in (True, False):
            with self.subTest(early_succeeds=early_succeeds), self.transition(False):
                early = observer.process_row(self.root / 'stat')
                zombie = dict(early, state='Z')
                attempts = []
                handles = []

                def bind(pid, flags):
                    self.assertEqual((pid, flags), (self.leader.pid, 0))
                    attempts.append(pid)
                    if early_succeeds != (len(attempts) == 1):
                        raise OSError(errno.EPERM, 'fixture binding unavailable')
                    descriptor = real_pidfd_open(pid, flags)
                    handles.append(descriptor)
                    return descriptor

                def poll_ready(timeout):
                    self.assertEqual(timeout, 0)
                    return [(handles[0], select.POLLIN)]

                poller = mock.Mock()
                poller.poll.side_effect = poll_ready
                with observer._GroupExitProofs({self.key}) as proofs, mock.patch.object(os, 'pidfd_open', bind):
                    proofs.pin(self.leader.pid, early, exiting_singleton=True)
                    with mock.patch.object(observer, 'current_process', return_value=zombie), \
                            mock.patch.object(Path, 'iterdir', side_effect=FileNotFoundError(errno.ENOENT, 'fixture retired')), \
                            mock.patch.object(select, 'poll', return_value=poller):
                        self.assertEqual(observer.threads_are_quiescent(self.leader.pid, zombie), not early_succeeds)
                self.assertEqual(attempts, [self.leader.pid, self.leader.pid])
                self.assertEqual(poller.poll.call_count, int(not early_succeeds))
                descriptor, = handles
                with self.assertRaises(OSError) as closed:
                    os.fstat(descriptor)
                self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_earlier_known_error_precedes_exiting_singleton_fdinfo_close(self):
        with self.transition(True) as (obs, _):
            snapshot, opened = observer.snapshot, Path.open
            closed = []

            def fail(path, *args, **kwargs):
                if path == self.child_root / 'environ':
                    raise PermissionError(errno.EACCES, 'fixture preceding group access refusal')
                stream = opened(path, *args, **kwargs)
                if path.parent != Path('/proc/self/fdinfo'):
                    return stream

                def close():
                    stream.close()
                    closed.append(int(path.name))
                    raise OSError(errno.EIO, 'fixture descriptor identity close refusal')

                return mock.Mock(read=stream.read, close=close)

            with mock.patch.object(observer, 'snapshot', lambda: dict(reversed(snapshot().items()))), \
                    mock.patch.object(Path, 'open', fail), self.assertRaises(observer.ObservationError) as failure:
                obs.sample()
            self.assertEqual(failure.exception.errno, errno.EACCES)
            self.assertIs(obs.error, failure.exception)
            packet = obs.identity_failure(failure.exception)
            self.assertTrue(packet['complete'])
            first, = [event for event in packet['events'] if event['first_failure']]
            self.assertEqual((first['operation'], first['primitive_errno'], first['context']['group_expected']['pid']),
                             ('attribute_open', errno.EACCES, self.child))
            secondary, = [event for event in packet['events'] if event['operation'] == 'pidfd_fdinfo_close']
            self.assertEqual((secondary['primitive_errno'], secondary['context']['group_expected']['pid']),
                             (errno.EIO, self.leader.pid))
            self.assertEqual(packet['events'][-1]['normalized_errno'], errno.EACCES)
            descriptor, = closed
            with self.assertRaises(OSError) as invalid:
                os.fstat(descriptor)
            self.assertEqual(invalid.exception.errno, errno.EBADF)


class ObservationRetirementTests(unittest.TestCase):
    """Model group retirement without reading procfs or opening a real pidfd."""

    def setUp(self):
        self.pid = 44444
        self.tid = 44445
        self.row = dict(start=12345, state='S', parent=1, group=55555, session=55555)
        self.token = 'synthetic-retired-group-test'
        self.marker = b'YTDLP_QUALIFICATION_TOKEN=' + self.token.encode()
        self.root = Path(f'/proc/{self.pid}')

    @contextmanager
    def retired_group(self, *, ready=True, inventory_errno=errno.ENOENT,
                      read_errno=None, replace_on_open=False, pidfd_errno=None,
                      poll_mask=None, poll_errno=None, wrong_descriptor=False,
                      close_errno=None, already_exited=False, leader_inventory=False,
                      duplicate_events=False, gone_on_open=False, sibling_live=False,
                      reuse_task=False, complete_inventory=False, fdinfo_payload=None,
                      fdinfo_errno=None, fdinfo_close_errno=None, earlier_memory_error=None):
        state = dict(row=dict(self.row, state='Z' if already_exited else 'S'),
                     task=dict(self.row, start=12399, state='S'),
                     opened=[], closed=[], polls=[], reads=[], read_tids=[], inventories=[],
                     fdinfo_opened=[], fdinfo_reads=[], fdinfo_closed=[])
        handles = set()
        test = self
        sibling = self.root / 'task' / str(self.tid)
        earlier_pid = self.pid - 1
        earlier_root = Path(f'/proc/{earlier_pid}')
        earlier_row = dict(self.row, start=self.row['start'] - 1, state='S')
        rows = {self.pid: dict(self.row)}
        if earlier_memory_error is not None:
            rows = {earlier_pid: earlier_row, **rows}

        def identity(path):
            test.assertIn(path, (self.root / 'stat', self.root / 'task' / str(self.pid) / 'stat',
                                sibling / 'stat', earlier_root / 'stat'),
                          'fixture escaped the owned group identity')
            if path.parent == earlier_root:
                return dict(earlier_row)
            if state['row'] is None:
                raise FileNotFoundError(errno.ENOENT, 'synthetic retired group identity')
            if path.parent == sibling:
                return dict(state['task'])
            return dict(state['row'])

        def inventory(path):
            test.assertEqual(path, self.root / 'task', 'fixture escaped the owned task inventory')
            state['inventories'].append(path)
            if sibling_live:
                return iter((self.root / 'task' / str(self.pid), sibling))
            if complete_inventory:
                return iter((self.root / 'task' / str(self.pid),))
            if leader_inventory and len(state['inventories']) == 1:
                return iter((self.root / 'task' / str(self.pid),))
            if inventory_errno is not None:
                raise OSError(inventory_errno, 'synthetic retired task inventory')
            return iter(())

        class Memory:
            def __init__(self, path):
                self.path = path

            def __enter__(self):
                return self

            def __exit__(self, *_exception):
                return False

            def read(self):
                state['reads'].append(self.path.name)
                if self.path.parent == earlier_root:
                    state['read_tids'].append(earlier_pid)
                    raise OSError(earlier_memory_error, 'synthetic preceding group memory refusal')
                state['read_tids'].append(self.tid if self.path.parent == sibling else self.pid)
                state['row']['state'] = 'Z'
                if reuse_task and self.path.parent == sibling:
                    state['task']['start'] += 1
                if read_errno is not None:
                    raise OSError(read_errno, 'synthetic attributed memory failure')
                return self.marker + b'\0' if self.path.name == 'environ' else b'fixture\0'

            marker = self.marker
            tid = self.tid
            pid = self.pid

        class DescriptorInfo:
            def __init__(self, descriptor):
                self.descriptor = descriptor
                state['fdinfo_opened'].append(descriptor)

            def __enter__(self):
                return self

            def __exit__(self, *_exception):
                self.close()
                return False

            def close(self):
                state['fdinfo_closed'].append(self.descriptor)
                if fdinfo_close_errno is not None:
                    raise OSError(fdinfo_close_errno, 'synthetic descriptor identity close refusal')

            def read(self, size=-1):
                test.assertEqual(size, 4097, 'fdinfo identity read is not bounded')
                state['fdinfo_reads'].append(size)
                if fdinfo_errno is not None:
                    raise OSError(fdinfo_errno, 'synthetic descriptor identity refusal')
                data = fdinfo_payload if fdinfo_payload is not None else f'Pid:\t{test.pid}\n'.encode()
                return data[:size]

        def opened(path, *args, **kwargs):
            if path.parent == Path('/proc/self/fdinfo'):
                test.assertTrue(path.name.isdecimal())
                descriptor = int(path.name)
                test.assertIn(descriptor, handles, 'descriptor identity is not owned by this sample')
                return DescriptorInfo(descriptor)
            test.assertIn(path, (self.root / 'environ', self.root / 'cmdline',
                                sibling / 'environ', sibling / 'cmdline',
                                earlier_root / 'environ', earlier_root / 'cmdline'),
                          'fixture escaped the owned memory attributes')
            return Memory(path)

        def pidfd_open(pid, flags=0):
            test.assertEqual((pid, flags), (self.pid, 0), 'pidfd must bind the complete expected group')
            if pidfd_errno is not None:
                raise OSError(pidfd_errno, 'synthetic pidfd refusal')
            descriptor = 900000 + len(state['opened'])
            state['opened'].append(descriptor)
            handles.add(descriptor)
            if replace_on_open:
                state['row']['start'] += 1
            if gone_on_open:
                state['row'] = None
            return descriptor

        class Poll:
            def __init__(self):
                self.descriptor = None

            def register(self, descriptor, mask=select.POLLIN):
                test.assertIn(descriptor, handles)
                test.assertIsNone(self.descriptor, 'a poller must not admit another group')
                test.assertTrue(mask & select.POLLIN)
                self.descriptor = descriptor

            def poll(self, timeout=None):
                test.assertEqual(timeout, 0, 'termination evidence must not wait for the process')
                state['polls'].append(self.descriptor)
                if poll_errno is not None:
                    raise OSError(poll_errno, 'synthetic poll refusal')
                if not ready:
                    return []
                descriptor = self.descriptor + 1 if wrong_descriptor else self.descriptor
                events = [(descriptor, select.POLLIN if poll_mask is None else poll_mask)]
                return events * 2 if duplicate_events else events

        def close(descriptor):
            test.assertIn(descriptor, handles, 'only this fixture owns the descriptor')
            test.assertNotIn(descriptor, state['closed'], 'descriptor closed more than once')
            state['closed'].append(descriptor)
            if close_errno is not None:
                raise OSError(close_errno, 'synthetic close refusal')

        with mock.patch.object(observer, 'snapshot', return_value=rows), \
                mock.patch.object(observer, 'process_row', side_effect=identity), \
                mock.patch.object(Path, 'iterdir', new=inventory), \
                mock.patch.object(Path, 'open', new=opened), \
                mock.patch.object(os, 'pidfd_open', side_effect=pidfd_open, create=True), \
                mock.patch.object(select, 'poll', new=Poll), \
                mock.patch.object(os, 'close', side_effect=close):
            yield state
        self.assertCountEqual(state['opened'], state['closed'], 'pidfd ownership leaked')
        self.assertCountEqual(state['fdinfo_opened'], state['fdinfo_closed'], 'fdinfo stream leaked')

    def observed(self, diagnostics=False, identity_diagnostics=False):
        result = observer.Observer(self.token, diagnostics=diagnostics,
                                   identity_diagnostics=identity_diagnostics)
        result.known.add((self.pid, self.row['start']))
        return result

    def test_enoent_after_leader_exit_requires_independent_group_termination(self):
        for diagnostics, identity in ((False, False), (True, False), (True, True)):
            with self.subTest(diagnostics=diagnostics, identity=identity), self.retired_group() as state:
                observed = self.observed(diagnostics, identity)
                result = observed.sample()
                self.assertFalse(result['live'], 'independently terminated group remained live')
                self.assertFalse(result['url_in_argv'])
                self.assertIsNone(observed.error)
                self.assertTrue(state['inventories'], 'missing task inventory was not exercised')
                self.assertTrue(state['polls'], 'a missing inventory alone was accepted as termination')
                self.assertEqual(state['reads'], ['environ'])

    def test_missing_task_inventory_without_termination_evidence_remains_blocking(self):
        for diagnostics, identity in ((False, False), (True, False), (True, True)):
            with self.subTest(diagnostics=diagnostics, identity=identity), \
                    self.retired_group(ready=False) as state:
                observed = self.observed(diagnostics, identity)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertIs(observed.error, failure.exception)
                self.assertTrue(state['inventories'])
                with mock.patch.object(observer, 'snapshot', return_value={}):
                    with self.assertRaises(observer.ObservationError) as repeated:
                        observed.sample()
                self.assertIs(repeated.exception, failure.exception)

    def test_inventory_guard_accepts_only_independently_terminated_group(self):
        for diagnostics, identity in ((False, False), (True, False), (True, True)):
            with self.subTest(diagnostics=diagnostics, identity=identity), \
                    self.retired_group(already_exited=True, leader_inventory=True) as state:
                observed = self.observed(diagnostics, identity)
                result = observed.sample()
                self.assertFalse(result['live'], 'terminal pidfd evidence did not resolve the inventory race')
                self.assertIsNone(observed.error)
                self.assertGreaterEqual(len(state['inventories']), 2)
                self.assertTrue(state['polls'], 'the inventory guard was bypassed without independent evidence')
                self.assertEqual(state['reads'], [], 'memory of the retired leader was requested')

    def test_inventory_guard_retains_enoent_origin_without_terminal_evidence(self):
        with self.retired_group(ready=False, already_exited=True, leader_inventory=True):
            observed = self.observed(True, True)
            with self.assertRaises(observer.ObservationError) as failure:
                observed.sample()
            self.assertEqual(failure.exception.errno, errno.EIO)
            private = observed.identity_failure(failure.exception)
            self.assertTrue(private['complete'])
            events = private['events']
            first = [event for event in events if event['first_failure']]
            self.assertEqual(len(first), 1)
            self.assertEqual((first[0]['operation'], first[0]['phase'], first[0]['primitive_errno']),
                             ('task_inventory', 'quiescence_check', errno.ENOENT))
            guards = [event for event in events if event['operation'] == 'inventory_guard']
            self.assertTrue(guards)
            self.assertEqual((guards[0]['primitive_errno'], guards[0]['primitive_origin']),
                             (errno.EIO, 'application_state_check'))
            self.assertIs(observed.error, failure.exception)

    def test_unproven_pidfd_states_cannot_accept_a_missing_inventory(self):
        cases = (
            dict(ready=False),
            dict(pidfd_errno=errno.ESRCH),
            dict(pidfd_errno=errno.ENOSYS),
            dict(pidfd_errno=errno.EACCES),
            dict(pidfd_errno=errno.EIO),
            dict(poll_errno=errno.EINTR),
            dict(poll_errno=errno.EIO),
            dict(poll_mask=select.POLLERR),
            dict(poll_mask=select.POLLNVAL),
            dict(poll_mask=select.POLLIN | select.POLLERR),
            dict(poll_mask=select.POLLIN | select.POLLNVAL),
            dict(poll_mask=select.POLLOUT),
            dict(poll_mask=select.POLLIN | 0x40000000),
            dict(wrong_descriptor=True),
            dict(duplicate_events=True),
        )
        for options in cases:
            with self.subTest(options=options), \
                    self.retired_group(already_exited=True, leader_inventory=True, **options):
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                expected_final = errno.ENOENT if 'poll_errno' in options else errno.EIO
                self.assertEqual(failure.exception.errno, expected_final)
                self.assertIs(observed.error, failure.exception)
                private = observed.identity_failure(failure.exception)
                first = [event for event in private['events'] if event['first_failure']]
                self.assertEqual(len(first), 1)
                expected_first = options.get('pidfd_errno', errno.ENOENT)
                self.assertEqual(first[0]['primitive_errno'], expected_first,
                                 'the diagnostic changed the primitive chronological order')
                expected_operation = 'pidfd_open' if 'pidfd_errno' in options else 'task_inventory'
                self.assertEqual(first[0]['operation'], expected_operation)
                self.assertTrue(any(event['operation'] == 'task_inventory'
                                    and event['primitive_errno'] == errno.ENOENT
                                    for event in private['events']),
                                'failed auxiliary evidence erased the missing inventory')

    def test_permission_and_io_failure_remain_latched_after_group_termination(self):
        for number in (errno.EACCES, errno.EIO):
            for diagnostics, identity in ((False, False), (True, False), (True, True)):
                with self.subTest(errno=number, diagnostics=diagnostics, identity=identity), \
                        self.retired_group(read_errno=number) as state:
                    observed = self.observed(diagnostics, identity)
                    with self.assertRaises(observer.ObservationError) as failure:
                        observed.sample()
                    self.assertEqual(failure.exception.errno, number)
                    self.assertIs(observed.error, failure.exception)
                    poll_count = len(state['polls'])
                    with mock.patch.object(observer, 'snapshot', return_value={}):
                        with self.assertRaises(observer.ObservationError) as repeated:
                            observed.sample()
                    self.assertIs(repeated.exception, failure.exception)
                    self.assertEqual(len(state['polls']), poll_count,
                                     'a latched privacy gap consulted a new termination witness')

    def test_terminal_evidence_never_erases_a_previous_argument_leak(self):
        with self.retired_group(already_exited=True, leader_inventory=True):
            observed = self.observed()
            identity = self.pid, self.row['start']
            observed.leaks.add(identity)
            result = observed.sample()
            self.assertFalse(result['live'])
            self.assertEqual(result['url_in_argv'], [identity],
                             'termination evidence erased the prior privacy verdict')

    def test_pidfd_replacement_or_disappearance_cannot_certify_the_old_group(self):
        for options in (dict(replace_on_open=True), dict(gone_on_open=True)):
            with self.subTest(options=options), \
                    self.retired_group(already_exited=True, leader_inventory=True, **options) as state:
                observed = self.observed(True, True)
                try:
                    result = observed.sample()
                except observer.ObservationError as error:
                    self.assertIs(observed.error, error)
                else:
                    self.assertTrue(result['live'], 'unbound pidfd was accepted as terminal evidence')
                self.assertEqual(state['polls'], [], 'an unbound pidfd was polled as the old identity')
                self.assertEqual(observed.known, {(self.pid, self.row['start'])})

    def test_zombie_leader_with_a_live_sibling_remains_live(self):
        for ready in (False, True):
            with self.subTest(pidfd_ready=ready), \
                    self.retired_group(ready=ready, already_exited=True, sibling_live=True) as state:
                observed = self.observed(True, True)
                result = observed.sample()
                self.assertIn(str(self.pid), result['live'])
                self.assertIsNone(observed.error)
                self.assertEqual(state['reads'], ['environ', 'cmdline'])
                self.assertEqual(state['read_tids'], [self.tid, self.tid])
                self.assertEqual(state['polls'], [], 'readable live sibling was replaced by a stop inference')

    @contextmanager
    def vanishing_thread(self, scans, *, after_open=False, open_errno=errno.ESRCH,
                         preceding_gap=False, replace_before_read=False, **options):
        """Select a running nonleader, fail its environ open, then expose successive task inventories."""
        task_root = self.root / 'task'
        sibling = task_root / str(self.tid)
        preceding = task_root / str(self.tid + 3)
        with self.retired_group(already_exited=True, sibling_live=True,
                                read_errno=open_errno if after_open else None, **options) as state:
            state['task']['state'] = 'R'
            state['thread_opens'] = 0
            remaining = iter(scans)
            current = {}
            sibling_stat_reads = 0
            previous_open, previous_inventory, previous_stat = Path.open, Path.iterdir, observer.process_row

            def opened(path, *args, **kwargs):
                if preceding_gap and path == preceding / 'environ':
                    raise ProcessLookupError(errno.ESRCH, 'synthetic preceding thread gap')
                if path == sibling / 'environ':
                    state['thread_opens'] += 1
                    if not after_open:
                        raise OSError(open_errno, 'synthetic thread environment open')
                return previous_open(path, *args, **kwargs)

            def inventory(path):
                nonlocal current
                if not state['thread_opens']:
                    if preceding_gap:
                        yield preceding
                    yield from previous_inventory(path)
                    return
                self.assertEqual(path, task_root)
                current = next(remaining, scans[-1])
                yield task_root / str(self.pid)
                if isinstance(current, OSError):
                    raise current
                yield from (task_root / str(tid) for tid in current)

            def identity(path):
                nonlocal sibling_stat_reads
                if path == preceding / 'stat':
                    return dict(self.row, start=12403, state='R')
                if path == sibling / 'stat' and not state['thread_opens']:
                    sibling_stat_reads += 1
                    if replace_before_read and sibling_stat_reads == 2:
                        state['task']['start'] += 1
                if path.parent.parent == task_root and isinstance(current, dict) and int(path.parent.name) in current:
                    value = current[int(path.parent.name)]
                    if isinstance(value, OSError):
                        raise value
                    start, status = value
                    return dict(self.row, start=start, state=status)
                return previous_stat(path)

            with mock.patch.object(Path, 'open', new=opened), mock.patch.object(Path, 'iterdir', new=inventory), \
                    mock.patch.object(observer, 'process_row', side_effect=identity):
                yield state

    def test_vanishing_thread_needs_bound_whole_group_readiness(self):
        end = {self.tid: (12399, 'Z')}
        missing = {self.tid: FileNotFoundError(errno.ENOENT, 'synthetic thread stat')}
        lost_inventory = FileNotFoundError(errno.ENOENT, 'synthetic task inventory')
        for first in (end, {self.tid: (12399, 'R')}, missing, lost_inventory):
            for ready in (False, True):
                for diagnostics, identity in ((False, False), (True, False), (True, True)):
                    with self.subTest(first=first, ready=ready, diagnostics=diagnostics, identity=identity), \
                            self.vanishing_thread((first, {}), ready=ready) as state:
                        observed = self.observed(diagnostics, identity)
                        if ready:
                            result = observed.sample()
                            self.assertFalse(result['live'])
                            self.assertFalse(result['url_in_argv'])
                            self.assertIsNone(observed.error)
                        else:
                            with self.assertRaises(observer.ObservationError) as failure:
                                observed.sample()
                            self.assertEqual(failure.exception.errno, errno.ESRCH)
                            self.assertIs(observed.error, failure.exception)
                            if identity:
                                events = observed.identity_failure(failure.exception)['events']
                                self.assertEqual((events[0]['operation'], events[0]['primitive_errno']),
                                                 ('attribute_open', errno.ESRCH))
                        self.assertEqual(state['thread_opens'], 1)
                        self.assertEqual(len(state['opened']), 1)
                        self.assertEqual(state['fdinfo_closed'], state['opened'])
                        self.assertEqual(state['polls'], state['opened'])
                        self.assertEqual(state['closed'], state['opened'])

    def test_vanishing_thread_cannot_certify_survivors_replacements_or_strong_errors(self):
        target = {self.tid: (12399, 'R')}
        end = {self.tid: (12399, 'Z')}
        survivors = {self.tid + 1: (12500, 'S'), self.tid + 2: (12501, 'R')}
        cases = (
            ((target, target), {}, errno.ESRCH),
            ((end, survivors), {}, errno.ESRCH),
            (({self.tid: (12400, 'Z')}, {}), {}, errno.ESRCH),
            ((end, {self.tid + 1: (12500, 'Z')}), {}, errno.ESRCH),
            (({self.tid: OSError(errno.EIO, 'synthetic stat refusal')}, {}), {}, errno.ESRCH),
            (({self.tid + 1: FileNotFoundError(errno.ENOENT, 'synthetic other task')}, {}), {}, errno.ESRCH),
            ((end, {}), {'open_errno': errno.EACCES}, errno.EACCES),
            ((end, {}), {'after_open': True}, errno.ESRCH),
            ((end, {}), {'preceding_gap': True}, errno.ESRCH),
            (({self.tid: (12400, 'Z')}, {}), {'replace_before_read': True}, errno.ESRCH),
            ((end, {}), {'pidfd_errno': errno.ENOSYS}, errno.ESRCH),
            ((end, {}), {'fdinfo_payload': b'Pid:\t1\n'}, errno.ESRCH),
            ((end, {}), {'earlier_memory_error': errno.EACCES}, errno.EACCES),
        )
        for scans, options, expected in cases:
            for diagnostics, identity in ((False, False), (True, False), (True, True)):
                with self.subTest(scans=scans, options=options, diagnostics=diagnostics, identity=identity), \
                        self.vanishing_thread(scans, **options) as state:
                    observed = self.observed(diagnostics, identity)
                    if 'earlier_memory_error' in options:
                        observed.known.add((self.pid - 1, self.row['start'] - 1))
                    with self.assertRaises(observer.ObservationError) as failure:
                        observed.sample()
                    self.assertEqual(failure.exception.errno, expected)
                    self.assertIs(observed.error, failure.exception)
                    self.assertFalse(state['polls'])
                    self.assertEqual(state['closed'], state['opened'])
                    if identity and isinstance(scans[0].get(self.tid), OSError):
                        events = observed.identity_failure(failure.exception)['events']
                        self.assertIn(('stat_read', errno.EIO),
                                      [(e['operation'], e['primitive_errno']) for e in events])

    def test_vanishing_thread_proof_errors_retain_the_open_and_inventory_gap(self):
        missing = {self.tid: FileNotFoundError(errno.ENOENT, 'synthetic thread stat')}
        cases = (
            (missing, 'stat_read', 'pidfd_close', {'close_errno': errno.EIO}, errno.EIO),
            (missing, 'stat_read', 'pidfd_poll', {'poll_errno': errno.EIO}, errno.ESRCH),
            (FileNotFoundError(errno.ENOENT, 'synthetic inventory'), 'task_inventory', 'pidfd_close',
             {'close_errno': errno.EIO}, errno.EIO),
        )
        for first, gap, operation, options, expected in cases:
            for diagnostics, identity in ((False, False), (True, False), (True, True)):
                with self.subTest(gap=gap, operation=operation, diagnostics=diagnostics, identity=identity), \
                        self.vanishing_thread((first, {}), **options) as state:
                    observed = self.observed(diagnostics, identity)
                    with self.assertRaises(observer.ObservationError) as failure:
                        observed.sample()
                    self.assertEqual(failure.exception.errno, expected)
                    self.assertIs(observed.error, failure.exception)
                    self.assertEqual(len(state['opened']), 1)
                    self.assertEqual(state['polls'], state['opened'])
                    self.assertEqual(state['closed'], state['opened'])
                    if identity:
                        packet = observed.identity_failure(failure.exception)
                        self.assertTrue(packet['complete'])
                        self.assertEqual([(e['operation'], e['primitive_errno']) for e in packet['events']],
                                         [('attribute_open', errno.ESRCH), (gap, errno.ENOENT),
                                          (operation, errno.EIO), ('error_normalization', None)])

    def test_reused_task_cannot_be_accepted_through_a_group_pidfd(self):
        with self.retired_group(already_exited=True, sibling_live=True, reuse_task=True) as state:
            observed = self.observed(True, True)
            with self.assertRaises(observer.ObservationError) as failure:
                observed.sample()
            self.assertEqual(failure.exception.errno, errno.ESRCH)
            self.assertIs(observed.error, failure.exception)
            self.assertEqual(state['polls'], [])
            private = observed.identity_failure(failure.exception)
            first = [event for event in private['events'] if event['first_failure']]
            self.assertEqual(len(first), 1)
            self.assertEqual((first[0]['operation'], first[0]['phase'], first[0]['primitive_origin']),
                             ('identity_guard', 'task_stat_after', 'application_identity_check'))

    def test_strong_inventory_errors_and_unexplained_empty_inventory_stay_blocking(self):
        for number in (errno.EACCES, errno.EIO, None):
            with self.subTest(inventory_errno=number), \
                    self.retired_group(already_exited=True, inventory_errno=number) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertEqual(failure.exception.errno, errno.EIO if number is None else number)
                self.assertIs(observed.error, failure.exception)
                self.assertEqual(state['polls'], [], 'a strong or unexplained inventory gap was ignored')

    def test_bound_group_readiness_accepts_documented_exit_masks(self):
        for mask in (select.POLLIN, select.POLLHUP, select.POLLIN | select.POLLHUP):
            with self.subTest(mask=mask), \
                    self.retired_group(already_exited=True, leader_inventory=True, poll_mask=mask) as state:
                observed = self.observed()
                result = observed.sample()
                self.assertFalse(result['live'])
                self.assertIsNone(observed.error)
                self.assertEqual(state['polls'], state['opened'])

    def test_complete_historical_inventory_does_not_require_auxiliary_pidfd(self):
        self.row['state'] = 'Z'
        for number in (errno.ENOSYS, errno.ESRCH, errno.EACCES, errno.EIO):
            with self.subTest(pidfd_errno=number), \
                    self.retired_group(already_exited=True, complete_inventory=True,
                                       pidfd_errno=number) as state:
                observed = self.observed(True, True)
                result = observed.sample()
                self.assertFalse(result['live'])
                self.assertIn(self.pid, result['zombies'])
                self.assertIsNone(observed.error)
                self.assertEqual(state['polls'], [])
                self.assertGreaterEqual(len(state['inventories']), 2)

    def test_close_failure_preserves_an_initial_gap_and_never_returns_success(self):
        for ready in (False, True):
            with self.subTest(terminal_evidence=ready), \
                    self.retired_group(ready=ready, already_exited=True, leader_inventory=True,
                                       close_errno=errno.EIO) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertEqual(failure.exception.errno, errno.EIO)
                self.assertIs(observed.error, failure.exception)
                private = observed.identity_failure(failure.exception)
                first = [event for event in private['events'] if event['first_failure']]
                self.assertEqual(len(first), 1)
                self.assertEqual((first[0]['operation'], first[0]['primitive_errno']),
                                 ('task_inventory', errno.ENOENT),
                                 'resolved inventory evidence vanished from the close failure chain')
                close_events = [event for event in private['events'] if event['operation'] == 'pidfd_close']
                self.assertTrue(close_events)
                self.assertEqual(close_events[-1]['primitive_errno'], errno.EIO)
                self.assertCountEqual(state['opened'], state['closed'])

    def test_unattributed_group_never_acquires_a_pidfd(self):
        with self.retired_group(already_exited=True, leader_inventory=True) as state:
            result = observer.Observer(self.token).sample()
            self.assertFalse(result['live'])
            self.assertEqual(state['opened'], [])
            self.assertEqual(state['polls'], [])
            self.assertEqual(state['closed'], [])

    @contextmanager
    def retiring_descendant(self, observed, *, parent_source='known', child_first=False,
                            change=None, open_errno=errno.ESRCH, leader_inventory=True, **retirement):
        """Inject an attribute-open race on a new descendant of a separate parent."""
        parent = self.pid + 10
        parent_root = Path(f'/proc/{parent}')
        parent_row = dict(self.row, start=self.row['start'] - 1)
        child_row = dict(self.row, state='R', parent=parent)
        rows = {parent: dict(parent_row), self.pid: dict(child_row)}
        if child_first:
            rows = dict(reversed(rows.items()))
        if parent_source == 'known':
            observed.known.add((parent, parent_row['start']))
        with self.retired_group(leader_inventory=leader_inventory, **retirement) as state:
            if retirement.get('earlier_memory_error') is not None:
                earlier_pid = self.pid - 1
                earlier_row = observer.snapshot()[earlier_pid]
                observed.known.add((earlier_pid, earlier_row['start']))
                rows = {earlier_pid: earlier_row, **rows}
            state['row'] = child_row
            state['child_opens'] = 0
            parent_seen_after_exit = False
            post_read_stat_failure = False
            previous_stat = observer.process_row
            previous_open = Path.open

            class OpenedMemory:
                def __enter__(self):
                    return self

                def read(self):
                    if change == 'stream-read':
                        raise ProcessLookupError(errno.ESRCH, 'synthetic stream read failure')
                    return b'fixture\0'

                def __exit__(self, *_exception):
                    if change == 'stream-close':
                        raise ProcessLookupError(errno.ESRCH, 'synthetic stream close failure')
                    return False

            def stat(path):
                nonlocal parent_seen_after_exit, post_read_stat_failure
                if path == parent_root / 'stat':
                    parent_seen_after_exit = bool(state['child_opens'])
                    return dict(parent_row)
                if change == 'parent-reused-during-check' and parent_seen_after_exit and path == self.root / 'stat':
                    parent_row['start'] += 1
                    parent_seen_after_exit = False
                if post_read_stat_failure and path == self.root / 'stat':
                    post_read_stat_failure = False
                    raise ProcessLookupError(errno.ESRCH, 'synthetic post-read task stat failure')
                return previous_stat(path)

            def opened(path, *args, **kwargs):
                nonlocal post_read_stat_failure
                if path.parent == parent_root:
                    self.assertIn(path.name, ('cmdline', 'environ'))
                    data = b'fixture\0'
                    if path.name == 'environ' and parent_source in ('marker', 'external'):
                        data = self.marker + b'\0'
                        if parent_source == 'external':
                            data += b'YTDLP_QUALIFICATION_EXTERNAL=1\0'
                    return io.BytesIO(data)
                if path == self.root / 'environ':
                    self.assertEqual(child_row['state'], 'R')
                    state['child_opens'] += 1
                    child_row['state'] = 'Z'
                    if change in ('stream-read', 'stream-close'):
                        return OpenedMemory()
                    if change in ('post-read-stat', 'post-read-guard'):
                        post_read_stat_failure = change == 'post-read-stat'
                        return io.BytesIO(b'fixture\0')
                    if change == 'parent-reused':
                        parent_row['start'] += 1
                    if change == 'child-reparented':
                        child_row['parent'] = 1
                    if change == 'child-reused':
                        child_row['start'] += 1
                    raise OSError(open_errno, 'synthetic attribute-open failure')
                if change == 'external-sibling' and path == self.root / 'task' / str(self.tid) / 'environ':
                    return io.BytesIO(self.marker + b'\0YTDLP_QUALIFICATION_EXTERNAL=1\0')
                return previous_open(path, *args, **kwargs)

            with mock.patch.object(observer, 'snapshot', return_value=rows), \
                    mock.patch.object(observer, 'process_row', side_effect=stat), \
                    mock.patch.object(Path, 'open', new=opened):
                yield parent, state
            self.assertEqual(state['child_opens'], 1)

    def test_new_descendant_needs_bound_whole_group_exit_evidence(self):
        for diagnostics, identity in ((False, False), (True, False), (True, True)):
            for parent_source in ('known', 'marker'):
                for child_first in (True, False):
                    with self.subTest(diagnostics=diagnostics, identity=identity,
                                      parent=parent_source, child_first=child_first):
                        observed = observer.Observer(self.token, diagnostics=diagnostics,
                                                     identity_diagnostics=identity)
                        with self.retiring_descendant(observed, parent_source=parent_source,
                                                     child_first=child_first) as (parent, state):
                            result = observed.sample()
                            self.assertEqual(set(result['live']), {str(parent)})
                            self.assertEqual(len(state['opened']), 1)
                            self.assertEqual(state['opened'], state['polls'])
                            self.assertEqual(state['opened'], state['closed'])
                            self.assertEqual(state['fdinfo_reads'], [4097])
                            self.assertIsNone(observed.error)

    def test_new_descendant_preserves_incomplete_and_strong_failures(self):
        for options, expected in ((dict(ready=False), errno.EIO),
                                  (dict(open_errno=errno.EACCES), errno.EACCES),
                                  (dict(open_errno=errno.EIO), errno.EIO)):
            with self.subTest(options=options):
                observed = observer.Observer(self.token, diagnostics=True, identity_diagnostics=True)
                prior_leak = (self.pid + 20, self.row['start'] + 20)
                observed.leaks.add(prior_leak)
                with self.retiring_descendant(observed, **options) as (_, state):
                    with self.assertRaises(observer.ObservationError) as failure:
                        observed.sample()
                    self.assertEqual(failure.exception.errno, expected)
                    self.assertIn(prior_leak, observed.leaks)
                    first = next(event for event in observed.identity_failure(failure.exception)['events']
                                 if event['first_failure'])
                    self.assertEqual((first['operation'], first['primitive_errno']),
                                     ('attribute_open', options.get('open_errno', errno.ESRCH)))
                    with self.assertRaises(observer.ObservationError) as repeated:
                        observed.sample()
                    self.assertIs(repeated.exception, failure.exception)
                    if not options.get('ready', True):
                        self.assertTrue(state['polls'])

    def test_new_descendant_close_failure_retains_the_resolved_open_and_inventory(self):
        for diagnostics, identity in ((False, False), (True, False), (True, True)):
            with self.subTest(diagnostics=diagnostics, identity=identity):
                observed = observer.Observer(self.token, diagnostics=diagnostics, identity_diagnostics=identity)
                with self.retiring_descendant(observed, close_errno=errno.EIO) as (_, state):
                    with self.assertRaises(observer.ObservationError) as failure:
                        observed.sample()
                    with self.assertRaises(observer.ObservationError) as repeated:
                        observed.sample()
                    self.assertIs(repeated.exception, failure.exception)
                    self.assertEqual(failure.exception.errno, errno.EIO)
                    self.assertEqual(len(state['opened']), 1)
                    self.assertEqual(state['polls'], state['opened'])
                    self.assertEqual(state['closed'], state['opened'])
                packets = []
                if diagnostics:
                    packets.append((observed.diagnostic_failure(failure.exception), 'attribute_read'))
                if identity:
                    packets.append((observed.identity_failure(failure.exception), 'attribute_open'))
                for packet, first_operation in packets:
                    events = packet['events']
                    self.assertTrue(packet['complete'])
                    self.assertEqual([(event['operation'], event['primitive_errno']) for event in events],
                                     [(first_operation, errno.ESRCH), ('task_inventory', errno.ENOENT),
                                      ('pidfd_close', errno.EIO), ('error_normalization', None)])
                    self.assertTrue(events[0]['first_failure'])
                    self.assertEqual(events[-1]['cause_sequence'], events[2]['sequence'])
                    self.assertEqual(events[-1]['normalized_errno'], errno.EIO)

    def test_new_descendant_requires_current_parent_and_child_identities(self):
        for change in ('parent-reused', 'parent-reused-during-check', 'child-reparented', 'child-reused'):
            with self.subTest(change=change):
                observed = observer.Observer(self.token)
                with self.retiring_descendant(observed, change=change) as (_, state):
                    if change == 'child-reused':
                        observed.sample()
                        self.assertNotIn((self.pid, state['row']['start']), observed.known)
                    else:
                        with self.assertRaises(observer.ObservationError):
                            observed.sample()
                    self.assertFalse(state['opened'])

    def test_descendant_esrch_after_open_never_grants_new_exit_proof(self):
        cases = (('post-read-stat', 'stat_read', 'task_stat_after'),
                 ('post-read-guard', 'identity_guard', 'task_stat_after'),
                 ('stream-read', 'attribute_read', 'attribute_read'),
                 ('stream-close', 'attribute_close', 'attribute_read'))
        for diagnostics, identity in ((False, False), (True, False), (True, True)):
            for change, operation, phase in cases:
                with self.subTest(change=change, diagnostics=diagnostics, identity=identity):
                    observed = observer.Observer(self.token, diagnostics=diagnostics,
                                                 identity_diagnostics=identity)
                    with self.retiring_descendant(observed, parent_source='marker', change=change) as (_, state):
                        with self.assertRaises(observer.ObservationError) as failure:
                            observed.sample()
                        self.assertEqual(failure.exception.errno, errno.EIO)
                        self.assertIs(observed.error, failure.exception)
                        self.assertFalse(state['opened'])
                        self.assertFalse(state['polls'])
                        if identity:
                            first = next(event for event in observed.identity_failure(failure.exception)['events']
                                         if event['first_failure'])
                            self.assertEqual((first['operation'], first['phase'], first['primitive_errno']),
                                             (operation, phase, errno.ESRCH))

    def test_external_parent_never_grants_descendant_exit_authority(self):
        observed = observer.Observer(self.token)
        with self.retiring_descendant(observed, parent_source='external', child_first=True) as (parent, state):
            result = observed.sample()
            self.assertFalse(result['live'])
            self.assertIn((parent, self.row['start'] - 1), observed.external)
            self.assertFalse(state['opened'])

    def test_retained_external_child_does_not_acquire_a_pidfd(self):
        observed = observer.Observer(self.token)
        observed.external.add((self.pid, self.row['start']))
        with self.retiring_descendant(observed) as (parent, state):
            result = observed.sample()
            self.assertEqual(set(result['live']), {str(parent)})
            self.assertFalse(state['opened'])

    def test_live_sibling_external_marker_excludes_a_retiring_descendant(self):
        observed = observer.Observer(self.token)
        with self.retiring_descendant(observed, parent_source='marker', child_first=True,
                                     sibling_live=True, change='external-sibling') as (parent, state):
            result = observed.sample()
            self.assertEqual(set(result['live']), {str(parent)})
            self.assertIn((self.pid, self.row['start']), observed.external)
            self.assertFalse(state['opened'])

    def test_missing_initial_descendant_inventory_retains_its_failure(self):
        observed = observer.Observer(self.token, diagnostics=True, identity_diagnostics=True)
        with self.retiring_descendant(observed, leader_inventory=False, ready=False):
            with self.assertRaises(observer.ObservationError) as failure:
                observed.sample()
            self.assertIs(observed.error, failure.exception)
            events = observed.identity_failure(failure.exception)['events']
            self.assertTrue(any(event['operation'] == 'task_inventory'
                                and event['phase'] == 'task_inventory'
                                and event['primitive_errno'] == errno.ENOENT for event in events))

    def test_live_sibling_of_new_descendant_still_requires_argument_inspection(self):
        observed = observer.Observer(self.token)
        with self.retiring_descendant(observed, sibling_live=True) as (_, state):
            result = observed.sample()
            self.assertIn(str(self.pid), result['live'])
            self.assertEqual(state['read_tids'], [self.tid, self.tid])
            self.assertEqual(state['reads'], ['environ', 'cmdline'])
            self.assertFalse(state['polls'])

    def test_new_descendant_cannot_displace_an_earlier_owned_memory_error(self):
        observed = observer.Observer(self.token, diagnostics=True, identity_diagnostics=True)
        with self.retiring_descendant(observed, earlier_memory_error=errno.EACCES, ready=False):
            with self.assertRaises(observer.ObservationError) as failure:
                observed.sample()
            self.assertIs(observed.error, failure.exception)
            self.assertEqual(failure.exception.errno, errno.EACCES)
            first = next(event for event in observed.identity_failure(failure.exception)['events']
                         if event['first_failure'])
            self.assertEqual((first['operation'], first['context']['group_expected']['pid']),
                             ('attribute_read', self.pid - 1))

    def test_resolved_descendant_close_preserves_another_groups_prior_memory_failure(self):
        observed = observer.Observer(self.token, diagnostics=True, identity_diagnostics=True)
        with self.retiring_descendant(observed, earlier_memory_error=errno.EACCES,
                                      close_errno=errno.EIO) as (_, state):
            # Read this group's environment first. Its refusal is processed after its parent's exit proof.
            earlier_pid = self.pid - 1
            earlier = observer.snapshot()[earlier_pid]
            observed.known.remove((earlier_pid, earlier['start']))
            earlier['parent'] = self.pid
            with self.assertRaises(observer.ObservationError) as failure:
                observed.sample()
            self.assertEqual(failure.exception.errno, errno.EACCES)
            self.assertIs(observed.error, failure.exception)
            self.assertEqual(len(state['opened']), 1)
            self.assertEqual(state['polls'], state['opened'])
            self.assertEqual(state['closed'], state['opened'])
            events = observed.identity_failure(failure.exception)['events']
            self.assertEqual((events[0]['operation'], events[0]['primitive_errno'],
                              events[0]['context']['group_expected']['pid']),
                             ('attribute_read', errno.EACCES, earlier_pid))
            self.assertEqual([(event['primitive_errno'], event['context']['group_expected']['pid'])
                              for event in events if event['operation'] == 'pidfd_close'], [(errno.EIO, self.pid)])

    def test_normalization_keeps_the_first_failing_close_group_identity(self):
        closed = []
        private = 'synthetic-private-close-detail'
        observed = self.observed(True, True)
        groups = ((44444, 12345, 900001), (44446, 12400, 900002))
        observed.known.update((pid, start) for pid, start, _descriptor in groups)

        def body():
            proofs = observer._GROUP_EXIT_PROOFS.get()
            for pid, start, descriptor in groups:
                row = dict(self.row, start=start, state='Z')
                proofs.handles[pid, start] = pid, row, descriptor
                proofs.attributions[pid, start] = 'known_identity'
            return dict(live={}, zombies=[], url_in_argv=[])

        def close(descriptor):
            closed.append(descriptor)
            raise OSError(errno.EIO if descriptor == groups[0][2] else errno.EACCES, private)

        observed._sample = body
        with unavailable_synthetic_pidfds(), \
                mock.patch.object(observer.os, 'close', side_effect=close):
            with self.assertRaises(observer.ObservationError) as failure:
                observed.sample()
        self.assertEqual(closed, [row[2] for row in groups])
        self.assertEqual(failure.exception.errno, errno.EIO)
        self.assertIs(observed.error, failure.exception)
        packet = observed.identity_failure(failure.exception)
        self.assertTrue(packet['complete'])
        events = packet['events']
        self.assertEqual([event['operation'] for event in events],
                         ['pidfd_close', 'pidfd_close', 'error_normalization'])
        normalized = events[-1]
        cause = events[normalized['cause_sequence'] - 1]
        self.assertEqual((cause['primitive_errno'], normalized['normalized_errno']),
                         (errno.EIO, errno.EIO))
        self.assertEqual(cause['context']['group_expected']['pid'], groups[0][0])
        self.assertEqual(events[1]['context']['group_expected']['pid'], groups[1][0])
        self.assertEqual(normalized['context']['group_expected'], cause['context']['group_expected'],
                         'normalization was attributed to another failing descriptor')
        self.assertNotIn(private, json.dumps(packet))

    def test_pidfd_namespace_identity_must_match_the_observed_procfs_group(self):
        payloads = (
            f'Pid:\t{self.pid + 1}\n'.encode(), b'Pid:\t0\n', b'Pid:\t-1\n', b'',
            f'Pid:\t{self.pid}\nPid:\t{self.pid}\n'.encode(), b'Pid:\tnot-a-pid\n',
            f'Pid:\t{self.pid}\n'.encode() + b'x' * 4097,
            b'Pid:\t0\nNote:\tsynthetic-private-fdinfo-detail\n',
        )
        for payload in payloads:
            with self.subTest(fdinfo_case=payloads.index(payload)), \
                    self.retired_group(already_exited=True, leader_inventory=True,
                                       fdinfo_payload=payload) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertIs(observed.error, failure.exception)
                self.assertEqual(state['polls'], [], 'an identity from another procfs PID view was trusted')
                packet = observed.identity_failure(failure.exception)
                self.assertTrue(packet['complete'])
                self.assertNotIn('synthetic-private-fdinfo-detail', json.dumps(packet))
        for number in (errno.ENOENT, errno.EACCES, errno.EIO):
            with self.subTest(fdinfo_errno=number), \
                    self.retired_group(already_exited=True, leader_inventory=True,
                                       fdinfo_errno=number) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertIs(observed.error, failure.exception)
                self.assertEqual(state['polls'], [], 'unreadable pidfd identity became exit authority')

    def test_bad_pidfd_namespace_evidence_does_not_replace_a_complete_inventory(self):
        self.row['state'] = 'Z'
        with self.retired_group(already_exited=True, complete_inventory=True,
                               fdinfo_payload=f'Pid:\t{self.pid + 1}\n'.encode()) as state:
            observed = self.observed(True, True)
            result = observed.sample()
            self.assertFalse(result['live'])
            self.assertIn(self.pid, result['zombies'])
            self.assertIsNone(observed.error)
            self.assertEqual(state['polls'], [])

    def test_fdinfo_close_failure_remains_blocking_after_complete_inventory(self):
        self.row['state'] = 'Z'
        for read_errno in (None, errno.EACCES):
            with self.subTest(read_errno=read_errno), \
                    self.retired_group(already_exited=True, complete_inventory=True,
                                       fdinfo_errno=read_errno, fdinfo_close_errno=errno.EIO) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertEqual(failure.exception.errno, errno.EIO)
                self.assertIs(observed.error, failure.exception)
                packet = observed.identity_failure(failure.exception)
                self.assertTrue(packet['complete'])
                first = [event for event in packet['events'] if event['first_failure']]
                self.assertEqual(len(first), 1)
                operation = 'pidfd_fdinfo_close' if read_errno is None else 'pidfd_fdinfo_read'
                self.assertEqual((first[0]['operation'], first[0]['primitive_errno']),
                                 (operation, errno.EIO if read_errno is None else read_errno))
                normalized = packet['events'][-1]
                self.assertEqual(normalized['normalized_errno'], errno.EIO)
                cause = packet['events'][normalized['cause_sequence'] - 1]
                self.assertEqual(cause['operation'], 'pidfd_fdinfo_close')
                self.assertEqual(state['polls'], [])
                self.assertEqual(state['fdinfo_reads'], [4097])

    def test_fdinfo_close_failure_precedes_a_later_inventory_refusal(self):
        for read_errno in (None, errno.EACCES):
            with self.subTest(fdinfo_read_errno=read_errno), \
                    self.retired_group(already_exited=True, inventory_errno=errno.EEXIST,
                                       fdinfo_errno=read_errno, fdinfo_close_errno=errno.EIO) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertEqual(failure.exception.errno, errno.EIO,
                                 'a later inventory refusal replaced the earlier close failure')
                self.assertIs(observed.error, failure.exception)
                packet = observed.identity_failure(failure.exception)
                self.assertTrue(packet['complete'])
                first = [event for event in packet['events'] if event['first_failure']]
                self.assertEqual(len(first), 1)
                operation = 'pidfd_fdinfo_close' if read_errno is None else 'pidfd_fdinfo_read'
                self.assertEqual((first[0]['operation'], first[0]['primitive_errno']),
                                 (operation, errno.EIO if read_errno is None else read_errno))
                self.assertTrue(any(event['operation'] == 'pidfd_fdinfo_close'
                                    and event['primitive_errno'] == errno.EIO
                                    for event in packet['events']))
                self.assertEqual(state['polls'], [])

    def test_memory_refusal_precedes_a_later_fdinfo_close_failure(self):
        for number in (errno.EACCES, errno.EIO):
            with self.subTest(memory_errno=number), \
                    self.retired_group(read_errno=number, fdinfo_close_errno=errno.EIO) as state:
                observed = self.observed(True, True)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                self.assertEqual(failure.exception.errno, number)
                self.assertIs(observed.error, failure.exception)
                packet = observed.identity_failure(failure.exception)
                self.assertTrue(packet['complete'])
                first = [event for event in packet['events'] if event['first_failure']]
                self.assertEqual(len(first), 1)
                self.assertEqual((first[0]['operation'], first[0]['primitive_errno']),
                                 ('attribute_read', number))
                self.assertTrue(any(event['operation'] == 'pidfd_fdinfo_close'
                                    and event['primitive_errno'] == errno.EIO
                                    for event in packet['events']),
                                'the later descriptor cleanup error was lost')
                self.assertEqual(state['polls'], [])

    def test_earlier_owned_group_error_precedes_another_groups_fdinfo_close(self):
        for attribution in ('known', 'foreign', 'external'):
            with self.subTest(earlier_group=attribution), \
                    self.retired_group(already_exited=True, fdinfo_close_errno=errno.EIO,
                                       earlier_memory_error=errno.EACCES) as state:
                observed = self.observed(True, True)
                earlier_identity = self.pid - 1, self.row['start'] - 1
                if attribution != 'foreign':
                    observed.known.add(earlier_identity)
                if attribution == 'external':
                    observed.external.add(earlier_identity)
                with self.assertRaises(observer.ObservationError) as failure:
                    observed.sample()
                expected = errno.EACCES if attribution == 'known' else errno.EIO
                self.assertEqual(failure.exception.errno, expected)
                self.assertIs(observed.error, failure.exception)
                packet = observed.identity_failure(failure.exception)
                self.assertTrue(packet['complete'])
                first = [event for event in packet['events'] if event['first_failure']]
                self.assertEqual(len(first), 1)
                operation = 'attribute_read' if attribution == 'known' else 'pidfd_fdinfo_close'
                expected_pid = earlier_identity[0] if attribution == 'known' else self.pid
                self.assertEqual((first[0]['operation'], first[0]['primitive_errno']),
                                 (operation, expected))
                self.assertEqual(first[0]['context']['group_expected']['pid'], expected_pid)
                self.assertEqual(packet['events'][-1]['normalized_errno'], expected)
                if attribution != 'known':
                    self.assertFalse(any(event['primitive_errno'] == errno.EACCES
                                         for event in packet['events']),
                                     'an excluded or unattributed group entered the failure chain')
                self.assertEqual(state['polls'], [])

    def test_attribute_reader_matches_native_context_and_error_precedence(self):
        path = self.root / 'environ'
        for fault in ('none', 'open', 'enter', 'read', 'close', 'read-and-close'):
            outcomes = []
            for instrumented in (False, True):
                calls = []
                first = PermissionError(errno.EACCES, 'synthetic private read')
                last = OSError(errno.EIO, 'synthetic private close')

                class Stream:
                    def __enter__(self):
                        calls.append(('enter',))
                        if fault == 'enter':
                            raise first
                        return self

                    def read(self):
                        calls.append(('read',))
                        if fault in ('read', 'read-and-close'):
                            raise first
                        return b'private fixture bytes'

                    def __exit__(self, kind, error, traceback):
                        calls.append(('exit', kind, getattr(error, 'errno', None)))
                        if fault in ('close', 'read-and-close'):
                            raise last
                        return False

                def opened(current, *args, **kwargs):
                    self.assertEqual(current, path)
                    calls.append(('open', args, kwargs))
                    if fault == 'open':
                        raise first
                    return Stream()

                observed = self.observed(True, True)
                scope = observer._DiagnosticScope(observed)
                token = observer._DIAGNOSTIC_SCOPE.set(scope)
                try:
                    with mock.patch.object(Path, 'open', new=opened):
                        try:
                            result = (observer._identity_read_bytes(path) if instrumented
                                      else path.read_bytes())
                            outcome = ('result', result)
                        except OSError as error:
                            self.assertIs(error, last if fault in ('close', 'read-and-close') else first)
                            outcome = ('error', type(error), error.errno)
                    if instrumented:
                        self.assertFalse(observed.diagnostics_incomplete,
                                         'the current inspected reader became opaque')
                    outcomes.append((calls, outcome))
                finally:
                    observer._DIAGNOSTIC_SCOPE.reset(token)
            with self.subTest(fault=fault):
                self.assertEqual(outcomes[0], outcomes[1],
                                 'instrumentation changed native I/O order or exception precedence')

    def test_uninspected_reader_keeps_execution_but_refuses_complete_diagnostics(self):
        path = self.root / 'environ'
        variants = ((3, 9, 'cpython', False), (3, 16, 'cpython', False),
                    (4, 0, 'cpython', False), (3, 15, 'pypy', False),
                    (3, 15, 'cpython', True))
        for major, minor, implementation, customized in variants:
            with self.subTest(major=major, minor=minor, implementation=implementation,
                              customized=customized):
                observed = self.observed(True, True)
                scope = observer._DiagnosticScope(observed)
                token = observer._DIAGNOSTIC_SCOPE.set(scope)
                error = PermissionError(errno.EACCES, 'synthetic private refusal')
                runtime = SimpleNamespace(version_info=SimpleNamespace(major=major, minor=minor),
                                          implementation=SimpleNamespace(name=implementation))
                try:
                    with ExitStack() as stack:
                        stack.enter_context(mock.patch.object(observer, 'sys', runtime))
                        opened = stack.enter_context(mock.patch.object(Path, 'open', side_effect=error))
                        if customized:
                            reader = stack.enter_context(mock.patch.object(Path, 'read_bytes', side_effect=error))
                        with self.assertRaises(PermissionError) as caught:
                            observer._identity_read_bytes(path)
                        self.assertIs(caught.exception, error)
                        self.assertTrue(observed.diagnostics_incomplete)
                        if customized:
                            reader.assert_called_once_with()
                            opened.assert_not_called()
                        else:
                            opened.assert_called_once()
                finally:
                    observer._DIAGNOSTIC_SCOPE.reset(token)

    def test_retirement_mutations_fail_their_behavioral_oracles(self):
        original = (PROJECT / 'tests/process-observer.py').read_text()
        readiness = (
            "            if (len(events) != 1 or events[0][0] != descriptor\n"
            "                    or not events[0][1] & allowed or events[0][1] & ~allowed):")
        binding = '            if not matches or not admissible(after):'
        inventory = (
            "    except FileNotFoundError as error:\n"
            "        proofs = _GROUP_EXIT_PROOFS.get()\n"
            "        if error.errno == errno.ENOENT and proofs is not None "
            "and proofs.resolve_inventory(pid, row, error):")
        changes = (
            ('missing-readiness', readiness, '            if False:',
             'test_unproven_pidfd_states_cannot_accept_a_missing_inventory'),
            ('non-group-flags', "opener, pid, 0)", "opener, pid, 1)",
             'test_enoent_after_leader_exit_requires_independent_group_termination'),
            ('missing-identity-revalidation', binding, '            if not matches:',
             'test_pidfd_replacement_or_disappearance_cannot_certify_the_old_group'),
            ('unbound-descriptor', 'if handle is None or key not in self.bound:',
             'if handle is None:',
             'test_pidfd_replacement_or_disappearance_cannot_certify_the_old_group'),
            ('strong-inventory-as-disappearance', inventory,
             "    except OSError as error:\n"
             "        proofs = _GROUP_EXIT_PROOFS.get()\n"
             "        if proofs is not None and proofs.resolve_inventory(pid, row, error):",
             'test_strong_inventory_errors_and_unexplained_empty_inventory_stay_blocking'),
            ('lost-environment-failure',
             "            if pid in environment_errors:\n"
             "                observation_failure(pid, row, environment_errors[pid])",
             "            if False:\n"
             "                observation_failure(pid, row, environment_errors[pid])",
             'test_permission_and_io_failure_remain_latched_after_group_termination'),
            ('unclosed-descriptor', '                    os.close(descriptor)',
             '                    pass',
             'test_enoent_after_leader_exit_requires_independent_group_termination'),
            ('lost-argument-leak', "'url_in_argv': sorted(self.leaks)", "'url_in_argv': []",
             'test_terminal_evidence_never_erases_a_previous_argument_leak'),
            ('lost-latched-failure',
             '            if self.error is not None:\n                raise self.error',
             '            if False:\n                raise self.error',
             'test_permission_and_io_failure_remain_latched_after_group_termination'),
            ('wrong-pid-namespace', 'and int(values[0]) == pid and pid > 0)',
             'and int(values[0]) > 0 and pid > 0)',
             'test_pidfd_namespace_identity_must_match_the_observed_procfs_group'),
            ('unbounded-fdinfo', 'len(data) > 4096:', 'len(data) > 8192:',
             'test_pidfd_namespace_identity_must_match_the_observed_procfs_group'),
            ('ignored-fdinfo-close', '                    self.cleanup_error = error',
             '                    pass',
             'test_fdinfo_close_failure_remains_blocking_after_complete_inventory'),
            ('uninspected-runtime-accepted', 'not 10 <= sys.version_info.minor <= 15',
             'not 10 <= sys.version_info.minor',
             'test_uninspected_reader_keeps_execution_but_refuses_complete_diagnostics'),
        )
        detected = 0
        for name, before, after, method in changes:
            with self.subTest(mutation=name):
                self.assertEqual(original.count(before), 1, 'mutation target is not unique')
                code = compile(original.replace(before, after), '<retirement-mutant>', 'exec')
                spec = importlib.util.spec_from_loader('retirement_mutant', loader=None)
                candidate = importlib.util.module_from_spec(spec)
                exec(code, candidate.__dict__)
                result = unittest.TestResult()
                with mock.patch.dict(globals(), observer=candidate):
                    type(self)(methodName=method).run(result)
                self.assertEqual(result.errors, [], 'mutation crashed outside its behavioral assertion')
                self.assertTrue(result.failures, 'mutation escaped its specific behavioral oracle')
                detected += 1
        self.assertEqual(detected, 13)


class TeardownRescueTests(unittest.TestCase):
    """Exercise the rescue consumer with private children and native pidfds."""

    @contextmanager
    def fixture(self, count=2, foreign=False):
        real_os, real_signal, real_observer = os, signal, observer
        case = ProcessTests('test_mock_rescue_requires_token_and_current_start_identity')
        case.setUp()
        children, witnesses, sentinels, attempts, events = [], [], [], [], []
        active = {}
        fixture = SimpleNamespace(case=case, events=events, children=children,
                                  witnesses=witnesses, sentinels=sentinels,
                                  close_attempts=attempts, active=active, outcome=None)
        try:
            for index in range(count + int(foreign)):
                environment = dict(real_os.environ)
                environment.pop('YTDLP_QUALIFICATION_TOKEN', None)
                if index < count:
                    environment['YTDLP_QUALIFICATION_TOKEN'] = case.token
                process = subprocess.Popen(
                    [sys.executable, '-I', '-c',
                     'import time; print("ready", flush=True); time.sleep(30)'],
                    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                children.append(process)
                readiness = select.poll()
                readiness.register(process.stdout, select.POLLIN)
                self.assertTrue(readiness.poll(3000), 'private child did not acknowledge startup')
                self.assertEqual(process.stdout.readline(), b'ready\n')
                witnesses.append(real_os.pidfd_open(process.pid))
            rows = {str(process.pid): real_observer.current_process(process.pid)
                    for process in children}
            fixture.rows = rows
            fixture.count = count
            fixture.real_os = real_os
            fixture.real_signal = real_signal
            fixture.real_observer = real_observer
            fixture.marker = case.observer.marker
            fixture.sentinel_path = case.root / 'sentinel'
            fixture.sentinel_path.write_bytes(b'private descriptor sentinel')
            fixture.sentinel_identity = fixture.sentinel_path.stat()
            yield fixture
        finally:
            # Assertions precede this owner-only safety net. It cannot turn an
            # unconfirmed candidate rescue into a passing behavioral oracle.
            for process in children:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)
            for descriptor in list(active):
                real_os.close(descriptor)
            for descriptor in sentinels + witnesses:
                real_os.close(descriptor)
            case.temp.cleanup()

    def drive(self, fixture, *, initial_error=None, snapshot_error=None,
              open_errors=None, identity_errors=None, replaced=(), signal_errors=None,
              close_errors=None, reuse=(), communicate_errors=None,
              terminal_error=None, terminal_live=False, initial_live=True,
              popen_fallback=False, disappear_at=None):
        """Inject at local boundaries, leaving observer/kernel global APIs alone."""
        open_errors, identity_errors = open_errors or {}, identity_errors or {}
        signal_errors, close_errors = signal_errors or {}, close_errors or {}
        communicate_errors = communicate_errors or {}
        case, events = fixture.case, fixture.events
        real_os, real_signal = fixture.real_os, fixture.real_signal
        by_pid = {process.pid: index for index, process in enumerate(fixture.children)}
        owned = dict(list(fixture.rows.items())[:fixture.count])
        generation = 0

        def sample():
            events.append(('sample',))
            if initial_error is not None:
                raise initial_error
            return {'live': owned if initial_live else {}}

        def snapshot():
            events.append(('snapshot',))
            if snapshot_error is not None:
                raise snapshot_error
            return {int(pid): row for pid, row in fixture.rows.items()}

        def disappear(phase, index):
            if disappear_at == phase and index == 0:
                process = fixture.children[index]
                process.kill()
                process.communicate(timeout=3)
                raise ProcessLookupError(errno.ESRCH, 'injected after confirmed child exit')

        def opener(pid):
            nonlocal generation
            index = by_pid[pid]
            events.append(('open', index))
            disappear('open', index)
            if index in open_errors:
                raise open_errors[index]
            descriptor = real_os.pidfd_open(pid)
            generation += 1
            fixture.active[descriptor] = (index, generation)
            return descriptor

        def current(pid):
            index = by_pid[pid]
            events.append(('identity', index))
            disappear('identity', index)
            if index in identity_errors:
                raise identity_errors[index]
            row = fixture.rows[str(pid)]
            return dict(row, start=row['start'] + 1) if index in replaced else row

        def send(descriptor, number):
            index, _generation = fixture.active[descriptor]
            events.append(('signal', index, number))
            disappear('signal', index)
            if index in signal_errors:
                raise signal_errors[index]
            # Invalid candidates are recorded for a causal no-signal assertion,
            # without exposing an unrelated child to the deliberately bad mutant.
            if index < fixture.count and index not in replaced:
                real_signal.pidfd_send_signal(descriptor, number)

        def closer(descriptor):
            value = fixture.active.pop(descriptor, None)
            fixture.close_attempts.append((descriptor, value))
            events.append(('close', value))
            if value is None:
                # Do not actually close a sentinel on an intentionally bad retry.
                return
            index, _generation = value
            real_os.close(descriptor)
            if index in reuse:
                sentinel = real_os.open(fixture.sentinel_path, real_os.O_RDONLY)
                if sentinel != descriptor:
                    real_os.dup2(sentinel, descriptor)
                    real_os.close(sentinel)
                fixture.sentinels.append(descriptor)
            if index in close_errors:
                raise close_errors[index]

        def terminal_sample():
            events.append(('terminal',))
            if terminal_error is not None:
                raise terminal_error
            live = {str(process.pid): fixture.rows[str(process.pid)]
                    for index, process in enumerate(fixture.children[:fixture.count])
                    if not self.exited(fixture, index)}
            return {'live': owned if terminal_live else live}

        terminal = SimpleNamespace(known=set(), sample=terminal_sample)
        case.observer = SimpleNamespace(marker=fixture.marker,
                                        known={(int(pid), row['start']) for pid, row in owned.items()},
                                        sample=sample)
        if popen_fallback:
            for index, process in enumerate(fixture.children[:fixture.count]):
                def poll(index=index, process=process):
                    events.append(('poll', index))
                    return process.poll()

                def kill(index=index, process=process):
                    events.append(('kill', index))
                    return process.kill()

                def communicate(timeout, index=index, process=process):
                    events.append(('communicate', index))
                    if index in communicate_errors:
                        raise communicate_errors[index]
                    return process.communicate(timeout=timeout)
                case.processes.append(SimpleNamespace(poll=poll, kill=kill, communicate=communicate))
        fake_os = SimpleNamespace(
            pidfd_open=opener, close=closer, waitpid=real_os.waitpid, WNOHANG=real_os.WNOHANG,
            kill=lambda pid, number: events.append(('unsafe-pid-signal', pid, number)))
        fake_signal = SimpleNamespace(SIGKILL=real_signal.SIGKILL, pidfd_send_signal=send)
        fake_observer = SimpleNamespace(snapshot=snapshot, current_process=current,
                                        Observer=lambda _token: terminal,
                                        ObservationError=fixture.real_observer.ObservationError)
        with mock.patch.dict(globals(), os=fake_os, signal=fake_signal, observer=fake_observer):
            try:
                case.tearDown()
            except BaseException as error:
                fixture.outcome = error
        fixture.terminal = terminal
        return fixture.outcome

    def exited(self, fixture, index):
        poller = select.poll()
        poller.register(fixture.witnesses[index], select.POLLIN)
        return bool(poller.poll(0))

    def assert_rescued(self, fixture):
        self.assertFalse(any(event[0] == 'unsafe-pid-signal' for event in fixture.events),
                         'candidate attempted signal authority based on a numeric PID alone')
        self.assertTrue(all(self.exited(fixture, index) for index in range(fixture.count)),
                        'a private child survived candidate rescue')
        self.assertIn(('terminal',), fixture.events, 'terminal observation was skipped')
        expected = {(int(pid), row['start'])
                    for pid, row in list(fixture.rows.items())[:fixture.count]}
        self.assertEqual(fixture.terminal.known, expected, 'terminal identities were not preserved')
        self.assertFalse(fixture.active, 'a candidate-owned pidfd remained open')
        generations = [value for _descriptor, value in fixture.close_attempts]
        self.assertNotIn(None, generations, 'a consumed/reassigned descriptor was closed again')
        self.assertEqual(len(generations), len(set(generations)), 'a pidfd generation was closed twice')

    def secondary(self, error):
        return getattr(error, 'teardown_secondary_errors', None)

    def test_nominal_rescue_closes_each_generation_and_confirms_terminal(self):
        with self.fixture() as fixture:
            self.assertIsNone(self.drive(fixture))
            self.assert_rescued(fixture)
            self.assertEqual(len(fixture.close_attempts), 2)
            self.assertEqual([event[1] for event in fixture.events if event[0] == 'signal'], [0, 1])
            self.assertFalse(fixture.case.root.exists(), 'confirmed clean fixture was not removed')

    def test_first_observation_error_survives_close_error_and_rescue_continues(self):
        with self.fixture() as fixture:
            first = PermissionError(errno.EACCES, 'private observation detail')
            later = OSError(errno.EIO, 'private close detail')
            self.assertIs(self.drive(fixture, initial_error=first, close_errors={0: later}), first)
            self.assertEqual(first.errno, errno.EACCES)
            self.assert_rescued(fixture)
            self.assertEqual(self.secondary(first), (('OSError', errno.EIO),))
            self.assertTrue(fixture.case.root.is_dir())

    def test_isolated_close_error_remains_blocking_without_stopping_next_rescue(self):
        with self.fixture() as fixture:
            first = OSError(errno.EIO, 'private close detail')
            self.assertIs(self.drive(fixture, close_errors={0: first}), first)
            self.assert_rescued(fixture)
            self.assertEqual(self.secondary(first), ())
            self.assertTrue(fixture.case.root.is_dir())
            names = [event[0:2] for event in fixture.events]
            self.assertLess(names.index(('close', (0, 1))), names.index(('open', 1)))

    def test_consumed_fd_is_never_retried_even_after_number_reuse(self):
        for number in (errno.EIO, errno.EINTR, errno.EBADF):
            with self.subTest(errno=number), self.fixture() as fixture:
                first = OSError(number, 'injected after real kernel close')
                self.assertIs(self.drive(fixture, close_errors={0: first}, reuse=(0,)), first)
                self.assert_rescued(fixture)
                self.assertEqual(len(fixture.sentinels), 1)
                actual = fixture.real_os.fstat(fixture.sentinels[0])
                expected = fixture.sentinel_identity
                self.assertEqual((actual.st_dev, actual.st_ino), (expected.st_dev, expected.st_ino))
                self.assertEqual(fixture.real_os.read(fixture.sentinels[0], 27), b'private descriptor sentinel')

    def test_close_failure_does_not_skip_owned_popen_or_terminal_checks(self):
        with self.fixture() as fixture:
            first = OSError(errno.EIO, 'injected close')
            self.assertIs(self.drive(fixture, close_errors={0: first}, popen_fallback=True), first)
            self.assert_rescued(fixture)
            self.assertEqual([event[1] for event in fixture.events if event[0] == 'communicate'], [0, 1])
            self.assertLess(fixture.events.index(('communicate', 1)), fixture.events.index(('terminal',)))

    def test_replaced_identity_is_not_signaled_or_declared_terminal(self):
        with self.fixture() as fixture:
            result = self.drive(fixture, replaced=(0,))
            self.assertIsInstance(result, fixture.real_observer.ObservationError)
            self.assertNotIn(('signal', 0, fixture.real_signal.SIGKILL), fixture.events)
            self.assertFalse(self.exited(fixture, 0))
            self.assertTrue(self.exited(fixture, 1))
            self.assertTrue(fixture.case.root.is_dir())
            self.assertIn(('terminal',), fixture.events)
            self.assertFalse(fixture.active)

    def test_foreign_marker_is_excluded_from_snapshot_rescue(self):
        with self.fixture(foreign=True) as fixture:
            self.assertIsNone(self.drive(fixture, initial_live=False))
            self.assert_rescued(fixture)
            self.assertFalse(self.exited(fixture, 2), 'foreign witness was signaled')
            self.assertNotIn(('open', 2), fixture.events, 'foreign marker entered rescue selection')
            self.assertFalse(fixture.case.root.exists())

    def test_disappearance_does_not_skip_other_rescue_or_claim_unknown_exit(self):
        for phase in ('open', 'identity', 'signal'):
            for number in (errno.ESRCH, errno.ENOENT):
                with self.subTest(phase=phase, errno=number), self.fixture() as fixture:
                    arguments = {phase + '_errors': {0: OSError(number, 'injected disappearance')}}
                    result = self.drive(fixture, **arguments)
                    self.assertIsInstance(result, fixture.real_observer.ObservationError)
                    self.assertFalse(self.exited(fixture, 0), 'injection unexpectedly terminated its witness')
                    self.assertTrue(self.exited(fixture, 1), 'independent rescue was skipped')
                    self.assertIn(('terminal',), fixture.events)
                    self.assertTrue(fixture.case.root.is_dir())
                    self.assertFalse(fixture.active)

    def test_confirmed_disappearance_allows_remaining_rescue_without_false_error(self):
        for phase in ('open', 'identity', 'signal'):
            with self.subTest(phase=phase), self.fixture() as fixture:
                self.assertIsNone(self.drive(fixture, disappear_at=phase))
                self.assert_rescued(fixture)
                self.assertFalse(fixture.case.root.exists())

    def test_snapshot_primary_survives_close_error_with_initial_live_inventory(self):
        with self.fixture() as fixture:
            first = ValueError('private snapshot detail')
            later = OSError(errno.EIO, 'private close detail')
            self.assertIs(self.drive(fixture, snapshot_error=first, close_errors={0: later}), first)
            self.assert_rescued(fixture)
            self.assertEqual(self.secondary(first), (('OSError', errno.EIO),))
            self.assertTrue(fixture.case.root.is_dir())

    def test_combined_errors_keep_chronological_primary_and_bounded_metadata(self):
        with self.fixture(count=3) as fixture:
            first = PermissionError(errno.EPERM, 'private initial text')
            timeout = subprocess.TimeoutExpired('private command', 5)
            terminal = OSError(errno.EIO, 'private terminal text')
            result = self.drive(
                fixture, initial_error=first,
                open_errors={0: OSError(errno.EMFILE, 'private open')},
                signal_errors={1: PermissionError(errno.EPERM, 'private signal')},
                close_errors={1: OSError(errno.EIO, 'private close')},
                communicate_errors={0: timeout}, terminal_error=terminal, popen_fallback=True)
            self.assertIs(result, first)
            self.assertEqual(first.errno, errno.EPERM)
            self.assertEqual([event[1] for event in fixture.events if event[0] == 'open'], [0, 1, 2])
            self.assertEqual([event[1] for event in fixture.events if event[0] == 'communicate'], [0, 1, 2])
            self.assertIn(('terminal',), fixture.events)
            secondary = self.secondary(first)
            self.assertEqual(secondary, (('OSError', errno.EMFILE), ('OSError', errno.EPERM),
                                         ('OSError', errno.EIO), ('TimeoutExpired', None),
                                         ('OSError', errno.EIO)))
            self.assertNotIn('private', repr(secondary))
            self.assertTrue(fixture.case.root.is_dir())

    def test_snapshot_error_keeps_original_identity_and_fallback_rescue(self):
        with self.fixture() as fixture:
            first = IndexError('private initial parser detail')
            second = ValueError('private snapshot detail')
            result = self.drive(fixture, initial_error=first, snapshot_error=second,
                                popen_fallback=True)
            self.assertIs(result, first)
            self.assertEqual(self.secondary(first), (('ValueError', None),))
            self.assert_rescued(fixture)
            self.assertEqual([event[1] for event in fixture.events if event[0] == 'communicate'], [0, 1])
            self.assertTrue(fixture.case.root.is_dir())

    def test_terminal_failure_never_allows_fixture_cleanup(self):
        for mode in ('error', 'live'):
            with self.subTest(mode=mode), self.fixture() as fixture:
                terminal = PermissionError(errno.EACCES, 'private terminal detail')
                options = {'terminal_error': terminal} if mode == 'error' else {'terminal_live': True}
                result = self.drive(fixture, **options)
                if mode == 'error':
                    self.assertIs(result, terminal)
                else:
                    self.assertIsInstance(result, fixture.real_observer.ObservationError)
                self.assert_rescued(fixture)
                self.assertTrue(fixture.case.root.is_dir(), 'uncertain fixture evidence was erased')
                self.assertFalse(fixture.case.temp._finalizer.alive)
                fixture.case.doCleanups()
                self.assertTrue(fixture.case.root.is_dir(), 'unittest cleanup erased uncertain evidence')

    def test_secondary_metadata_is_bounded_without_private_exception_text(self):
        with self.fixture(count=10) as fixture:
            first = ValueError('private initial detail')
            errors = {index: OSError(errno.EIO, 'private close detail') for index in range(10)}
            self.assertIs(self.drive(fixture, initial_error=first, close_errors=errors), first)
            self.assert_rescued(fixture)
            self.assertEqual(self.secondary(first), (('OSError', errno.EIO),) * 8)
            self.assertEqual(getattr(first, 'teardown_secondary_overflow', None), 2)
            self.assertNotIn('private', repr(self.secondary(first)))

    def test_programming_errors_and_base_exceptions_are_not_silently_accepted(self):
        for interruption in (AssertionError('injected programming failure'),
                             KeyboardInterrupt(), SystemExit(7)):
            with self.subTest(exception=type(interruption).__name__), self.fixture() as fixture:
                self.assertIs(self.drive(fixture, close_errors={0: interruption}), interruption)
                self.assertTrue(fixture.case.root.is_dir())
                self.assertFalse(fixture.case.temp._finalizer.alive)
                self.assertEqual(len(fixture.close_attempts), 1)


def report_first_failure(watcher, error, *, fedora_native):
    """Emit only closed public metadata; recording a failure must preserve it."""
    # The public envelope name never comes from a test environment or exception.
    key = 'fedora_native_first_failure' if fedora_native else 'stress_first_failure'
    fallback = '{"' + key + '":{"complete":false}}'
    limit = 16 * 1024
    line = fallback
    try:
        evidence = dict(complete=False, diagnostic=observer._empty_diagnostic())
        try:
            evidence['diagnostic'] = observer.copy_diagnostic(watcher.diagnostic_failure(error))
        except BaseException:
            pass
        try:
            projection = observer.IdentityProjection()
            # Preserve the independent primitive evidence even if projection fails.
            empty = dict(observer._empty_identity_diagnostic(), view='public', scope_id=projection.scope_id)
            evidence['identity'] = observer.copy_identity_export(empty)
            projected = projection.project(watcher.identity_failure(error))
            evidence['identity'] = observer.copy_identity_export(projected)
        except BaseException:
            pass
        packets = [evidence[key] for key in ('diagnostic', 'identity') if key in evidence]
        evidence['complete'] = len(packets) == 2 and all(packet['complete'] for packet in packets)
        record = {key: evidence}
        line = json.dumps(record, separators=(',', ':'), ensure_ascii=True)
        if len(line) + 1 > limit:
            # Preserve the first primitive even when the complete history is too large.
            evidence['complete'] = False
            for packet in packets:
                omitted = len(packet['events'][1:])
                if omitted:
                    del packet['events'][1:]
                    packet['omitted'] = min(2147483647, packet['omitted'] + omitted)
                    packet['complete'] = False
            line = json.dumps(record, separators=(',', ':'), ensure_ascii=True)
    except BaseException:
        line = fallback
    try:
        # unittest writes progress dots without a trailing newline.
        sys.stderr.write('\n' + (line if len(line) + 1 <= limit else fallback) + '\n')
    except BaseException:
        pass


class StressFirstFailureTests(unittest.TestCase):
    target = 'test_cli_escalates_subgroup_before_retiring_sentinel'
    selection = {'STRESS_SHARD': '2', 'YTDLP_STRESS_FIRST_FAILURE': '2:18'}
    shard4_selection = {'STRESS_SHARD': '4', 'YTDLP_STRESS_FIRST_FAILURE': '4:12'}

    engine_target = 'test_engine_cli_wrapper_exit_retains_resource_and_lock'
    engine_selection = {'YTDLP_FEDORA_FIRST_FAILURE': 'engine-cli-first-sample'}

    def capture(self, case, stream, sample):
        with redirect_stderr(stream), self.assertRaises(observer.ObservationError) as caught:
            sample()
        self.assertIs(caught.exception, case.observer.error)
        return caught.exception

    def test_scope_and_success_are_silent(self):
        other = 'test_mock_rescue_requires_token_and_current_start_identity'
        for method, env, enabled in (
                (self.target, {}, False), (self.target, {'STRESS_SHARD': '2'}, False),
                (self.target, dict(self.selection, STRESS_SHARD='1'), False),
                (self.target, dict(self.selection, YTDLP_STRESS_FIRST_FAILURE='2:19'), False),
                (self.target, dict(self.selection, STRESS_SHARD='4'), False),
                (self.target, dict(self.shard4_selection, STRESS_SHARD='2'), False),
                (other, self.selection, False), (other, self.shard4_selection, False),
                (self.target, self.selection, True), (self.target, self.shard4_selection, True)):
            with self.subTest(method=method, env=env):
                case = ProcessTests(method)
                self.check_silent_scope(case, env, enabled, case.sample_before_cli_escalation)

    def test_fedora_native_scope_and_success_are_silent(self):
        for method, env, reuse, enabled in (
                (self.engine_target, {}, False, False), (self.engine_target, self.selection, False, False),
                (self.engine_target, {'YTDLP_FEDORA_FIRST_FAILURE': '1'}, False, False),
                (self.target, self.engine_selection, False, False),
                (self.engine_target, self.engine_selection, True, False),
                (self.engine_target, self.engine_selection, False, sys.version_info[:2] == (3, 15))):
            with self.subTest(method=method, env=env, reuse=reuse):
                case = ProcessTests(method)
                self.check_silent_scope(case, env, enabled, lambda: case.sample_before_engine_signal(reuse))

    def check_silent_scope(self, case, env, enabled, invoke):
        case.observer = observer.Observer('private-fixture')
        output = io.StringIO()

        def sample():
            self.assertIs(case.observer.diagnostics_enabled, enabled)
            self.assertIs(case.observer.identity_diagnostics_enabled, enabled)

        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(case.observer, 'sample', side_effect=sample) as sampled, redirect_stderr(output):
            invoke()
        sampled.assert_called_once_with()
        self.assertFalse(case.observer.diagnostics_enabled)
        self.assertFalse(case.observer.identity_diagnostics_enabled)
        self.assertEqual(output.getvalue(), '')

    def test_private_child_open_refusal_survives_capture_and_teardown(self):
        for selection in (self.selection, self.shard4_selection):
            with self.subTest(shard=selection['STRESS_SHARD']):
                case = ProcessTests(self.target)
                self.check_private_open(case, case.sample_before_cli_escalation, selection, 'stress_first_failure',
                                        'environ', errno.EACCES, 'known_identity', True)

    def test_fedora_native_private_cmdline_error_survives_capture_and_teardown(self):
        case = ProcessTests(self.engine_target)
        self.check_private_open(case, lambda: case.sample_before_engine_signal(False),
                                self.engine_selection, 'fedora_native_first_failure', 'cmdline', errno.EIO, 'marker',
                                sys.version_info[:2] == (3, 15))

    def test_private_child_attribution_waits_for_cat_exec(self):
        # The unmarked first image gates the marked cat's exec on the challenge
        # becoming readable. Its PID, parent and starttime survive that exec.
        stage = """import os, select, sys
if not select.select([0], [], [], 5)[0]:
    sys.exit(1)
env = dict(os.environ)
env['YTDLP_QUALIFICATION_TOKEN'] = env.pop('PENDING_FIXTURE')
os.execve(sys.argv[1], [sys.argv[1]], env)
"""
        launch = subprocess.Popen

        def delayed_cat(argv, *, env, **pipes):
            pending = env.copy()
            pending['PENDING_FIXTURE'] = pending.pop('YTDLP_QUALIFICATION_TOKEN')
            return launch([sys.executable, '-I', '-B', '-c', stage, *argv], env=pending, **pipes)

        case = ProcessTests(self.target)
        with mock.patch.object(subprocess, 'Popen', new=delayed_cat):
            self.check_private_open(case, case.sample_before_cli_escalation, self.shard4_selection,
                                    'stress_first_failure', 'environ', errno.EACCES, 'known_identity', True)

    def ready_cat_row(self, child, cat):
        # Keep stdin open after the private echo so the same cat remains available
        # for both the independent marker observation and the later injected fault.
        self.assertEqual(os.write(child.stdin.fileno(), b'.'), 1)
        self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'fixture cat did not echo')
        self.assertTrue(os.read(child.stdout.fileno(), 1) == b'.', 'fixture cat echo did not match')
        self.assertIsNone(child.poll())
        self.assertTrue(Path(f'/proc/{child.pid}/exe').samefile(cat))
        row = observer.current_process(child.pid)
        self.assertIsNotNone(row)
        self.assertEqual(row['parent'], os.getpid())
        return row

    def check_private_open(self, case, sample, selection, label, resource, number, attribution, eligible):
        case.setUp()
        private = 'private-first-failure-canary'
        environment = {'YTDLP_QUALIFICATION_TOKEN': case.token, 'PRIVATE_SAMPLE': private}
        cat = shutil.which('cat', path=os.defpath)
        self.assertIsNotNone(cat)
        with subprocess.Popen([cat], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
            try:
                row = self.ready_cat_row(child, cat)
                denied = Path(f'/proc/{child.pid}/{resource}')
                original_open = Path.open

                def deny(path, *args, **kwargs):
                    if path == denied:
                        raise OSError(number, private, str(denied))
                    return original_open(path, *args, **kwargs)

                with mock.patch.object(observer, 'snapshot', return_value={child.pid: row}):
                    for enabled in (False, True):
                        case.observer = observer.Observer(case.token)
                        self.assertIn(str(child.pid), case.observer.sample()['live'])
                        self.assertIn((child.pid, row['start']), case.observer.known)
                        output = io.StringIO()
                        with mock.patch.dict(os.environ, selection if enabled else {}, clear=True), \
                                mock.patch.object(Path, 'open', new=deny):
                            refusal = self.capture(case, output, sample)
                        self.assertEqual(refusal.errno, number)
                        if not (enabled and eligible):
                            self.assertEqual(output.getvalue(), '')
            finally:
                child.communicate(timeout=5)
        self.assertEqual(child.returncode, 0)
        teardown_output = io.StringIO()
        with mock.patch.dict(os.environ, selection), mock.patch.object(observer, 'snapshot', return_value={}), \
                redirect_stderr(teardown_output), self.assertRaises(observer.ObservationError) as cleanup:
            case.tearDown()
        self.assertEqual(teardown_output.getvalue(), '')
        self.assertIs(cleanup.exception, refusal)
        self.assertTrue(case.root.exists())
        case.temp.cleanup()
        if not eligible:
            return

        line, = output.getvalue().strip().splitlines()
        self.assertLessEqual(len(line.encode('ascii')) + 1, 16384)
        self.assertFalse(any(secret in line for secret in
                             (case.token, private, str(denied), 'YTDLP_QUALIFICATION_TOKEN')),
                         'a private fixture value escaped into the diagnostic line')
        wrapper = json.loads(line)
        self.assertEqual(set(wrapper), {label})
        packet = wrapper[label]
        self.assertEqual(set(packet), {'complete', 'diagnostic', 'identity'})
        self.assertIs(packet['complete'], True)
        diagnostic = observer.copy_diagnostic(packet['diagnostic'])
        identity = observer.copy_identity_export(packet['identity'])
        expected_class = 'PermissionError' if number == errno.EACCES else 'OSError'
        for capsule, operation in ((diagnostic, 'attribute_read'), (identity, 'attribute_open')):
            self.assertIs(capsule['complete'], True)
            first, last = capsule['events']
            self.assertEqual((first['operation'], first['phase'], first['primitive_errno'],
                              first['exception_class'], first['attribution_source']),
                             (operation, 'attribute_read', number, expected_class, attribution))
            self.assertEqual((last['operation'], last['relation'], last['cause_sequence'], last['normalized_errno']),
                             ('error_normalization', 'normalization', first['sequence'], number))
            self.assertLessEqual(first['monotonic_ns'], last['monotonic_ns'])
        first = identity['events'][0]
        self.assertEqual(first['resource_kind'], resource)
        self.assertIs(first['kernel_return_proven'], False)
        context = first['context']
        self.assertEqual(context['group_expected']['reference'], 'g1')
        task = context['task_before']
        self.assertEqual((task['reference'], task['group_reference'], task['starttime_known']), ('t1', 'g1', True))

        with mock.patch.dict(os.environ, selection):
            # Pad a valid public history beyond the line budget without inventing private coordinates.
            expanded = dict(identity, events=[dict(identity['events'][0], sequence=n, first_failure=n == 1)
                                              for n in range(1, 33)])
            with mock.patch.object(observer.IdentityProjection, 'project', return_value=expanded):
                output = io.StringIO()
                self.assertIs(self.capture(case, output, sample), refusal)
                self.assertLessEqual(len(output.getvalue().strip().encode('ascii')) + 1, 16384)
                short = json.loads(output.getvalue())[label]
                self.assertIs(short['complete'], False)
                remaining = observer.copy_identity_export(short['identity'])
                self.assertEqual(remaining['events'][0]['operation'], 'attribute_open')
                self.assertEqual(remaining['omitted'], 32 - len(remaining['events']))
            for projection in ({'side_effect': ValueError(private)}, {'return_value': dict(identity, pid=child.pid)}):
                with mock.patch.object(observer.IdentityProjection, 'project', **projection):
                    output = io.StringIO()
                    self.assertIs(self.capture(case, output, sample), refusal)
                    partial = json.loads(output.getvalue())[label]
                    self.assertIs(partial['complete'], False)
                    self.assertEqual(observer.copy_diagnostic(partial['diagnostic']), diagnostic)
                    empty = observer.copy_identity_export(partial['identity'])
                    self.assertEqual((empty['complete'], empty['events']), (False, []))
                    self.assertNotIn(private, output.getvalue())
            with mock.patch.object(case.observer, 'diagnostic_failure', side_effect=ValueError(private)):
                output = io.StringIO()
                self.assertIs(self.capture(case, output, sample), refusal)
                partial = json.loads(output.getvalue())[label]
                self.assertIs(partial['complete'], False)
                empty = observer.copy_diagnostic(partial['diagnostic'])
                self.assertEqual((empty['complete'], empty['events']), (False, []))
                remaining = observer.copy_identity_export(partial['identity'])
                self.assertEqual(remaining['events'], identity['events'])
                self.assertIs(remaining['complete'], True)
                self.assertNotIn(private, output.getvalue())
            broken = mock.Mock()
            broken.write.side_effect = OSError(errno.EIO, private)
            self.assertIs(self.capture(case, broken, sample), refusal)
            self.assertTrue(broken.write.called)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='process-contract-')
        # Python 3.10 has no delete=False. Failed observation must not let the
        # automatic finalizer delete files still held by an uncertain consumer.
        self.temp._finalizer.detach()
        self.root = Path(self.temp.name)
        self.token = os.urandom(24).hex()
        self.observer = observer.Observer(self.token)
        self.processes = []
        ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)

    def tearDown(self):
        # Capture the production verdict before test-only intervention.
        failures = []
        try:
            state = self.observer.sample()
        except (OSError, ValueError, IndexError) as error:
            failures.append(error)
            state = {'live': {}}
        # Rescue is independent of the oracle being mutation-tested. Select
        # only this fixture's exact inherited marker, then revalidate identity.
        rescue = dict(state['live'])
        try:
            rows = observer.snapshot()
        except (OSError, ValueError, IndexError) as error:
            failures.append(error)
            rows = {}
        for pid, row in rows.items():
            try:
                marked = self.observer.marker in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
            except OSError:
                marked = False
            if marked:
                rescue[str(pid)] = row
        for pid, row in rescue.items():
            descriptor = None
            try:
                descriptor = os.pidfd_open(int(pid))
                current = observer.current_process(int(pid))
                if current and current['start'] == row['start']:
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            except (FileNotFoundError, ProcessLookupError):
                pass
            except (OSError, ValueError, IndexError) as error:
                failures.append(error)
            finally:
                if descriptor is not None:
                    # Linux may release the number even when close fails.
                    # Consume this ownership once; other rescues remain independent.
                    try:
                        os.close(descriptor)
                    except OSError as error:
                        failures.append(error)
        for process in self.processes:
            try:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)
            except (OSError, subprocess.TimeoutExpired) as error:
                failures.append(error)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    time.sleep(.02)
            except ChildProcessError:
                break
        try:
            terminal = observer.Observer(self.token)
            terminal.known.update(self.observer.known)
            terminal.known.update((int(pid), row['start']) for pid, row in rescue.items())
            if terminal.sample()['live']:
                raise observer.ObservationError('fixture shutdown remains unconfirmed')
        except (OSError, ValueError, IndexError) as error:
            failures.append(error)
        else:
            if not failures:
                self.temp.cleanup()
        if failures:
            # Preserve the native primary exception, without chaining private
            # secondary messages. Metadata is inspectable even on Python 3.10;
            # unittest's ordinary traceback does not render these attributes.
            secondary = []
            for error in failures[1:9]:
                category = ('OSError' if isinstance(error, OSError) else
                            'ValueError' if isinstance(error, ValueError) else
                            'IndexError' if isinstance(error, IndexError) else
                            'TimeoutExpired')
                number = error.errno if isinstance(error, OSError) else None
                secondary.append((category, number if type(number) is int and 0 <= number <= 4095 else None))
            failures[0].teardown_secondary_errors = tuple(secondary)
            failures[0].teardown_secondary_overflow = max(0, len(failures) - 9)
            raise failures[0]

    def launch(self, argv):
        p = subprocess.Popen(argv, env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.processes.append(p)
        return p

    def test_mock_rescue_requires_token_and_current_start_identity(self):
        source = (PROJECT / 'tests/lib/mock-common.sh').read_text()
        function = re.search(r'^signal_test_processes\(\) \{\n.*?^\}\n', source, re.M | re.S).group()
        marker = self.token + '-mock'
        process = subprocess.Popen(['sleep', '30'],
                                   env=dict(os.environ, YTDLP_ARIA2_MOCK_PROCESS_TOKEN=marker))
        self.processes.append(process)
        start = observer.process_row(Path(f'/proc/{process.pid}/stat'))['start']
        script = function + '''
PROJECT_DIR=$1
YTDLP_ARIA2_MOCK_PROCESS_TOKEN=$2
TEST_PROCESS_IDENTITIES=("$3:$4")
signal_test_processes TERM
'''

        def attempt(project, token, identity):
            return subprocess.run(['bash', '-c', script, 'mock-rescue', str(project), token,
                                   str(process.pid), str(identity)], capture_output=True, timeout=5)

        self.assertEqual(attempt(PROJECT, marker, start + 1).returncode, 0)
        self.assertIsNone(process.poll(), 'rescue signaled a replaced start identity')
        self.assertEqual(attempt(PROJECT, marker + '-foreign', start).returncode, 70)
        self.assertIsNone(process.poll(), 'rescue signaled a foreign token')
        fake_project = self.root / 'unreadable-rescue'
        (fake_project / 'tests').mkdir(parents=True)
        (fake_project / 'tests/process-observer.py').write_text('''import importlib.util
import errno
spec = importlib.util.spec_from_file_location('real_mock_observer', REAL_HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
process_row = module.process_row
threads_are_quiescent = module.threads_are_quiescent
same_process = module.same_process
def token_process_is_live(pid, marker):
    raise PermissionError(errno.EACCES, 'synthetic private error')
'''.replace('REAL_HELPER', repr(str(PROJECT / 'tests/process-observer.py'))))
        refused = attempt(fake_project, marker, start)
        self.assertEqual(refused.returncode, 70)
        self.assertNotIn(b'synthetic private error', refused.stderr)
        self.assertIsNone(process.poll(), 'rescue converted unknown ownership into signal authority')
        self.assertEqual(attempt(PROJECT, marker, start).returncode, 0)
        self.assertEqual(process.wait(timeout=3), -signal.SIGTERM)

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
    ready = root / '.thread-ready.tmp'
    ready.write_text(str(os.getpid()))
    ready.replace(root / 'thread-ready')
    if select.select([release], [], [], 3)[0]: os.read(release, 1)
    os.write(fd, b'access after barrier')
    os.close(fd)
    (root / 'thread-last-access').write_text(str(time.monotonic_ns()))
    os._exit(0)
threading.Thread(target=worker).start()
ctypes.CDLL(None).pthread_exit(None)
''')
        return script

    def test_thread_readiness_is_published_after_complete_write(self):
        script = self.thread_fixture()
        source = script.read_text()
        publication = """    ready = root / '.thread-ready.tmp'
    ready.write_text(str(os.getpid()))
    ready.replace(root / 'thread-ready')
"""
        self.assertEqual(source.count(publication), 1)
        premature = self.root / 'premature-thread-readiness.py'
        premature.write_text(source.replace(
            publication, "    (root / 'thread-ready').write_text(str(os.getpid()))\n"))
        driver = self.root / 'thread-readiness-driver.py'
        driver.write_text(r'''import os, runpy, select, sys
from pathlib import Path
script, directory, release, opened, proceed = sys.argv[1:]
root = Path(directory)
opened, proceed = int(opened), int(proceed)
real_open = Path.open
def gated_open(path, mode='r', *args, **kwargs):
    stream = real_open(path, mode, *args, **kwargs)
    if (mode == 'w' and path.parent == root
            and path.name in ('.thread-ready.tmp', 'thread-ready')):
        os.write(opened, b'O')
        os.close(opened)
        if not select.select([proceed], [], [], 3)[0]: os._exit(91)
        if os.read(proceed, 1) != b'W': os._exit(92)
        os.close(proceed)
    return stream
Path.open = gated_open
sys.argv = [script, directory, release, 'direct']
runpy.run_path(script, run_name='__main__')
''')
        for mutant in (False, True):
            with self.subTest(premature_publication=mutant):
                case = self.root / ('premature-ready' if mutant else 'complete-ready')
                case.mkdir()
                opened_read, opened_write = os.pipe()
                proceed_read, proceed_write = os.pipe()
                release_read, release_write = os.pipe()
                descriptors = [opened_read, opened_write, proceed_read, proceed_write,
                               release_read, release_write]
                try:
                    process = subprocess.Popen(
                        [sys.executable, '-I', '-B', str(driver),
                         str(premature if mutant else script), str(case),
                         str(release_read), str(opened_write), str(proceed_read)],
                        pass_fds=(release_read, opened_write, proceed_read),
                        start_new_session=True,
                        env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.processes.append(process)
                    for descriptor in (opened_write, proceed_read, release_read):
                        os.close(descriptor)
                        descriptors.remove(descriptor)
                    self.assertTrue(select.select([opened_read], [], [], 3)[0],
                                    'readiness writer did not open its file')
                    self.assertEqual(os.read(opened_read, 1), b'O')
                    opened_path = case / ('thread-ready' if mutant else '.thread-ready.tmp')
                    self.assertEqual(opened_path.stat().st_size, 0)

                    def assert_unpublished():
                        self.assertFalse((case / 'thread-ready').exists(),
                                         'thread readiness published before complete write')

                    # The real open has created an empty file, but write_text has
                    # not received its stream. Judge publication before release.
                    if mutant:
                        with self.assertRaisesRegex(
                                self.failureException, 'published before complete write'):
                            assert_unpublished()
                    else:
                        assert_unpublished()
                    self.assertFalse((case / 'thread-last-access').exists())
                    os.write(proceed_write, b'W')
                    self.assertEqual(int(self.wait_file(f'{case.name}/thread-ready', process)),
                                     process.pid)
                    os.write(release_write, b'R')
                    out, err = process.communicate(timeout=3)
                    self.assertEqual(process.returncode, 0, (out, err))
                finally:
                    for descriptor in descriptors:
                        os.close(descriptor)

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
                    mock.patch.object(Path, 'read_text', side_effect=lambda **kwargs: held.read()):
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
            self.assertTrue(observer.token_process_is_live(consumer, fresh.marker),
                            'runner oracle lost a live thread behind a zombie leader')
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
            self.assertFalse(observer.token_process_is_live(consumer, fresh.marker))
            self.assertTrue((self.root / 'thread-last-access').exists())
            self.assertEqual(os.waitpid(consumer, 0)[1], 0)
            unrelated.communicate(timeout=3)
            process.communicate(timeout=3)
            self.assertEqual(unrelated.returncode, 0)
        finally:
            if write_end is not None:
                os.close(write_end)

    def test_observer_uses_live_memory_when_zombie_leader_access_is_denied(self):
        real_read = observer.read_observation
        live_reads = []

        def denied_leader(path):
            ready = self.root / 'thread-ready'
            if ready.exists():
                pid = int(ready.read_text())
                root = Path(f'/proc/{pid}')
                if path.parent == root:
                    row = observer.current_process(pid)
                    if row is not None and row['state'] == 'Z':
                        raise PermissionError(errno.EACCES, 'synthetic exited-leader memory ownership')
                elif path.parent.parent == root / 'task':
                    live_reads.append(path.name)
            return real_read(path)

        with mock.patch.object(observer, 'read_observation', side_effect=denied_leader):
            self.test_observer_detects_orphan_zombie_leader_live_thread()
        self.assertIn('environ', live_reads)
        self.assertIn('cmdline', live_reads)

    def test_observer_process_row_ignores_name_encoding(self):
        raw = Path('/proc/self/stat').read_bytes()
        prefix, fields = raw.split(b' (', 1)[0], raw.rsplit(b') ', 1)[1].split()
        expected = dict(start=int(fields[19]), state=fields[0].decode('ascii'),
                        parent=int(fields[1]), group=int(fields[2]), session=int(fields[3]))
        path = self.root / 'synthetic-stat'
        for name in (b'worker', 'révision'.encode(), b'a' * 14 + b'\xc3', b'worker ) (\xff'):
            with self.subTest(name=name.hex()):
                path.write_bytes(prefix + b' (' + name + b') ' + b' '.join(fields) + b'\n')
                self.assertEqual(observer.process_row(path), expected)

    def test_observer_invalid_identity_cannot_prove_absence(self):
        raw = Path('/proc/self/stat').read_bytes()
        prefix, tail = raw.rsplit(b') ', 1)
        invalid = [(b'missing stat fields', IndexError), (prefix + b') S 1', IndexError)]
        for index in (1, 2, 3, 19):
            for value in (b'?', b'\xff'):
                fields = tail.split()
                fields[index] = value
                invalid.append((prefix + b') ' + b' '.join(fields), ValueError))
        path = self.root / 'invalid-stat'
        foreign = Path('/proc/0/stat')
        own = Path(f'/proc/{os.getpid()}')
        real_read = Path.read_text

        def read(candidate, *args, **kwargs):
            return real_read(path if candidate == foreign else candidate, *args, **kwargs)

        for payload, error in invalid:
            with self.subTest(payload=payload):
                path.write_bytes(payload)
                with self.assertRaises(error):
                    observer.process_row(path)
                # Even an unmarked foreign entry must be readable before the
                # complete inventory can support a claim of no live consumer.
                with mock.patch.object(Path, 'iterdir', return_value=iter((own, foreign.parent))), \
                        mock.patch.object(Path, 'read_text', read):
                    with self.assertRaises(error):
                        observer.Observer(self.token).sample()

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

    def test_observer_final_sample_follows_the_stop_request(self):
        source = (PROJECT / 'tests/process-observer.py').read_text()
        before = '            stopping = args.stop.exists()\n'
        after = '            if stopping:\n'
        self.assertEqual(source.count(before), 1)
        self.assertEqual(source.count(after), 1)
        premature = self.root / 'premature-final-observer.py'
        premature.write_text(source.replace(before, '').replace(
            after, '            if args.stop.exists():\n'))
        harness = self.root / 'final-observer-harness.sh'
        harness.write_text((PROJECT / 'tests/zenity-real-session-qualification.sh')
                           .read_text().rsplit('\nmain "$@"', 1)[0])
        wrapper = self.root / 'gated-final-observer.py'
        wrapper.write_text('''import importlib.util, json, os, select, sys
from contextlib import ExitStack, contextmanager
from pathlib import Path
from unittest import mock
''' + inspect.getsource(denied_procfs_enumeration) + '''
source, token, evidence, stop, reported, proceed, case = sys.argv[1:]
reported, proceed = int(reported), int(proceed)
spec = importlib.util.spec_from_file_location('controlled_observer', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_sample = module.Observer.sample
count = 0
def gated_sample(observer):
    global count
    count += 1
    if count == 2 and case == 'denied':
        with denied_procfs_enumeration(PermissionError('final procfs root denied')):
            return real_sample(observer)
    state = real_sample(observer)
    if count == 1:
        (Path(evidence) / 'held-sample.json').write_text(json.dumps(state))
        os.write(reported, b'S')
        os.close(reported)
        if not select.select([proceed], [], [], 3)[0]: os._exit(91)
        if os.read(proceed, 1) != b'P': os._exit(92)
        os.close(proceed)
    return state
module.Observer.sample = gated_sample
sys.argv = [source, token, evidence, stop]
module.main()
''')
        consumer_code = '''import os, sys
report, release = map(int, sys.argv[1:])
if os.fork(): os._exit(23)
os.setsid()
os.write(report, (str(os.getpid()) + '\\n').encode())
os.close(report)
os.read(release, 1)
os._exit(0)
'''
        for case_name, mutant in (('stopped', False), ('stopped', True),
                                  ('orphan', False), ('denied', False), ('denied', True)):
            with self.subTest(case=case_name, premature_final_sample=mutant):
                case = self.root / f'final-{case_name}-{mutant}'
                case.mkdir()
                stop = case / 'stop'
                child_read, child_write = os.pipe()
                release_read, release_write = os.pipe()
                report_read, report_write = os.pipe()
                proceed_read, proceed_write = os.pipe()
                request_read, request_write = os.pipe()
                descriptors = [child_read, child_write, release_read, release_write,
                               report_read, report_write, proceed_read, proceed_write,
                               request_read, request_write]
                try:
                    consumer = subprocess.Popen(
                        [sys.executable, '-I', '-B', '-c', consumer_code,
                         str(child_write), str(release_read)],
                        pass_fds=(child_write, release_read), start_new_session=True,
                        env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.processes.append(consumer)
                    self.assertTrue(select.select([child_read], [], [], 3)[0],
                                    'orphan fixture did not publish its identity')
                    child = int(os.read(child_read, 100))
                    self.assertEqual(consumer.wait(timeout=3), 23)
                    if case_name == 'denied':
                        os.write(release_write, b'R')
                        self.assertEqual(os.waitpid(child, 0)[1], 0)
                    environment = dict(os.environ, FIXTURE_PYTHON=sys.executable,
                                       FIXTURE_WRAPPER=str(wrapper), FIXTURE_SOURCE=str(
                                           premature if mutant else PROJECT / 'tests/process-observer.py'),
                                       FIXTURE_TOKEN=self.token, FIXTURE_EVIDENCE=str(case),
                                       FIXTURE_STOP=str(stop), FIXTURE_REPORT=str(report_write),
                                       FIXTURE_PROCEED=str(proceed_read), FIXTURE_CASE=case_name,
                                       FIXTURE_REQUEST=str(request_read))
                    verdict = subprocess.Popen(['bash', '-c', '''source "$1"
"${FIXTURE_PYTHON}" -I -B "${FIXTURE_WRAPPER}" "${FIXTURE_SOURCE}" \
    "${FIXTURE_TOKEN}" "${FIXTURE_EVIDENCE}" "${FIXTURE_STOP}" \
    "${FIXTURE_REPORT}" "${FIXTURE_PROCEED}" "${FIXTURE_CASE}" &
WATCHER_PID=$!
IFS= read -r request <&"${FIXTURE_REQUEST}"
assert_no_residual_processes "${FIXTURE_EVIDENCE}" "${FIXTURE_STOP}"
''', 'bash', str(harness)], env=environment,
                                               pass_fds=(report_write, proceed_read, request_read),
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.processes.append(verdict)
                    for descriptor in (child_write, release_read, report_write,
                                       proceed_read, request_read):
                        os.close(descriptor)
                        descriptors.remove(descriptor)
                    self.assertTrue(select.select([report_read], [], [], 3)[0],
                                    'observer did not hold its real first sample')
                    self.assertEqual(os.read(report_read, 1), b'S')
                    held = json.loads((case / 'held-sample.json').read_text())
                    if case_name == 'denied':
                        self.assertFalse(held['live'])
                    else:
                        self.assertIn(str(child), held['live'])
                    if case_name == 'stopped':
                        os.write(release_write, b'R')
                        self.assertEqual(os.waitpid(child, 0)[1], 0)
                        self.assertFalse(Path(f'/proc/{child}').exists())
                    # The real harness requests stop only after the observed
                    # child has exited/reaped, or while the orphan stays live.
                    os.write(request_write, b'stop\n')
                    deadline = time.monotonic() + 3
                    while not stop.exists():
                        self.assertLess(time.monotonic(), deadline, 'harness did not request observer stop')
                        time.sleep(.005)
                    os.write(proceed_write, b'P')
                    out, err = verdict.communicate(timeout=3)
                    final = json.loads((case / 'processes-current.json').read_text())
                    if case_name == 'stopped':
                        def assert_fresh():
                            self.assertEqual(verdict.returncode, 0,
                                             'observer used a sample taken before stop')
                            self.assertFalse(final['live'])
                        if mutant:
                            with self.assertRaisesRegex(self.failureException, 'sample taken before stop'):
                                assert_fresh()
                            self.assertEqual(verdict.returncode, 65, (out, err))
                            self.assertIn(str(child), final['live'])
                        else:
                            assert_fresh()
                    elif case_name == 'orphan':
                        self.assertEqual(verdict.returncode, 65, (out, err))
                        self.assertIn(str(child), final['live'])
                        self.assertIsNone(os.waitid(os.P_PID, child, os.WEXITED | os.WNOHANG | os.WNOWAIT))
                        # The live-orphan refusal precedes release and rescue.
                        os.write(release_write, b'R')
                        self.assertEqual(os.waitpid(child, 0)[1], 0)
                    elif mutant:
                        with self.assertRaisesRegex(self.failureException, 'accepted final procfs denial'):
                            self.assertEqual(verdict.returncode, 1, 'accepted final procfs denial')
                        self.assertEqual(verdict.returncode, 0, (out, err))
                    else:
                        self.assertEqual(verdict.returncode, 1, (out, err))
                        self.assertIn(b'PermissionError: final procfs root denied', err)
                        self.assertFalse(final['live'], 'stale successful JSON was not the control')
                finally:
                    for descriptor in descriptors:
                        os.close(descriptor)

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

        def read(_path, **kwargs):
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

    def test_capability_admission_requires_readable_process_inventory(self):
        module = self.supervisor_module()
        foreign = self.launch([sys.executable, '-I', '-B', '-c',
                               'import time; time.sleep(10)'])
        foreign_stat = Path(f'/proc/{foreign.pid}/stat')
        own_stat = Path(f'/proc/{os.getpid()}/stat')
        real_read = Path.read_text
        real_read(foreign_stat)

        for failure in ('permission', 'io', 'esrch', 'malformed', 'missing', None):
            with self.subTest(failure=failure):
                reads = []

                def read(path, *args, **kwargs):
                    if path == foreign_stat:
                        reads.append(path)
                        if failure == 'permission':
                            raise PermissionError('pre-existing foreign stat denial')
                        if failure == 'io':
                            raise OSError('pre-existing foreign stat I/O failure')
                        if failure == 'esrch':
                            raise ProcessLookupError('foreign procfs stat observation failed')
                        if failure == 'malformed':
                            return 'invalid procfs stat'
                        if failure == 'missing':
                            raise FileNotFoundError('enumerated process disappeared')
                    return real_read(path, *args, **kwargs)

                # Keep the real disposable probe and known foreign process.
                # An unrelated ambient procfs race must not mask this oracle.
                with mock.patch.object(module, 'process_paths', return_value=[own_stat, foreign_stat]), \
                        mock.patch.object(Path, 'read_text', read):
                    if failure in ('permission', 'io', 'esrch', 'malformed'):
                        with mock.patch.object(os, 'fork', side_effect=AssertionError(
                                'process launched despite unreadable pre-existing stat')):
                            self.assertEqual(module.supervise(['unused-command'], 1, .1), 69)
                    else:
                        module.check_capabilities()
                self.assertEqual(reads, [foreign_stat] * (2 if failure == 'esrch' else 1))

    def test_capability_admission_reopens_a_stale_foreign_stat_once(self):
        import errno

        module = self.supervisor_module()
        foreign = subprocess.Popen(
            [sys.executable, '-I', '-B', '-c', 'import os; os.read(0, 1)'],
            env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True)
        self.processes.append(foreign)
        foreign_stat = Path(f'/proc/{foreign.pid}/stat')
        own_stat = Path(f'/proc/{os.getpid()}/stat')
        descriptor = os.open(foreign_stat, os.O_RDONLY)
        real_read = Path.read_text
        try:
            # Retain the real stat descriptor across a synchronized normal exit
            # and reap. Reading that descriptor now produces kernel ESRCH.
            foreign.communicate(b'x', timeout=3)
            self.assertEqual(foreign.returncode, 0)
            self.assertFalse(foreign_stat.exists())
            for replacement in ('missing', 'esrch', 'permission', 'io'):
                with self.subTest(replacement=replacement):
                    errors = []

                    def read(path, *args, **kwargs):
                        if path != foreign_stat:
                            return real_read(path, *args, **kwargs)
                        try:
                            if not errors or replacement == 'esrch':
                                return os.read(descriptor, 4096).decode()
                            if replacement == 'permission':
                                raise PermissionError(errno.EACCES, 'reopened stat denied')
                            if replacement == 'io':
                                raise OSError(errno.EIO, 'reopened stat I/O failure')
                            return real_read(path, *args, **kwargs)
                        except OSError as error:
                            errors.append(error.errno)
                            raise

                    with mock.patch.object(module, 'process_paths', return_value=[own_stat, foreign_stat]), \
                            mock.patch.object(Path, 'read_text', read):
                        if replacement == 'missing':
                            module.check_capabilities()
                        else:
                            with mock.patch.object(os, 'fork', side_effect=AssertionError(
                                    'process launched after an unconfirmed stat reopen')):
                                self.assertEqual(module.supervise(['unused-command'], 1, .1), 69)
                    expected = {'missing': errno.ENOENT, 'esrch': errno.ESRCH,
                                'permission': errno.EACCES, 'io': errno.EIO}[replacement]
                    self.assertEqual(errors, [errno.ESRCH, expected])
        finally:
            os.close(descriptor)

    def test_capability_admission_confirms_reaped_stat_identity_once(self):
        import errno

        module = self.supervisor_module()
        foreign_stat = Path('/proc/0/stat')
        own_stat = Path(f'/proc/{os.getpid()}/stat')
        real_read = Path.read_text
        normal = real_read(own_stat, encoding='ascii', errors='surrogateescape')
        # Captured from a real child while its parent reaped it, followed by
        # ENOENT on a fresh open. Retain the kernel bytes for deterministic
        # regression: reproducing the scheduling race is not a test premise.
        reaped = ('1210922 (python3) X 0 -1 -1 0 -1 4227148 157 0 0 0 0 0 0 0 '
                  '20 0 0 0 1625239 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 17 3 0 0 0 '
                  '0 0 0 0 0 0 0 0 0 0\n')

        def altered(source, index, value):
            prefix, tail = source.rsplit(') ', 1)
            fields = tail.split()
            fields[index] = value
            return prefix + ') ' + ' '.join(fields) + '\n'

        missing = FileNotFoundError(errno.ENOENT, 'confirmed disappearance')
        stale = ProcessLookupError(errno.ESRCH, 'stale descriptor')
        denied = PermissionError(errno.EACCES, 'stat denied')
        unreadable = OSError(errno.EIO, 'stat unreadable')
        cases = [
            ('captured-reap-missing', (reaped, missing), True),
            ('captured-reap-live', (reaped, normal), True),
            ('stale-live', (stale, normal), True),
            ('stale-missing', (stale, missing), True),
            ('normal', (normal,), True),
            ('missing', (missing,), True),
            ('persistent-reap', (reaped, reaped), False),
            ('reap-then-stale', (reaped, stale), False),
            ('stale-then-reap', (stale, reaped), False),
            ('persistent-stale', (stale, stale), False),
            ('reap-then-permission', (reaped, denied), False),
            ('reap-then-io', (reaped, unreadable), False),
            ('reap-then-malformed', (reaped, 'invalid procfs stat'), False),
            ('reap-then-invalid-sid', (reaped, altered(normal, 3, '?')), False),
            ('reap-then-invalid-start', (reaped, altered(normal, 19, '?')), False),
            ('permission', (denied,), False),
            ('io', (unreadable,), False),
            ('malformed', ('invalid procfs stat',), False),
        ]
        # State is sampled before sighand acquisition in do_task_stat. A
        # coherent sentinel in each real state grants only a confirmation.
        for state in ('R', 'S', 'D', 'T', 't', 'X', 'Z', 'P', 'I'):
            cases.append(('state-' + state, (altered(reaped, 0, state), missing), True))
        # Unrelated invalid data cannot obtain a second read even if it would
        # have appeared valid. The exact read count is part of the oracle.
        for label, index, value in (('state', 0, '?'), ('state-pair', 0, 'XS'),
                                    ('parent', 1, '1'), ('group', 2, '1'),
                                    ('session', 3, '-2'), ('start', 19, '?')):
            cases.append(('invalid-' + label, (altered(reaped, index, value),), False))

        for label, replies, admitted in cases:
            with self.subTest(case=label):
                reads = []

                def read(path, *args, **kwargs):
                    if path != foreign_stat:
                        return real_read(path, *args, **kwargs)
                    reads.append(path)
                    self.assertLessEqual(len(reads), len(replies), 'unbounded admission confirmation')
                    result = replies[len(reads) - 1]
                    if isinstance(result, BaseException):
                        raise result
                    return result

                with mock.patch.object(module, 'process_paths', return_value=[own_stat, foreign_stat]), \
                        mock.patch.object(Path, 'read_text', read):
                    if admitted:
                        module.check_capabilities()
                    else:
                        with mock.patch.object(os, 'fork', side_effect=AssertionError(
                                'process launched with an unconfirmed stat identity')):
                            self.assertEqual(module.supervise(['unused-command'], 1, .1), 69)
                self.assertEqual(len(reads), len(replies), 'admission did not confirm exactly once')

    def test_procfs_identity_ignores_arbitrary_thread_name_bytes(self):
        module = self.supervisor_module()
        predicates = []
        for filename, absent in (('download-video.sh', 'PY_GROUP_ABSENT'),
                                 ('download-video-gui.sh', 'PY_GUI_GROUP_ABSENT')):
            source = (PROJECT / filename).read_text(encoding='utf-8')
            for marker in (absent, 'PY_ESCALATE_OWNED'):
                code = source.split(f"<<'{marker}'\n", 1)[1].split(f'\n{marker}', 1)[0]
                tree = ast.parse(code)
                # Execute actual reusable production predicates, excluding the
                # entrypoint that would signal or exit this test controller.
                tree.body = [node for node in tree.body if isinstance(
                    node, (ast.Import, ast.ImportFrom, ast.FunctionDef))]
                namespace = {}
                exec(compile(tree, f'{filename}:{marker}', 'exec'), namespace)
                predicates.append((filename, marker, namespace))
        worker = r'''import ctypes, os, sys, threading
def named_thread():
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(15, bytes.fromhex(sys.argv[1]), 0, 0, 0):
        os._exit(90)
    os.write(1, str(threading.get_native_id()).encode('ascii') + b'\n')
    if os.read(0, 1) != b'X':
        os._exit(91)
thread = threading.Thread(target=named_thread)
thread.start()
thread.join()
'''
        # Only a non-leader thread has this name. It is absent from /proc's
        # root PID inventory, so the fixture cannot poison unrelated suites.
        for name in (b'private-worker', 'révision'.encode(), ('a' * 14 + 'é').encode()):
            with self.subTest(name=name.hex()):
                child = subprocess.Popen(
                    [sys.executable, '-I', '-B', '-c', worker, name.hex()],
                    env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                self.processes.append(child)
                try:
                    self.assertTrue(select.select([child.stdout], [], [], 3)[0],
                                    'named thread did not publish readiness')
                    thread = int(child.stdout.readline())
                    self.assertNotEqual(thread, child.pid)
                    path = Path(f'/proc/{child.pid}/task/{thread}/stat')
                    raw = path.read_bytes()
                    self.assertEqual(raw.split(b' (', 1)[1].rsplit(b') ', 1)[0], name[:15])
                    expected = raw.rsplit(b') ', 1)[1].split()
                    self.assertEqual(int(expected[3]), child.pid)
                    self.assertGreater(int(expected[19]), 0)
                    if len(name) > 15:
                        with self.assertRaises(UnicodeDecodeError):
                            raw.decode('utf-8')
                    row = observer.process_row(path)
                    for key, index in (('parent', 1), ('group', 2), ('session', 3), ('start', 19)):
                        self.assertEqual(row[key], int(expected[index]))
                    # Include the real non-leader task in a controlled root
                    # inventory: an unrelated name must not break selection.
                    # Its root alias is real procfs, not synthetic stat data.
                    real_iterdir = Path.iterdir

                    def inventory(directory):
                        if directory == Path('/proc'):
                            return iter((Path(f'/proc/{os.getpid()}'), Path(f'/proc/{thread}')))
                        return real_iterdir(directory)

                    with mock.patch.object(Path, 'iterdir', inventory):
                        self.assertEqual(observer.snapshot()[thread]['start'], int(expected[19]))
                        self.assertFalse(observer.Observer(self.token + '-unrelated').sample()['live'])
                    # An independent byte oracle validates the kernel identity.
                    # First exercise admission, so the former implementation
                    # fails on its real decoding error before any new helper.
                    with mock.patch.object(module, 'process_paths', return_value=[path]):
                        module.check_capabilities()
                        self.assertFalse(module.session_alive(-1),
                                         'foreign comm bytes vetoed an empty session')
                        self.assertTrue(module.session_alive(child.pid))
                    self.assertFalse(module.process_quiescent(thread, expected[19].decode('ascii')))
                    for filename, marker, namespace in predicates:
                        with self.subTest(source=filename, predicate=marker):
                            self.assertFalse(namespace['process_quiescent'](
                                thread, expected[19].decode('ascii')))
                            if 'process_fields' in namespace:
                                fields = namespace['process_fields'](thread)
                                self.assertEqual(fields[3], expected[3].decode('ascii'))
                                self.assertEqual(fields[19], expected[19].decode('ascii'))
                finally:
                    # Release only the attributed fixture after the verdict;
                    # no global signal or harness rescue is a successful stop.
                    child.communicate(b'X', timeout=3)
                    self.assertEqual(child.returncode, 0)

    def test_capability_refusal_diagnostic_excludes_private_exception_data(self):
        import errno

        module = self.supervisor_module()
        private = 'synthetic_private_capability_marker'
        custom = type(private, (OSError,), {})
        cases = [(PermissionError(errno.EACCES, private, f'/private/{private}'),
                  'PermissionError', str(errno.EACCES)),
                 (ProcessLookupError(errno.ESRCH, private), 'ProcessLookupError', str(errno.ESRCH)),
                 (FileNotFoundError(errno.ENOENT, private), 'FileNotFoundError', str(errno.ENOENT)),
                 (UnicodeDecodeError('utf-8', private.encode() + b'\xff', 0, 1, private),
                  'UnicodeDecodeError', 'none'),
                 (AttributeError(private), 'AttributeError', 'none'),
                 (IndexError(private), 'IndexError', 'none'),
                 (ValueError(private), 'ValueError', 'none'),
                 (custom(errno.EIO, private), 'OSError', str(errno.EIO)),
                 (custom(private, private), 'OSError', 'none'),
                 (custom(100000, private), 'OSError', 'none')]
        for error, kind, number in cases:
            for entrypoint in ('check', 'supervise'):
                with self.subTest(kind=kind, errno=number, entrypoint=entrypoint):
                    output = io.StringIO()
                    with mock.patch.object(module, 'check_capabilities', side_effect=error), \
                            mock.patch.object(sys, 'argv', ['supervisor', '--check-capabilities']), \
                            mock.patch.object(os, 'fork', side_effect=AssertionError(
                                'diagnostic refusal launched work')), redirect_stderr(output):
                        status = (module.main() if entrypoint == 'check'
                                  else module.supervise(['unused-command'], 1, .1))
                    self.assertEqual(status, 69)
                    self.assertNotIn(private, output.getvalue(),
                                     'capability diagnostic leaked private exception data')
                    self.assertEqual(output.getvalue(),
                                     'Error: required Linux process supervision capabilities are unavailable. '
                                     f'cause={kind} errno={number}\n')

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

    @staticmethod
    def hls_witness_module():
        module_spec = importlib.util.spec_from_file_location(
            'hls_witness', PROJECT / 'tests/hls-cancellation-witness.py')
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        return module

    def exercise_hls_witness(self, mode, *, late_inventory=False, corruption=None,
                             restore_mutation=False):
        import socket
        import threading
        import types

        module = self.hls_witness_module()
        native = self.root / 'native.py'
        native.write_text('''import os, signal, subprocess, sys
from pathlib import Path
root = Path(os.environ['HLS_FIXTURE_ROOT'])
mode = os.environ['HLS_FIXTURE_MODE']
if '--orphan' in sys.argv:
    (root / 'orphan').write_text(str(os.getpid()))
    while True: signal.pause()
if mode == 'detached':
    subprocess.run([sys.executable, '-c',
        'import subprocess,sys; subprocess.Popen(sys.argv[1:], start_new_session=True, '
        'stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)',
        sys.executable, __file__, '--orphan'], check=True)
def stopped(_number, _frame):
    (root / 'consumer-term').touch()
    if mode != 'survivor': raise SystemExit(143)
signal.signal(signal.SIGTERM, stopped)
(root / 'ready').write_text(str(os.getpid()))
while True: signal.pause()
''')
        engine = self.root / 'engine.py'
        engine.write_text('''import os, signal, subprocess, sys
from pathlib import Path
root = Path(os.environ['HLS_FIXTURE_ROOT'])
mode = os.environ['HLS_FIXTURE_MODE']
if mode == 'premature':
    (root / 'ready').write_text(str(os.getpid()))
    raise SystemExit(143)
args = [sys.executable, str(root / 'native.py'), '--load-info-json', 'synthetic-plan']
if mode == 'absent': args = [sys.executable, '-c', 'import signal; signal.pause()']
child = subprocess.Popen(args, start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=None if mode == 'pipe' else subprocess.DEVNULL,
                         stderr=None if mode == 'pipe' else subprocess.DEVNULL)
def stopped(_number, _frame):
    if mode not in ('unforwarded', 'pipe'): child.terminate()
    if mode not in ('unforwarded', 'survivor', 'pipe'): child.wait(timeout=3)
    if mode == 'published': (root / 'result').write_text('unexpected successful publication')
    if mode == 'success-message': print('Download completed successfully.')
    raise SystemExit(143)
signal.signal(signal.SIGTERM, stopped)
if mode == 'absent': (root / 'ready').write_text(str(child.pid))
while True: signal.pause()
''')
        (self.root / 'saved-fragment').write_bytes(b'fixture media must remain retained')
        witness = module.CancellationWitness(
            self.root, '/hls/missing.ts', str(native), os.getpid(), token=self.token)
        stopping = threading.Event()
        server_errors = []

        def barrier():
            try:
                deadline = time.monotonic() + 3
                while not (self.root / 'ready').exists():
                    if stopping.wait(.005):
                        return
                    if time.monotonic() >= deadline:
                        raise AssertionError('synthetic consumer readiness missing')
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.connect(str(witness.address))
                    connection.sendall(f'RETRY {time.monotonic_ns()}\n'.encode('ascii'))
                    connection.recv(1)
            except (ConnectionResetError, BrokenPipeError):
                pass
            except BaseException as error:
                server_errors.append(type(error).__name__)

        server = threading.Thread(target=barrier)
        server.start()
        source = (PROJECT / 'tests/real-tools-integration.sh').read_text()
        body = source.split("<<'PY_EXISTING_ASSEMBLED'\n", 1)[1].split('\nPY_EXISTING_ASSEMBLED', 1)[0]
        function = next(node for node in ast.parse(body).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'capture_engine')
        process_holder = []

        def launch(*arguments, **keywords):
            process = subprocess.Popen(*arguments, **keywords)
            process_holder.append(process)
            self.processes.append(process)
            # A deterministic late-inventory challenge: the real detached child
            # is already adopted before the HLS observer first sees the engine.
            self.wait_file('ready', process)
            if mode == 'detached':
                self.wait_file('orphan', process)
            return process

        controlled = types.SimpleNamespace(Popen=launch, PIPE=subprocess.PIPE,
                                           TimeoutExpired=subprocess.TimeoutExpired,
                                           CompletedProcess=subprocess.CompletedProcess)
        namespace = dict(signal=signal, subprocess=controlled, root=self.root, sys=sys, time=time)
        exec(compile(ast.Module(body=[function], type_ignores=[]), 'real-hls-capture', 'exec'), namespace)
        observed, failure, result = [], None, None
        original_children = module.direct_children
        original_signal = witness.before_signal
        persistent_patches = []
        if corruption == 'peer':
            witness.server_pid += 1

        def corrupt_signal(process):
            if corruption == 'identity':
                original_identity = module.identity

                def changed(pid):
                    row = original_identity(pid)
                    if row is not None and pid == process.pid:
                        row = dict(row, start=row['start'] + 1)
                    return row

                with mock.patch.object(module, 'identity', side_effect=changed):
                    return original_signal(process)
            if corruption == 'persistent-unreadable':
                patcher = mock.patch.object(module.observer, 'snapshot',
                                            side_effect=PermissionError('controlled'))
                patcher.start()
                persistent_patches.append(patcher)
                return original_signal(process)
            if corruption == 'unreadable':
                with mock.patch.object(module.observer, 'snapshot', side_effect=PermissionError('controlled')):
                    return original_signal(process)
            return original_signal(process)

        witness.before_signal = corrupt_signal
        try:
            with ExitStack() as patches:
                if late_inventory:
                    patches.enter_context(mock.patch.object(
                        module, 'direct_children', side_effect=lambda: original_children() & {
                            witness.engine[0] if witness.engine else -1}))
                try:
                    result = namespace['capture_engine'](
                        [sys.executable, str(engine)],
                        dict(os.environ, HLS_FIXTURE_ROOT=str(self.root), HLS_FIXTURE_MODE=mode),
                        timeout=.5 if mode == 'pipe' else 3, grace=.1,
                        cancellation=witness, cancel_observed=observed)
                except (AssertionError, PermissionError, subprocess.TimeoutExpired) as error:
                    failure = error
            for patcher in persistent_patches:
                patcher.stop()
            persistent_patches.clear()
            if restore_mutation:
                witness.restore_fragment = lambda saved, missing: Path(saved).rename(missing)
            witness.restore_fragment(self.root / 'saved-fragment', self.root / 'restored-fragment')
            alive = self.observer.sample()['live']
            preservation = (self.root / 'preserve-active-engine').exists()
            # Verdicts precede witness close, rescue, harvesting or fixture removal.
            if mode == 'normal' and corruption is None:
                self.assertIsNone(failure)
                self.assertEqual(result.returncode, 143)
                self.assertTrue(observed)
                self.assertTrue(witness.completed)
                self.assertFalse(alive)
                self.assertFalse(preservation)
            elif mode == 'detached' and late_inventory:
                # Removing adopted-child discovery makes the actual oracle
                # accept a persistent new-session consumer. This counterexample
                # must be rejected by the independent assertion below.
                self.assertIsNone(failure)
                self.assertTrue(alive)
                with self.assertRaisesRegex(self.failureException, 'orphan escaped'):
                    self.assertFalse(alive, 'orphan escaped the late-inventory mutant')
            else:
                self.assertIsNotNone(failure, 'HLS witness accepted an invalid cancellation')
                self.assertFalse(witness.completed)
                if mode in ('detached', 'survivor', 'unforwarded', 'pipe'):
                    self.assertTrue(alive, 'negative control was rescued before its verdict')
                    self.assertTrue(preservation, 'live consumer lost fixture preservation')
            if corruption == 'persistent-unreadable':
                self.assertTrue(preservation, 'uncertain identity lost fixture preservation')
            if mode == 'unforwarded':
                self.assertFalse((self.root / 'consumer-term').exists())
            if mode == 'survivor':
                self.assertTrue((self.root / 'consumer-term').exists())
            def assert_preserved():
                self.assertTrue((self.root / 'saved-fragment').exists(),
                                'premature fixture restoration')
                self.assertFalse((self.root / 'restored-fragment').exists())

            if restore_mutation:
                with self.assertRaisesRegex(self.failureException, 'premature fixture restoration'):
                    assert_preserved()
            elif witness.completed:
                self.assertFalse((self.root / 'saved-fragment').exists())
                self.assertTrue((self.root / 'restored-fragment').exists())
            else:
                assert_preserved()
        finally:
            for patcher in persistent_patches:
                patcher.stop()
            stopping.set()
            witness.close()
            server.join(3)
            self.assertFalse(server.is_alive(), 'retry barrier did not close')
            self.assertEqual(server_errors, [])

    def test_hls_cancellation_active_native_consumer(self):
        self.exercise_hls_witness('normal')

    def test_hls_cancellation_rejects_surviving_consumer(self):
        self.exercise_hls_witness('survivor')

    def test_hls_cancellation_rejects_unforwarded_signal(self):
        self.exercise_hls_witness('unforwarded')

    def test_hls_cancellation_rejects_detached_consumer(self):
        self.exercise_hls_witness('detached')

    def test_hls_cancellation_late_inventory_mutation_is_detected(self):
        self.exercise_hls_witness('detached', late_inventory=True)

    def test_hls_cancellation_rejects_missing_native_consumer(self):
        self.exercise_hls_witness('absent')

    def test_hls_cancellation_rejects_premature_return(self):
        self.exercise_hls_witness('premature')

    def test_hls_cancellation_rejects_replaced_identity(self):
        self.exercise_hls_witness('normal', corruption='identity')

    def test_hls_cancellation_rejects_unreadable_identity(self):
        self.exercise_hls_witness('normal', corruption='unreadable')

    def test_hls_witness_identity_revalidates_procfs_stat_esrch(self):
        module = self.hls_witness_module()
        row = dict(start=123, state='S', parent=1, group=123, session=123)
        path = Path('/proc/123/stat')
        with mock.patch.object(module.observer, 'process_row',
                               side_effect=[ProcessLookupError(errno.ESRCH, 'read race'), row]) as read:
            self.assertEqual(module.identity(123), row)
        self.assertEqual([call.args[0] for call in read.call_args_list], [path, path])
        with mock.patch.object(module.observer, 'process_row',
                               side_effect=[ProcessLookupError(errno.ESRCH, 'read race'),
                                            FileNotFoundError(errno.ENOENT, 'gone')]):
            self.assertIsNone(module.identity(123))
        replacement = dict(row, start=row['start'] + 1)
        with mock.patch.object(module.observer, 'process_row',
                               side_effect=[ProcessLookupError(errno.ESRCH, 'read race'), replacement]):
            self.assertEqual(module.identity(123), replacement)
        with mock.patch.object(module.observer, 'process_row',
                               side_effect=[ProcessLookupError(errno.ESRCH, 'read race'),
                                            ProcessLookupError(errno.ESRCH, 'still racing')]):
            with self.assertRaises(ProcessLookupError):
                module.identity(123)
        for number in (errno.EACCES, errno.EIO):
            with self.subTest(errno=number), \
                    mock.patch.object(module.observer, 'process_row',
                                      side_effect=[ProcessLookupError(errno.ESRCH, 'read race'),
                                                   OSError(number, 'retry failed')]):
                with self.assertRaises(OSError) as failure:
                    module.identity(123)
                self.assertEqual(failure.exception.errno, number)

    def test_hls_cancellation_rejects_held_pipe_after_leader_exit(self):
        self.exercise_hls_witness('pipe')

    def test_hls_cancellation_rejects_wrong_barrier_peer(self):
        self.exercise_hls_witness('normal', corruption='peer')

    def test_hls_cancellation_premature_restoration_mutation_is_detected(self):
        self.exercise_hls_witness('unforwarded', restore_mutation=True)

    def test_hls_cancellation_does_not_signal_foreign_process(self):
        guardian = self.root / 'foreign.py'
        guardian.write_text('''import signal, sys
from pathlib import Path
root = Path(sys.argv[1])
def stopped(_number, _frame):
    (root / 'foreign-signalled').touch()
    raise SystemExit(91)
for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, stopped)
(root / 'foreign-ready').write_text('ready')
while True: signal.pause()
''')
        foreign = self.launch([sys.executable, str(guardian), str(self.root)])
        self.wait_file('foreign-ready', foreign)
        # The HLS controller is a sibling of this separately marked process,
        # so neither ancestry nor subreaping can grant authority over it.
        result = subprocess.run(
            [sys.executable, '-I', '-B', str(PROJECT / 'tests/process-supervision-integration.py'),
             'ProcessTests.test_hls_cancellation_active_native_consumer'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
        self.assertEqual(result.returncode, 0, 'isolated HLS positive control failed')
        self.assertIsNone(foreign.poll(), 'HLS witness terminated an unrelated process')
        self.assertFalse((self.root / 'foreign-signalled').exists(),
                         'HLS witness signalled an unrelated process')

    def test_hls_cancellation_preserves_uncertain_cleanup(self):
        self.exercise_hls_witness('normal', corruption='persistent-unreadable')

    def test_hls_cancellation_rejects_successful_publication(self):
        self.exercise_hls_witness('published')

    def test_hls_cancellation_rejects_success_message(self):
        self.exercise_hls_witness('success-message')

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

    def timeout_pidfd_terminal(self, descriptor):
        readiness = select.poll()
        readiness.register(descriptor, select.POLLIN)
        events = readiness.poll(0)
        if not events:
            return False
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0][0], descriptor)
        self.assertTrue(events[0][1] & select.POLLIN)
        self.assertFalse(events[0][1] & ~(select.POLLIN | select.POLLHUP))
        return True

    def admit_timeout_launcher(self, identities, descriptors, release):
        # The fixture's voluntary exit must follow its first complete privacy
        # observation. The production timeout remains armed throughout; a late
        # or failed observation cannot authorize release or repair its refusal.
        for descriptor in descriptors.values():
            self.assertFalse(self.timeout_pidfd_terminal(descriptor),
                             'fixture terminated before initial observation')
        state = self.observer.sample()
        self.assertFalse(state['url_in_argv'], 'initial fixture observation found a URL')
        for pid, row in identities.items():
            self.assertIn(str(pid), state['live'], 'fixture missing from initial observation')
            for field in ('start', 'parent', 'group', 'session'):
                self.assertEqual(state['live'][str(pid)][field], row[field],
                                 'initial fixture identity changed')
        for descriptor in descriptors.values():
            self.assertFalse(self.timeout_pidfd_terminal(descriptor),
                             'fixture terminated during initial observation')
        self.assertEqual(os.write(release, b'R'), 1, 'launcher acknowledgement was not written')

    def test_timeout_admission_requires_current_complete_observation(self):
        identities = {101: {'start': 11, 'parent': 100, 'group': 101, 'session': 101},
                      102: {'start': 12, 'parent': 101, 'group': 102, 'session': 101}}
        descriptors = {101: 201, 102: 202}
        cases = ('valid', 'missing', 'reused', 'privacy', 'terminal-before', 'terminal-after',
                 'esrch', 'eacces', 'eio', 'missing-ack')
        for case in cases:
            with self.subTest(case=case):
                state = {'live': {str(pid): dict(row) for pid, row in identities.items()},
                         'url_in_argv': []}
                if case == 'missing':
                    state['live'].pop('101')
                elif case == 'reused':
                    state['live']['101']['start'] += 1
                elif case == 'privacy':
                    state['url_in_argv'] = [(102, 12)]
                events = []
                reads, writes = os.pipe()
                os.set_blocking(reads, False)
                original_write = os.write
                error = None
                if case in ('esrch', 'eacces', 'eio'):
                    error = observer.ObservationError(
                        {'esrch': errno.ESRCH, 'eacces': errno.EACCES, 'eio': errno.EIO}[case],
                        'synthetic initial observation refusal')

                def terminal(descriptor):
                    events.append(('pidfd', descriptor))
                    return ((case == 'terminal-before' and len(events) == 1)
                            or (case == 'terminal-after' and len(events) == 4))

                def sample():
                    events.append(('sample',))
                    if error is not None:
                        raise error
                    return state

                def write(descriptor, payload):
                    events.append(('ack',))
                    self.assertEqual((descriptor, payload), (writes, b'R'))
                    return 0 if case == 'missing-ack' else original_write(descriptor, payload)

                try:
                    with mock.patch.object(self, 'timeout_pidfd_terminal', side_effect=terminal), \
                            mock.patch.object(self.observer, 'sample', side_effect=sample), \
                            mock.patch.object(os, 'write', side_effect=write):
                        if case == 'valid':
                            self.admit_timeout_launcher(identities, descriptors, writes)
                        elif error is not None:
                            with self.assertRaises(observer.ObservationError) as caught:
                                self.admit_timeout_launcher(identities, descriptors, writes)
                            self.assertIs(caught.exception, error)
                        else:
                            with self.assertRaises(self.failureException):
                                self.admit_timeout_launcher(identities, descriptors, writes)
                    if case == 'valid':
                        self.assertEqual(os.read(reads, 2), b'R')
                        self.assertEqual(events, [('pidfd', 201), ('pidfd', 202), ('sample',),
                                                  ('pidfd', 201), ('pidfd', 202), ('ack',)])
                    else:
                        with self.assertRaises(BlockingIOError):
                            os.read(reads, 1)
                        if case != 'missing-ack':
                            self.assertNotIn(('ack',), events)
                finally:
                    os.close(reads)
                    os.close(writes)

    def test_timeout_early_leader_resistant_descendant_holding_pipe(self):
        child = self.child(resistant=True, new_group=True)
        launcher = self.root / 'launch.py'
        launcher.write_text('''import os, subprocess, sys, time
from pathlib import Path
subprocess.Popen([sys.executable, sys.argv[1]])
while not Path(sys.argv[1]).with_name('ready').exists(): time.sleep(.01)
if os.read(int(sys.argv[2]), 1) != b'R': raise SystemExit(70)
''')
        admission, release = os.pipe()
        self.addCleanup(os.close, release)
        try:
            p = subprocess.Popen(
                [sys.executable, str(PROJECT / 'private-process-supervisor.py'),
                 '--timeout', '.3', '--grace', '.2', '--', sys.executable,
                 str(launcher), str(child), str(admission)], pass_fds=(admission,),
                env=dict(os.environ, YTDLP_QUALIFICATION_TOKEN=self.token),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            self.processes.append(p)
        finally:
            os.close(admission)
        consumer = int(self.wait_file('ready', p))
        consumer_row = observer.current_process(consumer)
        self.assertIsNotNone(consumer_row)
        leader = consumer_row['parent']
        leader_row = observer.current_process(leader)
        self.assertIsNotNone(leader_row)
        self.assertEqual((leader_row['parent'], leader_row['group'], leader_row['session']),
                         (p.pid, leader, leader))
        self.assertEqual((consumer_row['group'], consumer_row['session']), (consumer, leader))
        identities = {leader: leader_row, consumer: consumer_row}
        descriptors = {}
        for pid, row in identities.items():
            descriptor = os.pidfd_open(pid)
            self.addCleanup(os.close, descriptor)
            current = observer.current_process(pid)
            self.assertIsNotNone(current)
            for field in ('start', 'parent', 'group', 'session'):
                self.assertEqual(current[field], row[field], 'pidfd fixture identity changed')
            descriptors[pid] = descriptor
        self.admit_timeout_launcher(identities, descriptors, release)
        deadline = time.monotonic() + 5
        while not self.timeout_pidfd_terminal(descriptors[leader]):
            self.assertIsNone(p.poll(), 'supervisor returned before launcher retirement')
            self.assertLess(time.monotonic(), deadline, 'launcher did not acknowledge release')
            time.sleep(.001)
        # The supervisor pins its zombie child. Check raw exit_code as well as
        # identity: terminal readiness alone could be TERM, not voluntary exit.
        fields = Path(f'/proc/{leader}/stat').read_text(
            encoding='ascii', errors='surrogateescape').rsplit(') ', 1)[1].split()
        self.assertEqual((int(fields[19]), fields[0], int(fields[1])),
                         (leader_row['start'], 'Z', p.pid))
        self.assertEqual(int(fields[49]), 0, 'launcher did not exit normally after observation')
        self.assertFalse(self.timeout_pidfd_terminal(descriptors[consumer]))
        self.assertFalse((self.root / 'term').exists(), 'timeout preceded the early leader exit')
        self.assertIsNone(p.poll(), 'supervisor returned while the descendant remained live')
        # Pipe EOF must not hide a premature supervisor return. Check the
        # authenticated last FD holder immediately after wait(), before drain.
        self.assertEqual(p.wait(timeout=5), 137)
        self.assertTrue(self.timeout_pidfd_terminal(descriptors[consumer]),
                        'supervisor returned before last FD holder stopped')
        p.communicate(timeout=5)
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

    def sample_before_engine_signal(self, reuse):
        if (reuse is False and sys.version_info[:2] == (3, 15)
                and self._testMethodName == 'test_engine_cli_wrapper_exit_retains_resource_and_lock'
                and os.environ.get('YTDLP_FEDORA_FIRST_FAILURE') == 'engine-cli-first-sample'):
            return self.sample_with_first_failure(fedora_native=True)
        return self.observer.sample()

    def engine_case(self, reuse):
        self.child(slow=True)
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
        self.sample_before_engine_signal(reuse)
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
        self.child(resistant=True, new_group=True)
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

    def sample_before_cli_escalation(self):
        selection = (os.environ.get('STRESS_SHARD'), os.environ.get('YTDLP_STRESS_FIRST_FAILURE'))
        if (self._testMethodName != 'test_cli_escalates_subgroup_before_retiring_sentinel'
                or selection not in (('2', '2:18'), ('4', '4:12'))):
            return self.observer.sample()
        return self.sample_with_first_failure(fedora_native=False)

    def sample_with_first_failure(self, *, fedora_native):
        watcher = self.observer
        previous = watcher.diagnostics_enabled, watcher.identity_diagnostics_enabled
        watcher.diagnostics_enabled = watcher.identity_diagnostics_enabled = True
        try:
            return watcher.sample()
        except Exception as error:
            report_first_failure(watcher, error, fedora_native=fedora_native)
            raise
        finally:
            watcher.diagnostics_enabled, watcher.identity_diagnostics_enabled = previous

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
        self.sample_before_cli_escalation()
        p.send_signal(signal.SIGTERM)
        self.wait_file('term', p)
        p.send_signal(signal.SIGUSR1)
        out, err = self.finish(p)
        self.assertEqual(p.returncode, 143, (out, err))
        self.assertFalse(self.observer.sample()['live'], 'CLI lost subgroup authority before escalation')

    def test_gui_stops_timeout_subgroup_after_leader_exit(self):
        self.child(resistant=True)
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


class YtdlpDiagnosticFixture(unittest.TestCase):
    """Exercise the actual Bash pipeline; external bytes never enter argv."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ytdlp-diagnostics-')
        self.root = Path(self.temp.name)
        source = Path(os.environ.get('YTDLP_PRIVACY_TEST_SOURCE', PROJECT / 'download-video.sh')).read_text()
        self.source = source[source.index('run_supervised_ytdlp() {'):source.index('\nremove_recorded_private_aria2_sensitive_file()')]
        self.wrapper = self.root / 'pipeline.sh'
        self.wrapper.write_text('''set -uo pipefail
run_supervised_command() { "$@"; DOWNLOAD_STATUS=$?; }
''' + self.source + '''
run_supervised_ytdlp "$@"
exit "$DOWNLOAD_STATUS"
''')

    def tearDown(self):
        self.temp.cleanup()

    def run_pipeline(self, payload, status=23, wrapper=None, memory_limit=False):
        import resource
        private_input = self.root / 'external.bin'
        private_input.write_bytes(payload)
        producer = self.root / 'producer.py'
        producer.write_text('''import os, sys
from pathlib import Path
payload = Path(__file__).with_name("external.bin").read_bytes()
os.write(1, bytes(range(256)) + b"\\nYTDLP_PROGRESS|1|2|3\\n")
os.write(2, payload)
sys.exit(int(sys.argv[1]))
''')
        def constrain_memory():
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024,) * 2)
        return subprocess.run(['bash', str(wrapper or self.wrapper), sys.executable,
                               str(producer), str(status)], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=15,
                              preexec_fn=constrain_memory if memory_limit else None)

    def assert_private_result(self, result, status=23):
        self.assertEqual(result.returncode, status, 'producer status changed')
        self.assertEqual(result.stdout, bytes(range(256)) + b'\nYTDLP_PROGRESS|1|2|3\n')
        self.assertNotIn(b'PRIVATE_', result.stderr, 'external diagnostic disclosed a private sentinel')
        self.assertTrue(result.stderr.startswith(b'[YTDLP_'), 'controlled diagnostic missing')
        self.assertLessEqual(len(result.stderr), 16384)

class YtdlpDiagnosticTests(YtdlpDiagnosticFixture):
    def test_closed_categories_unicode_controls_and_unknown_messages(self):
        cases = [
            (b'ERROR: Unsupported URL: https://localhost/a?key=PRIVATE_ONE&auth=PRIVATE_TWO', b'[YTDLP_UNSUPPORTED_URL]'),
            (b'ERROR: [generic] PRIVATE_GENERIC: extraction failed', b'[YTDLP_DIAGNOSTIC]'),
            (b'ERROR: HTTP Error 403: PRIVATE_REASON', b'(code 403)'),
            (b'HTTP Error 499: PRIVATE_REASON', b'reported an HTTP error.\n'),
            (b'Requested format is not available PRIVATE_FORMAT', b'[YTDLP_FORMAT_UNAVAILABLE]'),
            ('inconnu \u00e9\u6f22\u202e PRIVATE_UNICODE'.encode(), b'[YTDLP_DIAGNOSTIC]'),
            (b'\xff\xfe PRIVATE_INVALID\x00\r\x1b[31mPRIVATE_ANSI\nPRIVATE_LF', b'[YTDLP_DIAGNOSTIC]'),
            (b'ordinary seemingly harmless text PRIVATE_UNKNOWN', b'[YTDLP_DIAGNOSTIC]'),
        ]
        for payload, category in cases:
            with self.subTest(category=category):
                result = self.run_pipeline(payload)
                self.assert_private_result(result)
                self.assertIn(category, result.stderr)
        self.assert_private_result(self.run_pipeline(b'PRIVATE_SUCCESS', status=0), 0)

    def test_line_and_emission_limits_continue_to_eof(self):
        import resource
        producer = self.root / 'stream.py'
        producer.write_text('''import os
from pathlib import Path
for _ in range(32768):
    os.write(2, b"PRIVATE_LONG" + b"x" * 4084)
os.write(2, b"\\n")
for _ in range(20000):
    os.write(2, b"PRIVATE_MANY\\n")
Path(__file__).with_name("drained").write_text("complete")
os.write(1, b"complete")
''')
        def constrain_memory():
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024,) * 2)
        # This byte-protocol ceiling excludes the host's locale archive, which
        # can exceed 64 MiB before Bash starts. Keep the limit and every emitted
        # diagnostic observable; other fixtures retain the caller's locale.
        result = subprocess.run(['bash', str(self.wrapper), sys.executable, str(producer)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
                                env=dict(os.environ, LC_ALL='C', LANGUAGE='C'),
                                preexec_fn=constrain_memory)
        self.assertEqual(result.returncode, 0, 'bounded filter broke the producer pipe')
        self.assertEqual(result.stdout, b'complete')
        self.assertTrue((self.root / 'drained').exists())
        self.assertLessEqual(len(result.stderr), 16384)
        self.assertLessEqual(len(result.stderr.splitlines()), 64)
        self.assertIn(b'[YTDLP_DIAGNOSTIC_TRUNCATED]', result.stderr)
        self.assertIn(b'[YTDLP_DIAGNOSTIC_LIMIT]', result.stderr)
        self.assertNotIn(b'PRIVATE_', result.stderr, 'long diagnostic disclosed a private sentinel')

    def test_filter_failure_is_fatal_and_never_prints_exception(self):
        mutant = self.root / 'fault.sh'
        original = self.wrapper.read_text()
        needle = 'line = sys.stdin.buffer.readline(line_limit + 1)'
        self.assertIn(needle, original)
        mutant.write_text(original.replace(needle, 'raise RuntimeError("PRIVATE_EXCEPTION")'))
        for producer_status in (0, 23):
            result = self.run_pipeline(b'PRIVATE_INPUT\n', producer_status, mutant)
            self.assertEqual(result.returncode, 70, 'filter failure lost priority')
            self.assertIn(b'[YTDLP_DIAGNOSTIC_FILTER_FAILED]', result.stderr)
            self.assertNotIn(b'PRIVATE_', result.stderr, 'filter traceback disclosed private data')
            self.assertNotIn(b'Traceback', result.stderr)

    def test_descendant_holding_stderr_delays_completion_until_eof(self):
        child = self.root / 'descendant.py'
        child.write_text('''import os, time
from pathlib import Path
root = Path(__file__).parent
if os.fork():
    os.write(2, b"PRIVATE_PARENT\\n")
    (root / "producer-exited").write_text("yes")
    os._exit(23)
os.close(1)
(root / "child-ready").write_text("yes")
while not (root / "release").exists():
    time.sleep(.01)
os.write(2, b"PRIVATE_DESCENDANT\\n")
os._exit(0)
''')
        # The independent parent marker proves early producer exit; the child
        # retains only stderr, so stdout capture cannot create a false wait.
        p = subprocess.Popen(['bash', str(self.wrapper), sys.executable, str(child)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while (not all((self.root / name).exists() for name in ('child-ready', 'producer-exited'))
                   and time.monotonic() < deadline):
                time.sleep(.01)
            self.assertTrue((self.root / 'child-ready').exists(), 'descendant did not start')
            self.assertTrue((self.root / 'producer-exited').exists())
            # Observe after both sides of the fork are ready; a process that has
            # merely not been scheduled yet is not evidence of waiting for EOF.
            observation_end = time.monotonic() + .2
            while time.monotonic() < observation_end:
                self.assertIsNone(p.poll(), 'pipeline returned before descendant EOF')
                time.sleep(.01)
            (self.root / 'release').touch()
            out, err = p.communicate(timeout=5)
            self.assertEqual(p.returncode, 23)
            self.assertEqual(out, b'')
            self.assertIn(b'[YTDLP_DIAGNOSTIC]', err)
            self.assertNotIn(b'PRIVATE_', err)
        finally:
            (self.root / 'release').touch()
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGKILL)
            p.communicate(timeout=5)

    def test_group_signals_preserve_final_drain_and_producer_status(self):
        producer = self.root / 'signal-producer.py'
        producer.write_text('''import os, signal, sys, time
from pathlib import Path
root = Path(__file__).parent
def stop(number, frame):
    for _ in range(10000):
        os.write(2, b"PRIVATE_SIGNAL\\n")
    (root / "handled").write_text(str(number))
    sys.exit(128 + number)
for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, stop)
(root / "ready").write_text("yes")
while True:
    time.sleep(.01)
''')
        engine_source = self.root / 'engine-functions.sh'
        engine_source.write_text((PROJECT / 'download-video.sh').read_text().rsplit('\nmain "$@"', 1)[0])
        supervised = self.root / 'supervised.sh'
        supervised.write_text('''source "$1"
TEMP_DIR=$2
OUTPUT_LOCK_ROOT=$2
REUSE_CURRENT_SESSION=false
shift 2
trap cleanup EXIT
trap 'request_shutdown HUP 129' HUP
trap 'request_shutdown INT 130' INT
trap 'request_shutdown TERM 143' TERM
run_supervised_ytdlp "$@"
exit "$DOWNLOAD_STATUS"
''')
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number):
                for name in ('ready', 'handled'):
                    (self.root / name).unlink(missing_ok=True)
                p = subprocess.Popen(['bash', str(supervised), str(engine_source), str(self.root),
                                      sys.executable, str(producer)], stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while not (self.root / 'ready').exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue((self.root / 'ready').exists())
                    p.send_signal(number)
                    out, err = p.communicate(timeout=8)
                    self.assertEqual(p.returncode, 128 + number, 'signal status changed')
                    self.assertEqual((self.root / 'handled').read_text(), str(int(number)))
                    self.assertEqual(out, b'')
                    self.assertIn(b'[YTDLP_DIAGNOSTIC_LIMIT]', err)
                    self.assertNotIn(b'PRIVATE_', err)
                finally:
                    if p.poll() is None:
                        os.killpg(p.pid, signal.SIGKILL)
                    p.communicate(timeout=5)


class YtdlpRealDiagnosticTests(YtdlpDiagnosticFixture):
    """Real loopback witnesses, explicitly required by the real-tool suite."""

    def test_real_postprocess_phase_precedes_remux_through_closed_stderr(self):
        import shutil
        if not any(argument == 'YtdlpRealDiagnosticTests'
                   or argument.startswith('YtdlpRealDiagnosticTests.')
                   for argument in sys.argv[1:]):
            self.skipTest('real witnesses require explicit YtdlpRealDiagnosticTests selection')
        executable, ffmpeg = shutil.which('yt-dlp'), shutil.which('ffmpeg')
        self.assertIsNotNone(executable, 'real qualification requires yt-dlp')
        self.assertIsNotNone(ffmpeg, 'real qualification requires FFmpeg')
        source = Path(os.environ.get('YTDLP_PRIVACY_TEST_SOURCE', PROJECT / 'download-video.sh')).read_text()
        reporting = source[source.index('configure_download_reporting() {'):
                           source.index('\n# Execute either the private aria2 direct path')]
        options = subprocess.check_output(['bash', '-c', '''set -euo pipefail
MACHINE_PROGRESS=true
ARTE_ENABLED=false
PATH_RECORD_FD_PATH=''
YT_DLP_OPTIONS=()
''' + reporting + '\nconfigure_download_reporting\nprintf "%s\\0" "${YT_DLP_OPTIONS[@]}"\n'])
        component = self.root / 'fixture [probe].mp4'
        subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i',
                        'color=c=blue:s=32x32:r=5', '-t', '1', '-c:v', 'mpeg4', str(component)],
                       check=True, capture_output=True, timeout=10)
        seed = self.root / 'seed.json'
        seed.write_text(json.dumps(dict(id='probe', title='fixture', extractor='generic',
                                       extractor_key='Generic', duration=1,
                                       formats=[dict(format_id='av', ext='mp4', protocol='http',
                                                     url='http://127.0.0.1:9/unused-owned-component',
                                                     vcodec='mpeg4', acodec='none')])) + '\n')
        binaries = self.root / 'bin'
        binaries.mkdir()
        ready, release = self.root / 'remux-ready', self.root / 'remux-release'
        wrapper = binaries / 'ffmpeg'
        wrapper.write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
args = sys.argv[1:]
if '-i' in args and any(arg.endswith('.mkv') for arg in args):
    Path(os.environ['PHASE_TEST_READY']).touch()
    deadline = time.monotonic() + 10
    while not Path(os.environ['PHASE_TEST_RELEASE']).exists():
        if time.monotonic() >= deadline:
            sys.exit(75)
        time.sleep(.01)
os.execv(os.environ['PHASE_TEST_FFMPEG'], [os.environ['PHASE_TEST_FFMPEG'], *args])
''')
        wrapper.chmod(0o700)
        home = self.root / 'home'
        home.mkdir()
        environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home),
                           XDG_CACHE_HOME=str(home), XDG_DATA_HOME=str(home),
                           PHASE_TEST_READY=str(ready), PHASE_TEST_RELEASE=str(release),
                           PHASE_TEST_FFMPEG=ffmpeg, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
        command = ['bash', str(self.wrapper), executable, '--ignore-config', '--no-plugin-dirs',
                   '--no-cache-dir', '--no-update', '--no-overwrites', '--no-simulate',
                   '--load-info-json', str(seed), '--format', 'av', '--remux-video', 'mkv',
                   '--output', str(self.root / '%(title)s [%(id)s].%(ext)s'),
                   *[os.fsdecode(option) for option in options.split(b'\0') if option]]
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        prefix = bytearray()
        expected = b'YTDLP_POSTPROCESS|started|MediaPostprocessing\n'
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and process.poll() is None:
                if select.select([process.stdout], [], [], .02)[0]:
                    prefix.extend(os.read(process.stdout.fileno(), 65536))
                if ready.exists() and expected in prefix:
                    break
            reached, observed = ready.exists(), expected in prefix
        finally:
            # Release only the owned fixture barrier, including on a failing
            # assertion. The actual remux then runs and its status is collected.
            release.touch()
            try:
                tail, diagnostic = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)
                raise
        self.assertTrue(reached, 'real yt-dlp never requested its FFmpeg remux')
        self.assertTrue(observed, 'postprocess phase absent from stdout before real remux')
        self.assertEqual(process.returncode, 0, diagnostic)
        self.assertEqual((prefix + tail).count(expected), 1, 'phase is not emitted once at its real boundary')
        self.assertNotIn(b'YTDLP_POSTPROCESS|', diagnostic, 'raw stderr progress bypassed the closed filter')
        self.assertIn(b'[YTDLP_DIAGNOSTIC]', diagnostic, 'real postprocessor stderr was not exercised')
        self.assertTrue((self.root / 'fixture [probe].mkv').is_file())

    def test_real_unsupported_generic_and_http_reason_witnesses(self):
        import http.server
        import shutil
        import threading
        # The default suite also runs under the mock-signals PATH. Only the
        # real-tool entrypoint (or explicit focused invocation) admits engines.
        if not any(argument == 'YtdlpRealDiagnosticTests'
                   or argument.startswith('YtdlpRealDiagnosticTests.')
                   for argument in sys.argv[1:]):
            self.skipTest('real witnesses require explicit YtdlpRealDiagnosticTests selection')
        executable = shutil.which('yt-dlp')
        self.assertIsNotNone(executable, 'real qualification requires yt-dlp')

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith('/http-reason'):
                    self.send_response(403, 'PRIVATE_HTTP_REASON')
                    self.end_headers()
                elif self.path == '/PRIVATE_GENERIC_ID':
                    # A valid empty manifest reaches Generic's no-format error
                    # with its explicit ID on every supported yt-dlp version.
                    # HTTP errors do not consistently include that ID.
                    data = (b'<?xml version="1.0"?>'
                            b'<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">'
                            b'<Period/></MPD>')
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/dash+xml')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    data = b'<html><title>synthetic fixture</title><body>No media</body></html>'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = 'http://127.0.0.1:' + str(server.server_port)
            cases = [
                ('unsupported-url', base + '/unsupported?key=PRIVATE_QUERY_ONE&auth=PRIVATE_QUERY_TWO',
                 (b'PRIVATE_QUERY_ONE', b'PRIVATE_QUERY_TWO'), b'[YTDLP_UNSUPPORTED_URL]'),
                ('generic-id', base + '/PRIVATE_GENERIC_ID', (b'PRIVATE_GENERIC_ID',), b'[YTDLP_DIAGNOSTIC]'),
                ('http-reason', base + '/http-reason', (b'PRIVATE_HTTP_REASON',), b'[YTDLP_HTTP_ERROR]'),
            ]
            for witness, url, sentinels, category in cases:
                with self.subTest(witness=witness):
                    batch = self.root / 'urls'
                    batch.write_text(url + '\n')
                    command = [executable, '--ignore-config', '--no-plugin-dirs', '--no-cache-dir', '--proxy', '',
                               '--no-progress', '--skip-download', '--socket-timeout', '3',
                               '--retries', '0', '--extractor-retries', '0', '--batch-file', str(batch)]
                    raw = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
                    self.assertNotEqual(raw.returncode, 0, 'real witness unexpectedly succeeded')
                    for sentinel in sentinels:
                        self.assertTrue(sentinel in raw.stderr, 'real witness did not reproduce the leak')
                    if sentinels == (b'PRIVATE_GENERIC_ID',):
                        # This exact prefix proves the ID is outside any URL;
                        # a separate bug-report/help URL may follow the message.
                        self.assertTrue(b'[generic] PRIVATE_GENERIC_ID: No video formats found!' in raw.stderr,
                                        'Generic witness lacks a schemeless private ID')
                    result = subprocess.run(['bash', str(self.wrapper), *command], stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, timeout=15)
                    self.assertEqual(result.returncode, raw.returncode)
                    self.assertEqual(result.stdout, raw.stdout)
                    self.assertTrue(all(value not in result.stderr for value in sentinels),
                                    'real yt-dlp stderr disclosed private sentinel')
                    self.assertIn(category, result.stderr)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(5)


if __name__ == '__main__':
    unittest.main()
