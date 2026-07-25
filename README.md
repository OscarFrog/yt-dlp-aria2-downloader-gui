# yt-dlp aria2 downloader

Interface graphique Zenity et moteur Bash pour télécharger une URL unique sous
l’une de ces deux formes :

- **vidéo entière en MKV** ;
- **piste audio de meilleure qualité dans son format natif**.

La version 2.1.5 conserve `download-video.sh` comme moteur terminal et
`download-video-gui.sh` comme interface graphique. Le GUI collecte l’URL, le
type de sortie et le dossier, puis appelle le moteur sans dupliquer la logique
`yt-dlp`.

> **Correctif 2.1.4 :** la détection des capacités aria2c accepte maintenant
> la syntaxe réelle de Fedora, notamment `--no-conf[=true|false]`.


## Comportement des deux modes

### Vidéo entière (MKV)

Le moteur sélectionne la meilleure piste vidéo et la meilleure piste audio,
puis les fusionne ou remuxe dans un conteneur MKV sans réencodage lorsque les
flux sont compatibles.

### Piste audio (format natif)

Le mode audio reprend la logique du script `download-audio.sh` :

```text
--format ba/b
--extract-audio
--audio-format best
--audio-quality 0
```

Il privilégie la meilleure piste audio seule. Si le site n’en propose pas, il
utilise le meilleur fichier combiné et en extrait la piste audio. Aucun MP3,
M4A ou Opus n’est imposé : le résultat peut donc être WebM/Opus, M4A/AAC ou un
autre format fourni par la source.


### Compatibilité du sélecteur de dossier

La boîte de sélection de dossier utilise les libellés système de Zenity. Les
options `--ok-label` et `--cancel-label` ne sont volontairement pas envoyées au
sélecteur de fichiers, car Zenity 4 sur Fedora les refuse pour ce type de boîte
de dialogue.

## Fonctions

- une URL par exécution, sans playlist accidentelle ;
- deux choix seulement dans l’interface ;
- choix et mémorisation du dossier de destination ;
- mémorisation du dernier choix vidéo/audio ;
- progression `yt-dlp` et progression console `aria2c` ;
- annulation du groupe complet (`yt-dlp`, `aria2c`, FFmpeg) ;
- journal privé par exécution ;
- lanceur dans le menu des applications ;
- tests statiques et tests d’intégration hermétiques.

## Prérequis

Commandes nécessaires dans `PATH` : Bash, `yt-dlp`, `aria2c`, `ffmpeg`,
`ffprobe`, Deno, Zenity, GNU coreutils, GNU grep et `setsid`.

Versions minimales contrôlées par le moteur :

- `yt-dlp >= 2026.06.09` ;
- `aria2c >= 1.37.0` ;
- Deno `>= 2.3.0`.

### Fedora 44

```bash
sudo dnf install yt-dlp aria2 ffmpeg-free zenity
```

Installation de Deno si nécessaire :

```bash
curl -fsSL https://deno.land/install.sh | sh
```

Ouvrir ensuite un nouveau terminal.

## Installation de l’interface

```bash
chmod +x download-video.sh download-video-gui.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

Le lanceur **yt-dlp aria2 downloader** est créé dans
`~/.local/share/applications/`.

Le lanceur conserve le chemin absolu du dépôt. Après déplacement du dossier,
relancer `./install-gui.sh install`.

## Utilisation graphique

```bash
./download-video-gui.sh
```

L’interface demande :

1. l’URL ;
2. **Vidéo entière (MKV)** ou **Piste audio (format natif)** ;
3. le dossier de destination.


## Dépannage du sélecteur de dossier Zenity

La sélection du dossier essaie d’abord de rouvrir le dernier emplacement avec
`--filename`. Si Zenity ou GTK refuse cette présélection, l’interface recommence
automatiquement sans dossier initial. Si les deux tentatives échouent, le
message affiche maintenant la sortie d’erreur réelle de Zenity afin de faciliter
le diagnostic.

Pour tester Zenity indépendamment de l’application :

```bash
zenity --file-selection --directory --title='Test du sélecteur de dossier'
printf 'Code de retour : %d\n' "$?"
```

## Utilisation en terminal

Vidéo entière en MKV :

```bash
./download-video.sh \
  --mode video \
  --output-dir "${HOME}/Vidéos" \
  'https://example.com/video'
```

Piste audio native de meilleure qualité :

```bash
./download-video.sh \
  --mode audio \
  --output-dir "${HOME}/Musique" \
  'https://example.com/video'
```

Les anciennes options `--audio-format` et `--audio-quality` ont été supprimées
afin d’éviter toute conversion imposée.

## Données locales

Configuration :

```text
~/.config/yt-dlp-aria2-downloader/gui.conf
```

Journaux :

```text
~/.local/state/yt-dlp-aria2-downloader/download-*.log
```

Les anciens profils `audio-mp3`, `audio-m4a` et `audio-opus` sont migrés
automatiquement vers le profil unique `audio`.

## Tests

```bash
./test-static.sh
./tests/mock-integration.sh
./tests/installer-integration.sh
```

Analyse statique recommandée :

```bash
shellcheck -o all download-video.sh download-video-gui.sh install-gui.sh
shellcheck test-static.sh tests/*.sh
```

## Désinstallation du lanceur

```bash
./install-gui.sh uninstall
```

## Limites et usage légal

- aucune playlist ;
- aucune gestion graphique des cookies ou de l’authentification ;
- le format audio final dépend du meilleur flux fourni par le site ;
- utiliser ce logiciel uniquement pour les contenus que vous êtes autorisé à
  télécharger.

## Licence

MIT. Voir [LICENSE](LICENSE).
