#!/bin/sh
#
# Importe la configuration objects/ via Ninja en mode REST.
# Les dossiers sont traités dans l'ordre des dépendances.
#
# Prérequis :
# - Connecteurs et objets intégrés déjà présents sur le serveur.
# - Tâches à importer configurées comme suspendues.
# - Options Ninja compatibles avec la version installée.

set -eu

: "${MIDPOINT_URL:?MIDPOINT_URL doit contenir l'URL de MidPoint}"
: "${MIDPOINT_ADMIN_PASSWORD:?MIDPOINT_ADMIN_PASSWORD doit contenir le mot de passe}"

MIDPOINT_ADMIN_USER="${MIDPOINT_ADMIN_USER:-administrator}"
NINJA="${NINJA:-/opt/midpoint/bin/ninja.sh}"
OBJECTS_DIR="${OBJECTS_DIR:-/opt/midpoint/objects}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-5}"

MIDPOINT_URL="${MIDPOINT_URL%/}"

fail() {
    printf 'ERREUR : %s\n' "$*" >&2
    exit 1
}

check_positive_integer() {
    case "$2" in
        ''|*[!0-9]*)
            fail "$1 doit être un entier strictement positif."
            ;;
    esac

    [ "$2" -gt 0 ] ||
        fail "$1 doit être supérieur à zéro."
}

check_positive_integer WAIT_TIMEOUT "$WAIT_TIMEOUT"
check_positive_integer WAIT_INTERVAL "$WAIT_INTERVAL"
check_positive_integer HTTP_TIMEOUT "$HTTP_TIMEOUT"

[ -x "$NINJA" ] ||
    fail "Ninja introuvable ou non exécutable : $NINJA"

[ -d "$OBJECTS_DIR" ] ||
    fail "Répertoire introuvable : $OBJECTS_DIR"

command -v wget >/dev/null 2>&1 ||
    fail "wget est requis."

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
echo " Mode REST / ECS"
echo "======================================"
printf 'URL MidPoint : %s\n' "$MIDPOINT_URL"
printf 'Répertoire   : %s\n' "$OBJECTS_DIR"
echo

# Vérifie l'accessibilité HTTP, pas les droits d'import REST.
# Le délai global est contrôlé entre les tentatives.
# Une requête en cours peut dépasser légèrement ce délai.
printf 'Attente de MidPoint : %s\n' "$MIDPOINT_URL"

started_at=$(date +%s)
deadline=$((started_at + WAIT_TIMEOUT))

while :; do
    now=$(date +%s)
    remaining=$((deadline - now))

    [ "$remaining" -gt 0 ] ||
        fail "MidPoint inaccessible après ${WAIT_TIMEOUT}s."

    request_timeout="$HTTP_TIMEOUT"
    if [ "$request_timeout" -gt "$remaining" ]; then
        request_timeout="$remaining"
    fi

    if wget -q -T "$request_timeout" -O /dev/null \
        "$MIDPOINT_URL/" 2>/dev/null; then
        break
    fi

    now=$(date +%s)
    remaining=$((deadline - now))

    [ "$remaining" -gt 0 ] ||
        fail "MidPoint inaccessible après ${WAIT_TIMEOUT}s."

    sleep_duration="$WAIT_INTERVAL"
    if [ "$sleep_duration" -gt "$remaining" ]; then
        sleep_duration="$remaining"
    fi

    sleep "$sleep_duration"
done

echo "MidPoint est accessible en HTTP."
echo

imported_directories=0

for type in $ORDERED_TYPES; do
    dir="$OBJECTS_DIR/$type"

    if [ ! -d "$dir" ]; then
        printf '%s\n' "--- Ignoré : $type (répertoire absent) ---"
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

    if "$NINJA" \
        -m "$MIDPOINT_URL" \
        -u "$MIDPOINT_ADMIN_USER" \
        -p "$MIDPOINT_ADMIN_PASSWORD" \
        import \
        -i "$dir" \
        -o; then
        imported_directories=$((imported_directories + 1))
    else
        fail "Échec de Ninja pour $type. Les imports précédents ne sont pas annulés."
    fi

    echo
done

printf 'Ninja a terminé sans code d’échec pour %s répertoire(s).\n' \
    "$imported_directories"