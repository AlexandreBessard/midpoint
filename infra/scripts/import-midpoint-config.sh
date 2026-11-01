#!/bin/bash
# Imports a midPoint `objects/` export tree into the local midPoint instance
# (native PostgreSQL repository, via bin/ninja.sh) and restarts the service.
#
# Run ON the midPoint EC2 instance, as root (sudo), after copying the
# `objects/` folder onto the box (e.g. via WinSCP to /home/ec2-user/objects):
#
#   sudo MIDPOINT_ADMIN_PASSWORD='...' ./import-midpoint-config.sh /home/ec2-user/objects
#
# What it does, in order:
#   1. Copies the given objects/ tree into a scratch working directory (your
#      upload is never modified) and strips OS junk files (._*, Thumbs.db).
#   2. Makes sure midPoint is running, then fetches the live instance's own
#      connector catalog (bin/ninja.sh export -t ConnectorType) and rewrites
#      each resource's <connectorRef> to match by bundle+type -- the OIDs in
#      an export from a *different* midPoint install never match this one's,
#      since connectors are discovered and OID-assigned per install.
#   3. Unless disabled, forces every imported Task to `suspended` so nothing
#      starts polling/syncing a live resource right after import.
#   4. Imports every object type directory via `ninja.sh import -O`, in
#      dependency order, stopping on the first batch with errors.
#   5. Restarts the midpoint systemd service and waits for it to come back
#      up and respond on the REST API.
#
# `simulationResults/` and `connectors/` are intentionally never imported:
# the former is disposable bulk output, the latter is managed by midPoint
# itself via connector discovery, not by hand-import.
set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <path-to-objects-folder>}"
MIDPOINT_HOME="${MIDPOINT_HOME:-/opt/midpoint/var}"
MIDPOINT_BIN="${MIDPOINT_BIN:-/opt/midpoint/bin}"
MIDPOINT_USER="${MIDPOINT_USER:-midpoint}"
ADMIN_USER="${MIDPOINT_ADMIN_USER:-administrator}"
SUSPEND_IMPORTED_TASKS="${SUSPEND_IMPORTED_TASKS:-true}"
WORK_DIR="/tmp/midpoint-config-import"

IMPORT_ORDER=(
  schemas
  lookupTables
  sequences
  marks
  valuePolicies
  securityPolicies
  policies
  objectTemplates
  archetypes
  roles
  orgs
  services
  resources
  tasks
  objectCollections
  dashboards
  reports
  systemConfigurations
)
EXCLUDE_DIRS=(simulationResults connectors)

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run this as root (sudo)."
[ -d "$SOURCE_DIR" ] || fail "'$SOURCE_DIR' is not a directory."
[ -x "$MIDPOINT_BIN/ninja.sh" ] || fail "$MIDPOINT_BIN/ninja.sh not found -- wrong MIDPOINT_BIN?"

LOG_DIR="${LOG_DIR:-/var/log/midpoint-config-import}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/import-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
TEE_PID=$!
# Without this, the script can exit (success or fail()) before the
# background tee process has flushed everything to disk, leaving the log
# file incomplete right when you go looking at it. Closing our own stdout/
# stderr signals EOF to tee so it can finish, then we wait for it.
trap 'exec 1>&- 2>&-; wait "$TEE_PID" 2>/dev/null' EXIT
log "Logging to $LOG_FILE"

if [ -z "${MIDPOINT_ADMIN_PASSWORD:-}" ]; then
  read -r -s -p "midPoint admin password for '$ADMIN_USER': " MIDPOINT_ADMIN_PASSWORD
  echo
fi

ninja() {
  sudo -u "$MIDPOINT_USER" "$MIDPOINT_BIN/ninja.sh" "$@"
}

ensure_midpoint_running() {
  if systemctl is-active --quiet midpoint; then
    return
  fi
  log "midpoint service is not active, starting it..."
  systemctl start midpoint
}

wait_for_midpoint() {
  local tries=24
  while [ "$tries" -gt 0 ]; do
    if curl -s -o /dev/null -w '%{http_code}' -u "$ADMIN_USER:$MIDPOINT_ADMIN_PASSWORD" \
         http://localhost:8080/midpoint/ws/rest/self | grep -q '^200$'; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 5
  done
  return 1
}

# --- 1. stage a clean working copy -----------------------------------------
log "Staging working copy in $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp -a "$SOURCE_DIR" "$WORK_DIR/objects"
find "$WORK_DIR/objects" \( -name '._*' -o -name 'Thumbs.db' -o -name 'desktop.ini' \) -delete
chown -R "$MIDPOINT_USER:$MIDPOINT_USER" "$WORK_DIR"
OBJECTS_DIR="$WORK_DIR/objects"

# --- 2. fetch this instance's connector catalog and fix up connectorRef ----
ensure_midpoint_running
log "Waiting for midPoint to respond before reading its connector catalog..."
wait_for_midpoint || fail "midPoint did not come up in time; aborting before touching the repository."

if [ -d "$OBJECTS_DIR/resources" ]; then
  log "Fetching connector catalog and remapping connectorRef in resources/"
  CONNECTORS_JSON="$WORK_DIR/connectors.json"
  curl -s -H 'Accept: application/json' -u "$ADMIN_USER:$MIDPOINT_ADMIN_PASSWORD" \
    http://localhost:8080/midpoint/ws/rest/connectors > "$CONNECTORS_JSON"

  python3 - "$CONNECTORS_JSON" "$OBJECTS_DIR/resources" <<'PYEOF'
import json, re, sys, glob, os

connectors_json, resources_dir = sys.argv[1], sys.argv[2]

def find_connectors(obj, found):
    if isinstance(obj, dict):
        if 'connectorBundle' in obj and 'oid' in obj:
            found.append(obj)
        for v in obj.values():
            find_connectors(v, found)
    elif isinstance(obj, list):
        for v in obj:
            find_connectors(v, found)

with open(connectors_json) as f:
    data = json.load(f)
found = []
find_connectors(data, found)

by_key = {}
for c in found:
    key = (c['connectorBundle'], c['connectorType'])
    by_key.setdefault(key, []).append(c)

ns_re = re.compile(r'xmlns:cfg="[^"]*bundle/([^/]+)/([^"]+)"')
ref_re = re.compile(r'(connectorRef oid=")([^"]+)(")')

for path in sorted(glob.glob(os.path.join(resources_dir, '*.xml'))):
    with open(path, encoding='utf-8') as f:
        content = f.read()
    m = ns_re.search(content)
    name = os.path.basename(path)
    if not m:
        print(f"  SKIP  {name}: no connectorConfiguration namespace found")
        continue
    bundle, ctype = m.group(1), m.group(2)
    candidates = by_key.get((bundle, ctype))
    if not candidates:
        print(f"  WARN  {name}: connector '{bundle}' / '{ctype}' not installed on this instance -- left as-is, resource will not work until that connector is added")
        continue
    new_oid = sorted(candidates, key=lambda c: c.get('connectorVersion', ''))[-1]['oid']
    new_content, n = ref_re.subn(lambda m2: m2.group(1) + new_oid + m2.group(3), content, count=1)
    if n and new_content != content:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"  FIXED {name}: connectorRef -> {new_oid} ({bundle})")
    else:
        print(f"  OK    {name}: connectorRef already correct")
PYEOF
fi

# --- 3. suspend imported tasks unless explicitly disabled -------------------
if [ "$SUSPEND_IMPORTED_TASKS" = "true" ] && [ -d "$OBJECTS_DIR/tasks" ]; then
  log "Forcing imported tasks to 'suspended' (set SUSPEND_IMPORTED_TASKS=false to skip this)"
  count=0
  for f in "$OBJECTS_DIR"/tasks/*.xml; do
    [ -e "$f" ] || continue
    if grep -q '<executionState>runnable</executionState>' "$f"; then
      sed -i 's#<executionState>runnable</executionState>#<executionState>suspended</executionState>#' "$f"
      count=$((count + 1))
    fi
  done
  log "  suspended $count previously-runnable task(s)"
fi

# --- 4. import everything, in dependency order ------------------------------
total_processed=0
total_errors=0
for dir in "${IMPORT_ORDER[@]}"; do
  [ -d "$OBJECTS_DIR/$dir" ] || continue
  log "Importing $dir/"
  out=$(ninja import -i "$OBJECTS_DIR/$dir" -O 2>&1) || true
  summary=$(echo "$out" | grep -o 'Import finished.*' | tail -n1)
  echo "$out" | grep -E '^\[.*ERROR' || true
  if [ -z "$summary" ]; then
    fail "No 'Import finished' summary for $dir/ -- raw output:\n$out"
  fi
  log "  $summary"
  errors=$(echo "$summary" | sed -n 's/.*error: \([0-9]\+\).*/\1/p')
  processed=$(echo "$summary" | sed -n 's/.*Processed: \([0-9]\+\).*/\1/p')
  errors="${errors:-0}"
  processed="${processed:-0}"
  total_processed=$((total_processed + processed))
  total_errors=$((total_errors + errors))
  if [ "$errors" -gt 0 ]; then
    fail "$dir/ had $errors error(s); stopping before importing anything that depends on it. Fix and re-run."
  fi
done

# warn about, but don't fail on, unexpected extra directories
for d in "$OBJECTS_DIR"/*/; do
  name=$(basename "$d")
  if [[ ! " ${IMPORT_ORDER[*]} " == *" $name "* ]] && [[ ! " ${EXCLUDE_DIRS[*]} " == *" $name "* ]]; then
    log "NOTE: '$name/' is not a known object type (not imported, not excluded) -- check it manually"
  fi
done

log "All imports complete: $total_processed objects processed, $total_errors errors."

# --- 5. restart midPoint and verify ------------------------------------------
log "Restarting midpoint service to pick up the new system configuration..."
systemctl restart midpoint
log "Waiting for midPoint to come back up..."
if wait_for_midpoint; then
  log "midPoint is back up and responding on :8080."
else
  fail "midPoint did not come back up after restart -- check: journalctl -u midpoint -f"
fi

log "Done."
