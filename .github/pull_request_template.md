# Pull request

## Summary

Describe the outcome and the reason for the change.

## Contract and risk

- Affected components and trust boundaries:
- Behavior intentionally changed:
- Behavior explicitly preserved:
- Compatibility or recovery implications:

## Validation

Commands and qualifications actually executed:

```text

```

Checks not run, with the reason:

- None.

## External mutation authority

Authority granted by the task:

- None.

External mutations actually performed (pushes, merges, tags, releases,
publications, workflow dispatches, repository settings, or secrets):

- None.

## Repository coherence

- [ ] The diff contains no unrelated changes.
- [ ] Focused regression coverage matches the changed contract.
- [ ] `./tests/run-all.sh --full --jobs 4` passed, or the limitation is stated above.
- [ ] Shell changes satisfy `SHELL_STYLE.md` and the canonical inventories.
- [ ] User-facing English and French documentation remain aligned, when applicable.
- [ ] Tracked-file additions, removals, moves, and role changes are reflected in `REPOSITORY_FILES.md`.
- [ ] Workflow permissions, action pins, checkout credentials, and trust boundaries remain valid, when applicable.
- [ ] No external mutation exceeded the task's explicit authority; every mutation is reported in `External mutation authority`.
