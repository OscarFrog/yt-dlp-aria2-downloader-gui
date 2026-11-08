# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/process-observer.py.

Observe one qualification's inherited marker and process identities, without
signaling or reaping the application. No arguments or environment are retained.
"""

import argparse
from contextvars import ContextVar
import errno
import json
import os
from pathlib import Path
import select
import sys
import time
from types import FunctionType, MethodDescriptorType, MethodType, WrapperDescriptorType
import uuid


class ObservationError(OSError):
    """An attributed process could not be observed; no private data is kept."""


_DIAGNOSTIC_SCOPE = ContextVar('observer_diagnostic_scope', default=None)
_GROUP_EXIT_PROOFS = ContextVar('observer_group_exit_proofs', default=None)
_DIAGNOSTIC_KEY = '_qualification_observer_diagnostic'
_EXCEPTION_DICT = BaseException.__dict__['__dict__']
_MAX_DIAGNOSTIC_EVENTS = 32
_OPERATIONS = frozenset(('stat_read', 'stat_fields', 'stat_start', 'stat_state',
                         'stat_parent', 'stat_group', 'stat_session', 'attribute_read',
                         'task_inventory', 'process_inventory', 'identity_guard',
                         'inventory_guard', 'error_normalization', 'error_input',
                         'error_errno', 'sample', 'pidfd_open', 'pidfd_poll',
                         'pidfd_close', 'pidfd_guard', 'pidfd_scope',
                         'pidfd_fdinfo_open', 'pidfd_fdinfo_read', 'pidfd_fdinfo_close'))
_PHASES = frozenset(('identity_before', 'task_stat_before', 'attribute_read',
                    'task_stat_after', 'identity_after', 'task_inventory',
                    'quiescence_check', 'argument_inspection', 'environment_inspection',
                    'error_normalization', 'snapshot', 'unknown'))
_CLASSES = (ObservationError, PermissionError, FileNotFoundError, ProcessLookupError,
            InterruptedError, OSError, ValueError, IndexError)
_CLASS_NAMES = ('ObservationError', 'PermissionError', 'FileNotFoundError',
                'ProcessLookupError', 'InterruptedError', 'OSError', 'ValueError', 'IndexError')
_EVENT_KEYS = frozenset(('sequence', 'monotonic_ns', 'component', 'operation', 'phase',
                         'exception_class', 'primitive_errno', 'errno_state',
                         'normalized_errno', 'normalization_applied', 'attribution_source',
                         'identity_verified', 'first_failure', 'relation', 'cause_sequence'))

# Identity diagnostics are a separate, explicitly enabled protocol. Their raw
# coordinates are private: only IdentityProjection produces exportable aliases.
_IDENTITY_KEY = '_qualification_observer_identity'
_IDENTITY_OPERATIONS = _OPERATIONS | {'attribute_open', 'attribute_close', 'attribute_enter',
                                    'attribute_lookup', 'attribute_opaque'}
_PATH_READ_BYTES = Path.read_bytes
_TYPE_NAMESPACE = type.__dict__['__dict__']
_TYPE_BASES = type.__dict__['__mro__']
_IDENTITY_ORIGINS = frozenset(('system_operation', 'application_identity_check',
                              'application_state_check', 'application_parse', 'unknown'))
_IDENTITY_SLOTS = ('group_expected', 'group_selected', 'group_before', 'group_after',
                   'group_revalidation', 'task_selected', 'task_before', 'task_after',
                   'parent_snapshot', 'task_inventory', 'task_revalidation', 'group_quiescence')
_IDENTITY_CHECKS = ('group_match_before', 'group_match_after', 'task_match_after',
                    'group_match_revalidation')
_IDENTITY_CONTEXT_KEYS = frozenset(_IDENTITY_SLOTS + _IDENTITY_CHECKS + (
    'parent_relation', 'parent_temporal_verified', 'quiescence', 'attributed', 'observation_resource'))
_PRIVATE_IDENTITY_KEYS = frozenset(('kind', 'pid', 'tgid', 'tid', 'starttime',
                                  'group_starttime', 'state', 'ppid', 'pgid', 'sid',
                                  'source', 'namespace', 'group_binding'))
_PUBLIC_IDENTITY_KEYS = frozenset(('kind', 'reference', 'group_reference',
                                 'starttime_known', 'state', 'source', 'namespace', 'group_binding'))
_IDENTITY_EVENT_KEYS = _EVENT_KEYS | {'primitive_origin', 'resource_kind',
                                    'kernel_return_proven', 'context'}
_IDENTITY_STATES = frozenset(('R', 'S', 'D', 'Z', 'X', 'x', 'T', 't', 'W', 'K', 'P', 'I'))
_MAX_IDENTITY_ALIASES = 512


def _closed_keys(value, expected):
    if (type(value) is not dict or len(value) != len(expected)
            or any(type(key) is not str or len(key) > 64 for key in value)
            or set(value) != expected):
        raise ValueError('invalid identity diagnostic structure')


def _closed_choice(value, allowed):
    if type(value) is not str or len(value) > 64 or value not in allowed:
        raise ValueError('invalid identity diagnostic category')


def _closed_integer(value, low=0, high=9223372036854775807):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('invalid identity diagnostic integer')


def _identity_reference(value, kind=None):
    if value is None:
        return
    if (type(value) is not str or not 2 <= len(value) <= 4
            or value[0] not in ('g', 't') or not value[1:].isascii()
            or not value[1:].isdecimal() or not 1 <= int(value[1:]) <= _MAX_IDENTITY_ALIASES
            or value[1:] != str(int(value[1:]))
            or (kind is not None and value[0] != ('g' if kind == 'group' else 't'))):
        raise ValueError('invalid identity diagnostic reference')


def _copy_identity(value, public=False):
    if value is None:
        return None
    _closed_keys(value, _PUBLIC_IDENTITY_KEYS if public else _PRIVATE_IDENTITY_KEYS)
    _closed_choice(value['kind'], {'group', 'task'})
    _closed_choice(value['group_binding'], {'self' if value['kind'] == 'group' else 'expected_group'})
    _closed_choice(value['source'], {'procfs_path', 'procfs_path_stat'})
    _closed_choice(value['namespace'], {'unknown'})
    if value['state'] is not None:
        _closed_choice(value['state'], _IDENTITY_STATES)
    if public:
        _identity_reference(value['reference'], value['kind'])
        _identity_reference(value['group_reference'], 'group')
        if type(value['starttime_known']) is not bool:
            raise ValueError('invalid identity diagnostic certainty')
        if not value['starttime_known'] and value['reference'] is not None:
            raise ValueError('unresolved identity has a stable reference')
        if value['kind'] == 'group' and value['reference'] != value['group_reference']:
            raise ValueError('inconsistent public leader reference')
    else:
        for key in ('pid', 'tgid', 'tid', 'ppid', 'pgid', 'sid'):
            if value[key] is not None:
                _closed_integer(value[key], 1 if key in ('pid', 'tgid', 'tid') else 0, 2147483647)
        for key in ('starttime', 'group_starttime'):
            if value[key] is not None:
                _closed_integer(value[key])
        if value['pid'] != value['tgid']:
            raise ValueError('inconsistent group path identity')
        if value['kind'] == 'group' and (value['tid'] != value['tgid']
                                        or value['starttime'] != value['group_starttime']):
            raise ValueError('inconsistent leader identity')
    return dict(value)


def _copy_identity_context(value, public=False):
    _closed_keys(value, _IDENTITY_CONTEXT_KEYS)
    copied = {key: _copy_identity(value[key], public) for key in _IDENTITY_SLOTS}
    for key in _IDENTITY_CHECKS:
        _closed_choice(value[key], {'unknown', 'same', 'different', 'missing'})
        copied[key] = value[key]
    _closed_choice(value['parent_relation'], {'none', 'snapshot_ppid_only'})
    _closed_choice(value['observation_resource'], {'environ', 'cmdline', 'unknown'})
    _closed_choice(value['quiescence'], {'unknown', 'true', 'false'})
    if value['parent_temporal_verified'] is not False or type(value['attributed']) is not bool:
        raise ValueError('unsupported identity attribution guarantee')
    copied.update(parent_relation=value['parent_relation'], parent_temporal_verified=False,
                  quiescence=value['quiescence'], attributed=value['attributed'],
                  observation_resource=value['observation_resource'])
    return copied


def _copy_identity_packet(payload, public):
    expected = {'schema', 'view', 'complete', 'omitted', 'events'}
    if public:
        expected.add('scope_id')
    _closed_keys(payload, expected)
    _closed_integer(payload['schema'], 2, 2)
    _closed_choice(payload['view'], {'public' if public else 'private'})
    if type(payload['complete']) is not bool:
        raise ValueError('invalid identity diagnostic completeness')
    _closed_integer(payload['omitted'], 0, 2147483647)
    if public:
        scope_id = payload['scope_id']
        if (type(scope_id) is not str or len(scope_id) != 32
                or any(char not in '0123456789abcdef' for char in scope_id)):
            raise ValueError('invalid qualification diagnostic scope')
    rows = payload['events']
    if type(rows) is not list or len(rows) > _MAX_DIAGNOSTIC_EVENTS:
        raise ValueError('invalid identity diagnostic bound')
    if payload['complete'] and (not rows or payload['omitted']):
        raise ValueError('incomplete identity diagnostic marked complete')
    copied = []
    for index, row in enumerate(rows, 1):
        _closed_keys(row, _IDENTITY_EVENT_KEYS)
        _closed_choice(row['operation'], _IDENTITY_OPERATIONS)
        _closed_choice(row['relation'], {'primitive', 'retry', 'revalidation', 'quiescence',
                                        'normalization', 'close'})
        _closed_choice(row['primitive_origin'], _IDENTITY_ORIGINS)
        _closed_choice(row['resource_kind'], {'environ', 'cmdline', 'stat', 'task_inventory',
                                             'proc_inventory', 'pidfd', 'unknown'})
        if row['kernel_return_proven'] is not False:
            raise ValueError('unsupported kernel provenance claim')
        # Reuse the closed V1 scalar validation, with the V2 operation projected
        # to its V1 boundary only for validation. The output retains its detail.
        base = {key: row[key] for key in _EVENT_KEYS}
        if base['operation'] in ('attribute_open', 'attribute_close', 'attribute_enter',
                                 'attribute_lookup', 'attribute_opaque'):
            base['operation'] = 'attribute_read'
        if base['relation'] == 'close':
            base['relation'] = 'revalidation'
        base['sequence'], base['first_failure'], base['cause_sequence'] = 1, True, None
        copy_diagnostic(dict(schema=1, complete=False, omitted=0, events=[base]))
        _closed_integer(row['sequence'], index, index)
        if row['first_failure'] is not (index == 1):
            raise ValueError('invalid identity first event')
        if row['cause_sequence'] is not None:
            _closed_integer(row['cause_sequence'], 1, index - 1)
        item = dict(row)
        item['context'] = _copy_identity_context(row['context'], public)
        if public and not item['context']['attributed'] and any(
                item['context'][key] is not None for key in _IDENTITY_SLOTS):
            raise ValueError('unattributed identity cannot be exported')
        copied.append(item)
    result = dict(schema=2, view='public' if public else 'private',
                  complete=payload['complete'], omitted=payload['omitted'], events=copied)
    if public:
        result['scope_id'] = payload['scope_id']
    return result


def copy_identity_diagnostic(payload):
    """Copy bounded numeric metadata for private storage only."""
    return _copy_identity_packet(payload, False)


def copy_identity_export(payload):
    """Copy a closed public packet; numeric process coordinates are forbidden."""
    return _copy_identity_packet(payload, True)


class IdentityProjection:
    """One qualification's bounded aliases; never a signaling authority.

    The caller persists the paired private/public packets before publishing the
    public one. Correlation needs no extra procfs reads or identity decisions.
    """
    def __init__(self):
        self.scope_id = uuid.uuid4().hex
        self.groups = {}
        self.tasks = {}

    def _alias(self, identity):
        group_key = (identity['tgid'], identity['group_starttime'])
        group = None
        if None not in group_key:
            if group_key not in self.groups:
                if len(self.groups) + len(self.tasks) >= _MAX_IDENTITY_ALIASES:
                    raise ValueError('identity diagnostic alias bound exceeded')
                self.groups[group_key] = 'g' + str(len(self.groups) + 1)
            group = self.groups[group_key]
        reference = group if identity['kind'] == 'group' else None
        if identity['kind'] == 'task' and identity['tid'] is not None and identity['starttime'] is not None:
            key = (identity['tgid'], identity['group_starttime'], identity['tid'], identity['starttime'])
            if key not in self.tasks:
                if len(self.groups) + len(self.tasks) >= _MAX_IDENTITY_ALIASES:
                    raise ValueError('identity diagnostic alias bound exceeded')
                self.tasks[key] = 't' + str(len(self.tasks) + 1)
            reference = self.tasks[key]
        return dict(kind=identity['kind'], reference=reference, group_reference=group,
                    starttime_known=identity['starttime'] is not None, state=identity['state'],
                    source=identity['source'], namespace='unknown', group_binding=identity['group_binding'])

    def project(self, packet):
        private = copy_identity_diagnostic(packet)
        result = dict(private, view='public', scope_id=self.scope_id)
        for event in result['events']:
            context = event['context']
            expected = context['group_expected']
            for key in _IDENTITY_SLOTS:
                identity = context[key]
                admitted = context['attributed'] and expected is not None and identity is not None
                if admitted and identity['kind'] == 'group' and key != 'parent_snapshot':
                    # A replaced group was observed, but never thereby attributed.
                    # Preserve the comparison and private coordinates, not a new
                    # public alias/state for that unrelated process identity.
                    admitted = ((identity['tgid'], identity['starttime'])
                                == (expected['tgid'], expected['starttime']))
                if admitted and identity['kind'] == 'task':
                    admitted = ((identity['tgid'], identity['group_starttime'])
                                == (expected['tgid'], expected['starttime']))
                context[key] = self._alias(identity) if admitted else None
            if not context['attributed']:
                context['parent_relation'] = 'none'
        return copy_identity_export(result)


def _empty_identity_context():
    result = dict.fromkeys(_IDENTITY_SLOTS)
    result.update(dict.fromkeys(_IDENTITY_CHECKS, 'unknown'))
    result.update(parent_relation='none', parent_temporal_verified=False,
                  quiescence='unknown', attributed=False, observation_resource='unknown')
    return result


def _identity_scope():
    scope = _DIAGNOSTIC_SCOPE.get()
    return scope if scope is not None and scope.owner.identity_diagnostics_enabled else None


def _empty_identity_diagnostic():
    return dict(schema=2, view='private', complete=False, omitted=0, events=[])


def _identity_capsule(error, owner=None):
    mapping = _exception_mapping(error)
    value = dict.get(mapping, _IDENTITY_KEY)
    if value is None:
        return None
    _closed_keys(value, {'packet', 'origin', 'owner'})
    scope = _identity_scope()
    expected = owner if owner is not None else scope.owner._diagnostic_identity if scope is not None else None
    if value['owner'] is not expected:
        return None
    packet = copy_identity_diagnostic(value['packet'])
    _closed_integer(value['origin'], 1, len(packet['events']))
    return dict(packet=packet, origin=value['origin'])


def _identity_store(error, capsule):
    mapping = _exception_mapping(error)
    if len(mapping) == 32 and _IDENTITY_KEY not in mapping:
        raise ValueError('observer exception metadata is full')
    capsule['owner'] = _identity_scope().owner._diagnostic_identity
    dict.__setitem__(mapping, _IDENTITY_KEY, capsule)


def _identity_origin(operation):
    if operation in ('stat_read', 'attribute_open', 'attribute_read', 'attribute_close',
                     'attribute_enter', 'task_inventory', 'process_inventory',
                     'pidfd_open', 'pidfd_poll', 'pidfd_close', 'pidfd_fdinfo_open',
                     'pidfd_fdinfo_read', 'pidfd_fdinfo_close'):
        return 'system_operation'
    if operation in ('stat_fields', 'stat_start', 'stat_state', 'stat_parent', 'stat_group', 'stat_session'):
        return 'application_parse'
    return 'unknown'


def _identity_note(error, operation, phase=None, origin=None):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        if _identity_capsule(error) is not None:
            return
        category, number, errno_state = _error_metadata(error)
        primitive_origin = _identity_origin(operation) if origin is None else origin
        resource = scope.identity_resource
        if operation.startswith('stat_'):
            resource = 'stat'
        elif operation == 'task_inventory':
            resource = 'task_inventory'
        elif operation == 'process_inventory':
            resource = 'proc_inventory'
        elif operation.startswith('pidfd_'):
            resource = 'pidfd'
        event = dict(sequence=1, monotonic_ns=time.monotonic_ns(), component='observer',
                     operation=operation, phase=scope.phase if phase is None else phase,
                     exception_class=category, primitive_errno=number, errno_state=errno_state,
                     normalized_errno=None, normalization_applied=False,
                     attribution_source=scope.attribution, identity_verified='unknown', first_failure=True,
                     relation='primitive', cause_sequence=None, primitive_origin=primitive_origin,
                     resource_kind=resource, kernel_return_proven=False,
                     context=_copy_identity_context(scope.identity_context))
        complete = (not scope.owner.diagnostics_incomplete and errno_state != 'unavailable'
                    and primitive_origin != 'unknown')
        packet = copy_identity_diagnostic(dict(schema=2, view='private', complete=complete,
                                               omitted=0, events=[event]))
        _identity_store(error, dict(packet=packet, origin=1))
    except BaseException:
        scope.failed()


def _identity_link(initial, secondary, relation, retain_initial=False):
    scope = _identity_scope()
    if scope is None or initial is secondary:
        return
    try:
        _identity_note(initial, 'error_input', 'error_normalization')
        _identity_note(secondary, 'error_input', 'error_normalization')
        first, later = _identity_capsule(initial), _identity_capsule(secondary)
        if first is None or later is None:
            scope.failed()
            return
        packet = first['packet']
        offset = len(packet['events'])
        for index, event in enumerate(later['packet']['events']):
            event['sequence'] += offset
            event['first_failure'] = False
            if event['cause_sequence'] is not None:
                event['cause_sequence'] += offset
            if index == 0:
                event['relation'] = relation
            if len(packet['events']) < _MAX_DIAGNOSTIC_EVENTS:
                packet['events'].append(event)
            else:
                packet['omitted'] = min(2147483647, packet['omitted'] + 1)
        packet['omitted'] = min(2147483647, packet['omitted'] + later['packet']['omitted'])
        packet['complete'] = packet['complete'] and later['packet']['complete'] and not packet['omitted']
        origin = first['origin'] if retain_initial else later['origin'] + offset
        if origin > len(packet['events']):
            origin = first['origin']
            packet['complete'] = False
        _identity_store(initial if retain_initial else secondary,
                        dict(packet=copy_identity_diagnostic(packet), origin=origin))
    except BaseException:
        scope.failed()


def _identity_normalized(initial, result, number, applied):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        _identity_note(initial, 'error_input', 'error_normalization')
        capsule = _identity_capsule(initial)
        if capsule is None:
            scope.failed()
            return
        packet = capsule['packet']
        for event in packet['events']:
            _identity_attribute_context(event['context'], scope)
            if event['context']['attributed'] and event['attribution_source'] == 'unknown':
                event['attribution_source'] = scope.attribution
        projected = int(number) if type(number) is bool else number
        if type(projected) is not int or not -2147483648 <= projected <= 2147483647:
            projected = None
            packet['complete'] = False
        if len(packet['events']) == _MAX_DIAGNOSTIC_EVENTS:
            packet['complete'] = False
            packet['omitted'] = min(2147483647, packet['omitted'] + 1)
        else:
            # Cleanup can fail on several groups. Normalize the explicit
            # cause, not the last handle whose diagnostic scope was active.
            cause = packet['events'][capsule['origin'] - 1]
            context = _copy_identity_context(cause['context'])
            packet['events'].append(dict(
                sequence=len(packet['events']) + 1, monotonic_ns=time.monotonic_ns(),
                component='observer', operation='error_normalization', phase='error_normalization',
                exception_class='ObservationError', primitive_errno=None,
                errno_state='boolean' if type(number) is bool else 'none',
                normalized_errno=projected, normalization_applied=applied,
                attribution_source=cause['attribution_source'], identity_verified='unknown', first_failure=False,
                relation='normalization', cause_sequence=capsule['origin'], primitive_origin='unknown',
                resource_kind=cause['resource_kind'], kernel_return_proven=False, context=context))
        packet['complete'] = packet['complete'] and not scope.owner.diagnostics_incomplete
        _identity_store(result, dict(packet=copy_identity_diagnostic(packet), origin=len(packet['events'])))
    except BaseException:
        scope.failed()


def _identity_repeated_close(error):
    # Re-raising the very same exception object is still a second failing
    # operation. Never overwrite its earlier read metadata with close metadata.
    scope = _identity_scope()
    if scope is None:
        return
    try:
        capsule = _identity_capsule(error)
        if capsule is None:
            _identity_note(error, 'attribute_close', 'attribute_read')
            return
        packet = capsule['packet']
        if len(packet['events']) == _MAX_DIAGNOSTIC_EVENTS:
            packet['omitted'] = min(2147483647, packet['omitted'] + 1)
            packet['complete'] = False
        else:
            category, number, errno_state = _error_metadata(error)
            packet['events'].append(dict(
                sequence=len(packet['events']) + 1, monotonic_ns=time.monotonic_ns(),
                component='observer', operation='attribute_close', phase='attribute_read',
                exception_class=category, primitive_errno=number, errno_state=errno_state,
                normalized_errno=None, normalization_applied=False,
                attribution_source=scope.attribution, identity_verified='unknown', first_failure=False,
                relation='close', cause_sequence=capsule['origin'], primitive_origin='system_operation',
                resource_kind=scope.identity_resource, kernel_return_proven=False,
                context=_copy_identity_context(scope.identity_context)))
            packet['complete'] = packet['complete'] and errno_state != 'unavailable'
            capsule['origin'] = len(packet['events'])
        _identity_store(error, dict(packet=copy_identity_diagnostic(packet), origin=capsule['origin']))
    except BaseException:
        scope.failed()


def _identity_row(pid, tid, row, group_start, kind):
    _closed_integer(pid, 1, 2147483647)
    _closed_integer(tid, 1, 2147483647)
    if row is not None:
        _closed_keys(row, {'start', 'state', 'parent', 'group', 'session'})
    result = dict(kind=kind, pid=pid, tgid=pid, tid=tid,
                  starttime=row['start'] if row is not None else None,
                  group_starttime=group_start, state=row['state'] if row is not None else None,
                  ppid=row['parent'] if row is not None else None,
                  pgid=row['group'] if row is not None else None,
                  sid=row['session'] if row is not None else None,
                  source='procfs_path_stat' if row is not None else 'procfs_path', namespace='unknown',
                  group_binding='self' if kind == 'group' else 'expected_group')
    return _copy_identity(result)


def _identity_attribute_context(context, scope):
    expected = context['group_expected']
    attribution = scope.identity_attribution
    if (attribution is not None and expected is not None
            and (expected['tgid'], expected['starttime']) == attribution['key']):
        context['attributed'] = True
        if attribution['parent'] is not None:
            context['parent_snapshot'] = _copy_identity(attribution['parent'])
            context['parent_relation'] = 'snapshot_ppid_only'


def _identity_begin(pid, row, resource):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        scope.identity_context = _empty_identity_context()
        scope.identity_resource = resource if type(resource) is str and resource in ('environ', 'cmdline') else 'unknown'
        scope.identity_context['observation_resource'] = scope.identity_resource
        scope.identity_context['group_expected'] = _identity_row(pid, pid, row, row['start'], 'group')
        _identity_attribute_context(scope.identity_context, scope)
    except BaseException:
        scope.failed()


def _identity_capture(slot, pid, tid, row, *, kind='group'):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        if row is None and kind == 'group':
            scope.identity_context[slot] = None
            return
        expected = scope.identity_context['group_expected']
        group_start = row['start'] if kind == 'group' and row is not None else (
            expected['starttime'] if expected is not None else None)
        scope.identity_context[slot] = _identity_row(pid, tid, row, group_start, kind)
    except BaseException:
        scope.failed()


def _identity_check(key, value):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        _closed_choice(value, {'unknown', 'same', 'different', 'missing', 'true', 'false'})
        if key not in _IDENTITY_CHECKS and key != 'quiescence':
            raise ValueError('invalid identity check')
        scope.identity_context[key] = value
    except BaseException:
        scope.failed()


def _identity_path(pid, row, path):
    """Read only bounded path coordinates; never retain or format a full path."""
    scope = _identity_scope()
    if scope is None:
        return None
    try:
        parts = path.parts
        if (type(parts) is not tuple or len(parts) not in (4, 6)
                or any(type(part) is not str or len(part) > 32 for part in parts)
                or parts[:2] != ('/', 'proc') or not parts[2].isascii()
                or not parts[2].isdecimal() or int(parts[2]) != pid
                or parts[-1] not in ('environ', 'cmdline')):
            raise ValueError('unsupported diagnostic resource path')
        if len(parts) == 6:
            if parts[3] != 'task' or not parts[4].isascii() or not parts[4].isdecimal():
                raise ValueError('unsupported diagnostic task path')
            tid = int(parts[4])
        else:
            tid = pid
        _closed_integer(tid, 1, 2147483647)
        expected = scope.identity_context['group_expected']
        if expected is None or (expected['tgid'], expected['starttime']) != (pid, row['start']):
            _identity_begin(pid, row, parts[-1])
        scope.identity_resource = parts[-1]
        scope.identity_context['observation_resource'] = parts[-1]
        selected = scope.identity_context['task_selected']
        if selected is None or selected['tid'] != tid:
            _identity_capture('task_selected', pid, tid, None, kind='task')
        return tid
    except BaseException:
        scope.failed()
        return None


def _identity_restore(error):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        capsule = _identity_capsule(error)
        if capsule is not None:
            event = capsule['packet']['events'][-1]
            scope.identity_context = _copy_identity_context(event['context'])
            scope.identity_resource = event['context']['observation_resource']
            _identity_attribute_context(scope.identity_context, scope)
    except BaseException:
        scope.failed()


def _identity_attribution(pid, row, source, selected):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        parent = None
        if source == 'descendant' and row['parent'] in selected:
            parent_row = selected[row['parent']]
            parent = _identity_row(row['parent'], row['parent'], parent_row, parent_row['start'], 'group')
        scope.identity_attribution = dict(key=(pid, row['start']), parent=parent)
        _identity_begin(pid, row, 'unknown')
    except BaseException:
        scope.failed()


def _identity_group_result(pid, row, current, slot, check=None):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        _identity_capture(slot, pid, pid, current)
        if check is not None:
            recorded = scope.identity_context[slot]
            expected = scope.identity_context['group_expected']
            result = 'missing' if current is None else 'unknown'
            if recorded is not None and expected is not None:
                result = 'same' if recorded['starttime'] == expected['starttime'] else 'different'
            _identity_check(check, result)
    except BaseException:
        scope.failed()


def _identity_task_result(pid, tid, row, slot):
    scope = _identity_scope()
    if scope is None or tid is None:
        return
    try:
        _identity_capture(slot, pid, tid, row, kind='task')
        if slot == 'task_after':
            before, after = scope.identity_context['task_before'], scope.identity_context['task_after']
            if before is not None and after is not None:
                _identity_check('task_match_after',
                                'same' if before['starttime'] == after['starttime'] else 'different')
    except BaseException:
        scope.failed()


def _identity_after_origin():
    scope = _identity_scope()
    if scope is not None:
        try:
            if scope.identity_context['task_match_after'] == 'same':
                return 'application_state_check'
        except BaseException:
            scope.failed()
    return 'application_identity_check'


def _identity_inventory_task(pid, task, row=None, *, selection=False):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        name = task.name
        if type(name) is not str or len(name) > 10 or not name.isascii() or not name.isdecimal():
            raise ValueError('invalid diagnostic task coordinate')
        tid = int(name)
        slot = 'task_selected' if selection else (
            'task_revalidation' if scope.revalidation_error is not None else 'task_inventory')
        _identity_capture(slot, pid, tid, row, kind='task')
    except BaseException:
        scope.failed()


def _identity_quiescence_begin(pid, row):
    scope = _identity_scope()
    if scope is None:
        return
    try:
        expected = scope.identity_context['group_expected']
        if expected is None or (expected['tgid'], expected['starttime']) != (pid, row['start']):
            _identity_begin(pid, row, 'unknown')
    except BaseException:
        scope.failed()


def copy_diagnostic(payload):
    """Validate and copy closed metadata; never format arbitrary exception data."""
    def keys(value, expected):
        if (type(value) is not dict or len(value) != len(expected)
                or any(type(key) is not str or len(key) > 64 for key in value)
                or set(value) != expected):
            raise ValueError('invalid observer diagnostic structure')

    def choice(value, allowed):
        if type(value) is not str or len(value) > 64 or value not in allowed:
            raise ValueError('invalid observer diagnostic category')

    def integer(value, low, high):
        if type(value) is not int or not low <= value <= high:
            raise ValueError('invalid observer diagnostic integer')

    keys(payload, {'schema', 'complete', 'omitted', 'events'})
    integer(payload['schema'], 1, 1)
    if type(payload['complete']) is not bool:
        raise ValueError('invalid observer diagnostic completeness')
    integer(payload['omitted'], 0, 2147483647)
    rows = payload['events']
    if type(rows) is not list or len(rows) > _MAX_DIAGNOSTIC_EVENTS:
        raise ValueError('invalid observer diagnostic bound')
    if payload['complete'] and (not rows or payload['omitted']):
        raise ValueError('incomplete observer diagnostic marked complete')
    copied = []
    for index, row in enumerate(rows, 1):
        keys(row, _EVENT_KEYS)
        integer(row['sequence'], index, index)
        integer(row['monotonic_ns'], 0, 9223372036854775807)
        choice(row['component'], {'observer'})
        choice(row['operation'], _OPERATIONS)
        choice(row['phase'], _PHASES)
        choice(row['exception_class'], _CLASS_NAMES + ('UnknownException',))
        choice(row['errno_state'], {'absent', 'none', 'integer', 'boolean', 'invalid', 'unavailable'})
        choice(row['attribution_source'], {'unknown', 'marker', 'known_identity', 'descendant'})
        choice(row['identity_verified'], {'unknown'})
        choice(row['relation'], {'primitive', 'retry', 'revalidation', 'quiescence', 'normalization'})
        for field in ('primitive_errno', 'normalized_errno'):
            if row[field] is not None:
                integer(row[field], -2147483648, 2147483647)
        if type(row['normalization_applied']) is not bool or type(row['first_failure']) is not bool:
            raise ValueError('invalid observer diagnostic boolean')
        if row['first_failure'] != (index == 1):
            raise ValueError('invalid observer diagnostic first event')
        if row['cause_sequence'] is not None:
            integer(row['cause_sequence'], 1, index - 1)
        copied.append(dict(row))
    return dict(schema=1, complete=payload['complete'], omitted=payload['omitted'], events=copied)


class _DiagnosticScope:
    def __init__(self, owner):
        self.owner = owner
        self.phase = 'unknown'
        self.attribution = 'unknown'
        self.revalidation_error = None
        self.quiescence_error = None
        if owner.identity_diagnostics_enabled:
            self.identity_context = _empty_identity_context()
            self.identity_resource = 'unknown'
            self.identity_attribution = None

    def failed(self):
        self.owner.diagnostics_incomplete = True


def _empty_diagnostic():
    return dict(schema=1, complete=False, omitted=0, events=[])


def _exception_mapping(error):
    # Even dict.get can invoke a colliding key's __eq__. Admit bounded native
    # string keys before looking up or inserting any diagnostic attribute.
    mapping = _EXCEPTION_DICT.__get__(error)
    if (type(mapping) is not dict or len(mapping) > 32
            or any(type(key) is not str or len(key) > 64 for key in mapping)):
        raise ValueError('unsafe observer exception metadata')
    return mapping


def _capsule(error, owner=None):
    mapping = _exception_mapping(error)
    value = dict.get(mapping, _DIAGNOSTIC_KEY)
    if value is None:
        return None
    if (type(value) is not dict or len(value) != 3
            or any(type(key) is not str or len(key) > 64 for key in value)
            or set(value) != {'packet', 'origin', 'owner'}):
        raise ValueError('invalid observer diagnostic capsule')
    scope = _DIAGNOSTIC_SCOPE.get()
    expected_owner = owner if owner is not None else scope.owner._diagnostic_identity if scope is not None else None
    if value['owner'] is not expected_owner:
        return None
    packet = copy_diagnostic(value['packet'])
    origin = value['origin']
    if type(origin) is not int or not 1 <= origin <= len(packet['events']):
        raise ValueError('invalid observer diagnostic origin')
    return dict(packet=packet, origin=origin)


def _store_capsule(error, capsule):
    capsule['owner'] = _DIAGNOSTIC_SCOPE.get().owner._diagnostic_identity
    mapping = _exception_mapping(error)
    if len(mapping) == 32 and _DIAGNOSTIC_KEY not in mapping:
        raise ValueError('observer exception metadata is full')
    dict.__setitem__(mapping, _DIAGNOSTIC_KEY, capsule)


def _error_metadata(error):
    category = 'UnknownException'
    kind = type(error)
    for known, name in zip(_CLASSES, _CLASS_NAMES):
        if kind is known:
            category = name
            break
    if category == 'UnknownException':
        return category, None, 'unavailable'
    if isinstance(error, OSError):
        value = OSError.errno.__get__(error)
    else:
        mapping = _exception_mapping(error)
        if 'errno' not in mapping:
            return category, None, 'absent'
        value = dict.get(mapping, 'errno')
    if value is None:
        return category, None, 'none'
    if type(value) is bool:
        return category, None, 'boolean'
    if type(value) is int and -2147483648 <= value <= 2147483647:
        return category, value, 'integer'
    return category, None, 'invalid'


def _note(error, operation, phase=None):
    scope = _DIAGNOSTIC_SCOPE.get()
    if scope is None:
        return
    _identity_note(error, operation, phase)
    try:
        if _capsule(error) is not None:
            return
        category, number, errno_state = _error_metadata(error)
        row = dict(sequence=1, monotonic_ns=time.monotonic_ns(), component='observer',
                   operation=operation, phase=scope.phase if phase is None else phase,
                   exception_class=category, primitive_errno=number, errno_state=errno_state,
                   normalized_errno=None, normalization_applied=False,
                   attribution_source=scope.attribution, identity_verified='unknown',
                   first_failure=True, relation='primitive', cause_sequence=None)
        complete = (not scope.owner.diagnostics_incomplete and errno_state != 'unavailable'
                    and operation not in ('sample', 'error_input'))
        packet = copy_diagnostic(dict(schema=1, complete=complete, omitted=0, events=[row]))
        _store_capsule(error, dict(packet=packet, origin=1))
    except BaseException:
        scope.failed()


def _link(initial, secondary, relation, *, retain_initial=False):
    scope = _DIAGNOSTIC_SCOPE.get()
    if scope is None or initial is secondary:
        return
    _identity_link(initial, secondary, relation, retain_initial)
    try:
        _note(initial, 'error_input', 'error_normalization')
        _note(secondary, 'error_input', 'error_normalization')
        first, later = _capsule(initial), _capsule(secondary)
        if first is None or later is None:
            scope.failed()
            return
        packet = first['packet']
        offset = len(packet['events'])
        appended = later['packet']['events']
        for index, row in enumerate(appended):
            row['sequence'] += offset
            row['first_failure'] = False
            if row['cause_sequence'] is not None:
                row['cause_sequence'] += offset
            if index == 0:
                row['relation'] = relation
            if len(packet['events']) < _MAX_DIAGNOSTIC_EVENTS:
                packet['events'].append(row)
            else:
                packet['omitted'] = min(2147483647, packet['omitted'] + 1)
        packet['omitted'] = min(2147483647, packet['omitted'] + later['packet']['omitted'])
        packet['complete'] = packet['complete'] and later['packet']['complete'] and not packet['omitted']
        origin = first['origin'] if retain_initial else later['origin'] + offset
        if origin > len(packet['events']):
            origin = first['origin']
            packet['complete'] = False
        _store_capsule(initial if retain_initial else secondary, dict(packet=copy_diagnostic(packet), origin=origin))
    except BaseException:
        scope.failed()


def _normalized(initial, result, number, applied):
    scope = _DIAGNOSTIC_SCOPE.get()
    if scope is None:
        return
    _identity_normalized(initial, result, number, applied)
    try:
        _note(initial, 'error_input', 'error_normalization')
        capsule = _capsule(initial)
        if capsule is None:
            scope.failed()
            return
        packet = capsule['packet']
        for row in packet['events']:
            if row['attribution_source'] == 'unknown':
                row['attribution_source'] = scope.attribution
        projected = int(number) if type(number) is bool else number
        if type(projected) is not int or not -2147483648 <= projected <= 2147483647:
            projected = None
            packet['complete'] = False
        if len(packet['events']) == _MAX_DIAGNOSTIC_EVENTS:
            packet['complete'] = False
            packet['omitted'] = min(2147483647, packet['omitted'] + 1)
        else:
            cause = packet['events'][capsule['origin'] - 1]
            packet['events'].append(dict(
                sequence=len(packet['events']) + 1, monotonic_ns=time.monotonic_ns(),
                component='observer', operation='error_normalization', phase='error_normalization',
                exception_class='ObservationError', primitive_errno=None,
                errno_state='boolean' if type(number) is bool else 'none',
                normalized_errno=projected, normalization_applied=applied,
                attribution_source=cause['attribution_source'], identity_verified='unknown', first_failure=False,
                relation='normalization', cause_sequence=capsule['origin']))
        packet['complete'] = packet['complete'] and not scope.owner.diagnostics_incomplete
        _store_capsule(result, dict(packet=copy_diagnostic(packet), origin=len(packet['events'])))
    except BaseException:
        scope.failed()


def _call(operation, phase, function, *args, **kwargs):
    scope = _DIAGNOSTIC_SCOPE.get()
    if scope is None:
        return function(*args, **kwargs)
    previous = scope.phase
    if phase is not None:
        scope.phase = phase
    try:
        return function(*args, **kwargs)
    except BaseException as error:
        _note(error, operation)
        raise
    finally:
        scope.phase = previous


def _inventory(path, operation, phase):
    # No diagnostic context remains active while control is yielded to readers.
    iterator = _call(operation, phase, lambda: iter(path.iterdir()))
    while True:
        try:
            entry = next(iterator)
        except StopIteration:
            return
        except BaseException as error:
            _note(error, operation, phase)
            raise
        yield entry


def _guard(error, operation, phase, *, identity_origin='application_identity_check'):
    _identity_note(error, operation, phase, identity_origin)
    _note(error, operation, phase)
    return error


class _IdentityAttributeContext:
    """Observe the existing context protocol without changing exit precedence."""
    def __init__(self, stream):
        self.stream = stream
        self.supported = False
        # with caches both special methods before entry. Looking up __exit__
        # later could call a different method after __enter__ or read changed it.
        try:
            enter = _identity_special_definition(type(stream), '__enter__')
            leave = _identity_special_definition(type(stream), '__exit__')
            if enter is None or leave is None:
                _identity_scope().failed()
                return
            self.enter = enter.__get__(stream, type(stream))
            self.exit = leave.__get__(stream, type(stream))
            self.supported = True
        except BaseException:
            _identity_scope().failed()

    def __enter__(self):
        try:
            return self.enter()
        except BaseException as error:
            _identity_note(error, 'attribute_enter', 'attribute_read')
            raise

    def __exit__(self, kind, error, traceback):
        # A close failure remains the propagated exception, as in read_bytes.
        # The earlier read failure survives only as closed diagnostic metadata.
        try:
            return self.exit(kind, error, traceback)
        except BaseException as close_error:
            if error is close_error:
                _identity_repeated_close(close_error)
            else:
                _identity_note(close_error, 'attribute_close', 'attribute_read')
            if error is not None and error is not close_error:
                _identity_link(error, close_error, 'close')
            raise


def _identity_special_definition(kind, name):
    # Read only native class dictionaries. Do not run a descriptor to decide
    # whether it is supported, nor consult arbitrary instance attributes.
    bases = _TYPE_BASES.__get__(kind)
    if type(bases) is not tuple or len(bases) > 32:
        return None
    for base in bases:
        namespace = _TYPE_NAMESPACE.__get__(base)
        if name in namespace:
            value = namespace[name]
            return value if type(value) in (FunctionType, MethodDescriptorType, WrapperDescriptorType) else None
    return None


def _identity_read_bytes(path):
    # Match the inspected CPython Path.read_bytes implementations. The explicit
    # boundaries cost Python time; they do not establish identical scheduling or
    # prove that a mock's OSError came from a kernel system call.
    scope = _identity_scope()
    try:
        reader = path.read_bytes
    except BaseException as error:
        _identity_note(error, 'attribute_lookup', 'attribute_read', 'unknown')
        raise
    if (type(reader) is not MethodType or reader.__self__ is not path
            or reader.__func__ is not _PATH_READ_BYTES):
        # Replacing a customized read_bytes would change its contract. Preserve
        # the call and declare that its internal I/O boundaries are unavailable.
        scope.failed()
        return _identity_opaque_read(reader)
    if (sys.implementation.name != 'cpython' or sys.version_info.major != 3
            or not 10 <= sys.version_info.minor <= 14):
        scope.failed()
        return _identity_opaque_read(reader)
    try:
        stream = path.open(mode='rb', buffering=0) if sys.version_info.minor >= 14 else path.open(mode='rb')
    except BaseException as error:
        _identity_note(error, 'attribute_open', 'attribute_read')
        raise
    context = _IdentityAttributeContext(stream)
    if not context.supported:
        return _identity_opaque_context(stream)
    with context as opened:
        try:
            return opened.read()
        except BaseException as error:
            _identity_note(error, 'attribute_read', 'attribute_read')
            raise


def _identity_opaque_read(reader):
    try:
        return reader()
    except BaseException as error:
        _identity_note(error, 'attribute_opaque', 'attribute_read', 'unknown')
        raise


def _identity_opaque_context(stream):
    try:
        with stream as opened:
            return opened.read()
    except BaseException as error:
        _identity_note(error, 'attribute_opaque', 'attribute_read', 'unknown')
        raise


def _inventory_quiescence(pid, row):
    scope = _DIAGNOSTIC_SCOPE.get()
    if scope is None:
        return threads_are_quiescent(pid, row), None
    previous = scope.quiescence_error
    scope.quiescence_error = None
    try:
        return threads_are_quiescent(pid, row), scope.quiescence_error
    finally:
        scope.quiescence_error = previous


class _GroupExitProofs:
    """Keep attributed whole-group pidfds only for one observer sample.

    A missing task directory is not exit evidence: a zombie leader can still
    have live siblings. Only a pidfd bound before that inventory can establish
    that the entire old thread group has exited. It grants no signal, wait or
    cleanup authority, and never excuses a failed memory observation.
    """
    def __init__(self, known):
        self.allowed = set(known)
        self.attributions = {key: 'known_identity' for key in self.allowed}
        self.handles = {}
        self.bound = set()
        self.unavailable = {}
        self.resolved = {}
        self.attempted = set()
        self.terminated = set()
        self.cleanup_error = None

    def __enter__(self):
        self.previous = _GROUP_EXIT_PROOFS.get()
        self.token = _GROUP_EXIT_PROOFS.set(self)
        return self

    def __exit__(self, _kind, initial, _traceback):
        failure = initial
        if self.cleanup_error is not None:
            failure = self.cleanup_error
            if initial is not None and initial is not failure:
                try:
                    _link(failure, initial, 'quiescence', retain_initial=True)
                except BaseException:
                    try:
                        scope = _DIAGNOSTIC_SCOPE.get()
                        if scope is not None:
                            scope.failed()
                    except BaseException:
                        pass
        try:
            for key, (pid, row, descriptor) in self.handles.items():
                try:
                    os.close(descriptor)
                except BaseException as error:
                    # Diagnostic metadata must never prevent closing a handle.
                    previous = failure
                    if failure is None:
                        failure = error
                    scope = None
                    try:
                        scope = _DIAGNOSTIC_SCOPE.get()
                        if scope is not None:
                            scope.attribution = self.attributions[key]
                        _identity_attribution(pid, row, self.attributions[key], {})
                        _note(error, 'pidfd_close', 'quiescence_check')
                        if previous is not None:
                            _link(previous, error, 'quiescence', retain_initial=True)
                        elif key in self.unavailable:
                            _link(self.unavailable[key], error, 'quiescence')
                        elif key in self.resolved:
                            _link(self.resolved[key], error, 'quiescence')
                    except BaseException:
                        try:
                            if scope is not None:
                                scope.failed()
                        except BaseException:
                            pass
            # Never retry close(): an interrupted close can already have freed
            # its descriptor. Every owned descriptor is attempted exactly once.
        finally:
            # A failed context reset must not retain a usable proof, nor mask
            # an earlier refusal. The fallback only restores the previous
            # lexical scope.
            self.handles.clear()
            self.bound.clear()
            self.allowed.clear()
            self.terminated.clear()
            self.unavailable.clear()
            self.resolved.clear()
            self.attempted.clear()
            self.attributions.clear()
            self.cleanup_error = None
            try:
                _GROUP_EXIT_PROOFS.reset(self.token)
            except BaseException as error:
                previous = failure
                if failure is None:
                    failure = error
                try:
                    _guard(error, 'pidfd_scope', 'quiescence_check',
                           identity_origin='application_state_check')
                    if previous is not None:
                        _link(previous, error, 'quiescence', retain_initial=True)
                except BaseException:
                    try:
                        scope = _DIAGNOSTIC_SCOPE.get()
                        if scope is not None:
                            scope.failed()
                    except BaseException:
                        pass
                try:
                    _GROUP_EXIT_PROOFS.set(self.previous)
                except BaseException as secondary:
                    try:
                        _guard(secondary, 'pidfd_scope', 'quiescence_check',
                               identity_origin='application_state_check')
                        _link(failure, secondary, 'quiescence', retain_initial=True)
                        scope = _DIAGNOSTIC_SCOPE.get()
                        if scope is not None:
                            scope.failed()
                    except BaseException:
                        pass
        if failure is not None and failure is not initial:
            if isinstance(failure, ObservationError) or not isinstance(failure, Exception):
                raise failure
            _raise_incomplete_observation(failure)
        return False

    def allow(self, pid, row, attribution):
        self.allowed.add((pid, row['start']))
        self.attributions[pid, row['start']] = attribution

    def retired(self, pid, row):
        return (pid, row['start']) in self.terminated

    def _raise_cleanup(self, earlier=None):
        failure = self.cleanup_error
        if earlier is not None:
            _link(earlier, failure, 'quiescence', retain_initial=True)
            failure = earlier
        if isinstance(failure, ObservationError) or not isinstance(failure, Exception):
            self.cleanup_error = failure
            raise failure
        try:
            _raise_incomplete_observation(failure)
        except ObservationError as error:
            self.cleanup_error = error
            raise

    def _pidfd_identity(self, pid, descriptor):
        # fdinfo projects Pid into the same procfs namespace as our stat reads.
        # A stable numeric PID alone does not bridge different PID namespaces.
        stream = _call('pidfd_fdinfo_open', 'quiescence_check',
                       Path(f'/proc/self/fdinfo/{descriptor}').open, 'rb')
        initial = None
        try:
            data = _call('pidfd_fdinfo_read', 'quiescence_check', stream.read, 4097)
        except BaseException as error:
            initial = error
            raise
        finally:
            try:
                stream.close()
            except BaseException as error:
                previous = self.cleanup_error
                if previous is None:
                    self.cleanup_error = error
                scope = None
                try:
                    scope = _DIAGNOSTIC_SCOPE.get()
                    _note(error, 'pidfd_fdinfo_close', 'quiescence_check')
                    if initial is not None:
                        _link(initial, error, 'quiescence')
                    if previous is not None:
                        _link(previous, error, 'quiescence', retain_initial=True)
                except BaseException:
                    try:
                        if scope is not None:
                            scope.failed()
                    except BaseException:
                        pass
                if initial is None:
                    raise
        if type(data) is not bytes or len(data) > 4096:
            return False
        values = [line.partition(b':')[2].strip() for line in data.splitlines()
                  if line.partition(b':')[0].strip() == b'Pid']
        return (len(values) == 1 and 0 < len(values[0]) <= 10 and values[0].isascii()
                and values[0].isdigit() and int(values[0]) == pid and pid > 0)

    def pin(self, pid, row):
        key = pid, row['start']
        if key not in self.allowed or key in self.attempted:
            return
        self.attempted.add(key)
        opener = getattr(os, 'pidfd_open', None)
        if not callable(opener):
            # The historical complete-inventory proof remains available on a
            # runtime without pidfds; an incomplete inventory still refuses.
            return
        try:
            before = _call('stat_read', 'quiescence_check', current_process, pid)
            if before is None or before['start'] != row['start'] or before['state'] not in ('Z', 'X'):
                return
            descriptor = _call('pidfd_open', 'quiescence_check', opener, pid, 0)
            if type(descriptor) is not int or not 0 <= descriptor <= 2147483647:
                raise _guard(OSError(errno.EIO, 'pidfd descriptor is invalid'),
                             'pidfd_guard', 'quiescence_check', identity_origin='application_state_check')
            self.handles[key] = (pid, row, descriptor)
            matches = self._pidfd_identity(pid, descriptor)
            after = _call('stat_read', 'quiescence_check', current_process, pid)
            _identity_group_result(pid, row, after, 'group_quiescence')
            if (not matches or after is None or after['start'] != row['start']
                    or after['state'] not in ('Z', 'X')):
                raise _guard(ProcessLookupError(errno.ESRCH, 'pidfd identity could not be bound'),
                             'pidfd_guard', 'quiescence_check')
            self.bound.add(key)
        except (OSError, ValueError, IndexError) as error:
            # This is an optional independent proof. A complete historical
            # inventory still suffices; an incomplete one cannot use this fd.
            self.unavailable[key] = error
        if self.cleanup_error is not None:
            self._raise_cleanup()

    def resolve_inventory(self, pid, row, initial):
        key = pid, row['start']
        if key in self.terminated:
            return True
        handle = self.handles.get(key)
        if handle is None or key not in self.bound:
            if key in self.unavailable:
                _link(self.unavailable[key], initial, 'quiescence')
            return False
        descriptor = handle[2]
        try:
            poller = _call('pidfd_poll', 'quiescence_check', select.poll)
            _call('pidfd_poll', 'quiescence_check', poller.register, descriptor, select.POLLIN)
            events = _call('pidfd_poll', 'quiescence_check', poller.poll, 0)
            allowed = select.POLLIN | select.POLLHUP
            if (len(events) != 1 or events[0][0] != descriptor
                    or not events[0][1] & allowed or events[0][1] & ~allowed):
                return False
        except (OSError, ValueError, IndexError) as error:
            _link(initial, error, 'quiescence', retain_initial=True)
            # A later disappearance must not erase a failure of this proof.
            _raise_incomplete_observation(initial)
        self.terminated.add(key)
        self.resolved[key] = initial
        return True


def _task_inventory(pid, row, phase):
    try:
        yield from _inventory(Path(f'/proc/{pid}/task'), 'task_inventory', phase)
    except FileNotFoundError as error:
        proofs = _GROUP_EXIT_PROOFS.get()
        if error.errno == errno.ENOENT and proofs is not None and proofs.resolve_inventory(pid, row, error):
            return
        raise


def current_process(pid):
    """Read one fresh identity, with a bounded retry for a stale proc handle."""
    path = Path(f'/proc/{pid}/stat')
    previous_error = None
    for attempt in range(2):
        try:
            return process_row(path)
        except FileNotFoundError:
            return None
        except (ProcessLookupError, InterruptedError) as error:
            if attempt:
                if previous_error is not None:
                    _link(previous_error, error, 'retry')
                raise
            if _DIAGNOSTIC_SCOPE.get() is not None:
                previous_error = error
        except BaseException as error:
            if previous_error is not None:
                _link(previous_error, error, 'retry')
            raise
    raise AssertionError('unreachable identity retry')


def same_process(pid, row):
    """Confirm disappearance or replacement only through a fresh stat read."""
    current = current_process(pid)
    scope = _identity_scope()
    if scope is not None:
        if scope.phase == 'identity_before':
            _identity_group_result(pid, row, current, 'group_before', 'group_match_before')
        elif scope.phase == 'identity_after':
            _identity_group_result(pid, row, current, 'group_after', 'group_match_after')
    return current is not None and current['start'] == row['start']


def read_observation(path):
    """Retry an interrupted read once, without treating it as an empty file."""
    if _identity_scope() is not None:
        try:
            return _call('attribute_read', 'attribute_read', _identity_read_bytes, path)
        except InterruptedError as first_error:
            try:
                return _call('attribute_read', 'attribute_read', _identity_read_bytes, path)
            except BaseException as error:
                _link(first_error, error, 'retry')
                raise
    try:
        return _call('attribute_read', 'attribute_read', path.read_bytes)
    except InterruptedError as first_error:
        try:
            return _call('attribute_read', 'attribute_read', path.read_bytes)
        except BaseException as error:
            _link(first_error, error, 'retry')
            raise


def read_process_observation(pid, row, path):
    """Accept memory only from the same live task within the same thread group."""
    tid = _identity_path(pid, row, path)
    if not _call('identity_guard', 'identity_before', same_process, pid, row):
        raise _guard(ProcessLookupError(errno.ESRCH, 'observation group identity changed'),
                     'identity_guard', 'identity_before')
    before = _call('stat_read', 'task_stat_before', process_row, path.with_name('stat'))
    _identity_task_result(pid, tid, before, 'task_before')
    if before['state'] in ('Z', 'X'):
        raise _guard(ProcessLookupError(errno.ESRCH, 'observation task has terminated'),
                     'identity_guard', 'task_stat_before', identity_origin='application_state_check')
    data = read_observation(path)
    after = _call('stat_read', 'task_stat_after', process_row, path.with_name('stat'))
    _identity_task_result(pid, tid, after, 'task_after')
    if after['start'] != before['start'] or after['state'] in ('Z', 'X'):
        raise _guard(ProcessLookupError(errno.ESRCH, 'observation task identity changed'),
                     'identity_guard', 'task_stat_after', identity_origin=_identity_after_origin())
    if not _call('identity_guard', 'identity_after', same_process, pid, row):
        raise _guard(ProcessLookupError(errno.ESRCH, 'observation task identity changed'),
                     'identity_guard', 'identity_after')
    return data


def observation_failure(pid, row, error, *, current_presence_only=False):
    # Fresh exit evidence can explain a missing attribute, but cannot restore a
    # lost privacy interval after another read failure. Only the token predicate
    # asks solely about current presence rather than continuous observation.
    _identity_restore(error)
    _note(error, 'error_input', 'error_normalization')
    if current_presence_only or isinstance(error, (FileNotFoundError, ProcessLookupError)):
        scope = _DIAGNOSTIC_SCOPE.get()
        previous_target = scope.revalidation_error if scope is not None else None
        if scope is not None:
            scope.revalidation_error = error
        try:
            current = _call('stat_read', 'identity_after', current_process, pid)
            _identity_group_result(pid, row, current, 'group_revalidation', 'group_match_revalidation')
            if _identity_scope() is None:
                if current is None or current['start'] != row['start'] or threads_are_quiescent(pid, current):
                    return
            else:
                # Preserve the same short circuit and predicate calls. A later
                # identity is distinct from the unavailable post-read identity.
                if current is None or current['start'] != row['start']:
                    return
                quiescent = threads_are_quiescent(pid, current)
                _identity_check('quiescence', 'true' if quiescent else 'false')
                if quiescent:
                    return
        except (OSError, ValueError, IndexError) as identity_error:
            _link(error, identity_error, 'revalidation')
            error = identity_error
        finally:
            if scope is not None:
                scope.revalidation_error = previous_target
    _raise_incomplete_observation(error)


def _raise_incomplete_observation(error):
    """Normalize a refusal without granting fresh disappearance an exemption."""
    normalization_operation = 'error_errno'
    try:
        number = getattr(error, 'errno', None)
        normalization_operation = 'error_normalization'
        applied = False
        if not isinstance(number, int) or not 0 < number < 4096:
            number = errno.EIO
            applied = True
        final_error = ObservationError(number, 'attributed process observation is incomplete')
    except BaseException as metadata_error:
        _note(metadata_error, normalization_operation, 'error_normalization')
        _link(error, metadata_error, 'revalidation')
        raise
    _normalized(error, final_error, number, applied)
    raise final_error from None


def token_process_is_live(pid, marker):
    """Observe a fixture token without granting authority after a read failure."""
    for attempt in range(2):
        try:
            row = process_row(Path(f'/proc/{pid}/stat'))
            break
        except FileNotFoundError:
            return False
        except (ProcessLookupError, InterruptedError):
            if attempt:
                raise
    if threads_are_quiescent(pid, row):
        return False
    pending = None
    inspected = False
    try:
        for path in observation_paths(pid, row, 'environ'):
            try:
                environment = read_process_observation(pid, row, path).split(b'\0')
            except (FileNotFoundError, ProcessLookupError) as error:
                # A dead group leader may have a live sibling with readable
                # memory. Visit that sibling before deciding observability.
                pending = error
                continue
            except OSError as error:
                observation_failure(pid, row, error, current_presence_only=True)
                continue
            if not same_process(pid, row):
                return False
            inspected = inspected or any(environment)
            if marker in environment:
                return True
        if pending is not None and not inspected:
            observation_failure(pid, row, pending, current_presence_only=True)
    except ObservationError:
        raise
    except (OSError, ValueError, IndexError) as error:
        observation_failure(pid, row, error, current_presence_only=True)
    return False


def process_row(path):
    # comm is an arbitrary byte string, possibly truncated inside UTF-8.
    # Keep identity parsing independent and let malformed fields/read errors fail.
    content = _call('stat_read', None, path.read_text, encoding='ascii', errors='surrogateescape')
    fields = _call('stat_fields', None, lambda: content.rsplit(') ', 1)[1].split())
    return {'start': _call('stat_start', None, lambda: int(fields[19])),
            'state': _call('stat_state', None, lambda: fields[0]),
            'parent': _call('stat_parent', None, lambda: int(fields[1])),
            'group': _call('stat_group', None, lambda: int(fields[2])),
            'session': _call('stat_session', None, lambda: int(fields[3]))}


def snapshot():
    # glob can suppress an unreadable/missing procfs root into an empty match.
    # Failure to observe is a qualification error, never evidence of shutdown.
    paths = [entry / 'stat' for entry in _inventory(Path('/proc'), 'process_inventory', 'snapshot')
             if entry.name.isdecimal()]
    own_pid = os.getpid()
    if Path(f'/proc/{own_pid}/stat') not in paths:
        raise _guard(OSError('incomplete procfs inventory: observer is absent'),
                     'inventory_guard', 'snapshot', identity_origin='application_state_check')
    rows = {}
    for path in paths:
        try:
            rows[int(path.parent.name)] = _call('stat_read', 'snapshot', process_row, path)
        except FileNotFoundError:
            # A process may disappear between enumeration and its stat read.
            continue
        except ProcessLookupError as first_error:
            # A stat opened before exit can fail with ESRCH when read later.
            # Reopen once: a vanished pathname confirms disappearance, a live
            # replacement supplies a fresh identity, and repeated or different
            # errors still make the observation fail instead of proving a stop.
            try:
                rows[int(path.parent.name)] = _call('stat_read', 'snapshot', process_row, path)
            except FileNotFoundError:
                continue
            except BaseException as error:
                _link(first_error, error, 'retry')
                raise
    if own_pid not in rows:
        raise _guard(OSError('incomplete procfs inventory: observer stat is absent'),
                     'inventory_guard', 'snapshot', identity_origin='application_state_check')
    return rows


def observation_paths(pid, row, name):
    """Choose live tasks; an exited leader need not retain accessible memory."""
    _identity_begin(pid, row, name)
    proofs = _GROUP_EXIT_PROOFS.get()
    if proofs is not None and proofs.retired(pid, row):
        return
    current = _call('stat_read', 'identity_before', current_process, pid)
    _identity_group_result(pid, row, current, 'group_selected')
    if current is None or current['start'] != row['start']:
        return
    if current['state'] not in ('Z', 'X'):
        _identity_task_result(pid, pid, current, 'task_selected')
        yield Path(f'/proc/{pid}/{name}')
        # The leader can exit after selection. Revalidate before considering
        # siblings; memory readers also revalidate both identities themselves.
        current = _call('stat_read', 'identity_after', current_process, pid)
        _identity_group_result(pid, row, current, 'group_after', 'group_match_after')
        if current is None or current['start'] != row['start']:
            return
    if current['state'] in ('Z', 'X'):
        if proofs is not None:
            proofs.pin(pid, current)
        live = False
        for task in _task_inventory(pid, current, 'task_inventory'):
            if task.name.isdecimal() and task.name != str(pid):
                _identity_inventory_task(pid, task)
                try:
                    identity = _call('stat_read', 'task_stat_before', process_row, task / 'stat')
                except FileNotFoundError:
                    continue
                _identity_inventory_task(pid, task, identity)
                if identity['state'] in ('Z', 'X'):
                    continue
                live = True
                _identity_inventory_task(pid, task, identity, selection=True)
                yield task / name
        if not live:
            quiescent, quiescence_error = _inventory_quiescence(pid, current)
            if not quiescent:
                error = _guard(OSError(errno.EIO, 'observation task inventory is incomplete'),
                               'inventory_guard', 'task_inventory',
                               identity_origin='application_state_check')
                if quiescence_error is not None:
                    _link(quiescence_error, error, 'quiescence')
                raise error


def threads_are_quiescent(pid, row):
    """Classify the thread group independently of the production predicates."""
    _identity_quiescence_begin(pid, row)
    proofs = _GROUP_EXIT_PROOFS.get()
    if proofs is not None and proofs.retired(pid, row):
        return True
    if row['state'] not in ('Z', 'X'):
        return False
    previous = None
    try:
        if proofs is not None:
            proofs.pin(pid, row)
        for _ in range(2):
            tasks = set()
            for task in _task_inventory(pid, row, 'quiescence_check'):
                _identity_inventory_task(pid, task)
                state = _call('stat_read', 'quiescence_check', process_row, task / 'stat')
                _identity_inventory_task(pid, task, state)
                if state['state'] not in ('Z', 'X'):
                    return False
                tasks.add((task.name, state['start']))
            if proofs is not None and proofs.retired(pid, row):
                return True
            current = _call('stat_read', 'quiescence_check', process_row, Path(f'/proc/{pid}/stat'))
            _identity_group_result(pid, row, current, 'group_quiescence')
            if current['start'] != row['start'] or current['state'] not in ('Z', 'X'):
                return False
            if not tasks or (previous is not None and tasks != previous):
                return False
            previous = tasks
    except ObservationError:
        raise
    except (OSError, ValueError, IndexError) as error:
        # Incomplete observation of an attributed task cannot grant quiescence.
        scope = _DIAGNOSTIC_SCOPE.get()
        if scope is not None:
            scope.quiescence_error = error
            if scope.revalidation_error is not None:
                _link(scope.revalidation_error, error, 'quiescence', retain_initial=True)
        return False
    return True


class Observer:
    def __init__(self, token, *, marker_name='YTDLP_QUALIFICATION_TOKEN', allow_external=True,
                 diagnostics=False, identity_diagnostics=False):
        if identity_diagnostics is True and diagnostics is not True:
            raise ValueError('identity diagnostics require observer diagnostics')
        self.marker = marker_name.encode() + b'=' + token.encode()
        self.known = set()
        self.leaks = set()
        self.external = set()
        self.allow_external = allow_external
        self.error = None
        self.diagnostics_enabled = diagnostics is True
        self.identity_diagnostics_enabled = identity_diagnostics is True
        self.diagnostics_incomplete = False
        self._diagnostic_identity = object()

    def identity_failure(self, error):
        """Return private coordinates for this failure; never export them directly."""
        if not self.identity_diagnostics_enabled:
            return _empty_identity_diagnostic()
        try:
            capsule = _identity_capsule(error, self._diagnostic_identity)
            if capsule is None:
                self.diagnostics_incomplete = True
                return _empty_identity_diagnostic()
            packet = capsule['packet']
            packet['complete'] = packet['complete'] and not self.diagnostics_incomplete
            return copy_identity_diagnostic(packet)
        except BaseException:
            self.diagnostics_incomplete = True
            return _empty_identity_diagnostic()

    def diagnostic_failure(self, error):
        """Return only metadata attached to this propagated failure, never process data."""
        if not self.diagnostics_enabled:
            return _empty_diagnostic()
        try:
            capsule = _capsule(error, self._diagnostic_identity)
            if capsule is None:
                self.diagnostics_incomplete = True
                return _empty_diagnostic()
            packet = capsule['packet']
            packet['complete'] = packet['complete'] and not self.diagnostics_incomplete
            return copy_diagnostic(packet)
        except BaseException:
            self.diagnostics_incomplete = True
            return _empty_diagnostic()

    def sample(self):
        # An explicitly disabled nested observer must mask its caller's scope.
        token = None
        scope_entered = False
        previous_scope = None
        try:
            previous_scope = _DIAGNOSTIC_SCOPE.get()
            scope = _DiagnosticScope(self) if self.diagnostics_enabled else None
            token = _DIAGNOSTIC_SCOPE.set(scope)
            scope_entered = True
        except BaseException:
            self.diagnostics_incomplete = True
            try:
                token = _DIAGNOSTIC_SCOPE.set(None)
                scope_entered = True
            except BaseException:
                pass
        try:
            if self.error is not None:
                raise self.error
            try:
                with _GroupExitProofs(self.known):
                    return self._sample()
            except ObservationError as error:
                # A later disappearance cannot erase a gap in privacy observation.
                self.error = error
                raise
        except BaseException as error:
            _note(error, 'sample', 'unknown')
            raise
        finally:
            if scope_entered:
                try:
                    _DIAGNOSTIC_SCOPE.reset(token)
                except BaseException:
                    self.diagnostics_incomplete = True
                    try:
                        _DIAGNOSTIC_SCOPE.set(previous_scope)
                    except BaseException:
                        pass

    def _sample(self):
        rows = snapshot()
        selected = {}
        environment_errors = {}
        attribution_sources = {}
        # The independent launch marker finds a worker even if its immediate
        # parent disappeared between samples. Recorded PID/start identities
        # continue to work after exec clears the environment.
        for pid, row in rows.items():
            key = pid, row['start']
            marked = False
            scope = _DIAGNOSTIC_SCOPE.get()
            if scope is not None:
                scope.attribution = 'known_identity' if key in self.known else 'unknown'
            if key in self.known:
                _identity_attribution(pid, row, 'known_identity', rows)
            elif _identity_scope() is not None:
                scope.identity_attribution = None
            try:
                for path in observation_paths(pid, row, 'environ'):
                    try:
                        environment = read_process_observation(pid, row, path).split(b'\0')
                    except OSError as error:
                        if pid not in environment_errors or isinstance(environment_errors[pid],
                                                                       (FileNotFoundError, ProcessLookupError)):
                            if pid in environment_errors:
                                _link(environment_errors[pid], error, 'retry')
                            environment_errors[pid] = error
                        continue
                    if any(environment) and isinstance(environment_errors.get(pid),
                                                       (FileNotFoundError, ProcessLookupError)):
                        environment_errors.pop(pid, None)
                    if self.marker not in environment:
                        continue
                    current = _call('stat_read', 'environment_inspection', process_row, Path(f'/proc/{pid}/stat'))
                    if current['start'] != row['start']:
                        break
                    marked = True
                    if self.allow_external and b'YTDLP_QUALIFICATION_EXTERNAL=1' in environment:
                        self.external.add(key)
                    break
            except (OSError, ValueError, IndexError) as error:
                proofs = _GROUP_EXIT_PROOFS.get()
                if proofs is not None and error is proofs.cleanup_error:
                    # Collection order is semantic, independent of optional
                    # diagnostics. A later group's cleanup cannot displace an
                    # earlier privacy failure of an already attributed group.
                    for earlier_pid, earlier_error in environment_errors.items():
                        earlier_row = rows[earlier_pid]
                        earlier_key = earlier_pid, earlier_row['start']
                        if (earlier_key in self.external
                                or (earlier_pid not in selected and earlier_key not in self.known)
                                or isinstance(earlier_error, (FileNotFoundError, ProcessLookupError))):
                            continue
                        source = attribution_sources.get(earlier_pid, 'known_identity')
                        scope = _DIAGNOSTIC_SCOPE.get()
                        if scope is not None:
                            scope.attribution = source
                        _identity_attribution(earlier_pid, earlier_row, source, selected)
                        proofs._raise_cleanup(earlier_error)
                    earlier = environment_errors.get(pid)
                    if isinstance(earlier, (FileNotFoundError, ProcessLookupError)):
                        _link(earlier, error, 'quiescence')
                    raise
                if pid not in environment_errors or isinstance(environment_errors[pid],
                                                               (FileNotFoundError, ProcessLookupError)):
                    if pid in environment_errors:
                        _link(environment_errors[pid], error, 'retry')
                    environment_errors[pid] = error
            if marked or key in self.known:
                selected[pid] = row
                attribution_sources[pid] = 'marker' if marked else 'known_identity'
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid not in selected and row['parent'] in selected:
                    selected[pid] = row
                    attribution_sources[pid] = 'descendant'
                    changed = True
        # Only the harness's explicit xdg-open wrapper marks an intentionally
        # opened external application. It is not a supervised download worker.
        excluded = {pid for pid, row in rows.items() if (pid, row['start']) in self.external}
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid not in excluded and row['parent'] in excluded:
                    excluded.add(pid)
                    self.external.add((pid, row['start']))
                    changed = True
        selected = {pid: row for pid, row in selected.items() if pid not in excluded}
        for pid, row in selected.items():
            scope = _DIAGNOSTIC_SCOPE.get()
            if scope is not None:
                scope.attribution = attribution_sources[pid]
            _identity_attribution(pid, row, attribution_sources[pid], selected)
            key = pid, row['start']
            self.known.add(key)
            proofs = _GROUP_EXIT_PROOFS.get()
            if proofs is not None:
                proofs.allow(pid, row, attribution_sources[pid])
            if pid in environment_errors:
                observation_failure(pid, row, environment_errors[pid])
            pending = None
            inspected = False
            try:
                for path in observation_paths(pid, row, 'cmdline'):
                    try:
                        argv = read_process_observation(pid, row, path).lower()
                    except (FileNotFoundError, ProcessLookupError) as error:
                        if pending is not None and not inspected:
                            _link(pending, error, 'retry')
                        pending = error
                        continue
                    except OSError as error:
                        if pending is not None and not inspected:
                            _link(pending, error, 'retry')
                        observation_failure(pid, row, error)
                        continue
                    # Revalidate after reading argv; a reused PID is not evidence.
                    current = _call('stat_read', 'argument_inspection', process_row, Path(f'/proc/{pid}/stat'))
                    if current['start'] != row['start']:
                        break
                    inspected = inspected or bool(argv)
                    if b'http://' in argv or b'https://' in argv:
                        self.leaks.add(key)
                        break
                if pending is not None and not inspected:
                    observation_failure(pid, row, pending)
            except ObservationError:
                raise
            except (OSError, ValueError, IndexError) as error:
                if pending is not None and not inspected:
                    _link(pending, error, 'retry')
                observation_failure(pid, row, error)
        quiescent = {pid for pid, row in selected.items() if threads_are_quiescent(pid, row)}
        return {
            'monotonic_ns': time.monotonic_ns(),
            'live': {str(pid): row for pid, row in selected.items() if pid not in quiescent},
            'zombies': [pid for pid, row in selected.items() if pid in quiescent and row['state'] == 'Z'],
            'url_in_argv': sorted(self.leaks),
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('token')
    parser.add_argument('evidence', type=Path)
    parser.add_argument('stop', type=Path)
    args = parser.parse_args()
    observer = Observer(args.token)
    with (args.evidence / 'process-topology.jsonl').open('a') as log:
        while True:
            # The terminal observation must start after the stop request, not
            # return a sample captured while the application was still exiting.
            stopping = args.stop.exists()
            state = observer.sample()
            log.write(json.dumps(state) + '\n')
            log.flush()
            temporary = args.evidence / '.processes-current.tmp'
            temporary.write_text(json.dumps(state))
            os.replace(temporary, args.evidence / 'processes-current.json')
            if stopping:
                return
            time.sleep(0.05)


if __name__ == '__main__':
    main()
