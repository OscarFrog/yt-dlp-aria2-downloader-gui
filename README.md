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
is **2.1.25**.

## Recommended installation

Open the [latest GitHub release](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest).

For **Fedora 44 or newer**, download these three assets:

```text
install-fedora.sh
yt-dlp-aria2-downloader-gui-2.1.25-1.fc44.noarch.rpm
SHA256SUMS
```

Verify the downloaded files, then run the supported Fedora bootstrap:

```bash
sha256sum --ignore-missing --check SHA256SUMS
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.1.25-1.fc44.noarch.rpm
```

The bootstrap enables RPM Fusion Free when needed, replaces `ffmpeg-free` with
the full RPM Fusion `ffmpeg`, installs the required Fedora packages, installs
the application RPM, validates the FFmpeg provider, and initializes the
per-user yt-dlp and Deno runtimes.

For **Debian or Ubuntu**, download the versioned DEB and `SHA256SUMS`, verify
it, then install it with `sudo apt install ./yt-dlp-aria2-downloader-gui_2.1.25-1_all.deb`.
For **other GNU/Linux distributions or portable use**, use the versioned ZIP or
a Git checkout. The managed yt-dlp and Deno runtimes currently support Linux
`x86_64` and `aarch64`.

For an RPM installation, the graphical launcher and application icon are installed automatically in the desktop application menu. **Do not run `install-gui.sh` after installing a package.** That helper is only for ZIP and Git installations.
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
- static tests, integration tests, and GitHub Actions validation on Ubuntu
  and Fedora 44.

## Requirements

System commands required by the application are:

- Bash **4.4 or newer**;
- `aria2c` **1.37.0 or newer**;
- FFmpeg and `ffprobe`;
- Zenity for the graphical interface;
- `curl`, GnuPG, and `unzip` for managed runtime bootstrap/update;
- GNU coreutils, GNU grep, `find`, and `setsid`/`flock`, normally provided by
  Fedora's core system packages and `util-linux`;
- Firefox with an authenticated YouTube session only when using the optional
  authenticated YouTube HLS profile.

`yt-dlp` and Deno are **not required as system packages**. The application
maintains verified per-user runtimes under
`~/.local/share/yt-dlp-aria2-downloader/runtime/`.

By default, engine launches check the signed yt-dlp **stable** release channel
and the Deno stable channel. A new runtime is staged separately, validated, and
activated atomically. Network operations and lock waits are bounded; if an
update check fails, the last verified runtime remains active. yt-dlp's official
Linux executable carries its compatible bundled Python dependencies, including
`curl_cffi` and the bundled EJS support used by current YouTube extraction.

Set `YTDLP_ARIA2_YTDLP_CHANNEL=nightly` to opt in to yt-dlp nightly builds.
Set `YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0` for a **strict zero-network mode**:
only already-installed runtimes are validated, and a missing or invalid runtime
causes a clear failure without invoking `curl`. Use `runtime-manager.sh ensure`
when bootstrap-without-update is explicitly desired. `runtime-manager.sh rollback
yt-dlp` and `runtime-manager.sh rollback deno` activate a validated previous
runtime when one is available.

The runtime manager first resolves the exact release tag and then downloads all
assets from that immutable coordinate, avoiding a `latest`-moving-between-files
race. The yt-dlp runtime is authenticated with the upstream signed SHA-256
manifest. Deno archives are checked against the SHA-256 checksum published
alongside the same exact official release before extraction and validation.
Candidate runtime executions are also time-bounded. Individual network calls
are bounded; a complete bootstrap contains several sequential calls, so their
limits are not a single global wall-clock deadline.

System packages such as FFmpeg, aria2, and Zenity remain managed by the
distribution package manager; the Fedora bootstrap installs the newest
versions available from the enabled Fedora/RPM Fusion repositories at
installation time.

## Release provenance and immutability

GitHub **Immutable Releases** must be enabled in the repository settings before
pushing the release tag. The release workflow verifies the exact asset-name
inventory, compares a pre-existing release byte-for-byte on reruns, confirms
that the resulting release is immutable, and then verifies GitHub's release
attestation and each local asset. A newly created mutable release is removed and
the workflow fails instead of being accepted.

After downloading an artifact, users with GitHub CLI can additionally verify
both build provenance and immutable-release identity:

```bash
gh attestation verify ./ARTIFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify v2.1.25 -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset v2.1.25 ./ARTIFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
```

`SHA256SUMS` remains useful for offline/local integrity checks; the GitHub
attestation and immutable-release checks add provenance and release identity.

## Package installation

GitHub releases publish a Fedora RPM, a Debian/Ubuntu DEB, the portable ZIP,
the Fedora bootstrap, and a single `SHA256SUMS` file. RPM and DEB packages place
the commands, dedicated application icon, and desktop launcher system-wide; no
separate `install-gui.sh` command is required for a package installation.

When upgrading from a ZIP or Git installation, remove the old per-user launcher
first so it cannot override the packaged desktop entry:

```bash
./install-gui.sh uninstall
```

### Fedora 44 and newer

Use `install-fedora.sh` from the same GitHub release as the RPM. Do not install
the RPM directly on a fresh Fedora system, because RPM Fusion must be enabled
before DNF resolves the `ffmpeg` dependency.

Download:

```text
install-fedora.sh
yt-dlp-aria2-downloader-gui-2.1.25-1.fc44.noarch.rpm
SHA256SUMS
```

Verify all downloaded release assets:

```bash
sha256sum --ignore-missing --check SHA256SUMS
```

Then run:

```bash
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.1.25-1.fc44.noarch.rpm
```

The bootstrap performs these checks and actions:

- enables RPM Fusion Free if it is absent;
- replaces Fedora `ffmpeg-free` with RPM Fusion `ffmpeg` when necessary;
- installs the required system dependencies, including aria2, Zenity, curl,
  GnuPG, and unzip;
- installs the application RPM;
- verifies that `ffmpeg` is supplied by RPM Fusion and that `ffmpeg-free` is
  absent;
- initializes and validates the managed yt-dlp stable and Deno stable
  runtimes for the current user.

The RPM itself does not download third-party runtimes from a package-manager
scriptlet. Runtime downloads happen in the unprivileged user context and are
verified before activation.

### Debian and Ubuntu

Release 2.1.25 publishes an architecture-independent DEB aligned with the same
managed-runtime model as Fedora. Download:

```text
yt-dlp-aria2-downloader-gui_2.1.25-1_all.deb
SHA256SUMS
```

Verify and install it:

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.1.25-1_all.deb
```

The DEB depends on the normal system tools (`aria2c`, FFmpeg/FFprobe, Zenity,
curl, GnuPG, unzip, coreutils, grep, findutils, and util-linux), but **does not
depend on distribution yt-dlp or Deno packages**. yt-dlp and Deno are installed
and verified in the invoking user's runtime directory on first use.

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

Debian/Ubuntu:

```bash
sudo apt remove yt-dlp-aria2-downloader-gui
```

The package manager removes the system commands, desktop launcher, and
application icon. Per-user managed runtimes are deliberately not package-owned
and remain under `~/.local/share/yt-dlp-aria2-downloader/runtime/`. After the
application is removed, they can optionally be purged with:

```bash
rm -rf -- ~/.local/share/yt-dlp-aria2-downloader/runtime/
```

`install-gui.sh uninstall` is only needed to clean up an older ZIP or Git
installation created in the current user's home directory.

## Installation from a portable release archive

Download these release assets:

```text
yt-dlp-aria2-downloader-gui-2.1.25.zip
SHA256SUMS
```

Verify and extract the archive:

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.25.zip
cd yt-dlp-aria2-downloader-gui-2.1.25
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
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
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
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

For current YouTube extraction, the engine uses the managed Deno runtime through
an explicit path:

```text
--js-runtimes deno:/absolute/path/to/managed/deno
```

The managed official yt-dlp Linux executable includes the compatible EJS
components used by the release. The wrapper therefore does **not** request
`--remote-components ejs:npm` during downloads. yt-dlp and its bundled
dependencies are updated together as one verified runtime, avoiding an
independently updated EJS/Python dependency set.

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

Managed yt-dlp and Deno runtimes:

```text
~/.local/share/yt-dlp-aria2-downloader/runtime/
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
