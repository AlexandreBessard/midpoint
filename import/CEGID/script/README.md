# fetch_cegid.py

Appelle l'API HRUX de CEGID (`dossier.contrat.exporter.csv` via `hrux_c47e.jsp`) et
écrit la réponse telle quelle dans `import/CEGID/`, sous un nom horodaté
`CEGID_AAAAMMJJ_HHMMSS.csv`.

Le script ne fait que l'appel + l'écriture du fichier : il ne dédoublonne pas les
matricules et ne modifie pas la configuration MidPoint. Le format renvoyé par cette
API (`MATRICULE;CIVILITE;PRENOM;NOM;DATE_DEBUT;DATE_DEPART;CODE_ENTITE;LIBELLE_ENTITE;DATE_NAISSANCE`)
est déjà celui attendu par `scripts/dedup_cegid.py` — l'étape de dédoublonnage reste
une étape manuelle séparée, à lancer sur le fichier produit ici.

## Prérequis

- Python 3 (bibliothèque standard uniquement, rien à installer).
- Les variables d'environnement suivantes :

| Variable | Obligatoire | Défaut | Description |
|---|---|---|---|
| `CEGID_TOKEN_VALUE` | **oui** | — | Le jeton d'authentification (secret). Le script s'arrête si elle est absente. |
| `CEGID_TOKEN_ID` | non | `MIDPOINT` | Identifiant de token. |
| `CEGID_CDVUE` | non | `MIDPOINT` | Paramètre `cdvue` de la requête. |
| `CEGID_URL` | non | `https://anett-hru.cegid.com/hru/hrux_c47e.jsp` | URL de l'endpoint, utile pour tester contre un autre environnement. |

**Ne jamais committer de valeur de token** (dans ce script, un `.env`, ou ailleurs
dans le repo) — à définir uniquement dans l'environnement local/serveur, ou à
stocker dans `credentials.kdbx`.

## Utilisation

PowerShell :

```powershell
$env:CEGID_TOKEN_VALUE = "<valeur du token>"
python import/CEGID/script/fetch_cegid.py
```

Bash :

```bash
export CEGID_TOKEN_VALUE="<valeur du token>"
python3 import/CEGID/script/fetch_cegid.py
```

Par défaut, le fichier est écrit dans `import/CEGID/` (dossier parent du script).
Pour écrire ailleurs (par exemple pour un test) :

```bash
python3 import/CEGID/script/fetch_cegid.py --output-dir /tmp/test
```

## Sortie

- `import/CEGID/CEGID_<AAAAMMJJ>_<HHMMSS>.csv` — un nouveau fichier à chaque exécution,
  jamais écrasé entre deux runs (le nom change à chaque appel grâce à l'horodatage).
- Erreurs (token manquant, HTTP != 200, réponse vide, erreur réseau) : message sur
  stderr et code de sortie non nul, rien n'est écrit sur disque.

Ces fichiers contiennent des données personnelles de salariés : ils restent
ignorés par git (`import/` est dans `.gitignore`), seul le dossier `script/`
est suivi.
