# SPDX-License-Identifier: MIT
"""
Manage portable desktop-launcher files through anchored directory descriptors.

Project: yt-dlp-aria2-downloader-gui
Repository path: private-launcher-manager.py

The helper opens every XDG path component without following symbolic links,
keeps the managed directories open across each transaction, and performs all
publication and removal relative to those descriptors. This prevents a
concurrent path replacement from redirecting launcher mutations elsewhere.
Transactions sharing one data root are serialized, and private hard-link
backups support a best-effort restoration of the preceding managed leaves after
partial publication errors.

This file is intentionally non-executable. Invoke it explicitly with python3.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import re
import secrets
import select
import shutil
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager


APP_ID = "yt-dlp-aria2-downloader"
DESKTOP_NAME = f"{APP_ID}.desktop"
ICON_NAME = f"{APP_ID}.svg"
MAX_ASSET_BYTES = 1024 * 1024
MAX_VALIDATOR_OUTPUT_BYTES = 64 * 1024
EXIT_VALIDATION = 65
EXIT_IO = 70
EXIT_TEMPORARY = 75
MAX_DIRECTORY_BIND_ATTEMPTS = 8
MAX_REMOVAL_ATTEMPTS = 8
LOCK_TIMEOUT_SECONDS = 10.0
VALIDATOR_TIMEOUT_SECONDS = 10.0
CURRENT_TOKEN_RE = re.compile(r"^[0-9a-f]{24}$")
LEGACY_TOKEN_RE = re.compile(r"^[A-Za-z0-9]{8}$")
EMBEDDED_ICON = b"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg"
     width="256" height="256" viewBox="0 0 256 256">
  <title>yt-dlp aria2 downloader</title>
  <rect x="16" y="16" width="224" height="224" rx="48"
        fill="#2864dc"/>
  <path d="M83 68v92l78-46z" fill="#ffffff"/>
  <path d="M128 136v48m-24-24 24 24 24-24"
        fill="none" stroke="#ffffff" stroke-width="16"
        stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M88 204h80" fill="none" stroke="#ffffff"
        stroke-width="14" stroke-linecap="round"/>
</svg>
"""

AnchorHook = Callable[[], None]
SHUTDOWN_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
SIGNAL_EXIT_STATUSES = {
    signal.SIGHUP: 129,
    signal.SIGINT: 130,
    signal.SIGTERM: 143,
}
_pending_shutdown_signal: int | None = None
_shutdown_deferral_depth = 0
_shutdown_delivery_safe = False


class LauncherError(Exception):
    """Expected launcher validation or containment failure."""


class ReportedLauncherError(LauncherError):
    """Failure whose complete user-facing diagnostic was already emitted."""


class TemporaryLauncherError(LauncherError):
    """Bounded transient failure that a later invocation may resolve."""


class LauncherInterruptedError(BaseException):
    """Requested process shutdown after transaction cleanup or rollback."""

    def __init__(self, signal_number: int) -> None:
        self.signal_number = signal_number
        self.exit_status = SIGNAL_EXIT_STATUSES[signal_number]
        super().__init__(f"launcher transaction interrupted by signal {signal_number}")


def raise_pending_shutdown() -> None:
    """Raise a recorded shutdown only at an explicitly safe checkpoint."""

    if _pending_shutdown_signal is not None and _shutdown_deferral_depth == 0:
        raise LauncherInterruptedError(_pending_shutdown_signal)


def shutdown_requested() -> bool:
    return _pending_shutdown_signal is not None


@contextmanager
def defer_shutdown_interruptions() -> Iterator[None]:
    """Finish rollback or cleanup before honoring a pending shutdown."""

    global _shutdown_deferral_depth

    _shutdown_deferral_depth += 1
    try:
        yield
    finally:
        _shutdown_deferral_depth -= 1
        if _shutdown_deferral_depth == 0:
            raise_pending_shutdown()


def request_shutdown(signal_number: int, _frame: object) -> None:
    """Record shutdown without raising inside an unknown critical instruction."""

    global _pending_shutdown_signal

    first_request = _pending_shutdown_signal is None
    if first_request:
        _pending_shutdown_signal = signal_number
    # Later callbacks are intentional no-ops until delivery becomes safe. Do
    # not mutate signal dispositions from inside a handler: another managed
    # signal can arrive concurrently and make signal.signal() itself fail.
    if first_request and _shutdown_delivery_safe:
        raise LauncherInterruptedError(_pending_shutdown_signal)


def install_shutdown_signal_handlers() -> None:
    """Install shutdown handlers before the helper can mutate managed files."""

    global _pending_shutdown_signal, _shutdown_deferral_depth
    global _shutdown_delivery_safe

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, SHUTDOWN_SIGNALS)
    try:
        _pending_shutdown_signal = None
        _shutdown_deferral_depth = 0
        _shutdown_delivery_safe = False
        for managed_signal in SHUTDOWN_SIGNALS:
            signal.signal(managed_signal, request_shutdown)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def enable_immediate_shutdown_delivery() -> None:
    """Close the final checkpoint-to-process-exit signal window."""

    global _shutdown_delivery_safe

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, SHUTDOWN_SIGNALS)
    try:
        _shutdown_delivery_safe = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    raise_pending_shutdown()


def directory_open_flags() -> int:
    required_flags = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")

    for flag_name in required_flags:
        if not hasattr(os, flag_name):
            raise LauncherError(
                "this platform cannot provide no-follow directory operations"
            )

    return os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW


def data_home_components(data_home: str) -> list[str]:
    if not data_home.startswith("/"):
        raise LauncherError("XDG_DATA_HOME must resolve to an absolute path")
    if data_home == "/" or not data_home.strip("/"):
        raise LauncherError("refusing the filesystem root as XDG data home")

    components = [component for component in data_home.split("/") if component]
    if any(component in {".", ".."} for component in components):
        raise LauncherError(
            f"refusing a non-canonical XDG data path component: {data_home}"
        )
    return components


def child_display_path(parent_display: str, name: str) -> str:
    return f"{parent_display.rstrip('/')}/{name}"


def open_child_directory(
    parent_fd: int,
    name: str,
    display_path: str,
    *,
    create: bool,
    missing_ok: bool = False,
) -> int | None:
    flags = directory_open_flags()

    for _attempt in range(MAX_DIRECTORY_BIND_ATTEMPTS):
        try:
            path_stat = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            if not create:
                if missing_ok:
                    return None
                raise LauncherError(
                    f"installation directory does not exist: {display_path}"
                ) from None
            try:
                os.mkdir(name, mode=0o700, dir_fd=parent_fd)
            except FileExistsError:
                continue
            except OSError as exc:
                raise LauncherError(
                    f"unable to create installation directory: {display_path}"
                ) from exc
            continue

        if stat.S_ISLNK(path_stat.st_mode):
            raise LauncherError(
                f"refusing a symbolic-link installation directory: {display_path}"
            )
        if not stat.S_ISDIR(path_stat.st_mode):
            raise LauncherError(
                f"installation path is not a directory: {display_path}"
            )

        try:
            directory_fd = os.open(name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            continue
        except OSError as exc:
            if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                raise LauncherError(
                    f"refusing an unsafe installation directory: {display_path}"
                ) from exc
            raise LauncherError(
                f"unable to open installation directory: {display_path}"
            ) from exc

        descriptor_stat = os.fstat(directory_fd)
        if (
            descriptor_stat.st_dev == path_stat.st_dev
            and descriptor_stat.st_ino == path_stat.st_ino
        ):
            return directory_fd
        os.close(directory_fd)

    raise LauncherError(
        f"installation directory changed repeatedly while opening: {display_path}"
    )


def open_data_home(data_home: str, *, create: bool) -> int | None:
    components = data_home_components(data_home)
    current_fd = os.open("/", directory_open_flags())
    current_display = "/"

    try:
        for component in components:
            next_display = child_display_path(current_display, component)
            next_fd = open_child_directory(
                current_fd,
                component,
                next_display,
                create=create,
                missing_ok=not create,
            )
            if next_fd is None:
                os.close(current_fd)
                return None
            os.close(current_fd)
            current_fd = next_fd
            current_display = next_display
    except Exception:
        os.close(current_fd)
        raise

    return current_fd


def open_directory_branch(
    root_fd: int,
    root_display: str,
    components: tuple[str, ...],
    *,
    create: bool,
) -> int | None:
    current_fd = os.dup(root_fd)
    current_display = root_display.rstrip("/") or "/"

    try:
        for component in components:
            next_display = child_display_path(current_display, component)
            next_fd = open_child_directory(
                current_fd,
                component,
                next_display,
                create=create,
                missing_ok=not create,
            )
            if next_fd is None:
                os.close(current_fd)
                return None
            os.close(current_fd)
            current_fd = next_fd
            current_display = next_display
    except Exception:
        os.close(current_fd)
        raise

    return current_fd


def register_fd(stack: ExitStack, descriptor: int | None) -> int | None:
    if descriptor is not None:
        stack.callback(close_fd_best_effort, descriptor)
    return descriptor


def close_fd_best_effort(descriptor: int) -> None:
    """Close an anchored descriptor without masking the primary outcome."""

    try:
        os.close(descriptor)
    except OSError as exc:
        print(
            f"Warning: unable to close launcher descriptor {descriptor}: {exc}.",
            file=sys.stderr,
        )


def validate_user_directory(descriptor: int, display_path: str) -> None:
    directory_stat = os.fstat(descriptor)
    if directory_stat.st_uid != os.geteuid():
        raise LauncherError(
            f"installation directory is not owned by the current user: {display_path}"
        )
    if stat.S_IMODE(directory_stat.st_mode) & 0o022:
        raise LauncherError(
            "installation directory is writable by group or other users: "
            f"{display_path}"
        )


def lock_data_home(descriptor: int, display_path: str) -> None:
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        raise_pending_shutdown()
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raise_pending_shutdown()
            return
        except OSError as exc:
            if exc.errno not in {errno.EACCES, errno.EAGAIN}:
                raise LauncherError(
                    f"unable to lock the launcher data directory: {display_path}"
                ) from exc
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TemporaryLauncherError(
                f"timed out waiting for another launcher transaction: {display_path}"
            )
        time.sleep(min(0.05, remaining))
        raise_pending_shutdown()


def open_managed_directories(
    data_home: str,
    *,
    create: bool,
    stack: ExitStack,
) -> tuple[int | None, int | None, int | None, int | None]:
    data_fd = register_fd(stack, open_data_home(data_home, create=create))
    if data_fd is None:
        return None, None, None, None
    validate_user_directory(data_fd, data_home)
    lock_data_home(data_fd, data_home)
    validate_data_home_path_identity(data_home, data_fd)
    validate_user_directory(data_fd, data_home)

    applications_fd = register_fd(
        stack,
        open_directory_branch(
            data_fd,
            data_home,
            ("applications",),
            create=create,
        ),
    )
    launcher_fd = register_fd(
        stack,
        open_directory_branch(
            data_fd,
            data_home,
            (APP_ID,),
            create=create,
        ),
    )
    icon_fd = register_fd(
        stack,
        open_directory_branch(
            data_fd,
            data_home,
            ("icons", "hicolor", "scalable", "apps"),
            create=create,
        ),
    )
    if applications_fd is not None:
        validate_user_directory(
            applications_fd,
            child_display_path(data_home, "applications"),
        )
    if launcher_fd is not None:
        validate_user_directory(
            launcher_fd,
            child_display_path(data_home, APP_ID),
        )
    if icon_fd is not None:
        validate_user_directory(
            icon_fd,
            child_display_path(data_home, "icons/hicolor/scalable/apps"),
        )
    return data_fd, applications_fd, launcher_fd, icon_fd


def validate_data_home_path_identity(data_home: str, anchored_fd: int) -> None:
    try:
        current_fd = open_data_home(data_home, create=False)
    except LauncherError as exc:
        raise LauncherError(
            "XDG data home changed during the launcher transaction"
        ) from exc
    if current_fd is None:
        raise LauncherError("XDG data home changed during the launcher transaction")

    try:
        anchored_stat = os.fstat(anchored_fd)
        current_stat = os.fstat(current_fd)
    finally:
        os.close(current_fd)
    if (
        anchored_stat.st_dev != current_stat.st_dev
        or anchored_stat.st_ino != current_stat.st_ino
    ):
        raise LauncherError("XDG data home changed during the launcher transaction")


def validate_directory_branch_identity(
    data_fd: int,
    data_home: str,
    components: tuple[str, ...],
    anchored_fd: int | None,
    *,
    expect_absent: bool = False,
) -> None:
    try:
        current_fd = open_directory_branch(
            data_fd,
            data_home,
            components,
            create=False,
        )
    except LauncherError as exc:
        raise LauncherError(
            "managed launcher directory changed during the transaction: "
            + "/".join(components)
        ) from exc

    if expect_absent or anchored_fd is None:
        if current_fd is not None:
            os.close(current_fd)
            raise LauncherError(
                "managed launcher directory appeared during the transaction: "
                + "/".join(components)
            )
        return
    if current_fd is None:
        raise LauncherError(
            "managed launcher directory disappeared during the transaction: "
            + "/".join(components)
        )

    try:
        anchored_stat = os.fstat(anchored_fd)
        current_stat = os.fstat(current_fd)
    finally:
        os.close(current_fd)
    if (
        anchored_stat.st_dev != current_stat.st_dev
        or anchored_stat.st_ino != current_stat.st_ino
    ):
        raise LauncherError(
            "managed launcher directory changed during the transaction: "
            + "/".join(components)
        )


def validate_managed_path_identities(
    data_home: str,
    data_fd: int,
    applications_fd: int | None,
    launcher_fd: int | None,
    icon_fd: int | None,
    *,
    launcher_removed: bool = False,
) -> None:
    validate_data_home_path_identity(data_home, data_fd)
    validate_directory_branch_identity(
        data_fd,
        data_home,
        ("applications",),
        applications_fd,
    )
    validate_directory_branch_identity(
        data_fd,
        data_home,
        (APP_ID,),
        launcher_fd,
        expect_absent=launcher_removed,
    )
    validate_directory_branch_identity(
        data_fd,
        data_home,
        ("icons", "hicolor", "scalable", "apps"),
        icon_fd,
    )
    validate_data_home_path_identity(data_home, data_fd)


def read_bounded_regular_file(path: str, label: str) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK

    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise LauncherError(f"unable to open {label}") from exc

    try:
        source_stat = os.fstat(descriptor)
        if not stat.S_ISREG(source_stat.st_mode):
            raise LauncherError(f"{label} is not a regular non-symlink file")
        if source_stat.st_size > MAX_ASSET_BYTES:
            raise LauncherError(f"{label} exceeds the one-MiB safety limit")

        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, MAX_ASSET_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_ASSET_BYTES:
                raise LauncherError(f"{label} exceeds the one-MiB safety limit")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def read_icon_content(path: str) -> bytes:
    try:
        source_stat = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return EMBEDDED_ICON
    except OSError as exc:
        raise LauncherError("unable to inspect icon source") from exc

    if stat.S_ISLNK(source_stat.st_mode) or not stat.S_ISREG(source_stat.st_mode):
        return EMBEDDED_ICON
    return read_bounded_regular_file(path, "icon source")


def executable_by_current_user(file_stat: os.stat_result) -> bool:
    execute_mask = stat.S_IXOTH
    if os.geteuid() == 0:
        return bool(stat.S_IMODE(file_stat.st_mode) & 0o111)
    if file_stat.st_uid == os.geteuid():
        execute_mask = stat.S_IXUSR
    elif file_stat.st_gid == os.getegid() or file_stat.st_gid in os.getgroups():
        execute_mask = stat.S_IXGRP
    return bool(file_stat.st_mode & execute_mask)


def open_launcher_target(path: str) -> int:
    if not os.path.isabs(path):
        raise LauncherError("launcher target must be an absolute path")

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise LauncherError(f"launcher target is absent or unsafe: {path}") from exc

    try:
        target_stat = os.fstat(descriptor)
        if not stat.S_ISREG(target_stat.st_mode) or not executable_by_current_user(
            target_stat
        ):
            raise LauncherError(
                f"launcher target is not a regular executable file: {path}"
            )
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def validate_launcher_target_identity(path: str, anchored_fd: int) -> None:
    try:
        current_fd = open_launcher_target(path)
    except LauncherError as exc:
        raise LauncherError(
            f"launcher target changed during the transaction: {path}"
        ) from exc
    try:
        anchored_stat = os.fstat(anchored_fd)
        current_stat = os.fstat(current_fd)
    finally:
        os.close(current_fd)
    if (
        anchored_stat.st_dev != current_stat.st_dev
        or anchored_stat.st_ino != current_stat.st_ino
    ):
        raise LauncherError(f"launcher target changed during the transaction: {path}")


def quote_desktop_exec_path(value: str) -> str:
    value = value.replace("\\", "\\\\\\\\")
    value = value.replace('"', '\\\\"')
    value = value.replace("`", "\\\\`")
    value = value.replace("$", "\\\\$")
    return f'"{value}"'


def build_desktop_content(data_home: str) -> bytes:
    launcher_path = child_display_path(child_display_path(data_home, APP_ID), "launch")
    if any(character in launcher_path for character in ("%", "=", "\n", "\r")):
        raise LauncherError(
            "the XDG data path cannot be represented safely in a desktop Exec key: "
            f"{launcher_path}"
        )
    desktop_exec = quote_desktop_exec_path(launcher_path)
    desktop_text = (
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Version=1.0\n"
        "Name=yt-dlp aria2 downloader\n"
        "Comment=Download a video or extract an audio track\n"
        "Comment[fr]=Télécharger une vidéo ou extraire une piste audio\n"
        f"Exec={desktop_exec}\n"
        f"Icon={APP_ID}\n"
        "Terminal=false\n"
        "Categories=AudioVideo;\n"
        "StartupNotify=true\n"
    )
    try:
        return desktop_text.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise LauncherError(
            "the XDG data path is not valid UTF-8 for a desktop entry"
        ) from exc


def create_temporary_file(
    directory_fd: int,
    prefix: str,
    suffix: str,
    content: bytes,
) -> str:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW

    for _attempt in range(32):
        name = f"{prefix}{secrets.token_hex(12)}{suffix}"
        try:
            descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
        except FileExistsError:
            continue

        operation_error: BaseException | None = None
        try:
            try:
                view = memoryview(content)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise OSError(errno.EIO, "short write")
                    view = view[written:]
                os.fchmod(descriptor, 0o644)
            except BaseException as exc:
                operation_error = exc
            try:
                os.close(descriptor)
            except OSError as exc:
                if operation_error is None:
                    operation_error = exc
                else:
                    print(
                        f"Warning: temporary-file close also failed: {exc}.",
                        file=sys.stderr,
                    )

            if operation_error is not None:
                raise operation_error
        except BaseException:
            with defer_shutdown_interruptions():
                try:
                    os.unlink(name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                except OSError as cleanup_error:
                    print(
                        "Warning: unable to remove a partial launcher temporary "
                        f"file {name}: {cleanup_error}.",
                        file=sys.stderr,
                    )
            raise
        return name

    raise LauncherError("unable to allocate a unique launcher temporary file")


def validate_desktop_file(applications_fd: int, temporary_name: str) -> None:
    raise_pending_shutdown()
    validator = shutil.which("desktop-file-validate")
    if validator is None:
        print(
            "Note: desktop-file-validate is unavailable; launcher validation "
            "was skipped.",
            file=sys.stderr,
        )
        raise_pending_shutdown()
        return

    validation_path = f"/proc/self/fd/{applications_fd}/{temporary_name}"
    if not os.path.exists(f"/proc/self/fd/{applications_fd}"):
        raise LauncherError(
            "the procfs descriptor view required for validation is absent"
        )

    process: subprocess.Popen[bytes] | None = None
    output_chunks: list[bytes] = []
    output_size = 0
    output_truncated = False
    deadline = time.monotonic() + VALIDATOR_TIMEOUT_SECONDS
    timed_out = False
    operation_interrupted = False
    wait_error: BaseException | None = None

    # Once process creation begins, honor a recorded request only after every
    # possible child has been killed, reaped, and disconnected. The polling
    # checks below still react to the request within 100 ms.
    with defer_shutdown_interruptions():
        try:
            process = subprocess.Popen(
                [validator, "--no-hints", validation_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                pass_fds=(applications_fd,),
                start_new_session=True,
            )
            if shutdown_requested():
                operation_interrupted = True
            elif process.stdout is None:
                raise LauncherError("unable to capture desktop-file-validate output")
            else:
                descriptor = process.stdout.fileno()
                os.set_blocking(descriptor, False)
                while True:
                    if shutdown_requested():
                        operation_interrupted = True
                        break
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        timed_out = True
                        break
                    readable, _writable, _exceptional = select.select(
                        [descriptor], [], [], min(0.1, remaining)
                    )
                    if not readable:
                        continue
                    try:
                        chunk = os.read(descriptor, 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        break
                    retained = chunk[
                        : max(0, MAX_VALIDATOR_OUTPUT_BYTES - output_size)
                    ]
                    if retained:
                        output_chunks.append(retained)
                        output_size += len(retained)
                    if len(retained) != len(chunk):
                        output_truncated = True
        except BaseException:
            operation_interrupted = True
            raise
        finally:
            if process is not None:
                if not timed_out and not operation_interrupted:
                    while process.poll() is None:
                        if shutdown_requested():
                            operation_interrupted = True
                            break
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            timed_out = True
                            break
                        try:
                            process.wait(timeout=min(0.1, remaining))
                        except subprocess.TimeoutExpired:
                            continue
                        except BaseException as exc:
                            operation_interrupted = True
                            wait_error = exc
                            break
                if shutdown_requested():
                    operation_interrupted = True
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired as exc:
                    if operation_interrupted:
                        print(
                            "Warning: interrupted desktop-file-validate could not "
                            "be reaped after SIGKILL.",
                            file=sys.stderr,
                        )
                    else:
                        raise TemporaryLauncherError(
                            "desktop-file-validate could not be reaped after "
                            "termination"
                        ) from exc
                if process.stdout is not None:
                    try:
                        process.stdout.close()
                    except OSError as exc:
                        print(
                            "Warning: unable to close desktop-file-validate output: "
                            f"{exc}.",
                            file=sys.stderr,
                        )
                if wait_error is not None:
                    raise wait_error

    if timed_out:
        raise TemporaryLauncherError(
            "desktop-file-validate exceeded the ten-second safety limit"
        )
    if process is None:
        raise LauncherError("desktop-file-validate did not start")
    if process.returncode == 0:
        return

    validator_output = b"".join(output_chunks).decode("utf-8", "replace")
    print(
        "Error: the generated desktop launcher failed validation "
        f"(status {process.returncode}).",
        file=sys.stderr,
    )
    if validator_output:
        print(validator_output.rstrip("\n"), file=sys.stderr)
    if output_truncated:
        print("[validator output truncated at 64 KiB]", file=sys.stderr)
    print(
        "The previously installed launcher, if any, was left unchanged.",
        file=sys.stderr,
    )
    raise ReportedLauncherError


def descriptor_mount_id(descriptor: int) -> int | None:
    try:
        with open(
            f"/proc/self/fdinfo/{descriptor}", encoding="ascii"
        ) as descriptor_info:
            for line in descriptor_info:
                key, separator, value = line.partition(":")
                if separator and key == "mnt_id":
                    return int(value.strip())
    except (OSError, ValueError):
        return None
    return None


def remove_nondirectory_at(parent_fd: int, name: str) -> None:
    try:
        entry_stat = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(entry_stat.st_mode):
        return
    try:
        os.unlink(name, dir_fd=parent_fd)
    except (FileNotFoundError, IsADirectoryError):
        return


def create_backup_link(
    directory_fd: int | None,
    source_name: str,
    prefix: str,
) -> str:
    if directory_fd is None:
        return ""
    try:
        source_stat = os.stat(
            source_name, dir_fd=directory_fd, follow_symlinks=False
        )
    except FileNotFoundError:
        return ""
    if stat.S_ISDIR(source_stat.st_mode):
        raise LauncherError(
            f"refusing to replace a directory at managed leaf {source_name}"
        )

    for _attempt in range(32):
        backup_name = f"{prefix}{secrets.token_hex(12)}.backup"
        try:
            os.link(
                source_name,
                backup_name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileExistsError:
            continue
        except OSError as exc:
            raise LauncherError(
                f"unable to preserve managed leaf {source_name} before publication"
            ) from exc
        return backup_name
    raise LauncherError(f"unable to allocate a backup for managed leaf {source_name}")


def restore_published_leaf(
    directory_fd: int | None,
    target_name: str,
    backup_name: str,
) -> None:
    if directory_fd is None:
        raise LauncherError(
            f"cannot restore managed leaf without an anchored directory: {target_name}"
        )
    if backup_name:
        os.replace(
            backup_name,
            target_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        # rename(2) is a successful no-op when both names are hard links to
        # the same inode, so explicitly remove a surviving backup name.
        remove_nondirectory_at(directory_fd, backup_name)
        return

    try:
        target_stat = os.stat(
            target_name, dir_fd=directory_fd, follow_symlinks=False
        )
    except FileNotFoundError:
        return
    if stat.S_ISDIR(target_stat.st_mode):
        raise LauncherError(
            f"refusing to remove a replacement directory at {target_name}"
        )
    os.unlink(target_name, dir_fd=directory_fd)


def remove_launcher_staging_directory(parent_fd: int, name: str) -> None:
    """Remove only the exact contents an installer stage can own."""

    flags = directory_open_flags()
    for _attempt in range(MAX_REMOVAL_ATTEMPTS):
        try:
            child_fd = os.open(name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            return
        except OSError as exc:
            if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                return
            raise

        child_stat = os.fstat(child_fd)
        parent_stat = os.fstat(parent_fd)
        parent_mount_id = descriptor_mount_id(parent_fd)
        child_mount_id = descriptor_mount_id(child_fd)
        mount_identity_known = (
            parent_mount_id is not None and child_mount_id is not None
        )
        safe_to_inspect = (
            child_stat.st_dev == parent_stat.st_dev
            and mount_identity_known
            and child_mount_id == parent_mount_id
        )

        try:
            if safe_to_inspect:
                child_names = os.listdir(child_fd)
                if child_names:
                    if child_names != ["launch"]:
                        return
                    try:
                        launch_stat = os.stat(
                            "launch", dir_fd=child_fd, follow_symlinks=False
                        )
                    except FileNotFoundError:
                        continue
                    if not stat.S_ISLNK(launch_stat.st_mode):
                        return
                    try:
                        os.unlink("launch", dir_fd=child_fd)
                    except FileNotFoundError:
                        continue
        finally:
            os.close(child_fd)

        try:
            current_stat = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if (
            not stat.S_ISDIR(current_stat.st_mode)
            or current_stat.st_dev != child_stat.st_dev
            or current_stat.st_ino != child_stat.st_ino
        ):
            continue

        try:
            os.rmdir(name, dir_fd=parent_fd)
            return
        except FileNotFoundError:
            return
        except NotADirectoryError:
            continue
        except OSError as exc:
            if exc.errno in {errno.EBUSY, errno.ENOTEMPTY}:
                return
            raise

    raise LauncherError("launcher staging artifact changed repeatedly during removal")


def remove_matching_entries(
    directory_fd: int | None,
    predicate: Callable[[str], bool],
    *,
    allow_directories: bool,
) -> None:
    if directory_fd is None:
        return

    for name in os.listdir(directory_fd):
        raise_pending_shutdown()
        if not predicate(name):
            continue
        try:
            entry_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if allow_directories:
            if stat.S_ISDIR(entry_stat.st_mode):
                remove_launcher_staging_directory(directory_fd, name)
            continue
        remove_nondirectory_at(directory_fd, name)
    raise_pending_shutdown()


def temporary_token(
    name: str,
    prefix: str,
    suffix: str,
) -> str | None:
    if not name.startswith(prefix) or not name.endswith(suffix):
        return None
    suffix_start = -len(suffix) if suffix else None
    token = name[len(prefix) : suffix_start]
    return token or None


def matches_current_temporary(name: str, prefix: str, suffix: str) -> bool:
    token = temporary_token(name, prefix, suffix)
    return token is not None and CURRENT_TOKEN_RE.fullmatch(token) is not None


def matches_legacy_temporary(name: str, prefix: str, suffix: str) -> bool:
    token = temporary_token(name, prefix, suffix)
    return token is not None and LEGACY_TOKEN_RE.fullmatch(token) is not None


def remove_stale_artifacts(
    applications_fd: int | None,
    launcher_fd: int | None,
    icon_fd: int | None,
) -> None:
    remove_matching_entries(
        applications_fd,
        lambda name: matches_current_temporary(
            name,
            f".{APP_ID}.",
            ".desktop",
        )
        or matches_legacy_temporary(name, f".{APP_ID}.", ".tmp"),
        allow_directories=False,
    )
    remove_matching_entries(
        applications_fd,
        lambda name: matches_current_temporary(
            name,
            f".{APP_ID}.",
            ".backup",
        ),
        allow_directories=False,
    )
    remove_matching_entries(
        launcher_fd,
        lambda name: matches_current_temporary(name, ".install.", "")
        or matches_legacy_temporary(name, ".install.", ""),
        allow_directories=True,
    )
    remove_matching_entries(
        launcher_fd,
        lambda name: matches_legacy_temporary(name, ".validate.", ".desktop"),
        allow_directories=False,
    )
    remove_matching_entries(
        launcher_fd,
        lambda name: matches_current_temporary(name, ".launch.", ".backup"),
        allow_directories=False,
    )
    remove_matching_entries(
        icon_fd,
        lambda name: matches_current_temporary(name, f".{APP_ID}.", ".tmp")
        or matches_legacy_temporary(name, f".{APP_ID}.", ".tmp"),
        allow_directories=False,
    )
    remove_matching_entries(
        icon_fd,
        lambda name: matches_current_temporary(
            name,
            f".{APP_ID}.",
            ".backup",
        ),
        allow_directories=False,
    )


def unlink_known_file(directory_fd: int | None, name: str, label: str) -> bool:
    if directory_fd is None:
        return False

    try:
        entry_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if stat.S_ISDIR(entry_stat.st_mode):
        raise LauncherError(f"refusing to remove a directory at {label}")

    try:
        os.unlink(name, dir_fd=directory_fd)
    except FileNotFoundError:
        return False
    except IsADirectoryError as exc:
        raise LauncherError(f"refusing to remove a directory at {label}") from exc
    return True


def remove_anchored_directory_if_empty(
    parent_fd: int,
    name: str,
    directory_fd: int | None,
) -> bool:
    if directory_fd is None:
        return False

    descriptor_stat = os.fstat(directory_fd)
    try:
        path_stat = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if (
        not stat.S_ISDIR(path_stat.st_mode)
        or path_stat.st_dev != descriptor_stat.st_dev
        or path_stat.st_ino != descriptor_stat.st_ino
    ):
        return False
    try:
        os.rmdir(name, dir_fd=parent_fd)
        return True
    except OSError as exc:
        if exc.errno in {errno.ENOENT, errno.ENOTEMPTY}:
            return False
        raise


def ensure_launcher_target_is_replaceable(launcher_fd: int, display_path: str) -> None:
    try:
        target_stat = os.stat("launch", dir_fd=launcher_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISLNK(target_stat.st_mode):
        raise LauncherError(
            f"launcher path already exists and is not a symbolic link: {display_path}"
        )


def install_launcher(
    data_home: str,
    launcher_target: str,
    icon_source: str,
    *,
    after_anchor: AnchorHook | None = None,
) -> None:
    desktop_content = build_desktop_content(data_home)
    icon_content = read_icon_content(icon_source)

    with ExitStack() as stack:
        # Registered first so it runs after every descriptor callback, including
        # on early returns and exceptional exits.
        stack.callback(raise_pending_shutdown)
        launcher_target_fd = register_fd(stack, open_launcher_target(launcher_target))
        assert launcher_target_fd is not None
        data_fd, applications_fd, launcher_fd, icon_fd = open_managed_directories(
            data_home,
            create=True,
            stack=stack,
        )
        if None in {data_fd, applications_fd, launcher_fd, icon_fd}:
            raise LauncherError("unable to create the managed launcher directories")
        assert data_fd is not None
        assert applications_fd is not None
        assert launcher_fd is not None
        assert icon_fd is not None

        os.fchmod(launcher_fd, 0o700)
        remove_stale_artifacts(applications_fd, launcher_fd, icon_fd)
        raise_pending_shutdown()
        ensure_launcher_target_is_replaceable(
            launcher_fd,
            child_display_path(child_display_path(data_home, APP_ID), "launch"),
        )
        raise_pending_shutdown()

        if after_anchor is not None:
            after_anchor()
        raise_pending_shutdown()

        desktop_temporary = ""
        icon_temporary = ""
        launcher_temporary = ""
        desktop_backup = ""
        icon_backup = ""
        launcher_backup = ""
        launcher_temporary_fd: int | None = None
        desktop_publication_attempted = False
        icon_publication_attempted = False
        launcher_publication_attempted = False
        rollback_failures: list[tuple[str, BaseException]] = []
        cleanup_failures: list[tuple[str, BaseException]] = []
        try:
            with defer_shutdown_interruptions():
                desktop_temporary = create_temporary_file(
                    applications_fd,
                    f".{APP_ID}.",
                    ".desktop",
                    desktop_content,
                )
            with defer_shutdown_interruptions():
                icon_temporary = create_temporary_file(
                    icon_fd,
                    f".{APP_ID}.",
                    ".tmp",
                    icon_content,
                )
            with defer_shutdown_interruptions():
                launcher_temporary = f".install.{secrets.token_hex(12)}"
                os.mkdir(launcher_temporary, mode=0o700, dir_fd=launcher_fd)
                launcher_temporary_fd = open_child_directory(
                    launcher_fd,
                    launcher_temporary,
                    child_display_path(data_home, launcher_temporary),
                    create=False,
                )
                if launcher_temporary_fd is None:
                    raise LauncherError("unable to open launcher staging directory")

            validate_desktop_file(applications_fd, desktop_temporary)
            os.symlink(launcher_target, "launch", dir_fd=launcher_temporary_fd)
            raise_pending_shutdown()
            with defer_shutdown_interruptions():
                desktop_backup = create_backup_link(
                    applications_fd,
                    DESKTOP_NAME,
                    f".{APP_ID}.",
                )
            with defer_shutdown_interruptions():
                icon_backup = create_backup_link(
                    icon_fd,
                    ICON_NAME,
                    f".{APP_ID}.",
                )
            with defer_shutdown_interruptions():
                launcher_backup = create_backup_link(
                    launcher_fd,
                    "launch",
                    ".launch.",
                )

            launcher_publication_attempted = True
            os.replace(
                "launch",
                "launch",
                src_dir_fd=launcher_temporary_fd,
                dst_dir_fd=launcher_fd,
            )
            raise_pending_shutdown()
            if os.readlink("launch", dir_fd=launcher_fd) != launcher_target:
                raise LauncherError("published launcher target is incorrect")
            raise_pending_shutdown()
            icon_publication_attempted = True
            os.replace(
                icon_temporary,
                ICON_NAME,
                src_dir_fd=icon_fd,
                dst_dir_fd=icon_fd,
            )
            icon_temporary = ""
            raise_pending_shutdown()
            desktop_publication_attempted = True
            os.replace(
                desktop_temporary,
                DESKTOP_NAME,
                src_dir_fd=applications_fd,
                dst_dir_fd=applications_fd,
            )
            desktop_temporary = ""
            raise_pending_shutdown()
            validate_launcher_target_identity(launcher_target, launcher_target_fd)
            validate_managed_path_identities(
                data_home,
                data_fd,
                applications_fd,
                launcher_fd,
                icon_fd,
            )
            validate_launcher_target_identity(launcher_target, launcher_target_fd)
            validate_data_home_path_identity(data_home, data_fd)
            raise_pending_shutdown()
        except BaseException:
            with defer_shutdown_interruptions():
                for label, attempted, directory_fd, target_name, backup_name in (
                    (
                        "desktop entry",
                        desktop_publication_attempted,
                        applications_fd,
                        DESKTOP_NAME,
                        desktop_backup,
                    ),
                    (
                        "application icon",
                        icon_publication_attempted,
                        icon_fd,
                        ICON_NAME,
                        icon_backup,
                    ),
                    (
                        "launcher link",
                        launcher_publication_attempted,
                        launcher_fd,
                        "launch",
                        launcher_backup,
                    ),
                ):
                    if not attempted:
                        continue
                    try:
                        restore_published_leaf(
                            directory_fd, target_name, backup_name
                        )
                        if label == "desktop entry":
                            desktop_backup = ""
                        elif label == "application icon":
                            icon_backup = ""
                        else:
                            launcher_backup = ""
                    except Exception as rollback_error:
                        rollback_failures.append((label, rollback_error))
            raise
        finally:
            with defer_shutdown_interruptions():
                if launcher_temporary_fd is not None:
                    try:
                        os.close(launcher_temporary_fd)
                    except Exception as cleanup_error:
                        cleanup_failures.append(
                            ("launcher staging descriptor", cleanup_error)
                        )
                if desktop_temporary:
                    try:
                        remove_nondirectory_at(applications_fd, desktop_temporary)
                    except Exception as cleanup_error:
                        cleanup_failures.append(("desktop staging file", cleanup_error))
                if icon_temporary:
                    try:
                        remove_nondirectory_at(icon_fd, icon_temporary)
                    except Exception as cleanup_error:
                        cleanup_failures.append(("icon staging file", cleanup_error))
                if launcher_temporary:
                    try:
                        remove_launcher_staging_directory(
                            launcher_fd, launcher_temporary
                        )
                    except Exception as cleanup_error:
                        cleanup_failures.append(
                            ("launcher staging directory", cleanup_error)
                        )
                failed_rollback_labels = {
                    label for label, _error in rollback_failures
                }
                for label, directory_fd, backup_name in (
                    ("desktop entry", applications_fd, desktop_backup),
                    ("application icon", icon_fd, icon_backup),
                    ("launcher link", launcher_fd, launcher_backup),
                ):
                    if not backup_name or label in failed_rollback_labels:
                        continue
                    try:
                        remove_nondirectory_at(directory_fd, backup_name)
                    except Exception as cleanup_error:
                        cleanup_failures.append((f"{label} backup", cleanup_error))

                for label, rollback_error in rollback_failures:
                    print(
                        f"Warning: unable to roll back the {label}: {rollback_error}.",
                        file=sys.stderr,
                    )
                for label, cleanup_error in cleanup_failures:
                    print(
                        f"Warning: unable to clean the {label}: {cleanup_error}.",
                        file=sys.stderr,
                    )
                # Publication is already committed after final validation. Cleanup
                # failures are reported but must not turn that committed state into
                # an error that can no longer be rolled back.

    raise_pending_shutdown()
    desktop_path = child_display_path(
        child_display_path(data_home, "applications"), DESKTOP_NAME
    )
    icon_path = child_display_path(
        child_display_path(data_home, "icons/hicolor/scalable/apps"), ICON_NAME
    )
    print(f"Launcher installed: {desktop_path}")
    print(f"Launcher target:    {launcher_target}")
    print(f"Application icon:   {icon_path}")
    print("Reinstall the launcher if the project directory is moved.")
    raise_pending_shutdown()


def uninstall_launcher(
    data_home: str,
    *,
    after_anchor: AnchorHook | None = None,
) -> None:
    desktop_path = child_display_path(
        child_display_path(data_home, "applications"), DESKTOP_NAME
    )

    with ExitStack() as stack:
        # Registered first so it runs after every descriptor callback, including
        # on early returns and exceptional exits.
        stack.callback(raise_pending_shutdown)
        data_fd, applications_fd, launcher_fd, icon_fd = open_managed_directories(
            data_home,
            create=False,
            stack=stack,
        )
        if data_fd is None:
            print(f"No launcher is installed at: {desktop_path}")
            return

        if after_anchor is not None:
            after_anchor()
        raise_pending_shutdown()

        desktop_backup = ""
        launcher_backup = ""
        icon_backup = ""
        desktop_removal_attempted = False
        launcher_removal_attempted = False
        icon_removal_attempted = False
        launcher_removed = False
        rollback_failures: list[tuple[str, BaseException]] = []
        cleanup_failures: list[tuple[str, BaseException]] = []
        try:
            remove_stale_artifacts(applications_fd, launcher_fd, icon_fd)
            raise_pending_shutdown()
            with defer_shutdown_interruptions():
                desktop_backup = create_backup_link(
                    applications_fd,
                    DESKTOP_NAME,
                    f".{APP_ID}.",
                )
            with defer_shutdown_interruptions():
                launcher_backup = create_backup_link(
                    launcher_fd,
                    "launch",
                    ".launch.",
                )
            with defer_shutdown_interruptions():
                icon_backup = create_backup_link(
                    icon_fd,
                    ICON_NAME,
                    f".{APP_ID}.",
                )

            if applications_fd is not None:
                desktop_removal_attempted = True
                launcher_removed = unlink_known_file(
                    applications_fd,
                    DESKTOP_NAME,
                    desktop_path,
                )
                raise_pending_shutdown()
            if launcher_fd is not None:
                launcher_removal_attempted = True
                launcher_removed = (
                    unlink_known_file(
                        launcher_fd,
                        "launch",
                        child_display_path(
                            child_display_path(data_home, APP_ID), "launch"
                        ),
                    )
                    or launcher_removed
                )
                raise_pending_shutdown()
            if icon_fd is not None:
                icon_removal_attempted = True
                launcher_removed = (
                    unlink_known_file(
                        icon_fd,
                        ICON_NAME,
                        child_display_path(
                            child_display_path(
                                data_home,
                                "icons/hicolor/scalable/apps",
                            ),
                            ICON_NAME,
                        ),
                    )
                    or launcher_removed
                )
                raise_pending_shutdown()
            validate_managed_path_identities(
                data_home,
                data_fd,
                applications_fd,
                launcher_fd,
                icon_fd,
            )
            raise_pending_shutdown()
        except BaseException:
            with defer_shutdown_interruptions():
                for label, attempted, directory_fd, target_name, backup_name in (
                    (
                        "application icon",
                        icon_removal_attempted,
                        icon_fd,
                        ICON_NAME,
                        icon_backup,
                    ),
                    (
                        "launcher link",
                        launcher_removal_attempted,
                        launcher_fd,
                        "launch",
                        launcher_backup,
                    ),
                    (
                        "desktop entry",
                        desktop_removal_attempted,
                        applications_fd,
                        DESKTOP_NAME,
                        desktop_backup,
                    ),
                ):
                    if not attempted:
                        continue
                    try:
                        restore_published_leaf(
                            directory_fd, target_name, backup_name
                        )
                        if label == "desktop entry":
                            desktop_backup = ""
                        elif label == "application icon":
                            icon_backup = ""
                        else:
                            launcher_backup = ""
                    except Exception as rollback_error:
                        rollback_failures.append((label, rollback_error))
            raise
        finally:
            with defer_shutdown_interruptions():
                failed_rollback_labels = {
                    label for label, _error in rollback_failures
                }
                for label, directory_fd, backup_name in (
                    ("desktop entry", applications_fd, desktop_backup),
                    ("application icon", icon_fd, icon_backup),
                    ("launcher link", launcher_fd, launcher_backup),
                ):
                    if not backup_name or label in failed_rollback_labels:
                        continue
                    try:
                        remove_nondirectory_at(directory_fd, backup_name)
                    except Exception as cleanup_error:
                        cleanup_failures.append((f"{label} backup", cleanup_error))

                for label, rollback_error in rollback_failures:
                    print(
                        f"Warning: unable to roll back the {label}: {rollback_error}.",
                        file=sys.stderr,
                    )
                for label, cleanup_error in cleanup_failures:
                    print(
                        f"Warning: unable to clean the {label}: {cleanup_error}.",
                        file=sys.stderr,
                    )
                # Removal is already committed after final validation. Cleanup
                # failures are reported but must not create a non-restorable error.

        try:
            remove_anchored_directory_if_empty(data_fd, APP_ID, launcher_fd)
        except OSError as cleanup_error:
            print(
                "Warning: unable to remove the empty launcher directory: "
                f"{cleanup_error}.",
                file=sys.stderr,
            )
        raise_pending_shutdown()

    raise_pending_shutdown()
    if launcher_removed:
        print(f"Launcher removed: {desktop_path}")
    else:
        print(f"No launcher is installed at: {desktop_path}")
    raise_pending_shutdown()


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage the private portable desktop-launcher files."
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--data-home", required=True)
    install_parser.add_argument("--launcher-target", required=True)
    install_parser.add_argument("--icon-source", required=True)

    uninstall_parser = subparsers.add_parser("uninstall")
    uninstall_parser.add_argument("--data-home", required=True)
    return parser


def main() -> int:
    os.umask(0o077)
    arguments = build_argument_parser().parse_args()

    try:
        result_status = 0
        try:
            install_shutdown_signal_handlers()
            if arguments.action == "install":
                install_launcher(
                    arguments.data_home,
                    arguments.launcher_target,
                    arguments.icon_source,
                )
            else:
                uninstall_launcher(arguments.data_home)
        except ReportedLauncherError:
            result_status = EXIT_VALIDATION
        except TemporaryLauncherError as exc:
            print(f"Error: {exc}.", file=sys.stderr)
            result_status = EXIT_TEMPORARY
        except LauncherError as exc:
            print(f"Error: {exc}.", file=sys.stderr)
            result_status = EXIT_VALIDATION
        except OSError as exc:
            print(
                f"Error: launcher filesystem operation failed: {exc}.",
                file=sys.stderr,
            )
            result_status = EXIT_IO

        raise_pending_shutdown()
        # From here onward no resource, mutation, rollback, cleanup, or
        # diagnostic work remains. Immediate delivery makes a signal on the
        # final return opcode observable without reintroducing transaction
        # interruption hazards.
        enable_immediate_shutdown_delivery()
        return result_status
    except LauncherInterruptedError as exc:
        return exc.exit_status


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LauncherInterruptedError as exc:
        # Covers a signal delivered after main() has selected its result but
        # before the interpreter has raised the terminating SystemExit.
        raise SystemExit(exc.exit_status) from None
