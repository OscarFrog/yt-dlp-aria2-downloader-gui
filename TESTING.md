# Testing

This document describes the repeatable validation procedure for the current
project. It is intentionally independent of a particular release date.

## Complete local test suite

Run from the repository root:

```bash
./test-static.sh
./tests/mock-integration.sh
./tests/installer-integration.sh
```

## Bash syntax

```bash
bash -n download-video.sh
bash -n download-video-gui.sh
bash -n install-gui.sh
bash -n test-static.sh
bash -n tests/mock-integration.sh
bash -n tests/installer-integration.sh
```

## ShellCheck

```bash
shellcheck -o all \
  download-video.sh \
  download-video-gui.sh \
  install-gui.sh

shellcheck \
  test-static.sh \
  tests/mock-integration.sh \
  tests/installer-integration.sh
```

## Covered behavior

The automated suite checks, among other things:

- argument validation and exactly one URL per run;
- preservation of URLs containing shell metacharacters;
- trimming of leading and trailing whitespace entered in the GUI;
- native-audio selection with `ba/b`, `best`, and quality `0`;
- absence of forced MP3, M4A, or Opus output formats;
- MKV video selection without forced re-encoding;
- yt-dlp and aria2c progress parsing;
- a neutral final progress message instead of a premature success message;
- monotonic progress after post-processing begins;
- deletion of successful-download logs and retention of failure logs;
- complete process-group cancellation and termination;
- Zenity timeout and unexpected-error handling;
- folder-chooser fallback behavior on Zenity 4;
- minimum versions and required capabilities of yt-dlp, aria2c, and Deno;
- `.desktop` launcher installation, French localization, validation, and
  removal.

## GitHub Actions

`.github/workflows/shell.yml` runs the same validation in two environments:

- `ubuntu-latest`;
- a Fedora 44 container on a GitHub-hosted runner.

`.github/workflows/release.yml` is triggered by tags matching `v*`. It runs
the complete Ubuntu validation job first, verifies that the tag matches the
versions declared by the scripts and documentation, creates a versioned ZIP
archive, generates `SHA256SUMS`, and publishes both files in a GitHub release.

## Real-world checks on Fedora 44

After the automated suite passes, perform two lawful manual tests:

1. download one complete MKV video;
2. download one native audio track.

Verify that cancellation stops the download, the final file opens correctly,
and the audio extension was not forced by the interface.

## Locale-stabilized probes

Version, help, and progress output is generated under `LC_ALL=C` for stable
parsing. Zenity windows remain in the graphical session's locale.
