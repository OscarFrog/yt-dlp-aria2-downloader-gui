# yt-dlp aria2 downloader

[![Shell validation](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[Version française](README.fr.md)

A Zenity graphical interface and Bash download engine for GNU/Linux only. It downloads a
single URL using one of three profiles:

- a **complete MKV video**, using the best available video and audio streams;
- an explicit **authenticated YouTube HLS video** profile that reads Firefox
  cookies and remuxes the selected HLS stream into MKV;
- the **best available audio track**, preserving its source codec and
  container whenever yt-dlp can do so without re-encoding.

The project uses `yt-dlp` for media extraction, `aria2c` to accelerate direct
HTTP/FTP downloads, and FFmpeg to merge, remux, or extract streams. DASH and HLS
streams deliberately remain on yt-dlp's native downloader. The current version
is **2.1.21**.

## Recommended installation

Open the [latest GitHub release](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest)
and download the file matching your system:

- **Fedora 44 or newer:** `2.1.21` RPM,
  `yt-dlp-aria2-downloader-gui-2.1.21-1.fc44.noarch.rpm`;
- **Debian 13 (Trixie) with `trixie-backports` enabled:** `2.1.21` DEB,
  `yt-dlp-aria2-downloader-gui_2.1.21-1_all.deb`;
- **Ubuntu, other GNU/Linux distributions, or portable use:** the versioned ZIP.
  Ensure that `yt-dlp` and `aria2c` satisfy the minimum versions listed below.

For an RPM or DEB installation, the graphical launcher and its application icon
are installed automatically in the desktop application menu. **Do not run
`install-gui.sh` after installing a package.** That helper is only for ZIP and
Git installations.

## Main features

- simple Zenity graphical interface;
- download engine that can also be used from a terminal;
- one URL per run, with accidental playlist downloads disabled;
- personal yt-dlp configuration and plugins are disabled for deterministic execution;
- completed media and post-processed outputs are never overwritten silently;
- destination-folder selection and preference persistence;
- MKV video download without re-encoding when the streams are compatible;
- optional authenticated YouTube HLS fallback using Firefox cookies;
- extraction of the best audio track while preserving its source format when possible;
- interrupted-download resumption when supported by the website;
- unified graphical progress for direct files, native HLS/DASH fragments,
  separate video/audio streams, and FFmpeg post-processing;
- cancellation of the complete process group through one shared GUI session;
- supervised yt-dlp and wrapper-managed FFmpeg commands, including bounded shutdown;
- FFprobe validation of both video and audio streams for complete-video results, and of the audio stream for audio results, before success is published;
- one active writer per destination directory, preventing concurrent
  instances from sharing partial or post-processing files;
- private diagnostic logs retained only for problematic runs, with URL redaction and an 8 MiB retained-size cap;
- application-menu launcher;
- static tests, integration tests, and GitHub Actions validation on Ubuntu,
  Debian 13, and Fedora 44.

## Requirements

The following commands must be installed and available in `PATH`:

- Bash **4.4 or newer**;
- `yt-dlp` **2026.06.09 or newer**;
- `aria2c` **1.37.0 or newer**;
- FFmpeg and `ffprobe`;
- Deno **2.3.0 or newer for YouTube extraction**; other supported sites can run without Deno;
- Zenity for the graphical interface;
- Firefox with an authenticated YouTube session only when using the optional
  authenticated YouTube HLS profile;
- GNU coreutils, GNU grep, and `setsid`, which is usually provided by
  `util-linux`.

The engine always checks the minimum versions of `yt-dlp` and `aria2c`. Deno is checked only when it is installed or when YouTube extraction requires it.

## Package installation

GitHub releases publish a Fedora RPM, a Debian package, the portable ZIP, and a
single `SHA256SUMS` file. Package installations place the commands, dedicated
application icon, and desktop launcher system-wide; they do not depend on the
directory where the downloaded package was stored. No separate
`install-gui.sh` command is required for RPM or DEB installations.

When upgrading from a ZIP or Git installation, remove the old per-user launcher
first so it cannot override the packaged desktop entry:

```bash
./install-gui.sh uninstall
```

### Fedora 44 and newer

The complete `ffmpeg` package comes from RPM Fusion Free. Enable that repository
before installing the RPM when it is not already configured:

```bash
sudo dnf install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
```

Download these release assets:

```text
yt-dlp-aria2-downloader-gui-2.1.21-1.fc44.noarch.rpm
SHA256SUMS
```

Verify the downloaded RPM and install it:

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo dnf install --allowerasing ./yt-dlp-aria2-downloader-gui-2.1.21-1.fc44.noarch.rpm
```

The RPM declares yt-dlp, aria2, FFmpeg/FFprobe, Zenity, and the required GNU command-line tools as hard dependencies. Deno remains a separately managed runtime and is required only for YouTube extraction.

### Debian 13 (Trixie)

The DEB requires `aria2 >= 1.37.0` and `yt-dlp >= 2026.06.09`. Debian 13
provides the required aria2 version in the base distribution and a sufficiently
recent yt-dlp through `trixie-backports`. Enable backports first:

```bash
printf '%s\n' 'deb http://deb.debian.org/debian trixie-backports main' | \
  sudo tee /etc/apt/sources.list.d/trixie-backports.list >/dev/null
sudo apt update
sudo apt install -t trixie-backports yt-dlp
```

Download these release assets:

```text
yt-dlp-aria2-downloader-gui_2.1.21-1_all.deb
SHA256SUMS
```

Verify and install the package:

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.1.21-1_all.deb
```

APT now rejects the installation if the configured repositories cannot satisfy
the same yt-dlp and aria2 minimum versions enforced by the engine.

### Ubuntu

The DEB is not currently advertised as a turnkey Ubuntu package because the
supported Ubuntu repositories do not provide the yt-dlp minimum required by
this release. Use the portable ZIP or Git installation instead and install a
compatible `yt-dlp` separately. Verify it with `yt-dlp --version` before use;
do not force-install the DEB while ignoring package dependencies.

### Packaged commands

After RPM or DEB installation, start the graphical interface from the
application menu or run:

```bash
yt-dlp-aria2-downloader-gui
```

The terminal engine is installed as:

```bash
yt-dlp-aria2-downloader --help
```

### Removing a package installation

Fedora:

```bash
sudo dnf remove yt-dlp-aria2-downloader-gui
```

Debian:

```bash
sudo apt remove yt-dlp-aria2-downloader-gui
```

The package manager removes the system commands, desktop launcher, and
application icon. `install-gui.sh uninstall` is only needed to clean up an
older ZIP or Git installation created in the current user's home directory.

## Installation from a portable release archive

Download these release assets:

```text
yt-dlp-aria2-downloader-gui-2.1.21.zip
SHA256SUMS
```

Verify and extract the archive:

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.21.zip
cd yt-dlp-aria2-downloader-gui-2.1.21
chmod +x download-video.sh download-video-gui.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

## Installation from Git

Clone the repository:

```bash
git clone https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui.git
cd yt-dlp-aria2-downloader-gui
```

Make the scripts executable and install the application-menu launcher:

```bash
chmod +x download-video.sh download-video-gui.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

The **yt-dlp aria2 downloader** launcher is created in:

```text
~/.local/share/applications/
```

The desktop entry calls a stable per-user launcher link stored under:

```text
~/.local/share/yt-dlp-aria2-downloader/launch
```

That private link targets the repository's absolute GUI-script path. After
moving the project directory, run `./install-gui.sh install` again.

## Graphical usage

The graphical workflow uses a sequence of native Zenity dialogs. The steps below describe the complete interface without relying on screenshots, so the documentation remains accurate when dialog dimensions or desktop themes change.

Start **yt-dlp aria2 downloader** from the application menu. A package
installation also provides `yt-dlp-aria2-downloader-gui`; from a ZIP or
Git checkout, run:

```bash
./download-video-gui.sh
```

### 1. Enter the video URL

Paste the URL of the video to download, then validate the dialog.


Leading and trailing whitespace accidentally copied with the URL is removed by
the graphical interface.

### 2. Choose the download mode

Select one of the three available profiles:

- **Complete video (MKV)** downloads the best available video and audio streams
  and combines them in an MKV container;
- **YouTube video - Firefox cookies (HLS/MKV)** is an explicit authenticated
  fallback for YouTube and reads the local Firefox session before downloading
  an HLS stream and remuxing it to MKV;
- **Audio track (native format)** downloads the best available audio track while
  preserving its native format whenever possible.


### 3. Choose the destination folder

Select the folder where the downloaded media will be saved.


### 4. Follow the download progress

The progress dialog displays transfer progress and post-processing stages. Wrapper-managed FFmpeg remuxing uses FFmpeg machine progress and the source duration instead of an artificial timer. Use
the cancel button to stop the complete download process.


### 5. Download result

After a successful download, the interface displays the path of the completed
media file.


When the download fails, the interface displays an error dialog and preserves
the diagnostic log.


The retained log can be opened from the error dialog. Before retention, URL-like values are replaced with `[REDACTED_URL]` and only the last 8 MiB are kept. The live log is private (`0600`) while the worker is running.



### Privacy of URLs in the graphical interface

The GUI writes the requested URL to a private temporary file and passes only that file path to the engine. The engine then supplies yt-dlp through its private batch-file interface, so the URL is not exposed in the GUI, engine, or yt-dlp command-line arguments. URLs containing `user:password@host` are rejected. Direct CLI use with a positional URL remains supported; as with any command-line program, that positional URL can be visible in the invoking process arguments.

## Command-line usage

Download a complete MKV video:

```bash
./download-video.sh \
  --mode video \
  --output-dir "${HOME}/Videos" \
  'https://example.com/video'
```

Download the best native audio track:

```bash
./download-video.sh \
  --mode audio \
  --output-dir "${HOME}/Music" \
  'https://example.com/video'
```

Use the authenticated YouTube HLS fallback:

```bash
./download-video.sh \
  --mode video \
  --youtube-hls-firefox \
  --output-dir "${HOME}/Videos" \
  'https://www.youtube.com/watch?v=VIDEO_ID'
```

Display help or version information:

```bash
./download-video.sh --help
./download-video.sh --version
```

Always quote URLs with single or double quotation marks because they may
contain shell metacharacters such as `&`.

The engine deliberately uses `--ignore-config`, disables yt-dlp plugins through
`YTDLP_NO_PLUGINS=1`, and enables explicit no-overwrite policies. When the
installed aria2c build advertises `--no-netrc`, the engine enables it to avoid
loading credentials from a personal `.netrc` file. Builds that omit this
optional capability are accepted and are not passed an unsupported option.
Interrupted
`.part` files may still be resumed, but an existing completed or post-processed
media file is preserved and the run fails instead of replacing it.

The output template limits the title and media identifier by encoded byte
length, reducing filename failures with long Unicode titles on filesystems that
limit one path component to 255 bytes.

## Downloader behavior

The engine configures aria2c for direct HTTP/FTP transfers and explicitly uses
yt-dlp's native downloader for DASH and HLS manifests:

```text
--downloader aria2c
--downloader dash,m3u8:native
```

This keeps segmented media handling inside yt-dlp while retaining aria2c's
multi-connection acceleration where it is appropriate.

For current YouTube extraction, the engine enables Deno. yt-dlp uses locally installed EJS components when available and may request the official EJS components from npm as a fallback:

```text
--js-runtimes deno
--remote-components ejs:npm
```

yt-dlp may download the yt-dlp-ejs challenge-solver components from npm when compatible local components are unavailable. Set `YTDLP_DISABLE_REMOTE_EJS=1` to prohibit that fallback. In strict mode, YouTube extraction fails rather than downloading remote components.

### Complete video

The engine selects the best video track and the best audio track, then merges
or remuxes them into an MKV container without re-encoding when the streams are
compatible.

### Authenticated YouTube HLS video

The graphical profile `YouTube video - Firefox cookies (HLS/MKV)` is an
explicit fallback for YouTube sessions that require sign-in and whose ordinary
HTTPS media URLs return HTTP 403. It adds:

```text
--cookies-from-browser firefox
--extractor-args youtube:player_client=web_safari
--format (bv*+ba/b)[protocol^=m3u8]
```

The profile is limited to video mode and YouTube URLs. It reads the local
Firefox cookie database through yt-dlp, but this application does not copy,
export, or store cookie values in `gui.conf`. Successful HLS downloads are
handled by yt-dlp's native fragmented-media downloader. yt-dlp first applies
its MPEG-TS-in-MP4 fixup,
then the wrapper performs a second stream-copy remux from the repaired MP4 to
MKV. Neither stage re-encodes the audio or video.

This is a compatibility fallback, not a replacement for PO Token provider
plugins. YouTube enforcement can change independently of this project.

### Native audio track

Audio mode uses:

```text
--format ba/b
--extract-audio
--audio-format best
--audio-quality 0
```

It prefers the best audio-only stream. When the website does not provide one,
it uses the best combined media file and extracts its audio. yt-dlp preserves
the source codec and container whenever possible, but may invoke FFmpeg to remux
or convert media when the source cannot be extracted directly.

## Local data

Graphical-interface configuration:

```text
~/.config/yt-dlp-aria2-downloader/gui.conf
```

Execution logs:

```text
~/.local/state/yt-dlp-aria2-downloader/download-*.log
```

The live worker log is created with mode `0600` inside the private runtime
temporary directory and is removed after success. Failed, canceled, interrupted,
or inconsistent runs publish only a sanitized diagnostic copy in the state
directory: URL-like values are replaced, only the last 8 MiB are retained, and
the resulting file remains mode `0600`. Retained diagnostic logs older than 15
days are removed automatically the next time the graphical interface starts.

A same-user, per-destination advisory lock is kept under
`$XDG_RUNTIME_DIR/yt-dlp-aria2-downloader` when that runtime directory is
absolute, private, and owned by the current user. Otherwise, the engine uses a
private `/tmp/yt-dlp-aria2-downloader-UID` fallback. Lock files contain no URL,
cookie, or media path, and the kernel releases the lock automatically when the
engine exits. Downloads to different destination directories may run
concurrently.

## Tests

See [TESTING.md](TESTING.md) for local validation, Fedora-specific checks, and
the GitHub Actions jobs.

## Uninstalling the launcher

```bash
./install-gui.sh uninstall
```

## Limitations and lawful use

- playlists are disabled;
- Firefox cookies are read only when the explicit authenticated YouTube HLS
  profile is selected;
- that HLS fallback is video-only and does not preserve a separate native
  YouTube audio track;
- the final audio format depends on the best stream supplied by the website;
- some websites may restrict or prohibit downloading;
- use this software only for content that you are authorized to download.

## License

This project is distributed under the MIT License. See [LICENSE](LICENSE).
