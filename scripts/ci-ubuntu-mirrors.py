# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/ci-ubuntu-mirrors.py.

Select the official HTTPS archives in the known Ubuntu CI runner mirror list.
This source-only helper never installs packages or changes repository trust.
"""

import os
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


def open_directory(path, owner):
    """Pin every path component without following a symlink."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("invalid APT directory")
    descriptor = os.open("/", OPEN_READ | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            child = os.open(component, OPEN_READ | os.O_DIRECTORY, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        metadata = os.fstat(descriptor)
        if metadata.st_uid != owner or stat.S_IMODE(metadata.st_mode) & 0o022:
            raise ValueError("APT directory is not owned and protected")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_file(directory, name, owner):
    descriptor = os.open(name, OPEN_READ, dir_fd=directory)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != owner
                or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) & 0o022
                or metadata.st_size > MAX_BYTES):
            raise ValueError("APT configuration is not a bounded owned regular file")
        data = os.read(descriptor, MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError("APT configuration exceeds its size bound")
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
            raise ValueError("unsupported Ubuntu source stanza")
        current[key] = value.strip()
    if not stanzas:
        raise ValueError("missing Ubuntu source stanza")
    for stanza in stanzas:
        if (stanza.get("URIs") != MIRROR_URI or stanza.get("Signed-By") != KEYRING
                or stanza.get("Types") not in ("deb", "deb deb-src")
                or not stanza.get("Suites") or not stanza.get("Components")
                or set(stanza) - {"Types", "URIs", "Signed-By", "Suites", "Components"}):
            raise ValueError("unsupported Ubuntu source or signature configuration")


def configure(directory, owner):
    """Replace only the reviewed mirror list; the internal path aids fixtures."""
    parent = open_directory(directory, owner)
    sources = None
    temporary = None
    try:
        sources = os.open("sources.list.d", OPEN_READ | os.O_DIRECTORY, dir_fd=parent)
        source_metadata = os.fstat(sources)
        if source_metadata.st_uid != owner or stat.S_IMODE(source_metadata.st_mode) & 0o022:
            raise ValueError("Ubuntu source directory is not owned and protected")
        source, _ = read_file(sources, "ubuntu.sources", owner)
        validate_sources(source)
        data, metadata = read_file(parent, "apt-mirrors.txt", owner)
        entries = tuple(tuple(line.split()) for line in data.decode("ascii").splitlines())
        if entries not in (ORIGINAL, SELECTED):
            raise ValueError("unrecognized Ubuntu runner mirror list")
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
            raise ValueError("APT configuration changed during preparation")
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
    except (OSError, ValueError, UnicodeError):
        print("Error: Ubuntu CI mirror preparation failed; package setup must stop.",
              file=sys.stderr)
        return 65
    print("Ubuntu CI mirrors: official HTTPS archives " + ("selected." if changed else "already selected."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
