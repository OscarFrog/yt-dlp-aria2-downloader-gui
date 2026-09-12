# Repository file inventory

This document is the current technical inventory of the repository. It describes source paths and the reason each remains part of the project. `test-static.sh` checks path agreement with the working source inventory; additions, removals, renames and role changes require an explicit update here.

## Scope and method

The inventory covers executable Bash and Python entry points, shared modules, tests, mocks, helpers, packaging, installation and uninstall scripts, desktop integration, configuration, GitHub Actions, release tooling, metadata, documentation with verifiable behavior, and supply-chain assets. Generated artifacts, caches, decorative images, and binaries that cannot reasonably be audited are excluded.

The table records responsibilities and consumers, not an assertion that every file has passed a complete code audit. `ARCHITECTURE.md` describes component and trust boundaries; `TESTING.md` owns validation procedures and qualification limits. Static inventory validation proves path coverage, not the semantic accuracy of these descriptions.

Source archives contain the committed source tree. **Source-only** below means a component available from that tree but excluded from the installed RPM/DEB payload. `packaging/install-tree.sh`, the RPM spec and the DEB builder define native installation; rows for installed components identify that use explicitly.

## Cross-component interfaces

- Bash launchers and `download-video.sh` form the CLI/GUI execution boundary.
- Python files are invoked explicitly with `python3`: `private-aria2-plan.py` serves the engine/GUI, `private-launcher-manager.py` serves the portable installer, and the version helpers serve release documentation, contributor validation and unprivileged automation preparation. `tests/push-version-integration.py` qualifies the Git guard and deterministic source-version preparation.
- `progress-monitor.sh` translates yt-dlp, aria2c, and FFmpeg events into the Zenity progress protocol.
- `runtime-manager.sh` owns per-user yt-dlp/Deno installation, attestation, activation, locking, and rollback.
- `packaging/install-tree.sh` is the shared DESTDIR assembler for RPM and DEB; package scriptlets and lifecycle tests validate installation, removal, preservation, and upgrade behavior.
- GitHub Actions separate static validation, real-tool qualification, stress testing, package construction, protected RPM signing, publication, and post-publication verification.

## Exact inventory

The first column contains every source path included in this inventory, including new non-ignored files before they are committed.

| File | Type | Purpose and retention reason | Decision |
| --- | --- | --- | --- |
| `.agents/skills/packaging-release/SKILL.md` | Agent skill | Source-only route for package, installer, version and release tasks; directs agents to shared lifecycle, validation and authorization contracts. | KEEP |
| `.agents/skills/shell-change/SKILL.md` | Agent skill | Source-only route for Bash and shell-bearing workflow edits; links binding shell policy, inventories and focused/full validation. | KEEP |
| `.agents/skills/workflow-supply-chain/SKILL.md` | Agent skill | Source-only route for Actions, pins, provenance and signing changes; requires inspection of job authority and artifact trust boundaries. | KEEP |
| `.codex/rules/default.rules` | Codex execution policy | Source-only command-prefix decisions for Codex; prompts direct Git/GitHub commands and forbids covered force-push forms. Complements task authority and sandbox policy. | KEEP |
| `.editorconfig` | Editor configuration | Source-only UTF-8/LF, whitespace and indentation settings for editors; mirrors the shell formatter contract without replacing its explicit flags. | KEEP |
| `.githooks/pre-push` | Bash hook | Contributor-only Git pre-push guard; invokes the shared version checker on committed objects before any remote update. Enable per checkout; not installed by RPM/DEB. | KEEP |
| `.github/ISSUE_TEMPLATE/codex-task.yml` | GitHub issue form | Source-only task intake for objective, acceptance criteria, scope, validation and external authority; consumed when opening a GitHub issue. | KEEP |
| `.github/pull_request_template.md` | GitHub PR template | Source-only review record for outcome, risks, actual validation, version coherence and authorized external mutations. | KEEP |
| `.github/workflows/packages.yml` | CI workflow | Source-only PR package CI after successful shell qualification: validates a Git-free archive, builds RPM/DEB, authenticates the previous immutable release and exercises package lifecycle/upgrades. | KEEP |
| `.github/workflows/promotion.yml` | CI workflow | Source-only main promotion guard; verifies all PR qualification records against the exact squash tree without rerunning suites. | KEEP |
| `.github/workflows/qualification.yml` | CI workflow | Source-only PR FFmpeg generation matrix after shell qualification, sharing Ubuntu baseline fixtures with real-tools; the Fedora download job uses disposable local storage volumes subject to private-filesystem validation. | KEEP |
| `.github/workflows/real-tools.yml` | CI workflow | Source-only PR qualification with pinned yt-dlp matrices after shell validation, one shared Ubuntu FFmpeg baseline and bounded real aria2 repetitions; separately checks scheduled current-stable yt-dlp. | KEEP |
| `.github/workflows/release-docs.yml` | CI workflow | Source-only post-release pipeline; independently reproduces published-reference updates and seven-file source bumps, then creates or fast-forwards a review branch through a data-only publisher. | KEEP |
| `.github/workflows/release.yml` | CI workflow | Source-only authorized tag pipeline: verifies qualified source proof and final ZIP identity, builds exact artifacts, isolates RPM signing, tests upgrades, attests immutable publication and verifies public downloads. | KEEP |
| `.github/workflows/shell.yml` | CI workflow | Source-only PR identity/syntax/coherence gate, canonical Ubuntu/Fedora validation, early pinned actionlint and actual Python 3.10 qualification; the Fedora job gives private-state and media tests disposable local storage volumes. | KEEP |
| `.github/workflows/shfmt-update.yml` | CI workflow | Source-only formatter preparation with a source bump before candidate execution, isolated independent verification and bounded branch publication; preserves existing branches and no-op runs. | KEEP |
| `.github/workflows/stress.yml` | CI workflow | Source-only twenty distinct signal-jitter tuples and ten runtime transaction cycles after full validation; the unchanged required check aggregates all complementary PR workflows before merge. | KEEP |
| `.gitignore` | Git configuration | Source-only exclusions for generated media, transport sidecars, caches, local qualification evidence and release artifacts; does not remove already tracked paths. | KEEP |
| `AGENTS.md` | Agent policy | Source-only repository router and shared invariants; directs agents to authoritative documents, relevant skills, validation and mutation/version boundaries. | KEEP |
| `ARCHITECTURE.md` | Documentation/policy | Source-only technical map of component interactions, local metadata/media separation, publication guarantees, process supervision and cleanup boundaries. | KEEP |
| `CHANGELOG.md` | Release history | Installed RPM/DEB user documentation; records unreleased and historical changes and supplies the current-version heading checked by static validation. | KEEP |
| `CI_AUDIT.md` | Audit report | Source-only dated CI timing, duplication, protection and implementation evidence; records measurements and limitations without replacing operating policy. | KEEP |
| `LICENSE` | License | Repository MIT licensing text; installed by the RPM spec as license metadata. The DEB installs its format-specific copyright file. | KEEP |
| `README.fr.md` | User documentation | Installed RPM/DEB French guide aligned with the English guide, including installation, network storage and privacy behavior. | KEEP |
| `README.md` | User documentation | Installed RPM/DEB English guide, including installation, network destination behavior, local disk requirements and cautious legacy-residue inspection. | KEEP |
| `REPOSITORY_FILES.md` | Source inventory | Source-only path, role, consumer and installation inventory; checked by static validation and consulted for additions, removals and changed responsibilities. | KEEP |
| `SHELL_STYLE.md` | Shell policy | Source-only normative Bash structure, privacy, diagnostics, headers, comments, ShellCheck and pinned shfmt contract; consumed by agents and static validation. | KEEP |
| `TESTING.md` | Documentation/policy | Source-only canonical validation, regression and real-tool procedures, plus explicitly opt-in disposable SMB/CIFS qualification and its limits. | KEEP |
| `download-video-gui.sh` | Bash entrypoint | Installed RPM/DEB Zenity frontend, also used from Git/ZIP; uses the shared private allocator, passes the destination to the engine and preserves active state until shutdown is confirmed. | KEEP |
| `download-video.sh` | Bash entrypoint | Installed RPM/DEB CLI engine and application-version source, also used from Git/ZIP; separates private authentication/media state, supervises transfers/remux and validates no-overwrite publication. | KEEP |
| `install-fedora.sh` | Bash installer | Standalone Fedora bootstrap distributed with releases, not installed in libexec; authenticates the exact application RPM, prepares system dependencies and managed runtimes. | KEEP |
| `install-gui.sh` | Bash installer | Source-only portable launcher entrypoint for Git/ZIP users; supervises `private-launcher-manager.py` to install/remove per-user desktop integration. | KEEP |
| `packaging/deb/build-deb.sh` | Bash builder | Source-only DEB assembly: invokes the shared install tree, removes the RPM-only cleanup helper, writes Debian metadata and validates the resulting package. | KEEP |
| `packaging/deb/copyright` | Debian metadata | Machine-readable MIT copyright metadata installed into the DEB documentation directory by its builder. | KEEP |
| `packaging/deb/test-package-lifecycle.sh` | Package qualification | Source-only privileged DEB install/remove/purge/reinstall checks; called by package/release CI and uses shared payload/runtime-preservation assertions. | KEEP |
| `packaging/deb/test-package-upgrade.sh` | Package qualification | Source-only DEB upgrade from the verified previous immutable package; checks installed payload and retained user runtime through upgrade/removal. | KEEP |
| `packaging/icons/yt-dlp-aria2-downloader.svg` | Icon asset | Installed RPM/DEB hicolor icon; also read by the portable launcher installer for per-user desktop integration. | KEEP |
| `packaging/install-tree.sh` | Bash builder | Source-only common DESTDIR payload assembler consumed by RPM/DEB builders and packaging tests; installs runtime helpers, desktop/icon/docs/manpages and command symlinks. | KEEP |
| `packaging/keys/RPM-GPG-KEY-OscarFrog` | Public trust asset | Public RPM signer certificate consumed by Fedora bootstrap, preflight, signing/verification tests and immutable release assets; no private signing material. | KEEP |
| `packaging/keys/yt-dlp-public.key` | Public trust asset | Installed in native private `keys/`; authenticates yt-dlp release checksums in the runtime manager, which also locates it in Git/ZIP sources. | KEEP |
| `packaging/man/yt-dlp-aria2-downloader-gui.1` | Manpage | Installed RPM/DEB manual for the graphical command, its profiles and state; maintained with user-facing GUI behavior. | KEEP |
| `packaging/man/yt-dlp-aria2-downloader.1` | Manpage | Installed RPM/DEB manual for CLI options, examples and files; maintained with the engine's public interface. | KEEP |
| `packaging/package-user-cleanup.sh` | RPM lifecycle helper | Installed by RPM, deliberately omitted from DEB; migrates exact legacy launchers and removes only proven-owned user data on final RPM erase. | KEEP |
| `packaging/rpm/build-rpm.sh` | Bash builder | Source-only noarch RPM builder used by CI/release; archives committed sources, supplies the engine-derived package version to the spec and validates payload. | KEEP |
| `packaging/rpm/test-package-lifecycle.sh` | Package qualification | Source-only privileged Fedora RPM install/remove/reinstall checks; verifies commands, desktop/icon state and the RPM-specific cleanup contract. | KEEP |
| `packaging/rpm/test-package-upgrade.sh` | Package qualification | Source-only upgrade from exact previous immutable RPM bytes; verifies current payload and runtime preservation before final RPM cleanup. | KEEP |
| `packaging/rpm/yt-dlp-aria2-downloader-gui.spec` | RPM metadata | Source-only RPM definition for dependencies, build/install, file ownership and lifecycle scriptlets; invokes the common payload assembler with the supplied version. | KEEP |
| `packaging/yt-dlp-aria2-downloader.desktop` | Desktop integration | Installed RPM/DEB system menu entry targeting the public GUI command and dedicated icon; portable entry generation is owned by the Python launcher helper. | KEEP |
| `private-aria2-plan.py` | Python module/script | Installed Python helper: selects validated local metadata/disk roots, handles private aria2 plans, checks local space, copies and publishes media without replacement, and cleans identity-bound active workspaces. | KEEP |
| `private-launcher-manager.py` | Python helper | Source-only portable install/uninstall implementation called by `install-gui.sh`; anchors XDG directories, locks transactions, validates desktop data and rolls back partial publication. | KEEP |
| `progress-monitor.sh` | Bash progress helper | Installed RPM/DEB helper called by the GUI; turns native/aria2/FFmpeg records into monotonic Zenity progress, including the final media-copy phase. | KEEP |
| `runtime-manager.sh` | Bash runtime helper | Installed RPM/DEB helper and Git/ZIP component called by engine/bootstrap; authenticates, activates, attests and rolls back per-user yt-dlp/Deno versions under a lock. | KEEP |
| `scripts/check-push-version.py` | Python module/script | Source-only offline source/published-version coherence check; also checks live remote versions and actual pushed blobs before authorized pushes, without executing candidates or mutating source/remote state. | KEEP |
| `scripts/check-shell-format.sh` | Bash validation | Source-only non-mutating check of every canonical shell file with the pinned verified shfmt binary; called by the test runner and contributors. | KEEP |
| `scripts/check-workflows.sh` | Bash validation | Source-only explicit actionlint/ShellCheck workflow validation; requires the reviewed installed actionlint version, rejects unsafe workflow types and never provisions tools implicitly. | KEEP |
| `scripts/ci-validation.py` | Python validation | Source-only authenticated Actions proof verifier shared by PR gates, main promotion, release and evidence tooling; binds latest successful runs/jobs to the exact virtual merge and squash tree. | KEEP |
| `scripts/verify-source-archive.py` | Python validation | Source-only final ZIP verifier; compares complete inventory, modes and bytes with immutable qualified Git blobs without executing archive contents. | KEEP |
| `scripts/dev-tools/ensure-shfmt.sh` | Bash tool bootstrap | Source-only formatter resolver used by formatting scripts; parses the pin, verifies cached/downloaded bytes and returns an exact executable path. | KEEP |
| `scripts/dev-tools/actionlint-pin.env` | Tool pin metadata | Source-only reviewed actionlint version and Linux archive SHA-256 pins; consumed by the local workflow check and the verified Ubuntu CI bootstrap. | KEEP |
| `scripts/dev-tools/shfmt-pin.env` | Tool pin metadata | Source-only shfmt version and Linux amd64/arm64 SHA-256 pins read by the bootstrap, doctor and update workflow. | KEEP |
| `scripts/format-shell.sh` | Bash development tool | Source-only mutating counterpart to the formatting check; applies the same pinned flags to the canonical shell inventory. | KEEP |
| `scripts/git-inspect.sh` | Bash agent tool | Source-only fixed-action Git summary/history/status/diff/inventory inspector; closes the Git environment, ignores replacement refs and accepts no arbitrary Git options or output paths. | KEEP |
| `scripts/release-evidence-qualification.sh` | Release qualification | Source-only maintainer helper; reads public release/assets, attestations, qualified tree proof and exact release/scheduled Actions evidence, then writes a local qualification report. | KEEP |
| `scripts/release-preflight.sh` | Release qualification | Source-only maintainer check of signed-tag/version identity, GitHub release/environment settings and pinned signing identity before authorized publication. | KEEP |
| `scripts/update-published-version.py` | Python development tool | Source-only bounded updater/checker for published asset references in both READMEs and the static published-version pin; consumed by release documentation automation and tests. | KEEP |
| `scripts/prepare-source-version.py` | Python development tool | Source-only offline preparation of seven development-version carriers from a verified version floor, date and reason; stages all changes with controlled rollback in an isolated source tree and never publishes. | KEEP |
| `test-static.sh` | Static validation | Source-only fast/full contract entrypoint for source identities/inventories, syntax, version coherence, Codex metadata/rules, workflow boundaries and package/runtime regression registration. | KEEP |
| `tests/aria2-auth-headers-integration.sh` | Integration test | Source-only full-suite test using real aria2 and controlled origins to qualify replay-safe headers, native fallback and cross-origin secret isolation. | KEEP |
| `tests/aria2-real-behavior-integration.sh` | Real-tool qualification | Source-only direct-transfer Range/no-Range/redirect/error/cancel/restart tests against a controlled server; PR coverage plus release checks of newly resolved distribution dependencies with each pinned yt-dlp fallback. | KEEP |
| `tests/ci-validation-integration.py` | Python test | Source-only static-suite adversarial GitHub metadata and workflow graph qualification; protects identity, timestamp consistency, complete gates and absence of redundant main/release suites. | KEEP |
| `tests/source-archive-integration.py` | Python test | Source-only static-suite real Git/ZIP fixtures; reject changed source bytes, paths, modes, symlinks and commit identities before source promotion. | KEEP |
| `tests/ffmpeg-generation-compatibility.sh` | Real-tool qualification | Source-only generation-sensitive FFmpeg/FFprobe media and cancellation tests called by the generation qualification wrapper. | KEEP |
| `tests/ffmpeg-generation-qualification.sh` | Qualification wrapper | Source-only entrypoint for the FFmpeg generation matrix; verifies expected tool versions and runs each real-tool/progress/duration fixture once; its explicit compatibility-only mode avoids duplicating the shared Ubuntu baseline. | KEEP |
| `tests/ffmpeg-progress-integration.sh` | Integration test | Source-only fast/full test of wrapper-managed FFmpeg progress and monitor aggregation using controlled tool behavior. | KEEP |
| `tests/ffmpeg-real-progress-integration.sh` | Real-tool qualification | Source-only test of real FFmpeg `-progress` output, monotonic monitor updates and result-publication gating; separate from the mock progress suite. | KEEP |
| `tests/hls-remux-duration-integration.sh` | Real-tool qualification | Source-only real FFmpeg/FFprobe regression for truncated HLS remux output; requires rejection and preservation of the valid source until publication. | KEEP |
| `tests/install-fedora-authentication-integration.sh` | Integration test | Source-only fast/full bootstrap authentication and root-staging tests using isolated command fixtures; complements privileged RPM signature qualification. | KEEP |
| `tests/installer-integration.sh` | Integration test | Source-only fast/full Bash/Python portable launcher lifecycle tests: escaping, anchored paths, concurrent transactions, rollback, signals and foreign-file preservation. | KEEP |
| `tests/lib/assert.sh` | Sourced Bash test library | Source-only shared checked assertions for statuses, text, paths and modes; callers own shell state and use byte-specific checks where text capture is insufficient. | KEEP |
| `tests/lib/package-lifecycle.sh` | Sourced Bash test library | Source-only common installed-command, symlink, icon, dependency and removal assertions used by RPM/DEB lifecycle and upgrade tests. | KEEP |
| `tests/lib/package-runtime-preservation.sh` | Sourced Bash test library | Source-only deterministic runtime snapshot/probe helpers used by native package lifecycle/upgrade qualification to prove user-data preservation. | KEEP |
| `tests/lib/project-files.sh` | Sourced Bash source inventory | Source-only authoritative shell/Python path arrays and shell exceptions; consumed by static checks, formatting and the canonical runner. | KEEP |
| `tests/lib/test-runner.sh` | Sourced Bash/Python test library | Source-only bounded child/session supervision, identity checks, cancellation and timing helpers used by the canonical and repetition runners. | KEEP |
| `tests/mock-integration.sh` | Integration test | Source-only grouped engine/GUI tests including permissive destination simulation, sentinel secrecy, signal cancellation, old-residue preservation and unconfirmed-shutdown cleanup; the explicit stress-signals aggregate covers all timing-sensitive signal/network/runtime fixtures without joining the ordinary full manifest. | KEEP |
| `tests/package-user-cleanup-integration.sh` | Integration test | Source-only fast/full regression for legacy launchers, custom-XDG ownership records, symlinks and allowlisted RPM user cleanup. | KEEP |
| `tests/packaging-integration.sh` | Integration test | Source-only unprivileged fast/full test of the common package tree, exact installed paths/modes and excluded contributor/portable files. | KEEP |
| `tests/private-aria2-plan-integration.sh` | Bash/Python integration test | Source-only fast/full helper tests: strict private files, publication identities, root selection, unsupported primitives, copy failures, collisions, signals and cleanup preservation. | KEEP |
| `tests/progress-monitor-integration.sh` | Integration test | Source-only fast/full qualification of progress aggregation, phase transitions and the local-disk notice consumed by the Zenity progress interface. | KEEP |
| `tests/push-version-integration.py` | Python test | Static-suite behavioral qualification of the real Git hook and source-version preparation using disposable local repositories; covers omissions, partial staging, remote baselines, deterministic transforms, interruption and rollback. | KEEP |
| `tests/release-docs-integration.py` | Python test | Source-only replay of actual documentation workflow steps with inert release data and a simulated GitHub API; checks exact transforms, streaming, no-op preparation, fast-forward publication, races and hostile handoffs. | KEEP |
| `tests/shfmt-version-handoff-integration.py` | Python test | Source-only replay of actual shfmt workflow steps using local Git repositories and controlled upstream/container stubs; checks independent bump reconstruction, publication leases, no-op runs and rejected mutations. | KEEP |
| `tests/real-tools-integration.sh` | Real-tool qualification | Source-only real local HTTP fixtures for direct/audio/HLS/DASH, optional permissive-directory simulation and explicit disposable network-share qualification. | KEEP |
| `tests/repeat-qualification.sh` | Bash qualification runner | Source-only bounded parallel repetition of independent commands with ordered logs; available for explicit repeat qualifications and exercised by runner integration; ordinary CI does not wrap identical deterministic fixtures in redundant repetitions. | KEEP |
| `tests/rpm6-multisig-integration.sh` | RPM qualification | Source-only Fedora/RPM 6 test using ephemeral keys and a tiny v6 fixture to qualify signer ordering/corruption alongside the production v4 package. | KEEP |
| `tests/run-all-signal-integration.sh` | Integration test | Source-only full-suite HUP/INT/TERM and descendant-cleanup qualification of the canonical test runner; drains subprocess diagnostics during waits and qualifies pipe-capacity backpressure. | KEEP |
| `tests/run-all.sh` | Bash validation runner | Source-only canonical doctor and fast/full scheduler; runs formatting/static/ShellCheck first, then isolated integration suites using shared process supervision. | KEEP |
| `tests/runtime-manager-hardening-integration.sh` | Integration test | Source-only full/stress coverage of managed-runtime authentication, hostile configuration, strict offline mode, identity, locking, journal recovery and rollback. | KEEP |
| `tests/runtime-manager-integration.sh` | Integration test | Source-only fast/full basic runtime bootstrap/update, activation, path/attestation and controlled-failure tests with isolated runtime fixtures. | KEEP |
| `tests/test-runner-integration.sh` | Integration test | Source-only fast/full regression for runner process supervision, scheduling, status propagation and exact validation manifests. | KEEP |
| `tests/zenity-real-session-qualification.sh` | Interactive qualification | Source-only operator-assisted real-desktop GUI scenarios; records visible interactions, process topology and cleanup evidence outside ordinary headless CI. | KEEP |

## Historical and compatibility files

`CHANGELOG.md` is intentionally historical and is installed with the packages. Package upgrade tests, runtime preservation helpers, RPM cleanup, and RPM v4/v6 qualification remain active compatibility or security mechanisms. Legacy launcher paths and old runtime fixtures are retained only where they represent data created by supported previous installations or named compatibility boundaries. No tracked file is currently proven redundant or safe to remove.

## Inventory status

- Tracked and new source files included: **100**.
- Inventory entries: **100**.
- Files retained: **100**.
- Historical files: **1** (`CHANGELOG.md`).
These counts describe inventory coverage, not a defect-free audit verdict. All descriptions are in English; machine-readable filenames, command names, SPDX identifiers, package metadata and protocol tokens retain their required spelling.
