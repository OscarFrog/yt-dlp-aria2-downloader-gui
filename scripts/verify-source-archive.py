# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/verify-source-archive.py.

Verify source ZIP paths, modes and bytes against an immutable qualified Git tree.
Read members without extracting or executing archive contents.
"""

import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import zipfile


LIMIT = 64 * 1024 * 1024


class ArchiveRefusal(ValueError):
    """A fixed, non-sensitive explanation of an invalid source archive."""


def require(condition, message):
    if not condition:
        raise ArchiveRefusal(message)


def check_extra(extra):
    # Git emits exactly one extended modification timestamp. Other extensions
    # can change paths or extraction semantics differently between ZIP readers.
    require(len(extra) == 9 and extra[:5] == b"UT\x05\x00\x01",
            "archive extra fields differ from the Git timestamp format")


def check_local_header(source, item):
    source.fp.seek(item.header_offset)
    header = source.fp.read(30)
    require(len(header) == 30, "truncated archive local header")
    signature, _, flags, method, _, _, _, _, _, name_size, extra_size = struct.unpack(
        "<4s5H3I2H", header)
    require(signature == b"PK\x03\x04", "invalid archive local header")
    require(flags == item.flag_bits and method == item.compress_type,
            "archive local and central headers disagree")
    name = source.fp.read(name_size)
    encoding = "utf-8" if flags & 0x800 else "cp437"
    require(name == item.orig_filename.encode(encoding),
            "archive local path differs from the qualified source")
    check_extra(source.fp.read(extra_size))


def git(*args, input_data=None):
    result = subprocess.run(
        ["git", "--no-replace-objects", *args], input=input_data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False,
        env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"},
    )
    require(result.returncode == 0, "cannot read immutable Git source")
    require(len(result.stdout) <= LIMIT, "Git source exceeds archive limit")
    return result.stdout


def verify(archive, prefix, commit):
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "invalid source commit")
    require(re.fullmatch(r"yt-dlp-aria2-downloader-gui-[0-9]+\.[0-9]+\.[0-9]+/", prefix),
            "invalid archive prefix")
    require(git("rev-parse", f"{commit}^{{commit}}").decode().strip() == commit,
            "source does not identify a commit")
    entries = {}
    for row in git("ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
        if not row:
            continue
        metadata, path = row.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        require(kind == "blob" and mode in ("100644", "100755", "120000"),
                "unsupported Git source entry")
        name = path.decode("utf-8")
        require(not name.startswith("/") and all(p not in ("", ".", "..") for p in name.split("/")),
                "unsafe Git source path")
        entries[prefix + name] = (int(mode, 8), oid)
    expected_dirs = {prefix}
    for name in entries:
        parts = name.split("/")
        expected_dirs.update("/".join(parts[:i]) + "/" for i in range(1, len(parts)))
    require(Path(archive).stat().st_size <= LIMIT, "source archive exceeds limit")
    with zipfile.ZipFile(archive) as source:
        require(source.comment == commit.encode("ascii"), "ZIP source commit differs")
        members = source.infolist()
        names = [item.filename for item in members]
        require(len(names) == len(set(names)), "duplicate archive path")
        require(set(names) == set(entries) | expected_dirs, "archive inventory differs from Git tree")
        require(sum(item.file_size for item in members) <= LIMIT, "expanded archive exceeds limit")
        for item in members:
            require(item.orig_filename == item.filename, "ambiguous archive member name")
            require(not item.flag_bits & ~(0x800 | 0x8), "unsupported archive member flags")
            require(item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                    "unsupported source archive compression")
            check_extra(item.extra)
            check_local_header(source, item)
            if item.filename in expected_dirs:
                require(item.is_dir() and item.file_size == 0, "invalid archive directory")
                require(item.create_system == 0 and item.external_attr == 0x10,
                        "archive directory extraction mode differs")
                continue
            mode, oid = entries[item.filename]
            # The creator platform determines whether extractors interpret
            # Unix permission bits at all; checking only those bits is unsafe.
            if mode == 0o100644:
                require(item.create_system == 0 and item.external_attr == 0,
                        "archive regular-file extraction mode differs")
            elif mode == 0o120000:
                require(item.create_system == 3 and item.external_attr == 0o120777 << 16,
                        "archive symlink extraction mode differs")
            else:
                require(item.create_system == 3 and item.external_attr == mode << 16,
                        "archive executable extraction mode differs")
            expected = git("cat-file", "blob", oid)
            require(source.read(item) == expected, "archive member differs from qualified source")
    return len(entries)


def main():
    if len(sys.argv) != 4:
        print("Usage: verify-source-archive.py ZIP PREFIX COMMIT", file=sys.stderr)
        return 64
    try:
        count = verify(*sys.argv[1:])
    except ArchiveRefusal as error:
        print(f"Error: source archive identity/integrity verification failed: {error}.", file=sys.stderr)
        return 65
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile, UnicodeError):
        print("Error: source archive identity/integrity verification failed.", file=sys.stderr)
        return 65
    print(f"Verified {count} source paths, modes and contents against the exact Git commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
