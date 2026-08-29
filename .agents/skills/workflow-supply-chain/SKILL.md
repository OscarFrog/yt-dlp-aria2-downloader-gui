---
name: workflow-supply-chain
description: Review or change GitHub Actions, dependency pins, provenance, signing, or privileged publication boundaries in this repository.
---

# Workflow and supply-chain change

Use this skill when work touches `.github/workflows/`, action pins, workflow
permissions, artifact provenance, signing, or publication trust zones.

## Establish the contract

1. Read `AGENTS.md`, the CI/release sections of `ARCHITECTURE.md`, and the
   relevant GitHub Actions and qualification sections of `TESTING.md`.
2. Inspect the complete affected workflow, its called scripts, matching static
   assertions in `test-static.sh`, and related integration tests.
3. Identify each job's input trust level, permissions, secrets, executed code,
   and output before changing the graph.

Keep third-party Actions pinned to full commit SHAs, preserve disabled checkout
credentials and least privilege, and revalidate data crossing trust zones. Do
not copy these invariants into a second policy document; their authoritative
review form is in `AGENTS.md`.

For `shfmt-update.yml`, also read the shfmt-update section of `SHELL_STYLE.md`.
For release or packaging paths, use the `packaging-release` skill as well.

Ordinary workflow editing does not authorize triggering publication, changing
repository settings or secrets, creating tags, or retrying a privileged job.
Obtain explicit authority for those external mutations.

## Validate

Run focused static or integration coverage while developing, followed by:

```bash
./tests/run-all.sh --full --jobs 4
git diff --check
```

Run specialized workflow or release qualifications only when the environment
and task scope support them, and report exactly what ran.
