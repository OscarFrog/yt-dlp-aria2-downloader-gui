# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/ci-ubuntu-mirrors.py.

Run CI APT with dedicated signed Ubuntu sources; retain the legacy normalizer.
This source-only helper never changes repository signing trust.
"""

import os
from contextlib import contextmanager
import fcntl
import re
import subprocess
import errno
from pathlib import Path
import secrets
import stat
import sys


MIRROR_URI = "mirror+file:/etc/apt/apt-mirrors.txt"
KEYRING = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
MIXED_URIS = (MIRROR_URI, "http://security.ubuntu.com/ubuntu")
DIRECT_URIS = ("https://archive.ubuntu.com/ubuntu/", "https://security.ubuntu.com/ubuntu/")
NOBLE_SUITES = (("noble", "noble-updates", "noble-backports"), ("noble-security",))
NOBLE_COMPONENTS = frozenset(("main", "restricted", "universe", "multiverse"))
ORIGINAL = (
    ("http://azure.archive.ubuntu.com/ubuntu/", "priority:1"),
    ("https://archive.ubuntu.com/ubuntu/", "priority:2"),
    ("https://security.ubuntu.com/ubuntu/", "priority:3"),
)
SELECTED = (
    ("https://archive.ubuntu.com/ubuntu/", "priority:1"),
    ("https://security.ubuntu.com/ubuntu/", "priority:2"),
)
OPEN_READ = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
MAX_BYTES = 16384
FAILURE_CATEGORIES = (
    "directory-path", "owner", "permissions", "file-type", "file-links",
    "size-limit", "source-syntax", "source-uri", "source-signature",
    "source-fields", "mirror-list", "concurrent-change",
)
# Diagnostic vocabulary only, never an acceptance list. These exact endpoints
# occur in the reviewed runner-image recipe; no host/scheme normalization occurs.
SOURCE_URI_SHAPES = {
    MIRROR_URI: "expected-mirror-file",
    "https://archive.ubuntu.com/ubuntu/": "https-archive",
    "https://security.ubuntu.com/ubuntu/": "https-security",
    "http://azure.archive.ubuntu.com/ubuntu/": "http-azure",
    "http://azure.archive.ubuntu.com/ubuntu": "http-azure-no-slash",
    "http://archive.ubuntu.com/ubuntu/": "http-archive",
    "http://archive.ubuntu.com/ubuntu": "http-archive-no-slash",
    "http://security.ubuntu.com/ubuntu/": "http-security",
    "http://security.ubuntu.com/ubuntu": "http-security-no-slash",
}


class PreparationError(ValueError):
    """Carry only a fixed diagnostic category, never configuration contents."""

    def __init__(self, category, *, source_uri_detail=None, mirror_list_detail=None):
        super().__init__(category)
        self.category = category
        self.source_uri_detail = source_uri_detail
        self.mirror_list_detail = mirror_list_detail


def source_uri_shape(value):
    """Classify an already parsed field without retaining any received URI."""
    if value is None:
        return "missing"
    if value == "":
        return "empty"
    return SOURCE_URI_SHAPES.get(value, "other")


def source_uri_diagnostic(error):
    """Export only a closed label and bounded parser positions on URI refusal."""
    if not isinstance(error, PreparationError) or failure_category(error) != "source-uri":
        return None
    detail = error.source_uri_detail
    if type(detail) is not tuple or len(detail) != 3:
        return None
    shape, index, count = detail
    if (type(shape) is not str or shape not in (*SOURCE_URI_SHAPES.values(), "missing", "empty", "other")
            or type(index) is not int or type(count) is not int
            or not 1 <= index <= count <= MAX_BYTES):
        return None
    return f"Source URI shape: {shape}; stanza: {index}/{count}"


def mirror_list_shape(layout, entries):
    """Describe already parsed rejected entries; never retain received tokens."""
    profile = "historical-indirect" if layout is None else layout
    # The complete count remains visible, but no partial list is presented as
    # complete. The diagnostic has a separate bound from the secured file read.
    if len(entries) > 8:
        return profile, len(entries), None
    shapes = []
    for entry in entries:
        if len(entry) != 2:
            shapes.append(("invalid-entry", "other"))
            continue
        uri, priority = entry
        shapes.append((SOURCE_URI_SHAPES.get(uri, "other"), {
            "priority:1": "priority-1", "priority:2": "priority-2",
            "priority:3": "priority-3",
        }.get(priority, "other")))
    return profile, len(entries), tuple(shapes)


def mirror_list_diagnostic(error):
    """Export only closed labels, ordered shapes and a bounded entry count."""
    if not isinstance(error, PreparationError) or failure_category(error) != "mirror-list":
        return None
    detail = error.mirror_list_detail
    if type(detail) is not tuple or len(detail) != 3:
        return None
    profile, count, shapes = detail
    if (type(profile) is not str or profile not in ("historical-indirect", "mixed", "direct")
            or type(count) is not int or not 0 <= count <= MAX_BYTES):
        return None
    if count > 8:
        if shapes is not None:
            return None
        summary = "omitted-limit"
    else:
        if type(shapes) is not tuple or len(shapes) != count:
            return None
        for shape in shapes:
            if (type(shape) is not tuple or len(shape) != 2
                    or type(shape[0]) is not str
                    or shape[0] not in (*SOURCE_URI_SHAPES.values(), "other", "invalid-entry")
                    or type(shape[1]) is not str
                    or shape[1] not in ("priority-1", "priority-2", "priority-3", "other")):
                return None
        summary = ",".join(f"{uri}/{priority}" for uri, priority in shapes) or "empty"
    return f"Mirror list profile: {profile}; entries: {count}; entry-shapes: {summary}"


def failure_category(error):
    """Reduce rejected input and OS errors to bounded, non-sensitive labels."""
    if isinstance(error, PreparationError):
        if type(error.category) is str and error.category in FAILURE_CATEGORIES:
            return error.category
    if isinstance(error, OSError):
        if error.errno == errno.ENOENT:
            return "missing-file"
        if error.errno in (errno.EACCES, errno.EPERM):
            return "access-denied"
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            return "path-type"
        return "io-error"
    return "unrecognized-configuration"


def open_directory(path, owner):
    """Pin every path component without following a symlink."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise PreparationError("directory-path")
    descriptor = os.open("/", OPEN_READ | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            child = os.open(component, OPEN_READ | os.O_DIRECTORY, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        metadata = os.fstat(descriptor)
        if metadata.st_uid != owner:
            raise PreparationError("owner")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise PreparationError("permissions")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def file_identity(metadata):
    """Include in-place changes as well as replacement and permission changes."""
    return (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid,
            metadata.st_mode, metadata.st_nlink, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)


def read_file(directory, name, owner):
    with scoped_descriptor(os.open(name, OPEN_READ, dir_fd=directory)) as descriptor:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PreparationError("file-type")
        if metadata.st_uid != owner:
            raise PreparationError("owner")
        if metadata.st_nlink != 1:
            raise PreparationError("file-links")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise PreparationError("permissions")
        if metadata.st_size > MAX_BYTES:
            raise PreparationError("size-limit")
        data = b""
        while True:
            chunk = os.read(descriptor, MAX_BYTES + 1 - len(data))
            data += chunk
            if len(data) > MAX_BYTES:
                raise PreparationError("size-limit")
            if not chunk:
                break
        if len(data) != metadata.st_size or file_identity(os.fstat(descriptor)) != file_identity(metadata):
            raise PreparationError("concurrent-change")
        return data, metadata


def validate_sources(data):
    """Keep the historical layout; admit only complete strict Noble direct layouts."""
    stanzas = []
    current = {}
    for line in data.decode("ascii").splitlines() + [""]:
        if line.startswith("#"):
            continue
        if not line.strip():
            if current:
                stanzas.append(current)
                current = {}
            continue
        key, separator, value = line.partition(":")
        if not separator or not key or key != key.strip() or key in current:
            raise PreparationError("source-syntax")
        current[key] = value.strip()
    if not stanzas:
        raise PreparationError("source-syntax")
    uris = tuple(stanza.get("URIs") for stanza in stanzas)
    if uris in (MIXED_URIS, DIRECT_URIS):
        if (any(byte < 32 and byte not in (9, 10, 13) or byte == 127 for byte in data)
                or b"\r" in data.replace(b"\r\n", b"")):
            raise PreparationError("source-syntax")
        for index, stanza in enumerate(stanzas):
            if stanza.get("Signed-By") != KEYRING:
                raise PreparationError("source-signature")
            components = stanza.get("Components", "").split()
            if (set(stanza) != {"Types", "URIs", "Signed-By", "Suites", "Components"}
                    or stanza.get("Types") not in ("deb", "deb deb-src")
                    or tuple(stanza.get("Suites", "").split()) != NOBLE_SUITES[index]
                    or len(components) != len(NOBLE_COMPONENTS)
                    or frozenset(components) != NOBLE_COMPONENTS):
                raise PreparationError("source-fields")
        return "mixed" if uris == MIXED_URIS else "direct"
    for index, stanza in enumerate(stanzas, 1):
        if stanza.get("URIs") != MIRROR_URI:
            raise PreparationError("source-uri", source_uri_detail=(
                source_uri_shape(stanza.get("URIs")), index, len(stanzas)))
        if stanza.get("Signed-By") != KEYRING:
            raise PreparationError("source-signature")
        if (stanza.get("Types") not in ("deb", "deb deb-src")
                or not stanza.get("Suites") or not stanza.get("Components")
                or set(stanza) - {"Types", "URIs", "Signed-By", "Suites", "Components"}):
            raise PreparationError("source-fields")


def direct_sources(source):
    """Change only the two validated URI lines, retaining other source bytes."""
    result = []
    index = 0
    for line in source.splitlines(keepends=True):
        if line.startswith(b"URIs:"):
            ending = b"\r\n" if line.endswith(b"\r\n") else b"\n" if line.endswith(b"\n") else b""
            line = b"URIs: " + DIRECT_URIS[index].encode("ascii") + ending
            index += 1
        result.append(line)
    replacement = b"".join(result)
    if index != 2 or validate_sources(replacement) != "direct":
        raise PreparationError("source-fields")
    return replacement


def validate_directories(directory, parent, sources, owner):
    """Refuse detached/replaced directories instead of preparing an unused tree."""
    current = open_directory(directory, owner)
    try:
        before, after = os.fstat(parent), os.fstat(current)
        linked = os.stat("sources.list.d", dir_fd=current, follow_symlinks=False)
        opened = os.fstat(sources)
        if ((before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
                or (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid, opened.st_gid)
                != (linked.st_dev, linked.st_ino, linked.st_mode, linked.st_uid, linked.st_gid)
                or not stat.S_ISDIR(linked.st_mode) or linked.st_uid != owner
                or stat.S_IMODE(linked.st_mode) & 0o022):
            raise PreparationError("concurrent-change")
    finally:
        os.close(current)


def configure(directory, owner):
    """Commit one reviewed file; direct-source results use fixed status tokens."""
    parent = open_directory(directory, owner)
    sources = None
    temporary = None
    target_directory = parent
    failed = False
    try:
        sources = os.open("sources.list.d", OPEN_READ | os.O_DIRECTORY, dir_fd=parent)
        source_metadata = os.fstat(sources)
        if source_metadata.st_uid != owner:
            raise PreparationError("owner")
        if stat.S_IMODE(source_metadata.st_mode) & 0o022:
            raise PreparationError("permissions")
        source, source_file_metadata = read_file(sources, "ubuntu.sources", owner)
        layout = validate_sources(source)
        data, metadata = read_file(parent, "apt-mirrors.txt", owner)
        entries = tuple(tuple(line.split()) for line in data.decode("ascii").splitlines())
        if entries not in (ORIGINAL, SELECTED):
            raise PreparationError("mirror-list", mirror_list_detail=mirror_list_shape(layout, entries))
        if layout in ("mixed", "direct"):
            target_directory, target_name, target_metadata = sources, "ubuntu.sources", source_file_metadata
            replacement = direct_sources(source) if layout == "mixed" else source
            changed = layout == "mixed"
        else:
            target_name, target_metadata = "apt-mirrors.txt", metadata
            replacement = "".join(f"{uri}\t{priority}\n" for uri, priority in SELECTED).encode("ascii")
            changed = entries != SELECTED

        def revalidate():
            validate_directories(directory, parent, sources, owner)
            current, current_metadata = read_file(parent, "apt-mirrors.txt", owner)
            current_source, current_source_metadata = read_file(sources, "ubuntu.sources", owner)
            if (current != data or file_identity(current_metadata) != file_identity(metadata)
                    or current_source != source
                    or file_identity(current_source_metadata) != file_identity(source_file_metadata)):
                raise PreparationError("concurrent-change")

        if not changed:
            revalidate()
            # A previous rename may have succeeded before its directory fsync
            # failed. Repetition must establish durability, not just equality.
            current = os.open(target_name, OPEN_READ, dir_fd=target_directory)
            try:
                if file_identity(os.fstat(current)) != file_identity(target_metadata):
                    raise PreparationError("concurrent-change")
                os.fsync(current)
            finally:
                os.close(current)
            os.fsync(target_directory)
            revalidate()
            return "direct-current" if layout == "direct" else False
        temporary = ".apt-mirrors-" + secrets.token_hex(12)
        output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=target_directory)
        with os.fdopen(output, "wb") as stream:
            if stream.write(replacement) != len(replacement):
                raise OSError(errno.EIO, "incomplete staged write")
            stream.flush()
            os.fchown(stream.fileno(), target_metadata.st_uid, target_metadata.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(target_metadata.st_mode))
            os.fsync(stream.fileno())
            staged_metadata = os.fstat(stream.fileno())
        revalidate()
        staged, staged_current = read_file(target_directory, temporary, owner)
        if staged != replacement or file_identity(staged_current) != file_identity(staged_metadata):
            raise PreparationError("concurrent-change")
        os.replace(temporary, target_name, src_dir_fd=target_directory, dst_dir_fd=target_directory)
        temporary = None
        os.fsync(target_directory)
        validate_directories(directory, parent, sources, owner)
        final, final_metadata = read_file(target_directory, target_name, owner)
        if (final != replacement or (final_metadata.st_dev, final_metadata.st_ino)
                != (staged_metadata.st_dev, staged_metadata.st_ino)
                or (final_metadata.st_uid, final_metadata.st_gid, final_metadata.st_mode,
                    final_metadata.st_nlink, final_metadata.st_size, final_metadata.st_mtime_ns)
                != (staged_metadata.st_uid, staged_metadata.st_gid, staged_metadata.st_mode,
                    staged_metadata.st_nlink, staged_metadata.st_size, staged_metadata.st_mtime_ns)):
            raise PreparationError("concurrent-change")
        other_directory, other_name = ((parent, "apt-mirrors.txt") if layout == "mixed"
                                       else (sources, "ubuntu.sources"))
        other, other_metadata = read_file(other_directory, other_name, owner)
        expected, expected_metadata = ((data, metadata) if layout == "mixed"
                                       else (source, source_file_metadata))
        if other != expected or file_identity(other_metadata) != file_identity(expected_metadata):
            raise PreparationError("concurrent-change")
        return "direct-selected" if layout == "mixed" else True
    except BaseException:
        failed = True
        raise
    finally:
        cleanup_error = None
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=target_directory)
            except OSError as error:
                cleanup_error = error
        if sources is not None:
            try:
                os.close(sources)
            except OSError as error:
                if cleanup_error is None:
                    cleanup_error = error
        try:
            os.close(parent)
        except OSError as error:
            if cleanup_error is None:
                cleanup_error = error
        if not failed and cleanup_error is not None:
            raise cleanup_error


# A dedicated configuration is a command-scoped boundary, not a repair of the
# runner's sources. The legacy normalizer below remains separately regression
# tested; CI uses only --setup / --apt.
CI_APT_ROOT = Path('/run/yt-dlp-ci-apt')
APT_OPTIONS = frozenset((
    'Acquire::Retries=3', 'Acquire::http::Timeout=30',
    'Acquire::https::Timeout=30', 'DPkg::Lock::Timeout=60',
    'APT::Update::Error-Mode=any',
))
CI_PACKAGES = frozenset((
    'aria2', 'build-essential', 'curl', 'desktop-file-utils', 'ffmpeg',
    'findutils', 'gnupg', 'libmp3lame-dev', 'libopus-dev', 'libvpx-dev',
    'libx264-dev', 'lintian', 'nasm', 'pkg-config', 'python3-venv',
    'shellcheck', 'unzip', 'xz-utils',
))


def dedicated_files(root):
    """Exact public bytes; no runner source, preference, hook or proxy input."""
    root = str(root)
    if not re.fullmatch(r'/[a-zA-Z0-9/_-]+', root):
        raise PreparationError('directory-path')
    sources = ''.join(
        f'Types: deb\nURIs: {uri}\nSuites: {" ".join(suites)}\n'
        'Components: main restricted universe multiverse\n'
        f'Signed-By: {KEYRING}\n\n'
        for uri, suites in zip(DIRECT_URIS, NOBLE_SUITES)
    ).encode('ascii')
    # APT_CONFIG is read before parts/main. Command-line -o alone is too late
    # to exclude ambient configuration and hooks. Empty lists/cache also avoid
    # installing candidates from stale foreign indexes left by the runner.
    config = '\n'.join((
        f'Dir::Etc::main "{root}/empty.conf";',
        f'Dir::Etc::parts "{root}/empty";',
        f'Dir::Etc::sourcelist "{root}/ubuntu.sources";',
        f'Dir::Etc::sourceparts "{root}/empty";',
        f'Dir::Etc::preferences "{root}/empty.conf";',
        f'Dir::Etc::preferencesparts "{root}/empty";',
        f'Dir::Etc::trusted "{root}/empty.conf";',
        f'Dir::Etc::trustedparts "{root}/empty";',
        f'Dir::Etc::netrc "{root}/empty.conf";',
        f'Dir::Etc::netrcparts "{root}/empty";',
        f'Dir::State::lists "{root}/lists";',
        f'Dir::Cache "{root}/cache";',
        'Dir::Cache::pkgcache "";', 'Dir::Cache::srcpkgcache "";',
        'Acquire::Retries "3";', 'APT::Update::Error-Mode "any";',
        'Acquire::https::AllowRedirect "false";',
        'Acquire::https::Verify-Peer "true";',
        'Acquire::https::Verify-Host "true";',
        '',
    )).encode('ascii')
    return {'apt.conf': config, 'ubuntu.sources': sources, 'empty.conf': b''}


@contextmanager
def scoped_descriptor(descriptor):
    """A teardown failure cannot replace this operation's first exception."""
    failed = False
    try:
        yield descriptor
    except BaseException:
        failed = True
        raise
    finally:
        try:
            os.close(descriptor)
        except OSError:
            if not failed:
                raise


def dedicated_snapshot(root, owner):
    """Authenticate the configuration consumed by each operation; never repair."""
    with scoped_descriptor(open_directory(root, owner)) as descriptor:
        metadata = os.fstat(descriptor)
        if stat.S_IMODE(metadata.st_mode) != 0o755:
            raise PreparationError('permissions')
        snapshot = [('root', metadata.st_dev, metadata.st_ino)]
        for name, expected in dedicated_files(root).items():
            data, info = read_file(descriptor, name, owner)
            if data != expected:
                raise PreparationError('source-fields')
            if stat.S_IMODE(info.st_mode) != 0o644:
                raise PreparationError('permissions')
            snapshot.append((name, file_identity(info)))
        with scoped_descriptor(open_directory(root / 'empty', owner)) as empty:
            if os.listdir(empty):
                raise PreparationError('source-fields')
            info = os.fstat(empty)
            if stat.S_IMODE(info.st_mode) != 0o755:
                raise PreparationError('permissions')
            snapshot.append(('empty', info.st_dev, info.st_ino, info.st_mode))
        # APT can chown partial subdirectories to its sandbox user, but their
        # containing directories must stay owned and writable only by root.
        for name in ('lists', 'cache', 'cache/archives'):
            with scoped_descriptor(open_directory(root / name, owner)) as child:
                info = os.fstat(child)
                if stat.S_IMODE(info.st_mode) != 0o755:
                    raise PreparationError('permissions')
                snapshot.append((name, info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode))
        with scoped_descriptor(open_directory(Path(KEYRING).parent, owner)) as keys:
            data, info = read_file(keys, Path(KEYRING).name, owner)
            if not data or not stat.S_IMODE(info.st_mode) & 0o004:
                raise PreparationError('source-signature')
            snapshot.append(('keyring', file_identity(info), data))
        return snapshot


def prepare_dedicated(root, owner):
    """Create once in a protected parent; incomplete preparation stays refused."""
    with scoped_descriptor(open_directory(root.parent, owner)) as parent:
        try:
            os.mkdir(root.name, mode=0o700, dir_fd=parent)
            created = True
        except FileExistsError:
            created = False
        with scoped_descriptor(os.open(root.name, OPEN_READ | os.O_DIRECTORY, dir_fd=parent)) as descriptor:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            if created:
                for name in ('empty', 'lists', 'cache', 'cache/archives'):
                    os.mkdir(root / name, mode=0o755)
                    os.chmod(root / name, 0o755)
                for name, data in dedicated_files(root).items():
                    with scoped_descriptor(os.open(
                            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                            0o600, dir_fd=descriptor)) as fd:
                        if os.write(fd, data) != len(data):
                            raise PreparationError('concurrent-change')
                        os.fchmod(fd, 0o644)
                        os.fsync(fd)
                os.fchmod(descriptor, 0o755)
            durable_snapshot(root, descriptor, owner)


def durable_snapshot(root, descriptor, owner):
    """Re-establish durability before every use, including a failed setup repeat."""
    before = dedicated_snapshot(root, owner)
    held = os.fstat(descriptor)
    if before[0] != ('root', held.st_dev, held.st_ino):
        raise PreparationError('concurrent-change')
    for name in dedicated_files(root):
        with scoped_descriptor(os.open(name, OPEN_READ, dir_fd=descriptor)) as fd:
            os.fsync(fd)
    for name in ('empty', 'lists', 'cache', 'cache/archives'):
        with scoped_descriptor(open_directory(root / name, owner)) as child:
            os.fsync(child)
    os.fsync(descriptor)
    with scoped_descriptor(open_directory(root.parent, owner)) as parent:
        os.fsync(parent)
    if dedicated_snapshot(root, owner) != before:
        raise PreparationError('concurrent-change')
    return before


def validated_apt_arguments(arguments):
    """Closed workflow API: no caller source/config/authentication overrides."""
    arguments = list(arguments)
    if len(arguments) > 100 or any(type(value) is not str or len(value) > 4096 for value in arguments):
        raise PreparationError('source-fields')
    while arguments[:1] == ['-o']:
        if len(arguments) < 2 or arguments[1] not in APT_OPTIONS:
            raise PreparationError('source-fields')
        arguments = arguments[2:]
    if arguments == ['update']:
        return
    if not arguments or arguments[0] not in ('install', 'remove', 'purge'):
        raise PreparationError('source-fields')
    operation = arguments.pop(0)
    if arguments[:1] != ['--yes']:
        raise PreparationError('source-fields')
    arguments.pop(0)
    if operation == 'install' and arguments[:1] == ['--no-install-recommends']:
        arguments.pop(0)
    if not arguments:
        raise PreparationError('source-fields')
    for value in arguments:
        if value in CI_PACKAGES and operation == 'install':
            continue
        if value == 'yt-dlp-aria2-downloader-gui' and operation in ('remove', 'purge'):
            continue
        # Local DEBs are candidate artifacts already authenticated by the
        # package lifecycle caller; accepting them does not authenticate them.
        if (operation == 'install' and value.startswith('/') and value.endswith('.deb')
                and '\n' not in value and '\r' not in value and '\x00' not in value):
            continue
        raise PreparationError('source-fields')


def run_dedicated(root, owner, arguments):
    validated_apt_arguments(arguments)
    descriptor = open_directory(root, owner)
    status = 0
    failed = False
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        before = durable_snapshot(root, descriptor, owner)
        environment = {
            'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root',
            'LC_ALL': 'C', 'LANGUAGE': 'C', 'DEBIAN_FRONTEND': 'noninteractive',
            'APT_CONFIG': str(root / 'apt.conf'),
        }
        result = subprocess.run(['/usr/bin/apt-get', *arguments], env=environment, check=False)
        status = result.returncode if result.returncode >= 0 else 128 - result.returncode
        # Preserve the original APT failure even if revalidation also fails.
        try:
            if dedicated_snapshot(root, owner) != before:
                raise PreparationError('concurrent-change')
        except (OSError, ValueError, UnicodeError):
            if status:
                return status
            raise
        return status
    except BaseException:
        failed = True
        raise
    finally:
        try:
            os.close(descriptor)
        except OSError:
            if not failed and not status:
                raise


def dedicated_main(arguments):
    if os.geteuid() != 0 or not arguments or arguments[0] not in ('--setup', '--apt'):
        return 64
    try:
        # Supported disposable target, not an installation interface for hosts.
        platform = Path('/usr/lib/os-release').read_text(encoding='utf-8')
        fields = dict(line.split('=', 1) for line in platform.splitlines() if '=' in line)
        if fields.get('ID', '').strip('"') != 'ubuntu' or fields.get('VERSION_ID', '').strip('"') != '24.04':
            raise PreparationError('source-fields')
        if arguments == ['--setup']:
            prepare_dedicated(CI_APT_ROOT, 0)
            print('Ubuntu CI APT: dedicated signed HTTPS sources ready.')
            return 0
        if arguments[0] == '--apt':
            return run_dedicated(CI_APT_ROOT, 0, arguments[1:])
        return 64
    except (OSError, ValueError, UnicodeError) as error:
        print('Error: Ubuntu CI APT preparation or validation failed; package setup must stop.', file=sys.stderr)
        print('Category: ' + failure_category(error), file=sys.stderr)
        return 65


def main():
    if sys.argv[1:2] in (["--setup"], ["--apt"]):
        return dedicated_main(sys.argv[1:])
    if len(sys.argv) != 1 or os.geteuid() != 0:
        print("Error: CI mirror preparation requires root and accepts no arguments.", file=sys.stderr)
        return 64
    try:
        changed = configure("/etc/apt", 0)
    except (OSError, ValueError, UnicodeError) as error:
        print("Error: Ubuntu CI mirror preparation failed; package setup must stop.",
              file=sys.stderr)
        print("Category: " + failure_category(error), file=sys.stderr)
        detail = source_uri_diagnostic(error)
        if detail is not None:
            print(detail, file=sys.stderr)
        detail = mirror_list_diagnostic(error)
        if detail is not None:
            print(detail, file=sys.stderr)
        return 65
    if changed in ("direct-selected", "direct-current"):
        print("Ubuntu CI sources: official HTTPS archive/security "
              + ("selected." if changed == "direct-selected" else "already selected."))
    else:
        print("Ubuntu CI mirrors: official HTTPS archives " + ("selected." if changed else "already selected."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
