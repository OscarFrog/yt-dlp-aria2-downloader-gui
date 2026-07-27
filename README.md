# yt-dlp aria2 downloader

[![Shell validation](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[Version française](README.fr.md)

A Zenity graphical interface and Bash download engine for Linux. It downloads a
single URL in one of two forms:

- a **complete MKV video**, using the best available video and audio streams;
- the **best audio track in its native format**, without forcing MP3, M4A, or
  Opus conversion.

The project uses `yt-dlp` for media extraction, `aria2c` to accelerate direct
HTTP/FTP downloads, and FFmpeg to merge, remux, or extract streams. DASH and HLS
streams deliberately remain on yt-dlp's native downloader. The current version
is **2.1.6**.

## Main features

- simple Zenity graphical interface;
- download engine that can also be used from a terminal;
- one URL per run, with accidental playlist downloads disabled;
- destination-folder selection and preference persistence;
- MKV video download without re-encoding when the streams are compatible;
- extraction of the best audio track in the source format;
- interrupted-download resumption when supported by the website;
- graphical progress display and cancellation of the complete process group;
- private log file for every run;
- application-menu launcher;
- static tests, integration tests, and GitHub Actions validation on Ubuntu and
  Fedora 44.

## Requirements

The following commands must be installed and available in `PATH`:

- Bash;
- `yt-dlp` **2026.06.09 or newer**;
- `aria2c` **1.37.0 or newer**;
- FFmpeg and `ffprobe`;
- Deno **2.3.0 or newer**;
- Zenity for the graphical interface;
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
yt-dlp-aria2-downloader-gui-2.1.6.zip
SHA256SUMS
```

Verify and extract the archive:

```bash
sha256sum --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.6.zip
cd yt-dlp-aria2-downloader-gui-2.1.6
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

The launcher stores the repository's absolute path. After moving the project
directory, run `./install-gui.sh install` again.

## Graphical usage

Start **yt-dlp aria2 downloader** from the application menu, or run:

```bash
./download-video-gui.sh
```

The interface requests, in order:

1. the video URL;
2. **Complete video (MKV)** or **Audio track (native format)**;
3. the destination folder.

Leading and trailing whitespace accidentally copied with the URL is removed by
the graphical interface.

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

Display help or version information:

```bash
./download-video.sh --help
./download-video.sh --version
```

Always quote URLs with single or double quotation marks because they may
contain shell metacharacters such as `&`.

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

This means a YouTube download can contact npm in addition to the media website.

### Complete video

The engine selects the best video track and the best audio track, then merges
or remuxes them into an MKV container without re-encoding when the streams are
compatible.

### Native audio track

Audio mode uses:

```text
--format ba/b
--extract-audio
--audio-format best
--audio-quality 0
```

It prefers the best audio-only stream. When the website does not provide one,
it uses the best combined media file and extracts its audio. The result may be
WebM/Opus, M4A/AAC, or another format supplied by the source.

## Local data

Graphical-interface configuration:

```text
~/.config/yt-dlp-aria2-downloader/gui.conf
```

Execution logs:

```text
~/.local/state/yt-dlp-aria2-downloader/download-*.log
```

Logs are private and are intentionally retained until the user removes them.

## Tests

See [TESTING.md](TESTING.md) for local validation, Fedora-specific checks, and
the GitHub Actions jobs.

## Uninstalling the launcher

```bash
./install-gui.sh uninstall
```

## Limitations and lawful use

- playlists are disabled;
- the graphical interface does not manage cookies or authentication;
- the final audio format depends on the best stream supplied by the website;
- some websites may restrict or prohibit downloading;
- use this software only for content that you are authorized to download.

## License

This project is distributed under the MIT License. See [LICENSE](LICENSE).
