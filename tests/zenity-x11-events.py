# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/zenity-x11-events.py.

Optional isolated X11 event adapter for the real multi-instance qualification.
Input/profile/folder answers are scripted; progress, cancellation, completion
and the second entry after New download are real Zenity windows. No human
gesture is claimed. The dedicated display never selects personal windows.
"""

import ctypes as c
import ctypes.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import time
import traceback


class Attributes(c.Structure):
    _fields_ = [(name, kind) for name, kind in (
        ('x', c.c_int), ('y', c.c_int), ('width', c.c_int), ('height', c.c_int),
        ('border', c.c_int), ('depth', c.c_int), ('visual', c.c_void_p), ('root', c.c_ulong),
        ('clazz', c.c_int), ('bit_gravity', c.c_int), ('win_gravity', c.c_int),
        ('backing_store', c.c_int), ('backing_planes', c.c_ulong), ('backing_pixel', c.c_ulong),
        ('save_under', c.c_int), ('colormap', c.c_ulong), ('map_installed', c.c_int),
        ('map_state', c.c_int), ('all_masks', c.c_long), ('our_masks', c.c_long),
        ('propagate_mask', c.c_long), ('override_redirect', c.c_int), ('screen', c.c_void_p))]


class Data(c.Union):
    _fields_ = [('b', c.c_char * 20), ('s', c.c_short * 10), ('l', c.c_long * 5)]


class Client(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
                ('display', c.c_void_p), ('window', c.c_ulong), ('message_type', c.c_ulong),
                ('format', c.c_int), ('data', Data)]


class Event(c.Union):
    _fields_ = [('client', Client), ('padding', c.c_long * 24)]


class Display:
    def __init__(self):
        self.x = c.CDLL(ctypes.util.find_library('X11'))
        self.xt = c.CDLL(ctypes.util.find_library('Xtst'))
        bindings = {
            'XOpenDisplay': ([c.c_char_p], c.c_void_p),
            'XDefaultRootWindow': ([c.c_void_p], c.c_ulong),
            'XQueryTree': ([c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                            c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)], c.c_int),
            'XFetchName': ([c.c_void_p, c.c_ulong, c.POINTER(c.c_void_p)], c.c_int),
            'XGetWindowAttributes': ([c.c_void_p, c.c_ulong, c.POINTER(Attributes)], c.c_int),
            'XInternAtom': ([c.c_void_p, c.c_char_p, c.c_int], c.c_ulong),
            'XSendEvent': ([c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.c_void_p], c.c_int),
            'XSetInputFocus': ([c.c_void_p, c.c_ulong, c.c_int, c.c_ulong], c.c_int),
            'XKeysymToKeycode': ([c.c_void_p, c.c_ulong], c.c_uint),
            'XFlush': ([c.c_void_p], c.c_int),
            'XSync': ([c.c_void_p, c.c_int], c.c_int),
            'XFree': ([c.c_void_p], c.c_int),
            'XCloseDisplay': ([c.c_void_p], c.c_int),
        }
        for name, (arguments, result) in bindings.items():
            function = getattr(self.x, name)
            function.argtypes, function.restype = arguments, result
        self.xt.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
        self.errors = []
        self.error_type = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)

        def record_error(_display, _event):
            self.errors.append('X11 request failed')
            return 0

        self.error_callback = self.error_type(record_error)
        self.x.XSetErrorHandler.argtypes = [c.c_void_p]
        self.x.XSetErrorHandler.restype = c.c_void_p
        self.previous_handler = self.x.XSetErrorHandler(self.error_callback)
        self.display = self.x.XOpenDisplay(os.environ['DISPLAY'].encode())
        if not self.display:
            self.x.XSetErrorHandler(self.previous_handler)
            raise RuntimeError('Cannot open the dedicated qualification display')

    def synchronize(self):
        self.x.XSync(self.display, 0)
        if self.errors:
            raise RuntimeError(self.errors[0])

    def wait_window(self, title):
        deadline = time.monotonic() + 15
        root = self.x.XDefaultRootWindow(self.display)
        while time.monotonic() < deadline:
            actual_root, parent, count = c.c_ulong(), c.c_ulong(), c.c_uint()
            children = c.POINTER(c.c_ulong)()
            if not self.x.XQueryTree(self.display, root, c.byref(actual_root), c.byref(parent),
                                    c.byref(children), c.byref(count)):
                raise RuntimeError('Cannot enumerate the dedicated display')
            found = None
            try:
                for index in range(count.value):
                    name, attrs = c.c_void_p(), Attributes()
                    window = children[index]
                    if self.x.XFetchName(self.display, window, c.byref(name)) and name.value:
                        value = c.string_at(name).decode(errors='replace')
                        self.x.XFree(name)
                        if value == title and self.x.XGetWindowAttributes(self.display, window, c.byref(attrs)):
                            if attrs.map_state == 2:
                                found = window
            finally:
                if children:
                    self.x.XFree(children)
            self.synchronize()
            if found:
                return found
            time.sleep(.02)
        raise AssertionError(f'No mapped real Zenity window: {title}')

    def action(self, title, action, record, *, extra_buttons=2):
        window = self.wait_window(title)
        event = {'monotonic_ns': time.monotonic_ns(), 'window': window, 'title': title,
                 'action': action, 'real_window': True, 'human_gesture': False}
        with Path(record).open('a') as stream:
            stream.write(json.dumps(event) + '\n')
        if action == 'window-close':
            value = Event()
            value.client.type, value.client.display, value.client.window = 33, self.display, window
            value.client.message_type = self.x.XInternAtom(self.display, b'WM_PROTOCOLS', 0)
            value.client.format = 32
            value.client.data.l[0] = self.x.XInternAtom(self.display, b'WM_DELETE_WINDOW', 0)
            if not self.x.XSendEvent(self.display, window, 0, 0, c.byref(value)):
                raise RuntimeError('Window-close event was refused')
        else:
            self.x.XSetInputFocus(self.display, window, 1, 0)
            self.x.XFlush(self.display)
            # Let GTK consume FocusIn before traversing its button focus chain.
            # This is event-injection readiness, not an application deadline.
            time.sleep(.1)

            def key(symbol, pressed):
                code = self.x.XKeysymToKeycode(self.display, symbol)
                if not code or not self.xt.XTestFakeKeyEvent(self.display, code, pressed, 0):
                    raise RuntimeError('Keyboard event was refused')

            if action == 'new-download':
                # Traverse from Open folder through Close and any optional
                # View log button to the actual New download button.
                key(0xffe1, 1)
                for _ in range(extra_buttons + 1):
                    key(0xff09, 1)
                    key(0xff09, 0)
                key(0xffe1, 0)
                symbol = 0xff0d
            elif action == 'cancel':
                symbol = 0xff1b
            else:
                raise ValueError(action)
            key(symbol, 1)
            key(symbol, 0)
        self.x.XFlush(self.display)
        self.synchronize()

    def close(self):
        try:
            self.x.XCloseDisplay(self.display)
        finally:
            self.x.XSetErrorHandler(self.previous_handler)


class Session:
    def __init__(self, root):
        self.root = root
        self.children = []
        self.original_display = os.environ.get('DISPLAY')
        self.display = None
        self.real_zenity = shutil.which('zenity')
        if not self.real_zenity or not shutil.which('Xwayland') or not shutil.which('dbus-daemon'):
            raise RuntimeError('The optional event qualification requires Zenity, Xwayland and dbus-daemon')
        try:
            # No service directories: the fixture cannot activate a personal
            # portal, file manager, keyring or accessibility service.
            config = root / 'events-bus.conf'
            config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
                              '<auth>EXTERNAL</auth><policy context="default"><allow own="*"/>'
                              '<allow send_destination="*"/><allow receive_sender="*"/>'
                              '</policy></busconfig>')
            with (root / 'events-bus.log').open('wb') as log:
                bus = subprocess.Popen(['dbus-daemon', '--nofork', '--config-file=' + str(config),
                                        '--print-address=1'], stdout=subprocess.PIPE, stderr=log)
            self.children.append(bus)
            if not select.select([bus.stdout], [], [], 10)[0]:
                raise RuntimeError('Private D-Bus readiness timeout')
            address = bus.stdout.readline().decode().strip()
            if not address.startswith('unix:'):
                raise RuntimeError('Invalid private D-Bus address')
            read_fd, write_fd = os.pipe()
            try:
                with (root / 'events-xwayland.log').open('wb') as log:
                    server = subprocess.Popen(['Xwayland', '-rootless', '-noreset', '-nolisten', 'tcp',
                                               '-displayfd', str(write_fd)], pass_fds=(write_fd,),
                                              stdout=log, stderr=log)
                self.children.append(server)
                os.close(write_fd)
                write_fd = None
                if not select.select([read_fd], [], [], 10)[0]:
                    raise RuntimeError('Dedicated Xwayland readiness timeout')
                number = os.read(read_fd, 32).strip()
                if not number.isdigit():
                    raise RuntimeError('Invalid dedicated Xwayland display')
            finally:
                os.close(read_fd)
                if write_fd is not None:
                    os.close(write_fd)
            self.env = dict(DISPLAY=':' + number.decode(), DBUS_SESSION_BUS_ADDRESS=address,
                            GDK_BACKEND='x11', GTK_USE_PORTAL='0', NO_AT_BRIDGE='1', GTK_A11Y='none',
                            FIXTURE_REAL_ZENITY=self.real_zenity,
                            FIXTURE_X11_EVENTS=str(root / 'dialog-events.jsonl'))
            os.environ['DISPLAY'] = self.env['DISPLAY']
            self.display = Display()
        except BaseException:
            self.close()
            raise

    def progress_action(self, label, action):
        self.display.action(f'qualification:{label}:progress', action, self.env['FIXTURE_X11_EVENTS'])

    def close(self):
        failures = []
        try:
            if self.display is not None:
                try:
                    self.display.close()
                except Exception as error:
                    failures.append(error)
                self.display = None
            for process in reversed(self.children):
                try:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired as error:
                    failures.append(error)
                    # Only our unreaped direct fixture child is eligible for
                    # rescue; its timeout remains a failing qualification.
                    with (self.root / 'fixture-cleanup.jsonl').open('a') as stream:
                        stream.write(json.dumps({'monotonic_ns': time.monotonic_ns(),
                                                 'event': 'timeout-before-fixture-rescue'}) + '\n')
                    try:
                        process.kill()
                        process.wait(timeout=10)
                    except Exception as rescue_error:
                        failures.append(rescue_error)
                except Exception as error:
                    failures.append(error)
        finally:
            if self.original_display is None:
                os.environ.pop('DISPLAY', None)
            else:
                os.environ['DISPLAY'] = self.original_display
        if failures:
            raise RuntimeError('Dedicated graphical fixture cleanup failed') from failures[0]


def dialog(args):
    label = os.environ['FIXTURE_LABEL']
    record = os.environ['FIXTURE_X11_EVENTS']
    new_marker = Path(record).parent / f'{label}.new-download'
    kind = next((name for name in ('entry', 'progress', 'question', 'info', 'error', 'text-info')
                 if '--' + name in args), '')
    if '--version' in args:
        os.execv(os.environ['FIXTURE_REAL_ZENITY'], [os.environ['FIXTURE_REAL_ZENITY'], *args])
    if kind == 'entry' and not (label.startswith('entry-') or new_marker.exists()):
        print(os.environ['FIXTURE_URL'])
        return 0
    if '--file-selection' in args:
        print(os.environ['FIXTURE_OUTPUT'])
        return 0
    if '--list' in args:
        print('Complete video (MKV)')
        return 0
    title = f'qualification:{label}:{kind}'
    args = [arg for arg in args if not arg.startswith('--title=')] + ['--title=' + title]
    command = [os.environ['FIXTURE_REAL_ZENITY'], *args]
    if kind == 'progress':
        os.execv(command[0], command)
    action = 'new-download' if kind == 'question' and label == 'new-download' else 'window-close'
    if label == 'entry-cancel':
        action = 'cancel'
    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    display = None
    try:
        display = Display()
        display.action(title, action, record,
                       extra_buttons=sum(arg.startswith('--extra-button=') for arg in args))
        output, _ = process.communicate(timeout=10)
        with Path(record).open('a') as stream:
            stream.write(json.dumps({'monotonic_ns': time.monotonic_ns(), 'title': title,
                                     'event': 'dialog-result', 'status': process.returncode,
                                     'selected_new_download': output.strip() == b'New download'}) + '\n')
        if action == 'new-download':
            if output.strip() != b'New download':
                raise AssertionError(f'Injected completion action did not select New download: {output!r}')
            new_marker.write_text('real New download button selected\n')
        sys.stdout.buffer.write(output)
        return process.returncode
    except BaseException:
        # Record failure before rescue. A broken injector must never become
        # Zenity's ordinary Cancel status and produce a passing GUI outcome.
        with Path(record).open('a') as stream:
            stream.write(json.dumps({'monotonic_ns': time.monotonic_ns(), 'title': title,
                                     'event': 'adapter-failed-before-rescue'}) + '\n')
        raise
    finally:
        try:
            if display is not None:
                display.close()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


if __name__ == '__main__':
    try:
        result = dialog(sys.argv[1:])
    except Exception:
        traceback.print_exc()
        result = 70
    sys.exit(result)
