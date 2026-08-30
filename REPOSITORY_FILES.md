# Inventaire et utilité des fichiers du dépôt

Ce document est l’inventaire technique courant du dépôt. Il ne vise aucune
ancienne version applicative comme état de référence. Sa table est contrôlée
contre l’arbre Git courant et décrit la raison durable de conserver chaque
chemin.

Le document a été créé en français parce que la revue exhaustive initiale et
ses libellés obligatoires ont été demandés en français. Seuls les chemins de la
table sont consommés mécaniquement ; la langue de cette documentation technique
n’établit pas une seconde source de vérité parallèle aux documents utilisateur.

## Inventaire exact

La première colonne de la table ci-dessous contient exactement les **83**
chemins tracked. `test-static.sh` la compare mécaniquement à `git ls-files` ;
dans une archive sans `.git`, il la compare à l’arbre de fichiers de l’archive.
Un ajout, retrait ou renommage tracked exige donc une mise à jour explicite de
ce document.

## Pourquoi l’en-tête Python est différent

`private-aria2-plan.py` est installé en mode `0644`, n’est pas une commande
publique et est invoqué explicitement par `download-video.sh` avec `python3`.
L’absence de shebang est donc volontaire : en ajouter un créerait à tort une
interface exécutable directe. En Python, un identifiant SPDX suivi d’un
docstring de module constitue une structure plus idiomatique que le bandeau de
commentaires destiné aux exécutables Bash.

Cette différence est cohérente avec `SHELL_STYLE.md`, car son bandeau canonique
ne s’applique qu’aux fichiers de `ALL_SHELL_FILES`. La règle était toutefois
insuffisamment explicite : le module décrivait bien sa confidentialité, son rôle
et son mode d’appel, mais le projet et le chemin du fichier n’étaient ni exigés
ni validés. La passe a donc conservé la structure Python, ajouté l’identité du
projet et du module au docstring, documenté la frontière entre formats dans
`AGENTS.md` et `SHELL_STYLE.md`, créé `PYTHON_FILES`, et ajouté une validation
SPDX/docstring par l’AST. Copier le bandeau Bash ou ajouter un shebang aurait été
une fausse uniformisation.

`private-launcher-manager.py` suit la même identité Python sans shebang. Il
reste toutefois propre au ZIP et au checkout Git : `install-gui.sh` l’appelle
explicitement avec `python3` pour ancrer les transactions du launcher portable
sur des descripteurs de répertoire, et les paquets système ne l’installent pas.

Les autres formats utilisent leur mécanisme natif : titre Markdown, champ
`name` d’un workflow, métadonnées RPM/Debian, section `NAME` des manpages,
champs Desktop Entry ou identité cryptographique OpenPGP. `LICENSE` et le
copyright Debian portent la licence globale lorsque le format ne reçoit pas un
commentaire SPDX synthétique.

## Méthode et lecture de la table

Pour chaque chemin, la revue a croisé l’historique Git, les références
textuelles, `source` et imports, appels directs, workflows, payloads RPM/DEB/ZIP,
tests et fixtures, documentation, manpages, publication, upgrade depuis la
release immuable précédente, cleanup, récupération après crash et compatibilité
historique. Les colonnes condensent les vingt questions de la revue :

- `Rôle`, `Utilisé par` et `Nécessaire ?` indiquent la fonction exacte, les
  consommateurs, le domaine qui en dépend, l’installation éventuelle et la
  raison précise de conservation ;
- `Contenu correct ?` couvre l’exactitude, le nom, l’en-tête, les commentaires,
  les versions et références obsolètes ;
- `Historique ?` distingue documentation actuelle, compatibilité volontaire et
  journal historique, et dit si cette dette reste nécessaire ;
- `Redondant ?` compare les responsabilités proches et les refactorings récents ;
- `Action` répond à la possibilité de retrait. Aucun retrait n’est proposé sans
  preuve couvrant toutes les surfaces citées ci-dessus.

Les versions courante et publiée sont contrôlées par les validations statiques
et de release plutôt que figées ici. Les mentions 2.1.27–2.1.29 restent
justifiées par la migration et le nettoyage de données. Les autres anciennes
versions restent confinées au `CHANGELOG`, au changelog RPM ou à des fixtures
de compatibilité explicites.

| Fichier | Type | Rôle | Utilisé par | Nécessaire ? | Contenu correct ? | Historique ? | Redondant ? | Action |
| ------- | ---- | ---- | ----------- | ------------ | ----------------- | ------------ | ----------- | ------ |
| `.agents/skills/packaging-release/SKILL.md` | Skill Codex | Route les travaux RPM, DEB, installation, cleanup, version et release vers les contrats et validations adaptés | Codex lors des tâches packaging/release | Oui — procédure contributive à chargement progressif, présente dans le ZIP source mais non installée par les paquets | Oui — n’accorde aucune autorité implicite de signature ou publication | Non | Non, orchestre sans recopier `TESTING.md` | KEEP |
| `.agents/skills/shell-change/SKILL.md` | Skill Codex | Route toute modification ou revue Shell vers le style, l’architecture, les inventaires et les validations canoniques | Codex lors des tâches Bash ou blocs Shell de workflows | Oui — procédure contributive à chargement progressif, présente dans le ZIP source mais non installée par les paquets | Oui — `SHELL_STYLE.md` reste l’unique politique détaillée | Non | Non, ne duplique pas les règles Shell | KEEP |
| `.agents/skills/workflow-supply-chain/SKILL.md` | Skill Codex | Route les changements GitHub Actions, pins, provenance et frontières privilégiées | Codex lors des tâches CI/supply chain | Oui — procédure contributive à chargement progressif, présente dans le ZIP source mais non installée par les paquets | Oui — distingue édition, qualification et mutation externe autorisée | Non | Non, complète le routeur racine | KEEP |
| `.codex/rules/default.rules` | Politique Codex mécanique | Demande confirmation pour Git, GitHub CLI et wrappers d’environnement hors sandbox, et interdit les formes usuelles de force-push vers `main` | Codex dans un projet approuvé, `test-static.sh`, mainteneurs | Oui — garde-fou contributif présent dans le ZIP source mais non installé par RPM/DEB | Oui — chaque règle porte une décision explicite, des exemples validés et les refspecs `main` courantes sont couvertes | Non | Non, rend mécaniques certaines limites d’`AGENTS.md` sans accorder d’autorité | KEEP |
| `.editorconfig` | Configuration éditeur | Fixe UTF-8/LF et les paramètres shfmt/Python | Éditeurs, shfmt, `test-static.sh` | Oui — cohérence de contribution | Oui — sections Shell et Python alignées | Non | Non, complète les validateurs | KEEP |
| `.github/ISSUE_TEMPLATE/codex-task.yml` | Formulaire GitHub | Cadre objectif, preuves, critères, périmètre, invariants, validation et autorité externe d’une tâche agent | Contributeurs, Codex, GitHub Issues, `test-static.sh` | Oui — qualité des demandes, présent dans le ZIP source mais non installé par RPM/DEB | Oui — champs structurés et avertissement explicite contre les secrets | Non | Non, structure l’entrée de travail plutôt que la politique du dépôt | KEEP |
| `.github/pull_request_template.md` | Modèle GitHub | Exige résumé, risques, validations réelles, autorité/mutations externes et contrôles de cohérence avant revue | Contributeurs, GitHub Pull Requests, `test-static.sh` | Oui — revue et livraison, présent dans le ZIP source mais non installé par RPM/DEB | Oui — possède une section explicite pour l’autorité accordée et les mutations réellement exécutées | Non | Non, transforme la Definition of Done en preuve par PR | KEEP |
| `.github/workflows/packages.yml` | GitHub Actions | Construit et qualifie RPM/DEB, cycle de vie et upgrade | GitHub Actions, release policy | Oui — packaging/CI | Oui — actions épinglées, permissions minimales, release précédente authentifiée | Compatibilité d’upgrade volontaire | Non, distinct de la publication | KEEP |
| `.github/workflows/qualification.yml` | GitHub Actions | Qualifie plusieurs générations FFmpeg/FFprobe | GitHub Actions, helper de preuve étendue | Oui — qualification étendue | Oui — matrices 6.1.1/8.1.2/9.0.1 intentionnelles | Compatibilité générationnelle actuelle | Non | KEEP |
| `.github/workflows/real-tools.yml` | GitHub Actions | Exécute les scénarios avec vrais outils et le stable hebdomadaire | GitHub Actions, preuve post-release | Oui — intégration réelle | Oui — pins reproductibles et stable planifié distingués | Pins anciens conservés comme bornes de qualification | Non | KEEP |
| `.github/workflows/release.yml` | GitHub Actions | Valide, signe, publie, rend immuable et revérifie une release | Tags `v*`, dispatch de récupération, helper de preuve | Oui — release | Oui — séparation des secrets, attestations et inventaire exact | Compatibilité d’upgrade volontaire | Non, seule surface de publication | KEEP |
| `.github/workflows/shell.yml` | GitHub Actions | Lance la suite canonique sur Ubuntu et Fedora | Pull requests, pushes `main` | Oui — CI principale | Oui — environnements et commandes cohérents | Non | Non | KEEP |
| `.github/workflows/shfmt-update.yml` | GitHub Actions | Prépare, vérifie et publie une mise à jour du pin shfmt | Planification, dispatch, pin shfmt | Oui — maintenance formatter/supply chain | Oui — candidat isolé et publisher data-only | Non | Non | KEEP |
| `.github/workflows/stress.yml` | GitHub Actions | Répète les scénarios sensibles aux races et au cleanup | Pull requests, pushes `main` | Oui — stress CI | Oui — répétitions bornées et indépendantes | Non | Non, complète la suite fonctionnelle | KEEP |
| `.gitignore` | Configuration Git | Exclut médias, temporaires, caches, preuves locales et artefacts | Git | Oui — hygiène et confidentialité locale | Oui — inclut caches Python et `qualification-evidence/` | Non | Non | KEEP |
| `AGENTS.md` | Politique technique | Route les agents vers les sources de vérité et fixe invariants, règles de revue, validation et limites de livraison | Agents, revue Codex, `test-static.sh`, skills du dépôt | Oui — gouvernance des changements | Oui — plus concis, sans recopier les procédures spécialisées | Non | Non, route vers les politiques spécialisées | KEEP |
| `ARCHITECTURE.md` | Documentation technique | Cartographie les composants, flux, processus, données privées, packaging, CI et frontières de confiance | `AGENTS.md`, skills, mainteneurs et agents | Oui — compréhension technique courante, présente dans le ZIP source mais non installée par RPM/DEB | Oui — dérivée des implémentations, tests et workflows actuels | Non | Non, complète l’inventaire par une vue relationnelle | KEEP |
| `CHANGELOG.md` | Documentation historique | Journal chronologique des releases et décisions | Utilisateurs, packaging, release, audit de versions | Oui — documentation/release | Oui — 2.3.5 courant et entrées anciennes figées | Oui — valeur historique explicite | Non, ne remplace pas les docs courantes | KEEP — HISTORIQUE |
| `LICENSE` | Licence | Texte MIT du projet | Utilisateurs, README, RPM | Oui — juridique | Oui — texte MIT complet | Non | Non | KEEP |
| `README.fr.md` | Documentation utilisateur | Guide utilisateur français complet | Utilisateurs, packages, ZIP, release | Oui — documentation installée | Oui — parité fonctionnelle et versions 2.3.5/2.3.4 | Compatibilité cleanup documentée et justifiée | Non, traduction maintenue | KEEP |
| `README.md` | Documentation utilisateur | Guide utilisateur anglais de référence | Utilisateurs, packages, ZIP, release | Oui — documentation installée | Oui — exigences, paquets et assets publics vérifiés | Compatibilité cleanup documentée et justifiée | Non | KEEP |
| `REPOSITORY_FILES.md` | Documentation technique | Inventorie le rôle et la conservation de chaque fichier tracked | `AGENTS.md`, `test-static.sh`, mainteneurs | Oui — traçabilité active de l’arbre | Oui — couverture exacte validée | Non, inventaire courant et non rapport de version | Non | KEEP |
| `SHELL_STYLE.md` | Politique technique | Contrat Bash, shfmt, ShellCheck et frontières d’en-tête | Tous les Shell, agents, tests | Oui — développement/CI | Oui — périmètre Bash et différence Python explicites | Non | Non | KEEP |
| `TESTING.md` | Documentation technique | Procédures locales, CI, packaging, release et qualifications manuelles | Mainteneurs, README, agents | Oui — validation | Oui — profils, matrices CI, Zenity réel et preuve post-release alignés | Non | Non | KEEP |
| `download-video-gui.sh` | Bash production | Interface Zenity et supervision d’une session | Desktop entry, launcher, package, tests GUI | Oui — exécution GUI, installé | Oui — rôle/en-tête/options cohérents | Compatibilité de configuration testée | Non, sépare UI et moteur | KEEP |
| `download-video.sh` | Bash production | Moteur CLI pour une URL, média et publication finale | GUI, launchers, packages, tests réels/mocks | Oui — cœur d’exécution, installé | Oui — version 2.3.5 et interface/manpage alignées | Récupération de staging ancien volontaire | Non | KEEP |
| `install-fedora.sh` | Bash installation | Authentifie puis installe RPM et dépendances Fedora | Utilisateurs, packages/release CI, tests auth | Oui — installation Fedora | Oui — clés/fingerprints et chemin dev non signé contrôlés | Compatibilité RPM volontaire | Non | KEEP |
| `install-gui.sh` | Bash installation | Installe ou retire le launcher portable par utilisateur | Utilisateurs Git/ZIP, tests installer | Oui — installation portable | Oui — desktop, icône, modes et cleanup cohérents | Nettoyage d’anciens artefacts volontaire | Non, distinct des paquets système | KEEP |
| `packaging/deb/build-deb.sh` | Bash packaging | Construit et valide le DEB `all` reproductible | Workflows packages/release | Oui — packaging DEB | Oui — payload, dépendances et exclusion du cleanup RPM exacts | Non | Non | KEEP |
| `packaging/deb/copyright` | Métadonnée Debian | Déclare source, copyright et licence du DEB | `build-deb.sh`, dpkg | Oui — conformité Debian | Oui — couvre tous les fichiers sous MIT | Non | Non, format Debian requis | KEEP |
| `packaging/deb/test-package-lifecycle.sh` | Bash qualification paquet | Teste install/remove/purge/réinstallation DEB réels | Workflows packages/release | Oui — CI packaging privilégiée | Oui — payload privé et préservation utilisateur contrôlés | Compatibilité de cycle de vie volontaire | Non | KEEP |
| `packaging/deb/test-package-upgrade.sh` | Bash qualification paquet | Teste upgrade du DEB immuable précédent vers courant | Workflows packages/release | Oui — compatibilité release | Oui — versions et artefacts sont fournis dynamiquement | Oui — compatibilité d’upgrade nécessaire | Non | KEEP — COMPATIBILITÉ |
| `packaging/icons/yt-dlp-aria2-downloader.svg` | SVG | Icône scalable du launcher système | `install-tree.sh`, packages, desktop | Oui — UI/packaging, installée | Oui — nom et identifiant cohérents | Non | Non, seule icône actuelle | KEEP |
| `packaging/install-tree.sh` | Bash packaging | Assemble l’arbre commun RPM/DEB sous DESTDIR | Spec RPM, build DEB, test packaging | Oui — packaging | Oui — modes, symlinks, docs, manpages et privé exacts | Non | Non, mutualise les deux formats | KEEP |
| `packaging/keys/RPM-GPG-KEY-OscarFrog` | Clé publique OpenPGP | Certificat public de signature des RPM | Release, preflight, asset public, installation Fedora | Oui — authentification supply chain | Oui — fingerprint primaire et sous-clé attendus | Rotation future, pas dette actuelle | Non, domaine de confiance RPM distinct | KEEP |
| `packaging/keys/yt-dlp-public.key` | Clé publique OpenPGP | Vérifie les exécutables officiels yt-dlp gérés | `runtime-manager.sh`, packages | Oui — bootstrap runtime, installée | Oui — fingerprint épinglé attendu | Compatibilité de vérification actuelle | Non, clé upstream distincte | KEEP |
| `packaging/man/yt-dlp-aria2-downloader-gui.1` | Manpage | Décrit la commande GUI installée | `install-tree.sh`, man(1), packages | Oui — documentation installée | Oui — profils et chemins XDG alignés | Non | Non, interface GUI distincte | KEEP |
| `packaging/man/yt-dlp-aria2-downloader.1` | Manpage | Décrit la commande CLI et toutes ses options | `install-tree.sh`, man(1), packages | Oui — documentation installée | Oui — usage de `download-video.sh` aligné | Non | Non | KEEP |
| `packaging/package-user-cleanup.sh` | Bash cleanup | Supprime seulement les données allowlistées lors de l’effacement RPM final | Spec RPM, install-tree, tests cleanup | Oui — désinstallation RPM, installée seulement en RPM | Oui — bornes HOME/XDG/symlink et modes best-effort explicites | Oui — chemins GUI historiques encore nécessaires au cleanup | Non | KEEP — COMPATIBILITÉ |
| `packaging/rpm/build-rpm.sh` | Bash packaging | Produit et valide le RPM Fedora noarch v4 | Workflows packages/release | Oui — packaging RPM | Oui — archive propre, spec et payload contrôlés | Format v4 volontaire pour signature actuelle | Non | KEEP |
| `packaging/rpm/test-package-lifecycle.sh` | Bash qualification paquet | Teste installation, retrait et réinstallation RPM réels | Workflows packages/release | Oui — CI packaging privilégiée | Oui — payload et cleanup final contrôlés | Compatibilité de cycle de vie volontaire | Non | KEEP |
| `packaging/rpm/test-package-upgrade.sh` | Bash qualification paquet | Teste upgrade du RPM immuable précédent vers courant | Workflows packages/release | Oui — compatibilité release | Oui — source précédente résolue dynamiquement | Oui — compatibilité d’upgrade nécessaire | Non | KEEP — COMPATIBILITÉ |
| `packaging/rpm/yt-dlp-aria2-downloader-gui.spec` | Spec RPM | Déclare dépendances, installation, `%files`, scriptlet cleanup et changelog RPM | rpmbuild via `build-rpm.sh` | Oui — packaging RPM | Oui — version macro, payload et changelog figé cohérents | Changelog embarqué légitime | Non | KEEP |
| `packaging/yt-dlp-aria2-downloader.desktop` | Desktop Entry | Lance la commande GUI système | `install-tree.sh`, packages, desktop shell | Oui — intégration bureau, installé | Oui — Exec/TryExec/icône/catégories valides | Non | Non | KEEP |
| `private-aria2-plan.py` | Module Python privé | Classe, construit et publie atomiquement les transferts aria2 privés | `download-video.sh`, packages, cinq suites ciblées | Oui — confidentialité/transport, installé en 0644 | Oui — SPDX, docstring projet/chemin/rôle et syntaxe validés | Non | Non, isole le traitement JSON et fichiers privés | KEEP |
| `private-launcher-manager.py` | Module Python privé | Ancre et sérialise les transactions du launcher portable avec `flock` et `openat`/`dir_fd`, puis tente leur rollback sans suivre les liens symboliques | `install-gui.sh`, ZIP/Git, tests installer | Oui — confinement installation portable, présent dans le ZIP mais non installé par RPM/DEB | Oui — cible exécutable, publication/retrait et interruption avec rollback best-effort, validator borné/reapé et stale cleanup typé/non récursif restent liés aux descripteurs ouverts, avec rejet final des remplacements de la racine ou d'un répertoire géré | Non | Non, fournit les primitives transactionnelles indisponibles en Bash | KEEP |
| `progress-monitor.sh` | Bash production | Transforme les événements yt-dlp/aria2/FFmpeg en progression Zenity | GUI, package, tests progress/réels | Oui — exécution GUI, installé | Oui — protocoles v2/legacy et bornes cohérents | Fallback de flux legacy encore testé | Non | KEEP |
| `runtime-manager.sh` | Bash production | Installe, atteste, active et restaure yt-dlp/Deno par utilisateur | Moteur, Fedora installer, packages, tests runtime | Oui — exécution et supply chain, installé | Oui — versions minimales, locks, journal et rollback cohérents | Compatibilité/récupération volontaire | Non | KEEP |
| `scripts/check-shell-format.sh` | Bash développement | Vérifie sans modifier le format de tous les Shell canoniques | `run-all.sh`, agents, CI | Oui — validation | Oui — utilise pin et `.editorconfig` | Non | Non, contrepartie non mutante du formatter | KEEP |
| `scripts/dev-tools/ensure-shfmt.sh` | Bash développement | Télécharge/cache le binaire shfmt épinglé après vérification SHA-256 | Check/format scripts, workflow updater | Oui — formatter authentifié | Oui — plateformes, modes et publication atomique | Non | Non | KEEP |
| `scripts/dev-tools/shfmt-pin.env` | Configuration outil | Épingle version et digests shfmt amd64/arm64 | ensure-shfmt, workflow updater, docs | Oui — supply chain développement | Oui — 3.13.1 et deux digests gérés | Non | Non | KEEP |
| `scripts/format-shell.sh` | Bash développement | Reformate tous les Shell canoniques | Mainteneurs, workflow de préparation | Oui — maintenance | Oui — inventaire et options canoniques | Non | Non, action mutante distincte du check | KEEP |
| `scripts/release-evidence-qualification.sh` | Bash qualification | Vérifie après publication release, assets, attestations et runs | Mainteneurs, `TESTING.md`, tests statiques | Oui — preuve post-release manuelle | Oui — exemple générique et sortie locale documentée | Non | Non, complète le preflight et la CI | KEEP |
| `scripts/release-preflight.sh` | Bash release | Vérifie tag, versions, règles GitHub et matériel de signature avant push | Mainteneurs, `TESTING.md`, tests statiques | Oui — garde release | Oui — contrôles API et fingerprints cohérents | Non | Non, intervient avant publication | KEEP |
| `test-static.sh` | Bash test | Valide inventaires, en-têtes, skills/règles/modèles Codex, workflows, versions, packaging et contrats source | `run-all.sh`, workflows, mainteneurs | Oui — CI statique | Oui — impose notamment une décision sûre explicite dans chaque règle Codex et teste le rejet d’une décision implicite | Non | Non | KEEP |
| `tests/aria2-auth-headers-integration.sh` | Bash test | Prouve allowlist de headers et isolation cross-origin | `run-all.sh`, tests statiques | Oui — sécurité transport | Oui — contrôle positif et mutant dangereux | Non | Non | KEEP |
| `tests/aria2-real-behavior-integration.sh` | Bash test réel | Qualifie Range, redirect, erreur, cancel, reprise et quiescence aria2 | Workflows real-tools/release | Oui — comportement réel | Oui — serveur local et répétitions bornées | Reprise native volontaire | Non | KEEP |
| `tests/ffmpeg-generation-compatibility.sh` | Bash test | Vérifie les invariants média sensibles aux générations FFmpeg | Qualification multi-génération | Oui — compatibilité FFmpeg | Oui — fixtures ciblées | Compatibilité générationnelle nécessaire | Non | KEEP |
| `tests/ffmpeg-generation-qualification.sh` | Bash orchestrateur test | Réutilise les suites réelles avec une génération FFmpeg donnée | Workflow qualification | Oui — matrice FFmpeg | Oui — délégation claire | Compatibilité générationnelle nécessaire | Non | KEEP |
| `tests/ffmpeg-progress-integration.sh` | Bash test | Vérifie la progression FFmpeg gérée par le wrapper | `run-all.sh`, tests statiques | Oui — progression | Oui — cas mesurés et erreurs | Non | Non | KEEP |
| `tests/ffmpeg-real-progress-integration.sh` | Bash test réel | Vérifie `-progress`, monotonie et publication avec vrai FFmpeg | Real-tools, release, qualification | Oui — intégration réelle | Oui — répétable et borné | Non | Non | KEEP |
| `tests/hls-remux-duration-integration.sh` | Bash test réel | Empêche la publication d’un remux HLS tronqué malgré succès FFmpeg | Real-tools, release, qualification | Oui — intégrité média | Oui — cas reproductible et réparation | Régression historique devenue contrat courant | Non | KEEP |
| `tests/install-fedora-authentication-integration.sh` | Bash test | Teste auth RPM fail-closed et staging root immuable | `run-all.sh`, tests statiques | Oui — sécurité installation | Oui — mutations de clé/paquet couvertes | Non | Non | KEEP |
| `tests/installer-integration.sh` | Bash test | Teste installation portable, réinstallation, échecs, signaux transactionnels et retrait | `run-all.sh`, tests statiques | Oui — launcher | Oui — modes, espaces, symlinks, allocations/validator interrompus, rollback et temporaires | Cleanup d’artefacts anciens volontaire | Non | KEEP |
| `tests/lib/assert.sh` | Bibliothèque Bash test | Assertions partagées de statut, texte, fichier, lien et mode | Suites d’intégration ciblées et `test-static.sh` | Oui — infrastructure tests | Oui — API appelée directement | Non | Non, évite la duplication | KEEP |
| `tests/lib/package-lifecycle.sh` | Bibliothèque Bash test | Assertions communes de payload et retrait RPM/DEB | Quatre scripts lifecycle/upgrade | Oui — packaging tests | Oui — abstraction commune aux formats | Non | Non, factorisation active | KEEP |
| `tests/lib/package-runtime-preservation.sh` | Bibliothèque Bash test | Prépare et compare l’arbre runtime utilisateur pendant lifecycle/upgrade | Tests RPM/DEB | Oui — preuve de non-perte | Oui — snapshots déterministes et cleanup | Oui — compatibilité d’upgrade nécessaire | Non | KEEP — COMPATIBILITÉ |
| `tests/lib/project-files.sh` | Bibliothèque Bash test | Source de vérité des inventaires Shell et Python | shfmt, ShellCheck, run-all, static, workflow updater et test du manifeste runner | Oui — validation | Oui — catégories canoniques exactes | Non | Non | KEEP |
| `tests/lib/test-runner.sh` | Bibliothèque Bash test | Supervise enfants, délais, logs, signaux, identité des processus et collecte parallèle | `run-all.sh`, repeat helper, tests runner | Oui — infrastructure tests | Oui — statuts, groupes, handshake/fallback start time, superviseur tokenisé et PID obsolètes testés | Non | Non | KEEP |
| `tests/mock-integration.sh` | Bash test hermétique | Couvre moteur, GUI, signaux, runtime et staging via mocks | `run-all.sh`, stress CI | Oui — couverture fonctionnelle rapide | Oui — groupes explicites, sessions no-fork PID/PGID/SID, signaux de groupe et fixtures privées | Migrations/legacy testés volontairement | Non, complément des vrais outils | KEEP |
| `tests/package-user-cleanup-integration.sh` | Bash test | Attaque les bornes HOME/XDG/symlink du cleanup RPM | `run-all.sh`, stress CI | Oui — sécurité suppression | Oui — scénarios forgés et répétitions | Compatibilité de chemins anciens nécessaire | Non | KEEP |
| `tests/packaging-integration.sh` | Bash test | Vérifie l’arbre DESTDIR, modes, assets et exclusions | `run-all.sh`, tests statiques | Oui — packaging hermétique | Oui — payload attendu actuel | Vérifie aussi l’absence d’assets obsolètes | Non | KEEP |
| `tests/private-aria2-plan-integration.sh` | Bash test | Teste validation, construction et commit atomique du module Python | `run-all.sh`, tests statiques | Oui — helper privé | Oui — erreurs, collisions et rollback couverts | Non | Non | KEEP |
| `tests/progress-monitor-integration.sh` | Bash test | Teste parsing, pondération, monotonie et fin de progression | `run-all.sh`, tests statiques | Oui — UI/progression | Oui — protocoles directs/natifs/postprocess | Fallback legacy encore contractuel | Non | KEEP |
| `tests/real-tools-integration.sh` | Bash test réel | Génère des médias locaux et exerce vrais yt-dlp/aria2/FFmpeg/FFprobe | Real-tools, release, qualification | Oui — intégration réelle | Oui — routes direct/HLS/DASH/audio et mutants | Pins reproductibles volontaires | Non, complément des mocks | KEEP |
| `tests/repeat-qualification.sh` | Bash orchestrateur test | Répète en parallèle des qualifications indépendantes et ordonne les logs | Quatre workflows, qualification FFmpeg | Oui — détection de races | Oui — limites et isolation documentées | Non | Non | KEEP |
| `tests/rpm6-multisig-integration.sh` | Bash test packaging | Prouve les sémantiques signatures RPM v4/v6 et corruption | Packages/release CI | Oui — décision de format/signature | Oui — v4 production et v6 qualification séparés | Oui — compatibilité v4/v6 nécessaire | Non | KEEP — COMPATIBILITÉ |
| `tests/run-all-signal-integration.sh` | Bash test | Vérifie qu’une interruption de run-all tue les groupes enfants sans cibler un PID réutilisé | `run-all.sh`, tests statiques | Oui — sûreté du runner | Oui — identité héritée, descendant et délai bornés | Non | Non | KEEP |
| `tests/run-all.sh` | Bash orchestrateur test | Diagnostique l’environnement ou lance format, static, ShellCheck et suites profilées/parallèles | Développeurs, agents, quatre workflows | Oui — entrée canonique de diagnostic et validation | Oui — doctor borné, manifestes exacts, ordre d’échec déterministe et suites dominantes lancées en premier | Non | Non | KEEP |
| `tests/runtime-manager-hardening-integration.sh` | Bash test | Stresse locks, réseau nul, bootstrap, journal, rollback et bornes | `run-all.sh`, stress CI | Oui — supply chain/runtime | Oui — mutations et répétitions | Récupération/compatibilité volontaire | Non | KEEP |
| `tests/runtime-manager-integration.sh` | Bash test | Vérifie installation normale, chemins, offline et rollback runtime | `run-all.sh`, signal test | Oui — runtime | Oui — x86_64/aarch64 et états courants/précédents | Compatibilité rollback nécessaire | Non | KEEP |
| `tests/test-runner-integration.sh` | Bash test | Teste doctor JSON, concurrence, manifestes exacts, timing, transitions finales et terminaison du runner | `run-all.sh`, tests statiques | Oui — infrastructure tests | Oui — couvre environnement, ordre d’échec, signaux, PID réutilisé et enfant sans token résistant à TERM | Non | Non | KEEP |
| `tests/zenity-real-session-qualification.sh` | Bash qualification manuelle | Enregistre une session GUI réelle contrôlée avec preuve de confidentialité/processus | Mainteneurs via `TESTING.md`; inventaire Shell | Oui — validation UI non simulable | Oui — scénarios, plateformes et preuves documentés | Non | Non, ne peut être remplacé par le mock headless | KEEP |

## Vérification des candidats historiques et temporaires

La recherche globale n’a trouvé aucun blob tracked identique, aucun fichier de
rejet/sauvegarde/éditeur, aucun cache Python, aucune preuve générée et aucun
répertoire d’anciennes captures. Tous les chemins ont un consommateur explicite
dans la table. `.gitignore` est utilisé par Git et contrôlé par `test-static.sh` ;
les trois skills sont découvertes dynamiquement dans `.agents/skills/`. Les
scripts de qualification manuelle qui ne sont pas lancés en CI ont un
consommateur et une procédure explicites dans `TESTING.md`.

Pour chaque fichier pouvant sembler ancien, la question demandée a été posée :

> « Quelle valeur concrète apporte encore ce fichier dans le dépôt actuel ? »

- `CHANGELOG.md` apporte la chronologie de release, est installé dans les
  paquets et permet d’interpréter les compatibilités ; sa valeur est suffisante.
- Le changelog du spec RPM est une métadonnée du paquet et conserve des versions
  figées exigées par les tests ; il ne duplique pas le journal général.
- Les tests d’upgrade et `package-runtime-preservation.sh` prouvent la non-perte
  de données depuis le paquet immuable précédent ; leur valeur est fonctionnelle.
- `package-user-cleanup.sh` et ses chemins legacy permettent l’effacement final
  sûr de données réellement créées par d’anciennes installations ; retirer ces
  branches casserait une compatibilité documentée.
- Les fixtures d’anciennes versions yt-dlp/Deno/FFmpeg/RPM représentent des
  bornes, mutations ou générations nommées ; elles ne prétendent pas être les
  versions courantes.
- `tests/zenity-real-session-qualification.sh` couvre l’interaction réelle,
  impossible à démontrer par les mocks headless.
- `scripts/release-evidence-qualification.sh` vérifie après publication des
  faits publics que le workflow déclaratif seul ne prouve pas.
- `REPOSITORY_FILES.md` est un inventaire courant vérifié par CI, pas un rapport
  ponctuel abandonné ; sa valeur disparaîtrait seulement si ce contrôle était
  remplacé par une source de vérité équivalente.

Aucun fichier ne satisfait les conditions de
`SUPPRIMER — PROUVÉ INUTILE`. Il n’existe donc aucun candidat nécessitant une
preuve individuelle de suppression supplémentaire.

# AUDIT DE L’UTILITÉ DE TOUS LES FICHIERS

- Nombre total de fichiers tracked : **83**.
- Nombre de fichiers examinés : **83**.
- Nombre de fichiers à conserver : **83**, dont les catégories historique et
  compatibilité ci-dessous.
- Nombre de fichiers historiques : **1** (`CHANGELOG.md`).
- Nombre de fichiers à corriger : **0**.
- Nombre de fichiers redondants : **0**.
- Nombre de suppressions réellement justifiées : **0**.
- Nombre de cas à revalider : **0**.

Les cinq fichiers classés `KEEP — COMPATIBILITÉ` en plus du changelog sont des
preuves ou mécanismes actifs, pas des reliquats : les deux tests d’upgrade de
paquets, la préservation du runtime utilisateur, le cleanup RPM et la
qualification RPM v4/v6.
