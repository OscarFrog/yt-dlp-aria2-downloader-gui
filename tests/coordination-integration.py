# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/coordination-integration.py.

Exercise cross-registry reservation compatibility, admission and cleanup with
real Bash actors, flock descriptors and deterministic checkpoint barriers.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
HELPER = PROJECT / 'private-aria2-plan.py'

# Only relocate the two historical parents and inject named filesystem faults.
# Production candidate selection, validation, lock acquisition and checkpoints
# remain intact. A healthy runtime root keeps metadata out of the fault's scope.
HELPER_SHIM = '''import errno, importlib.util, json, os, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('production', sys.argv.pop(1))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = Path(os.environ['COORDINATION_FIXTURE'])
real_candidates = m.private_root_candidates
def candidates(*, disk, no_runtime):
    mapping = {'/tmp': root / 'primary', '/var/tmp': root / 'fallback'}
    return [(mapping.get(str(path), path), runtime)
            for path, runtime in real_candidates(disk=disk, no_runtime=no_runtime)]
m.private_root_candidates = candidates
real_write = m.os.write
def write(descriptor, data):
    target = Path(os.readlink(f'/proc/self/fd/{descriptor}'))
    failing = os.environ.get('COORDINATION_PROBE_FAILURE', '')
    if (failing and target.name.startswith('.probe-')
            and target.is_relative_to(root / failing)):
        print('INJECTED_PROBE_ENOSPC', file=sys.stderr, flush=True)
        raise OSError(errno.ENOSPC, 'fixture private-root probe is full')
    return real_write(descriptor, data)
m.os.write = write
real_replace = m.replace_private_json
activated = 0
def replace(path, payload):
    global activated
    checkpoint = str(path).endswith('.resume.json')
    saving = checkpoint and '--action' in sys.argv and sys.argv[sys.argv.index('--action') + 1] == 'save'
    if saving and os.environ.get('COORDINATION_SAVE_FAILURE'):
        with (root / 'save-attempts.jsonl').open('a') as log:
            log.write(json.dumps(str(path)) + '\\n')
        if path.is_relative_to(root / os.environ['COORDINATION_SAVE_FAILURE']):
            raise OSError(errno.EIO, 'fixture checkpoint write failed')
    result = real_replace(path, payload)
    if checkpoint and payload.get('active') is True:
        activated += 1
        if activated == 1 and os.environ.get('COORDINATION_ACTIVATION_BARRIER') == '1':
            print(f'ACTIVATED|{os.getpid()}', flush=True)
            assert sys.stdin.readline().strip() == 'release'
    return result
m.replace_private_json = replace
raise SystemExit(m.main())
'''

ACTOR = '''#!/usr/bin/env bash
source "${COORDINATION_FIXTURE}/engine-functions.sh"
PRIVATE_ARIA2_HELPER="${COORDINATION_FIXTURE}/helper-wrapper.py"
OUTPUT_DIR=${COORDINATION_OUTPUT}
MODE=video
MACHINE_PROGRESS=false
YOUTUBE_HLS_FIREFOX=false
RESULT_FILE=''
URL='https://example.invalid/coordination-fixture'
YT_DLP_OPTIONS=()
trap cleanup EXIT
trap 'request_shutdown TERM 143' TERM
if [[ -n ${COORDINATION_STAT_FAILURE:-} ]]; then
    # Refuse only the identity stat for the selected lock and observation view.
    # All output-directory and private-storage observations remain real.
    stat() {
        local target='' kind='' view=''
        if [[ $# == 4 && $2 == '%d:%i:%u' && $3 == -- ]]; then
            target=$4
            case $1 in
                -Lc) view=opened; target=$(readlink -- "${target}") || return $? ;;
                -c) view=visible ;;
            esac
            if [[ ${target##*/} == resource-*.lock ]]; then
                kind=fine
            elif [[ ${target##*/} =~ ^[[:xdigit:]]{64}\\.lock$ ]]; then
                kind=historical
            fi
            if [[ -n ${kind} && ${COORDINATION_STAT_FAILURE} == "${kind}-${view}" ]]; then
                printf 'INJECTED_LOCK_STAT_FAILURE|%s\\n' "${COORDINATION_STAT_FAILURE}" >&2
                return 1
            fi
        fi
        command stat "$@"
    }
fi
if [[ ${COORDINATION_OLD_RESOLVER:-0} == 1 ]]; then
    # Model the previous one-registry protocol through its real allocator.
    # The actual production lock/admission/cleanup bodies are not replaced.
    resolve_coordination_roots() {
        resolve_lock_root RESOURCE_LOCK_ROOT false || return $?
        RESOURCE_LOCK_ROOTS=("${RESOURCE_LOCK_ROOT}")
        RESOURCE_REGISTRY_OPTIONS=()
    }
fi
prepare_output_directory
prepare_private_work_files
python3 -B - "${PRIVATE_ARIA2_PLAN}" "${OUTPUT_DIR}" "${COORDINATION_NAME}" <<'PY_PLAN'
import json, sys
from pathlib import Path
target, output, name = sys.argv[1:]
Path(target).write_text(json.dumps({'id': 'fixture-media', 'extractor_key': 'Generic',
    'requested_downloads': [{'filename': str(Path(output) / name), 'format_id': 'av',
    'ext': 'mp4', 'protocol': 'http', 'url': 'https://example.invalid/synthetic'}]}))
PY_PLAN
acquire_resource_reservations
printf 'ADMITTED|%s\\n' "${RESOURCE_STATE_FILE}"
IFS= read -r action
[[ ${action} == exit ]]
'''


class CoordinationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='coordination-integration-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in ('primary', 'fallback', 'output', 'runtime', 'home'):
            (self.root / name).mkdir(mode=0o700)
        self.output = self.root / 'output'
        self.alias = self.root / 'alias'
        self.alias.symlink_to(self.output, target_is_directory=True)
        leaf = f'yt-dlp-aria2-downloader-{os.geteuid()}'
        self.registries = [self.root / name / leaf for name in ('primary', 'fallback')]
        source = (PROJECT / 'download-video.sh').read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        (self.root / 'engine-functions.sh').write_text(source[:-len('main "$@"\n')])
        (self.root / 'helper.py').write_text(HELPER_SHIM)
        # Python starts the import shim with the real helper as its first arg;
        # the engine's public Python helper interface is otherwise unchanged.
        (self.root / 'helper-wrapper.py').write_text(
            'import os, sys\n'
            f'os.execv(sys.executable, [sys.executable, "-B", {str(self.root / "helper.py")!r}, '
            f'{str(HELPER)!r}, *sys.argv[1:]])\n')
        (self.root / 'actor.sh').write_text(ACTOR)
        self.env = dict(os.environ, COORDINATION_FIXTURE=str(self.root),
                        HOME=str(self.root / 'home'), XDG_RUNTIME_DIR=str(self.root / 'runtime'),
                        PYTHONDONTWRITEBYTECODE='1', YTDLP_ARIA2_SUPERVISED_SESSION='false')
        self.actors = []
        self.addCleanup(self.stop_actors)

    def stop_actors(self):
        for actor in self.actors:
            process = actor['process']
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()

    def launch(self, name='same-media.mp4', *, old=False, probe='', save='', barrier=False, alias=False, stat_failure=''):
        label = len(self.actors)
        diagnostic = self.root / f'actor-{label}.stderr'
        with diagnostic.open('wb') as stream:
            process = subprocess.Popen(['bash', str(self.root / 'actor.sh')],
                env=dict(self.env, COORDINATION_NAME=name,
                         COORDINATION_OUTPUT=str(self.alias / '.' if alias else self.output),
                         COORDINATION_OLD_RESOLVER=str(int(old)), COORDINATION_PROBE_FAILURE=probe,
                         COORDINATION_SAVE_FAILURE=save, COORDINATION_ACTIVATION_BARRIER=str(int(barrier)),
                         COORDINATION_STAT_FAILURE=stat_failure),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stream, start_new_session=True)
        actor = {'process': process, 'diagnostic': diagnostic, 'lines': []}
        self.actors.append(actor)
        return actor

    def line(self, actor, prefix):
        process = actor['process']
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(10), f'fixture barrier absent: {prefix}')
        line = process.stdout.readline().decode()
        actor['lines'].append(line)
        self.assertTrue(line.startswith(prefix), (line, actor['diagnostic'].read_text()))
        return line.rstrip('\n')

    def admitted(self, actor):
        path = Path(self.line(actor, 'ADMITTED|').split('|', 1)[1])
        actor['state_path'] = path
        actor['state'] = json.loads(path.read_text())
        return actor

    def finish(self, actor, expected=0, *, release=False):
        data = b'exit\n' if release else None
        output, _ = actor['process'].communicate(data, timeout=10)
        if expected:
            self.assertNotIn(b'ADMITTED|', output)
        self.assertEqual(actor['process'].returncode, expected, actor['diagnostic'].read_text())
        return output

    def checkpoints(self, family=None):
        rows = {}
        for registry in self.registries:
            for path in registry.glob('resources-*/*.resume.json'):
                record = json.loads(path.read_text())
                if family is None or record['family'] == family:
                    rows[path] = record
        return rows

    def history(self, index):
        registry = self.registries[index]
        registry.mkdir(mode=0o700, exist_ok=True)
        key = hashlib.sha256(os.fsencode(str(self.output)) + b'\0').hexdigest()
        return registry / (key + '.lock')

    def helper(self, *arguments, expected=0, save=''):
        result = subprocess.run([sys.executable, '-B', str(self.root / 'helper-wrapper.py'), *arguments],
                                env=dict(self.env, COORDINATION_SAVE_FAILURE=save),
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stderr.decode())
        return result

    def test_legacy_exclusive_locks_in_both_roots_and_launch_orders(self):
        for index in (0, 1):
            with self.subTest(root=index), self.history(index).open('a') as legacy:
                fcntl.flock(legacy, fcntl.LOCK_EX | fcntl.LOCK_NB)
                rejected = self.launch()
                self.finish(rejected, 75)
                self.assertIn('already using the destination', rejected['diagnostic'].read_text())
            owner = self.admitted(self.launch())
            for other in (0, 1):
                with self.history(other).open('a') as legacy:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(legacy, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.finish(owner, release=True)

    def test_probe_failure_never_splits_from_either_old_owner(self):
        for old_fallback in (False, True):
            with self.subTest(old_fallback=old_fallback):
                owner = self.admitted(self.launch(old=True, probe='primary' if old_fallback else ''))
                for failed_root in ('primary', 'fallback'):
                    rejected = self.launch(probe=failed_root, alias=True)
                    self.finish(rejected, 73)
                    self.assertIn('INJECTED_PROBE_ENOSPC', rejected['diagnostic'].read_text())
                    self.assertIsNone(owner['process'].poll())
                    records = self.checkpoints('same-media')
                    self.assertEqual(sum(row['active'] for row in records.values()), 1)
                self.finish(owner, release=True)

    def test_unreadable_lock_identities_refuse_before_admission_and_preserve_owner(self):
        owner = self.admitted(self.launch())
        before = {path: path.read_bytes() for path in self.checkpoints()}
        for kind in ('historical', 'fine'):
            for view in ('opened', 'visible'):
                fault = f'{kind}-{view}'
                with self.subTest(fault=fault):
                    rejected = self.launch(stat_failure=fault)
                    self.finish(rejected, 73)
                    self.assertIn(f'INJECTED_LOCK_STAT_FAILURE|{fault}', rejected['diagnostic'].read_text())
                    self.assertEqual({path: path.read_bytes() for path in self.checkpoints()}, before)
                    self.assertIsNone(owner['process'].poll())
                    for registry in self.registries:
                        with (registry / f"resource-{owner['state']['key']}.lock").open('a') as lock:
                            with self.assertRaises(BlockingIOError):
                                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.finish(self.launch(), 75)
        self.finish(owner, release=True)
        healthy = self.admitted(self.launch())
        self.finish(healthy, release=True)

    def test_checkpoint_aware_single_registry_clients_in_both_orders_and_roots(self):
        for old_fallback in (False, True):
            old_options = {'old': True, 'probe': 'primary' if old_fallback else ''}
            for old_first in (False, True):
                with self.subTest(old_fallback=old_fallback, old_first=old_first):
                    first_options = old_options if old_first else {}
                    second_options = {} if old_first else old_options
                    owner = self.admitted(self.launch(**first_options))
                    records = self.checkpoints('same-media')
                    active = {path for path, row in records.items() if row['active']}
                    self.assertEqual(len(active), 1 if old_first else 2)
                    if old_first:
                        self.assertTrue(next(iter(active)).is_relative_to(self.registries[int(old_fallback)]))
                    rejected = self.launch(alias=True, **second_options)
                    self.finish(rejected, 75)
                    self.assertIn('currently reserved', rejected['diagnostic'].read_text())
                    independent = self.admitted(self.launch('independent.mp4', **second_options))
                    self.assertIsNone(owner['process'].poll())
                    self.finish(independent, release=True)
                    self.assertIsNone(owner['process'].poll())
                    self.finish(owner, release=True)

    def test_primary_recovers_while_old_fallback_owner_is_alive(self):
        owner = self.admitted(self.launch(old=True, probe='primary'))
        self.assertTrue(any(path.is_relative_to(self.registries[1]) for path in self.checkpoints()))
        rejected = self.launch(alias=True)
        self.finish(rejected, 75)
        self.assertIn('currently reserved', rejected['diagnostic'].read_text())
        self.assertIsNone(owner['process'].poll())
        self.finish(owner, release=True)
        healthy = self.admitted(self.launch())
        self.assertEqual(len(self.checkpoints()), 2)
        self.finish(healthy, release=True)

    def test_independent_siblings_coexist_with_all_locks_retained(self):
        left = self.admitted(self.launch('family.a.mp4'))
        right = self.admitted(self.launch('family.b.mp4', alias=True))
        self.finish(self.launch('family.mp4'), 75)
        for actor in (left, right):
            records = self.checkpoints(actor['state']['family'])
            self.assertEqual(len(records), 2)
            self.assertEqual({row['transaction'] for row in records.values()}, {actor['state']['transaction']})
            self.assertTrue(all(row['active'] for row in records.values()))
            for registry in self.registries:
                with (registry / f"resource-{actor['state']['key']}.lock").open('a') as lock:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.finish(left, release=True)
        self.assertIsNone(right['process'].poll())
        self.finish(right, release=True)

    def test_active_fallback_checkpoint_survives_crash_and_refuses_admission(self):
        owner = self.admitted(self.launch(old=True, probe='primary'))
        before = {path: path.read_bytes() for path in self.checkpoints()}
        owner['process'].kill()
        self.finish(owner, -signal.SIGKILL)
        rejected = self.launch()
        self.finish(rejected, 75)
        self.assertIn('unconfirmed shutdown', rejected['diagnostic'].read_text())
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_malformed_other_checkpoint_is_not_absence(self):
        owner = self.admitted(self.launch())
        self.finish(owner, release=True)
        record = next(path for path in self.checkpoints() if path.is_relative_to(self.registries[1]))
        record.write_text('{invalid JSON')
        rejected = self.launch()
        self.finish(rejected, 65)
        self.assertIn('resource ownership', rejected['diagnostic'].read_text())
        self.assertEqual(record.read_text(), '{invalid JSON')

    def test_passive_checkpoint_only_in_fallback_authorizes_exact_resume(self):
        owner = self.admitted(self.launch(old=True, probe='primary'))
        partial = self.output / 'same-media.mp4.part'
        partial.write_bytes(b'owned synthetic partial')
        self.finish(owner, release=True)
        self.assertEqual(len(self.checkpoints()), 1)
        resumed = self.admitted(self.launch())
        self.assertIn(partial.name, resumed['state']['owned'])
        self.assertEqual(len(self.checkpoints()), 2)
        self.assertTrue(all(row['active'] for row in self.checkpoints().values()))
        self.assertEqual(partial.read_bytes(), b'owned synthetic partial')
        self.finish(resumed, release=True)

    def test_foreign_transaction_cleanup_cannot_passivate_any_owner(self):
        owner = self.admitted(self.launch())
        before = {path: path.read_bytes() for path in self.checkpoints()}
        foreign = dict(owner['state'], transaction='f' * 64)
        self.assertNotEqual(foreign['transaction'], owner['state']['transaction'])
        state = self.root / 'foreign-state.json'
        state.write_text(json.dumps(foreign))
        state.chmod(0o600)
        self.helper('resource-state', '--state', str(state), '--action', 'save',
                    '--registry', str(self.registries[0]), '--registry', str(self.registries[1]))
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.finish(owner, release=True)

    def test_completed_record_in_other_root_vetoes_a_matching_resume(self):
        owner = self.admitted(self.launch())
        partial = self.output / 'same-media.mp4.part'
        partial.write_bytes(b'completed synthetic resource')
        # The historical split could leave different passive histories. Produce
        # both with the real serializer: fallback says completed, primary only
        # owns these unchanged bytes. The latter alone must not grant resume.
        self.helper('resource-state', '--state', str(owner['state_path']), '--action', 'save',
                    '--registry', str(self.registries[1]), '--completed-path', str(partial))
        self.finish(owner, release=True)
        records = self.checkpoints()
        self.assertEqual(len(records), 2)
        self.assertEqual({row['completed'] for row in records.values()}, {'', partial.name})
        before = {path: path.read_bytes() for path in records}
        rejected = self.launch()
        self.finish(rejected, 1)
        self.assertIn('final media destination already exists', rejected['diagnostic'].read_text())
        self.assertEqual({path: path.read_bytes() for path in records}, before)
        self.assertEqual(partial.read_bytes(), b'completed synthetic resource')

    def test_term_between_activations_only_checkpoints_its_own_commits(self):
        interrupted = self.launch(barrier=True)
        helper_pid = int(self.line(interrupted, 'ACTIVATED|').split('|')[1])
        before = self.checkpoints()
        self.assertEqual(len(before), 1)
        self.assertTrue(next(iter(before.values()))['active'])
        # The child identifies itself at the held post-commit barrier. TERM
        # prevents the second activation; Bash then runs its registered cleanup.
        os.kill(helper_pid, signal.SIGTERM)
        self.finish(interrupted, 143)
        after = self.checkpoints()
        self.assertEqual(set(after), set(before))
        self.assertTrue(all(not row['active'] for row in after.values()))
        self.assertEqual({row['transaction'] for row in before.values()},
                         {row['transaction'] for row in after.values()})
        retry = self.admitted(self.launch())
        self.finish(retry, release=True)

    def test_failed_first_save_still_attempts_the_other_owned_registry(self):
        owner = self.admitted(self.launch(save='primary'))
        failed_save = self.helper('resource-state', '--state', str(owner['state_path']), '--action', 'save',
                                  '--registry', str(self.registries[0]), '--registry', str(self.registries[1]),
                                  expected=70, save='primary')
        self.assertIn(b'fixture checkpoint write failed', failed_save.stderr)
        attempts_path = self.root / 'save-attempts.jsonl'
        attempts = [Path(json.loads(line)) for line in attempts_path.read_text().splitlines()]
        self.assertEqual(len(attempts), 2)
        self.assertEqual(set(attempts), set(self.checkpoints()))
        fallback = next(path for path in self.checkpoints() if path.is_relative_to(self.registries[1]))
        saved_fallback = fallback.read_bytes()
        self.assertFalse(json.loads(saved_fallback)['active'])
        # The helper reports failure even though it saved the other registry.
        # Existing engine cleanup preserves its incoming status and warns.
        self.finish(owner, release=True)
        records = self.checkpoints()
        self.assertEqual(len(records), 2)
        for path, row in records.items():
            self.assertEqual(row['active'], path.is_relative_to(self.registries[0]))
            self.assertEqual(row['transaction'], owner['state']['transaction'])
        attempts = [Path(json.loads(line)) for line in attempts_path.read_text().splitlines()]
        self.assertEqual(set(attempts), set(records))
        self.assertEqual(fallback.read_bytes(), saved_fallback)
        self.assertIn('checkpoint failed', owner['diagnostic'].read_text())
        self.finish(self.launch(), 75)


if __name__ == '__main__':
    unittest.main()
