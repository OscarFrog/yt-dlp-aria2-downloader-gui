# Interface graphique — version 2.1.5

Cette version propose exactement deux sorties :

- **Vidéo entière (MKV)** ;
- **Piste audio (format natif)**.

Le mode audio reprend le comportement de `download-audio.sh` avec `ba/b`,
`--extract-audio`, `--audio-format best` et `--audio-quality 0`. Aucun format de
conversion n’est présenté à l’utilisateur.

> **Correctif 2.1.4 :** la détection des capacités aria2c accepte maintenant
> la syntaxe réelle de Fedora, notamment `--no-conf[=true|false]`.


## Installation Fedora

```bash
sudo dnf install yt-dlp aria2 ffmpeg-free zenity
chmod +x download-video.sh download-video-gui.sh install-gui.sh
./install-gui.sh install
```

## Terminal

```bash
./download-video.sh --mode video --output-dir "${HOME}/Vidéos" 'URL'
./download-video.sh --mode audio --output-dir "${HOME}/Musique" 'URL'
```

Les préférences audio des versions 2.0.x sont automatiquement converties vers
le profil unique `audio`.


## Correctif Zenity 2.1.4

Le sélecteur de dossier conserve désormais les libellés système de Zenity. Les
options de personnalisation `--ok-label` et `--cancel-label` ne lui sont plus
transmises, car Zenity 4 sur Fedora les rejette pour les boîtes de sélection de
fichiers.
