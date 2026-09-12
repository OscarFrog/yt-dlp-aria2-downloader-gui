# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/source-archive-integration.py.

Exercise source ZIP identity, inventory, mode and content checks on local Git.
"""

import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest
import warnings
import zipfile
import zlib


PROJECT = Path(__file__).resolve().parents[1]
CHECK = PROJECT / "scripts/verify-source-archive.py"
PREFIX = "yt-dlp-aria2-downloader-gui-1.2.3/"


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="source-archive-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.archive = self.root / "source.zip"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
            GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
            GIT_TERMINAL_PROMPT="0",
        )
        self.git("init", "--initial-branch=main")
        (self.repo / "nested").mkdir()
        (self.repo / "nested/data é.txt").write_text("qualified source\n")
        executable = self.repo / "script.sh"
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        (self.repo / "link").symlink_to("nested/data é.txt")
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", "source")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.git("archive", "--format=zip", f"--prefix={PREFIX}",
                 f"--output={self.archive}", self.commit)

    def git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.repo, env=self.env,
                                capture_output=True, timeout=15, check=True)
        return result.stdout.decode()

    def check(self, expected=0, reason=None):
        result = subprocess.run(
            [sys.executable, "-I", str(CHECK), str(self.archive), PREFIX, self.commit],
            cwd=self.repo, env=self.env, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stderr.decode())
        if reason is not None:
            self.assertIn(reason, result.stderr.decode())

    def rewrite(self, change):
        with zipfile.ZipFile(self.archive) as source:
            rows = [(item, source.read(item)) for item in source.infolist()]
            comment = source.comment
        rows, comment = change(rows, comment)
        with zipfile.ZipFile(self.archive, "w") as target:
            target.comment = comment
            for item, data in rows:
                attributes = item.external_attr
                target.writestr(item, data)
                # writestr supplies Unix 0600 whenever external_attr is zero.
                # Restore Git's DOS regular-file attributes before the central
                # directory is written so each test changes only its subject.
                item.external_attr = attributes

    def test_exact_archive_with_modes_unicode_and_symlink(self):
        self.check()

    def test_unchanged_rewrite_is_accepted(self):
        self.rewrite(lambda rows, comment: (rows, comment))
        self.check()

    def test_changed_bytes(self):
        def mutate(rows, comment):
            return [(i, b"different" if i.filename.endswith(".txt") else b) for i, b in rows], comment
        self.rewrite(mutate)
        self.check(65, "archive member differs from qualified source")

    def test_wrong_commit(self):
        self.rewrite(lambda rows, comment: (rows, b"0" * 40))
        self.check(65, "ZIP source commit differs")

    def test_missing_path(self):
        self.rewrite(lambda rows, comment: (rows[:-1], comment))
        self.check(65, "archive inventory differs from Git tree")

    def test_unexpected_path(self):
        with zipfile.ZipFile(self.archive, "a") as source:
            source.writestr(PREFIX + "../escape", b"unexpected")
        self.check(65, "archive inventory differs from Git tree")
        self.assertFalse((self.root / "escape").exists())

    def test_duplicate_path(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "a") as source:
                source.writestr(PREFIX + "script.sh", b"replacement")
        self.check(65, "duplicate archive path")

    def test_changed_executable_mode(self):
        def mutate(rows, comment):
            for item, _ in rows:
                if item.filename.endswith("script.sh"):
                    item.external_attr = 0o100644 << 16
            return rows, comment
        self.rewrite(mutate)
        self.check(65, "archive executable extraction mode differs")

    def test_changed_symlink_target(self):
        def mutate(rows, comment):
            return [(i, b"/etc/passwd" if i.filename.endswith("/link") else b) for i, b in rows], comment
        self.rewrite(mutate)
        self.check(65, "archive member differs from qualified source")

    def test_dos_creator_cannot_hide_executable_permissions(self):
        def mutate(rows, comment):
            for item, _ in rows:
                if item.filename.endswith("script.sh"):
                    item.create_system = 0
            return rows, comment
        self.rewrite(mutate)
        self.check(65, "archive executable extraction mode differs")

    def test_directory_permissions_cannot_make_source_inaccessible(self):
        def mutate(rows, comment):
            for item, _ in rows:
                if item.filename.endswith("nested/"):
                    item.create_system = 3
                    item.external_attr = 0o040000 << 16
            return rows, comment
        self.rewrite(mutate)
        self.check(65, "archive directory extraction mode differs")

    def test_dos_lower_attributes_cannot_change_extraction(self):
        def mutate(rows, comment):
            for item, _ in rows:
                if item.filename.endswith("script.sh"):
                    item.external_attr |= 0x10
            return rows, comment
        self.rewrite(mutate)
        self.check(65, "archive executable extraction mode differs")

    def test_unicode_path_extension_is_refused(self):
        def mutate(rows, comment):
            for item, _ in rows:
                if item.filename.endswith("script.sh"):
                    payload = (b"\x01" + struct.pack("<I", zlib.crc32(item.filename.encode()))
                               + item.filename.encode())
                    item.extra += struct.pack("<HH", 0x7075, len(payload)) + payload
            return rows, comment
        self.rewrite(mutate)
        self.check(65, "archive extra fields differ from the Git timestamp format")

    def test_local_extra_fields_are_checked_independently(self):
        with zipfile.ZipFile(self.archive) as source:
            item = source.getinfo(PREFIX + "script.sh")
            offset = item.header_offset
        data = bytearray(self.archive.read_bytes())
        name_size, extra_size = struct.unpack_from("<HH", data, offset + 26)
        self.assertEqual(extra_size, 9)
        extra_offset = offset + 30 + name_size
        data[extra_offset:extra_offset + 2] = b"up"
        self.archive.write_bytes(data)
        self.check(65, "archive extra fields differ from the Git timestamp format")

    def test_nul_member_name_is_refused(self):
        def mutate(rows, comment):
            for item, _ in rows:
                if item.filename.endswith("script.sh"):
                    item.filename += "\x00alias"
            return rows, comment
        self.rewrite(mutate)
        self.check(65, "ambiguous archive member name")


if __name__ == "__main__":
    unittest.main()
