# Validation report - version 2.1.6

Date: July 25, 2026

## Purpose of the change

Version 2.1.6 converts the complete project to English without changing the
core download behavior. It retains the native-audio mode, the Zenity file
chooser compatibility fix, and the aria2c option parser that accepts optional
boolean arguments in brackets, such as `--no-conf[=true|false]`.

The project still exposes one best-quality **native audio track** mode. Its
`yt-dlp` construction follows the supplied `download-audio.sh` strategy:

```text
--format ba/b
--extract-audio
--audio-format best
--audio-quality 0
```

## English-localization checks

- all Markdown documentation is in English;
- all graphical-interface labels and messages are in English;
- the `.desktop` launcher description is in English;
- French comments in scripts were translated;
- integration-test expectations match the English interface;
- hard-coded French directory names were replaced with XDG user-directory
  detection and English fallback paths.

## Automated checks

- `bash -n` on every shipped script;
- argument errors and effective removal of public `--audio-format` and
  `--audio-quality` options;
- audio mode with `ba/b`, format `best`, and quality `0`;
- no forced `mp3`, `m4a`, or `opus` value;
- unchanged MKV video mode;
- migration and persistence of the single `audio` graphical profile;
- URLs containing shell metacharacters;
- output folders and result files containing `%`;
- `yt-dlp` and `aria2c` progress parsing;
- complete process-group cancellation and termination;
- Zenity errors and timeouts;
- no `--ok-label` or `--cancel-label` in folder-selection dialogs;
- automatic folder-chooser retry without `--filename` when preselection fails;
- preservation and display of Zenity stderr diagnostics after a double failure;
- minimum versions of `yt-dlp`, Deno, and `aria2c`;
- `.desktop` launcher installation and removal.

Run:

```bash
./test-static.sh
./tests/mock-integration.sh
./tests/installer-integration.sh
```

## Checks to run on Fedora

```bash
shellcheck -o all download-video.sh download-video-gui.sh install-gui.sh
shellcheck test-static.sh tests/*.sh
```

Then perform two lawful real-world tests: one MKV video and one audio track. The
audio file must preserve the best format offered by the source without an
extension being forced by the interface.

## Locale-stabilized capability probes

Version and capability output is generated under the `C` locale for:

- `yt-dlp --version`;
- `yt-dlp --help`;
- `deno --version`;
- `aria2c --version`;
- `aria2c --help=#all`;
- `setsid --help`.

The actual download worker also runs with `LC_ALL=C`. Zenity windows are not
affected by this assignment and remain in the graphical session's locale.
