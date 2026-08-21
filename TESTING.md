# Testing

This document describes the repeatable validation procedure for the current
project. It is intentionally independent of a particular release date.

## Complete local test suite

Run from the repository root:

```bash
./tests/run-all.sh
```

## Bash syntax

```bash
bash -n download-video.sh
bash -n download-video-gui.sh
bash -n progress-monitor.sh
bash -n runtime-manager.sh
bash -n install-fedora.sh
bash -n install-gui.sh
bash -n test-static.sh
bash -n tests/run-all.sh
bash -n tests/lib/assert.sh
bash -n tests/lib/project-files.sh
bash -n tests/mock-integration.sh
bash -n tests/runtime-manager-integration.sh
bash -n tests/runtime-manager-hardening-integration.sh
bash -n tests/progress-monitor-integration.sh
bash -n tests/installer-integration.sh
bash -n tests/packaging-integration.sh
bash -n tests/package-user-cleanup-integration.sh
bash -n tests/ffmpeg-progress-integration.sh
bash -n tests/real-tools-integration.sh
bash -n packaging/install-tree.sh
bash -n packaging/package-user-cleanup.sh
bash -n packaging/deb/build-deb.sh
bash -n packaging/deb/postinst
bash -n packaging/deb/prerm
bash -n packaging/deb/postrm
bash -n packaging/deb/test-package-lifecycle.sh
bash -n packaging/deb/test-package-upgrade.sh
bash -n packaging/rpm/build-rpm.sh
bash -n packaging/rpm/test-package-lifecycle.sh
bash -n packaging/rpm/test-package-upgrade.sh
```

## ShellCheck

```bash
shellcheck -o all \
  download-video.sh \
  download-video-gui.sh \
  progress-monitor.sh \
  runtime-manager.sh \
  install-gui.sh

shellcheck -x -o all \
  test-static.sh \
  tests/run-all.sh \
  tests/lib/assert.sh \
  tests/lib/project-files.sh \
  install-fedora.sh \
  tests/mock-integration.sh \
  tests/runtime-manager-integration.sh \
  tests/runtime-manager-hardening-integration.sh \
  tests/progress-monitor-integration.sh \
  tests/installer-integration.sh \
  tests/packaging-integration.sh \
  tests/package-user-cleanup-integration.sh \
  tests/ffmpeg-progress-integration.sh \
  tests/real-tools-integration.sh \
  packaging/install-tree.sh \
  packaging/package-user-cleanup.sh \
  packaging/deb/build-deb.sh \
  packaging/deb/postinst \
  packaging/deb/prerm \
  packaging/deb/postrm \
  packaging/deb/test-package-lifecycle.sh \
  packaging/deb/test-package-upgrade.sh \
  packaging/rpm/build-rpm.sh \
  packaging/rpm/test-package-lifecycle.sh \
  packaging/rpm/test-package-upgrade.sh
```

## Covered behavior

The automated suite checks, among other things:

- argument validation, terminal `--`, and exactly one URL per run;
- preservation of URLs containing shell metacharacters;
- trimming of leading and trailing whitespace entered in the GUI;
- native-audio selection with `ba/b`, `best`, and quality `0`;
- absence of forced MP3, M4A, or Opus output formats;
- MKV video selection without forced re-encoding;
- structured yt-dlp planning and progress records, aria2c console fallback,
  byte-weighted progress, fragment progress, and unknown-size animation;
- separate video/audio transfers, direct audio, HLS, DASH, merge, remux,
  extraction, late progress, and error paths;
- verification that a local transfer reaching 100% does not complete the global
  operation and that global 100% appears only after final-result publication;
- deletion of successful-download logs and retention of failure logs;
- automatic removal of retained diagnostic logs older than 15 days while
  preserving newer logs, unrelated files, and symbolic links;
- atomic process-group publication, bounded cancellation tests, explicit
  progress-pipe closure, termination, and verification that no worker process
  remains after GUI scenarios;
- process-group recovery when PGID-file publication is delayed;
- atomic publication and failure cleanup of the result-path file;
- rejection of a second writer targeting the same canonical output directory;
- explicit refusal to overwrite completed or post-processed media files while
  preserving interrupted-download resume behavior;
- disabling of inherited yt-dlp plugins and personal configuration;
- forwarding of HUP, INT, and TERM sent only to the CLI wrapper PID;
- forwarding of termination signals during the wrapper-managed HLS FFmpeg remux;
- preservation of immediate command failure statuses before PGID observation;
- one shared process session for GUI, engine, yt-dlp, aria2c, FFmpeg, and Deno;
- FFprobe rejection of missing or structurally invalid expected media streams;
- canonical destination validation before the progress monitor emits 100 percent;
- no-target-directory publication when a destination changes into a directory;
- private XDG runtime locks and fallback permissions;
- byte-bounded Unicode output templates;
- fallback from relative XDG configuration and state paths;
- retention of process-group control until every descendant has exited;
- Zenity timeout and unexpected-error handling;
- folder-chooser fallback behavior on Zenity 4;
- minimum versions, suffixed yt-dlp versions, required capabilities, and
  behavior under a hostile inherited locale;
- aria2 help lines containing short-option aliases and builds that omit the
  optional netrc capability;
- `.desktop` launcher installation through a stable private link, exact Exec
  escaping, restrictive-path handling, validation, permissions, reinstall, and
  removal;
- package install-tree layout, stable command symlinks, system desktop entry,
  dedicated hicolor icon, documentation permissions, and exclusion of tests
  and obsolete images;
- real privileged installation and removal of the generated RPM in Fedora 44
  `fresh` and `ffmpeg-free` GitHub Actions environments, including launcher and
  icon cleanup;
- fail-closed rejection of an unsigned PR RPM by the production Fedora bootstrap,
  with unsigned installation permitted only through the explicit
  `--allow-unsigned-dev` development path;
- real build, APT installation, removal, and ownership validation of the DEB on
  Ubuntu 24.04 without system yt-dlp or Deno package dependencies.

- private GUI URL transfer through owner-only URL and yt-dlp batch files, with
  the requested URL absent from GUI, engine, and yt-dlp process arguments;
- retained-log URL redaction, an 8 MiB retained-size limit, and private live
  diagnostics kept under the runtime temporary directory;
- complete-video rejection when either the video or audio stream is absent;
- conditional Deno requirements and YouTube-only remote EJS fallback;
- measured wrapper-managed FFmpeg remux progress and bounded progress arithmetic;
- hermetic real-tool transfers using generated media and a loopback HTTP server;
- managed-runtime operation with Deno outside PATH, bounded lock/network waits,
  strict zero-network `require` mode, exact-tag stable/nightly/stable switching,
  lock-descriptor isolation, ten-cycle contention/double-rollback stress,
  interrupted-activation journal recovery, explicit/automatic rollback, and
  x86_64/aarch64 asset mapping.
- package reinstall plus real previous-immutable-release -> current upgrade
  validation for RPM and DEB, using the exact previously published package
  bytes rather than rebuilding the previous version from source;
- preservation of a deterministic archive snapshot of the per-user
  managed-runtime tree across previous package installation and package
  upgrade, followed by allowlisted managed-runtime cleanup on final package
  removal;
- package-cleanup integration coverage for a custom `XDG_DATA_HOME`, exact
  legacy `-gui` paths, preservation of unrelated similarly named files, and
  preservation of a portable ZIP/Git launcher;
- exact same RPM artifact tested in Fedora `fresh` and `ffmpeg-free`;
- current stable yt-dlp compatibility in addition to the minimum supported
  version;
- exact release asset inventory and immutable-release/asset verification.

## GitHub Actions

`.github/workflows/shell.yml` runs the same validation for pull requests and
for pushes to `main`, in two environments:

- `ubuntu-24.04`;
- a Fedora 44 container on a GitHub-hosted runner.

`.github/workflows/packages.yml` validates both package formats. Before package
upgrade testing, a dedicated `previous-release` job resolves the immediately
preceding semantic-version release, requires it to be immutable, downloads its
exact published RPM, DEB, and SHA256SUMS, and verifies release identity,
checksums, release-asset identity, and SLSA provenance bound to the expected
repository, release workflow, and exact source commit. The RPM and DEB upgrade
jobs consume those verified bytes through a short-lived Actions artifact and
recheck their transferred SHA-256 digests before installation.

Pull-request CI builds one unsigned noarch RPM and proves that the production
bootstrap rejects it unless `--allow-unsigned-dev` is explicitly selected.
Release CI builds the RPM once, signs those exact bytes once in the isolated
`rpm-signing` GitHub Environment, and then installs the identical signed RPM
on Fedora 44 in `fresh` and `ffmpeg-free` scenarios through the supported
RPM Fusion bootstrap. The
architecture-independent DEB is built on Ubuntu 24.04, installed with APT, and
removed again. Both lifecycle checks verify the managed-runtime manager and
embedded yt-dlp signing key; the DEB no longer depends on distribution yt-dlp
or Deno packages.


`.github/workflows/real-tools.yml` installs actual yt-dlp, aria2c, FFmpeg, and
FFprobe on Ubuntu. It generates tiny media fixtures locally, serves them over a
loopback HTTP server, validates a complete video with audio, and rejects a
video-only result without contacting a public media service.

`.github/workflows/release.yml` is triggered by tags matching `v*`. It runs
the complete validation and the hermetic real-tool integration first, verifies
tag ancestry and project versions, then resolves the previous semantic-version
release.

That previous release must be immutable. Its exact published RPM and DEB are
downloaded and verified with the published SHA256SUMS, `gh release verify`,
`gh release verify-asset`, and SLSA provenance constrained to the expected
repository, release workflow, and exact source commit.

The current ZIP, RPM, and DEB are built in separate jobs. The release RPM is
built exactly once as an unsigned artifact, then a secret-bearing signing job
with no repository checkout verifies the expected signing-key fingerprint and
adds the OpenPGP signature. The resulting signed RPM bytes are the exact bytes
requalified in Fedora `fresh` and `ffmpeg-free` and later published. RPM and DEB upgrade tests use the previously published
immutable package bytes and verify that a deterministic archive snapshot of
the per-user managed-runtime tree remains unchanged across installation and
upgrade. Final package removal then verifies that the managed runtime has been
removed by the package cleanup hook.

The publication job downloads the exact tested current artifacts, adds the
public `RPM-GPG-KEY-OscarFrog` certificate, generates one shared SHA256SUMS file,
verifies the exact release asset inventory, requires the
resulting GitHub Release to be immutable, and verifies the release attestation
and every local asset.

If a newly created release unexpectedly remains mutable, the workflow attempts
to delete it and verifies that cleanup succeeded. Failure or unconfirmed cleanup
causes publication to fail explicitly. Only the final job receives
`contents: write`.

## Release maintainer preflight

Before pushing a release tag, confirm that GitHub Immutable Releases are
enabled for the repository:

    gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2026-03-10' \
      repos/OscarFrog/yt-dlp-aria2-downloader-gui/immutable-releases \
      --jq '.enabled'

The command requires repository administration read access. A successful
preflight must return:

    true

A specific release is considered qualified only after its final `publish` job
has completed successfully. The presence of immutable-release, attestation, or
asset-verification commands in the workflow alone is not evidence that a
particular release actually passed those checks.

## Real-world checks on Fedora 44

After the automated suite passes, perform lawful manual tests:

1. download one complete MKV video;
2. download one native audio track;
3. download one YouTube video with the authenticated Firefox HLS profile;
4. cancel one direct transfer and one fragmented HLS transfer;
5. test a destination containing spaces, Unicode characters, and `%`;
6. verify that a second concurrent download targeting the same output cannot
   corrupt files created by the first one;
7. interrupt the authenticated HLS profile during the final FFmpeg remux and
   verify that no FFmpeg process remains;
8. verify one audio and one video result with FFprobe before opening them.

Verify that cancellation stops the download, the final files open correctly,
the audio extension was not forced by the interface, and no worker process is
left behind.

## Locale-stabilized probes

Version, help, and progress output is generated under `LC_ALL=C` for stable
parsing. Zenity windows remain in the graphical session's locale.

## Stress validation

`.github/workflows/stress.yml` runs two independent ten-pass stress jobs on pull
requests and pushes to `main`:

- the complete mock process/cancellation integration suite ten times, increasing
  the probability of exposing cancellation, PGID publication, process-reaping,
  and timing races;
- the runtime-manager hardening integration suite ten times, repeatedly
  exercising fresh bootstrap, strict zero-network behavior, exact-tag
  resolution, activation-journal recovery, lock contention, and rollback
  transactions.
