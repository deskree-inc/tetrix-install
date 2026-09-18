#!/usr/bin/env bash
# object-store-preflight.sh — refuse to start the 1.0 stack over an 0.9.x install
# whose objects are still in the retired MinIO volume.
#
# The host-side half of the ADR-0037 D7 upgrade guard. The other half is the
# start-up check inside the `seaweedfs` service, which fails closed on every path
# (the updater's `up -d` included). This one runs BEFORE `docker compose up`, from
# setup.sh, so an operator gets the refusal and the remedy up front instead of a
# restart-looping store, a daemon stuck on `service_healthy`, and — with the
# documented `--remove-orphans` — a MinIO container already removed.
#
# Exit 0  nothing to protect: no legacy volume, an empty one, or the operator has
#         set OBJECT_STORE_MIGRATION_COMPLETE=true in .env (the assertion that the
#         copy is done — the compose twin of Helm's objectStore.migrationComplete).
# Exit 1  the legacy volume still holds objects and no assertion was made.
# Exit 2  could not decide (compose config unreadable). Never treated as "fine".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

marker="$(sed -n 's/^OBJECT_STORE_MIGRATION_COMPLETE=//p' .env 2>/dev/null | tail -1 | tr -d "\"'[:space:]")"
if [ "$marker" = "true" ]; then
  exit 0
fi

# The volume's real name (project prefix included) comes from compose itself, so
# COMPOSE_PROJECT_NAME and -p are honoured the same way `up` honours them.
VOL="$(docker compose config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
print((d.get("volumes") or {}).get("minio-data", {}).get("name", ""))')" || {
  echo "ERROR: object-store-preflight: could not read the compose configuration" >&2
  exit 2
}
# Declaration gone: the retention window is over and there is nothing to guard.
[ -n "$VOL" ] || exit 0
# No such volume on this host: a fresh install, or one that never ran MinIO.
docker volume inspect "$VOL" >/dev/null 2>&1 || exit 0

# Any entry under the bundled bucket is an object (MinIO keeps one <key>/xl.meta
# directory per object). An `ls` error is folded into the output on purpose: a
# directory that cannot be read cannot be proven empty, so it refuses.
docker image inspect busybox:1.37 >/dev/null 2>&1 || docker pull -q busybox:1.37 >/dev/null 2>&1 || true
entries="$(docker run --rm -v "${VOL}:/legacy:ro" busybox:1.37 sh -c \
  '[ -d /legacy/tetrix-objects ] && ls -A /legacy/tetrix-objects 2>&1 | head -n 1' 2>&1)"
[ -n "$entries" ] || exit 0

cat >&2 <<EOF
REFUSING TO START: the retired MinIO volume '${VOL}' still holds objects, and
OBJECT_STORE_MIGRATION_COMPLETE is not 'true' in .env.

This bundle (1.0) runs SeaweedFS, which has its OWN volume. Starting it now would
point the daemon at an EMPTY object store: every entity still lists from
PostgreSQL and every content read returns nothing, with no error anywhere.

  1. Go back to the 0.9.x bundle and run scripts/migrate-object-store.sh
     (ADR-0037 D7); reconcile it against the entity table.
  2. Set OBJECT_STORE_MIGRATION_COMPLETE=true in .env.
  3. Re-run setup.sh. Keep the MinIO volume until you have signed off — it is
     your rollback.
EOF
exit 1
