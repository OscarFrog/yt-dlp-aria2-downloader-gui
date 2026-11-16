# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/ci-ubuntu-mirrors.py.

Select the official HTTPS archives in the known Ubuntu CI runner mirror list.
This source-only helper never installs packages or changes repository trust.
"""

import os
import errno
from pathlib import Path
import secrets
import stat
import sys


MIRROR_URI = "mirror+file:/etc/apt/apt-mirrors.txt"
KEYRING = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
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

    def __init__(self, category, *, source_uri_detail=None):
        super().__init__(category)
        self.category = category
        self.source_uri_detail = source_uri_detail


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


def read_file(directory, name, owner):
    descriptor = os.open(name, OPEN_READ, dir_fd=directory)
    try:
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
        data = os.read(descriptor, MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise PreparationError("size-limit")
        return data, metadata
    finally:
        os.close(descriptor)


def validate_sources(data):
    """Accept only signed Ubuntu stanzas using the known mirror indirection."""
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


def configure(directory, owner):
    """Replace only the reviewed mirror list; the internal path aids fixtures."""
    parent = open_directory(directory, owner)
    sources = None
    temporary = None
    try:
        sources = os.open("sources.list.d", OPEN_READ | os.O_DIRECTORY, dir_fd=parent)
        source_metadata = os.fstat(sources)
        if source_metadata.st_uid != owner:
            raise PreparationError("owner")
        if stat.S_IMODE(source_metadata.st_mode) & 0o022:
            raise PreparationError("permissions")
        source, _ = read_file(sources, "ubuntu.sources", owner)
        validate_sources(source)
        data, metadata = read_file(parent, "apt-mirrors.txt", owner)
        entries = tuple(tuple(line.split()) for line in data.decode("ascii").splitlines())
        if entries not in (ORIGINAL, SELECTED):
            raise PreparationError("mirror-list")
        if entries == SELECTED:
            return False
        replacement = "".join(f"{uri}\t{priority}\n" for uri, priority in SELECTED).encode("ascii")
        temporary = ".apt-mirrors-" + secrets.token_hex(12)
        output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        with os.fdopen(output, "wb") as stream:
            stream.write(replacement)
            stream.flush()
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fsync(stream.fileno())
        current, current_metadata = read_file(parent, "apt-mirrors.txt", owner)
        if (current != data or (current_metadata.st_dev, current_metadata.st_ino)
                != (metadata.st_dev, metadata.st_ino)
                or read_file(sources, "ubuntu.sources", owner)[0] != source):
            raise PreparationError("concurrent-change")
        os.replace(temporary, "apt-mirrors.txt", src_dir_fd=parent, dst_dir_fd=parent)
        temporary = None
        os.fsync(parent)
        return True
    finally:
        if temporary is not None:
            os.unlink(temporary, dir_fd=parent)
        if sources is not None:
            os.close(sources)
        os.close(parent)


def main():
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
        return 65
    print("Ubuntu CI mirrors: official HTTPS archives " + ("selected." if changed else "already selected."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
