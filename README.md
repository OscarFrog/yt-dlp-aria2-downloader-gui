# yt-dlp aria2 downloader

[![Shell validation](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[Version française](README.fr.md)

Download a video or its audio track on **GNU/Linux**, through a small Zenity
interface or the terminal. Paste a URL, choose your tracks and destination,
then follow the download and processing progress.

- **Video:** best available video and audio, combined into MKV.
- **Audio:** best available audio track, preserving its source format when possible.
- **Languages:** independent audio and subtitle choices on compatible sites.
- **Everyday use:** remembered preferences, cancellation and concurrent independent downloads.

The current development version is **2.4.4**.
The latest published package release is **2.4.4**.

## Contents

[Screenshots](#screenshots) · [Installation](#recommended-installation) ·
[Quick start](#quick-start) · [Audio and subtitles](#audio-and-subtitles) ·
[Terminal](#command-line-usage) · [Troubleshooting](#essential-troubleshooting) ·
[More documentation](#more-documentation)

## Screenshots

Real Zenity dialogs with demonstration data. The interface labels are in
English; window appearance varies with the desktop theme. The progress shown
is a demonstration, not a download benchmark.

| Paste a URL | Follow progress |
| --- | --- |
| ![URL entry dialog ready for a video address](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-url.png) | ![Download progress dialog with a Cancel button](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-progress.png) |

| Select audio tracks | Select subtitles |
| --- | --- |
| ![Audio tracks checklist with selectable languages and a Continue button](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-audio.png) | ![Subtitles checklist including No subtitles](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-subtitles.png) |

## Recommended installation

Use the [latest GitHub release](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest).
The filenames below match the currently published v2.4.4 release.
Download the files for your platform into the same folder, then open a terminal there.

| Platform | Application download |
| --- | --- |
| Fedora 44 | [RPM](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest/download/yt-dlp-aria2-downloader-gui-2.4.4-1.fc44.noarch.rpm) |
| Debian / Ubuntu | [DEB](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest/download/yt-dlp-aria2-downloader-gui_2.4.4-1_all.deb) |
| Other GNU/Linux / portable use | [ZIP](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest/download/yt-dlp-aria2-downloader-gui-2.4.4.zip) |

### Fedora 44

Download these four assets from that release:

```text
install-fedora.sh
RPM-GPG-KEY-OscarFrog
yt-dlp-aria2-downloader-gui-2.4.4-1.fc44.noarch.rpm
SHA256SUMS
```

```bash
sha256sum --ignore-missing --check SHA256SUMS
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.4.4-1.fc44.noarch.rpm
```

Use the bootstrap rather than installing the RPM directly on a fresh Fedora
system. It verifies the signatures, enables RPM Fusion Free when needed,
replaces `ffmpeg-free` with the full `ffmpeg`, installs dependencies and prepares
the verified per-user yt-dlp and Deno runtimes.

### Debian and Ubuntu

The latest published release, 2.4.4, provides the DEB. Download:

```text
yt-dlp-aria2-downloader-gui_2.4.4-1_all.deb
SHA256SUMS
```

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.4.4-1_all.deb
```

The package installs system dependencies. Verified yt-dlp and Deno runtimes are
prepared for your user on first use; distribution packages for those two tools
are not required.

For RPM and DEB installations, the launcher and icon are installed automatically in the desktop application menu.
**Do not run `install-gui.sh` after installing a package.**
When replacing a ZIP/Git installation, first remove its old launcher from that
source directory with `./install-gui.sh uninstall`.

### Portable ZIP or Git checkout

<details>
<summary>Install from the release ZIP</summary>

Install the [system requirements](#requirements) first. Download:

```text
yt-dlp-aria2-downloader-gui-2.4.4.zip
SHA256SUMS
```

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.4.4.zip
cd yt-dlp-aria2-downloader-gui-2.4.4
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

</details>

<details>
<summary>Install from Git</summary>

Install the [system requirements](#requirements) first, then run:

```bash
git clone https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui.git
cd yt-dlp-aria2-downloader-gui
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

</details>

For ZIP/Git, keep the source directory: the launcher points to it. Run
`./install-gui.sh install` again after moving it.

### Requirements

GNU/Linux on `x86_64` or `aarch64` for the managed runtimes, with:

- Bash **4.4 or newer**, Python **3.10 or newer**, aria2 **1.37.0 or newer**;
- FFmpeg and `ffprobe`, Zenity, CA certificates, curl, GnuPG and unzip;
- GNU coreutils/grep, findutils and util-linux (`setsid`, `flock`);
- usable Linux pidfds, WNOWAIT and readable procfs process/thread information.

Firefox with a logged-in YouTube session is needed only for the explicit
YouTube HLS/Firefox profile. The package installers handle system dependencies;
ZIP/Git users install them through their distribution.

<details>
<summary>Additional release verification with GitHub CLI</summary>

Replace `ARTIFACT` with the downloaded file's name:

```bash
gh attestation verify ./ARTIFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify v2.4.4 -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset v2.4.4 ./ARTIFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
```

Checksums check file integrity; these commands also check provenance and the
immutable release identity. See [release security](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#ci-and-release-trust-zones).

</details>

## Quick start

Open **yt-dlp aria2 downloader** from the application menu, or run the packaged command:

```bash
yt-dlp-aria2-downloader-gui
```

From a ZIP or Git directory instead:

```bash
./download-video-gui.sh
```

1. Paste one video URL. Playlists are disabled.
2. Choose **Complete video (MKV)** or **Audio track (native format)**.
   For YouTube URLs, the video choice is **YouTube video - Firefox cookies (HLS/MKV)**.
3. Choose a destination folder, then audio/subtitle tracks when offered.
4. Follow progress; **Cancel** stops the session. After success, use
   **Open folder**, **New download** or **Close**.

### Authenticated YouTube HLS video

This video-only profile reads your local Firefox session and uses
`youtube:player_client=web_safari` to request HLS, then remuxes to MKV without
re-encoding. It does not store cookies in `gui.conf`. Availability depends on
your session and YouTube; this fallback is not a guarantee of access or a
replacement for PO Token provider plugins. The CLI still accepts ordinary
`--mode video` for YouTube.

## Audio and subtitles

On compatible sites, **Complete video (MKV)** analyses available tracks.
Two checklists follow: **Audio tracks**, then **Subtitles**.
Each window has only **Cancel** and **Continue**; continuing from subtitles starts the download.

- Audio starts with a reliably identified original version. If the original
  version is unknown, it falls back to French, then the site's default or another
  ordinary track, with an explanation. You can select several tracks.
- Subtitles follow the selected default audio: none for French audio; otherwise
  full French subtitles when uniquely available for a reliably identified language.
  You can change this choice.
- **No subtitles**, or leaving all subtitle rows unchecked, produces no subtitle
  tracks. Choose that option or specific tracks. Checking both is a conflict:
  correct the selection before downloading.
- **Full** translates dialogue; **Forced** covers selected passages and does not
  replace a full translation. Tracks remain switchable in your media player.

Lists contain distinct admissible tracks after filtering and deduplication.
Subtitles for deaf or hard-of-hearing viewers and explicitly identified comfort audio are excluded. Audio description remains available. Availability depends
on the programme, territory and rights.

The MKV contains exactly the chosen tracks, without re-encoding video or audio.
Subtitles use UTF-8 SRT with text, line breaks and timing preserved.
Source positioning is not retained; appearance depends on your player.
Unsupported formatting/timing or missing tracks causes an explicit error.

## Command-line usage

The examples below run from a ZIP/Git directory. For an RPM/DEB installation,
replace `./download-video.sh` with `yt-dlp-aria2-downloader`.
Replace the example address with your URL and keep it quoted.

Complete video:

```bash
./download-video.sh \
  --mode video \
  --output-dir "${HOME}/Videos" \
  'https://example.com/video'
```

Native audio:

```bash
./download-video.sh \
  --mode audio \
  --output-dir "${HOME}/Music" \
  'https://example.com/video'
```

For compatible video sources, add `--tracks-auto` for automatic choices,
`--all-tracks` for all admissible tracks, or `--no-subtitles` to omit subtitles.
The last option also works with either of the first two. The exclusions above apply.

YouTube HLS with Firefox cookies:

```bash
./download-video.sh \
  --mode video \
  --youtube-hls-firefox \
  --output-dir "${HOME}/Videos" \
  'https://www.youtube.com/watch?v=VIDEO_ID'
```

Help and version:

```bash
./download-video.sh --help
./download-video.sh --version
```

For packaged help:

```bash
yt-dlp-aria2-downloader --help
```

A positional URL can appear in process arguments. Use the GUI or `--url-file FILE`
with a private, user-owned file when that matters. URLs containing
`user:password@host` are rejected. Personal yt-dlp configuration and plugins are disabled.

## Files, cancellation and privacy

- Independent downloads may share a destination. Overlapping requests are
  refused while reserved; existing results are not silently renamed or adopted.
  Local processing has a late-collision window with unrelated external writers;
  it is not an atomic no-overwrite guarantee. Network/private-workspace publication
  refuses late collisions. [Details](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#shared-destination-reservations).
- Native interrupted downloads can resume only when the site and saved ownership
  checks permit it. Cancelled wrapper-managed aria2 transfers and isolated network
  sessions discard partial state after confirmed shutdown; the next run starts afresh.
- Network shares may need a private **local disk workspace**, with space for streams
  and merged/remuxed media as well as destination space. Unsupported storage is refused.
  If copying fails or its outcome is uncertain, inspect the reported retained source
  and destination before retrying. Do not remove uncertain temporary files or locks.
- Verified per-user runtimes update by default. A failed update check keeps the last
  verified runtime. [Runtime controls and recovery](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#managed-runtimes-and-persistent-state).

Default locations (XDG overrides are supported):

| Data | Location |
| --- | --- |
| Preferences | `~/.config/yt-dlp-aria2-downloader/gui.conf` |
| yt-dlp / Deno | `~/.local/share/yt-dlp-aria2-downloader/runtime/` |
| Problem-run logs | `~/.local/state/yt-dlp-aria2-downloader/download-*.log` |

Successful-run logs are normally removed. Retained logs are private, URL-redacted,
limited to 8 MiB and removed after 15 days when a new GUI session is prepared.
Titles and local paths can still be personal: review logs before sharing them.
Never share cookies, headers or private transfer plans. Do not recursively delete
old temporary directories just because their names look familiar.

## Essential troubleshooting

Use **View log** when an error dialog offers it; otherwise follow its message.
Include the application version and diagnostic identifier when reporting a problem.

| Problem | First check |
| --- | --- |
| Missing dependency | System requirements and the reported tool version; on Fedora use the bootstrap with full RPM Fusion FFmpeg. |
| YouTube HLS unavailable | Firefox login, the selected profile and current availability for that session. |
| `ENOSPC` / `EDQUOT` | Free space and quota on both the local workspace and destination. |
| Access or mount error | Permissions, mount availability and credentials; keep private workspace permissions private. |
| Existing file or reserved media | Preserve the file; wait for the other download to stop. Never delete locks to bypass a refusal. |
| Validation or uncertain copy | Read the specific diagnostic and inspect preserved media before starting again. |

For storage recovery, cancellation limits and diagnostic interpretation, see
[engine details](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#engine-pipeline)
and [network qualification limits](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#network-destination-regression-and-opt-in-cifs-qualification).

<details>
<summary>Runtime recovery and update controls</summary>

Set `YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0` to require already verified runtimes
during downloads, without network access for their installation or update.
Media downloads remain available. The default yt-dlp channel is stable;
`YTDLP_ARIA2_YTDLP_CHANNEL=nightly` explicitly opts into nightly builds.

From a ZIP/Git directory, explicitly download and prepare missing runtimes with:

```bash
./runtime-manager.sh ensure
```

If a verified previous version is available, roll back the affected component:

```bash
./runtime-manager.sh rollback yt-dlp
./runtime-manager.sh rollback deno
```

</details>

## Uninstall

Fedora:

```bash
sudo dnf remove yt-dlp-aria2-downloader-gui
```

Debian/Ubuntu:

```bash
sudo apt remove yt-dlp-aria2-downloader-gui
```

Final RPM removal attempts cleanup of verified managed runtimes and known legacy
user artifacts; upgrades preserve them. DEB removal/purge preserves per-user data.
Portable launcher links are preserved by package cleanup.

For a launcher installed from a portable ZIP or Git checkout, run from its source directory:

```bash
./install-gui.sh uninstall
```

## More documentation

- [Architecture and safety boundaries](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md)
- [Tests and qualification](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md)
- [Version coherence and release preparation](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#version-coherence-and-release-preparation)
- [Codex setup and task routing](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#codex-session-setup-and-task-routing)
- [Change history](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/CHANGELOG.md)

<details>
<summary>Maintainers: manual release recovery</summary>

Ordinary commits and PR merges need no version bump. Release preparation and
publication are separate, explicitly authorized operations. Only after the signed
tag exists and the [release preflight](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#release-maintainer-preflight)
has passed, manual recovery uses the exact tag:

```bash
gh workflow run release.yml \
  --ref v2.4.4 \
  -f tag=v2.4.4 \
  -R OscarFrog/yt-dlp-aria2-downloader-gui
```

A published tag and its assets must never be reused for different contents.

</details>

Use this software only for content you are authorized to download. Website
restrictions and upstream availability can change. Distributed under the
[MIT License](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/LICENSE).
