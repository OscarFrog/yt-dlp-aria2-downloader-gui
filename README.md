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
is **2.1.17**.

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
- FFprobe validation of the expected audio or video stream before success is published;
- one active writer per destination directory, preventing concurrent
  instances from sharing partial or post-processing files;
- private diagnostic logs retained only for problematic runs;
- application-menu launcher;
- static tests, integration tests, and GitHub Actions validation on Ubuntu and
  Fedora 44.

## Requirements

The following commands must be installed and available in `PATH`:

- Bash **4.4 or newer**;
- `yt-dlp` **2026.06.09 or newer**;
- `aria2c` **1.37.0 or newer**;
- FFmpeg and `ffprobe`;
- Deno **2.3.0 or newer**;
- Zenity for the graphical interface;
- Firefox with an authenticated YouTube session only when using the optional
  authenticated YouTube HLS profile;
- GNU coreutils, GNU grep, and `setsid`, which is usually provided by
  `util-linux`.

The engine checks the minimum versions of `yt-dlp`, `aria2c`, and Deno before
starting a download.

## Installation on Fedora 44

The full `ffmpeg` package is provided by the RPM Fusion Free repository. Enable
that repository first when it is not already configured:

```bash
sudo dnf install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
```

Then install the required Fedora packages:

```bash
sudo dnf install yt-dlp aria2 ffmpeg zenity
```

Install Deno when it is not already available:

```bash
curl -fsSL https://deno.land/install.sh | sh
```

Open a new terminal, then verify the dependencies:

```bash
yt-dlp --version
aria2c --version
ffmpeg -version
ffprobe -version
deno --version
zenity --version
setsid --version
```

## Installation from a release archive

Download both release assets from the GitHub release page:

```text
yt-dlp-aria2-downloader-gui-2.1.17.zip
SHA256SUMS
```

Verify and extract the archive:

```bash
sha256sum --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.17.zip
cd yt-dlp-aria2-downloader-gui-2.1.17
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

Start **yt-dlp aria2 downloader** from the application menu, or run:

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

The progress dialog displays the current download or post-processing stage. Use
the cancel button to stop the complete download process.


### 5. Download result

After a successful download, the interface displays the path of the completed
media file.


When the download fails, the interface displays an error dialog and preserves
the diagnostic log.


The retained log can be opened from the error dialog. It contains the details
needed to diagnose the failure and may include the requested URL.


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

For current YouTube extraction, the engine also enables Deno and requests the
EJS components from npm when yt-dlp needs them:

```text
--js-runtimes deno
--remote-components ejs:npm
```

yt-dlp may download the yt-dlp-ejs challenge-solver components from npm.
Those scripts are executed by Deno with restricted file-system and network
permissions. A YouTube download can therefore contact npm in addition to the
media website.

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

Logs are private. A log is deleted automatically after the final media file
is confirmed. Failed, canceled, interrupted, or inconsistent runs retain their
logs for troubleshooting. Retained diagnostic logs older than 15 days are
removed automatically the next time the graphical interface starts.

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
