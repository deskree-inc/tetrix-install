#!/usr/bin/env bash
# Mint a registry credential from this deployment's licence and `docker login`
# with it (tetrix-architecture ADR-0024).
#
# This is the compose twin of the chart's credential CronJob + bootstrap Job.
# Compose has no scheduler, so the same job is split in two: setup.sh calls this
# once before starting the stack, and scripts/install-credential-timer.sh installs
# a systemd timer that re-runs it every 30 minutes.
#
# THE CREDENTIAL LIVES AT MOST AN HOUR. That is the point of ADR-0024 — nothing
# long-lived is ever handed to a customer — but it means a host that has been idle
# needs a fresh login before `docker compose pull`. Re-run this; it is idempotent
# and cheap.
#
# Nothing here prints the credential. The mint response goes to a 600 temp file
# that is removed on exit, and the password reaches docker only on stdin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MINT_URL="${TETRIX_MINT_URL:-https://ops.deskree.com/api/licensing/registry-token}"
CLOUD_ENV="${TETRIX_CLOUD_ENV:-/etc/tetrix/cloud.env}"
DO_PULL=false

for arg in "$@"; do
  case "$arg" in
    --pull) DO_PULL=true ;;
    --no-pull) DO_PULL=false ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/registry-login.sh [--pull]

  NON-CLOUD (ADR-0024, unchanged): mints a short-lived registry credential from
  LICENSE_TOKEN in .env and runs `docker login` against TETRIX_IMAGE_ORIGIN. Safe
  to re-run at any time; the credential expires within the hour, so re-run before
  `docker compose pull` on a host that has been idle.

  No-ops when TETRIX_IMAGE_ORIGIN is empty (pulling from Docker Hub — use your
  own `docker login` for that).

  Needs network access to ops.deskree.com.

  CLOUD (TETRIX_DEPLOYMENT_MODE=cloud): no mint at all. The deployment license IS
  the registry password and the deployment UUID is the username, so this logs in
  with them directly into a tmpfs Docker config, pulls, logs out, and removes the
  config. --pull is what cloud-up.sh passes; without it the login is left in place
  for a caller that will pull itself.
EOF
      exit 0
      ;;
  esac
done

# ── Cloud: the license is the credential, just in time ────────────────────────
# There is no mint, no broker, no second credential and no timer. The whole
# reason cloud can do this is that the license is already on the box in tmpfs and
# already scoped to this deployment — minting a short-lived credential FROM it
# would add a control-plane round trip and a second secret to protect without
# reducing what a compromise yields.
MODE="${TETRIX_DEPLOYMENT_MODE:-}"
if [ -z "$MODE" ] && [ -r "$CLOUD_ENV" ]; then
  MODE="$(sed -n 's/^TETRIX_DEPLOYMENT_MODE=//p' "$CLOUD_ENV" | head -1)"
fi

if [ "${MODE:-dev}" = "cloud" ]; then
  [ -r "$CLOUD_ENV" ] || { echo "ERROR: ${CLOUD_ENV} is not readable" >&2; exit 2; }
  set -a
  # shellcheck source=/dev/null  # a constant path unless a test overrides it
  . "$CLOUD_ENV"
  set +a

  : "${TETRIX_DEPLOYMENT_ID:?TETRIX_DEPLOYMENT_ID is required in cloud mode}"

  cloud_die() { printf '%s\n' "$1" >&2; echo "ERROR: ${2}" >&2; exit "${3:-1}"; }

  # The Docker config MUST be tmpfs. A credential written to $HOME/.docker
  # survives a reboot, and "just in time" then means nothing.
  DOCKER_CONFIG="${TETRIX_DOCKER_CONFIG_DIR:-/run/tetrix/docker}"
  case "$DOCKER_CONFIG" in
    /run/tetrix/*) ;;
    *) cloud_die tetrix_registry_auth_failed \
         "cloud mode requires the Docker config under /run/tetrix (got ${DOCKER_CONFIG})" 2 ;;
  esac
  export DOCKER_CONFIG

  # EVERY remaining precondition is checked before the config directory is
  # created. Creating it first left a directory behind on refusal, and — worse —
  # made the two checks below unreachable on any host without a real /run, so
  # they could not be tested at all.

  # Registry host is validated, not taken on trust: this credential is the
  # license, so `docker login` against an attacker-named host is exfiltration.
  ORIGIN="${TETRIX_IMAGE_ORIGIN:-registry.deskree.com/}"
  REGISTRY="${ORIGIN%/}"
  REGISTRY="${REGISTRY#https://}"
  REGISTRY="${REGISTRY#http://}"
  ALLOWED_REGISTRY="${TETRIX_CLOUD_REGISTRY:-registry.deskree.com}"
  [ "$REGISTRY" = "$ALLOWED_REGISTRY" ] || cloud_die tetrix_registry_auth_failed \
    "cloud mode may only authenticate to ${ALLOWED_REGISTRY} (got ${REGISTRY})" 2

  LICENSE_FILE="${TETRIX_LICENSE_FILE:-${TETRIX_RUNTIME_DIR:-/run/tetrix/runtime}/license}"
  [ -s "$LICENSE_FILE" ] || cloud_die tetrix_registry_auth_failed \
    "the deployment license is not in tmpfs; load-license.sh must run first" 1

  command -v docker >/dev/null 2>&1 || cloud_die tetrix_registry_auth_failed \
    "docker is not on PATH" 2

  # Preconditions all hold; only now is the tmpfs credential surface created.
  install -d -m 0700 "$DOCKER_CONFIG"

  cloud_cleanup() {
    docker logout "$REGISTRY" >/dev/null 2>&1 || true
    rm -rf "$DOCKER_CONFIG"
  }

  # --password-stdin: the license never appears in argv or shell history.
  if ! tr -d '\r\n' <"$LICENSE_FILE" \
       | docker login "$REGISTRY" --username "$TETRIX_DEPLOYMENT_ID" \
         --password-stdin >/dev/null 2>&1; then
    cloud_cleanup
    cloud_die tetrix_registry_auth_failed \
      "the registry refused this deployment's license" 1
  fi
  echo "Authenticated to ${REGISTRY} as ${TETRIX_DEPLOYMENT_ID} (tmpfs config)"

  if [ "$DO_PULL" = true ]; then
    # Digest pulls only: COMPOSE_FILE carries docker-compose.release.yml, so every
    # image resolved here is an immutable sha256 reference.
    trap 'cloud_cleanup' EXIT
    if ! bash "${ROOT}/scripts/compose.sh" pull --quiet; then
      printf '%s\n' tetrix_registry_pull_failed >&2
      echo "ERROR: pulling the pinned release images failed" >&2
      exit 1
    fi
    echo "Pulled the pinned release images"
    # Credential removed here rather than only on exit, so it is gone the moment
    # the pull that needed it finished.
    trap - EXIT
    cloud_cleanup
    echo "Removed the tmpfs Docker credential"
  fi
  exit 0
fi

# ── Non-cloud (ADR-0024 legacy mint) ──────────────────────────────────────────
# Honour an explicit TETRIX_DOCKER_CONFIG_DIR here too, so a non-cloud operator
# who wants the credential somewhere other than $HOME/.docker gets it — but the
# DEFAULT stays $HOME/.docker, because that is the config `docker compose pull`
# reads on this host and changing it would silently break existing installs.
DOCKER_CONFIG="${TETRIX_DOCKER_CONFIG_DIR:-${DOCKER_CONFIG:-$HOME/.docker}}"
export DOCKER_CONFIG
install -d -m 0700 "$DOCKER_CONFIG"

env_get() {
  grep -E "^${1}=" .env 2>/dev/null | cut -d= -f2- | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

if [ ! -f .env ]; then
  echo "ERROR: no .env in ${ROOT}. Run ./scripts/setup.sh first." >&2
  exit 1
fi

ORIGIN="${TETRIX_IMAGE_ORIGIN-$(env_get TETRIX_IMAGE_ORIGIN)}"
if [ -z "$ORIGIN" ]; then
  echo "TETRIX_IMAGE_ORIGIN is empty — images come from Docker Hub, so there is"
  echo "nothing for this script to do. Use your own 'docker login' if those pulls"
  echo "need credentials."
  exit 0
fi
# Accept "registry.deskree.com/" (as .env writes it) or a bare host.
REGISTRY="${ORIGIN%/}"

TOKEN="${LICENSE_TOKEN-$(env_get LICENSE_TOKEN)}"
if [ -z "$TOKEN" ]; then
  cat >&2 <<EOF
ERROR: LICENSE_TOKEN is empty in .env.

The registry broker mints its pull credential FROM the licence, so an unlicensed
install cannot use it. Either paste your licence token into .env, or pull from
Docker Hub instead by setting:

    TETRIX_IMAGE_ORIGIN=

(and running your own 'docker login').
EOF
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not on PATH." >&2
  exit 1
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/tetrix-mint.XXXXXX")"
chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT

# Retry only what is worth retrying. A refused licence is answered immediately —
# re-asking cannot change it, and each attempt spends one of the 10 mints/hour
# this deployment is allowed.
attempt=0
while :; do
  attempt=$((attempt + 1))
  CODE="$(curl -sS --connect-timeout 15 --max-time 60 \
            -o "$TMP" -w '%{http_code}' \
            -X POST "$MINT_URL" \
            -H "authorization: Bearer ${TOKEN}" \
            -H 'content-type: application/json' \
            -d '{}' 2>/dev/null)" || CODE=000

  case "$CODE" in
    200) break ;;
    401|403)
      echo "ERROR: the control plane refused this licence." >&2
      echo "  $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("detail") or d.get("error") or "no detail")' "$TMP" 2>/dev/null || echo 'no detail')" >&2
      echo "This is the licence being enforced, not a transient error — the broker is" >&2
      echo "where suspension and revocation take effect. Contact Deskree support." >&2
      exit 1 ;;
    000|429|500|502|503|504)
      if [ "$attempt" -ge 3 ]; then
        if [ "$CODE" = "429" ]; then
          echo "ERROR: mint rate cap reached (10/hour for this deployment)." >&2
          echo "Nothing is wrong with the licence — retry shortly." >&2
        else
          echo "ERROR: cannot reach the Deskree control plane after ${attempt} attempts." >&2
          echo "  ${MINT_URL} (HTTP ${CODE})" >&2
          echo "This is a CONNECTIVITY problem, not a licensing one. Compose installs need" >&2
          echo "egress to ops.deskree.com. To pull from Docker Hub instead, set" >&2
          echo "TETRIX_IMAGE_ORIGIN= in .env and use your own 'docker login'." >&2
        fi
        exit 1
      fi
      echo "attempt ${attempt} got HTTP ${CODE}; retrying..." >&2
      sleep 5 ;;
    *)
      echo "ERROR: unexpected HTTP ${CODE} from ${MINT_URL}" >&2
      exit 1 ;;
  esac
done

USERNAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["username"])' "$TMP")"
EXPIRES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("expires_at",""))' "$TMP")"

# --password-stdin so the credential never appears in argv or the shell history.
if ! python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["password"])' "$TMP" \
     | docker login "$REGISTRY" --username "$USERNAME" --password-stdin >/dev/null 2>&1; then
  echo "ERROR: 'docker login ${REGISTRY}' failed with the minted credential." >&2
  echo "The mint succeeded, so this is a docker-side problem — check that the daemon" >&2
  echo "is running and can reach ${REGISTRY}." >&2
  exit 1
fi

echo "Logged in to ${REGISTRY} (expires ${EXPIRES:-within the hour})."
