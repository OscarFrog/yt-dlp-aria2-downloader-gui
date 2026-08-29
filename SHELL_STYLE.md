# Shell style and formatting policy

This file is the permanent shell-style contract for
`yt-dlp-aria2-downloader-gui`.

The Google Shell Style Guide is the reference baseline where it is compatible
with established project behavior and safety requirements. This checked-in
policy and the repository's mechanical validation are authoritative.

Upstream changes to the Google Shell Style Guide do not automatically change
project policy. They become normative only after explicit review and merge into
this repository.

## Baseline

Explicit project conventions and exceptions take precedence over the upstream
baseline:

- indentation is **4 spaces**, not Google's 2-space default;
- all canonical Bash files, including sourced libraries, use
  `#!/usr/bin/env bash`;
- shell source filenames use lowercase `kebab-case`, for example
  `runtime-manager.sh` and `project-files.sh`; this intentionally overrides
  Google's underscore-based source filename recommendation;
- the canonical shell inventory currently contains Bash files only; any future
  POSIX `sh` exception must be explicit in both the inventory and validation;
- `runtime-manager.sh` deliberately retains its no-errexit execution model;
- the Google 80-column limit is a readability target, not a CI-enforced maximum;
- line length is advisory when exact URLs, regular expressions, protocol
  templates, package metadata, fixtures, generated text, or four-space
  indentation make wrapping less clear;
- deliberately shared mutable file-scope state may use `UPPER_SNAKE_CASE` so
  its global lifetime is visually explicit.

Repository-specific rules override generic formatter defaults and external
style recommendations.

## Canonical structure

Substantial Bash executables use this order:

1. shebang;
2. canonical project header;
3. `set` / `umask`;
4. readonly/exported constants;
5. truly necessary mutable shared state;
6. cleanup/signal helpers and trap strategy;
7. generic utility functions;
8. domain/business functions;
9. bottom-most `main()`;
10. final `main "$@"`.

The explicit `main()` exemptions are defined by `MAIN_EXEMPT_SHELL_FILES` in
`tests/lib/project-files.sh`. Do not infer new exemptions from script size or
simplicity. Sourced libraries and tiny linear executables are exempt only when
listed there.

Functions and ordinary local variables use `lower_snake_case`. Constants,
exports, and top-level readonly values use `UPPER_SNAKE_CASE`.

Keep functions focused and avoid hidden coupling where a clear parameter,
return status, stdout contract, or explicitly documented shared variable can
express the dependency.

## Bash idiom contract

The canonical shell inventory is Bash, so prefer Bash-native constructs when
they improve correctness and clarity.

- Executable scripts use `set -euo pipefail` unless an explicit documented
  exception applies. `runtime-manager.sh` retains its intentional no-errexit
  model.
- Sourced libraries must not unexpectedly alter their caller's shell options,
  traps, working directory, `umask`, or process-wide state.
- Prefer `[[ ... ]]` over `[ ... ]` for Bash conditionals.
- Prefer `(( ... ))` for arithmetic conditions and `$(( ... ))` for arithmetic
  expansion.
- Use arrays for command argument lists. Do not construct argv in a string for
  later reparsing.
- Quote parameter, command, and arithmetic expansions unless the surrounding
  Bash construct intentionally and safely suppresses word splitting and
  pathname expansion.
- Use `--` before positional path operands when the invoked command supports it
  and a leading-dash path could otherwise be interpreted as an option.
- When a command substitution's exit status matters, do not hide it behind a
  declaration builtin. Prefer, for example:

  ```bash
  local value=''
  value=$(command)
  ```

  instead of relying on the status of `local value=$(command)`.
- Prefer explicit status handling where failure is expected or carries domain
  meaning. Do not disable a safety option globally to avoid handling one
  expected failure.
- Avoid `eval`. If it is genuinely necessary, document why ordinary arrays,
  parameter expansion, or direct invocation cannot express the operation and
  make the trust boundary explicit.
- Avoid unnecessary subshells and pipelines in stateful loops when they would
  make variable lifetime or exit-status behavior unclear.
- Treat filenames and external text as arbitrary data. Do not assume they are
  whitespace-free, newline-free, or option-safe unless a validated contract
  guarantees it.

## Exit-status and error-handling contract

Exit status is part of a shell function or executable's public behavior.

- Use non-zero status for genuine failure and zero for success.
- Preserve meaningful failure statuses when callers depend on them.
- Expected predicate failure is not necessarily an error; handle it explicitly
  instead of emitting misleading diagnostics.
- Prefer explicit error messages that identify the failed operation and useful
  context.
- Cleanup paths must be best-effort where appropriate and must not accidentally
  replace a more important original failure status.
- Trap behavior must be intentional. Signal and cleanup handlers must avoid
  introducing recursion, double cleanup, or unrelated state changes.
- A command whose non-zero status is intentionally tolerated must make that
  intent clear from its surrounding control flow or a durable nearby comment.

## Comment contract

Comments are written in English and are durable maintenance documentation, not
a chronological patch log.

- Explain **why** a guard, fallback, timeout, trust boundary, compatibility
  branch, or safety invariant exists; do not paraphrase obvious syntax.
- Keep release, audit, patch, and finding history in `CHANGELOG.md`, issues,
  pull requests, or qualification reports rather than permanent code comments.
- Sourced libraries document callable helpers concisely, including non-obvious
  caller-provided globals, shared outputs, side effects, or return contracts.
- Keep ShellCheck directives immediately adjacent to the command or compound
  command they affect.
- A `disable=` directive carries nearby durable rationale.
- `source=` directives identify the static source corresponding to a dynamic
  source path.
- Tests may use durable labels such as `Scenario`, `Regression guard`,
  `Mutation test`, `Negative control`, and `Positive controls`.
- Durable future work belongs in an issue or pull request rather than an
  open-ended `TODO`/`FIXME` comment.
- Comments must remain correct when read independently of the commit or release
  that introduced them.

## ShellCheck contract

All canonical shell files must pass the repository's ShellCheck validation.

Suppressions are exceptional:

- use the narrowest practical scope;
- keep the directive immediately adjacent to the affected command or compound
  command;
- every `disable=` requires a durable rationale;
- prefer fixing the underlying construct over suppressing a valid diagnostic;
- file-wide or repository-wide suppressions require an explicit documented
  project exception;
- do not suppress a warning merely because a particular test fixture happens
  not to trigger the unsafe case.

Optional ShellCheck checks may be adopted when they improve the project without
creating disproportionate noise. Enabling or disabling a project-wide optional
check is a policy change and must be reviewed together with the resulting code
and validation changes.

## shfmt contract

Every canonical shell file is formatted with the upstream `mvdan/sh` `shfmt`
binary pinned by:

`scripts/dev-tools/shfmt-pin.env`

The canonical formatting flags are:

```text
-i 4 -ci -bn
```

`--simplify` / `-s` is intentionally disabled.

The repository's `.editorconfig` mirrors these settings for editors, but the
validation scripts pass the canonical flags explicitly so CI does not depend on
editor behavior.

The canonical flags currently appear in both
`scripts/check-shell-format.sh` and `scripts/format-shell.sh`. They must remain
identical. Any formatting-policy change must update those scripts,
`.editorconfig`, this policy, and the corresponding static validation in the
same change.

Check formatting without changing files:

```bash
./scripts/check-shell-format.sh
```

Apply canonical formatting:

```bash
./scripts/format-shell.sh
```

`tests/run-all.sh` runs the non-mutating formatting check before the rest of the
validation suite.

Do not manually preserve a layout that conflicts with canonical `shfmt` output.
If canonical `shfmt` produces an undesirable layout, change the formatting
policy explicitly rather than adding ad hoc formatting exceptions.

The formatter bootstrap downloads the exact pinned upstream GitHub release
asset when the verified binary is absent from the local managed tool directory.
The downloaded asset must match the SHA-256 recorded in `shfmt-pin.env` before
execution.

This integrity check applies to an already approved project pin; a digest
computed from a newly discovered candidate is not, by itself, an independent
upstream authentication root.

## Canonical shell inventory

`tests/lib/project-files.sh` is the single source of truth for project shell
files.

Static validation also discovers tracked and non-ignored `.sh` files and
recognized Bash/POSIX shebangs. A new shell file that is not added to the
canonical inventory therefore fails validation.

This makes formatting, headers, ShellCheck, and the `main()` contract apply to
future shell additions automatically.

When adding, deleting, moving, or renaming a shell file, update the canonical
inventory in the same change.

Do not exclude a shell file from the inventory merely to avoid formatting,
header, ShellCheck, or structural validation. An exclusion is a project-policy
decision and requires an explicit documented reason.

## Canonical headers

Canonical shell files use the standard project header enforced by static
validation:

```text
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : relative/path/to/file.sh
# Purpose     : Concise durable purpose.
# ==============================================================================
```

The `File` field must match the repository-relative path. Renaming or moving a
canonical shell file therefore requires updating its header.

The `Purpose` field describes durable responsibility, not release history,
implementation chronology, or an audit finding.

## Formatting and review discipline

Formatting is mechanical; semantic review remains required.

When modifying shell code:

1. make the smallest coherent semantic change;
2. apply canonical formatting;
3. inspect the diff so formatting does not hide unintended behavior changes;
4. run the non-mutating formatting check;
5. run the repository validation suite;
6. review failures instead of weakening the checks merely to obtain green CI.

Avoid unrelated whole-file or repository-wide formatting churn unless the task
explicitly calls for it.

Generated patches should remain reviewable. Refactoring, formatting-policy
changes, behavioral changes, and security-sensitive changes should be separated
when practical if combining them would obscure review.

## shfmt version updates

`.github/workflows/shfmt-update.yml` checks the latest stable upstream GitHub
release every Monday and can also be run manually.

When a newer stable release exists, the workflow separates candidate execution,
read-only verification, and privileged publication:

1. `prepare-shfmt-update` has `contents: read` only, downloads the Linux amd64
   and arm64 candidates, verifies their release metadata and SHA-256 digests,
   runs the native candidate in a no-network sandbox, reformats the canonical
   shell inventory, and emits only a textual Git patch plus its digest;
2. `verify-shfmt-update` also has `contents: read` only and starts from a fresh
   checkout of the exact candidate base revision. It refuses a stale base,
   validates the handoff digest and strict path allowlist, verifies upstream
   provenance and canonical equivalence under the previously trusted formatter,
   runs `tests/run-all.sh`, and emits a verified patch bound to the tested tree;
3. `publish-shfmt-pr` alone has repository write permissions. From another
   fresh checkout of the exact base revision, it rechecks staleness, the verified
   handoff, the allowlist, and the tested-tree digests before publishing the
   branch without executing candidate code or project scripts from the modified
   workspace. Git hooks are disabled for the privileged commit.

A newly discovered formatter candidate is therefore treated as untrusted until
human review and merge. The project never switches formatter versions silently
in the middle of an ordinary validation run.

The new release becomes the project reference only when that update pull request
is reviewed and merged.

This preserves reproducibility: one commit always identifies one exact `shfmt`
version and exact asset digests.

## Policy maintenance

This document is normative.

A deliberate change to shell style, formatter behavior, canonical structure,
ShellCheck policy, inventory rules, or documented project exceptions must
update this file and the corresponding mechanical validation together whenever
applicable.

Existing code is not an independent source of policy when it conflicts with
this document or with enforced validation. Conversely, do not rewrite stable
code merely to satisfy a newly inferred preference that has not been adopted as
project policy.
