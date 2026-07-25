# Rapport de validation — version 2.1.5

Date : 25 juillet 2026

## Objet de la modification

La version 2.1.5 conserve le mode audio natif et le correctif Zenity de la version 2.1.2. Elle corrige aussi la détection des options aria2c lorsque l’aide utilise des arguments booléens facultatifs entre crochets, par exemple `--no-conf[=true|false]`. Elle utilise toujours un seul mode
**piste audio native de meilleure qualité**. Sa construction `yt-dlp` reprend le
script `download-audio.sh` fourni :

```text
--format ba/b
--extract-audio
--audio-format best
--audio-quality 0
```

## Vérifications automatisées

- `bash -n` sur tous les scripts livrés ;
- erreurs d’arguments et retrait effectif de `--audio-format` et
  `--audio-quality` de l’interface publique ;
- mode audio avec `ba/b`, format `best` et qualité `0` ;
- absence de valeur forcée `mp3`, `m4a` ou `opus` ;
- mode vidéo MKV inchangé ;
- migration et sauvegarde du profil graphique unique `audio` ;
- URL contenant des métacaractères shell ;
- dossier et fichier de résultat contenant `%` ;
- progression `yt-dlp` et `aria2c` ;
- annulation et terminaison du groupe de processus ;
- erreurs et expiration Zenity ;
- absence de `--ok-label` et `--cancel-label` dans les boîtes de sélection de dossier ;
- reprise automatique du sélecteur de dossier sans `--filename` lorsque la présélection échoue ;
- conservation et affichage du diagnostic stderr de Zenity en cas de double échec ;
- versions minimales de `yt-dlp`, Deno et `aria2c` ;
- installation et désinstallation du lanceur `.desktop`.

Commandes à exécuter :

```bash
./test-static.sh
./tests/mock-integration.sh
./tests/installer-integration.sh
```

## Contrôles restant à faire sur Fedora

```bash
shellcheck -o all download-video.sh download-video-gui.sh install-gui.sh
shellcheck test-static.sh tests/*.sh
```

Puis réaliser deux essais légaux réels : une vidéo MKV et une piste audio. Le
fichier audio obtenu doit conserver le meilleur format proposé par la source,
sans extension imposée par l’interface.

## Stabilisation complète des sondes — version 2.1.5

Les sorties interrogées pour vérifier les versions et les capacités sont
désormais générées sous la locale `C` :

- `yt-dlp --version` ;
- `yt-dlp --help` ;
- `deno --version` ;
- `aria2c --version` ;
- `aria2c --help=#all` ;
- `setsid --help`.

Le worker réel reste également lancé avec `LC_ALL=C`. Les fenêtres Zenity ne
sont pas concernées par cette affectation et restent dans la locale de la
session graphique.
