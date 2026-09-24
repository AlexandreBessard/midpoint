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

Une fois la config importée, MidPoint est opérationnel — **aucun redémarrage n'est
nécessaire après un import** (voir §5).

## 2. Composants AWS

| Composant | Rôle |
|---|---|
| ECS Fargate — service `midpoint` | fait tourner l'appli en continu (port 8080) |
| ECS Fargate — task `midpoint-import` | tâche ponctuelle (*run-task*, pas un service) qui importe `objects/` |
| RDS Postgres | le repository MidPoint (rôles, ressources, tâches, historique...) |
| EFS, monté sur `/opt/midpoint/var` | `midpoint-home` : `config.xml`, keystore, logs, **et les fichiers CSV** lus par les connecteurs CEGID/ADP/HQZ (`import/*.csv`) — nécessaire dès qu'il y a plus d'une task |
| Secrets Manager | mot de passe RDS + mot de passe du compte `administrator` MidPoint |
| ECS Service Connect (ou ALB interne) | DNS interne stable pour joindre `midpoint` depuis la task d'import, sans passer par l'ALB public |

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

## 4. Deux modes pour `ninja.sh`

| Mode | Commande | Utilisation |
|---|---|---|
| **Direct-repo** | `ninja.sh -M <midpoint-home> import ...` | usage **local uniquement** (`docker-compose.yml`, service `midpoint_import`) : écrit directement dans Postgres en lisant `config.xml` sur le volume partagé |
| **REST** | `ninja.sh -m <url> -u administrator -p <mdp> import ...` | usage **ECS** : passe par l'API de MidPoint lui-même |

**Pourquoi pas le mode direct-repo sur ECS ?** Si MidPoint tourne sur plusieurs tasks
(ou même une seule, en usage prod), écrire directement dans RDS contourne le cache en
mémoire de MidPoint : les tasks ne sont pas prévenues du changement tant que leur
cache n'expire pas. En mode REST, c'est MidPoint qui traite l'import et invalide son
cache correctement — pas de redémarrage à prévoir.

C'est pour ça que ce repo a deux scripts :

- [`import-config.sh`](import-config.sh) — mode `-M`, usage local (`docker-compose.yml`).
- [`import-config-ecs.sh`](import-config-ecs.sh) — mode `-m` (REST), usage ECS. Il
  attend en plus que `MIDPOINT_URL` réponde avant de lancer l'import (`WAIT_TIMEOUT`/
  `WAIT_INTERVAL`, 180s/5s par défaut), et échoue explicitement si `MIDPOINT_URL` ou
  `MIDPOINT_ADMIN_PASSWORD` ne sont pas positionnés.

## 5. Faut-il redémarrer MidPoint après un import ?

**Non**, pour la quasi-totalité des types d'objets (ressources, rôles, archétypes,
tâches, templates) importés en mode REST : l'effet est immédiat, MidPoint invalide son
cache et propage le changement à toutes ses instances.

Seule exception : un changement sur `PersonObjectTemplate` ou les règles de
corrélation qui doit s'appliquer aux utilisateurs *déjà existants* nécessite de
lancer une tâche de **recompute** (pas un restart, une tâche métier standard de
MidPoint) — hors scope de ce document.

## 6. Mise en place de l'infra (une fois)

1. **Secrets** :
   ```sh
   aws secretsmanager create-secret --name midpoint/rds-password --secret-string '...'
   aws secretsmanager create-secret --name midpoint/admin-password --secret-string '...'
   ```
   `admin-password` est utilisé à deux endroits : pour fixer le mot de passe du
   compte `administrator` au premier démarrage de MidPoint, et pour authentifier
   `ninja.sh` en REST lors des imports. Un mot de passe fixe (pas auto-généré) évite
   d'avoir à le récupérer dans les logs pour la CI.

2. **Task definition `midpoint`** (service permanent) :
   - image ECR buildée depuis ce repo ;
   - volume EFS monté sur `/opt/midpoint/var` ;
   - `MP_SET_midpoint_repository_*` pointant vers RDS (mêmes clés que dans
     `docker-compose.yml`, adaptées à RDS) ;
   - variable pour fixer le mot de passe admin au premier boot, branchée sur le
     secret `admin-password` (nom exact de la clé `MP_SET_...` à vérifier dans la
     doc de l'image `evolveum/midpoint:4.10.1` pour la version admin-password) ;
   - port 8080 exposé.

3. **Service ECS `midpoint`**, avec Service Connect activé pour exposer un DNS
   interne stable (ex. `midpoint:8080`) :
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

4. **Task definition `midpoint-import`** (tâche ponctuelle, jamais lancée comme
   service) :
   - même image ECR que `midpoint` ;
   - pas d'EFS, pas de secret RDS ;
   - `MIDPOINT_URL=http://midpoint:8080/midpoint` (DNS Service Connect) et le secret
     `admin-password` mappé sur `MIDPOINT_ADMIN_PASSWORD` ;
   - `command` overridée : `["/opt/midpoint/import-config-ecs.sh"]`.

## 7. Flux à chaque changement de `objects/`

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
```

`sg-import` n'a besoin que d'un accès sortant vers `sg-midpoint` sur le port 8080 —
pas d'accès RDS ni EFS pour cette task. Les logs de l'import (`--- Importing <type>
---` par dossier, produits par `import-config.sh`) partent dans CloudWatch Logs via
le driver `awslogs` de la task definition.

## 8. Premier déploiement (bootstrap)

1. `create-service midpoint` sur une RDS vide → MidPoint crée son schéma et son
   compte `administrator` (mot de passe fixé par le secret).
2. `aws ecs wait services-stable` puis un premier `run-task midpoint-import` → toute
   la configuration ANETT est importée.

Ensuite, chaque merge touchant `objects/` ne rejoue que l'étape 7, sans jamais
toucher au service `midpoint`.

## 9. Tester en local avant de pousser sur ECS

Ce repo contient un `docker-compose.yml` qui reproduit ce flux en local avec Docker :
le service `midpoint` démarre, un healthcheck attend qu'il soit prêt, puis le
service `midpoint_import` lance `import-config.sh` (en mode `-M` direct-repo,
puisqu'en local tout tourne dans le même environnement Docker).

```sh
echo "POSTGRES_PASSWORD=un_mot_de_passe" > .env
docker compose up --build
docker compose logs -f midpoint_import   # suivre l'import
```

C'est le bon réflexe pour valider un changement dans `objects/` (ordre d'import,
XML valide...) avant de le laisser partir en pipeline vers ECS.

## 10. Points non encore validés

- Le nom exact de la variable `MP_SET_...` pour fixer le mot de passe admin au
  premier boot (à vérifier dans la doc de l'image `evolveum/midpoint:4.10.1`).
- `import-config-ecs.sh` n'a pas encore été testé contre une vraie API MidPoint en
  mode REST (`-m`) — écrit par analogie avec la doc ninja, à valider au premier run
  ECS réel (voir `docker compose logs midpoint_import` pour le comportement du
  mode `-M` équivalent, déjà testé en local).
- Ce document n'a pas été validé sur une vraie infra ECS (pas d'accès AWS dans
  l'environnement où il a été rédigé) — à considérer comme un plan de départ à
  ajuster pendant la mise en œuvre.
