# README screenshots

These six images show the native Zenity interface from application version
2.4.4, captured on 31 October 2026. The URL, audio, subtitle and progress
captures use source commit `c848baa84a8ab9be7182a9e638494ba557499d09`;
the folder and error-log captures use `e1273bdbe812a50602e443ced69aa991f4c3c6c4`.
They illustrate the interface; they are not evidence of a real-media download
or a complete graphical qualification.

| File | Native dimensions | What is shown |
| --- | --- | --- |
| `readme-url.png` | 700 × 155 | The real empty URL-entry dialog. |
| `readme-audio.png` | 800 × 520 | The real audio checklist with a synthetic catalogue. |
| `readme-subtitles.png` | 820 × 520 | The real subtitle checklist after Continue in the audio window. |
| `readme-progress.png` | 710 × 126 | The real progress-window arguments and formatter, with simulated progress. |
| `readme-folder.png` | 813 × 326 | The real destination chooser with private example Audio/Videos folders; Videos is selected. |
| `readme-error-log.png` | 950 × 650 | The real diagnostic viewer after View log, with a sanitized simulated disk-space error. |

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
- The destination chooser uses `select_output_dir` with a private example
  Downloads directory containing Audio and Videos. The real Videos row and OK
  button are selected; the function returns the expected canonical directory.
- The error fixture uses the real `render_diagnostic` formatter from
  `private-aria2-plan.py` with its disk-space message and an explicit
  demonstration preamble. `show_error_with_log` retains and sanitizes the log,
  then `show_diagnostic_dialog` opens the real `view_diagnostic_file` viewer
  through its View log button. File identity and privacy checks remain active.
  The visible log footer names only this fixture's temporary `/tmp` directory.
  This is a simulated diagnostic, not an actual disk-full event or media transfer.
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
Keep these six paths stable when refreshing captures: installed README copies
display the current images from `main`. Update capture provenance and both
languages' descriptions when the images change.

Before merge, validate the image targets in the qualified candidate tree.
After merge and branch deletion, check their public URLs, returned bytes and
rendering from GitHub and local README copies.

`test-static.sh` checks the six expected PNG paths, nonempty alternative text,
the exact absolute URLs on `main`, PNG headers and dimensions. Each image must
be at most 512 KiB and 2560 pixels on either side. This set totals about 136 KiB.
Visual review remains necessary: these mechanical checks do not establish that
a screenshot is faithful to the interface.

## Social preview

`social-preview.png` is the opaque 1280 × 640 GitHub sharing card, kept below
1,000,000 bytes. It is a source-only asset for the repository's Social preview
setting and is not installed in RPM/DEB packages.

The decorative navy background was generated with the built-in imagegen tool.
Exact typography and the real `readme-url.png` and `readme-progress.png`
captures were composed deterministically with Pillow and Noto Sans. Both
captures retain their native dimensions and pixel content; no interface was
generated or repainted. The progress remains the demonstration described above.
The card uses these three texts, with line wrapping where needed:

- `yt-dlp aria2 downloader`
- `Video & Audio Downloader for Linux`
- `yt-dlp • aria2 • FFmpeg • Zenity`

To refresh it, combine reviewed captures with a quiet opaque background and
the same text. Verify the screenshot regions against their source pixels,
export an RGB PNG at exactly 1280 × 640 below 1,000,000 bytes, and inspect both
the full-size card and a 400-pixel-wide preview. Preserve the privacy and
demonstration boundaries above. Uploading the card in GitHub settings is a
separate action from updating this file.
