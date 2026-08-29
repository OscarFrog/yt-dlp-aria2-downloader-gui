---
name: packaging-release
description: Change or review RPM, DEB, install, cleanup, versioning, release-preflight, or publication code in this repository without weakening lifecycle or release guarantees.
---

# Packaging and release change

Use this skill for native packages, installation or removal behavior, package
upgrade compatibility, version surfaces, release preparation, or publication
automation.

## Route the work

1. Read `AGENTS.md`, the packaging/release sections of `ARCHITECTURE.md`, and
   the relevant procedures in `TESTING.md`.
2. Inspect both package formats when changing their common payload, and inspect
   `packaging/install-tree.sh`, package metadata, lifecycle/upgrade tests, and
   matching workflow jobs before editing.
3. For user-facing installation or version changes, inspect and align
   `README.md`, `README.fr.md`, `CHANGELOG.md`, manpages, and mechanically linked
   version assertions.

Preserve previous-immutable-release upgrade coverage, user runtime/config/state
preservation, RPM signer authentication, exact package identity, noarch payload
semantics, and the deliberate RPM/DEB cleanup difference unless the task
explicitly changes one of those contracts.

A code or documentation task does not authorize creating a tag, signing or
publishing packages, publishing a release, or changing secrets, environments,
or repository rules. Stop for explicit authorization at that boundary.

## Validate

Use focused package or cleanup integration tests during development. Before
delivery, run:

```bash
./tests/run-all.sh --full --jobs 4
git diff --check
```

Then run the applicable package, upgrade, real-tool, preflight, or release
qualification documented in `TESTING.md` when its prerequisites and the task's
authority permit it. Distinguish local proof from privileged or published
release evidence.
