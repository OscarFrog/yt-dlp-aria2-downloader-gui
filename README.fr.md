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
téléchargeur natif de yt-dlp. La version actuelle est la **2.1.21**.

## Installation recommandée

Ouvrez la [dernière release GitHub](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest)
et téléchargez le fichier correspondant à votre système :

- **Fedora 44 ou version plus récente :** le RPM `2.1.21`,
  `yt-dlp-aria2-downloader-gui-2.1.21-1.fc44.noarch.rpm` ;
- **Debian, Ubuntu, autre distribution GNU/Linux ou utilisation portable :**
  l’archive ZIP versionnée. Vérifiez que `yt-dlp` et `aria2c` respectent les
  versions minimales indiquées ci-dessous.

Avec une installation RPM, le lanceur graphique et son icône sont
installés automatiquement dans le menu des applications. **Ne lancez pas
`install-gui.sh` après l’installation d’un paquet.** Cet outil est réservé aux
installations depuis le ZIP ou Git.

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
- annulation de tout le groupe de processus au sein d’une session GUI unique ;
- supervision de yt-dlp et des commandes FFmpeg exécutées par le moteur, avec arrêt borné ;
- validation FFprobe des pistes vidéo et audio pour une vidéo complète, et de la piste audio pour le mode audio, avant la publication du succès ;
- une seule instance en écriture par dossier de destination, afin
  d'empêcher le partage concurrent de fichiers partiels ou de
  post-traitement ;
- journaux privés conservés uniquement pour les exécutions problématiques, avec expurgation des URL et limite de 8 Mio ;
- lanceur dans le menu des applications ;
- tests statiques, tests d'intégration et validation GitHub Actions sous Ubuntu
  et Fedora 44.

## Prérequis

Les commandes suivantes doivent être installées et disponibles dans `PATH` :

- Bash **4.4 ou plus récent** ;
- `yt-dlp` **2026.06.09 ou plus récent** ;
- `aria2c` **1.37.0 ou plus récent** ;
- FFmpeg et `ffprobe` ;
- Deno **2.3.0 ou plus récent pour l’extraction YouTube** ; les autres sites pris en charge peuvent fonctionner sans Deno ;
- Zenity pour l'interface graphique ;
- Firefox avec une session YouTube authentifiée uniquement pour le profil
  YouTube HLS authentifié facultatif ;
- GNU coreutils, GNU grep et `setsid`, généralement fourni par `util-linux`.

Le moteur contrôle toujours les versions minimales de `yt-dlp` et `aria2c`. Deno n’est contrôlé que lorsqu’il est installé ou lorsque l’extraction YouTube l’exige.

## Installation par paquet

Les releases GitHub publient un RPM Fedora, l'archive ZIP portable et un
fichier `SHA256SUMS` commun. Le RPM installe les commandes, l’icône dédiée et le
lanceur graphique au niveau du système ; son fonctionnement ne dépend pas du
dossier dans lequel le paquet a été téléchargé. Aucune exécution séparée de
`install-gui.sh` n’est nécessaire avec un RPM.

Avant de migrer depuis une installation ZIP ou Git, supprimez l'ancien lanceur
utilisateur afin qu'il ne masque pas l'entrée installée par le paquet :

```bash
./install-gui.sh uninstall
```

### Fedora 44 et versions suivantes

Le paquet `ffmpeg` complet est fourni par RPM Fusion Free. Activez ce dépôt
avant l'installation du RPM s'il n'est pas déjà configuré :

```bash
sudo dnf install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
```

Téléchargez les fichiers suivants depuis la release :

```text
yt-dlp-aria2-downloader-gui-2.1.21-1.fc44.noarch.rpm
SHA256SUMS
```

Vérifiez puis installez le RPM :

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo dnf install --allowerasing ./yt-dlp-aria2-downloader-gui-2.1.21-1.fc44.noarch.rpm
```

Le RPM déclare yt-dlp, aria2, FFmpeg/FFprobe, Zenity et les outils GNU nécessaires comme dépendances strictes. Deno reste géré séparément et n’est obligatoire que pour l’extraction YouTube.

### Debian et Ubuntu

La release 2.1.21 ne publie pas de DEB. Le binaire yt-dlp actuellement
disponible dans `trixie-backports` pour Debian 13 est antérieur au minimum de
sécurité exigé par ce projet (`2026.06.09`). Les dépôts Ubuntu sont également
sous ce minimum. Utilisez l’archive ZIP portable ou l’installation Git et
fournissez séparément une version compatible de yt-dlp. N’abaissez pas la
version minimale et ne forcez pas l’installation d’un ancien yt-dlp.

### Commandes installées par les paquets

Après l'installation du RPM, démarrez l'interface depuis le menu des
applications ou avec :

```bash
yt-dlp-aria2-downloader-gui
```

Le moteur en ligne de commande est installé sous le nom :

```bash
yt-dlp-aria2-downloader --help
```

### Désinstaller une installation par paquet

Fedora :

```bash
sudo dnf remove yt-dlp-aria2-downloader-gui
```

Le gestionnaire de paquets supprime les commandes système, le lanceur graphique
et l’icône de l’application. `install-gui.sh uninstall` sert uniquement à
nettoyer une ancienne installation ZIP ou Git créée dans le dossier personnel
de l’utilisateur courant.

## Installation depuis une archive de release portable

Téléchargez les fichiers suivants :

```text
yt-dlp-aria2-downloader-gui-2.1.21.zip
SHA256SUMS
```

Vérifiez puis extrayez l'archive :

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.21.zip
cd yt-dlp-aria2-downloader-gui-2.1.21
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

Le parcours graphique utilise une succession de fenêtres Zenity natives. Les étapes ci-dessous décrivent entièrement l’interface sans dépendre de captures d’écran, afin que la documentation reste exacte lorsque les dimensions des fenêtres ou le thème du bureau évoluent.

Démarrez **yt-dlp aria2 downloader** depuis le menu des applications. Une
installation par paquet fournit également la commande
`yt-dlp-aria2-downloader-gui` ; depuis une archive ZIP ou un clone Git,
utilisez :

```bash
./download-video-gui.sh
```

### 1. Saisir l'URL de la vidéo

Collez l'URL de la vidéo à télécharger, puis validez la fenêtre.


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


### 3. Choisir le dossier de destination

Sélectionnez le dossier dans lequel le média téléchargé sera enregistré.


### 4. Suivre la progression

La fenêtre de progression indique l’étape actuelle du téléchargement ou du post-traitement. Le remuxage FFmpeg géré par le moteur utilise la sortie de progression machine de FFmpeg et la durée de la source, et non un compteur artificiel. Le bouton d'annulation permet d'arrêter l'ensemble du
processus.


### 5. Résultat du téléchargement

Après un téléchargement réussi, l'interface affiche le chemin du fichier
multimédia terminé.


Lorsque le téléchargement échoue, l'interface affiche une fenêtre d'erreur et
conserve le journal de diagnostic.


Le journal conservé peut être ouvert depuis la fenêtre d’erreur. Avant sa conservation, les valeurs ressemblant à des URL sont remplacées par `[REDACTED_URL]` et seuls les 8 derniers Mio sont gardés. Le journal actif reste privé (`0600`) pendant l’exécution.



### Confidentialité des URL dans l’interface graphique

La GUI écrit l’URL demandée dans un fichier temporaire privé et ne transmet au moteur que le chemin de ce fichier. Le moteur fournit ensuite l’URL à yt-dlp via son interface de fichier batch privé : l’URL n’apparaît donc pas dans les arguments de ligne de commande de la GUI, du moteur ou de yt-dlp. Les URL contenant `utilisateur:motdepasse@hôte` sont refusées. L’utilisation CLI directe avec une URL positionnelle reste possible ; comme pour toute commande, cette URL peut alors être visible dans les arguments du processus appelant.

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
avec `YTDLP_NO_PLUGINS=1` et applique une politique explicite de
non-écrasement. Lorsque le build aria2c installé annonce `--no-netrc`, le
moteur active cette option afin d’éviter la lecture des identifiants d’un
fichier `.netrc` personnel. Les builds qui n’exposent pas cette capacité
facultative restent acceptés et ne reçoivent pas une option non prise en charge.
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

Pour l’extraction YouTube actuelle, le moteur active Deno. yt-dlp utilise les composants EJS locaux compatibles lorsqu’ils sont présents et peut récupérer les composants officiels depuis npm comme solution de repli :

```text
--js-runtimes deno
--remote-components ejs:npm
```

yt-dlp peut télécharger depuis npm les composants de résolution de défis yt-dlp-ejs lorsque les composants locaux compatibles sont absents. Définissez `YTDLP_DISABLE_REMOTE_EJS=1` pour interdire cette solution de repli ; l’extraction YouTube échouera alors plutôt que de récupérer un composant distant.

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

Le journal actif du processus est créé en mode `0600` dans le dossier
temporaire d’exécution privé, puis supprimé après un succès. Pour une exécution
échouée, annulée, interrompue ou incohérente, seule une copie de diagnostic
expurgée est publiée dans le dossier d’état : les valeurs ressemblant à des URL
sont remplacées, seuls les 8 derniers Mio sont conservés et le fichier final
reste en mode `0600`. Les journaux de diagnostic conservés depuis plus de 15
jours sont supprimés automatiquement au prochain démarrage de l’interface.

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
