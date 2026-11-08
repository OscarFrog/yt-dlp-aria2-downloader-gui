# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/hls-cancellation-witness.py.

Hold one real fragment retry and independently verify its owned consumers.
The sequential fixture controller subreaps, but never harvests before verdict.
No argument or environment contents are retained in evidence or diagnostics.
"""

import ctypes
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import struct
import time

spec = importlib.util.spec_from_file_location(
    'hls_process_observer', Path(__file__).with_name('process-observer.py'))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


def identity(pid):
    path = Path(f'/proc/{pid}/stat')
    try:
        return observer.process_row(path)
    except FileNotFoundError:
        return None
    except ProcessLookupError:
        # procfs can report ESRCH while a stat file opened for reading races
        # with task exit. Reopen once: only a now-missing path confirms
        # disappearance; a repeated or different read error remains unknown.
        try:
            return observer.process_row(path)
        except FileNotFoundError:
            return None


def direct_children():
    children = set()
    for task in Path('/proc/self/task').iterdir():
        children.update(map(int, (task / 'children').read_text().split()))
    return children


class CancellationWitness:
    """One engine invocation; no concurrent launches share this controller."""

    def __init__(self, root, fragment, executable, server_pid, *, token=None, result=None, output=None):
        self.root = Path(root)
        self.executable = os.fsencode(executable)
        self.result = Path(result) if result is not None else self.root / 'result'
        self.output = Path(output) if output is not None else self.root / 'output'
        self.token = token or os.urandom(24).hex()
        self.marker = b'YTDLP_QUALIFICATION_TOKEN=' + self.token.encode()
        self.records = {}
        self.descriptors = {}
        self.engine = None
        self.consumer = None
        self.signalled = False
        self.completed = False
        self.request_time = None
        self.connection = None
        self.frame = bytearray()
        self.server_pid = server_pid
        server = identity(server_pid)
        if server is None:
            raise AssertionError('HLS fixture server identity is unavailable')
        self.server_start = server['start']
        if direct_children():
            raise AssertionError('HLS witness requires an idle sequential controller')
        self.libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        if self.libc.prctl(37, ctypes.byref(previous), 0, 0, 0):
            raise OSError('HLS witness cannot inspect subreaper state')
        self.previous_subreaper = previous.value
        if self.libc.prctl(36, 1, 0, 0, 0):
            raise OSError('HLS witness cannot establish subreaping')
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.address = self.root / 'hls-cancel.sock'
        self.configuration = self.root / 'hls-cancel.json'
        bound = False
        try:
            self.listener.bind(str(self.address))
            bound = True
            self.address.chmod(0o600)
            self.listener.listen(1)
            self.listener.setblocking(False)
            descriptor = os.open(self.configuration, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                json.dump({'fragment': fragment, 'socket': str(self.address)}, stream)
        except BaseException:
            self.listener.close()
            if bound:
                self.address.unlink()
            if not self.previous_subreaper:
                self.libc.prctl(36, 0, 0, 0, 0)
            raise
        self.started = time.monotonic_ns()

    def environment(self, environment):
        return dict(environment, YTDLP_QUALIFICATION_TOKEN=self.token)

    def register(self, process):
        row = identity(process.pid)
        if row is None or row['parent'] != os.getpid():
            raise AssertionError('HLS engine launch identity is unavailable')
        self.engine = process.pid, row['start']
        self.sample()

    def remember(self, pid, row):
        key = pid, row['start']
        if key not in self.records:
            if len(self.records) >= 1024:
                raise AssertionError('HLS process inventory exceeds its bound')
            try:
                descriptor = os.pidfd_open(pid)
            except ProcessLookupError:
                if identity(pid) is None:
                    return
                raise AssertionError('HLS process identity changed during acquisition') from None
            current = identity(pid)
            if current is None:
                os.close(descriptor)
                return
            if current['start'] != row['start']:
                os.close(descriptor)
                raise AssertionError('HLS process identity changed during acquisition')
            self.descriptors[key] = descriptor
        self.records[key] = dict(row)

    def sample(self):
        rows = observer.snapshot()
        # A detached worker that outlives its parent is adopted here, even if
        # its marker is unreadable or was removed before our first sample.
        # The controller launches only this engine, never unrelated children.
        selected = set()
        for pid in direct_children():
            row = identity(pid)
            if row is None:
                continue
            if row['parent'] != os.getpid():
                raise AssertionError('HLS adopted-child identity is inconsistent')
            rows[pid] = row
            selected.add(pid)
        selected.update(pid for pid, row in rows.items()
                        if (pid, row['start']) in self.records)
        changed = True
        while changed:
            children = {pid for pid, row in rows.items() if row['parent'] in selected}
            changed = bool(children - selected)
            selected.update(children)
        live = {}
        for pid in selected:
            row = rows[pid]
            self.remember(pid, row)
            current = identity(pid)
            if current is None:
                continue
            if current['start'] != row['start']:
                raise AssertionError('HLS attributed process identity is uncertain')
            if not observer.threads_are_quiescent(pid, current):
                live[pid] = current
        return live

    def ready(self):
        if self.connection is None:
            try:
                connection, _ = self.listener.accept()
            except BlockingIOError:
                return False
            peer_pid, _, _ = struct.unpack('3i', connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i')))
            current = identity(peer_pid)
            if (peer_pid != self.server_pid or current is None
                    or current['start'] != self.server_start):
                connection.close()
                raise AssertionError('HLS retry barrier has an unexpected peer')
            connection.setblocking(False)
            self.connection = connection
        if self.request_time is None:
            try:
                data = self.connection.recv(64)
            except BlockingIOError:
                return False
            self.frame.extend(data)
            if not data or len(self.frame) > 32:
                raise AssertionError('HLS retry barrier frame is incomplete')
            if not self.frame.endswith(b'\n'):
                return False
            if not self.frame.startswith(b'RETRY ') or not self.frame[6:-1].isdigit():
                raise AssertionError('HLS retry barrier frame is invalid')
            self.request_time = int(self.frame[6:-1])
            if not self.started <= self.request_time <= time.monotonic_ns():
                raise AssertionError('HLS retry barrier chronology is invalid')
        if self.connection in select.select([self.connection], [], [], 0)[0]:
            raise AssertionError('HLS retry barrier closed before cancellation')
        return True

    def before_signal(self, process):
        if not self.ready():
            raise AssertionError('HLS cancellation preceded the active retry')
        live = self.sample()
        engine = live.get(process.pid)
        if engine is None or (process.pid, engine['start']) != self.engine:
            raise AssertionError('HLS engine identity changed before cancellation')
        consumers = []
        for pid, row in live.items():
            # Ownership comes from ancestry/adoption, never a marker or UID.
            try:
                with Path(f'/proc/{pid}/cmdline').open('rb') as stream:
                    arguments = stream.read(65537)
            except (FileNotFoundError, ProcessLookupError):
                if identity(pid) is None:
                    continue
                raise AssertionError('HLS attributed command remains unreadable') from None
            if len(arguments) > 65536:
                raise AssertionError('HLS command observation exceeds its bound')
            arguments = arguments.split(b'\0')
            if self.executable not in arguments[:3]:
                continue
            if b'--load-info-json' not in arguments or b'--dump-single-json' in arguments:
                continue
            with Path(f'/proc/{pid}/environ').open('rb') as stream:
                environment = stream.read(65537)
            if len(environment) > 65536:
                raise AssertionError('HLS fixture identity observation exceeds its bound')
            environment = environment.split(b'\0')
            if self.marker not in environment:
                raise AssertionError('HLS native consumer lost its fixture identity')
            current = identity(pid)
            if current is None or any(current[key] != row[key]
                                      for key in ('start', 'parent', 'group', 'session')):
                raise AssertionError('HLS native consumer identity is inconsistent')
            leader = live.get(row['session'])
            if (leader is None or row['group'] != row['session']
                    or leader['group'] != row['session'] or leader['session'] != row['session']):
                raise AssertionError('HLS native consumer has no live supervised session')
            chain, parent = set(), pid
            while parent != process.pid:
                if parent in chain or parent not in live:
                    raise AssertionError('HLS native consumer has no live engine ancestry')
                current = identity(parent)
                if current is None or any(current[key] != live[parent][key]
                                          for key in ('start', 'parent', 'group', 'session')):
                    raise AssertionError('HLS supervised ancestry changed before cancellation')
                chain.add(parent)
                parent = live[parent]['parent']
            consumers.append((pid, row['start']))
        if len(consumers) != 1:
            raise AssertionError('HLS cancellation requires one active native consumer')
        self.consumer = consumers[0]
        self.signalled = True
        return [(pid, str(row['start'])) for pid, row in live.items() if pid != process.pid]

    def quiescent(self):
        # Reparenting is complete when a parent exits; the second full sample
        # must also find every adopted descendant stopped before fixture release.
        previous = None
        for _ in range(2):
            if self.sample():
                return False
            current = set(self.records)
            if previous is not None and current != previous:
                return False
            previous = current
        for descriptor in self.descriptors.values():
            poller = select.poll()
            poller.register(descriptor, select.POLLIN)
            events = poller.poll(0)
            if (not events or any(not mask & select.POLLIN
                                  or mask & (select.POLLERR | select.POLLNVAL)
                                  for _, mask in events)):
                return False
        return True

    def verify_completed(self, process, stdout, stderr):
        if not self.signalled or self.consumer is None:
            raise AssertionError('HLS engine ended before an observed retry cancellation')
        if process.returncode != 143:
            raise AssertionError('HLS cancellation did not preserve status 143')
        if not self.quiescent():
            raise AssertionError('HLS cancellation left an active or uncertain consumer')
        if self.result.exists() or list(self.output.glob('*.mkv')):
            raise AssertionError('HLS cancellation published a successful result')
        if b'Download completed successfully.' in stdout + stderr:
            raise AssertionError('HLS cancellation reported a successful download')
        self.completed = True

    def restore_fragment(self, saved, missing):
        if self.completed:
            Path(saved).rename(missing)

    def close(self):
        # EOF releases the fixture server even on failure. Media restoration
        # and preservation removal remain forbidden until quiescence succeeds.
        if self.connection is not None:
            self.connection.close()
        self.listener.close()
        if self.completed:
            for (pid, _), descriptor in self.descriptors.items():
                if self.engine is not None and pid == self.engine[0]:
                    continue
                try:
                    os.waitid(os.P_PIDFD, descriptor, os.WEXITED | os.WNOHANG)
                except ChildProcessError:
                    pass
            self.configuration.unlink()
            self.address.unlink()
            if not self.previous_subreaper and self.libc.prctl(36, 0, 0, 0, 0):
                raise OSError('HLS witness cannot restore subreaper state')
        for descriptor in self.descriptors.values():
            os.close(descriptor)
