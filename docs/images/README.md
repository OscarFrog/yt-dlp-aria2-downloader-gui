# README screenshots

These four images show the native Zenity interface from application version
2.4.4, captured on 31 October 2026 from source commit
`c848baa84a8ab9be7182a9e638494ba557499d09`.
They illustrate the interface; they are not evidence of a real-media download
or a complete graphical qualification.

| File | Native dimensions | What is shown |
| --- | --- | --- |
| `readme-url.png` | 700 × 155 | The real empty URL-entry dialog. |
| `readme-audio.png` | 800 × 520 | The real audio checklist with a synthetic catalogue. |
| `readme-subtitles.png` | 820 × 520 | The real subtitle checklist after Continue in the audio window. |
| `readme-progress.png` | 710 × 126 | The real progress-window arguments and formatter, with simulated progress. |

The English labels come from the application. Both READMEs use these same
images with translated alternative text and captions. Desktop theme and font
settings can change the appearance of a user's windows.

## Capture method

- Real Zenity 4.2.2 on an isolated Xwayland 24.1.14 display, with the Adwaita
  theme, Cairo renderer and `C.UTF-8` locale.
- The existing session/display adapter in `tests/zenity-x11-events.py` provides
  a private display and a service-free D-Bus session. HOME and all XDG locations
  are separate private temporary directories; no personal desktop is captured.
- The URL and track windows use the unchanged dialog functions from
  `download-video-gui.sh`, loaded without its final entry-point call.
- Track data comes from the synthetic `raw_fixture()` catalogue in
  `tests/art-tracks-integration.py`. The real Continue button advances from
  audio to subtitles. No remote metadata or media is downloaded.
- The progress window uses the application's Zenity options. Its message comes
  from `format_download_message` in `progress-monitor.sh`, supplied with the
  demonstration values: item 1/2, 62%, 4.2 MiB/s, 00:18 remaining.
- Only the owned dialog window is captured. The adapter's PPM capture is
  converted losslessly to PNG with ImageMagick; no retouching or layout changes
  are applied. Temporary dialogs and display processes are then stopped.

For refreshed screenshots, repeat this isolated scenario against the intended
source revision and visually compare the result with the current interface.
Do not capture real URLs, cookies, account names, media titles or personal paths.
The complete graphical validation procedure remains in
[TESTING.md](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#autonomous-route).

## Storage and references

These are source documentation assets, not installed RPM/DEB payloads. The
READMEs use absolute raw GitHub URLs on the permanent `main` branch, so they
also work from installed documentation after squash and source-branch deletion.
Keep these four paths stable when refreshing captures: installed README copies
display the current images from `main`. Update capture provenance and both
languages' descriptions when the images change.

Before merge, validate the image targets in the qualified candidate tree.
After merge and branch deletion, check their public URLs, returned bytes and
rendering from GitHub and local README copies.

`test-static.sh` checks the four expected PNG paths, nonempty alternative text,
the exact absolute URLs on `main`, PNG headers and dimensions. Each image must
be at most 512 KiB and 2560 pixels on either side. This set totals about 75 KiB.
Visual review remains necessary: these mechanical checks do not establish that
a screenshot is faithful to the interface.
