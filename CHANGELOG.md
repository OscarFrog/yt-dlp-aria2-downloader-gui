# Changelog

## Unreleased

### Reliability and data safety

- Read the progress log directly and preserve partial records, eliminating the
  asynchronous reader pipeline and preventing busy loops at end of input.
- Refuse to overwrite an existing machine result file or a pre-existing final
  HLS MKV, and emit symmetric remux completion/error records.
- Bound GUI worker shutdown, protect procfs/PGID reads against races, validate
  that reported results remain inside the selected destination, and surface
  technical progress-monitor failures.
- Strengthen integration tests with bounded process waits, fragmented-record
  coverage, result-collision checks, and deterministic monotonic-progress
  assertions.

## 2.1.12 - 2026-07-29

### Unified download progress

- Add structured `yt-dlp` planning and progress records with format identifiers,
  byte counts, estimated sizes, and fragment counters.
- Aggregate separate video and audio transfers instead of treating each local
  100% value as completion of the whole operation.
- Preserve `aria2c` console progress as a fallback for direct transfers and use
  a bounded animated state whenever no reliable total size is available.
- Represent merge, remux, extraction, metadata, and final verification as
  explicit phases; 100% is emitted only after the atomic result file exists and
  the worker has exited.

### Authenticated YouTube HLS fallback

- Add an explicit video-only profile that reads Firefox cookies and selects
  `web_safari` HLS formats for YouTube sessions affected by sign-in checks or
  GVS HTTP 403 responses.
- Keep ordinary video, native-audio, and non-YouTube behavior unchanged.
- Let yt-dlp repair MPEG-TS-in-MP4 HLS output before a separate stream-copy MKV
  remux, preventing unknown-timestamp failures in FFmpeg's Matroska muxer.
- Ignore the native HLS bootstrap record reported as 100% at fragment 0/N.
- Validate the selected URL, persist the GUI profile, and cover the exact
  yt-dlp and FFmpeg argument vectors with integration tests.

### Validation

- Add dedicated progress-monitor integration scenarios for direct files, native
  downloads, HLS, DASH, composite streams, post-processing, unknown sizes, late
  output, and failure paths.
- Keep the existing GUI cancellation and process-group tests as regression
  coverage for interrupted downloads.

### Review hardening

- Normalize the final `after_move` path record to one verified regular file and
  reject stale, empty, or missing result targets before publishing GUI success.
- End the progress monitor cleanly when Zenity closes its input pipe and surface
  state-directory or temporary-log initialization failures in the graphical UI.
- Make release re-runs verify existing assets without overwriting them, validate
  semantic version tags strictly, and align Fedora CI timeout diagnostics with
  Ubuntu.

## 2.1.11 - 2026-07-29

### GUI and installer fixes

- Preserve the download worker's exit status when the retained log viewer is
  closed, and avoid displaying a failed download as 100% complete.
- Save GUI preferences transactionally, parse progress percentages explicitly
  as base 10, and relaunch the GUI through Bash when requested.
- Resolve scripts invoked as `bash script.sh` from the current directory.
- Allow uninstall from XDG paths rejected for desktop-entry generation, publish
  the desktop file with `mv -T`, and report launcher-link read failures clearly.

### Test reliability

- Normalize expected exit statuses as decimal values in the assertion helpers
  and isolate split-stream commands from the test harness shell.
- Reject missing or empty canonical file lists before running ShellCheck.
- Replace brittle comment-presence assertions with behavioral coverage.
- Improve integration-test dependency diagnostics, asynchronous `gio` polling,
  interrupted-worker cleanup, and hostile newline-path coverage.

## 2.1.10 - 2026-07-28

### Runtime robustness

- Publish result paths atomically only after a successful yt-dlp run and remove
  stale result files before starting.
- Recover the worker process group through `/proc` when PGID-file publication is
  delayed, and terminate the complete worker tree on startup failure.
- Resolve the cancellation/completion race, treat zombie supervisors as
  completed, verify actual process-group signal delivery, keep `setsid --wait`
  alive for graceful reaping, and force-stop it after the final `KILL` fallback.
- Exit the progress producer explicitly when Zenity closes its pipe, so
  cancellation cannot remain blocked in a synchronous Bash pipeline.
- Use real newlines in Zenity error dialogs.
- Handle configuration files without a final newline and ignore only the partial
  first record of oversized progress logs.
- Remove retained diagnostic logs older than 15 days when the graphical
  interface starts.

### Installer and validation

- Reject occupied non-symlink launcher paths, verify the published link target,
  report skipped optional desktop validation, and normalize validation failures.
- Remove known stale installer artifacts during uninstall and validate all
  required installer commands explicitly.
- Separate product failures from test-harness errors, distinguish grep failures,
  verify command invocability, and centralize the project shell-file lists.

## 2.1.9 - 2026-07-27

### Process lifecycle and progress

- Publish the worker process-group identifier atomically before the GUI reads it.
- Keep retrying transient or incomplete PGID reads instead of accepting a
  partial numeric value.
- Protect the cleanup critical section from repeated termination signals while
  preserving the original exit status.
- Display aria2c transfer speed even when the server does not report a total
  size or percentage.

### Desktop launcher

- Install a stable private launcher link so project paths containing Desktop
  Entry field-code characters remain usable.
- Apply the two required Desktop Entry escaping layers to the stable `Exec`
  path and reject XDG data paths that cannot be represented portably.
- Improve `desktop-file-validate` diagnostics while preserving an existing
  launcher after validation failure.
- Reject relative `XDG_DATA_HOME` values and clean up the stable launcher link
  during uninstall.

### Test reliability

- Avoid changing the caller's `errexit` state inside assertion helpers.
- Add exact-line assertions, readable-file checks, and explicit argument-count
  diagnostics.
- Verify option/value adjacency, locale stabilization, aria2c progress without
  a percentage, and additional engine and GUI error paths.
- Expand installer coverage for hostile project paths, exact `Exec` escaping,
  permissions, validation failures, reinstallations, and missing GUI scripts.

## 2.1.8 - 2026-07-27

### Argument parsing and diagnostics

- Unified positional-URL handling before and after `--`.
- Accept a harmless terminal `--` and reject duplicate URLs consistently.
- Distinguish unparseable runtime versions from versions that are too old.
- Use stable profile-label constants and report directory-resolution failures.

### Tests and continuous integration

- Added a shared `tests/run-all.sh` entry point for local, Ubuntu, Fedora, and
  release validation.
- Added reusable assertion helpers with named failure diagnostics.
- Made retained-log tests independent of scenario order.
- Added coverage for suffixed yt-dlp versions and separator edge cases.
- Added manual workflow dispatch for CI and release recovery.

### Installer and releases

- Removed the unnecessary MIME database refresh for a launcher without
  `MimeType` associations.
- Made repeated launcher removal messages accurate.
- Verified that a release tag resolves to the checked-out commit.
- Extracted and ran the complete validation suite from the final ZIP before
  publishing it.

### Documentation

- State the GNU/Linux-only platform requirement explicitly.
- Explain that yt-dlp-ejs components may be downloaded from npm and executed by
  Deno with restricted permissions.

## 2.1.7 - 2026-07-27

### Diagnostics and interface

- Delete the private download log after a successful run only when the final
  media file can be confirmed.
- Retain logs for failed, canceled, interrupted, or inconsistent runs.
- Keep graphical progress monotonic after yt-dlp enters post-processing.
- Read the last non-empty result path defensively when yt-dlp writes more than
  one `after_move` record.

### Installer and release safety

- Generate, validate, and replace the `.desktop` launcher atomically.
- Require the release workflow's validation job to succeed before publishing
  the ZIP archive and checksum.
- Verify script, README, and changelog versions before creating a release.

### Documentation and tests

- Clarify that native audio is preserved whenever possible, rather than
  promising that FFmpeg will never be required.
- Add integration coverage for successful-log deletion, failed-log retention,
  monotonic post-processing progress, and launcher temporary-file cleanup.

## 2.1.6 - 2026-07-27

### Post-review maintenance

- Trimmed accidental leading and trailing whitespace from URLs entered in the
  graphical interface.
- Replaced the premature final progress message with a neutral finalization
  message until the worker exit status is known.
- Added a French localized description to the generated `.desktop` launcher.
- Consolidated version-specific notes into this changelog and replaced the
  dated validation report with reusable testing documentation.
- Added GitHub Actions validation in a Fedora 44 container.
- Added tag-driven release automation for a versioned ZIP and `SHA256SUMS`.

### English localization

- Translated all Markdown documentation into English.
- Translated all Zenity labels, messages, and completion actions into English.
- Translated the application launcher's `.desktop` description into English.
- Translated the remaining French comments and integration-test expectations.
- Replaced hard-coded French directory fallbacks with XDG user-directory
  detection and English fallback paths.
- Updated the project version to 2.1.6.

### Validation

- Updated integration assertions for the English graphical interface.
- Retained Bash syntax checks, ShellCheck validation, mock integration tests,
  and launcher installation tests.

## 2.1.5 - 2026-07-25

### Locale stabilization

- Ran `yt-dlp --version` with `LC_ALL=C`.
- Ran `yt-dlp --help` with `LC_ALL=C`.
- Ran `deno --version` with `LC_ALL=C`.
- Ran `aria2c --version` with `LC_ALL=C`.
- Ran `aria2c --help=#all` with `LC_ALL=C`.
- Ran `setsid --help` with `LC_ALL=C`.
- Kept `LC_ALL=C` on the download worker to stabilize actual `yt-dlp` and
  aria2c progress output.

### Tests

- Added static checks preventing regressions in the six stabilized probes.
- Kept validation of the worker launch with
  `LC_ALL=C setsid --fork --wait`.

## 2.1.4 - 2026-07-25

### Interface

- Added a **New download** button after a successful download.
- The button restarts the interface at the URL entry step.
- The last destination folder and profile remain saved.

### Application launcher

- Replaced `Categories=AudioVideo;Network;` with `Categories=AudioVideo;`.
- Removed the warning about multiple main categories.

### Tests

- Updated the launcher integration test.
- Added validation for the **New download** button.

## 2.1.3 - 2026-07-25

### aria2c compatibility

- Fixed a false capability failure on Fedora's aria2c help syntax such as
  `--no-conf[=true|false]`. The parser now recognizes bracketed optional
  arguments in addition to `=VALUE`, whitespace, and end-of-line forms.
- Forced the aria2c version/help probes to use `LC_ALL=C` for stable parsing.
- Updated the integration mock to reproduce the real aria2c 1.37 help format.

### Interface

- Replaced literal `\n` sequences in the download-failure question with real
  line breaks.

## 2.1.2 - 2026-07-25

### Zenity

- Removed `--ok-label` and `--cancel-label` from directory-selection dialogs.
  Zenity 4 file choosers on Fedora reject these options even though they are
  accepted by other dialog types.
- Kept custom labels on entry and list dialogs, where they are supported.
- Added an integration guard that fails if custom button-label options are ever
  passed to a file-selection dialog again.

## 2.1.1 - 2026-07-25

### Zenity

- Captured Zenity stderr for unexpected dialog failures and displayed the
  underlying diagnostic instead of only a generic error.
- Added a compatibility fallback for directory selection: when the chooser
  fails with the remembered `--filename` directory, retry once without an
  initial directory.
- Added an integration test that simulates a `--filename`-specific Zenity
  failure and verifies the successful fallback.

## 2.1.0 - 2026-07-25

### Audio

- Reused the dedicated `download-audio.sh` selection strategy for audio mode:
  `ba/b`, `--extract-audio`, `--audio-format best`, and `--audio-quality 0`.
- Removed the public `--audio-format` and `--audio-quality` CLI options so the
  application no longer forces MP3, M4A, Opus, or another conversion format.
- Preserved the best source audio codec/container whenever possible.

### Interface

- Reduced the profile selector to exactly two entries: complete MKV video or
  native-format audio track.
- Migrated saved `audio-mp3`, `audio-m4a`, and `audio-opus` profiles to the new
  single `audio` profile.

### Tests and documentation

- Updated integration tests to require `ba/b`, `--audio-format best`, and
  `--audio-quality 0` while rejecting forced MP3/M4A/Opus values.
- Updated CLI validation, README files, and release validation notes.

## 2.0.4 - 2026-07-24

### Tests

- Added local `ffmpeg` and `ffprobe` mocks to the integration test so it no
  longer depends on executables installed on the host.
- Added assertions that both media tools resolve to the private mock directory.
- Replaced the remaining single-quoted French strings containing Unicode
  apostrophes in the test assertions.

### Static analysis

- Initialized `URL`, `PROFILE`, and `OUTPUT_DIR` before the Zenity selection
  loops to make their data flow explicit and avoid the SC2153 false positive.

## 2.0.3 - 2026-07-24

- Fixed the warnings and optional diagnostics reported by
  `shellcheck -o all` on the three production scripts.
- Removed reliance on `errexit` inside functions used as conditions by
  capturing expected statuses explicitly.
- Replaced process substitutions used for version discovery with checked
  command substitutions.
- Added explicit default branches to configuration and profile `case`
  statements.
- Replaced typographic apostrophes in single-quoted shell strings with
  double-quoted literal strings.
- Made Zenity error dialogs best-effort with a stderr fallback.
- Strengthened yt-dlp and aria2c capability checks so option names must appear
  as option definitions, not merely inside descriptive text.
- Configured CI to run ShellCheck optional checks on production scripts.

## 2.0.2 - 2026-07-24

- Raised the minimum yt-dlp version to 2026.06.09, which contains the security
  fix relevant to aria2c-backed downloads.
- Added an aria2c 1.37.0 minimum-version check and negative integration test.
- Added integration tests for Zenity progress timeout and unexpected progress
  errors, including process-group termination verification.
- Extended local syntax validation to every shipped Bash script.
- Preserved conventional signal exit codes: 129 for HUP, 130 for INT, and 143
  for TERM.
- Pinned actions/checkout v7.0.1 to its full commit SHA, disabled persisted
  credentials, and added a CI timeout.

## 2.0.1 - 2026-07-24

- Confirmed that the reported concatenated lines were display artifacts; all
  shipped Bash files pass syntax validation.
- Added minimum-version checks for yt-dlp 2025.11.12 and Deno 2.3.0.
- Added runtime capability checks for required yt-dlp and aria2c options.
- Distinguished Zenity cancellation, timeout, validation failure, and internal
  errors in all selection dialogs.
- Added integration coverage for dependency and Zenity failure paths.

## 2.0.0 - 2026-07-24

- Added the Zenity interface.
- Added destination-folder selection.
- Added MKV video, MP3 audio, M4A audio, and Opus audio profiles.
- Added atomic persistence of the last profile and destination folder.
- Added structured `yt-dlp` progress and fallback `aria2c` progress.
- Added private, unique logs.
- Added complete process-group cancellation.
- Added a `.desktop` launcher installer.
- Added static tests, mocked-command tests, and continuous integration.
- Added the `--output-dir`, `--mode`, `--audio-format`, `--audio-quality`,
  `--machine-progress`, and `--result-file` CLI options.
- Isolated user configurations with `--ignore-config` for `yt-dlp` and
  `--no-conf=true` for `aria2c`.

## 1.1.0 - 2026-07-22

- Initial MKV video engine using `yt-dlp` and `aria2c`.
