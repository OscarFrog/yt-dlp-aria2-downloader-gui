# Changelog

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
