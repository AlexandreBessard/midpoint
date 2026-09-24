#!/bin/sh

set -e

MIDPOINT_HOME="${MIDPOINT_HOME:-/opt/midpoint/var}"
NINJA="${NINJA:-/opt/midpoint/bin/ninja.sh}"
OBJECTS_DIR="${OBJECTS_DIR:-/opt/midpoint/objects}"

echo "======================================"
echo " MidPoint configuration import"
echo "======================================"
echo "MidPoint home: $MIDPOINT_HOME"
echo "Objects dir:   $OBJECTS_DIR"
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

    if ! ls "$dir"/*.xml >/dev/null 2>&1; then
        echo "--- Skipping $type (no XML files) ---"
        continue
    fi

    echo "--- Importing $type ---"
    "$NINJA" -M "$MIDPOINT_HOME" import -i "$dir" -o
    echo
done

echo "Configuration import completed successfully."
