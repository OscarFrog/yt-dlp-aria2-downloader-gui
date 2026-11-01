# yt-dlp aria2 downloader

[![Validation Shell](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[English version](README.md)

Téléchargez une vidéo ou sa piste audio sous **GNU/Linux**, avec une interface
Zenity simple ou depuis le terminal. Collez une URL, choisissez les pistes et
le dossier de destination, puis suivez le téléchargement et le traitement.

- **Vidéo :** meilleures pistes vidéo et audio disponibles, réunies dans un MKV.
- **Audio :** meilleure piste disponible, en conservant son format source lorsque possible.
- **Langues :** choix indépendants des audios et sous-titres sur les sites compatibles.
- **Au quotidien :** préférences mémorisées, annulation et téléchargements indépendants simultanés.

La version de développement actuelle est la **2.4.4**.
La dernière release de paquets publiée est la **2.4.4**.

## Sommaire

[Captures d'écran](#captures-décran) · [Installation](#installation-recommandée) ·
[Premiers pas](#premiers-pas) · [Audio et sous-titres](#audio-et-sous-titres) ·
[Terminal](#utilisation-en-ligne-de-commande) · [Dépannage](#dépannage-essentiel) ·
[Documentation complémentaire](#documentation-complémentaire)

## Captures d'écran

Véritables fenêtres Zenity avec des données de démonstration. Les libellés de
l'interface sont en anglais ; l'apparence dépend du thème du bureau. La
progression présentée est une démonstration, pas une mesure de performances.

| Coller une URL | Suivre la progression |
| --- | --- |
| ![Fenêtre de saisie prête à recevoir une URL vidéo](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-url.png) | ![Fenêtre de progression du téléchargement avec le bouton Cancel](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-progress.png) |

| Choisir les pistes audio | Choisir les sous-titres |
| --- | --- |
| ![Liste des pistes audio avec les langues disponibles et le bouton Continue](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-audio.png) | ![Liste des sous-titres avec l'option No subtitles](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-subtitles.png) |

| Choisir un dossier de destination | Consulter un journal d'erreur |
| --- | --- |
| ![Sélecteur du dossier de destination avec des dossiers de démonstration](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-folder.png) | ![Visionneuse ouverte via View log, affichant une erreur d'espace disque simulée](https://raw.githubusercontent.com/OscarFrog/yt-dlp-aria2-downloader-gui/main/docs/images/readme-error-log.png) |

Le journal illustre une erreur d'espace disque simulée.

## Installation recommandée

Ouvrez la [dernière release GitHub](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest).
Les noms ci-dessous correspondent à la release v2.4.4 actuellement publiée.
Téléchargez les fichiers adaptés à votre système dans un même dossier, puis ouvrez-y un terminal.

| Système | Application à télécharger |
| --- | --- |
| Fedora 44 | [RPM](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest/download/yt-dlp-aria2-downloader-gui-2.4.4-1.fc44.noarch.rpm) |
| Debian / Ubuntu | [DEB](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest/download/yt-dlp-aria2-downloader-gui_2.4.4-1_all.deb) |
| Autres GNU/Linux / utilisation portable | [ZIP](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest/download/yt-dlp-aria2-downloader-gui-2.4.4.zip) |

### Fedora 44

Téléchargez ces quatre fichiers depuis cette release :

```text
install-fedora.sh
RPM-GPG-KEY-OscarFrog
yt-dlp-aria2-downloader-gui-2.4.4-1.fc44.noarch.rpm
SHA256SUMS
```

```bash
sha256sum --ignore-missing --check SHA256SUMS
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.4.4-1.fc44.noarch.rpm
```

Utilisez le bootstrap plutôt qu'une installation directe du RPM sur une Fedora
fraîche. Il vérifie les signatures, active RPM Fusion Free si nécessaire,
remplace `ffmpeg-free` par le `ffmpeg` complet, installe les dépendances et
prépare les runtimes yt-dlp et Deno vérifiés propres à l'utilisateur.

### Debian et Ubuntu

La dernière release publiée, la 2.4.4, fournit le DEB. Téléchargez :

```text
yt-dlp-aria2-downloader-gui_2.4.4-1_all.deb
SHA256SUMS
```

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.4.4-1_all.deb
```

Le paquet installe les dépendances système. Les runtimes yt-dlp et Deno vérifiés
sont préparés pour votre utilisateur au premier lancement ; les paquets de la
distribution pour ces deux outils ne sont pas nécessaires.

Avec le RPM et le DEB, le lanceur et son icône sont installés automatiquement dans le menu des applications.
**Ne lancez pas `install-gui.sh` après l’installation d’un paquet.**
Pour remplacer une installation ZIP/Git, retirez d'abord son ancien lanceur
depuis le dossier source avec `./install-gui.sh uninstall`.

### Archive ZIP portable ou clone Git

<details>
<summary>Installer depuis le ZIP de release</summary>

Installez d'abord les [prérequis système](#prérequis). Téléchargez :

```text
yt-dlp-aria2-downloader-gui-2.4.4.zip
SHA256SUMS
```

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.4.4.zip
cd yt-dlp-aria2-downloader-gui-2.4.4
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

</details>

<details>
<summary>Installer avec Git</summary>

Installez d'abord les [prérequis système](#prérequis), puis exécutez :

```bash
git clone https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui.git
cd yt-dlp-aria2-downloader-gui
chmod +x download-video.sh download-video-gui.sh runtime-manager.sh install-gui.sh
chmod +x test-static.sh tests/*.sh
./install-gui.sh install
```

</details>

Pour ZIP/Git, conservez le dossier source : le lanceur pointe vers celui-ci.
Après un déplacement, relancez `./install-gui.sh install`.

### Prérequis

GNU/Linux sur `x86_64` ou `aarch64` pour les runtimes gérés, avec :

- Bash **4.4 ou plus récent**, Python **3.10 ou plus récent**, aria2 **1.37.0 ou plus récent** ;
- FFmpeg et `ffprobe`, Zenity, certificats CA, curl, GnuPG et unzip ;
- GNU coreutils/grep, findutils et util-linux (`setsid`, `flock`) ;
- pidfds Linux et WNOWAIT utilisables, informations procfs des processus/threads lisibles.

Firefox avec une session YouTube authentifiée n'est nécessaire que pour le
profil YouTube HLS/Firefox explicitement sélectionné. Les installateurs de
paquets gèrent les dépendances système ; pour ZIP/Git, installez-les avec
les outils de votre distribution.

<details>
<summary>Vérification complémentaire de la release avec GitHub CLI</summary>

Remplacez `ARTEFACT` par le nom du fichier téléchargé :

```bash
gh attestation verify ./ARTEFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify v2.4.4 -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset v2.4.4 ./ARTEFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
```

Les empreintes contrôlent l'intégrité des fichiers ; ces commandes vérifient
aussi leur provenance et l'identité de la release immuable. Consultez la
[sécurité des releases](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#ci-and-release-trust-zones).

</details>

## Premiers pas

Ouvrez **yt-dlp aria2 downloader** depuis le menu des applications, ou lancez
la commande installée par le paquet :

```bash
yt-dlp-aria2-downloader-gui
```

Depuis un dossier ZIP ou Git, utilisez plutôt :

```bash
./download-video-gui.sh
```

1. Collez une URL vidéo. Les listes de lecture sont désactivées.
2. Choisissez **Complete video (MKV)** ou **Audio track (native format)**.
   Pour YouTube, le choix vidéo est **YouTube video - Firefox cookies (HLS/MKV)**.
3. Choisissez un dossier de destination, puis les pistes audio/sous-titres lorsqu'elles sont proposées.
4. Suivez la progression ; **Cancel** arrête la session. Après un succès, utilisez
   **Open folder** (ouvrir le dossier), **New download** (nouveau téléchargement) ou **Close** (fermer).

### Vidéo YouTube HLS authentifiée

Ce profil réservé à la vidéo lit votre session Firefox locale et utilise
`youtube:player_client=web_safari` pour demander du HLS, puis remuxe en MKV sans
réencodage. Il ne stocke pas les cookies dans `gui.conf`. La disponibilité
dépend de votre session et de YouTube ; ce repli ne garantit pas l'accès et ne
remplace pas les plugins fournisseurs de PO Token. Le moteur CLI accepte
toujours le mode ordinaire `--mode video` pour YouTube.

Le flux HLS identifié comme étant en direct dans ses métadonnées est refusé dans
tous les profils, y compris YouTube HLS/Firefox, car yt-dlp pourrait transmettre
des URL et des en-têtes privés dans les arguments d'un processus FFmpeg.
Des métadonnées HLS insuffisantes ou contradictoires
sur le caractère en direct du flux sont également refusées. La découverte des métadonnées peut
avoir déjà contacté le site ; le refus intervient avant le
transfert du média et ne publie aucun résultat réussi. Utilisez un enregistrement
à la demande dont les métadonnées peuvent être validées.

## Audio et sous-titres

Sur les sites compatibles, **Complete video (MKV)** analyse les pistes disponibles.
Deux listes à cocher suivent : **Audio tracks**, puis **Subtitles**.
Chaque fenêtre comporte uniquement **Cancel** (annuler) et **Continue** (continuer) ;
continuer depuis les sous-titres lance le téléchargement.

- L'audio présélectionné privilégie une version originale identifiée de façon
  fiable. Si la VO est inconnue, il choisit le français, puis la piste par
  défaut du site ou une autre piste ordinaire, avec une explication. Vous pouvez
  sélectionner plusieurs pistes.
- Les sous-titres dépendent de l'audio par défaut choisi : aucun pour le
  français ; sinon, des sous-titres français complets lorsqu'ils sont disponibles
  sans ambiguïté pour une langue identifiée de façon fiable. Ce choix reste modifiable.
- **No subtitles**, ou toutes les lignes de sous-titres décochées, produit un
  fichier sans aucune piste de sous-titres. Choisissez cette option ou des pistes
  précises. Cocher les deux crée un conflit : il faut corriger la sélection avant de télécharger.
- **Full** (complets) traduit les dialogues ; **Forced** (forcés) couvre certains
  passages et ne remplace pas une traduction complète. Les pistes restent
  activables ou désactivables dans votre lecteur.

Les listes contiennent les pistes distinctes admissibles après filtrage et déduplication.
Les sous-titres pour personnes sourdes ou malentendantes et les pistes explicitement
identifiées comme confort audio sont exclus. L'audiodescription reste disponible.
La disponibilité dépend du programme, du territoire et des droits.

Le MKV contient exactement les pistes choisies, sans réencodage vidéo ou audio.
Les sous-titres utilisent le SRT UTF-8 en conservant le texte, les retours à la ligne
et les horaires. Les positions de la source ne sont pas conservées ; la présentation
dépend du lecteur. Une mise en forme/horloge non prise en charge ou une piste
manquante produit une erreur explicite.

## Utilisation en ligne de commande

Les exemples suivants s'exécutent depuis un dossier ZIP/Git. Pour un RPM/DEB,
remplacez `./download-video.sh` par `yt-dlp-aria2-downloader`.
Remplacez l'adresse d'exemple par votre URL et conservez les guillemets.

Vidéo complète :

```bash
./download-video.sh \
  --mode video \
  --output-dir "${HOME}/Videos" \
  'https://example.com/video'
```

Audio natif :

```bash
./download-video.sh \
  --mode audio \
  --output-dir "${HOME}/Music" \
  'https://example.com/video'
```

Pour les sources vidéo compatibles, ajoutez `--tracks-auto` pour les choix
automatiques, `--all-tracks` pour toutes les pistes admissibles ou `--no-subtitles`
pour omettre les sous-titres. Cette dernière option fonctionne aussi avec l'une
des deux premières. Les exclusions décrites plus haut s'appliquent.

YouTube HLS avec les cookies Firefox :

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

Aide de la commande installée par paquet :

```bash
yt-dlp-aria2-downloader --help
```

Une URL positionnelle peut apparaître dans les arguments des processus. Utilisez
la GUI ou `--url-file FILE` avec un fichier privé vous appartenant si nécessaire.
Les URL contenant `utilisateur:motdepasse@hôte` sont refusées. La configuration
personnelle et les plugins yt-dlp sont désactivés.

## Fichiers, annulation et confidentialité

- Des téléchargements indépendants peuvent partager une destination. Les demandes
  qui se recouvrent sont refusées tant que les fichiers sont réservés ; les résultats
  existants ne sont ni renommés ni adoptés silencieusement. Le traitement local
  présente une fenêtre de collision tardive avec d'autres programmes : il n'offre
  pas une garantie atomique de non-écrasement. La publication réseau/depuis un
  espace privé refuse les collisions tardives. [Détails](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#shared-destination-reservations).
- Les téléchargements natifs interrompus ne reprennent que si le site et les
  preuves d'appartenance enregistrées le permettent. Après confirmation de l'arrêt,
  l'annulation des transferts aria2 gérés par le moteur et des sessions réseau
  isolées supprime les partiels ; la demande suivante recommence à zéro.
- Une destination réseau peut nécessiter un **espace disque local privé**, capable
  de contenir les pistes et les médias assemblés/remuxés, en plus de l'espace de
  destination. Un stockage non pris en charge est refusé. Si la copie échoue ou
  reste incertaine, inspectez la source conservée signalée et la destination avant
  de réessayer. Ne supprimez pas les temporaires ou verrous incertains.
- Les runtimes vérifiés propres à l'utilisateur sont mis à jour par défaut. Un
  échec du contrôle de mise à jour conserve le dernier runtime vérifié.
  [Réglages et récupération des runtimes](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#managed-runtimes-and-persistent-state).

Emplacements par défaut (les personnalisations XDG sont prises en charge) :

| Données | Emplacement |
| --- | --- |
| Préférences | `~/.config/yt-dlp-aria2-downloader/gui.conf` |
| yt-dlp / Deno | `~/.local/share/yt-dlp-aria2-downloader/runtime/` |
| Journaux des exécutions problématiques | `~/.local/state/yt-dlp-aria2-downloader/download-*.log` |

Les journaux des exécutions réussies sont normalement supprimés. Les journaux
conservés sont privés, expurgés des URL, limités à 8 Mio et supprimés après
15 jours lors de la préparation d'une nouvelle session GUI. Les titres et
chemins locaux peuvent rester personnels : relisez les journaux avant de les
partager. Ne partagez jamais de cookies, d'en-têtes ou de plans de transfert
privés. Ne supprimez pas récursivement d'anciens dossiers temporaires sur la
seule ressemblance de leurs noms.

## Dépannage essentiel

Utilisez **View log** lorsqu'une fenêtre d'erreur le propose ; sinon, suivez son
message. Indiquez la version de l'application et l'identifiant du diagnostic
lorsque vous signalez un problème.

| Problème | Première vérification |
| --- | --- |
| Dépendance manquante | Prérequis système et version de l'outil signalé ; sous Fedora, utilisez le bootstrap avec le FFmpeg complet de RPM Fusion. |
| YouTube HLS indisponible | Connexion Firefox, profil sélectionné et disponibilité actuelle pour cette session. |
| `HLS_LIVE_UNSAFE` | Le HLS en direct ou incertain est refusé avant le transfert du média. Utilisez un enregistrement à la demande validé ; changer les cookies ne contourne pas cette protection. |
| `ENOSPC` / `EDQUOT` | Espace libre et quota sur l'espace local de travail et la destination. |
| Erreur d'accès ou de montage | Permissions, disponibilité du montage et identifiants ; préservez les permissions privées de l'espace de travail. |
| Fichier existant ou média réservé | Conservez le fichier ; attendez l'arrêt de l'autre téléchargement. Ne supprimez jamais les verrous pour contourner un refus. |
| Validation ou copie incertaine | Lisez le diagnostic précis et inspectez les médias conservés avant de recommencer. |

Pour la récupération du stockage, les limites d'annulation et l'interprétation
des diagnostics, consultez les
[détails du moteur](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md#engine-pipeline)
et les [limites de qualification réseau](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#network-destination-regression-and-opt-in-cifs-qualification).

<details>
<summary>Récupération et contrôle des mises à jour des runtimes</summary>

Définissez `YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0` pour exiger des runtimes déjà
vérifiés pendant les téléchargements, sans accès réseau pour leur installation
ou leur mise à jour. Les téléchargements de médias restent disponibles. Le canal yt-dlp
par défaut est stable ; `YTDLP_ARIA2_YTDLP_CHANNEL=nightly` active volontairement
les versions nightly.

Depuis un dossier ZIP/Git, téléchargez et préparez explicitement les runtimes manquants avec :

```bash
./runtime-manager.sh ensure
```

Si une version précédente vérifiée est disponible, réactivez celle du composant concerné :

```bash
./runtime-manager.sh rollback yt-dlp
./runtime-manager.sh rollback deno
```

</details>

## Désinstallation

Fedora :

```bash
sudo dnf remove yt-dlp-aria2-downloader-gui
```

Debian/Ubuntu :

```bash
sudo apt remove yt-dlp-aria2-downloader-gui
```

La désinstallation finale du RPM tente de nettoyer les runtimes gérés vérifiés
et les anciens artefacts utilisateur reconnus ; les mises à niveau les préservent.
Le retrait/purge du DEB conserve les données propres aux utilisateurs.
Le nettoyage des paquets conserve les liens des lanceurs portables.

Pour un lanceur installé depuis une archive ZIP portable ou un checkout Git, exécutez depuis son dossier source :

```bash
./install-gui.sh uninstall
```

## Documentation complémentaire

- [Architecture et frontières de sécurité](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/ARCHITECTURE.md)
- [Tests et qualification](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md)
- [Cohérence des versions et préparation des releases](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#version-coherence-and-release-preparation)
- [Démarrage de Codex et routage des tâches](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#codex-session-setup-and-task-routing)
- [Historique des changements](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/CHANGELOG.md)

<details>
<summary>Mainteneurs : reprise manuelle d'une release</summary>

Les commits et fusions de PR ordinaires n'exigent pas de changement de version.
La préparation et la publication d'une release sont des opérations distinctes,
explicitement autorisées. Uniquement après la création du tag signé et la réussite
du [preflight de release](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md#release-maintainer-preflight),
la reprise manuelle utilise le tag exact :

```bash
gh workflow run release.yml \
  --ref v2.4.4 \
  -f tag=v2.4.4 \
  -R OscarFrog/yt-dlp-aria2-downloader-gui
```

Un tag publié et ses assets ne doivent jamais servir à distribuer un contenu différent.

</details>

## Communauté

- Questions et aide à l'utilisation : [GitHub Discussions](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/discussions).
- Signaler un [bug](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/issues/new?template=bug-report.yml) ou proposer une [fonctionnalité](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/issues/new?template=feature-request.yml).
- Contribuer au code ou à la documentation : [guide de contribution](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/CONTRIBUTING.md).
- Vulnérabilité suspectée : [signaler en privé](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/security/advisories/new) selon la [politique de sécurité](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/SECURITY.md).

Utilisez ce logiciel uniquement pour les contenus que vous êtes autorisé à
télécharger. Les restrictions des sites et leur disponibilité upstream peuvent
évoluer. Distribué sous [licence MIT](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/LICENSE).
