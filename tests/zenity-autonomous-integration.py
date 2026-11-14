# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/zenity-autonomous-integration.py.

Exercise autonomous graphical evidence with independent positive and negative
witnesses. These headless controls qualify the verdict, not desktop gestures.
"""

import copy
import ctypes
from contextlib import nullcontext, redirect_stderr, redirect_stdout
import importlib.util
import io
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


PROJECT = Path(__file__).resolve().parents[1]
DRIVER = PROJECT / 'tests/zenity-autonomous-qualification.py'


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECK = load_module('autonomous_qualification', DRIVER)
ADAPTER = load_module('autonomous_events', PROJECT / 'tests/zenity-x11-events.py')


def event(kind, when, **fields):
    if kind in ('window-mapped', 'progress-rendered', 'folder-mapped'):
        fields = {'real_window': True, 'window': 101, 'screenshot': 'window-101-1.ppm',
                  'screenshot_sha256': 'a' * 64, 'width': 480, 'height': 200, **fields}
    return {'event': kind, 'monotonic_ns': when, **fields}


def evidence(scenario='success', label=None, race_side='after-publication'):
    """Independent expected desktop observations, without calling the driver."""
    label = label or scenario
    row = {
        'scenario': scenario, 'label': label, 'status': 0, 'events': [],
        'output_present': True, 'output_verified': True,
        'result_discovered': True, 'result_published': True, 'partial_retained': False,
        'diagnostics_clean': True, 'state_clean': True,
        'observer_error': False, 'final_live': {}, 'final_windows': [],
        'url_in_argv': [], 'stage': {'transfer_active': True, 'ffmpeg_active': False},
        'closure_ns': 5_000_000_000, 'exit_ns': 6_000_000_000,
    }
    row['events'] = [
        event('window-mapped', 1_000_000_000, dialog='progress',
              title=f'qualification:{label}:progress', window=101),
        event('progress-value', 2_000_000_000, value=10),
        event('progress-rendered', 2_500_000_000, value=10, dialog='progress',
              title=f'qualification:{label}:progress'),
        event('progress-value', 3_000_000_000, value=99),
        event('window-mapped', 4_000_000_000, dialog='question',
              classification='success', title=f'qualification:{label}:question', window=102,
              displayed_path_exact=True, displayed_path_sha256='b' * 64),
    ]
    if scenario in ('error', 'cancel-transfer', 'cancel-ffmpeg', 'signal-entry', 'signal-progress'):
        row.update(output_present=False, output_verified=False, result_published=False)
        row['events'].pop()
    if scenario == 'error':
        row['status'] = 3
        row['events'].append(event('http-error-response', 3_500_000_000, status=404))
        row['events'].append(event('window-mapped', 4_000_000_000, dialog='question',
                                   classification='error', title=f'qualification:{label}:question', window=102))
    elif scenario in ('cancel-transfer', 'cancel-ffmpeg'):
        row['status'] = 130
        row['stage']['ffmpeg_active'] = scenario == 'cancel-ffmpeg'
        row['events'].append(event('input-action', 5_000_000_000, action='cancel',
                                   real_window=True, window=101,
                                   title=f'qualification:{label}:progress'))
    elif scenario in ('signal-entry', 'signal-progress'):
        row['status'] = 143
        if scenario == 'signal-entry':
            row['result_discovered'] = False
            row['stage']['transfer_active'] = False
            row['events'] = [event('window-mapped', 1_000_000_000, dialog='entry',
                                    title=f'qualification:{label}:entry', window=101)]
    elif scenario == 'new-download':
        row['events'].extend([
            event('dialog-result', 4_100_000_000, dialog='question', status=0,
                  selected_action='new-download', title=f'qualification:{label}:question'),
            event('window-mapped', 4_200_000_000, dialog='entry',
                  title=f'qualification:{label}:entry', window=103),
            event('dialog-result', 4_300_000_000, dialog='entry', status=1,
                  title=f'qualification:{label}:entry'),
        ])
    elif scenario == 'open-folder':
        row['events'].extend([
            event('dialog-result', 4_100_000_000, dialog='question', status=0,
                  selected_action='open-folder', title=f'qualification:{label}:question'),
            event('folder-mapped', 4_200_000_000, destination_exact=True, location_property_exact=True,
                  title=f'qualification:{label}:folder', window=103),
            event('folder-gui-exited', 6_100_000_000, title=f'qualification:{label}:folder', viewer_alive=True),
            event('folder-closed', 6_200_000_000, title=f'qualification:{label}:folder', viewer_status=0),
        ])
    elif scenario == 'cancel-success-race':
        row['race_side'] = race_side
        before = race_side == 'before-publication'
        for item in row['events']:
            if item['event'] == 'progress-value' and item['value'] == 99:
                item['value'] = 97 if before else 100
        if before:
            row.update(status=130, output_present=False, output_verified=False, result_published=False)
            row['stage']['ffmpeg_active'] = True
            row['events'] = [item for item in row['events'] if item.get('classification') != 'success']
        row['events'].append(event('race-attempt', 3_500_000_000,
                                   mapped=True, action_after_complete=False,
                                   final_present=not before, final_verified=not before,
                                   ffmpeg_active=before, result_published=not before))
        row['events'].append(event('input-action', 3_600_000_000, action='cancel',
                                   real_window=True, window=101,
                                   title=f'qualification:{label}:progress'))
        row['events'].sort(key=lambda item: item['monotonic_ns'])
    return row


def complete_evidence():
    scenarios = ('success', 'error', 'cancel-transfer', 'cancel-ffmpeg',
                 'new-download', 'open-folder', 'signal-entry', 'signal-progress')
    rows = [evidence(scenario) for scenario in scenarios]
    for side in ('before-publication', 'after-publication'):
        rows.extend(evidence('cancel-success-race', f'race-{side}-{index:02d}', side) for index in range(5))
    return {'schema': 1, 'scenarios': rows}


class EvidenceTests(unittest.TestCase):
    def reject(self, row):
        with self.assertRaises(ValueError):
            CHECK.validate_scenario(row)

    def test_complete_independent_witnesses(self):
        summary = complete_evidence()
        for row in summary['scenarios']:
            with self.subTest(scenario=row['scenario'], label=row['label']):
                CHECK.validate_scenario(row)
        CHECK.validate_evidence(summary)

    def test_every_required_observation_is_explicit(self):
        row = evidence()
        for key in row:
            with self.subTest(missing=key):
                missing = copy.deepcopy(row)
                del missing[key]
                self.reject(missing)

    def test_terminal_observer_refuses_live_process_windows_and_privacy(self):
        witnesses = {
            'observer_error': True,
            'final_live': {'456': {'start': 12345, 'state': 'S'}},
            'final_windows': [{'window': 101, 'title': 'qualification:success:progress'}],
            'url_in_argv': [{'pid': 456, 'url': 'https://secret.invalid/private-token'}],
            'diagnostics_clean': False,
            'state_clean': False,
        }
        for key, value in witnesses.items():
            with self.subTest(observation=key):
                row = evidence()
                row[key] = value
                with self.assertRaises(ValueError) as failure:
                    CHECK.validate_scenario(row)
                self.assertNotIn('private-token', str(failure.exception))

    def test_missing_observation_cannot_look_like_an_empty_inventory(self):
        for key in ('final_live', 'final_windows', 'url_in_argv', 'events', 'stage'):
            with self.subTest(observation=key):
                row = evidence()
                row[key] = None
                self.reject(row)

    def test_boolean_and_string_values_cannot_impersonate_typed_evidence(self):
        for key, value in (
            ('status', False), ('status', '0'), ('output_present', 1),
            ('output_verified', 'yes'), ('observer_error', 0),
            ('closure_ns', True), ('exit_ns', '6000000000'),
        ):
            with self.subTest(field=key, value=value):
                row = evidence()
                row[key] = value
                self.reject(row)

    def test_exit_observation_follows_closure_within_deadline(self):
        for exit_ns in (4_999_999_999, 15_000_000_001):
            with self.subTest(exit_ns=exit_ns):
                row = evidence()
                row['exit_ns'] = exit_ns
                self.reject(row)

    def test_adapter_failure_cannot_be_relabelled_as_user_cancellation(self):
        row = evidence('cancel-transfer')
        row['events'].append(event('adapter-failed-before-rescue', 4_000_000_000))
        self.reject(row)

    def test_success_requires_media_verification_and_visible_success(self):
        for key in ('output_present', 'output_verified', 'result_published', 'result_discovered'):
            row = evidence()
            row[key] = False
            self.reject(row)
        row = evidence()
        row['events'] = [item for item in row['events'] if item.get('classification') != 'success']
        self.reject(row)

    def test_error_and_success_dialogues_are_not_interchangeable(self):
        for scenario, classification in (('success', 'error'), ('error', 'success')):
            with self.subTest(scenario=scenario):
                row = evidence(scenario)
                row['events'].append(event('window-mapped', 4_500_000_000, dialog='question',
                                           classification=classification,
                                           title=f'qualification:{scenario}:question', window=103))
                self.reject(row)

    def test_error_cannot_be_a_cancel_or_a_completed_download(self):
        for change in ({'status': 0}, {'status': 1}, {'status': 69}, {'status': 130},
                       {'status': 143}, {'output_present': True}):
            row = evidence('error')
            row.update(change)
            self.reject(row)
        row = evidence('error')
        row['events'] = [item for item in row['events'] if item['event'] != 'http-error-response']
        self.reject(row)

    def test_cancellation_is_bound_to_the_requested_active_stage(self):
        for scenario, stage in (('cancel-transfer', 'transfer_active'), ('cancel-ffmpeg', 'ffmpeg_active')):
            with self.subTest(scenario=scenario):
                row = evidence(scenario)
                row['stage'][stage] = False
                self.reject(row)
                row = evidence(scenario)
                row['status'] = 0
                self.reject(row)
                row = evidence(scenario)
                row['output_present'] = True
                self.reject(row)

    def test_signals_require_the_target_dialog_and_expected_status(self):
        for scenario in ('signal-entry', 'signal-progress'):
            with self.subTest(scenario=scenario):
                row = evidence(scenario)
                row['status'] = 130
                self.reject(row)
                row = evidence(scenario)
                row['events'] = [item for item in row['events'] if item['event'] != 'window-mapped']
                self.reject(row)

    def test_progress_signal_requires_distinct_bounded_monotonic_values(self):
        for values in ([10, 10], [99, 10], [-1, 99], [10, 101], [True, 99], []):
            with self.subTest(values=values):
                row = evidence('signal-progress')
                row['events'] = [item for item in row['events'] if item['event'] != 'progress-value']
                row['events'].extend(event('progress-value', 2_000_000_000 + index, value=value)
                                     for index, value in enumerate(values))
                self.reject(row)

    def test_mapped_window_requires_actual_capture_identity(self):
        for field, value in (
            ('real_window', False), ('window', True), ('window', 0),
            ('screenshot', '../outside.ppm'), ('screenshot_sha256', 'unverified'),
            ('width', 0), ('height', '200'),
        ):
            with self.subTest(field=field, value=value):
                row = evidence()
                completion = next(item for item in row['events'] if item.get('classification') == 'success')
                completion[field] = value
                self.reject(row)

    def test_signal_requires_visible_progress_before_closure(self):
        for mutation in ('missing-render', 'late-render', 'late-mapping'):
            with self.subTest(mutation=mutation):
                row = evidence('signal-progress')
                if mutation == 'missing-render':
                    row['events'] = [item for item in row['events'] if item['event'] != 'progress-rendered']
                else:
                    kind = 'progress-rendered' if mutation == 'late-render' else 'window-mapped'
                    for item in row['events']:
                        if item['event'] == kind:
                            item['monotonic_ns'] = row['closure_ns'] + 1
                self.reject(row)

    def test_new_download_requires_selection_then_fresh_entry_then_cancel(self):
        for mutation in ('no-selection', 'wrong-status', 'no-entry', 'stale-entry',
                         'no-second-cancel', 'cancel-before-entry'):
            with self.subTest(mutation=mutation):
                row = evidence('new-download')
                selected = next(item for item in row['events'] if item.get('selected_action') == 'new-download')
                entry = next(item for item in row['events'] if item['event'] == 'window-mapped'
                             and item.get('dialog') == 'entry')
                canceled = next(item for item in row['events'] if item['event'] == 'dialog-result'
                                and item.get('dialog') == 'entry')
                if mutation == 'no-selection':
                    row['events'].remove(selected)
                elif mutation == 'wrong-status':
                    selected['status'] = 2
                elif mutation == 'no-entry':
                    row['events'].remove(entry)
                elif mutation == 'stale-entry':
                    entry['monotonic_ns'] = selected['monotonic_ns'] - 1
                elif mutation == 'no-second-cancel':
                    row['events'].remove(canceled)
                else:
                    canceled['monotonic_ns'] = entry['monotonic_ns'] - 1
                self.reject(row)

    def test_new_download_accepts_real_extra_button_status_but_not_boolean(self):
        row = evidence('new-download')
        selected = next(item for item in row['events'] if item.get('selected_action') == 'new-download')
        selected['status'] = 1
        CHECK.validate_scenario(row)
        selected['status'] = False
        self.reject(row)

    def test_open_folder_preserves_the_viewer_until_gui_exit(self):
        for mutation in ('wrong-destination', 'no-folder', 'no-exit-observation',
                         'premature-close', 'no-close', 'no-selection', 'wrong-location-property',
                         'viewer-failure', 'boolean-viewer-status'):
            with self.subTest(mutation=mutation):
                row = evidence('open-folder')
                folder = next(item for item in row['events'] if item['event'] == 'folder-mapped')
                exited = next(item for item in row['events'] if item['event'] == 'folder-gui-exited')
                closed = next(item for item in row['events'] if item['event'] == 'folder-closed')
                if mutation == 'wrong-destination':
                    folder['destination_exact'] = False
                elif mutation == 'wrong-location-property':
                    folder['location_property_exact'] = False
                elif mutation == 'viewer-failure':
                    closed['viewer_status'] = 1
                elif mutation == 'boolean-viewer-status':
                    closed['viewer_status'] = False
                elif mutation == 'no-folder':
                    row['events'].remove(folder)
                elif mutation == 'no-exit-observation':
                    row['events'].remove(exited)
                elif mutation == 'premature-close':
                    closed['monotonic_ns'] = row['exit_ns'] - 1
                elif mutation == 'no-close':
                    row['events'].remove(closed)
                else:
                    row['events'] = [item for item in row['events'] if item.get('selected_action') != 'open-folder']
                self.reject(row)

    def test_completion_race_preserves_each_valid_outcome(self):
        CHECK.validate_scenario(evidence('cancel-success-race', race_side='before-publication'))
        CHECK.validate_scenario(evidence('cancel-success-race', race_side='after-publication'))

    def test_completion_race_cannot_invent_attempts_or_false_failures(self):
        for mutation in ('early-attempt', 'no-attempt', 'duplicate-attempt', 'contradictory-attempt',
                         'no-cancel', 'failure-status', 'canceled-published-result',
                         'disappeared-without-action', 'cancel-before-attempt',
                         'unverified-published-media', 'missing-side'):
            with self.subTest(mutation=mutation):
                row = evidence('cancel-success-race')
                attempt = next(item for item in row['events'] if item['event'] == 'race-attempt')
                if mutation == 'early-attempt':
                    attempt['monotonic_ns'] = 2_900_000_000
                elif mutation == 'no-attempt':
                    row['events'].remove(attempt)
                elif mutation == 'duplicate-attempt':
                    row['events'].append(copy.deepcopy(attempt))
                elif mutation == 'contradictory-attempt':
                    attempt['action_after_complete'] = True
                elif mutation == 'no-cancel':
                    row['events'] = [item for item in row['events'] if item.get('action') != 'cancel']
                elif mutation == 'failure-status':
                    row.update(status=1, output_present=False, output_verified=False)
                    row['events'] = [item for item in row['events'] if item.get('classification') != 'success']
                elif mutation == 'canceled-published-result':
                    row['status'] = 130
                elif mutation == 'disappeared-without-action':
                    attempt.update(mapped=False, action_after_complete=True)
                elif mutation == 'cancel-before-attempt':
                    for item in row['events']:
                        if item.get('action') == 'cancel':
                            item['monotonic_ns'] = attempt['monotonic_ns'] - 1
                elif mutation == 'unverified-published-media':
                    attempt['final_verified'] = False
                else:
                    del row['race_side']
                self.reject(row)

    def test_prepublication_race_requires_live_ffmpeg_and_absent_result_record(self):
        for field, value in (('ffmpeg_active', False), ('result_published', True)):
            with self.subTest(field=field):
                row = evidence('cancel-success-race', race_side='before-publication')
                attempt = next(item for item in row['events'] if item['event'] == 'race-attempt')
                attempt[field] = value
                self.reject(row)

    def test_native_partial_is_preserved_without_manufacturing_success(self):
        for scenario in ('cancel-ffmpeg', 'cancel-success-race'):
            for verified in (False, True):
                with self.subTest(scenario=scenario, decodable=verified):
                    row = evidence(scenario, race_side='before-publication')
                    row.update(output_present=True, output_verified=verified, partial_retained=True)
                    CHECK.validate_scenario(row)
                    row['result_published'] = True
                    row['partial_retained'] = False
                    self.reject(row)

    def test_no_media_action_cannot_claim_a_retained_partial(self):
        for scenario in ('error', 'signal-entry'):
            with self.subTest(scenario=scenario):
                row = evidence(scenario)
                row.update(output_present=True, partial_retained=True)
                self.reject(row)

    def test_summary_requires_every_scenario_and_ten_independent_race_trials(self):
        summary = complete_evidence()
        for index in (0, len(summary['scenarios']) - 1):
            with self.subTest(missing_trial=index):
                broken = copy.deepcopy(summary)
                del broken['scenarios'][index]
                with self.assertRaises(ValueError):
                    CHECK.validate_evidence(broken)
        broken = copy.deepcopy(summary)
        broken['scenarios'][-1]['label'] = broken['scenarios'][-2]['label']
        with self.assertRaises(ValueError):
            CHECK.validate_evidence(broken)
        broken = copy.deepcopy(summary)
        broken['scenarios'][-1] = evidence('cancel-success-race', 'extra-before', 'before-publication')
        with self.assertRaises(ValueError):
            CHECK.validate_evidence(broken)
        for schema in (True, '1', 2):
            with self.subTest(schema=schema):
                broken = copy.deepcopy(summary)
                broken['schema'] = schema
                with self.assertRaises(ValueError):
                    CHECK.validate_evidence(broken)

    def test_validation_remains_active_under_python_optimization(self):
        code = '''import importlib.util, sys
spec = importlib.util.spec_from_file_location("qualification", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    module.validate_evidence({"schema": 1, "scenarios": []})
except ValueError:
    sys.exit(0)
sys.exit(1)
'''
        completed = subprocess.run([sys.executable, '-I', '-B', '-O', '-c', code, str(DRIVER)],
                                   capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)


class AdapterFailureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zenity-evidence-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.record = self.root / 'events.jsonl'
        self.destination = self.root / 'chosen'
        self.destination.mkdir()
        self.final = self.destination / 'qualified.mkv'
        self.final.write_bytes(b'fixture final file')
        environment = {
            'FIXTURE_AUTONOMOUS': '1', 'FIXTURE_LABEL': 'new-download',
            'FIXTURE_SCENARIO': 'new-download', 'FIXTURE_X11_EVENTS': str(self.record),
            'FIXTURE_REAL_ZENITY': '/unused/real-zenity',
            'FIXTURE_OUTPUT': str(self.destination),
            'FIXTURE_EXPECTED_FINAL': str(self.final),
        }
        patcher = mock.patch.dict(os.environ, environment)
        patcher.start()
        self.addCleanup(patcher.stop)

    def events(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def success_args(self):
        return ['--question', '--no-markup', '--text=The download is complete.\n\nFile: ' + str(self.final)]

    def test_real_live_child_failure_is_recorded_before_rescue(self):
        # The child is genuinely alive until the adapter rescues it. Capturing
        # evidence after terminate would miss the original failing state.
        real_popen = subprocess.Popen
        children = []
        observed = []

        def start_child(*_args, **_kwargs):
            child = real_popen([sys.executable, '-I', '-B', '-c',
                               'import sys; sys.stdin.buffer.read()'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            children.append(child)
            real_terminate = child.terminate

            def observe_rescue():
                self.assertIsNone(child.poll(), 'failure witness was collected after child exit')
                observed.append(self.events()[-1]['event'])
                real_terminate()

            child.terminate = observe_rescue
            return child

        display = mock.Mock()
        display.wait_window.side_effect = RuntimeError('injected mapping failure')
        try:
            with mock.patch.object(ADAPTER.subprocess, 'Popen', side_effect=start_child), \
                    mock.patch.object(ADAPTER, 'Display', return_value=display):
                with self.assertRaisesRegex(RuntimeError, 'injected mapping failure'):
                    ADAPTER.autonomous_dialog(self.success_args())
            self.assertEqual(observed, ['adapter-failed-before-rescue'])
            self.assertEqual(len(children), 1)
            self.assertIsNotNone(children[0].poll())
            self.assertFalse(any(item['event'] == 'dialog-result' for item in self.events()))
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)

    def test_zero_exit_without_selected_new_download_is_failure(self):
        # A real successful process exit cannot manufacture the selected
        # completion button's output, even if the input adapter accepted keys.
        real_popen = subprocess.Popen
        children = []

        def start_child(*_args, **_kwargs):
            child = real_popen([sys.executable, '-I', '-B', '-c',
                               'print("unselected completion action")'],
                              stdout=subprocess.PIPE)
            children.append(child)
            return child

        display = mock.Mock()
        display.capture.return_value = {'window': 102, 'real_window': True}
        try:
            with mock.patch.object(ADAPTER.subprocess, 'Popen', side_effect=start_child), \
                    mock.patch.object(ADAPTER, 'Display', return_value=display):
                with self.assertRaisesRegex(AssertionError, 'New download'):
                    ADAPTER.autonomous_dialog(self.success_args())
            self.assertEqual(self.events()[-1]['event'], 'adapter-failed-before-rescue')
            self.assertFalse((self.root / 'new-download.new-download').exists())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)

    def test_folder_route_rejects_wrong_directory_before_launch(self):
        other_parent = self.root / 'other'
        other_parent.mkdir()
        wrong = other_parent / self.destination.name
        wrong.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(self.destination, target_is_directory=True)
        for arguments in ([str(wrong)], [str(alias)], [], [str(self.destination), str(wrong)]):
            with self.subTest(arguments=arguments), \
                    mock.patch.object(ADAPTER.subprocess, 'Popen') as popen, \
                    mock.patch.object(ADAPTER.shutil, 'which', return_value='/unused/nautilus'):
                with self.assertRaisesRegex(AssertionError, 'exact selected directory'):
                    ADAPTER.autonomous_open_folder(arguments)
                popen.assert_not_called()
                self.assertEqual(self.events()[-1]['event'], 'adapter-failed-before-rescue')

    def test_success_cannot_display_a_different_final_file(self):
        args = self.success_args()
        args[-1] += '.wrong'
        with mock.patch.object(ADAPTER.subprocess, 'Popen') as popen:
            with self.assertRaises((AssertionError, ValueError)):
                ADAPTER.autonomous_dialog(args)
            popen.assert_not_called()

    def test_expected_wrapper_term_reaches_and_reaps_the_real_dialog_child(self):
        # A wrapper must not change the production single-Zenity-PID contract.
        # The live child acknowledges TERM; the test rescues it only on failure.
        script = '''import importlib.util, os, pathlib, signal, subprocess, sys, time
spec = importlib.util.spec_from_file_location("adapter", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = pathlib.Path(sys.argv[2])
real_popen = subprocess.Popen
child_code = """import pathlib, signal, sys
root = pathlib.Path(sys.argv[1])
def received(number, _frame):
    (root / 'child-signal').write_text(str(number))
    sys.exit(128 + number)
signal.signal(signal.SIGTERM, received)
(root / 'child-ready').write_text('ready')
while True:
    signal.pause()
"""
def start(*_args, **_kwargs):
    process = real_popen([sys.executable, '-I', '-B', '-c', child_code, str(root)],
                         stdout=subprocess.PIPE)
    (root / 'child-pid').write_text(str(process.pid))
    return process
class Display:
    def wait_window(self, _title):
        deadline = time.monotonic() + 5
        while not (root / 'child-ready').exists():
            if time.monotonic() >= deadline:
                raise RuntimeError('child readiness timeout')
            time.sleep(.01)
        return 123
    def capture(self, _title, _record):
        return {'window':123, 'real_window':True}
    def close(self):
        pass
module.subprocess.Popen = start
module.Display = Display
sys.exit(module.autonomous_dialog(['--entry']))
'''
        environment = dict(os.environ, FIXTURE_LABEL='signal-entry', FIXTURE_SCENARIO='signal-entry')
        wrapper = subprocess.Popen([sys.executable, '-I', '-B', '-c', script,
                                    str(PROJECT / 'tests/zenity-x11-events.py'), str(self.root)],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        handle = None
        child_pid = None
        try:
            deadline = time.monotonic() + 5
            while True:
                self.assertIsNone(wrapper.poll(), 'adapter exited before its mapped-window witness')
                if self.record.exists() and any(row['event'] == 'window-mapped' for row in self.events()):
                    break
                self.assertLess(time.monotonic(), deadline, 'adapter did not reach a mapped window')
                time.sleep(.01)
            child_pid = int((self.root / 'child-pid').read_text())
            handle = os.pidfd_open(child_pid)
            wrapper.send_signal(signal.SIGTERM)
            stdout, stderr = wrapper.communicate(timeout=5)
            self.assertEqual(wrapper.returncode, 143, stderr.decode(errors='replace'))
            self.assertEqual(stdout, b'')
            self.assertEqual((self.root / 'child-signal').read_text(), str(int(signal.SIGTERM)))
            self.assertFalse(Path(f'/proc/{child_pid}').exists(), 'dialog child was not reaped before wrapper exit')
            self.assertFalse(any(row['event'] == 'adapter-failed-before-rescue' for row in self.events()))
        finally:
            if handle is not None:
                try:
                    signal.pidfd_send_signal(handle, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                finally:
                    os.close(handle)
            if wrapper.poll() is None:
                wrapper.kill()
            wrapper.communicate(timeout=5)


class EvidenceStreamTests(unittest.TestCase):
    def test_final_partial_failure_record_is_not_silently_discarded(self):
        with tempfile.TemporaryDirectory(prefix='zenity-stream-') as temporary:
            path = Path(temporary) / 'events.jsonl'
            first = event('window-mapped', 1, title='qualification:success:progress')
            last = event('adapter-failed-before-rescue', 2, title='qualification:success:progress')
            path.write_text(json.dumps(first) + '\n' + json.dumps(last))
            self.assertEqual(CHECK.read_events(path, 'success'), [first])
            with self.assertRaises(ValueError):
                CHECK.read_events(path, 'success', complete=True)
            with path.open('a') as stream:
                stream.write('\n')
            self.assertEqual(CHECK.read_events(path, 'success', complete=True), [first, last])

    def test_partial_identity_is_never_evidence_for_another_invocation(self):
        with tempfile.TemporaryDirectory(prefix='zenity-stream-') as temporary:
            path = Path(temporary) / 'events.jsonl'
            chosen = event('dialog-result', 2, title='qualification:success:question')
            others = [event('dialog-result', 1, title='qualification:successor:question'),
                      event('dialog-result', 3, title='qualification:other:question')]
            path.write_text(''.join(json.dumps(row) + '\n' for row in [*others, chosen]))
            self.assertEqual(CHECK.read_events(path, 'success', complete=True), [chosen])


class MediaRouteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zenity-media-route-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.content = b'0123456789abcdef'
        self.source = self.root / 'fixture-media'
        self.source.write_bytes(self.content)
        self.proof = self.root / 'predeclared-proof.json'
        self.events = self.root / 'events.jsonl'
        self.active = set()
        self.gate = mock.Mock()
        self.gate.wait.return_value = True
        routes = {
            '/registered.mp4': ('internal-label', self.source, self.gate, self.proof, False),
            '/error.mp4': ('controlled-error', self.source, self.gate, self.proof, True),
        }
        self.handler = CHECK.make_media_handler(routes, self.active, self.events)

    def request(self, target, headers=''):
        raw = f'GET {target} HTTP/1.0\r\nHost: fixture.invalid\r\n{headers}\r\n'.encode('ascii')

        class Request(self.handler):
            def setup(request):
                request.rfile = io.BytesIO(raw)
                request.wfile = io.BytesIO()

            def finish(request):
                pass

        request = Request(None, ('127.0.0.1', 12345), object())
        head, body = request.wfile.getvalue().split(b'\r\n\r\n', 1)
        return int(head.split(b' ', 2)[1]), head, body

    def test_registered_media_and_range_use_the_preconstructed_record(self):
        # BaseHTTPRequestHandler reduces a leading // to / before dispatch.
        for target in ('/registered.mp4', '//registered.mp4'):
            with self.subTest(target=target):
                status, _, body = self.request(target)
                self.assertEqual((status, body), (200, self.content))
        status, head, body = self.request('/registered.mp4', 'Range: bytes=4-\r\n')
        self.assertEqual((status, body), (206, self.content[4:]))
        self.assertIn(b'Content-Range: bytes 4-15/16\r\n', head + b'\r\n')
        self.assertEqual(self.gate.wait.call_count, 3)
        self.assertEqual(self.active, set())
        self.assertFalse(self.events.exists())
        self.assertFalse(self.proof.exists())

    def test_unknown_alias_and_traversal_targets_cannot_access_media_or_evidence(self):
        targets = ('/unknown.mp4', '/nested/registered.mp4', '/x/../registered.mp4',
                   '/../registered.mp4', '/%2e%2e/registered.mp4', '/%72egistered.mp4',
                   '/registered.more.mp4', '/registered.mp4?query=ignored',
                   '/registered.mp4#ignored', 'http://fixture.invalid/registered.mp4',
                   '/REGISTERED.mp4', '/nested/error.mp4', '/error.mp4?query=ignored')
        for target in targets:
            with self.subTest(target=target), \
                    mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('unregistered media read')), \
                    mock.patch.object(CHECK, 'write_json', side_effect=AssertionError('unregistered proof write')):
                status, _, _ = self.request(target)
                self.assertEqual(status, 404)
        self.gate.wait.assert_not_called()
        self.assertEqual(self.active, set())
        self.assertEqual({path.name for path in self.root.iterdir()}, {'fixture-media'})
        self.assertEqual(self.source.read_bytes(), self.content)

    def test_transfer_timeout_writes_only_the_preconstructed_failure_path(self):
        def timeout(_deadline):
            self.assertEqual(self.active, {'internal-label'})
            return False

        self.gate.wait.side_effect = timeout
        with mock.patch.object(CHECK, 'write_json', wraps=CHECK.write_json) as write:
            status, _, body = self.request('//registered.mp4')
        self.assertEqual(status, 200)
        self.assertEqual(body, self.content[:len(self.content) // 2])
        write.assert_called_once_with(self.proof, {'barrier_timeout': True})
        self.assertEqual(json.loads(self.proof.read_text()), {'barrier_timeout': True})
        self.assertEqual({path.name for path in self.root.iterdir()}, {'fixture-media', 'predeclared-proof.json'})
        self.assertEqual(self.active, set())

    def test_controlled_http_error_uses_the_registered_label_without_media_access(self):
        with mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('error route read media')):
            status, _, _ = self.request('/error.mp4')
        self.assertEqual(status, 404)
        events = [json.loads(line) for line in self.events.read_text().splitlines()]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['event'], 'http-error-response')
        self.assertEqual(events[0]['label'], 'controlled-error')
        self.assertEqual(events[0]['status'], 404)
        self.assertGreater(events[0]['monotonic_ns'], 0)
        self.gate.wait.assert_not_called()
        self.assertFalse(self.proof.exists())


class WindowTitleTests(unittest.TestCase):
    @staticmethod
    def display(payload=b'output 100% $ \xc3\xa9', *, status=0, actual=2, fmt=8,
                length=None, remaining=0, null=False):
        display = ADAPTER.Display.__new__(ADAPTER.Display)
        display.display = object()
        display.x = mock.Mock()
        display.x.XInternAtom.side_effect = lambda _display, name, _only: 2 if name == b'UTF8_STRING' else 1
        primary = ctypes.create_string_buffer(payload)
        legacy = ctypes.create_string_buffer(b'output 100% $ \xe9')

        def property_read(*args):
            self_actual, self_fmt, self_length, self_remaining, self_value = args[7:]
            self_actual._obj.value = actual
            self_fmt._obj.value = fmt
            self_length._obj.value = len(payload) if length is None else length
            self_remaining._obj.value = remaining
            self_value._obj.value = None if null or not actual else ctypes.addressof(primary)
            return status

        def legacy_read(_display, _window, pointer):
            pointer._obj.value = ctypes.addressof(legacy)
            return 1

        display.x.XGetWindowProperty.side_effect = property_read
        display.x.XFetchName.side_effect = legacy_read
        return display

    def test_utf8_accent_is_exact_and_absent_property_uses_legacy(self):
        current = self.display()
        self.assertEqual(current.window_title(123), 'output 100% $ é')
        current.x.XFetchName.assert_not_called()
        current.x.XFree.assert_called_once()
        legacy = self.display(actual=0, length=0)
        self.assertEqual(legacy.window_title(123), 'output 100% $ é')
        legacy.x.XFetchName.assert_called_once()

    def test_refused_truncated_and_malformed_properties_cannot_fall_back(self):
        for change in ({'status': 1}, {'actual': 3}, {'fmt': 16}, {'length': 8193},
                       {'remaining': 1}, {'null': True}, {'payload': b'\xff'}):
            with self.subTest(change=change):
                display = self.display(**change)
                with self.assertRaises((RuntimeError, UnicodeDecodeError)):
                    display.window_title(123)
                display.x.XFetchName.assert_not_called()


class LocaleProtocolTests(unittest.TestCase):
    def test_gui_utf8_boundary_preserves_host_and_non_character_categories(self):
        source = (PROJECT / 'download-video-gui.sh').read_text(encoding='utf-8')
        self.assertEqual(source.count('\nmain "$@"'), 1)
        source = source.rsplit('\nmain "$@"', 1)[0]
        categories = ('LC_ALL', 'LC_CTYPE', 'LANG', 'LANGUAGE', 'LC_MESSAGES',
                      'LC_NUMERIC', 'LC_COLLATE', 'LC_TIME', 'LC_MONETARY',
                      'LC_ADDRESS', 'LC_IDENTIFICATION', 'LC_MEASUREMENT',
                      'LC_NAME', 'LC_PAPER', 'LC_TELEPHONE')
        probe = 'for category in ' + ' '.join(categories) + '; do\n'
        probe += '    printf "%s\\0" "${!category-}"\ndone\n'
        cases = (
            ('preserved', 'fr_FR.utf8', {'fr_FR.utf8': 'UTF-8'}, [], 0, None),
            ('neutral', 'C', {'C': 'ANSI_X3.4-1968', 'C.UTF-8': 'UTF-8'}, [], 0, 'C.UTF-8'),
            ('alias', 'C', {'C': 'ANSI_X3.4-1968', 'C.utf8': 'UTF-8'}, [], 0, 'C.utf8'),
            ('candidate-diagnostic', 'C', {'C': 'ANSI_X3.4-1968', 'C.UTF-8': 'UTF-8\nwarning',
                                         'C.utf8': 'UTF-8'}, [], 0, 'C.utf8'),
            ('fallback', 'C', {'C': 'ANSI_X3.4-1968', 'fr_FR.utf8': 'UTF-8'},
             ['C', 'fr_FR.utf8'], 0, 'fr_FR.utf8'),
            ('category-only', '', {'': 'ANSI_X3.4-1968', 'C.UTF-8': 'UTF-8'}, [], 0, 'C.UTF-8'),
            ('unavailable', 'C', {'C': 'ANSI_X3.4-1968'}, ['C'], 69, None),
            ('list-error', 'C', {'C': 'ANSI_X3.4-1968'}, None, 69, None),
            ('probe-error', 'C', {}, [], 69, None),
            ('invalid-category', 'project_missing_LOCALE.utf8', {'project_missing_LOCALE.utf8': 'ANSI_X3.4-1968'}, [], 69, None),
        )
        with tempfile.TemporaryDirectory(prefix='zenity-locale-boundary-') as temporary:
            root = Path(temporary)
            binary = root / 'bin'
            binary.mkdir(mode=0o700)
            locale = binary / 'locale'
            locale.write_text('#!/usr/bin/python3\n'
                              'import json, os, sys\n'
                              'from pathlib import Path\n'
                              'policy = json.loads(Path(os.environ["LOCALE_TEST_POLICY"]).read_bytes())\n'
                              'if sys.argv[1:] == ["-a"]:\n'
                              '    if policy["available"] is None: sys.exit(7)\n'
                              '    print("\\n".join(policy["available"]))\n'
                              'elif sys.argv[1:] == ["charmap"]:\n'
                              '    value = policy["charmaps"].get(os.environ.get("LC_ALL", ""))\n'
                              '    if value is None: sys.exit(1)\n'
                              '    if os.environ.get("LC_ALL") == "project_missing_LOCALE.utf8": print("invalid locale", file=sys.stderr)\n'
                              '    print(value)\n'
                              'else: sys.exit(2)\n', encoding='utf-8')
            locale.chmod(0o700)
            zenity = binary / 'zenity'
            zenity.write_text('#!/bin/bash\n' + probe + 'printf "%s\\0" "$@"\nexit 42\n', encoding='utf-8')
            zenity.chmod(0o700)
            policy = root / 'policy.json'
            for label, inherited_all, charmaps, available, expected, selected in cases:
                with self.subTest(case=label):
                    policy.write_text(json.dumps(dict(charmaps=charmaps, available=available)), encoding='utf-8')
                    environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                                       LOCALE_TEST_POLICY=str(policy), LC_ALL=inherited_all, LC_CTYPE='C',
                                       LANG='fr_FR.utf8', LANGUAGE='fr_FR:fr')
                    for category in categories[4:]:
                        environment[category] = 'fr_FR.utf8'
                    statements = ('\n' + probe + 'initialize_zenity_command || exit $?\n'
                                  + probe + 'set +e\n"${ZENITY_COMMAND[@]}" --text="été 日本語"\n'
                                  + 'status=$?\n' + probe + 'exit "$status"\n')
                    completed = subprocess.run(['bash', '-s'], input=(source + statements).encode('utf-8'),
                                               env=environment, capture_output=True, timeout=10)
                    self.assertEqual(completed.returncode, 42 if expected == 0 else expected, completed.stderr)
                    fields = completed.stdout.split(b'\0')
                    parent = [environment[name].encode('utf-8') for name in categories]
                    self.assertEqual(fields[:len(categories)], parent)
                    if expected:
                        self.assertEqual(len(fields), len(categories) + 1)
                        self.assertIn(b'Error:', completed.stderr)
                        continue
                    self.assertEqual(fields[len(categories):2 * len(categories)], parent)
                    child = dict(zip(categories, fields[2 * len(categories):3 * len(categories)]))
                    self.assertEqual(child['LANGUAGE'], b'fr_FR:fr')
                    self.assertEqual(child['LANG'], b'fr_FR.utf8')
                    if selected is None:
                        self.assertEqual(list(child.values()), parent)
                    else:
                        self.assertEqual(child['LC_ALL'], b'')
                        self.assertEqual(child['LC_CTYPE'], selected.encode('ascii'))
                        for category in categories[4:]:
                            self.assertEqual(child[category], (inherited_all or 'fr_FR.utf8').encode('ascii'))
                    self.assertEqual(fields[3 * len(categories)], '--text=été 日本語'.encode('utf-8'))
                    self.assertEqual(fields[3 * len(categories) + 1:-1], parent)

    def run_gui_locale_callsite(self, source, target):
        categories = ('LC_ALL', 'LC_CTYPE', 'LANG', 'LANGUAGE', 'LC_MESSAGES',
                      'LC_NUMERIC', 'LC_COLLATE', 'LC_TIME', 'LC_MONETARY')
        probe = 'for category in ' + ' '.join(categories) + '; do\n'
        probe += '    printf "%s\\0" "${!category-}"\ndone\n'
        self.assertEqual(source.count('\nmain "$@"'), 1)
        source = source.rsplit('\nmain "$@"', 1)[0]
        with tempfile.TemporaryDirectory(prefix='zenity-locale-callsite-') as temporary:
            root = Path(temporary)
            binary = root / 'bin'
            binary.mkdir(mode=0o700)
            (root / 'input').write_bytes(b'')
            locale = binary / 'locale'
            locale.write_text('#!/bin/bash\n'
                              'if [[ ${1-} == charmap && ${LC_ALL-} == C.UTF-8 ]]; then\n'
                              '    printf "UTF-8\\n"\n'
                              'elif [[ ${1-} == charmap && ${LC_ALL-} == C ]]; then\n'
                              '    printf "ANSI_X3.4-1968\\n"\n'
                              'else exit 1; fi\n', encoding='utf-8')
            locale.chmod(0o700)
            zenity = binary / 'zenity'
            zenity.write_text('#!/bin/bash\n{\n' + probe + '} >"${LOCALE_TEST_ROOT}/child.env"\n'
                              'printf "%s\\0" "$@" >"${LOCALE_TEST_ROOT}/child.argv"\n'
                              'printf "%s\\n" "$$" >"${LOCALE_TEST_ROOT}/child.pid"\n'
                              'printf "selected\\n"\nexit 1\n', encoding='utf-8')
            zenity.chmod(0o700)
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                               LOCALE_TEST_ROOT=str(root), LOCALE_TEST_TARGET=target,
                               LC_ALL='C', LC_CTYPE='C', LANG='fr_FR.utf8', LANGUAGE='fr_FR:fr',
                               LC_MESSAGES='fr_FR.utf8', LC_NUMERIC='fr_FR.utf8',
                               LC_COLLATE='fr_FR.utf8', LC_TIME='fr_FR.utf8', LC_MONETARY='fr_FR.utf8')
            # Actual main and startup run until script resolution, where the
            # fixture enters the real launch function without a media session.
            # Registered children are waited, and only fixture-owned files exist.
            statements = r'''
cleanup() { :; }
begin_signal_registration() { :; }
finish_signal_registration() {
    printf '%s\n' "${ZENITY_PID}" >"${LOCALE_TEST_ROOT}/registered.pid"
    if [[ ${LOCALE_TEST_TARGET} != capture ]]; then
        set +e
        wait "${ZENITY_PID}"
        printf '%s\n' "$?" >"${LOCALE_TEST_ROOT}/status"
        if [[ -n ${PROGRESS_MONITOR_PID} ]]; then
            wait "${PROGRESS_MONITOR_PID}"
        fi
        exit 0
    fi
}
bash() { return 0; }
run_fixture() {
    RUNTIME_TMPDIR=${LOCALE_TEST_ROOT}
    PROGRESS_PIPE=${LOCALE_TEST_ROOT}/input
    PROGRESS_DIALOG_ERROR_FILE=${LOCALE_TEST_ROOT}/dialog-error
    PROGRESS_MONITOR_ERROR_FILE=${LOCALE_TEST_ROOT}/monitor-error
    PROGRESS_MONITOR=/dev/null
    OUTPUT_DIR=${LOCALE_TEST_ROOT}
    case ${LOCALE_TEST_TARGET} in
        capture)
            captured=''
            run_zenity_capture captured --question --text='été 日本語'
            printf '%s\n' "${ZENITY_STATUS}" >"${LOCALE_TEST_ROOT}/status"
            printf '%s' "${captured}" >"${LOCALE_TEST_ROOT}/captured"
            exit 0
            ;;
        arte) wait_for_arte_catalogue ;;
        progress) run_progress_dialog ;;
    esac
    exit 97
}
resolve_script_dir() {
'''
            statements += '{\n' + probe + '} >"${LOCALE_TEST_ROOT}/parent-after.env"\nrun_fixture\n}\n'
            # A removed startup call must fail the same oracle, not accidentally
            # continue to the real user's request-selection implementation.
            statements += 'collect_download_request() { run_fixture; }\n'
            statements += '{\n' + probe + '} >"${LOCALE_TEST_ROOT}/parent-before.env"\nmain\n'
            completed = subprocess.run(['/bin/bash', '-s'], input=(source + statements).encode('utf-8'),
                                       env=environment, capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual((root / 'status').read_bytes(), b'1\n')
            self.assertEqual((root / 'registered.pid').read_bytes(), (root / 'child.pid').read_bytes())
            parent = [environment[name].encode('utf-8') for name in categories]
            self.assertEqual((root / 'parent-before.env').read_bytes().split(b'\0')[:-1], parent)
            self.assertEqual((root / 'parent-after.env').read_bytes().split(b'\0')[:-1], parent)
            child = dict(zip(categories, (root / 'child.env').read_bytes().split(b'\0')[:-1]))
            self.assertEqual(child['LC_ALL'], b'', 'Zenity launch bypassed the UTF-8 boundary')
            self.assertEqual(child['LC_CTYPE'], b'C.UTF-8', 'Zenity launch bypassed the UTF-8 boundary')
            self.assertEqual(child['LANG'], b'fr_FR.utf8')
            self.assertEqual(child['LANGUAGE'], b'fr_FR:fr')
            for category in categories[4:]:
                self.assertEqual(child[category], b'C')
            arguments = (root / 'child.argv').read_bytes().split(b'\0')[:-1]
            if target == 'capture':
                self.assertEqual(arguments, [b'--question', '--text=été 日本語'.encode('utf-8')])
                self.assertEqual((root / 'captured').read_bytes(), b'selected')
            else:
                self.assertIn(b'--progress', arguments)
                self.assertEqual(b'--pulsate' in arguments, target == 'arte')

    def test_gui_utf8_boundary_is_wired_to_startup_and_all_three_launch_sites(self):
        source = (PROJECT / 'download-video-gui.sh').read_text(encoding='utf-8')
        for target in ('capture', 'arte', 'progress'):
            with self.subTest(target=target):
                self.run_gui_locale_callsite(source, target)

    def test_gui_utf8_launch_and_startup_bypasses_are_rejected(self):
        source = (PROJECT / 'download-video-gui.sh').read_text(encoding='utf-8')
        for target, original, replacement in (
            ('capture', '    "${ZENITY_COMMAND[@]}" "$@"', '    zenity "$@"'),
            ('arte', '    "${ZENITY_COMMAND[@]}" --progress --pulsate', '    zenity --progress --pulsate'),
            ('progress', '    "${ZENITY_COMMAND[@]}" --progress \\\n', '    zenity --progress \\\n'),
            ('capture', '    if ! initialize_zenity_command; then', '    if ! true; then'),
        ):
            with self.subTest(target=target, bypass=original):
                self.assertEqual(source.count(original), 1)
                mutant = source.replace(original, replacement, 1)
                with self.assertRaisesRegex(AssertionError, 'Zenity launch bypassed the UTF-8 boundary'):
                    self.run_gui_locale_callsite(mutant, target)

    def test_default_preserves_host_categories_without_inserting_lc_all(self):
        current = dict(os.environ)
        self.assertEqual(CHECK.qualification_locale_environment(), current)
        self.assertEqual(dict(os.environ), current)
        for inherited in (
            {'LANG': 'C', 'LC_MESSAGES': 'C', 'LANGUAGE': 'fr_FR:fr'},
            {'LC_ALL': 'C', 'LANG': 'not-installed', 'LC_CTYPE': 'not-installed', 'LANGUAGE': 'fr_FR:fr'},
        ):
            with self.subTest(inherited=inherited), mock.patch.dict(os.environ, inherited, clear=True):
                self.assertEqual(CHECK.qualification_locale_environment(), inherited)
                self.assertEqual(dict(os.environ), inherited)

    def test_invalid_effective_categories_cannot_be_hidden_by_probe_startup(self):
        for category in ('LANG', 'LC_CTYPE', 'LC_NUMERIC'):
            inherited = {'LANG': 'C', category: 'not-an-installed-qualification-locale'}
            with self.subTest(category=category), mock.patch.dict(os.environ, inherited, clear=True):
                with self.assertRaisesRegex(ValueError, 'locale is unavailable'):
                    CHECK.qualification_locale_environment()
                self.assertEqual(dict(os.environ), inherited)

    def test_real_python_startup_records_effective_categories_after_coercion(self):
        invalid = 'project_missing_LOCALE.utf8'
        environment = dict(os.environ, LANG='C', LC_ALL='', LC_CTYPE=invalid,
                           PYTHONCOERCECLOCALE='1', PYTHONUTF8='0')
        for name in ('LC_NUMERIC', 'LC_MESSAGES', 'LC_COLLATE', 'LC_TIME', 'LC_MONETARY'):
            environment[name] = 'C'
        completed = subprocess.run(
            [sys.executable, '-B', '-c',
             'import importlib.util, json, os, sys\n'
             'before = dict(os.environ)\n'
             'spec = importlib.util.spec_from_file_location("driver", sys.argv[1])\n'
             'driver = importlib.util.module_from_spec(spec)\n'
             'spec.loader.exec_module(driver)\n'
             'try:\n'
             '    selected = driver.qualification_locale_environment()\n'
             '    qualified = True\n'
             'except ValueError:\n'
             '    selected = dict(os.environ)\n'
             '    qualified = False\n'
             'try:\n'
             '    driver.qualification_locale_environment(sys.argv[2])\n'
             '    explicit_refused = False\n'
             'except ValueError:\n'
             '    explicit_refused = True\n'
             'proof = driver.qualification_locale_evidence(selected)\n'
             'print(json.dumps(dict(proof=proof, qualified=qualified,\n'
             '    explicit_refused=explicit_refused,\n'
             '    unchanged=dict(os.environ) == before,\n'
             '    before={key: before.get(key) for key in proof})))', str(DRIVER), invalid],
            env=environment, capture_output=True, timeout=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result['proof'], result['before'])
        self.assertEqual(set(result['proof']), {
            'LC_ALL', 'LANG', 'LANGUAGE', 'LC_CTYPE', 'LC_NUMERIC', 'LC_MESSAGES',
            'LC_COLLATE', 'LC_TIME', 'LC_MONETARY', 'PYTHONUTF8', 'PYTHONCOERCECLOCALE',
        })
        self.assertEqual(result['proof']['LC_ALL'], '')
        self.assertEqual(result['proof']['LANG'], 'C')
        self.assertEqual(result['proof']['PYTHONCOERCECLOCALE'], '1')
        self.assertEqual(result['proof']['PYTHONUTF8'], '0')
        # A host without a coercion target must refuse the still-invalid value;
        # a coerced host qualifies its actual replacement, never the input name.
        self.assertEqual(result['qualified'], result['proof']['LC_CTYPE'] != invalid)
        self.assertTrue(result['explicit_refused'])
        self.assertTrue(result['unchanged'])

    def test_requested_available_locale_overrides_lc_all_only_in_child_environment(self):
        before = dict(os.environ)
        requested = os.environ.get('LC_ALL') or 'C'
        environment = CHECK.qualification_locale_environment(requested)
        self.assertEqual(environment['LC_ALL'], requested)
        self.assertEqual(os.environ, before)
        for name, value in before.items():
            if name != 'LC_ALL':
                self.assertEqual(environment[name], value)
        with mock.patch.dict(os.environ, LC_ALL='invalid-locale-from-parent'):
            self.assertEqual(CHECK.qualification_locale_environment('C')['LC_ALL'], 'C')
            self.assertEqual(os.environ['LC_ALL'], 'invalid-locale-from-parent')

    def test_unavailable_locale_never_falls_back_silently(self):
        for value in ('not-an-installed-qualification-locale', ''):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'locale is unavailable'):
                CHECK.qualification_locale_environment(value)

    def test_scripted_unicode_folder_is_byte_exact_under_ascii_python(self):
        destination = '/tmp/\u00e9t\u00e9 japonais \u65e5\u672c\u8a9e'
        environment = dict(os.environ, LC_ALL='C', FIXTURE_AUTONOMOUS='1',
                           FIXTURE_LABEL='success', FIXTURE_SCENARIO='success',
                           FIXTURE_X11_EVENTS='/tmp/unused-locale-dialog-events',
                           FIXTURE_OUTPUT=destination.encode('utf-8'))
        completed = subprocess.run(
            [sys.executable, '-I', '-B', '-X', 'utf8=0',
             str(PROJECT / 'tests/zenity-x11-events.py'), '--file-selection'],
            env=environment, capture_output=True, timeout=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, (destination + '\n').encode('utf-8'))
        self.assertEqual(completed.stderr, b'')


class PlatformAdmissionTests(unittest.TestCase):
    def test_manual_route_executes_the_same_supported_release_admission(self):
        source = (PROJECT / 'tests/zenity-real-session-qualification.sh').read_text(encoding='utf-8')
        case_start = '    case ${ID:-}:${VERSION_ID:-} in\n'
        self.assertEqual(source.count(case_start), 1)
        begin = source.index(case_start)
        end = source.index('    esac\n', begin) + len('    esac\n')
        failure_begin = source.index('fail_test() {\n')
        failure_end = source.index('\n}\n', failure_begin) + len('\n}\n')
        # Execute only the real admission block and its real failure function.
        # This fixture cannot launch the GUI or claim a manual scenario PASS.
        with tempfile.TemporaryDirectory(prefix='zenity-platform-') as temporary:
            script = Path(temporary) / 'admission.sh'
            script.write_text('set -Eeuo pipefail\nID=$1\nVERSION_ID=$2\n'
                              + source[failure_begin:failure_end] + source[begin:end]
                              + 'printf "admitted\\n"\n', encoding='utf-8')
            for distribution, version, expected in (
                ('fedora', '44', 0), ('fedora', '45', 0), ('ubuntu', '24.04', 0),
                ('', '', 65), ('fedora', '', 65), ('fedora', '43', 65),
                ('fedora', '46', 65), ('ubuntu', '22.04', 65), ('debian', '45', 65),
            ):
                with self.subTest(distribution=distribution, version=version):
                    result = subprocess.run(
                        ['bash', '--noprofile', '--norc', str(script), distribution, version],
                        env=dict(os.environ, BASH_ENV='/dev/null'), capture_output=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stdout, b'admitted\n' if expected == 0 else b'')
                    if expected:
                        self.assertIn(b'requires Fedora 44/45 or Ubuntu 24.04', result.stderr)
                    else:
                        self.assertEqual(result.stderr, b'')

    def test_explicit_supported_graphical_releases_are_admitted(self):
        for distribution, version in (('fedora', '44'), ('fedora', '45'), ('ubuntu', '24.04')):
            with self.subTest(distribution=distribution, version=version):
                self.assertEqual(CHECK.qualification_distribution(
                    {'ID': distribution, 'VERSION_ID': '"' + version + '"'}),
                    (distribution, version))

    def test_unknown_or_incomplete_releases_are_not_silently_admitted(self):
        for value in ({}, {'ID': 'fedora'}, {'ID': 'fedora', 'VERSION_ID': '43'},
                      {'ID': 'fedora', 'VERSION_ID': '46'}, {'ID': 'ubuntu', 'VERSION_ID': '22.04'},
                      {'ID': 'debian', 'VERSION_ID': '45'}):
            with self.subTest(os_release=value), self.assertRaisesRegex(ValueError, 'requires Fedora'):
                CHECK.qualification_distribution(value)


class PublicationWitnessTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='zenity-publication-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.parent = self.root / 'gui'
        self.parent.mkdir(mode=0o700)
        self.record = self.parent / 'result.txt'
        self.final = self.root / 'native-remux.mkv'
        self.final.write_bytes(b'unconfirmed native remux bytes')
        self.observer = load_module('result_observer', PROJECT / 'tests/process-observer.py')
        self.child = subprocess.Popen(
            self.child_command(),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(self.stop_child)
        # Popen can return while exec still exposes an empty /proc cmdline.
        # Observe only after this attributed child has initialized itself.
        self.wait_child_message(self.child, b'publication-ready\n')
        self.identity = self.observer.process_row(Path(f'/proc/{self.child.pid}/stat'))
        self.state = {'live': {str(self.child.pid): self.identity}}
        self.witness = CHECK.ResultWitness(self.final, self.observer)
        self.addCleanup(self.witness.close)

    def child_command(self):
        code = "import os, sys; os.write(1, b'publication-ready\\n'); sys.stdin.buffer.read()"
        return [sys.executable, '-I', '-B', '-c', code,
                str(PROJECT / 'download-video.sh'), '--result-file', str(self.record), 'argv-sentinel']

    def wait_child_message(self, child, expected):
        readable, _, _ = select.select([child.stdout], [], [], 5)
        self.assertTrue(readable, 'publication fixture child did not acknowledge initialization')
        self.assertEqual(os.read(child.stdout.fileno(), 4096), expected)

    def stop_child(self, child=None):
        child = self.child if child is None else child
        try:
            child.communicate(input=b'', timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate(timeout=5)

    def test_initializing_child_is_observed_only_after_exec_acknowledgement(self):
        code = ('import os, sys\n'
                'os.write(1, b"initializing\\n")\n'
                'assert sys.stdin.buffer.read(2) == b"go"\n'
                f'os.execv(sys.executable, {self.child_command()!r})\n')
        child = subprocess.Popen([sys.executable, '-I', '-B', '-c', code],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(self.stop_child, child)
        self.wait_child_message(child, b'initializing\n')
        identity = self.observer.process_row(Path(f'/proc/{child.pid}/stat'))
        state = {'live': {str(child.pid): identity}}
        witness = CHECK.ResultWitness(self.final, self.observer)
        self.addCleanup(witness.close)
        self.assertIsNone(child.poll())
        self.assertFalse(witness.observe(state)['result_discovered'])
        os.write(child.stdin.fileno(), b'go')
        self.wait_child_message(child, b'publication-ready\n')
        current = self.observer.process_row(Path(f'/proc/{child.pid}/stat'))
        self.assertEqual(current['start'], identity['start'])
        observed = witness.observe(state)
        self.assertTrue(observed['result_discovered'])
        self.assertFalse(observed['result_published'])

    def publish(self, payload=None):
        temporary = self.parent / 'pending'
        temporary.write_bytes(payload if payload is not None else os.fsencode(self.final) + b'\n')
        temporary.chmod(0o600)
        os.link(temporary, self.record)
        temporary.unlink()

    def test_native_partial_is_not_publication_and_is_never_deleted(self):
        before = self.final.stat()
        payload = self.final.read_bytes()
        observed = self.witness.observe(self.state)
        self.assertTrue(observed['result_discovered'])
        self.assertFalse(observed['result_published'])
        self.assertIsNone(observed['published_ns'])
        self.witness.close()
        self.assertEqual((self.final.stat().st_dev, self.final.stat().st_ino), (before.st_dev, before.st_ino))
        self.assertEqual(self.final.read_bytes(), payload)

    def test_atomic_record_is_observed_and_survives_gui_cleanup(self):
        self.witness.observe(self.state)
        self.publish()
        published = self.witness.refresh()
        self.assertTrue(published['result_published'])
        self.assertGreater(published['published_ns'], 0)
        self.assertEqual(len(published['record_sha256']), 64)
        self.record.unlink()
        self.parent.rmdir()
        self.assertEqual(self.witness.refresh(), published)
        self.assertNotIn('argv-sentinel', json.dumps(published))

    def test_record_payload_mode_and_symlink_are_not_success_evidence(self):
        self.witness.observe(self.state)
        self.publish(b'/different/finished.mkv\n')
        with self.assertRaises(ValueError):
            self.witness.refresh()
        self.record.unlink()
        self.publish()
        self.record.chmod(0o644)
        with self.assertRaises(ValueError):
            self.witness.refresh()
        self.record.unlink()
        self.record.symlink_to(self.final)
        with self.assertRaises((OSError, ValueError)):
            self.witness.refresh()
        self.assertEqual(self.final.read_bytes(), b'unconfirmed native remux bytes')

    def test_pid_identity_mismatch_cannot_read_another_command_line(self):
        state = copy.deepcopy(self.state)
        state['live'][str(self.child.pid)]['start'] += 1
        original = Path.read_bytes

        def read(path):
            if path == Path(f'/proc/{self.child.pid}/cmdline'):
                raise AssertionError('unattributed argv was inspected')
            return original(path)

        with mock.patch.object(Path, 'read_bytes', read):
            observed = self.witness.observe(state)
        self.assertFalse(observed['result_discovered'])
        self.assertFalse(observed['result_published'])

    def test_fifo_result_is_refused_without_waiting_for_a_writer(self):
        os.mkfifo(self.record, 0o600)
        code = '''import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("qualification", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
observer = module.load_module("observer", "process-observer.py")
pid = sys.argv[3]
identity = observer.process_row(pathlib.Path("/proc") / pid / "stat")
witness = module.ResultWitness(pathlib.Path(sys.argv[2]), observer)
try:
    witness.observe({"live": {pid: identity}})
except ValueError:
    sys.exit(0)
finally:
    witness.close()
sys.exit(1)
'''
        completed = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(DRIVER),
                                    str(self.final), str(self.child.pid)],
                                   capture_output=True, text=True, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)


class ManualEvidencePrivacyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (PROJECT / 'tests/zenity-real-session-qualification.sh').read_text()
        start = source.index('    if [[ -d ${SESSION_ROOT}/state ]]; then',
                             source.index('    assert_no_residual_processes "${evidence_dir}"'))
        end = source.index("    printf '\\nGUI process exited", start)
        cls.gate = source[start:end]

    def exercise_gate(self, payload, location='stderr', scanner_failure=False):
        with tempfile.TemporaryDirectory(prefix='manual-privacy-gate-') as temporary:
            root = Path(temporary)
            state, evidence_dir = root / 'state', root / 'evidence'
            state.mkdir(mode=0o700)
            evidence_dir.mkdir(mode=0o700)
            paths = {'stdout': root / 'gui.stdout', 'stderr': root / 'gui.stderr',
                     'state': state / 'download.log'}
            for path in paths.values():
                path.write_bytes(b'Synthetic clean diagnostic\n')
            paths[location].write_bytes(payload)
            program = r'''
set -euo pipefail
SESSION_ROOT=$1
evidence_dir=$SESSION_ROOT/evidence
raw_gui_stdout=$SESSION_ROOT/gui.stdout
raw_gui_stderr=$SESSION_ROOT/gui.stderr
leak_file=$evidence_dir/privacy-findings.txt
state_url_hits=0
: >"${leak_file}"
fail_test() { printf '%s\n' "$1" >&2; exit 65; }
'''
            if scanner_failure:
                program += r'''
scan_failure_path=$2
grep() {
    if [[ ${*: -1} == "${scan_failure_path}" ]]; then
        [[ ${SCAN_FAILURE_OUTPUT} != partial ]] || printf 'partial scanner output\n'
        return 2
    fi
    command grep "$@"
}
'''
                program = 'SCAN_FAILURE_OUTPUT=' + scanner_failure + '\n' + program
            failure_path = state if location == 'state' else paths[location]
            result = subprocess.run(['bash', '-s', '--', str(root), str(failure_path)],
                                    input=program + self.gate, text=True,
                                    capture_output=True, timeout=10)
            exported = [evidence_dir / 'gui.stdout', evidence_dir / 'gui.stderr']
            if scanner_failure or b'SYNTHETIC_PRIVATE_URL' in payload:
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertTrue(all(not path.exists() for path in exported))
                self.assertNotIn('SYNTHETIC_PRIVATE_URL', result.stdout + result.stderr)
                if scanner_failure:
                    self.assertIn('privacy scan', result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(all(path.is_file() for path in exported))
                for name in ('stdout', 'stderr'):
                    self.assertEqual((evidence_dir / ('gui.' + name)).read_bytes(),
                                     paths[name].read_bytes())

    def test_clean_diagnostics_are_preserved(self):
        self.exercise_gate(b'Useful diagnostic, without a URL\n')

    def test_url_case_and_binary_boundaries_are_refused(self):
        for location in ('stdout', 'stderr', 'state'):
            for scheme in (b'https', b'HTTPS', b'hTtPs', b'HTTP'):
                with self.subTest(location=location, scheme=scheme):
                    self.exercise_gate(b'\0\xff' + scheme +
                                       b'://example.invalid/SYNTHETIC_PRIVATE_URL\n', location)

    def test_scanner_error_cannot_authorize_archiving(self):
        for location in ('stdout', 'stderr', 'state'):
            for failure in ('silent', 'partial'):
                with self.subTest(location=location, failure=failure):
                    self.exercise_gate(b'Clean diagnostic\n', location, scanner_failure=failure)


class PrivacyAndCleanupTests(unittest.TestCase):
    def test_private_gui_diagnostics_and_state_gate_artifact_publication(self):
        for location in ('clean', 'diagnostics', 'state'):
            with self.subTest(location=location), tempfile.TemporaryDirectory(prefix='zenity-privacy-') as temporary:
                root = Path(temporary)
                state = root / 'state'
                state.mkdir(mode=0o700)
                private = root / 'private-diagnostics'
                private.mkdir()
                raw = private / 'trial.raw'
                raw.write_bytes(b'bounded diagnostic\n')
                retained = state / 'download.log'
                retained.write_bytes(b'safe retained log\n')
                if location == 'diagnostics':
                    raw.write_bytes(b'HTTP://secret.invalid/private-token\n')
                elif location == 'state':
                    retained.write_bytes(b'https://secret.invalid/private-token\n')
                expected = (location != 'diagnostics', location != 'state')
                self.assertEqual(CHECK.privacy_evidence(root, raw), expected)
                self.assertFalse(raw.exists(), 'private diagnostic escaped qualification cleanup')
                exported = root / 'trial.log'
                self.assertEqual(exported.exists(), location == 'clean')
                if exported.exists():
                    self.assertEqual(exported.read_bytes(), b'bounded diagnostic\n')

    def test_retained_state_symlink_cannot_authorize_clean_evidence(self):
        with tempfile.TemporaryDirectory(prefix='zenity-privacy-') as temporary:
            root = Path(temporary)
            (root / 'state').mkdir(mode=0o700)
            raw = root / 'trial.raw'
            raw.write_bytes(b'clean diagnostic\n')
            (root / 'state/alias').symlink_to(raw)
            with self.assertRaises(ValueError):
                CHECK.privacy_evidence(root, raw)
            self.assertFalse((root / 'trial.log').exists())

    def test_unreadable_state_directory_cannot_be_reported_clean(self):
        with tempfile.TemporaryDirectory(prefix='zenity-privacy-') as temporary:
            root = Path(temporary)
            state = root / 'state'
            state.mkdir(mode=0o700)
            denied = state / 'denied'
            denied.mkdir(mode=0o700)
            (denied / 'download.log').write_bytes(b'https://secret.invalid/private-token\n')
            raw = root / 'trial.raw'
            raw.write_bytes(b'clean diagnostic\n')
            denied_identity = (denied.stat().st_dev, denied.stat().st_ino)
            original = os.scandir

            def deny_scan(path):
                info = os.fstat(path) if isinstance(path, int) else os.stat(path, follow_symlinks=False)
                if (info.st_dev, info.st_ino) == denied_identity:
                    raise PermissionError('injected unreadable fixture directory')
                return original(path)

            # Root bypasses Unix mode bits; inject the same EACCES only at this
            # directory's enumeration boundary, including fd-based traversal.
            boundary = mock.patch.object(os, 'scandir', side_effect=deny_scan) if os.geteuid() == 0 else nullcontext()
            denied.chmod(0)
            try:
                with boundary:
                    with self.assertRaises(PermissionError):
                        with os.scandir(denied) as entries:
                            list(entries)
                    with self.assertRaises((OSError, ValueError)):
                        CHECK.privacy_evidence(root, raw)
                self.assertFalse((root / 'trial.log').exists())
            finally:
                denied.chmod(0o700)

    def test_export_copy_failure_invalidates_both_summary_locations(self):
        with tempfile.TemporaryDirectory(prefix='zenity-export-') as temporary:
            base = Path(temporary)
            root, exported = base / 'private', base / 'exported'
            root.mkdir(mode=0o700)
            exported.mkdir(mode=0o700)
            summary = {'schema': 1, 'passed': True, 'failure': None, 'scenarios': []}
            for directory in (root, exported):
                CHECK.write_json(directory / 'summary.json', summary)
            (root / 'trial.log').write_bytes(b'qualified diagnostic\n')

            def broken_copy(source, destination):
                destination.write(source.read(3))
                raise OSError('injected artifact copy failure')

            with mock.patch.object(CHECK.shutil, 'copyfileobj', side_effect=broken_copy):
                with self.assertRaisesRegex(OSError, 'artifact copy failure'):
                    CHECK.export_evidence(root, exported, summary)
            self.assertEqual((exported / 'trial.log').read_bytes(), b'qua')
            for directory in (root, exported):
                self.assertIs(json.loads((directory / 'summary.json').read_text())['passed'], False)

    def test_export_rollback_interruption_preserves_initial_error_and_invalidates_summaries(self):
        with tempfile.TemporaryDirectory(prefix='zenity-export-') as temporary:
            base = Path(temporary)
            root, exported = base / 'private', base / 'exported'
            root.mkdir(mode=0o700)
            exported.mkdir(mode=0o700)
            (root / 'trial.log').write_bytes(b'qualified diagnostic\n')
            original_write = CHECK.write_json
            primary = OSError(5, 'synthetic original export failure')
            rollback = False

            def failing_write(path, value):
                nonlocal rollback
                if path.name == 'summary.json' and rollback:
                    raise SystemExit(0)
                original_write(path, value)
                if path.name == 'summary.json' and value['passed'] is True:
                    rollback = True
                    raise primary

            summary = {'schema': 1, 'passed': True, 'failure': None, 'scenarios': []}
            with mock.patch.object(CHECK, 'write_json', side_effect=failing_write):
                with self.assertRaises(OSError) as failure:
                    CHECK.export_evidence(root, exported, summary)
            self.assertIs(failure.exception, primary)
            for directory in (root, exported):
                target = directory / 'summary.json'
                self.assertTrue(not target.exists() or json.loads(target.read_text())['passed'] is False)

    def test_export_passing_verdict_follows_complete_artifact_copy(self):
        with tempfile.TemporaryDirectory(prefix='zenity-export-') as temporary:
            base = Path(temporary)
            root, exported = base / 'private', base / 'exported'
            root.mkdir(mode=0o700)
            exported.mkdir(mode=0o700)
            payload = b'qualified diagnostic\n'
            (root / 'trial.log').write_bytes(payload)
            summary = {'schema': 1, 'passed': True, 'failure': None, 'scenarios': []}
            original = CHECK.write_json
            verdicts = []

            def checked_write(path, value):
                if path.name == 'summary.json' and value['passed'] is True:
                    self.assertEqual((exported / 'trial.log').read_bytes(), payload)
                    verdicts.append(path.parent)
                return original(path, value)

            with mock.patch.object(CHECK, 'write_json', side_effect=checked_write):
                CHECK.export_evidence(root, exported, summary)
            self.assertCountEqual(verdicts, [root, exported])
            for directory in (root, exported):
                self.assertIs(json.loads((directory / 'summary.json').read_text())['passed'], True)

    def test_failed_summary_write_cannot_prevent_session_cleanup(self):
        # Exercise main's actual exception/finally route. Admission and graphics
        # are inert; an admitted session still owns a resource when writes fail.
        with tempfile.TemporaryDirectory(prefix='zenity-cleanup-') as temporary:
            root = Path(temporary)
            session = mock.Mock()
            session.env = {}
            events = []
            session.close.side_effect = lambda: events.append('session-closed')
            module = mock.Mock()
            module.Session.return_value = session
            real_write = CHECK.write_json
            real_read = Path.read_text

            def prepare(destination, _shared):
                real_write(destination / 'tools.json', {})

            def write(path, value):
                if path.name == 'summary.json':
                    events.append('summary-write-failed')
                    raise OSError('injected evidence write failure')
                return real_write(path, value)

            def read(path, *args, **kwargs):
                if path == Path('/etc/os-release'):
                    return 'ID=fedora\nVERSION_ID=44\n'
                return real_read(path, *args, **kwargs)

            previous_umask = os.umask(0o077)
            try:
                with mock.patch.object(sys, 'argv', [str(DRIVER)]), \
                        mock.patch.object(CHECK.tempfile, 'mkdtemp', return_value=str(root)), \
                        mock.patch.object(CHECK, 'load_module', return_value=module), \
                        mock.patch.object(CHECK, 'source_identity', return_value={}), \
                        mock.patch.object(CHECK, 'prepare_runtime', side_effect=prepare), \
                        mock.patch.object(CHECK, 'qualification_locale_environment', return_value=dict(os.environ)) as locale_environment, \
                        mock.patch.object(CHECK, 'write_json', side_effect=write), \
                        mock.patch.object(Path, 'read_text', read), \
                        mock.patch.object(CHECK.shutil, 'which', return_value='/unused/tool'), \
                        mock.patch.object(CHECK.subprocess, 'run', side_effect=RuntimeError('injected tool failure')), \
                        redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(CHECK.main(), 1)
                    locale_environment.assert_called_once_with(None)
            finally:
                os.umask(previous_umask)
            self.assertIn('summary-write-failed', events)
            self.assertIn('session-closed', events)
            self.assertLess(events.index('summary-write-failed'), events.index('session-closed'))
            session.close.assert_called_once_with()


class TerminalVerdictTests(unittest.TestCase):
    """Exercise both real CLI entry points with inert, explicit observations."""

    def run_terminal(self, program, case, candidate=None):
        filename = ('multi-instance-real.py' if program == 'multi' else
                    'zenity-autonomous-qualification.py')
        target = Path(candidate) if candidate else PROJECT / 'tests' / filename
        with tempfile.TemporaryDirectory(prefix='terminal-verdict-') as temporary:
            base = Path(temporary)
            retained = base / 'pre-existing.txt'
            retained.write_text('preserve this independent witness')
            fixture = base / 'fixture'
            if program == 'zenity':
                fixture.mkdir(mode=0o700)
            command = [sys.executable, '-I', '-B', str(Path(__file__).resolve()),
                       '--terminal-proof-worker', program, str(target), case, str(fixture)]
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, timeout=20,
                                    env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C.UTF-8'})
            self.assertEqual(retained.read_text(), 'preserve this independent witness')
            root = fixture / 'private' if program == 'zenity' else fixture
            artifacts = {}
            for path in fixture.rglob('*.json'):
                if '.seed.' in path.name or path.name.endswith('.seed.json'):
                    continue
                # Preserve only the records needed by the independent assertions.
                if (path.name in ('summary.json', 'qualification-errors.json', 'main-return.json') or
                        path.name.endswith(('.before-rescue.json', '.final-before-rescue.json',
                                            '.observer-error.json'))):
                    artifacts[path.relative_to(fixture).as_posix()] = json.loads(path.read_text())
            notices = fixture / 'harness-events.json'
            events = json.loads(notices.read_text()) if notices.is_file() else []
            outcome = dict(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr,
                           artifacts=artifacts, events=events, retained=root.is_dir())
            self.assertNotIn('Traceback', result.stderr, result.stderr)
            return outcome

    def assert_terminal_verdict(self, result, passed):
        self.assertEqual(result['returncode'], 0 if passed else 1,
                         result['stdout'] + result['stderr'])
        lines = result['stdout'].splitlines()
        pass_lines = [line for line in lines if line.startswith('PASS:')]
        if passed:
            self.assertTrue(pass_lines, result['stdout'])
            self.assertNotIn('FAIL', result['stdout'] + result['stderr'])
        else:
            self.assertFalse(pass_lines, 'A provisional PASS escaped a failing qualification')
            self.assertIn('FAIL', result['stdout'] + result['stderr'])
        self.assertTrue(result['retained'], 'Uncertain fixture was removed')
        self.assertTrue(any(name.endswith('main-return.json') for name in result['artifacts']),
                        'The real main return was not observed')
        for name, record in result['artifacts'].items():
            if name.endswith('summary.json'):
                self.assertIs(record['passed'], passed, name)
            if name.endswith('main-return.json'):
                self.assertEqual(record['returned'], 0 if passed else 1)

    def test_zenity_complete_program_terminal_matrix(self):
        for case in ('clean', 'final-live', 'final-url', 'earlier-url', 'eacces', 'eio',
                     'missing', 'empty', 'null-fields', 'invalid-identity', 'identity-error',
                     'export-error', 'export-final-write', 'cleanup-error', 'url-and-cleanup',
                     'earlier-and-cleanup', 'final-url-write', 'final-live-write',
                     'systemexit-observation', 'url-and-systemexit-cleanup'):
            with self.subTest(case=case):
                result = self.run_terminal('zenity', case)
                self.assert_terminal_verdict(result, case == 'clean')
                if case == 'clean':
                    self.assertIn('private/summary.json', result['artifacts'])
                    self.assertIn('exported/summary.json', result['artifacts'])
                if case not in ('earlier-url', 'earlier-and-cleanup'):
                    # All 18 scenarios completed the real validator before the
                    # final observation/cleanup injection; none is skipped.
                    summary = result['artifacts']['private/summary.json']
                    self.assertEqual(len(summary['scenarios']), 18)
                    self.assertEqual(sum(event['kind'] == 'result-closed'
                                         for event in result['events']), 18)
                if case == 'final-url':
                    final = result['artifacts']['private/success.final-before-rescue.json']
                    self.assertEqual(final['url_in_argv'], [[70000, 41]])
                    self.assertEqual(final['live'], {})
                if case in ('missing', 'empty', 'null-fields', 'invalid-identity'):
                    final = result['artifacts']['private/success.final-before-rescue.json']
                    self.assertIs(final.get('observation_complete'), False)
                if case == 'url-and-systemexit-cleanup':
                    summary = result['artifacts']['private/summary.json']
                    self.assertEqual(summary['failure'], 'Terminal URL argument exposure.')
                    self.assertEqual(summary['errors'][0]['phase'], summary['failure'])
                    self.assertGreaterEqual(len(summary['errors']), 2)
                if case in ('final-url-write', 'final-live-write'):
                    summary = result['artifacts']['private/summary.json']
                    expected = ('Terminal URL argument exposure.' if case == 'final-url-write' else
                                'Live process residue before rescue.')
                    self.assertEqual(summary['failure'], expected)
                    self.assertEqual(summary['errors'][0]['phase'], summary['failure'])
                if case == 'earlier-and-cleanup':
                    summary = result['artifacts']['private/summary.json']
                    self.assertEqual(summary['failure'], summary['errors'][0]['phase'])
                    self.assertGreaterEqual(len(summary['errors']), 2)

    def test_multi_complete_program_terminal_matrix(self):
        for case in ('clean', 'final-live', 'final-url', 'previous-url', 'eacces', 'eio',
                     'missing', 'empty', 'identity-mismatch', 'initial-error',
                     'export-error', 'cleanup-error', 'previous-incomplete',
                     'initial-and-cleanup', 'final-live-write', 'systemexit-observation',
                     'url-and-systemexit-cleanup'):
            with self.subTest(case=case):
                result = self.run_terminal('multi', case)
                self.assert_terminal_verdict(result, case == 'clean')
                failures = result['artifacts']['qualification-errors.json']
                if case == 'clean':
                    self.assertEqual(failures, [])
                else:
                    expected = {
                        'final-live': 'terminal-live', 'final-url': 'terminal-url',
                        'previous-url': 'scenario', 'previous-incomplete': 'scenario',
                        'eacces': 'terminal-observation', 'eio': 'terminal-observation',
                        'missing': 'terminal-observation', 'empty': 'terminal-observation',
                        'identity-mismatch': 'terminal-live', 'initial-error': 'scenario',
                        'export-error': 'evidence-export', 'cleanup-error': 'server-shutdown',
                        'initial-and-cleanup': 'scenario', 'final-live-write': 'terminal-live',
                        'systemexit-observation': 'terminal-observation',
                        'url-and-systemexit-cleanup': 'terminal-url',
                    }[case]
                    self.assertTrue(failures, case)
                    self.assertEqual(failures[0]['phase'], expected)
                if case == 'initial-and-cleanup':
                    self.assertEqual([row['phase'] for row in failures], ['scenario', 'server-shutdown'])
                if case == 'final-live-write':
                    self.assertEqual([row['phase'] for row in failures][:2],
                                     ['terminal-live', 'terminal-evidence'])
                if case == 'url-and-systemexit-cleanup':
                    self.assertEqual([row['phase'] for row in failures][:2],
                                     ['terminal-url', 'server-shutdown'])
                if case == 'identity-mismatch':
                    self.assertIn('rescue-identity-changed', [row['phase'] for row in failures])
                if case == 'final-url':
                    final = result['artifacts']['cycle0-A.final-before-rescue.json']
                    self.assertEqual(final['url_in_argv'], [[810000, 111]])
                if case == 'clean':
                    finals = [name for name in result['artifacts']
                              if name.endswith('.final-before-rescue.json') and not name.startswith('evidence/')]
                    self.assertGreaterEqual(len(finals), 20)

    def test_terminal_verdict_mutations_are_detected_by_the_relevant_oracle(self):
        original = DRIVER.read_text(encoding='utf-8')
        changes = (
            ('omit-live', "live_residue = (rescue is not None and bool(rescue['live'])) or process.poll() is None",
             'live_residue = process.poll() is None', 'final-live', 'returncode'),
            ('omit-url', "if state is not None and state['url_in_argv']:",
             'if False:', 'final-url', 'returncode'),
            ('error-as-success', "record_failure('Terminal process observation failed.', error)",
             'pass', 'eacces', 'returncode'),
            ('omit-observation', 'observed = watch.finish()',
             'observed = watch.last', 'final-url', 'returncode'),
            ('miss-system-exit', "except BaseException as error:\n            record_failure('Fixture server cleanup failed.', error)",
             "except Exception as error:\n            record_failure('Fixture server cleanup failed.', error)",
             'url-and-systemexit-cleanup', 'returncode'),
            ('force-zero', 'return 0 if passed else 1', 'return 0', 'final-url', 'returncode'),
            ('missing-as-empty', 'observed = watch.finish()',
             "observed = watch.finish() or dict(monotonic_ns=1, live={}, zombies=[], url_in_argv=[])",
             'missing', 'returncode'),
            ('cleanup-rehabilitates', '    if passed:\n        for row in rows:',
             '    passed = True\n    if passed:\n        for row in rows:', 'earlier-url', 'returncode'),
            ('early-pass', '        passed = True\n    except BaseException as error:',
             "        passed = True\n        print('PASS: premature fixture verdict', flush=True)\n"
             '    except BaseException as error:', 'final-url', 'message'),
        )
        for name, before, after, case, oracle in changes:
            with self.subTest(mutation=name), tempfile.TemporaryDirectory(prefix='terminal-mutant-') as temporary:
                self.assertEqual(original.count(before), 1, name)
                mutant = original.replace(before, after)
                compile(mutant, '<terminal-mutant>', 'exec')
                target = Path(temporary) / DRIVER.name
                target.write_text(mutant, encoding='utf-8')
                result = self.run_terminal('zenity', case, target)
                if oracle == 'returncode':
                    self.assertEqual(result['returncode'], 0,
                                     'Mutation did not reach its intended false-success path: ' +
                                     result['stdout'] + result['stderr'])
                else:
                    self.assertEqual(result['returncode'], 1)
                    self.assertIn('PASS: premature fixture verdict', result['stdout'])
                with self.assertRaises(AssertionError):
                    self.assert_terminal_verdict(result, False)


    def test_multi_mutations_preserve_the_real_exit_status_oracle(self):
        driver = PROJECT / 'tests/multi-instance-real.py'
        original = driver.read_text(encoding='utf-8')
        observed = "            state = terminal_observation(obs.sample())\n        except BaseException as error:"
        changes = (
            ('omit-live', "            if state['live']:\n                qualification_failure(failures, 'terminal-live', label)",
             '            if False:\n                pass', 'final-live', 'returncode'),
            ('omit-url', "            if state['url_in_argv']:\n                qualification_failure(failures, 'terminal-url', label)",
             '            if False:\n                pass', 'final-url', 'returncode'),
            ('error-as-success', "            qualification_failure(failures, 'terminal-observation', label, error)",
             '            pass', 'eacces', 'returncode'),
            ('omit-observation', observed,
             "            state = dict(monotonic_ns=1, live={}, zombies=[], url_in_argv=[])\n"
             '        except BaseException as error:', 'final-url', 'returncode'),
            ('miss-system-exit', "except BaseException as error:\n            qualification_failure(failures, 'terminal-observation', label, error)",
             "except Exception as error:\n            qualification_failure(failures, 'terminal-observation', label, error)",
             'systemexit-observation', 'returncode'),
            ('force-zero', '    sys.exit(main())', '    main()', 'final-url', 'returncode'),
            ('missing-as-empty', observed,
             "            state = terminal_observation(obs.sample() or dict(monotonic_ns=1, live={}, zombies=[], url_in_argv=[]))\n"
             '        except BaseException as error:', 'missing', 'returncode'),
            ('cleanup-rehabilitates', '    if succeeded and not failures:',
             '    failures.clear()\n    if succeeded and not failures:', 'eacces', 'returncode'),
            ('early-pass', '        succeeded = True\n    except BaseException as error:',
             "        succeeded = True\n        print('PASS: premature fixture verdict', flush=True)\n"
             '    except BaseException as error:', 'final-url', 'message'),
        )
        for name, before, after, case, oracle in changes:
            with self.subTest(mutation=name), tempfile.TemporaryDirectory(prefix='terminal-mutant-') as temporary:
                self.assertEqual(original.count(before), 1, name)
                mutant = original.replace(before, after)
                compile(mutant, '<terminal-mutant>', 'exec')
                directory = Path(temporary) / 'tests'
                directory.mkdir()
                target = directory / driver.name
                target.write_text(mutant, encoding='utf-8')
                (directory / 'process-observer.py').write_bytes((PROJECT / 'tests/process-observer.py').read_bytes())
                result = self.run_terminal('multi', case, target)
                if oracle == 'returncode':
                    self.assertEqual(result['returncode'], 0,
                                     'Mutation did not reach its intended false-success path: ' +
                                     result['stdout'] + result['stderr'])
                else:
                    self.assertEqual(result['returncode'], 1)
                    self.assertIn('PASS: premature fixture verdict', result['stdout'])
                with self.assertRaises(AssertionError):
                    self.assert_terminal_verdict(result, False)


if __name__ == '__main__':
    if len(sys.argv) == 6 and sys.argv[1] == '--terminal-proof-worker':
        fixtures = load_module('terminal_proof_fixtures', PROJECT / 'tests/terminal-proof-fixtures.py')
        program, target, case, workspace = sys.argv[2:]
        if program == 'multi':
            fixtures.run_multi(Path(target), case, Path(workspace))
        elif program == 'zenity':
            fixtures.run_zenity(Path(target), case, Path(workspace), evidence, event)
        else:
            raise ValueError('Unknown synthetic terminal witness')
    else:
        unittest.main()
