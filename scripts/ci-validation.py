# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/ci-validation.py.

Verify GitHub qualification records against an exact squash-merged Git tree.
Read authenticated Actions metadata; never trust a cache or candidate artifact.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time


REPOSITORY = "OscarFrog/yt-dlp-aria2-downloader-gui"
OID = re.compile(r"[0-9a-f]{40}")
IDENTITY_PREFIX = "Source identity "
MAX_BYTES = 8 * 1024 * 1024
MAX_PAGES = 10
WORKFLOWS = {
    "shell.yml": {
        "Ubuntu", "Fedora 44", "Python 3.10 / Ubuntu",
    },
    "packages.yml": {
        "Git-free source archive", "Previous immutable release",
        "Fedora 44 RPM build-once", "Fedora 44 RPM (fresh)",
        "Fedora 44 RPM (ffmpeg-free)", "Ubuntu 24.04 DEB",
    },
    "qualification.yml": {
        "FFmpeg 6.1.1 / Ubuntu 24.04", "FFmpeg 8.1.2 / Fedora 44",
        "FFmpeg 9.0.1 / verified upstream source",
    },
    "real-tools.yml": {
        "Local media, pinned yt-dlp 2026.6.9",
        "Local media, pinned yt-dlp 2026.7.4",
        "Local media, pinned yt-dlp 2026.8.19",
    },
    "stress.yml": {
        *(f"Mock process/cancellation stress shard {shard}/4" for shard in range(1, 5)),
        "Mock process/cancellation stress (20x deterministic jitter)",
        "Runtime-manager hardening (10 rollback/contention cycles)",
    },
}
SCHEDULED_JOB = "Scheduled current stable yt-dlp"
REQUIRED_STEPS = {
    "Ubuntu": {"Check workflow syntax and embedded shell", "Run validation"},
    "Fedora 44": {"Run validation"},
    "Python 3.10 / Ubuntu": {"Exercise the complete contract under Python 3.10"},
    "Git-free source archive": {"Build and retest Git-free source archive"},
    "Previous immutable release": {"Resolve previous semantic-version release", "Verify exact published previous packages"},
    "Fedora 44 RPM build-once": {"Build RPM once", "Qualify RPM v4/v6 signature semantics"},
    "Ubuntu 24.04 DEB": {"Build, lifecycle, reinstall, and upgrade DEB"},
    **{f"Fedora 44 RPM ({scenario})": {
        "Reject a different globally trusted RPM signer in PR CI",
        "Confirm unsigned PR RPM is rejected by release bootstrap",
        "Install exact unsigned PR RPM through explicit development bootstrap",
        "Validate installed environment", "Remove and re-run exact RPM lifecycle",
        "Test previous immutable release -> current RPM upgrade",
    } for scenario in ("fresh", "ffmpeg-free")},
    **{name: {f"Qualify FFmpeg {version} generation"} for name, version in (
        ("FFmpeg 6.1.1 / Ubuntu 24.04", "6.1.1"),
        ("FFmpeg 8.1.2 / Fedora 44", "8.1.2"),
        ("FFmpeg 9.0.1 / verified upstream source", "9.0.1"),
    )},
    **{f"Local media, pinned yt-dlp {version}": {
        "Run direct, audio, HLS and DASH boundary qualification",
        "Run aria2 direct-transfer behavior qualification",
        "Run real FFmpeg progress qualification", "Run HLS post-remux duration validation",
    } for version in ("2026.6.9", "2026.7.4", "2026.8.19")},
    **{f"Mock process/cancellation stress shard {shard}/4": {
        "Repeat race-sensitive integration scenarios with bounded jitter",
    } for shard in range(1, 5)},
    "Mock process/cancellation stress (20x deterministic jitter)": {
        "Require all cancellation stress shards", "Require every complementary qualification before merge",
    },
    "Runtime-manager hardening (10 rollback/contention cycles)": {
        "Qualify runtime-manager transactions and contention",
    },
}
ALLOWED_SKIPS = {
    ("Fedora 44 RPM (ffmpeg-free)", "Test previous immutable release -> current RPM upgrade"),
    *((f"Local media, pinned yt-dlp {version}", step)
      for version in ("2026.6.9", "2026.7.4")
      for step in ("Run real FFmpeg progress qualification", "Run HLS post-remux duration validation")),
}


def required_steps(job_name, filename):
    if job_name.startswith(IDENTITY_PREFIX):
        steps = {"Bind validation to the event source"}
        if filename != "shell.yml":
            steps.add("Require successful shell validation before qualification")
        return steps
    return REQUIRED_STEPS[job_name]


class Refusal(Exception):
    """A sanitized, fail-closed qualification refusal."""


class Pending(Exception):
    """The expected current qualification run has not completed yet."""


class Interrupted(Exception):
    """Stop the active metadata subprocess when the caller is cancelled."""

    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    raise Interrupted(signum)


def require(condition, message):
    if not condition:
        raise Refusal(message)


def oid(value):
    require(isinstance(value, str) and OID.fullmatch(value), "Invalid Git object identity.")
    return value


def integer(value):
    require(type(value) is int and value > 0, "Invalid GitHub numeric identity.")
    return value


def timestamp(value):
    require(isinstance(value, str), "Missing GitHub timestamp.")
    try:
        result = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise Refusal("Invalid GitHub timestamp.") from error
    return result


class GitHub:
    """Read only the fixed public repository, with credentials in the environment."""

    def get(self, endpoint):
        environment = os.environ.copy()
        require(bool(environment.get("GH_TOKEN")), "GH_TOKEN is required for authenticated GitHub reads.")
        environment.update(GH_HOST="github.com", GH_PROMPT_DISABLED="1", GH_PAGER="cat")
        process = subprocess.Popen(
            ["gh", "api", "--hostname", "github.com", "--method", "GET",
             "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28",
             f"repos/{REPOSITORY}/{endpoint}"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=environment, start_new_session=True,
        )
        try:
            output = read_response(process)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        finally:
            process.stdout.close()
        require(process.returncode == 0, "Authenticated GitHub metadata read failed; no proof was reused.")
        try:
            return json.loads(output)
        except (ValueError, UnicodeError) as error:
            raise Refusal("Invalid GitHub metadata response.") from error


def read_response(process):
    """Bound subprocess output while reading, including a stalled API response."""
    output = bytearray()
    deadline = time.monotonic() + 45
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise subprocess.TimeoutExpired("gh", 45)
            chunk = os.read(process.stdout.fileno(), min(65536, MAX_BYTES + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            require(len(output) <= MAX_BYTES, "GitHub metadata exceeds the supported size.")
    process.wait(timeout=max(0, deadline - time.monotonic()))
    return bytes(output)


class Verifier:
    def __init__(self, api, now=None):
        self.api = api
        self.now = now

    def observed_timestamp(self, value):
        observed = timestamp(value)
        require(observed <= (self.now or datetime.now(timezone.utc)),
                "Qualification metadata is future-dated.")
        return observed

    def pages(self, endpoint, key=None):
        results = []
        separator = "&" if "?" in endpoint else "?"
        for page in range(1, MAX_PAGES + 1):
            response = self.api.get(f"{endpoint}{separator}per_page=100&page={page}")
            batch = response if key is None else response[key]
            require(isinstance(batch, list) and len(batch) <= 100, "Invalid GitHub pagination response.")
            results.extend(batch)
            if len(batch) < 100:
                return results
        raise Refusal("GitHub metadata pagination limit reached; incomplete evidence is not accepted.")

    def commit(self, sha):
        result = self.api.get(f"git/commits/{oid(sha)}")
        require(result["sha"] == sha, "Git commit response does not match the requested object.")
        oid(result["tree"]["sha"])
        require(isinstance(result["parents"], list), "Missing Git parent identities.")
        for parent in result["parents"]:
            oid(parent["sha"])
        return result

    def pull(self, number):
        result = self.api.get(f"pulls/{integer(number)}")
        require(result["number"] == number, "Pull request identity changed.")
        require(result["base"]["repo"]["full_name"] == REPOSITORY and result["base"]["ref"] == "main",
                "Qualification must originate from a pull request targeting this repository's main.")
        oid(result["head"]["sha"])
        # Fork contributions are valid. Their head repository must still match
        # the authenticated run; a deleted/unavailable fork fails closed.
        require(isinstance(result["head"]["repo"]["full_name"], str), "PR head repository is unavailable.")
        require(isinstance(result["head"]["ref"], str) and result["head"]["ref"], "PR head branch is unavailable.")
        return result

    def workflow(self, filename):
        result = self.api.get(f"actions/workflows/{filename}")
        integer(result["id"])
        require(result["path"] == f".github/workflows/{filename}" and result["state"] == "active",
                "Required qualification workflow is missing, disabled or has a different path.")
        return result

    def latest(self, workflow, pull):
        runs = self.pages(
            f"actions/workflows/{workflow['id']}/runs?event=pull_request&head_sha={pull['head']['sha']}",
            "workflow_runs",
        )
        # GitHub empties run.pull_requests after merge. The authoritative
        # association is commit -> merged PR -> head, plus the merge parents.
        candidates = []
        for run in runs:
            references = run["pull_requests"]
            require(isinstance(references, list), "Missing workflow PR association metadata.")
            if references and not any(item["number"] == pull["number"] for item in references):
                continue
            candidates.append(run)
        if not candidates:
            raise Pending("The current PR has no required qualification run yet.")
        return max(candidates, key=lambda run: (timestamp(run["created_at"]), integer(run["id"])))

    def run_metadata(self, run, workflow, pull):
        integer(run["id"])
        integer(run["run_attempt"])
        require(run["workflow_id"] == workflow["id"] and run["path"] == workflow["path"],
                "Workflow run identity or definition path differs from the required workflow.")
        require(run["repository"]["full_name"] == REPOSITORY,
                "Workflow run belongs to another repository.")
        require(run["head_repository"]["full_name"] == pull["head"]["repo"]["full_name"],
                "Workflow run belongs to another PR head repository.")
        require(run["event"] == "pull_request" and run["head_sha"] == pull["head"]["sha"],
                "Workflow run event or PR head does not match the merged revision.")
        require(run["head_branch"] == pull["head"]["ref"],
                "Workflow run used a different PR branch and contextual package policy.")
        if run["status"] != "completed":
            require(run["status"] in {"queued", "in_progress", "waiting", "pending", "requested"},
                    "Unrecognized workflow run state.")
            raise Pending("The latest required qualification run is still pending.")
        require(run["conclusion"] == "success", "The latest required workflow run did not succeed.")
        # Successful qualification is a historical fact about this exact source
        # and workflow contract; elapsed time alone does not invalidate it.
        # This does not certify future external dependencies: scheduled probes
        # and checks on the final release artifacts qualify those separately.
        created = self.observed_timestamp(run["created_at"])
        updated = self.observed_timestamp(run["updated_at"])
        require(created <= updated, "Qualification run timestamps are inconsistent.")

    def qualified_source(self, run, filename):
        jobs = self.pages(
            f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs",
        )
        names = [job["name"] for job in jobs]
        require(len(names) == len(set(names)), "Duplicate qualification job identities.")
        identities = [name for name in names if name.startswith(IDENTITY_PREFIX)]
        require(len(identities) == 1, "Exactly one GitHub source identity job is required.")
        source = oid(identities[0][len(IDENTITY_PREFIX):])
        expected = WORKFLOWS[filename] | {identities[0]}
        if filename == "real-tools.yml":
            expected |= {SCHEDULED_JOB}
        require(set(names) == expected, "Required qualification job inventory has changed or is incomplete.")
        for job in jobs:
            require(job["run_id"] == run["id"] and job["status"] == "completed",
                    "Qualification job is incomplete or belongs to another run.")
            if job["name"] == SCHEDULED_JOB:
                require(job["conclusion"] == "skipped", "Scheduled diagnostics cannot replace pinned qualification.")
                continue
            require(job["conclusion"] == "success", "A required qualification job did not succeed.")
            steps = job["steps"]
            require(isinstance(steps, list) and steps, "Required qualification step metadata is empty.")
            step_names = [step["name"] for step in steps]
            mandatory = required_steps(job["name"], filename)
            require(all(step_names.count(name) == 1 for name in mandatory),
                    "Required qualification steps are missing or duplicated.")
            for step in steps:
                expected_conclusion = "skipped" if (job["name"], step["name"]) in ALLOWED_SKIPS else "success"
                require(step["status"] == "completed" and step["conclusion"] == expected_conclusion,
                        "A qualification step failed, is incomplete or was unexpectedly skipped.")
            completed = self.observed_timestamp(job["completed_at"])
            require(timestamp(run["created_at"]) <= completed <= timestamp(run["updated_at"]),
                    "Qualification job timestamp is outside its workflow run.")
        # This name is resolved from github.sha by GitHub, independently of
        # run.head_sha (the PR head). The workflow checks the checkout against
        # it. Whole-tree equality below also binds every workflow and parameter.
        return self.commit(source)

    @staticmethod
    def snapshot(run):
        return tuple(run[key] for key in (
            "id", "run_attempt", "status", "conclusion", "head_sha", "workflow_id", "path", "updated_at",
        ))

    def unchanged(self, original, workflow, pull):
        current = self.latest(workflow, pull)
        require(self.snapshot(current) == self.snapshot(original),
                "Latest qualification run or attempt changed during verification; retry explicitly.")
        current = self.api.get(f"actions/runs/{original['id']}")
        self.run_metadata(current, workflow, pull)
        require(self.snapshot(current) == self.snapshot(original),
                "Qualification run changed during verification; retry explicitly.")

    def verify(self, sha):
        target = self.commit(sha)
        require(len(target["parents"]) == 1, "Promotion requires a squash commit with exactly one parent.")
        comparison = self.api.get(f"compare/{sha}...main")
        require(comparison["status"] in {"ahead", "identical"}
                and comparison["merge_base_commit"]["sha"] == sha,
                "Promoted commit is not an ancestor of the canonical main branch.")
        associated = self.pages(f"commits/{sha}/pulls")
        candidates = [item for item in associated if item["merge_commit_sha"] == sha]
        require(len(candidates) == 1, "Exactly one merged PR must identify the promoted squash commit.")
        pull = self.pull(candidates[0]["number"])
        require(pull["merged"] is True and pull["merge_commit_sha"] == sha,
                "Promoted commit is not the final commit of the merged PR.")
        timestamp(pull["merged_at"])
        proofs = []
        for filename in WORKFLOWS:
            workflow = self.workflow(filename)
            run = self.latest(workflow, pull)
            self.run_metadata(run, workflow, pull)
            source = self.qualified_source(run, filename)
            require(source["tree"]["sha"] == target["tree"]["sha"],
                    "Qualified Git tree differs from the promoted tree.")
            require([parent["sha"] for parent in source["parents"]] == [
                target["parents"][0]["sha"], pull["head"]["sha"],
            ], "The qualified virtual merge has different main or PR parents.")
            proofs.append((workflow, run, source["sha"]))
        current_pull = self.pull(pull["number"])
        require(current_pull["merged"] is True and current_pull["merge_commit_sha"] == sha
                and current_pull["head"] == pull["head"], "Merged PR identity changed during verification.")
        for workflow, run, _ in proofs:
            self.unchanged(run, workflow, pull)
        return {
            "commit": sha, "tree": target["tree"]["sha"], "pull_request": pull["number"],
            "qualifications": [{"workflow": workflow["path"], "run_id": run["id"],
                                "run_attempt": run["run_attempt"], "source_commit": source,
                                "url": f"https://github.com/{REPOSITORY}/actions/runs/{run['id']}"}
                               for workflow, run, source in proofs],
        }

    def qualification(self, sha, pull, filename):
        workflow = self.workflow(filename)
        run = self.latest(workflow, pull)
        self.run_metadata(run, workflow, pull)
        source = self.qualified_source(run, filename)
        require(source["sha"] == sha, "Qualification tested a different virtual merge commit.")
        require([parent["sha"] for parent in source["parents"]] == [
            oid(pull["base"]["sha"]), oid(pull["head"]["sha"]),
        ], "Qualification does not match the triggering PR base and head.")
        self.unchanged(run, workflow, pull)
        return workflow, run

    def shell(self, sha, pull):
        _, run = self.qualification(sha, pull, "shell.yml")
        return run["id"]

    def required(self, sha, pull, verified):
        # The existing required stress check aggregates the other workflows.
        # Waiting on stress itself here would deadlock its own terminal job.
        pending = False
        for filename in WORKFLOWS:
            if filename == "stress.yml" or filename in verified:
                continue
            try:
                verified[filename] = self.qualification(sha, pull, filename)
            except Pending:
                pending = True
        if pending:
            raise Pending("Complementary PR qualifications are still pending.")
        # Retain completed observations only within this process to bound API
        # polling. Revalidate every latest run before opening the merge gate.
        for workflow, run in verified.values():
            self.unchanged(run, workflow, pull)
        return {filename: run["id"] for filename, (_, run) in verified.items()}


def event_pull():
    require(os.environ.get("GITHUB_EVENT_NAME") == "pull_request", "Shell waiting requires a pull_request event.")
    path = Path(os.environ["GITHUB_EVENT_PATH"])
    with path.open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, "PR event metadata exceeds the supported size.")
    result = json.loads(data)["pull_request"]
    require(result["base"]["repo"]["full_name"] == REPOSITORY and result["base"]["ref"] == "main",
            "Shell waiting requires a PR targeting the canonical main branch.")
    integer(result["number"])
    oid(result["head"]["sha"])
    oid(result["base"]["sha"])
    return result


def main():
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify", "wait-shell", "wait-required"))
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        oid(args.commit)
        require(os.environ.get("GITHUB_REPOSITORY", REPOSITORY) == REPOSITORY,
                "Qualification promotion is restricted to the canonical repository.")
        api = GitHub()
        if args.command == "verify":
            print(json.dumps(Verifier(api).verify(args.commit), sort_keys=True, indent=2))
            return 0
        pull = event_pull()
        minutes = 13 if args.command == "wait-shell" else 45
        deadline = time.monotonic() + minutes * 60
        verified = {}
        while time.monotonic() < deadline:
            try:
                verifier = Verifier(api)
                result = (verifier.shell(args.commit, pull) if args.command == "wait-shell"
                          else verifier.required(args.commit, pull, verified))
                print(f"PR qualification accepted: {json.dumps(result, sort_keys=True)}, source {args.commit}.")
                return 0
            except Pending:
                print("Waiting for the latest required qualifications of this exact PR merge.", flush=True)
                time.sleep(min(15, max(0, deadline - time.monotonic())))
        raise Refusal(f"Required qualification did not complete within {minutes} minutes.")
    except (Refusal, Pending) as error:
        print(f"Qualification refused: {error}", file=sys.stderr)
    except Interrupted as error:
        print("Qualification interrupted; no proof was accepted.", file=sys.stderr)
        return 128 + error.signum
    except (KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired):
        print("Qualification refused: metadata unavailable or malformed; no previous success was reused.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
