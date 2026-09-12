# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/ci-validation-integration.py.

Exercise content-bound CI promotion and reject stale or forged GitHub evidence.
Fixtures replace authenticated API reads; this suite never contacts GitHub.
"""

import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ci_validation", PROJECT / "scripts/ci-validation.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
TARGET, SOURCE, BASE, HEAD, TREE, OTHER = (character * 40 for character in "abcdef")
NOW = datetime(2026, 9, 12, 12, tzinfo=timezone.utc)
RECENT = "2026-09-12T11:00:00Z"


class FixtureAPI:
    def __init__(self):
        self.responses = {}
        self.calls = []
        self.transforms = {}

    def get(self, endpoint):
        self.calls.append(endpoint)
        result = copy.deepcopy(self.responses[endpoint])
        if endpoint in self.transforms:
            result = self.transforms[endpoint](result)
        return result


def fixture():
    api = FixtureAPI()
    pull = {
        "number": 23, "merged": True, "merged_at": RECENT, "merge_commit_sha": TARGET,
        "base": {"ref": "main", "sha": BASE, "repo": {"full_name": CHECK.REPOSITORY}},
        "head": {"sha": HEAD, "ref": "feature", "repo": {"full_name": "contributor/project"}},
    }
    api.responses[f"git/commits/{TARGET}"] = {
        "sha": TARGET, "tree": {"sha": TREE}, "parents": [{"sha": BASE}],
    }
    api.responses[f"git/commits/{SOURCE}"] = {
        "sha": SOURCE, "tree": {"sha": TREE}, "parents": [{"sha": BASE}, {"sha": HEAD}],
    }
    api.responses[f"compare/{TARGET}...main"] = {"status": "ahead", "merge_base_commit": {"sha": TARGET}}
    api.responses[f"commits/{TARGET}/pulls?per_page=100&page=1"] = [pull]
    api.responses["pulls/23"] = pull
    for index, filename in enumerate(CHECK.WORKFLOWS, 1):
        path = f".github/workflows/{filename}"
        api.responses[f"actions/workflows/{filename}"] = {"id": index, "path": path, "state": "active"}
        run = {
            "id": index * 100, "run_attempt": 1, "workflow_id": index, "path": path,
            "repository": {"full_name": CHECK.REPOSITORY}, "head_repository": pull["head"]["repo"],
            "head_sha": HEAD, "head_branch": "feature", "event": "pull_request", "status": "completed", "conclusion": "success",
            "created_at": RECENT, "updated_at": RECENT, "pull_requests": [],
        }
        api.responses[f"actions/workflows/{index}/runs?event=pull_request&head_sha={HEAD}&per_page=100&page=1"] = {
            "workflow_runs": [run],
        }
        api.responses[f"actions/runs/{index * 100}"] = run
        names = CHECK.WORKFLOWS[filename] | {CHECK.IDENTITY_PREFIX + SOURCE}
        if filename == "real-tools.yml":
            names |= {CHECK.SCHEDULED_JOB}
        api.responses[f"actions/runs/{index * 100}/attempts/1/jobs?per_page=100&page=1"] = {
            "jobs": [{"run_id": index * 100, "name": name, "status": "completed", "completed_at": RECENT,
                      "steps": [] if name == CHECK.SCHEDULED_JOB else [
                          {"name": step, "status": "completed",
                           "conclusion": "skipped" if (name, step) in CHECK.ALLOWED_SKIPS else "success"}
                          for step in sorted(CHECK.required_steps(name, filename))],
                      "conclusion": "skipped" if name == CHECK.SCHEDULED_JOB else "success"}
                     for name in sorted(names)],
        }
    return api


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.api = fixture()
        self.verifier = CHECK.Verifier(self.api, NOW)

    def verify(self):
        return self.verifier.verify(TARGET)

    def run_data(self, index=1):
        return self.api.responses[f"actions/runs/{index * 100}"]

    def jobs(self, index=1):
        return self.api.responses[f"actions/runs/{index * 100}/attempts/1/jobs?per_page=100&page=1"]["jobs"]

    def test_squash_changes_commit_but_exact_tree_is_accepted(self):
        result = self.verify()
        self.assertNotEqual(TARGET, SOURCE)
        self.assertEqual(result["tree"], TREE)
        self.assertEqual(len(result["qualifications"]), 5)
        self.assertTrue(all(item["source_commit"] == SOURCE for item in result["qualifications"]))

    def test_pr_association_may_be_empty_after_merge_and_fork_is_accepted(self):
        self.assertEqual(self.verify()["pull_request"], 23)

    def test_source_tree_change_including_workflow_parameters_is_rejected(self):
        self.api.responses[f"git/commits/{SOURCE}"]["tree"]["sha"] = OTHER
        with self.assertRaisesRegex(CHECK.Refusal, "tree differs"):
            self.verify()

    def test_stale_main_base_is_rejected_even_with_same_tree(self):
        self.api.responses[f"git/commits/{SOURCE}"]["parents"][0]["sha"] = OTHER
        with self.assertRaisesRegex(CHECK.Refusal, "different main or PR parents"):
            self.verify()

    def test_old_pr_head_is_rejected(self):
        self.api.responses[f"git/commits/{SOURCE}"]["parents"][1]["sha"] = OTHER
        with self.assertRaises(CHECK.Refusal):
            self.verify()

    def test_non_squash_or_orphan_target_is_rejected(self):
        for parents in ([], [{"sha": BASE}, {"sha": HEAD}]):
            with self.subTest(parents=parents):
                self.api.responses[f"git/commits/{TARGET}"]["parents"] = parents
                with self.assertRaisesRegex(CHECK.Refusal, "squash"):
                    self.verify()

    def test_target_outside_main_is_rejected(self):
        self.api.responses[f"compare/{TARGET}...main"]["status"] = "diverged"
        with self.assertRaisesRegex(CHECK.Refusal, "ancestor"):
            self.verify()

    def test_direct_main_commit_without_merged_pr_is_rejected(self):
        self.api.responses[f"commits/{TARGET}/pulls?per_page=100&page=1"] = []
        with self.assertRaisesRegex(CHECK.Refusal, "Exactly one merged PR"):
            self.verify()

    def test_ambiguous_pr_or_unmerged_pr_is_rejected(self):
        path = f"commits/{TARGET}/pulls?per_page=100&page=1"
        self.api.responses[path] *= 2
        with self.assertRaises(CHECK.Refusal):
            self.verify()
        self.api.responses[path] = self.api.responses[path][:1]
        self.api.responses["pulls/23"]["merged"] = False
        with self.assertRaises(CHECK.Refusal):
            self.verify()

    def test_workflow_identity_and_origin_are_strict(self):
        changes = {
            "workflow_id": 99, "path": ".github/workflows/other.yml", "event": "workflow_dispatch",
            "repository": {"full_name": "attacker/project"}, "head_sha": OTHER,
            "head_repository": {"full_name": "attacker/project"},
            "head_branch": "automation/release-docs-v1.2.3",
        }
        for key, value in changes.items():
            with self.subTest(key=key):
                original = self.run_data()[key]
                self.run_data()[key] = value
                with self.assertRaises(CHECK.Refusal):
                    self.verify()
                self.run_data()[key] = original

    def test_disabled_or_renamed_workflow_is_rejected(self):
        workflow = self.api.responses["actions/workflows/shell.yml"]
        for key, value in (("state", "disabled_manually"), ("path", "other.yml")):
            with self.subTest(key=key):
                original = workflow[key]
                workflow[key] = value
                with self.assertRaises(CHECK.Refusal):
                    self.verify()
                workflow[key] = original

    def test_failed_or_pending_latest_run_never_falls_back_to_success(self):
        path = f"actions/workflows/1/runs?event=pull_request&head_sha={HEAD}&per_page=100&page=1"
        for status, conclusion, exception in (
            ("completed", "failure", CHECK.Refusal), ("in_progress", None, CHECK.Pending),
            ("completed", "cancelled", CHECK.Refusal),
        ):
            with self.subTest(status=status, conclusion=conclusion):
                newer = dict(self.run_data(), id=199, status=status, conclusion=conclusion,
                             created_at="2026-09-12T11:30:00Z")
                self.api.responses[path]["workflow_runs"] = [self.run_data(), newer]
                with self.assertRaises(exception):
                    self.verify()

    def test_required_jobs_cannot_be_skipped_removed_duplicated_or_replaced(self):
        path = "actions/runs/100/attempts/1/jobs?per_page=100&page=1"
        original = copy.deepcopy(self.jobs())
        variants = [original[:-1], original + [original[0]],
                    [dict(job, name="unrelated") if index == 0 else job for index, job in enumerate(original)],
                    [dict(job, conclusion="skipped") if index == 0 else job for index, job in enumerate(original)],
                    [dict(job, run_id=999) if index == 0 else job for index, job in enumerate(original)]]
        for jobs in variants:
            with self.subTest(jobs=jobs):
                self.api.responses[path]["jobs"] = jobs
                with self.assertRaises(CHECK.Refusal):
                    self.verify()

    def test_forged_or_missing_identity_is_rejected(self):
        job = next(job for job in self.jobs() if job["name"].startswith(CHECK.IDENTITY_PREFIX))
        for identity in ("Source identity refs/pull/23/merge", "Source identity " + OTHER, "Other identity"):
            job["name"] = identity
            with self.subTest(identity=identity), self.assertRaises((CHECK.Refusal, KeyError)):
                self.verify()

    def test_successful_job_cannot_hide_missing_failed_or_skipped_qualification_steps(self):
        job = next(job for job in self.jobs() if job["name"] == "Ubuntu")
        original = copy.deepcopy(job["steps"])
        variants = [[], [{"name": "Set up job", "status": "completed", "conclusion": "success"}],
                    original + [original[0]]]
        for status, conclusion in (("completed", "failure"), ("completed", "skipped"),
                                   ("in_progress", None)):
            variants.append([dict(step, status=status, conclusion=conclusion)
                             if index == 0 else step for index, step in enumerate(original)])
        for steps in variants:
            with self.subTest(steps=steps):
                job["steps"] = steps
                with self.assertRaises(CHECK.Refusal):
                    self.verify()

    def test_skip_exceptions_cannot_move_to_another_matrix_job(self):
        self.verify()
        for index, name, step_name in (
            (2, "Fedora 44 RPM (fresh)", "Test previous immutable release -> current RPM upgrade"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Run real FFmpeg progress qualification"),
            (4, "Local media, pinned yt-dlp 2026.6.9", "Run aria2 direct-transfer behavior qualification"),
        ):
            job = next(job for job in self.jobs(index) if job["name"] == name)
            step = next(step for step in job["steps"] if step["name"] == step_name)
            step["conclusion"] = "skipped"
            with self.subTest(job=name, step=step_name), self.assertRaises(CHECK.Refusal):
                self.verify()
            step["conclusion"] = "success"

    def test_historical_exact_content_success_does_not_expire_with_the_calendar(self):
        historical = (NOW - timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for index in range(1, 6):
            self.run_data(index).update(created_at=historical, updated_at=historical)
            for job in self.jobs(index):
                job["completed_at"] = historical
        self.assertEqual(self.verify()["tree"], TREE)

    def test_future_run_or_job_timestamps_are_rejected(self):
        future = (NOW + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.run_data()["updated_at"] = future
        with self.assertRaisesRegex(CHECK.Refusal, "future-dated"):
            self.verify()
        self.run_data()["updated_at"] = RECENT
        self.jobs()[0]["completed_at"] = future
        with self.assertRaisesRegex(CHECK.Refusal, "future-dated"):
            self.verify()

    def test_observation_clock_advances_after_verifier_creation(self):
        observed = "2026-09-12T12:30:00Z"
        with patch.object(CHECK, "datetime", wraps=datetime) as clock:
            clock.now.return_value = NOW
            verifier = CHECK.Verifier(self.api)
            clock.now.return_value = NOW + timedelta(hours=1)
            self.assertEqual(verifier.observed_timestamp(observed), CHECK.timestamp(observed))
            with self.assertRaisesRegex(CHECK.Refusal, "future-dated"):
                CHECK.Verifier(self.api, NOW).observed_timestamp(observed)
    def test_job_timestamps_must_belong_to_the_observed_run(self):
        historical = (NOW - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.jobs()[0]["completed_at"] = historical
        with self.assertRaisesRegex(CHECK.Refusal, "outside its workflow run"):
            self.verify()
        self.jobs()[0]["completed_at"] = RECENT
        self.run_data()["created_at"] = "2026-09-12T11:30:00Z"
        with self.assertRaisesRegex(CHECK.Refusal, "timestamps are inconsistent"):
            self.verify()

    def test_full_original_pr_rerun_after_merge_can_renew_proof(self):
        self.api.responses["pulls/23"]["merged_at"] = "2026-08-01T11:00:00Z"
        for index in range(1, 6):
            self.run_data(index)["run_attempt"] = 2
            old = f"actions/runs/{index * 100}/attempts/1/jobs?per_page=100&page=1"
            new = f"actions/runs/{index * 100}/attempts/2/jobs?per_page=100&page=1"
            self.api.responses[new] = self.api.responses.pop(old)
        self.assertTrue(all(item["run_attempt"] == 2 for item in self.verify()["qualifications"]))

    def test_rerun_started_during_verification_is_rejected(self):
        self.api.transforms["actions/runs/100"] = lambda run: dict(run, run_attempt=2)
        with self.assertRaisesRegex(CHECK.Refusal, "changed during"):
            self.verify()

    def test_new_run_started_during_verification_is_rejected(self):
        path = f"actions/workflows/1/runs?event=pull_request&head_sha={HEAD}&per_page=100&page=1"

        def replace_on_second_read(response):
            if self.api.calls.count(path) > 1:
                response["workflow_runs"][0]["id"] = 199
            return response

        self.api.transforms[path] = replace_on_second_read
        with self.assertRaisesRegex(CHECK.Refusal, "changed during"):
            self.verify()

    def test_missing_run_and_excessive_pagination_fail_closed(self):
        endpoint = f"actions/workflows/1/runs?event=pull_request&head_sha={HEAD}&per_page=100&page=1"
        self.api.responses[endpoint]["workflow_runs"] = []
        with self.assertRaises(CHECK.Pending):
            self.verify()
        for page in range(1, CHECK.MAX_PAGES + 1):
            self.api.responses[f"bounded?per_page=100&page={page}"] = [1] * 100
        with self.assertRaisesRegex(CHECK.Refusal, "pagination limit"):
            self.verifier.pages("bounded")

    def test_shell_gate_binds_exact_virtual_merge(self):
        pull = self.api.responses["pulls/23"]
        self.assertEqual(self.verifier.shell(SOURCE, pull), 100)
        with self.assertRaisesRegex(CHECK.Refusal, "different virtual merge"):
            self.verifier.shell(TARGET, pull)

    def test_shell_gate_checks_event_parent_identity(self):
        pull = copy.deepcopy(self.api.responses["pulls/23"])
        pull["base"]["sha"] = OTHER
        with self.assertRaisesRegex(CHECK.Refusal, "triggering PR"):
            self.verifier.shell(SOURCE, pull)

    def test_required_gate_excludes_its_own_stress_workflow(self):
        result = self.verifier.required(SOURCE, self.api.responses["pulls/23"], {})
        self.assertEqual(set(result), CHECK.WORKFLOWS.keys() - {"stress.yml"})
        self.assertNotIn("actions/workflows/stress.yml", self.api.calls)

    def test_required_gate_waits_without_repolling_successes_and_rechecks_them(self):
        self.run_data(3).update(status="in_progress", conclusion=None)
        verified = {}
        pull = self.api.responses["pulls/23"]
        with self.assertRaises(CHECK.Pending):
            self.verifier.required(SOURCE, pull, verified)
        self.assertEqual(set(verified), {"shell.yml", "packages.yml", "real-tools.yml"})
        self.run_data(3).update(status="completed", conclusion="success")
        self.run_data(1).update(status="completed", conclusion="failure")
        with self.assertRaises(CHECK.Refusal):
            self.verifier.required(SOURCE, pull, verified)
        self.assertEqual(self.api.calls.count("actions/workflows/shell.yml"), 1)

    def test_required_gate_rejects_failed_or_skipped_complementary_job(self):
        for conclusion in ("failure", "skipped"):
            self.jobs(3)[0]["conclusion"] = conclusion
            with self.subTest(conclusion=conclusion), self.assertRaises(CHECK.Refusal):
                self.verifier.required(SOURCE, self.api.responses["pulls/23"], {})

    def test_release_evidence_caller_preserves_proof_refusal(self):
        text = (PROJECT / "scripts/release-evidence-qualification.sh").read_text(encoding="utf-8")
        functions = []
        for name in ("fail_qualification", "collect_content_qualification"):
            start = text.index(name + "() {\n")
            end = text.index("\n}\n", start) + 3
            functions.append(text[start:end])
        script = "\n".join(functions) + """
PROJECT_DIR=/fixture
GH_TOKEN=fixture-token
REQUIRE_EXTENDED_QUALIFICATION=0
result=unpublished
python3() { printf '{"commit":"forged-success"}'; return 17; }
if collect_content_qualification OscarFrog/yt-dlp-aria2-downloader-gui aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa result; then
    exit 99
else
    status=$?
fi
[[ ${status} == 65 && ${result} == unpublished ]]
"""
        result = subprocess.run(["bash", "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"content-bound source qualification was refused", result.stderr)

    def test_event_is_bounded_and_requires_canonical_pr(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "event.json"
            path.write_text(json.dumps({"pull_request": self.api.responses["pulls/23"]}), encoding="utf-8")
            with patch.dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(path)):
                self.assertEqual(CHECK.event_pull()["number"], 23)
                with patch.dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch"):
                    with self.assertRaises(CHECK.Refusal):
                        CHECK.event_pull()
                path.write_bytes(b" " * (CHECK.MAX_BYTES + 1))
                with self.assertRaises(CHECK.Refusal):
                    CHECK.event_pull()

    def test_token_never_enters_arguments_or_error_output(self):
        with patch.dict(os.environ, GH_TOKEN="fixture-secret-token"):
            with patch.object(CHECK.subprocess, "Popen") as popen, patch.object(CHECK, "read_response", return_value=b"{}"):
                process = popen.return_value
                process.returncode = 0
                self.assertEqual(CHECK.GitHub().get("actions/workflows/shell.yml"), {})
                args, kwargs = popen.call_args
                self.assertNotIn("fixture-secret-token", repr(args))
                self.assertIn("GET", args[0])
                self.assertEqual(kwargs["env"]["GH_TOKEN"], "fixture-secret-token")
                self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)

    def test_api_timeout_or_cancellation_reaps_the_metadata_process_group(self):
        for error in (subprocess.TimeoutExpired("gh", 45), CHECK.Interrupted(15)):
            with self.subTest(error=type(error).__name__):
                with patch.dict(os.environ, GH_TOKEN="fixture-token"):
                    with patch.object(CHECK.subprocess, "Popen") as popen:
                        process = popen.return_value
                        process.pid = 4321
                        with patch.object(CHECK.os, "killpg") as kill, patch.object(CHECK, "read_response", side_effect=error):
                            with self.assertRaises(type(error)):
                                CHECK.GitHub().get("actions/workflows/shell.yml")
                            kill.assert_called_once_with(4321, CHECK.signal.SIGKILL)
                            process.wait.assert_called_once()
                            process.stdout.close.assert_called_once()

    def test_api_stream_is_bounded_before_completion_and_reaps_oversized_writer(self):
        real_popen = subprocess.Popen
        children = []

        def local_writer(_arguments, **kwargs):
            code = "import os,time; os.write(1, b'x' * 4096); time.sleep(30)"
            process = real_popen([sys.executable, "-c", code], **kwargs)
            children.append(process)
            return process

        with patch.dict(os.environ, GH_TOKEN="fixture-token"), patch.object(CHECK, "MAX_BYTES", 1024):
            with patch.object(CHECK.subprocess, "Popen", side_effect=local_writer):
                with self.assertRaisesRegex(CHECK.Refusal, "supported size"):
                    CHECK.GitHub().get("actions/workflows/shell.yml")
        self.assertEqual(children[0].returncode, -CHECK.signal.SIGKILL)
        self.assertTrue(children[0].stdout.closed)

    def test_api_stream_accepts_complete_json_without_contacting_github(self):
        real_popen = subprocess.Popen

        def local_writer(_arguments, **kwargs):
            return real_popen([sys.executable, "-c", 'print("{\\\"id\\\": 123}")'], **kwargs)

        with patch.dict(os.environ, GH_TOKEN="fixture-token"):
            with patch.object(CHECK.subprocess, "Popen", side_effect=local_writer):
                self.assertEqual(CHECK.GitHub().get("actions/workflows/shell.yml"), {"id": 123})


class WorkflowContractTests(unittest.TestCase):
    @staticmethod
    def workflow(filename):
        return (PROJECT / ".github/workflows" / filename).read_text(encoding="utf-8")

    @staticmethod
    def jobs(text):
        # Parse only the repository's established two-space job/needs layout;
        # actionlint separately validates full YAML and expression semantics.
        section = text.split("\njobs:\n", 1)[1]
        matches = list(re.finditer(r"(?m)^  ([a-z][a-z0-9-]*):\s*$", section))
        return {match.group(1): section[match.end():matches[index + 1].start()
                                      if index + 1 < len(matches) else len(section)]
                for index, match in enumerate(matches)}

    @staticmethod
    def dependencies(job):
        inline = re.search(r"(?m)^    needs: ([a-z][a-z0-9-]*)$", job)
        if inline:
            return {inline.group(1)}
        block = re.search(r"(?m)^    needs:\n((?:      - [a-z][a-z0-9-]*\n)+)", job)
        if block:
            return set(re.findall(r"- ([a-z][a-z0-9-]*)", block.group(1)))
        sequence = re.search(r"(?m)^    needs: \[([a-z0-9, -]+)\]$", job)
        return {part.strip() for part in sequence.group(1).split(",")} if sequence else set()

    def assert_gate(self, jobs, job, gate, seen=None):
        seen = (seen or set()) | {job}
        dependencies = self.dependencies(jobs[job])
        self.assertTrue(dependencies, f"{job} has no dependency on {gate}")
        for dependency in dependencies:
            if dependency == gate:
                return
            self.assertIn(dependency, jobs)
            self.assertNotIn(dependency, seen, "Cyclic CI dependency")
        for dependency in dependencies:
            self.assert_gate(jobs, dependency, gate, seen)

    def test_qualification_only_on_pr_with_context_bound_identity(self):
        for filename in CHECK.WORKFLOWS:
            with self.subTest(filename=filename):
                text = self.workflow(filename)
                triggers = text.split("permissions:", 1)[0]
                self.assertRegex(triggers, r"(?m)^  pull_request:")
                self.assertNotRegex(triggers, r"(?m)^  push:")
                self.assertIn("name: Source identity ${{ github.sha }}", text)
                self.assertIn("cancel-in-progress: true", text)
                self.assertNotIn("continue-on-error:", text)
                jobs = self.jobs(text)
                self.assertIn("EXPECTED_SHA: ${{ github.sha }}", jobs["identity"])
                self.assertIn('[[ $(git rev-parse HEAD) == "${EXPECTED_SHA}" ]]', jobs["identity"])
                self.assertNotRegex(jobs["identity"], r"(?m)^          ref:")
                self.assertNotRegex(text, r"(?m)^          ref:")
                for job in jobs:
                    if job not in {"identity", "current-stable-local-media"}:
                        self.assert_gate(jobs, job, "identity")
                if filename != "shell.yml":
                    self.assertIn("scripts/ci-validation.py wait-shell --commit", text)

    def test_required_step_inventory_tracks_the_workflow_definitions(self):
        for filename, names in CHECK.WORKFLOWS.items():
            text = self.workflow(filename)
            for name in names | {CHECK.IDENTITY_PREFIX + SOURCE}:
                for step in CHECK.required_steps(name, filename):
                    with self.subTest(workflow=filename, job=name, step=step):
                        self.assertIn("- name: " + step + "\n", text)

    def test_release_reuses_proof_and_preserves_artifact_qualification(self):
        text = self.workflow("release.yml")
        self.assertIn("scripts/ci-validation.py verify --commit", text)
        for redundant in ("tests/run-all.sh", "tests/rpm6-multisig-integration.sh"):
            self.assertNotIn(redundant, text)
        for retained in ("git verify-tag", "test-package-lifecycle.sh", "test-package-upgrade.sh",
                         "gh attestation verify", "gh release verify", "verify-published:"):
            self.assertIn(retained, text)
        jobs = self.jobs(text)
        for job in ("zip", "rpm-build", "deb", "previous-release"):
            self.assertIn(job, set(jobs))
            self.assert_gate(jobs, job, "validate")

    def assert_release_runtime_contract(self, text):
        jobs = self.jobs(text)
        self.assertIn("release-runtime", set(jobs))
        runtime = jobs["release-runtime"]
        self.assertEqual(self.dependencies(runtime), {"validate"})
        self.assertIn("runs-on: ubuntu-24.04", runtime)
        self.assertNotIn(": write", runtime)
        self.assertNotIn("secrets.", runtime)
        self.assertNotIn("continue-on-error:", runtime)
        self.assertIn("ref: ${{ needs.validate.outputs.commit }}", runtime)
        self.assertIn("--require-hashes", runtime)
        self.assertIn("--only-binary=:all:", runtime)
        matrix = re.search(r"(?m)^        yt_dlp_version: \[([^\n]+)\]$", runtime)
        self.assertIsNotNone(matrix)
        self.assertEqual(re.findall(r"[0-9]+\.[0-9]+\.[0-9]+", matrix.group(1)),
                         ["2026.6.9", "2026.8.19"])
        suites = ("tests/real-tools-integration.sh", "tests/aria2-real-behavior-integration.sh",
                  "tests/ffmpeg-real-progress-integration.sh", "tests/hls-remux-duration-integration.sh")
        # Source identity cannot prove unchanged apt dependencies. Preserve the
        # fresh Ubuntu behavior check while forbidding another generic suite.
        for suite in suites:
            self.assertEqual(runtime.count("bash ./" + suite), 1, suite)
            for name, job in jobs.items():
                if name != "release-runtime":
                    self.assertNotIn(suite, job, name)
        for suite in suites[2:]:
            steps = [step for step in re.split(r"(?m)^      - ", runtime) if suite in step]
            self.assertEqual(len(steps), 1, suite)
            self.assertIn("if: matrix.yt_dlp_version == '2026.8.19'", steps[0])
        for suite in suites[:2]:
            step = next(step for step in re.split(r"(?m)^      - ", runtime) if suite in step)
            self.assertNotIn("if:", step)
        aria2 = next(step for step in re.split(r"(?m)^      - ", runtime) if suites[1] in step)
        self.assertIn("ARIA2_BEHAVIOR_BASIC_RUNS: 3", aria2)
        self.assertIn("ARIA2_BEHAVIOR_CANCEL_RESTART_RUNS: 10", aria2)
        for redundant in ("tests/run-all.sh", "tests/repeat-qualification.sh", "tests/rpm6-multisig-integration.sh",
                          "tests/mock-integration.sh"):
            self.assertNotIn(redundant, text)
        self.assertIn("release-runtime", self.dependencies(jobs["verify-source"]))
        self.assertIn("verify-source", self.dependencies(jobs["publish"]))
        # Package work can overlap the independent current-environment probe.
        for build in ("zip", "rpm-build", "deb", "previous-release"):
            pending = list(self.dependencies(jobs[build]))
            visited = set()
            while pending:
                dependency = pending.pop()
                self.assertNotEqual(dependency, "release-runtime", build)
                if dependency not in visited:
                    visited.add(dependency)
                    pending.extend(self.dependencies(jobs[dependency]))

    def test_release_retains_only_the_fresh_environment_runtime_exception(self):
        self.assert_release_runtime_contract(self.workflow("release.yml"))

    def test_runtime_exception_cannot_bypass_publication_or_expand_to_generic_retests(self):
        text = self.workflow("release.yml")
        mutations = (
            ("needs: [validate, zip, rpm-test, deb, release-runtime]", "needs: [validate, zip, rpm-test, deb]"),
            ("needs: [validate, zip, rpm-test, deb, verify-source]", "needs: [validate, zip, rpm-test, deb]"),
            ("bash ./tests/real-tools-integration.sh", "bash ./tests/run-all.sh --full --jobs 4"),
            ("bash ./tests/real-tools-integration.sh", "bash ./tests/repeat-qualification.sh --runs 3 --jobs 3 -- bash ./tests/real-tools-integration.sh"),
            ("bash ./tests/real-tools-integration.sh", "bash ./tests/real-tools-integration.sh\n          bash ./tests/real-tools-integration.sh"),
            ("if: matrix.yt_dlp_version == '2026.8.19'", "if: true"),
            ("ARIA2_BEHAVIOR_CANCEL_RESTART_RUNS: 10", "ARIA2_BEHAVIOR_CANCEL_RESTART_RUNS: 1"),
            ("name: Run aria2 direct-transfer behavior qualification", "name: Run aria2 direct-transfer behavior qualification\n        if: matrix.yt_dlp_version == '2026.8.19'"),
            ("name: Qualify routing with current release dependencies", "name: Qualify routing with current release dependencies\n        if: false"),
            ("--require-hashes", "--no-deps"),
        )
        for old, new in mutations:
            with self.subTest(mutation=old):
                self.assertIn(old, text)
                with self.assertRaises(AssertionError):
                    self.assert_release_runtime_contract(text.replace(old, new, 1))
        jobs = self.jobs(text)
        old = jobs["rpm-build"]
        new = old.replace("needs: validate", "needs: [validate, release-runtime]", 1)
        self.assertNotEqual(old, new)
        with self.assertRaises(AssertionError):
            self.assert_release_runtime_contract(text.replace(old, new, 1))

    def assert_release_identity_contract(self, text):
        jobs = self.jobs(text)
        validate = jobs["validate"]
        self.assertIn("commit: ${{ steps.source.outputs.commit }}", validate)
        self.assertIn("tag_object: ${{ steps.source.outputs.tag_object }}", validate)
        self.assertIn("id: source", validate)
        guard = '[[ ${target_sha} == "${GITHUB_SHA}" ]]'
        self.assertIn(guard, validate)
        self.assertLess(validate.index(guard), validate.index("uses: actions/checkout@"))
        self.assertIn("'commit=%s\\ntag_object=%s\\n'", validate)
        for name, job in jobs.items():
            if "uses: actions/checkout@" not in job:
                continue
            source = "steps.source.outputs.commit" if name == "validate" else "needs.validate.outputs.commit"
            refs = re.findall(r"(?m)^          ref: (.+)$", job)
            self.assertEqual(refs, ["${{ " + source + " }}"], name)
            self.assertIn("persist-credentials: false", job)
            if name != "validate":
                self.assertIn("validate", self.dependencies(job), name)

        verify = jobs["verify-source"]
        self.assertTrue({"validate", "zip", "rpm-test", "deb", "release-runtime"} <= self.dependencies(verify))
        self.assertIn('scripts/ci-validation.py verify --commit "${SOURCE_COMMIT}"', verify)
        self.assertIn("SOURCE_COMMIT: ${{ needs.validate.outputs.commit }}", verify)
        self.assertNotIn(": write", verify)
        self.assertIn("actions: read", verify)
        self.assertIn("pull-requests: read", verify)
        self.assertIn("verify-source", self.dependencies(jobs["publish"]))

        for name, privileged_step in (("rpm-sign", "Sign exact release RPM with OpenPGP"),
                                      ("publish", "Attest release artifacts")):
            job = jobs[name]
            tag_guard = '[[ ${current_tag_object} == "${SOURCE_TAG_OBJECT}" ]]'
            self.assertIn("SOURCE_TAG_OBJECT: ${{ needs.validate.outputs.tag_object }}", job)
            self.assertIn('[[ ${SOURCE_COMMIT} == "${GITHUB_SHA}" ]]', job)
            self.assertIn('git/ref/tags/${RELEASE_TAG}', job)
            self.assertIn(tag_guard, job)
            self.assertLess(job.index(tag_guard), job.index("name: " + privileged_step))
            self.assertNotIn("ci-validation.py", job)
            self.assertNotRegex(job, r"(?:bash|sh|python3)(?:\s+-[A-Za-z]+)*\s+(?:\./)?(?:scripts|tests|packaging)/")
            self.assertNotRegex(job, r"(?m)^\s+(?:source |\./)(?:scripts|tests|packaging|install-fedora)")
        self.assertNotIn("uses: actions/checkout@", jobs["rpm-sign"])
        self.assertNotIn(": write", jobs["rpm-sign"])

    def test_release_freezes_source_and_rechecks_proof_before_privileged_publication(self):
        self.assert_release_identity_contract(self.workflow("release.yml"))

    def test_release_identity_guards_reject_structural_regressions(self):
        text = self.workflow("release.yml")
        mutations = (
            ('[[ ${target_sha} == "${GITHUB_SHA}" ]]', "true"),
            ("ref: ${{ steps.source.outputs.commit }}", "ref: ${{ env.RELEASE_TAG }}"),
            ("ref: ${{ needs.validate.outputs.commit }}", "ref: ${{ env.RELEASE_TAG }}"),
            ("needs: [validate, zip, rpm-test, deb, verify-source]", "needs: [validate, zip, rpm-test, deb]"),
            ("needs: [validate, zip, rpm-test, deb, release-runtime]", "needs: validate"),
            ('[[ ${current_tag_object} == "${SOURCE_TAG_OBJECT}" ]]', "true"),
            ('run: python3 -I scripts/ci-validation.py verify --commit "${SOURCE_COMMIT}"', "run: true"),
            ("name: Attest release artifacts", "name: Attest release artifacts\n        run: bash scripts/candidate.sh"),
        )
        for old, new in mutations:
            with self.subTest(mutation=old):
                self.assertIn(old, text)
                with self.assertRaises(AssertionError):
                    self.assert_release_identity_contract(text.replace(old, new, 1))

    def assert_release_artifact_contract(self, text):
        jobs = self.jobs(text)
        for producer in ("previous-release", "zip", "rpm-build", "rpm-sign", "deb"):
            job = jobs[producer]
            self.assertIn("artifact_id: ${{ steps.artifact.outputs.artifact-id }}", job)
            self.assertEqual(job.count("id: artifact\n"), 1, producer)
            self.assertRegex(job, r"uses: actions/upload-artifact@[^\n]+\n        id: artifact\n")
        self.assertIn("artifact_id: ${{ needs.rpm-sign.outputs.artifact_id }}", jobs["rpm-test"])
        for format_name, producer in (("zip", "zip"), ("rpm", "rpm-test"), ("deb", "deb")):
            self.assertIn(format_name + "_artifact_id: ${{ needs." + producer + ".outputs.artifact_id }}",
                          jobs["publish"])
        consumers = {
            "rpm-sign": ["needs.rpm-build.outputs.artifact_id"],
            "rpm-test": ["needs.rpm-sign.outputs.artifact_id", "needs.previous-release.outputs.artifact_id"],
            "deb": ["needs.previous-release.outputs.artifact_id"],
            "publish": ["needs.zip.outputs.artifact_id", "needs.rpm-test.outputs.artifact_id", "needs.deb.outputs.artifact_id"],
            "verify-published": [f"needs.publish.outputs.{kind}_artifact_id" for kind in ("zip", "rpm", "deb")],
        }
        self.assertEqual({name for name, job in jobs.items() if "uses: actions/download-artifact@" in job},
                         set(consumers))
        for consumer, sources in consumers.items():
            job = jobs[consumer]
            downloads = list(re.finditer(
                r"(?m)^      - uses: actions/download-artifact@[^\n]+\n(?:(?!      - ).*\n)*", job,
            ))
            self.assertEqual(len(downloads), len(sources), consumer)
            triple = consumer in {"publish", "verify-published"}
            guard = ('[[ ${ARTIFACT_IDS} =~ ^[1-9][0-9]{0,19}(,[1-9][0-9]{0,19}){2}$ ]]'
                     if triple else '[[ ${ARTIFACT_IDS} =~ ^[1-9][0-9]{0,19}$ ]]')
            for download, source in zip(downloads, sources):
                block = download.group()
                self.assertIn("artifact-ids: ${{ " + source + " }}", block)
                self.assertIn("digest-mismatch: error", block)
                self.assertNotRegex(block, r"(?m)^          (?:name|pattern|merge-multiple):")
                before = job[:download.start()]
                required_ids = sources if triple else [source]
                ids = ",".join("${{ " + value + " }}" for value in required_ids)
                binding = "ARTIFACT_IDS: " + ids + "\n"
                self.assertIn(binding, before)
                bound_guard = before[before.rindex(binding):]
                self.assertIn(guard, bound_guard)
                self.assertIn("exit 65", bound_guard[bound_guard.rindex(guard):])

    def test_release_downloads_exact_artifact_ids_with_fatal_integrity_checks(self):
        self.assert_release_artifact_contract(self.workflow("release.yml"))

    def test_artifact_guards_reject_fallback_or_unsigned_replacement(self):
        text = self.workflow("release.yml")
        mutations = (
            ("artifact_id: ${{ steps.artifact.outputs.artifact-id }}", "artifact_id: ${ steps.artifact.outputs.artifact-id }"),
            ("digest-mismatch: error", "digest-mismatch: warn"),
            ("artifact-ids: ${{ needs.rpm-build.outputs.artifact_id }}", "pattern: unsigned-rpm"),
            ("artifact-ids: ${{ needs.rpm-test.outputs.artifact_id }}", "artifact-ids: ${{ needs.rpm-build.outputs.artifact_id }}"),
            ("artifact-ids: ${{ needs.publish.outputs.zip_artifact_id }}", "pattern: release-*"),
            ('[[ ${ARTIFACT_IDS} =~ ^[1-9][0-9]{0,19}$ ]]', "true"),
            ('[[ ${ARTIFACT_IDS} =~ ^[1-9][0-9]{0,19}(,[1-9][0-9]{0,19}){2}$ ]]', "true"),
        )
        for old, new in mutations:
            with self.subTest(mutation=old):
                self.assertIn(old, text)
                with self.assertRaises(AssertionError):
                    self.assert_release_artifact_contract(text.replace(old, new, 1))

    def test_main_only_promotes_identity(self):
        text = self.workflow("promotion.yml")
        self.assertRegex(text, r"(?m)^  push:")
        self.assertRegex(text, r"(?m)^      - main$")
        self.assertIn("scripts/ci-validation.py verify --commit", text)
        self.assertNotIn("tests/run-all.sh", text)
        self.assertNotIn("contents: write", text)

    def test_existing_required_stress_gate_waits_for_complementary_qualification(self):
        jobs = self.jobs(self.workflow("stress.yml"))
        gate = jobs["mock-stress-gate"]
        self.assertIn("scripts/ci-validation.py wait-required --commit", gate)
        self.assertIn("Mock process/cancellation stress (20x deterministic jitter)", gate)
        self.assertNotIn("package-cleanup-stress", jobs)


if __name__ == "__main__":
    unittest.main()
