# Repository agent instructions

This file defines persistent instructions for coding agents working in this
repository.

## Repository policy

Repository-specific policy is authoritative over generic style recommendations.

Before modifying code, inspect the relevant project documentation and validation
surface. Do not silently replace established project conventions with generic
best practices.

When requirements conflict, use this precedence:

1. explicit task requirements;
2. applicable `AGENTS.md` instructions;
3. repository-specific policy documents such as `SHELL_STYLE.md`;
4. mechanically enforced repository validation and tests;
5. external style guides and generic recommendations.

If an explicit task appears to require weakening a security, integrity,
packaging, release, or validation invariant, identify the conflict before
changing the invariant.

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

For shell changes, `./tests/run-all.sh` is the final project validation entry
point unless the task specifies an additional qualification procedure.

A successful formatter run is not a substitute for syntax, ShellCheck,
integration, packaging, or behavioral validation.

## Documentation discipline

Permanent source comments explain durable intent: invariants, trust boundaries,
fallbacks, non-obvious constraints, caller contracts, and reasons for unusual
behavior.

Keep chronological development history in commits, pull requests, issues,
`CHANGELOG.md`, audit reports, or qualification reports rather than in source
comments.

When changing a documented project policy, update the authoritative policy and
its mechanical validation together whenever practical.

## Scope and review

Before finishing:

- review the diff for unrelated edits;
- verify that new shell files are added to the canonical inventory;
- verify that renamed shell files have matching canonical headers and inventory
  entries;
- verify that new exceptions are explicit, narrowly scoped, and documented;
- summarize the files changed and the validation actually performed.

Do not claim tests, checks, builds, releases, or runtime behavior were verified
unless they were actually executed or directly inspected.
