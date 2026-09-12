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
