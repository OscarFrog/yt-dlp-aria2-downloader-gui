# yt-dlp aria2 downloader

[![Validation Shell](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[English version](README.md)

Interface graphique Zenity et moteur Bash exclusivement pour GNU/Linux. Le programme télécharge
une seule URL avec l'un des trois profils suivants :

- une **vidéo MKV complète**, avec les meilleures pistes vidéo et audio
  disponibles ;
- une **vidéo YouTube HLS authentifiée**, qui lit les cookies Firefox et
  remuxe le flux HLS sélectionné dans un conteneur MKV ;
- la **meilleure piste audio disponible**, en conservant son codec et son
  conteneur source lorsque yt-dlp peut le faire sans réencodage.

Le projet utilise `yt-dlp` pour l'extraction des médias, `aria2c` pour accélérer
les téléchargements directs HTTP/FTP et FFmpeg pour fusionner, remuxer ou
extraire les flux. Les flux DASH et HLS restent volontairement traités par le
téléchargeur natif de yt-dlp. La version actuelle est la **2.1.15**.

## Fonctionnalités principales

- interface graphique Zenity simple ;
- moteur utilisable également depuis un terminal ;
- une URL par exécution, avec désactivation des téléchargements accidentels de
  listes de lecture ;
- configuration personnelle et plugins yt-dlp désactivés pour une exécution déterministe ;
- médias terminés et sorties de post-traitement jamais écrasés silencieusement ;
- sélection du dossier de destination et mémorisation des préférences ;
- vidéo MKV sans réencodage lorsque les flux sont compatibles ;
- solution de repli YouTube HLS authentifiée facultative avec les cookies Firefox ;
- extraction de la meilleure piste audio avec conservation du format source lorsque possible ;
- reprise des téléchargements interrompus lorsque le site le permet ;
- progression graphique unifiée pour les fichiers directs, les fragments
  HLS/DASH, les pistes vidéo/audio séparées et le post-traitement FFmpeg ;
- annulation de tout le groupe de processus ;
- une seule instance en écriture par dossier de destination, afin
  d'empêcher le partage concurrent de fichiers partiels ou de
  post-traitement ;
- journaux privés conservés uniquement pour les exécutions problématiques ;
- lanceur dans le menu des applications ;
- tests statiques, tests d'intégration et validation GitHub Actions sous Ubuntu
  et Fedora 44.

## Prérequis

Les commandes suivantes doivent être installées et disponibles dans `PATH` :

- Bash **4.4 ou plus récent** ;
- `yt-dlp` **2026.06.09 ou plus récent** ;
- `aria2c` **1.37.0 ou plus récent** ;
- FFmpeg et `ffprobe` ;
- Deno **2.3.0 ou plus récent** ;
- Zenity pour l'interface graphique ;
- Firefox avec une session YouTube authentifiée uniquement pour le profil
  YouTube HLS authentifié facultatif ;
- GNU coreutils, GNU grep et `setsid`, généralement fourni par `util-linux`.

Le moteur contrôle les versions minimales de `yt-dlp`, `aria2c` et Deno avant
chaque téléchargement.

## Installation sous Fedora 44

Le paquet `ffmpeg` complet est fourni par le dépôt RPM Fusion Free. Activez ce
dépôt s'il n'est pas encore configuré :

```bash
sudo dnf install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
```

Installez ensuite les paquets requis :

```bash
sudo dnf install yt-dlp aria2 ffmpeg zenity
```

Installez Deno s'il n'est pas déjà disponible :

```bash
curl -fsSL https://deno.land/install.sh | sh
```

Ouvrez un nouveau terminal, puis vérifiez les dépendances :

```bash
yt-dlp --version
aria2c --version
ffmpeg -version
ffprobe -version
deno --version
zenity --version
setsid --version
```

## Installation depuis une archive de release

Téléchargez les deux fichiers publiés avec la release GitHub :

```text
yt-dlp-aria2-downloader-gui-2.1.15.zip
SHA256SUMS
```

Vérifiez puis extrayez l'archive :

```bash
sha256sum --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.15.zip
cd yt-dlp-aria2-downloader-gui-2.1.15
chmod +x download-video.sh download-video-gui.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

## Installation avec Git

```bash
git clone https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui.git
cd yt-dlp-aria2-downloader-gui
chmod +x download-video.sh download-video-gui.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

Le lanceur est créé dans :

```text
~/.local/share/applications/
```

L'entrée du menu appelle un lien de lancement stable stocké dans :

```text
~/.local/share/yt-dlp-aria2-downloader/launch
```

Ce lien privé cible le chemin absolu du script graphique dans le dépôt. Après
avoir déplacé le dossier du projet, relancez `./install-gui.sh install`.

## Utilisation graphique

Démarrez **yt-dlp aria2 downloader** depuis le menu des applications ou avec :

```bash
./download-video-gui.sh
```

### 1. Saisir l'URL de la vidéo

Collez l'URL de la vidéo à télécharger, puis validez la fenêtre.

![Fenêtre de saisie de l'URL](docs/images/gui-url.png "Saisie de l'URL")

Les espaces copiés accidentellement avant ou après l'URL sont supprimés par
l'interface graphique.

### 2. Choisir le mode de téléchargement

Sélectionnez l'un des trois profils disponibles :

- **Complete video (MKV)** télécharge les meilleures pistes vidéo et audio
  disponibles, puis les rassemble dans un conteneur MKV ;
- **YouTube video - Firefox cookies (HLS/MKV)** constitue un mode de repli
  authentifié réservé à YouTube : il lit la session Firefox locale, télécharge
  un flux HLS puis le remuxe en MKV ;
- **Audio track (native format)** télécharge la meilleure piste audio disponible
  en conservant son format natif chaque fois que cela est possible.

![Fenêtre de sélection du mode](docs/images/gui-mode.png "Choix du mode de téléchargement")

### 3. Choisir le dossier de destination

Sélectionnez le dossier dans lequel le média téléchargé sera enregistré.

![Fenêtre de sélection du dossier](docs/images/gui-destination.png "Choix du dossier de destination")

### 4. Suivre la progression

La fenêtre de progression indique l'étape actuelle du téléchargement ou du
post-traitement. Le bouton d'annulation permet d'arrêter l'ensemble du
processus.

![Fenêtre de progression](docs/images/gui-progress.png "Progression du téléchargement")

### 5. Résultat du téléchargement

Après un téléchargement réussi, l'interface affiche le chemin du fichier
multimédia terminé.

![Fenêtre de téléchargement terminé](docs/images/gui-download-complete.png "Téléchargement terminé")

Lorsque le téléchargement échoue, l'interface affiche une fenêtre d'erreur et
conserve le journal de diagnostic.

![Fenêtre d'échec du téléchargement](docs/images/gui-download-failed.png "Échec du téléchargement")

Le journal conservé peut être ouvert depuis la fenêtre d'erreur. Il contient les
informations nécessaires au diagnostic et peut inclure l'URL demandée.

![Affichage du journal de diagnostic](docs/images/gui-log.png "Journal de diagnostic")

## Utilisation en ligne de commande

Vidéo MKV complète :

```bash
./download-video.sh \
  --mode video \
  --output-dir "${HOME}/Videos" \
  'https://example.com/video'
```

Meilleure piste audio native :

```bash
./download-video.sh \
  --mode audio \
  --output-dir "${HOME}/Music" \
  'https://example.com/video'
```

Mode de repli YouTube HLS authentifié :

```bash
./download-video.sh \
  --mode video \
  --youtube-hls-firefox \
  --output-dir "${HOME}/Videos" \
  'https://www.youtube.com/watch?v=VIDEO_ID'
```

Aide et version :

```bash
./download-video.sh --help
./download-video.sh --version
```

Placez toujours les URL entre apostrophes ou guillemets, car elles peuvent
contenir des métacaractères du shell comme `&`.

Le moteur utilise volontairement `--ignore-config`, désactive les plugins yt-dlp
avec `YTDLP_NO_PLUGINS=1` et applique une politique explicite de non-écrasement.
Les fichiers `.part` interrompus peuvent toujours être repris, mais un média
terminé ou post-traité déjà présent est conservé et l'exécution échoue au lieu
de le remplacer.

Le modèle de sortie limite le titre et l'identifiant du média selon leur taille
encodée en octets, ce qui réduit les échecs avec de longs titres Unicode sur les
systèmes de fichiers limitant un composant de chemin à 255 octets.

## Fonctionnement des téléchargeurs

Le moteur utilise aria2c pour les transferts directs HTTP/FTP et le téléchargeur
natif de yt-dlp pour les manifestes DASH et HLS :

```text
--downloader aria2c
--downloader dash,m3u8:native
```

Pour l'extraction YouTube actuelle, le moteur active également Deno et autorise
yt-dlp à récupérer les composants EJS depuis npm lorsqu'ils sont nécessaires :

```text
--js-runtimes deno
--remote-components ejs:npm
```

yt-dlp peut télécharger depuis npm les composants de résolution de défis
yt-dlp-ejs. Ces scripts sont exécutés par Deno avec des permissions restreintes
d'accès au système de fichiers et au réseau. Un téléchargement YouTube peut
donc contacter npm en plus du site qui héberge le média.

### Vidéo YouTube HLS authentifiée

Le profil graphique `YouTube video - Firefox cookies (HLS/MKV)` constitue une
solution de repli explicite pour les sessions YouTube qui exigent une connexion
et dont les URL média HTTPS ordinaires répondent par une erreur HTTP 403. Il
ajoute :

```text
--cookies-from-browser firefox
--extractor-args youtube:player_client=web_safari
--format (bv*+ba/b)[protocol^=m3u8]
```

Ce profil est limité au mode vidéo et aux URL YouTube. yt-dlp lit la base locale
des cookies Firefox, mais l'application ne copie, n'exporte et ne conserve
aucune valeur de cookie dans `gui.conf`. Les téléchargements HLS sont traités
par le téléchargeur natif de fragments de yt-dlp. yt-dlp répare d'abord le
MPEG-TS placé dans un fichier MP4,
puis le moteur effectue un second remuxage par copie de flux du MP4 réparé vers
MKV. Aucune des deux étapes ne réencode l'audio ou la vidéo.

Il s'agit d'une solution de compatibilité, et non d'un remplacement des
fournisseurs automatiques de PO Token. Les règles YouTube peuvent évoluer
indépendamment du projet.

### Vidéo complète

Le moteur sélectionne les meilleures pistes vidéo et audio, puis les fusionne ou
les remuxe dans un conteneur MKV sans réencodage lorsque les flux sont
compatibles.

### Piste audio native

Le mode audio utilise :

```text
--format ba/b
--extract-audio
--audio-format best
--audio-quality 0
```

Il privilégie la meilleure piste audio seule. Si le site n'en fournit pas, il
utilise le meilleur fichier combiné et en extrait l'audio. yt-dlp conserve le
codec et le conteneur source lorsque cela est possible, mais peut utiliser
FFmpeg pour remuxer ou convertir un média qui ne peut pas être extrait directement.

## Données locales

Configuration de l'interface :

```text
~/.config/yt-dlp-aria2-downloader/gui.conf
```

Journaux d'exécution :

```text
~/.local/state/yt-dlp-aria2-downloader/download-*.log
```

Les journaux sont privés. Un journal est supprimé automatiquement dès que le
fichier média final est confirmé. Les exécutions échouées, annulées, interrompues
ou incohérentes conservent leur journal afin de faciliter le diagnostic. Les
journaux de diagnostic conservés depuis plus de 15 jours sont supprimés
automatiquement au prochain démarrage de l'interface graphique.

Un verrou consultatif par utilisateur et par dossier de destination est
conservé sous `$XDG_RUNTIME_DIR/yt-dlp-aria2-downloader` lorsque ce dossier
d'exécution est absolu, privé et appartient à l'utilisateur courant. Sinon, le
moteur utilise le repli privé `/tmp/yt-dlp-aria2-downloader-UID`. Les fichiers
de verrou ne contiennent ni URL, ni cookie, ni chemin de média, et le noyau
libère automatiquement le verrou à la fin du moteur. Des téléchargements vers
des dossiers différents peuvent s'exécuter simultanément.

## Tests

Consultez [TESTING.md](TESTING.md) pour les validations locales, les contrôles
spécifiques à Fedora et les tâches GitHub Actions.

## Désinstallation du lanceur

```bash
./install-gui.sh uninstall
```

## Limites et utilisation légale

- les listes de lecture sont désactivées ;
- les cookies Firefox ne sont lus que lorsque le profil YouTube HLS
  authentifié est explicitement sélectionné ;
- ce mode HLS est réservé à la vidéo et ne préserve pas une piste audio
  YouTube native séparée ;
- le format audio final dépend du meilleur flux fourni par le site ;
- certains sites limitent ou interdisent les téléchargements ;
- utilisez ce programme uniquement pour les contenus que vous êtes autorisé à
  télécharger.

## Licence

Ce projet est distribué sous licence MIT. Consultez [LICENSE](LICENSE).
