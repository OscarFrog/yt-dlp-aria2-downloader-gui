---
name: shell-change
description: Modify or review Bash code and shell-bearing workflow blocks in this repository while following its shell inventory, formatting, and validation contracts.
---

# Shell change

Use this skill for a change that creates, modifies, refactors, formats, or
reviews shell code in this repository.

## Route the work

1. Read the root `AGENTS.md` and `SHELL_STYLE.md` in full.
2. Read the relevant component flow in `ARCHITECTURE.md` and the applicable
   validation section in `TESTING.md`.
3. Inspect the implementation, its callers, focused regression tests, and the
   canonical arrays in `tests/lib/project-files.sh` before editing.

Treat `SHELL_STYLE.md` as the source of truth. Do not reproduce its rules here,
infer a competing style from nearby code, or run an unrelated formatting sweep.

If a shell path is added, removed, moved, or renamed, update both the canonical
source inventory and `REPOSITORY_FILES.md`. Preserve the exact project header
and any documented narrow exception.

## Locale boundaries

Apply `AGENTS.md` → **Locale Independence — Mandatory Development Rule** and
`SHELL_STYLE.md` → **Mandatory locale independence**. Inspect inherited locale,
collation, regex classes, numeric parsing and embedded Python encodings before
editing. Establish technical locale boundaries early enough, preserve caller
state when sourcing, and keep GUI/Unicode data contracts intact. Register changed
boundaries and add behavioral and negative regressions; a literal locale export
is not sufficient evidence. Use the multilingual matrix in `TESTING.md`.

## Validate

Run the narrowest useful regression while developing. Before delivery, run:

```bash
./scripts/check-shell-format.sh
./tests/run-all.sh --full --jobs 4
git diff --check
```

Run any additional component-specific qualification required by `TESTING.md`.
Report checks that could not run instead of implying success.
