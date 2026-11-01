# import-midpoint-config.sh

Imports a midPoint `objects/` export tree (resources, roles, archetypes, tasks, etc.) into a running
midPoint instance via `bin/ninja.sh`, fixing up the parts that never survive a move between servers, and
restarts the service. Self-contained — copy this one file to any midPoint box and run it.

## Requirements on the target instance

- midPoint installed as a bare/native install (not Docker) under `/opt/midpoint`, with:
  - `bin/ninja.sh` present and working
  - a native PostgreSQL repository (`<repository><type>native</type></repository>` in `config.xml`)
  - a systemd service literally named `midpoint` (`systemctl restart midpoint` must work)
  - a system user named `midpoint` that owns `/opt/midpoint` and can run `ninja.sh`
- `python3` and `curl` available (both present by default on Amazon Linux 2023).
- You're running the script as root (`sudo`), on the instance itself — not remotely.

This matches the Terraform in `infra/terraform/` in this repo; if you provisioned midPoint some other way,
check those three things first.

## Usage

1. **Upload `objects/` and this script onto the instance.** With WinSCP (or plain `scp`), log in as
   `ec2-user` and drop both into its home directory:
   - `/home/ec2-user/objects/` — the config tree
   - `/home/ec2-user/import-midpoint-config.sh` — the script

   They don't strictly need to live there or together — the script only ever reads from wherever you
   point it, and immediately copies everything into its own scratch directory
   (`/tmp/midpoint-config-import/`) before touching anything — but this is the simplest default and what
   this README's examples assume. `ec2-user`'s home directory is `700` (private to that user), which is
   fine: you run the script via `sudo`, and root can read it regardless.

2. Run it as root, pointing at wherever `objects/` landed:
   ```bash
   cd /home/ec2-user
   chmod +x import-midpoint-config.sh
   sudo MIDPOINT_ADMIN_PASSWORD='<midpoint administrator password>' \
     ./import-midpoint-config.sh /home/ec2-user/objects
   ```
   If you don't pass `MIDPOINT_ADMIN_PASSWORD`, it will prompt for it interactively (hidden input).

The admin password is needed because the script calls the REST API (`/ws/rest/connectors`,
`/ws/rest/self`) to read the instance's own connector catalog and to confirm the app is actually up —
it does not use the REST API to import objects (that's all done via `ninja.sh` directly against the
repository).

## What it does, step by step

1. **Validates arguments and starts logging.** Once it knows it's running as root with a valid source
   directory, everything it prints from that point on is also written to a timestamped file under
   `/var/log/midpoint-config-import/` (see "Where to find logs" below) in addition to your terminal.
2. **Stages a scratch copy.** Copies your `objects/` folder to `/tmp/midpoint-config-import/objects` and
   strips OS junk files (`._*` AppleDouble files from macOS, `Thumbs.db`, `desktop.ini`). Your original
   upload is never modified.
3. **Starts midPoint if it isn't running**, then waits for it to respond.
4. **Fixes `connectorRef` in every resource.** Connector objects (`ConnectorType`) are discovered and
   assigned an OID by each midPoint install independently — the OID baked into a resource exported from
   server A will almost never exist on server B. The script fetches this instance's own connector list,
   matches each resource's connector by **bundle + type** (parsed from the
   `connectorConfiguration` XML namespace), and rewrites `connectorRef` to the right local OID.
   - If a resource's connector bundle isn't installed on this instance at all (e.g. a connector that
     only exists on the source server), it's left untouched and printed as a `WARN` — that resource will
     not work until the matching connector JAR is installed here.
5. **Suspends imported tasks.** Every `Task` with `executionState=runnable` in the export is forced to
   `suspended` on import, so nothing starts polling or syncing a resource the moment it lands. Set
   `SUSPEND_IMPORTED_TASKS=false` if you explicitly want tasks to come in with whatever state they were
   exported with.
6. **Imports everything via `ninja.sh import -O`**, one object type directory at a time, in dependency
   order (schemas → lookup tables → policies → archetypes → roles/orgs/services → resources → tasks →
   collections/dashboards/reports → system configuration last, since it references almost everything
   else). Stops immediately at the first directory with import errors, rather than importing something
   whose dependencies failed.
7. **Restarts `midpoint`** and polls `/ws/rest/self` until it responds (or times out after 2 minutes),
   so you get a clear pass/fail rather than "the restart command didn't error."

**Never imported, on purpose:**
- `simulationResults/` — disposable bulk simulation output, not configuration.
- `connectors/` — connector objects are managed by midPoint's own classpath discovery; hand-importing a
  stale export of them would conflict with that, not fix anything.

## Where to find logs during/after an import

- **`/var/log/midpoint-config-import/import-<timestamp>.log`** — the script automatically saves a full
  copy of everything it printed (timestamped progress, each batch's `Import finished...` summary, every
  `FIXED`/`WARN`/`SKIP`/`OK` line from the connectorRef remap step) to a new timestamped file here on
  every run, in addition to showing it live in your terminal. The exact path is printed as the first line
  of output (`Logging to /var/log/midpoint-config-import/import-...log`). Override the directory with
  `LOG_DIR=/some/other/path` if needed.
- **`/opt/midpoint/var/log/midpoint.log`** — midPoint's own application log. `ninja.sh` runs against the
  same `midpoint.home` as the live service and logs to this same file, so deeper detail behind any
  `ERROR` line the script prints (full stack trace, which object/OID failed) is here, not in the script's
  own output.
- **`journalctl -u midpoint -f`** — the service-level log for the final restart step. If the script's own
  health-check times out ("midPoint did not come back up after restart"), this is where to see why the
  process itself didn't come up (crash, port conflict, keystore error, etc. — see the main
  `infra/README.md` for an example of a startup failure diagnosed this way).
- **`/tmp/midpoint-config-import/objects`** on the instance — the scratch copy the script actually fed to
  `ninja.sh`, left behind after the run. Useful for confirming exactly what was imported, e.g. what
  `connectorRef` ended up in a given resource file or which tasks got suspended.

## Known limitations

- **Connector credentials don't survive.** Passwords in `connectorConfiguration` are encrypted
  (`protectedString`) with the *source* server's keystore and won't decrypt here. Resources import fine
  structurally but will fail test-connection until credentials are re-entered on this instance.
- **CSV/file-based resources need their data files too.** This script only moves `objects/` — if a
  resource points at a local CSV file (e.g. under `midpoint.home/import/`), that file isn't part of this
  transfer and needs to be copied separately for the resource to actually connect.
- **Connector version matching is bundle+type only**, not version-exact. If an instance somehow has
  multiple versions of the same connector bundle installed, the script picks the highest version string
  — fine for the normal case of exactly one version per bundle.

## Troubleshooting

- Re-run is safe: the script always does a clean scratch copy and `ninja.sh import -O` (overwrite), so
  running it again just re-applies the same `objects/` tree.
- If it stops mid-way with an error, the batch it stopped on and everything after it was **not**
  imported; everything before it already was. Fix the reported problem and re-run from the top — earlier
  batches re-importing is harmless.
- `journalctl -u midpoint -f` for live application logs if the final restart/health-check fails.
- The scratch copy at `/tmp/midpoint-config-import/objects` is left behind after the script finishes —
  useful for inspecting exactly what got imported (including the rewritten `connectorRef` values).
