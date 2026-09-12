# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/shfmt-bootstrap-integration.py.

Qualify the formatter bootstrap with private pinned assets and controlled cold
cache interleavings. No upstream network or user formatter cache is modified.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


class BootstrapInterrupted(KeyboardInterrupt):
    """Escape unittest's ordinary failure capture after fixture cleanup."""


class ShfmtBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.starting_child = False
        self.pending_signal = 0
        self.interrupted = False
        self.previous_handlers = {}
        self.addCleanup(self.restore_signal_handlers)
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            self.previous_handlers[number] = signal.signal(number, self.interrupt)
        self.temporary = tempfile.TemporaryDirectory(prefix="shfmt-bootstrap-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.script = self.base / "ensure-shfmt.sh"
        shutil.copyfile(ROOT / "scripts/dev-tools/ensure-shfmt.sh", self.script)
        self.asset = self.base / "asset"
        self.asset.write_text("#!/usr/bin/env bash\nprintf 'v9.8.7\\n'\n", encoding="utf-8")
        digest = hashlib.sha256(self.asset.read_bytes()).hexdigest()
        (self.base / "shfmt-pin.env").write_text(
            "SHFMT_VERSION=9.8.7\n" +
            f"SHFMT_LINUX_AMD64_SHA256={digest}\nSHFMT_LINUX_ARM64_SHA256={digest}\n",
            encoding="utf-8",
        )
        self.cache = self.base / "cache"
        self.version_dir = self.cache / "v9.8.7"
        self.binary = self.version_dir / "shfmt"
        self.calls = self.base / "downloads"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, SHFMT_TOOL_ROOT=str(self.cache),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        BOOTSTRAP_TEST_ASSET=str(self.asset), BOOTSTRAP_TEST_CALLS=str(self.calls),
                        BOOTSTRAP_TEST_MKDIR=shutil.which("mkdir"),
                        BOOTSTRAP_TEST_FLOCK=shutil.which("flock"))
        stub = "#!" + sys.executable + "\n" + textwrap.dedent('''
            import os
            from pathlib import Path
            import shutil
            import sys
            args = sys.argv[1:]
            if Path(sys.argv[0]).name == "flock":
                if "BOOTSTRAP_TEST_LOCK_READY_FD" in os.environ:
                    os.write(int(os.environ["BOOTSTRAP_TEST_LOCK_READY_FD"]), b"R")
                os.execv(os.environ["BOOTSTRAP_TEST_FLOCK"], ["flock", *args])
            if Path(sys.argv[0]).name == "mkdir":
                if "BOOTSTRAP_TEST_READY_FD" in os.environ:
                    os.write(int(os.environ["BOOTSTRAP_TEST_READY_FD"]), b"R")
                    if os.read(int(os.environ["BOOTSTRAP_TEST_RELEASE_FD"]), 1) != b"G":
                        raise SystemExit(70)
                os.execv(os.environ["BOOTSTRAP_TEST_MKDIR"], ["mkdir", *args])
            with open(os.environ["BOOTSTRAP_TEST_CALLS"], "ab") as output:
                output.write(b"download\\n")
            if "BOOTSTRAP_TEST_DOWNLOAD_READY_FD" in os.environ:
                os.write(int(os.environ["BOOTSTRAP_TEST_DOWNLOAD_READY_FD"]), b"R")
                if os.read(int(os.environ["BOOTSTRAP_TEST_DOWNLOAD_RELEASE_FD"]), 1) != b"G":
                    raise SystemExit(70)
            if os.environ.get("BOOTSTRAP_TEST_FAIL"):
                raise SystemExit(22)
            shutil.copyfile(os.environ["BOOTSTRAP_TEST_ASSET"], args[args.index("--output") + 1])
        ''')
        for name in ("curl", "mkdir", "flock"):
            path = self.bin / name
            path.write_text(stub, encoding="utf-8")
            path.chmod(0o755)

    def restore_signal_handlers(self):
        if not self.interrupted:
            for number, handler in self.previous_handlers.items():
                signal.signal(number, handler)

    def interrupt(self, number, _frame=None):
        # A new session must be registered for cleanup before interruption can
        # escape Popen. The enclosing runner cannot signal these fixture groups.
        if self.starting_child:
            self.pending_signal = self.pending_signal or number
            return
        self.interrupted = True
        for fatal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(fatal, signal.SIG_IGN)
        self.doCleanups()
        raise BootstrapInterrupted(128 + number)

    def start_process(self, arguments, extra=None, pass_fds=()):
        self.starting_child = True
        try:
            child = subprocess.Popen(arguments, env=dict(self.env, **(extra or {})),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, pass_fds=pass_fds,
                                     start_new_session=True)
            self.addCleanup(self.stop, child)
            return child
        finally:
            self.starting_child = False
            if self.pending_signal:
                self.interrupt(self.pending_signal)

    def start(self, extra=None, pass_fds=()):
        return self.start_process(["bash", str(self.script)], extra, pass_fds)

    @staticmethod
    def stop(child):
        # Nested test drivers own further sessions. Give their handlers a
        # bounded chance to clean those up before using a forcible fallback.
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            child.communicate(timeout=2)
            return
        except subprocess.TimeoutExpired:
            # Only an unreaped direct child authorizes this numeric group.
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        child.communicate(timeout=10)

    @staticmethod
    def fixture_identity(pid):
        try:
            metadata = Path(f"/proc/{pid}/stat").read_text()
        except (FileNotFoundError, ProcessLookupError):
            return None
        fields = metadata[metadata.rfind(") ") + 2:].split()
        if fields[0] in ("Z", "X", "x") or fields[3] != str(pid):
            return None
        return fields[19]

    def stop_observed_fixture(self, pid, identity):
        # The negative regression must also clean a broken nested supervisor.
        # Bind its reported session leader to a start time, never PID alone.
        if identity is not None and self.fixture_identity(pid) == identity:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def finish(self, child, status=0):
        stdout, stderr = child.communicate(timeout=10)
        self.assertEqual(child.returncode, status, stdout + stderr)
        if status == 0:
            self.assertEqual(stdout, str(self.binary) + "\n")
            result = subprocess.run([stdout.strip(), "--version"], text=True,
                                    capture_output=True, timeout=10, check=True)
            self.assertEqual(result.stdout, "v9.8.7\n")
        return stdout, stderr

    def download_count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def pipe(self):
        pair = os.pipe()
        for descriptor in pair:
            self.addCleanup(os.close, descriptor)
        return pair

    def test_warm_cache_keeps_verified_inode_without_download(self):
        self.finish(self.start())
        before = self.binary.stat()
        self.finish(self.start())
        self.assertEqual(self.binary.stat().st_ino, before.st_ino)
        self.assertEqual(self.download_count(), 1)

    def test_stale_cold_miss_rechecks_after_other_consumer_publishes(self):
        ready_read, ready_write = self.pipe()
        release_read, release_write = self.pipe()
        paused = self.start({"BOOTSTRAP_TEST_READY_FD": str(ready_write),
                             "BOOTSTRAP_TEST_RELEASE_FD": str(release_read)},
                            (ready_write, release_read))
        self.assertTrue(select.select([ready_read], [], [], 10)[0], "cold miss never reached preparation")
        self.assertEqual(os.read(ready_read, 1), b"R")
        self.finish(self.start())
        before = self.binary.stat()
        os.write(release_write, b"G")
        self.finish(paused)
        self.assertEqual(self.binary.stat().st_ino, before.st_ino)
        self.assertEqual(self.download_count(), 1, "stale miss downloaded the same verified asset twice")

    def test_concurrent_consumers_share_one_download(self):
        children = [self.start() for _ in range(6)]
        for child in children:
            self.finish(child)
        self.assertEqual(self.download_count(), 1)
        self.assertEqual(list(self.version_dir.glob(".shfmt-download.*")), [])

    def test_failed_download_preserves_old_entry_and_cleans_own_temporary(self):
        self.version_dir.mkdir(parents=True)
        self.binary.write_bytes(b"damaged previous cache; not executable\n")
        before = self.binary.stat()
        self.finish(self.start({"BOOTSTRAP_TEST_FAIL": "1"}), 69)
        self.assertEqual(self.binary.stat().st_ino, before.st_ino)
        self.assertEqual(self.binary.read_bytes(), b"damaged previous cache; not executable\n")
        self.assertEqual(list(self.version_dir.glob(".shfmt-download.*")), [])
        self.finish(self.start())
        self.assertEqual(self.download_count(), 2)

    def test_bad_checksum_is_never_executed_or_published(self):
        marker = self.base / "executed"
        self.asset.write_text(f"#!/usr/bin/env bash\ntouch '{marker}'\n", encoding="utf-8")
        self.finish(self.start(), 65)
        self.assertFalse(marker.exists())
        self.assertFalse(self.binary.exists())
        self.assertEqual(list(self.version_dir.glob(".shfmt-download.*")), [])

    def test_interrupted_download_releases_lock_and_cleans_temporary(self):
        ready_read, ready_write = self.pipe()
        release_read, release_write = self.pipe()
        child = self.start({"BOOTSTRAP_TEST_DOWNLOAD_READY_FD": str(ready_write),
                            "BOOTSTRAP_TEST_DOWNLOAD_RELEASE_FD": str(release_read)},
                           (ready_write, release_read))
        self.assertTrue(select.select([ready_read], [], [], 10)[0], "download never started")
        self.assertEqual(os.read(ready_read, 1), b"R")
        child.send_signal(signal.SIGTERM)
        os.write(release_write, b"G")
        self.finish(child, 143)
        self.assertFalse(self.binary.exists())
        self.assertEqual(list(self.version_dir.glob(".shfmt-download.*")), [])
        self.finish(self.start())
        self.assertEqual(self.download_count(), 2)

    def test_waiting_for_external_lock_is_interruptible_before_unlock(self):
        self.version_dir.mkdir(parents=True)
        ready_read, ready_write = self.pipe()
        with (self.version_dir / ".shfmt.lock").open("ab") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            child = self.start({"BOOTSTRAP_TEST_LOCK_READY_FD": str(ready_write)}, (ready_write,))
            self.assertTrue(select.select([ready_read], [], [], 10)[0], "lock waiter never started")
            self.assertEqual(os.read(ready_read, 1), b"R")
            child.send_signal(signal.SIGTERM)
            self.finish(child, 143)
            self.assertEqual(self.download_count(), 0)
        self.finish(self.start())
        self.assertEqual(self.download_count(), 1)

    def test_interrupted_test_runner_cleans_separate_fixture_sessions(self):
        driver = textwrap.dedent('''
            import json, runpy, sys, unittest
            module = runpy.run_path(sys.argv[1])
            class InterruptedCase(module["ShfmtBootstrapTests"]):
                def setUp(self):
                    super().setUp()
                    self.version_dir.mkdir(parents=True)
                    print(json.dumps(str(self.version_dir / ".shfmt.lock")), flush=True)
                    assert sys.stdin.readline() == "locked\\n"
                def start(self, *args, **kwargs):
                    child = super().start(*args, **kwargs)
                    print(json.dumps(child.pid), flush=True)
                    return child
            try:
                result = unittest.TextTestRunner().run(
                    InterruptedCase("test_concurrent_consumers_share_one_download"))
            except module["BootstrapInterrupted"] as interruption:
                raise SystemExit(interruption.args[0])
            raise SystemExit(not result.wasSuccessful())
        ''')
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number):
                child = self.start_process([sys.executable, "-B", "-c", driver, __file__])
                def read_message():
                    # Do not mix TextIO read-ahead with descriptor readiness:
                    # another complete message may already be in its buffer.
                    message = bytearray()
                    while not message.endswith(b"\n"):
                        self.assertTrue(select.select([child.stdout], [], [], 10)[0],
                                        "nested fixture handshake timed out")
                        piece = os.read(child.stdout.fileno(), 1)
                        self.assertTrue(piece, "nested fixture closed its handshake")
                        message.extend(piece)
                    return json.loads(message)
                lock_path = Path(read_message())
                with lock_path.open("ab") as held:
                    fcntl.flock(held, fcntl.LOCK_EX)
                    child.stdin.write("locked\n")
                    child.stdin.flush()
                    fixtures = []
                    for _ in range(6):
                        pid = read_message()
                        self.assertIsInstance(pid, int)
                        self.assertGreater(pid, 1)
                        identity = self.fixture_identity(pid)
                        self.assertIsNotNone(identity, "fixture exited before interruption probe")
                        self.addCleanup(self.stop_observed_fixture, pid, identity)
                        fixtures.append(pid)
                    os.killpg(child.pid, number)
                    stdout, stderr = child.communicate(timeout=10)
                    self.assertEqual(child.returncode, 128 + number, stdout + stderr)
                    for pid in fixtures:
                        self.assertFalse(Path(f"/proc/{pid}").exists(),
                                         "interrupted test leaked a separate fixture session")

    def test_wrong_version_is_rejected(self):
        self.asset.write_text("#!/usr/bin/env bash\nprintf 'v0.0.0\\n'\n", encoding="utf-8")
        digest = hashlib.sha256(self.asset.read_bytes()).hexdigest()
        (self.base / "shfmt-pin.env").write_text(
            "SHFMT_VERSION=9.8.7\n" +
            f"SHFMT_LINUX_AMD64_SHA256={digest}\nSHFMT_LINUX_ARM64_SHA256={digest}\n",
            encoding="utf-8",
        )
        self.finish(self.start(), 65)
        self.assertFalse(self.binary.exists())

    def test_symbolic_binary_and_lock_are_preserved(self):
        self.version_dir.mkdir(parents=True)
        sentinel = self.base / "sentinel"
        sentinel.write_bytes(b"preserve\n")
        for name in ("shfmt", ".shfmt.lock"):
            with self.subTest(name=name):
                candidate = self.version_dir / name
                candidate.symlink_to(sentinel)
                self.finish(self.start(), 65)
                self.assertTrue(candidate.is_symlink())
                self.assertEqual(sentinel.read_bytes(), b"preserve\n")
                self.assertEqual(self.download_count(), 0)
                candidate.unlink()


if __name__ == "__main__":
    try:
        unittest.main()
    except BootstrapInterrupted as interruption:
        raise SystemExit(interruption.args[0])
