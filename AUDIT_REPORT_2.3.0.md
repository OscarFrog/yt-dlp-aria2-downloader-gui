# Audit professionnel complet — yt-dlp-aria2-downloader-gui v2.3.0

Date de l’audit : **28 août 2026**
Dépôt : <https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui>
Version : **v2.3.0**
SHA audité : **`d313f86ec4125382d0524fc0a40557f4596859a5`**

## 1. Verdict exécutif

| Décision | Résultat |
|---|---|
| GO / GO SOUS CONDITIONS / NO-GO | **NO-GO** selon le seuil professionnel strict demandé |
| READY FOR DISTRIBUTION | **NOT READY** tant que les deux findings HIGH ne sont pas corrigés |
| Score global | **79/100** |
| Moyenne brute des 40 domaines | 86,3/100 |
| Critical | 0 |
| High confirmés | 2 |
| Medium confirmés | 4 |
| Medium non vérifié | 1 |
| Low confirmés | 6 |
| Info actionnables | 5 |
| Race production téléchargement confirmée | 0 |
| Race test-runner confirmée | 1 |
| Familles de tests flaky confirmées | 2 |
| Code mort production confirmé | 0 |
| Token mort test confirmé | 1 |
| Gates release-critical non vérifiés | 2 |

La release publiée est **authentique, immutable, correctement signée et reproductible au niveau des artefacts**. RPM, DEB, ZIP, installateur et clé correspondent aux sources et aux artefacts du run de release. Le NO-GO ne vient donc pas d’une release corrompue.

Il vient de deux écarts incompatibles avec le seuil demandé :

1. le bootstrap Fedora exécute sous `root` un RPM de dépôt RPM Fusion téléchargé sans la vérification isolée déjà disponible dans la CI ;
2. le nouveau test-runner possède une fenêtre de signal avant enregistrement du PID, reproduite avec des descendants survivants.

S’ajoutent l’exposition d’aria2/GnuTLS à un correctif postérieur à la dernière release, une politique de tag qui ne verrouille pas l’identité du signataire, une régression site tiers concerné amont et deux fixtures de signaux instables.

Le score utilise une règle explicite : la moyenne brute est 86,3, puis un finding HIGH confirmé impose un plafond de 79. Un score proche de 100 aurait été artificiel.

## 2. Périmètre, méthode et limites

L’audit a été conduit en lecture seule sur le dépôt et sur GitHub. Aucun push, commit distant, PR, release, secret ou environnement n’a été modifié. Les mutations ont été réalisées uniquement sur des copies temporaires.

Méthode appliquée aux claims importants :

- H0 : comportement correct ;
- H1 : scénario de panne ;
- meilleure réfutation disponible ;
- preuve statique ;
- preuve dynamique ;
- mutation ou injection de faute ;
- répétition ;
- verdict `PROUVÉ`, `PROBABLE`, `NON VÉRIFIÉ` ou `RÉFUTÉ`.

Environnement local principal : Fedora 44, Bash 5.3.9, Python 3.14.7, FFmpeg/FFprobe 8.1.2, aria2 1.37.0 lié à GnuTLS 3.8.11, ShellCheck 0.11.0, RPM 6.0.2.

Limites importantes :

- aucune installation destructive n’a été refaite sur l’OS utilisateur ; les installations et upgrades reposent sur les jobs exacts de release et l’inspection des artefacts ;
- la qualification Zenity réelle exige des actions visibles d’un opérateur et n’a pas été rejouée ;
- les backports sécurité complets des paquets FFmpeg Ubuntu/RPM Fusion n’ont pas pu être démontrés ;
- les benchmarks lourds n’ont pas tous sept observations : les résultats sont étiquetés avec leur taille d’échantillon ;
- la matrice dynamique de clés expirées/révoquées n’est pas complète.

## 3. Snapshot exact

| Élément | Attendu | Observé | Verdict |
|---|---|---|---|
| Tag | `v2.3.0` | `v2.3.0` | PASS |
| Objet tag annoté | `f066cead4be2c60e28c28a590136edc64dea50bc` | identique | PASS |
| Commit pelé | `d313f86ec4125382d0524fc0a40557f4596859a5` | identique | PASS |
| `main` local | même commit | identique | PASS |
| `origin/main` | même commit | identique | PASS |
| Working tree initial | propre | propre | PASS |
| Signature tag | fingerprint autorisée | `43E5361414863738F0324F2B047B26057E612CDC` | PASS |

`git verify-tag --raw v2.3.0`, avec la clé OscarFrog importée dans un keyring isolé, produit `GOODSIG` et `VALIDSIG`.

## 4. Historique et refactor v2.2.6 → v2.3.0

| Commit | Changement | Risque | Verdict |
|---|---|---|---|
| `5a92eefe` | v2.2.3 | historique intermédiaire | revu |
| `41d47aff` | v2.2.4 | historique intermédiaire | revu |
| `a3d09715` | v2.2.5 | historique intermédiaire | revu |
| `a8b67f8b` | v2.2.6 | baseline fonctionnelle précédente | revu |
| `d795c1ab` | PR #44, restructuration et parallélisation | élevé | aucune régression CLI confirmée ; race runner trouvée |
| `d313f86e` | PR #45, correction de shadowing | élevé | correction valide ; faiblesse de conception résiduelle |

Le diff 2.2.6→2.3.0 couvre 50 fichiers, environ 6 203 insertions et 2 593 suppressions. L’aide CLI normalisée reste identique hors numéro de version. `git diff --check`, les tests statiques et ShellCheck passent. Aucune autre régression sémantique active de shadowing n’a été trouvée.

Contrairement à l’hypothèse du prompt, **`.editorconfig` n’a pas été supprimé** : il est présent au tag, documenté et testé.

## 5. Architecture et cohérence

| Fichier/composant | Responsabilité | Dépendances/état | Verdict |
|---|---|---|---|
| `download-video-gui.sh` | dialogues, profil, worker, résultat final | Zenity, PGID, fichiers privés | cohérent, complexe |
| `download-video.sh` | orchestration du téléchargement | yt-dlp, aria2, FFmpeg, FFprobe | cohérent, 2 188 lignes |
| `runtime-manager.sh` | acquisition, validation, activation, rollback | GitHub, GPG, checksum, locks | robuste |
| `private-aria2-plan.py` | classification, plan privé, commit/rollback | Python 3.10+ | cohérent, compile |
| `progress-monitor.sh` | parsing et affichage monotone | log append-only, résultat atomique | cohérent |
| `tests/lib/test-runner.sh` | sessions, slots, logs et terminaison | Bash + trampoline Python | **race confirmée** |
| `tests/run-all.sh` | profils, scheduling, reporting | runner, ShellCheck, suites | rapide mais contrat à corriger |
| `install-fedora.sh` | bootstrap système Fedora | DNF, RPM Fusion, clé RPM projet | **supply chain insuffisante** |
| packaging RPM/DEB/ZIP | construction et cycle de vie | outils distro | artefacts cohérents |
| `release.yml` | build, signature, publication, attestations | GitHub Actions | solide, signer tag non épinglé |

Chaîne fonctionnelle validée :

```text
Zenity → GUI → moteur → runtime manager → yt-dlp PLAN
       → aria2 direct ou yt-dlp natif → FFmpeg → FFprobe
       → résultat atomique → progress monitor → GUI
```

Chaîne release validée :

```text
tag → validation → real-tools → packages → signature RPM
    → tests fresh/upgrade → publication → fresh-download verification
```

Les `main()` sont devenus des orchestrateurs lisibles. La complexité reste concentrée dans le moteur, la GUI, le moniteur, `test-static.sh` et le mock principal. Une nouvelle extraction de helpers n’est justifiée que si elle réduit une responsabilité mesurable sans réintroduire de portée dynamique.

## 6. Findings détaillés

### AUD-230-001 — Bootstrap RPM Fusion insuffisamment authentifié

- Statut : **CONFIRMÉ**
- Gravité : **HIGH**
- Confiance : élevée
- Composant : installation Fedora / supply chain
- Fichier : `install-fedora.sh:367-373`
- H0 : le RPM de bootstrap tiers est authentifié avant exécution privilégiée.
- H1 : un paquet obtenu via l’URL est accepté par `dnf` sans identité cryptographique épinglée par le projet.
- Observé : l’URL distante est passée directement à `dnf install` sous `root` ; aucun fingerprint RPM Fusion, keyring isolé, NEVRA attendu, digest ou `localpkg_gpgcheck=True` n’est appliqué.
- Réfutation : HTTPS réduit l’exposition réseau, mais ne remplace pas une identité de signature épinglée et ne protège pas d’une origine compromise.
- Preuve indépendante : `.github/workflows/qualification.yml:52-131` utilise déjà TLS contraint, le fingerprint `E9A491A3DE247814E7E067EAE06F8ECDD651FF2E`, un keyring isolé, `rpmkeys --checksig` et le NEVRA `rpmfusion-free-release-44-3.noarch`.
- Impact : exécution de code privilégié lors d’une installation Fedora fraîche.
- Remédiation minimale : réutiliser la vérification de qualification avant toute transaction root.
- Non-régression : correct/wrong key, wrong NEVRA, RPM corrompu, paquet non signé, redirection et échec réseau.

### AUD-230-002 — Fenêtre de signal avant enregistrement du child runner

- Statut : **CONFIRMÉ**
- Gravité : **HIGH**
- Confiance : élevée
- Composant : `tests/lib/test-runner.sh`
- Fonction : `_test_runner_start_child`
- H0 : tout enfant démarré est visible du handler de signal.
- H1 : TERM arrive après le `&` mais avant `TEST_RUNNER_CHILD_PIDS[slot]=$!`.
- Preuve statique : `tests/lib/test-runner.sh:124-133` lance la trampoline puis remplit les tableaux ; les traps sont déjà actifs dans `tests/run-all.sh:588-591`.
- Preuve dynamique : stress exact tag, signal après un gate et jitter 0–2 ms : **6 survivants / 300 runs**. Le runner sortait 143 ; le contrôleur supprimait ensuite uniquement ses PID marqués.
- Réfutation : `run-all-signal-integration.sh` est vert, mais attend la publication des markers avant de signaler et ne couvre donc pas cette fenêtre.
- Contre-test : un descendant créant sa propre session survit **7/7** à la terminaison par PGID ; la phrase « complete descendant tree » est trop forte.
- Impact : après interruption locale/CI, une suite peut continuer sans supervision ; les résultats et nettoyages ne sont plus fiables.
- Remédiation minimale : rendre la phase lancement/enregistrement signal-safe et ajouter une injection avant enregistrement. Pour les sessions échappées, utiliser une primitive de confinement appropriée ou réduire explicitement le contrat.

### AUD-230-003 — aria2/GnuTLS antérieur au correctif CVE-2026-8367

- Statut : **CONFIRMÉ sur Fedora 44 observé**
- Gravité : **MEDIUM**
- Confiance : élevée
- H0 : le backend TLS d’aria2 valide correctement l’Extended Key Usage.
- H1 : aria2 1.37.0 lié à GnuTLS accepte un certificat dont l’usage n’est pas valide pour un serveur TLS.
- Observé : `aria2-1.37.0-9.fc44`, lié à GnuTLS 3.8.11 ; build janvier 2026, sans backport dans le changelog. Le correctif upstream a été fusionné le 15 mai 2026.
- Sources : [issue aria2 #2355](https://github.com/aria2/aria2/issues/2355), [correctif aria2 #2356](https://github.com/aria2/aria2/pull/2356).
- Application : `download-video.sh:1836-1866` délègue les transferts HTTPS directs à aria2.
- Impact : validation TLS incorrecte dans un scénario de certificat/mauvais EKU.
- Remédiation : reconnaître explicitement les paquets backportés ; sinon basculer HTTPS vers yt-dlp natif jusqu’à disponibilité d’un build corrigé.

### AUD-230-004 — Le workflow accepte tout tag GitHub validement signé

- Statut : **CONFIRMÉ**
- Gravité : **MEDIUM**
- Confiance : élevée
- H0 : le workflow impose le signataire autorisé.
- H1 : un autre tag annoté avec une signature GitHub valide passe le job initial.
- Preuve : `.github/workflows/release.yml:55-73` teste `verified=true` et `reason=valid`, sans fingerprint.
- Protection existante : `scripts/release-preflight.sh:160-188` compare correctement `43E536...12CDC`, et l’environnement `rpm-signing` a un reviewer.
- Limite : le preflight n’est pas un gate du workflow ; le contrôle d’environnement est humain.
- Release actuelle : non affectée, la v2.3.0 est signée par la bonne clé.
- Remédiation : vérification GPG locale dans un keyring isolé au job `validate`.

### AUD-230-005 — Régression site tiers concerné dans yt-dlp

- Statut : **CONFIRMÉ, cause amont**
- Gravité : **MEDIUM fonctionnalité**
- Confiance : élevée
- Scénario : URL site tiers concerné fournie par l’utilisateur.
- Observations : sept observations utiles sur stable/nightly ; quatre simulations consécutives sur 2026.08.19 retournent toutes status 1. Le moteur v2.3.0 reproduit exactement l’échec au planning, sans lancer aria2 ni publier un résultat.
- Meilleure protection : échec fail-closed, pas de faux succès.
- Source : [PR yt-dlp #17374](https://github.com/yt-dlp/yt-dlp/pull/17374), encore ouverte ; [issue #15497](https://github.com/yt-dlp/yt-dlp/issues/15497).
- Impact : site temporairement non fonctionnel malgré runtime stable et nightly actuels.
- Remédiation : suivre la fusion/release upstream, documenter le site cassé et améliorer le diagnostic. Un smoke live peut être informatif, jamais un gate déterministe unique.

### AUD-230-006 — Fixtures de signaux instables

- Statut : **CONFIRMÉ**
- Gravité : **MEDIUM**
- Confiance : élevée
- Preuve 1 : le run exact [33170482274](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/33170482274), tentative 1, échoue sur Ubuntu et Fedora à `worker group receives TERM`; la tentative 2 passe sur les deux OS.
- Preuve 2 : PR #46, fermée/non fusionnée, ajoute une synchronisation du démarrage du worker.
- Preuve 3 : scénario `private-staging-active-replacement`, 30/30 séquentiels verts mais 1/120 sous charge retourne 1 au lieu de 143. Le mock utilise `${MOCK_TERMINATION_MARKER:?}` sans définir ce marker dans ce scénario.
- Contre-test : l’ajout temporaire du marker supprime l’échec dans les contrôles parallèles effectués.
- Verdict : flakiness des fixtures, pas preuve d’une race du moteur de téléchargement.
- Remédiation : intégrer les deux corrections dans la prochaine version et rendre la synchronisation observable.

### AUD-230-007 — Contrat privé de `--url-file` non imposé

- Statut : CONFIRMÉ ; gravité : LOW ; confiance : élevée.
- `download-video.sh:1339-1350` vérifie type, non-symlink, lisibilité et propriétaire, mais accepte un fichier owner `0644`.
- Le help et la manpage disent « private regular file » ; la GUI crée bien son propre fichier en `0600`.
- Remédiation : exiger `mode & 077 == 0` ou documenter clairement que la confidentialité appartient à l’appelant.

### AUD-230-008 — MediaValidation ne donne pas la cause

- Statut : CONFIRMÉ ; gravité : LOW ; confiance : élevée.
- Les erreurs FFprobe sont supprimées et les branches convergent vers `return 1` ; le message final ne contient que le chemin.
- Cette faiblesse explique directement le rapport réel `MediaValidation` fourni pendant l’audit, mais le média n’était plus disponible : la cause particulière reste **NON VÉRIFIÉE**.
- Remédiation : codes bornés `missing-content-video`, `missing-audio`, `tail-inconsistent`, `probe-timeout`, `probe-parse-error`, sans recopier des secrets.

### AUD-230-009 — APIs Bash de sortie par nom collisionnelles

- Statut : CONFIRMÉ comme faiblesse de conception ; gravité : LOW.
- 71 écritures `printf -v` par nom existent dans dix fichiers.
- Aucun call-site actif collisionnel n’a été trouvé.
- Mutations : collisions confirmées pour `normalize_decimal_component value`, `compare_decimal_components result` et `test_runner_format_duration duration_ms`.
- Remédiation : contrôle générique des contrats ou migration progressive vers stdout/retours structurés. Référence : [portée dynamique Bash](https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html).

### AUD-230-010 — Preflight partiellement déclaratif

- Statut : CONFIRMÉ ; gravité : LOW.
- L’opérateur confirme manuellement admin bypass et type de policy, alors que l’API expose ces états.
- État actuel : admin bypass désactivé, policy `v*` de type tag, un reviewer ; aucun défaut de configuration actuel.
- Remédiation : vérifier automatiquement les valeurs API et conserver seulement la confirmation réellement humaine.

### AUD-230-011 — Qualification d’évidence fragile dans le temps

- Statut : CONFIRMÉ ; gravité : LOW.
- Lookup limité à 100 runs sans pagination ; certaines opérations publiques n’ont pas le retry borné du workflow de release.
- Remédiation : pagination jusqu’au SHA exact et wrapper réseau commun avec budget total.

### AUD-230-012 — Matrice OpenPGP négative incomplète

- Statut : CONFIRMÉ ; gravité : LOW.
- Unsigned, wrong signer, multisignature, ordre et corruption sont couverts.
- Expired, revoked et signature par primary ne sont pas tous exercés dynamiquement de bout en bout.
- Remédiation : fixtures temporaires datées/révoquées et assertions sur la raison de refus.

### AUD-230-013 — Posture sécurité FFmpeg downstream non démontrée

- Statut : **NON VÉRIFIÉ**
- Gravité potentielle : MEDIUM
- Confiance : moyenne
- Upstream 9.0.1 et sa signature sont vérifiés avec `FCF986EA15E6E293A5644F10B4322F04D67658D8`.
- Les matrices fonctionnelles 6.1.1/8.1.2/9.0.1 sont vertes, mais l’état exhaustif des backports sécurité Ubuntu/RPM Fusion n’est pas prouvé. La [page sécurité FFmpeg](https://ffmpeg.org/security.html) et les pages Ubuntu pour [CVE-2026-8461](https://ubuntu.com/security/CVE-2026-8461) et [CVE-2026-30999](https://ubuntu.com/security/CVE-2026-30999) justifient le gate.
- Ce finding n’affirme pas que les paquets sont vulnérables ; il interdit seulement une note de sécurité maximale sans preuve.

## 7. Race ledger global

| Race/hypothèse | Fenêtre ou trigger | Runs | Échecs | Verdict |
|---|---|---:|---:|---|
| Runner avant enregistrement PID | `&` → affectation tableau, TERM 0–2 ms | 300 | 6 survivants | **CONFIRMÉ** |
| Descendant recrée une session | `setsid` dans le child | 7 | 7 survivants | limite confirmée |
| GUI cancel avant worker prêt | CI Ubuntu/Fedora | 2 OS | 2 puis 0 au rerun | fixture flaky |
| Private staging + TERM | séquentiel | 30 | 0 | protection production non réfutée |
| Private staging + TERM sous charge | 4 shards | 120 | 1 status erroné | fixture flaky |
| Runtime locks/activation | tests hardening + CI | 10+ | 0 observé | PASS |
| Package cleanup | stress CI | 10 | 0 | PASS |
| aria commit/rollback | intégrations et mutations | multiples | 0 | PASS |
| Result/progress drain | mocks + intégrations | multiples | 0 | PASS |
| Cancel/success moteur réel | non interactif uniquement | partiel | 0 confirmé | non exhaustif |

Aucune race du moteur/GUI n’est confirmée. La race HIGH appartient au test-runner, qui reste un composant critique parce qu’il fonde la confiance dans toutes les autres suites.

## 8. Test-runner et scheduling

| Propriété | Résultat |
|---|---|
| Sessions dédiées par trampoline Python | oui |
| SIGINT/SIGQUIT réinitialisés avant exec | oui |
| Completion files exclusifs | oui |
| Slot reuse/unset | cohérent statiquement |
| Completion write failure | status 70, fail closed |
| `wait_any` | polling 10 ms, fonctionnel mais pas toujours le plus ancien |
| Earliest completion | 11 non-ties/97 observations n’étaient pas le plus ancien |
| Cleanup après signal enregistré | borné TERM puis KILL |
| Startup avant enregistrement | **non sûr** |
| Descendants qui changent de session | non couverts |

Le défaut `wait_any` est surtout un problème de fairness/performance, pas de mapping : aucun slot perdu, doublé ou omis n’a été démontré dans les runs normaux.

## 9. Performance

### 9.1 Mesures disponibles

| Composant | Runs | Médiane | p95 / max | Verdict |
|---|---:|---:|---:|---|
| `download-video.sh --version` | 7 | <0,01 s | 0,01 s | excellent, mesure grossière |
| Real-tools local complet | 3 | 65,10 s | 65,37 s | PASS stable |
| Full local jobs=1 | 1 | 165,287 s | n/a | baseline |
| Full exact CI Fedora jobs=4 | 1 | 43,473 s | n/a | gain 3,80× vs baseline locale, environnements différents |
| Claim PR #44 jobs=4 | 1 historique | 52,883 s | n/a | plausible/reproduite en ordre de grandeur |
| Static local | 1 | 3,99 s | n/a | PASS |
| site tiers concerné extraction stable | 4 | environ 2,5 s | environ 2,5 s | échec reproductible, pas lenteur app |

Les tailles d’échantillon jobs=1/jobs=4 ne permettent pas une médiane/p95 honnête. `jobs=4` est **probablement** le meilleur compromis actuel : le gain est massif, la CI exacte est verte, et 4 correspond aux quatre catégories ShellCheck. `jobs=8` n’est pas déclaré meilleur faute de campagne comparable.

### 9.2 Top cinq observé dans la première tentative CI exacte

| Suite | Durée | Part/bottleneck |
|---|---:|---|
| Mock engine HLS | 12,567 s | scénarios FFmpeg/HLS |
| Mock engine core/storage | 12,012 s | nombreux scénarios moteur |
| run-all signal/descendant | 11,635 s | délais/grâce de processus |
| Mock GUI progress | 10,941 s | synchronisations GUI |
| Mock GUI state | 9,875 s | nombreux démarrages de GUI mock |

Le dépôt contient 89 occurrences textuelles de `sleep` dans les Shell files, commandes requises incluses. La majorité sont du polling borné, des grâces, des jitter de stress ou des sleepers volontairement longs ensuite tués. Aucun `sleep` de production n’a été prouvé inutile. Les sleeps 5/6 s de holders de lock sont interrompus explicitement après l’assertion ; les supprimer naïvement affaiblirait les tests.

Politique retenue : ne pas remplacer un polling observable ou une grâce de terminaison sans benchmark et stress race équivalents.

## 10. Matrice fonctionnelle et outils externes

| Outil | Version/OS | Preuve | Verdict |
|---|---|---|---|
| yt-dlp | 2026.06.09, 2026.07.04, 2026.08.19 | CI real-tools, release | PASS hors site cassé |
| yt-dlp | stable/nightly actuels, site tiers concerné | 7 observations | FAIL amont |
| Deno | 2.9.6 local | exact engine atteint le planning | PASS |
| FFmpeg/FFprobe | 6.1.1 Ubuntu | qualification CI | PASS fonctionnel |
| FFmpeg/FFprobe | 8.1.2 Fedora | local + qualification | PASS fonctionnel |
| FFmpeg/FFprobe | 9.0.1 source signée | qualification CI | PASS fonctionnel/signature |
| aria2 | 1.37.0 Fedora/Ubuntu | real-tools et CI | PASS fonctionnel, sécurité à corriger |
| Zenity | 4.2.2 Fedora, 4.0.1 Ubuntu | mocks/CI ; pas de session audit réelle | PARTIEL |
| shfmt | 3.13.1 | pin/hash/tag/tooling | PASS |
| ShellCheck | 0.9.0 Ubuntu | exact CI | PASS |
| ShellCheck | 0.11.0 Fedora/local | local + CI | PASS |

Versions officielles au 28 août 2026 : [yt-dlp 2026.08.19](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19), [Deno 2.9.6](https://github.com/denoland/deno/releases/tag/v2.9.6), [FFmpeg 9.0.1](https://ffmpeg.org/download.html), [aria2 1.37.0](https://github.com/aria2/aria2/releases/tag/release-1.37.0), [shfmt 3.13.1](https://github.com/mvdan/sh/releases/tag/v3.13.1), [ShellCheck 0.11.0](https://github.com/koalaman/shellcheck/releases/tag/v0.11.0). Le Deno 2.9.5 du prompt était déjà dépassé.

Trois runs locaux lourds `real-tools-integration.sh` sont verts : direct, audio, Opus, fallback, cover art, HLS, DASH, validation de tail et mutations FFprobe. Le message attendu « video-only failed validation » est un contrôle négatif, pas une régression.

## 11. Code mort et compatibilité historique

| Symbole/branche | Callers/producteur | Besoin historique | Classe | Action |
|---|---|---|---|---|
| `legacy_plan_seen` / `legacy_cookie_seen` | recovery staging | crash 2.2.0 après upgrade | UPGRADE/CRASH RECOVERY | conserver |
| parser `YTDLP_PROGRESS|` | mocks seulement aujourd’hui | mixed-version V1/V2 possible | COMPATIBILITY / probable deprecated | définir critère de retrait |
| profils `audio-mp3/m4a/opus` | migration config | anciennes configs 2.0.x | COMPATIBILITY | conserver |
| `SIGXFZ` | aucun attribut Python | typo de `SIGXFSZ` | DEAD CONFIRMED test-only | supprimer |
| helpers/globals production | appels statiques/dynamiques revus | actifs | ACTIVE | conserver |

Aucune suppression de code historique production n’est recommandée par intuition. Le gain attendu serait négligeable face au risque de casser recovery/upgrade.

## 12. Dynamic scoping et état global

| Famille | État | Verdict |
|---|---|---|
| `printf -v` par nom | 71 écritures | aucun collision active, contrat fragile |
| `declare -n` | 2 usages internes, `unset -n` | PASS |
| PR #45 `tag_commit` | shadowing corrigé | PASS |
| traps moteur/GUI/runtime | état global dédié ou locales vivantes | aucun shadowing actif trouvé |
| arrays runner PID/PGID/completion | cohérentes après inscription | fenêtre pré-inscription FAIL |

Les globals de PID, lock, temp, journal et résultat sont justifiés par les traps. Les petits résultats de parsing peuvent progressivement passer par stdout pour réduire la surface de portée dynamique.

## 13. Packaging, clés et release

### 13.1 Clés

| Clé | Attendu | Observé | Expiration | Verdict |
|---|---|---|---|---|
| Tag release | `43E536...12CDC` | identique | n/a | PASS |
| RPM primary | `7B5406...ABEA7F` | identique, certification only | 2029-08-20 | PASS |
| RPM signing subkey | `1F5B76...830245` | identique, unique signing | 2027-08-21 | PASS |
| FFmpeg source | `FCF986...658D8` | signature 9.0.1 valide | n/a | PASS |
| RPM Fusion qualification | `E9A491...1FF2E` | épinglé en CI | n/a | PASS CI / absent bootstrap prod |

### 13.2 Release et artefacts

| Étape | SHA/artefact | Signature/attestation | Verdict |
|---|---|---|---|
| Run release | `33170563848`, SHA exact | jobs verts | PASS |
| RPM | `37d2cf…14e0` | sous-clé attendue + SLSA | PASS |
| DEB | `f114f3…11ca` | checksum + SLSA | PASS |
| ZIP | `590f62…54ea` | checksum + SLSA | PASS |
| `install-fedora.sh` | `76ffc3…18bd` | byte-identical tag | PASS identité, logique FAIL |
| clé RPM | `7649cb…1231` | byte-identical tag | PASS |
| `SHA256SUMS` | `d6d59a…136a` | vérifie les cinq payloads | PASS |
| Release publique | immutable | `gh release verify*` | PASS |

La [release publique v2.3.0](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/releases/tag/v2.3.0) et le [run 33170563848](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/33170563848) correspondent exactement. RPM, DEB et ZIP sont identiques octet par octet aux artefacts du run. Fresh/reinstall et upgrades v2.2.6→v2.3.0 ont passé en CI.

Toutes les actions sont pinées par SHA et `persist-credentials:false`. Les images `fedora:44` et les ensembles apt/dnf restent mutables ; les attestations prouvent source et workflow, pas une reconstruction bit-reproducible de tout l’OS.

## 14. Documentation, headers et commentaires

| Domaine | Résultat | Verdict |
|---|---|---|
| En-têtes Shell | 46/46 inventoriés et conformes | PASS |
| Shebang/SPDX/File/Purpose | correspondances exactes | PASS |
| `.editorconfig` / style | présent, documenté, testé | PASS |
| TODO/FIXME/XXX/WIP permanents | aucun trouvé | PASS |
| README EN/FR | 31 titres et 24 liens chacun | très bon |
| Parité audio EN→FR | condition « no content video » omise en FR | INFO |
| Manpages/CLI | huit options alignées | PASS |
| `TESTING.md --full` | ambigu avec qualifications réelles séparées | INFO |
| Commentaire « complete descendant tree » | faux pour descendants `setsid` | à corriger |

Claim ledger documentation :

| Claim | Code | Test | EN | FR | Manpage | Verdict |
|---|---|---|---|---|---|---|
| une URL par run | oui | oui | oui | oui | oui | PASS |
| URL GUI privée | `0600` GUI | mocks | oui | oui | partiel | PASS GUI |
| média vidéo complet A+V | FFprobe | mocks+réel | oui | oui | résumé | PASS |
| audio sans vidéo de contenu | FFprobe | mocks+réel | oui | moins précis | résumé | INFO doc |
| cancellation sans survivants | PGID | tests | oui | oui | n/a | FAIL runner absolu |
| full = contrat complet | profil hermétique | oui | n/a | n/a | n/a | wording ambigu |

## 15. Scores

| Domaine | Score /100 | Justification |
|---|---:|---|
| Fonctionnalité globale | 82 | cœur vert, site réel cassé |
| Vidéo | 92 | réel/mocks/HLS/DASH verts |
| Audio | 94 | Opus/fallback/absence vidéo validés |
| HLS/DASH | 94 | matrices réelles vertes |
| GUI / Zenity | 82 | mocks verts, session réelle non rejouée |
| yt-dlp | 78 | stable sûr, site tiers concerné cassé |
| aria2 | 58 | fonctionnel, CVE GnuTLS non mitigée |
| FFmpeg | 80 | matrices vertes, backports sécurité non prouvés |
| FFprobe | 86 | validation forte, diagnostics trop génériques |
| Deno/runtime | 93 | 2.9.6 accepté, activation/rollback robustes |
| Progress | 94 | monotonicité/drain couverts |
| Cancellation | 81 | production non cassée, fixtures flaky |
| Process lifecycle | 78 | PGID solide après inscription, fenêtre runner |
| Race robustness | 68 | 6/300 survivants runner |
| Filesystem safety | 88 | staging/locks forts, contrat url-file |
| Runtime manager | 94 | locks, journal, rollback verts |
| RPM | 90 | artefact excellent, bootstrap tiers séparé |
| DEB | 95 | fresh/reinstall/upgrade verts |
| ZIP | 96 | git-free, byte-identical |
| Keys/OpenPGP | 93 | clés exactes, matrice négative incomplète |
| Supply chain | 60 | bootstrap RPM Fusion HIGH |
| GitHub Actions | 82 | actions pinées, signer tag non autorisé |
| shfmt | 98 | pin/hashes/tooling solides |
| ShellCheck | 98 | 0.9 et 0.11 verts |
| Tests mock | 76 | deux fixtures flaky |
| Tests real-tools | 94 | trois runs locaux + CI versionnée |
| Test-runner | 62 | race pré-inscription confirmée |
| Performance application | 84 | startup rapide, matrice partielle |
| Performance tests | 91 | jobs4 ~3,8×, échantillons limités |
| CI performance | 88 | full environ 43–53 s jobs4 |
| Dead-code hygiene | 91 | compat correctement conservée, un token mort |
| Architecture/coherence | 90 | responsabilités claires, fichiers encore gros |
| Maintainability | 86 | portée dynamique résiduelle |
| Headers | 100 | 46/46 |
| Comments | 96 | un claim process tree trop fort |
| Documentation EN | 94 | complète |
| Documentation FR | 92 | légère perte de précision |
| Manpages | 94 | CLI alignée, privacy wording |
| Error messages | 78 | MediaValidation non diagnostique |
| UX/fluidité | 82 | fluide hors erreurs externes/diagnostic |

**Moyenne brute : 86,3/100. Score global après plafond HIGH : 79/100.**

## 16. Release gates

| Gate | Statut | Preuve/action |
|---|---|---|
| Bugs | FAIL | findings HIGH/MEDIUM ouverts |
| Races production app | PASS partiel | aucune confirmée |
| Races test-runner | FAIL | 6/300 survivants |
| Flakiness | FAIL | annulation + staging fixture |
| Externals | FAIL | aria2 CVE, site tiers concerné |
| Tooling | PASS avec réserves | shfmt/ShellCheck verts |
| Keys actuelles | PASS | tag/RPM exacts |
| Packaging | PASS | RPM/DEB/ZIP exacts |
| Bootstrap Fedora | FAIL | RPM Fusion non épinglé |
| Release actuelle | PASS identité | immutable/attestée |
| Documentation | PASS avec INFO | petites ambiguïtés |
| Performance | PASS conditionnel | jobs4 efficace, séries incomplètes |
| GUI réelle | NON VÉRIFIÉ | opérateur requis |
| FFmpeg downstream security | NON VÉRIFIÉ | backports à qualifier |

## 17. Conditions pour revenir à GO et dépasser 95

Ordre recommandé pour une v2.3.1 :

1. porter dans `install-fedora.sh` la vérification RPM Fusion isolée déjà présente en qualification ;
2. fermer la fenêtre de signal du test-runner et ajouter un stress pré-inscription 300× ;
3. neutraliser aria2 HTTPS sur les builds GnuTLS non corrigés ou prouver un backport ;
4. imposer le fingerprint de signature du tag dans `release.yml` ;
5. intégrer les deux corrections de fixtures de signaux ;
6. améliorer le diagnostic MediaValidation et `--url-file` ;
7. qualifier/documenter site tiers concerné après fusion upstream ;
8. documenter les backports FFmpeg et rejouer une session Zenity réelle ;
9. compléter la matrice OpenPGP négative ;
10. relancer full jobs1/2/4/8 avec au moins sept mesures là où raisonnable.

Une optimisation qui contourne la supervision, diminue les vérifications cryptographiques ou retire une compatibilité de recovery sans preuve doit être rejetée.

## 18. Réponses explicites aux questions finales

| Question | Réponse |
|---|---|
| Tag/commit exact ? | Oui, `v2.3.0` → `d313f86...` |
| Release exacte et immutable ? | Oui |
| Signature du tag valide ? | Oui, fingerprint autorisée |
| Refactor sémantiquement sûr ? | Globalement oui, sauf race du nouveau runner |
| Bugs restants ? | Oui, findings listés |
| Races production ? | Aucune confirmée |
| Test-runner race-free ? | **Non** |
| Tests parallèles isolés ? | Majoritairement ; fenêtre startup et sessions échappées |
| jobs4 meilleur compromis ? | Probable, pas démontré par sept runs comparables |
| Fast profile correct ? | Oui comme profil rapide, pas release-equivalent |
| Full profile complet ? | Complet pour l’hermétique ; pas toutes qualifications réelles |
| Timing proche d’une minute ? | Oui en jobs4 exact CI |
| Accélérations sûres possibles ? | Oui, après correction runner et benchmarks |
| Sleeps inutiles prouvés ? | Non |
| Dead code ? | `SIGXFZ` seulement confirmé ; parser V1 probable deprecated |
| Compat historique utile ? | Oui pour staging/config/upgrade |
| Dynamic scope maîtrisé ? | Call-sites actifs oui ; contrats pas systématiquement sûrs |
| Autres shadowings type PR #45 ? | Aucun actif trouvé |
| aria2 privé fiable ? | Fonctionnel oui ; TLS GnuTLS à mitiger |
| yt-dlp compatible ? | Globalement, site tiers concerné non |
| Deno compatible ? | Oui, 2.9.6 |
| FFmpeg 6/8/9 ? | Fonctionnellement oui |
| FFprobe correct ? | Validation oui, diagnostic insuffisant |
| Zenity réel ? | Non rejoué pendant cet audit |
| Progress honnête ? | Oui selon mocks/intégrations |
| Cancel sans survivants ? | App non réfutée ; runner non |
| Runtime atomique ? | Oui selon tests disponibles |
| Package cleanup safe ? | Tests/stress verts |
| DEB non destructif ? | Oui selon lifecycle/upgrade |
| RPM cleanup correct ? | Oui selon jobs/tests |
| Manpages exactes ? | Oui hors nuance privacy |
| Headers/Purpose exacts ? | 46/46 |
| Commentaires vrais ? | Presque ; « complete descendant tree » à corriger |
| README EN/FR cohérents ? | Oui avec une omission mineure FR |
| TESTING exact ? | Ambigu sur la portée de `--full` |
| ShellCheck 0.9/0.11 ? | PASS/PASS |
| shfmt supply-chain safe ? | Oui dans le modèle actuel |
| Clés valides ? | Oui |
| Assets byte-identical ? | Oui |
| Performance correcte ? | Oui, preuves statistiques partielles |
| Optimisation dangereuse à refuser ? | Oui, toute baisse de supervision/sécurité/coverage |
| Refactoring inutile à refuser ? | Oui |
| Score réel ? | **79/100** |
| READY FOR DISTRIBUTION ? | **NON**, sous le seuil strict demandé |

## 19. Conclusion

La v2.3.0 est une base nettement plus cohérente que la série précédente : artefacts impeccablement reliés au tag, packaging sérieux, clés valides, tests réels riches, profils rapides et documentation globalement uniforme.

Elle ne satisfait toutefois pas encore le niveau « aucun problème actionnable, race-free, supply-chain complète » demandé. Le bootstrap RPM Fusion et la race du test-runner sont des blockers. aria2/GnuTLS, le signer du tag, la régression site tiers concerné et les fixtures flaky doivent aussi être traités avant de revendiquer une distribution professionnelle proche de 100.

**Verdict final : NO-GO — NOT READY FOR DISTRIBUTION — 79/100.**
