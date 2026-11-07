# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui tests/fixture-safety-integration.py.

Exercise fixture ownership, anchored cleanup, and isolated relative-XDG probes.
Every filesystem target is synthetic; no test cleans a real checkout path.
"""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE_ROOT = Path(__file__).resolve().parents[1]
ADMIT_ROOT = """
source "${SOURCE_ROOT}/tests/lib/mock-common.sh"
create_mock_test_root
readonly TEST_ROOT TEST_ROOT_FD TEST_ROOT_IDENTITY
readonly TEST_OWNER_BASHPID=${BASHPID}
printf '%s' "${TEST_ROOT}" >"${OBSERVED_ROOT}"
trap 'cleanup_test_root files-only' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
"""


class FixtureSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fixture-safety-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.checkout = self.base / "fake-checkout"
        self.home = self.base / "home"
        self.output = self.base / "output"
        self.tmp = self.base / "tmp"
        for directory in (self.checkout, self.home, self.output, self.tmp):
            directory.mkdir()
        self.observed = self.base / "observed-root"
        self.foreign = self.base / "foreign"
        self.foreign.mkdir()
        self.sentinel = self.foreign / "sentinel"
        self.sentinel.write_bytes(b"unrelated data\x00\xff\n")
        self.sentinel_identity = self.sentinel.stat()
        self.environment = os.environ.copy()
        self.environment.update(
            SOURCE_ROOT=str(SOURCE_ROOT), PROJECT_DIR=str(self.checkout),
            HOME=str(self.home), OUTPUT_DIR=str(self.output), TMPDIR=str(self.tmp),
            OBSERVED_ROOT=str(self.observed), FOREIGN=str(self.foreign),
            READY=str(self.base / "ready"),
        )

    def shell(self, body, *, cwd=None, env=None):
        environment = self.environment.copy()
        environment.update(env or {})
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + body],
            cwd=cwd or self.checkout, env=environment, text=True,
            capture_output=True, timeout=15, check=False,
        )

    def root(self):
        return Path(self.observed.read_text())

    def assert_foreign_preserved(self):
        self.assertEqual(self.sentinel.read_bytes(), b"unrelated data\x00\xff\n")
        current = self.sentinel.stat()
        self.assertEqual(
            (current.st_dev, current.st_ino),
            (self.sentinel_identity.st_dev, self.sentinel_identity.st_ino),
        )

    def assert_refused(self, result, status=70):
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        self.assertIn("test-root cleanup refused", result.stderr)
        self.assert_foreign_preserved()

    def test_owned_root_removes_nested_files_fifo_and_internal_symlink(self):
        result = self.shell(ADMIT_ROOT + """
mkdir -p "${TEST_ROOT}/nested/deeper"
printf fixture >"${TEST_ROOT}/nested/deeper/data"
mkfifo "${TEST_ROOT}/pipe"
ln -s "${FOREIGN}" "${TEST_ROOT}/external-link"
chmod 777 "${TEST_ROOT}/nested"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.root().exists())
        self.assert_foreign_preserved()

    def test_replaced_root_is_preserved(self):
        result = self.shell(ADMIT_ROOT + """
printf owned >"${TEST_ROOT}/owned"
mv "${TEST_ROOT}" "${TEST_ROOT}.original"
mkdir "${TEST_ROOT}"
printf third-party >"${TEST_ROOT}/sentinel"
""")
        self.assert_refused(result)
        self.assertEqual((self.root() / "sentinel").read_text(), "third-party")
        self.assertEqual(Path(str(self.root()) + ".original", "owned").read_text(), "owned")

    def test_root_symlink_is_preserved_without_following_target(self):
        result = self.shell(ADMIT_ROOT + """
mv "${TEST_ROOT}" "${TEST_ROOT}.original"
ln -s "${FOREIGN}" "${TEST_ROOT}"
""")
        self.assert_refused(result)
        self.assertTrue(self.root().is_symlink())
        self.assertTrue(Path(str(self.root()) + ".original").is_dir())

    def test_changed_root_mode_is_refused(self):
        result = self.shell(ADMIT_ROOT + 'chmod 755 "${TEST_ROOT}"\n')
        self.assert_refused(result)
        self.assertTrue(self.root().is_dir())

    def test_closed_root_descriptor_is_refused(self):
        result = self.shell(ADMIT_ROOT + 'exec {TEST_ROOT_FD}<&-\n')
        self.assert_refused(result)
        self.assertTrue(self.root().is_dir())

    def test_non_owner_subshell_preserves_owner_root(self):
        result = self.shell(ADMIT_ROOT + """
(
    trap 'cleanup_test_root files-only' EXIT
    :
)
[[ -d ${TEST_ROOT} ]]
printf 'owner root survives subshell\n'
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("owner root survives subshell", result.stdout)
        self.assertFalse(self.root().exists())
        self.assert_foreign_preserved()

    def test_initial_failure_survives_cleanup_refusal(self):
        result = self.shell(ADMIT_ROOT + """
mv "${TEST_ROOT}" "${TEST_ROOT}.original"
ln -s "${FOREIGN}" "${TEST_ROOT}"
exit 7
""")
        self.assert_refused(result, 7)

    def test_unconfirmed_process_cleanup_preserves_owned_files(self):
        # Process observation has its own integration suite. Here its failure
        # result must prevent filesystem cleanup, regardless of root identity.
        result = self.shell(ADMIT_ROOT + """
cleanup_test_processes() { return 1; }
trap cleanup_test_root EXIT
printf owned >"${TEST_ROOT}/owned"
""")
        self.assertEqual(result.returncode, 70, result.stdout + result.stderr)
        self.assertIn("test-process shutdown unconfirmed", result.stderr)
        self.assertEqual((self.root() / "owned").read_text(), "owned")
        self.assert_foreign_preserved()

    def injected_cleanup(self, mode):
        # Intercept only a stdlib boundary in the actual heredoc received over
        # stdin. Do not duplicate the cleanup algorithm or alter repository code.
        binary_directory = self.base / "injection-bin"
        binary_directory.mkdir()
        injector = self.base / "inject-cleanup.py"
        injector.write_text("""import errno
import os
from pathlib import Path
import shutil
import sys
from unittest import mock

source = sys.stdin.read()
sys.argv = ["cleanup"] + sys.argv[4:]
mode = os.environ["INJECTION_MODE"]
if mode == "replace-after-validation":
    original = os.fchdir
    def replacement(descriptor):
        path = sys.argv[1]
        os.rename(path, path + ".original")
        os.mkdir(path)
        Path(path, "third-party").write_text("preserve replacement")
        Path(path, "nested").mkdir()
        Path(path, "nested", "third-party").write_text("preserve nested replacement")
        original(descriptor)
    boundary = mock.patch("os.fchdir", side_effect=replacement)
elif mode == "observation-error":
    boundary = mock.patch("os.stat", side_effect=OSError(errno.EIO, "synthetic I/O failure"))
elif mode == "no-fd-safe-rmtree":
    boundary = mock.patch.object(shutil.rmtree, "avoids_symlink_attacks", False)
else:
    raise RuntimeError("unexpected injection mode")
with boundary:
    exec(compile(source, "actual-root-cleanup", "exec"), {"__name__": "__main__"})
""")
        wrapper = binary_directory / "python3"
        wrapper.write_text("""#!/usr/bin/env bash
exec "${REAL_PYTHON}" -I -B "${INJECTOR}" "$@"
""")
        wrapper.chmod(0o700)
        return self.shell(ADMIT_ROOT + """
printf owned >"${TEST_ROOT}/owned"
mkdir "${TEST_ROOT}/nested"
printf owned >"${TEST_ROOT}/nested/owned"
export PATH="${INJECTION_BIN}:${PATH}"
""", env={"REAL_PYTHON": sys.executable, "INJECTOR": str(injector),
                  "INJECTION_MODE": mode, "INJECTION_BIN": str(binary_directory)})

    def test_replacement_after_validation_never_redirects_traversal(self):
        result = self.injected_cleanup("replace-after-validation")
        self.assert_refused(result)
        self.assertEqual((self.root() / "third-party").read_text(), "preserve replacement")
        self.assertTrue((self.root() / "nested/third-party").is_file(), "replacement directory contents were removed")
        self.assertEqual((self.root() / "nested/third-party").read_text(), "preserve nested replacement")
        original = Path(str(self.root()) + ".original")
        self.assertTrue(original.is_dir())
        self.assertEqual(list(original.iterdir()), [])

    def test_root_observation_error_preserves_owned_contents(self):
        result = self.injected_cleanup("observation-error")
        self.assert_refused(result)
        self.assertEqual((self.root() / "owned").read_text(), "owned")

    def test_missing_fd_safe_recursion_capability_refuses_cleanup(self):
        result = self.injected_cleanup("no-fd-safe-rmtree")
        self.assert_refused(result)
        self.assertEqual((self.root() / "owned").read_text(), "owned")

    def test_signals_preserve_status_and_clean_only_owned_root(self):
        for received, expected in ((signal.SIGHUP, 129), (signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=received):
                ready = Path(self.environment["READY"])
                ready.unlink(missing_ok=True)
                process = subprocess.Popen(
                    ["bash", "-c", "set -euo pipefail\n" + ADMIT_ROOT + """
ln -s "${FOREIGN}" "${TEST_ROOT}/external-link"
printf ready >"${READY}"
read -r ignored
"""], cwd=self.checkout, env=self.environment,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True,
                )
                try:
                    deadline = time.monotonic() + 10
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), "owner shell did not reach signal rendezvous")
                    process.send_signal(received)
                    process.wait(timeout=10)
                    stdout, stderr = process.communicate(timeout=2)
                    self.assertEqual(process.returncode, expected, stdout + stderr)
                    self.assertFalse(self.root().exists())
                    self.assert_foreign_preserved()
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=2)

    def relative_probe(self, mode="valid", *, cwd=None, extra=""):
        gui = self.base / "synthetic-gui"
        gui.write_text("""#!/usr/bin/env bash
set -euo pipefail
case ${PROBE_MODE} in
    directory) mkdir -- "${XDG_CONFIG_HOME}" ;;
    dangling-link) ln -s missing-target "${XDG_STATE_HOME}" ;;
esac
mkdir -p -- "${HOME}/.config/yt-dlp-aria2-downloader"
printf 'output_dir=%s\\n' "${OUTPUT_DIR}" >"${HOME}/.config/yt-dlp-aria2-downloader/gui.conf"
printf '%s' "$PWD" >"${PROBE_CWD}"
""")
        gui.chmod(0o700)
        return self.shell(ADMIT_ROOT + """
source "${SOURCE_ROOT}/tests/lib/assert.sh"
source "${SOURCE_ROOT}/tests/lib/mock-gui.sh"
before=${PWD}
""" + extra + """
test_mock_gui_relative_xdg_fallback
[[ ${PWD} == "${before}" ]]
""", cwd=cwd, env={"GUI_UNDER_TEST": str(gui), "PROBE_MODE": mode,
                      "PROBE_CWD": str(self.base / "probe-cwd")})

    def test_preexisting_checkout_paths_survive_from_two_working_directories(self):
        historical = []
        for name in ("relative-config-home", "relative-state-home"):
            path = self.checkout / name
            path.mkdir()
            sentinel = path / "sentinel"
            sentinel.write_bytes(b"preexisting\x00data")
            historical.append((sentinel, sentinel.stat().st_ino))
        alternate = self.base / "alternate-cwd"
        alternate.mkdir()
        for cwd in (self.checkout, alternate):
            with self.subTest(cwd=cwd.name):
                result = self.relative_probe(cwd=cwd)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for sentinel, inode in historical:
                    self.assertTrue(sentinel.is_file(), "preexisting checkout sentinel was removed")
                    self.assertEqual(sentinel.read_bytes(), b"preexisting\x00data")
                    self.assertEqual(sentinel.stat().st_ino, inode)
                probe_cwd = Path((self.base / "probe-cwd").read_text())
                self.assertEqual(probe_cwd.parent, self.root())
                self.assertFalse(self.root().exists())
                self.assert_foreign_preserved()

    def test_relative_directory_usage_is_rejected(self):
        result = self.relative_probe("directory")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("The GUI used a relative XDG", result.stderr)

    def test_relative_dangling_symlink_usage_is_rejected(self):
        result = self.relative_probe("dangling-link")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("The GUI used a relative XDG", result.stderr)
        self.assert_foreign_preserved()

    def test_failed_probe_chdir_never_launches_gui(self):
        result = self.relative_probe(extra="cd() { return 17; }\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((self.base / "probe-cwd").exists())
        self.assertFalse((self.home / ".config").exists())
        self.assert_foreign_preserved()


if __name__ == "__main__":
    unittest.main(verbosity=2)
