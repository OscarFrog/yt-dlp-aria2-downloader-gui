# yt-dlp aria2 downloader

[![Validation Shell](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml/badge.svg)](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/shell.yml)

[English version](README.md)

## Sommaire

- [Installation recommandée](#installation-recommandée)
- [Fonctionnalités principales](#fonctionnalités-principales)
- [Prérequis](#prérequis)
- [Provenance et immuabilité des releases](#provenance-et-immuabilité-des-releases)
- [Installation par paquet](#installation-par-paquet)
  - [Fedora 44](#fedora-44)
  - [Debian et Ubuntu](#debian-et-ubuntu)
  - [Commandes installées par les paquets](#commandes-installées-par-les-paquets)
  - [Désinstaller une installation par paquet](#désinstaller-une-installation-par-paquet)
- [Installation depuis une archive de release portable](#installation-depuis-une-archive-de-release-portable)
- [Installation avec Git](#installation-avec-git)
- [Utilisation graphique](#utilisation-graphique)
- [Utilisation en ligne de commande](#utilisation-en-ligne-de-commande)
- [Fonctionnement des téléchargeurs](#fonctionnement-des-téléchargeurs)
- [Données locales](#données-locales)
- [Tests](#tests)
- [Désinstallation du lanceur](#désinstallation-du-lanceur)
- [Limites et utilisation légale](#limites-et-utilisation-légale)
- [Licence](#licence)

Interface graphique Zenity et moteur Bash exclusivement pour GNU/Linux. Le
programme télécharge une seule URL avec deux profils généraux et un profil
supplémentaire réservé à YouTube :

- une **vidéo MKV complète**, avec les meilleures pistes vidéo et audio
  disponibles ;
- une **vidéo YouTube HLS authentifiée**, qui lit les cookies Firefox et
  remuxe le flux HLS sélectionné dans un conteneur MKV ;
- la **meilleure piste audio disponible**, en conservant son codec et son
  conteneur source lorsque yt-dlp peut le faire sans réencodage.

Le projet utilise `yt-dlp` pour l'extraction des médias, `aria2c` pour accélérer
les téléchargements directs éligibles via un fichier d'entrée aria2 privé et
FFmpeg pour fusionner, remuxer ou extraire les flux. HTTPS repasse
automatiquement sur le transport natif de yt-dlp lorsque le backend TLS d'aria2
n'offre pas le durcissement requis de validation des certificats. Les flux DASH
et HLS restent eux aussi natifs.
La version de développement actuelle est la **2.3.8**.
La dernière release de paquets publiée est la **2.3.8**.

## Installation recommandée

Ouvrez la [dernière release GitHub](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/latest).
Les noms exacts ci-dessous correspondent à la release v2.3.8 actuellement publiée.

Pour **Fedora 44**, téléchargez ces quatre fichiers :

```text
install-fedora.sh
RPM-GPG-KEY-OscarFrog
yt-dlp-aria2-downloader-gui-2.3.8-1.fc44.noarch.rpm
SHA256SUMS
```

Vérifiez les fichiers téléchargés puis lancez le bootstrap Fedora officiel :

```bash
sha256sum --ignore-missing --check SHA256SUMS
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.3.8-1.fc44.noarch.rpm
```

Le bootstrap authentifie et active RPM Fusion Free si nécessaire, remplace `ffmpeg-free` par
le `ffmpeg` complet de RPM Fusion, installe les paquets Fedora requis, installe
le RPM de l'application, vérifie le fournisseur de FFmpeg puis initialise les
runtimes yt-dlp et Deno propres à l'utilisateur.

Pour **Debian ou Ubuntu**, téléchargez le DEB versionné et `SHA256SUMS`,
vérifiez-les puis installez le paquet avec `sudo apt install
./yt-dlp-aria2-downloader-gui_2.3.8-1_all.deb`. Pour **les autres distributions
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
- reprise des téléchargements interrompus gérés nativement par yt-dlp lorsque le site le permet ;
- annulation orientée confidentialité pour les transferts HTTP(S) directs gérés
  par aria2 : l'état partiel privé est supprimé et une exécution ultérieure
  redémarre proprement ;
- repli HTTPS natif automatique pour les combinaisons aria2/GnuTLS concernées ;
- progression graphique unifiée pour les fichiers directs, les fragments
  HLS/DASH, les pistes vidéo/audio séparées et le post-traitement FFmpeg ;
- annulation de tout le groupe de processus au sein d’une session GUI unique ;
- supervision de yt-dlp et des commandes FFmpeg exécutées par le moteur, avec arrêt borné ;
- validation FFprobe des pistes vidéo et audio pour une vidéo complète, et
  d'une piste audio sans piste vidéo de contenu pour le mode audio, avant la
  publication du succès ;
- une seule instance en écriture par dossier de destination, afin
  d'empêcher le partage concurrent de fichiers partiels ou de
  post-traitement ;
- journaux privés conservés uniquement pour les exécutions problématiques, avec expurgation des URL et limite de 8 Mio ;
- lanceur dans le menu des applications ;
- tests statiques, mocks et intégrations hermétiques avec outils réels,
  notamment qualification audio directe AAC/Opus/source combinée, routage
  HLS/DASH, comportement aria2 contrôlé Range/no-Range/redirection/erreur/annulation-redémarrage-propre,
  progression FFmpeg réelle et stress des courses de processus, avec validation
  GitHub Actions sous Ubuntu et Fedora 44.

## Prérequis

Les commandes système requises par l'application sont :

- Bash **4.4 ou plus récent** ;
- `aria2c` **1.37.0 ou plus récent** ;
- Python **3.10 ou plus récent** ;
- FFmpeg et `ffprobe` ;
- Zenity pour l'interface graphique ;
- `ca-certificates`, `curl`, GnuPG et `unzip` pour l'initialisation et la mise
  à jour vérifiées des runtimes ;
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
dernier runtime vérifié reste actif. L'exécutable Linux officiel de yt-dlp
embarque ses dépendances Python compatibles, notamment `curl_cffi`, ainsi que
le support EJS embarqué utilisé par l'extraction YouTube actuelle.
Le gestionnaire renvoie une attestation versionnée unique avec les chemins et
versions validés ; le moteur ne répète donc pas la découverte des exécutables
et de leurs capacités pendant le même lancement.

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

Les paquets système comme Python, FFmpeg, aria2 et Zenity restent gérés par le
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
gh release verify v2.3.8 -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset v2.3.8 ./ARTEFACT -R OscarFrog/yt-dlp-aria2-downloader-gui
```

`SHA256SUMS` reste utile pour un contrôle local ou hors ligne ; les attestations
et l'immuabilité ajoutent la preuve de provenance et d'identité de release.

Après publication, un job séparé en lecture seule retélécharge la release
publique, reconstruit la charge utile attendue à partir des artefacts Actions
exacts ayant passé la qualification des paquets, compare chaque asset octet par
octet, revérifie `SHA256SUMS` et valide les attestations de release/assets
contre ce dépôt, `release.yml` et le commit exact du tag de release.

### Identité de signature RPM, environnement et rotation des clés

L'autorisation d'un RPM Fedora est volontairement plus stricte que le trousseau
RPM global de la machine. Le bootstrap valide l'empreinte exacte du certificat
primaire `7B54065FE061E78ED2C96252E3BE996196ABEA7F`, exige exactement une sous-clé
de signature utilisable et épingle celle-ci sur
`1F5B769CE48A08AAC0A7D9DDECC9894B41830245`. Il importe ensuite uniquement ce
certificat dans un trousseau RPM 6 privé de type `fs` et y vérifie le RPM, en
redirigeant également le verrou de transaction RPM dans la même racine
temporaire privée. Une clé déjà approuvée par la base RPM globale de la machine
ne peut donc pas autoriser le RPM du projet. Le job de signature contrôle
indépendamment les mêmes empreintes complètes, demande explicitement la
sous-clé exacte avec `rpmsign --key-id`, puis vérifie cryptographiquement le RPM
signé avant publication. La sortie RPM `OPENPGP:pgpsig` reste uniquement
diagnostique : sous Fedora 44 avec RPM 6.0.2, elle affiche un Key ID long et non
l'empreinte OpenPGP complète ; elle n'est donc pas utilisée pour prendre la
décision d'autorisation.

Le format du paquet RPM de production est explicitement figé en **RPM v4** et
vérifié avant et après la signature de release. La CI construit séparément un
fixture RPM v6 dédié afin de qualifier la sémantique multi-signature de RPM 6 ;
cela ne migre pas silencieusement le format du paquet de production vers v6.

L'environnement GitHub `rpm-signing` constitue une frontière de sécurité
opérationnelle et pas seulement un nom dans le workflow. Conservez
`RPM_SIGNING_PRIVATE_KEY_B64` et `RPM_SIGNING_PASSPHRASE` comme **secrets
d'environnement**. Le bundle privé doit être produit avec
`--export-secret-subkeys` de GnuPG : la clé privée primaire reste hors ligne et
n'est importée que comme stub `sec#`, tandis que la sous-clé de signature dédiée
reste utilisable. Configurez un réviseur obligatoire et désactivez le
contournement administrateur. Pour un dépôt volontairement exploité par un
**mainteneur unique**, le seul réviseur peut également être l'auteur du
déclenchement : `prevent_self_review` reste donc désactivé par conception. Le
preflight mainteneur exige alors la confirmation explicite
`--confirm-single-maintainer-self-review` et vérifie que l'unique réviseur
correspond au compte GitHub authentifié. Limitez l'environnement à une politique
de déploiement **tag** sélectionnée `v*`. La reprise manuelle reste disponible,
mais elle doit exécuter le workflow depuis le tag exact de la release :

```bash
gh workflow run release.yml   --ref v2.3.8   -f tag=v2.3.8   -R OscarFrog/yt-dlp-aria2-downloader-gui
```

Le workflow refuse indépendamment toute exécution manuelle dont le type de ref,
le nom de ref ou le commit source ne correspond pas au tag de release demandé.

La sous-clé de signature actuelle expire le **21 août 2027**. Sa rotation doit
être préparée avant cette date. Pour une rotation normale sous le même
certificat primaire, publiez le certificat public actualisé, remplacez
l'empreinte de sous-clé épinglée dans le code, le workflow et les tests,
actualisez le secret de signature de l'environnement, puis imposez toute la
qualification Fedora positive et négative avant le tag suivant. En cas de
compromission de la sous-clé, arrêtez les releases, révoquez-la, remplacez le
secret d'environnement, publiez le certificat actualisé et ne reprenez les
releases qu'après épinglage de la nouvelle empreinte. Si le certificat primaire
est compromis, une nouvelle empreinte primaire est obligatoire : aucun
remplacement silencieux du certificat primaire n'est accepté.

## Installation par paquet

Les releases GitHub publient un RPM Fedora, un DEB Debian/Ubuntu, l'archive
ZIP portable, le bootstrap Fedora, la clé publique OpenPGP de signature RPM
et un fichier `SHA256SUMS` commun. Les paquets
RPM et DEB installent les commandes, l’icône dédiée et le lanceur graphique au
niveau du système. Aucune exécution séparée de `install-gui.sh` n’est nécessaire
avec une installation par paquet.

Avant de migrer depuis une installation ZIP ou Git, supprimez l'ancien lanceur
utilisateur afin qu'il ne masque pas l'entrée installée par le paquet :

```bash
./install-gui.sh uninstall
```

### Fedora 44

Utilisez `install-fedora.sh` provenant de la même release GitHub que le RPM.
N'installez pas directement le RPM sur une Fedora fraîche : RPM Fusion doit
être activé avant que DNF ne résolve la dépendance `ffmpeg`.

Téléchargez :

```text
install-fedora.sh
RPM-GPG-KEY-OscarFrog
yt-dlp-aria2-downloader-gui-2.3.8-1.fc44.noarch.rpm
SHA256SUMS
```

Vérifiez tous les fichiers téléchargés :

```bash
sha256sum --ignore-missing --check SHA256SUMS
```

Puis lancez :

```bash
bash ./install-fedora.sh ./yt-dlp-aria2-downloader-gui-2.3.8-1.fc44.noarch.rpm
```

Le bootstrap refuse par défaut un RPM de release non signé. Il vérifie que
`RPM-GPG-KEY-OscarFrog` contient exactement un certificat primaire d'empreinte
`7B54065FE061E78ED2C96252E3BE996196ABEA7F` ainsi que la sous-clé de signature dédiée
`1F5B769CE48A08AAC0A7D9DDECC9894B41830245`. Il importe ensuite uniquement ce
certificat dans un trousseau RPM 6 temporaire privé de type `fs` et exige que
`rpmkeys --checksig` valide le paquet dans ce domaine de confiance isolé. Les
chaînes d'affichage RPM comme `OPENPGP:pgpsig` restent uniquement diagnostiques
et ne servent pas de primitive d'autorisation. Avant tout import système ou
toute transaction de paquet, le bootstrap copie le certificat et le RPM via
`sudo` dans une zone privée appartenant à root. Il répète sur ces copies
l'identité exacte du paquet, les empreintes du certificat et la vérification de
signature isolée ; l'import système et DNF utilisent ensuite uniquement ces
mêmes chemins privés appartenant à root. Le remplacement des fichiers
utilisateur d'origine après leur copie ne peut donc plus modifier la transaction
autorisée.
DNF répète indépendamment la vérification avec
`localpkg_gpgcheck=True`. Une autre clé déjà approuvée dans la base RPM de la
machine ne peut donc pas autoriser le RPM du projet. L'option
`--allow-unsigned-dev` reste réservée explicitement aux builds locaux/CI de
développement et n'est jamais utilisée pour une release.

Sur une Fedora 44 fraîche, le bootstrap RPM Fusion suit le même modèle fermé
avant toute exécution par DNF sous root. L'installateur télécharge la clé et le
RPM de release via TLS contraint, exige l'empreinte RPM Fusion exacte
`E9A491A3DE247814E7E067EAE06F8ECDD651FF2E`, vérifie la signature dans un
trousseau isolé et exige le NEVRA audité
`rpmfusion-free-release-44-3.noarch`. Toute version Fedora sans pin explicite
est refusée jusqu'à sa qualification. Le certificat et le RPM de bootstrap RPM
Fusion franchissent la même frontière de staging appartenant à root et y sont
revérifiés avant tout import ou installation privilégiés.

Le bootstrap :

- authentifie et active RPM Fusion Free s'il est absent ;
- remplace `ffmpeg-free` par le `ffmpeg` RPM Fusion lorsque nécessaire ;
- installe les dépendances système requises ;
- vérifie la clé OpenPGP de signature RPM OscarFrog épinglée et la signature du RPM ;
- active le contrôle OpenPGP DNF du RPM local de release ;
- installe le RPM de l'application ;
- vérifie que `ffmpeg` provient de RPM Fusion et que `ffmpeg-free` est absent ;
- initialise et valide les runtimes yt-dlp stable et Deno stable pour
  l'utilisateur courant.

Le RPM lui-même ne télécharge aucun runtime tiers depuis un scriptlet RPM.
Les téléchargements de runtimes sont effectués dans le contexte non privilégié
de l'utilisateur et vérifiés avant activation.

### Debian et Ubuntu

La dernière release publiée, la 2.3.8, fournit un DEB indépendant de
l'architecture, aligné sur le même modèle de runtimes gérés que Fedora.
Téléchargez :

```text
yt-dlp-aria2-downloader-gui_2.3.8-1_all.deb
SHA256SUMS
```

Vérifiez puis installez :

```bash
sha256sum --ignore-missing --check SHA256SUMS
sudo apt install ./yt-dlp-aria2-downloader-gui_2.3.8-1_all.deb
```

Le DEB dépend explicitement d'`aria2`, de Python 3.10+, de FFmpeg/FFprobe,
de Zenity, des certificats CA, de curl, GnuPG, unzip et du thème d'icônes
hicolor. GNU coreutils, grep, findutils, sed et util-linux sont fournis par la
base Essential de Debian/Ubuntu et ne sont pas redéclarés inutilement comme
dépendances non versionnées. Le DEB
**ne dépend pas de paquets yt-dlp ou Deno fournis par la distribution**. yt-dlp
et Deno sont installés et vérifiés dans le runtime de l'utilisateur au premier
lancement.

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

Sous Fedora, une **désinstallation finale du RPM** continue d'effectuer un
nettoyage best-effort du runtime géré propre à chaque utilisateur ainsi que des
artefacts XDG historiques portant exactement le nom
`yt-dlp-aria2-downloader-gui`, pour les utilisateurs dont le dossier personnel
est disponible. Une mise à niveau du RPM ne déclenche pas ce nettoyage.

Sous Debian/Ubuntu, `apt remove` et `apt purge` suppriment le payload système du
paquet mais préservent volontairement les runtimes, la configuration, l'état et
le cache propres à chaque utilisateur. Une réinstallation reste ainsi non
destructive et aucun script du gestionnaire de paquets ne parcourt les dossiers
personnels.

Le nettoyage Fedora repose volontairement sur une liste blanche de chemins. Il
supprime le runtime géré sous
`${XDG_DATA_HOME:-$HOME/.local/share}/yt-dlp-aria2-downloader/runtime/` et les
anciens chemins `yt-dlp-aria2-downloader-gui` connus dans les emplacements XDG
de données, configuration, état et cache. Il ne recherche pas récursivement
dans le dossier personnel tous les fichiers dont le nom ressemble à celui du
paquet.

Pour le nettoyage RPM, à partir de la 2.1.27, le gestionnaire de runtime
enregistre le `XDG_DATA_HOME` réellement utilisé afin qu'une désinstallation ultérieure
puisse aussi retrouver un emplacement de données personnalisé. Un emplacement
XDG personnalisé utilisé uniquement par une ancienne version et jamais observé
par la 2.1.27 ne peut pas être reconstitué automatiquement de manière sûre.

À partir de la 2.1.29, la racine de données personnalisée reçoit également une
preuve de propriété privée qui lie l'identifiant de l'application, l'UID, HOME
et la racine de données réellement utilisée. La désinstallation finale ne suit
un marker personnalisé que s'il contient exactement une seule ligne avec un
chemin absolu et si la preuve régulière `0600` correspondante existe et
appartient à l'utilisateur cible. La seule modification du marker ne peut donc
plus autoriser une suppression dans une autre racine XDG.
 Le nettoyage refuse également les composants parents
symboliques sous la racine XDG autorisée : un chemin ambigu est préservé au
lieu d'être traversé par une suppression récursive. Après une mise à
niveau depuis la 2.1.27/2.1.28, une exécution du gestionnaire de runtime 2.1.29
crée automatiquement cette preuve. Si la 2.1.29 est supprimée avant cette
migration, l'ancienne racine personnalisée est conservée par prudence au lieu
d'être supprimée.

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
yt-dlp-aria2-downloader-gui-2.3.8.zip
SHA256SUMS
```

Vérifiez puis extrayez l'archive :

```bash
sha256sum --ignore-missing --check SHA256SUMS
unzip yt-dlp-aria2-downloader-gui-2.3.8.zip
cd yt-dlp-aria2-downloader-gui-2.3.8
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
Pour garantir le confinement, l'installateur portable exige un
`XDG_DATA_HOME` appartenant à l'utilisateur courant et non inscriptible par le
groupe ou les autres utilisateurs ; il refuse aussi tout lien symbolique à la
racine ou dans un composant parent. Le chemin de données doit aussi être en
UTF-8 valide et pouvoir être représenté sans ambiguïté dans une clé `Exec` de
fichier desktop. Il conserve des descripteurs sans suivi de liens pendant toute
la transaction : un remplacement concurrent du chemin ne peut donc pas
rediriger l'installation, le retrait ou le nettoyage.
Les demandes concurrentes d'installation et de retrait portables sont
sérialisées. Après l'échec d'une mise à jour multifichier, le helper tente de
restaurer l'état précédent du lanceur avant de signaler l'erreur principale et
tout échec de rollback. La cible graphique exécutable est revalidée avant tout
succès. HUP, INT et TERM déclenchent également ce nettoyage transactionnel avant
que la commande retourne respectivement le statut 129, 130 ou 143.

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

L'interface classe l'hôte normalisé de l'URL avant d'afficher ce menu. Elle
propose toujours :

- **Complete video (MKV)** télécharge les meilleures pistes vidéo et audio
  disponibles, puis les rassemble dans un conteneur MKV ;
- **Audio track (native format)** télécharge la meilleure piste audio disponible
  en conservant son format natif chaque fois que cela est possible.

Pour `youtube.com`, `youtu.be`, `youtube-nocookie.com` et leurs sous-domaines,
elle propose aussi **YouTube video - Firefox cookies (HLS/MKV)**. Ce mode de
repli authentifié lit la session Firefox locale, télécharge un flux HLS puis le
remuxe en MKV. Il n'apparaît jamais pour un autre hôte. Si ce profil a été
mémorisé lors d'un téléchargement YouTube, une requête non-YouTube suivante
sélectionne **Complete video (MKV)** à sa place.


### 3. Choisir le dossier de destination

Sélectionnez le dossier dans lequel le média téléchargé sera enregistré.
Pour protéger le staging privé, chaque ancêtre physique doit appartenir au
système ou à l'utilisateur courant ; tout ancêtre accessible en écriture au
groupe ou aux autres utilisateurs doit être protégé par le sticky bit (comme
`/tmp` normalement). L'application refuse un dossier partagé dangereux avant
d'y écrire une URL, un cookie, un fichier partiel ou un média.


### 4. Suivre la progression

La fenêtre de progression indique l’étape actuelle du téléchargement ou du post-traitement. Le remuxage FFmpeg géré par le moteur utilise la sortie de progression machine de FFmpeg et la durée de la source, et non un compteur artificiel. Le bouton d'annulation permet d'arrêter l'ensemble du
processus.


### 5. Résultat du téléchargement

Après un téléchargement réussi, l'interface affiche le chemin du fichier
multimédia terminé. **Open folder** ouvre son dossier de destination, **New
download** lance une nouvelle demande et **Close** termine la session. Dans le
cas exceptionnel où un journal de réussite n'a pas pu être supprimé mais où une
copie expurgée sûre existe, **View log** l'ouvre puis rend de nouveau accessibles
ces actions de fin.


Lorsqu'une erreur survient après la création d'un diagnostic utile du worker ou
de la progression, l'interface conserve un journal expurgé et propose **View
log** et **Close**. Cela couvre notamment le démarrage du worker, le runtime, le
téléchargeur, le moniteur de progression, le post-traitement et la validation
du résultat final.

Lorsque Zenity lui-même renvoie des détails techniques utiles avant qu'une
session de téléchargement existe, les mêmes actions **View log** et **Close**
ouvrent un diagnostic temporaire privé et borné. Ce diagnostic est supprimé
immédiatement après la boîte de dialogue ; il n'est pas présenté comme un
journal conservé persistant.


Le journal conservé peut être ouvert directement depuis la fenêtre d’erreur.
Avant sa conservation, les valeurs ressemblant à des URL sont remplacées par
`[REDACTED_URL]` et seule la portion tenant dans la limite finale de 8 Mio est
gardée. Une section clairement identifiée à la fin indique le nom exact du
fichier conservé et son chemin absolu canonique ; elle survit donc à la
troncature du journal source et désigne toujours le fichier ouvert par **View
log**. Le journal actif reste privé (`0600`) pendant l’exécution et n'est jamais
proposé comme solution de repli si la sanitisation sûre échoue. Les erreurs de
saisie et les autres échecs précoces sans diagnostic utile restent de simples
messages d'erreur.



### Confidentialité des URL dans l’interface graphique

La GUI écrit l’URL demandée dans un fichier temporaire privé et ne transmet au
moteur que le chemin de ce fichier. Le moteur fournit ensuite l’URL à yt-dlp via
son fichier batch privé. Pour un média HTTP(S) direct, les URL et en-têtes
validés sont écrits dans un fichier d'entrée aria2 privé `0600` : l'URL média
n'apparaît donc pas dans les arguments d'`aria2c`. Les URL contenant
`utilisateur:motdepasse@hôte` sont refusées. L’utilisation CLI directe avec une
URL positionnelle reste possible ; comme pour toute commande, cette URL peut
alors être visible dans les arguments du processus appelant.

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
Les fichiers `.part` gérés nativement par yt-dlp peuvent toujours être repris
lorsque l'amont le permet. Le staging aria2 des transferts HTTP(S) directs gérés
par le moteur est volontairement éphémère : une annulation utilisateur supprime
son état partiel/contrôle privé et une exécution ultérieure redémarre le
transfert direct proprement. Un média terminé ou post-traité déjà présent est
conservé et l'exécution échoue au lieu de le remplacer.

Le modèle de sortie limite le titre et l'identifiant du média selon leur taille
encodée en octets, ce qui réduit les échecs avec de longs titres Unicode sur les
systèmes de fichiers limitant un composant de chemin à 255 octets.

## Fonctionnement des téléchargeurs

Le moteur demande d'abord à yt-dlp de planifier les formats sélectionnés sans
télécharger le média. Les plans HTTP(S) directs représentables et sûrs à rejouer
sont transférés par aria2c via des fichiers privés d'entrée, manifeste, cookies
et staging. Les plans dont l'URL média contient une composante URI userinfo, ou dont les
en-têtes exigent un contexte non rejouable de façon sûre comme Referer, Cookie,
Authorization, une autorisation proxy ou un autre en-tête hors liste sûre,
restent sur le transport natif de yt-dlp. FTP et les autres protocoles non HTTP(S)
restent
également natifs. DASH et HLS sont explicitement conservés sur le téléchargeur
natif :

```text
--downloader dash,m3u8:native
aria2c --input-file=/privé/aria2.input --dir=/privé/staging ...
```

Cette architecture conserve l'accélération multi-connexion d'aria2c pour les
médias HTTP(S) directs validés sans placer l'URL média dans les arguments du
processus aria2c.

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

Dans l'état actuel d'upstream yt-dlp, les formats HLS de `web_safari` n'exigent
pas de GVS PO Token, mais depuis 2026.07 YouTube ne renvoie ces formats HLS que
pour certaines sessions connectées ou « trusted ». Ce comportement upstream
peut évoluer indépendamment du projet.

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

Journaux de diagnostic de la GUI :

```text
~/.local/state/yt-dlp-aria2-downloader/download-*.log
```

Le journal actif du processus est créé en mode `0600` dans le dossier
temporaire d’exécution privé, puis supprimé après un succès. Lorsqu’une
exécution échouée, annulée, interrompue ou incohérente a produit un journal
actif non vide et utile, seule une copie de diagnostic expurgée est publiée
dans le dossier d’état. Les valeurs ressemblant à des URL sont remplacées, le
contenu et les métadonnées d’identité finales restent ensemble dans la limite de
8 Mio, et le fichier obtenu conserve le mode `0600`. Sa section finale donne le
basename `download-*.log` exact et son chemin absolu canonique. Les journaux de
diagnostic conservés depuis plus de 15 jours sont supprimés automatiquement
lors de la prochaine préparation d’une session de téléchargement graphique.

Un verrou consultatif par utilisateur et par dossier de destination est
conservé sous le chemin canonique
`$XDG_RUNTIME_DIR/yt-dlp-aria2-downloader` lorsque toute sa chaîne physique est
sûre et que le dossier d'exécution est privé et appartient à l'utilisateur
courant. Sinon, le moteur utilise le repli privé revalidé
`/tmp/yt-dlp-aria2-downloader-UID`. Les fichiers de verrou ne contiennent ni
URL, ni cookie, ni chemin de média, et le noyau libère automatiquement le
verrou à la fin du moteur. Des téléchargements vers des dossiers différents
peuvent s'exécuter simultanément.

## Tests

Consultez le
[guide de test](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/TESTING.md)
du dépôt pour les validations locales, les contrôles spécifiques à Fedora et
les tâches GitHub Actions.

## Désinstallation d'un lanceur portable

Pour un lanceur installé depuis une archive ZIP portable ou un checkout Git,
exécutez cette commande depuis le dossier source correspondant :

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

Ce projet est distribué sous licence MIT. Consultez la
[licence du dépôt](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/blob/main/LICENSE).
