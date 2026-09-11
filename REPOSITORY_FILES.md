# Repository file inventory

This document is the current technical inventory of the repository. It describes the tracked tree and the reason each path remains part of the project. It is checked against the Git tree by `test-static.sh`; any tracked addition, removal, or rename requires an explicit update here.

## Scope and method

The inventory covers executable Bash and Python entry points, shared modules, tests, mocks, helpers, packaging, installation and uninstall scripts, desktop integration, configuration, GitHub Actions, release tooling, metadata, documentation with verifiable behavior, and supply-chain assets. Generated artifacts, caches, decorative images, and binaries that cannot reasonably be audited are excluded.

The review cross-checks Git history, imports and `source` calls, direct callers, workflows, RPM/DEB/ZIP payloads, tests and fixtures, documentation, publication, upgrade from the previous immutable release, cleanup, crash recovery, and compatibility. The table condenses the role, consumers, necessity, correctness, history, redundancy, and retention decision for every tracked path.

## Cross-component interfaces

- Bash launchers and `download-video.sh` form the CLI/GUI execution boundary.
- `private-aria2-plan.py`, `private-launcher-manager.py`, and `scripts/update-published-version.py` are invoked explicitly with `python3`; they are modules or private helpers, not direct public commands.
- `progress-monitor.sh` translates yt-dlp, aria2c, and FFmpeg events into the Zenity progress protocol.
- `runtime-manager.sh` owns per-user yt-dlp/Deno installation, attestation, activation, locking, and rollback.
- `packaging/install-tree.sh` is the shared DESTDIR assembler for RPM and DEB; package scriptlets and lifecycle tests validate installation, removal, preservation, and upgrade behavior.
- GitHub Actions separate static validation, real-tool qualification, stress testing, package construction, protected RPM signing, publication, and post-publication verification.

## Exact inventory

The first column contains every tracked path included in this inventory.

| File | Type | Purpose and retention reason | Decision |
| --- | --- | --- | --- |
| `.agents/skills/packaging-release/SKILL.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.agents/skills/shell-change/SKILL.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.agents/skills/workflow-supply-chain/SKILL.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.codex/rules/default.rules` | Configuration | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.editorconfig` | Configuration | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/ISSUE_TEMPLATE/codex-task.yml` | CI workflow | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/pull_request_template.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/workflows/packages.yml` | CI workflow | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/workflows/qualification.yml` | CI workflow | Qualifies supported FFmpeg generations; the Fedora download job uses disposable local storage volumes that remain subject to private-filesystem validation. | KEEP |
| `.github/workflows/real-tools.yml` | CI workflow | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/workflows/release-docs.yml` | CI workflow | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/workflows/release.yml` | CI workflow | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.github/workflows/shell.yml` | CI workflow | Runs canonical Ubuntu and Fedora validation; the Fedora job gives private-state and media tests disposable local storage volumes. | KEEP |
| `.github/workflows/shfmt-update.yml` | CI workflow | Separates formatter preparation, isolated verification and publication; verifier media tests use an anonymous disk volume removed with the container. | KEEP |
| `.github/workflows/stress.yml` | CI workflow | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `.gitignore` | Configuration | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `AGENTS.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `ARCHITECTURE.md` | Documentation/policy | Documents component interactions, local metadata/media separation, filesystem publication guarantees, process supervision and cleanup boundaries. | KEEP |
| `CHANGELOG.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `LICENSE` | License | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `README.fr.md` | Documentation/policy | French user guide aligned with the English guide, including network storage and privacy behavior. | KEEP |
| `README.md` | Documentation/policy | English user guide, including network destination behavior, local disk requirements and cautious legacy-residue inspection. | KEEP |
| `REPOSITORY_FILES.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `SHELL_STYLE.md` | Documentation/policy | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `TESTING.md` | Documentation/policy | Canonical validation, regression and real-tool commands, plus explicitly opt-in disposable SMB/CIFS qualification and its limits. | KEEP |
| `download-video-gui.sh` | Bash script | Zenity entry point: uses the shared private local allocator, passes the actual destination to the engine, and preserves active state when child shutdown cannot be confirmed. | KEEP |
| `download-video.sh` | Bash script | CLI engine: separates local private authentication state from media, selects protected local disk staging when needed, supervises transfers/remux, validates and publishes to the requested destination without overwriting. | KEEP |
| `install-fedora.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `install-gui.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/deb/build-deb.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/deb/copyright` | Debian packaging | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/deb/test-package-lifecycle.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/deb/test-package-upgrade.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/icons/yt-dlp-aria2-downloader.svg` | Icon asset | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/install-tree.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/keys/RPM-GPG-KEY-OscarFrog` | Packaging asset | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/keys/yt-dlp-public.key` | Packaging asset | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/man/yt-dlp-aria2-downloader-gui.1` | Packaging asset | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/man/yt-dlp-aria2-downloader.1` | Packaging asset | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/package-user-cleanup.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/rpm/build-rpm.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/rpm/test-package-lifecycle.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/rpm/test-package-upgrade.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/rpm/yt-dlp-aria2-downloader-gui.spec` | RPM packaging | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `packaging/yt-dlp-aria2-downloader.desktop` | Desktop integration | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `private-aria2-plan.py` | Python module/script | Installed Python helper: selects validated local metadata/disk roots, handles private aria2 plans, checks local space, copies and publishes media without replacement, and cleans identity-bound active workspaces. | KEEP |
| `private-launcher-manager.py` | Python module/script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `progress-monitor.sh` | Bash script | Turns native/aria2/FFmpeg records into monotonic Zenity progress, including the final media-copy phase. | KEEP |
| `runtime-manager.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/check-shell-format.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/dev-tools/ensure-shfmt.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/dev-tools/shfmt-pin.env` | Project file | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/format-shell.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/git-inspect.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/release-evidence-qualification.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/release-preflight.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `scripts/update-published-version.py` | Python module/script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `test-static.sh` | Bash script | Validates canonical source/package/version contracts and registration of the network regression group. | KEEP |
| `tests/aria2-auth-headers-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/aria2-real-behavior-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/ffmpeg-generation-compatibility.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/ffmpeg-generation-qualification.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/ffmpeg-progress-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/ffmpeg-real-progress-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/hls-remux-duration-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/install-fedora-authentication-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/installer-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/lib/assert.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/lib/package-lifecycle.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/lib/package-runtime-preservation.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/lib/project-files.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/lib/test-runner.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/mock-integration.sh` | Bash script | Hermetic engine/GUI tests including permissive destination simulation, sentinel secrecy during downloads, signal cancellation, preserved old residues and unconfirmed-shutdown cleanup. | KEEP |
| `tests/package-user-cleanup-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/packaging-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/private-aria2-plan-integration.sh` | Bash script | Behavioral Python helper tests: strict private files, staging/publication identities, root selection, unsupported primitives, copy failures, collisions, signals and cleanup preservation. | KEEP |
| `tests/progress-monitor-integration.sh` | Bash script | Qualifies progress aggregation, phase transitions and the constant local-disk staging notice consumed by the Zenity progress interface. | KEEP |
| `tests/real-tools-integration.sh` | Bash script | Real local HTTP media fixtures for direct/audio/HLS/DASH, optional permissive-directory simulation and explicit disposable network-share qualification. | KEEP |
| `tests/repeat-qualification.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/rpm6-multisig-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/run-all-signal-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/run-all.sh` | Bash script | Canonical doctor and fast/full test scheduler, including the network destination regressions. | KEEP |
| `tests/runtime-manager-hardening-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/runtime-manager-integration.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |
| `tests/test-runner-integration.sh` | Bash script | Verifies process supervision and exact validation manifests including the network regression group. | KEEP |
| `tests/zenity-real-session-qualification.sh` | Bash script | Tracked project component; retained because it is referenced by the source tree, tests, packaging, CI, or release process. | KEEP |

## Historical and compatibility files

`CHANGELOG.md` is intentionally historical and is installed with the packages. Package upgrade tests, runtime preservation helpers, RPM cleanup, and RPM v4/v6 qualification remain active compatibility or security mechanisms. Legacy launcher paths and old runtime fixtures are retained only where they represent data created by supported previous installations or named compatibility boundaries. No tracked file is currently proven redundant or safe to remove.

## Inventory status

- Tracked files included: **86**.
- Files examined: **86**.
- Files retained: **86**.
- Historical files: **1** (`CHANGELOG.md`).
- Files requiring correction: **0**.
- Redundant files: **0**.
- Justified removals: **0**.

All descriptions above are in English; filenames, command names, SPDX identifiers, package metadata, and protocol tokens remain unchanged where they are machine-readable.
