# SPDX-License-Identifier: MIT
"""
Manage local private state, direct-transfer plans and safe media publication.

Project: yt-dlp-aria2-downloader-gui
Repository path: private-aria2-plan.py

The helper selects and validates local private storage before secret writes,
keeps media URLs and headers in owner-only plans, and publishes completed media
without replacing existing names. Shared destinations receive an exclusive
media-only copy; sensitive transport and browser state remains local.

This file is intentionally non-executable. Invoke it explicitly with python3.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import re
import secrets
import signal
import stat
import sys
from pathlib import Path
from contextlib import contextmanager
from urllib.parse import urlsplit


EXIT_USAGE = 2
EXIT_VALIDATION = 65
EXIT_IO = 70

HEADER_NAME_RE = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
DIRECT_REPLAY_SAFE_HEADERS = frozenset(
    {
        "accept",
        "accept-language",
        "sec-fetch-mode",
        "user-agent",
    }
)
FORMAT_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
EXTENSION_RE = re.compile(r"^[A-Za-z0-9]+$")
STAGING_NAME_RE = re.compile(r"^item-[0-9]{3}\.download$")
LOCAL_DISK_FILESYSTEMS = frozenset({0xEF53, 0x58465342, 0x9123683E, 0x2FC12FC1})
LOCAL_MEMORY_FILESYSTEMS = frozenset({0x01021994})
NO_REPLACE_UNSUPPORTED = frozenset(
    {errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP, errno.ENOTSUP}
)


class PlanError(Exception):
    """Expected validation failure."""


class PublicationInterrupted(PlanError):
    """A catchable signal requested rollback before publication committed."""

    def __init__(self, signal_number: int) -> None:
        super().__init__("component publication was interrupted")
        self.signal_number = signal_number


class DestinationExistsError(PlanError):
    """A final destination already exists and must not be overwritten."""


def filesystem_type(descriptor: int) -> int:
    """Read the filesystem containing an opened inode, not a pathname guess."""
    libc = ctypes.CDLL(None, use_errno=True)
    result = ctypes.create_string_buffer(256)
    fstatfs = libc.fstatfs
    fstatfs.argtypes = [ctypes.c_int, ctypes.c_void_p]
    fstatfs.restype = ctypes.c_int
    if fstatfs(descriptor, ctypes.byref(result)) != 0:
        raise OSError(ctypes.get_errno(), "unable to inspect filesystem")
    return ctypes.c_ulong.from_buffer(result).value


def require_local_filesystem(descriptor: int, *, disk: bool = False) -> None:
    allowed = LOCAL_DISK_FILESYSTEMS
    if not disk:
        allowed = allowed | LOCAL_MEMORY_FILESYSTEMS
    if filesystem_type(descriptor) not in allowed:
        raise PlanError("directory is not on a supported local filesystem")


@contextmanager
def directory_descriptor(path: Path, *, trusted_chain: bool = False):
    """Anchor each physical path component without following symlinks."""
    if not path.is_absolute() or ".." in path.parts:
        raise PlanError("directory must use an absolute physical path")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            child = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
            if trusted_chain:
                metadata = os.fstat(descriptor)
                if metadata.st_uid not in {0, os.geteuid()}:
                    raise PlanError("directory chain has an untrusted owner")
                if metadata.st_mode & 0o022 and not metadata.st_mode & stat.S_ISVTX:
                    raise PlanError("directory chain is writable without sticky protection")
        yield descriptor
    finally:
        os.close(descriptor)


def require_private_directory_descriptor(descriptor: int) -> None:
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise PlanError("private directory must belong to the current user with mode 0700")


def private_root_candidates(*, disk: bool, no_runtime: bool) -> list[tuple[Path, bool]]:
    candidates: list[tuple[Path, bool]] = []
    if disk:
        cache = os.environ.get("XDG_CACHE_HOME", "")
        home = os.environ.get("HOME", "")
        if cache:
            candidates.append((Path(cache), False))
        if home:
            candidates.append((Path(home) / ".cache", False))
        candidates.append((Path("/var/tmp"), False))
    else:
        runtime = os.environ.get("XDG_RUNTIME_DIR", "")
        if runtime and not no_runtime:
            candidates.append((Path(runtime), True))
        candidates.extend(((Path("/tmp"), False), (Path("/var/tmp"), False)))
    return candidates


def select_private_root(*, disk: bool = False, no_runtime: bool = False) -> Path:
    """Create only our own leaf, then prove its privacy before any secret write."""
    leaf = f"yt-dlp-aria2-downloader-{os.geteuid()}"
    for parent, runtime in private_root_candidates(disk=disk, no_runtime=no_runtime):
        try:
            reject_controls(str(parent), "private root", reject_whitespace=False)
            with directory_descriptor(parent, trusted_chain=True) as parent_fd:
                require_local_filesystem(parent_fd, disk=disk)
                if runtime:
                    require_private_directory_descriptor(parent_fd)
                try:
                    os.mkdir(leaf, mode=0o700, dir_fd=parent_fd)
                except FileExistsError:
                    pass
                root_fd = os.open(
                    leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=parent_fd,
                )
                try:
                    require_private_directory_descriptor(root_fd)
                    require_local_filesystem(root_fd, disk=disk)
                    probe_name = f".probe-{secrets.token_hex(16)}"
                    probe_fd = os.open(
                        probe_name,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                        0o600, dir_fd=root_fd,
                    )
                    try:
                        probe_stat = os.fstat(probe_fd)
                        if (
                            not stat.S_ISREG(probe_stat.st_mode)
                            or probe_stat.st_uid != os.geteuid()
                            or stat.S_IMODE(probe_stat.st_mode) != 0o600
                        ):
                            raise PlanError("filesystem does not enforce private file permissions")
                        os.write(probe_fd, b"private storage probe\n")
                        os.fsync(probe_fd)
                    finally:
                        os.close(probe_fd)
                        os.unlink(probe_name, dir_fd=root_fd)
                    root_stat = os.fstat(root_fd)
                    visible = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
                    if (visible.st_dev, visible.st_ino) != (root_stat.st_dev, root_stat.st_ino):
                        raise PlanError("private directory changed during validation")
                    if directory_identity(parent / leaf) != (root_stat.st_dev, root_stat.st_ino):
                        raise PlanError("private directory path changed during validation")
                    return parent / leaf
                finally:
                    os.close(root_fd)
        except (OSError, PlanError):
            # No candidate receives secrets until every privacy check passes.
            # Existing user directories are never chmod'ed to make them usable.
            continue
    kind = "local disk workspace" if disk else "local private temporary directory"
    raise PlanError(f"no safe writable {kind} is available; check local storage and permissions")


def private_root(args: argparse.Namespace) -> int:
    print(select_private_root(disk=args.disk, no_runtime=args.no_runtime))
    return 0


def media_local_safe(args: argparse.Namespace) -> int:
    try:
        with directory_descriptor(Path(args.output_dir), trusted_chain=True) as descriptor:
            require_local_filesystem(descriptor)
    except (OSError, PlanError):
        return 1
    return 0


def reject_controls(value: str, label: str, *, reject_whitespace: bool) -> None:
    for character in value:
        codepoint = ord(character)

        if (
            codepoint < 0x20
            or codepoint == 0x7F
            or 0xD800 <= codepoint <= 0xDFFF
            or (reject_whitespace and character.isspace())
        ):
            raise PlanError(f"{label} contains an unsafe control/whitespace character")


def require_private_regular_file(path: Path, label: str) -> None:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as exc:
        raise PlanError(f"{label} does not exist") from exc

    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise PlanError(f"{label} must be a regular non-symlink file")

    if file_stat.st_uid != os.geteuid():
        raise PlanError(f"{label} must be owned by the current user")

    if stat.S_IMODE(file_stat.st_mode) & 0o077:
        raise PlanError(f"{label} must not be accessible by group or other users")


def resolve_output_directory(raw_path: str) -> Path:
    path = Path(raw_path)

    if not path.is_absolute():
        raise PlanError("output directory must be absolute")

    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise PlanError("unable to resolve output directory") from exc

    if not resolved.is_dir():
        raise PlanError("output directory is not a directory")

    return resolved


def resolve_staging_directory(raw_path: str, output_dir: Path) -> Path:
    path = Path(raw_path)

    if not path.is_absolute():
        raise PlanError("staging directory must be absolute")

    try:
        staging_stat = path.lstat()
    except FileNotFoundError as exc:
        raise PlanError("staging directory does not exist") from exc

    if stat.S_ISLNK(staging_stat.st_mode) or not stat.S_ISDIR(staging_stat.st_mode):
        raise PlanError("staging directory must be a non-symlink directory")

    if staging_stat.st_uid != os.geteuid():
        raise PlanError("staging directory must be owned by the current user")

    if stat.S_IMODE(staging_stat.st_mode) != 0o700:
        raise PlanError("staging directory must have mode 0700")

    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise PlanError("unable to resolve staging directory") from exc

    if resolved.parent != output_dir:
        raise PlanError("staging directory must be a direct child of output directory")

    with directory_descriptor(resolved, trusted_chain=True) as descriptor:
        require_local_filesystem(descriptor)
        if os.fstat(descriptor).st_dev != output_dir.stat().st_dev:
            raise PlanError("staging directory must share the output filesystem")

    return resolved


def resolve_private_output_path(raw_path: str, staging_dir: Path, label: str) -> Path:
    path = Path(raw_path)

    if not path.is_absolute():
        raise PlanError(f"{label} must be absolute")

    if path.name in {"", ".", ".."}:
        raise PlanError(f"{label} has an invalid basename")

    try:
        resolved_parent = path.parent.resolve(strict=True)
    except OSError as exc:
        raise PlanError(f"unable to resolve parent directory for {label}") from exc

    if resolved_parent != staging_dir:
        raise PlanError(f"{label} must be created inside the staging directory")

    resolved = resolved_parent / path.name

    if os.path.lexists(resolved):
        raise PlanError(f"{label} already exists")

    return resolved


def read_json(path: Path, label: str) -> object:
    require_private_regular_file(path, label)

    try:
        with directory_descriptor(path.parent, trusted_chain=True) as parent_fd:
            require_local_filesystem(parent_fd)
            descriptor = os.open(
                path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd
            )
            with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
                metadata = os.fstat(handle.fileno())
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.geteuid()
                    or stat.S_IMODE(metadata.st_mode) & 0o077
                ):
                    raise PlanError(f"{label} changed or is not private")
                return json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PlanError(f"unable to read valid JSON from {label}") from exc


def resolve_destination(
    filename: object,
    output_dir: Path,
    label: str,
) -> Path:
    if not isinstance(filename, str) or not filename:
        raise PlanError(f"{label} is absent")

    reject_controls(filename, label, reject_whitespace=False)

    candidate = Path(filename)

    if not candidate.is_absolute():
        candidate = output_dir / candidate

    if candidate.name in {"", ".", ".."}:
        raise PlanError(f"{label} has an invalid basename")

    reject_controls(candidate.name, f"{label} basename", reject_whitespace=False)

    try:
        resolved_parent = candidate.parent.resolve(strict=True)
    except OSError as exc:
        raise PlanError(f"unable to resolve parent directory for {label}") from exc

    if resolved_parent != output_dir:
        raise PlanError(f"{label} escapes the output directory")

    # Preserve the final path component verbatim. Resolving the complete path
    # here would follow a pre-existing final symlink and could silently change
    # the filename that yt-dlp selected.
    return resolved_parent / candidate.name


def validate_url(value: object) -> tuple[str, str, bool]:
    if not isinstance(value, str) or not value:
        raise PlanError("requested format has no URL")

    reject_controls(value, "URL", reject_whitespace=True)

    try:
        parsed = urlsplit(value)
    except ValueError as exc:
        raise PlanError("requested format has an invalid URL") from exc

    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise PlanError("only absolute HTTP(S) format URLs are accepted")

    has_userinfo = parsed.username is not None or parsed.password is not None
    return value, parsed.scheme, has_userinfo


def validate_headers(value: object) -> dict[str, str]:
    if value is None:
        return {}

    if not isinstance(value, dict):
        raise PlanError("http_headers must be a JSON object")

    headers: dict[str, str] = {}

    for raw_name, raw_value in value.items():
        if not isinstance(raw_name, str) or not HEADER_NAME_RE.fullmatch(raw_name):
            raise PlanError("unsafe HTTP header name in yt-dlp plan")

        if not isinstance(raw_value, str):
            raise PlanError(f"HTTP header {raw_name} value must be a string")

        header_value = raw_value
        reject_controls(
            header_value,
            f"HTTP header {raw_name}",
            reject_whitespace=False,
        )
        headers[raw_name] = header_value

    return headers


def direct_headers_are_replay_safe(headers: dict[str, str]) -> bool:
    normalized_names = [header_name.lower() for header_name in headers]
    return len(normalized_names) == len(set(normalized_names)) and all(
        header_name in DIRECT_REPLAY_SAFE_HEADERS
        for header_name in normalized_names
    )


def format_id_is_representable(value: object) -> bool:
    return (
        isinstance(value, str)
        and FORMAT_ID_RE.fullmatch(value) is not None
    )


def extension_is_representable(value: object) -> bool:
    return (
        isinstance(value, str)
        and EXTENSION_RE.fullmatch(value) is not None
    )


def component_destination(
    root_destination: Path,
    format_info: dict[str, object],
) -> Path:
    format_id = format_info.get("format_id")
    extension = format_info.get("ext")

    if not format_id_is_representable(format_id):
        raise PlanError("requested format has an unsafe format_id")

    if not extension_is_representable(extension):
        raise PlanError("requested format has an unsafe extension")

    base = root_destination.with_suffix(f".{extension}")
    component = base.with_name(
        f"{base.stem}.f{format_id}{base.suffix}"
    )

    if component.parent != root_destination.parent:
        raise PlanError("calculated component path escapes output directory")

    return component


def write_private_new(path: Path, payload: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC

    try:
        with directory_descriptor(path.parent, trusted_chain=True) as parent_fd:
            require_private_directory_descriptor(parent_fd)
            require_local_filesystem(parent_fd)
            descriptor = os.open(path.name, flags, 0o600, dir_fd=parent_fd)
    except OSError as exc:
        raise PlanError(f"unable to create private file: {path.name}") from exc

    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            metadata = os.fstat(handle.fileno())
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise PlanError("new private file does not enforce owner-only permissions")
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except UnicodeError as exc:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise PlanError(f"unable to write private file: {path.name}") from exc
    except OSError:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    except Exception:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def build_plan(args: argparse.Namespace) -> int:
    output_dir = resolve_output_directory(args.output_dir)
    staging_dir = resolve_staging_directory(args.staging_dir, output_dir)
    private_dir = Path(args.private_dir)
    with directory_descriptor(private_dir, trusted_chain=True) as private_fd:
        require_private_directory_descriptor(private_fd)
        require_local_filesystem(private_fd)

    plan_path = Path(args.plan)
    plan = read_json(plan_path, "yt-dlp plan")

    if not isinstance(plan, dict):
        raise PlanError("yt-dlp plan root must be a JSON object")

    downloads = plan.get("requested_downloads")

    if not isinstance(downloads, list) or len(downloads) != 1:
        raise PlanError("yt-dlp plan must contain exactly one requested download")

    root = downloads[0]

    if not isinstance(root, dict):
        raise PlanError("requested download is not a JSON object")

    root_destination = resolve_destination(
        root.get("filename") or root.get("_filename"),
        output_dir,
        "yt-dlp requested filename",
    )

    requested_formats = root.get("requested_formats")

    if requested_formats is None:
        transfers: list[dict[str, object]] = [root]
        destinations = [root_destination]
    else:
        if not isinstance(requested_formats, list) or not requested_formats:
            raise PlanError("requested_formats must be a non-empty JSON array")

        if len(requested_formats) > 16:
            raise PlanError("too many requested formats")

        transfers = []
        destinations = []

        for raw_format in requested_formats:
            if not isinstance(raw_format, dict):
                raise PlanError("requested format is not a JSON object")

            transfers.append(raw_format)
            destinations.append(
                component_destination(root_destination, raw_format)
            )

    if len(set(destinations)) != len(destinations):
        raise PlanError("multiple requested formats resolve to the same destination")

    # Reject known collisions before downloading. Commit must still enforce
    # no-overwrite publication against destinations created after this check.
    for destination in destinations:
        if os.path.lexists(destination):
            raise DestinationExistsError(
                f"destination already exists: {destination.name}"
            )

    aria2_input_path = resolve_private_output_path(
        args.aria2_input,
        private_dir,
        "aria2 input file",
    )
    manifest_path = resolve_private_output_path(
        args.manifest,
        private_dir,
        "transfer manifest",
    )

    input_lines: list[str] = []
    manifest_items: list[dict[str, str]] = []

    for index, (transfer, destination) in enumerate(
        zip(transfers, destinations, strict=True)
    ):
        url, url_scheme, has_userinfo = validate_url(transfer.get("url"))
        if has_userinfo:
            raise PlanError("URL user information requires native yt-dlp transport")
        if url_scheme == "https" and not args.allow_https_direct:
            raise PlanError("HTTPS requires native yt-dlp transport on this aria2 build")

        protocol = transfer.get("protocol")
        if not isinstance(protocol, str) or protocol not in {"http", "https"}:
            raise PlanError(
                "unsupported direct-transfer protocol"
            )

        headers = validate_headers(transfer.get("http_headers"))
        if not direct_headers_are_replay_safe(headers):
            raise PlanError(
                "HTTP headers require native yt-dlp transport"
            )

        staging_name = f"item-{index:03d}.download"

        input_lines.append(url)
        input_lines.append(f"  out={staging_name}")

        for header_name in sorted(headers):
            input_lines.append(
                f"  header={header_name}: {headers[header_name]}"
            )

        manifest_items.append(
            {
                "staging_name": staging_name,
                "destination": str(destination),
            }
        )

    manifest = {
        "version": 2,
        "output_dir": str(output_dir),
        "staging_dir": str(staging_dir),
        "output_identity": list(directory_identity(output_dir)),
        "staging_identity": list(directory_identity(staging_dir)),
        "items": manifest_items,
    }

    try:
        write_private_new(
            aria2_input_path,
            "\n".join(input_lines) + "\n",
        )

        write_private_new(
            manifest_path,
            json.dumps(
                manifest,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            + "\n",
        )
    except Exception:
        aria2_input_path.unlink(missing_ok=True)
        manifest_path.unlink(missing_ok=True)
        raise

    print(f"transfer_count={len(manifest_items)}")
    return 0


def classify_plan(args: argparse.Namespace) -> int:
    plan = read_json(Path(args.plan), "yt-dlp plan")

    if not isinstance(plan, dict):
        raise PlanError("yt-dlp plan root must be a JSON object")

    downloads = plan.get("requested_downloads")

    if not isinstance(downloads, list) or len(downloads) != 1:
        raise PlanError(
            "yt-dlp plan must contain exactly one requested download"
        )

    root = downloads[0]

    if not isinstance(root, dict):
        raise PlanError("requested download is not a JSON object")

    requested_formats = root.get("requested_formats")

    if requested_formats is None:
        transfers: list[dict[str, object]] = [root]
    else:
        if not isinstance(requested_formats, list) or not requested_formats:
            raise PlanError(
                "requested_formats must be a non-empty JSON array"
            )

        if len(requested_formats) > 16:
            raise PlanError("too many requested formats")

        transfers = []

        for raw_format in requested_formats:
            if not isinstance(raw_format, dict):
                raise PlanError(
                    "requested format is not a JSON object"
                )

            if (
                not format_id_is_representable(raw_format.get("format_id"))
                or not extension_is_representable(raw_format.get("ext"))
            ):
                print("transport=native")
                print(f"transfer_count={len(requested_formats)}")
                return 0

            transfers.append(raw_format)

    for transfer in transfers:
        protocol = transfer.get("protocol")

        if not isinstance(protocol, str) or protocol not in {"http", "https"}:
            print("transport=native")
            print(f"transfer_count={len(transfers)}")
            return 0

        _url, url_scheme, has_userinfo = validate_url(transfer.get("url"))
        if has_userinfo:
            print("transport=native")
            print(f"transfer_count={len(transfers)}")
            return 0
        if url_scheme == "https" and not args.allow_https_direct:
            print("transport=native")
            print(f"transfer_count={len(transfers)}")
            return 0
        headers = validate_headers(transfer.get("http_headers"))
        if not direct_headers_are_replay_safe(headers):
            print("transport=native")
            print(f"transfer_count={len(transfers)}")
            return 0

    print("transport=direct")
    print(f"transfer_count={len(transfers)}")
    return 0


def load_manifest(path: Path) -> dict[str, object]:
    manifest = read_json(path, "transfer manifest")

    if not isinstance(manifest, dict):
        raise PlanError("transfer manifest root must be a JSON object")

    if manifest.get("version") != 2:
        raise PlanError("unsupported transfer manifest version")

    return manifest


def path_matches_identity(path: Path, identity: tuple[int, int]) -> bool:
    try:
        path_stat = path.lstat()
    except FileNotFoundError:
        return False

    return (
        stat.S_ISREG(path_stat.st_mode)
        and (path_stat.st_dev, path_stat.st_ino) == identity
    )


def directory_identity(path: Path) -> tuple[int, int]:
    with directory_descriptor(path) as descriptor:
        metadata = os.fstat(descriptor)
        return metadata.st_dev, metadata.st_ino


def rename_without_overwrite(
    source: Path, destination: Path, *, source_fd: int = -100, destination_fd: int = -100
) -> None:
    """Require the kernel/filesystem no-replace operation; never emulate it."""
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise OSError(errno.ENOSYS, "rename without replacement is unavailable")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(source_fd, os.fsencode(source), destination_fd, os.fsencode(destination), 1):
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def same_inode(metadata: os.stat_result, identity: tuple[int, int]) -> bool:
    return stat.S_ISREG(metadata.st_mode) and (metadata.st_dev, metadata.st_ino) == identity


def anchored_file_matches(descriptor: int, name: str, identity: tuple[int, int]) -> bool:
    try:
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return same_inode(metadata, identity)


def parse_identity(value: str) -> tuple[int, int]:
    if not re.fullmatch(r"[0-9]+:[0-9]+", value):
        raise PlanError("invalid recorded filesystem identity")
    device, inode = value.split(":")
    return int(device), int(inode)


def publish_media(args: argparse.Namespace) -> int:
    """Copy local validated media to one exclusively staged destination inode."""
    source = Path(args.source)
    output = Path(args.output_dir)
    reject_controls(source.name, "media filename", reject_whitespace=False)
    expected_output = parse_identity(args.output_identity)
    expected_source = parse_identity(args.source_identity)
    requested_signal = 0

    def remember_signal(number: int, _frame: object) -> None:
        nonlocal requested_signal
        if not requested_signal:
            requested_signal = number

    def checkpoint() -> None:
        if requested_signal:
            raise PublicationInterrupted(requested_signal)

    previous_handlers = {}
    try:
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            previous_handlers[number] = signal.signal(number, remember_signal)
        with directory_descriptor(source.parent, trusted_chain=True) as source_dir_fd:
            require_local_filesystem(source_dir_fd)
            with directory_descriptor(output) as output_fd:
                output_stat = os.fstat(output_fd)
                if (output_stat.st_dev, output_stat.st_ino) != expected_output:
                    raise PlanError("media destination changed before publication")
                try:
                    os.stat(source.name, dir_fd=output_fd, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise DestinationExistsError("final media destination already exists")
                source_fd = os.open(
                    source.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=source_dir_fd,
                )
                try:
                    original = os.fstat(source_fd)
                    if (
                        not stat.S_ISREG(original.st_mode) or original.st_size <= 0
                        or original.st_uid != os.geteuid()
                        or (original.st_dev, original.st_ino) != expected_source
                    ):
                        raise PlanError("publication source must be nonempty media owned by the current user")
                    temporary_name = f".yt-dlp-publish.{secrets.token_hex(16)}.partial"
                    temporary_fd = os.open(
                        temporary_name,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                        0o600, dir_fd=output_fd,
                    )
                    temporary_identity = None
                    publication_attempted = False
                    published = False
                    try:
                        temporary_stat = os.fstat(temporary_fd)
                        temporary_identity = temporary_stat.st_dev, temporary_stat.st_ino
                        while True:
                            checkpoint()
                            block = os.read(source_fd, 1024 * 1024)
                            if not block:
                                break
                            remainder = memoryview(block)
                            while remainder:
                                checkpoint()
                                written = os.write(temporary_fd, remainder)
                                if written <= 0:
                                    raise OSError(errno.EIO, "media copy made no progress")
                                remainder = remainder[written:]
                        os.fsync(temporary_fd)
                        current = os.fstat(source_fd)
                        if (
                            (current.st_dev, current.st_ino, current.st_size,
                             current.st_mtime_ns, current.st_ctime_ns)
                            != (original.st_dev, original.st_ino, original.st_size,
                                original.st_mtime_ns, original.st_ctime_ns)
                            or os.fstat(temporary_fd).st_size != original.st_size
                        ):
                            raise PlanError("local media changed during publication")
                        if (
                            directory_identity(output) != expected_output
                            or not anchored_file_matches(output_fd, temporary_name, temporary_identity)
                        ):
                            raise PlanError("media publication directory or temporary file changed")
                        checkpoint()
                        publication_attempted = True
                        try:
                            rename_without_overwrite(
                                Path(temporary_name), Path(source.name),
                                source_fd=output_fd, destination_fd=output_fd,
                            )
                        except OSError as exc:
                            if exc.errno == errno.EEXIST:
                                publication_attempted = False
                                raise DestinationExistsError("final media destination already exists") from exc
                            if exc.errno not in NO_REPLACE_UNSUPPORTED:
                                raise
                            publication_attempted = False
                            # A hard link is also atomic and cannot replace an
                            # existing leaf. This fallback is never check+rename.
                            try:
                                publication_attempted = True
                                os.link(
                                    temporary_name, source.name,
                                    src_dir_fd=output_fd, dst_dir_fd=output_fd,
                                    follow_symlinks=False,
                                )
                            except FileExistsError as collision:
                                publication_attempted = False
                                raise DestinationExistsError("final media destination already exists") from collision
                            except OSError as link_error:
                                if link_error.errno in NO_REPLACE_UNSUPPORTED | {errno.EPERM, errno.EXDEV}:
                                    publication_attempted = False
                                    raise PlanError(
                                        "destination supports neither atomic no-replace rename nor hard links"
                                    ) from link_error
                                raise
                        published = True
                        if (
                            not anchored_file_matches(output_fd, source.name, temporary_identity)
                            or directory_identity(output) != expected_output
                        ):
                            raise PlanError("media publication outcome is uncertain; local source was preserved")
                    finally:
                        os.close(temporary_fd)
                        # An ambiguous network publication may have completed.
                        # Preserve its remaining name and always retain source.
                        if temporary_identity is None:
                            print("Warning: preserving unconfirmed media publication temporary file", file=sys.stderr)
                        elif not publication_attempted or published:
                            try:
                                if anchored_file_matches(output_fd, temporary_name, temporary_identity):
                                    os.unlink(temporary_name, dir_fd=output_fd)
                            except OSError:
                                print("Warning: preserving unconfirmed media publication temporary file", file=sys.stderr)
                finally:
                    os.close(source_fd)
        print(output / source.name)
        return 0
    finally:
        for number, previous in previous_handlers.items():
            signal.signal(number, previous)


def check_space(args: argparse.Namespace) -> int:
    plan = read_json(Path(args.plan), "yt-dlp plan")
    if not isinstance(plan, dict):
        raise PlanError("yt-dlp plan root must be a JSON object")
    downloads = plan.get("requested_downloads")
    if not isinstance(downloads, list) or len(downloads) != 1 or not isinstance(downloads[0], dict):
        raise PlanError("yt-dlp plan must contain exactly one requested download")
    selected = downloads[0].get("requested_formats") or downloads
    if not isinstance(selected, list):
        raise PlanError("requested_formats must be an array")
    estimate = 0
    complete = True
    for item in selected:
        if not isinstance(item, dict):
            raise PlanError("requested format is not a JSON object")
        size = item.get("filesize") or item.get("filesize_approx")
        if isinstance(size, (int, float)) and not isinstance(size, bool) and 0 < size < 2**63:
            estimate += int(size)
        else:
            complete = False
    with directory_descriptor(Path(args.output_dir), trusted_chain=True) as descriptor:
        require_local_filesystem(descriptor, disk=True)
        filesystem = os.fstatvfs(descriptor)
    available = filesystem.f_bavail * filesystem.f_frsize
    # Selected components, an assembled file and the HLS repair can coexist.
    required = estimate * 3 + 64 * 1024 * 1024
    if available < required:
        raise PlanError("insufficient local disk space for downloaded media and post-processing")
    if not complete:
        print("Warning: media size is unknown; local disk space cannot be guaranteed", file=sys.stderr)
    return 0


def cleanup_workspace(args: argparse.Namespace) -> int:
    """Remove only a live caller-authenticated private local workspace tree."""
    path = Path(args.path)
    expected = parse_identity(args.identity)
    if len(args.keep) != len(args.keep_identity):
        raise PlanError("every retained media file requires its identity")
    kept = {
        Path(filename): parse_identity(identity)
        for filename, identity in zip(args.keep, args.keep_identity, strict=True)
    }
    if len(kept) != len(args.keep):
        raise PlanError("retained media paths must be unique")
    if any(filename.parent != path for filename in kept):
        raise PlanError("retained media must be an identified direct workspace child")

    with directory_descriptor(path.parent, trusted_chain=True) as parent_fd:
        workspace_fd = os.open(
            path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
        try:
            root_stat = os.fstat(workspace_fd)
            if (root_stat.st_dev, root_stat.st_ino) != expected:
                raise PlanError("workspace identity changed; preserving its contents")
            require_private_directory_descriptor(workspace_fd)
            require_local_filesystem(workspace_fd)
            for filename, identity in kept.items():
                if not anchored_file_matches(workspace_fd, filename.name, identity):
                    raise PlanError("retained media identity changed; preserving workspace")
            entries = 0
            snapshot: dict[tuple[str, ...], tuple[int, int, int, int, int, int]] = {}

            def walk(descriptor: int, parts: tuple[str, ...], *, remove: bool) -> None:
                nonlocal entries
                if len(parts) > 64:
                    raise PlanError("workspace nesting is excessive; preserving contents")
                for name in os.listdir(descriptor):
                    entries += 1
                    if entries > 100000:
                        raise PlanError("workspace contains too many entries")
                    metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                    relative = parts + (name,)
                    identity = (
                        metadata.st_dev, metadata.st_ino, metadata.st_mode,
                        metadata.st_uid, metadata.st_ctime_ns, metadata.st_size,
                    )
                    if remove:
                        if snapshot.get(relative) != identity:
                            raise PlanError("workspace entry changed after inspection; preserving it")
                    else:
                        snapshot[relative] = identity
                    if metadata.st_uid != os.geteuid() or metadata.st_dev != root_stat.st_dev:
                        raise PlanError("workspace contains foreign data; preserving contents")
                    if not parts and path / name in kept:
                        if not same_inode(metadata, kept[path / name]):
                            raise PlanError("retained media identity changed")
                        continue
                    if stat.S_ISDIR(metadata.st_mode):
                        child_fd = os.open(
                            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=descriptor,
                        )
                        try:
                            child_stat = os.fstat(child_fd)
                            if (child_stat.st_dev, child_stat.st_ino) != (metadata.st_dev, metadata.st_ino):
                                raise PlanError("workspace directory changed; preserving contents")
                            require_private_directory_descriptor(child_fd)
                            require_local_filesystem(child_fd)
                            walk(child_fd, relative, remove=remove)
                            if remove:
                                visible = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                                if (visible.st_dev, visible.st_ino) != (metadata.st_dev, metadata.st_ino):
                                    raise PlanError("workspace directory changed during cleanup")
                                os.rmdir(name, dir_fd=descriptor)
                        finally:
                            os.close(child_fd)
                    elif stat.S_ISREG(metadata.st_mode):
                        if remove:
                            if not anchored_file_matches(descriptor, name, (metadata.st_dev, metadata.st_ino)):
                                raise PlanError("workspace file changed during cleanup")
                            os.unlink(name, dir_fd=descriptor)
                    else:
                        raise PlanError("workspace contains an unknown file type; preserving contents")

            walk(workspace_fd, (), remove=False)
            entries = 0
            walk(workspace_fd, (), remove=True)
            visible = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
            if (visible.st_dev, visible.st_ino) != expected:
                raise PlanError("workspace changed during cleanup")
            if not kept:
                os.rmdir(path.name, dir_fd=parent_fd)
        finally:
            os.close(workspace_fd)
    return 0


def publish_without_overwrite(
    source: Path,
    destination: Path,
    moved: list[tuple[Path, Path, tuple[int, int]]],
) -> tuple[int, int]:
    try:
        source_stat = source.lstat()
    except OSError as exc:
        raise PlanError(
            f"unable to inspect downloaded component: {source.name}"
        ) from exc

    source_identity = (source_stat.st_dev, source_stat.st_ino)
    renamed = False

    try:
        os.link(source, destination, follow_symlinks=False)
    except FileExistsError as exc:
        raise DestinationExistsError(
            f"destination already exists: {destination.name}"
        ) from exc
    except OSError as exc:
        if exc.errno not in NO_REPLACE_UNSUPPORTED | {errno.EPERM}:
            raise PlanError(
                f"unable to publish downloaded component: {destination.name}"
            ) from exc
        # A private local staging parent protects this pathname. Verify its
        # identity again before the filesystem's atomic no-replace operation.
        if not path_matches_identity(source, source_identity):
            raise PlanError("downloaded component changed before publication") from exc
        try:
            rename_without_overwrite(source, destination)
            renamed = True
        except FileExistsError as collision:
            raise DestinationExistsError(
                f"destination already exists: {destination.name}"
            ) from collision
        except OSError as rename_error:
            raise PlanError(
                "component filesystem does not support safe no-overwrite publication"
            ) from rename_error

    # From this point the helper has created a final-directory name. Record it
    # before verification so every later exception participates in rollback.
    moved.append((source, destination, source_identity))

    if not path_matches_identity(destination, source_identity):
        raise PlanError(
            f"published destination changed unexpectedly: {destination.name}"
        )

    try:
        if not renamed:
            if not path_matches_identity(source, source_identity):
                raise PlanError("staging source changed after publication")
            source.unlink()
    except OSError:
        # Never remove a path that another process replaced after publication.
        if path_matches_identity(destination, source_identity):
            destination.unlink(missing_ok=True)
        raise

    return source_identity


def rollback_publication(
    moved: list[tuple[Path, Path, tuple[int, int]]],
) -> list[str]:
    failures: list[str] = []

    for source, destination, identity in reversed(moved):
        try:
            destination_is_ours = path_matches_identity(destination, identity)
            source_is_ours = path_matches_identity(source, identity)
        except OSError:
            failures.append(destination.name)
            continue

        if not destination_is_ours:
            if not source_is_ours:
                failures.append(destination.name)
            continue

        try:
            if source_is_ours:
                # A post-link step failed before source unlink. Removing only our
                # matching destination restores the original staging-only state.
                destination.unlink()
                continue

            if os.path.lexists(source):
                # Never overwrite a path another process created in staging.
                failures.append(destination.name)
                continue

            try:
                os.link(destination, source, follow_symlinks=False)
            except OSError as exc:
                if exc.errno not in NO_REPLACE_UNSUPPORTED | {errno.EPERM}:
                    raise
                rename_without_overwrite(destination, source)
                continue
            if path_matches_identity(destination, identity):
                destination.unlink()
            else:
                failures.append(destination.name)
        except OSError:
            failures.append(destination.name)

    return failures


def commit_plan(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    manifest = load_manifest(manifest_path)

    raw_output_dir = manifest.get("output_dir")
    raw_staging_dir = manifest.get("staging_dir")
    raw_items = manifest.get("items")

    if not isinstance(raw_output_dir, str):
        raise PlanError("manifest output_dir is invalid")

    if not isinstance(raw_staging_dir, str):
        raise PlanError("manifest staging_dir is invalid")

    output_dir = resolve_output_directory(raw_output_dir)
    staging_dir = resolve_staging_directory(raw_staging_dir, output_dir)
    if (
        manifest.get("output_identity") != list(directory_identity(output_dir))
        or manifest.get("staging_identity") != list(directory_identity(staging_dir))
    ):
        raise PlanError("download output or staging directory identity changed")

    if not isinstance(raw_items, list) or not raw_items:
        raise PlanError("manifest contains no transfer items")

    if len(raw_items) > 16:
        raise PlanError("manifest contains too many transfer items")

    publications: list[tuple[Path, Path]] = []
    seen_destinations: set[Path] = set()
    seen_staging_names: set[str] = set()

    for raw_item in raw_items:
        if not isinstance(raw_item, dict):
            raise PlanError("manifest transfer item is invalid")

        staging_name = raw_item.get("staging_name")
        raw_destination = raw_item.get("destination")

        if (
            not isinstance(staging_name, str)
            or not STAGING_NAME_RE.fullmatch(staging_name)
        ):
            raise PlanError("manifest staging filename is invalid")

        if staging_name in seen_staging_names:
            raise PlanError("manifest contains duplicate staging filenames")
        seen_staging_names.add(staging_name)

        destination = resolve_destination(
            raw_destination,
            output_dir,
            "manifest destination",
        )

        if destination in seen_destinations:
            raise PlanError("manifest contains duplicate destinations")
        seen_destinations.add(destination)

        source = staging_dir / staging_name

        try:
            source_stat = source.lstat()
        except FileNotFoundError as exc:
            raise PlanError(
                f"downloaded staging file is missing: {staging_name}"
            ) from exc

        if stat.S_ISLNK(source_stat.st_mode) or not stat.S_ISREG(source_stat.st_mode):
            raise PlanError(
                f"downloaded staging entry is unsafe: {staging_name}"
            )

        if source_stat.st_size <= 0:
            raise PlanError(
                f"downloaded staging file is empty: {staging_name}"
            )

        aria2_control = Path(f"{source}.aria2")
        if os.path.lexists(aria2_control):
            raise PlanError(
                f"aria2 transfer is incomplete: {staging_name}"
            )

        if os.path.lexists(destination):
            raise DestinationExistsError(
                f"destination already exists: {destination.name}"
            )

        publications.append((source, destination))

    moved: list[tuple[Path, Path, tuple[int, int]]] = []
    requested_signal = 0

    def remember_signal(signal_number: int, _frame: object) -> None:
        nonlocal requested_signal
        if requested_signal == 0:
            requested_signal = signal_number

    def check_interruption() -> None:
        if requested_signal:
            raise PublicationInterrupted(requested_signal)

    # A handler must not raise between os.link() and rollback registration.
    # Record requests until an entire component is registered; keep recording
    # later signals while rollback restores the transaction's original state.
    previous_handlers = {}
    try:
        for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            previous_handlers[signal_number] = signal.signal(
                signal_number, remember_signal
            )
        try:
            for source, destination in publications:
                check_interruption()
                publish_without_overwrite(source, destination, moved)
            check_interruption()
        except BaseException as exc:
            rollback_failures = rollback_publication(moved)
            if rollback_failures:
                raise PlanError(
                    "publication failed and rollback could not restore "
                    f"{len(rollback_failures)} component(s)"
                ) from exc
            raise
    finally:
        for signal_number, previous_handler in previous_handlers.items():
            signal.signal(signal_number, previous_handler)

    print(f"published_count={len(moved)}")
    return 0


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build or publish a private aria2 direct-transfer plan."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    root = subparsers.add_parser("private-root", help="select a validated local private application root")
    root.add_argument("--disk", action="store_true")
    root.add_argument("--no-runtime", action="store_true")
    root.set_defaults(handler=private_root)

    local = subparsers.add_parser("media-local-safe", help="check whether media may stay in the selected directory")
    local.add_argument("--output-dir", required=True)
    local.set_defaults(handler=media_local_safe)

    publish = subparsers.add_parser("publish-media", help="copy and atomically publish one completed local media file")
    publish.add_argument("--source", required=True)
    publish.add_argument("--source-identity", required=True)
    publish.add_argument("--output-dir", required=True)
    publish.add_argument("--output-identity", required=True)
    publish.set_defaults(handler=publish_media)

    space = subparsers.add_parser("check-space", help="check known media size against available local disk space")
    space.add_argument("--plan", required=True)
    space.add_argument("--output-dir", required=True)
    space.set_defaults(handler=check_space)

    cleanup = subparsers.add_parser("cleanup-workspace", help="remove a caller-authenticated private local workspace")
    cleanup.add_argument("--path", required=True)
    cleanup.add_argument("--identity", required=True)
    cleanup.add_argument("--keep", action="append", default=[])
    cleanup.add_argument("--keep-identity", action="append", default=[])
    cleanup.set_defaults(handler=cleanup_workspace)

    classify = subparsers.add_parser(
        "classify",
        help="classify the selected yt-dlp transport as direct or native",
    )
    classify.add_argument("--plan", required=True)
    classify.add_argument("--allow-https-direct", action="store_true")
    classify.set_defaults(handler=classify_plan)

    build = subparsers.add_parser(
        "build",
        help="convert a private yt-dlp plan into a private aria2 input file",
    )
    build.add_argument("--plan", required=True)
    build.add_argument("--output-dir", required=True)
    build.add_argument("--staging-dir", required=True)
    build.add_argument("--private-dir", required=True)
    build.add_argument("--aria2-input", required=True)
    build.add_argument("--manifest", required=True)
    build.add_argument("--allow-https-direct", action="store_true")
    build.set_defaults(handler=build_plan)

    commit = subparsers.add_parser(
        "commit",
        help="publish completed staging files under yt-dlp's expected names",
    )
    commit.add_argument("--manifest", required=True)
    commit.set_defaults(handler=commit_plan)

    return parser


def main() -> int:
    if sys.version_info < (3, 10):
        print(
            "Error: private aria2 planning requires Python 3.10 or newer",
            file=sys.stderr,
        )
        return EXIT_VALIDATION

    parser = create_parser()
    args = parser.parse_args()

    try:
        return int(args.handler(args))
    except PublicationInterrupted as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 128 + exc.signal_number
    except KeyboardInterrupt:
        return 130
    except DestinationExistsError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except PlanError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return EXIT_VALIDATION
    except OSError as exc:
        print(f"Error: operating-system failure: {exc}", file=sys.stderr)
        return EXIT_IO


if __name__ == "__main__":
    sys.exit(main())
