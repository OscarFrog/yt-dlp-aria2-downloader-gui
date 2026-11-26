# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/observer_build.py.

Build the qualification-only observer offline from this checkout or source ZIP.
"""

import argparse
from functools import cache
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import stat
import subprocess


CRATE = Path(__file__).resolve().with_name('process-observer-rs')
OUTPUT = 'qualification-observer'


@cache
def build_directory():
    release = platform.freedesktop_os_release()
    if (release.get('ID'), release.get('VERSION_ID'), platform.machine()) != ('fedora', '45', 'x86_64'):
        raise RuntimeError('The qualification observer requires Fedora 45 x86_64')
    key = hashlib.sha256()
    for path in [CRATE / 'Cargo.toml', CRATE / 'Cargo.lock', *sorted((CRATE / 'src').rglob('*.rs'))]:
        key.update(path.relative_to(CRATE).as_posix().encode() + b'\0')
        key.update(hashlib.sha256(path.read_bytes()).digest())
    for tool in ('rustc', 'cargo', 'cc'):
        info = (Path('/usr/bin') / tool).stat()
        key.update(f'{tool}:{info.st_dev}:{info.st_ino}:{info.st_mtime_ns}\n'.encode())
    root = Path('/tmp') / f'yt-dlp-qualification-rust-{os.geteuid()}'
    target = root / key.hexdigest()
    for directory in (root, target):
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.lstat()
        if info.st_uid != os.geteuid() or info.st_mode != (stat.S_IFDIR | 0o700):
            raise PermissionError('Unsafe qualification build directory')
    return target


def cargo(*args):
    target = build_directory()
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(target), 'LC_ALL': 'C.UTF-8',
           'CARGO_HOME': str(target / 'cargo-home'), 'CARGO_TARGET_DIR': str(target),
           'CARGO_NET_OFFLINE': 'true', 'CARGO_INCREMENTAL': '0'}
    subprocess.run(['/usr/bin/cargo', *args], cwd='/', env=env, check=True, stdin=subprocess.DEVNULL)


@cache
def observer_binary():
    target = build_directory()
    binary = target / 'release' / OUTPUT
    # Cargo publishes a finished executable. Serialize the cold build across
    # fixture processes, including processes using different private HOMEs.
    descriptor = os.open(target, os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if not binary.exists():
            cargo('build', '--frozen', '--release', '--manifest-path', str(CRATE / 'Cargo.toml'))
        info = binary.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022
                or not os.access(binary, os.X_OK)):
            raise PermissionError('Unsafe qualification executable')
    finally:
        os.close(descriptor)
    return binary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='also check Rust format, lint and unit tests')
    options = parser.parse_args()
    binary = observer_binary()
    if options.check:
        manifest = str(CRATE / 'Cargo.toml')
        cargo('fmt', '--manifest-path', manifest, '--', '--check')
        cargo('clippy', '--frozen', '--release', '--all-targets', '--manifest-path', manifest, '--', '-D', 'warnings')
        cargo('test', '--frozen', '--release', '--manifest-path', manifest)
    print(binary)
