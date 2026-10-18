#!/bin/sh

set -e

MIDPOINT_HOME="${MIDPOINT_HOME:-/opt/midpoint/var}"
export MIDPOINT_HOME
NINJA="${NINJA:-/opt/midpoint/bin/ninja.sh}"
OBJECTS_DIR="${OBJECTS_DIR:-/opt/midpoint/objects}"
# Space-separated type names (e.g. "roles archetypes") to import only those
# folders instead of all of them. Empty/unset = import everything, same as
# before - used for bootstrap and full resyncs. See import-config-ecs.sh for
# the matching (and more heavily commented) implementation.
IMPORT_TYPES="${IMPORT_TYPES:-}"

type_selected() {
    [ -z "$IMPORT_TYPES" ] && return 0
    case " $IMPORT_TYPES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "======================================"
echo " MidPoint configuration import"
echo "======================================"
echo "MidPoint home: $MIDPOINT_HOME"
echo "Objects dir:   $OBJECTS_DIR"
if [ -n "$IMPORT_TYPES" ]; then
    echo "Types:         $IMPORT_TYPES (incremental selection)"
else
    echo "Types:         all"
fi
echo

# Import order follows the object dependencies actually present under objects/
# (an object that references another by OID must be imported after the object
# it references):
#   schemas              - custom extension schema, used by templates/mappings below
#   valuePolicies        - referenced by securityPolicies (DefaultPasswordPolicy)
#   securityPolicies     - referenced by systemConfigurations (DefaultSecurityPolicy)
#   lookupTables         - no local dependents, safe to import early
#   marks                - referenced by policies
#   sequences            - referenced by objectTemplates (UserPersonalNumberSequence)
#   objectTemplates      - referenced by archetypes (Person -> PersonObjectTemplate)
#   archetypes           - referenced by roles, orgs/services, resources (HQZ -> Interimaire)
#   roles                - reference archetypes
#   orgs                 - reference archetypes (World -> Location)
#   services             - reference archetypes
#   policies             - reference marks/roles
#   objectCollections    - reference policies
#   dashboards           - reference objectCollections/policies
#   reports              - reference objectCollections/dashboards
#   systemConfigurations - references securityPolicies
#   resources            - reference archetypes
#   tasks                - reference resources
#
# objects/simulationResults is intentionally not imported: it holds disposable
# simulation-run snapshots, not hand-maintained configuration.
ORDERED_TYPES="schemas valuePolicies securityPolicies lookupTables marks sequences objectTemplates archetypes roles orgs services policies objectCollections dashboards reports systemConfigurations resources tasks"

for type in $ORDERED_TYPES; do
    dir="$OBJECTS_DIR/$type"

    if [ ! -d "$dir" ]; then
        continue
    fi

    if ! type_selected "$type"; then
        echo "--- Skipping $type (not in IMPORT_TYPES selection) ---"
        continue
    fi

    if ! ls "$dir"/*.xml >/dev/null 2>&1; then
        echo "--- Skipping $type (no XML files) ---"
        continue
    fi

    echo "--- Importing $type ---"
    # No "-m" here: ninja.sh's wrapper always appends its own "-m $MIDPOINT_HOME"
    # (exported above), and passing -m ourselves too would fail with "Can only
    # specify option -m once". "-M" doesn't exist as a ninja option at all, and
    # the overwrite flag is "-O" (uppercase), not "-o" - both were silently
    # broken until verified against the real ninja.jar CLI parser.
    "$NINJA" import -i "$dir" -O
    echo
done

echo "Configuration import completed successfully."
