# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/push-version-integration.py.

Exercise the real pre-push hook against isolated, local bare Git repositories.
No GitHub push, user repository mutation or production credential is needed.
"""

import importlib.util
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("push_version", PROJECT / "scripts/check-push-version.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
PREPARE_SPEC = importlib.util.spec_from_file_location(
    "prepare_version", PROJECT / "scripts/prepare-source-version.py"
)
PREPARE = importlib.util.module_from_spec(PREPARE_SPEC)
PREPARE_SPEC.loader.exec_module(PREPARE)


def write_version_sources(root, version):
    """Write small source carriers and the exact maintained publication shapes."""
    (root / "download-video.sh").write_text(
        f'#!/usr/bin/env bash\nreadonly VERSION="{version}"\n', encoding="utf-8"
    )
    (root / "install-fedora.sh").write_text(f"readonly APP_VERSION='{version}'\n")
    (root / "test-static.sh").write_text(
        f"readonly EXPECTED_VERSION='{version}'\n"
        "readonly EXPECTED_PUBLISHED_VERSION='2.3.11'\n"
    )
    (root / "CHANGELOG.md").write_text(f"# Changelog\n\n## {version} - Unreleased\n")
    markers = {
        "README.md": f"The current development version is **{version}**.\n",
        "README.fr.md": f"La version de développement actuelle est la **{version}**.\n",
    }
    for name, marker in markers.items():
        text = marker + f"gh workflow run release.yml --ref v{version} -f tag=v{version}\n"
        for template, count in CHECK.PUBLISHED.README_REFERENCE_TEMPLATES[Path(name)]:
            text += (template.format(version="2.3.11") + "\n") * count
        (root / name).write_text(text, encoding="utf-8")
    spec = root / PREPARE.RPM_PATH
    spec.parent.mkdir(parents=True, exist_ok=True)
    spec.write_text(f"Name: fixture\n%changelog\n* Sat Sep 12 2026 Fixture - {version}-1\n- Previous.\n")


@unittest.skipUnless(shutil.which("git"), "Git is required for the local push-hook qualification")
class PushVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="push-version-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote é.git"
        self.repo = self.root / "checkout with spaces"
        self.repo.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
            GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
            GIT_TERMINAL_PROMPT="0",
        )
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("init", "--initial-branch=main")
        self.git("remote", "add", "origin", str(self.remote))
        (self.repo / "scripts").mkdir()
        (self.repo / ".githooks").mkdir()
        shutil.copy2(PROJECT / "scripts/check-push-version.py", self.repo / "scripts/check-push-version.py")
        shutil.copy2(PROJECT / "scripts/update-published-version.py", self.repo / "scripts/update-published-version.py")
        shutil.copy2(PROJECT / ".githooks/pre-push", self.repo / ".githooks/pre-push")
        self.commit("2.3.12", "baseline")
        self.git("push", "origin", "main")
        self.git("config", "core.hooksPath", ".githooks")
        self.git("switch", "-c", "feature")

    def git(self, *arguments, expected=0, cwd=None):
        result = subprocess.run(
            ["git", *arguments], cwd=cwd or self.repo, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stderr.decode(errors="replace"))
        return result

    def commit(self, version, marker):
        write_version_sources(self.repo, version)
        (self.repo / "change.txt").write_text(marker, encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", marker)
        return self.git("rev-parse", "HEAD").stdout.decode().strip()

    def check(self, *arguments, expected=0, data=None):
        result = subprocess.run(
            [sys.executable, "-B", "scripts/check-push-version.py", *arguments],
            cwd=self.repo, env=self.env, input=data,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25,
        )
        self.assertEqual(result.returncode, expected, result.stderr.decode(errors="replace"))
        return result

    def remote_ref(self, ref="refs/heads/feature"):
        return self.git("ls-remote", "--refs", "origin", ref).stdout

    def test_first_push_without_bump_is_rejected_before_remote_changes(self):
        self.commit("2.3.12", "forgot version")
        result = self.git("push", "origin", "feature", expected=1)
        self.assertIn(b"Prepare 2.3.13", result.stderr)
        self.assertEqual(self.remote_ref(), b"")

    def test_each_followup_push_requires_a_committed_increase(self):
        accepted = self.commit("2.3.13", "first push")
        self.git("push", "origin", "feature")
        self.git("push", "origin", "feature")  # A genuine no-op needs no bump.
        self.commit("2.3.13", "followup without bump")
        self.git("push", "origin", "feature", expected=1)
        self.assertIn(accepted.encode(), self.remote_ref())
        write_version_sources(self.repo, "2.3.14")
        self.check("check")  # Early feedback uses the working tree.
        self.git("push", "origin", "feature", expected=1)  # The hook uses the commit.
        updated = self.commit("2.3.14", "committed version")
        self.git("push", "origin", "feature")
        self.assertIn(updated.encode(), self.remote_ref())
        self.git("push", "origin", "--delete", "feature")  # Cleanup is not a source push.
        self.assertEqual(self.remote_ref(), b"")

    def test_remote_tags_are_read_live_and_compared_numerically(self):
        self.git("tag", "v2.3.9")
        self.git("push", "origin", "v2.3.9")
        self.commit("2.3.13", "numeric ordering")
        self.check("check")
        # Add a tag directly to the disposable bare fixture: local tags stay stale.
        self.git("tag", "v2.3.20", "main", cwd=self.remote)
        result = self.check("check", expected=65)
        self.assertIn(b"Prepare 2.3.21", result.stderr)
        self.git("push", "origin", "feature", expected=1)

    def test_next_version_binds_live_main_target_and_tags_to_one_catalog(self):
        initial = json.loads(self.check("next-version", "--branch", "feature").stdout)
        self.assertEqual(initial["target_sha"], "0" * 40)
        self.assertEqual(initial["next_version"], "2.3.13")
        self.commit("2.3.15", "existing target")
        target = self.git("rev-parse", "HEAD").stdout.strip().decode()
        self.git("push", "origin", "feature")
        self.git("tag", "v2.3.20", "main", cwd=self.remote)
        self.git("tag", "v2.3.9", "main", cwd=self.remote)
        metadata = json.loads(self.check("next-version", "--branch", "feature").stdout)
        catalog = self.git("ls-remote", "--refs", "origin", "refs/heads/main",
                           "refs/heads/feature", "refs/tags/v*").stdout
        self.assertEqual(metadata["schema_version"], 1)
        self.assertEqual(metadata["target_sha"], target)
        self.assertEqual(metadata["floor_version"], "2.3.20")
        self.assertEqual(metadata["next_version"], "2.3.21")
        self.assertEqual(metadata["refs_sha256"], hashlib.sha256(
            b"".join(sorted(catalog.splitlines(keepends=True)))
        ).hexdigest())
        self.assertEqual(metadata["main_sha"], self.git("rev-parse", "main").stdout.strip().decode())

    def test_stale_remote_objects_fail_closed_until_fetched(self):
        other = self.root / "other checkout"
        self.git("clone", str(self.remote), str(other))
        (other / "download-video.sh").write_text('readonly VERSION="2.3.13"\n')
        self.git("add", ".", cwd=other)
        self.git("commit", "--no-gpg-sign", "-m", "remote advance", cwd=other)
        self.git("push", "origin", "main", cwd=other)
        self.commit("2.3.14", "new candidate")
        self.check("check", expected=65)
        self.git("fetch", "origin")
        self.check("check")

    def test_batch_rejection_prevents_even_valid_branch_publication(self):
        self.commit("2.3.13", "valid branch")
        self.git("switch", "-c", "invalid", "main")
        self.commit("2.3.12", "invalid branch")
        self.git("push", "origin", "feature", "invalid", expected=1)
        self.assertEqual(self.remote_ref(), b"")
        self.assertEqual(self.remote_ref("refs/heads/invalid"), b"")

    def test_engine_only_bump_is_rejected_before_remote_lookup_or_push(self):
        self.commit("2.3.12", "coherent baseline")
        (self.repo / "download-video.sh").write_text('readonly VERSION="2.3.13"\n')
        result = self.check("check", "--remote", "not-configured", expected=65)
        self.assertIn(b"test-static.sh development version", result.stderr)
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", "engine-only bump")
        result = self.git("push", "origin", "feature", expected=1)
        self.assertIn(b"test-static.sh development version", result.stderr)
        self.assertEqual(self.remote_ref(), b"")

    def test_committed_incoherence_cannot_be_hidden_by_worktree_repairs(self):
        self.commit("2.3.13", "candidate")
        (self.repo / "install-fedora.sh").write_text("readonly APP_VERSION='2.3.12'\n")
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", "stale bootstrap")
        write_version_sources(self.repo, "2.3.13")
        self.check("check")
        result = self.git("push", "origin", "feature", expected=1)
        self.assertIn(b"install-fedora.sh APP_VERSION", result.stderr)
        self.assertEqual(self.remote_ref(), b"")

    def test_committed_symlink_carrier_is_rejected(self):
        self.commit("2.3.13", "candidate")
        bootstrap = self.repo / "install-fedora.sh"
        bootstrap.unlink()
        bootstrap.symlink_to("readonly APP_VERSION='2.3.13'\n")
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", "symbolic bootstrap")
        result = self.git("push", "origin", "feature", expected=1)
        self.assertIn(b"Committed install-fedora.sh must be a regular file", result.stderr)
        self.assertEqual(self.remote_ref(), b"")

    def test_local_replace_refs_cannot_disguise_the_pushed_commit(self):
        unchanged = self.commit("2.3.12", "unchanged version")
        replacement = self.commit("2.3.13", "replacement version")
        self.git("replace", unchanged, replacement)
        result = self.git("push", "origin", f"{unchanged}:refs/heads/feature", expected=1)
        self.assertIn(b"version 2.3.12 must be newer", result.stderr)
        self.assertEqual(self.remote_ref(), b"")

    def test_version_source_is_data_and_cannot_run_commands(self):
        self.commit("$(touch SHOULD_NOT_EXIST)", "invalid version")
        self.git("push", "origin", "feature", expected=1)
        self.assertFalse((self.repo / "SHOULD_NOT_EXIST").exists())
        self.commit("2.3.13", "valid literal")
        with (self.repo / "download-video.sh").open("a") as output:
            output.write('readonly VERSION="9.9.9"\n')
        self.check("check", expected=65)

    def test_split_push_urls_and_remote_errors_do_not_leak_urls(self):
        self.commit("2.3.13", "candidate")
        sentinel = str(self.root / "DO_NOT_LEAK_REMOTE_SECRET")
        self.git("config", "remote.origin.pushurl", sentinel)
        result = self.check("check", expected=65)
        self.assertNotIn(b"DO_NOT_LEAK", result.stderr)
        self.git("config", "--unset", "remote.origin.pushurl")
        self.git("remote", "set-url", "origin", sentinel)
        result = self.check("check", expected=65)
        self.assertNotIn(b"DO_NOT_LEAK", result.stderr)

    def test_malformed_hook_input_and_tag_only_operations(self):
        self.check("hook", "origin", expected=65, data=b"malformed metadata\n")
        zero = b"0" * 40
        oid = self.git("rev-parse", "HEAD").stdout.strip()
        # No remote query is needed for deletions, tag-only or no-op operations.
        self.check("hook", "missing", data=b"(delete) " + zero + b" refs/heads/old " + oid + b"\n")
        self.check("hook", "missing", data=b"refs/tags/v2.3.12 " + oid + b" refs/tags/v2.3.12 " + zero + b"\n")
        self.check("hook", "missing", data=b"")

    def test_remote_ref_change_during_check_is_rejected(self):
        oid = self.git("rev-parse", "HEAD").stdout.strip().decode()
        previous = os.getcwd()
        try:
            os.chdir(self.repo)
            with patch.object(CHECK, "remote_catalog", return_value=({"refs/heads/feature": "a" * 40}, (2, 3, 12))):
                with self.assertRaisesRegex(CHECK.CheckError, "changed during"):
                    CHECK.check_hook("origin", f"refs/heads/feature {oid} refs/heads/feature {'0' * 40}\n".encode())
        finally:
            os.chdir(previous)


class GitLifecycleTests(unittest.TestCase):
    def test_git_timeout_stops_and_reaps_the_actual_child(self):
        original_popen = subprocess.Popen
        children = []

        def sleeping_git(*_args, **kwargs):
            child = original_popen([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
            children.append(child)
            return child

        with patch.object(CHECK.subprocess, "Popen", side_effect=sleeping_git), patch.object(CHECK, "GIT_TIMEOUT", 0.05):
            with self.assertRaises(subprocess.TimeoutExpired):
                CHECK.git("version")
        self.assertIsNotNone(children[0].poll())
        self.assertTrue(children[0].stdout.closed)
        self.assertTrue(children[0].stderr.closed)


class OfflineCoherenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="version-coherence-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        write_version_sources(self.root, "2.3.13")

    def test_coherent_source_archive_needs_no_git_or_network(self):
        with patch.object(CHECK, "git", side_effect=AssertionError("Git must not run")):
            self.assertEqual(CHECK.worktree_version(self.root), (2, 3, 13))
        environment = os.environ.copy()
        environment["PATH"] = str(self.root / "no-commands")
        result = subprocess.run(
            [sys.executable, "-B", str(PROJECT / "scripts/check-push-version.py"),
             "coherence", "--root", str(self.root)],
            env=environment, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_source_carrier_is_checked(self):
        for name in ("download-video.sh", "install-fedora.sh", "test-static.sh",
                     "README.md", "README.fr.md", "CHANGELOG.md", PREPARE.RPM_PATH):
            with self.subTest(carrier=name):
                write_version_sources(self.root, "2.3.13")
                path = self.root / name
                path.write_text(path.read_text().replace("2.3.13", "2.3.12"))
                with self.assertRaises(CHECK.CheckError):
                    CHECK.worktree_version(self.root)

    def test_published_metadata_stays_distinct_and_coherent(self):
        readme = self.root / "README.fr.md"
        readme.write_text(readme.read_text().replace("2.3.11", "2.3.12"))
        with self.assertRaisesRegex(CHECK.CheckError, "published references"):
            CHECK.worktree_version(self.root)
        write_version_sources(self.root, "2.3.13")
        with readme.open("a") as output:
            output.write("yt-dlp-aria2-downloader-gui-2.3.13.zip\n")
        with self.assertRaisesRegex(CHECK.CheckError, "unpublished"):
            CHECK.worktree_version(self.root)

    def test_conflicting_development_announcements_are_rejected(self):
        announcements = {
            "README.md": "The current development version is **2.3.12**.\n",
            "README.fr.md": "La version de développement actuelle est la **2.3.12**.\n",
        }
        for name, previous in announcements.items():
            with self.subTest(carrier=name):
                write_version_sources(self.root, "2.3.13")
                path = self.root / name
                path.write_text(previous + path.read_text())
                with self.assertRaisesRegex(CHECK.CheckError, "exactly once"):
                    CHECK.worktree_version(self.root)

    def test_current_changelog_entry_must_be_first_and_unique(self):
        path = self.root / "CHANGELOG.md"
        for inserted_version in ("2.3.14", "2.3.13"):
            with self.subTest(heading=inserted_version):
                write_version_sources(self.root, "2.3.13")
                path.write_text(path.read_text().replace(
                    "# Changelog\n", f"# Changelog\n\n## {inserted_version} - Unreleased\n", 1
                ))
                with self.assertRaisesRegex(CHECK.CheckError, "begin with one unique"):
                    CHECK.worktree_version(self.root)

    def test_release_examples_require_both_exact_version_arguments(self):
        path = self.root / "README.md"
        for before, after in (("--ref v2.3.13", "--ref v2.3.12"),
                              ("-f tag=v2.3.13", "-f tag=v2.3.130")):
            with self.subTest(argument=before):
                write_version_sources(self.root, "2.3.13")
                path.write_text(path.read_text().replace(before, after))
                with self.assertRaisesRegex(CHECK.CheckError, "manual release"):
                    CHECK.worktree_version(self.root)

    def test_rpm_changelog_must_begin_with_one_current_entry(self):
        path = self.root / PREPARE.RPM_PATH
        for additional in ("* Sat Sep 12 2026 Fixture - 2.3.14-1\n",
                           "* Sat Sep 12 2026 Fixture - 2.3.13-1\n",
                           "* malformed leading entry\n"):
            with self.subTest(entry=additional):
                write_version_sources(self.root, "2.3.13")
                path.write_text(path.read_text().replace("%changelog\n", "%changelog\n" + additional))
                with self.assertRaisesRegex(CHECK.CheckError, "RPM changelog"):
                    CHECK.worktree_version(self.root)

    def test_duplicate_constants_and_symlink_are_rejected(self):
        static = self.root / "test-static.sh"
        with static.open("a") as output:
            output.write("readonly EXPECTED_VERSION='2.3.13'\n")
        with self.assertRaisesRegex(CHECK.CheckError, "exactly one"):
            CHECK.worktree_version(self.root)
        write_version_sources(self.root, "2.3.13")
        static.rename(self.root / "other-static")
        static.symlink_to("other-static")
        with self.assertRaisesRegex(CHECK.CheckError, "regular file"):
            CHECK.worktree_version(self.root)


class SourceVersionPreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="source-version-é-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        write_version_sources(self.root, "2.3.13")
        (self.root / "download-video.sh").chmod(0o755)

    def snapshot(self):
        return {path: (self.root / path).read_bytes() for path in PREPARE.SOURCE_PATHS}

    def prepare(self, floor="2.3.20", reason="Synchronize published release documentation.", date="2026-09-02"):
        return PREPARE.prepare_source_version(self.root, floor, reason, date)

    def test_offline_preparation_changes_seven_surfaces_preserving_publication_and_modes(self):
        before = self.snapshot()
        environment = os.environ.copy()
        environment["PATH"] = str(self.root / "no-commands")
        result = subprocess.run(
            [sys.executable, "-B", str(PROJECT / "scripts/prepare-source-version.py"),
             "--root", str(self.root), "--floor-version", "2.3.20", "--date", "2026-09-02",
             "--reason", "Synchronize published release documentation."],
            env=environment, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "old_version": "2.3.13", "new_version": "2.3.21", "date": "2026-09-02",
            "reason": "Synchronize published release documentation.",
        })
        self.assertEqual(CHECK.worktree_version(self.root), (2, 3, 21))
        after = self.snapshot()
        self.assertEqual({path for path in before if before[path] != after[path]}, set(PREPARE.SOURCE_PATHS))
        CHECK.PUBLISHED.check_published_version(self.root, "2.3.11")
        self.assertIn(b"* Wed Sep 02 2026 OscarFrog", after[PREPARE.RPM_PATH])
        self.assertTrue(after["CHANGELOG.md"].endswith(before["CHANGELOG.md"].removeprefix(b"# Changelog\n\n")))
        self.assertEqual((self.root / "download-video.sh").stat().st_mode & 0o777, 0o755)
        self.assertFalse(list(self.root.rglob(".*")))

    def test_source_version_is_also_a_floor_and_results_are_deterministic(self):
        originals = PREPARE.read_sources(self.root)
        first = PREPARE.prepare_texts(originals, "2.3.12", "Update shfmt to v3.12.0", "2026-09-12")
        second = PREPARE.prepare_texts(originals, "2.3.12", "Update shfmt to v3.12.0", "2026-09-12")
        self.assertEqual(first, second)
        self.assertEqual(first[1]["new_version"], "2.3.14")

    def test_invalid_reason_date_floor_or_source_causes_no_mutation(self):
        before = self.snapshot()
        for arguments in ({"reason": "bad\nreason"}, {"reason": "%post"},
                          {"date": "2026-02-30"}, {"date": "2026-9-02"},
                          {"floor": "2.3.999999999"}):
            with self.subTest(arguments=arguments), self.assertRaises(PREPARE.CHECK.CheckError):
                self.prepare(**arguments)
            self.assertEqual(self.snapshot(), before)
        (self.root / "README.md").write_text("unexpected source")
        invalid = self.snapshot()
        with self.assertRaises(PREPARE.CHECK.CheckError):
            self.prepare()
        self.assertEqual(self.snapshot(), invalid)

    def test_symlink_carrier_or_parent_is_rejected_without_writing_elsewhere(self):
        source = self.root / "install-fedora.sh"
        other = self.root / "other-file"
        source.rename(other)
        source.symlink_to(other.name)
        with self.assertRaisesRegex(PREPARE.CHECK.CheckError, "regular file"):
            self.prepare()
        self.assertEqual(other.read_text(), "readonly APP_VERSION='2.3.13'\n")
        source.unlink()
        other.rename(source)
        packaging = self.root / "packaging"
        packaging.rename(self.root / "other-packaging")
        packaging.symlink_to("other-packaging", target_is_directory=True)
        with self.assertRaisesRegex(PREPARE.CHECK.CheckError, "real directories"):
            self.prepare()

    def test_staging_disk_full_preserves_all_originals_and_cleans_temporaries(self):
        before = self.snapshot()
        real_stage = PREPARE.CHECK.PUBLISHED.stage_text
        calls = 0

        def stage(path, text):
            nonlocal calls
            calls += 1
            if calls == 5:
                raise OSError(errno.ENOSPC, "synthetic full disk")
            return real_stage(path, text)

        with patch.object(PREPARE.CHECK.PUBLISHED, "stage_text", side_effect=stage):
            with self.assertRaises(OSError):
                self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(list(self.root.rglob(".*")))

    def test_partial_publication_and_interrupt_restore_all_originals(self):
        for failure in (OSError(errno.EIO, "synthetic write failure"), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__):
                before = self.snapshot()
                real_replace = os.replace
                calls = 0

                def replace(source, destination):
                    nonlocal calls
                    calls += 1
                    if calls == 3:
                        raise failure
                    return real_replace(source, destination)

                with patch.object(PREPARE.os, "replace", side_effect=replace):
                    with self.assertRaises(type(failure)):
                        self.prepare()
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(list(self.root.rglob(".*")))

    def test_source_replaced_during_staging_is_preserved(self):
        real_stage = PREPARE.CHECK.PUBLISHED.stage_text
        calls = 0

        def stage(path, text):
            nonlocal calls
            staged = real_stage(path, text)
            calls += 1
            if calls == 14:
                (self.root / "install-fedora.sh").write_text("foreign writer\n")
            return staged

        with patch.object(PREPARE.CHECK.PUBLISHED, "stage_text", side_effect=stage):
            with self.assertRaisesRegex(PREPARE.CHECK.CheckError, "changed while"):
                self.prepare()
        self.assertEqual((self.root / "install-fedora.sh").read_text(), "foreign writer\n")
        self.assertEqual(CHECK.extract_version((self.root / "download-video.sh").read_bytes()), (2, 3, 13))
        self.assertFalse(list(self.root.rglob(".*")))


if __name__ == "__main__":
    unittest.main()
