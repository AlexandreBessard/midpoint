# Déploiement MidPoint sur AWS ECS — guide DevOps

Ce document explique comment déployer MidPoint sur ECS et comment synchroniser la
configuration métier (le dossier [`objects/`](objects/)) depuis ce repo GitLab vers
l'instance déployée. Aucune connaissance préalable de MidPoint n'est nécessaire.

## 1. Contexte en une minute

- MidPoint est une appli Java qui stocke toute sa configuration (rôles, connecteurs,
  règles de synchronisation...) dans une base Postgres, appelée son *repository*.
- Ce repo GitLab **n'est pas l'application** : c'est une copie exportée en XML de la
  configuration métier ANETT (dossier `objects/`, un sous-dossier par type d'objet).
- Le déploiement a donc deux volets bien séparés :
  1. faire tourner le conteneur MidPoint (image `evolveum/midpoint`) ;
  2. réinjecter le contenu de `objects/` dans son repository à chaque changement,
     via l'outil en ligne de commande `ninja.sh` (embarqué dans l'image officielle).

Une fois la config importée, **un redémarrage du service `midpoint` est nécessaire**
pour qu'il prenne en compte le changement (voir §5) : `ninja.sh` écrit toujours
directement dans la base Postgres, jamais via l'API de MidPoint (voir §4).

## 2. Composants AWS

| Composant | Rôle |
|---|---|
| ECS Fargate — service `midpoint` | fait tourner l'appli en continu (port 8080) |
| ECS Fargate — task `midpoint-import` | tâche ponctuelle (*run-task*, pas un service) qui importe `objects/` |
| RDS Postgres | le repository MidPoint (rôles, ressources, tâches, historique...) |
| EFS, monté sur `/opt/midpoint/var` | `midpoint-home` : `config.xml`, keystore, logs, **et les fichiers CSV** lus par les connecteurs CEGID/ADP/HQZ (`import/*.csv`) — nécessaire dès qu'il y a plus d'une task |
| Secrets Manager | mot de passe RDS (utilisé par `midpoint` **et** par la task `midpoint-import`, voir §4) + mot de passe du compte `administrator` (utilisé une seule fois, au tout premier boot de `midpoint`, voir §6.2) |
| ECS Service Connect (ou ALB interne) | optionnel pour ce flux : la task `midpoint-import` parle directement à RDS, pas à `midpoint`. Utile seulement si autre chose a besoin d'un DNS interne stable vers `midpoint` |

L'image Docker utilisée pour les deux task definitions est la même : celle buildée
depuis le [`Dockerfile`](Dockerfile) de ce repo, qui embarque déjà `objects/` et
[`import-config.sh`](import-config.sh).

⚠️ `credentials.kdbx` (coffre-fort local, gitignoré) ne doit jamais être copié dans
l'image ni dans un secret — il est hors scope du déploiement.

## 3. Ordre d'import de `objects/`

Les objets MidPoint se référencent entre eux par OID (un rôle référence un
archétype, une ressource référence un archétype, un archétype référence un
template...). Pour éviter les erreurs de référence manquante, `objects/` doit être
importé dans cet ordre (déjà implémenté dans `import-config.sh`) :

```
schemas → valuePolicies → securityPolicies → lookupTables → marks → sequences
  → objectTemplates → archetypes → roles → orgs → services → policies
  → objectCollections → dashboards → reports → systemConfigurations
  → resources → tasks
```

Exemples concrets de dépendances vérifiées dans ce repo : la ressource `HQZ` référence
l'archétype `Interimaire` ; l'archétype `Person` référence `PersonObjectTemplate` ;
`PersonObjectTemplate` référence la séquence `UserPersonalNumberSequence`.

`objects/simulationResults/` est volontairement exclu de l'import : ce sont des
exports de simulations, pas de la configuration.

## 4. `ninja.sh` n'a pas de mode REST — il écrit toujours directement dans Postgres

⚠️ Une version antérieure de ce document décrivait un "mode REST" pour `ninja.sh`
(`-m <url>`) censé passer par l'API de MidPoint pour invalider son cache
correctement sur plusieurs tasks. **Ce mode n'existe pas** dans la version de
`ninja.sh` embarquée dans `evolveum/midpoint:4.10.1-alpine` — vérifié en décompilant
les classes d'options (`ConnectionOptions`, `ImportOptions`) du `ninja.jar` réel et
en testant contre une instance MidPoint locale réelle (pas seulement contre la doc) :

- `-m`/`--midpoint-home` ne prend qu'un chemin de répertoire, jamais une URL. Le
  wrapper `ninja.sh` (le script shell, pas `ninja.jar`) ajoute de toute façon
  **toujours** son propre `-m "$MIDPOINT_HOME"` à la commande — en fournir un
  soi-même échoue avec `Can only specify option -m once`.
- `-U`/`--url` accepte bien une URL arbitraire, mais elle est interprétée comme une
  **URL JDBC** uniquement (`NinjaContext.getDatabase()` lève `Unknown database for
  url http://...` pour un schéma non-JDBC).
- Aucune commande `ninja.sh` ne mentionne "REST" dans son aide.

**Conséquence : `ninja.sh import` écrit toujours directement dans le repository
Postgres**, qu'on soit en local ou sur ECS. Il n'y a donc plus deux "modes", mais une
seule méthode, avec deux façons équivalentes de fournir la connexion :

| Script | Connexion | Usage |
|---|---|---|
| [`import-config.sh`](import-config.sh) | implicite, via `config.xml` du `MIDPOINT_HOME` partagé (volume EFS/Docker) | local (`docker-compose.yml`, service `midpoint_import`) |
| [`import-config-ecs.sh`](import-config-ecs.sh) | explicite, via `-U/-u/-p` (JDBC RDS) | ECS (task `midpoint-import`, pas d'EFS partagé) |

Deux pièges supplémentaires vérifiés contre le vrai `ninja.jar` (CLI JCommander, pas
la doc) et corrigés dans les deux scripts :

- L'option d'overwrite de la commande `import` est **`-O`** (majuscule), pas `-o`.
  `-M` (majuscule) n'existe pas du tout comme option ninja.
- `ninja.sh` exige toujours un `$MIDPOINT_HOME/config.xml`, même en mode JDBC direct
  (`-U/-u/-p`) où son contenu réel n'a pas d'importance puisque ces options priment.
  `import-config-ecs.sh` gère ça en copiant `doc/config/config-native.xml` (fourni
  dans l'image) vers un répertoire `MIDPOINT_HOME` jetable (`/tmp/ninja-home` par
  défaut) avant l'import, plutôt que de monter un EFS pour la task d'import.

**Autre prérequis découvert en testant en local** : contrairement à ce que laisse
penser `midpoint.repository.missingSchemaAction=create` (valeur par défaut), le
repository natif/sqale **n'auto-crée pas son schéma** au premier boot de l'appli
principale — elle plante avec `relation "m_global_metadata" does not exist`. Le
schéma doit être chargé une fois, avant le tout premier démarrage de `midpoint`, via
`ninja.sh run-sql` (voir §6.1 et §8).

**Import incrémental (`IMPORT_TYPES`)** : par défaut les deux scripts importent les
18 dossiers de `objects/` à chaque exécution, même pour un changement d'un seul
fichier — chaque dossier relance une JVM `ninja.sh` complète (~65-75s mesurés en
sandbox, voir §10), donc ~20-25 min au total quelle que soit la taille du
changement. Les deux scripts acceptent maintenant une variable d'environnement
optionnelle `IMPORT_TYPES` (ex. `IMPORT_TYPES="roles archetypes"`) qui limite
l'import à ces types, dans l'ordre des dépendances (peu importe l'ordre donné dans
la variable). Non définie/vide = comportement d'origine (tout importer), utilisé
pour le bootstrap (§8) et les resync complets — un changement partiel n'est sûr que
si les types non sélectionnés sont déjà en base depuis un import précédent.

Le job `plan_import` de `.gitlab-ci.yml` calcule cette variable automatiquement à
partir du diff git entre `$CI_COMMIT_BEFORE_SHA` et `$CI_COMMIT_SHA`, et retombe sur
un import complet dès qu'il ne peut pas garantir qu'un import partiel est sûr : pas
de commit précédent à comparer, ou changement de `Dockerfile`/des scripts d'import
eux-mêmes (ceux-là changent *comment* chaque type est importé, pas seulement un
type en particulier).

## 5. Faut-il redémarrer MidPoint après un import ?

**Oui.** Puisque `ninja.sh` écrit toujours directement dans Postgres sans passer par
l'appli (§4), l'instance `midpoint` en cours d'exécution ne sait pas que sa
configuration a changé tant que son cache mémoire n'a pas été rafraîchi. Avec
`desired-count: 1` (voir §6.4), la façon la plus simple d'y arriver est de forcer un
redéploiement du service juste après un import réussi :

```sh
aws ecs update-service --cluster mon-cluster --service midpoint --force-new-deployment
aws ecs wait services-stable --cluster mon-cluster --services midpoint
```

Ça démarre une tâche `midpoint` neuve, qui relit l'état à jour depuis RDS. C'est
inclus dans le flux CI (§7). Coût : une courte interruption de service le temps que
la nouvelle tâche démarre et passe le health check (`health-check-grace-period-seconds`).

Séparément : un changement sur `PersonObjectTemplate` ou les règles de corrélation
qui doit s'appliquer aux utilisateurs *déjà existants* nécessite en plus de lancer
une tâche de **recompute** (une tâche métier standard de MidPoint, pas un restart) —
hors scope de ce document.

## 6. Mise en place de l'infra (une fois)

1. **Schéma du repository, avant tout démarrage de `midpoint`.** Contrairement à
   l'hypothèse de départ, le repository natif/sqale ne crée pas ses tables tout seul
   au premier boot (voir §4) — `midpoint` planterait avec `relation
   "m_global_metadata" does not exist`. Charger le schéma une fois sur RDS, depuis un
   conteneur ayant accès réseau à RDS (ex. un `run-task` ponctuel avec la même image
   ECR, commande overridée) :
   ```sh
   ninja.sh run-sql --mode REPOSITORY --create \
     --jdbc-url "jdbc:postgresql://<rds-endpoint>:5432/midpoint" \
     --jdbc-username midpoint --jdbc-password "<rds-password>"
   ninja.sh run-sql --mode AUDIT --create \
     --jdbc-url "jdbc:postgresql://<rds-endpoint>:5432/midpoint" \
     --jdbc-username midpoint --jdbc-password "<rds-password>"
   ```
   Commandes validées en local contre un vrai Postgres (voir §9). À exécuter depuis
   le répertoire `/opt/midpoint` de l'image (les scripts SQL sont référencés en
   chemin relatif : `./doc/config/sql/native/postgres*.sql`).

2. **Secrets** :
   ```sh
   aws secretsmanager create-secret --name midpoint/rds-password --secret-string '...'
   aws secretsmanager create-secret --name midpoint/admin-password --secret-string '...'
   ```
   `rds-password` est utilisé par `midpoint` (connexion repository) **et** par la
   task `midpoint-import` (`ninja.sh -U/-u/-p`, voir §4) — ce n'est plus seulement le
   mot de passe RDS interne à `midpoint`. `admin-password` ne sert qu'à fixer le mot
   de passe du compte `administrator` de l'UI au tout premier démarrage ; il n'est
   plus utilisé par les imports (voir §4, il n'y a plus d'authentification REST).

   ⚠️ La variable `MP_SET_midpoint_administrator_initialPassword` (confirmée dans
   `bin/midpoint.bat` de l'image `evolveum/midpoint:4.10.1-alpine`, qui la mappe sur
   `-Dmidpoint.administrator.initialPassword`) n'est lue qu'**une seule fois**, au
   tout premier démarrage sur un repository RDS vide : elle crée le compte
   `administrator`, puis est ensuite ignorée même si le secret change. Le mot de
   passe doit aussi respecter la politique de mot de passe par défaut (≥ 8
   caractères, ≥ 1 majuscule, ≥ 1 minuscule, ≥ 1 chiffre) — sinon le compte
   `administrator` n'est pas créé du tout et le bootstrap (§8) échoue silencieusement.

3. **Task definition `midpoint`** (service permanent) :
   - image ECR buildée depuis ce repo ;
   - volume EFS monté sur `/opt/midpoint/var` ;
   - `MP_SET_midpoint_repository_*` pointant vers RDS (mêmes clés que dans
     `docker-compose.yml`, adaptées à RDS) ;
   - `MP_SET_midpoint_administrator_initialPassword` branchée sur le secret
     `admin-password`, pour fixer le mot de passe admin au premier boot (voir
     détails et mise en garde ci-dessus) ;
   - port 8080 exposé.

4. **Service ECS `midpoint`** (Service Connect optionnel désormais, voir §2 —
   gardé ici pour un accès interne pratique, ex. debug) :
   ```sh
   aws ecs create-service \
     --cluster mon-cluster \
     --service-name midpoint \
     --task-definition midpoint \
     --desired-count 1 \
     --launch-type FARGATE \
     --network-configuration "awsvpcConfiguration={subnets=[subnet-a,subnet-b],securityGroups=[sg-midpoint]}" \
     --service-connect-configuration '{"enabled":true,"services":[{"portName":"http","clientAliases":[{"port":8080,"dnsName":"midpoint"}]}]}' \
     --health-check-grace-period-seconds 120
   ```

5. **Task definition `midpoint-import`** (tâche ponctuelle, jamais lancée comme
   service) :
   - même image ECR que `midpoint` ;
   - pas d'EFS (le script crée son propre `MIDPOINT_HOME` jetable, voir §4) ;
   - réseau avec accès à RDS (pas à `midpoint`/Service Connect, contrairement à
     l'ancienne version de ce document) ;
   - `MIDPOINT_JDBC_URL=jdbc:postgresql://<rds-endpoint>:5432/midpoint`,
     `MIDPOINT_JDBC_USERNAME=midpoint`, et le secret `rds-password` mappé sur
     `MIDPOINT_JDBC_PASSWORD` ;
   - `command` overridée : `["/opt/midpoint/import-config-ecs.sh"]`.

## 7. Flux à chaque changement de `objects/`

Implémenté pour de vrai dans [`.gitlab-ci.yml`](.gitlab-ci.yml) (voir son
en-tête pour la liste des variables CI/CD requises) et
[`ecs/task-definitions/`](ecs/task-definitions/) (templates JSON de
`register-task-definition`, substitués via `envsubst`). Le flux ci-dessous en est la
version pédagogique ; la version réelle ajoute une étape `plan_import` avant l'étape
2, qui calcule `IMPORT_TYPES` (§4) pour ne rejouer que les dossiers réellement
modifiés plutôt que les 18 systématiquement.

Job GitLab CI déclenché quand `objects/**` change :

```sh
# 1. S'assurer que le service midpoint est up et stable
aws ecs wait services-stable --cluster mon-cluster --services midpoint

# 2. Lancer la task d'import
TASK_ARN=$(aws ecs run-task \
  --cluster mon-cluster \
  --task-definition midpoint-import \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-a,subnet-b],securityGroups=[sg-import]}" \
  --query 'tasks[0].taskArn' --output text)

# 3. Attendre la fin
aws ecs wait tasks-stopped --cluster mon-cluster --tasks "$TASK_ARN"

# 4. Vérifier le exit code, faire échouer le job CI sinon
EXIT_CODE=$(aws ecs describe-tasks --cluster mon-cluster --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)
[ "$EXIT_CODE" = "0" ] || { echo "Import échoué, voir CloudWatch Logs"; exit 1; }

# 5. Rafraîchir le cache de midpoint : redémarrer le service (voir §5 - ninja.sh
#    écrit directement dans RDS, midpoint ne sait pas que la config a changé)
aws ecs update-service --cluster mon-cluster --service midpoint --force-new-deployment
aws ecs wait services-stable --cluster mon-cluster --services midpoint
```

`sg-import` a besoin d'un accès sortant vers RDS (port 5432) — **pas** vers
`sg-midpoint` comme le disait une version antérieure de ce document (`ninja.sh`
n'appelle jamais l'API de `midpoint`, voir §4). Pas d'accès EFS pour cette task. Les
logs de l'import (`--- Import : <type> ---` par dossier, produits par
`import-config-ecs.sh`) partent dans CloudWatch Logs via le driver `awslogs` de la
task definition.

## 8. Premier déploiement (bootstrap)

1. Charger le schéma du repository sur RDS (§6.1) — **avant** de créer le service
   `midpoint`, sinon il plante au boot (voir §4).
2. `create-service midpoint` → MidPoint démarre sur un schéma vide et crée son
   compte `administrator` (mot de passe fixé par le secret `admin-password`).
3. `aws ecs wait services-stable` puis un premier `run-task midpoint-import` → toute
   la configuration ANETT est importée, suivi du redémarrage forcé décrit en §7
   étape 5 pour que `midpoint` la prenne en compte.

Ensuite, chaque merge touchant `objects/` ne rejoue que l'étape 7 (import + restart),
sans jamais recréer le service `midpoint` ni retoucher au schéma.

## 9. Tester en local avant de pousser sur ECS

Ce repo contient un `docker-compose.yml` qui reproduit ce flux en local avec Docker.
Testé de bout en bout (voir §10) : les deux scripts d'import tournent sans erreur sur
les 18 dossiers de `objects/`.

**Première fois sur un volume Postgres vide** (le schéma n'est pas auto-créé, §4).
On réutilise la connexion JDBC déjà déclarée sur le service `midpoint_import_ecs`
(profil `ecs-test`) en overridant juste sa commande :
```sh
echo "POSTGRES_PASSWORD=un_mot_de_passe" > .env
echo "ADMIN_PASSWORD=Un_mot_de_passe_conforme1" >> .env   # voir règles §6.2

docker compose up -d midpoint_data
docker compose --profile ecs-test run --rm --entrypoint sh midpoint_import_ecs -c '
  cd /opt/midpoint
  ./bin/ninja.sh run-sql --mode REPOSITORY --create \
    --jdbc-url "$MIDPOINT_JDBC_URL" \
    --jdbc-username "$MIDPOINT_JDBC_USERNAME" --jdbc-password "$MIDPOINT_JDBC_PASSWORD"
  ./bin/ninja.sh run-sql --mode AUDIT --create \
    --jdbc-url "$MIDPOINT_JDBC_URL" \
    --jdbc-username "$MIDPOINT_JDBC_USERNAME" --jdbc-password "$MIDPOINT_JDBC_PASSWORD"
'
```

**Ensuite, à chaque fois** :
```sh
docker compose up -d --build midpoint          # attendre "health: healthy"
docker compose logs -f midpoint_import         # suit l'import direct-repo local
```

**Pour tester spécifiquement le chemin ECS** (JDBC direct via `import-config-ecs.sh`,
service non démarré par défaut) :
```sh
docker compose --profile ecs-test run --rm midpoint_import_ecs
```

C'est le bon réflexe pour valider un changement dans `objects/` (ordre d'import,
XML valide...) avant de le laisser partir en pipeline vers ECS.

## 10. Points validés localement vs. encore ouverts

**Validé** (2026-10-05, contre une vraie image `evolveum/midpoint:4.10.1-alpine` et
un vrai Postgres, pas seulement contre la doc) :
- Le build de l'image (le `Dockerfile` d'origine ne buildait pas : `USER midpoint`
  n'existe pas dans l'image de base).
- Le chargement du schéma repository/audit via `ninja.sh run-sql`.
- Le healthcheck Docker (`/midpoint/` renvoyait une redirection que BusyBox wget ne
  sait pas suivre ; corrigé en ciblant `/actuator/health`).
- Les deux imports, `import-config.sh` (direct-repo local) et `import-config-ecs.sh`
  (JDBC direct), chacun sur les 18 dossiers de `objects/`, 0 erreur, options `-O`/
  `-U` vérifiées contre le vrai parseur CLI de `ninja.jar`.

**Validé sur une vraie infra AWS** (2026-10-06, sandbox ECS/RDS/EFS jetable géré par
Terraform, voir [`terraform/ecs-sandbox/`](terraform/ecs-sandbox/), détruit après le
test) — exactement les deux points qui ne pouvaient être vérifiés que sur de l'AWS
réel :
- **`sg-import` → RDS** : la task `midpoint-import` a chargé le schéma repository et
  audit (`ninja.sh run-sql`) via une vraie RDS Postgres, à travers ce security group,
  sans accès à `sg-midpoint` — confirme que le modèle réseau révisé en §7 fonctionne.
- **Redémarrage forcé après import** (§5/§7 étape 5) : `update-service
  --force-new-deployment` a bien fait démarrer une tâche `midpoint` neuve, qui est
  passée `HEALTHY`, pendant que l'ancienne se vidait — confirmé par
  `aws ecs wait services-stable`.
- Bout en bout : compte `administrator` créé au premier boot (mot de passe du
  secret `admin-password`, connexion vérifiée via `GET /ws/rest/self` en HTTP Basic,
  loggée depuis l'IP de l'opérateur), puis les 18 dossiers de `objects/` importés
  (0 erreur) et visibles après redémarrage (`GET /ws/rest/resources` : 11 ressources
  dont `AD Kalhyge`, `ADP`, `CEGID`, `HQZ In` ; `GET /ws/rest/roles` : 8 rôles dont
  `Superuser`, `Administrateur`, `Lecteur`).

Deux points pratiques relevés pendant ce test, à garder en tête pour la vraie CI :
- **Architecture de l'image** : la construire sur une machine ARM (Apple Silicon)
  sans `--platform linux/amd64` produit une image `arm64` que Fargate (plateforme
  `X86_64` par défaut, aucun `runtime_platform` déclaré) ne peut pas démarrer. Le
  pipeline CI doit soit cibler explicitement `linux/amd64` au build, soit déclarer
  `runtime_platform` ARM64 sur les task definitions si un runner Graviton est utilisé.
- **Durée de l'import** : chaque dossier de `objects/` relance une JVM `ninja.sh`
  complète (nouveau contexte Spring à chaque fois). En local c'est quasi instantané,
  mais sur la task `midpoint-import` du sandbox (0.5 vCPU / 1024 Mo, latence réseau
  réelle vers RDS) chaque dossier a pris ~65-75s, soit ~23 min pour les 18 dossiers.
  À anticiper dans le timeout du job CI (§7) et/ou revoir à la hausse `import_cpu`/
  `import_memory` si c'est trop lent en pratique.

**Validé localement** (2026-10-06) : l'import incrémental `IMPORT_TYPES` (§4), sur
les deux scripts - sélection correcte dans l'ordre des dépendances, et comportement
par défaut (tout importer) inchangé quand la variable n'est pas définie. La logique
de calcul du diff du job `plan_import` a aussi été rejouée à la main contre deux
vrais couples de commits de ce dépôt (pas des exemples synthétiques) : un diff
touchant `Dockerfile`/les scripts → bascule correctement sur un import complet ; un
diff ne touchant que des dossiers `objects/` → types extraits correctement.

**Encore ouvert** :
- Le flux GitLab CI (§7), `plan_import` inclus, n'existe pas encore comme pipeline
  réel — seulement rejoué à la main (scripts et logique de diff séparément), jamais
  comme un vrai pipeline GitLab CI de bout en bout.
- Pas de script de migration pour une future montée de version MidPoint (schéma
  `postgres-upgrade.sql`/`ninja.sh run-sql --upgrade`, présent dans l'image mais non
  documenté ici).
