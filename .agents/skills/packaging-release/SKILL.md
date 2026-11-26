---
name: packaging-release
description: Change or review Fedora RPM, install, cleanup, versioning, release-preflight, or publication code in this repository without weakening lifecycle or release guarantees.
---

# Packaging and release change

Use this skill for native packages, installation or removal behavior, package
upgrade compatibility, version surfaces, release preparation, or publication
automation.

Fedora 45 x86_64 is the only officially supported platform. Verify the userspace, machine and RPM architecture before application validation and preserve authenticated RPM installation and upgrade coverage.

## Route the work

1. Read `AGENTS.md`, the packaging/release sections of `ARCHITECTURE.md`, and
   the relevant procedures in `TESTING.md`.
2. For changes to the Fedora RPM payload, inspect
   `packaging/install-tree.sh`, package metadata, lifecycle/upgrade tests, and
   matching workflow jobs before editing.
3. For user-facing installation or version changes, inspect and align
   `README.md`, `README.fr.md`, `CHANGELOG.md`, manpages, and mechanically linked
   version assertions.

Preserve previous-immutable-release upgrade coverage, user runtime/config/state
preservation, RPM signer authentication, exact package identity, x86_64 package
semantics, and the RPM runtime-preservation contract unless the task
explicitly changes one of those contracts.

Apply the standing delegation in `AGENTS.md` to ordinary delivery and
post-publication documentation. Start publication only on a maintainer request
for a named version. That request covers its signed tag, official preflight,
tag push and eligible `rpm-signing` review. Follow the identity and environment
checks in `TESTING.md`. Changes to protections, keys or secrets require
specific authorization.

For an authorized source push, follow the release-preparation version policy in
`AGENTS.md`: preserve coherent versions without an automatic increment. Use
`scripts/check-push-version.py check` for that early check and the tracked
pre-push hook for the committed objects. Choose a new version only during
explicit release preparation. The signed-tag publication preflight remains a
separate release-only boundary.

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
