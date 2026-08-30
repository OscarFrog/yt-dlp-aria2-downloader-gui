# yt-dlp aria2 downloader

[![Shell validation](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[Version française](README.fr.md)

## Contents

- [Recommended installation](#recommended-installation)
- [Main features](#main-features)
- [Requirements](#requirements)
- [Release provenance and immutability](#release-provenance-and-immutability)
- [Package installation](#package-installation)
  - [Fedora 44](#fedora-44)
  - [Debian and Ubuntu](#debian-and-ubuntu)
  - [Packaged commands](#packaged-commands)
  - [Removing a package installation](#removing-a-package-installation)
- [Installation from a portable release archive](#installation-from-a-portable-release-archive)
- [Installation from Git](#installation-from-git)
- [Graphical usage](#graphical-usage)
- [Command-line usage](#command-line-usage)
- [Downloader behavior](#downloader-behavior)
- [Local data](#local-data)
- [Tests](#tests)
- [Uninstalling the launcher](#uninstalling-the-launcher)
- [Limitations and lawful use](#limitations-and-lawful-use)
- [License](#license)

A Zenity graphical interface and Bash download engine for GNU/Linux only. It downloads a
single URL using one of three profiles:

- a **complete MKV video**, using the best available video and audio streams;
- an explicit **authenticated YouTube HLS video** profile that reads Firefox
  cookies and remuxes the selected HLS stream into MKV;
- the **best available audio track**, preserving its source codec and
  container whenever yt-dlp can do so without re-encoding.

The project uses `yt-dlp` for media extraction, `aria2c` to accelerate eligible
direct downloads through a private aria2 input file, and FFmpeg to merge,
remux, or extract streams. HTTPS automatically stays on yt-dlp's native
transport when the installed aria2 TLS backend lacks the required certificate
validation hardening. DASH and HLS streams also remain native. The current
development version is **2.3.6**.
The latest published package release is **2.3.6**.

## Recommended installation

Open the [latest GitHub release](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest).
The exact asset names below match the currently published v2.3.6 release.

For **Fedora 44**, download these four assets:

```text
install-fedora.sh
RPM-GPG-KEY-OscarFrog
yt-dlp-aria2-downloader-gui-2.3.6-1.fc44.noarch.rpm
SHA256SUMS
```

Verify the downloaded files, then run the supported Fedora bootstrap:

```bash
sha256sum --ignore-missing --check SHA256SUMS
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.3.6-1.fc44.noarch.rpm
```

The bootstrap authenticates and enables RPM Fusion Free when needed, replaces
`ffmpeg-free` with the full RPM Fusion `ffmpeg`, installs the required Fedora packages, installs
the application RPM, validates the FFmpeg provider, and initializes the
per-user yt-dlp and Deno runtimes.

For **Debian or Ubuntu**, download the versioned DEB and `SHA256SUMS`, verify
it, then install it with `sudo apt install ./yt-dlp-aria2-downloader-gui_2.3.6-1_all.deb`.
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
- yt-dlp-native interrupted-download resumption when supported by the website;
- privacy-first cancellation for wrapper-managed direct HTTP(S) aria2
  transfers: private partial state is removed and a later run starts cleanly;
- automatic native HTTPS fallback for affected aria2/GnuTLS combinations;
- unified graphical progress for direct files, native HLS/DASH fragments,
  separate video/audio streams, and FFmpeg post-processing;
- cancellation of the complete process group through one shared GUI session;
- supervised yt-dlp and wrapper-managed FFmpeg commands, including bounded shutdown;
- FFprobe validation of both video and audio streams for complete-video results, and of an audio stream with no content-video stream for audio results, before success is published;
- one active writer per destination directory, preventing concurrent
  instances from sharing partial or post-processing files;
- private diagnostic logs retained only for problematic runs, with URL redaction and an 8 MiB retained-size cap;
- application-menu launcher;
- static, mock, and hermetic real-tool integration tests, including local
  direct AAC/Opus/combined-audio qualification, HLS/DASH routing, controlled
  aria2 Range/no-Range/redirect/error/cancel-clean-restart behavior, real FFmpeg progress,
  and race stress, with GitHub Actions validation on Ubuntu and Fedora 44.

## Requirements

System commands required by the application are:

- Bash **4.4 or newer**;
- `aria2c` **1.37.0 or newer**;
- Python **3.10 or newer**;
- FFmpeg and `ffprobe`;
- Zenity for the graphical interface;
- `ca-certificates`, `curl`, GnuPG, and `unzip` for verified managed-runtime
  bootstrap/update;
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
The runtime manager returns one versioned attestation containing the validated
paths and versions, so the engine does not repeat executable discovery and
capability probes during the same launch.

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

System packages such as Python, FFmpeg, aria2, and Zenity remain managed by the
distribution package manager; the Fedora bootstrap installs the newest
versions available from the enabled Fedora/RPM Fusion repositories at
installation time.

## Release provenance and immutability

GitHub **Immutable Releases** must be enabled in the repository settings before
pushing the release tag. The release workflow verifies the exact asset-name
inventory, compares a pre-existing release byte-for-byte on reruns, confirms
that the resulting release is immutable, and then verifies GitHub's release
attestation and each local asset. If a newly created release unexpectedly remains mutable, the workflow
attempts to remove it, verifies that the release has disappeared, and fails
explicitly if cleanup cannot be confirmed.

After downloading an artifact, users with GitHub CLI can additionally verify
both build provenance and immutable-release identity:

```bash
gh attestation verify ./ARTIFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify v2.3.6 -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset v2.3.6 ./ARTIFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
```

`SHA256SUMS` remains useful for offline/local integrity checks; the GitHub
attestation and immutable-release checks add provenance and release identity.

After publication, a separate read-only workflow job downloads the public
release again, reconstructs the expected payload from the exact Actions
artifacts that passed package qualification, compares every public asset
byte-for-byte, rechecks `SHA256SUMS`, and verifies release/asset attestations
against this repository, `release.yml`, and the exact release-tag commit.

### RPM signing identity, environment, and key rotation

Fedora release authorization is deliberately narrower than the host RPM trust
database. The consumer bootstrap validates the exact primary certificate
fingerprint `7B54065FE061E78ED2C96252E3BE996196ABEA7F`, requires exactly one usable
signing subkey, and pins that subkey to
`1F5B769CE48A08AAC0A7D9DDECC9894B41830245`. It then imports only that certificate
into a private RPM 6 filesystem (`fs`) keyring and verifies the RPM there, with
the RPM transaction lock redirected into the same private temporary root.
Consequently, a key already trusted by the host RPM database cannot authorize
the project RPM. The release signing job independently checks the same full
fingerprints, requests the exact signing subkey with `rpmsign --key-id`, and
cryptographically verifies the signed RPM before publication. RPM
`OPENPGP:pgpsig` output is diagnostic only: on Fedora 44 with RPM 6.0.2 it
reports a long Key ID rather than the complete OpenPGP fingerprint and is not
used as an authorization decision.

The production RPM package format is explicitly pinned to **RPM v4** and is
verified before and after release signing. CI separately builds a dedicated RPM
v6 fixture to qualify RPM 6 multi-signature semantics; this does not silently
migrate the production package format to v6.

The GitHub Environment named `rpm-signing` is an operational security boundary,
not merely a workflow label. Store `RPM_SIGNING_PRIVATE_KEY_B64` and
`RPM_SIGNING_PASSPHRASE` as **environment secrets**. The private-key bundle
must be produced with GnuPG `--export-secret-subkeys`: the primary private key
stays offline and imports only as a `sec#` stub, while the dedicated signing
subkey remains usable. Configure a required reviewer and disable administrator
bypass. For a repository intentionally operated by a **single maintainer**, the
sole reviewer may also be the workflow initiator, so `prevent_self_review`
remains disabled by design; the maintainer-side preflight requires an explicit
`--confirm-single-maintainer-self-review` acknowledgement and verifies that the
sole reviewer matches the authenticated GitHub account. Restrict the Environment
to a selected `v*` **tag** deployment policy. Manual recovery remains available,
but it must execute the workflow from the exact release tag:

```bash
gh workflow run release.yml \
  --ref v2.3.6 \
  -f tag=v2.3.6 \
  -R OscarFrog/yt-dlp-aria2-downloader-gui
```

The workflow independently rejects a manual run whose ref type, ref name, or
source commit does not match the requested release tag.

The current dedicated signing subkey expires on **2027-08-21**. Rotate it before
that date. For a normal subkey rotation under the same primary certificate,
publish the refreshed public certificate, update the pinned signing-subkey
fingerprint in source/workflow/tests, update the environment signing secret,
and require the complete negative/positive Fedora qualification before the next
tag. If the signing subkey is compromised, stop releases, revoke it, replace the
environment secret, publish the updated public certificate, and ship only after
the new fingerprint is pinned. If the primary certificate is compromised, a
new primary fingerprint is required; do not silently trust a replacement
primary key.

## Package installation

GitHub releases publish a Fedora RPM, a Debian/Ubuntu DEB, the portable ZIP,
the Fedora bootstrap, the RPM OpenPGP public signing key, and a single
`SHA256SUMS` file. RPM and DEB packages place
the commands, dedicated application icon, and desktop launcher system-wide; no
separate `install-gui.sh` command is required for a package installation.

When upgrading from a ZIP or Git installation, remove the old per-user launcher
first so it cannot override the packaged desktop entry:

```bash
./install-gui.sh uninstall
```

### Fedora 44

Use `install-fedora.sh` from the same GitHub release as the RPM. Do not install
the RPM directly on a fresh Fedora system, because RPM Fusion must be enabled
before DNF resolves the `ffmpeg` dependency.

Download:

```text
install-fedora.sh
RPM-GPG-KEY-OscarFrog
yt-dlp-aria2-downloader-gui-2.3.6-1.fc44.noarch.rpm
SHA256SUMS
```

Verify all downloaded release assets:

```bash
sha256sum --ignore-missing --check SHA256SUMS
```

Then run:

```bash
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.3.6-1.fc44.noarch.rpm
```

The bootstrap refuses an unsigned release RPM. It validates that
`RPM-GPG-KEY-OscarFrog` contains exactly one primary certificate with fingerprint
`7B54065FE061E78ED2C96252E3BE996196ABEA7F` and the dedicated signing subkey
`1F5B769CE48A08AAC0A7D9DDECC9894B41830245`. It then imports only that certificate
into a private temporary RPM 6 filesystem (`fs`) keyring and requires
`rpmkeys --checksig` to validate the package inside that isolated trust domain.
RPM display strings such as `OPENPGP:pgpsig` are diagnostic only and are not
used as authorization primitives. Before any system key import or package
transaction, the bootstrap copies the certificate and RPM through `sudo` into a
private root-owned staging directory. It repeats the exact package identity,
certificate fingerprints, and isolated signature verification against those
copies; the system key import and DNF then consume only the same protected
root-owned paths. Replacing the original user-owned files after staging cannot
change the authorized transaction. DNF independently repeats package
verification with `localpkg_gpgcheck=True`. A different key already trusted by
the host RPM database therefore cannot authorize this project RPM. The
`--allow-unsigned-dev` option exists only for explicit local/CI development
builds and is not used for releases.

On a fresh Fedora 44 system, the RPM Fusion bootstrap is held to the same
fail-closed model before DNF runs it as root. The installer downloads the key
and release RPM over constrained TLS, requires the exact RPM Fusion fingerprint
`E9A491A3DE247814E7E067EAE06F8ECDD651FF2E`, verifies the signature in an
isolated keyring, and requires the reviewed NEVRA
`rpmfusion-free-release-44-3.noarch`. Fedora releases without an explicit pin
are rejected until they have been qualified. The RPM Fusion certificate and
bootstrap RPM cross the same root-owned staging boundary and are revalidated
there before privileged import or installation.

The bootstrap performs these checks and actions:

- authenticates and enables RPM Fusion Free if it is absent;
- replaces Fedora `ffmpeg-free` with RPM Fusion `ffmpeg` when necessary;
- installs the required system dependencies, including aria2, Python 3.10+, Zenity, curl,
  GnuPG, and unzip;
- verifies the pinned OscarFrog RPM OpenPGP signing key and signature;
- enables DNF OpenPGP checking for the local release RPM;
- installs the application RPM;
- verifies that `ffmpeg` is supplied by RPM Fusion and that `ffmpeg-free` is
  absent;
- initializes and validates the managed yt-dlp stable and Deno stable
  runtimes for the current user.

The RPM itself does not download third-party runtimes from a package-manager
scriptlet. Runtime downloads happen in the unprivileged user context and are
verified before activation.

### Debian and Ubuntu

The latest published release, 2.3.6, provides an architecture-independent DEB
aligned with the same managed-runtime model as Fedora. Download:

```text
yt-dlp-aria2-downloader-gui_2.3.6-1_all.deb
SHA256SUMS
```

Verify and install it:

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.3.6-1_all.deb
```

The DEB explicitly depends on `aria2`, Python 3.10+, FFmpeg/FFprobe,
Zenity, CA certificates, curl, GnuPG, unzip, and the hicolor icon theme. GNU
coreutils, grep, findutils, sed, and util-linux are supplied by the
Debian/Ubuntu Essential base and are not redundantly declared as unversioned
package dependencies. The DEB
**does not depend on distribution yt-dlp or Deno packages**. yt-dlp and Deno
are installed and verified in the invoking user's runtime directory on first
use.

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

On Fedora, a **final RPM removal** continues to perform best-effort cleanup
of the managed per-user runtime and exact legacy
`yt-dlp-aria2-downloader-gui` XDG artifacts for users whose home directories
are available. RPM upgrades do not perform this cleanup.

On Debian/Ubuntu, `apt remove` and `apt purge` remove the system package payload
but deliberately preserve per-user managed runtimes, configuration, state, and
cache. This keeps reinstallations non-destructive and avoids package-manager
scripts traversing user home directories.

The Fedora cleanup is intentionally allowlisted. It removes the managed runtime
under `${XDG_DATA_HOME:-$HOME/.local/share}/yt-dlp-aria2-downloader/runtime/`
and known legacy `yt-dlp-aria2-downloader-gui` paths under the standard XDG
data, config, state, and cache locations. It does **not** recursively search the
home directory for similarly named files.

For RPM cleanup, from 2.1.27 onward, the runtime manager records the effective `XDG_DATA_HOME`
so a later package uninstall can also find a custom data directory. A custom
XDG location used only by an older release and never observed by 2.1.27 cannot
be reconstructed safely after the fact.

From 2.1.29 onward, a custom data root also receives a private ownership
sentinel binding the application ID, UID, HOME, and effective data root. Final
package removal follows a custom marker only when it is a single-line absolute
path and the matching regular `0600` sentinel is present and owned by the target
user. A modified marker alone can no longer authorize deletion in another XDG
root.
 Cleanup also refuses intermediate symbolic-link components below
the authorized XDG root, so an ambiguous parent path is preserved instead of
being traversed by recursive removal. After upgrading from 2.1.27/2.1.28, running the 2.1.29 runtime manager
creates the sentinel automatically. If 2.1.29 is removed before that migration
ever runs, the older custom root is conservatively preserved rather than
deleted.

The portable ZIP/Git launcher
`~/.local/share/yt-dlp-aria2-downloader/launch` is deliberately preserved when
present, because it can belong to an independent portable installation.

`install-gui.sh uninstall` remains the command for removing an older ZIP or Git
desktop installation from the current user's home directory.

## Installation from a portable release archive

Download these release assets:

```text
yt-dlp-aria2-downloader-gui-2.3.6.zip
SHA256SUMS
```

Verify and extract the archive:

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.3.6.zip
cd yt-dlp-aria2-downloader-gui-2.3.6
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
For containment, the portable installer requires a current-user-owned
`XDG_DATA_HOME` that is not writable by group or other users, and refuses a
root or parent component that is a symbolic link. The data path must be valid
UTF-8 and safely representable in a desktop `Exec` key. It keeps no-follow
directory descriptors open for the complete transaction, so a concurrent
pathname replacement cannot redirect installation, removal, or stale-file
cleanup.
Concurrent portable install/remove requests are serialized. After a failed
multi-file update, the helper attempts to restore the preceding launcher state
before reporting the primary error and any rollback failure. The executable GUI
target is revalidated before success. HUP, INT, and TERM also trigger this
transaction cleanup before the command returns status 129, 130, or 143.

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

The GUI writes the requested URL to a private temporary file and passes only
that file path to the engine. The engine then supplies yt-dlp through its private
batch-file interface. For direct HTTP(S) media, validated URLs and headers are
written to a private `0600` aria2 input file, so the media URL is not present in
`aria2c` argv. URLs containing `user:password@host` are rejected. Direct CLI use
with a positional URL remains supported; as with any command-line program, that
positional URL can be visible in the invoking process arguments.

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
yt-dlp-native `.part` files may still be resumed when supported upstream.
Wrapper-managed direct HTTP(S) aria2 staging is deliberately ephemeral: a user
cancellation removes its private partial/control state and a later run starts
the direct transfer cleanly. An existing completed or post-processed media file
is preserved and the run fails instead of replacing it.

The output template limits the title and media identifier by encoded byte
length, reducing filename failures with long Unicode titles on filesystems that
limit one path component to 255 bytes.

## Downloader behavior

The engine first asks yt-dlp to plan the selected formats without downloading
them. Replay-safe and representable direct HTTP(S) plans are transferred by
aria2c through private input, manifest, cookie, and staging files. Plans whose
media URL contains URI userinfo, or whose headers require non-replay-safe context
such as Referer, Cookie, Authorization, proxy authorization, or another
non-allowlisted header, remain on yt-dlp's native transport. FTP and other
non-HTTP(S) protocols
also remain native. DASH and HLS are explicitly kept native:

```text
--downloader dash,m3u8:native
aria2c --input-file=/private/aria2.input --dir=/private/staging ...
```

This keeps segmented media handling inside yt-dlp while retaining aria2c's
multi-connection acceleration for validated direct HTTP(S) media without
putting the media URL in aria2c process arguments.

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

With yt-dlp's current upstream behavior, `web_safari` HLS formats do not require
a GVS PO Token, but since 2026.07 YouTube returns those HLS formats only for some
logged-in or "trusted" sessions. This is upstream behavior and may change
independently of this project.

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

See the repository's
[testing guide](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md)
for local validation, Fedora-specific checks, and the GitHub Actions jobs.

## Uninstalling a portable launcher

For a launcher installed from a portable ZIP or Git checkout, run this command
from that source directory:

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

This project is distributed under the MIT License. See the repository
[license](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/LICENSE).
