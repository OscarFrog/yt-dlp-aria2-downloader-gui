# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-observer.py: private Rust observer client."""

import argparse
import atexit
import errno
import importlib.util
import json
import os
from functools import cache
from pathlib import Path
import re
import subprocess
import sys
import threading
import time


_OPERATIONS = frozenset(('stat', 'status', 'group_open', 'thread_open', 'pidfd_open', 'fdinfo',
                         'poll', 'inventory', 'environ_open', 'environ_read', 'cmdline_open',
                         'cmdline_read', 'close', 'identity', 'protocol', 'clock', 'limit'))
_PHASES = frozenset(('discovery', 'attribution', 'sample', 'query', 'protocol'))
_SOURCES = frozenset(('unknown', 'marker', 'known_identity', 'descendant', 'registered'))
_COORDINATES = ('pid', 'tid', 'start', 'task_start')
_DETAILS = {'schema', 'complete', 'errno', 'operation', 'phase', 'source'}


def _number(value, lower=0):
    return type(value) is int and lower <= value <= (1 << 64) - 1


def copy_diagnostic(packet):
    if (not isinstance(packet, dict) or set(packet) != _DETAILS
            or type(packet['schema']) is not int or packet['schema'] != 3
            or type(packet['complete']) is not bool or not _number(packet['errno'], 1)
            or packet['errno'] > 4095 or packet['operation'] not in _OPERATIONS
            or packet['phase'] not in _PHASES or packet['source'] not in _SOURCES):
        raise ValueError('Invalid native observation diagnostic')
    return dict(packet)


def copy_identity_diagnostic(packet):
    if set(packet) != _DETAILS.union(_COORDINATES) or not all(_number(packet[k]) for k in _COORDINATES):
        raise ValueError('Invalid private observation coordinates')
    return dict(copy_diagnostic({k: packet[k] for k in _DETAILS}), **{k: packet[k] for k in _COORDINATES})


def copy_identity_export(packet):
    if set(packet) != _DETAILS.union(('group', 'task')):
        raise ValueError('Invalid public observation coordinates')
    result = copy_diagnostic({k: packet[k] for k in _DETAILS})
    for name, prefix in (('group', 'g'), ('task', 't')):
        alias = packet[name]
        if alias is not None and not (isinstance(alias, str) and re.fullmatch(prefix + '[1-9][0-9]{0,3}', alias)):
            raise ValueError('Invalid public observation alias')
        result[name] = alias
    return result


class IdentityProjection:
    """Allocate bounded local labels. A numeric TID alone cannot identify a thread."""
    def __init__(self):
        self.groups = {}
        self.threads = {}

    @staticmethod
    def _alias(aliases, prefix, key):
        if key not in aliases:
            if len(aliases) >= 1024:
                raise ValueError('Too many diagnostic aliases')
            aliases[key] = prefix + str(len(aliases) + 1)
        return aliases[key]

    def project(self, packet):
        packet = copy_identity_diagnostic(packet)
        group, task = None, None
        if packet['pid'] and packet['start']:
            key = (packet['pid'], packet['start'])
            group = self._alias(self.groups, 'g', key)
            if packet['tid'] and packet['task_start']:
                task = self._alias(self.threads, 't', (*key, packet['tid'], packet['task_start']))
        return dict({k: packet[k] for k in _DETAILS}, group=group, task=task)


class ObservationError(OSError):
    """One native refusal; its text contains no fixture data."""
    def __init__(self, number, detail=None):
        super().__init__(number, 'Incomplete process observation')
        self.detail = detail


@cache
def observer_binary():
    spec = importlib.util.spec_from_file_location('qualification_observer_build',
                                                  Path(__file__).resolve().with_name('observer_build.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.observer_binary()


class _Connection:
    """One persistent child, private pipes, serialized requests and deterministic shutdown."""
    def __init__(self):
        self.process = subprocess.Popen([str(observer_binary())], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env={'LC_ALL': 'C'}, close_fds=True)
        self.lock = threading.Lock()

    @staticmethod
    def _reply(raw):
        try:
            if not raw.endswith(b'\n'):
                raise ValueError('Incomplete native response')
            reply = json.loads(raw)
            if isinstance(reply, dict) and set(reply) == {'ok'}:
                return reply['ok']
            if not isinstance(reply, dict) or set(reply) != {'error'}:
                raise ValueError('Invalid native response')
            detail = copy_identity_diagnostic(dict(reply['error'], schema=3, complete=True))
        except (ValueError, TypeError, KeyError, UnicodeError):
            raise ObservationError(errno.EIO) from None
        raise ObservationError(detail['errno'], detail)

    def request(self, command):
        with self.lock:
            try:
                self.process.stdin.write(command.encode('ascii') + b'\n')
                self.process.stdin.flush()
                raw = self.process.stdout.readline(8 * 1024 * 1024)
            except (ValueError, OSError) as error:
                raise ObservationError(getattr(error, 'errno', None) or errno.EIO) from None
            return self._reply(raw)

    def close(self):
        # QUIT reports checked close errors before reaping only our own child.
        with self.lock:
            if self.process.returncode is not None and self.process.stdin.closed:
                return
            try:
                output, _ = self.process.communicate(input=b'QUIT\n', timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.communicate()
                raise ObservationError(errno.ETIMEDOUT) from None
            if self.process.returncode or self._reply(output) is not True:
                raise ObservationError(errno.EIO)


_utilities = None
_utilities_lock = threading.Lock()


def _utility():
    global _utilities
    with _utilities_lock:
        if _utilities is None:
            _utilities = _Connection()
        return _utilities


def utility_pid():
    return _utilities.process.pid if _utilities is not None and _utilities.process.poll() is None else None


def close_utilities():
    global _utilities
    with _utilities_lock:
        if _utilities is not None:
            instance, _utilities = _utilities, None
            instance.close()


atexit.register(close_utilities)


def _id(value):
    if not _number(value, 1):
        raise ValueError('Invalid process identity')
    return str(value)


def _stat(channel, pid, tid=None):
    return channel.request('STAT ' + _id(pid) + ('' if tid is None else ' ' + _id(tid)))


def current_process(pid):
    return _stat(_utility(), pid)


def process_row(path):
    match = re.fullmatch(r'/proc/([1-9][0-9]*)(?:/task/([1-9][0-9]*))?/stat', str(path))
    if not match:
        raise ValueError('Unsupported process identity path')
    row = _stat(_utility(), int(match[1]), int(match[2]) if match[2] else None)
    if row is None:
        raise FileNotFoundError(errno.ENOENT, 'Process identity absent')
    return row


def same_process(pid, row):
    current = current_process(pid)
    return current is not None and current['start'] == row['start']


def snapshot():
    return {int(pid): row for pid, row in _utility().request('SNAPSHOT').items()}


def threads_are_quiescent(pid, row):
    return _utility().request('QUIESCENT ' + _id(pid) + ' ' + _id(row['start']))


def token_process_is_live(pid, marker):
    return _utility().request('TOKEN ' + _id(pid) + ' ' + marker.hex())


class Observer:
    """One qualification session. The native observer owns all attribution and kernel state."""
    def __init__(self, token, *, marker_name='YTDLP_QUALIFICATION_TOKEN', allow_external=True,
                 diagnostics=False, identity_diagnostics=False):
        if identity_diagnostics and not diagnostics:
            raise ValueError('Identity diagnostics require observer diagnostics')
        self.marker = marker_name.encode() + b'=' + token.encode()
        self.known = set()
        self.external = set()
        self.leaks = set()
        self.error = None
        self.diagnostics_enabled = diagnostics
        self.identity_diagnostics_enabled = identity_diagnostics
        self.diagnostics_incomplete = False
        self._connection = None
        self._closed = False
        self._allow_external = bool(allow_external)
        self._lock = threading.RLock()

    def _channel(self):
        if self._closed:
            raise ObservationError(errno.EBADF)
        if self._connection is None:
            channel = self._connection = _Connection()
            try:
                channel.request('INIT ' + self.marker.hex() + ' ' + str(int(self._allow_external)))
            except BaseException as initial:
                self._connection = None
                try:
                    channel.close()
                except OSError as secondary:
                    raise initial from secondary
                raise
        return self._connection

    def stat(self, pid):
        with self._lock:
            return _stat(self._channel(), pid)

    def register_root(self, pid, start):
        with self._lock:
            return self._channel().request('ROOT ' + _id(pid) + ' ' + _id(start))

    def quiescent(self, pid, start):
        with self._lock:
            return self._channel().request('QUIESCENT ' + _id(pid) + ' ' + _id(start))

    def _admit(self, verb, pid, start):
        with self._lock:
            if self.error is not None:
                raise self.error
            try:
                return self._channel().request(verb + ' ' + _id(pid) + ' ' + _id(start))
            except OSError as error:
                self.error = error
                raise

    def register(self, pid, start):
        """Authenticate the launch marker at a private fixture barrier."""
        return self._admit('REGISTER', pid, start)

    def claim(self, pid):
        row = self.stat(pid)
        if row is None or not self.register(pid, row['start']):
            raise ObservationError(errno.ESRCH)

    def child(self, process):
        """The owner retains its unreaped Popen while Rust authenticates the parent edge."""
        row = self.stat(process.pid)
        if process.returncode is not None or row is None or not self._admit('CHILD', process.pid, row['start']):
            raise ObservationError(errno.ESRCH)

    def use_leaf(self, label):
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", label):
            raise ObservationError(errno.EINVAL)
        mounts = {}
        for line in Path('/proc/self/mountinfo').read_text().splitlines():
            record, filesystem = line.split(' - ', 1)
            if filesystem.split()[0] == 'cgroup2':
                fields = record.split()
                mounts[fields[4]] = (fields[2], Path(fields[3]), fields[5].split(','))
        root = '/qualification/trials/' + label
        members, events = mounts.get(root + '/members'), mounts.get(root + '/events')
        if (not members or not events or members[0] != events[0]
                or members[1].parent != events[1].parent or members[1].parent.name != label
                or members[1].name != 'cgroup.procs' or events[1].name != 'cgroup.events'
                or any('ro' not in item[2] for item in mounts.values())):
            raise ObservationError(errno.EINVAL)
        with self._lock:
            self._channel().request('LEAF ' + label)


    def sample(self):
        with self._lock:
            if self.error is not None:
                raise self.error
            try:
                state = self._channel().request('SAMPLE')
                self.known = {tuple(identity) for identity in state.pop('known')}
                self.external = {tuple(identity) for identity in state.pop('external')}
                self.leaks = {tuple(identity) for identity in state['url_in_argv']}
                state['url_in_argv'] = sorted(self.leaks)
                return state
            except OSError as error:
                self.error = error
                if self._connection is not None and getattr(error, 'detail', None) is not None:
                    # A failed sample supplies no live or privacy verdict. Retain
                    # only identities the native session authenticated before it failed.
                    try:
                        identities = self._connection.request('KNOWN')
                        self.known = {tuple(identity) for identity in identities}
                    except (OSError, ValueError, TypeError):
                        error.add_note('Native authenticated identity inventory unavailable')
                raise

    def diagnostic_failure(self, error):
        if self.diagnostics_enabled and error is self.error and getattr(error, 'detail', None) is not None:
            return copy_diagnostic({k: error.detail[k] for k in _DETAILS})
        self.diagnostics_incomplete = True
        return dict(schema=3, complete=False, operation='protocol', phase='protocol',
                    errno=(error.errno if isinstance(error, OSError) and _number(error.errno, 1) else errno.EIO),
                    source='unknown')

    def identity_failure(self, error):
        if self.identity_diagnostics_enabled and error is self.error and getattr(error, 'detail', None) is not None:
            return copy_identity_diagnostic(error.detail)
        return dict(self.diagnostic_failure(error), pid=0, tid=0, start=0, task_start=0)

    def close(self):
        if not self._lock.acquire(timeout=3):
            # A stuck native read must not deadlock Watch cleanup after its join
            # deadline. Terminating this privately owned helper invalidates the
            # sample; it grants no authority over an application process.
            channel = self._connection
            if channel is not None:
                channel.process.kill()
            if not self._lock.acquire(timeout=3):
                raise ObservationError(errno.ETIMEDOUT)
        try:
            self._closed = True
            if self._connection is not None:
                channel, self._connection = self._connection, None
                try:
                    channel.close()
                except OSError as secondary:
                    if self.error is not None:
                        raise self.error from secondary
                    raise
        finally:
            self._lock.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('evidence', type=Path)
    parser.add_argument('stop', type=Path)
    parser.add_argument('session_pid', type=Path)
    parser.add_argument('viewer_pid', type=Path)
    args = parser.parse_args()
    token = sys.stdin.buffer.readline(256)
    if not token.endswith(b'\n') or not token.strip():
        parser.error('Missing private fixture marker')
    observer = Observer(token[:-1].decode('ascii'))
    try:
        with (args.evidence / 'process-topology.jsonl').open('a') as log:
            admitted = set()
            while True:
                stopping = args.stop.exists()
                for path in (args.session_pid, args.viewer_pid):
                    if path not in admitted and path.exists():
                        text = path.read_text().strip()
                        if text:
                            observer.claim(int(text))
                            admitted.add(path)
                if args.session_pid not in admitted:
                    if stopping:
                        raise ObservationError(errno.ESRCH)
                    time.sleep(0.05)
                    continue
                state = observer.sample()
                log.write(json.dumps(state) + '\n')
                log.flush()
                temporary = args.evidence / '.processes-current.tmp'
                temporary.write_text(json.dumps(state))
                os.replace(temporary, args.evidence / 'processes-current.json')
                if stopping:
                    return
                time.sleep(0.05)
    finally:
        observer.close()


if __name__ == '__main__':
    main()
