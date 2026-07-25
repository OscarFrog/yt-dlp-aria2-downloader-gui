# yt-dlp aria2 downloader GUI - version 2.1.6

This version provides exactly two output profiles:

- **Complete video (MKV)**;
- **Audio track (native format)**.

Audio mode follows the `download-audio.sh` selection strategy with `ba/b`,
`--extract-audio`, `--audio-format best`, and `--audio-quality 0`. The interface
does not ask the user to choose a conversion format.

> **Version 2.1.6:** all documentation, graphical-interface labels, launcher
> text, script comments, and test expectations are now in English. Hard-coded
> French directory fallbacks were replaced with XDG user-directory detection
> and English fallback paths.

## Fedora installation

```bash
sudo dnf install yt-dlp aria2 ffmpeg-free zenity
chmod +x download-video.sh download-video-gui.sh install-gui.sh
./install-gui.sh install
```

## Terminal usage

```bash
./download-video.sh --mode video --output-dir "${HOME}/Videos" 'URL'
./download-video.sh --mode audio --output-dir "${HOME}/Music" 'URL'
```

Audio preferences saved by versions 2.0.x are automatically migrated to the
single `audio` profile.

## Zenity 2.1.4 compatibility fix

The folder chooser keeps Zenity's system button labels. The custom
`--ok-label` and `--cancel-label` options are not passed to file-selection
dialogs because Zenity 4 on Fedora rejects them for this dialog type.

## aria2c 2.1.3 compatibility fix

aria2c capability detection accepts Fedora's actual option syntax, including
forms such as `--no-conf[=true|false]`.
