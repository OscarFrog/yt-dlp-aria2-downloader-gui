# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/shfmt-version-handoff-integration.py.

Replay the actual shfmt workflow's version/handoff/publication shell on local Git
fixtures. Network, upstream assets and Docker are controlled stubs: these tests
validate data boundaries and leases, not candidate execution or real GitHub CI.
"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/shfmt-update.yml"
VERSION_PATHS = (
    "download-video.sh", "install-fedora.sh", "test-static.sh", "README.md", "README.fr.md",
    "CHANGELOG.md", "packaging/rpm/yt-dlp-aria2-downloader-gui.spec",
)
SHELL_PATHS = VERSION_PATHS[:3]
PIN_PATH = "scripts/dev-tools/shfmt-pin.env"
CURRENT_PIN = next(line.split("=", 1)[1] for line in (ROOT / PIN_PATH).read_text().splitlines()
                   if line.startswith("SHFMT_VERSION="))
PIN_PARTS = CURRENT_PIN.split(".")
UPSTREAM = ".".join((*PIN_PARTS[:2], str(int(PIN_PARTS[2]) + 1)))
PAYLOAD = b"fixture upstream formatter asset; never executed\n"
ASSET_SHA = hashlib.sha256(PAYLOAD).hexdigest()


def step(name):
    """Extract one literal run block; fail if the workflow changes its structure."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    matches = [index for index, line in enumerate(lines) if line == "      - name: " + name]
    if len(matches) != 1:
        raise AssertionError("expected exactly one workflow step: " + name)
    start = matches[0] + 1
    while start < len(lines) and lines[start] != "        run: |":
        if lines[start].startswith("      - "):
            raise AssertionError("step has no literal shell block: " + name)
        start += 1
    result = []
    for line in lines[start + 1:]:
        if line and not line.startswith("          "):
            break
        result.append(line[10:] if line else "")
    if not result:
        raise AssertionError("empty workflow shell block: " + name)
    return "\n".join(result) + "\n"


@unittest.skipUnless(shutil.which("git"), "Git is unavailable; workflow Git handoff qualification skipped")
class ShfmtVersionHandoffTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["bash", "./scripts/dev-tools/ensure-shfmt.sh"], cwd=ROOT,
            text=True, capture_output=True, timeout=90, check=True,
        )
        cls.formatter = result.stdout.strip()
        if not Path(cls.formatter).is_file():
            raise AssertionError("trusted formatter is unavailable")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shfmt-handoff-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base_dir = Path(self.temporary.name)
        self.seed = self.base_dir / "source"
        self.seed.mkdir()
        self.remote = self.base_dir / "remote.git"
        self.runtime = self.base_dir / "runtime"
        self.runtime.mkdir()
        self.bin = self.base_dir / "bin"
        self.bin.mkdir()
        self.home = self.base_dir / "home"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_NO_REPLACE_OBJECTS="1",
                        GIT_TERMINAL_PROMPT="0", GIT_AUTHOR_DATE="2026-09-12T00:00:00Z",
                        GIT_COMMITTER_DATE="2026-09-12T00:00:00Z", GH_TOKEN="fictitious-test-token",
                        GITHUB_RUN_ID="1", GITHUB_RUN_ATTEMPT="1", SHFMT_VERSION=UPSTREAM,
                        RUNNER_TEMP=str(self.runtime), GITHUB_OUTPUT=str(self.runtime / "output"),
                        GITHUB_STEP_SUMMARY=str(self.runtime / "summary"),
                        MOCK_TOOL_LOG=str(self.runtime / "tools.log"), MOCK_UPSTREAM=UPSTREAM,
                        MOCK_ASSET_SHA=ASSET_SHA, MOCK_ASSET_PAYLOAD=PAYLOAD.decode("ascii"))
        for key in tuple(self.env):
            if key.startswith("GIT_CONFIG_KEY_") or key.startswith("GIT_CONFIG_VALUE_"):
                self.env.pop(key)
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"):
            self.env.pop(key, None)
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        for relative in (*VERSION_PATHS, PIN_PATH, "scripts/check-push-version.py",
                         "scripts/prepare-source-version.py", "scripts/update-published-version.py"):
            path = self.seed / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, path)
        inventory = self.seed / "tests/lib/project-files.sh"
        inventory.parent.mkdir(parents=True)
        inventory.write_text("PRODUCTION_SHELL_FILES=(\n" + "\n".join(SHELL_PATHS) +
                             "\n)\nPACKAGING_SHELL_FILES=(\n)\nTEST_SHELL_FILES=(\n)\n"
                             "DEVELOPMENT_SHELL_FILES=(\n)\n", encoding="utf-8")
        resolver = self.seed / "scripts/dev-tools/ensure-shfmt.sh"
        resolver.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$TEST_TRUSTED_SHFMT\"\n",
                            encoding="utf-8")
        self.env["TEST_TRUSTED_SHFMT"] = self.formatter
        self.install_stubs()
        self.git(self.seed, "init", "--initial-branch=main")
        self.git(self.seed, "config", "user.name", "Test")
        self.git(self.seed, "config", "user.email", "test@example.invalid")
        self.git(self.seed, "add", ".")
        self.git(self.seed, "-c", "core.hooksPath=/dev/null", "commit", "-m", "Fixture base")
        self.git(self.base_dir, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.seed, "remote", "add", "origin", str(self.remote))
        self.git(self.seed, "push", "origin", "main")
        self.base_sha = self.git(self.seed, "rev-parse", "HEAD").stdout.strip()
        self.env.update(EXPECTED_BASE_SHA=self.base_sha, GITHUB_SHA=self.base_sha)

    def install_stubs(self):
        code = "#!" + sys.executable + "\n" + textwrap.dedent('''
            import os
            from pathlib import Path
            import sys
            name = Path(sys.argv[0]).name
            args = sys.argv[1:]
            with open(os.environ["MOCK_TOOL_LOG"], "a", encoding="utf-8") as log:
                log.write(name + " " + " ".join(args) + "\\n")
            if name == "gh":
                if args[:2] == ["auth", "setup-git"]:
                    raise SystemExit(0)
                endpoint = args[1]
                if endpoint.endswith("/releases/latest"):
                    print("v" + os.environ["MOCK_UPSTREAM"])
                elif "/git/ref/tags/" in endpoint:
                    print("tag\\t" + "1" * 40)
                elif "/git/tags/" in endpoint:
                    print("v" + os.environ["MOCK_UPSTREAM"] + "\\tcommit\\ttrue\\tvalid")
                elif "/releases/tags/" in endpoint:
                    print("sha256:" + os.environ["MOCK_ASSET_SHA"])
                else:
                    raise SystemExit("unexpected gh endpoint")
            elif name == "curl":
                Path(args[args.index("--output") + 1]).write_text(os.environ["MOCK_ASSET_PAYLOAD"])
            elif name == "docker":
                if args[0] == "run" and os.environ.get("MOCK_DOCKER_FAIL"):
                    raise SystemExit(70)
            else:
                raise SystemExit("unexpected stub")
        ''')
        for name in ("gh", "curl", "docker"):
            path = self.bin / name
            path.write_text(code, encoding="utf-8")
            path.chmod(0o755)

    def git(self, cwd, *args, check=True):
        return subprocess.run(["git", *args], cwd=cwd, env=self.env, text=True,
                              capture_output=True, timeout=20, check=check)

    def clone(self, name):
        path = self.base_dir / name
        self.git(self.base_dir, "clone", str(self.remote), str(path))
        self.git(path, "config", "user.name", "Test")
        self.git(path, "config", "user.email", "test@example.invalid")
        return path

    def run_step(self, name, cwd, success=True):
        env = dict(self.env, GITHUB_WORKSPACE=str(cwd))
        result = subprocess.run(["bash", "-c", step(name)], cwd=cwd, env=env,
                                text=True, capture_output=True, timeout=35)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, "invalid handoff was accepted")
        return result

    def prepare(self):
        self.run_step("Prepare a coherent source version before candidate execution", self.seed)
        outputs = dict(line.split("=", 1) for line in (self.runtime / "output").read_text().splitlines())
        self.env.update(PROJECT_VERSION=outputs["project_version"], VERSION_FLOOR=outputs["version_floor"],
                        VERSION_DATE=outputs["version_date"], EXPECTED_BRANCH_SHA=outputs["previous_branch_sha"],
                        REF_CATALOG_SHA=outputs["ref_catalog_sha"])
        (self.seed / PIN_PATH).write_text(
            "# Managed by .github/workflows/shfmt-update.yml.\n"
            "# Do not change a checksum without changing/reviewing the corresponding asset.\n"
            f"SHFMT_VERSION={UPSTREAM}\nSHFMT_LINUX_AMD64_SHA256={ASSET_SHA}\n"
            f"SHFMT_LINUX_ARM64_SHA256={ASSET_SHA}\n", encoding="utf-8")
        subprocess.run([self.formatter, "-w", "-i", "4", "-ci", "-bn", "--", *SHELL_PATHS],
                       cwd=self.seed, check=True, capture_output=True, timeout=20)

    def candidate_handoff(self):
        self.run_step("Build data-only shfmt handoff", self.seed)
        shutil.copytree(self.runtime / "shfmt-update-handoff", self.runtime / "shfmt-candidate-handoff")

    def verify(self, success=True):
        self.candidate_handoff()
        verifier = self.clone("verifier")
        return self.run_step("Verify approved version bump, formatter semantics and upstream provenance",
                             verifier, success=success)

    def publish_checkout(self, success=True):
        handoff = self.runtime / "shfmt-update-handoff"
        shutil.rmtree(handoff)
        shutil.copytree(self.runtime / "shfmt-verified-handoff", handoff)
        publisher = self.clone("publisher")
        self.run_step("Verify base and apply allowlisted patch", publisher, success=success)
        return publisher

    def test_valid_bump_handoff_and_actual_local_branch_push(self):
        self.prepare()
        self.verify()
        publisher = self.publish_checkout()
        self.run_step("Create or update reviewed shfmt branch", publisher)
        target = self.git(self.seed, "ls-remote", "--heads", "origin", f"refs/heads/automation/shfmt-v{UPSTREAM}")
        self.assertIn(self.git(publisher, "rev-parse", "HEAD").stdout.strip(), target.stdout)
        self.assertEqual(self.git(self.seed, "ls-remote", "--heads", "origin", "refs/heads/main").stdout.split()[0],
                         self.base_sha)

    def test_candidate_runtime_change_is_rejected_before_mock_docker(self):
        self.prepare()
        with (self.seed / "download-video.sh").open("a") as output:
            output.write("\nprintf 'unauthorized runtime change'\n")
        result = self.verify(success=False)
        self.assertIn("canonical shell semantics/content", result.stderr)
        self.assertFalse((self.runtime / "tools.log").exists())

    def test_candidate_readme_extra_change_is_rejected(self):
        self.prepare()
        with (self.seed / "README.md").open("a") as output:
            output.write("\nUnapproved prose.\n")
        self.assertIn("approved version document", self.verify(success=False).stderr)

    def test_candidate_missing_rpm_bump_is_rejected(self):
        self.prepare()
        (self.seed / VERSION_PATHS[-1]).write_text(
            self.git(self.seed, "show", "HEAD:" + VERSION_PATHS[-1]).stdout, encoding="utf-8")
        self.assertIn("approved version document", self.verify(success=False).stderr)

    def test_failed_isolated_validation_produces_no_verified_patch(self):
        self.prepare()
        self.env["MOCK_DOCKER_FAIL"] = "1"
        self.assertEqual(self.verify(success=False).returncode, 70)
        self.assertFalse((self.runtime / "shfmt-verified-handoff/shfmt-update.patch").exists())

    def test_publisher_rejects_missing_manifest_entry(self):
        self.prepare()
        self.verify()
        manifest = self.runtime / "shfmt-verified-handoff/shfmt-tested-tree.sha256"
        manifest.write_text("\n".join(manifest.read_text().splitlines()[1:]) + "\n", encoding="utf-8")
        self.publish_checkout(success=False)

    def test_publisher_rejects_wrong_project_version(self):
        self.prepare()
        self.verify()
        self.env["PROJECT_VERSION"] = "999.0.0"
        self.publish_checkout(success=False)

    def test_changed_remote_catalogue_is_rejected_before_push(self):
        self.prepare()
        self.verify()
        publisher = self.publish_checkout()
        self.git(self.seed, "tag", "v999.0.0")
        self.git(self.seed, "push", "origin", "refs/tags/v999.0.0")
        result = self.run_step("Create or update reviewed shfmt branch", publisher, success=False)
        self.assertEqual(result.returncode, 75)
        self.assertEqual(self.git(self.seed, "ls-remote", "--heads", "origin",
                                 f"refs/heads/automation/shfmt-v{UPSTREAM}").stdout, "")

    def test_branch_created_before_preparation_is_preserved(self):
        branch = f"refs/heads/automation/shfmt-v{UPSTREAM}"
        self.git(self.seed, "push", "origin", f"HEAD:{branch}")
        result = self.run_step("Prepare a coherent source version before candidate execution",
                               self.seed, success=False)
        self.assertIn("stale or invalid", result.stderr)
        self.assertEqual(self.git(self.seed, "diff", "--name-only").stdout, "")
        self.assertEqual(self.git(self.seed, "ls-remote", "--heads", "origin", branch).stdout.split()[0],
                         self.base_sha)

    def test_branch_created_after_last_catalogue_read_is_preserved_by_real_lease(self):
        self.prepare()
        self.verify()
        publisher = self.publish_checkout()
        real_git = shutil.which("git")
        self.env.update(TEST_REAL_GIT=real_git, TEST_BARE_REMOTE=str(self.remote),
                        TEST_RACING_BRANCH=f"refs/heads/automation/shfmt-v{UPSTREAM}")
        wrapper = self.bin / "git"
        wrapper.write_text("#!" + sys.executable + "\n" + textwrap.dedent('''
            import os
            import subprocess
            import sys
            real = os.environ["TEST_REAL_GIT"]
            if sys.argv[1] == "push":
                subprocess.run([real, "--git-dir", os.environ["TEST_BARE_REMOTE"], "update-ref",
                                os.environ["TEST_RACING_BRANCH"], os.environ["EXPECTED_BASE_SHA"]], check=True)
            os.execv(real, [real, *sys.argv[1:]])
        '''), encoding="utf-8")
        wrapper.chmod(0o755)
        result = self.run_step("Create or update reviewed shfmt branch", publisher, success=False)
        self.assertIn("stale info", result.stderr)
        self.assertEqual(self.git(self.seed, "ls-remote", "--heads", "origin",
                                 self.env["TEST_RACING_BRANCH"]).stdout.split()[0], self.base_sha)

    def test_current_upstream_pin_is_noop(self):
        current = next(line.split("=", 1)[1] for line in (self.seed / PIN_PATH).read_text().splitlines()
                       if line.startswith("SHFMT_VERSION="))
        self.env["MOCK_UPSTREAM"] = current
        self.run_step("Detect latest stable shfmt release", self.seed)
        self.assertEqual((self.runtime / "output").read_text(), "update=false\n")
        self.assertEqual(self.git(self.seed, "diff", "--name-only").stdout, "")

    def test_numeric_release_tags_raise_the_version_floor(self):
        self.git(self.seed, "tag", "v999.2.8")
        self.git(self.seed, "push", "origin", "refs/tags/v999.2.8")
        self.prepare()
        self.assertEqual(self.env["VERSION_FLOOR"], "999.2.8")
        self.assertEqual(self.env["PROJECT_VERSION"], "999.2.9")
        self.verify()
        self.publish_checkout()

    def test_existing_same_base_candidate_is_noop_without_another_commit(self):
        self.prepare()
        self.git(self.seed, "add", ".")
        self.git(self.seed, "-c", "core.hooksPath=/dev/null", "commit", "-m", "Existing candidate")
        branch = f"automation/shfmt-v{UPSTREAM}"
        self.git(self.seed, "push", "origin", f"HEAD:refs/heads/{branch}")
        before = self.git(self.seed, "ls-remote", "--heads", "origin", f"refs/heads/{branch}").stdout
        checkout = self.clone("detect")
        (self.runtime / "output").write_text("")
        result = self.run_step("Detect latest stable shfmt release", checkout)
        self.assertIn("review it without another push", result.stdout)
        self.assertEqual((self.runtime / "output").read_text(), "update=false\n")
        self.assertEqual(self.git(self.seed, "ls-remote", "--heads", "origin", f"refs/heads/{branch}").stdout,
                         before)

    def test_existing_divergent_branch_is_preserved(self):
        self.prepare()
        self.git(self.seed, "add", ".")
        self.git(self.seed, "-c", "core.hooksPath=/dev/null", "commit", "-m", "Existing candidate")
        self.git(self.seed, "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Human work")
        branch = f"automation/shfmt-v{UPSTREAM}"
        self.git(self.seed, "push", "origin", f"HEAD:refs/heads/{branch}")
        before = self.git(self.seed, "ls-remote", "--heads", "origin", f"refs/heads/{branch}").stdout
        checkout = self.clone("detect")
        result = self.run_step("Detect latest stable shfmt release", checkout, success=False)
        self.assertIn("preserve and review", result.stderr)
        self.assertEqual(self.git(self.seed, "ls-remote", "--heads", "origin", f"refs/heads/{branch}").stdout,
                         before)


if __name__ == "__main__":
    unittest.main()
