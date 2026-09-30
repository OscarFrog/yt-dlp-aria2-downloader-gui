# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-supervision-integration.py.

Independent process observation and deterministic session/timeout regressions.
Rescue happens only after assertions; test subreaping is not application reaping.
"""

import ctypes
import importlib.util
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
            for pid, row in observer.snapshot().items():
                if (row['parent'] == os.getpid() and row['state'] == 'Z'
                        and pid not in {p.pid for p in self.processes}):
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
                real_glob = Path.glob
                inventories = 0
                late_child = None

                def enumerate_then_fork(path, pattern):
                    nonlocal inventories, late_child
                    snapshot = list(real_glob(path, pattern))
                    if path != Path('/proc') or pattern != '[0-9]*/stat':
                        return iter(snapshot)
                    inventories += 1
                    if inventories == 1:
                        self.assertIn(Path(f'/proc/{orphan}/stat'), snapshot)
                        # Only scheduling is controlled: freeze real directory
                        # entries, fork, then let production read real stat data.
                        os.write(trigger_write, b'F')
                        late_child = record(report_read, 'B')
                        self.assertNotIn(Path(f'/proc/{late_child}/stat'), snapshot)
                        deadline = time.monotonic() + 3
                        while fields(orphan)[0] != 'Z':
                            self.assertLess(time.monotonic(), deadline, 'orphan did not exit')
                            time.sleep(.005)
                    return iter(snapshot)

                with mock.patch.object(Path, 'glob', enumerate_then_fork), \
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
        sentinel = engine[sentinel_start:sentinel_end] + 'exit "${command_status}"\n'
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
        engine_probe = engine[engine.index('download_group_has_live_member() {'):
                              engine.index('download_group_is_absent() {')]
        engine_wait = engine[engine.index('wait_for_download_exit() {'):
                             engine.index('stop_download_worker() {')]
        gui_probe = gui[gui.index('worker_group_has_live_member() {'):
                        gui.index('worker_group_is_absent() {')]
        gui_wait = gui[gui.index('worker_group_may_be_alive() {'):
                       gui.index('process_is_running() {', gui.index('worker_group_may_be_alive() {'))]
        sentinel_start = engine.index('            # Stay alive as the authenticated session leader')
        sentinel = engine[engine.index('            while true; do', sentinel_start):
                          engine.index('            exit "${command_status}"', sentinel_start)]
        prologue = r'''set -euo pipefail
FIXTURE_ROOT=$1
mkdir -p "$FIXTURE_ROOT/900000001"
fixture_session=515151
[[ $2 != sentinel ]] || fixture_session=$$
write_state() {
    printf '%s (fixture) %s 0 %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345\n' \
        "$1" "$2" "$fixture_session" "$fixture_session" >"$FIXTURE_ROOT/$1/stat"
}
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
                    code = code.replace('/proc/[1-9]*/stat', '"${FIXTURE_ROOT}"/[1-9]*/stat')
                    code = code.replace('/proc/[0-9]*', '"${FIXTURE_ROOT}"/[0-9]*')
                    setup = prologue
                    if label == 'sentinel':
                        # A live modeled consumer must retain the sentinel.
                        # Stop this deterministic observation at its first wait.
                        setup += "sleep() { printf 'held\\n'; exit 64; }\n"
                    directory = self.root / (label + str(second_inventory))
                    directory.mkdir()
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

    def escalation_case(self, code, filename, *, threaded=False):
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
        real_signal = signal.pidfd_send_signal
        deliveries = []
        reads = 0
        late_child = None

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
            if threaded:
                os.write(trigger_write, b'F')
                late_child = record()
                self.assertNotEqual(thread_id, process.pid)
                self.assertEqual(real_read(main_children).strip(), '')
                thread_children = Path(f'/proc/{process.pid}/task/{thread_id}/children')
                self.assertIn(str(late_child), real_read(thread_children).split())

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
                nonlocal reads, late_child
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

            with mock.patch.object(signal, 'pidfd_send_signal', deliver), \
                    mock.patch.object(Path, 'read_text', read_then_release), \
                    mock.patch.object(sys, 'argv', ['probe', str(process.pid),
                                                   identity[19], identity[3]]):
                try:
                    exec(compile(code, filename, 'exec'), {})
                except SystemExit as result:
                    self.assertEqual(result.code, 0)

            if late_child is not None:
                witness = fields(late_child)
                self.assertNotIn(witness[0], ('Z', 'X'))
                self.assertEqual(int(witness[3]), late_child, 'child must own its private SID')
                inherited = os.stat(f'/proc/{late_child}/fd/{release_read}')
                held = os.fstat(release_write)
                self.assertEqual((inherited.st_dev, inherited.st_ino), (held.st_dev, held.st_ino))
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
            end = code.index('        children = frozen_children(pid)\n', start)
            mutant = code[:start] + code[end:]
            state_guard = "            if fields[0] not in ('T', 't'):\n                raise ValueError('thread is not stopped')\n"
            self.assertEqual(mutant.count(state_guard), 1)
            mutant = mutant.replace(state_guard, '', 1)
            with self.subTest(target=filename, freeze=False):
                with self.assertRaisesRegex(self.failureException, 'startup child escape'):
                    self.escalation_case(mutant, filename)

    def test_escalation_preserves_worker_thread_child_owner(self):
        for filename, code in self.escalation_sources():
            with self.subTest(target=filename, all_threads=True):
                self.escalation_case(code, filename, threaded=True)
            inventory = "for task in Path(f'/proc/{pid}/task').iterdir():"
            self.assertEqual(code.count(inventory), 1)
            mutant = code.replace(inventory, "for task in [Path(f'/proc/{pid}/task/{pid}')]:", 1)
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
kill() {
    builtin kill "$@" || return "$?"
    if [[ $1 == -CONT && ${3:-} == "${WORKER_PGID}" ]]; then
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
        printf '%s' "$consumer_pid" >"${OUTPUT_LOCK_ROOT}/blocked-escalation"
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
