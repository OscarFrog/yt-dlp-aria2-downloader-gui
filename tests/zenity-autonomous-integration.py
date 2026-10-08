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
            [sys.executable, '-I', '-B', '-c', 'import sys; sys.stdin.buffer.read()',
             str(PROJECT / 'download-video.sh'), '--result-file', str(self.record), 'argv-sentinel'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(self.stop_child)
        self.identity = self.observer.process_row(Path(f'/proc/{self.child.pid}/stat'))
        self.state = {'live': {str(self.child.pid): self.identity}}
        self.witness = CHECK.ResultWitness(self.final, self.observer)
        self.addCleanup(self.witness.close)

    def stop_child(self):
        try:
            self.child.communicate(input=b'', timeout=5)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.communicate(timeout=5)

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
                        mock.patch.object(CHECK, 'write_json', side_effect=write), \
                        mock.patch.object(Path, 'read_text', read), \
                        mock.patch.object(CHECK.shutil, 'which', return_value='/unused/tool'), \
                        mock.patch.object(CHECK.subprocess, 'run', side_effect=RuntimeError('injected tool failure')), \
                        redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(CHECK.main(), 1)
            finally:
                os.umask(previous_umask)
            self.assertIn('summary-write-failed', events)
            self.assertIn('session-closed', events)
            self.assertLess(events.index('summary-write-failed'), events.index('session-closed'))
            session.close.assert_called_once_with()


if __name__ == '__main__':
    unittest.main()
