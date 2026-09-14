# Repository agent instructions

This file is the repository-wide router and invariant set for coding agents.
Detailed shell, testing, architecture, and tracked-file policy lives in the
authoritative documents linked below.

Start Codex with this checkout as its project/current directory, not its parent.
Repository instructions, skills and trusted `.codex/rules` are discovered from
the startup context; changing a shell command's working directory does not prove
they were loaded. See `TESTING.md` → **Codex session setup and task routing**.

## Scope and precedence

These instructions apply to the complete repository: production code, tests,
documentation, packaging, configuration, and workflows.

Before changing a file, inspect the relevant implementation, documentation,
tests, and mechanical validation. Do not replace established project contracts
with generic conventions.

If a nested `AGENTS.md` is added later, it may refine instructions for that
subtree. It must not weaken repository-wide safety, privacy, supply-chain,
release, or validation invariants.

Within the repository policy, and subject to the host's system/developer
instructions and enforced permissions, use this order:

1. explicit task requirements;
2. applicable `AGENTS.md` instructions;
3. authoritative repository documents;
4. mechanically enforced validation and tests;
5. external style guides and generic recommendations.

A mismatch between documented policy and mechanical validation is a repository
defect. Resolve both surfaces together.

## Project map and sources of truth

| Document | Authoritative scope |
| --- | --- |
| `ARCHITECTURE.md` | Component interactions, data flow, process supervision, trust boundaries, packaging, CI, and release topology |
| `SHELL_STYLE.md` | Bash structure, headers, idioms, comments, shfmt, ShellCheck, and shell inventories |
| `TESTING.md` | Local profiles, targeted suites, CI coverage, qualifications, and release-only procedures |
| `REPOSITORY_FILES.md` | Exact tracked-file inventory, each file's consumer, packaging status, and retention reason |
| `README.md` and `README.fr.md` | Current English and French user-facing behavior, requirements, installation, and usage |
| `CHANGELOG.md` | Chronological release history, not current operating policy |
| `.codex/rules/default.rules` | Fixed-helper route for unattended Git inspection plus mechanical prompts and prohibitions for direct, mutating, or remote Codex command prefixes |

Use `AGENTS.md` to decide what to read, not as a substitute for those documents.

## Route work by change type

Use the task-to-component/test table in `TESTING.md` before broad searches.
Read the relevant `ARCHITECTURE.md` flow, implementation, callers and focused
tests. Reuse already-read, unchanged policy within a task instead of repeatedly
reading the whole repository.

| Change | Required route |
| --- | --- |
| Bash, shell libraries or shell-bearing workflows | `.agents/skills/shell-change/SKILL.md`; read `SHELL_STYLE.md` in full |
| Python helpers or Bash/Python interfaces | `TESTING.md` → **Python changes**; inspect both ends of the interface |
| RPM/DEB, installation, cleanup, versions or release | `.agents/skills/packaging-release/SKILL.md` and matching workflow/static contracts |
| GitHub Actions, pins, signatures or provenance | `.agents/skills/workflow-supply-chain/SKILL.md`; `./scripts/check-workflows.sh` for workflow changes |
| User-facing behavior/documentation | Both READMEs; keep English/French guidance equivalent |
| Added, removed, moved or repurposed files | `REPOSITORY_FILES.md` plus canonical source arrays in `tests/lib/project-files.sh` |
| Authorized source push | Standing version rule below, before expensive tests |

If a relevant repository skill is missing from the session's skill list, read
its explicit path above. File-structure tests do not prove runtime discovery.

When opening a task or pull request, use the repository templates to record the
objective, acceptance criteria, preserved invariants, actual validation, and
the exact level of external mutation authority. A selected template option
does not override the task text or grant authority by itself.

## File identity and inventories

Use language- and format-appropriate identity rather than copying the Bash
banner into every format.

- Canonical Bash files follow the exact header contract in `SHELL_STYLE.md`.
- Python source starts with the MIT SPDX identifier. Its first Python statement
  is a module docstring naming the project, repository-relative module path, and
  durable role. A deliberately non-executable Python helper has no shebang and
  is invoked explicitly with `python3`.
- Markdown titles, workflow `name` fields, desktop-entry keys, RPM and Debian
  metadata, manpage `NAME` sections, and OpenPGP packet identity are the native
  identifiers for those formats.
- `LICENSE` and packaging copyright metadata define repository-level licensing;
  source SPDX tags make it machine-readable where a source contract exists.

Keep the shell and Python inventories in `tests/lib/project-files.sh` accurate.
Keep the tracked-file table in `REPOSITORY_FILES.md` synchronized with Git and
update a row when a file's role, consumer, installation status, compatibility
purpose, or retention decision changes.

## Repository invariants

Treat established safety, privacy, trust-boundary, packaging, release,
installation, runtime-preservation, and cleanup behavior as intentional unless
the task explicitly changes it.

Prefer the smallest coherent change that satisfies the task and preserves
behavior outside its scope.

Do not delete or weaken a regression test merely to make a change pass. Change
a test only when the intended contract changes, and update the corresponding
documentation or policy in the same change when applicable.

Permanent comments explain durable intent, constraints, fallbacks, or caller
contracts. Keep chronological findings in commits, pull requests, issues,
`CHANGELOG.md`, or qualification reports.

## Code Review Rules

Treat the following as blocking findings unless the task explicitly and safely
changes the underlying contract:

- a GitHub Actions permission increase without demonstrated need, checkout
  credentials no longer disabled with `persist-credentials: false`, or a
  third-party Action not pinned to a full commit SHA with a readable version
  comment;
- a media URL, HTTP header, credential, token, cookie, or signing secret exposed
  through process arguments, logs, artifacts, or an untrusted execution path;
- candidate code or binaries executed inside a privileged publication job, or
  data crossing a trust boundary without the required digest, path, identity,
  or immutable-source revalidation;
- weakened signature, provenance, checksum, exact-version, release
  immutability, destination containment, symlink, or user-data-preservation
  checks;
- cancellation, process-group supervision, private temporary-file permissions,
  crash recovery, no-overwrite publication, or cleanup containment weakened;
- a regression test removed or relaxed without an explicit contract change and
  corresponding documentation;
- a shell file diverging from `SHELL_STYLE.md`, its canonical header, pinned
  formatting, or the canonical shell inventory;
- shared user-facing behavior changed in only one of the English or French
  READMEs;
- a tracked path added, removed, moved, or repurposed without an exact
  `REPOSITORY_FILES.md` update.

## Validation discipline

Use repository entry points instead of substituting ad hoc checks when a
canonical check exists.

Before selecting a validation profile on a new or restricted environment,
diagnose its capabilities without running the suite:

```bash
./tests/run-all.sh --doctor
```

Use `--doctor --json` when a machine-readable, versioned result is needed.

During development, run focused tests and, when useful:

```bash
./tests/run-all.sh --fast --jobs 4
```

Before review, run the complete local contract for repository changes:

```bash
./tests/run-all.sh --full --jobs 4
```

Run `python3 -B scripts/check-push-version.py coherence` before those suites.
It checks local version copies without network access or a required increment.
Use the live-remote `check` as well when a source push is authorized. Diagnose
cheap failures first; do not stack fast and full runs after every small edit.

For shell changes, also run `./scripts/check-shell-format.sh`. For workflow,
packaging, installation, cleanup, runtime, or release work, run the applicable
targeted qualifications documented in `TESTING.md`. Release-only, privileged,
interactive, or external-network procedures must not be claimed when they were
not actually run.

For every change, run `git diff --check` and inspect both staged and unstaged
diffs. A formatter result does not replace syntax, ShellCheck, integration,
packaging, or behavioral validation.

Diagnose a failure before rerunning it. If evidence proves an environmental or
timing failure, report that evidence and the successful rerun; do not hide an
unexplained failure.

## Delivery and release boundary

The protected `main` branch is updated through pull requests and required
checks. Do not bypass branch protection or force-push `main`.

For unattended repository inspection, use the tracked
`scripts/git-inspect.sh` helper. It accepts only fixed summary, log, status,
inventory, diff and diff-check actions, rejects caller-provided Git arguments, and runs under
the ordinary sandbox or baseline policy rather than an explicit Codex
`allow` rule. Its closed Git invocation trusts only the canonical physical path
of its own checkout so container ownership mappings cannot break inspection;
it never grants wildcard safe-directory trust. Direct Git, direct GitHub CLI,
Git global-option forms, and common environment wrappers remain interactive
when requested outside the sandbox.
More-specific rules document mutation intent and forbid common
force-push-to-`main` forms, including destination refspecs. These exact-argv
checks supplement task authority; they never create it and must not be
bypassed with another wrapper or spelling.

Do not create or push release tags, publish releases or packages, or alter
repository rules, secrets, or environments unless the task explicitly requests
that external or release action. Source-version preparation does not authorize
any of those actions.

### Standing rule: choose the version during release preparation

Ordinary commits, source pushes and PR merges do not require a version bump,
including follow-ups and automation branches. They may retain the last published
version. All source and published-reference carriers must remain coherent; the
hook validates the actual pushed objects, not only the working tree.

An explicit release preparation selects the target version from the accumulated
changes since the relevant release. Corrections to that unpublished candidate
may keep the same target unless the scope warrants another version. Freeze the
version before qualifying the candidate to tag; subsequent content changes
require the applicable validation of the new tree. A published version, its tag
and its assets must never be reused to distribute different contents.

Follow `TESTING.md` → **Version coherence and release preparation** for ordinary
push checks, explicit preparation and hook setup. Do not bypass the hook with
`--no-verify`, another hooks path, a wrapper or an API write. These checks grant
no authority to commit, push, merge, tag or publish.

Development artifacts are identified by their source SHA and CI run/attempt,
not by the shared numeric version alone. They are not official release assets.
The `shfmt-update.yml` and `release-docs.yml` automations retain the source
version and independently verify only their permitted transformations. Their
privileged publishers still validate data without executing candidate code.
An unchanged automation result produces no source push.

Tag-only pushes, deletions and no-ops are outside the source-coherence hook.
Tags and releases retain their separate explicit authorization, signed-tag
preflight and immutable-publication requirements. Source-push authorization
does not authorize an automatic version increment or publication.

## Completion checklist

Before finishing:

- review the diff for unrelated changes;
- verify source and tracked-file inventories;
- verify headers and native file identity for new or renamed files;
- verify workflow pins, permissions, credentials, and trust boundaries;
- verify English/French user documentation alignment when applicable;
- run and report the required validation honestly;
- summarize changed files and any qualification that could not be run.

Never claim that a test, build, release, or runtime behavior was verified unless
it was actually executed or directly inspected.
