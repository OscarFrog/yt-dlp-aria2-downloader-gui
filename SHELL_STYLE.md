# Shell style and formatting policy

This file is the permanent shell-style contract for
`yt-dlp-aria2-downloader-gui`.

## Baseline

The project follows the Google Shell Style Guide where it is compatible with
the established project behavior and safety requirements.

Explicit project conventions and exceptions take precedence:

- indentation is **4 spaces**, not Google's 2-space default;
- canonical Bash executables use `#!/usr/bin/env bash`;
- Debian maintainer hooks remain POSIX `/bin/sh`;
- `runtime-manager.sh` deliberately retains its no-errexit execution model;
- line length is advisory when exact URLs, regular expressions, protocol
  templates, package metadata, fixtures, or four-space indentation make
  wrapping less clear;
- deliberately shared mutable file-scope state may use `UPPER_SNAKE_CASE` so
  its global lifetime is visually explicit.

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

Sourced libraries and tiny linear executables may be explicitly exempted from
the `main()` rule in `tests/lib/project-files.sh`.

Functions and ordinary local variables use `lower_snake_case`. Constants,
exports and top-level readonly values use `UPPER_SNAKE_CASE`.

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
validation scripts pass the canonical flags explicitly so CI does not depend
on editor behavior.

Check formatting without changing files:

```bash
./scripts/check-shell-format.sh
```

Apply canonical formatting:

```bash
./scripts/format-shell.sh
```

`tests/run-all.sh` runs the non-mutating formatting check before the rest of
the validation suite.

The formatter bootstrap downloads the exact pinned upstream GitHub release
asset when the verified binary is absent from the local managed tool directory. The downloaded
asset must match the SHA-256 recorded in `shfmt-pin.env` before execution. This
integrity check applies to an already approved project pin; a digest computed
from a newly discovered candidate is not, by itself, an independent upstream
authentication root.

## Canonical shell inventory

`tests/lib/project-files.sh` is the single source of truth for project shell
files. Static validation also discovers tracked and non-ignored `.sh` files
and recognized Bash/POSIX shebangs. A new shell file that is not added to the
canonical inventory therefore fails validation.

This makes formatting, headers, ShellCheck and the `main()` contract apply to
future shell additions automatically.

## shfmt version updates

`.github/workflows/shfmt-update.yml` checks the latest stable upstream GitHub
release every Monday and can also be run manually.

When a newer stable release exists, the workflow uses two separate trust
zones:

1. `prepare-shfmt-update` has `contents: read` only, downloads the Linux amd64
   and arm64 candidates, computes their SHA-256 digests, updates the pin,
   reformats the canonical shell inventory, runs `tests/run-all.sh`, and emits
   only a textual Git patch plus its digest;
2. `publish-shfmt-pr` has the repository write permissions, starts from a fresh
   checkout of the exact candidate base revision, refuses a stale base, checks
   the handoff digest and a strict path allowlist, runs `git apply --check`,
   applies the patch, and publishes the branch without executing candidate code
   or project scripts from the modified workspace. Git hooks are disabled for
   the privileged commit.

A newly discovered formatter candidate is therefore treated as untrusted until
human review and merge. The project never switches formatter versions silently
in the middle of an ordinary validation run. The new release becomes the
project reference only when that update pull request is reviewed and merged.

This preserves reproducibility: one commit always identifies one exact shfmt
version and exact asset digests.
