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
téléchargeur natif de yt-dlp. La version actuelle est la **2.1.27**.

## Installation recommandée

Ouvrez la [dernière release GitHub](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest).

Pour **Fedora 44 ou une version plus récente**, téléchargez ces trois fichiers :

```text
install-fedora.sh
yt-dlp-aria2-downloader-gui-2.1.27-1.fc44.noarch.rpm
SHA256SUMS
```

Vérifiez les fichiers téléchargés puis lancez le bootstrap Fedora officiel :

```bash
sha256sum --ignore-missing --check SHA256SUMS
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.1.27-1.fc44.noarch.rpm
```

Le bootstrap active RPM Fusion Free si nécessaire, remplace `ffmpeg-free` par
le `ffmpeg` complet de RPM Fusion, installe les paquets Fedora requis, installe
le RPM de l'application, vérifie le fournisseur de FFmpeg puis initialise les
runtimes yt-dlp et Deno propres à l'utilisateur.

Pour **Debian ou Ubuntu**, téléchargez le DEB versionné et `SHA256SUMS`,
vérifiez-les puis installez le paquet avec `sudo apt install
./yt-dlp-aria2-downloader-gui_2.1.27-1_all.deb`. Pour **les autres distributions
GNU/Linux ou une utilisation portable**, utilisez le ZIP versionné ou un clone
Git. Les runtimes yt-dlp et Deno gérés automatiquement prennent actuellement en
charge Linux `x86_64` et `aarch64`.

Avec le RPM, le lanceur graphique et son icône sont installés automatiquement dans le menu des applications. **Ne lancez pas `install-gui.sh` après l’installation d’un paquet.** Cet outil est réservé aux installations ZIP et Git.
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

Les commandes système requises par l'application sont :

- Bash **4.4 ou plus récent** ;
- `aria2c` **1.37.0 ou plus récent** ;
- FFmpeg et `ffprobe` ;
- Zenity pour l'interface graphique ;
- `curl`, GnuPG et `unzip` pour l'initialisation et la mise à jour des runtimes ;
- GNU coreutils, GNU grep, `find` et `setsid`/`flock`, normalement fournis par
  les paquets système de base et `util-linux` ;
- Firefox avec une session YouTube authentifiée uniquement pour le profil
  YouTube HLS authentifié facultatif.

`yt-dlp` et Deno **n'ont plus besoin d'être installés comme paquets système**.
L'application maintient des runtimes vérifiés propres à l'utilisateur dans :

```text
~/.local/share/yt-dlp-aria2-downloader/runtime/
```

Par défaut, chaque lancement du moteur contrôle le canal **stable** signé de
yt-dlp et le canal stable de Deno. Toute nouvelle version est préparée
séparément, validée puis activée atomiquement. Les attentes de verrou et les
opérations réseau sont bornées ; si le contrôle de mise à jour échoue, le
dernier runtime vérifié reste actif.

Définissez `YTDLP_ARIA2_YTDLP_CHANNEL=nightly` pour utiliser volontairement les
nightly yt-dlp. Définissez `YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0` pour un **mode
strictement sans réseau** : seuls les runtimes déjà installés sont validés ; un
runtime absent ou invalide provoque un échec clair sans appel à `curl`. Utilisez
`runtime-manager.sh ensure` lorsqu'un bootstrap sans contrôle de mise à jour est
explicitement souhaité. `runtime-manager.sh rollback yt-dlp` et
`runtime-manager.sh rollback deno` réactivent un runtime précédent après
validation lorsqu'il existe.

Le gestionnaire résout d'abord le tag exact de la release, puis télécharge tous
les fichiers depuis cette coordonnée immuable, ce qui élimine la course où
`latest` changerait entre deux téléchargements. yt-dlp est authentifié avec le
manifeste SHA-256 signé par upstream. Les archives Deno sont vérifiées avec le
checksum SHA-256 publié à côté de la même release exacte avant extraction et
validation. L'exécution des runtimes candidats est elle aussi bornée dans le
temps. Les appels réseau individuels sont bornés ; un bootstrap complet en
chaîne plusieurs, il ne faut donc pas interpréter ces limites comme un délai
global unique.

Les paquets système comme FFmpeg, aria2 et Zenity restent gérés par le
gestionnaire de paquets de la distribution. Sous Fedora, le bootstrap officiel
installe les versions les plus récentes disponibles dans les dépôts
Fedora/RPM Fusion activés au moment de l'installation.

## Provenance et immuabilité des releases

Les **Immutable Releases** GitHub doivent être activées dans les paramètres du
dépôt avant de pousser le tag de release. Le workflow contrôle l'inventaire
exact des noms d'assets, compare octet par octet une release déjà existante lors
d'un rerun, confirme que la release obtenue est immuable, puis vérifie
l'attestation GitHub et chaque asset local. Si une nouvelle release reste anormalement mutable, le workflow tente
de la supprimer, vérifie ensuite sa disparition et échoue explicitement si le
nettoyage ne peut pas être confirmé.

Avec GitHub CLI, il est possible de vérifier en plus la provenance du build et
l'identité de la release :

```bash
gh attestation verify ./ARTEFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify v2.1.27 -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset v2.1.27 ./ARTEFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
```

`SHA256SUMS` reste utile pour un contrôle local ou hors ligne ; les attestations
et l'immuabilité ajoutent la preuve de provenance et d'identité de release.

## Installation par paquet

Les releases GitHub publient un RPM Fedora, un DEB Debian/Ubuntu, l'archive
ZIP portable, le bootstrap Fedora et un fichier `SHA256SUMS` commun. Les paquets
RPM et DEB installent les commandes, l’icône dédiée et le lanceur graphique au
niveau du système. Aucune exécution séparée de `install-gui.sh` n’est nécessaire
avec une installation par paquet.

Avant de migrer depuis une installation ZIP ou Git, supprimez l'ancien lanceur
utilisateur afin qu'il ne masque pas l'entrée installée par le paquet :

```bash
./install-gui.sh uninstall
```

### Fedora 44 et versions suivantes

Utilisez `install-fedora.sh` provenant de la même release GitHub que le RPM.
N'installez pas directement le RPM sur une Fedora fraîche : RPM Fusion doit
être activé avant que DNF ne résolve la dépendance `ffmpeg`.

Téléchargez :

```text
install-fedora.sh
yt-dlp-aria2-downloader-gui-2.1.27-1.fc44.noarch.rpm
SHA256SUMS
```

Vérifiez tous les fichiers téléchargés :

```bash
sha256sum --ignore-missing --check SHA256SUMS
```

Puis lancez :

```bash
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.1.27-1.fc44.noarch.rpm
```

Le bootstrap :

- active RPM Fusion Free s'il est absent ;
- remplace `ffmpeg-free` par le `ffmpeg` RPM Fusion lorsque nécessaire ;
- installe les dépendances système requises ;
- installe le RPM de l'application ;
- vérifie que `ffmpeg` provient de RPM Fusion et que `ffmpeg-free` est absent ;
- initialise et valide les runtimes yt-dlp stable et Deno stable pour
  l'utilisateur courant.

Le RPM lui-même ne télécharge aucun runtime tiers depuis un scriptlet RPM.
Les téléchargements de runtimes sont effectués dans le contexte non privilégié
de l'utilisateur et vérifiés avant activation.

### Debian et Ubuntu

La release 2.1.27 publie un DEB indépendant de l'architecture, aligné sur le
même modèle de runtimes gérés que Fedora. Téléchargez :

```text
yt-dlp-aria2-downloader-gui_2.1.27-1_all.deb
SHA256SUMS
```

Vérifiez puis installez :

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.1.27-1_all.deb
```

Le DEB dépend des outils système habituels (`aria2c`, FFmpeg/FFprobe, Zenity,
curl, GnuPG, unzip, coreutils, grep, findutils et util-linux), mais **ne dépend
pas de paquets yt-dlp ou Deno fournis par la distribution**. yt-dlp et Deno sont
installés et vérifiés dans le runtime de l'utilisateur au premier lancement.

### Commandes installées par les paquets

Après l'installation du RPM ou du DEB, démarrez l'interface depuis le menu
des applications ou avec :

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

Debian/Ubuntu :

```bash
sudo apt remove yt-dlp-aria2-downloader-gui
```

Une **désinstallation finale du paquet** effectue désormais un nettoyage
best-effort du runtime géré propre à chaque utilisateur ainsi que des artefacts
XDG historiques portant exactement le nom `yt-dlp-aria2-downloader-gui`, pour
les utilisateurs dont le dossier personnel est disponible. Une **mise à niveau
du paquet ne déclenche pas ce nettoyage**.

Le nettoyage repose volontairement sur une liste blanche de chemins. Il
supprime le runtime géré sous
`${XDG_DATA_HOME:-$HOME/.local/share}/yt-dlp-aria2-downloader/runtime/` et les
anciens chemins `yt-dlp-aria2-downloader-gui` connus dans les emplacements XDG
de données, configuration, état et cache. Il ne recherche pas récursivement
dans le dossier personnel tous les fichiers dont le nom ressemble à celui du
paquet.

À partir de la 2.1.27, le gestionnaire de runtime enregistre le
`XDG_DATA_HOME` réellement utilisé afin qu'une désinstallation ultérieure
puisse aussi retrouver un emplacement de données personnalisé. Un emplacement
XDG personnalisé utilisé uniquement par une ancienne version et jamais observé
par la 2.1.27 ne peut pas être reconstitué automatiquement de manière sûre.

Le lanceur portable ZIP/Git
`~/.local/share/yt-dlp-aria2-downloader/launch` est volontairement conservé
lorsqu'il existe, car il peut appartenir à une installation portable
indépendante.

`install-gui.sh uninstall` reste la commande destinée à supprimer une ancienne
installation de bureau ZIP ou Git dans le dossier personnel de l'utilisateur
courant.

## Installation depuis une archive de release portable

Téléchargez les fichiers suivants :

```text
yt-dlp-aria2-downloader-gui-2.1.27.zip
SHA256SUMS
```

Vérifiez puis extrayez l'archive :

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.1.27.zip
cd yt-dlp-aria2-downloader-gui-2.1.27
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

## Installation avec Git

```bash
git clone https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui.git
cd yt-dlp-aria2-downloader-gui
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
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

Pour l'extraction YouTube actuelle, le moteur utilise le runtime Deno géré
automatiquement via un chemin explicite :

```text
--js-runtimes deno:/chemin/absolu/vers/deno
```

L'exécutable Linux officiel yt-dlp géré par l'application contient les scripts
`yt-dlp-ejs` compatibles. Le wrapper ne demande donc **pas**
`--remote-components ejs:npm` pendant un téléchargement. yt-dlp et ses
dépendances embarquées sont mis à jour ensemble comme un seul runtime vérifié.

### Vidéo complète

Le moteur sélectionne les meilleures pistes vidéo et audio, puis les fusionne ou
les remuxe dans un conteneur MKV sans réencodage lorsque les flux sont
compatibles.

### Vidéo YouTube HLS authentifiée

Le profil graphique `YouTube video - Firefox cookies (HLS/MKV)` est un mode de
repli explicite pour les sessions YouTube nécessitant une authentification,
notamment lorsque les URL média HTTPS ordinaires retournent une erreur HTTP
403. Il ajoute les options suivantes :

    --cookies-from-browser firefox
    --extractor-args youtube:player_client=web_safari
    --format (bv*+ba/b)[protocol^=m3u8]

Ce profil est limité au mode vidéo et aux URL YouTube. yt-dlp lit directement
la base locale de cookies Firefox ; l'application ne copie, n'exporte et ne
stocke aucune valeur de cookie dans `gui.conf`.

Les téléchargements HLS réussis restent traités par le téléchargeur natif de
médias fragmentés de yt-dlp. yt-dlp applique d'abord son correctif
MPEG-TS-dans-MP4, puis le moteur effectue un second remux en copie de flux du
MP4 réparé vers MKV. Aucune de ces deux étapes ne réencode la vidéo ou l'audio.

Ce profil constitue une solution de compatibilité et ne remplace pas les
plugins fournisseurs de PO Token. Les mécanismes de contrôle de YouTube peuvent
évoluer indépendamment de ce projet.

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

Runtimes yt-dlp et Deno gérés :

```text
~/.local/share/yt-dlp-aria2-downloader/runtime/
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
