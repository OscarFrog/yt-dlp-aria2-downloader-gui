# SPDX-License-Identifier: MIT
"""Replay the release-docs publisher with inert fixtures and a local GitHub API.

Project: yt-dlp-aria2-downloader-gui
Repository path: tests/release-docs-integration.py

This source-only qualification executes the actual fixed workflow shell and
Python, never a remote service or a workflow dispatch. It is intentionally
non-executable; invoke it with python3.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
PATHS = (
    "CHANGELOG.md", "README.fr.md", "README.md", "download-video.sh",
    "install-fedora.sh", "packaging/rpm/yt-dlp-aria2-downloader-gui.spec", "test-static.sh",
)
MAIN, TARGET, RELEASE, TREE = (letter * 40 for letter in "abcd")
ZERO = "0" * 40
RELEASE_VERSION = "100.0.0"
BRANCH = "automation/release-docs-v" + RELEASE_VERSION
DATE = "2026-09-12"
REASON = "Synchronize published release documentation."


def workflow_step(name):
    """Read the actual literal run block without a YAML parsing dependency."""
    lines = (PROJECT / ".github/workflows/release-docs.yml").read_text().splitlines()
    marker = "      - name: " + name
    start = lines.index(marker) + 1
    while lines[start] != "        run: |":
        start += 1
    result = []
    for line in lines[start + 1:]:
        if line and not line.startswith("          "):
            break
        result.append(line[10:] if line else "")
    if not result:
        raise AssertionError("workflow shell block is empty")
    return "\n".join(result) + "\n"


FAKE_GH = r'''#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["REPLAY_ROOT"])
state_path = root / "api-state.json"
state = json.loads(state_path.read_text())
args = sys.argv[1:]

def save():
    state_path.write_text(json.dumps(state))

def emit(value):
    text = json.dumps(value)
    if "--jq" in args:
        query = args[args.index("--jq") + 1]
        result = subprocess.run(["jq", "-r", query], input=text, text=True, capture_output=True, check=True)
        print(result.stdout, end="")
    else:
        print(text)

if args[:2] == ["release", "verify"]:
    sys.exit(0)
if args[:2] == ["release", "view"]:
    emit({"isImmutable": True})
    sys.exit(0)
path = next(arg for arg in args if arg.startswith("repos/"))
route = path.split("/", 3)[3]
method = args[args.index("--method") + 1] if "--method" in args else "GET"
if method != "GET":
    payload = json.loads(Path(args[args.index("--input") + 1]).read_text())
    state["writes"].append([method, route, payload])
    save()
    if route == "git/blobs":
        data = base64.b64decode(payload["content"], validate=True)
        assert payload["encoding"] == "base64"
        emit({"sha": hashlib.sha1(data).hexdigest()})
    elif route == "git/trees":
        assert payload["base_tree"] == "d" * 40
        assert len(payload["tree"]) == 7
        emit({"sha": "1" * 40})
    elif route == "git/commits":
        assert payload["parents"] == [state["base_sha"]]
        emit({"sha": "2" * 40})
    else:
        assert route in ("git/refs", "git/refs/heads/" + state["branch"])
        if method == "PATCH":
            assert payload == {"sha": "2" * 40, "force": False}
        else:
            assert payload == {"ref": "refs/heads/" + state["branch"], "sha": "2" * 40}
        if state["scenario"] == "ref-race":
            sys.exit(1)
        state["target_sha"] = "2" * 40
        save()
        emit({"object": {"sha": "3" * 40 if state["scenario"] == "ambiguous" else "2" * 40}})
elif route == "git/ref/heads/main":
    state["main_reads"] += 1
    save()
    sha = "e" * 40 if state["scenario"] == "main-race" and state["main_reads"] >= 3 else "a" * 40
    emit({"object": {"sha": sha}})
elif route == "git/matching-refs/heads/" + state["branch"]:
    refs = [] if state["target_sha"] == "0" * 40 else [{"ref": "refs/heads/" + state["branch"], "object": {"sha": state["target_sha"]}}]
    emit(refs)
elif route == "git/ref/heads/" + state["branch"]:
    emit({"object": {"sha": state["target_sha"]}})
elif route == "git/matching-refs/tags/v":
    tags = [{"ref": "refs/tags/v100.0.0", "object": {"sha": "c" * 40}},
            {"ref": "refs/tags/v102.4.5", "object": {"sha": "f" * 40}}]
    emit([tags] if "--slurp" in args else tags)
elif route == "commits/v100.0.0":
    emit({"sha": "c" * 40})
elif route.startswith("compare/"):
    emit({"merge_base_commit": {"sha": route[8:].split("...")[0]}})
elif route.startswith("contents/"):
    relative, revision = route[9:].split("?ref=")
    assert revision in ("a" * 40, state["base_sha"])
    sys.stdout.buffer.write((root / "base" / relative).read_bytes())
elif route == "git/commits/" + state["base_sha"]:
    emit(json.loads((root / "commit.json").read_text()))
elif route == "git/trees/" + "d" * 40 + "?recursive=true":
    emit(json.loads((root / "tree.json").read_text()))
else:
    raise AssertionError("unexpected simulated GitHub API route")
'''


@unittest.skipUnless(shutil.which("git") and shutil.which("jq"), "Git and jq are required for workflow replay")
class ReleaseDocsReplay(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release-docs-replay-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base = self.root / "base"
        self.handoff = self.root / "runtime/release-docs-verified"
        for relative in PATHS:
            destination = self.base / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / relative, destination)
        self.command("prepare-source-version.py", "--root", self.base, "--floor-version", "100.0.0", "--date", DATE, "--reason", REASON)
        # The executable static fixture exceeds typical single-argument limits.
        with (self.base / "test-static.sh").open("a") as stream:
            stream.write("\n# " + "fixture" * 40000 + "\n")
        shutil.copytree(self.base, self.handoff)
        self.command("update-published-version.py", RELEASE_VERSION, "--root", self.handoff)
        self.command("prepare-source-version.py", "--root", self.handoff, "--floor-version", "102.4.5", "--date", DATE, "--reason", REASON)
        (self.root / "bin").mkdir()
        gh = self.root / "bin/gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o700)
        self.script = self.root / "publisher.sh"
        self.script.write_text(workflow_step("Revalidate release and publish allowlisted branch"))

    def command(self, script, *arguments):
        return subprocess.run(
            ["python3", "-B", str(PROJECT / "scripts" / script), *map(str, arguments)],
            capture_output=True, text=True, timeout=15, check=True,
        )

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *map(str, arguments)],
                              cwd=cwd or self.base,
                              env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1"),
                              capture_output=True, text=True, timeout=15, check=True)

    def initialize_git_source(self):
        (self.base / "scripts").mkdir()
        for name in ("check-push-version.py", "prepare-source-version.py", "update-published-version.py"):
            shutil.copy2(PROJECT / "scripts" / name, self.base / "scripts" / name)
        remote = self.root / "remote.git"
        self.git("init", "--bare", remote, cwd=self.root)
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", "Fixture")
        self.git("tag", "--no-sign", "v" + RELEASE_VERSION)
        self.git("remote", "add", "origin", remote)
        self.git("push", "origin", "main", "refs/tags/v" + RELEASE_VERSION)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def run_preparation(self, sha):
        script = self.root / "prepare.sh"
        script.write_text(workflow_step("Prepare allowlisted documentation patch"))
        environment = dict(os.environ, RELEASE_TAG="v" + RELEASE_VERSION, RELEASE_SHA=sha,
                           RUNNER_TEMP=str(self.root / "prepare-runtime"),
                           GITHUB_OUTPUT=str(self.root / "prepare-output"),
                           GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["bash", str(script)], cwd=self.base, env=environment,
                              capture_output=True, text=True, timeout=20)

    def manifest(self, root, output, paths):
        (root / output).write_text("".join(
            f"{hashlib.sha256((root / path).read_bytes()).hexdigest()}  {path}\n" for path in paths
        ))

    def prepare(self, followup=False, scenario="normal"):
        target = TARGET if followup else ZERO
        base = TARGET if followup else MAIN
        refs = {"refs/heads/main": MAIN, "refs/tags/v100.0.0": RELEASE, "refs/tags/v102.4.5": "f" * 40}
        if followup:
            refs["refs/heads/" + BRANCH] = target
        catalog = b"".join(sorted(f"{oid}\t{ref}\n".encode() for ref, oid in refs.items()))
        self.context = {
            "schema_version": 1, "remote": "origin", "branch": BRANCH, "main_sha": MAIN,
            "target_sha": target, "base_sha": base, "floor_version": "102.4.5", "next_version": "102.4.6",
            "refs_sha256": hashlib.sha256(catalog).hexdigest(), "date": DATE,
            "release_tag": "v" + RELEASE_VERSION, "release_sha": RELEASE, "release_version": RELEASE_VERSION,
        }
        (self.handoff / "release-docs-metadata.json").write_text(json.dumps(self.context) + "\n")
        self.manifest(self.base, "base.sha256", PATHS)
        shutil.copyfile(self.base / "base.sha256", self.handoff / "release-docs-base-tree.sha256")
        self.rehash()
        (self.root / "commit.json").write_text(json.dumps({
            "sha": base, "tree": {"sha": TREE}, "committer": {"date": DATE + "T08:09:10Z"},
        }))
        (self.root / "tree.json").write_text(json.dumps({
            "sha": TREE, "truncated": False, "tree": [{
                "path": path, "type": "blob", "mode": "100755" if path in
                ("download-video.sh", "install-fedora.sh", "test-static.sh") else "100644",
            } for path in PATHS],
        }))
        (self.root / "api-state.json").write_text(json.dumps({
            "branch": BRANCH, "base_sha": base, "target_sha": target, "scenario": scenario,
            "main_reads": 0, "writes": [],
        }))

    def rehash(self):
        self.manifest(self.handoff, "release-docs-tested-tree.sha256", PATHS)
        self.manifest(self.handoff, "release-docs-handoff.sha256", (*PATHS,
            "release-docs-base-tree.sha256", "release-docs-tested-tree.sha256", "release-docs-metadata.json"))

    def run_publisher(self):
        environment = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                           REPLAY_ROOT=str(self.root), RUNNER_TEMP=str(self.root / "runtime"),
                           GITHUB_REPOSITORY="fixture/repository", GITHUB_STEP_SUMMARY=str(self.root / "summary"),
                           RELEASE_VERSION=RELEASE_VERSION, RELEASE_TAG="v" + RELEASE_VERSION,
                           RELEASE_SHA=RELEASE, VERSION_CONTEXT=json.dumps(self.context))
        result = subprocess.run(["bash", str(self.script)], env=environment, cwd=self.root,
                                capture_output=True, text=True, timeout=30)
        state = json.loads((self.root / "api-state.json").read_text())
        return result, state

    def test_creation_preserves_verified_large_bytes_and_modes(self):
        self.prepare()
        result, state = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["writes"][-1][0:2], ["POST", "git/refs"])
        blobs = [entry for entry in state["writes"] if entry[1] == "git/blobs"]
        self.assertEqual(len(blobs), 7)
        self.assertGreater(max(len(entry[2]["content"]) for entry in blobs), 262144)
        entries = next(entry[2]["tree"] for entry in state["writes"] if entry[1] == "git/trees")
        self.assertEqual({entry["path"] for entry in entries if entry["mode"] == "100755"},
                         {"download-video.sh", "install-fedora.sh", "test-static.sh"})

    def test_followup_is_fast_forward_with_fresh_version(self):
        self.prepare(followup=True)
        result, state = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["writes"][-1], ["PATCH", "git/refs/heads/" + BRANCH,
                                               {"sha": "2" * 40, "force": False}])

    def test_changed_main_refuses_source_publication(self):
        self.prepare(scenario="main-race")
        result, state = self.run_publisher()
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(any(entry[1].startswith("git/refs") for entry in state["writes"]))

    def test_ref_race_and_ambiguous_response_are_not_success(self):
        for scenario in ("ref-race", "ambiguous"):
            with self.subTest(scenario=scenario):
                self.prepare(followup=True, scenario=scenario)
                result, _state = self.run_publisher()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Prepared exact", result.stdout)

    def test_rehashed_candidate_code_change_is_rejected_before_any_write(self):
        self.prepare()
        with (self.handoff / "download-video.sh").open("a") as stream:
            stream.write("\nprintf 'unreviewed candidate code'\n")
        self.rehash()
        result, state = self.run_publisher()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(state["writes"], [])

    def test_substituted_nested_directory_is_rejected(self):
        self.prepare()
        original = self.handoff / "packaging"
        saved = self.root / "foreign-packaging"
        original.rename(saved)
        original.symlink_to(saved, target_is_directory=True)
        result, state = self.run_publisher()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(state["writes"], [])
        self.assertTrue((saved / "rpm/yt-dlp-aria2-downloader-gui.spec").is_file())

    def test_source_date_and_missing_bump_are_rejected(self):
        for mutation in ("date", "version"):
            with self.subTest(mutation=mutation):
                self.prepare()
                if mutation == "date":
                    self.context["date"] = "2026-09-11"
                else:
                    self.context["next_version"] = "102.4.5"
                (self.handoff / "release-docs-metadata.json").write_text(json.dumps(self.context))
                self.rehash()
                result, state = self.run_publisher()
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertEqual(state["writes"], [])

    def test_preparation_noop_preserves_source_version_and_creates_no_handoff(self):
        self.command("update-published-version.py", RELEASE_VERSION, "--root", self.base)
        sha = self.initialize_git_source()
        before = (self.base / "download-video.sh").read_bytes()
        result = self.run_preparation(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "download-video.sh").read_bytes(), before)
        self.assertEqual(self.git("diff", "--name-only").stdout, "")
        self.assertIn("update=false\n", (self.root / "prepare-output").read_text())
        self.assertFalse((self.root / "prepare-runtime/release-docs-candidate").exists())

    def test_preparation_uses_target_descendant_and_bumps_before_handoff(self):
        # This fixture qualifies preparation and object binding. Its static
        # command is deliberately inert; it does not claim full-tree validation.
        static = self.base / "test-static.sh"
        static.write_text(static.read_text().replace("#!/usr/bin/env bash\n", "#!/usr/bin/env bash\nexit 0\n", 1))
        release_sha = self.initialize_git_source()
        self.git("checkout", "-b", BRANCH)
        self.command("prepare-source-version.py", "--root", self.base, "--floor-version", "103.0.0", "--date", DATE, "--reason", REASON)
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-m", "Existing automation source")
        target_sha = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("push", "origin", BRANCH)
        self.git("checkout", "main")
        result = self.run_preparation(release_sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        candidate = self.root / "prepare-runtime/release-docs-candidate"
        context = json.loads((candidate / "release-docs-metadata.json").read_text())
        self.assertEqual(context["base_sha"], target_sha)
        self.assertEqual(context["target_sha"], target_sha)
        self.assertEqual(context["next_version"], "103.0.2")
        self.assertEqual(set(self.git("diff", "--name-only").stdout.splitlines()), set(PATHS))
        declarations = re.findall(r"^readonly VERSION=[\"']([0-9.]+)[\"']$",
                                  (self.base / "download-video.sh").read_text(), re.M)
        self.assertEqual(declarations, ["103.0.2"])
        self.assertIn("update=true\n", (self.root / "prepare-output").read_text())

    def test_published_update_accepts_older_release_but_refuses_future_or_downgrade(self):
        self.command("update-published-version.py", RELEASE_VERSION, "--root", self.base)
        before = {path: (self.base / path).read_bytes() for path in PATHS}
        for rejected in ("100.0.2", "99.9.9"):
            with self.subTest(version=rejected):
                result = subprocess.run([
                    "python3", "-B", str(PROJECT / "scripts/update-published-version.py"),
                    rejected, "--root", str(self.base),
                ], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertEqual({path: (self.base / path).read_bytes() for path in PATHS}, before)


if __name__ == "__main__":
    unittest.main()
