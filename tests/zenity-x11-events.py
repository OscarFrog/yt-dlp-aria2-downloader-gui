# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/zenity-x11-events.py.

Isolated X11 event adapter for multi-instance and autonomous qualification.
Input/profile/folder answers are scripted; progress, cancellation, completion
and the second entry after New download are real Zenity windows. No human
gesture is claimed. The dedicated display never selects personal windows.
"""

import ast
import ctypes as c
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import select
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback
from urllib.parse import unquote, urlsplit


def read_display_number(read_fd):
    # Xwayland can write the digits and newline separately. Keep
    # the reader open until the complete displayfd reply arrives.
    number = b''
    deadline = time.monotonic() + 10
    while not number.endswith(b'\n'):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([read_fd], [], [], remaining)[0]:
            raise RuntimeError('Dedicated Xwayland readiness timeout')
        chunk = os.read(read_fd, 1)
        if not chunk or len(number) >= 32:
            raise RuntimeError('Invalid dedicated Xwayland display')
        number += chunk
    number = number.strip()
    if not number.isdigit():
        raise RuntimeError('Invalid dedicated Xwayland display')
    return number


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


class Key(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
                ('display', c.c_void_p), ('window', c.c_ulong), ('root', c.c_ulong),
                ('subwindow', c.c_ulong), ('time', c.c_ulong), ('x', c.c_int), ('y', c.c_int),
                ('x_root', c.c_int), ('y_root', c.c_int), ('state', c.c_uint),
                ('keycode', c.c_uint), ('same_screen', c.c_int)]


class Event(c.Union):
    _fields_ = [('client', Client), ('key', Key), ('padding', c.c_long * 24)]


class Image(c.Structure):
    _fields_ = [('width', c.c_int), ('height', c.c_int), ('xoffset', c.c_int),
                ('format', c.c_int), ('data', c.c_void_p), ('byte_order', c.c_int),
                ('bitmap_unit', c.c_int), ('bitmap_bit_order', c.c_int),
                ('bitmap_pad', c.c_int), ('depth', c.c_int), ('bytes_per_line', c.c_int),
                ('bits_per_pixel', c.c_int), ('red_mask', c.c_ulong),
                ('green_mask', c.c_ulong), ('blue_mask', c.c_ulong)]


def record_event(record, **fields):
    row = dict(monotonic_ns=time.monotonic_ns(), **fields)
    encoded = (json.dumps(row, separators=(',', ':')) + '\n').encode()
    fd = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    try:
        if os.write(fd, encoded) != len(encoded):
            raise RuntimeError('Incomplete graphical evidence record')
    finally:
        os.close(fd)


class DialogSignal(BaseException):
    def __init__(self, number):
        self.number = number


class Display:
    def __init__(self):
        self.x = c.CDLL(ctypes.util.find_library('X11'))
        self.xt = c.CDLL(ctypes.util.find_library('Xtst'))
        bindings = {
            'XOpenDisplay': ([c.c_char_p], c.c_void_p),
            'XCreateSimpleWindow': ([c.c_void_p, c.c_ulong, c.c_int, c.c_int, c.c_uint,
                                     c.c_uint, c.c_uint, c.c_ulong, c.c_ulong], c.c_ulong),
            'XStoreName': ([c.c_void_p, c.c_ulong, c.c_char_p], c.c_int),
            'XSelectInput': ([c.c_void_p, c.c_ulong, c.c_long], c.c_int),
            'XMapWindow': ([c.c_void_p, c.c_ulong], c.c_int),
            'XDestroyWindow': ([c.c_void_p, c.c_ulong], c.c_int),
            'XGetInputFocus': ([c.c_void_p, c.POINTER(c.c_ulong), c.POINTER(c.c_int)], c.c_int),
            'XPending': ([c.c_void_p], c.c_int),
            'XNextEvent': ([c.c_void_p, c.POINTER(Event)], c.c_int),
            'XDefaultRootWindow': ([c.c_void_p], c.c_ulong),
            'XQueryTree': ([c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                            c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)], c.c_int),
            'XFetchName': ([c.c_void_p, c.c_ulong, c.POINTER(c.c_void_p)], c.c_int),
            'XGetWindowProperty': ([c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long,
                                    c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int),
                                    c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                                    c.POINTER(c.c_void_p)], c.c_int),
            'XGetWindowAttributes': ([c.c_void_p, c.c_ulong, c.POINTER(Attributes)], c.c_int),
            'XInternAtom': ([c.c_void_p, c.c_char_p, c.c_int], c.c_ulong),
            'XSendEvent': ([c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.c_void_p], c.c_int),
            'XSetInputFocus': ([c.c_void_p, c.c_ulong, c.c_int, c.c_ulong], c.c_int),
            'XKeysymToKeycode': ([c.c_void_p, c.c_ulong], c.c_uint),
            'XFlush': ([c.c_void_p], c.c_int),
            'XSync': ([c.c_void_p, c.c_int], c.c_int),
            'XFree': ([c.c_void_p], c.c_int),
            'XCloseDisplay': ([c.c_void_p], c.c_int),
            'XGetImage': ([c.c_void_p, c.c_ulong, c.c_int, c.c_int, c.c_uint,
                          c.c_uint, c.c_ulong, c.c_int], c.POINTER(Image)),
            'XGetPixel': ([c.POINTER(Image), c.c_int, c.c_int], c.c_ulong),
            'XDestroyImage': ([c.POINTER(Image)], c.c_int),
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
        while time.monotonic() < deadline:
            matches = [row['window'] for row in self.mapped_windows() if row['title'] == title]
            if len(matches) > 1:
                raise AssertionError('Ambiguous real qualification window')
            if matches:
                return matches[0]
            time.sleep(.02)
        raise AssertionError(f'No mapped real Zenity window: {title}')

    def mapped_windows(self):
        root = self.x.XDefaultRootWindow(self.display)
        actual_root, parent, count = c.c_ulong(), c.c_ulong(), c.c_uint()
        children = c.POINTER(c.c_ulong)()
        if not self.x.XQueryTree(self.display, root, c.byref(actual_root), c.byref(parent),
                                c.byref(children), c.byref(count)):
            raise RuntimeError('Cannot enumerate the dedicated display')
        rows = []
        try:
            for index in range(count.value):
                attrs = Attributes()
                window = children[index]
                title = self.window_title(window)
                if title is not None:
                    if self.x.XGetWindowAttributes(self.display, window, c.byref(attrs)) and attrs.map_state == 2:
                        rows.append(dict(window=window, title=title))
        finally:
            if children:
                self.x.XFree(children)
        self.synchronize()
        return rows

    def window_title(self, window):
        # GTK's legacy WM_NAME can use Latin-1. Read the bounded UTF-8 property
        # first so a selected folder containing accents retains its identity.
        prop = self.x.XInternAtom(self.display, b'_NET_WM_NAME', 0)
        utf8 = self.x.XInternAtom(self.display, b'UTF8_STRING', 0)
        actual, length, remaining = c.c_ulong(), c.c_ulong(), c.c_ulong()
        fmt, value = c.c_int(), c.c_void_p()
        status = self.x.XGetWindowProperty(self.display, window, prop, 0, 2048, 0, utf8,
                                          c.byref(actual), c.byref(fmt), c.byref(length),
                                          c.byref(remaining), c.byref(value))
        try:
            if status != 0:
                raise RuntimeError('Cannot read qualification window title')
            if actual.value:
                if actual.value != utf8 or fmt.value != 8 or (length.value and not value.value):
                    raise RuntimeError('Invalid qualification window title property')
                if remaining.value or length.value > 8192:
                    raise RuntimeError('Oversized qualification window title')
                return c.string_at(value, length.value).decode('utf-8')
        finally:
            if value.value:
                self.x.XFree(value)
        value = c.c_void_p()
        if self.x.XFetchName(self.display, window, c.byref(value)) and value.value:
            try:
                return c.string_at(value).decode('latin-1')
            finally:
                self.x.XFree(value)
        return None

    def capture(self, title, record):
        """Retain pixels from a known fixture window, never the desktop root."""
        window = self.wait_window(title)
        attrs = Attributes()
        if not self.x.XGetWindowAttributes(self.display, window, c.byref(attrs)):
            raise RuntimeError('Cannot inspect the qualification window')
        if not (1 <= attrs.width <= 4096 and 1 <= attrs.height <= 4096):
            raise RuntimeError('Qualification window dimensions are out of bounds')
        value = self.x.XGetImage(self.display, window, 0, 0, attrs.width, attrs.height,
                                c.c_ulong(-1).value, 2)
        self.synchronize()
        if not value:
            raise RuntimeError('Cannot capture the qualification window')
        try:
            masks = [value.contents.red_mask, value.contents.green_mask, value.contents.blue_mask]
            if any(mask == 0 for mask in masks):
                raise RuntimeError('Unsupported qualification image format')
            shifts = [(mask & -mask).bit_length() - 1 for mask in masks]
            maxima = [mask >> shift for mask, shift in zip(masks, shifts)]
            pixels = bytearray()
            for y in range(attrs.height):
                for x in range(attrs.width):
                    pixel = self.x.XGetPixel(value, x, y)
                    pixels.extend(((pixel & mask) >> shift) * 255 // maximum
                                  for mask, shift, maximum in zip(masks, shifts, maxima))
            first_pixel = pixels[:3]
            if all(pixels[index:index + 3] == first_pixel for index in range(0, len(pixels), 3)):
                raise RuntimeError('Qualification window rendered no distinguishable pixels')
            data = f'P6\n{attrs.width} {attrs.height}\n255\n'.encode() + pixels
            name = f'window-{window}-{time.monotonic_ns()}.ppm'
            with (Path(record).parent / name).open('xb') as output:
                output.write(data)
            return dict(window=window, real_window=True, screenshot=name,
                        screenshot_sha256=hashlib.sha256(data).hexdigest(),
                        width=attrs.width, height=attrs.height)
        finally:
            self.x.XDestroyImage(value)

    def prepare_keyboard(self, record):
        # Xwayland can accept the first XTest pair without delivering it while
        # its optional EI path initializes/fails. Prove complete delivery in
        # our own disposable window before any semantic Zenity gesture.
        title = 'qualification:keyboard-readiness'
        root = self.x.XDefaultRootWindow(self.display)
        window = self.x.XCreateSimpleWindow(self.display, root, 0, 0, 160, 80, 0, 0, 0xffffff)
        completed = 0
        attempts = 0
        pressed = False
        try:
            self.x.XStoreName(self.display, window, title.encode())
            self.x.XSelectInput(self.display, window, 3)  # KeyPressMask | KeyReleaseMask
            self.x.XMapWindow(self.display, window)
            self.synchronize()
            if self.wait_window(title) != window:
                raise RuntimeError('Keyboard readiness window identity changed')
            self.x.XSetInputFocus(self.display, window, 1, 0)
            self.synchronize()
            focus, revert = c.c_ulong(), c.c_int()
            self.x.XGetInputFocus(self.display, c.byref(focus), c.byref(revert))
            self.synchronize()
            if focus.value != window:
                raise RuntimeError('Keyboard readiness window did not acquire focus')
            code = self.x.XKeysymToKeycode(self.display, 0xff1b)
            deadline = time.monotonic() + 10
            next_pair = 0.0
            while completed < 2 and time.monotonic() < deadline:
                while self.x.XPending(self.display):
                    value = Event()
                    self.x.XNextEvent(self.display, c.byref(value))
                    if value.key.window != window or value.key.keycode != code:
                        continue
                    if value.key.type == 2:
                        pressed = True
                    elif value.key.type == 3 and pressed:
                        completed += 1
                        pressed = False
                if completed >= 2:
                    break
                if time.monotonic() >= next_pair:
                    for state in (1, 0):
                        if not code or not self.xt.XTestFakeKeyEvent(self.display, code, state, 0):
                            raise RuntimeError('Keyboard readiness event was refused')
                    attempts += 1
                    self.synchronize()
                    next_pair = time.monotonic() + .05
                time.sleep(.005)
            with Path(record).open('a') as stream:
                stream.write(json.dumps({'monotonic_ns': time.monotonic_ns(),
                                         'event': 'keyboard-readiness-before-dialogs', 'title': title,
                                         'window': window, 'attempts': attempts,
                                         'completed_pairs': completed}) + '\n')
            if completed < 2 or pressed:
                raise RuntimeError('Keyboard readiness requires two complete received pairs')
        finally:
            self.x.XDestroyWindow(self.display, window)
            self.synchronize()

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
                # Leave the entry field before activating the Cancel button.
                # Escape has a separate response and must stay a distinct action.
                if title.endswith(':entry'):
                    key(0xff09, 1)
                    key(0xff09, 0)
                    self.synchronize()
                elif not title.endswith(':progress'):
                    raise ValueError('Cancel button traversal requires entry or progress')
                symbol = 0x20
            elif action == 'escape':
                symbol = 0xff1b
            elif action == 'open-folder':
                symbol = 0xff0d
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
                number = read_display_number(read_fd)
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
            self.display.prepare_keyboard(self.env['FIXTURE_X11_EVENTS'])
        except BaseException:
            self.close()
            raise

    def progress_action(self, label, action):
        self.display.action(f'qualification:{label}:progress', action, self.env['FIXTURE_X11_EVENTS'])

    def wait_window(self, label, kind):
        return self.display.wait_window(f'qualification:{label}:{kind}')

    def mapped_windows(self):
        return self.display.mapped_windows()

    def assert_no_windows(self, label):
        prefix = f'qualification:{label}:'
        if any(row['title'].startswith(prefix) for row in self.mapped_windows()):
            raise AssertionError('Qualification left a mapped application window')

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
    if os.environ.get('FIXTURE_AUTONOMOUS') == '1':
        return autonomous_dialog(args)
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
    if label == 'entry-cancel' and kind == 'entry':
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


def autonomous_dialog(args):
    """Drive real outcome dialogs; fixture request selections are explicit data."""
    label = os.environ['FIXTURE_LABEL']
    if not re.fullmatch(r'[A-Za-z0-9_-]+', label):
        raise ValueError('Invalid autonomous scenario label')
    scenario = os.environ['FIXTURE_SCENARIO']
    record = os.environ['FIXTURE_X11_EVENTS']
    marker = Path(record).parent / f'{label}.new-download'
    if '--version' in args:
        os.execv(os.environ['FIXTURE_REAL_ZENITY'], [os.environ['FIXTURE_REAL_ZENITY'], *args])
    kind = next((name for name in ('entry', 'progress', 'question', 'info', 'error', 'text-info')
                 if '--' + name in args), '')
    if kind == 'entry' and scenario != 'signal-entry' and not marker.exists():
        print(os.environ['FIXTURE_URL'])
        return 0
    if '--file-selection' in args:
        print(os.environ['FIXTURE_OUTPUT'])
        return 0
    if '--list' in args:
        print('Complete video (MKV)')
        return 0
    if not kind:
        raise RuntimeError('Unsupported autonomous dialog')
    text = next((arg[7:] for arg in args if arg.startswith('--text=')), '')
    classification = ('success' if text.startswith('The download is complete.') else
                      'error' if kind == 'error' or '--ok-label=View log' in args else 'other')
    title = f'qualification:{label}:{kind}'
    common = dict(title=title, dialog=kind, classification=classification)
    args = [arg for arg in args if not arg.startswith('--title=')] + ['--title=' + title]
    command = [os.environ['FIXTURE_REAL_ZENITY'], *args]
    process = None
    display = None
    old_handlers = {}

    def forward_signal(number, _frame):
        # The application's registered Zenity PID is this adapter. Retain its
        # ordinary shutdown semantics by forwarding to and collecting our own
        # real dialog child before the registered process can finish.
        for observed_signal in old_handlers:
            signal.signal(observed_signal, signal.SIG_IGN)
        if process is not None and process.poll() is None:
            process.send_signal(number)
            process.wait(timeout=10)
        raise DialogSignal(number)

    try:
        if classification == 'success':
            expected = Path(os.environ['FIXTURE_EXPECTED_FINAL'])
            if (text != 'The download is complete.\n\nFile: ' + str(expected)
                    or not expected.is_file() or expected.is_symlink() or '--no-markup' not in args):
                raise AssertionError('Completion dialog does not identify the verified final file')
            common['displayed_path_exact'] = True
            common['displayed_path_sha256'] = hashlib.sha256(os.fsencode(expected)).hexdigest()
        process = subprocess.Popen(command, stdin=subprocess.PIPE if kind == 'progress' else None,
                                   stdout=subprocess.PIPE)
        old_handlers = {number: signal.signal(number, forward_signal)
                        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
        display = Display()
        display.wait_window(title)
        # A mapped window can precede GTK's first paint. This bounded readiness
        # pause does not retry an action or extend its ten-second result budget.
        time.sleep(.1)
        record_event(record, event='window-mapped', **common, **display.capture(title, record))
        if kind == 'progress':
            pending = b''
            captured_progress = False
            input_open = True
            publication_hold = None
            while process.poll() is None:
                if publication_hold is not None and time.monotonic() >= publication_hold:
                    raise AssertionError('Published-result graphical race action timed out')
                if not input_open:
                    if publication_hold is None:
                        process.wait(timeout=10)
                        break
                    time.sleep(.02)
                    continue
                if not select.select([sys.stdin.buffer], [], [], .05)[0]:
                    continue
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    input_open = False
                    if publication_hold is None:
                        process.stdin.close()
                    continue
                pending += data
                if len(pending) > 65536:
                    raise RuntimeError('Oversized autonomous progress frame')
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    hold = (line == b'100' and scenario == 'cancel-success-race'
                            and os.environ.get('FIXTURE_RACE_SIDE') == 'after-publication')
                    if hold:
                        if publication_hold is None:
                            publication_hold = time.monotonic() + 10
                            record_event(record, event='race-publication-barrier', **common)
                    elif publication_hold is None:
                        try:
                            process.stdin.write(line + b'\n')
                            process.stdin.flush()
                        except BrokenPipeError:
                            process.wait(timeout=10)
                            break
                    if re.fullmatch(rb'[0-9]{1,3}', line):
                        value = int(line)
                        if not 0 <= value <= 100:
                            raise RuntimeError('Invalid autonomous progress percentage')
                        record_event(record, event='progress-value', value=value, **common)
                        if 5 <= value < 100 and not captured_progress:
                            time.sleep(.05)
                            record_event(record, event='progress-rendered', value=value,
                                         **common, **display.capture(title, record))
                            captured_progress = True
            output = process.stdout.read()
            selected = None
        elif scenario == 'signal-entry' and kind == 'entry':
            # The coordinator sends TERM to the GUI only after this proof is
            # visible. The ordinary GUI supervisor owns the dialog shutdown.
            output, _ = process.communicate(timeout=30)
            selected = None
        else:
            selected = ('new-download' if scenario == 'new-download' and classification == 'success'
                        else 'open-folder' if scenario == 'open-folder' and classification == 'success'
                        else 'cancel' if kind == 'entry' else 'window-close')
            display.action(title, selected, record,
                           extra_buttons=sum(arg.startswith('--extra-button=') for arg in args))
            output, _ = process.communicate(timeout=10)
            if selected == 'new-download':
                if process.returncode not in (0, 1) or output.strip() != b'New download':
                    raise AssertionError('Real completion New download mismatch: '
                                         f'status={process.returncode}, selected={output.strip() == b"New download"}')
                marker.write_text('real New download button selected\n')
            if selected == 'open-folder' and (process.returncode != 0 or output.strip()):
                raise AssertionError('Real completion did not select Open folder')
        record_event(record, event='dialog-result', status=process.returncode,
                     selected_action=selected, **common)
        sys.stdout.buffer.write(output)
        return process.returncode
    except DialogSignal as stopped:
        record_event(record, event='dialog-signal', signal=stopped.number, **common)
        return 128 + stopped.number
    except BaseException:
        record_event(record, event='adapter-failed-before-rescue', **common)
        raise
    finally:
        try:
            if display is not None:
                display.close()
        finally:
            try:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
            finally:
                for number, handler in old_handlers.items():
                    signal.signal(number, handler)


def autonomous_open_folder(args):
    """Open the exact selected synthetic directory on the private display/bus."""
    record = os.environ['FIXTURE_X11_EVENTS']
    label = os.environ['FIXTURE_LABEL']
    title = f'qualification:{label}:folder'
    display = None
    process = None
    manager = shutil.which('nautilus')
    try:
        expected = Path(os.environ['FIXTURE_OUTPUT'])
        if len(args) != 1 or Path(args[0]) != expected or expected.is_symlink() or not expected.is_dir():
            raise AssertionError('Open folder did not name the exact selected directory')
        if not manager:
            raise RuntimeError('Autonomous Open folder requires Nautilus')
        process = subprocess.Popen([manager, '--new-window', str(expected)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        display = Display()
        display.wait_window(expected.name)
        deadline = time.monotonic() + 10
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError('Selected file-manager location was not initialized')
            locations = subprocess.run(
                ['gdbus', 'call', '--session', '--dest', 'org.gnome.Nautilus',
                 '--object-path', '/org/freedesktop/FileManager1',
                 '--method', 'org.freedesktop.DBus.Properties.Get',
                 'org.freedesktop.FileManager1', 'OpenLocations'],
                check=True, timeout=remaining, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            encoded = locations.stdout.strip()
            if encoded not in ('(<@as []>,)', '(<[]>,)'):
                break
            # The mapped window can precede its initial navigation property.
            # Only an explicitly empty property permits this readiness wait.
            time.sleep(.02)
        if len(encoded) > 16384 or not encoded.startswith('(<[') or not encoded.endswith(']>,)'):
            raise AssertionError('File manager did not expose its selected location')
        opened = ast.literal_eval(encoded[2:-3])
        if not isinstance(opened, list) or len(opened) != 1 or not isinstance(opened[0], str):
            raise AssertionError('File manager exposed ambiguous selected locations')
        location = urlsplit(opened[0])
        if (location.scheme != 'file' or location.netloc or location.query or location.fragment
                or unquote(location.path, errors='strict') != str(expected)):
            raise AssertionError('File manager did not navigate to the selected destination')
        proof = display.capture(expected.name, record)
        record_event(record, event='folder-mapped', title=title, destination_exact=True,
                     location_property_exact=True,
                     destination_sha256=hashlib.sha256(os.fsencode(expected)).hexdigest(), **proof)
        release = Path(record).parent / f'{label}.viewer-release'
        deadline = time.monotonic() + 10
        while not release.exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError('Folder viewer did not survive until the GUI exit observation')
            time.sleep(.02)
        display.action(expected.name, 'window-close', record)
        deadline = time.monotonic() + 10
        while any(row['title'] == expected.name for row in display.mapped_windows()):
            if time.monotonic() >= deadline:
                raise AssertionError('Selected folder window did not close')
            time.sleep(.02)
        # Nautilus may keep its private application alive after its last window.
        # This shutdown addresses only the service-free bus owned by this fixture.
        quit_status = None
        if process.poll() is None:
            quit_status = subprocess.run([manager, '--quit'], timeout=10,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        process.wait(timeout=10)
        if process.returncode != 0:
            raise AssertionError('Isolated file manager failed')
        # The remote --quit client can return 255 after delivering the request.
        # The owned primary's successful exit and absence of its window, rather
        # than that client's convention, are the actual viewer shutdown proof.
        record_event(record, event='folder-closed', title=title,
                     viewer_status=process.returncode, quit_client_status=quit_status)
        return 0
    except BaseException:
        record_event(record, event='adapter-failed-before-rescue', title=title)
        raise
    finally:
        try:
            if display is not None:
                display.close()
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['--autonomous-open-folder'] and os.environ.get('FIXTURE_AUTONOMOUS') == '1':
            result = autonomous_open_folder(sys.argv[2:])
        else:
            result = dialog(sys.argv[1:])
    except Exception:
        traceback.print_exc()
        result = 70
    sys.exit(result)
