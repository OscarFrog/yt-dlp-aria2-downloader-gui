# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/ci-validation-integration.py.

Exercise source promotion and signing preflight against hostile GitHub metadata.
Fixtures replace authenticated API reads; this suite never contacts GitHub.
"""

import copy
import contextlib
from datetime import datetime, timedelta, timezone
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile


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
                          for step in sorted(CHECK.required_steps(name))],
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

    def test_one_validated_commit_read_serves_all_five_proofs(self):
        self.verify()
        self.assertEqual(self.api.calls.count(f"git/commits/{SOURCE}"), 1)
        self.assertEqual(self.api.calls.count(f"git/commits/{TARGET}"), 1)
        self.assertEqual(len(self.api.calls), 36)
        for index in range(1, 6):
            latest = f"actions/workflows/{index}/runs?event=pull_request&head_sha={HEAD}&per_page=100&page=1"
            self.assertEqual(self.api.calls.count(latest), 2)
            self.assertEqual(self.api.calls.count(f"actions/runs/{index * 100}"), 1)
        self.assertEqual(self.api.calls.count("pulls/23"), 2)

    def test_commit_identity_reuse_is_isolated_by_oid_consumer_and_verifier(self):
        original = self.verifier.commit(SOURCE)
        changed = self.verifier.commit(SOURCE)
        changed["tree"]["sha"] = OTHER
        changed["parents"][0]["sha"] = OTHER
        self.assertEqual(self.verifier.commit(SOURCE), original)
        self.assertEqual(self.api.calls.count(f"git/commits/{SOURCE}"), 1)
        self.assertNotEqual(self.verifier.commit(TARGET)["parents"], original["parents"])
        self.assertEqual(CHECK.Verifier(self.api, NOW).commit(SOURCE), original)
        self.assertEqual(self.api.calls.count(f"git/commits/{SOURCE}"), 2)

    def test_malformed_commit_responses_are_never_retained(self):
        endpoint = f"git/commits/{SOURCE}"
        original = copy.deepcopy(self.api.responses[endpoint])
        variants = ({"sha": OTHER}, {"tree": {"sha": "refs/heads/main"}},
                    {"parents": None}, {"parents": [{"sha": "not-an-oid"}]})
        for changed in variants:
            with self.subTest(changed=changed):
                verifier = CHECK.Verifier(self.api, NOW)
                before = self.api.calls.count(endpoint)
                self.api.responses[endpoint] = dict(original, **changed)
                with self.assertRaises(CHECK.Refusal):
                    verifier.commit(SOURCE)
                self.api.responses[endpoint] = copy.deepcopy(original)
                self.assertEqual(verifier.commit(SOURCE), original)
                self.assertEqual(self.api.calls.count(endpoint), before + 2)

    def test_completed_other_workflows_do_not_mask_a_pending_or_failed_shell(self):
        for status, conclusion, exception in (("in_progress", None, CHECK.Pending),
                                               ("completed", "failure", CHECK.Refusal)):
            with self.subTest(status=status):
                self.run_data().update(status=status, conclusion=conclusion)
                with self.assertRaises(exception):
                    self.verifier.required(SOURCE, self.api.responses["pulls/23"], {})

    def test_cached_commit_does_not_mask_a_new_attempt_in_any_workflow(self):
        self.verifier.commit(SOURCE)
        for index in range(1, 6):
            endpoint = f"actions/runs/{index * 100}"
            self.api.transforms[endpoint] = lambda run: dict(run, run_attempt=2)
            with self.subTest(workflow=index), self.assertRaisesRegex(CHECK.Refusal, "changed during"):
                self.verify()
            del self.api.transforms[endpoint]

    def test_identity_success_is_required_in_each_parallel_workflow(self):
        for index in range(1, 6):
            identity = next(job for job in self.jobs(index) if job["name"].startswith(CHECK.IDENTITY_PREFIX))
            identity["steps"][0]["conclusion"] = "skipped"
            with self.subTest(workflow=index), self.assertRaises(CHECK.Refusal):
                self.verify()
            identity["steps"][0]["conclusion"] = "success"

    def test_minimum_shell_and_shared_destination_steps_cannot_be_missing_or_skipped(self):
        checks = (
            (1, "Ubuntu", "Check Python with reviewed Ruff"),
            (1, "Python 3.10 / Ubuntu", "Build and bind verified Bash 4.4 on the disposable runner"),
            (1, "Python 3.10 / Ubuntu", "Bind every test interpreter to the minimum Python"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Install verified Deno for shared-destination qualification"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Install pinned impersonation dependencies for shared qualification"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Run real shared-destination GUI and CLI qualification"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Retain shared-destination verdicts and monotonic events"),
        )
        for index, name, step in checks:
            for outcome in ("missing", "skipped", "failure"):
                with self.subTest(job=name, step=step, outcome=outcome):
                    api = fixture()
                    jobs = api.responses[f"actions/runs/{index * 100}/attempts/1/jobs?per_page=100&page=1"]["jobs"]
                    job = next(item for item in jobs if item["name"] == name)
                    entry = next(item for item in job["steps"] if item["name"] == step)
                    if outcome == "missing":
                        job["steps"].remove(entry)
                    else:
                        entry["conclusion"] = outcome
                    with self.assertRaises(CHECK.Refusal):
                        CHECK.Verifier(api, NOW).verify(TARGET)

    def test_shared_prerequisite_obligation_matches_the_pinned_matrix(self):
        step_name = "Install pinned impersonation dependencies for shared qualification"
        for version in ("2026.6.9", "2026.7.4", "2026.8.19"):
            for outcome in ("expected", "missing", "failure", "opposite"):
                with self.subTest(version=version, outcome=outcome):
                    api = fixture()
                    jobs = api.responses["actions/runs/400/attempts/1/jobs?per_page=100&page=1"]["jobs"]
                    job = next(item for item in jobs if item["name"] == f"Local media, pinned yt-dlp {version}")
                    # Model the workflow condition independently of checker tables.
                    job["steps"] = [step for step in job["steps"] if step["name"] != step_name]
                    expected = "success" if version == "2026.8.19" else "skipped"
                    if outcome != "missing":
                        conclusion = (expected if outcome == "expected" else "failure" if outcome == "failure"
                                      else "skipped" if expected == "success" else "success")
                        job["steps"].append({"name": step_name, "status": "completed", "conclusion": conclusion})
                    verifier = CHECK.Verifier(api, NOW)
                    if outcome == "expected":
                        self.assertEqual(verifier.verify(TARGET)["tree"], TREE)
                    else:
                        with self.assertRaises(CHECK.Refusal, msg="matrix prerequisite obligation was not enforced"):
                            verifier.verify(TARGET)

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
                # Different immutable commit fixtures need independent observers.
                self.verifier = CHECK.Verifier(self.api, NOW)
                with self.assertRaisesRegex(CHECK.Refusal, "squash"):
                    self.verify()

    def test_withdrawn_workflow_is_rejected_after_pending_poll(self):
        for key, value in (("state", "disabled_manually"), ("path", "other.yml"), ("id", 999)):
            with self.subTest(field=key):
                api = fixture()
                verifier = CHECK.Verifier(api, NOW)
                verified = {}
                pending = api.responses["actions/runs/300"]
                pending.update(status="in_progress", conclusion=None)
                with self.assertRaises(CHECK.Pending):
                    verifier.required(SOURCE, api.responses["pulls/23"], verified)
                self.assertIn("shell.yml", verified)
                api.responses["actions/workflows/shell.yml"][key] = value
                pending.update(status="completed", conclusion="success")
                with self.assertRaises(CHECK.Refusal):
                    verifier.required(SOURCE, api.responses["pulls/23"], verified)

    def test_withdrawn_workflow_is_rejected_at_final_verification(self):
        def withdraw_at_final_pull(response):
            if self.api.calls.count("pulls/23") == 2:
                self.api.responses["actions/workflows/shell.yml"]["state"] = "disabled_manually"
            return response

        self.api.transforms["pulls/23"] = withdraw_at_final_pull
        with self.assertRaisesRegex(CHECK.Refusal, "disabled"):
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

    def test_fedora44_job_cannot_satisfy_fedora45_evidence(self):
        for workflow, job_name in ((1, "Fedora 45"), (2, "Fedora 45 RPM build-once"),
                                   (2, "Fedora 45 RPM (fresh)"), (2, "Fedora 45 RPM (ffmpeg-free)"),
                                   (3, "FFmpeg 9.0.2 / Fedora 45")):
            with self.subTest(job=job_name):
                job = next(item for item in self.jobs(workflow) if item["name"] == job_name)
                job["name"] = job_name.replace("Fedora 45", "Fedora 44")
                try:
                    with self.assertRaises(CHECK.Refusal):
                        self.verify()
                finally:
                    job["name"] = job_name

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
            (2, "Fedora 45 RPM (fresh)", "Test previous immutable release -> current RPM upgrade"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Run real FFmpeg progress qualification"),
            (4, "Local media, pinned yt-dlp 2026.6.9", "Run aria2 direct-transfer behavior qualification"),
        ):
            job = next(job for job in self.jobs(index) if job["name"] == name)
            step = next(step for step in job["steps"] if step["name"] == step_name)
            step["conclusion"] = "skipped"
            with self.subTest(job=name, step=step_name), self.assertRaises(CHECK.Refusal):
                self.verify()
            step["conclusion"] = "success"

    def test_critical_qualification_obligations_are_independent_of_the_checker_table(self):
        # These obligations are business contracts, not values derived from
        # REQUIRED_STEPS: removing a production requirement must fail this test.
        for index, name, obligation in (
            (1, "Ubuntu", "Check Python with reviewed Ruff"),
            (2, "Fedora 45 RPM build-once", "Qualify RPM v4/v6 signature semantics"),
            (2, "Previous immutable release", "Verify exact published previous packages"),
            (2, "Fedora 45 RPM (fresh)", "Reject a different globally trusted RPM signer in PR CI"),
            (4, "Local media, pinned yt-dlp 2026.8.19", "Run direct, audio, HLS and DASH boundary qualification"),
        ):
            with self.subTest(job=name, obligation=obligation):
                self.api = fixture()
                self.verifier = CHECK.Verifier(self.api, NOW)
                job = next(job for job in self.jobs(index) if job["name"] == name)
                remaining = [step for step in job["steps"] if step["name"] != obligation]
                job["steps"] = remaining + [{
                    "name": obligation, "status": "completed", "conclusion": "success",
                }]
                self.verify()
                job["steps"] = remaining
                with self.assertRaisesRegex(CHECK.Refusal, "Required qualification steps"):
                    self.verify()

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

    def test_complementary_qualification_binds_exact_virtual_merge(self):
        pull = self.api.responses["pulls/23"]
        self.assertEqual(self.verifier.qualification(SOURCE, pull, "shell.yml")[1]["id"], 100)
        with self.assertRaisesRegex(CHECK.Refusal, "different virtual merge"):
            self.verifier.qualification(TARGET, pull, "shell.yml")

    def test_complementary_qualification_checks_event_parent_identity(self):
        pull = copy.deepcopy(self.api.responses["pulls/23"])
        pull["base"]["sha"] = OTHER
        with self.assertRaisesRegex(CHECK.Refusal, "triggering PR"):
            self.verifier.qualification(SOURCE, pull, "shell.yml")

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
        workflow_reads = self.api.calls.count("actions/workflows/shell.yml")
        self.run_data(3).update(status="completed", conclusion="success")
        self.run_data(1).update(status="completed", conclusion="failure")
        with self.assertRaises(CHECK.Refusal):
            self.verifier.required(SOURCE, pull, verified)
        self.assertEqual(self.api.calls.count("actions/workflows/shell.yml"), workflow_reads + 1)

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


SCHEDULED_STEPS = {
    "Install real engines and current yt-dlp stable",
    "Install verified Deno for current-stable shared qualification",
    "Validate current-stable shared prerequisites",
    "Record resolved current-stable tool versions",
    "Run current-stable routing qualification",
    "Run current-stable aria2 direct-transfer behavior qualification",
    "Run current-stable real FFmpeg progress qualification",
    "Run current-stable HLS duration validation",
    "Run current-stable shared-destination GUI and CLI qualification",
    "Retain current-stable shared-destination verdicts and monotonic events",
}


class ScheduledProofTests(unittest.TestCase):
    """A green historical schedule cannot omit current shared qualification."""

    def setUp(self):
        self.api = FixtureAPI()
        self.api.responses["actions/workflows/real-tools.yml"] = {
            "id": 4, "path": ".github/workflows/real-tools.yml", "state": "active",
        }
        self.run_record = {
            "id": 600, "run_attempt": 2, "workflow_id": 4, "path": ".github/workflows/real-tools.yml",
            "repository": {"full_name": CHECK.REPOSITORY}, "head_repository": {"full_name": CHECK.REPOSITORY},
            "head_sha": SOURCE, "head_branch": "main", "event": "schedule",
            "status": "completed", "conclusion": "success", "created_at": RECENT, "updated_at": RECENT,
        }
        self.api.responses["actions/runs/600"] = self.run_record
        self.jobs = [{"run_id": 600, "name": name, "status": "completed", "completed_at": RECENT,
                      "conclusion": "skipped" if skipped else "success",
                      "steps": [{"name": step, "status": "completed", "conclusion": "success"}
                                for step in sorted(steps)]}
                     for name, skipped, steps in (
                         (CHECK.IDENTITY_PREFIX + SOURCE, False, {"Bind validation to the event source"}),
                         ("Scheduled current stable yt-dlp", False, SCHEDULED_STEPS),
                         ("Local media, pinned yt-dlp ${{ matrix.yt_dlp_version }}", True, set()),
                     )]
        self.api.responses["actions/runs/600/attempts/2/jobs?per_page=100&page=1"] = {"jobs": self.jobs}
        self.api.responses[f"git/commits/{SOURCE}"] = {
            "sha": SOURCE, "tree": {"sha": TREE}, "parents": [{"sha": BASE}],
        }
        self.verifier = CHECK.Verifier(self.api, NOW)

    def test_complete_attempt_binds_source_and_rechecks_run(self):
        result = self.verifier.scheduled(600, SOURCE)
        self.assertEqual(result, {"workflow": ".github/workflows/real-tools.yml", "run_id": 600,
                                  "run_attempt": 2, "source_commit": SOURCE, "source_tree": TREE})
        self.assertEqual(self.api.calls.count("actions/runs/600"), 2)
        self.assertIn("actions/runs/600/attempts/2/jobs?per_page=100&page=1", self.api.calls)
        self.assertEqual(CHECK.required_steps("Scheduled current stable yt-dlp"), SCHEDULED_STEPS)

    def test_case_can_run_again_with_a_fresh_result(self):
        case = ScheduledProofTests("test_complete_attempt_binds_source_and_rechecks_run")
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                result = unittest.TestResult()
                case.run(result)
                self.assertTrue(result.wasSuccessful(), (result.failures, result.errors))
                self.assertEqual(result.testsRun, 1)

    def test_required_weekly_steps_must_each_succeed_exactly_once(self):
        original = copy.deepcopy(self.jobs[1]["steps"])
        for name in sorted(SCHEDULED_STEPS):
            for variant in ("missing", "duplicate", "failure", "skipped", "incomplete"):
                with self.subTest(step=name, variant=variant):
                    steps = copy.deepcopy(original)
                    item = next(step for step in steps if step["name"] == name)
                    if variant == "missing":
                        steps.remove(item)
                    elif variant == "duplicate":
                        steps.append(copy.deepcopy(item))
                    elif variant == "incomplete":
                        item["status"] = "in_progress"
                    else:
                        item["conclusion"] = variant
                    self.jobs[1]["steps"] = steps
                    with self.assertRaisesRegex(CHECK.Refusal, "steps are missing or duplicated|step failed"):
                        self.verifier.scheduled(600, SOURCE)
        self.jobs[1]["steps"] = original

    def test_identity_and_required_job_inventory_cannot_be_replaced_by_green_status(self):
        original = copy.deepcopy(self.jobs)
        for variant in ("missing-identity", "wrong-source", "missing-shared-job", "duplicate-job",
                        "shared-job-skipped", "pinned-job-ran", "other-run", "empty-steps", "failed-identity"):
            with self.subTest(variant=variant):
                self.jobs[:] = copy.deepcopy(original)
                if variant == "missing-identity":
                    self.jobs.pop(0)
                elif variant == "wrong-source":
                    self.jobs[0]["name"] = CHECK.IDENTITY_PREFIX + OTHER
                elif variant == "missing-shared-job":
                    self.jobs.pop(1)
                elif variant == "duplicate-job":
                    self.jobs.append(copy.deepcopy(self.jobs[1]))
                elif variant == "shared-job-skipped":
                    self.jobs[1]["conclusion"] = "skipped"
                elif variant == "pinned-job-ran":
                    self.jobs[2]["conclusion"] = "success"
                elif variant == "other-run":
                    self.jobs[1]["run_id"] = 601
                elif variant == "empty-steps":
                    self.jobs[1]["steps"] = []
                else:
                    self.jobs[0]["steps"][0]["conclusion"] = "failure"
                with self.assertRaises(CHECK.Refusal):
                    self.verifier.scheduled(600, SOURCE)

    def test_run_provenance_and_attempt_are_checked(self):
        for field, value in (("id", 601), ("head_sha", OTHER), ("workflow_id", 9),
                             ("path", ".github/workflows/other.yml"), ("event", "workflow_dispatch"),
                             ("head_branch", "feature"), ("status", "in_progress"), ("conclusion", "failure"),
                             ("run_attempt", 0), ("repository", {"full_name": "other/repo"}),
                             ("head_repository", {"full_name": "other/repo"}),
                             ("created_at", "2026-09-12T11:30:00Z"),
                             ("updated_at", "2026-09-13T11:00:00Z")):
            with self.subTest(field=field):
                original = self.run_record[field]
                self.run_record[field] = value
                with self.assertRaises(CHECK.Refusal):
                    self.verifier.scheduled(600, SOURCE)
                self.run_record[field] = original

    def test_incomplete_pagination_and_changed_latest_attempt_are_refused(self):
        original = self.api.responses["actions/runs/600/attempts/2/jobs?per_page=100&page=1"]
        self.api.responses["actions/runs/600/attempts/2/jobs?per_page=100&page=1"] = {"jobs": self.jobs * 34}
        with self.assertRaisesRegex(CHECK.Refusal, "pagination"):
            self.verifier.scheduled(600, SOURCE)
        self.api.responses["actions/runs/600/attempts/2/jobs?per_page=100&page=1"] = original
        for field, value in (("run_attempt", 3), ("conclusion", "failure"), ("head_sha", OTHER),
                             ("event", "workflow_dispatch"), ("updated_at", "2026-09-12T11:30:00Z")):
            with self.subTest(field=field):
                reads = []

                def change_run(result):
                    reads.append(True)
                    if len(reads) == 2:
                        result[field] = value
                    return result

                self.api.transforms["actions/runs/600"] = change_run
                with self.assertRaises(CHECK.Refusal):
                    self.verifier.scheduled(600, SOURCE)
                self.assertEqual(len(reads), 2)

    def test_release_collector_propagates_refusal_and_binds_selected_schedule(self):
        text = (PROJECT / "scripts/release-evidence-qualification.sh").read_text(encoding="utf-8")
        functions = []
        for name in ("fail_qualification", "verify_scheduled_real_tools", "collect_scheduled_runs"):
            start = text.index(name + "() {\n")
            end = text.index("\n}\n", start) + 3
            functions.append(text[start:end])
        script = "\n".join(functions) + r'''
PROJECT_DIR=/fixture
GH_TOKEN=fixture-token
real_result=unpublished
shfmt_result=unpublished
retry_qualification_capture() { printf '{"databaseId":600,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'; }
select_latest_successful_schedule() { printf '%s' "$1"; }
assert_schedule_fresh() { return 0; }
python3() {
    [[ $* == '-I /fixture/scripts/ci-validation.py verify-schedule --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --run-id 600' ]] || return 99
    printf '{"run_attempt":2,"source_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_tree":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}'
    return "${CHECK_STATUS}"
}
if collect_scheduled_runs OscarFrog/yt-dlp-aria2-downloader-gui 14 real_result shfmt_result; then
    [[ ${CHECK_STATUS} == 0 ]]
    [[ $(jq -r '.qualification.run_attempt' <<<"${real_result}") == 2 ]]
else
    status=$?
    [[ ${CHECK_STATUS} == 17 && ${status} == 65 && ${real_result} == unpublished && ${shfmt_result} == unpublished ]]
fi
'''
        for status in (0, 17):
            with self.subTest(status=status):
                result = subprocess.run(["bash", "-c", script], env=dict(os.environ, CHECK_STATUS=str(status)),
                                        capture_output=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertEqual(result.stdout, b"")
                if status:
                    self.assertIn(b"scheduled current-stable qualification was refused", result.stderr)


class ScheduleDateTests(unittest.TestCase):
    """Exercise the real Bash selection/date boundary with an independent clock."""

    REFERENCE_EPOCH = 1790856000  # 2026-10-01T12:00:00Z

    @classmethod
    def setUpClass(cls):
        source = (PROJECT / "scripts/release-evidence-qualification.sh").read_text(encoding="utf-8")
        functions = []
        for name in ("fail_qualification", "select_latest_successful_schedule", "assert_schedule_fresh"):
            start = source.index(name + "() {\n")
            end = source.index("\n}\n", start) + 3
            functions.append(source[start:end])
        cls.functions = "\n".join(functions)

    @staticmethod
    def run_record(**changes):
        record = dict(databaseId=123, event="schedule", status="completed", conclusion="success",
                      createdAt="2026-09-30T12:00:00Z")
        record.update(changes)
        return record

    def check_records(self, records, zone="UTC", reference=None, source=None):
        # Only the reference clock is replaced. GNU date still performs every
        # candidate conversion; no production clock override is introduced.
        script = "set -Eeuo pipefail\n" + (self.functions if source is None else source) + r'''
REFERENCE_EPOCH=$2
date() {
    if [[ $# == 1 && $1 == +%s ]]; then
        printf '%s\n' "${REFERENCE_EPOCH}"
    else
        command date "$@"
    fi
}
selected=$(select_latest_successful_schedule "$1")
# The conditional also proves refusals do not depend on caller errexit.
if assert_schedule_fresh "${selected}" shfmt-update.yml 14; then
    printf '%s\n' "${selected}"
else
    exit "$?"
fi
'''
        environment = dict(os.environ, TZ=zone, LC_ALL="C")
        environment.pop("BASH_ENV", None)
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", script, "schedule-date-fixture",
             json.dumps(records), str(self.REFERENCE_EPOCH if reference is None else reference)],
            capture_output=True, text=True, timeout=5, check=False, env=environment,
        )

    def assert_invalid_timestamp(self, record, **options):
        result = self.check_records([record], **options)
        self.assertEqual(result.returncode, 65, "invalid timestamp was accepted: " + result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertIn("invalid createdAt timestamp", result.stderr)

    def test_missing_empty_and_non_string_dates_are_rejected(self):
        missing = self.run_record()
        del missing["createdAt"]
        self.assert_invalid_timestamp(missing)
        for value in (None, "", " ", "\t\n", False, True, 0, 1790856000, [], {}):
            with self.subTest(value=value):
                self.assert_invalid_timestamp(self.run_record(createdAt=value))

    def test_relative_partial_and_unzoned_dates_are_rejected(self):
        for value in (
            "2026-10-01T12:00:00Z yesterday", "2026-10-01T12:00:00Z -1 day",
            "yesterday", "now", "2026-09-30", "2026-09-30T12:00:00",
            "2026-09-30 12:00:00Z", "2026-9-30T12:00:00Z", "2026-09-30T12:00:00UTC",
            " 2026-09-30T12:00:00Z", "2026-09-30T12:00:00Z ",
            "2026-09-30T12:00:00Z\n", "2026-09-30T12:00:00Z\x00",
            "2026-09-30T12:00:00.1234567890Z", "2026-09-30T12:00:00.Z",
            "2026-09-30T12:00:00Zjunk", "junk2026-09-30T12:00:00Z",
        ):
            with self.subTest(value=value):
                self.assert_invalid_timestamp(self.run_record(createdAt=value))

    def test_impossible_calendar_clock_and_offsets_are_rejected(self):
        for value in (
            "2026-02-29T12:00:00Z", "2026-02-30T12:00:00Z", "2026-04-31T12:00:00Z",
            "2026-00-30T12:00:00Z", "2026-13-30T12:00:00Z", "2026-09-00T12:00:00Z",
            "2026-09-31T12:00:00Z", "2026-09-30T24:00:00Z", "2026-09-30T12:60:00Z",
            "2026-09-30T12:00:60Z", "2026-09-30T12:00:00+24:00",
            "2026-09-30T12:00:00+00:60", "2026-09-30T12:00:00-99:00",
        ):
            with self.subTest(value=value):
                self.assert_invalid_timestamp(self.run_record(createdAt=value))

    def test_absolute_timezone_and_fraction_variants_are_accepted(self):
        for value in (
            "2026-09-30T12:00:00Z", "2026-09-30T12:00:00+00:00",
            "2026-09-30T12:00:00-00:00", "2026-09-30T17:30:00+05:30",
            "2026-09-30T04:00:00-08:00", "2026-09-30T12:00:00.1Z",
            "2026-09-30T12:00:00.123456Z", "2026-09-30T12:00:00.123456789Z",
            "2026-09-30T17:30:00.123456789+05:30",
        ):
            with self.subTest(value=value):
                result = self.check_records([self.run_record(createdAt=value)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["createdAt"], value)

    def test_leap_day_is_valid_in_a_leap_year(self):
        reference = int(datetime(2024, 3, 1, 12, tzinfo=timezone.utc).timestamp())
        result = self.check_records([self.run_record(createdAt="2024-02-29T12:00:00Z")],
                                    reference=reference)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_freshness_boundaries_are_timezone_independent(self):
        # POSIX TZ rules do not silently fall back to UTC when tzdata is absent.
        for zone, offset in (("UTC0", "+0000"), ("HST10", "-1000"), ("JST-9", "+0900")):
            actual = subprocess.run(
                ["date", "-d", "@1790856000", "+%z"],
                env=dict(os.environ, TZ=zone, LC_ALL="C"), capture_output=True,
                text=True, timeout=5, check=False,
            )
            self.assertEqual(actual.returncode, 0, actual.stderr)
            self.assertEqual(actual.stdout.strip(), offset)
            for value, expected in (
                ("2026-09-17T12:00:00Z", 0),
                ("2026-09-17T12:00:01Z", 0),
                ("2026-09-17T11:59:59Z", 65),
                ("2026-10-01T12:00:00Z", 0),
                ("2026-10-01T12:00:01Z", 65),
                ("2026-09-17T17:30:00+05:30", 0),
                ("2026-09-17T17:29:59+05:30", 65),
                ("2026-09-17T04:00:00-08:00", 0),
                # Preserve the existing whole-second comparison, including
                # fractions in the boundary second; do not tighten freshness.
                ("2026-09-17T12:00:00.999999999Z", 0),
                ("2026-09-17T11:59:59.999999999Z", 65),
                ("2026-10-01T12:00:00.999999999Z", 0),
            ):
                with self.subTest(zone=zone, value=value):
                    result = self.check_records([self.run_record(createdAt=value)], zone=zone)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertIn("older than 14 days", result.stderr)

    def test_rerun_metadata_does_not_refresh_original_creation(self):
        result = self.check_records([self.run_record(
            createdAt="2026-09-17T11:59:59Z", updatedAt="2026-10-01T12:00:00Z", runAttempt=2)])
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("older than 14 days", result.stderr)

    def test_schedule_selection_policy_is_preserved(self):
        excluded = [self.run_record(event="workflow_dispatch"),
                    self.run_record(conclusion="failure"), self.run_record(status="in_progress")]
        result = self.check_records(excluded)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("no successful scheduled run", result.stderr)
        earlier = self.run_record(databaseId=122, createdAt="2026-09-20T12:00:00Z")
        result = self.check_records(excluded + [earlier])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["databaseId"], 122)
        # Selection still uses the first successful schedule in API order; an
        # invalid selected timestamp must not fall back to an older success.
        self.assert_invalid_timestamp(self.run_record(createdAt="yesterday"))
        result = self.check_records([self.run_record(createdAt="yesterday"), earlier])
        self.assertEqual(result.returncode, 65, result.stderr)

    def test_removing_json_date_guard_is_detected_by_negative_witness(self):
        start = self.functions.index('    if ! created_at=$(jq -er --arg pattern ')
        end = self.functions.index('    if ! created_epoch=', start)
        mutant = (self.functions[:start] +
                  '    created_at=$(jq -r ".createdAt" <<<"${run_json}")\n' + self.functions[end:])
        witness = self.run_record(createdAt="2026-10-01T12:00:00Z yesterday")
        self.assert_invalid_timestamp(witness)
        result = self.check_records([witness], source=mutant)
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaisesRegex(AssertionError, "invalid timestamp was accepted"):
            self.assert_invalid_timestamp(witness, source=mutant)


class PreflightTests(unittest.TestCase):
    @staticmethod
    def metadata():
        return {
            "protection_rules": [{"type": "required_reviewers", "prevent_self_review": False,
                                  "reviewers": [{"reviewer": {"login": "fixture-maintainer"}}]}],
            "can_admins_bypass": False,
            "deployment_branch_policy": {"custom_branch_policies": True},
        }

    def check_environment(self, metadata, *, api_failure=False, policy="v*\ttag", repeats=1):
        text = (PROJECT / "scripts/release-preflight.sh").read_text(encoding="utf-8")
        functions = []
        for name in ("fail", "api_capture", "verify_signing_environment"):
            start = text.index(name + "() {\n")
            end = text.index("\n}\n", start) + 3
            functions.append(text[start:end])
        script = "\n".join(functions) + r'''
set -Eeuo pipefail
API_VERSION=fixture
SIGNING_ENVIRONMENT=rpm-signing
gh() {
    local endpoint=${6}
    printf '%s\n' "${endpoint}" >>"${CHECK_CALLS}"
    case ${endpoint} in
        repos/fixture/project/environments/rpm-signing)
            command cat -- "${CHECK_METADATA}"
            [[ ${CHECK_API_FAILURE} == false ]] || return 17
            ;;
        user) printf 'fixture-maintainer\n' ;;
        repos/fixture/project/environments/rpm-signing/deployment-branch-policies)
            printf '%s\n' "${CHECK_POLICY}"
            ;;
        *) return 99 ;;
    esac
}
for ((iteration = 0; iteration < CHECK_REPEATS; iteration++)); do
    verify_signing_environment fixture/project
done
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "metadata.json"
            path.write_bytes(metadata if isinstance(metadata, bytes) else json.dumps(metadata).encode())
            trace = root / "calls"
            environment = dict(os.environ, CHECK_METADATA=str(path), CHECK_CALLS=str(trace),
                               CHECK_API_FAILURE=str(api_failure).lower(), CHECK_POLICY=policy,
                               CHECK_REPEATS=str(repeats))
            result = subprocess.run(["bash", "-c", script], env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
            return result, trace.read_text().splitlines()

    def test_six_environment_fields_share_one_snapshot_and_a_new_call_reads_again(self):
        result, calls = self.check_environment(self.metadata(), repeats=2)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        self.assertEqual(calls, ["repos/fixture/project/environments/rpm-signing", "user",
                                "repos/fixture/project/environments/rpm-signing/deployment-branch-policies"] * 2)

    def test_environment_snapshot_preserves_every_policy_refusal(self):
        changes = (
            lambda data: data.update(protection_rules=[]),
            lambda data: data["protection_rules"].append(copy.deepcopy(data["protection_rules"][0])),
            lambda data: data["protection_rules"][0].update(reviewers=[]),
            lambda data: data["protection_rules"][0]["reviewers"].append({"reviewer": {"login": "another"}}),
            lambda data: data["protection_rules"][0]["reviewers"][0]["reviewer"].update(login="another"),
            lambda data: data["protection_rules"][0].update(prevent_self_review=True),
            lambda data: data.update(can_admins_bypass=True),
            lambda data: data["deployment_branch_policy"].update(custom_branch_policies=False),
        )
        for index, change in enumerate(changes):
            metadata = self.metadata()
            change(metadata)
            result, calls = self.check_environment(metadata)
            with self.subTest(policy=index):
                self.assertEqual(result.returncode, 65, result.stderr.decode(errors="replace"))
                self.assertEqual(result.stdout, b"")
                self.assertEqual(calls.count("repos/fixture/project/environments/rpm-signing"), 1)
        for policy in ("v*\tbranch", "main\ttag", "v*\ttag\nmain\tbranch", ""):
            with self.subTest(deployment_policy=policy):
                result, _ = self.check_environment(self.metadata(), policy=policy)
                self.assertEqual(result.returncode, 65)

    def test_bounded_snapshot_refuses_malformed_types_and_failed_api_with_valid_output(self):
        variants = [b"{", b" " * 65537, b"[" * 2000 + b"]" * 2000,
                    dict(self.metadata(), protection_rules="invalid"),
                    dict(self.metadata(), can_admins_bypass=0),
                    dict(self.metadata(), deployment_branch_policy=[])]
        for invalid in (0, "false", [], {}):
            metadata = self.metadata()
            metadata["protection_rules"][0]["prevent_self_review"] = invalid
            variants.append(metadata)
        for control in ("\n", "\r", "\0", "\t", "\x7f"):
            metadata = self.metadata()
            metadata["protection_rules"][0]["reviewers"][0]["reviewer"]["login"] = "fixture-" + control + "maintainer"
            variants.append(metadata)
        for index, metadata in enumerate(variants):
            with self.subTest(metadata=index):
                result, _ = self.check_environment(metadata)
                self.assertEqual(result.returncode, 65)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"snapshot", result.stderr)
                self.assertNotIn(b"Traceback", result.stderr)
        result, _ = self.check_environment(self.metadata(), api_failure=True)
        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")


class SigningSecretReplayTests(unittest.TestCase):
    """Exercise signer policy, not cryptography, using the actual workflow block."""

    PRIMARY = "7B54065FE061E78ED2C96252E3BE996196ABEA7F"
    SUBKEY = "1F5B769CE48A08AAC0A7D9DDECC9894B41830245"

    @staticmethod
    def key_record(kind, *, capabilities="", secret="", fingerprint=""):
        fields = [""] * 16
        fields[0], fields[1] = kind, "u"
        fields[9], fields[11], fields[14] = fingerprint, capabilities, secret
        return ":".join(fields)

    def test_only_an_offline_primary_secret_reaches_the_signer(self):
        block = VersionBoundaryTests.step("release.yml", "Sign exact release RPM with OpenPGP")
        tools = r'''
rpm() {
    if [[ $* == *'%{rpmformat}'* ]]; then
        printf '4\n'
    elif [[ ${@: -1} == dist/* && -f ${SIGNER_CALL_LOG} ]]; then
        printf 'signed\n'
    else
        printf 'unsigned\n'
    fi
}
gpg() {
    if [[ $* == *'--list-secret-keys'* ]]; then
        printf '%s\n' "${SIGNER_LISTING}"
    elif [[ $* == *'--export'* ]]; then
        printf 'inert public key fixture\n'
    fi
}
rpmkeys() { return 0; }
gpgconf() { return 0; }
rpmsign() {
    printf '%s\n' "$*" >>"${SIGNER_CALL_LOG}"
}
'''
        for state in ("#", "+", "D2760001240102000005000012340000", "", "malformed"):
            with self.subTest(primary_secret_state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                unsigned = root / "unsigned"
                unsigned.mkdir()
                (unsigned / "fixture.rpm").write_bytes(b"inert package; never processed by real RPM tools\n")
                scratch = root / "scratch"
                scratch.mkdir()
                calls = root / "signer-calls"
                listing = "\n".join((
                    self.key_record("sec", capabilities="c", secret=state),
                    self.key_record("fpr", fingerprint=self.PRIMARY),
                    self.key_record("ssb", capabilities="s", secret="+"),
                    self.key_record("fpr", fingerprint=self.SUBKEY),
                )) if state != "malformed" else "not:a:secret:key:listing"
                environment = dict(
                    os.environ, TMPDIR=str(scratch), SIGNER_LISTING=listing, SIGNER_CALL_LOG=str(calls),
                    RPM_SIGNING_FINGERPRINT=self.PRIMARY, RPM_SIGNING_SUBKEY_FINGERPRINT=self.SUBKEY,
                    RPM_SIGNING_PRIVATE_KEY_B64="aW5lcnQgZml4dHVyZQ==",
                    RPM_SIGNING_PASSPHRASE="inert fixture passphrase",
                )
                result = subprocess.run(["bash", "-c", tools + block], cwd=root, env=environment,
                                        text=True, capture_output=True, timeout=15)
                if state == "#":
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(len(calls.read_text().splitlines()), 1)
                    self.assertIn("--key-id " + self.SUBKEY, calls.read_text())
                    self.assertEqual((root / "dist/fixture.rpm").read_bytes(),
                                     (unsigned / "fixture.rpm").read_bytes())
                else:
                    self.assertFalse(calls.exists(), "rejected private-primary state reached rpmsign")
                    self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
                    self.assertFalse((root / "dist").exists(), "rejected state prepared a signed publication")
                self.assertEqual(list(scratch.iterdir()), [], "signing temporary state survived cleanup")


class WorkflowContractTests(unittest.TestCase):
    # Workflow, job, minute limits for the job, setup, update, and the install timeout argument.
    MEDIA_BUDGETS = (
        ("real-tools.yml", "pinned-local-media", 65, 10, 3, '"${apt_remaining}s"'),
        ("real-tools.yml", "current-stable-local-media", 65, 8, 2, "4m"),
        ("release.yml", "release-runtime", 50, 8, 2, "4m"),
    )
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

    def assert_media_provisioning_budgets(self, text, job_name, expected_minutes, setup, update, apt_install):
        job = self.jobs(text)[job_name]
        minutes = int(re.search(r"(?m)^    timeout-minutes: (\d+)$", job).group(1))
        self.assertEqual(minutes, expected_minutes)
        steps = re.split(r"(?m)^      - ", job)[1:]
        budget_seconds = 0
        tests_seconds = 0
        for step in steps:
            explicit = re.search(r"(?m)^        timeout-minutes: (\d+)$", step)
            if explicit:
                budget_seconds += int(explicit.group(1)) * 60
            else:
                bounded = re.findall(r"timeout --signal=TERM --kill-after=10s ([0-9]+)m \\\n", step)
                self.assertEqual(len(bounded), 1, "Every media step needs one bounded deadline: " + step)
                duration = int(bounded[0]) * 60 + 10
                budget_seconds += duration
                tests_seconds += duration
        self.assertGreaterEqual(minutes * 60, budget_seconds + 120)
        expected_tests = 33 * 60 + 40 if job_name == "release-runtime" else 41 * 60 + 50
        self.assertEqual(tests_seconds, expected_tests, "Test deadlines and coverage must remain unchanged")
        install = next(step for step in steps if "apt_options=(" in step)
        self.assertRegex(install, rf"(?m)^        timeout-minutes: {setup}$")
        for option in ("Acquire::Retries=3", "Acquire::http::Timeout=30",
                       "Acquire::https::Timeout=30", "DPkg::Lock::Timeout=60"):
            self.assertEqual(install.count(option), 1)
        self.assertIn(f'sudo timeout --signal=TERM --kill-after=10s {update}m '
                      '\\\n            python3 -I -B scripts/ci-ubuntu-mirrors.py --apt "${apt_options[@]}" -o APT::Update::Error-Mode=any update', install)
        self.assertIn(f'sudo timeout --signal=TERM --kill-after=10s {apt_install} '
                      '\\\n            env DEBIAN_FRONTEND=noninteractive \\\n            python3 -I -B scripts/ci-ubuntu-mirrors.py --apt "${apt_options[@]}" install --yes --no-install-recommends', install)
        for forbidden in ("continue-on-error", "|| true", "--allow-unauthenticated", "--fix-missing",
                          "trusted=yes", "Acquire::AllowInsecureRepositories", "/etc/apt/sources"):
            self.assertNotIn(forbidden, install)
        self.assertLess(install.index('"${apt_options[@]}" -o APT::Update::Error-Mode=any update'),
                        install.index('"${apt_options[@]}" install'))
        self.assertLess(install.index('"${apt_options[@]}" install'), install.index("python3 -m venv"))

    def test_pinned_media_jobs_finish_independently_and_remain_required(self):
        job = self.jobs(self.workflow("real-tools.yml"))["pinned-local-media"]
        self.assertIn("    strategy:\n      fail-fast: false\n      matrix:", job)
        self.assertNotIn("continue-on-error", job)

    def test_media_provisioning_and_job_budgets_cover_all_original_tests(self):
        for workflow, name, minutes, setup, update, apt_install in self.MEDIA_BUDGETS:
            with self.subTest(job=name):
                self.assert_media_provisioning_budgets(self.workflow(workflow), name, minutes, setup, update, apt_install)

    def test_media_deadlines_cannot_be_removed_or_consume_the_test_budget(self):
        for workflow, name, minutes, setup, update, apt_install in self.MEDIA_BUDGETS:
            text = self.workflow(workflow)
            job = self.jobs(text)[name]
            for old, new in ((f"    timeout-minutes: {minutes}", "    timeout-minutes: 25"),
                             (f"        timeout-minutes: {setup}", "        timeout-minutes: 30"),
                             (f"sudo timeout --signal=TERM --kill-after=10s {update}m", "sudo"),
                             (f"sudo timeout --signal=TERM --kill-after=10s {apt_install}", "sudo"),
                             ("Acquire::http::Timeout=30", "Acquire::http::Timeout=0"),
                             ("Acquire::https::Timeout=30", "Acquire::https::Timeout=0"),
                             ("DPkg::Lock::Timeout=60", "DPkg::Lock::Timeout=-1"),
                             ("Acquire::Retries=3", "Acquire::Retries=0"),
                             ("-o APT::Update::Error-Mode=any", ""),
                             ('"${apt_options[@]}" -o APT::Update::Error-Mode=any update', '"${apt_options[@]}" -o APT::Update::Error-Mode=any update || true'),
                             ("8m \\\n            bash ./tests/real-tools-integration.sh", "7m \\\n            bash ./tests/real-tools-integration.sh")):
                with self.subTest(job=name, mutation=old):
                    self.assertIn(old, job)
                    mutated = text.replace(job, job.replace(old, new, 1), 1)
                    with self.assertRaises(AssertionError):
                        self.assert_media_provisioning_budgets(mutated, name, minutes, setup, update, apt_install)

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
                self.assertNotRegex(triggers, r"(?m)^  (?:pull_request_target|workflow_run):")
                self.assertIn("name: Source identity ${{ github.sha }}", text)
                self.assertIn("cancel-in-progress: true", text)
                self.assertNotIn("continue-on-error:", text)
                self.assertNotIn(": write", text)
                self.assertNotIn("secrets.", text)
                jobs = self.jobs(text)
                self.assertIn("EXPECTED_SHA: ${{ github.sha }}", jobs["identity"])
                self.assertIn('[[ $(git rev-parse HEAD) == "${EXPECTED_SHA}" ]]', jobs["identity"])
                self.assertNotRegex(jobs["identity"], r"(?m)^          ref:")
                self.assertNotRegex(text, r"(?m)^          ref:")
                for job in jobs:
                    if job not in {"identity", "current-stable-local-media"}:
                        self.assert_gate(jobs, job, "identity")
                self.assertNotIn("wait-shell", text)
                self.assertIn("timeout-minutes: 3", jobs["identity"])
                for retained in ("scripts/check-push-version.py coherence",
                                 "source tests/lib/project-files.sh", 'bash -n -- "${file}"'):
                    self.assertIn(retained, jobs["identity"])
                for unnecessary in ("GH_TOKEN", "actions: read", "pull-requests: read", "sleep "):
                    self.assertNotIn(unnecessary, jobs["identity"])

    def test_parallel_workflow_job_and_matrix_inventories_are_unchanged(self):
        for filename, required in CHECK.WORKFLOWS.items():
            names = []
            for job in self.jobs(self.workflow(filename)).values():
                name = re.search(r"(?m)^    name: (.+)$", job).group(1)
                if "${{ matrix." in name:
                    variable = re.search(r"\$\{\{ matrix\.([a-z_]+) \}\}", name).group(1)
                    declaration = re.search(r"(?m)^        " + variable + r": \[([^\n]+)\]$", job)
                    self.assertIsNotNone(declaration, name)
                    names.extend(name.replace("${{ matrix." + variable + " }}", value.strip(" '"))
                                 for value in declaration.group(1).split(","))
                else:
                    names.append(name.replace("${{ github.sha }}", SOURCE))
            expected = required | {CHECK.IDENTITY_PREFIX + SOURCE}
            if filename == "real-tools.yml":
                expected |= {CHECK.SCHEDULED_JOB}
            with self.subTest(workflow=filename):
                self.assertEqual(len(names), len(set(names)))
                self.assertEqual(set(names), expected)

    def test_each_cheap_identity_executes_source_coherence_and_syntax_guards(self):
        for filename in CHECK.WORKFLOWS:
            job = self.jobs(self.workflow(filename))["identity"]
            body = job.split("        run: |\n", 1)[1]
            script = "\n".join(line[10:] for line in body.splitlines() if line.strip())
            for failure, expected in (("none", 0), ("sha", 1), ("coherence", 17), ("syntax", 23)):
                with self.subTest(workflow=filename, failure=failure):
                    environment = dict(os.environ, EXPECTED_SHA=SOURCE, CHECK_SOURCE=SOURCE,
                                       CHECK_FAILURE=failure)
                    fixture = '''
git() {
    if [[ ${CHECK_FAILURE} == sha ]]; then printf 'wrong-source'; else printf '%s' "${CHECK_SOURCE}"; fi
}
python3() { [[ ${CHECK_FAILURE} != coherence ]] || return 17; }
source() { ALL_SHELL_FILES=(fixture.sh); }
bash() { [[ ${CHECK_FAILURE} != syntax ]] || return 23; }
'''
                    result = subprocess.run(["bash", "-c", fixture + script], env=environment,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr.decode(errors="replace"))

    def test_required_step_inventory_tracks_the_workflow_definitions(self):
        for filename, names in CHECK.WORKFLOWS.items():
            text = self.workflow(filename)
            for name in names | {CHECK.IDENTITY_PREFIX + SOURCE}:
                for step in CHECK.required_steps(name):
                    with self.subTest(workflow=filename, job=name, step=step):
                        if name.endswith(" / verified upstream source"):
                            version = name.split()[1]
                            upstream = self.jobs(text)["ffmpeg-upstream"]
                            self.assertIn("version: ['8.1.3', '9.0.1']", upstream)
                            self.assertIn("EXPECTED_FFMPEG_VERSION: ${{ matrix.version }}", upstream)
                            self.assertIn("- name: " + step + "\n",
                                          upstream.replace("${{ matrix.version }}", version))
                        else:
                            self.assertIn("- name: " + step + "\n", text)

    def test_minimum_interpreters_share_one_full_run_and_bind_absolute_fixtures(self):
        job = self.jobs(self.workflow("shell.yml"))["validate-python-minimum"]
        self.assertEqual(job.count("./tests/run-all.sh --full --jobs 4"), 1)
        capture = "YTDLP_PY310_FIRST_FAILURE"
        workflows = (PROJECT / ".github/workflows").glob("*.yml")
        self.assertEqual(sum(path.read_text().count(capture) for path in workflows), 1)
        self.assertIn("      - name: Exercise the complete contract under Python 3.10\n"
                      "        env:\n"
                      f"          {capture}: engine-cli-first-sample\n"
                      "        run: timeout ", job)
        self.assertIn("name: Python 3.10 / Ubuntu", job)
        for guard in (
            "${RUNNER_ENVIRONMENT} == github-hosted",
            "readonly version=4.4", "readonly fingerprint=7C0135FB088AAF6C66C650B9BB5869F064EA74AB",
            "${BASH_VERSINFO[2]} == 0", 'sudo ln -sfnT -- "${prefix}/bin/bash" /usr/bin/bash',
            "env PATH=/usr/bin:/bin bash", 'sudo ln -sfnT -- "${python_binary}" /usr/bin/python3',
            'printf \'%s\\n\' "${prefix}/bin" >>"${GITHUB_PATH}"',
        ):
            self.assertIn(guard, job)
        self.assertLess(job.index("sha256sum --check"), job.index("tar --extract"))
        self.assertLess(job.index('[[ ${signature_fingerprint} == "${fingerprint}" ]]'),
                        job.index("tar --extract"))
        self.assertLess(job.index("Confirm minimum Python and environment"),
                        job.index("./tests/run-all.sh --full --jobs 4"))
        self.assertIn("timeout --signal=TERM --kill-after=10s 8m", job)
        self.assertIn("timeout-minutes: 10", job)

    def test_fedora_suite_budget_preserves_workers_and_validation_status(self):
        job = self.jobs(self.workflow("shell.yml"))["validate-fedora"]
        self.assertEqual(re.findall(r"(?m)^    timeout-minutes: (\d+)$", job), ["10"])
        commands = re.findall(r"(?m)^      - name: Run validation\n        run: (.+)$", job)
        self.assertEqual(commands, [
            "timeout --signal=TERM --kill-after=10s 7m bash ./tests/run-all.sh --jobs 4",
        ])
        self.assertEqual(job.count("./tests/run-all.sh"), 1)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tests").mkdir()
            (root / "tests/run-all.sh").write_text(r'''
set -euo pipefail
[[ "$*" == '--jobs 4' ]] || exit 97
printf 'validation fixture started\n'
if [[ ${CHECK_EXPIRED} == 1 ]]; then
    while :; do :; done
fi
exit "${CHECK_VALIDATION_STATUS}"
''')
            for status, expired, expected in ((0, False, 0), (23, False, 23),
                                              (143, False, 143), (0, True, 124)):
                with self.subTest(status=status, expired=expired):
                    # Compress only the aggregate deadline; execute GNU timeout
                    # with the real TERM/KILL policy and command status handling.
                    command = commands[0].replace(" 7m ", " 0.05s ") if expired else commands[0]
                    result = subprocess.run(["bash", "-c", command], cwd=root,
                                            env=dict(os.environ, CHECK_EXPIRED=str(int(expired)),
                                                     CHECK_VALIDATION_STATUS=str(status)),
                                            capture_output=True, text=True, timeout=5, check=False)
                    self.assertEqual(result.stdout, "validation fixture started\n", result.stderr)
                    self.assertEqual(result.returncode, expected, result.stderr)

    def assert_shared_evidence_paths(self, retain, extra_paths=()):
        root = "${{ runner.temp }}/shared-destination-evidence/"
        expected = (
            "qualification.log",
            "shared-destination-real-*/*.log",
            "shared-destination-real-*/events.json",
            "shared-destination-real-*/qualification-errors.json",
            "shared-destination-real-*/*.before-rescue.json",
            "shared-destination-real-*/*.final-before-rescue.json",
        )
        paths = retain.split("          path: |\n", 1)[1].splitlines()
        self.assertCountEqual([path.strip() for path in paths if path.strip()],
                              [root + path for path in (*expected, *extra_paths)])

    def test_shared_destination_uses_one_verified_tool_entry_and_retains_only_diagnostics(self):
        job = self.jobs(self.workflow("real-tools.yml"))["pinned-local-media"]
        steps = re.split(r"(?m)^      - ", job)
        install = next(step for step in steps if step.startswith("name: Install verified Deno"))
        run = next(step for step in steps if step.startswith("name: Run real shared-destination"))
        retain = next(step for step in steps if step.startswith("name: Retain shared-destination"))
        for step in (install, run):
            self.assertIn("if: matrix.yt_dlp_version == '2026.8.19'", step)
        self.assertIn("always() && matrix.yt_dlp_version == '2026.8.19'", retain)
        self.assertIn("readonly version=2.9.4", install)
        self.assertIn("c24f955d9fbfe0ea5ae2b501c8e71ae76e31e4c9782390a54a284b3364fda725", install)
        self.assertLess(install.index("sha256sum --check"), install.index("unzip -q"))
        self.assertLess(install.index("sha256sum --check"), install.index('"${tool_dir}/deno" --version'))
        self.assertIn('export YTDLP_REAL_BINARY="${RUNNER_TEMP}/yt-dlp-venv/bin/yt-dlp"', run)
        self.assertIn("timeout --signal=TERM --kill-after=10s 8m", run)
        self.assertIn("./tests/repeat-qualification.sh --runs 1 --jobs 1", run)
        self.assertIn("python3 -B ./tests/multi-instance-real.py", run)
        self.assertIn("set -Eeuo pipefail", run)
        for field in ("HOME:", "XDG_CONFIG_HOME:", "XDG_STATE_HOME:", "XDG_DATA_HOME:"):
            self.assertNotIn(field, run)
        self.assertIn("if-no-files-found: error", retain)
        self.assertIn("github.sha", retain)
        self.assertIn("github.run_attempt", retain)
        self.assert_shared_evidence_paths(retain)

    def assert_current_stable_shared_contract(self, text):
        jobs = self.jobs(text)
        job = jobs["current-stable-local-media"]
        self.assertEqual(self.dependencies(job), {"identity"})
        self.assertEqual(re.findall(r"(?m)^    if: (.+)$", job),
                         ["github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"])
        self.assertEqual(re.findall(r"(?m)^    if: (.+)$", jobs["pinned-local-media"]),
                         ["github.event_name != 'schedule'"])
        self.assertIn("timeout-minutes: 65", job)
        steps = {step.splitlines()[0][6:]: step for step in re.split(r"(?m)^      - ", job)
                 if step.startswith("name: ")}
        self.assertEqual(set(steps), SCHEDULED_STEPS)
        for name, step in steps.items():
            if name.startswith("Retain "):
                self.assertIn("if: ${{ always() }}", step)
            else:
                self.assertNotRegex(step, r"(?m)^        if:")
        install = steps["Install real engines and current yt-dlp stable"]
        for required in ("--isolated --no-cache-dir install", "--index-url https://pypi.org/simple",
                         "--only-binary=:all:", '"yt-dlp[pin-curl-cffi]==${package_version}"',
                         "https://pypi.org/pypi/yt-dlp/json", "response.read(limit + 1)",
                         "timeout=30", "info['yanked'] is not False", "class NoRedirect", "curl", "unzip"):
            self.assertIn(required, install)
        for forbidden in ("--pre", "--trusted-host", "--no-deps", "--upgrade", "2026.8.19"):
            self.assertNotIn(forbidden, install)
        self.assertLess(install.index("package_version=$("), install.index("--isolated --no-cache-dir install"))
        self.assertIn('[[ ${installed} == "${package_version}" ]]', install)
        deno = steps["Install verified Deno for current-stable shared qualification"]
        for required in ("readonly version=2.9.8",
                         "readonly archive_sha=e890975bc2549807bbcc0b584ffafda72cc7c93349dd99c80483dd784f6c4609",
                         "https://github.com/denoland/deno/releases/download/v${version}/deno-x86_64-unknown-linux-gnu.zip",
                         "--proto '=https' --proto-redir '=https'", "--tlsv1.2",
                         "--connect-timeout 15 --max-time 120 --retry 3",
                         '[[ ${resolved} == "${version}" ]]'):
            self.assertIn(required, deno)
        self.assertLess(deno.index("sha256sum --check"), deno.index("unzip -q"))
        self.assertLess(deno.index("sha256sum --check"), deno.index('"${tool_dir}/deno" --version'))
        compatibility = steps["Validate current-stable shared prerequisites"]
        self.assertIn("requires('yt-dlp')", compatibility)
        self.assertIn("item.marker.evaluate({'extra': 'deno'})", compatibility)
        self.assertIn("version not in item.specifier", compatibility)
        self.assertIn("not applicable", compatibility)
        self.assertIn("raise SystemExit", compatibility)
        record = steps["Record resolved current-stable tool versions"]
        self.assertIn('>>"${GITHUB_ENV}"', record)
        self.assertIn('[[ ${resolved} =~', record)
        self.assertLess(record.index('[[ ${resolved} =~'), record.index('>>"${GITHUB_ENV}"'))
        self.assertIn("list --format=freeze", record)
        self.assertIn('[[ ${installed} == "${CURRENT_STABLE_YTDLP_PACKAGE_VERSION}" ]]', record)
        run = steps["Run current-stable shared-destination GUI and CLI qualification"]
        self.assertIn('export YTDLP_REAL_BINARY="${RUNNER_TEMP}/yt-dlp-venv/bin/yt-dlp"', run)
        self.assertIn('== "${CURRENT_STABLE_YTDLP_VERSION}" ]]', run)
        self.assertIn("timeout --signal=TERM --kill-after=10s 8m", run)
        self.assertIn("./tests/repeat-qualification.sh --runs 1 --jobs 1", run)
        self.assertEqual(run.count("python3 -B ./tests/multi-instance-real.py"), 1)
        self.assertIn("set -Eeuo pipefail", run)
        for prerequisite in ("Install verified Deno", "Validate current-stable shared prerequisites",
                             "Record resolved current-stable tool versions"):
            self.assertLess(job.index(prerequisite), job.index("Run current-stable shared-destination"))
        retain = steps["Retain current-stable shared-destination verdicts and monotonic events"]
        self.assertIn("if-no-files-found: error", retain)
        self.assertIn("name: shared-destination-current-stable-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}", retain)
        self.assert_shared_evidence_paths(retain, ("stable-resolution.json", "tool-versions.log"))

    def test_current_stable_requires_shared_fixture_and_its_resolved_prerequisites(self):
        self.assert_current_stable_shared_contract(self.workflow("real-tools.yml"))

    def test_current_stable_cannot_omit_skip_or_unbind_shared_qualification(self):
        text = self.workflow("real-tools.yml")
        for old, new in (
            ("if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'",
             "if: github.event_name != 'schedule'"),
            ("readonly version=2.9.8", "readonly version=2.9.4"),
            ("e890975bc2549807bbcc0b584ffafda72cc7c93349dd99c80483dd784f6c4609", "0" * 64),
            ("name: Run current-stable shared-destination GUI and CLI qualification\n",
             "name: Run current-stable shared-destination GUI and CLI qualification\n        if: false\n"),
            ('"yt-dlp[pin-curl-cffi]==${package_version}"', "--upgrade 'yt-dlp[pin-curl-cffi]'"),
            ('== "${CURRENT_STABLE_YTDLP_VERSION}" ]]', '== 2026.08.19 ]]'),
            ("version not in item.specifier", "False"),
            ("shared-destination-evidence/tool-versions.log", "shared-destination-evidence/private-seeds.json"),
            ("            ${{ runner.temp }}/shared-destination-evidence/shared-destination-real-*/qualification-errors.json\n", ""),
            ("shared-destination-real-*/qualification-errors.json", "shared-destination-real-*/*.json"),
        ):
            with self.subTest(mutation=old):
                self.assertIn(old, text)
                with self.assertRaises(AssertionError):
                    self.assert_current_stable_shared_contract(text.replace(old, new))

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
        self.assertIn("ref: ${{ github.sha }}", runtime)
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
            refs = re.findall(r"(?m)^          ref: (.+)$", job)
            self.assertEqual(refs, ["${{ github.sha }}"], name)
            self.assertIn("persist-credentials: false", job)
            if name != "validate":
                self.assertIn("validate", self.dependencies(job), name)

        verify = jobs["verify-source"]
        self.assertTrue({"validate", "zip", "rpm-test", "deb", "release-runtime"} <= self.dependencies(verify))
        proof = 'scripts/ci-validation.py verify --commit "${GITHUB_SHA}"'
        proof_guard = '[[ ${SOURCE_COMMIT} == "${GITHUB_SHA}" ]]'
        self.assertIn(proof, verify)
        self.assertIn(proof_guard, verify)
        self.assertLess(verify.index(proof_guard), verify.index(proof))
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
            ("needs: [validate, zip, rpm-test, deb, verify-source]", "needs: [validate, zip, rpm-test, deb]"),
            ("needs: [validate, zip, rpm-test, deb, release-runtime]", "needs: validate"),
            ('[[ ${current_tag_object} == "${SOURCE_TAG_OBJECT}" ]]', "true"),
            ('python3 -I scripts/ci-validation.py verify --commit "${GITHUB_SHA}"', "true"),
            ("name: Attest release artifacts", "name: Attest release artifacts\n        run: bash scripts/candidate.sh"),
        )
        for old, new in mutations:
            with self.subTest(mutation=old):
                self.assertIn(old, text)
                with self.assertRaises(AssertionError):
                    self.assert_release_identity_contract(text.replace(old, new, 1))

    def test_every_release_checkout_requires_the_direct_immutable_event_identity(self):
        text = self.workflow("release.yml")
        for name, job in self.jobs(text).items():
            if "uses: actions/checkout@" not in job:
                continue
            # Outputs can conceal a change of source from static trust analysis.
            # Even a currently equal output must remain proof data, not a ref.
            for source in ("steps.source.outputs.commit", "needs.validate.outputs.commit",
                           "env.RELEASE_TAG", "inputs.tag", "github.ref"):
                with self.subTest(job=name, source=source):
                    changed = job.replace("ref: ${{ github.sha }}", "ref: ${{ " + source + " }}", 1)
                    self.assertNotEqual(changed, job)
                    with self.assertRaises(AssertionError):
                        self.assert_release_identity_contract(text.replace(job, changed, 1))

    def test_final_source_proof_requires_the_event_commit(self):
        text = self.workflow("release.yml")
        job = self.jobs(text)["verify-source"]
        mutations = (
            ('[[ ${SOURCE_COMMIT} == "${GITHUB_SHA}" ]]', "true"),
            ('--commit "${GITHUB_SHA}"', '--commit "${SOURCE_COMMIT}"'),
        )
        for old, new in mutations:
            with self.subTest(mutation=old):
                self.assertIn(old, job)
                changed = job.replace(old, new, 1)
                with self.assertRaises(AssertionError):
                    self.assert_release_identity_contract(text.replace(job, changed, 1))

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

    def assert_required_stress_gate(self, text):
        jobs = self.jobs(text)
        gate = jobs["mock-stress-gate"]
        self.assertIn("scripts/ci-validation.py wait-required --commit", gate)
        self.assertIn("Mock process/cancellation stress (20x deterministic jitter)", gate)
        self.assertEqual(self.dependencies(gate), {"mock-stress", "runtime-hardening-stress"})
        self.assertIn("if: ${{ always() }}", gate)
        self.assertIn("if: github.event_name == 'pull_request'", gate)
        self.assertIn('EXPECTED_SHA: ${{ github.sha }}', gate)
        self.assertIn('${MOCK_STRESS_RESULT} != success', gate)
        self.assertIn('${RUNTIME_STRESS_RESULT} != success', gate)
        self.assertNotIn("package-cleanup-stress", jobs)
        self.assertIn('wait-required --commit "${EXPECTED_SHA}" --timeout-minutes 75', gate)
        gate_minutes = int(re.search(r"(?m)^    timeout-minutes: (\d+)$", gate).group(1))
        self.assertEqual(gate_minutes, 80)
        media_jobs = self.jobs(self.workflow("real-tools.yml"))
        maximum_job = max(int(re.search(r"(?m)^    timeout-minutes: (\d+)$", media_jobs[name]).group(1))
                          for name in ("pinned-local-media", "current-stable-local-media"))
        identity = int(re.search(r"(?m)^    timeout-minutes: (\d+)$", media_jobs["identity"]).group(1))
        self.assertGreaterEqual(75, maximum_job + identity + 5, "Reserve identity and runner queue margin")
        self.assertGreaterEqual(gate_minutes, 75 + 5, "Leave time for checkout and final API revalidation")

    def test_existing_required_stress_gate_waits_for_complementary_qualification(self):
        self.assert_required_stress_gate(self.workflow("stress.yml"))

    def test_parallel_graph_cannot_remove_or_skip_the_complete_final_gate(self):
        text = self.workflow("stress.yml")
        mutations = (
            ("      - runtime-hardening-stress\n", ""),
            ("if: ${{ always() }}", "if: false"),
            ("if: github.event_name == 'pull_request'", "if: false"),
            ("scripts/ci-validation.py wait-required --commit", "true"),
            ('${MOCK_STRESS_RESULT} != success', "false"),
            ('${RUNTIME_STRESS_RESULT} != success', "false"),
            (' --timeout-minutes 75', ''),
            (' --timeout-minutes 75', ' --timeout-minutes 45'),
            ('    timeout-minutes: 80', '    timeout-minutes: 50'),
        )
        for old, new in mutations:
            with self.subTest(mutation=old):
                self.assertIn(old, text)
                with self.assertRaises(AssertionError):
                    self.assert_required_stress_gate(text.replace(old, new, 1))


class WaitBudgetTests(unittest.TestCase):
    def test_wait_budget_rejects_invalid_values_before_external_reads(self):
        for value in ("0", "91", "100", "-1", "01", "+2", "1.5", "", "9" * 1000):
            with self.subTest(value=value), patch.object(CHECK.signal, "signal"), \
                    patch.object(CHECK, "GitHub") as api, \
                    patch.object(sys, "argv", ["ci-validation", "wait-required", "--commit", SOURCE,
                                               "--timeout-minutes", value]), \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    CHECK.main()
                self.assertEqual(raised.exception.code, 2)
                api.assert_not_called()
        for value in ("1", "45", "75", "90"):
            self.assertEqual(CHECK.wait_minutes(value), int(value))

    def test_wait_budget_cannot_change_promotion_or_schedule_verification(self):
        for command in ("verify", "verify-schedule"):
            with self.subTest(command=command), patch.object(CHECK.signal, "signal"), \
                    patch.object(CHECK, "GitHub") as api, \
                    patch.object(sys, "argv", ["ci-validation", command, "--commit", SOURCE,
                                               "--timeout-minutes", "75"]), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(CHECK.main(), 1)
                self.assertIn("only valid for required qualification waiting", errors.getvalue())
                api.assert_not_called()

    def test_default_wait_stays_45_minutes_and_explicit_75_accepts_later_proof(self):
        for explicit, accepted in ((False, False), (True, True)):
            clock = [0]
            calls = []

            def required(*_args):
                calls.append(clock[0])
                if len(calls) == 1:
                    clock[0] = 46 * 60
                    raise CHECK.Pending("incomplete fixture")
                return {"real-tools.yml": 400}

            arguments = ["ci-validation", "wait-required", "--commit", SOURCE]
            if explicit:
                arguments += ["--timeout-minutes", "75"]
            with self.subTest(explicit=explicit), patch.object(CHECK.signal, "signal"), \
                    patch.object(CHECK, "GitHub"), patch.object(CHECK, "event_pull", return_value={}), \
                    patch.object(CHECK, "Verifier") as verifier, patch.object(sys, "argv", arguments), \
                    patch.object(CHECK.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(CHECK.time, "sleep", side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                verifier.return_value.required.side_effect = required
                self.assertEqual(CHECK.main(), 0 if accepted else 1)
                self.assertEqual(len(calls), 2 if accepted else 1)
                self.assertEqual("qualification accepted" in output.getvalue(), accepted)
                if not accepted:
                    self.assertIn("within 45 minutes", errors.getvalue())

    def test_explicit_wait_still_expires_and_preserves_interruption(self):
        for interrupted in (False, True):
            clock = [0]
            with self.subTest(interrupted=interrupted), patch.object(CHECK.signal, "signal"), \
                    patch.object(CHECK, "GitHub"), patch.object(CHECK, "event_pull", return_value={}), \
                    patch.object(CHECK, "Verifier") as verifier, \
                    patch.object(sys, "argv", ["ci-validation", "wait-required", "--commit", SOURCE,
                                               "--timeout-minutes", "75"]), \
                    patch.object(CHECK.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(CHECK.time, "sleep", side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                verifier.return_value.required.side_effect = (CHECK.Interrupted(CHECK.signal.SIGTERM)
                                                               if interrupted else CHECK.Pending("incomplete fixture"))
                self.assertEqual(CHECK.main(), 143 if interrupted else 1)
                self.assertNotIn("qualification accepted", output.getvalue())
                if interrupted:
                    self.assertIn("interrupted; no proof was accepted", errors.getvalue())
                else:
                    self.assertEqual(clock[0], 75 * 60)
                    self.assertIn("within 75 minutes", errors.getvalue())


class UbuntuMirrorTests(unittest.TestCase):
    """Exercise the runner-specific change on files outside the host APT tree."""

    TARGETS = {
        "real-tools.yml": {"pinned-local-media", "current-stable-local-media"},
        "qualification.yml": {"ffmpeg-ubuntu-6", "ffmpeg-upstream"},
        "packages.yml": {"source-archive", "deb"},
        "release.yml": {"release-runtime", "zip", "deb"},
    }
    COMMAND = "sudo python3 -I -B scripts/ci-ubuntu-mirrors.py --setup"
    ORIGINAL = ("http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n"
                "https://archive.ubuntu.com/ubuntu/\tpriority:2\n"
                "https://security.ubuntu.com/ubuntu/\tpriority:3\n")
    SELECTED = ("https://archive.ubuntu.com/ubuntu/\tpriority:1\n"
                "https://security.ubuntu.com/ubuntu/\tpriority:2\n")
    SOURCE = ("# Hosted runner Ubuntu sources\nTypes: deb\n"
              "URIs: mirror+file:/etc/apt/apt-mirrors.txt\n"
              "Suites: noble noble-updates noble-backports\n"
              "Components: main universe restricted multiverse\n"
              "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\n"
              "Types: deb\nURIs: mirror+file:/etc/apt/apt-mirrors.txt\n"
              "Suites: noble-security\nComponents: main universe restricted multiverse\n"
              "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n")

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("ci_ubuntu_mirrors", PROJECT / "scripts/ci-ubuntu-mirrors.py")
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.apt = self.root / "apt"
        self.apt.mkdir(mode=0o755)
        self.sources = self.apt / "sources.list.d"
        self.sources.mkdir(mode=0o755)
        self.source = self.sources / "ubuntu.sources"
        self.source.write_text(self.SOURCE)
        self.source.chmod(0o640)
        self.mirrors = self.apt / "apt-mirrors.txt"
        self.mirrors.write_text(self.ORIGINAL)
        self.mirrors.chmod(0o644)
        self.external = self.sources / "external.list"
        self.external.write_text("external fixture retained byte for byte\n")

    def configure(self):
        return self.helper.configure(self.apt, os.geteuid())

    def assert_cli_refusal(self, category, *, owner=None, detail=None):
        """Exercise the real preparation with only its host APT path redirected."""
        configure = self.helper.configure
        fixture_owner = os.geteuid() if owner is None else owner
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", ["helper"]), \
                patch.object(self.helper.os, "geteuid", return_value=0), \
                patch.object(self.helper, "configure", side_effect=lambda _path, _owner:
                             configure(self.apt, fixture_owner)) as redirected, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(self.helper.main(), 65)
            redirected.assert_called_once_with("/etc/apt", 0)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(),
                         "Error: Ubuntu CI mirror preparation failed; package setup must stop.\n"
                         f"Category: {category}\n" + (f"{detail}\n" if detail is not None else ""))
        self.assertFalse(list(self.apt.glob(".apt-mirrors-*")))

    def assert_preserved(self):
        self.assertEqual(self.source.read_text(), self.SOURCE)
        self.assertEqual(self.source.stat().st_mode & 0o7777, 0o640)
        self.assertEqual(self.external.read_text(), "external fixture retained byte for byte\n")
        self.assertFalse(list(self.apt.glob(".apt-mirrors-*")))

    def test_exact_runner_list_selected_atomically_and_repeated_without_change(self):
        self.assertEqual(len(self.ORIGINAL.encode()), 144)
        before = self.mirrors.stat()
        self.assertTrue(self.configure())
        after = self.mirrors.stat()
        self.assertEqual(self.mirrors.read_text(), self.SELECTED)
        self.assertNotEqual(before.st_ino, after.st_ino)
        self.assertEqual((before.st_mode, before.st_uid, before.st_gid),
                         (after.st_mode, after.st_uid, after.st_gid))
        self.assertFalse(self.configure())
        self.assertEqual(self.mirrors.stat().st_ino, after.st_ino)
        self.assert_preserved()

    def test_unknown_or_weakened_mirrors_refused_before_change(self):
        for value in (self.ORIGINAL.replace("archive.ubuntu.com", "attacker.invalid", 1),
                      self.ORIGINAL.replace("https://archive", "http://archive"),
                      self.ORIGINAL.replace("priority:1", "priority:9"),
                      self.ORIGINAL.replace("priority:3", "priority:3 trusted=yes"),
                      self.ORIGINAL + "https://unknown.invalid/ priority:4\n",
                      self.ORIGINAL + self.ORIGINAL, "", "x" * 16385):
            with self.subTest(value=value[:60]):
                self.mirrors.write_text(value)
                with self.assertRaises(ValueError):
                    self.configure()
                self.assertEqual(self.mirrors.read_text(), value)
                self.assert_preserved()

    def test_unknown_sources_or_signature_configuration_refused_without_write(self):
        for value in (self.SOURCE.replace(self.helper.MIRROR_URI, "http://azure.archive.ubuntu.com/ubuntu/", 1),
                      self.SOURCE.replace(self.helper.KEYRING, "/tmp/untrusted.gpg", 1),
                      self.SOURCE.replace(f"Signed-By: {self.helper.KEYRING}\n", ""),
                      self.SOURCE + "Trusted: yes\n", self.SOURCE + "Allow-Insecure: yes\n",
                      self.SOURCE + "URIs: https://unknown.invalid/\n", "", "x" * 16385,
                      self.SOURCE.replace("Types: deb", " Types: deb", 1)):
            with self.subTest(value=value[:60]):
                self.source.write_text(value)
                with self.assertRaises(ValueError):
                    self.configure()
                self.assertEqual(self.source.read_text(), value)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                self.assertFalse(list(self.apt.glob(".apt-mirrors-*")))

    def test_symlinks_parent_links_hardlinks_and_fifo_refused_without_following(self):
        for path in (self.mirrors, self.source, self.sources, self.apt):
            with self.subTest(path=path.name):
                saved = path.with_name(path.name + ".saved")
                path.rename(saved)
                path.symlink_to(saved)
                try:
                    with self.assertRaises(OSError):
                        self.configure()
                finally:
                    path.unlink()
                    saved.rename(path)
        hardlink = self.root / "second-link"
        for path in (self.mirrors, self.source):
            with self.subTest(hardlink=path.name):
                os.link(path, hardlink)
                try:
                    with self.assertRaises(ValueError):
                        self.configure()
                finally:
                    hardlink.unlink()
        self.mirrors.unlink()
        os.mkfifo(self.mirrors, 0o600)
        with self.assertRaises(ValueError):
            self.configure()
        self.mirrors.unlink()
        self.mirrors.write_text(self.ORIGINAL)
        self.assert_preserved()

    def test_unowned_or_writable_configuration_refused(self):
        with self.assertRaises(ValueError):
            self.helper.configure(self.apt, os.geteuid() + 1)
        for path in (self.apt, self.sources, self.source, self.mirrors):
            with self.subTest(path=path.name):
                mode = path.stat().st_mode & 0o7777
                path.chmod(mode | 0o020)
                try:
                    with self.assertRaises(ValueError):
                        self.configure()
                finally:
                    path.chmod(mode)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_preserved()

    def test_changed_mirror_inode_or_source_refused_and_staging_removed(self):
        original_read = self.helper.read_file
        for mutation in ("mirror-inode", "source"):
            calls = []

            def read_file(*args):
                calls.append(args[1])
                if len(calls) == 3:
                    if mutation == "mirror-inode":
                        replacement = self.apt / "replacement"
                        replacement.write_text(self.ORIGINAL)
                        replacement.replace(self.mirrors)
                    else:
                        self.source.write_text(self.SOURCE + "# concurrent change\n")
                return original_read(*args)

            with self.subTest(mutation=mutation), patch.object(self.helper, "read_file", read_file):
                with self.assertRaises(self.helper.PreparationError) as caught:
                    self.configure()
                self.assertEqual(caught.exception.category, "concurrent-change")
            self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
            self.source.write_text(self.SOURCE)
            self.assert_preserved()

    def test_failed_atomic_replacement_preserves_original_and_cleans_temporary(self):
        with patch.object(self.helper.os, "replace", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                self.configure()
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_preserved()

    def test_cli_has_no_path_override_and_redacts_failed_configuration(self):
        for arguments, uid in ((["helper", "/tmp/override"], 0), (["helper"], 1000)):
            with patch.object(sys, "argv", arguments), patch.object(self.helper.os, "geteuid", return_value=uid), \
                    patch.object(self.helper, "configure") as configure, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(self.helper.main(), 64)
                configure.assert_not_called()
        output = io.StringIO()
        with patch.object(sys, "argv", ["helper"]), patch.object(self.helper.os, "geteuid", return_value=0), \
                patch.object(self.helper, "configure", side_effect=ValueError("secret-source-url")) as configure, \
                contextlib.redirect_stderr(output):
            self.assertEqual(self.helper.main(), 65)
            configure.assert_called_once_with("/etc/apt", 0)
        self.assertNotIn("secret-source-url", output.getvalue())

    def test_cli_source_diagnostics_preserve_rejected_bytes(self):
        cases = (
            (b"", "source-syntax"),
            (b"private malformed configuration", "source-syntax"),
            (self.SOURCE.replace(self.helper.MIRROR_URI, "https://private.invalid/secret").encode(),
             "source-uri"),
            (self.SOURCE.replace(f"Signed-By: {self.helper.KEYRING}\n", "").encode(),
             "source-signature"),
            (self.SOURCE.replace(self.helper.KEYRING, "/private/secret.gpg").encode(),
             "source-signature"),
            ((self.SOURCE + "Trusted: yes\n").encode(), "source-fields"),
            (self.SOURCE.replace("Types: deb", "Types: private").encode(), "source-fields"),
            (b"x" * 16385, "size-limit"),
            (b"\xffprivate-non-ascii-configuration", "unrecognized-configuration"),
        )
        for source, category in cases:
            with self.subTest(category=category):
                self.source.write_bytes(source)
                before = [(path.stat().st_ino, path.stat().st_mtime_ns, path.stat().st_mode)
                          for path in (self.source, self.mirrors)]
                self.assert_cli_refusal(category, detail=(
                    "Source URI shape: other; stanza: 1/2" if category == "source-uri" else None))
                self.assertEqual(self.source.read_bytes(), source)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                self.assertEqual([(path.stat().st_ino, path.stat().st_mtime_ns, path.stat().st_mode)
                                  for path in (self.source, self.mirrors)], before)

    def test_cli_reports_first_rejection_without_inspecting_later_faults(self):
        self.source.write_text("broken source without a separator\n", encoding="utf-8")
        self.mirrors.write_text("https://private.invalid/secret priority:1\n", encoding="utf-8")
        original_read = self.helper.read_file
        self.apt.chmod(0o775)
        try:
            with patch.object(self.helper, "read_file", wraps=original_read) as read:
                self.assert_cli_refusal("owner", owner=os.geteuid() + 1)
                read.assert_not_called()
                self.assert_cli_refusal("permissions")
                read.assert_not_called()
        finally:
            self.apt.chmod(0o755)
        with patch.object(self.helper, "read_file", wraps=original_read) as read:
            self.assert_cli_refusal("source-syntax")
            self.assertEqual([call.args[1] for call in read.call_args_list], ["ubuntu.sources"])
        self.source.write_text(self.SOURCE, encoding="utf-8")
        with patch.object(self.helper, "read_file", wraps=original_read) as read:
            self.assert_cli_refusal("mirror-list", detail=(
                "Mirror list profile: historical-indirect; entries: 1; entry-shapes: other/priority-1"))
            self.assertEqual([call.args[1] for call in read.call_args_list],
                             ["ubuntu.sources", "apt-mirrors.txt"])
        self.assertEqual(self.mirrors.read_text(), "https://private.invalid/secret priority:1\n")
        self.assert_preserved()

    def test_uri_shape_exact_values_remain_refusals_without_extra_reads(self):
        cases = (
            (None, "missing"), ("", "empty"),
            ("https://archive.ubuntu.com/ubuntu/", "https-archive"),
            ("https://security.ubuntu.com/ubuntu/", "https-security"),
            ("http://azure.archive.ubuntu.com/ubuntu/", "http-azure"),
            ("http://azure.archive.ubuntu.com/ubuntu", "http-azure-no-slash"),
            ("http://archive.ubuntu.com/ubuntu/", "http-archive"),
            ("http://archive.ubuntu.com/ubuntu", "http-archive-no-slash"),
            ("http://security.ubuntu.com/ubuntu/", "http-security"),
            ("http://security.ubuntu.com/ubuntu", "http-security-no-slash"),
        )
        original_read = self.helper.read_file
        for value, shape in cases:
            with self.subTest(shape=shape):
                line = f"URIs: {self.helper.MIRROR_URI}\n"
                source = self.SOURCE.replace(line, "" if value is None else f"URIs: {value}\n", 1)
                self.source.write_text(source, encoding="ascii")
                before = [(path.stat().st_ino, path.stat().st_mtime_ns, path.stat().st_mode)
                          for path in (self.source, self.mirrors)]
                with patch.object(self.helper, "read_file", wraps=original_read) as read:
                    self.assert_cli_refusal("source-uri", detail=f"Source URI shape: {shape}; stanza: 1/2")
                    self.assertEqual([call.args[1] for call in read.call_args_list], ["ubuntu.sources"])
                self.assertEqual(self.source.read_text(encoding="ascii"), source)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                self.assertEqual([(path.stat().st_ino, path.stat().st_mtime_ns, path.stat().st_mode)
                                  for path in (self.source, self.mirrors)], before)
        self.assertEqual(self.helper.source_uri_shape(self.helper.MIRROR_URI), "expected-mirror-file")

    def test_uri_shape_does_not_normalize_or_export_unknown_values(self):
        values = (
            "https://archive.ubuntu.com.attacker.invalid/ubuntu/",
            "https://archive.ubuntu.com@attacker.invalid/ubuntu/",
            "https://secret@archive.ubuntu.com/ubuntu/",
            "https://archive.ubuntu.com/ubuntu/?token=private",
            "https://archive.ubuntu.com/ubuntu/#private",
            "https://archive.ubuntu.com/private/", "https://archive.ubuntu.com/ubuntu",
            "HTTPS://archive.ubuntu.com/ubuntu/", "https://archive.ubuntu.com:443/ubuntu/",
            "https://archive.ubuntu.com./ubuntu/", "http://private.invalid/secret",
            "file:/private/secret", "mirror+file:/private/secret",
            "https://archive.ubuntu.com/ubuntu/ https://security.ubuntu.com/ubuntu/",
            "https://security.ubuntu.com/ubuntu/ https://archive.ubuntu.com/ubuntu/",
            f"{self.helper.MIRROR_URI} {self.helper.MIRROR_URI}",
            "private\x1b[31msecret", "private\x00secret",
        )
        for value in values:
            with self.subTest(case=values.index(value)):
                source = self.SOURCE.replace(self.helper.MIRROR_URI, value, 1)
                self.source.write_text(source, encoding="ascii")
                self.assert_cli_refusal("source-uri", detail="Source URI shape: other; stanza: 1/2")
                self.assertEqual(self.source.read_text(encoding="ascii"), source)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)

    def test_uri_diagnostic_preserves_stanza_order_and_first_guard(self):
        first, second = self.SOURCE.strip().split("\n\n")
        bad = second.replace(self.helper.MIRROR_URI, "https://security.ubuntu.com/ubuntu/")
        cases = (
            (first + "\n\n" + bad, "source-uri", "Source URI shape: https-security; stanza: 2/2"),
            (self.SOURCE + "\n" + bad, "source-uri", "Source URI shape: https-security; stanza: 3/3"),
            (bad + "\n\n" + first, "source-uri", "Source URI shape: https-security; stanza: 1/2"),
            (bad.replace(self.helper.KEYRING, "private") + "\n\n" + first,
             "source-uri", "Source URI shape: https-security; stanza: 1/2"),
            (first.replace(self.helper.KEYRING, "private") + "\n\n" + bad, "source-signature", None),
            (first.replace(f"Signed-By: {self.helper.KEYRING}", "") + "\n\n" + bad,
             "source-signature", None),
            (first + "\nTrusted: yes\n\n" + bad, "source-fields", None),
            (bad + "\n\nbroken syntax", "source-syntax", None),
            (bad + "\nURIs: private", "source-syntax", None),
        )
        for source, category, detail in cases:
            with self.subTest(category=category, detail=detail):
                self.source.write_text(source, encoding="ascii")
                self.assert_cli_refusal(category, detail=detail)
                self.assertEqual(self.source.read_text(encoding="ascii"), source)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)

    def test_uri_detail_rendering_is_closed_and_bounded(self):
        class Hostile(str):
            def __eq__(self, _other):
                raise AssertionError("unexpected comparison of untrusted detail")

        for detail in (None, "private", [], ("private", 1, 2),
                       (Hostile("other"), 1, 2), ("other", True, 2),
                       ("other", 0, 2), ("other", 3, 2), ("other", 1, 16385),
                       ("other", "private", 2), ("other", 1), ("other", 1, 2, "private")):
            with self.subTest(case=type(detail).__name__):
                error = self.helper.PreparationError("source-uri", source_uri_detail=detail)
                self.assertIsNone(self.helper.source_uri_diagnostic(error))
                with patch.object(sys, "argv", ["helper"]), \
                        patch.object(self.helper.os, "geteuid", return_value=0), \
                        patch.object(self.helper, "configure", side_effect=error), \
                        contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(self.helper.main(), 65)
                self.assertEqual(errors.getvalue(),
                                 "Error: Ubuntu CI mirror preparation failed; package setup must stop.\n"
                                 "Category: source-uri\n")
        self.assertIsNone(self.helper.source_uri_diagnostic(self.helper.PreparationError(
            "source-signature", source_uri_detail=("other", 1, 2))))

    def test_uri_diagnostic_does_not_reread_a_replaced_source(self):
        source = self.SOURCE.replace(self.helper.MIRROR_URI, "https://security.ubuntu.com/ubuntu/", 1)
        self.source.write_text(source, encoding="ascii")
        original_read = self.helper.read_file
        calls = []

        def read_file(*args):
            calls.append(args[1])
            data, metadata = original_read(*args)
            replacement = self.sources / "replacement"
            replacement.write_text(self.SOURCE, encoding="ascii")
            replacement.replace(self.source)
            return data, metadata

        with patch.object(self.helper, "read_file", read_file):
            self.assert_cli_refusal("source-uri", detail="Source URI shape: https-security; stanza: 1/2")
        self.assertEqual(calls, ["ubuntu.sources"])
        self.assertEqual(self.source.read_text(), self.SOURCE)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)

    def test_uri_diagnostic_success_remains_silent_and_idempotent(self):
        configure = self.helper.configure
        for message in ("selected.", "already selected."):
            with patch.object(sys, "argv", ["helper"]), \
                    patch.object(self.helper.os, "geteuid", return_value=0), \
                    patch.object(self.helper, "configure", side_effect=lambda _path, _owner:
                                 configure(self.apt, os.stat(self.apt).st_uid)), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(self.helper.main(), 0)
            self.assertEqual(errors.getvalue(), "")
            self.assertEqual(output.getvalue(), f"Ubuntu CI mirrors: official HTTPS archives {message}\n")
        self.assert_preserved()

    def test_cli_metadata_categories_keep_configuration_unchanged(self):
        for path in (self.apt, self.sources, self.source, self.mirrors):
            with self.subTest(path=path.name):
                mode = path.stat().st_mode & 0o7777
                path.chmod(mode | 0o020)
                try:
                    self.assert_cli_refusal("permissions")
                finally:
                    path.chmod(mode)
        for path in (self.source, self.mirrors):
            with self.subTest(hardlink=path.name):
                linked = self.root / "second-link"
                os.link(path, linked)
                try:
                    self.assert_cli_refusal("file-links")
                finally:
                    linked.unlink()
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_preserved()

    def test_cli_missing_symlink_and_nonregular_configuration_are_distinct(self):
        self.source.rename(self.sources / "source.saved")
        saved = self.sources / "source.saved"
        try:
            self.assert_cli_refusal("missing-file")
            self.source.symlink_to(saved)
            try:
                self.assert_cli_refusal("path-type")
            finally:
                self.source.unlink()
            os.mkfifo(self.source, 0o600)
            try:
                self.assert_cli_refusal("file-type")
            finally:
                self.source.unlink()
        finally:
            saved.rename(self.source)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_preserved()

    def test_cli_io_and_unknown_errors_never_expose_exception_details(self):
        class HostileCategory(str):
            def __eq__(self, _other):
                raise AssertionError("untrusted category must not be compared")

        cases = [
            (OSError(errno.ENOENT, "private reason", "/private/path"), "missing-file"),
            (OSError(errno.EACCES, "private reason", "/private/path"), "access-denied"),
            (OSError(errno.EPERM, "private reason", "/private/path"), "access-denied"),
            (OSError(errno.EIO, "private reason", "/private/path"), "io-error"),
            (OSError(errno.ELOOP, "private reason", "/private/path"), "path-type"),
            (OSError(errno.ENOTDIR, "private reason", "/private/path"), "path-type"),
            (OSError("private reason"), "io-error"),
            (ValueError("https://private.invalid/secret\nCategory: success"), "unrecognized-configuration"),
            (self.helper.PreparationError("private\nCategory: success"), "unrecognized-configuration"),
            (self.helper.PreparationError(HostileCategory("owner")), "unrecognized-configuration"),
            (self.helper.PreparationError({"private": "value"}), "unrecognized-configuration"),
        ]
        for error, category in cases:
            with self.subTest(category=category):
                output, errors = io.StringIO(), io.StringIO()
                with patch.object(sys, "argv", ["helper"]), \
                        patch.object(self.helper.os, "geteuid", return_value=0), \
                        patch.object(self.helper, "configure", side_effect=error), \
                        contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    self.assertEqual(self.helper.main(), 65)
                self.assertEqual(output.getvalue(), "")
                self.assertEqual(errors.getvalue(),
                                 "Error: Ubuntu CI mirror preparation failed; package setup must stop.\n"
                                 f"Category: {category}\n")
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_preserved()

    @staticmethod
    def apt_stat_identity(metadata):
        # Reading can legitimately update atime; it is not a mutation guard.
        return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_uid,
                metadata.st_gid, metadata.st_nlink, metadata.st_size,
                metadata.st_mtime_ns, metadata.st_ctime_ns)

    def mixed_source(self):
        first, second = self.SOURCE.split("\n\n", 1)
        return first + "\n\n" + second.replace(
            "mirror+file:/etc/apt/apt-mirrors.txt", "http://security.ubuntu.com/ubuntu", 1)

    def normalized_source(self, source):
        return source.replace("URIs: mirror+file:/etc/apt/apt-mirrors.txt",
                              "URIs: https://archive.ubuntu.com/ubuntu/", 1).replace(
                                  "URIs: http://security.ubuntu.com/ubuntu",
                                  "URIs: https://security.ubuntu.com/ubuntu/", 1)

    def assert_no_apt_staging(self):
        self.assertFalse(list(self.apt.glob(".apt-mirrors-*")))
        self.assertFalse(list(self.sources.glob(".apt-mirrors-*")))

    def test_mixed_exact_layout_changes_only_source_and_is_idempotent(self):
        for types in ("deb", "deb deb-src"):
            for mirrors in (self.ORIGINAL, self.SELECTED):
                with self.subTest(types=types, mirrors_selected=mirrors == self.SELECTED):
                    source = self.mixed_source().replace("Types: deb\n", f"Types: {types}\n")
                    self.source.write_text(source, encoding="ascii")
                    self.mirrors.write_text(mirrors, encoding="ascii")
                    source_before, mirror_before = self.source.stat(), self.mirrors.stat()
                    self.assertEqual(self.configure(), "direct-selected")
                    source_after = self.source.stat()
                    self.assertEqual(self.source.read_text(encoding="ascii"), self.normalized_source(source))
                    self.assertNotEqual(source_before.st_ino, source_after.st_ino)
                    self.assertEqual((source_after.st_uid, source_after.st_gid, source_after.st_mode),
                                     (source_before.st_uid, source_before.st_gid, source_before.st_mode))
                    self.assertEqual(self.mirrors.read_text(encoding="ascii"), mirrors)
                    self.assertEqual(self.apt_stat_identity(self.mirrors.stat()), self.apt_stat_identity(mirror_before))
                    self.assertEqual(self.configure(), "direct-current")
                    self.assertEqual(self.apt_stat_identity(self.source.stat()), self.apt_stat_identity(source_after))
                    self.assertEqual(self.apt_stat_identity(self.mirrors.stat()), self.apt_stat_identity(mirror_before))
                    self.assertEqual(self.external.read_text(), "external fixture retained byte for byte\n")
                    self.assert_no_apt_staging()

    def test_mixed_preserves_comments_components_order_and_line_endings(self):
        source = (self.mixed_source().replace("main universe restricted multiverse",
                                             "multiverse restricted main universe")
                  .replace("\n\n", "\n\n# private fixture comment retained\n")
                  .replace("\n", "\r\n"))
        self.source.write_bytes(source.encode("ascii"))
        self.assertEqual(self.configure(), "direct-selected")
        self.assertEqual(self.source.read_bytes(), self.normalized_source(source).encode("ascii"))
        self.assertEqual(self.configure(), "direct-current")
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_and_direct_require_every_field_in_both_stanzas(self):
        replacements = (
            ("Types: deb", "Types: deb-src", "source-fields"),
            ("Types: deb", "Types: deb deb", "source-fields"),
            ("Types: deb", "Types: deb deb-src extra", "source-fields"),
            ("Components: main universe restricted multiverse", "Components: main universe restricted", "source-fields"),
            ("Components: main universe restricted multiverse", "Components: main main universe restricted multiverse", "source-fields"),
            ("Components: main universe restricted multiverse", "Components: main universe restricted private", "source-fields"),
            ("Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg",
             "Signed-By: /tmp/private.gpg", "source-signature"),
            ("Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg", "", "source-signature"),
        )
        for direct in (False, True):
            baseline = self.normalized_source(self.mixed_source()) if direct else self.mixed_source()
            first, second = baseline.strip().split("\n\n")
            for index in (0, 1):
                for old, new, category in replacements:
                    with self.subTest(direct=direct, stanza=index, category=category, field=old.split(":")[0]):
                        stanzas = [first, second]
                        stanzas[index] = stanzas[index].replace(old, new)
                        source = "\n\n".join(stanzas) + "\n"
                        self.source.write_text(source, encoding="ascii")
                        self.assert_cli_refusal(category)
                        self.assertEqual(self.source.read_text(encoding="ascii"), source)
                        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                        self.assert_no_apt_staging()
                for extra in ("Trusted: yes", "Allow-Insecure: yes", "Enabled: no", "Private: value"):
                    with self.subTest(direct=direct, stanza=index, extra=extra.split(":")[0]):
                        stanzas = [first, second]
                        stanzas[index] += "\n" + extra
                        source = "\n\n".join(stanzas) + "\n"
                        self.source.write_text(source, encoding="ascii")
                        self.assert_cli_refusal("source-fields")
                        self.assertEqual(self.source.read_text(encoding="ascii"), source)
                        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                        self.assert_no_apt_staging()

    def test_mixed_and_direct_require_noble_suites_and_stanza_order(self):
        for direct in (False, True):
            source = self.normalized_source(self.mixed_source()) if direct else self.mixed_source()
            cases = (
                source.replace("noble noble-updates noble-backports", "noble-updates noble noble-backports"),
                source.replace("noble noble-updates noble-backports", "noble noble-updates"),
                source.replace("noble noble-updates noble-backports", "noble noble-updates noble-backports noble-security"),
                source.replace("noble-security", "noble-updates"),
                source.replace("noble-security", "noble-security noble-security"),
                source.replace("noble", "jammy"),
                source.replace("Suites: noble-security", "Suites:"),
            )
            for number, bad in enumerate(cases):
                with self.subTest(direct=direct, case=number):
                    self.source.write_text(bad, encoding="ascii")
                    self.assert_cli_refusal("source-fields")
                    self.assertEqual(self.source.read_text(encoding="ascii"), bad)
                    self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
            first, second = source.strip().split("\n\n")
            layouts = [second + "\n\n" + first, source + "\n" + second]
            if direct:
                layouts.append(first + "\n")
            for bad in layouts:
                with self.subTest(direct=direct, layout=bad.count("Types:")):
                    self.source.write_text(bad, encoding="ascii")
                    with self.assertRaises(self.helper.PreparationError):
                        self.configure()
                    self.assertEqual(self.source.read_text(encoding="ascii"), bad)
                    self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                    self.assert_no_apt_staging()

    def test_mixed_rejects_uri_variants_without_broadening_endpoints(self):
        original = self.mixed_source()
        uris = (
            "http://security.ubuntu.com/ubuntu/",
            "https://security.ubuntu.com/ubuntu/",
            "http://security.ubuntu.com:80/ubuntu",
            "http://security.ubuntu.com./ubuntu",
            "http://security.ubuntu.com.attacker.invalid/ubuntu",
            "http://security.ubuntu.com@attacker.invalid/ubuntu",
            "http://secret@security.ubuntu.com/ubuntu",
            "http://security.ubuntu.com/ubuntu?token=private",
            "http://security.ubuntu.com/private",
            "HTTP://security.ubuntu.com/ubuntu",
            "http://security.ubuntu.com/ubuntu http://security.ubuntu.com/ubuntu",
        )
        for number, uri in enumerate(uris):
            with self.subTest(case=number):
                source = original.replace("http://security.ubuntu.com/ubuntu", uri)
                self.source.write_text(source, encoding="ascii")
                with self.assertRaises(self.helper.PreparationError) as caught:
                    self.configure()
                self.assertEqual(caught.exception.category, "source-uri")
                self.assertEqual(self.source.read_text(encoding="ascii"), source)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                self.assert_no_apt_staging()

    def test_mixed_cli_reports_direct_preparation_and_idempotence(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        configure = self.helper.configure
        owner = os.geteuid()
        for message in ("selected.", "already selected."):
            with patch.object(sys, "argv", ["helper"]), \
                    patch.object(self.helper.os, "geteuid", return_value=0), \
                    patch.object(self.helper, "configure", side_effect=lambda _path, _owner:
                                 configure(self.apt, owner)), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(self.helper.main(), 0)
            self.assertEqual(errors.getvalue(), "")
            self.assertEqual(output.getvalue(), f"Ubuntu CI sources: official HTTPS archive/security {message}\n")
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_requires_safe_source_mirror_and_directory_properties(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        for path in (self.apt, self.sources, self.source, self.mirrors):
            with self.subTest(permissions=path.name):
                mode = path.stat().st_mode & 0o7777
                path.chmod(mode | 0o020)
                try:
                    self.assert_cli_refusal("permissions")
                finally:
                    path.chmod(mode)
            with self.subTest(symlink=path.name):
                saved = path.with_name(path.name + ".saved")
                path.rename(saved)
                path.symlink_to(saved)
                try:
                    with self.assertRaises(OSError):
                        self.configure()
                finally:
                    path.unlink()
                    saved.rename(path)
        for path in (self.source, self.mirrors):
            with self.subTest(hardlink=path.name):
                linked = self.root / "link"
                os.link(path, linked)
                try:
                    self.assert_cli_refusal("file-links")
                finally:
                    linked.unlink()
        with self.assertRaises(self.helper.PreparationError):
            self.helper.configure(self.apt, os.geteuid() + 1)
        self.assertEqual(self.source.read_text(), self.mixed_source())
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_still_validates_unused_mirror_list(self):
        for source in (self.mixed_source(), self.normalized_source(self.mixed_source())):
            for mirrors, shapes in (
                    (self.ORIGINAL.replace("archive.ubuntu.com", "private.invalid", 1),
                     "other/priority-1,https-archive/priority-2,https-security/priority-3"),
                    (self.ORIGINAL.replace("https://archive", "http://archive"),
                     "http-azure/priority-1,http-archive/priority-2,https-security/priority-3"),
                    ("", "empty")):
                with self.subTest(direct="https://archive.ubuntu.com/ubuntu/" in source, empty=not mirrors):
                    self.source.write_text(source, encoding="ascii")
                    self.mirrors.write_text(mirrors, encoding="ascii")
                    profile = "direct" if "https://archive.ubuntu.com/ubuntu/" in source else "mixed"
                    self.assert_cli_refusal("mirror-list", detail=(
                        f"Mirror list profile: {profile}; entries: {3 if mirrors else 0}; entry-shapes: {shapes}"))
                    self.assertEqual(self.source.read_text(), source)
                    self.assertEqual(self.mirrors.read_text(), mirrors)
                    self.assert_no_apt_staging()

    def test_mixed_complete_read_handles_short_chunks_and_rejects_truncation(self):
        mixed = self.mixed_source().encode("ascii")
        self.source.write_bytes(mixed)
        real_read = self.helper.os.read
        calls = []

        def short_read(fd, limit):
            calls.append(limit)
            return real_read(fd, min(limit, 11))

        with patch.object(self.helper.os, "read", short_read):
            self.assertEqual(self.configure(), "direct-selected")
        self.assertGreater(len(calls), 30)
        self.assertEqual(self.source.read_text(), self.normalized_source(self.mixed_source()))
        hidden = mixed + b"\nTypes: deb\nURIs: https://private.invalid/secret\n"
        self.source.write_bytes(hidden)
        source_inode = self.source.stat().st_ino
        delivered = [False]

        def truncated_read(fd, limit):
            if os.fstat(fd).st_ino == source_inode:
                if delivered[0]:
                    return b""
                delivered[0] = True
                return real_read(fd, min(limit, len(mixed)))
            return real_read(fd, limit)

        with patch.object(self.helper.os, "read", truncated_read):
            self.assert_cli_refusal("concurrent-change")
        self.assertEqual(self.source.read_bytes(), hidden)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_rejects_growth_during_source_read(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        source_inode = self.source.stat().st_ino
        real_read = self.helper.os.read
        changed = [False]
        suffix = b"\nTypes: deb\nURIs: https://private.invalid/secret\n"

        def growing_read(fd, limit):
            data = real_read(fd, limit)
            if not changed[0] and os.fstat(fd).st_ino == source_inode:
                changed[0] = True
                with self.source.open("ab") as stream:
                    stream.write(suffix)
            return data

        with patch.object(self.helper.os, "read", growing_read):
            self.assert_cli_refusal("concurrent-change")
        self.assertEqual(self.source.read_bytes(), self.mixed_source().encode("ascii") + suffix)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_source_changes_before_commit_refuse_without_overwriting_writer(self):
        real_read = self.helper.read_file
        for mutation in ("inode", "bytes", "mode"):
            mixed = self.mixed_source()
            self.source.write_text(mixed, encoding="ascii")
            self.source.chmod(0o640)
            calls = []

            def read_file(*args):
                calls.append(args[1])
                if len(calls) == 3:
                    if mutation == "inode":
                        replacement = self.sources / "replacement"
                        replacement.write_text(mixed, encoding="ascii")
                        replacement.chmod(0o640)
                        replacement.replace(self.source)
                    elif mutation == "bytes":
                        self.source.write_text(mixed + "# cloud-init update\n", encoding="ascii")
                    else:
                        self.source.chmod(0o600)
                return real_read(*args)

            with self.subTest(mutation=mutation), patch.object(self.helper, "read_file", read_file):
                self.assert_cli_refusal("concurrent-change")
            self.assertEqual(self.source.read_text(), mixed + ("# cloud-init update\n" if mutation == "bytes" else ""))
            self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
            self.assert_no_apt_staging()

    def test_mixed_idempotent_path_revalidates_source_and_mirrors(self):
        source = self.normalized_source(self.mixed_source())
        real_read = self.helper.read_file
        for target in ("source", "mirrors"):
            self.source.write_text(source, encoding="ascii")
            self.mirrors.write_text(self.ORIGINAL, encoding="ascii")
            calls = []

            def read_file(*args):
                calls.append(args[1])
                if len(calls) == 3:
                    path = self.source if target == "source" else self.mirrors
                    replacement = path.with_name("replacement")
                    replacement.write_bytes(path.read_bytes())
                    replacement.chmod(path.stat().st_mode & 0o7777)
                    replacement.replace(path)
                return real_read(*args)

            with self.subTest(target=target), patch.object(self.helper, "read_file", read_file):
                self.assert_cli_refusal("concurrent-change")
            self.assertEqual(self.source.read_text(), source)
            self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
            self.assert_no_apt_staging()

    def test_mixed_changed_directory_refuses_detached_preparation(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        original_fsync = self.helper.os.fsync
        moved = self.apt / "sources.saved"
        replaced = [False]

        def fsync(fd):
            original_fsync(fd)
            if not replaced[0]:
                replaced[0] = True
                self.sources.rename(moved)
                self.sources.mkdir(mode=0o755)
                self.source.write_text(self.SOURCE, encoding="ascii")

        with patch.object(self.helper.os, "fsync", fsync):
            self.assert_cli_refusal("concurrent-change")
        self.assertEqual(self.source.read_text(), self.SOURCE)
        self.assertEqual((moved / "ubuntu.sources").read_text(), self.mixed_source())
        self.assertFalse(list(moved.glob(".apt-mirrors-*")))
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_fsync_failure_preserves_precommit_or_reports_committed_state(self):
        original_fsync = self.helper.os.fsync
        for failure in (1, 2):
            mixed = self.mixed_source()
            self.source.write_text(mixed, encoding="ascii")
            before = self.source.stat()
            mirror_before = self.mirrors.stat()
            calls = []

            def fsync(fd):
                calls.append(fd)
                if len(calls) == failure:
                    raise OSError(errno.EIO, "private durability failure")
                return original_fsync(fd)

            with self.subTest(fsync_call=failure), patch.object(self.helper.os, "fsync", fsync):
                self.assert_cli_refusal("io-error")
            self.assertEqual(len(calls), failure)
            self.assertEqual(self.source.read_text(), mixed if failure == 1 else self.normalized_source(mixed))
            self.assertEqual(self.source.stat().st_ino == before.st_ino, failure == 1)
            self.assertEqual(self.apt_stat_identity(self.mirrors.stat()), self.apt_stat_identity(mirror_before))
            self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
            self.assert_no_apt_staging()

    def test_mixed_interruption_before_commit_preserves_original_and_cleans_staging(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        before = self.source.stat()
        with patch.object(self.helper.os, "fsync", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.configure()
        self.assertEqual(self.source.read_text(), self.mixed_source())
        self.assertEqual(self.apt_stat_identity(self.source.stat()), self.apt_stat_identity(before))
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_failed_replace_and_short_write_never_commit(self):
        mixed = self.mixed_source()
        self.source.write_text(mixed, encoding="ascii")
        before = self.source.stat()
        real_fdopen = self.helper.os.fdopen

        class ShortWriter:
            def __init__(self, fd, mode):
                self.stream = real_fdopen(fd, mode)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return self.stream.__exit__(*args)

            def __getattr__(self, name):
                return getattr(self.stream, name)

            def write(self, data):
                return self.stream.write(data[:-1])

        with patch.object(self.helper.os, "fdopen", ShortWriter):
            self.assert_cli_refusal("io-error")
        self.assertEqual(self.apt_stat_identity(self.source.stat()), self.apt_stat_identity(before))
        with patch.object(self.helper.os, "replace", side_effect=OSError(errno.EIO, "private replacement failure")):
            self.assert_cli_refusal("io-error")
        self.assertEqual(self.apt_stat_identity(self.source.stat()), self.apt_stat_identity(before))
        self.assertEqual(self.source.read_text(), mixed)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_postcommit_cloud_init_changes_stay_failures_without_rollback(self):
        real_replace = self.helper.os.replace
        mixed = self.mixed_source()
        for target in ("source", "mirrors"):
            self.source.write_text(mixed, encoding="ascii")
            self.mirrors.write_text(self.ORIGINAL, encoding="ascii")

            def replace(*args, **kwargs):
                real_replace(*args, **kwargs)
                if target == "source":
                    self.source.write_text(mixed + "# cloud-init writer\n", encoding="ascii")
                else:
                    self.mirrors.write_text(self.ORIGINAL + "# cloud-init writer\n", encoding="ascii")

            with self.subTest(target=target), patch.object(self.helper.os, "replace", replace):
                self.assert_cli_refusal("concurrent-change")
            self.assertEqual(self.source.read_text(), mixed + "# cloud-init writer\n"
                             if target == "source" else self.normalized_source(mixed))
            self.assertEqual(self.mirrors.read_text(), self.ORIGINAL + ("# cloud-init writer\n"
                                                                      if target == "mirrors" else ""))
            self.assert_no_apt_staging()

    def test_mixed_control_bytes_cannot_create_an_alternate_source_parse(self):
        for value in (*range(9), 11, 12, *range(14, 32), 127):
            with self.subTest(control=value):
                source = self.mixed_source().encode("ascii") + b"# fixture" + bytes([value]) + b"\n"
                self.source.write_bytes(source)
                self.assert_cli_refusal("source-syntax")
                self.assertEqual(self.source.read_bytes(), source)
                self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
                self.assert_no_apt_staging()
        source = self.mixed_source().encode("ascii").replace(b"\n", b"\r")
        self.source.write_bytes(source)
        self.assert_cli_refusal("source-syntax")
        self.assertEqual(self.source.read_bytes(), source)

    def test_mixed_postcommit_durability_failure_cannot_be_bypassed_by_idempotence(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        original_fsync = self.helper.os.fsync
        calls = []

        def fail_directory(fd):
            calls.append(fd)
            if len(calls) == 2:
                raise OSError(errno.EIO, "private durability failure")
            original_fsync(fd)

        with patch.object(self.helper.os, "fsync", fail_directory):
            self.assert_cli_refusal("io-error")
        committed = self.source.stat()
        self.assertEqual(self.source.read_text(), self.normalized_source(self.mixed_source()))
        for failure in (1, 2):
            calls.clear()

            def repeat_fsync(fd):
                calls.append(fd)
                if len(calls) == failure:
                    raise OSError(errno.EIO, "private repeated durability failure")
                original_fsync(fd)

            with self.subTest(fsync_call=failure), patch.object(self.helper.os, "fsync", repeat_fsync), \
                    patch.object(self.helper.os, "replace") as replace:
                self.assert_cli_refusal("io-error")
                replace.assert_not_called()
            self.assertEqual(len(calls), failure)
            self.assertEqual(self.apt_stat_identity(self.source.stat()), self.apt_stat_identity(committed))
        with patch.object(self.helper.os, "fsync", wraps=original_fsync) as sync, \
                patch.object(self.helper.os, "replace") as replace:
            self.assertEqual(self.configure(), "direct-current")
            self.assertEqual(sync.call_count, 2)
            replace.assert_not_called()
        self.assertEqual(self.apt_stat_identity(self.source.stat()), self.apt_stat_identity(committed))
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_cleanup_failure_keeps_primary_error_and_closes_directories(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        original_close = self.helper.os.close
        closed = []
        primary = OSError(errno.EIO, "private primary write failure")

        def close(fd):
            inode = os.fstat(fd).st_ino
            original_close(fd)
            closed.append(inode)

        with patch.object(self.helper.os, "fsync", side_effect=primary), \
                patch.object(self.helper.os, "unlink", side_effect=OSError(errno.EACCES, "private cleanup failure")), \
                patch.object(self.helper.os, "close", close):
            with self.assertRaises(OSError) as caught:
                self.configure()
        self.assertIs(caught.exception, primary)
        self.assertIn(self.apt.stat().st_ino, closed)
        self.assertIn(self.sources.stat().st_ino, closed)
        self.assertEqual(self.source.read_text(), self.mixed_source())
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        residue = list(self.sources.glob(".apt-mirrors-*"))
        self.assertEqual(len(residue), 1)
        residue[0].unlink()
        self.assert_no_apt_staging()

    def test_mixed_postcommit_permission_change_is_not_a_success(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        original_replace = self.helper.os.replace

        def replace(*args, **kwargs):
            original_replace(*args, **kwargs)
            self.source.chmod(0o600)

        with patch.object(self.helper.os, "replace", replace):
            self.assert_cli_refusal("concurrent-change")
        self.assertEqual(self.source.read_text(), self.normalized_source(self.mixed_source()))
        self.assertEqual(self.source.stat().st_mode & 0o7777, 0o600)
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mixed_ambient_exception_does_not_hide_final_close_failure(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        original_open = self.helper.open_directory
        original_close = self.helper.os.close
        parent = []

        def open_directory(*args):
            fd = original_open(*args)
            if not parent:
                parent.append(fd)
            return fd

        def close(fd):
            original_close(fd)
            if parent and fd == parent[0]:
                raise OSError(errno.EIO, "private final close failure")

        try:
            raise ValueError("ambient caller exception")
        except ValueError:
            with patch.object(self.helper, "open_directory", open_directory), \
                    patch.object(self.helper.os, "close", close):
                with self.assertRaises(OSError) as caught:
                    self.configure()
        self.assertEqual(caught.exception.errno, errno.EIO)
        self.assertEqual(self.source.read_text(), self.normalized_source(self.mixed_source()))
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assert_no_apt_staging()

    def test_mirror_diagnostic_profiles_keep_unknown_lists_blocking_and_unchanged(self):
        cases = (("historical-indirect", self.SOURCE), ("mixed", self.mixed_source()),
                 ("direct", self.normalized_source(self.mixed_source())))
        mirrors = "https://private.invalid/secret priority:1\n"
        for profile, source in cases:
            with self.subTest(profile=profile):
                self.source.write_text(source, encoding="ascii")
                self.mirrors.write_text(mirrors, encoding="ascii")
                before = [self.apt_stat_identity(path.stat()) for path in (self.source, self.mirrors)]
                self.assert_cli_refusal("mirror-list", detail=(
                    f"Mirror list profile: {profile}; entries: 1; entry-shapes: other/priority-1"))
                self.assertEqual(self.source.read_text(encoding="ascii"), source)
                self.assertEqual(self.mirrors.read_text(encoding="ascii"), mirrors)
                self.assertEqual([self.apt_stat_identity(path.stat()) for path in (self.source, self.mirrors)],
                                 before)
                self.assertEqual(self.external.read_text(), "external fixture retained byte for byte\n")
                self.assert_no_apt_staging()

    def test_mirror_diagnostic_keeps_known_order_priority_and_arity_distinct(self):
        cases = (
            ("https://security.ubuntu.com/ubuntu/ priority:3\n"
             "https://archive.ubuntu.com/ubuntu/ priority:2\n"
             "http://azure.archive.ubuntu.com/ubuntu/ priority:1\n", 3,
             "https-security/priority-3,https-archive/priority-2,http-azure/priority-1"),
            ("http://azure.archive.ubuntu.com/ubuntu priority:1\n"
             "http://archive.ubuntu.com/ubuntu priority:2\n"
             "http://security.ubuntu.com/ubuntu priority:3\n", 3,
             "http-azure-no-slash/priority-1,http-archive-no-slash/priority-2,http-security-no-slash/priority-3"),
            ("https://archive.ubuntu.com/ubuntu/ priority:1\n"
             "https://security.ubuntu.com/ubuntu/ priority:1\n", 2,
             "https-archive/priority-1,https-security/priority-1"),
            ("https://archive.ubuntu.com/ubuntu/ priority:99\n", 1, "https-archive/other"),
            ("https://archive.ubuntu.com/ubuntu/\n", 1, "invalid-entry/other"),
            ("https://archive.ubuntu.com/ubuntu/ priority:1 private-extra\n", 1, "invalid-entry/other"),
            ("\n", 1, "invalid-entry/other"),
            ("", 0, "empty"),
            (self.ORIGINAL + self.ORIGINAL, 6,
             "http-azure/priority-1,https-archive/priority-2,https-security/priority-3,"
             "http-azure/priority-1,https-archive/priority-2,https-security/priority-3"),
        )
        for mirrors, count, shapes in cases:
            with self.subTest(entries=count, expected=shapes):
                self.mirrors.write_text(mirrors, encoding="ascii")
                self.assert_cli_refusal("mirror-list", detail=(
                    f"Mirror list profile: historical-indirect; entries: {count}; entry-shapes: {shapes}"))
                self.assertEqual(self.mirrors.read_text(encoding="ascii"), mirrors)
                self.assert_preserved()

    def test_mirror_diagnostic_bounds_without_presenting_omitted_entries_as_complete(self):
        for count in (8, 9, 200):
            mirrors = "https://archive.ubuntu.com/ubuntu/ priority:1\n" * count
            self.mirrors.write_text(mirrors, encoding="ascii")
            shapes = ",".join(["https-archive/priority-1"] * count) if count <= 8 else "omitted-limit"
            self.assert_cli_refusal("mirror-list", detail=(
                f"Mirror list profile: historical-indirect; entries: {count}; entry-shapes: {shapes}"))
            self.assertEqual(self.mirrors.read_text(encoding="ascii"), mirrors)
            self.assert_preserved()
        self.mirrors.write_bytes(b"x" * (self.helper.MAX_BYTES + 1))
        self.assert_cli_refusal("size-limit")

    def test_mirror_diagnostic_unknown_values_are_not_normalized_or_disclosed(self):
        values = (
            "https://archive.ubuntu.com.attacker.invalid/ubuntu/",
            "https://archive.ubuntu.com/ubuntu/?private=secret",
            "https://private:secret@archive.ubuntu.com/ubuntu/",
            "HTTPS://archive.ubuntu.com/ubuntu/",
            "https://archive.ubuntu.com:443/ubuntu/",
            "https://archive.ubuntu.com/ubuntu/private",
            "file:/private/secret", "mirror+file:/private/secret",
            "https://archive.ubuntu.com/ubuntu/#secret", "private\x1b[31msecret",
        )
        for value in values:
            with self.subTest(case=values.index(value)):
                mirrors = f"{value} priority:1\n"
                self.mirrors.write_text(mirrors, encoding="ascii")
                self.assert_cli_refusal("mirror-list", detail=(
                    "Mirror list profile: historical-indirect; entries: 1; entry-shapes: other/priority-1"))
                self.assertEqual(self.mirrors.read_text(encoding="ascii"), mirrors)
        self.mirrors.write_bytes(b"https://private.invalid/\xff priority:1\n")
        self.assert_cli_refusal("unrecognized-configuration")
        self.assert_preserved()

    def test_mirror_diagnostic_renderer_refuses_forged_unbounded_or_private_details(self):
        class Hostile(str):
            def __eq__(self, _other):
                raise AssertionError("untrusted detail compared")

        pair = (("https-archive", "priority-1"),)
        invalid = (
            None, [], "private", ("private", 1, pair), (Hostile("mixed"), 1, pair),
            ("mixed", True, pair), ("mixed", -1, ()), ("mixed", 16385, None),
            ("mixed", 1, None), ("mixed", 9, pair), ("mixed", 1, []),
            ("mixed", 2, pair), ("mixed", 0, pair), ("mixed", 1, (("private", "priority-1"),)),
            ("mixed", 1, (("https-archive", "private"),)),
            ("mixed", 1, ((Hostile("other"), "other"),)),
            ("mixed", 1, (("other", Hostile("other")),)),
            ("mixed", 1, (("other",),)), ("mixed", 1, (["other", "other"],)),
            ("mixed", 1), ("mixed", 1, pair, "private"),
        )
        for detail in invalid:
            with self.subTest(kind=type(detail).__name__):
                error = self.helper.PreparationError("mirror-list", mirror_list_detail=detail)
                self.assertIsNone(self.helper.mirror_list_diagnostic(error))
                with patch.object(sys, "argv", ["helper"]), \
                        patch.object(self.helper.os, "geteuid", return_value=0), \
                        patch.object(self.helper, "configure", side_effect=error), \
                        contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(self.helper.main(), 65)
                self.assertEqual(errors.getvalue(),
                                 "Error: Ubuntu CI mirror preparation failed; package setup must stop.\n"
                                 "Category: mirror-list\n")
        for category in ("source-signature", "source-uri", "concurrent-change"):
            self.assertIsNone(self.helper.mirror_list_diagnostic(self.helper.PreparationError(
                category, mirror_list_detail=("mixed", 1, pair))))

    def test_mirror_diagnostic_uses_only_secured_bytes_already_read(self):
        self.source.write_text(self.mixed_source(), encoding="ascii")
        self.mirrors.write_text("https://security.ubuntu.com/ubuntu/ priority:1\n", encoding="ascii")
        original_read = self.helper.read_file
        calls = []

        def read_file(*args):
            calls.append(args[1])
            data, metadata = original_read(*args)
            if args[1] == "apt-mirrors.txt":
                replacement = self.apt / "replacement"
                replacement.write_text(self.ORIGINAL, encoding="ascii")
                replacement.replace(self.mirrors)
            return data, metadata

        with patch.object(self.helper, "read_file", read_file):
            self.assert_cli_refusal("mirror-list", detail=(
                "Mirror list profile: mixed; entries: 1; entry-shapes: https-security/priority-1"))
        self.assertEqual(calls, ["ubuntu.sources", "apt-mirrors.txt"])
        self.assertEqual(self.mirrors.read_text(), self.ORIGINAL)
        self.assertEqual(self.source.read_text(), self.mixed_source())
        self.assert_no_apt_staging()

    def test_mirror_diagnostic_does_not_run_before_earlier_guards(self):
        self.source.write_text(self.mixed_source().replace(self.helper.KEYRING, "/private/secret.gpg"),
                               encoding="ascii")
        self.mirrors.write_text("private unknown list\n", encoding="ascii")
        original_read = self.helper.read_file
        with patch.object(self.helper, "mirror_list_shape", side_effect=AssertionError("late diagnostic")), \
                patch.object(self.helper, "read_file", wraps=original_read) as read:
            self.assert_cli_refusal("source-signature")
        self.assertEqual([call.args[1] for call in read.call_args_list], ["ubuntu.sources"])
        self.source.write_text(self.mixed_source(), encoding="ascii")
        self.mirrors.chmod(0o666)
        with patch.object(self.helper, "mirror_list_shape", side_effect=AssertionError("late diagnostic")):
            self.assert_cli_refusal("permissions")
        self.assertEqual(self.mirrors.read_text(), "private unknown list\n")
        self.assertEqual(self.source.read_text(), self.mixed_source())

    def test_mirror_diagnostic_is_absent_on_all_accepted_profiles_and_repeats(self):
        profiles = ((self.SOURCE, "mirrors", self.SOURCE),
                    (self.mixed_source(), "sources", self.normalized_source(self.mixed_source())),
                    (self.normalized_source(self.mixed_source()), "sources",
                     self.normalized_source(self.mixed_source())))
        configure = self.helper.configure
        for source, kind, final_source in profiles:
            for mirrors in (self.ORIGINAL, self.SELECTED):
                with self.subTest(kind=kind, already_direct=source == final_source,
                                  selected=mirrors == self.SELECTED):
                    self.source.write_text(source, encoding="ascii")
                    self.mirrors.write_text(mirrors, encoding="ascii")
                    for repeat in (False, True):
                        with patch.object(sys, "argv", ["helper"]), \
                                patch.object(self.helper.os, "geteuid", return_value=0), \
                                patch.object(self.helper, "configure", side_effect=lambda _path, _owner:
                                             configure(self.apt, os.stat(self.apt).st_uid)), \
                                patch.object(self.helper, "mirror_list_shape",
                                             side_effect=AssertionError("diagnostic on success")), \
                                contextlib.redirect_stdout(io.StringIO()) as output, \
                                contextlib.redirect_stderr(io.StringIO()) as errors:
                            self.assertEqual(self.helper.main(), 0)
                        self.assertEqual(errors.getvalue(), "")
                        already = repeat or (kind == "mirrors" and mirrors == self.SELECTED) or (
                            kind == "sources" and source == final_source)
                        action = "already selected." if already else "selected."
                        label = "archives " if kind == "mirrors" else "archive/security "
                        self.assertEqual(output.getvalue(), f"Ubuntu CI {kind}: official HTTPS {label}{action}\n")
                        self.assertEqual(self.source.read_text(), final_source)
                        self.assertEqual(self.mirrors.read_text(), self.SELECTED if kind == "mirrors" else mirrors)
                        self.assert_no_apt_staging()

    def assert_workflow_scope(self, filename, text):
        jobs = WorkflowContractTests.jobs(text)
        selected = self.TARGETS.get(filename, set())
        for name, job in jobs.items():
            if name not in selected:
                self.assertNotIn("ci-ubuntu-mirrors.py", job)
                continue
            self.assertEqual(job.count(self.COMMAND), 1)
            self.assertIn("runs-on: ubuntu-24.04", job)
            self.assertLess(job.index("persist-credentials: false"), job.index(self.COMMAND))
            self.assertLess(job.index(self.COMMAND), job.index("ci-ubuntu-mirrors.py --apt"))
            self.assertNotIn("apt-get", job)
            line = next(line.strip() for line in job.splitlines() if "ci-ubuntu-mirrors.py --setup" in line)
            self.assertEqual(line, self.COMMAND)
            self.assertNotIn("/etc/apt/", job)

    def test_exact_nine_jobs_prepare_mirrors_before_apt_and_exclude_privileged_jobs(self):
        for path in (PROJECT / ".github/workflows").glob("*.yml"):
            with self.subTest(workflow=path.name):
                self.assert_workflow_scope(path.name, path.read_text())

    def test_missing_late_or_failure_masked_preparation_is_rejected(self):
        for filename in self.TARGETS:
            text = WorkflowContractTests.workflow(filename)
            for original, replacement in ((self.COMMAND, "true"),
                                           (self.COMMAND, self.COMMAND + " || true"),
                                           (self.COMMAND, self.COMMAND + " /tmp/config")):
                with self.subTest(workflow=filename, mutation=replacement), self.assertRaises(AssertionError):
                    self.assert_workflow_scope(filename, text.replace(original, replacement, 1))
        text = WorkflowContractTests.workflow("real-tools.yml")
        moved = text.replace("          " + self.COMMAND + "\n", "", 1)
        moved = moved.replace('          case ${YT_DLP_VERSION}',
                              "          " + self.COMMAND + '\n          case ${YT_DLP_VERSION}', 1)
        with self.assertRaises(AssertionError):
            self.assert_workflow_scope("real-tools.yml", moved)

    def test_preparation_failure_preserves_status_and_prevents_every_package_setup(self):
        binary = self.root / "bin"
        binary.mkdir()
        sudo = binary / "sudo"
        sudo.write_text('#!/bin/bash\n'
                        'if [[ $* == "python3 -I -B scripts/ci-ubuntu-mirrors.py --setup" ]]; then exit 65; fi\n'
                        'printf unexpected >"${CHECK_UNEXPECTED}"\nexit 99\n')
        sudo.chmod(0o755)
        for filename, names in self.TARGETS.items():
            jobs = WorkflowContractTests.jobs(WorkflowContractTests.workflow(filename))
            for name in names:
                step = next(block for block in re.split(r"(?m)^      - ", jobs[name])
                            if self.COMMAND in block)
                block = step.split("run: |\n", 1)[1]
                script = "\n".join(line[10:] for line in block.splitlines() if line.startswith("          "))
                sentinel = self.root / "unexpected"
                environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                                   CHECK_UNEXPECTED=str(sentinel))
                with self.subTest(workflow=filename, job=name):
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                            env=environment, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
                    self.assertFalse(sentinel.exists())


def require_fixture_process_exit(pid, starttime, *, read_stat=None,
                                 monotonic=time.monotonic, sleep=time.sleep):
    """Observe asynchronous kernel exit without accepting a surviving fixture."""
    if read_stat is None:
        read_stat = Path("/proc", str(pid), "stat").read_text
    deadline = monotonic() + 1.0
    while True:
        try:
            try:
                snapshot = read_stat()
            except ProcessLookupError:
                # A procfs descriptor opened before reap can return ESRCH.
                # Reopen once: only absence or the same terminal identity is
                # evidence of exit; repeated unreadability remains a failure.
                snapshot = read_stat()
            fields = snapshot.rsplit(") ", 1)[1].split()
        except FileNotFoundError:
            return
        if fields[19] != starttime:
            raise AssertionError("APT fixture PID identity changed before terminal observation")
        if fields[0] in ("Z", "X"):
            return
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise AssertionError("Bounded APT fixture is still executing after 1s")
        sleep(min(0.005, remaining))


class DirectoryOwnershipTests(unittest.TestCase):
    """Observe real FD lifetimes independently of injected syscall failures."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("apt_directory_ownership", PROJECT / "scripts/ci-ubuntu-mirrors.py")
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / 'first' / 'second'
        self.directory.mkdir(parents=True, mode=0o700)
        self.sentinel = self.root / 'sentinel'
        self.sentinel.write_bytes(b'independently owned descriptor')
        self.owner = os.geteuid()

    @contextlib.contextmanager
    def acquisitions(self, *, open_error=None, stat_error=None, close_errors=None, reuse=False):
        """Record generations, not reusable integers; clean only witness-owned FDs."""
        real_open, real_close, real_stat = os.open, os.close, os.fstat
        trace = {'events': [], 'live': {}, 'opens': 0, 'closes': 0, 'sentinel': None}
        close_errors = close_errors or {}

        def opening(path, flags, **kwargs):
            trace['opens'] += 1
            generation = trace['opens']
            parent = trace['live'].get(kwargs.get('dir_fd'))
            trace['events'].append(('open', generation, parent, flags))
            if open_error is not None and generation == open_error[0]:
                raise open_error[1]
            fd = real_open(path, flags, **kwargs)
            trace['live'][fd] = generation
            trace['events'].append(('acquired', generation))
            return fd

        def closing(fd):
            trace['closes'] += 1
            generation = trace['live'].get(fd, 'foreign-or-consumed')
            trace['events'].append(('close', generation))
            real_close(fd)
            trace['live'].pop(fd, None)
            if reuse and trace['closes'] == 1:
                sentinel = real_open(self.sentinel, os.O_RDONLY | os.O_CLOEXEC)
                if sentinel != fd:
                    os.dup2(sentinel, fd, inheritable=False)
                    real_close(sentinel)
                trace['sentinel'] = fd
            if trace['closes'] in close_errors:
                raise close_errors[trace['closes']]

        def examining(fd):
            trace['events'].append(('fstat', trace['live'].get(fd, 'foreign-or-consumed')))
            if stat_error is not None:
                raise stat_error
            return real_stat(fd)

        try:
            with patch.object(self.helper.os, 'open', side_effect=opening), \
                    patch.object(self.helper.os, 'close', side_effect=closing), \
                    patch.object(self.helper.os, 'fstat', side_effect=examining):
                yield trace
        finally:
            # The witness owns leaked resources for cleanup, but asserts their
            # state before cleanup; it never turns a candidate leak into PASS.
            for fd in tuple(trace['live']):
                real_close(fd)
            sentinel = trace['sentinel']
            if sentinel is not None:
                try:
                    metadata = real_stat(sentinel)
                except OSError as error:
                    if error.errno != errno.EBADF:
                        raise
                else:
                    if (metadata.st_dev, metadata.st_ino) == (self.sentinel.stat().st_dev, self.sentinel.stat().st_ino):
                        real_close(sentinel)

    def test_nominal_walk_returns_only_the_final_live_descriptor(self):
        real_stat = os.fstat
        for directory in (self.root, self.directory):
            with self.subTest(components=len(directory.parts)), self.acquisitions() as trace:
                fd = self.helper.open_directory(directory, self.owner)
                count = len(directory.parts)
                self.assertEqual(trace['live'], {fd: count})
                self.assertEqual((real_stat(fd).st_dev, real_stat(fd).st_ino),
                                 (directory.stat().st_dev, directory.stat().st_ino))
                expected = [('open', 1, None, self.helper.OPEN_READ | os.O_DIRECTORY), ('acquired', 1)]
                for generation in range(2, count + 1):
                    expected += [('open', generation, generation - 1, self.helper.OPEN_READ | os.O_DIRECTORY),
                                 ('acquired', generation), ('close', generation - 1)]
                self.assertEqual(trace['events'], expected + [('fstat', count)])
                self.assertEqual(trace['closes'], count - 1)
                # Only the caller releases the successfully transferred FD.
                self.helper.os.close(fd)
                self.assertEqual(trace['live'], {})

    def test_child_open_failure_preserves_exact_primary_and_releases_parent(self):
        for failed_open in (2, len(self.directory.parts)):
            primary = PermissionError(errno.EACCES, 'private opening failure')
            with self.subTest(failed_open=failed_open), self.acquisitions(open_error=(failed_open, primary)) as trace:
                with self.assertRaises(PermissionError) as caught:
                    self.helper.open_directory(self.directory, self.owner)
                self.assertIs(caught.exception, primary)
                self.assertEqual(caught.exception.errno, errno.EACCES)
                self.assertEqual(trace['live'], {})
                self.assertEqual([event[1] for event in trace['events'] if event[0] == 'close'],
                                 list(range(1, failed_open)))

    def test_failed_validation_releases_final_descriptor_without_masking(self):
        primary = OSError(errno.EIO, 'private stat failure')
        with self.acquisitions(stat_error=primary) as trace:
            with self.assertRaises(OSError) as caught:
                self.helper.open_directory(self.directory, self.owner)
            self.assertIs(caught.exception, primary)
            self.assertEqual(trace['live'], {})
        for category in ('owner', 'permissions'):
            if category == 'permissions':
                self.directory.chmod(0o777)
            with self.subTest(category=category), self.acquisitions() as trace:
                with self.assertRaises(self.helper.PreparationError) as caught:
                    self.helper.open_directory(self.directory, self.owner + (category == 'owner'))
                self.assertEqual(caught.exception.category, category)
                self.assertEqual(trace['live'], {})
            self.directory.chmod(0o700)

    def test_parent_close_errors_never_retry_or_lose_the_child(self):
        for error_number in (errno.EIO, errno.EINTR, errno.EBADF):
            for failed_close in (1, len(self.directory.parts) - 1):
                primary = OSError(error_number, 'injected after native close')
                with self.subTest(errno=error_number, position=failed_close), \
                        self.acquisitions(close_errors={failed_close: primary}) as trace:
                    with self.assertRaises(OSError) as caught:
                        self.helper.open_directory(self.directory, self.owner)
                    self.assertIs(caught.exception, primary)
                    self.assertEqual(caught.exception.errno, error_number)
                    self.assertEqual(trace['live'], {})
                    self.assertEqual([event[1] for event in trace['events'] if event[0] == 'close'],
                                     list(range(1, failed_close + 2)))

    def test_reassigned_parent_number_is_not_closed_during_cleanup(self):
        real_stat = os.fstat
        primary = OSError(errno.EIO, 'injected after native close and reuse')
        with self.acquisitions(close_errors={1: primary}, reuse=True) as trace:
            with self.assertRaises(OSError) as caught:
                self.helper.open_directory(self.directory, self.owner)
            self.assertIs(caught.exception, primary)
            try:
                metadata = real_stat(trace['sentinel'])
            except OSError as error:
                self.fail(f'foreign sentinel was closed: errno {error.errno}')
            self.assertEqual((metadata.st_dev, metadata.st_ino),
                             (self.sentinel.stat().st_dev, self.sentinel.stat().st_ino))
            self.assertEqual(trace['live'], {})
            self.assertEqual([event for event in trace['events'] if event[0] == 'close'],
                             [('close', 1), ('close', 2)])

    def test_open_error_precedes_cleanup_error_with_bounded_secondary(self):
        primary = PermissionError(errno.EACCES, 'private primary')
        secondary = OSError(errno.EIO, 'private cleanup /token')
        with self.acquisitions(open_error=(2, primary), close_errors={1: secondary}) as trace:
            with self.assertRaises(PermissionError) as caught:
                self.helper.open_directory(self.directory, self.owner)
            self.assertIs(caught.exception, primary)
            self.assertEqual(caught.exception.errno, errno.EACCES)
            self.assertEqual(caught.exception.directory_close_category, 'io-error')
            self.assertEqual(trace['live'], {})
            self.assertEqual([event for event in trace['events'] if event[0] == 'close'], [('close', 1)])

    def test_two_failed_closes_keep_first_error_and_consume_each_fd_once(self):
        primary = InterruptedError(errno.EINTR, 'private primary')
        secondary = PermissionError(errno.EPERM, 'private secondary')
        with self.acquisitions(close_errors={1: primary, 2: secondary}) as trace:
            with self.assertRaises(InterruptedError) as caught:
                self.helper.open_directory(self.directory, self.owner)
            self.assertIs(caught.exception, primary)
            self.assertEqual(caught.exception.directory_close_category, 'access-denied')
            self.assertEqual(trace['live'], {})
            self.assertEqual([event for event in trace['events'] if event[0] == 'close'],
                             [('close', 1), ('close', 2)])

    def test_validation_refusal_precedes_cleanup_failure(self):
        count = len(self.directory.parts)
        for primary in (None, OSError(errno.EIO, 'private stat'), KeyboardInterrupt()):
            secondary = OSError(errno.EIO, 'private cleanup')
            expected = type(primary) if primary is not None else self.helper.PreparationError
            with self.subTest(primary=expected.__name__), \
                    self.acquisitions(stat_error=primary, close_errors={count: secondary}) as trace:
                with self.assertRaises(expected) as caught:
                    self.helper.open_directory(self.directory, self.owner + 1)
                if primary is None:
                    self.assertEqual(caught.exception.category, 'owner')
                else:
                    self.assertIs(caught.exception, primary)
                self.assertEqual(caught.exception.directory_close_category, 'io-error')
                self.assertEqual(trace['live'], {})
                self.assertEqual([event[1] for event in trace['events'] if event[0] == 'close'],
                                 list(range(1, count + 1)))

    def test_invalid_paths_and_symlink_components_remain_rejected(self):
        for directory in ('relative/path', str(self.directory / '..')):
            with self.subTest(directory=directory), self.acquisitions() as trace:
                with self.assertRaises(self.helper.PreparationError) as caught:
                    self.helper.open_directory(directory, self.owner)
                self.assertEqual(caught.exception.category, 'directory-path')
                self.assertEqual(trace['events'], [])
        alias = self.root / 'alias'
        alias.symlink_to(self.directory, target_is_directory=True)
        with self.acquisitions() as trace:
            with self.assertRaises(OSError) as caught:
                self.helper.open_directory(alias, self.owner)
            self.assertIn(caught.exception.errno, (errno.ELOOP, errno.ENOTDIR))
            self.assertEqual(trace['live'], {})

    def test_cleanup_diagnostic_rejects_unbounded_or_private_forged_details(self):
        error = OSError(errno.EACCES, 'private primary')
        self.assertIsNone(self.helper.directory_close_diagnostic(error))
        for detail in (None, '', 5, True, ['io-error'], 'private/token', 'io-error\nprivate', 'x' * 20000):
            error.directory_close_category = detail
            with self.subTest(detail_type=type(detail).__name__):
                self.assertIsNone(self.helper.directory_close_diagnostic(error))
        for category in ('missing-file', 'access-denied', 'path-type', 'io-error'):
            error.directory_close_category = category
            self.assertEqual(self.helper.directory_close_diagnostic(error), f'Directory cleanup: {category}')

    def test_cli_preserves_primary_category_secondary_and_refuses_apt(self):
        for dedicated in (False, True):
            primary = PermissionError(errno.EACCES, 'private primary /token')
            secondary = OSError(errno.EIO, 'private secondary /token')
            output, errors = io.StringIO(), io.StringIO()
            def refused(*_):
                return self.helper.open_directory(self.directory, self.owner)
            with self.subTest(dedicated=dedicated), \
                    self.acquisitions(open_error=(2, primary), close_errors={1: secondary}), \
                    patch.object(self.helper.os, 'geteuid', return_value=0), \
                    patch.object(sys, 'argv', ['helper']), \
                    patch.object(Path, 'read_text', return_value='ID=ubuntu\nVERSION_ID=24.04\n'), \
                    patch.object(self.helper, 'prepare_dedicated', side_effect=refused), \
                    patch.object(self.helper, 'configure', side_effect=refused), \
                    patch.object(self.helper.subprocess, 'run') as execute, \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                status = self.helper.dedicated_main(['--setup']) if dedicated else self.helper.main()
                self.assertEqual(status, 65)
                self.assertEqual(output.getvalue(), '')
                expected = ('Error: Ubuntu CI APT preparation or validation failed; package setup must stop.\n'
                            if dedicated else 'Error: Ubuntu CI mirror preparation failed; package setup must stop.\n')
                self.assertEqual(errors.getvalue(), expected + 'Category: access-denied\nDirectory cleanup: io-error\n')
                execute.assert_not_called()


class DedicatedAPTTests(unittest.TestCase):
    """Exercise the real scoped helper without invoking the host package manager."""

    @classmethod
    def setUpClass(cls):
        UbuntuMirrorTests.setUpClass()
        cls.helper = UbuntuMirrorTests.helper
        cls.canonical_keyring = cls.helper.CI_KEYRING

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / 'ci-apt'
        self.owner = os.geteuid()
        self.key = self.parent / 'keyring.gpg'
        self.key.write_bytes(b'fixture key; cryptographic rejection is tested with actual APT')
        self.key.chmod(0o644)
        self.key_patch = patch.object(self.helper, 'CI_KEYRING', str(self.key))
        self.key_patch.start()
        self.addCleanup(self.key_patch.stop)

    def setup(self):
        self.helper.prepare_dedicated(self.root, self.owner)

    def run_apt(self, arguments=None, *, action=None, status=0):
        calls = []

        def execute(command, **kwargs):
            calls.append((command, kwargs))
            if action:
                action(command, kwargs)
            return subprocess.CompletedProcess(command, status)

        with patch.object(self.helper.subprocess, 'run', side_effect=execute):
            result = self.helper.run_dedicated(self.root, self.owner, arguments or ['update'])
        return result, calls

    def test_exact_official_sources_and_no_ambient_apt_configuration(self):
        self.setup()
        sources = (self.root / 'ubuntu.sources').read_text(encoding='ascii')
        self.assertEqual(sources.count('Types: deb\n'), 2)
        self.assertEqual(self.canonical_keyring, '/etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg')
        self.assertEqual(self.helper.CI_SIGNER, 'F6ECB3762474EDA9D21B7022871920D1991BC93C')
        self.assertEqual(sources.count(f'Signed-By: {self.key} {self.helper.CI_SIGNER}\n'), 2)
        self.assertIn('URIs: https://archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates noble-backports\n', sources)
        self.assertIn('URIs: https://security.ubuntu.com/ubuntu/\nSuites: noble-security\n', sources)
        self.assertEqual(sources.count('Components: main restricted universe multiverse\n'), 2)
        config = (self.root / 'apt.conf').read_text(encoding='ascii')
        for setting in ('main', 'parts', 'sourcelist', 'sourceparts', 'preferences',
                        'preferencesparts', 'trusted', 'trustedparts', 'netrc', 'netrcparts'):
            self.assertIn(f'Dir::Etc::{setting} "{self.root}/', config)
        for setting in ('Dir::State::lists', 'Dir::Cache'):
            self.assertIn(f'{setting} "{self.root}/', config)
        for setting in ('Dir::Cache::pkgcache', 'Dir::Cache::srcpkgcache'):
            self.assertIn(f'{setting} "";', config)
        self.assertIn('APT::Update::Error-Mode "any";', config)
        self.assertIn('Acquire::https::AllowRedirect "false";', config)
        for setting in ('Verify-Peer', 'Verify-Host'):
            self.assertIn(f'Acquire::https::{setting} "true";', config)
        for forbidden in ('trusted=yes', 'AllowUnauthenticated', 'AllowInsecureRepositories', 'mirror+file'):
            self.assertNotIn(forbidden, sources + config)

    @contextlib.contextmanager
    def assert_ambient_unread(self, source):
        """Observe Python opens directly; access times cannot prove non-reading."""
        identity = source.stat()
        opened = []

        def watch(opener):
            def observed(*args, **kwargs):
                result = opener(*args, **kwargs)
                descriptor = result if isinstance(result, int) else result.fileno()
                metadata = os.fstat(descriptor)
                if (metadata.st_dev, metadata.st_ino) == (identity.st_dev, identity.st_ino):
                    opened.append(True)
                return result
            return observed

        # Path.open is a separate boundary: Python 3.10 caches its io opener.
        # Also cover direct io/builtins and dir_fd-based os.open, including aliases.
        with patch.object(Path, 'open', watch(Path.open)), \
                patch('builtins.open', watch(open)), patch.object(io, 'open', watch(io.open)), \
                patch.object(os, 'open', watch(os.open)):
            yield
        self.assertFalse(opened, 'ambient source opened during dedicated preparation')

    def assert_ambient_unchanged(self, source, before, content):
        # Verify stable identity and nanosecond metadata before our own read.
        # Reading to compare contents can update atime on an otherwise intact file.
        after = source.stat()
        for field in ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
                      'st_size', 'st_mtime_ns', 'st_ctime_ns'):
            self.assertEqual(getattr(after, field), getattr(before, field), field)
        self.assertEqual(source.read_text(encoding='utf-8'), content)

    def test_all_host_source_shapes_are_unread_and_unchanged(self):
        ambient = self.parent / 'ambient'
        ambient.mkdir()
        for content in (UbuntuMirrorTests.SOURCE, 'mixed sources', 'unknown mirror secret', 'external hostile source'):
            source = ambient / 'ubuntu.sources'
            source.write_text(content, encoding='utf-8')
            # Force the verification read to be eligible for a relatime update,
            # without sleeping or depending on crossing a clock-second boundary.
            os.utime(source, ns=(1, source.stat().st_mtime_ns))
            before = source.stat()
            with self.assert_ambient_unread(source), \
                    patch.object(self.helper, 'configure', side_effect=AssertionError('legacy used')):
                self.setup()
                self.assertEqual(self.run_apt()[0], 0)
            self.assert_ambient_unchanged(source, before, content)

    def test_ambient_read_witness_detects_open_mutations(self):
        source = self.parent / 'ambient.sources'
        source.write_text('synthetic ambient source', encoding='utf-8')
        alias = self.parent / 'ambient-alias'
        alias.symlink_to(source)
        self.setup()

        def descriptor_read():
            with self.helper.scoped_descriptor(os.open(source.parent, os.O_RDONLY | os.O_DIRECTORY)) as directory:
                with self.helper.scoped_descriptor(os.open(source.name, os.O_RDONLY, dir_fd=directory)) as descriptor:
                    os.read(descriptor, 1)

        def builtin_read():
            with open(source, encoding='utf-8') as stream:
                stream.read()

        def io_read():
            with io.open(source, encoding='utf-8') as stream:
                stream.read()

        for reader in (source.read_bytes, alias.read_text, io_read, builtin_read, descriptor_read):
            with self.subTest(reader=reader.__name__), \
                    self.assertRaisesRegex(AssertionError, 'ambient source opened'):
                with self.assert_ambient_unread(source):
                    self.run_apt(action=lambda *_: reader())

    def test_ambient_integrity_witness_checks_metadata_before_read(self):
        source = self.parent / 'ambient.sources'
        source.write_text('synthetic ambient source', encoding='utf-8')
        before = source.stat()
        order = []
        real_stat, real_read = Path.stat, Path.read_text

        def inspect(path, *args, **kwargs):
            order.append('stat')
            return real_stat(path, *args, **kwargs)

        def read(path, *args, **kwargs):
            self.assertEqual(order, ['stat'])
            order.append('read')
            return real_read(path, *args, **kwargs)

        with patch.object(Path, 'stat', inspect), patch.object(Path, 'read_text', read):
            self.assert_ambient_unchanged(source, before, 'synthetic ambient source')
        self.assertEqual(order, ['stat', 'read'])

    def test_ambient_integrity_witness_rejects_metadata_and_content_mutations(self):
        from types import SimpleNamespace

        source = self.parent / 'ambient.sources'
        source.write_text('synthetic ambient source', encoding='utf-8')
        before = source.stat()
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
                  'st_size', 'st_mtime_ns', 'st_ctime_ns')
        for field in fields:
            changed = SimpleNamespace(**{name: getattr(before, name) for name in fields})
            setattr(changed, field, getattr(changed, field) + 1)
            with self.subTest(field=field), patch.object(Path, 'stat', return_value=changed), \
                    patch.object(Path, 'read_text') as read, self.assertRaisesRegex(AssertionError, field):
                self.assert_ambient_unchanged(source, before, 'synthetic ambient source')
            read.assert_not_called()
        with patch.object(Path, 'read_text', return_value='modified source'), self.assertRaises(AssertionError):
            self.assert_ambient_unchanged(source, before, 'synthetic ambient source')

    def test_update_and_install_share_exact_environment_and_protected_files(self):
        self.setup()
        environments = []
        snapshots = []
        with patch.dict(os.environ, {'APT_CONFIG': '/private/hostile', 'http_proxy': 'private',
                                     'LANGUAGE': 'fr', 'LD_PRELOAD': '/private/secret'}):
            for args in (['update'], ['install', '--yes', 'aria2']):
                status, calls = self.run_apt(args)
                self.assertEqual(status, 0)
                self.assertEqual(calls[0][0], ['/usr/bin/apt-get', *args])
                environments.append(calls[0][1]['env'])
                snapshots.append(self.helper.dedicated_snapshot(self.root, self.owner))
        self.assertEqual(environments[0], environments[1])
        self.assertEqual(snapshots[0], snapshots[1])
        self.assertEqual(environments[0], {
            'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LC_ALL': 'C',
            'LANGUAGE': 'C', 'DEBIAN_FRONTEND': 'noninteractive',
            'APT_CONFIG': str(self.root / 'apt.conf'),
        })

    def test_repeated_setup_preserves_bytes_modes_and_inodes(self):
        self.setup()
        before = self.helper.dedicated_snapshot(self.root, self.owner)
        self.setup()
        self.assertEqual(self.helper.dedicated_snapshot(self.root, self.owner), before)

    def test_unknown_options_and_package_selectors_refuse_before_execution(self):
        self.setup()
        variants = (['-c', '/private'], ['-o', 'Dir::Etc::sourcelist=/private', 'update'],
                    ['-o', 'APT::Get::AllowUnauthenticated=true', 'update'],
                    ['-o', 'Acquire::Retries=0', 'update'], ['-o'], ['upgrade'],
                    ['install', '--yes', '--allow-unauthenticated', 'aria2'],
                    ['install', '--yes', 'aria2-'], ['install', '--yes', 'aria2+'],
                    ['install', '--yes', 'aria2/noble'], ['install', '--yes', 'aria2=1'],
                    ['install', '--yes', '.*'], ['install', '--yes', 'unreviewed'],
                    ['install', '--yes', './local.deb'], ['remove', '--yes', 'aria2'],
                    ['install', '--yes'], ['update', 'extra'], ['install', '--yes', '/x\nsecret.deb'])
        for args in variants:
            with self.subTest(args=args), patch.object(self.helper.subprocess, 'run') as execute:
                with self.assertRaises(self.helper.PreparationError):
                    self.helper.run_dedicated(self.root, self.owner, args)
                execute.assert_not_called()

    def test_existing_options_packages_and_local_artifact_boundary(self):
        self.setup()
        options = [part for value in sorted(self.helper.APT_OPTIONS) for part in ('-o', value)]
        for args in (options + ['update'],
                     ['install', '--yes', '--no-install-recommends', *sorted(self.helper.CI_PACKAGES)],
                     ['install', '--yes', '/tmp/Téléchargements été/local.deb'],
                     ['remove', '--yes', 'yt-dlp-aria2-downloader-gui'],
                     ['purge', '--yes', 'yt-dlp-aria2-downloader-gui']):
            with self.subTest(operation=args):
                self.assertEqual(self.run_apt(args)[0], 0)

    def test_missing_setup_or_partial_setup_never_executes_apt(self):
        for partial in (False, True):
            if partial:
                self.root.mkdir(mode=0o700)
                (self.root / 'apt.conf').write_text('partial', encoding='ascii')
            with self.subTest(partial=partial), patch.object(self.helper.subprocess, 'run') as execute:
                with self.assertRaises((OSError, self.helper.PreparationError)):
                    self.helper.run_dedicated(self.root, self.owner, ['update'])
                execute.assert_not_called()

    def test_changed_config_sources_or_signature_refuses_without_repair(self):
        self.setup()
        for name in self.helper.dedicated_files(self.root):
            path = self.root / name
            original = path.read_bytes()
            for replacement in (b'foreign', original + b'\n'):
                path.write_bytes(replacement)
                with self.subTest(name=name), patch.object(self.helper.subprocess, 'run') as execute:
                    with self.assertRaises(self.helper.PreparationError):
                        self.helper.run_dedicated(self.root, self.owner, ['update'])
                    execute.assert_not_called()
                    self.assertEqual(path.read_bytes(), replacement)
                path.write_bytes(original)
        self.key.write_bytes(b'')
        with self.assertRaises(self.helper.PreparationError):
            self.run_apt()

    def test_replaced_source_between_update_and_install_refuses_install(self):
        self.setup()
        self.assertEqual(self.run_apt()[0], 0)
        (self.root / 'ubuntu.sources').write_bytes(b'URIs: https://hostile.invalid/')
        with patch.object(self.helper.subprocess, 'run') as execute:
            with self.assertRaises(self.helper.PreparationError):
                self.helper.run_dedicated(self.root, self.owner, ['install', '--yes', 'aria2'])
            execute.assert_not_called()

    def test_unsafe_permissions_owners_links_and_extra_config_refuse(self):
        self.setup()
        for name in ('apt.conf', 'ubuntu.sources', 'empty.conf'):
            path = self.root / name
            for mode in (0o666, 0o600, 0o664):
                path.chmod(mode)
                with self.subTest(name=name, mode=mode), self.assertRaises(self.helper.PreparationError):
                    self.run_apt()
            path.chmod(0o644)
            backup = self.parent / 'backup'
            path.rename(backup)
            path.symlink_to(backup)
            with self.assertRaises(OSError):
                self.run_apt()
            path.unlink()
            os.link(backup, path)
            with self.assertRaises(self.helper.PreparationError):
                self.run_apt()
            path.unlink()
            backup.rename(path)
        for name in ('empty', 'lists', 'cache', 'cache/archives'):
            directory = self.root / name
            for mode in (0o700, 0o777):
                directory.chmod(mode)
                with self.subTest(directory=name, mode=mode), self.assertRaises(self.helper.PreparationError):
                    self.run_apt()
            directory.chmod(0o755)
        with self.assertRaises(self.helper.PreparationError):
            self.helper.dedicated_snapshot(self.root, self.owner + 1)
        (self.root / 'empty' / 'injected.conf').write_text('hostile', encoding='ascii')
        with self.assertRaises(self.helper.PreparationError):
            self.run_apt()

    def test_read_error_or_short_read_never_executes(self):
        self.setup()
        read = self.helper.os.read
        for error in (OSError(errno.EIO, 'secret'), PermissionError(errno.EACCES, 'private')):
            with patch.object(self.helper.os, 'read', side_effect=error), \
                    patch.object(self.helper.subprocess, 'run') as execute:
                with self.assertRaises(OSError):
                    self.helper.run_dedicated(self.root, self.owner, ['update'])
                execute.assert_not_called()
        with patch.object(self.helper.os, 'read', side_effect=lambda fd, size: read(fd, min(size, 3))):
            self.assertEqual(self.run_apt()[0], 0)
        with patch.object(self.helper.os, 'read', return_value=b''), self.assertRaises(self.helper.PreparationError):
            self.run_apt()

    def test_failed_write_and_fsync_are_blocking_and_do_not_run_apt(self):
        with patch.object(self.helper.os, 'write', return_value=0), self.assertRaises(self.helper.PreparationError):
            self.setup()
        with self.assertRaises(self.helper.PreparationError):
            self.run_apt()
        # A separate owned fixture permits testing sync failures without fixing
        # the deliberately incomplete previous fixture.
        self.root = self.parent / 'sync-apt'
        self.setup()
        for call_number in range(1, 10):
            fsync = self.helper.os.fsync
            count = 0

            def failing(fd):
                nonlocal count
                count += 1
                if count == call_number:
                    raise OSError(errno.EIO, 'private sync failure')
                return fsync(fd)

            with self.subTest(call=call_number), patch.object(self.helper.os, 'fsync', side_effect=failing), \
                    patch.object(self.helper.subprocess, 'run') as execute:
                with self.assertRaises(OSError):
                    self.helper.run_dedicated(self.root, self.owner, ['update'])
                execute.assert_not_called()

    def test_apt_failures_signals_and_secondary_refusal_keep_original_status(self):
        self.setup()
        for raw, expected in ((0, 0), (23, 23), (100, 100), (-15, 143), (-9, 137)):
            self.assertEqual(self.run_apt(status=raw)[0], expected)
        config = self.root / 'apt.conf'
        data = config.read_bytes()
        self.assertEqual(self.run_apt(status=100, action=lambda *_: config.write_bytes(b'changed'))[0], 100)
        config.write_bytes(data)
        with self.assertRaises(self.helper.PreparationError):
            self.run_apt(action=lambda *_: config.write_bytes(b'changed'))

    def test_directory_or_keyring_replacement_during_apt_is_not_success(self):
        self.setup()
        for name in ('lists', 'cache/archives'):
            path = self.root / name
            old = self.parent / 'displaced'

            def replace(*_):
                path.rename(old)
                path.mkdir(mode=0o755)

            with self.subTest(name=name), self.assertRaises(self.helper.PreparationError):
                self.run_apt(action=replace)
            path.rmdir()
            old.rename(path)
        with self.assertRaises(self.helper.PreparationError):
            self.run_apt(action=lambda *_: self.key.write_bytes(b'replaced'))

    def test_held_directory_cannot_validate_a_replaced_path(self):
        self.setup()
        held = self.helper.open_directory(self.root, self.owner)
        self.addCleanup(os.close, held)
        self.root.rename(self.parent / 'old-root')
        self.setup()
        with self.assertRaises(self.helper.PreparationError):
            self.helper.durable_snapshot(self.root, held, self.owner)

    def test_primary_read_error_is_not_replaced_by_close_failure(self):
        self.setup()
        descriptor = self.helper.open_directory(self.root, self.owner)
        self.addCleanup(os.close, descriptor)
        close = self.helper.os.close

        def failing_close(fd):
            close(fd)
            raise OSError(errno.EIO, 'secondary private close error')

        with patch.object(self.helper.os, 'read', side_effect=PermissionError(errno.EACCES, 'primary')), \
                patch.object(self.helper.os, 'close', side_effect=failing_close):
            with self.assertRaises(PermissionError) as caught:
                self.helper.read_file(descriptor, 'apt.conf', self.owner)
            self.assertEqual(caught.exception.errno, errno.EACCES)

    def test_scoped_close_preserves_primary_and_reports_standalone_failure(self):
        for primary in (False, True):
            fd = os.open(self.key, os.O_RDONLY)
            close = self.helper.os.close

            def failing_close(value):
                close(value)
                raise OSError(errno.EIO, 'secondary')

            with self.subTest(primary=primary), patch.object(self.helper.os, 'close', side_effect=failing_close):
                expected = self.helper.PreparationError if primary else OSError
                with self.assertRaises(expected):
                    with self.helper.scoped_descriptor(fd):
                        if primary:
                            raise self.helper.PreparationError('permissions')

    def test_cli_refuses_wrong_platform_and_redacts_unknown_error(self):
        for error in (OSError(errno.EIO, '/private/secret'), ValueError('https://private.invalid/token')):
            with patch.object(self.helper.os, 'geteuid', return_value=0), \
                    patch.object(Path, 'read_text', side_effect=error), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(self.helper.dedicated_main(['--setup']), 65)
                self.assertNotIn('private', errors.getvalue())
        for platform in ('ID=fedora\nVERSION_ID=45\n', 'ID=ubuntu\nVERSION_ID=22.04\n'):
            with patch.object(self.helper.os, 'geteuid', return_value=0), \
                    patch.object(Path, 'read_text', return_value=platform), \
                    patch.object(self.helper, 'prepare_dedicated') as prepare, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(self.helper.dedicated_main(['--setup']), 65)
                prepare.assert_not_called()

    def test_writable_legacy_keyring_is_neither_read_nor_repaired(self):
        legacy = self.parent / 'legacy-keyrings'
        legacy.mkdir()
        key = legacy / 'ubuntu-archive-keyring.gpg'
        key.write_bytes(b'untrusted legacy key')
        legacy.chmod(0o777)
        key.chmod(0o777)
        before = (legacy.stat(), key.stat())
        open_directory = self.helper.open_directory

        def checked(path, owner):
            self.assertNotEqual(Path(path), legacy, 'legacy key directory consumed')
            return open_directory(path, owner)

        with patch.object(self.helper, 'KEYRING', str(key)), \
                patch.object(self.helper, 'open_directory', side_effect=checked):
            self.setup()
            self.assertEqual(self.run_apt()[0], 0)
            self.assertEqual(self.run_apt(['install', '--yes', 'aria2'])[0], 0)
        self.assertEqual(self.helper.file_identity(legacy.stat()), self.helper.file_identity(before[0]))
        self.assertEqual(self.helper.file_identity(key.stat()), self.helper.file_identity(before[1]))
        self.assertEqual(key.read_bytes(), b'untrusted legacy key')

    def test_selected_keyring_permissions_are_not_relaxed(self):
        keys = self.parent / 'selected-keys'
        keys.mkdir(mode=0o755)
        self.key.rename(keys / self.key.name)
        self.key = keys / self.key.name
        with patch.object(self.helper, 'CI_KEYRING', str(self.key)):
            self.setup()
            for target, mode in ((keys, 0o775), (keys, 0o777),
                                 (self.key, 0o664), (self.key, 0o666)):
                original_mode = target.stat().st_mode & 0o777
                target.chmod(mode)
                try:
                    with self.subTest(target=target.name, mode=mode), \
                            patch.object(self.helper.subprocess, 'run') as execute:
                        for operation in (self.setup, self.run_apt):
                            with self.assertRaises(self.helper.PreparationError) as error:
                                operation()
                            self.assertEqual(error.exception.category, 'permissions')
                        execute.assert_not_called()
                        self.assertEqual(target.stat().st_mode & 0o777, mode)
                finally:
                    target.chmod(original_mode)

    def test_selected_keyring_missing_or_linked_never_falls_back(self):
        self.setup()
        original = self.parent / 'saved-key'
        self.key.rename(original)
        for variant in ('missing', 'symlink', 'hardlink'):
            if variant == 'symlink':
                self.key.symlink_to(original)
            elif variant == 'hardlink':
                os.link(original, self.key)
            try:
                with self.subTest(variant=variant), patch.object(self.helper.subprocess, 'run') as execute, \
                        self.assertRaises((OSError, self.helper.PreparationError)):
                    self.run_apt()
                execute.assert_not_called()
            finally:
                if variant != 'missing':
                    self.key.unlink()
        original.rename(self.key)
        self.assertEqual(self.run_apt()[0], 0)

    def test_selected_keyring_directory_symlink_is_rejected(self):
        alias = self.parent / 'key-directory-alias'
        alias.symlink_to(self.key.parent, target_is_directory=True)
        with patch.object(self.helper, 'CI_KEYRING', str(alias / self.key.name)), \
                patch.object(self.helper.subprocess, 'run') as execute, self.assertRaises(OSError):
            self.setup()
        execute.assert_not_called()

    def test_signature_fingerprint_removed_from_sources_blocks_apt(self):
        self.setup()
        source = self.root / 'ubuntu.sources'
        original = source.read_bytes()
        source.write_bytes(original.replace((' ' + self.helper.CI_SIGNER).encode('ascii'), b''))
        with patch.object(self.helper.subprocess, 'run') as execute, \
                self.assertRaises(self.helper.PreparationError) as error:
            self.run_apt()
        self.assertEqual(error.exception.category, 'source-fields')
        execute.assert_not_called()


class ProcessExitObservationTests(unittest.TestCase):
    """Exercise bounded fixture exit and conservative procfs observations."""

    @staticmethod
    def observation(snapshots):
        clock = [0.0]
        sleeps = []
        reads = [0]

        def read_stat():
            snapshot = snapshots[min(reads[0], len(snapshots) - 1)]
            reads[0] += 1
            if isinstance(snapshot, BaseException):
                raise snapshot
            if snapshot is None:
                raise FileNotFoundError
            state, starttime = snapshot
            fields = ["0"] * 20
            fields[0], fields[6], fields[19] = state, "4", starttime
            return "123 (apt fixture) " + " ".join(fields)

        def sleep(delay):
            sleeps.append(delay)
            clock[0] += delay

        def observe():
            require_fixture_process_exit(123, "71", read_stat=read_stat,
                                         monotonic=lambda: clock[0], sleep=sleep)

        return observe, clock, sleeps, reads

    def test_absent_or_terminal_fixture_needs_no_wait(self):
        for snapshot in (None, ("Z", "71"), ("X", "71")):
            with self.subTest(snapshot=snapshot):
                observe, clock, sleeps, reads = self.observation([snapshot])
                observe()
                self.assertEqual((clock[0], sleeps, reads[0]), (0, [], 1))

    def test_running_fixture_must_become_terminal_or_absent(self):
        for terminal in (None, ("Z", "71"), ("X", "71")):
            with self.subTest(terminal=terminal):
                observe, clock, sleeps, reads = self.observation([("R", "71"), terminal])
                observe()
                self.assertEqual((clock[0], sleeps, reads[0]), (0.005, [0.005], 2))

    def test_surviving_fixture_is_rejected_at_the_bounded_deadline(self):
        # Even PF_EXITING in stat flags is not evidence of terminal state.
        for state in ("R", "S", "D", "T"):
            with self.subTest(state=state):
                observe, clock, sleeps, reads = self.observation([(state, "71")])
                with self.assertRaisesRegex(AssertionError, "still executing after 1s"):
                    observe()
                self.assertEqual(clock[0], 1.0)
                self.assertTrue(all(0 < delay <= 0.005 for delay in sleeps))
                self.assertLessEqual(reads[0], 202)

    def test_reused_pid_cannot_supply_another_process_terminal_state(self):
        observe, clock, sleeps, reads = self.observation([("R", "71"), ("Z", "72")])
        with self.assertRaisesRegex(AssertionError, "PID identity changed"):
            observe()
        self.assertEqual((clock[0], sleeps, reads[0]), (0.005, [0.005], 2))

    def test_reaped_proc_stat_descriptor_requires_a_fresh_absence_observation(self):
        with subprocess.Popen([sys.executable, "-I", "-B", "-c",
                               "import signal; signal.pause()"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as process:
            path = Path("/proc", str(process.pid), "stat")
            try:
                starttime = path.read_text().rsplit(") ", 1)[1].split()[19]
                with path.open() as held:
                    process.terminate()
                    process.wait(timeout=3)
                    with self.assertRaises(ProcessLookupError) as reaped:
                        held.read()
                    self.assertEqual(reaped.exception.errno, errno.ESRCH)
                    reads = []

                    def stale_once():
                        reads.append(path)
                        return held.read() if len(reads) == 1 else path.read_text()

                    require_fixture_process_exit(process.pid, starttime, read_stat=stale_once)
                    self.assertEqual(len(reads), 2)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)

    def test_esrch_recheck_keeps_terminal_identity_and_survival_guards(self):
        for terminal in (None, ("Z", "71"), ("X", "71")):
            with self.subTest(terminal=terminal):
                observe, clock, sleeps, reads = self.observation([
                    ProcessLookupError(errno.ESRCH, "stale fixture stat"), terminal])
                observe()
                self.assertEqual((clock[0], sleeps, reads[0]), (0, [], 2))
        observe, clock, sleeps, reads = self.observation([
            ProcessLookupError(errno.ESRCH, "stale fixture stat"), ("R", "71")])
        with self.assertRaisesRegex(AssertionError, "still executing after 1s"):
            observe()
        self.assertEqual(clock[0], 1.0)
        self.assertLessEqual(reads[0], 203)
        observe, clock, sleeps, reads = self.observation([
            ProcessLookupError(errno.ESRCH, "stale fixture stat"), ("Z", "72")])
        with self.assertRaisesRegex(AssertionError, "PID identity changed"):
            observe()
        self.assertEqual((clock[0], sleeps, reads[0]), (0, [], 2))

    def test_unreadable_proc_stat_never_authorizes_fixture_exit(self):
        for error in (ProcessLookupError(errno.ESRCH, "still unreadable"),
                      PermissionError(errno.EACCES, "denied"), OSError(errno.EIO, "read failed")):
            with self.subTest(error=type(error).__name__):
                observe, clock, sleeps, reads = self.observation([
                    ProcessLookupError(errno.ESRCH, "stale fixture stat"), error])
                with self.assertRaises(type(error)) as refused:
                    observe()
                self.assertIs(refused.exception, error)
                self.assertEqual((clock[0], sleeps, reads[0]), (0, [], 2))
        for error in (PermissionError(errno.EACCES, "denied"), OSError(errno.EIO, "read failed")):
            with self.subTest(first_error=type(error).__name__):
                observe, clock, sleeps, reads = self.observation([error])
                with self.assertRaises(type(error)) as refused:
                    observe()
                self.assertIs(refused.exception, error)
                self.assertEqual((clock[0], sleeps, reads[0]), (0, [], 1))


class VersionBoundaryTests(unittest.TestCase):
    """Replay real workflow scripts with inert remote-read fixtures, never GitHub."""

    @staticmethod
    def step(workflow, name):
        text = (PROJECT / ".github/workflows" / workflow).read_text()
        block = text.split("      - name: " + name + "\n", 1)[1]
        block = block.split("\n      - ", 1)[0].split("        run: |\n", 1)[1]
        return "\n".join(line[10:] for line in block.splitlines()
                         if line.startswith("          ")) + "\n"

    def test_first_failure_capture_is_scoped_to_two_stress_invocations(self):
        step = self.step("stress.yml", "Repeat race-sensitive integration scenarios with bounded jitter")
        with tempfile.TemporaryDirectory() as temporary:
            probe = Path(temporary) / "bash"
            probe.write_text('#!/bin/sh\n'
                             'test "$*" = "./tests/mock-integration.sh --group stress-signals" || exit 65\n'
                             'printf "capture=%s\\n" "$YTDLP_STRESS_FIRST_FAILURE"\n')
            probe.chmod(0o755)
            for shard in range(1, 5):
                with self.subTest(shard=shard):
                    env = dict(os.environ, STRESS_SHARD=str(shard), YTDLP_STRESS_FIRST_FAILURE="2:18",
                               PATH=temporary + os.pathsep + os.environ["PATH"])
                    output = subprocess.check_output(["/bin/bash", "-c", step], env=env, text=True)
                    captures = [line for line in output.splitlines() if line.startswith("capture=")]
                    selected = {(2, 18): "capture=2:18", (4, 12): "capture=4:12"}
                    expected = [selected.get((shard, n), "capture=") for n in range(shard, 21, 4)]
                    self.assertEqual(captures, expected)

    def test_media_apt_blocks_preserve_errors_signals_and_stop_stalled_provisioning(self):
        targets = (("real-tools.yml", "Install real engines"),
                   ("real-tools.yml", "Install real engines and current yt-dlp stable"),
                   ("release.yml", "Install current Ubuntu engines and pinned yt-dlp"))
        expected_options = ["-o", "Acquire::Retries=3", "-o", "Acquire::http::Timeout=30",
                            "-o", "Acquire::https::Timeout=30", "-o", "DPkg::Lock::Timeout=60"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            sudo = binary / "sudo"
            sudo.write_text('#!/bin/bash\n'
                            'if [[ $* == "python3 -I -B scripts/ci-ubuntu-mirrors.py --setup" ]]; then exit 0; fi\n'
                            'exec "$@"\n')
            sudo.chmod(0o755)
            proxy = binary / "python3"
            proxy.write_text('#!/bin/bash\n'
                             'if [[ $* == "-I -B scripts/ci-ubuntu-mirrors.py --apt "* ]]; then\n'
                             '    shift 4; exec apt-get "$@"\n'
                             'fi\n'
                             f'exec "{sys.executable}" "$@"\n')
            proxy.chmod(0o755)
            apt = binary / "apt-get"
            apt.write_text('''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
args = sys.argv[1:]
stage = "install" if "install" in args else "update"
with open(os.environ["CHECK_APT_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "stage": stage, "frontend": os.environ.get("DEBIAN_FRONTEND")}) + "\\n")
if stage == os.environ["CHECK_APT_STAGE"]:
    action = os.environ["CHECK_APT_ACTION"]
    if action == "failure":
        raise SystemExit(23 if stage == "update" else 27)
    if action == "interrupt":
        os.kill(os.getpid(), signal.SIGTERM)
    if action in {"stall", "ignore-term"}:
        starttime = Path("/proc/self/stat").read_text().rsplit(") ", 1)[1].split()[19]
        Path(os.environ["CHECK_APT_PID"]).write_text(json.dumps({"pid": os.getpid(), "starttime": starttime}))
        if action == "ignore-term":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            signal.pause()
''')
            apt.chmod(0o755)
            for workflow, step_name in targets:
                script = self.step(workflow, step_name)
                # Stop at the real APT boundary; the marker represents the
                # subsequent venv/pip work, never a substitute package command.
                ending = "\ncase ${YT_DLP_VERSION}" if "\ncase ${YT_DLP_VERSION}" in script else "\npython3 -m venv"
                prefix = script.split(ending, 1)[0]
                self.assertIn("ci-ubuntu-mirrors.py --apt", prefix)
                self.assertNotIn("python3 -m venv", prefix)
                for stage, action, expected in (("none", "success", 0), ("update", "failure", 23),
                                                 ("install", "failure", 27), ("update", "interrupt", 143),
                                                 ("install", "interrupt", 143), ("update", "stall", 124),
                                                 ("install", "stall", 124), ("install", "ignore-term", 137)):
                    with self.subTest(workflow=workflow, step=step_name, stage=stage, action=action):
                        run = root / f"case-{len(list(root.iterdir()))}"
                        run.mkdir()
                        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                                   CHECK_APT_STAGE=stage, CHECK_APT_ACTION=action,
                                   CHECK_APT_LOG=str(run / "calls"), CHECK_APT_PID=str(run / "pid"),
                                   CHECK_CONTINUED=str(run / "continued"))
                        env.pop("DEBIAN_FRONTEND", None)
                        current = prefix
                        if action in {"stall", "ignore-term"}:
                            current, count = re.subn(
                                r'(?m)^sudo timeout --signal=TERM --kill-after=10s (?:[1-9][0-9]*m|"\$\{apt_remaining\}s") ',
                                "sudo timeout --signal=TERM --kill-after=0.1s 0.5s ", current,
                            )
                            self.assertEqual(count, 2)
                        current += '\nprintf completed >"${CHECK_CONTINUED}"\n'
                        result = subprocess.run(["bash", "-c", current], env=env, capture_output=True,
                                                text=True, timeout=5, check=False)
                        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                        self.assertEqual((run / "continued").exists(), expected == 0)
                        calls = [json.loads(line) for line in (run / "calls").read_text().splitlines()]
                        self.assertEqual([call["stage"] for call in calls],
                                         ["update"] if stage == "update" else ["update", "install"])
                        for call in calls:
                            self.assertEqual(call["args"][:8], expected_options)
                            if call["stage"] == "update":
                                self.assertEqual(call["args"][8:], ["-o", "APT::Update::Error-Mode=any", "update"])
                            else:
                                self.assertEqual(call["args"][8:11], ["install", "--yes", "--no-install-recommends"])
                                self.assertEqual(call["frontend"], "noninteractive")
                        if (run / "pid").exists():
                            identity = json.loads((run / "pid").read_text())
                            # SIGKILL also terminates GNU timeout. Its child can
                            # close inherited pipes before the kernel exposes a
                            # terminal state; wait briefly for actual quiescence.
                            require_fixture_process_exit(identity["pid"], identity["starttime"])

    def test_pinned_install_uses_only_the_remaining_apt_budget(self):
        script = self.step("real-tools.yml", "Install real engines").split("\ncase ${YT_DLP_VERSION}", 1)[0]
        # Substitute the kernel clock and record what the unchanged shell passes
        # to timeout. Updating the clock in the update call fixes the chronology.
        script = script.replace("/proc/uptime", '"${CHECK_UPTIME}"')
        stub = r'''
sudo() {
    case $1 in
        python3) [[ ${!#} == --setup ]] ;;
        timeout)
            if [[ ${!#} == update ]]; then
                printf 'update %s\n' "$4"
                printf '%s' "${CHECK_AFTER}" >"${CHECK_UPTIME}"
            else
                printf 'install %s\n' "$4"
            fi
            ;;
        *) return 64 ;;
    esac
}
'''
        def uptime_record(value):
            return f"{value} 1234.56\n" if value else ""

        with tempfile.TemporaryDirectory() as temporary:
            clock = Path(temporary) / "uptime"

            def replay(before, after, status, expected_calls):
                with self.subTest(before=before, after=after):
                    clock.write_text(uptime_record(before))
                    env = dict(os.environ, CHECK_UPTIME=str(clock), CHECK_AFTER=uptime_record(after))
                    result = subprocess.run(["bash", "-c", stub + script + "\necho continued\n"],
                                            env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), expected_calls)

            update = ["update 3m"]
            for before, after, expected in (("1000.01", "1000.99", "479s"),
                                            ("1000.99", "1008.01", "471s"),
                                            ("1000.01", "1048.90", "431s"),
                                            ("1000.01", "1144.99", "335s"),
                                            ("1000.01", "1478.99", "1s"),
                                            ("0008.99", "0016.01", "471s"),
                                            ("999999999991.99", "999999999999.01", "471s")):
                replay(before, after, 0, [*update, "install " + expected, "continued"])

            for after in ("1479.00", "1480.01", "999.99"):
                replay("1000.01", after, 124, update)

            for invalid in ("", "nonsense", "1+1.00", "１.00", "1000.2", "1000.123", "1000000000000.00"):
                replay(invalid, "1008.01", 65, [])
                replay("1000.01", invalid, 65, update)

    def test_pinned_engine_installation_preserves_hashes_and_pip_failure(self):
        pins = {"2026.6.9": "442ba4c75724b9496144c8434b617962ee08d0ee7c26ec663848fe9b78d5a3e4",
                "2026.7.4": "f11f2b11d5a8ac4059f9bdf29fa4407dc7c6bb00c5097e95ca22a7a9db518266",
                "2026.8.19": "1d57897e94c6665a0a6f9bc54b34e584284e32c034ffab3a7df25d8f7b24eedf"}
        for workflow, name, versions in (("real-tools.yml", "Install real engines", tuple(pins)),
                                         ("release.yml", "Install current Ubuntu engines and pinned yt-dlp",
                                          ("2026.6.9", "2026.8.19"))):
            script = self.step(workflow, name)
            script = "set -Eeuo pipefail\npython3() { return 0; }\n" + script[script.index("case ${YT_DLP_VERSION}"):]
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for version in versions:
                    for status in (0, 23):
                        with self.subTest(workflow=workflow, version=version, status=status):
                            run = root / f"{version}-{status}"
                            binary = run / "yt-dlp-venv/bin"
                            binary.mkdir(parents=True)
                            pip = binary / "pip"
                            pip.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >"${CHECK_ARGUMENTS}"\n'
                                           'exit "${CHECK_PIP_STATUS}"\n')
                            pip.chmod(0o755)
                            env = dict(os.environ, RUNNER_TEMP=str(run), YT_DLP_VERSION=version,
                                       GITHUB_PATH=str(run / "path"), CHECK_ARGUMENTS=str(run / "arguments"),
                                       CHECK_PIP_STATUS=str(status))
                            result = subprocess.run(["bash", "-c", script], env=env,
                                                    capture_output=True, timeout=5, check=False)
                            self.assertEqual(result.returncode, status, result.stderr)
                            arguments = (run / "arguments").read_text().splitlines()
                            self.assertEqual(arguments[:4], ["install", "--disable-pip-version-check",
                                                            "--only-binary=:all:", "--require-hashes"])
                            self.assertEqual(arguments[4], "--requirement")
                            self.assertEqual(Path(arguments[5]).read_text(),
                                             f"yt-dlp=={version} --hash=sha256:{pins[version]}\n")
                            self.assertEqual((run / "path").exists(), status == 0)

    def test_minimum_bash_bootstrap_authenticates_before_extracting_or_building(self):
        script = self.step("shell.yml", "Build and bind verified Bash 4.4 on the disposable runner")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            upstream = root / "upstream/bash-4.4"
            upstream.mkdir(parents=True)
            configure = upstream / "configure"
            configure.write_text('#!/bin/bash\nprintf build >>"${CHECK_BUILD}"\nexit 42\n')
            configure.chmod(0o755)
            archive = root / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                output.add(upstream, arcname="bash-4.4")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            script = re.sub(r"readonly source_sha=[0-9a-f]{64}", "readonly source_sha=" + digest, script)
            fixture = r'''
curl() {
    local output='' url=''
    while (($#)); do
        case $1 in --output) output=$2; shift ;; https://*) url=$1 ;; esac
        shift
    done
    printf download >>"${CHECK_DOWNLOAD}"
    case ${url} in
        *.tar.gz) cp -- "${CHECK_ARCHIVE}" "${output}" ;;
        *) printf 'inert verification fixture\n' >"${output}" ;;
    esac
}
gpgv() {
    [[ ${CHECK_SIGNATURE} != failure ]] || return 23
    local fingerprint=7C0135FB088AAF6C66C650B9BB5869F064EA74AB
    [[ ${CHECK_SIGNATURE} != wrong ]] || fingerprint=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    printf '[GNUPG:] VALIDSIG %s 2016-09-14 1473863216 0 4 0 17 2 00 %s\n' \
        "${fingerprint}" "${fingerprint}"
}
tar() { printf extract >>"${CHECK_EXTRACT}"; command tar "$@"; }
sudo() { printf 'Unexpected host mutation\n' >&2; return 99; }
'''
            for condition, expected in (("valid", 42), ("checksum", 1), ("wrong", 1),
                                        ("failure", 23), ("self-hosted", 1)):
                with self.subTest(condition=condition):
                    run = root / condition
                    run.mkdir()
                    current = script.replace("readonly source_sha=" + digest,
                                             "readonly source_sha=" + "0" * 64) if condition == "checksum" else script
                    env = dict(os.environ, RUNNER_TEMP=str(run), GITHUB_PATH=str(run / "path"),
                               GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="self-hosted" if condition == "self-hosted" else "github-hosted",
                               CHECK_ARCHIVE=str(archive), CHECK_SIGNATURE=condition,
                               CHECK_BUILD=str(run / "build"), CHECK_EXTRACT=str(run / "extract"),
                               CHECK_DOWNLOAD=str(run / "download"))
                    result = subprocess.run(["bash", "-c", fixture + current], env=env,
                                            capture_output=True, timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual((run / "extract").exists(), condition == "valid")
                    self.assertEqual((run / "build").exists(), condition == "valid")
                    self.assertEqual((run / "download").exists(), condition != "self-hosted")

    def test_deno_bootstrap_refuses_bad_digest_before_extracting_or_executing(self):
        for step_name, expected_version in (
                ("Install verified Deno for shared-destination qualification", "2.9.4"),
                ("Install verified Deno for current-stable shared qualification", "2.9.8")):
            script = self.step("real-tools.yml", step_name)
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "deno.zip"
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr("deno", '#!/bin/bash\nprintf executed >>"${CHECK_EXECUTE}"\n'
                                    'printf "deno %s\\n" "${CHECK_VERSION}"\n')
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                fixture = r'''
    curl() {
        while (($#)); do
            if [[ $1 == --output ]]; then cp -- "${CHECK_ARCHIVE}" "$2"; return; fi
            shift
        done
        return 99
    }
    unzip() { printf inspect >>"${CHECK_EXTRACT}"; command unzip "$@"; }
    '''
                for condition, valid_digest, installed_version, expected in (
                        ("bad-digest", False, expected_version, 1),
                        ("wrong-version", True, "0.0.0", 1),
                        ("valid", True, expected_version, 0)):
                    with self.subTest(step=step_name, condition=condition):
                        run = root / condition
                        run.mkdir()
                        current = re.sub(r"readonly archive_sha=[0-9a-f]{64}",
                                         "readonly archive_sha=" + (digest if valid_digest else "0" * 64), script)
                        env = dict(os.environ, RUNNER_TEMP=str(run), GITHUB_PATH=str(run / "path"),
                                   CHECK_ARCHIVE=str(archive), CHECK_EXECUTE=str(run / "execute"),
                                   CHECK_EXTRACT=str(run / "extract"), CHECK_VERSION=installed_version)
                        result = subprocess.run(["bash", "-c", fixture + current], env=env,
                                                capture_output=True, timeout=10, check=False)
                        self.assertEqual(result.returncode, expected, result.stderr)
                        self.assertEqual((run / "extract").exists(), valid_digest)
                        self.assertEqual((run / "execute").exists(), valid_digest)
                        self.assertEqual((run / "path").exists(), expected == 0)

    def test_current_stable_metadata_requires_bounded_official_stable_release(self):
        import contextlib
        import io
        from types import SimpleNamespace
        import urllib.error
        import urllib.request

        script = self.step("real-tools.yml", "Install real engines and current yt-dlp stable")
        program = script.split("<<'PY_STABLE_VERSION'\n", 1)[1].split("\nPY_STABLE_VERSION", 1)[0]
        valid = {"name": "yt-dlp", "version": "2026.8.19", "yanked": False, "requires_python": ">=3.10"}
        variants = [("valid", json.dumps({"info": valid}).encode(), True)]
        for name, replacement in (("prerelease", {"version": "2026.8.19rc1"}),
                                  ("development", {"version": "2026.8.19.dev1"}),
                                  ("multiline", {"version": "2026.8.19\nFORGED=value"}),
                                  ("invalid-calendar", {"version": "2026.2.30"}),
                                  ("non-string", {"version": 2026}),
                                  ("other-project", {"name": "other-project"}),
                                  ("yanked", {"yanked": True})):
            variants.append((name, json.dumps({"info": dict(valid, **replacement)}).encode(), False))
        variants.extend((("missing-info", b"{}", False), ("invalid-json", b"broken", False),
                         ("oversized", b" " * (8 * 1024 * 1024 + 1), False)))
        with tempfile.TemporaryDirectory() as temporary:
            for name, payload, accepted in variants:
                with self.subTest(variant=name):
                    destination = Path(temporary) / (name + ".json")
                    calls = []

                    def read(size):
                        calls.append(("read", size))
                        return payload

                    def open_response(source, timeout):
                        calls.append(("open", source, timeout))
                        return contextlib.nullcontext(SimpleNamespace(read=read))

                    def opener(handler):
                        with self.assertRaisesRegex(ValueError, "redirects"):
                            handler.redirect_request(None, None, 302, "redirect", {}, "http://fixture.invalid/")
                        return SimpleNamespace(open=open_response)

                    output = io.StringIO()
                    with patch.object(sys, "argv", ["-", str(destination)]), \
                            patch.object(urllib.request, "build_opener", side_effect=opener), \
                            contextlib.redirect_stdout(output):
                        if accepted:
                            exec(compile(program, "workflow-stable-metadata", "exec"), {})
                        else:
                            with self.assertRaises((ValueError, KeyError)):
                                exec(compile(program, "workflow-stable-metadata", "exec"), {})
                    self.assertEqual(calls, [("open", "https://pypi.org/pypi/yt-dlp/json", 30),
                                             ("read", 8 * 1024 * 1024 + 1)])
                    self.assertEqual(destination.exists(), accepted)
                    self.assertEqual(output.getvalue(), "2026.8.19\n" if accepted else "")
                    if accepted:
                        record = json.loads(destination.read_text())
                        self.assertEqual(record["package_version"], valid["version"])
                        self.assertEqual(record["source"], "https://pypi.org/pypi/yt-dlp/json")
                        self.assertIsNotNone(datetime.fromisoformat(record["observed_at"]).tzinfo)
            with patch.object(urllib.request, "build_opener", side_effect=urllib.error.URLError("unavailable")):
                with self.assertRaises(urllib.error.URLError):
                    exec(compile(program, "workflow-stable-metadata", "exec"), {})

    def test_current_stable_installs_exact_selected_version_or_preserves_failure(self):
        script = self.step("real-tools.yml", "Install real engines and current yt-dlp stable")
        # Exercise the real resolution/install boundary without apt or network.
        script = "set -Eeuo pipefail\n" + script[script.index('python3 -m venv "${RUNNER_TEMP}/yt-dlp-venv"'):]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for variant, pip_status, installed, expected in (("valid", 0, "2026.8.19", 0),
                                                            ("dependency-refusal", 23, "2026.8.19", 23),
                                                            ("substituted-version", 0, "2026.7.4", 1)):
                with self.subTest(variant=variant):
                    run = root / variant
                    binary = run / "yt-dlp-venv/bin"
                    binary.mkdir(parents=True)
                    python = binary / "python"
                    python.write_text('#!/bin/bash\nif [[ $1 == - ]]; then printf "2026.8.19\\n"; '
                                      'else printf "%s\\n" "${CHECK_INSTALLED}"; fi\n')
                    python.chmod(0o755)
                    pip = binary / "pip"
                    pip.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >"${CHECK_ARGUMENTS}"\n'
                                   'exit "${CHECK_PIP_STATUS}"\n')
                    pip.chmod(0o755)
                    env = dict(os.environ, RUNNER_TEMP=str(run), GITHUB_ENV=str(run / "env"),
                               GITHUB_PATH=str(run / "path"), CHECK_ARGUMENTS=str(run / "arguments"),
                               CHECK_INSTALLED=installed, CHECK_PIP_STATUS=str(pip_status))
                    result = subprocess.run(["bash", "-c", "python3() { return 0; }\n" + script],
                                            env=env, capture_output=True, timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    arguments = (run / "arguments").read_text().splitlines()
                    self.assertEqual(arguments[-1], "yt-dlp[pin-curl-cffi]==2026.8.19")
                    self.assertNotIn("--upgrade", arguments)
                    self.assertEqual((run / "env").exists(), not expected)
                    self.assertEqual((run / "path").exists(), not expected)

    def test_current_stable_version_record_rejects_multiline_and_run_rejects_substitution(self):
        record = self.step("real-tools.yml", "Record resolved current-stable tool versions")
        run = self.step("real-tools.yml", "Run current-stable shared-destination GUI and CLI qualification")
        fixture = r'''
deno() { printf 'deno 2.9.4\n'; }
aria2c() { printf 'aria2 fixture\n'; }
ffmpeg() { printf 'ffmpeg fixture\n'; }
ffprobe() { printf 'ffprobe fixture\n'; }
timeout() { printf invoked >"${CHECK_RUN}"; }
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "yt-dlp-venv/bin"
            binary.mkdir(parents=True)
            for name, body in (("yt-dlp", 'printf "%s\\n" "${CHECK_VERSION}"'),
                               ("python", 'printf "%s\\n" "${CHECK_PACKAGE_VERSION}"'),
                               ("pip", 'printf "fixture==1\\n"')):
                path = binary / name
                path.write_text("#!/bin/bash\n" + body + "\n")
                path.chmod(0o755)
            evidence = root / "shared-destination-evidence"
            evidence.mkdir()
            (evidence / "stable-resolution.json").write_text('{"package_version":"2026.8.19"}\n')
            env = dict(os.environ, RUNNER_TEMP=str(root), GITHUB_ENV=str(root / "env"),
                       TMPDIR=str(root / "evidence"), CHECK_RUN=str(root / "invoked"),
                       CURRENT_STABLE_YTDLP_PACKAGE_VERSION="2026.8.19", CHECK_PACKAGE_VERSION="2026.8.19")
            for version, expected in (("2026.08.19\nFORGED=value", 1), ("2026.08.19", 0)):
                with self.subTest(version=version):
                    result = subprocess.run(["bash", "-c", fixture + record],
                                            env=dict(env, CHECK_VERSION=version), capture_output=True,
                                            timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual((root / "env").exists(), not expected)
            self.assertEqual((root / "env").read_text(), "CURRENT_STABLE_YTDLP_VERSION=2026.08.19\n")
            for selected, expected in (("2026.07.04", 1), ("2026.08.19", 0)):
                with self.subTest(selected=selected):
                    result = subprocess.run(["bash", "-c", fixture + run],
                                            env=dict(env, CHECK_VERSION="2026.08.19", CURRENT_STABLE_YTDLP_VERSION=selected),
                                            capture_output=True, timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual((root / "invoked").exists(), not expected)

    def test_current_stable_deno_metadata_policy_fails_closed(self):
        import contextlib
        import io
        from types import SimpleNamespace
        from importlib import metadata

        script = self.step("real-tools.yml", "Validate current-stable shared prerequisites")
        program = script.split("<<'PY_DENO_COMPAT'\n", 1)[1].split("\nPY_DENO_COMPAT", 1)[0]
        # pip supplies PEP 508 parsing in the workflow venv. Replace only that
        # external parser so ordinary repository validation need not install pip.
        usable = SimpleNamespace(name="deno", marker=None, url=None, specifier={"2.9.8"})
        too_new = copy.copy(usable)
        too_new.specifier = {"99.0.0"}
        direct = copy.copy(usable)
        direct.url = "https://fixture.invalid/deno.whl"
        other_extra = copy.copy(too_new)
        other_extra.marker = SimpleNamespace(evaluate=lambda context: context["extra"] == "pin-deno")
        unrelated = copy.copy(too_new)
        unrelated.name = "other-runtime"
        modules = {
            "pip._vendor.packaging.requirements": SimpleNamespace(Requirement=lambda value: value),
            "pip._vendor.packaging.version": SimpleNamespace(Version=lambda value: value),
        }
        for requirements, version, accepted in (
                ([usable], "2.9.8", True), ([usable], "2.9.4", False),
                ([usable, other_extra, unrelated], "2.9.8", True),
                ([], "2.9.8", False), ([other_extra], "2.9.8", False),
                ([too_new], "2.9.8", False), ([usable, too_new], "2.9.8", False),
                ([direct], "2.9.8", False)):
            with self.subTest(requirements=requirements, version=version), patch.dict(sys.modules, modules), \
                    patch.object(sys, "argv", ["-", version]), \
                    patch.object(metadata, "requires", return_value=requirements), \
                    contextlib.redirect_stdout(io.StringIO()):
                if accepted:
                    exec(compile(program, "workflow-deno-compatibility", "exec"), {})
                else:
                    with self.assertRaisesRegex(SystemExit, "does not satisfy"):
                        exec(compile(program, "workflow-deno-compatibility", "exec"), {})

    def test_development_artifact_names_bind_source_and_run_across_consumer_reruns(self):
        text = (PROJECT / ".github/workflows/packages.yml").read_text()
        rpm_names = re.findall(r"(?m)^          name: (rpm-under-test-.+)$", text)
        # Producer and consumer share a run-scoped identity even if only the
        # consumer is rerun. Attempt metadata belongs to the artifact producer.
        self.assertEqual(rpm_names, [
            "rpm-under-test-${{ github.sha }}-${{ github.run_id }}",
            "rpm-under-test-${{ github.sha }}-${{ github.run_id }}",
        ])
        self.assertIn("name: deb-under-test-${{ github.sha }}-${{ github.run_id }}", text)

    def test_ordinary_same_version_package_candidate_keeps_real_upgrade_baseline(self):
        script = self.step("packages.yml", "Resolve previous semantic-version release")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "download-video.sh"
            engine.write_text('#!/bin/bash\nprintf "download-video.sh version 2.3.26\\n"\n')
            engine.chmod(0o755)
            fixture = r'''
git() {
    case $1 in
        rev-parse) printf '%s\n' "${CHECK_COMMIT}" ;;
        merge-base) [[ ${CHECK_ANCESTRY} == yes ]] ;;
        *) printf 'Unexpected Git operation\n' >&2; return 99 ;;
    esac
}
gh() {
    [[ $1 == api ]] || return 99
    [[ ${CHECK_API_FAILURE} == no ]] || return 17
    printf '%s\n' "${CHECK_RELEASES}"
}
'''
            for releases, ancestry, api_failure, expected in (
                    ("v99.0.0\nv2.3.26\nv2.3.17", "yes", "no", 0),
                    ("v2.3.26\nv2.3.17", "no", "no", 65),
                    ("v2.3.26", "yes", "no", 65),
                    ("v2.3.26\nv2.3.17", "yes", "yes", 17)):
                with self.subTest(releases=releases, ancestry=ancestry, api_failure=api_failure):
                    output = root / "output"
                    output.unlink(missing_ok=True)
                    env = dict(os.environ, GITHUB_OUTPUT=str(output), CHECK_COMMIT=SOURCE,
                               GITHUB_EVENT_NAME="pull_request", GITHUB_HEAD_REF="ordinary-change",
                               GITHUB_REPOSITORY="fixture/project", CHECK_RELEASES=releases,
                               CHECK_ANCESTRY=ancestry, CHECK_API_FAILURE=api_failure)
                    result = subprocess.run(["bash", "-c", fixture + script], cwd=root, env=env,
                                            capture_output=True, timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected == 0:
                        self.assertEqual(output.read_text(),
                                         f"tag=v2.3.17\nversion=2.3.17\ncommit={SOURCE}\n")
                    else:
                        self.assertFalse(output.exists())

    def test_release_still_refuses_tag_version_mismatch(self):
        script = self.step("release.yml", "Verify tag and versions")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # The actual candidate carriers retain their real source/published checks.
            for path in ("download-video.sh", "install-fedora.sh", "README.md", "README.fr.md",
                         "test-static.sh", "CHANGELOG.md", "scripts/check-push-version.py",
                         "scripts/update-published-version.py",
                         "packaging/rpm/yt-dlp-aria2-downloader-gui.spec"):
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(PROJECT / path, destination)
            version = subprocess.check_output([str(root / "download-video.sh"), "--version"], text=True).split()[-1]
            fixture = 'git() { if [[ $1 == rev-parse ]]; then printf "%s\\n" "${GITHUB_SHA}"; fi; }\n'
            for tag, expected in (("v" + version, 0), ("v999.9.9", 65)):
                with self.subTest(tag=tag):
                    result = subprocess.run(["bash", "-c", fixture + script], cwd=root,
                                            env=dict(os.environ, RELEASE_TAG=tag, GITHUB_SHA=SOURCE,
                                                     GITHUB_EVENT_NAME="push"), capture_output=True,
                                            timeout=10, check=False)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertIn(b"release executable version mismatch", result.stderr)

    def test_existing_publication_accepts_only_identical_bytes(self):
        script = self.step("release.yml", "Publish and verify immutable release")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dist").mkdir()
            (root / "published").mkdir()
            names = ("fixture.zip", "fixture.rpm", "fixture.deb", "install-fedora.sh",
                     "RPM-GPG-KEY-OscarFrog", "SHA256SUMS")
            for name in names:
                (root / "dist" / name).write_text("tested bytes\n")
                (root / "published" / name).write_text("tested bytes\n")
            fixture = r'''
gh() {
    [[ $1 == release ]] || return 99
    case $2 in
        view)
            if [[ $# == 3 ]]; then return 0; fi
            case $5 in
                assets) printf '%s\n' fixture.zip fixture.rpm fixture.deb install-fedora.sh RPM-GPG-KEY-OscarFrog SHA256SUMS ;;
                isImmutable) printf 'true\n' ;;
                *) return 99 ;;
            esac ;;
        download) cp -- "published/${7}" "${5}/${7}" ;;
        verify|verify-asset) return 0 ;;
        *) printf 'Forbidden publication mutation: %s\n' "$2" >&2; return 99 ;;
    esac
}
'''
            for changed in (False, True):
                with self.subTest(changed=changed):
                    if changed:
                        (root / "dist/fixture.rpm").write_text("different source payload\n")
                    result = subprocess.run(["bash", "-c", fixture + script], cwd=root,
                                            env=dict(os.environ, RELEASE_TAG="v2.3.26",
                                                     GITHUB_REPOSITORY="fixture/project"),
                                            capture_output=True, timeout=10, check=False)
                    self.assertEqual(result.returncode, 65 if changed else 0, result.stderr)
                    if changed:
                        self.assertIn(b"differs byte-for-byte", result.stderr)


class PassiveDiagnosticsTests(unittest.TestCase):
    """Exercise passive reads and the real Ubuntu step without running suites."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "ci_diagnostics", PROJECT / "scripts/ci-validation-diagnostics.py")
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)

    def directories(self, root):
        diagnostics, logs = root / "diagnostics", root / "logs"
        for directory in (diagnostics, logs):
            directory.mkdir(mode=0o700)
        return diagnostics, logs

    def test_exact_vocabulary_does_not_disclose_valid_prefix_secrets(self):
        helper = self.helper
        accepted = b"Mock scenario: config-crlf"
        self.assertEqual(helper.selected_line(accepted), accepted.decode())
        for line in (b"Mock scenario: secret-token-valid-alnum",
                     accepted + b"-secret-token", accepted + b" secret-token",
                     b"Payload secret-token: " + b"a" * 64,
                     b"Payload download-video.sh: " + b"x" * 64):
            with self.subTest(line=line):
                self.assertIsNone(helper.selected_line(line))
        for line, expected in (
            (b"FAIL: https://private.invalid/?secret-token", "failure-diagnostic-present"),
            (b"Installed helper contract passed: /secret-token", "installed-helper-contract-passed"),
            (b"Payload download-video.sh: " + b"a" * 64, "installed-payload-checked"),
        ):
            self.assertEqual(helper.selected_line(line), expected)
            self.assertNotIn("secret-token", helper.selected_line(line))

    def test_open_log_descriptors_preserve_late_data_after_unlink(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as temporary:
            diagnostics, logs = self.directories(Path(temporary))
            helper.publish(str(diagnostics), str(logs))
            directory = helper.private_directory(str(diagnostics))
            reader = helper.LogReader(directory)
            try:
                self.assertEqual(set(reader.sample()), set(helper.LOG_NAMES))
                with (logs / helper.LOG_NAMES[0]).open("ab") as producer:
                    for name in helper.LOG_NAMES:
                        (logs / name).unlink()
                    logs.rmdir()
                    producer.write(b"Mock scenario: config-crlf\nFAIL: secret-token\n")
                    producer.flush()
                    sample = reader.sample()[helper.LOG_NAMES[0]]
                    self.assertEqual(sample["events"], ["Mock scenario: config-crlf",
                                                        "failure-diagnostic-present"])
                    self.assertNotIn("secret-token", json.dumps(sample))
            finally:
                reader.close()
                os.close(directory)

    def test_refuses_unsafe_paths_rendezvous_and_log_files_without_blocking(self):
        helper = self.helper
        variants = ("directory-link", "ancestor-link", "permissions", "wrong-owner",
                    "record-link", "oversize-record", "wrong-identity", "log-link", "log-fifo")
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                diagnostics, logs = self.directories(root)
                helper.publish(str(diagnostics), str(logs))
                if variant in ("directory-link", "ancestor-link", "permissions", "wrong-owner"):
                    target = str(diagnostics)
                    if variant == "directory-link":
                        (root / "alias").symlink_to(diagnostics)
                        target = str(root / "alias")
                    elif variant == "ancestor-link":
                        (root / "alias").symlink_to(root)
                        target = str(root / "alias/diagnostics")
                    elif variant == "permissions":
                        diagnostics.chmod(0o755)
                    owner = os.geteuid() + (1 if variant == "wrong-owner" else 0)
                    with patch.object(helper.os, "geteuid", return_value=owner):
                        with self.assertRaises((OSError, ValueError)):
                            helper.private_directory(target)
                    continue
                record = diagnostics / "logs.json"
                if variant == "record-link":
                    record.rename(diagnostics / "original")
                    record.symlink_to(diagnostics / "original")
                elif variant == "oversize-record":
                    record.write_bytes(b"secret-token" * helper.MAX_READ)
                elif variant == "wrong-identity":
                    payload = json.loads(record.read_text())
                    payload["inode"] += 1
                    record.write_text(json.dumps(payload))
                elif variant.startswith("log-"):
                    (logs / helper.LOG_NAMES[0]).unlink()
                    if variant == "log-link":
                        (logs / helper.LOG_NAMES[0]).symlink_to(record)
                    else:
                        os.mkfifo(logs / helper.LOG_NAMES[0], 0o600)
                directory = helper.private_directory(str(diagnostics))
                reader = helper.LogReader(directory)
                try:
                    with self.assertRaises((OSError, ValueError)):
                        reader.sample()
                finally:
                    reader.close()
                    os.close(directory)

    def test_unknown_and_oversized_lines_and_total_read_bound(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as temporary:
            diagnostics, logs = self.directories(Path(temporary))
            helper.publish(str(diagnostics), str(logs))
            path = logs / helper.LOG_NAMES[0]
            path.write_bytes(b"x" * (helper.MAX_LINE + 1) + b"Mock scenario: config-crlf\n"
                             b"Mock scenario: secret-token\nMock scenario: config-crlf\n")
            directory = helper.private_directory(str(diagnostics))
            reader = helper.LogReader(directory)
            try:
                sample = reader.sample()[helper.LOG_NAMES[0]]
                self.assertEqual(sample["events"], ["Mock scenario: config-crlf"])
                with patch.object(helper, "MAX_LOG_BYTES", sample["bytes_read"] + 7):
                    with path.open("ab") as producer:
                        producer.write(b"secret-token" * 50)
                    bounded = reader.sample()[helper.LOG_NAMES[0]]
                    self.assertTrue(bounded["size_bound"])
                    self.assertEqual(bounded["bytes_read"], sample["bytes_read"] + 7)
                    self.assertEqual(reader.sample()[helper.LOG_NAMES[0]]["events"], [])
            finally:
                reader.close()
                os.close(directory)

    def test_observer_real_counters_stop_and_finite_bound(self):
        import contextlib
        import io
        helper = self.helper
        with tempfile.TemporaryDirectory() as temporary:
            diagnostics, logs = self.directories(Path(temporary))
            helper.publish(str(diagnostics), str(logs))
            (diagnostics / "done").touch(mode=0o600)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(helper.observe(str(diagnostics)), 0)
            row = json.loads(output.getvalue())
            self.assertTrue(row["done"])
            self.assertTrue(row["logs_attached"])
            self.assertIn("/proc/stat", row["counters"])
            self.assertEqual(len(row["counters"]["/proc/loadavg"]["value"].split()), 3)
            (diagnostics / "done").unlink()
            output = io.StringIO()
            with patch.object(helper, "MAX_SAMPLES", 2), patch.object(helper.time, "sleep"), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(helper.observe(str(diagnostics)), 70)
            rows = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(len(rows), 2)
            self.assertTrue(rows[-1]["expired"])
            with patch.object(helper.os, "open", side_effect=PermissionError(13, "secret-token")):
                self.assertEqual(helper.counter("/proc/stat"), {"error": "PermissionError", "errno": 13})

    def test_done_requires_handoff_and_drains_tail_beyond_one_chunk(self):
        import contextlib
        import io
        helper = self.helper
        for variant in ("missing", "tail", "size-bound"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temporary:
                diagnostics, logs = self.directories(Path(temporary))
                if variant != "missing":
                    helper.publish(str(diagnostics), str(logs))
                    size = helper.MAX_READ * 2 if variant == "tail" else helper.MAX_LOG_BYTES + 1
                    (logs / helper.LOG_NAMES[0]).write_bytes(
                        b"x" * size + b"\nMock scenario: config-crlf\n")
                (diagnostics / "done").touch(mode=0o600)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    status = helper.observe(str(diagnostics))
                row = json.loads(output.getvalue())
                self.assertEqual(status, 0 if variant == "tail" else 65)
                self.assertEqual(row["complete"], variant == "tail")
                if variant == "tail":
                    self.assertEqual(row["logs"][helper.LOG_NAMES[0]]["last_event"],
                                     "Mock scenario: config-crlf")
                elif variant == "size-bound":
                    self.assertTrue(row["logs"][helper.LOG_NAMES[0]]["size_bound"])
                    self.assertEqual(row["logs"][helper.LOG_NAMES[0]]["bytes_read"],
                                     helper.MAX_LOG_BYTES)
                else:
                    self.assertFalse(row["logs_attached"])

    def test_failed_fstat_closes_the_opened_descriptor(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "done").touch(mode=0o600)
            directory = helper.private_directory(str(root))
            real_open = os.open
            opened = []

            def record_open(*args, **kwargs):
                descriptor = real_open(*args, **kwargs)
                opened.append(descriptor)
                return descriptor

            try:
                with patch.object(helper.os, "open", side_effect=record_open), \
                        patch.object(helper.os, "fstat", side_effect=OSError(5, "fixture")):
                    with self.assertRaises(OSError):
                        helper.private_file(directory, "done")
                self.assertEqual(len(opened), 1)
                with self.assertRaises(OSError):
                    os.fstat(opened[0])
            finally:
                os.close(directory)

    def test_publish_does_not_replace_existing_rendezvous(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as temporary:
            diagnostics, logs = self.directories(Path(temporary))
            record = diagnostics / "logs.json"
            record.write_text("preserve-me")
            record.chmod(0o600)
            with self.assertRaises(FileExistsError):
                helper.publish(str(diagnostics), str(logs))
            self.assertEqual(record.read_text(), "preserve-me")

    def test_runner_consumes_optional_variable_before_any_child(self):
        source = (PROJECT / "tests/run-all.sh").read_text()
        main = source[source.rindex("\nmain() {\n"):]
        fixture = r'''
set -euo pipefail
parse_arguments() { DOCTOR_ONLY=false; LIST_ONLY=false; PROFILE=full; JOBS=4; }
validate_shell_file_arrays() { :; }
validate_suite_manifest() { :; }
test_runner_initialize() { TEST_RUNNER_LOG_DIR=${CHECK_LOGS}; }
cleanup() { :; }
test_runner_now_ms() { printf '1\n'; }
test_runner_format_duration() { printf -v "$2" '0.000s'; }
run_static_validation() {
    python3 -c 'import os; assert "YTDLP_ARIA2_CI_DIAGNOSTICS_DIR" not in os.environ'
    [[ -f ${CHECK_DIAGNOSTICS}/logs.json ]]
    printf 'private rendezvous, child environment clean\n'
}
run_integration_suites() { run_static_validation; }
'''
        with tempfile.TemporaryDirectory() as temporary:
            diagnostics, logs = self.directories(Path(temporary))
            result = subprocess.run(["bash", "-c", fixture + main], cwd=PROJECT,
                                    env=dict(os.environ, PROJECT_DIR=str(PROJECT),
                                             CHECK_LOGS=str(logs), CHECK_DIAGNOSTICS=str(diagnostics),
                                             YTDLP_ARIA2_CI_DIAGNOSTICS_DIR=str(diagnostics)),
                                    capture_output=True, text=True, timeout=5, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("child environment clean"), 2)
            self.assertEqual(json.loads((diagnostics / "logs.json").read_text())["directory"], str(logs))

    def test_real_workflow_step_preserves_statuses_and_observer_failure(self):
        script = VersionBoundaryTests.step("shell.yml", "Run validation")
        command = "timeout --signal=TERM --kill-after=10s 7m bash ./tests/run-all.sh --jobs 4"
        self.assertIn(command, script)
        fixture = r'''
umask "${CHECK_INCOMING_UMASK}"
python3() {
    if [[ ${4:-} == observe && ${CHECK_OBSERVER_FAILURE} == 1 ]]; then
        command python3 "$1" "$2" "$3" "$4" "${CHECK_INVALID_DIAGNOSTICS}"
        return
    fi
    command python3 "$@"
}
timeout() {
    [[ "$*" == '--signal=TERM --kill-after=10s 7m bash ./tests/run-all.sh --jobs 4' ]] || return 98
    # Exercise the EXIT path before normal collection or log handoff.
    if [[ ${CHECK_COMMAND_STATUS} == 27 ]]; then exit 27; fi
    shift 3
    if [[ ${CHECK_TIMEOUT} == 1 ]]; then
        command timeout --signal=TERM --kill-after=10s 0.05s "$@"
    else
        "$@"
    fi
}
'''
        cases = ((0, False, False, 0), (23, False, False, 23), (27, False, False, 27),
                 (0, True, False, 124), (0, False, True, 65), (23, False, True, 23))
        for case, incoming_umask in ((case, mask) for case in cases for mask in ("0022", "0077")):
            command_status, expired, observer_failed, expected = case
            with self.subTest(status=expected, expired=expired, observer_failed=observer_failed,
                              umask=incoming_umask), \
                    tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for directory in ("scripts", "tests", "runner-temp", "logs"):
                    (root / directory).mkdir(mode=0o700)
                (root / "invalid").mkdir(mode=0o755)
                (root / "invalid").chmod(0o755)
                shutil.copyfile(PROJECT / "scripts/ci-validation-diagnostics.py",
                                root / "scripts/ci-validation-diagnostics.py")
                (root / "tests/run-all.sh").write_text(r'''
set -euo pipefail
[[ $(umask) == "${CHECK_INCOMING_UMASK}" ]] || exit 96
command python3 -I -B scripts/ci-validation-diagnostics.py publish \
    "${YTDLP_ARIA2_CI_DIAGNOSTICS_DIR}" "${CHECK_LOGS}"
printf 'Mock scenario: config-crlf\n' >"${CHECK_LOGS}/mock-gui-state.log"
if [[ ${CHECK_TIMEOUT} == 1 ]]; then sleep 1; fi
exit "${CHECK_COMMAND_STATUS}"
''')
                result = subprocess.run(["bash", "-c", fixture + script], cwd=root,
                                        env=dict(os.environ, RUNNER_TEMP=str(root / "runner-temp"),
                                                 CHECK_LOGS=str(root / "logs"),
                                                 CHECK_INVALID_DIAGNOSTICS=str(root / "invalid"),
                                                 CHECK_INCOMING_UMASK=incoming_umask,
                                                 CHECK_COMMAND_STATUS=str(command_status),
                                                 CHECK_TIMEOUT=str(int(expired)),
                                                 CHECK_OBSERVER_FAILURE=str(int(observer_failed))),
                                        capture_output=True, text=True, timeout=5, check=False)
                self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
                records = list((root / "runner-temp").glob("*/samples.jsonl"))
                self.assertEqual(len(records), 1)
                self.assertTrue((records[0].parent / "done").is_file())
                if not observer_failed:
                    rows = [json.loads(line) for line in records[0].read_text().splitlines()]
                    self.assertTrue(rows[-1]["done"])
                self.assertIn(f"Validation status: {124 if expired else command_status};", result.stdout)


if __name__ == "__main__":
    unittest.main()
