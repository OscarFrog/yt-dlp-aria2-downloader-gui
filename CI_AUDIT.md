# Audit et optimisation CI/CD — 12 septembre 2026

Audit en lecture seule de `OscarFrog/yt-dlp-aria2-downloader-gui`, effectué le 12 septembre 2026 vers 10:35–10:52 UTC. Huit workflows lus intégralement, dont `shfmt-update.yml` (1316 lignes) et `release-docs.yml` (653 lignes). La première partie décrit l'état AVANT modification, correspondant à la release v2.3.14 / main `52286eb4f620dfc73ec810c0296f4d6780b697bd`. La section « Résultat implémenté » présente ensuite le changement local, la projection révisée après mesures et la validation effectivement exécutée.

Les huit fichiers inspectés sont `shell.yml`, `packages.yml`, `real-tools.yml`, `qualification.yml`, `stress.yml`, `release.yml`, `release-docs.yml`, `shfmt-update.yml`. Les sections CI/release de `TESTING.md` et `ARCHITECTURE.md`, le skill workflow/supply-chain et les règles de commande du dépôt ont été lus. L'audit runtime et tests détaillés complète cet audit distant.

## Méthode et limites des mesures

100 dernières exécutions de tous workflows (7–12 septembre), 20 dernières exécutions de release (24 août–12 septembre), 50 dernières exécutions de stress. Durées workflow = `updated_at - created_at` pour les runs terminés avec succès ; elles incluent les files runner, initialisations, transferts et éventuelles attentes. Jobs et étapes des PR #74, main correspondant et trois releases ont été inspectés. Les secondes job proviennent de `completed_at - started_at`. Ces mesures sont des observations, pas des garanties sur les prochains runners.

Les deux heures mentionnées dans la mission ne sont PAS reproduites par l'échantillon récent. Les releases réussies des 20 derniers runs prennent entre 9m27 et 13m48 (17 réussites, médiane 12m00). Les PR récentes sont dominées par les 14–18 minutes de stress. Ajouter les durées des jobs parallèles serait trompeur.

Sources : [100 runs](https://api.github.com/repos/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs?per_page=100), [20 runs release](https://api.github.com/repos/OscarFrog/yt-dlp-aria2-downloader-gui/actions/workflows/release.yml/runs?per_page=20), [PR #74](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/pull/74).

## Protections effectives, sans modification distante

[Ruleset main 21119508](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/rules/21119508), actif sur `refs/heads/main` : suppression et non-fast-forward interdits ; PR obligatoire ; squash seul autorisé par la règle (les réglages généraux du dépôt autorisent aussi merge et rebase, mais cette règle de main les restreint) ; branches strictement à jour pour les checks ; aucun acteur de bypass ; `current_user_can_bypass=never`. Aucune approbation humaine n'est obligatoire (`required_approving_review_count=0`), les discussions doivent être résolues. CodeQL doit respecter `medium_or_higher` et `errors`. Le endpoint de protection classique renvoie 404 « Branch not protected » parce que la protection est un ruleset, ce qui ne signifie PAS main non protégée.

Neuf contextes requis exacts, à préserver pour éviter une PR bloquée indéfiniment :

- `Fedora 44`
- `Ubuntu`
- `Local media, pinned yt-dlp 2026.6.9`
- `Local media, pinned yt-dlp 2026.8.19`
- `Fedora 44 RPM build-once`
- `Fedora 44 RPM (fresh)`
- `Fedora 44 RPM (ffmpeg-free)`
- `Ubuntu 24.04 DEB`
- `Mock process/cancellation stress (20x deterministic jitter)`

Python 3.10, yt-dlp 2026.7.4, l'archive et la matrice FFmpeg existent mais leurs noms ne sont pas required checks. Une preuve destinée à la release doit tout de même exiger leur réussite, afin de couvrir la qualification complète. Les contextes requis ne spécifient pas d'`integration_id` dans la réponse ruleset : vérifier des workflows/IDs/jobs GitHub Actions précis est plus fort qu'un simple texte « success ».

[Ruleset tags 21646097](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/rules/21646097), actif sur `refs/tags/v*` : update et suppression interdits, aucun bypass. Création des tags non interdite par ce ruleset ; la signature et l'autorisation du signer restent obligatoires dans release. [Immutable releases](https://api.github.com/repos/OscarFrog/yt-dlp-aria2-downloader-gui/immutable-releases) : `enabled=true`, `enforced_by_owner=false`.

## Déclenchements constatés

| Workflow | PR | push main | tag v* | Autre | Annulation obsolète |
| --- | --- | --- | --- | --- | --- |
| shell | Oui | Oui | Non | dispatch | Oui, workflow/événement/ref |
| packages | Oui | Oui | Non | Aucun | Oui, workflow/ref |
| real-tools | Oui, 3 yt-dlp figés | Oui, idem | Non | dispatch ; lundi version stable actuelle | Oui, workflow/événement/ref |
| qualification | Oui, FFmpeg 6/8/9 | Oui, idem | Non | dispatch | Oui, workflow/événement/ref |
| stress | Oui | Oui | Non | dispatch | Oui, workflow/événement/ref |
| release | Non | Non | Oui | dispatch depuis tag exact pour récupération | Non, sérialisation par tag |
| release-docs | Non | Non | Indirect | workflow_run completed de Release packages ; travail seulement si success | Non, par run release |
| shfmt-update | Non | Non | Non | lundi ; dispatch main | Non, groupe global |

Aucun workflow suivi ne se déclenche sur l'événement `release:`. Les runs `dynamic` CodeQL observés sont gérés par le service GitHub et ne viennent pas d'un neuvième fichier caché du dépôt. Leur configuration n'a pas été modifiée.

## Matrice des propriétés avant optimisation

| Validation | PR | main | tag/release | Nature |
| --- | --- | --- | --- | --- |
| syntaxe Bash, ShellCheck, statique, suites locales | Oui Ubuntu/Fedora/Python3.10 | Oui idem | Oui Ubuntu | contenu/systèmes/interpréteur |
| actionlint avec archive vérifiée | Oui Ubuntu | Oui Ubuntu | Non dédié | syntaxe workflows |
| run-all extraction sans `.git` | Oui archive | Oui archive | Oui ZIP final | absence Git + produit archive |
| yt-dlp 2026.6.9/2026.8.19 réels | Oui | Oui | Oui | même contrat local réexécuté |
| yt-dlp 2026.7.4 réel | Oui | Oui | Non | compatibilité intermédiaire |
| FFmpeg 6.1.1 / 8.1.2 / 9.0.1 | Oui | Oui | Non | générations complémentaires |
| compilation FFmpeg9 source signée | Oui | Oui | Non | même outil reconstruit |
| stress mock 20 jitters | Oui | Oui | Non | conditions temporelles complémentaires ; suites hors signaux répétées |
| runtime stress 10x / cleanup10x | Oui | Oui | Non | contention/répétition |
| résolution previous immutable + provenance | Oui | Oui | Oui | catalogue externe peut évoluer |
| RPM v4/v6,3x sur paquet partagé | Oui | Oui | Oui | signature testée sur candidats différents |
| RPM unsigned, fresh/ffmpeg-free, lifecycle | Oui | Oui | Non unsigned | artefact PR et mode dev |
| RPM signé, fresh/ffmpeg-free, lifecycle | Non | Non | Oui | octets finaux + vrai signer |
| DEB build/install/purge/reinstall/upgrade | Oui | Oui | Oui | artefacts construits indépendamment |
| lintian DEB | Oui | Oui | Non | analyse du paquet |
| signature tag annoté/signer autorisé/main/version | Non | Non | Oui | identité release intrinsèque |
| signature RPM dédiée hors checkout | Non | Non | Oui | objet signé final |
| signature DEB OpenPGP | Non | Non | Non | inexistante ; DEB couvert par checksums/provenance/release immutable |
| attestations de tous assets/checksums | Non | Non | Oui | provenance release |
| inventory et comparaison téléchargements publics | Non | Non | Oui | objets effectivement publiés |
| release-docs run-all après release | Non | Non | Seulement si NOUVEAU contenu docs/bump | tree réellement différent ; normalement no-op |

`run-all.sh` sans profil explicite prend le profil complet par défaut dans l'environnement CI. L'archive sans `.git` est un environnement différent, même lorsque les fichiers suivis coïncident : conserver une qualification archive initiale, puis vérifier mécaniquement le ZIP final sans rejouer le programme entier.

## Temps observés par workflow

| Workflow | Événement | n réussites | Médiane | Min–max |
| --- | --- | --- | --- | --- |
| Shell | PR | 9 | 2m39 | 2m14–5m08 |
| Shell | main | 5 | 2m43 | 2m05–3m19 |
| Packages | PR | 7 | 3m42 | 2m26–6m14 |
| Packages | main | 5 | 2m43 | 2m17–3m31 |
| Real-tools | PR | 9 | 3m39 | 3m22–6m53 |
| Real-tools | main | 5 | 3m38 | 3m29–3m54 |
| FFmpeg | PR | 9 | 6m20 | 5m03–9m17 |
| FFmpeg | main | 5 | 6m25 | 6m10–6m37 |
| Stress | PR | 7 | 16m54 | 13m45–18m27 |
| Stress | main | 5 | 17m38 | 14m36–18m25 |
| Release | tags récents | 2 | 12m47,5 | 12m27–13m08 |

## Mesures des étapes décisives de PR #74

[Shell](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34686801410) : jobs Ubuntu159s, Python3.10 152s, Fedora203s. Tests respectifs137s/130s/175s ; provisioning15–16s. Ces variantes restent complémentaires.

[FFmpeg](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34686801466) : upstream9 job387s dont compilation312s, qualification50s ; main équivalent395s, compilation318s, qualification54s. Ubuntu6 job86s/tests62s ; Fedora8 job127s/tests73s. Un cache authentifié de source/toolchain peut économiser CPU, mais ce job n'est pas le chemin critique actuel, dominé par stress.

[Packages](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34686801467) : archive171s dont146s suite ; RPM build36s ; DEB65s dont34s lifecycle/upgrade ; RPM fresh125s dont78s bootstrap ; ffmpeg-free104s dont31s bootstrap. Certaines files runner sont visibles : fresh démarre09:50:41 alors que rpm-build finit09:49:09 et previous-release09:48:58.

[Real-tools](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34686801418) : jobs182/196/214s selon yt-dlp ; routing3x35–47s ; aria2 comportement108–126s ; installation23–25s. Les trois routing runs parallèles coûtent surtout CPU, tandis que le comportement aria2 est le plus long composant. Les propriétés du chemin aria2 direct doivent être séparées des différences yt-dlp avant toute suppression de matrice.

[Stress](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34686801391) : quatre shards exécutent chacun cinq suites mock complètes,1096/1033/1031/892s de tests ; runtime161s ; cleanup7s. Environ70,8 minutes runner pour le seul stress, contre37,2 pour les quatre autres workflows PR cumulés. Répéter les assertions mock hors signaux pour chaque jitter est la principale cible intra-phase. Préserver les20 combinaisons/jitters et ne répéter que les groupes dépendant effectivement des variables jitter.

PR #74 consomme environ108,0 minutes runner au total, mais termine après18m27 en temps mural. C'est une autre explication possible d'un chiffre de deux heures, à ne pas confondre avec l'attente humaine.

## SHA commit vs tree : démonstration mécanique du squash

Pour [PR #74](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/pull/74) :

- HEAD branche : `c293123722cdb486e5c8f41b0d22d85fe4db298f`.
- Parent main au moment des tests : `933a15aba409e4fc165722113e03c98ae4cb5d7c`.
- Merge virtuel réellement checkout : `f5c97bae0f4ec4ba54db98646d2ba6e47daa1da3`, journal job Ubuntu103535084521, ligne « HEAD is now at f5c97ba Merge c293... into 933... », puis `git log -1 --format=%H`.
- Squash final main : `52286eb4f620dfc73ec810c0296f4d6780b697bd`.
- Tree des trois commits : **`96b5a08f52511f26ffaf936b1a4527fd00b9bcc7`**, lu séparément dans Git Database REST API.

[Merge virtuel API](https://api.github.com/repos/OscarFrog/yt-dlp-aria2-downloader-gui/git/commits/f5c97bae0f4ec4ba54db98646d2ba6e47daa1da3), [Squash API](https://api.github.com/repos/OscarFrog/yt-dlp-aria2-downloader-gui/git/commits/52286eb4f620dfc73ec810c0296f4d6780b697bd), [HEAD API](https://api.github.com/repos/OscarFrog/yt-dlp-aria2-downloader-gui/git/commits/c293123722cdb486e5c8f41b0d22d85fe4db298f).

Attention : `actions/runs/34686801410.head_sha` et `check-suites/93959557920.head_sha` valent le HEAD de branche, pas le merge virtuel réellement exécuté. `head_commit.tree_id` est également le tree HEAD. Les champs `pull_requests` de ce run et de cette check-suite sont désormais vides. Ne pas les utiliser seuls pour inventer un tree qualifié. `commits/{squash}/pulls` permet de retrouver PR74 après fermeture. Une preuve doit enregistrer le checkout réel quand il existe, puis le revalider contre Git et le run attendu. GitHub documente le merge virtuel pour `pull_request` ; tous les checkouts de ces cinq workflows utilisent la ref par défaut, aucun ne force le HEAD. [Événements GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).

Si main avance, le résultat de merge peut changer. Le mode strict interdit l'intégration normale d'une branche obsolète, mais la promotion doit encore comparer les trees exacts et les parents/HEAD de la PR. Toute différence échoue ; les commits d'égale version ou les anciens résultats de même nom ne suffisent jamais.

## Architecture avant : chemin critique réel

Pour v2.3.14 : dernier commit branche09:47:44 ; workflows PR09:48:30 ; dernier stress09:48:30→10:06:57 ; squash10:07:15 ; workflows main10:07:18→10:24:56 ; tag/run release10:08:09→10:20:36. Temps dernier commit→release vérifiée **32m52** ; workflow PR→release32m06.

La release part AVANT fin main et termine même AVANT le stress main. Il n'existe pas de dépendance vers les runs main, ni de preuve complète de qualification FFmpeg/stress consommée par la release. Les refaire en main dépense CPU, sans être un verrou réel de publication.

Si un mainteneur attend explicitement toute chaque phase comme décrit dans la mission, le même échantillon coûte **18m27 PR +17m38 main +12m27 release =48m32**, hors temps humain. Médianes récentes :16m54+17m38+12m47,5=47m19,5. Aucune base empirique pour annoncer120min récentes.

[Release v2.3.14 run](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34687642948), [release v2.3.11](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34112854426), [release v2.3.9](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34097895198).

Chemin release v2.3.14 : validate184s (suite167s) → real-tools critique219s → rpm-build32s → attente avant signer87s (Environment et/ou ordonnancement) → signature24s → RPM fresh115s → publish32s → fresh-download39s, plus inter-jobs. ZIP135s (suite119s) et DEB42s parallèles après real-tools. Intervalle avant `rpm-signing` observable1m27 entre fin build10:15:31 et début sign10:16:58 ; à distinguer des tests ; les timestamps jobs seuls ne répartissent pas cet intervalle entre approbation Environment et attente runner. Conserver le contrôle humain/environnement. Sur v2.3.11 attente2m55. Les full/archive/real-tools font perdre une partie importante du chemin avant construction, sans tester des fichiers différents lorsque le tree est identique.

## Duplications, déterminisme et réutilisation

| Répétition | Ce qu'elle valide | Identité/conditions | Recommandation |
| --- | --- | --- | --- |
| full checkout PR/main/tag | contrats du programme/test/mock/statique | PR merge virtuel, main squash, tag main ; égaux par tree dans exemple ; images distro/Python complémentaires mais Ubuntu main/release déjà couvert | Réutiliser preuve complète tree+profil+workflow ; refaire contrôles spécifiques Git/tag séparément |
| full sans Git PR/main/release ZIP | fonctionnement sans métadonnées Git | mêmes blobs suivis ; conteneur ZIP diffère par métadonnées timestamp/comment commit | Une qualification archive PR ; vérifier inventaire/modes/octet extraits ZIP final contre tree, sans full redondant |
| real-tools PR/main/release | downloader routing/progress/HLS/aria2 | mêmes pins hashés yt-dlp, fixtures loopback ; versions apt susceptibles d'évoluer | Preuve version/profil/tree ; nouvelle dépendance = nouveau candidat qualifié ; scheduled latest conservé |
| FFmpeg PR/main | générations6/8/9 | mêmes pins ; signature upstream9, build toolchain/distro susceptibles de changer | Une fois par candidat ; ne pas réduire matrice ; cache éventuel n'est qu'accélérateur |
| vingt FULL mock/shards | timing/process cleanup et nombreuses assertions non temporelles | vingt jitters définis, mais la majorité de la suite ne consomme aucun jitter | Conserver20 jitters pour groupe signaux ; full générale une fois |
| runtime10x/cleanup10x | contention/temp fichiers/cleanup | runtime compte aussi boucles internes10 ; cleanup surtout répétition identicale | Ne réduire qu'après inspection des points race ; coût faible hors chemin critique, priorité inférieure |
| routing3x/HLS3x | réseau/process local + conversion | mêmes fixtures ; nondéterminisme scheduling apporte un peu de couverture | Non équivalent à20 jitters ; abaisser seulement après justification, sinon une qualification candidat suffit |
| RPM semantics3x | format et signature + clés éphémères | plusieurs clés au hasard mais même contrats de signature ; distributions même version | Une exécution contient déjà plusieurs signers/scénarios ; vérifier test avant réduire ; coût peu critique |
| RPM/DEB PR/main | build et lifecycle mêmes sources | artifacts main reconstruits, pas nécessairement bit-identiques | Retirer rebuild main si preuves PR exactes ; release final construit/testé séparément reste justifié |
| package final release | signature véritable, données/modes/lifecycle/upgrade réels | nouvelles bytes RPM signé et nouveaux conteneurs paquets | Conserver tant qu'aucune promotion directe prouvée d'artifact final |
| previous-release PR/main/release | catalogue/version/précédent/provenance | catalogue de releases externe, pourrait évoluer même si tree identique | Résoudre/revalider au moment release ; ne réutiliser ancien baseline sans revalidation |
| release-docs full après succès | nouveau tree refs docs+bump, si modification | pas le tree publié ; workflow normalement no-op10–13s | Garder frontière verifier/publisher ; pas une répétition du même contenu |
| shfmt verifier full puis PR | candidat formatter isolé, nouvelle source version/formatage | tree peut être identique, environnement sandbox protection important | Hors chemin courant release ; ne pas retirer isolation/verifier pour économiser quelques minutes hebdomadaires |

Les suites hermétiques sont déterministes dans leurs entrées mais peuvent détecter des races nondéterministes. Des répétitions de gigue, OS, versions Python/yt-dlp/FFmpeg différentes sont des propriétés distinctes. En revanche le catalogue remote, les téléchargements distro, la validité actuelle des clés et la release précédente sont des entrées externes. Une preuve décrit un environnement/pin/révision ; elle ne promet pas que toute future version d'une dépendance se comportera pareil.

## Comparaison des mécanismes de preuve/promotion

- `needs` : verrou sûr au sein d'un même run ; outputs seuls trop transitoires pour une release future.
- Reusable workflows/composite/scripts : bonne source unique des commandes, mais ce n'est pas une preuve ; attention aux noms de checks qui peuvent être préfixés et aux règles existantes.
- Check/status `success` : insuffisant seul ; exiger workflow attendu, dépôt attendu, événement, run/attempt terminé, jobs attendus réellement `success`, paramètres et identité tree réellement testée. Un job skip doit échouer à la réutilisation.
- Artifact Actions : adapté à une petite preuve JSON portant commit/tree/profil, lié au run exact et SHA256 du transfert vérifié explicitement ; le pin download-artifact v8 de ce dépôt refuse déjà les digests incohérents par défaut (action.yml du SHA vérifié), et l'option explicite digest-mismatch:error rend cette garantie visible. L'identité immuable de l'artifact doit également être liée aux jobs qui l'ont testé. [Artifacts](https://docs.github.com/en/actions/tutorials/store-and-share-data).
- `workflow_run` : bon déclencheur de vérification indépendante, jamais preuve par son nom seulement ; vérifier le run REST et relire artifact comme données, sans exécuter candidate dans zone privilégiée.
- Attestations : lient digest, workflow, dépôt et source ; elles attestent l'origine, pas que tous les tests demandés ont réellement réussi. Vérifier aussi jobs/profil. Les permissions de signature attestation ne doivent pas être données à une PR/fork juste pour une optimisation. [Attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations).
- Cache : accélère un téléchargement ou une compilation ; aucune preuve de réussite. Clés exactes sources/outil/plateforme et revalidation des bytes restent nécessaires. [Caches](https://docs.github.com/en/actions/concepts/workflows-and-actions/dependency-caching).
- Promotion de packages PR : nécessite attestation/digest/build provenance sûrs, extraction de source exacte et respect signer final ; augmente la surface de confiance cross-run et impose artifact retention/récupération. Les packages sont construits en32–65s ici ; l'investissement n'est pas prioritaire devant les17m de stress répété et6m de préqualification release. Préférer petite preuve de qualification + build release exact une fois, signature/test des bytes finaux conservés.
- Candidat main vers tag : provenance plus simple car trusted branch mais ajouter un build préalable fait peu gagner sur builds30–60s et complique invalidation/recovery. Pertinent ultérieurement seulement si compilation produit devient coûteuse.

Pour réduire les ruptures : conserver les neuf required contexts actuels ; pas de modification distante des rulesets. Supprimer les déclencheurs lourds push main uniquement avec nouveau vérificateur d'identité fail-closed qui ne dépend pas d'un nom status seul, puis exiger la même preuve dans release. Une preuve absente/corrompue/révision ancienne doit produire un échec explicite et une procédure de qualification de remplacement, jamais un succès artificiel.

## Fail-fast et annulation

Les cinq workflows PR annulent déjà les révisions obsolètes via concurrency. Le nouvel agencement doit conserver cette règle. `cancel-in-progress:false` release évite d'interrompre signatures/publications ; conserver aussi les mutations automation sérialisées. Les matrices utilisent souvent `fail-fast:false` : utile pour diagnostic exhaustif mais coûteux quand une nouvelle révision arrive (couverte par concurrency).

Les validations rapides ne conditionnent pas actuellement les lourdes entre workflows. Un agrégateur/source commune et des jobs `needs` peuvent faire échouer rapidement syntaxe/static/version avant qualifications. Éviter de mettre le full complet2–3m en préalable strict de tous les jobs indépendants si un petit statique suffit : sinon le coût du fail-fast rallonge le chemin heureux. Les static contract et checks workflow ne devraient jamais attendre stress/compilation.

## Projection prudente avant mesure locale de la nouvelle architecture

Sans toucher stress : PR17–18m + preuve<1m + release6–7m ≈24–26m, contre48m32 si toutes les phases initiales étaient attendues séquentiellement :22m32–24m32 économisées,46–51%. Contre32m52 observées avec chevauchement :6m52–8m52 économisées,21–27%.

Avec répétitions ciblées du groupe signaux et les20 jitters conservés : le chemin PR devrait être borné par FFmpeg9 (~6m30) ou stress ciblé, plus statique/gates/files runners. Si ces derniers restent sous7m et la release à6–7m, objectif total14–18m, contre48m32 séquentiel (63–71%) ou32m52 réellement observé (45–57%). Ceci est une projection, à confirmer par premier run distant après intégration autorisée et mesure locale des groupes ; aucun nouveau workflow distant n'a été déclenché pendant l'audit.

## Données brutes locales

`/tmp/ci-audit-runs.json`, `/tmp/ci-audit-release-runs.json`, `/tmp/ci-audit-stress-runs.json`, `/tmp/ci-audit-duration-summary.json`, `/tmp/ci-audit-ruleset-main.json`, `/tmp/ci-audit-ruleset-tags.json`, `/tmp/ci-audit-immutable.json`, `/tmp/ci-audit-jobs-*.json`, `/tmp/ci-audit-pr74-*.json`, `/tmp/ci-audit-pr74-ubuntu.log`. Ces fichiers ne sont pas des tests exécutés localement : ils sont des réponses API/logs historiques consultés en lecture seule.


## Consommateurs à mettre en cohérence avec la promotion

`scripts/release-evidence-qualification.sh` exige actuellement dans `collect_exact_sha_runs` les succès de release/shell/packages/real-tools/stress sur le SHA exact du tag, plus qualification sur option `REQUIRE_EXTENDED_QUALIFICATION=true`. Il devient incompatible avec une suppression des runs lourds main après squash : le rapport post-release doit valider la nouvelle preuve tree, tout en conservant le run release sur commit exact et les contrôles scheduled récents. Mettre aussi à jour aide, rapport et `TESTING.md` section Post-release evidence qualification. `test-static.sh` contient des assertions sur les fonctions, la pagination et les noms workflows autour de ses lignes3360–3410.

`scripts/release-preflight.sh` a été lu intégralement : aucune exigence de runs main ou source exact SHA qualifiée ; il vérifie signature tag sur HEAD, arbre propre/version/docs, releases immuables, contrôle Environment et portée secrets, certificat RPM. Il reste applicable sans supprimer aucun de ses contrôles. Les deux README ne promettent aucun full run main, mais une courte explication équivalente de la preuve tree est souhaitable. Ne pas modifier les commandes manuelles de récupération release pour imposer une qualification redondante.

## Résultat implémenté — contrat de la tâche

Objectif et critères : qualifier le contenu candidat une fois dans chaque
condition complémentaire, vérifier son identité après squash, puis limiter la
release aux objets et entrées propres à la publication. Les neuf noms de checks
requis, les vingt tuples de stress, les matrices OS/Python/yt-dlp/FFmpeg, les
frontières de signature et les installations/upgrades réels sont conservés.
Autorité : modifications locales et lectures GitHub seulement. Aucun commit,
push, merge, tag, dispatch, réglage distant, secret ou publication autorisé ou
réalisé pendant cette tâche. La version reste inchangée pour ce travail local ;
le prochain push de sources devra appliquer la règle d'incrément du dépôt.

### Architecture après

```text
PR : merge virtuel GitHub
  └─ identité du checkout + cohérence version + syntaxe
      └─ shell : statique/actionlint/shfmt/ShellCheck + full Ubuntu/Fedora/Python3.10
          ├─ archive sans Git + RPM/DEB candidats/lifecycle/upgrade
          ├─ yt-dlp figés + aria2 + progression/HLS Ubuntu
          ├─ FFmpeg 6 spécifique / Fedora8 / compilation FFmpeg9 authentifiée
          └─ 20 tuples stress-signals + 10 cycles rollback + 10 cycles contention
              └─ check requis existant agrège TOUS les workflows
                  └─ SQUASH
                      └─ main : preuve d'identité seulement
                          └─ TAG signé
                              └─ preuve source + tag/signer/ancestralité/versions
                                  ├─ ZIP vérifié contre blobs/modes/chemins Git
                                  ├─ RPM construit → signé → installé/upgrade
                                  ├─ runtime Ubuntu actuel : routing/aria2 sur2 pins, progression/HLS1x
                                  └─ DEB construit → installé/upgrade
                                      └─ preuves source revérifiées
                                          └─ artifacts par IDs immuables
                                              └─ attestations/publication
                                                  └─ téléchargement public vérifié
```

Les workflows lourds n'ont plus de déclencheur `push main`. Les diagnostics
manuels et le contrôle hebdomadaire de la version stable actuelle restent
possibles. Les quatre qualifications complémentaires attendent la validation
shell, puis tournent en parallèle. Cela ajoute environ trois minutes au chemin
heureux, mais évite compilation/provisionnements coûteux sur un contrat shell
invalide. Les matrices échouent rapidement et les révisions PR obsolètes restent
annulées. Les publications restent sérialisées sans annulation automatique.

### Comptages après et justification

| Propriété | Avant PR/main/release | Après PR/main/release | Motif |
| --- | --- | --- | --- |
| full local | 4 / 4 / 2 | 4 / 0 / 0 | Les quatre environnements initiaux restent distincts ; la preuve remplace les relectures du même contenu |
| routing réel | 18 / 18 / 6 | 5 / 0 / 2 | Trois yt-dlp Ubuntu + Fedora8 + FFmpeg9 en PR ; deux pins d'origine sur dépendances distro nouvellement résolues en release |
| durée HLS | 18 / 18 / 6 | 3 / 0 / 1 | yt-dlp est mocké ; une exécution par génération en PR, puis une sur l'environnement Ubuntu actuel |
| progression FFmpeg | 6 / 6 / 2 | 3 / 0 / 1 | Indépendante de yt-dlp ; trois passages internes conservés par invocation, environnement actuel vérifié une fois en release |
| comportement aria2 réel | 3 / 3 / 2 | 3 / 0 / 2 | Les fallbacks natifs dépendent de yt-dlp ; chaque combinaison conservée sur les dépendances actuelles, cycles internes inchangés |
| RPM multisignatures | 3 / 3 / 3 | 1 / 0 / 0 | Une fixture contient déjà les signers/ordres/corruptions ; signature finale réelle contrôlée séparément |
| stress mock | 20 full / 20 full / 0 | 20 groupes ciblés / 0 / 0 | Tous tuples conservés, groupe signaux + annulation réseau + runtime erreurs/progression |
| runtime cycles, par famille rollback/contention | 100 / 100 / 0 | 10 / 0 / 0 | Retrait du multiplicateur externe ; contention/rollback cycliques internes conservés |
| cleanup répété hors full | 10 / 10 / 0 | 0 / 0 / 0 | Fixture déterministe déjà exécutée dans chaque full |
| packages finaux signés/installés | release | release | Objets nouveaux, dépendances actuelles et précédent immuable : propriétés complémentaires |

Les scénarios staging qui utilisent indirectement les délais de démarrage
attendent une barrière avant remplacement/injection ; leur état testé ne change
pas avec ce délai. Ils restent dans full. Les scénarios réseau et runtime ayant
un intérêt temporel sont inclus explicitement dans `stress-signals`, au lieu de
supposer que tous les consommateurs de jitter appartiennent au groupe signals.

La revue finale a confirmé une exception nécessaire : le tree et les pins ne
fixent pas toutes les révisions apt/dnf et leurs bibliothèques. Les lifecycle
installent les packages et vérifient leurs commandes, mais ne prouvent pas les
transferts et conversions réels sur ces dépendances nouvelles. `release-runtime`
conserve donc les deux pins yt-dlp d'origine avec routing et comportement aria2,
sans répétition externe ; progression FFmpeg/HLS ne passent qu'une fois, car
ces deux fixtures utilisent yt-dlp mocké. Le test aria2, lui, vérifie aussi les
fallbacks natifs yt-dlp et reste nécessaire pour chacun des deux pins.
Les versions des outils et l'inventaire des packages distribution sont consignés.
Cette qualification D coûte quelques minutes mais tourne désormais en parallèle
des builds/signature/lifecycle, au lieu de bloquer leur démarrage. La supprimer
exigerait une identité d'environnement vérifiable ou un refus explicite en cas
de dépendances modifiées ; une sonde hebdomadaire ne la remplace pas.

### Preuve et sécurité finales

Le vérificateur lit les API authentifiées GitHub et les objets Git immuables.
Le nom du job `Source identity <github.sha>` est produit par GitHub ; le checkout
est contrôlé contre ce SHA. Ni un artifact rédigé par un test ni un cache ne
peut fabriquer cette preuve. La validation lie workflow ID/path, dépôt et
branche HEAD, événement PR, dernier run/tentative, jobs ET étapes réellement
terminés avec succès, tree entier et parents du squash. Les exceptions skip sont
nommées et limitées aux scénarios conditionnels connus ; une suite sautée dans
un job vert est refusée. Les métadonnées sont relues avant acceptation, et le
transport API est borné pendant la lecture et annulable.

Aucune expiration calendaire arbitraire n'est appliquée : une qualification
historique d'un contenu/pins inchangé reste un fait. Un contenu/contexte modifié,
un nouveau résultat échoué ou incomplet, un workflow désactivé ou une preuve
retirée invalide la réutilisation. La sonde hebdomadaire conserve le suivi de
yt-dlp stable ; le helper post-release exige ses résultats récents. La release
résout et contrôle à nouveau ses dépendances d'installation, ses clés/signatures
et la release précédente. `release-runtime` exerce les transferts/conversions
avec les dépendances Ubuntu résolues pour cette publication. Cela ne qualifie pas automatiquement chaque nouvelle
version de dépendance ; la sonde hebdomadaire n'est pas un verrou de publication.

La validation initiale du tag exporte son commit et son objet annoté ; tous les
checkouts release utilisent le commit figé. Signer et publisher revérifient
l'objet du tag. Un dernier job sans permission d'écriture revérifie la preuve
après l'attente de signature et les tests des packages. Les zones privilégiées
n'exécutent pas les helpers du dépôt. Les artifacts release sont liés aux IDs
immuables des uploads consommés par les tests ; les downloads échouent sur ID
absent ou digest différent, et la vérification publique reçoit ces mêmes IDs.

Les nouveaux tests de ZIP comparent chemins, contenu, modes d'extraction,
plateforme du créateur et métadonnées des en-têtes locaux/centraux. Deux
contre-exemples trouvés en revue (exécutable rendu non exécutable par le champ
DOS, répertoire extrait avec mode000) sont désormais rejetés. Les champs Unicode
ambigus ou autres extensions que le timestamp Git attendu sont refusés.

Les données GitHub ne constituent pas une transaction atomique entre API et
publication. La stabilité des objets Git, les IDs artifacts, les règles de tag
immuable et les contrôles proches de la publication bornent cette frontière.
La suppression d'un fork ou des runs peut rendre une preuve indisponible :
refus explicite et nouvelle PR qualifiée, jamais acceptation présumée. Les
anciens tags sans jobs d'identité ne sont pas migrés par supposition. La reprise
ciblée d'une release utilise ses IDs artifacts existants ; leur expiration ou
suppression échoue explicitement et ne sélectionne pas un candidat homonyme.

### Prévision de gain

Après la qualification locale des vingt tuples de stress, la projection retenue
est **23–30 minutes** : environ17–21 minutes de PR (shell puis plus longue
qualification), moins d'une minute de promotion et5–8 minutes de release.
Les files runners et le délai humain d'approbation de signature peuvent ajouter
du temps ; ce dernier n'a pas de borne garantie. Les vingt tuples ont pris
13m54 sur quatre shards partageant un hôte local. Des runners séparés peuvent
réduire cette durée, mais les attentes de synchronisation restent nécessaires.
Un total20 minutes reste un objectif à mesurer, pas une promesse. Cette mesure
remplace l'hypothèse initiale15–25 minutes. La compilation complète FFmpeg9
(~5m12 observées) est conservée :
réduire son périmètre ou faire confiance à un cache binaire aurait changé une
garantie pour un gain non prioritaire. Le build propre à l'application ne coûte
que quelques dizaines de secondes ; aucune promotion de packages PR inter-run
n'est donc introduite.

| Référence | Avant | Après estimé | Gain absolu estimé | Gain estimé |
| --- | --- | --- | --- | --- |
| Parcours réellement observé avec chevauchement | 32m52 | 23–30min | 2m52–9m52 | 9–30% |
| Parcours attendant chaque phase | 48m32 | 23–30min | 18m32–25m32 | 38–53% |

Ce ne sont pas encore des durées GitHub de la nouvelle architecture. La première
PR autorisée devra confirmer le coût des gardes API, les noms et états réels des
steps, les files runners et le chemin critique final. Les cas forks sont testés
avec fixtures ; les PR récentes auditées proviennent toutes du dépôt canonique.
Le gain CPU devrait être supérieur au gain mural, puisque les répétitions
supprimées tournaient souvent en parallèle.

### Fichiers et responsabilités

- `shell.yml`, `packages.yml`, `qualification.yml`, `real-tools.yml`, `stress.yml` : qualification PR, gates et déduplication ; `promotion.yml` ajouté pour main.
- `release.yml` : preuve source, SHA figés, vérification ZIP, release-only et chaîne d'IDs artifacts ; signature/provenance/lifecycle conservés.
- `scripts/ci-validation.py` : source unique de vérification des métadonnées Actions et identité Git.
- `scripts/verify-source-archive.py` : identité mécanique du ZIP final.
- `scripts/release-evidence-qualification.sh` : rapport post-release utilisant la preuve tree au lieu de rechercher des full sur SHA squash.
- `tests/ci-validation-integration.py`, `tests/source-archive-integration.py`, `test-static.sh` : tests négatifs, mutations et invariants du graphe.
- `tests/mock-integration.sh`, `tests/ffmpeg-generation-qualification.sh` : groupe temporel ciblé et fixtures communes exécutées une fois.
- `TESTING.md`, `ARCHITECTURE.md`, `README.md`, `README.fr.md` : politique, reprise et explications cohérentes dans les deux langues.
- `tests/lib/project-files.sh`, `REPOSITORY_FILES.md` : inventaires exacts,100 fichiers.
- `CI_AUDIT.md` : présent rapport daté. `AGENTS.md`, skills, préflight, release-docs et shfmt-update inchangés : leurs frontières restent adaptées.

### Validation réellement exécutée

Environnement local final : Bash5.3.9, Python3.14.7, ShellCheck0.11.0,
aria2 1.37.0, FFmpeg/FFprobe8.1.2 et yt-dlp2026.08.19. Les vérifications de
grammaire Python3.10 ne constituent pas une exécution sous cet interpréteur ;
le job CI utilisant réellement Python3.10 reste conservé.

| Commande ou qualification | Résultat réel |
| --- | --- |
| `./tests/run-all.sh --doctor --json` | Prêt :49 exigences satisfaites,15 outils/capacités optionnels présents ; diagnostic sans suite |
| `python3 -B scripts/check-push-version.py coherence` | PASS, version de développement2.3.14 cohérente |
| `./scripts/check-workflows.sh` | PASS :9 workflows, actionlint1.7.12 et ShellCheck activé |
| `./scripts/check-shell-format.sh` | PASS :shfmt figé v3.13.1, options `-i 4 -ci -bn` |
| `./test-static.sh` | PASS ; inventaires, contrats de workflows, signatures et frontières privilégiées conservés |
| `tests/ci-validation-integration.py` |46 tests PASS : identité, squash, anciens runs, courses, skips, transport API et mutations du graphe, dont l'exception des dépendances distro actuelles |
| `tests/source-archive-integration.py` |15 tests PASS : ZIP exact et refus de contenus/modes/identités/métadonnées altérés |
| ZIP réel de `HEAD` initial |94 chemins, octets et modes vérifiés ; ce contrôle porte sur le commit initial, pas sur les modifications locales non commitées |
| `./tests/run-all.sh --full --jobs 4` | PASS final hors sandbox en260,825s :6 validations statiques et21 suites d'intégration, dont installation, packaging, cleanup, runtime, signaux et réseau local ; un précédent full avait passé en244,724s avant l'ajustement final du graphe runtime |
| Stress exact de `stress.yml` |20 tuples uniques sur20 PASS, quatre shards, mêmes six paramètres de jitter et mêmes limites ; groupe complet `stress-signals` à chaque passage |
| Runtime hardening ciblé | PASS avec10 cycles rollback et10 cycles contention |
| Package user cleanup ciblé | PASS |
| `tests/ffmpeg-generation-qualification.sh --compatibility-only` | PASS avec FFmpeg8.1.2 et yt-dlp2026.08.19 ; branche du wrapper vérifiée localement |
| `EXPECTED_FFMPEG_VERSION=8.1.2 EXPECTED_YTDLP_VERSION=2026.08.19 timeout --signal=TERM --kill-after=10s 30m bash ./tests/ffmpeg-generation-qualification.sh` | PASS : routage réel, progression FFmpeg, durée HLS et fixtures de compatibilité |
| `ARIA2_BEHAVIOR_BASIC_RUNS=3 ARIA2_BEHAVIOR_CANCEL_RESTART_RUNS=10 timeout --signal=TERM --kill-after=10s 12m bash ./tests/aria2-real-behavior-integration.sh` | PASS en environ198s :3 passages transport,10 quiescences,10 annulations/reprises et repli Referer natif ; outils locaux ci-dessus |
| Helper de rapport post-release, API simulée | PASS : routes d'authentification, refus de preuve absent/échoué et dépôt incorrect ; pas un rapport de nouvelle release publique |
| `./scripts/git-inspect.sh diff-check` et inspection des diffs | PASS ; aucun changement indexé, revue des modifications suivies et nouveaux fichiers |

Le stress a été lancé via `tests/repeat-qualification.sh` sur un worker
temporaire reproduisant le bloc shell exact du workflow : quatre shards
parallèles exécutant chacun cinq tuples. Durées respectives :824,141s,
827,275s,826,467s,833,786s ; temps mural833,994s. Les quatre shards partageaient
un même hôte ; ces chiffres ne sont pas quatre mesures de runners GitHub.

Échecs diagnostiqués pendant le développement : une assertion statique de la
liste des outils du signer devait intégrer `gh`, ajouté pour vérifier le tag
dans cette zone isolée ; contrat et assertion ont été corrigés ensemble.
Un passage ciblé de signaux, puis le premier full sous sandbox, ont échoué sur
les préconditions d'environnement : propriétaires de répertoires privés
remappés et création de socket loopback refusée avec `EPERM`. Le full a notamment
signalé `no safe writable local private temporary directory` et une exception
`PermissionError` à la création du serveur de test. Le diagnostic `--doctor`
avait réussi dans son contexte d'exécution ; il ne prouvait pas les capacités
du processus soumis aux restrictions du lancement suivant. Après diagnostic,
l'exécution hôte autorisée a passé la suite entière, sans modification des
contrôles de sécurité ni relaxation d'un test runtime.

Journaux locaux : `/tmp/ci-full-final.log` conserve l'échec sandbox ;
`/tmp/ci-full-final-host.log` le premier full réussi ;
`/tmp/ci-full-delivery-host.log` le full final réussi après le correctif runtime ;
`/tmp/ci-stress-qualification-ws1ihjya/qualification.log` les vingt tuples ;
`/tmp/ci-ffmpeg8-final.log` la qualification FFmpeg réelle complète ;
`/tmp/ci-aria2-final-qualification.log` le comportement aria2 réel. Ces fichiers
temporaires documentent cette session et ne deviennent pas des preuves de
qualification acceptées par la release.

Non exécutés pendant cette tâche : nouvelle PR GitHub, nouvelle promotion main,
matrices distantes Fedora/Ubuntu/Python3.10 et FFmpeg6/9, compilation FFmpeg9,
installation/upgrade des nouveaux RPM/DEB finaux dans leurs runners,
signature avec les secrets du projet, attestations ou publication. Les contrats
correspondants sont inspectés et protégés statiquement ; leur réussite n'est pas
présumée. La première PR autorisée devra valider le nouveau protocole avec les
métadonnées GitHub réelles et mesurer son chemin critique.

### Suivi de la PR75 : identité directement visible par CodeQL

Après l'autorisation de push, la version2.3.15 (`c061888`) a été soumise dans
[PR75](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/pull/75).
L'analyse Actions et Python a réussi, mais le
[check de sécurité CodeQL](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/runs/103549626215)
a signalé cinq nouvelles alertes élevées `actions/cache-poisoning/poisonable-step`
dans `release.yml`. Les références de checkout provenant de sorties de jobs
masquaient à l'analyse la contrainte shell existante `target_sha == GITHUB_SHA`.
L'inspection n'a pas démontré de contournement du garde par une PR.

Le correctif2.3.16 utilise directement `${{ github.sha }}` dans les dix checkouts
release. Les sorties restent des données de preuve ; le garde pré-checkout,
le signer autorisé, l'objet annoté, les permissions et la provenance restent
inchangés. Le dernier job exige lui aussi `SOURCE_COMMIT == GITHUB_SHA` avant
de vérifier la qualification du commit de l'événement. Les tests refusent
la réintroduction d'une référence issue d'un input, output ou tag dans chacun
des dix jobs, ainsi que la suppression du garde final. Aucune alerte n'est
dismissed et aucune règle CodeQL n'est désactivée.

La référence distante fraîche avant ce correctif donne main `52286eb`, branche
PR `c061888`, plancher2.3.15 et prochain PATCH2.3.16. Les48 tests de preuve/contrats
CI, actionlint sur9 workflows et le format shell passent localement. Le doctor
hôte confirme49 exigences satisfaites et15 capacités optionnelles disponibles.
La disparition des alertes doit être vérifiée sur le nouveau commit poussé ;
les tests locaux ne constituent pas une exécution du moteur CodeQL GitHub.

Sur `c061888`, toutes les qualifications distantes ont finalement réussi :
Ubuntu/Fedora/Python3.10, packages, trois versions yt-dlp, FFmpeg6/8/9, quatre
shards stress et runtime. Le
[dernier check requis](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34692289601/job/103550665274)
a terminé à12:06:07UTC, après un démarrage des workflows à11:55:21UTC :
**10min46 pour la qualification PR**. Le plus long shard stress a pris5min11 ;
[FFmpeg9](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34692289606/job/103550034833)
6min11. L'agrégat a attendu le dernier workflow puis réussi, sans deadlock.
Cette première mesure distante remplace l'estimation17–21min pour cette PR ;
elle ne mesure ni une release ni un parcours complet PR→publication.

Le correctif2.3.16 a passé `bash ./tests/run-all.sh --full --jobs 4` sur l'hôte
en235,007s, incluant le statique, ShellCheck et toutes les suites d'intégration
du profil full. Journal local : `/tmp/ci-codeql-fix-full.log`. La cohérence des
versions et le contrôle live-remote ont également réussi. Les longues matrices
distantes du nouveau commit restent à réexécuter par la PR puisque le contenu
et la version ont changé ; aucune release n'a été déclenchée pour ce contrôle.

## Phase 2 — optimisation locale mesurée, septembre 2026

Cette section concerne les changements locaux après le commit
`3c42d53a2927ed6efd1b4e048712b467c7e5f55a`, tree
`7a3b3d3d7c39c030a3e71ffcda39b6021188abf5`, développement **2.3.18**.
Elle ne doit pas être confondue avec les mesures et modifications historiques
ci-dessus. Le propriétaire a ensuite demandé un commit local après validation.
Aucun push, merge, tag, dispatch, changement de protection, signature ou
publication n'est autorisé pour cette livraison. Les résultats locaux
ne sont pas des preuves que le workflow release peut consommer.

### Architecture avant et après

La réutilisation PR → squash main → release existait déjà au début de cette
phase. La supprimer puis la réintroduire n'aurait produit aucun gain. Les pertes
restantes étaient surtout **à l'intérieur** des qualifications : assertions
Bash coûteuses sur de grands textes, un fork par PID à chaque recherche de
processus oubliés, suites Python cachées derrière un seul worker statique,
préparations répétées de fixtures et parcours média complets pour vérifier des
menus. Les workflows complémentaires attendaient en outre le workflow shell
complet, alors que leurs résultats ne dépendent pas de ses sorties.

Le DAG conservé/implémenté est :

```text
PR, checkout exact de chaque workflow
 ├─ identité/version/syntaxe → shell : Ubuntu, Fedora, Python 3.10
 ├─ identité/version/syntaxe → packages : archive, RPM partagé, DEB
 ├─ identité/version/syntaxe → real-tools : trois versions yt-dlp
 ├─ identité/version/syntaxe → qualification : FFmpeg 6/8/9
 └─ identité/version/syntaxe → stress : quatre shards + runtime
                               ↓
                 agrégat complet, cinq workflows requis
                               ↓
main squash : vérifier tree/parents/runs/attempts, sans requalifier les sources
                               ↓
release : preuve source + identité du tag
          → construction des candidats → signature isolée du RPM
          → tests des paquets finaux → nouvelle vérification de preuve
          → publication des mêmes artefacts identifiés et vérifiés
```

Le chemin critique PR est désormais le **maximum** des branches indépendantes,
plus leurs contrôles initiaux, provisioning et jonction finale ; pas la somme
shell + branche complémentaire la plus lente. Le gain réel dépend du runner et
doit être mesuré sur la prochaine PR autorisée. Les noms de checks, événements,
matrices, limites de jobs et conditions de l'agrégat sont conservés. Un échec
fonctionnel tardif du shell peut maintenant survenir après le démarrage de
travaux complémentaires : c'est un coût possible, pas un succès partiel admis.

Localement, un seul ordonnanceur borné exécute **12 tâches statiques**, dont
six familles Python explicites, puis les 10 suites FAST ou 21 suites FULL.
`test-static.sh` autonome reste complet ; `--source-only` est expressément un
bloc partiel, jamais une qualification autonome équivalente. Le nouveau test
de bootstrap augmente la couverture. Des mutants vérifient qu'une perte de
propagation de `--source-only`, une omission ou une répétition est détectée.

### Groupes de corrections et justification

| Groupe | Fichiers principaux | Cause racine et correction | Preuve / risque conservé |
| --- | --- | --- | --- |
| PERF-001, élevé, tests/processus | `tests/mock-integration.sh`, `tests/test-runner-integration.sh` | Lire les arguments NUL par `mapfile`, au lieu d'un `tr` externe par PID et par scan | Même recherche globale, mêmes exclusions et délais ; cas argv, disparition, processus étranger et orphelin ; ne pas restreindre aux seuls enfants vivants |
| PERF-016, élevé, CPU/tests | `test-static.sh` | Remplacer les suffixes Bash répétés par une recherche littérale bytes à curseur croissant | NUL, LF final, fragments vides, chevauchement, Unicode/octet invalide ; 150 comparaisons indépendantes ; ordre/non-chevauchement identiques |
| PERF-004, élevé, architecture/tests | `tests/run-all.sh`, `test-static.sh`, tests du runner/signaux | Sortir les replays Python imbriqués vers le même ordonnanceur, sans parallélisme imbriqué | Dispatch exact une fois, borne jobs 1/4, ordre des échecs, barrière statique, HUP/INT/TERM avec descendant Python |
| PERF-017, moyen, I/O/tests | `tests/release-docs-integration.py` | Préparer une fois les données inertes, puis copies privées par test | Pas de hardlinks ni état Git/API partagé ; ordre inversé, exécution filtrée, mutation et échec de préparation testés |
| PERF-005, moyen, tests GUI | `tests/mock-integration.sh` | Séparer preuve de menu/transfert d'URL et preuve du transport complet | GUI réelle, URL-file et validateurs réels pour chaque hôte ; E2E média représentatifs conservés ; pas de simple URL-file fabriqué par le test |
| PERF-002, élevé, réseau/runtime | `download-video.sh`, `private-aria2-plan.py`, tests helper/réels | Refuser aussi le résultat assemblé déjà présent, dans la vraie destination finale, avant les téléchargements de composants | Répertoire par descripteur et identité, liens et collisions refusés ; absence de GET/POST, conservation inode/octets ; le contrôle préalable n'est pas un verrou de publication |
| PERF-010, moyen, CPU/runtime | `progress-monitor.sh` | Affecter les compteurs/sommes à des variables de sortie ; supprimer 13 substitutions par événement V2 à deux flux connus | Même progression, plafonds et cadence ; 69 événements mixtes et 39 contrôles numériques différentiels indépendants |
| PERF-012, moyen, I/O/runtime | `download-video-gui.sh`, tests GUI-state | Une lecture `stat` initiale complète par journal, au lieu de quatre | Revalidation finale conserve identité, propriétaire, mode et mtime ; 13 cas de conservation/remplacement/erreur ; aucune hypothèse nouvelle CIFS |
| PERF-003, élevé, CI/DAG | quatre workflows packages/qualification/real-tools/stress | Remplacer l'attente shell par contrôles initiaux locaux, lancer les branches indépendantes | Agrégat complet et preuves immuables conservés ; suppression de permissions de lecture désormais inutiles, aucune permission ajoutée |
| PERF-014, moyen, CI/réseau | `scripts/ci-validation.py`, `scripts/release-preflight.sh`, tests CI | Mémo par objet Git validé et observateur ; un snapshot borné pour six champs du même Environment | Runs/attempts/PR restent frais ; état/identité des workflows revérifiés ; API en échec et JSON hostile refusés |
| PERF-009, élevé, cache/processus | `scripts/dev-tools/ensure-shfmt.sh`, nouveau test Python | Verrou stable, relecture sous verrou, publication atomique sans supprimer l'ancien exécutable | Six consommateurs, refus des liens, checksum/version, échec de téléchargement, interruption pendant verrou et nettoyage des sessions de test |
| PERF-018, élevé, synchronisation/tests | `tests/run-all.sh`, `tests/repeat-qualification.sh`, `tests/lib/test-runner.sh`, tests runner/signaux | Éviter la fenêtre de perte d'INT du traitement Bash d'un enfant au premier plan ; mode monitor et transition de session à PID constant | Signal réel à deux frontières de `wait_for`, transition bloquée HUP/INT/TERM, SID authentifié, vrai Ctrl-C en PTY ; aucun timeout augmenté ni second signal de rattrapage |

Les tests de transport lents ne sont pas supprimés parce qu'ils sont lents.
Les axes OS, Python, yt-dlp et FFmpeg restent distincts. Les mêmes tuples de
stress sont conservés. Aucun cache de résultat « vert », filtre de fichiers
modifiés ou réutilisation fondée seulement sur une version n'est introduit.

### Répétitions supprimées et frontières de réutilisation

| Information/propriété | Avant cette phase | Après cette phase | Identité / raison de conserver d'autres lectures |
| --- | --- | --- | --- |
| Six assertions ordonnées | Copies/recherches Bash coûteuses dans les suffixes | Un curseur croissant par assertion | Source bytes de l'invocation, pas de cache persistant |
| Processus du fixture | Un processus `tr` par PID/scan | Une lecture Bash par PID/scan | Tous les PID restent observés ; les scans successifs voient de nouveaux événements |
| Replays Python | Cinq familles séquentielles cachées dans statique | Six familles explicites, une fois chacune | La sixième est une preuve nouvelle du bootstrap, pas une répétition |
| Données inertes release-docs | Préparation complète pour chaque cas | Une préparation, copies privées | Les décisions, états API, dépôts Git et publications simulées restent propres à chaque cas |
| Menus par hôte | Transport et post-traitement pour chaque assertion de menu | Pont GUI/moteur ciblé ; transport qualifié séparément | La table d'hôtes et l'URL réellement transmise restent vérifiées |
| Objet Git de même SHA | Quatre GET redondants pendant les cinq preuves | Objet validé réutilisé dans le même observateur | Les métadonnées mutables sont revérifiées, y compris un workflow retiré pendant l'attente |
| Six champs Environment | Six réponses réseau potentiellement incohérentes | Une réponse bornée, six champs validés | Utilisateur authentifié et politique de déploiement restent deux preuves distinctes et fraîches |
| shfmt froid concurrent | Téléchargements et remplacement concurrents | Un téléchargement ; consommateurs relisent sous verrou | SHA-256 et version vérifiés aussi à chaud ; jamais de confiance dans le seul chemin cache |
| Vidéo directe déjà assemblée | Re-téléchargement de composants et POST | Refus avant transfert, pas de faux nouveau succès | La première extraction yt-dlp reste nécessaire pour connaître le nom final exact |
| Main/release | Réutilisation exacte déjà en place | Conservée et renforcée, pas de nouveau gain crédité | Tree/parents/runs/attempts et octets d'artefacts, jamais la seule version |

### Méthode et benchmarks

Baseline source propre et figée, hôte quatre CPU, Bash 5.3.9, Python 3.14.7,
ShellCheck 0.11, shfmt 3.13.1, FFmpeg/ffprobe 8.1.2, yt-dlp 2026.08.19,
aria2 1.37. Les benchmarks par paires n'exécutent pas de suites concurrentes
d'autres agents. Les durées murales incluent leur harnais lorsqu'indiqué.
Une première FAST sandbox a échoué en 96,32 s sur le propriétaire remappé d'un
répertoire : **ce n'est pas le baseline**. Doctor puis FAST/FULL hôte ont passé
sans affaiblir le contrôle de propriétaire. Les journaux de l'échec restent
conservés.

| Mesure isolée | Avant | Après | Gain absolu / relatif | Échantillon et limite |
| --- | --- | --- | --- | --- |
| Six assertions sources réelles | 13,295 s | 0,171 s | 13,124 s / 98,7 % | Médianes de trois passages |
| Scan global, hôte 257 processus | 0,9166 s | 0,0222 s | 0,8944 s / 97,6 % | Médianes de cinq paires ; dépend du nombre de processus |
| Release-docs complet | 16,570 s, 10 cas | 13,977 s, 12 cas | 2,593 s / 15,6 % | Nouveaux cas d'isolation inclus ; préparation seule 2,719 → 0,316 s |
| Quatorze menus, pont GUI réel final | 32,593 s | 8,811 s | 23,782 s / 73,0 % | Un passage isolé par variante ; trois mutations URL/chemin/mode rejetées ; inclut setup/cleanup |
| Progression, 100 événements, source finale | 1,9575 s | 0,5107 s | 1,4468 s / 73,9 % | Médianes de trois ; même sortie, service d'un backlog, pas gain sur le débit média |
| Nettoyage, 100 journaux récents | 1,726 s | 0,522 s | 1,204 s / 69,8 % | Médianes de trois paires ; `stat` 410 → 110 |
| Nettoyage, 100 journaux expirés | 6,672 s | 5,753 s | 0,919 s / 13,8 % | `stat` 1510 → 1210 ; mêmes 100 suppressions et 101 realpath |
| Expirés, huit ancêtres supplémentaires | 10,282 s | 9,096 s | 1,186 s / 11,5 % | Même profondeur, aucun gain réseau extrapolé |
| Nettoyage sans journaux | 0,051 s | 0,056 s | Aucun gain significatif | Bruit/harnais, ne pas promettre un lancement vide accéléré |
| Répétition vidéo locale déjà présente | 4,003–4,057 s | 2,407–2,466 s | Environ 1,59 s / 39,6 % | Deux fixtures indépendants ; 2 GET / 56 486 octets → 0 GET, inode/SHA conservés |
| Premier téléchargement de cette fixture | 4,190–4,212 s | 4,142–4,246 s | Pas de différence démontrée | Petit média loopback ; extraction/réseau/remux toujours réels |
| Bootstrap froid, six consommateurs | 6 téléchargements | 1 téléchargement | 5 acquisitions évitées / 83,3 % | Comptage déterministe sous entrelacements contrôlés, pas chronométrage WAN |
| GET pour preuve CI corrigée, même sécurité | 40 sans mémo | 36 avec mémo | 4 GET / 10 % | Le code historique non corrigé faisait 35 ; cinq lectures de sécurité ajoutées, net historique +1 |
| Endpoint Environment par préflight | 6 GET | 1 GET | 5 GET / 83,3 % | Ne retire ni lecture utilisateur ni politique ; pas de temps réseau inventé |

Le prototype de progression sur 1 000 événements donnait 19,845 → 5,312 s.
Après passage de nameref à `printf -v`, la **source finale** a été remesurée :
100 événements ci-dessus et un passage de 1 000 en 5,1042 s, hash de sortie
identique. Ne pas présenter les trois mesures du prototype comme trois mesures
de la version finale. Les gains de scan, menus, préparation et ordonnanceur se
recouvrent dans FAST/FULL : ne pas les additionner à leur gain global.

### Qualification globale et gain par étape

Les résultats globaux finaux sont consignés ci-dessous après gel et exécution.
Baseline admis : FAST **135,570 s**, FULL **303,760 s**, avec `--jobs 4`.
Chaque baseline est un passage complet ; aucune médiane globale n'est inventée.
STANDARD n'est pas un nouveau profil : la qualification normale/default reste
FULL. FAST est le profil quotidien existant ; REAL et STRESS restent des
qualifications supplémentaires décrites dans `TESTING.md`.

| Parcours local | Avant, PASS | Après, PASS | Gain mesuré | Portée |
| --- | --- | --- | --- | --- |
| FAST, développement quotidien, avant reprise SIGINT | 135,570 s | 79,952 s | 55,618 s / 41,0 % | Un passage complet par état ; ne comprend pas les nouvelles régressions de transition monitor |
| FULL, qualification normale, avant reprise SIGINT | 303,760 s | 195,007 s | 108,753 s / 35,8 % | Passage réussi antérieur au correctif SIGINT ; les échecs restent documentés ci-dessous |
| FAST final, correctif SIGINT inclus | 135,570 s | 79,090 s | 56,480 s / 41,7 % | Un passage final isolé, mêmes dix intégrations avec les nouvelles régressions runner |
| FULL final, correctif SIGINT inclus | 303,760 s | 200,070 s | 103,690 s / 34,1 % | Un passage final isolé, douze statiques et vingt et une intégrations, tous PASS |

Le FULL du premier point de reprise comprend douze tâches statiques et vingt
et une intégrations. Les plus longues intégrations de ce passage sont runtime-hardening (92,917 s),
GUI-state (75,086 s), signaux mock (66,813 s), engine-core (55,953 s),
GUI-progress (48,627 s) et réseau mock (47,093 s). Ces durées de tâches sous
concurrence ne sont pas des benchmarks isolés ni des durées à additionner.
Le contrat statique devient un ensemble de tâches dont la plus longue observée
est shfmt-version-handoff (27,473 s), au lieu de conserver les cinq familles
Python en série dans un seul worker.
Le temps CPU cumulé `user + system` de GNU time passe de 501,42 à 406,51 s
pour ce FULL : **94,91 secondes CPU évitées / 18,9 %**. Pour ce FAST, il passe de
168,58 à 149,60 s : **18,98 secondes CPU / 11,3 %**. Ce sont les mêmes paires
globales, pas des échantillons supplémentaires. Le gain mural plus grand que
le gain CPU est cohérent avec la combinaison travail supprimé/parallélisation.
Sur les sources finales après le correctif SIGINT, le CPU cumulé est de
420,80 s pour FULL (**80,62 s / 16,1 %** de moins que le baseline) et 153,27 s
pour FAST (**15,31 s / 9,1 %** de moins). Les écarts entre deux passages après
modification mêlent nouvelles régressions et variabilité hôte ; ils ne prouvent
pas à eux seuls le coût du changement de mode Bash.

Pour le lancement GUI sans historique, aucun gain global n'est démontré : le
microbanc de pruning vide reste autour de 50 ms. Avec cent journaux récents,
la phase mesurée avant le worker économise environ 1,2 s ; ce n'est pas un
chronométrage de toute l'interface. La préparation d'un premier téléchargement
et le téléchargement complet hors débit réseau n'ont pas de nouveau gain mural
global établi. Le premier petit transfert réel est inchangé dans le bruit ;
la répétition refusée économise environ 1,59 s et tout son transfert média.
La réduction CPU du moniteur ne doit pas être transformée en gain universel
de durée du téléchargement.

Les données GitHub existantes du cohort étudié en phase 2 montrent 826 secondes
**runner cumulées** dans quatre attentes shell, et une PR terminée en 590 s.
Cette cohorte qualifie le merge virtuel
`7207a69c264d7c3f8d122b53811f1da52588f61e`, et non littéralement le SHA local.
Références conservées : [shell](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34696964058)
et [stress / agrégat](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34696964087).
Retirer les quatre attentes ne prouve pas un gain mural de 826 s : une partie de
l'attente peut se déplacer dans l'agrégat final. À capacité identique, si S est
le chemin shell et H le plus long complément, S + H devient max(S, H), soit
min(S, H) d'attente supprimable, hors provisioning. Projection prudente pour ce
cohort : de quelques dizaines de secondes à environ trois minutes sur une PR
verte, **à confirmer à distance**, pas un pourcentage mesuré. La branche shell
de cette cohorte durait 199 s ; environ 199 s constituent la borne simplifiée
de chevauchement attribuable à cette barrière, pas une garantie de gain net.

Main était déjà une vérification de preuve
([23 s observées](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34697523722)) ;
pas de suite FULL supprimée une seconde fois. La
[release v2.3.17 observée](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/actions/runs/34695335820)
prenait 495 s, sur un autre commit que cette Phase 2, avec un
intervalle de 199 s non attribuable précisément entre approbation, file et
provisioning. Il n'est ni supprimé ni revendiqué comme gain. Les builders et
la signature release ne changent pas. Leur gain direct de reconstruction dans
cette phase est **zéro** ; l'archive de qualification bénéficie du runner local
accéléré. Le cycle commit → release peut gagner sur la PR et ses tests, mais
aucun nouveau cycle distant n'a été exécuté : pas de total chiffré fiable à
additionner aux mesures locales.

Les builders natifs exigent un worktree propre et RPM archive `HEAD`. Les
exécuter sur le checkout modifié ou contourner leur garde ne qualifierait pas
un paquet final. Les mesures ci-dessus précèdent le commit local demandé à la
reprise ; les constructions natives finales n'ont pas été exécutées. Le test de packaging local,
présent dans FAST/FULL, qualifie bien `install-tree.sh` en lib et libexec mais
n'est pas une construction RPM/DEB ni un cycle install/upgrade privilégié.
Un nouveau benchmark natif devra utiliser un commit propre exact, les deux
builders canoniques, un `SOURCE_DATE_EPOCH` contrôlé et un répertoire `/tmp`
privé ; il ne doit pas inventer une identité de release pour une fixture.

### Revue contradictoire, corrections et limites

Des agents non auteurs ont revu séparément CI/sécurité, tests/couverture,
runtime/filesystems et cache/processus. Leurs conclusions n'ont pas été
acceptées sans contre-exemples exécutables. Les deux dernières questions
« travail encore inutile ? » et « optimisation fragile ou dangereuse ? » ont
été examinées indépendamment.

Les contre-exemples ont conduit à corriger :

- un workflow désactivé ou remplacé pendant une attente pouvait encore être
  accepté ; l'observation finale revérifie maintenant état, chemin et ID ;
- le mémo d'objet Git masquait un sous-test de commit à deux parents ; chaque
  variante d'objet volontairement différente reçoit son propre observateur ;
- un `flock` au premier plan retardait le TERM jusqu'au délai de verrou ;
  acquisition par enfant enregistré + `wait` interruptible, nettoyage/reap ;
- les nouvelles sessions des fixtures shfmt pouvaient survivre à l'interruption
  du test Python ; handlers HUP/INT/TERM, enregistrement avant interruption,
  cleanup coopératif puis forcé borné et contre-tests du vrai unittest ;
- la preuve du manifeste simulé seule ne détectait pas un replay caché dans
  statique ; régression sur le vrai dispatch et quatre mutants ;
- le raccourci des menus ne prouvait plus le transfert GUI réel pour chaque URL ;
  pont réel GUI → fichier privé → validateurs, sans transport redondant.

Un défaut du nouveau harnais
`tests/shfmt-bootstrap-integration.py:test_interrupted_test_runner_cleans_separate_fixture_sessions`
a aussi été diagnostiqué : `select` sur un descripteur ne voit pas les lignes
déjà préchargées par TextIO. La lecture utilise maintenant `os.read` jusqu'au
séparateur, avec un délai de disponibilité, puis le test des trois signaux a
réussi. Ce défaut corrigé n'est pas la cause du timeout FULL INT ci-dessous.

Le premier FAST global modifié a passé en **79,952 s** (contre 135,570 s,
gain 55,618 s / 41,0 %). Le premier FULL modifié a terminé en 191,56 s avec
**un échec SIGINT du lanceur**, vingt autres suites d'intégration réussies et
les douze tâches statiques réussies. Ses 191,56 s ne sont donc **pas** un
benchmark FULL qualifié. Le journal original reste
`after-full-host.log` ; aucun délai ni assertion n'est allongé/relâché pour le
rendre vert. Des diagnostics de masques de signaux et d'enfants directs sont
ajoutés sans argv ni environnement sensible. Huit probes instrumentés, quarante
contrôleurs INT seuls et quatre contrôleurs conservant le préambule exact puis
HUP/INT ont passé. La dernière qualification FULL, après cet enrichissement,
a passé en **195,007 s**, dont 11,130 s pour la suite run-all-signal complète.
**À ce point de reprise, la cause du premier timeout restait ouverte.** Le
succès suivant ne prouvait ni une correction ni une origine environnementale.
L'investigation et le correctif ultérieurs sont détaillés ci-dessous. Le rapport local
`run-all-signal-diagnosis.md` conserve observations, limites et différences
entre le contre-exemple d'horloge artificiellement bloquée et l'échec réel.

Résiduel important : le POST yt-dlp sur destination **locale directe** possède
une fenêtre de collision après le préflight. Le correctif évite le cas déjà
présent mais ne rend pas ce POST atomique. Une transaction POST privée avec
plan rebâti/rebasé et publication finale no-replace serait un lot distinct,
à qualifier sur métadonnées, reprise et filesystems ; ne pas annoncer cette
race préexistante comme corrigée. La publication depuis workspace garde ses
protections existantes.

La CLI utilisateur et ses profils sont conservés. Deux évolutions d'interface
sont intentionnelles : `test-static.sh --source-only` est un nouveau bloc
partiel explicite ; le sous-ordre CI interne `wait-shell`, devenu sans appelant
après suppression de la barrière, est retiré avec sa méthode Python. Le refus
du final déjà présent devient un véritable échec (status 1), au lieu du faux
nouveau succès observé auparavant ; les deux README décrivent cette protection.

Restent aussi le polling final inter-workflows, la compilation FFmpeg 9 et les
entrées externes réellement fraîches. Un cache binaire de FFmpeg sans producteur
authentifié/toolchain exacte serait dangereux. Construire un RPM de release
depuis le paquet PR sans qualifier les octets finaux signés le serait aussi.
Trois substitutions par événement V2 et un probe de lisibilité par PID sont des
pistes mineures ; aucune suppression non mesurée de contrôles ou d'attentes de
quiescence n'est faite pour finir avec un meilleur chiffre.

| Piste de l'audit non implémentée | Motif / condition de reprise |
| --- | --- |
| PERF-006, compilation FFmpeg épinglée | Le coût historique est réel, mais un cache sûr doit authentifier producteur, source, recette et toolchain ; pas de simple cache PR par version |
| PERF-007, deuxième extraction native | Rejouer un plan peut changer live, expiration, cookies, fragments et métadonnées ; aucun gain WAN ni équivalence générale démontrés |
| PERF-008, probes/aide runtime | Les frontières candidat/installé et la fraîcheur restent nécessaires ; parseur groupé possible, mais pas de lot mesuré/qualifié dans cette phase |
| PERF-011, tail FFprobe | Une sortie compacte n'est pas une preuve de parsing équivalent ; drain, statut, timestamps et générations à qualifier avant changement |
| PERF-013, lectures du PLAN | Gain conditionnel sur gros JSON ; une fusion doit préserver identité, refus et chemins natifs/workspace, sans cap arbitraire sur un plan légitime |
| PERF-015, zombie adopté lors d'annulation | Attente conditionnelle démontrée dans l'audit, pas cause démontrée du FULL INT ; ne pas libérer l'ancre d'un groupe contenant encore un descendant vivant |

### Plan de suite recommandé

| Ordre | Fichiers / intervention | Gain attendu | Risque / non-régression nécessaire |
| --- | --- | --- | --- |
| 1 | Correctif SIGINT et régressions décrits ci-dessous : qualification finale et surveillance sur les autres versions Bash | Supprimer la fenêtre démontrée et les qualifications perdues, sans gain moyen chiffrable | Aucun allongement de délai ; HUP/INT/TERM, descendants résistants, masques et première demande conservés |
| 2 | Les trente-deux fichiers ci-dessous : revue du diff et commit local demandé après validation | Conserver les gains déjà mesurés, pas un gain supplémentaire | Refaire seulement les tests affectés par les retouches ; builders RPM/DEB canoniques sur le commit exact, sans contourner leur garde |
| 3 | Quatre workflows modifiés, `scripts/ci-validation.py` : PR seulement après autorisation et incrément requis au push | Chevauchement du chemin shell ; borne simplifiée 199 s dans la cohorte étudiée, gain net à mesurer | Toutes matrices/identités/attempts et gate final ; coûts sur PR rouge, provisioning, archive Git-free et lifecycle/upgrade réels |
| 4 | `download-video.sh`, `private-aria2-plan.py`, tests média/publication : transaction POST privée et plan rebasé | Éviter collision tardive et travail désormais inutilisable ; pas de secondes promises | Risque élevé pour les fichiers utilisateur ; no-replace kernel, chemins/métadonnées, cancellation, reprise et local/CIFS réels |
| 5 | `.github/workflows/qualification.yml`, éventuel producteur de toolchain : réemploi FFmpeg authentifié | Build historique environ 292 s runner par hit ; gain mural dépend du nouveau chemin critique | Producteur/source/signature/recette/compilateur/libs/architecture, cache hostile, miss, mêmes codecs et tests 6/8/9 |
| 6 | `runtime-manager.sh`, `download-video.sh`, helper PLAN : parseurs groupés puis replay/streaming seulement sur modes prouvés | Moins de probes/reparsing ; aucune nouvelle fourchette sans A/B | Garder chaque capacité requise, frontières candidat/installé, fraîcheur live/URLs, mémoire bornée, drain et refus des médias mutants |

Aucun acte distant, signature ou publication de ce plan n'est autorisé par sa
présence dans ce rapport.

### Validations réellement exécutées dans cette phase

Les résultats suivants portent sur la Phase 2, et non sur les succès historiques
décrits plus haut. Les durées de qualifications fonctionnelles qui pouvaient
chevaucher d'autres travaux ne sont pas utilisées comme benchmarks isolés.

| Validation | Résultat et portée |
| --- | --- |
| Doctor hôte `--doctor --json` | PASS : 49 exigences, zéro échec, 15 capacités optionnelles présentes ; capacité ne signifie pas qualification exécutée |
| `python3 -B scripts/check-push-version.py coherence` | PASS, développement 2.3.18 ; pas de contrôle live-remote de push non autorisé |
| `./scripts/check-shell-format.sh` | PASS, shfmt épinglé 3.13.1, 51 fichiers Bash canoniques ; contrôle autonome et inclus dans FULL |
| `./scripts/check-workflows.sh` | PASS, actionlint 1.7.12 avec ShellCheck, neuf workflows |
| FAST `--jobs 4` | Baseline puis version modifiée PASS, 135,570 → 79,952 s, mêmes dix intégrations |
| FULL `--jobs 4`, avant reprise SIGINT | Baseline PASS 303,760 s ; premier après FAIL 191,56 s ; suivant PASS 195,007 s, alors sans modification du timeout/superviseur |
| Contrat statique complet | Douze tâches finales PASS : source/identités/inventaires/versions, grammaire Python 3.10, shfmt, quatre inventaires ShellCheck et six suites Python |
| Suites Python finales | PASS : shfmt-version-handoff 14 cas, release-docs 12, push-version 30, ci-validation 62, source-archive 15, shfmt-bootstrap 10 ; total 143 cas unittest |
| STRESS final | PASS : vingt tuples distincts des six délais, quatre shards de cinq ; 20 succès de groupe, 426,35 s sur cet hôte, shard maximal 426,193 s ; pas de nouveau baseline global STRESS |
| Runtime renforcé final | PASS : `RUNTIME_HARDENING_ROLLBACK_RUNS=10 RUNTIME_HARDENING_CONTENTION_RUNS=10`, même timeout CI 2 min / grâce 10 s ; 84,13 s |
| REAL routage | `tests/real-tools-integration.sh` normal et `--simulate-network` PASS, yt-dlp 2026.08.19 / FFmpeg 8.1.2 / aria2 1.37 ; deux flux réels et répétitions refusées sans GET |
| REAL progression | `tests/ffmpeg-real-progress-integration.sh` PASS sur le moniteur final, trois passages internes ; mock FFmpeg et progression générale également PASS |
| Authentification aria2 | `tests/aria2-auth-headers-integration.sh` PASS, deux origines loopback, refus de fuite inter-origines ; inclus aussi dans FULL |
| Régressions ciblées | Scanner réel/orphelin, assertions ordonnées, dispatch réel et mutants, isolation seed/ordre inversé/filtre, helper/final existant, pruning 13 cas, pont GUI et trois mutations : PASS ; dernier FULL intègre les régressions permanentes |
| Revue contradictoire exécutée | 150 comparaisons d'assertions sous deux locales, 69 événements de progression mixtes et 39 compteurs, mutations de preuves CI, cinq probes cache/processus, interruption des vraies sessions bootstrap : PASS après corrections ; réserves conservées ci-dessus |
| Contrôles du premier point de reprise | Diff indexé vide, diff non indexé relu, `scripts/git-inspect.sh diff-check` PASS ; inventaire 101 fichiers, 13 Python, README EN/FR alignés ; SHA-256 des 51 Bash, 13 Python et neuf workflows identiques au gel de ce FULL/STRESS |

Les **21 intégrations FULL** effectivement passées sont : les neuf groupes mock
`signals`, `engine-core`, `engine-hls`, `engine-staging`, `engine-network`,
`gui-state`, `gui-progress`, `runtime-compat`, `runtime-validation` ; puis
`tests/test-runner-integration.sh`, `tests/run-all-signal-integration.sh`,
`tests/runtime-manager-integration.sh`,
`tests/runtime-manager-hardening-integration.sh`,
`tests/private-aria2-plan-integration.sh`,
`tests/aria2-auth-headers-integration.sh`,
`tests/progress-monitor-integration.sh`,
`tests/ffmpeg-progress-integration.sh`,
`tests/install-fedora-authentication-integration.sh`,
`tests/installer-integration.sh`, `tests/package-user-cleanup-integration.sh`
et `tests/packaging-integration.sh`.

Le mode autonome de `test-static.sh` a également passé pendant l'implémentation.
Sur le code final, son vrai dispatch est qualifié par les contrôles positifs et
les quatre mutants, sans relancer les six mêmes familles hors ordonnanceur.
Après consolidation documentaire, `bash ./test-static.sh --source-only` a
également passé (`static-doc-final.log`), sans répéter les intégrations et
replays inchangés déjà qualifiés par FULL.
Les replays Git/ZIP ont bien exécuté de vrais dépôts privés et archives ; ils
ne remplacent pas un FULL du futur ZIP final sans `.git`.

### Validations non exécutées et limites de livraison

- Aucun nouveau workflow GitHub PR/merge/package/release n'est déclenché : les
  chiffres distants après modification restent des projections. Aucune signature,
  publication, mutation de protection, secret ou environnement.
- Aucun build RPM/DEB final sur ce worktree modifié, ni installation/upgrade/
  purge privilégié, authentification d'un nouveau RPM signé, RPM 6 multisignature,
  preflight live de publication ou vérification d'une nouvelle release publique.
  Les builders exigent un commit propre ; le staging lib/libexec et la préservation
  des données utilisateur sont testés localement mais ne sont pas ces procédures.
- Aucun FULL d'une nouvelle archive Git-free de ces changements.
  Les quinze tests source-archive et les contrôles d'inventaire passent ; le job
  archive et la vérification des octets à la release restent obligatoires.
- Pas d'exécution réelle Bash 4.4, Python 3.10 ou des environnements Fedora 44 /
  Ubuntu 24.04 complets de la matrice. La grammaire Python 3.10 ne démontre pas
  la compatibilité runtime avec cet interpréteur.
- Pas de nouvelle matrice complète yt-dlp, FFmpeg 6/8/9, ni campagne complète
  `aria2-real-behavior-integration.sh` 3/10/10 ou qualification HLS/générations
  distincte ; le routage HLS/DASH local et les trois passages de progression
  FFmpeg 8.1.2 ne remplacent pas ces axes.
- Pas de vrai site externe, profil Firefox/cookies utilisateur, session Zenity
  interactive, montage CIFS/SMB réel ni mesure disque froid. Les fixtures privées
  et la simulation de destination permissive ne prouvent pas ces environnements.
- La perte de SIGINT de l'interpréteur est démontrée et contournée dans les
  deux lanceurs ; l'instruction exacte de l'échec naturel n'a pas été capturée.
  Ce n'est ni un correctif du Bash système ni une preuve sur toutes ses versions.

### Reprise SIGINT : cause démontrée et correction ciblée

PERF-018 est un problème de fiabilité avec un coût de performance : une
annulation perdue consomme son délai d'échec, puis invalide une qualification
entière. Sa fréquence réelle n'est pas estimable avec les échantillons
disponibles ; aucun gain moyen en secondes ou pourcentage n'est revendiqué.

La reprise a d'abord confirmé l'identité des sources du checkpoint. Un FULL
diagnostique a ensuite échoué en **188,04 s**, cette fois sur la garde du cas
SIGINT réentrant ; douze tâches statiques et vingt autres intégrations passent.
Un groupe concurrent réduit de trois suites voisines et cinq observations du
contrôleur a reproduit le timeout INT initial à sa deuxième observation
(campagne **77,12 s, FAIL**). Les succès des autres observations ne corrigent
pas cet échec. La capture montre une attente de commande au premier plan dans
une boucle Bash, sans blocage initial d'INT, et non le builtin `wait` à cet
instant. `do_wait`, l'absence de signal kernel pending ou `SigIgn=4`, pris seuls,
ne distinguent pas un report normal d'une perte de signal.

Un contrôle déterministe sur le **Bash 5.3.9 installé**, dont le build ID est
vérifié, a envoyé le même vrai SIGINT à deux frontières successives de
`wait_for`, sans changer les variables ou masques du processus :

| Signal reçu par le même script minimal | Sans monitor | Avec `set -m` |
| --- | --- | --- |
| Immédiatement avant l'appel à `waitchld` | Trap exécuté, sortie 130 | Trap exécuté, sortie 130 |
| Immédiatement après le retour de `waitchld` | Trap perdu, script poursuit jusqu'à 0 | Trap exécuté, sortie 130 |

La fenêtre est postérieure à la collecte de l'enfant mais antérieure à la fin
du traitement spécial d'INT au premier plan. Le signal peut y être enregistré
dans un état privé qui n'est plus consommé avant sa réinitialisation par une
attente suivante. Le contrôle sans monitor démontre la perte ; le contrôle avec
monitor démontre le mécanisme de contournement. L'attribution de l'échec
naturel à cette instruction précise reste **inférée**, car sa capture a eu lieu
après le timeout. Le comportement général des traps et attentes est décrit par
le [manuel GNU Bash](https://www.gnu.org/software/bash/manual/html_node/Signals.html) ;
les preuves du défaut lui-même sont les contre-exemples locaux, pas ce manuel.

Le changement minimal adopté concerne seulement les exécutables
`tests/run-all.sh` et `tests/repeat-qualification.sh` et leur superviseur :

1. Activer monitor dans ces deux lanceurs pour conserver le chemin ordinaire
   des traps ; ne pas modifier le Bash système ou les options des appelants
   qui sourcent la bibliothèque.
2. Avec HUP/INT/TERM bloqués, quitter le groupe provisoire créé par Bash en
   rejoignant celui du parent, puis appeler `setsid`, sans changer de PID.
   Toute erreur de transition sort à 70 avant de démarrer la commande.
3. Exiger **SID = PGID**, en plus de la preuve d'identité existante, avant de
   considérer le groupe comme dédié et de l'autoriser comme cible collective.
   Ce contrôle supplémentaire résulte de la revue indépendante du prototype.
4. Garder les délais, escalades, tokens, start times et codes 129/130/143 ;
   compléter uniquement le diagnostic de timeout de la garde réentrante.

Les régressions permanentes observent le mode réellement actif avant
l'initialisation des deux exécutables, refusent l'identité prématurée et
couvrent huit cas de transition : sorties normales 0/7, puis HUP/INT/TERM avant
et après le changement de groupe. Les signaux sont observés pending avant de
libérer la ressource attendue. Aucun GDB n'est requis par FAST/FULL. Une copie
privée supprimant seulement le contrôle SID a été rejetée par cette vraie
régression ; ce n'est pas une assertion de présence textuelle.

La contre-revue a également exercé un vrai Ctrl-C dans un PTY privé lorsque le
terminal appartenait à la commande au premier plan : statut 130 et disparition
des descendants. Quatre contrôles PTY conservent aussi les sorties et statuts
0/7, sans notification de jobs parasite. Des erreurs injectées séparément dans
`getpgid`, `setpgid` et `setsid` produisent 70, sans lancer ni forker la commande,
sans sortie ni divulgation du détail de l'exception. Le prototype a passé la
suite runner complète et la suite de signaux complète ; les vérifications
canoniques finales sont consignées séparément, sans transformer ces prototypes
en résultats du code livré.

Les diagnostics et journaux ont été conservés localement sous
`qualification-evidence/phase2-sigint-resume-2026-09-12.6HWrL2/`, notamment
`bash-wait-reap-window.py/.log/.md`, `bash-wait-monitor-control.py/.log`,
`monitor-prototype-independent-review.md`, `monitor-pty-review.jsonl` et
`monitor-oserror-review.jsonl`. Le checkpoint précédent et ses données de
benchmark sont recopiés dans
`qualification-evidence/phase2-resume-2026-09-12.cvqNgw/`. Ces chemins sont
ignorés par Git, exclus du commit et ne constituent pas une preuve distante
ou un artefact de release. Le présent document conserve la synthèse permanente.

### Qualification finale après le correctif SIGINT

Après stabilisation des sources et clôture de deux revues indépendantes
(SIGINT/processus, puis CI/runtime/supply-chain hors SIGINT), sans nouvelle
anomalie bloquante démontrée :

| Contrôle canonique | Résultat |
| --- | --- |
| Cohérence 2.3.18, syntaxe et ShellCheck des quatre sources SIGINT | PASS |
| Nouvelle régression monitor seule, contrôle d'interruption de son propre harnais | PASS ; le premier HUP/129 survit à un TERM pendant cleanup |
| `tests/run-all-signal-integration.sh` | PASS, 8,51 s, délais originaux |
| `scripts/check-shell-format.sh` | PASS, 51 Bash, shfmt 3.13.1 |
| `tests/run-all.sh --full --jobs 4` | PASS : 12 statiques, 143 tests unittest et 21 intégrations ; 200,070 s runner, 200,10 s GNU time |
| Runner et signaux dans ce FULL | PASS : 39,642 s et 11,703 s, avec les nouveaux cas et les voisins réels |
| `tests/run-all.sh --fast --jobs 4` | PASS : 12 statiques et 10 intégrations ; 79,090 s runner, 79,14 s GNU time ; exécuté séparément pour mesurer le profil final |
| Empreintes avant/après les deux suites | Identiques : 51 Bash, 13 Python, 9 workflows ; aucune modification de code pendant les mesures |

Ce sont deux mesures finales uniques, pas une médiane de répétitions. Le FULL
précède FAST ; aucune autre suite agent n'était exécutée en concurrence.
Les deux échecs diagnostiques de reprise restent FAIL et sont exclus des gains.
La première copie du prototype runner avait aussi échoué à 126 parce qu'elle
n'était pas exécutable ; la permission de cette copie privée a été corrigée
avant son succès. Cela ne concernait pas les permissions des scripts canoniques
et n'explique pas le défaut SIGINT.

Les journaux `canonical-signals.log/.time`, `final-full.log/.time`,
`final-fast.log/.time` et `final-source.sha256` restent dans le dossier ignoré
de reprise. La mise à jour documentaire finale n'impose pas de rejouer toutes
les intégrations inchangées : son contrôle statique ciblé et l'inspection Git
précèdent le commit local. Les qualifications distantes, natives privilégiées,
autres interpréteurs et filesystems réels non exécutés restent explicitement
listés plus haut ; ces succès locaux ne les remplacent pas.

### Fichiers modifiés

Trente-deux fichiers au total, dont un ajout ; aucune suppression de fichier :

- Workflows : `.github/workflows/packages.yml`,
  `.github/workflows/qualification.yml`, `.github/workflows/real-tools.yml`,
  `.github/workflows/stress.yml`.
- Runtime : `download-video.sh`, `download-video-gui.sh`,
  `private-aria2-plan.py`, `progress-monitor.sh`.
- Outils : `scripts/ci-validation.py`, `scripts/release-preflight.sh`,
  `scripts/dev-tools/ensure-shfmt.sh`.
- Tests : `test-static.sh`, `tests/run-all.sh`,
  `tests/run-all-signal-integration.sh`, `tests/test-runner-integration.sh`,
  `tests/mock-integration.sh`, `tests/private-aria2-plan-integration.sh`,
  `tests/real-tools-integration.sh`, `tests/ci-validation-integration.py`,
  `tests/release-docs-integration.py`, `tests/lib/project-files.sh`,
  `tests/lib/test-runner.sh`, `tests/repeat-qualification.sh`,
  **nouveau** `tests/shfmt-bootstrap-integration.py`.
- Documentation : `ARCHITECTURE.md`, `SHELL_STYLE.md`, `TESTING.md`,
  `REPOSITORY_FILES.md`, `README.md`, `README.fr.md`, `CHANGELOG.md`,
  `CI_AUDIT.md`.

Les journaux et contre-exemples de cette session sont conservés dans
`/tmp/yt-perf-phase2.3gxGRJ`, `/tmp/yt-phase2-tests.gMXrsq` et
`/tmp/yt-phase2-menu-bridge.wnomrvG6`. Ce dernier contient `MENU_BRIDGE.md`,
`menus-original.json`, `menus-bridge.json`, `mutations.log` et `gui-progress.log`
pour le pont GUI final. Le sous-répertoire `runtime.T2KJcln5` du premier chemin
contient les bancs runtime et `RUNTIME_PHASE2.md`. Ces fichiers temporaires ne
constituent pas un stockage durable ni une preuve de publication.

## Phase 3 — red team indépendante de la qualification

L'audit porte exclusivement sur le passage de
`3c42d53a2927ed6efd1b4e048712b467c7e5f55a` à
`a2ff3a9519dde14d4019767408c3342db9e609a6`. Les deux commits existaient
localement, avec ce parent direct, HEAD exactement au second commit et worktree
initial propre sur `fix/shfmt-candidate-container-permissions`. Le diff Git
confirme les 32 chemins annoncés : 31 modifications, un ajout, aucune suppression.
La référence Phase 2 reste immuable ; les corrections ci-dessous sont distinctes.
Aucune opération distante ni publication n'est autorisée par cette qualification.

### Défauts démontrés et corrections

- **RED-001 — ÉLEVÉ, CONFIRMÉ : annulation au terminal.** Le nouveau `set -m`
  permet à Ctrl+C de terminer un utilitaire foreground et de conduire directement
  à EXIT/130 sans passer par le trap INT du runner. Le cleanup utilisait alors
  TERM ; un worker Python ne déroulait pas son `finally`. Un deuxième Ctrl+C
  pouvait interrompre ce cleanup et laisser le worker vivant. Une autre fenêtre
  existait pendant le handshake avant l'enregistrement des tableaux PID, ainsi
  que pendant la suppression du fichier d'identité. Les vrais entrypoints BASE
  et HEAD ont été comparés dans des PTY privés, avec workers et descendants réels.
  Correction : garde non réentrante dans les deux cleanups, relais INT sur statut
  EXIT 130, enregistrement provisoire PID/start-time avant le premier utilitaire
  foreground, suppression de l'identité après enregistrement définitif. Le
  contrôle SID/PGID/token demeure obligatoire avant tout signal collectif.
  Huit cas PTY permanents couvrent les deux entrypoints et les fenêtres simple,
  double, handshake et suppression ; trois mutations retirant respectivement
  garde, relais INT et enregistrement provisoire sont rejetées.
- **RED-002 — MOYEN, CONFIRMÉ : timeout du nouveau scénario real-tools.**
  `subprocess.run(timeout=60)` tuait seulement le PID du moteur autonome par
  SIGKILL ; son worker et sa sentinelle, dans une autre session, survivaient.
  Le cleanup extérieur supprimait alors leurs fixtures. Une reproduction avec
  les vraies fonctions du moteur et un timeout contrôlé d'une seconde montre
  ces deux survivants, puis les récolte. Correction : capture explicite,
  HUP/INT/TERM enregistrés sans exception réentrante, relais coopératif au moteur,
  deux attentes bornées de 20 secondes pour son arrêt et son escalade interne.
  Le timeout du scénario reste 60 secondes ; statut et diagnostic initiaux sont
  conservés. Un arrêt non confirmé conserve les fixtures au lieu de supprimer
  l'état encore utilisé. La contre-revue a aussi démontré et corrigé trois défauts
  du prototype local : signal pendant armement du garde, OSError pendant
  capture du nettoyage et échec de création du marqueur de conservation.
  Celui-ci est désormais créé avant Popen : ENOSPC empêche tout lancement.
  Les régressions utilisent les véritables fonctions et
  traps du moteur ; des objets inertes couvrent le timeout d'escalade et l'erreur
  de capture sans créer de processus délibérément impossible à arrêter.
- **RED-003 — MOYEN, CONFIRMÉ : assertions real-tools désactivables.**
  `PYTHONOPTIMIZE=1` supprimait les dix nouvelles assertions de collision finale,
  tout en laissant afficher le message PASS. Un moteur témoin réécrivant le
  résultat était accepté. Le pilote utilise maintenant `python3 -I -`, qui
  conserve ces assertions malgré l'environnement hérité. Le test permanent
  exécute la vraie fonction shell et vérifie aussi qu'une copie privée retirant
  `-I` retombe sur ce faux succès. Les paramètres métier via `os.environ` restent
  disponibles ; aucun paramètre de transport utilisateur n'est changé.
- **RED-004 — MOYEN, CONFIRMÉ pour la fragilité d'observation ; attribution
  au FAST échoué PROBABLE.** La nouvelle assertion monitor exigeait la mort
  instantanée des descendants après récolte du leader. Un témoin réel reproduit
  110 fois sur 500 un enfant encore R avec SIGKILL pending après killpg et
  communicate du leader, puis Z sans autre signal (premier cas : 5,66 ms).
  L'assertion confondait ainsi une terminaison noyau asynchrone avec un orphelin.
  Correction limitée au test : vérifier PID/start-time autour de la lecture de
  SigPnd/ShdPnd, attendre au maximum une seconde seulement si KILL est déjà
  pending, puis exiger Z ou disparition. Un enfant vivant sans KILL échoue
  immédiatement ; aucun signal supplémentaire ni retry de suite n'est ajouté.
  Les diagnostics incluent désormais cas, étape, signal et identité. Le journal
  du FAST historique ne contenait pas cet instantané : son attribution précise
  ne devient pas CONFIRMÉE par ce témoin indépendant.

Aucun fichier runtime, workflow ou builder n'est modifié par ces
corrections. Elles ne retirent aucun test et ne changent ni les profils ni le
nombre de jobs. Les nouveaux scénarios ont un coût de qualification explicite ;
la fiabilité prime sur la conservation exacte d'un chronométrage antérieur.

### TESTS VALIDÉS COMME RÉELLEMENT REDONDANTS

| Travail ancien | Propriété et remplacement | Conclusion |
| --- | --- | --- |
| Cinq familles Python imbriquées dans le statique | Mêmes scripts et interpréteur, une tâche explicite chacune ; manifeste et mutations de dispatch | Déplacement, aucune suppression ; confiance élevée |
| Préparation release-docs par test | Seed inerte copiée sans hardlinks ; API, Git et mutations propres à chaque test | Préparation redondante, isolation testée |
| Quatre attentes CI de la fin de shell | Même qualification complète exigée par le gate terminal et la preuve de promotion | Ordonnancement redondant pour l'acceptation ; travail sur PR rouge potentiellement accru |
| Transport complet de 14 cas GUI/host | GUI et validateurs moteur réels jusqu'à la frontière PLAN, puis transports représentatifs conservés | Propriétés menu, classification et handoff préservées ; contexte E2E complet différent |

FAST garde les 10 mêmes intégrations, FULL les 21 mêmes. La phase statique
passe de 6 à 12 tâches : les cinq familles déplacées et le nouveau bootstrap
shfmt expliquent cette différence. FAST n'est pas une qualification release ;
`test-static.sh --source-only` n'est pas le contrôle statique autonome complet.
Le changement d'attendu de la collision MKV de 0 à 1 est un changement de contrat
documenté dans les deux READMEs, destiné à préserver le média existant.

### TESTS À RÉTABLIR OU À CORRIGER

Les tests de signaux envoyés au PID ne suffisaient pas à qualifier Ctrl+C au
terminal : les huit nouveaux cas ferment cette lacune. Le timeout et les
assertions du nouveau test real-tools demandaient les corrections RED-002/003.
Aucun rétablissement des cinq familles Python ou des 14 transports GUI n'est
justifié par un défaut démontré. L'équivalence des menus est compositionnelle,
et ne doit pas être présentée comme identité de chaque exécution E2E antérieure.

### Mesures indépendantes et dénominateur

Clones locaux séparés aux deux SHA exacts, mêmes outils hôte, jobs 4 et cache
shfmt chaud. Ces passages sont exploratoires : de petites reproductions ont
chevauché la campagne, sans autre FULL/FAST ou qualification real-tools lourde.
Un passage valide par case ne constitue pas une distribution statistique.

| Profil | BASE déclaré Phase 2 | HEAD déclaré Phase 2 | BASE red team | HEAD red team | Gain red team |
| --- | ---: | ---: | ---: | ---: | ---: |
| FAST | 135,570 s | 79,090 s | 128,675 s | 82,091 s | 36,2 % |
| FULL | 303,760 s | 200,070 s | 264,752 s | 200,287 s | 24,3 % |

Les durées utilisent le même chronomètre runner. CPU FULL : 498,00 → 419,60 s,
soit 15,7 % économisés, proche des 16,1 % historiques. Le CPU BASE varie peu
alors que son temps mural varie beaucoup ; les gains muraux 34,1 %/41,7 % sont
des observations uniques, pas des constantes indépendamment confirmées.
Un deuxième HEAD FAST a échoué à 77,887 s wrapper sur
`monitor cancellation left an original child alive` : **FAIL exclu des gains**.
L'absence de reproduction sur six diagnostics ciblés ne transforme pas ce
passage en PASS ; RED-004 conserve explicitement la limite d'attribution.
Le premier FULL en sandbox, échoué à 109,55 s avec propriétaires
65534 et sockets EPERM, est également exclu ; les tests hôte lèvent ces
restrictions d'environnement sans changer les sources.

Microbancs alternés BASE/HEAD sans autre suite concurrente, mêmes entrées et
sorties vérifiées ; valeurs min / médiane / max en secondes :

| Mesure | n par état | BASE | HEAD | Gain médian |
| --- | ---: | --- | --- | ---: |
| Six assertions, même corpus | 3 | 13,235 / 13,276 / 13,486 | 0,154 / 0,157 / 0,163 | 98,8 % |
| Scan global, 265 processus | 5 | 0,915 / 0,939 / 0,985 | 0,017 / 0,020 / 0,022 | 97,9 % |
| Progression, 100 événements | 3 | 1,926 / 1,929 / 2,005 | 0,482 / 0,521 / 0,567 | 73,0 % |

Ces gains ne s'additionnent pas. Aucune accélération du premier téléchargement,
du packaging final, de la release ou du cycle commit → release n'est mesurée.
Le vérificateur CI fait historiquement 35 → 36 GET : quatre lectures Git
immuables évitées, cinq relectures de workflow ajoutées. Le 40 → 36 documenté
compare deux variantes au même niveau de sécurité, pas BASE à HEAD. Les 826 s
d'attente CI cumulées restent distinctes d'une durée murale PR.

### Identité CI, objets et frontières non exécutées

Les quatre workflows modifiés ont été intégralement relus. Les PR qualifient le
SHA de merge synthétique, pas seulement `pull_request.head.sha`. La promotion
du squash exige arbre entier et parents exacts ; aucun cache de succès mutable
ni artefact PR ne devient un paquet release. Les objets release sont construits,
puis signés/testés selon leur type, transmis par IDs immuables et digest fatal,
et publiés sans reconstruction. Les permissions des quatre jobs identity sont
réduites ; les checkouts restent sans credentials persistants. Aucun nouvel
`actions/cache`, secret ou privilège n'est introduit. Les groupes de concurrence
des workflows sont distincts ; une cohorte annulée ne satisfait pas le gate.

Deux paquets natifs ont été construits et leurs inventaires/modes/liens/octets
inspectés depuis le clone HEAD propre : RPM format 4 non signé Fedora 44 et DEB
all, tous deux version 2.3.18. RPM transforme cinq shebangs par son BRP Fedora ;
la comparaison exhaustive conserve cette transformation explicite. Ce sont des
builds locaux, pas les objets finaux signés/installés de release.

- **NOT TESTED / REQUIRES REMOTE CI** : cohorte réelle aux SHA exacts, dernières
  tentatives/reruns, supersession A → B → C, timeout identity de 3 minutes,
  matrices OS/outils et vrais rulesets/environnements. Risque de disponibilité
  et d'intégration moyen ; aucune release sans réussite des gates distants.
- **NOT TESTED / REQUIRES REAL NATIVE PACKAGE** : objets finaux signés,
  installations, réinstallations, upgrades depuis release immuable, suppressions
  sur OS jetables, attestation et téléchargement public. Les builds locaux ne
  lèvent pas ces conditions de release.
- **NOT TESTED / REQUIRES REAL CIFS/SMB** : aucun montage réel disponible.
  Les vérifications locales de destination et la simulation de permissions ne
  qualifient ni latence, ni inode, ni verrouillage/rename/fsync du serveur SMB.
  Le préflight MKV n'est pas une réservation atomique jusqu'au POST ; cette
  limite locale tardive était déjà documentée. Le cache shfmt privé local reste
  distinct d'une destination réseau permissive.

### Qualification finale et verdict après corrections

Après la double revue indépendante et stabilisation des cinq fichiers de code,
un FULL corrigé puis un FULL BASE ont été exécutés séquentiellement sur l'hôte,
jobs 4, cache shfmt chaud, **sans aucun autre test concurrent**. Doctor et
cohérence ont précédé chaque passage ; les empreintes des sources Bash/Python
et workflows sont identiques avant/après chacun. Il s'agit d'une paire, pas
d'une médiane de répétitions.

| Mesure finale isolée | BASE | Code corrigé Phase 3 | Gain observé |
| --- | ---: | ---: | ---: |
| FULL, chronomètre runner | 257,830 s | 202,611 s | 21,4 % |
| FULL, wrapper | 257,878 s | 202,674 s | 21,4 % |
| CPU user + system | 493,16 s | 422,31 s | 14,4 % |

Le FULL corrigé passe les 12 tâches statiques, 143 tests Python et 21 suites
d'intégration. Le runner enrichi passe en 47,606 s et les signaux run-all en
11,610 s sous concurrence. La comparaison finale conserve donc un gain utile
avec davantage de preuves d'annulation. Les 34,1 %/41,7 % historiques ne sont
pas reproduits comme constantes ; aucun FAST corrigé distinct n'a été relancé
uniquement pour afficher un pourcentage, son contrat étant inclus dans FULL.

Les qualifications ciblées passent : runner complet avant les derniers
durcissements du pilote, puis régressions finales extraites des vraies fonctions,
signaux run-all, helper private-aria2-plan avec copie réelle entre devices,
real-tools local et simulation, puis real-tools local sur le pilote final.
Les replays ci-validation (62 tests), bootstrap (10 tests), actionlint sur les
9 workflows et shfmt canonique passent. FULL reprend syntaxe, compilation Python,
ShellCheck et l'intégralité du contrat statique final. Les diagnostics attendus
des injections d'erreur ne sont pas des échecs masqués.

Les équipes adverses convergent après avoir contesté les correctifs. L'équipe
qui a démontré RED-004 a corrigé son seul test ; l'autre équipe a contre-relu
ce changement et vérifié indépendamment ses contrôles négatifs. Le mécanisme
RED-004 est confirmé ; la cause exacte du FAST antérieur reste probable.
Les journaux FAIL restent conservés et exclus des chiffres de succès.

**ARCHITECTURE VALIDÉE AVEC RÉSERVES après corrections.** Le commit Phase 2
initial nécessitait RED-001/002/003/004 ; aucun autre défaut bloquant n'est
démontré par la revue finale. **RELEASE VERDICT = GO WITH CONDITIONS** : obtenir
la cohorte CI réelle du code final et ses identités/protections, qualifier les
objets natifs finaux et l'archive sur leurs environnements de release, et
qualifier une vraie destination CIFS/SMB avant d'en annoncer la compatibilité
sans réserve. Ces conditions n'autorisent aucune publication pendant cet audit.

Les journaux, contre-exemples et paquets de cette red team sont conservés sous
`/tmp/phase3-*`, hors inventaire suivi. Ils ne sont ni des artefacts publiés ni
une preuve durable de release. Les résultats locaux ne doivent pas être
substitués aux qualifications finales ci-dessus.
