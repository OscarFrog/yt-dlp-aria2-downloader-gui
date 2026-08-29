# Repository agent instructions

This file is the repository-wide router and invariant set for coding agents.
Detailed shell, testing, architecture, and tracked-file policy lives in the
authoritative documents linked below.

## Scope and precedence

These instructions apply to the complete repository: production code, tests,
documentation, packaging, configuration, and workflows.

Before changing a file, inspect the relevant implementation, documentation,
tests, and mechanical validation. Do not replace established project contracts
with generic conventions.

If a nested `AGENTS.md` is added later, it may refine instructions for that
subtree. It must not weaken repository-wide safety, privacy, supply-chain,
release, or validation invariants.

When requirements conflict, use this order:

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

Use `AGENTS.md` to decide what to read, not as a substitute for those documents.

## Route work by change type

- For runtime, GUI, progress, cancellation, transfer, or helper changes, read
  the matching sections of `ARCHITECTURE.md` and inspect the relevant focused
  integration tests before editing.
- For any shell source, shell library, generated shell fixture, or shell-bearing
  workflow block, read `SHELL_STYLE.md` in full and apply it as binding policy.
- For packaging, installation, cleanup, workflow, supply-chain, or release
  changes, read the relevant `ARCHITECTURE.md` and `TESTING.md` sections and
  inspect matching integration tests and static contracts.
- For user-facing behavior or documentation, inspect both `README.md` and
  `README.fr.md` and keep equivalent guidance aligned.
- For a tracked-file addition, removal, move, or rename, update
  `REPOSITORY_FILES.md` so every retained path has an explicit role and
  consumer.
- For a version or release-metadata change, inspect `test-static.sh`, the
  current `CHANGELOG.md` entry, packaging metadata, both READMEs, and release
  workflows before editing any version surface.

Repository skills under `.agents/skills/` provide task-specific reading and
validation routes. They do not replace the policies named above.

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

During development, run focused tests and, when useful:

```bash
./tests/run-all.sh --fast --jobs 4
```

Before review, run the complete local contract for repository changes:

```bash
./tests/run-all.sh --full --jobs 4
```

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

Do not create or push release tags, publish releases or packages, alter
repository rules, secrets, or environments, or initiate a version bump unless
the task explicitly requests that external or release action.

When a version change is explicitly requested, update every mechanically linked
version and documentation surface in one coherent change and run the release
preflight required by `TESTING.md`.

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
