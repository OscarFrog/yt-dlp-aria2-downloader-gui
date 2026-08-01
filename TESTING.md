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
bash -n install-gui.sh
bash -n test-static.sh
bash -n tests/run-all.sh
bash -n tests/lib/assert.sh
bash -n tests/lib/project-files.sh
bash -n tests/mock-integration.sh
bash -n tests/progress-monitor-integration.sh
bash -n tests/installer-integration.sh
bash -n tests/packaging-integration.sh
bash -n packaging/install-tree.sh
bash -n packaging/deb/build-deb.sh
bash -n packaging/deb/test-package-lifecycle.sh
bash -n packaging/rpm/build-rpm.sh
bash -n packaging/rpm/test-package-lifecycle.sh
```

## ShellCheck

```bash
shellcheck -o all \
  download-video.sh \
  download-video-gui.sh \
  progress-monitor.sh \
  install-gui.sh

shellcheck -x -o all \
  test-static.sh \
  tests/run-all.sh \
  tests/lib/assert.sh \
  tests/lib/project-files.sh \
  tests/mock-integration.sh \
  tests/progress-monitor-integration.sh \
  tests/installer-integration.sh \
  tests/packaging-integration.sh \
  packaging/install-tree.sh \
  packaging/deb/build-deb.sh \
  packaging/deb/test-package-lifecycle.sh \
  packaging/rpm/build-rpm.sh \
  packaging/rpm/test-package-lifecycle.sh
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
- real privileged installation and removal of the generated DEB and RPM in
  disposable GitHub Actions environments, including launcher and icon cleanup.

## GitHub Actions

`.github/workflows/shell.yml` runs the same validation for pull requests and
for pushes to `main`, in two environments:

- `ubuntu-24.04`;
- a Fedora 44 container on a GitHub-hosted runner.

`.github/workflows/packages.yml` builds a DEB on Ubuntu and a noarch RPM in a
Fedora 44 container for every pull request and push to `main`. Each generated
package is installed with its native package manager, its commands, desktop
entry, icon, and version are checked, then the package is removed and the
absence of all application-owned files is verified.

`.github/workflows/release.yml` is triggered by tags matching `v*`. It runs
the complete validation first, verifies tag ancestry and project versions,
builds the ZIP, DEB, and RPM in separate read-only jobs, performs the same real
package installation and removal checks, downloads the exact tested artifacts
into one publication job, generates a shared SHA256SUMS file, and publishes all
four assets. Only the final job receives `contents: write`.

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
