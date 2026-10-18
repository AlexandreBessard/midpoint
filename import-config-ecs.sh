#!/bin/sh
#
# Importe la configuration objects/ via Ninja, en connexion JDBC directe vers
# le repository RDS (ninja.sh n'a pas de mode "REST" : il écrit toujours
# directement dans la base - voir DEVOPS.md §4). Les dossiers sont traités
# dans l'ordre des dépendances.
#
# Conséquence : cet import ne passe pas par l'instance MidPoint en cours
# d'exécution, donc elle ne sait pas que sa configuration a changé tant
# qu'elle n'est pas redémarrée (voir DEVOPS.md §7, étape "force-new-deployment"
# après un import réussi).
#
# Prérequis :
# - Schéma du repository déjà initialisé (ninja run-sql --mode REPOSITORY
#   --create, voir DEVOPS.md §6.1) - ninja n'auto-crée pas le schéma.
# - Connecteurs et objets intégrés déjà présents sur le serveur.
# - Tâches à importer configurées comme suspendues.
# - Options Ninja compatibles avec la version installée.
#
# IMPORT_TYPES (optionnel) : liste de types séparés par des espaces (ex.
# "roles archetypes") pour ne traiter que ces dossiers, dans l'ordre des
# dépendances - au lieu des 18 dossiers systématiquement. Non défini/vide =
# comportement d'origine (tout importer), utilisé pour le bootstrap (§8) et
# les resync complets. Sûr pour des mises à jour incrémentales : les types
# non sélectionnés sont supposés déjà présents en base depuis un import
# précédent, pas besoin de les rejouer.

set -eu

: "${MIDPOINT_JDBC_URL:?MIDPOINT_JDBC_URL doit contenir l'URL JDBC du repository (ex: jdbc:postgresql://host:5432/midpoint)}"
: "${MIDPOINT_JDBC_PASSWORD:?MIDPOINT_JDBC_PASSWORD doit contenir le mot de passe JDBC}"

MIDPOINT_JDBC_USERNAME="${MIDPOINT_JDBC_USERNAME:-midpoint}"
NINJA="${NINJA:-/opt/midpoint/bin/ninja.sh}"
OBJECTS_DIR="${OBJECTS_DIR:-/opt/midpoint/objects}"
IMPORT_TYPES="${IMPORT_TYPES:-}"

# ninja.sh (le wrapper, pas ninja.jar) ajoute toujours lui-même un "-m
# $MIDPOINT_HOME" à la commande - en fournir un nous-mêmes échoue avec
# "Can only specify option -m once". MIDPOINT_HOME doit malgré tout pointer
# vers un répertoire contenant un config.xml (même minimal : la connexion
# réelle est fixée par -U/-u/-p ci-dessous, qui priment sur son contenu).
MIDPOINT_HOME="${MIDPOINT_HOME:-/tmp/ninja-home}"
export MIDPOINT_HOME
CONFIG_TEMPLATE="${CONFIG_TEMPLATE:-/opt/midpoint/doc/config/config-native.xml}"

fail() {
    printf 'ERREUR : %s\n' "$*" >&2
    exit 1
}

type_selected() {
    [ -z "$IMPORT_TYPES" ] && return 0
    case " $IMPORT_TYPES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

[ -x "$NINJA" ] ||
    fail "Ninja introuvable ou non exécutable : $NINJA"

[ -d "$OBJECTS_DIR" ] ||
    fail "Répertoire introuvable : $OBJECTS_DIR"

if [ ! -e "$MIDPOINT_HOME/config.xml" ]; then
    [ -f "$CONFIG_TEMPLATE" ] ||
        fail "Modèle de config.xml introuvable : $CONFIG_TEMPLATE"
    mkdir -p "$MIDPOINT_HOME"
    cp "$CONFIG_TEMPLATE" "$MIDPOINT_HOME/config.xml"
fi

# Ordre établi à partir des dépendances du dépôt.
ORDERED_TYPES="
schemas
valuePolicies
securityPolicies
lookupTables
marks
sequences
objectTemplates
archetypes
roles
orgs
services
policies
objectCollections
dashboards
reports
systemConfigurations
resources
tasks
"

# Vérifier qu'au moins un dossier prévu contient un fichier XML.
has_xml=0

for type in $ORDERED_TYPES; do
    for file in "$OBJECTS_DIR/$type"/*.xml; do
        if [ -f "$file" ]; then
            has_xml=1
            break
        fi
    done

    if [ "$has_xml" -eq 1 ]; then
        break
    fi
done

[ "$has_xml" -eq 1 ] ||
    fail "Aucun fichier XML trouvé dans les dossiers prévus."

echo "======================================"
echo " Import configuration MidPoint"
echo " Connexion JDBC directe (ECS)"
echo "======================================"
printf 'JDBC URL   : %s\n' "$MIDPOINT_JDBC_URL"
printf 'Répertoire : %s\n' "$OBJECTS_DIR"
if [ -n "$IMPORT_TYPES" ]; then
    printf 'Types      : %s (sélection incrémentale)\n' "$IMPORT_TYPES"
else
    printf 'Types      : tous\n'
fi
echo

imported_directories=0

for type in $ORDERED_TYPES; do
    dir="$OBJECTS_DIR/$type"

    if [ ! -d "$dir" ]; then
        printf '%s\n' "--- Ignoré : $type (répertoire absent) ---"
        continue
    fi

    if ! type_selected "$type"; then
        printf '%s\n' "--- Ignoré : $type (hors sélection IMPORT_TYPES) ---"
        continue
    fi

    has_xml=0
    for file in "$dir"/*.xml; do
        if [ -f "$file" ]; then
            has_xml=1
            break
        fi
    done

    if [ "$has_xml" -eq 0 ]; then
        printf '%s\n' "--- Ignoré : $type (aucun fichier XML) ---"
        continue
    fi

    printf '%s\n' "--- Import : $type ---"

    # Pas de "-m" ici (voir commentaire sur MIDPOINT_HOME plus haut). "-M"
    # n'existe pas comme option ninja, et l'option d'overwrite est "-O"
    # (majuscule), pas "-o" - les deux ont été vérifiées contre le vrai
    # analyseur de CLI de ninja.jar (JCommander), pas seulement contre sa doc.
    if "$NINJA" \
        -U "$MIDPOINT_JDBC_URL" \
        -u "$MIDPOINT_JDBC_USERNAME" \
        -p "$MIDPOINT_JDBC_PASSWORD" \
        import \
        -i "$dir" \
        -O; then
        imported_directories=$((imported_directories + 1))
    else
        fail "Échec de Ninja pour $type. Les imports précédents ne sont pas annulés."
    fi

    echo
done

printf 'Ninja a terminé sans code d’échec pour %s répertoire(s).\n' \
    "$imported_directories"
