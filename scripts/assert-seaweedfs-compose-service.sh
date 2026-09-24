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

# ── The anonymous-S3 verdict ─────────────────────────────────────────────────
# anon_probe <network> <image> <url> [sh prefix]: an UNSIGNED S3 ListObjects (a
# plain GET on the bucket) from a throwaway container, with busybox `wget -S` so
# the HTTP status line is printed even on an error status. The last line is
# always `probe-exit=<wget's exit>` once the container ran.
anon_probe() {
  docker run --rm --network "$1" --entrypoint sh "$2" -c \
    "${4:-:}; wget -S -O- '$3' 2>&1; echo \"probe-exit=\$?\"" 2>&1
}

# classify_anon_probe <transcript> -> closed | open | could-not-run
# The verdict is taken from the HTTP status the SERVER sent, never from the mere
# fact that the probe container ran: busybox wget exits 1 on ANY error status
# (403 and 404 alike) and also on "bad address" / "Connection refused", and the
# shell exits 127 when wget is missing, so the exit code alone cannot tell a
# closed store from an open one or from no answer at all.
#   403 (S3 AccessDenied)                    -> closed
#   404 (NoSuchBucket), or 2xx with exit 0   -> open (the anonymous call was served)
#   no status line, any other status, no
#   probe-exit marker (docker run failed)    -> could-not-run: neither verdict
classify_anon_probe() {
  local out="$1" exitcode status
  exitcode="$(printf '%s\n' "$out" | sed -n 's/^probe-exit=\([0-9][0-9]*\)$/\1/p' | tail -1)"
  [ -n "$exitcode" ] || { echo could-not-run; return; }
  status="$(printf '%s\n' "$out" | grep -oE 'HTTP/1\.[01] [0-9]{3}' | tail -1 | awk '{print $2}')"
  case "$status" in
    403) echo closed ;;
    404) echo open ;;
    2??) if [ "$exitcode" = "0" ]; then echo open; else echo could-not-run; fi ;;
    "")
      # No status line: only a body can still decide (another client's output shape).
      case "$out" in
        *AccessDenied*|*"Access Denied"*) echo closed ;;
        *NoSuchBucket*) echo open ;;
        *) echo could-not-run ;;
      esac ;;
    *) echo could-not-run ;;
  esac
}

# --self-test: the classifier on the transcripts each outcome really produces
# (captured from chrislusf/seaweedfs:4.47's busybox wget), then — when a docker
# daemon is reachable — the two "could not run" cases for real: wget missing,
# and a connection refused.
if [ "${1:-}" = "--self-test" ]; then
  st_pass=0; st_fail=0
  expect() { # expect <want> <name> <transcript>
    local got; got="$(classify_anon_probe "$3")"
    if [ "$got" = "$1" ]; then echo "  OK: $2 -> $got"; st_pass=$((st_pass+1))
    else echo "  FAIL: $2 -> $got (want $1)"; st_fail=$((st_fail+1)); fi
  }
  expect closed "403 AccessDenied (closed store)" "Connecting to seaweedfs:8333 (172.18.0.2:8333)
  HTTP/1.1 403 Forbidden
  Content-Type: application/xml
wget: server returned error: HTTP/1.1 403 Forbidden
probe-exit=1"
  expect open "404 NoSuchBucket (open store, bucket absent)" "Connecting to seaweedfs:8333 (172.18.0.2:8333)
  HTTP/1.1 404 Not Found
wget: server returned error: HTTP/1.1 404 Not Found
probe-exit=1"
  expect open "200 ListBucketResult (open store)" "Connecting to seaweedfs:8333 (172.18.0.2:8333)
  HTTP/1.1 200 OK
writing to stdout
<ListBucketResult><Name>tetrix-objects</Name></ListBucketResult>
probe-exit=0"
  expect could-not-run "wget missing" "sh: wget: not found
probe-exit=127"
  expect could-not-run "connection refused" "Connecting to seaweedfs:8333 (172.18.0.2:8333)
wget: can't connect to remote host (172.18.0.2): Connection refused
probe-exit=1"
  expect could-not-run "name does not resolve" "wget: bad address 'seaweedfs:8333'
probe-exit=1"
  expect could-not-run "5xx from the gateway" "  HTTP/1.1 503 Service Unavailable
wget: server returned error: HTTP/1.1 503 Service Unavailable
probe-exit=1"
  expect could-not-run "docker run itself failed (no probe-exit marker)" "Unable to find image 'x:y' locally
docker: Error response from daemon: pull access denied"
  expect could-not-run "empty output" ""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # The image the compose service defaults to, read from the file (config --images needs a .env).
    st_image="$(sed -n 's/^ *image: *\(chrislusf\/seaweedfs\):\${SEAWEEDFS_IMAGE_TAG:-\([^}]*\)}.*/\1:\2/p' "$COMPOSE_FILE" | head -1)"
    [ -n "$st_image" ] || { echo "  FAIL: cannot read the seaweedfs image from ${COMPOSE_FILE}"; exit 1; }
    docker pull -q "$st_image" >/dev/null 2>&1 || true
    expect could-not-run "live: wget missing ($st_image)" \
      "$(anon_probe none "$st_image" http://127.0.0.1:8333/tetrix-objects 'PATH=/nonexistent')"
    expect could-not-run "live: connection refused ($st_image)" \
      "$(anon_probe none "$st_image" http://127.0.0.1:8333/tetrix-objects)"
  else
    echo "  note: no docker daemon; the two live cases were not run"
  fi
  echo "self-test: ${st_pass} passed, ${st_fail} failed"
  [ "$st_fail" -eq 0 ] || exit 1
  exit 0
fi
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: the docker daemon is not reachable" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' is required" >&2; exit 1; }

PROJECT="swassert$$"
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
#
# The probe (anon_probe above) runs from a sibling container on the project
# network, using the service's OWN image, so nothing extra is pulled: this used
# quay.io/minio/mc until that image stopped being publicly pullable, which turned
# this check red for every PR with an empty "Got:". classify_anon_probe decides
# from the server's HTTP status; a probe that got no answer is neither verdict
# (and still fails this assert).
if [ "$healthy" = "1" ]; then
  sw_cid="$(dc ps -q seaweedfs 2>/dev/null | head -1)"
  sw_image="$(docker inspect -f '{{.Config.Image}}' "$sw_cid" 2>/dev/null)"
  anon="$(anon_probe "${PROJECT}_default" "$sw_image" http://seaweedfs:8333/tetrix-objects)"
  anon_flat="$(printf '%s' "$anon" | tr '\n' ' ' | cut -c1-300)"
  case "$(classify_anon_probe "$anon")" in
    closed)
      ok "an anonymous S3 request is refused by the running service (403)" ;;
    open)
      bad "an anonymous S3 request was NOT refused by the running service — the object store is open. Got: ${anon_flat}" ;;
    *)
      bad "the anonymous S3 probe got no usable answer (image ${sw_image:-?}); this proves nothing about the store either way. Got: ${anon_flat}" ;;
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
