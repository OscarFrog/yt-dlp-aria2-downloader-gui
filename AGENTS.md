# Repository agent instructions

This file defines persistent instructions for coding agents working in this
repository.

## Scope and instruction discovery

This file applies to the entire repository tree, including source code, tests,
documentation, packaging, configuration, and workflows.

Before modifying any repository file, inspect the relevant project
documentation, implementation, tests, and validation surface. Do not silently
replace established project conventions with generic best practices.

If a more deeply nested `AGENTS.md` is added later, it may refine instructions
for that subtree. It must not silently weaken repository-wide safety, privacy,
supply-chain, release, or validation invariants.

## Repository policy

Repository-specific policy is authoritative over generic style recommendations.

When requirements conflict, use this precedence:

1. explicit task requirements;
2. applicable `AGENTS.md` instructions;
3. repository-specific policy documents such as `SHELL_STYLE.md`;
4. mechanically enforced repository validation and tests;
5. external style guides and generic recommendations.

If an explicit task appears to require weakening a security, integrity,
packaging, release, or validation invariant, identify the conflict before
changing the invariant.

A mismatch between documented policy and mechanical validation is a repository
defect. Resolve the policy and validation together; do not choose one silently
or ignore a failing canonical check.

## Required reading by change type

`TESTING.md` is the authoritative guide to validation profiles, targeted
qualifications, CI coverage, and release-only procedures.

- For shell source, shell libraries, generated shell fixtures, or shell-bearing
  workflow blocks, read `SHELL_STYLE.md` in full.
- For packaging, installation, cleanup, workflow, supply-chain, or release
  changes, read the relevant sections of `TESTING.md` and inspect the matching
  integration tests and static contracts before editing.
- For user-facing behavior or documentation, inspect both `README.md` and
  `README.fr.md` and keep equivalent English and French guidance aligned.
- For version or release metadata, inspect the version-coherence assertions in
  `test-static.sh`, the current `CHANGELOG.md` entry, packaging metadata, and
  release workflows before changing any version surface.

## Shell policy

`SHELL_STYLE.md` is the authoritative shell style and formatting policy for
this repository.

Before creating, modifying, reviewing, refactoring, or formatting any shell
file, read `SHELL_STYLE.md` in full and apply it as a binding project
requirement.

Do not infer an alternative shell style from generic conventions, upstream
style guides, formatter defaults, or nearby code when `SHELL_STYLE.md` defines
an explicit project rule or exception.

For every shell file touched:

- preserve the canonical project structure and naming conventions defined in
  `SHELL_STYLE.md`;
- preserve documented project exceptions;
- keep the canonical shell inventory in `tests/lib/project-files.sh` accurate;
- use the repository-pinned `shfmt` configuration;
- do not use `shfmt --simplify` / `shfmt -s`;
- keep ShellCheck suppressions narrow, adjacent, and justified;
- do not add chronological audit, patch, release, or finding history to
  permanent source comments;
- do not make an unrelated formatting sweep unless the task explicitly calls
  for it.

Before considering shell-related work complete, run:

```bash
./scripts/check-shell-format.sh
./tests/run-all.sh
```

Fix failures caused by the change before finishing. If a validation step cannot
be run in the current environment, report exactly which step was not run and
why; do not imply that it passed.

Do not manually rewrite formatting in a way that conflicts with canonical
`shfmt` output.

## Project invariants

Treat established safety, privacy, trust-boundary, packaging, release,
installation, runtime-preservation, and cleanup behavior as intentional unless
the task explicitly changes it.

Prefer the smallest coherent change that satisfies the task and preserves
existing behavior outside the requested scope.

Do not delete or weaken regression tests merely to make a change pass. Update a
test only when the intended project contract has genuinely changed, and update
the corresponding documentation or policy in the same change when applicable.

## Validation discipline

Use the repository's own validation entry points rather than substituting ad hoc
checks when canonical checks exist.

During development, targeted tests and `./tests/run-all.sh --fast --jobs 4` may
provide quicker feedback. They are not substitutes for the complete validation
required before review.

For shell changes, `./tests/run-all.sh` is the final project validation entry
point unless the task specifies an additional qualification procedure.

For workflow, packaging, installation, cleanup, or release-related changes, run
the applicable targeted qualifications documented in `TESTING.md` in addition
to the complete local suite. Release-only or privileged procedures must not be
claimed when they were not actually run.

For every change, run `git diff --check` and review both staged and unstaged
diffs before delivery.

A successful formatter run is not a substitute for syntax, ShellCheck,
integration, packaging, or behavioral validation.

Diagnose a failing test or CI job before rerunning it. If evidence shows an
environmental or timing failure, report that evidence and the successful rerun;
do not hide flaky or unexplained failures.

## Workflow and supply-chain discipline

Preserve the repository's least-privilege and data-only trust boundaries.

- Pin third-party GitHub Actions and reusable workflows to a full 40-character
  commit SHA and retain a human-readable version comment.
- Keep checkout credentials disabled with `persist-credentials: false` unless a
  narrowly documented job boundary explicitly requires otherwise.
- Grant each workflow and job only the permissions it needs. Untrusted
  candidates and validation jobs must not receive repository write permissions
  or secrets.
- Do not execute candidate binaries or modified repository code inside a
  privileged publication job. Transfer reviewed data between trust zones and
  revalidate its digest, path allowlist, and immutable base where the workflow
  contract requires it.
- Preserve existing signature, provenance, checksum, exact-version, and
  immutable-release verification. A digest computed from newly discovered bytes
  is not an independent authentication root.

## Change delivery and release boundary

The protected `main` branch is updated through pull requests and required status
checks. Do not bypass branch protection, required checks, or review gates, and do
not force-push `main`.

Do not create or push release tags, publish releases or packages, alter
repository rules/secrets/environments, or initiate a version bump unless the
task explicitly requests that external or release action.

When a version change is explicitly requested, update every mechanically linked
version and documentation surface in one coherent change and run the release
preflight procedures required by `TESTING.md`.

## Documentation discipline

Permanent source comments explain durable intent: invariants, trust boundaries,
fallbacks, non-obvious constraints, caller contracts, and reasons for unusual
behavior.

Keep chronological development history in commits, pull requests, issues,
`CHANGELOG.md`, audit reports, or qualification reports rather than in source
comments.

Keep `README.md` and `README.fr.md` aligned when shared user-facing behavior,
requirements, installation steps, or release guidance changes.

When changing a documented project policy, update the authoritative policy and
its mechanical validation together whenever practical.

## Scope and review

Before finishing:

- review the diff for unrelated edits;
- verify that new shell files are added to the canonical inventory;
- verify that renamed shell files have matching canonical headers and inventory
  entries;
- verify that new exceptions are explicit, narrowly scoped, and documented;
- verify that workflow actions remain commit-pinned and permissions remain
  minimal;
- verify that user-facing English and French documentation remain aligned when
  applicable;
- summarize the files changed and the validation actually performed.

Do not claim tests, checks, builds, releases, or runtime behavior were verified
unless they were actually executed or directly inspected.
