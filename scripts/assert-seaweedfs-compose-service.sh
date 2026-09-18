#!/usr/bin/env bash
# Start the compose SeaweedFS service for real and check it works.
# (Installer twin of tetrix-ee-helm-chart's scripts/assert-seaweedfs-compose-service.sh;
# the compose file lives at the repo root here.)
#
# WHY THIS EXISTS: nothing in CI started it. Every other guard reads the compose
# file as TEXT — the profiled-service allowlist, the image scan, the pins — so on
# 2026-09-16 a service whose start-up guard compose had silently eaten
# (`${VAR:-}` is interpolated at PARSE time, rendering `[ -z "" ]`) sat in a
# restart loop while lint-and-assert stayed green. `docker compose up` even
# reported "Started". A compose service that is never started is not covered.
#
# Four states, because only the first is obvious:
#   1. with a credential  -> healthy, and anonymous S3 access REFUSED
#   2. with an empty one  -> refuses to start, rather than silently serving the
#      whole object store anonymously while looking healthy
#   3. beside a POPULATED legacy MinIO volume (an 0.9.x install upgraded without
#      running the D7 copy) -> refuses to start. The Helm chart refuses this
#      upgrade at render time (`objectStore.migrationComplete`); compose has no
#      render step, so the refusal has to live in the service itself, or a Cloud
#      VM upgrade and an on-prem `up -d` both point the daemon at an EMPTY store
#      with no error anywhere.
#   4. the same volume with OBJECT_STORE_MIGRATION_COMPLETE=true -> starts. That
#      is the operator asserting the copy is done, the twin of the Helm value.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${ROOT}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
[ -f "$COMPOSE_FILE" ] || { echo "ERROR: ${COMPOSE_FILE} is missing" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: the docker daemon is not reachable" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' is required" >&2; exit 1; }

PROJECT="swassert$$"
MC_IMAGE="quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"
ENVFILE="${COMPOSE_DIR}/.env"
# Written into the file this assert creates, so a leftover from a crashed run is
# distinguishable from an operator's real .env. Without it the "do not clobber"
# guard below turns every later run into a SKIP that exits 0 — a vacuous pass,
# which is the exact failure class this whole change set exists to remove.
ENV_MARKER="# written by assert-seaweedfs-compose-service.sh — safe to delete"
ENV_PREEXISTING=0
if [ -f "$ENVFILE" ]; then
  if head -1 "$ENVFILE" 2>/dev/null | grep -qF "$ENV_MARKER"; then
    echo "note: removing a leftover ${ENVFILE} from an earlier run of this assert"
    rm -f "$ENVFILE"
  else
    ENV_PREEXISTING=1
  fi
fi
pass=0; fail=0
ok()  { echo "  OK: $*";   pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }

dc() { (cd "$COMPOSE_DIR" && docker compose -p "$PROJECT" "$@") ; }
cleanup() {
  dc down -v >/dev/null 2>&1
  # `down -v` removes declared volumes; the legacy one is also removed by name in
  # case a run died between creating it and declaring it.
  docker volume rm -f "${PROJECT}_minio-data" "${PROJECT}_seaweedfs-data" >/dev/null 2>&1
  docker network rm "${PROJECT}_default" >/dev/null 2>&1
  [ "$ENV_PREEXISTING" = "0" ] && rm -f "$ENVFILE"
  return 0
}
trap cleanup EXIT
# An operator's own .env is not ours to overwrite — but skipping must not read as
# a pass, so this exits NON-ZERO and says exactly how to run it.
if [ "$ENV_PREEXISTING" = "1" ]; then
  echo "ERROR: ${ENVFILE} exists and was not written by this assert." >&2
  echo "       It will not be overwritten. Move it aside and re-run." >&2
  exit 1
fi

# TETRIX_HOST is required for the file to decode at all (services[daemon].extra_hosts).
write_env() { # write_env <user> <password> [extra .env line]
  printf '%s\nTETRIX_HOST=tetrix.assert.local\nMINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n%s\n' \
    "$ENV_MARKER" "$1" "$2" "${3:-}" >"$ENVFILE"
}

# A legacy MinIO data volume as an 0.9.x install leaves it: one object under the
# bucket directory, in MinIO's on-disk shape (<key>/xl.meta), plus its metadata
# tree. Created through `compose create` first so the volume carries compose's
# labels and `down -v` owns it.
populate_legacy_volume() {
  dc create seaweedfs >/dev/null 2>&1 || true
  docker run --rm -v "${PROJECT}_minio-data:/v" busybox:1.37 sh -c \
    'mkdir -p /v/tetrix-objects/0123abcd/text /v/.minio.sys/buckets/tetrix-objects \
     && : > /v/tetrix-objects/0123abcd/xl.meta && : > /v/tetrix-objects/0123abcd/text/xl.meta' \
    >/dev/null 2>&1
}

# State of the single seaweedfs container after a short settle: "running", or the
# exit state plus the first log lines, for the refusal cases.
settle_state() {
  sleep 8
  cid="$(dc ps -a -q seaweedfs 2>/dev/null | head -1)"
  [ -n "$cid" ] || { state=absent; code=; logs=; return; }
  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
  code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)"
  logs="$(docker logs "$cid" 2>&1 | head -6)"
}

wait_health() {
  local want="$1" n=0 cid state
  while [ "$n" -lt 45 ]; do
    cid="$(dc ps -q seaweedfs 2>/dev/null | head -1)"
    if [ -n "$cid" ]; then
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null)"
      [ "$state" = "$want" ] && return 0
    fi
    n=$((n+1)); sleep 2
  done
  return 1
}

# The host-side preflight setup.sh runs before `up`: same three states, decided
# from the host. It reads the compose config for the project, so it is run with
# the same project name the service is.
preflight() { (cd "$COMPOSE_DIR" && COMPOSE_PROJECT_NAME="$PROJECT" bash scripts/object-store-preflight.sh 2>&1); }

# ── 1. A credentialed service comes up and refuses anonymous access ──────────
write_env tetrix "assert-secret-$$"
dc up -d seaweedfs >/dev/null 2>&1
healthy=0
if wait_health healthy; then
  healthy=1
  ok "the compose service reaches its own healthcheck's 'healthy' state"
else
  cid="$(dc ps -q seaweedfs 2>/dev/null | head -1)"
  bad "the compose service never became healthy; last logs:"
  [ -n "$cid" ] && docker logs "$cid" 2>&1 | tail -5 | sed 's/^/      /'
fi

# Gated on the service actually being UP. A dead service refuses everything, so
# running this against one would turn an outage into a passing security
# assertion — and "Access Denied" and "could not connect" are both just a failed
# list to a naive match.
if [ "$healthy" = "1" ]; then
  anon="$(docker run --rm --network "${PROJECT}_default" --entrypoint sh "$MC_IMAGE" -c \
    'mc alias set anon http://seaweedfs:8333 "" "" >/dev/null 2>&1; mc ls anon/tetrix-objects 2>&1' 2>/dev/null)"
  case "$anon" in
    *"Access Denied"*|*"AccessDenied"*)
      ok "an anonymous S3 request is refused by the running service" ;;
    *)
      bad "an anonymous S3 request was NOT refused by the running service — the object store is open. Got: ${anon}" ;;
  esac
else
  bad "anonymous access was NOT checked: the service never came up, so this proves nothing about whether the store is closed"
fi
# The legacy volume exists here (compose created it for the mount) and is EMPTY —
# a fresh install. The preflight must let that through.
if out="$(preflight)"; then
  ok "host preflight passes beside an empty legacy volume (fresh install)"
else
  bad "host preflight refused a fresh install with an empty legacy volume: ${out}"
fi
dc down -v >/dev/null 2>&1

# ── 2. An empty credential must stop the service, not open it ────────────────
# The dangerous direction: SeaweedFS engages authentication only when a
# credential is configured, so an empty one would serve every S3 call
# anonymously while /healthz stayed 200.
write_env "" ""
dc up -d seaweedfs >/dev/null 2>&1
sleep 8
cid="$(dc ps -a -q seaweedfs 2>/dev/null | head -1)"
if [ -z "$cid" ]; then
  bad "no seaweedfs container exists after 'up' with an empty credential"
else
  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
  code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)"
  logs="$(docker logs "$cid" 2>&1 | head -3)"
  if [ "$state" = "running" ]; then
    bad "the service is RUNNING with an empty credential — it would serve every S3 call anonymously"
  elif printf '%s' "$logs" | grep -q 'Refusing to start'; then
    ok "an empty credential stops the service (state=${state}, exit=${code}) instead of opening the store"
  else
    bad "the service is not running but did not print the credential refusal; logs: ${logs}"
  fi
fi

dc down -v >/dev/null 2>&1

# ── 3. A populated legacy MinIO volume must stop the service, not be ignored ─
# The upgrade-without-copy case. The two stores have separate volumes, so a
# SeaweedFS that starts here serves an empty bucket: entities still list from
# PostgreSQL, every content read returns nothing, and nothing errors.
write_env tetrix "assert-secret-$$"
populate_legacy_volume
if out="$(preflight)"; then
  bad "host preflight passed beside a POPULATED legacy volume — setup.sh would proceed to up -d"
elif printf '%s' "$out" | grep -q 'REFUSING TO START' && printf '%s' "$out" | grep -q 'migrate-object-store.sh'; then
  ok "host preflight refuses beside a populated legacy volume and names the remedy"
else
  bad "host preflight failed without the expected refusal text: ${out}"
fi
dc up -d seaweedfs >/dev/null 2>&1
settle_state
if [ "$state" = "absent" ]; then
  bad "no seaweedfs container exists after 'up' beside a populated legacy volume"
elif [ "$state" = "running" ]; then
  bad "the service is RUNNING beside a populated legacy MinIO volume — an upgraded 0.9.x install would be pointed at an EMPTY store"
elif printf '%s' "$logs" | grep -q 'OBJECT_STORE_MIGRATION_COMPLETE'; then
  ok "a populated legacy MinIO volume stops the service (state=${state}, exit=${code}) and names the remedy"
else
  bad "the service is not running but did not print the legacy-volume refusal; logs: ${logs}"
fi
dc down -v >/dev/null 2>&1
docker volume rm -f "${PROJECT}_minio-data" >/dev/null 2>&1

# ── 4. The operator's assertion that the copy is done lets it start ──────────
write_env tetrix "assert-secret-$$" "OBJECT_STORE_MIGRATION_COMPLETE=true"
populate_legacy_volume
if out="$(preflight)"; then
  ok "host preflight passes once the operator asserts the migration is complete"
else
  bad "host preflight still refuses with OBJECT_STORE_MIGRATION_COMPLETE=true: ${out}"
fi
dc up -d seaweedfs >/dev/null 2>&1
if wait_health healthy; then
  ok "with OBJECT_STORE_MIGRATION_COMPLETE=true the same volume no longer blocks the service"
else
  settle_state
  bad "the service did not start even though the operator asserted the migration is complete (state=${state}); logs: ${logs}"
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
