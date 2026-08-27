#!/usr/bin/env bash
# One-command bootstrap: .env, secrets, TLS, /etc/hosts, Traefik routes, stack start.
# Only interactive prompt: OPENAI_API_KEY (unless already in .env or the environment).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NO_START=false
MODE_ARG=""
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=true ;;
    --mode=*) MODE_ARG="${arg#--mode=}" ;;
    cloud|dev) MODE_ARG="$arg" ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/setup.sh [--no-start]

  Creates .env (from .env.example), prompts for OPENAI_API_KEY if missing,
  auto-generates unset passwords into .env (persisted; re-runs never rotate),
  generates TLS certs, updates /etc/hosts, renders Traefik routes,
  fetches Deskree ops license verify keys into .local-license-keys/,
  then runs "docker compose up -d" unless --no-start is passed.

  Chart-managed secrets match Helm (tetrix/aidb/postgres/neo4j/meili/minio/
  Keycloak/collectors CP). Skip the OpenAI prompt by exporting OPENAI_API_KEY
  or setting it in .env first. Network access to ops.deskree.com is required
  (no empty/dev-key fallback).
EOF
      exit 0
      ;;
  esac
done

rand_hex() {
  openssl rand -hex 24
}

# Helm twin: templates/secret.yaml uses randAlphaNum N (alnum, no punctuation).
rand_alnum() {
  local n="${1:-32}"
  openssl rand -base64 "$((n * 2))" | tr -d '/+=' | head -c "${n}"
}

set_env_key() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    local escaped
    escaped="$(printf '%s' "$value" | sed -e 's/[&/\]/\\&/g')"
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

get_env_key() {
  local key="$1"
  # Trim whitespace / CR so "KEY=  " counts as unset (auto-gen). In cloud mode
  # ENV_FILE is the tmpfs render, so reads work without ever writing back.
  grep -E "^${key}=" "${ENV_FILE:-.env}" 2>/dev/null | cut -d= -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

# Persist store = .env (Helm twin of lookup on <release>-tetrixaidb-secrets).
# Empty / missing → generate once; non-empty → reuse (re-runs / upgrades never rotate).
ensure_secret() {
  local key="$1"
  local generator="${2:-hex}" # hex | alnum | alnum48
  local current
  current="$(get_env_key "$key")"
  if [ -n "${current}" ]; then
    return 0
  fi
  local value
  case "${generator}" in
    alnum) value="$(rand_alnum 32)" ;;
    alnum48) value="$(rand_alnum 48)" ;;
    *) value="$(rand_hex)" ;;
  esac
  set_env_key "$key" "${value}"
  echo "Generated ${key} (persisted in .env)"
}

ensure_secret_alnum() {
  ensure_secret "$1" alnum
}

prompt_openai_api_key() {
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    set_env_key OPENAI_API_KEY "${OPENAI_API_KEY}"
    return
  fi

  local current
  current="$(get_env_key OPENAI_API_KEY)"
  if [ -n "${current}" ]; then
    return
  fi

  if [ ! -t 0 ]; then
    echo "ERROR: OPENAI_API_KEY is not set. Export it or add it to .env before running setup non-interactively." >&2
    exit 1
  fi

  local key=""
  while [ -z "${key}" ]; do
    read -rsp "Enter OPENAI_API_KEY: " key
    echo
    if [ -z "${key}" ]; then
      echo "OPENAI_API_KEY is required." >&2
    fi
  done
  set_env_key OPENAI_API_KEY "${key}"
}

ensure_hosts_entry() {
  local ip="$1"
  local hostname="$2"
  local hosts_file="/etc/hosts"

  if grep -qE "[[:space:]]${hostname}([[:space:]]|$)" "${hosts_file}" 2>/dev/null; then
    return 0
  fi

  local line="${ip}  ${hostname}"
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "${line}" >> "${hosts_file}"
    echo "Added ${hostname} to ${hosts_file}"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    echo "Adding ${hostname} to ${hosts_file} (sudo required)..."
    if printf '%s\n' "${line}" | sudo tee -a "${hosts_file}" >/dev/null; then
      echo "Added ${hostname} to ${hosts_file}"
      return 0
    fi
  fi

  echo "WARN: Could not update ${hosts_file}. Add this line manually:" >&2
  echo "  ${line}" >&2
  return 1
}

# Helm twin: ConfigMap → /app/licensing/baked_keys/public_keys.json from ops keyset.
# The licensing image ignores LICENSE_PUBLIC_KEYS / TETRIX_LICENSING_PUBLIC_KEYS.
fetch_ops_license_keys() {
  local url="https://ops.deskree.com/api/licensing/keys"
  local dest_dir=".local-license-keys"
  local dest="${dest_dir}/public_keys.json"
  local tmp kids

  mkdir -p "${dest_dir}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/tetrix-ops-keys.XXXXXX")"

  echo "Fetching Deskree ops license verify keys (${url})..."
  if ! curl -fsSL --connect-timeout 15 --max-time 60 "${url}" -o "${tmp}"; then
    rm -f "${tmp}"
    echo "ERROR: Failed to fetch license verify keys from ${url}" >&2
    echo "  Network access to ops.deskree.com is required before docker compose up." >&2
    echo "  Refusing to start with the image default 'dev' kid or an empty keyset." >&2
    exit 1
  fi

  if ! kids="$(
    python3 - "${tmp}" "${dest}" <<'PY'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
try:
    payload = json.load(open(src, encoding="utf-8"))
except Exception as e:
    print(f"invalid JSON from ops keys endpoint: {e}", file=sys.stderr)
    sys.exit(2)
keys = payload.get("keys") if isinstance(payload, dict) else None
if not isinstance(keys, dict) or not keys:
    print("ops keys response missing non-empty .keys object", file=sys.stderr)
    sys.exit(2)
# Compact JSON object {kid: PEM} — same shape Helm mounts.
with open(dest, "w", encoding="utf-8") as f:
    json.dump(keys, f, separators=(",", ":"))
    f.write("\n")
print(" ".join(sorted(keys)))
PY
  )"; then
    rm -f "${tmp}"
    echo "ERROR: Ops keys response was unusable (expected JSON with non-empty .keys)." >&2
    exit 1
  fi
  rm -f "${tmp}"

  if ! printf '%s' "${kids}" | grep -qw 'k1'; then
    echo "ERROR: Ops verify keyset missing expected kid 'k1' (got: ${kids})." >&2
    exit 1
  fi

  echo "Wrote ${dest} (kids: ${kids})"
}

# Restorable snapshot of the pin-set this stack is running (ADR-0022 D3 compose
# upgrade). The in-app upgrade rewrites the .env pins from the signed release
# manifest; if the apply fails it restores from a snapshot. Values are RESOLVED
# (explicit tags — .env value, else the ${VAR:-default} baked into
# docker-compose.yml), never indirections: a new release bundle ships NEW compose
# defaults, so a snapshot full of ${VAR:-…} would silently "restore" forward.
write_pin_snapshot() {
  local dest="runtime/pin-snapshot.env"
  mkdir -p runtime
  {
    echo "# Applied compose pin-set — written by scripts/setup.sh ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))."
    echo "# Restore target if an in-app Owner upgrade fails (see README.md § Upgrades):"
    echo "#   grep -v '^#' runtime/pin-snapshot.env  # then set these keys in .env"
    echo "#   docker compose up -d --remove-orphans"
    echo "# Resolved values only — no \${VAR:-default} indirection."
    printf 'TETRIX_RELEASE_VERSION=%s\n' "$(get_env_key TETRIX_RELEASE_VERSION)"
    grep -E '^[[:space:]]*image:' docker-compose.yml \
      | grep -oE '\$\{[A-Za-z0-9_]+:-[^}]*\}' \
      | sort -u \
      | while read -r ref; do
          local var default value
          var="${ref#\$\{}"
          var="${var%%:-*}"
          default="${ref#*:-}"
          default="${default%\}}"
          value="$(get_env_key "${var}")"
          printf '%s=%s\n' "${var}" "${value:-${default}}"
        done
  } > "${dest}"
  echo "Wrote ${dest} (restorable pin snapshot)"
}

# Compose bind-mounts the canonical Keycloak helpers from ONE runtime directory
# so the same compose file works from a released tar and from a full checkout.
# A release bundle carries them in chart-scripts/; a checkout has them two levels
# up. Neither path may appear in docker-compose.yml — the released artifact has
# no repository above it (Cloud M0.3, Task 1).
materialize_chart_scripts() {
  local source=""
  if [ -d "${ROOT}/chart-scripts" ]; then
    source="${ROOT}/chart-scripts"
  elif [ -d "${ROOT}/../../scripts" ]; then
    source="${ROOT}/../../scripts"
  else
    echo "ERROR: canonical Keycloak scripts are absent" >&2
    exit 1
  fi
  local dest="${TETRIX_RUNTIME_DIR:-${ROOT}/runtime}/chart-scripts"
  install -d -m 0755 "${dest}"
  for script in keycloak-provision-rest.sh keycloak-provision-kcadm.sh keycloak-dcr-scope-repair.sh; do
    install -m 0755 "${source}/${script}" "${dest}/${script}"
  done
  echo "Materialized canonical Keycloak scripts into ${dest}"
}

sync_derived_urls() {
  local host
  host="$(get_env_key TETRIX_HOST)"
  host="${host:-tetrix.local}"
  set_env_key TETRIX_PUBLIC_URL "https://${host}"
  set_env_key KEYCLOAK_HOSTNAME "https://${host}/auth"
  set_env_key KEYCLOAK_ISSUER "https://${host}/auth/realms/tetrix"
  set_env_key KEYCLOAK_AUDIENCE_DAEMON "https://${host}/api"
  set_env_key MCP_BASE_URL "https://${host}/mcp"
  set_env_key COLLECTORS_AUDIENCE_API "https://${host}/api-collectors"
  set_env_key COLLECTORS_AUDIENCE_MCP "https://${host}/mcp"

  local trusted
  trusted="$(get_env_key KEYCLOAK_TRUSTED_HOSTS)"
  # Strip surrounding quotes if present.
  trusted="${trusted#\"}"
  trusted="${trusted%\"}"
  if [ -z "${trusted}" ] || ! printf '%s' "${trusted}" | grep -q "${host}"; then
    trusted="localhost 127.0.0.1 anysphere.cursor-mcp www.cursor.com claude.ai chatgpt.com ${host}"
  fi
  # Always quote — values contain spaces and must not break shell tooling.
  set_env_key KEYCLOAK_TRUSTED_HOSTS "\"${trusted}\""

  local owner_email
  owner_email="$(get_env_key KEYCLOAK_OWNER_EMAIL)"
  if [ -z "${owner_email}" ]; then
    set_env_key KEYCLOAK_OWNER_EMAIL "owner@${host}"
  fi

  # Helm twin: adminApiIamPassword / licensingIamPassword fall back to resolved tetrixPassword.
  if [ -z "$(get_env_key ADMIN_API_IAM_PASSWORD)" ]; then
    set_env_key ADMIN_API_IAM_PASSWORD "$(get_env_key TETRIX_PASSWORD)"
  fi
  if [ -z "$(get_env_key LICENSING_IAM_PASSWORD)" ]; then
    set_env_key LICENSING_IAM_PASSWORD "$(get_env_key TETRIX_PASSWORD)"
  fi
}

# ── Mode ──────────────────────────────────────────────────────────────────────
# dev   generates and PERSISTS credentials into .env, as it always has.
# cloud generates nothing here: generate-local-secrets.py already put every
#       credential in Vault and render-runtime-env.py rendered them to a tmpfs
#       file. This script must not write a secret to disk in cloud mode — a
#       persisted .env would survive reboot, reach backups, and be snapshotted
#       by the updater, which is the whole thing the tmpfs design avoids.
MODE="${MODE_ARG:-${TETRIX_DEPLOYMENT_MODE:-dev}}"
case "$MODE" in
  dev) ENV_FILE="${ROOT}/.env" ;;
  cloud)
    ENV_FILE="${TETRIX_RUNTIME_ENV:-/run/tetrix/runtime.env}"
    [ -s "$ENV_FILE" ] || {
      echo "ERROR: cloud runtime env is absent; tetrix-secrets.service must run first" >&2
      exit 1
    }
    [ -L "${ROOT}/.env" ] || ln -sfn "$ENV_FILE" "${ROOT}/.env"
    ;;
  *) echo "ERROR: TETRIX_DEPLOYMENT_MODE must be dev or cloud" >&2; exit 2 ;;
esac
export TETRIX_DEPLOYMENT_MODE="$MODE"

# ── Bootstrap .env ────────────────────────────────────────────────────────────
if [ "$MODE" = "dev" ] && [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

if [ "$MODE" = "cloud" ]; then
  # Cloud validates; it never generates or persists. Every required key was
  # rendered from Vault into the tmpfs env before this ran.
  #
  # OPENAI_API_KEY, RESEND_API_KEY and EXPLORE_LLM_API_KEY are deliberately NOT
  # in this list. They are marked `optional` in vault-runtime-keys.txt:
  # external-service credentials the installer never writes, configured after
  # install. Requiring one here would fail a tenant install
  # for a missing SaaS key, so do not add them back. The daemon boots
  # embedding-credentials-pending
  # (ADR-0008), Keycloak skips the realm SMTP merge, and the Explore chat dock
  # shows a degraded face; all three converge when the key arrives.
  missing=""
  for key in LICENSE_TOKEN TETRIX_PASSWORD AIDB_PASSWORD POSTGRES_PASSWORD \
             NEO4J_PASSWORD MEILI_MASTER_KEY MINIO_ROOT_PASSWORD \
             KEYCLOAK_DB_PASSWORD KEYCLOAK_ADMIN_PASSWORD \
             CONTROL_PLANE_DB_PASSWORD KEYCLOAK_ADMIN_CLIENT_SECRET \
             KEYCLOAK_PASSWORD_VERIFY_CLIENT_SECRET \
             TETRIX_HOST TETRIX_RELEASE_VERSION; do
    grep -qE "^${key}=." "$ENV_FILE" || missing="${missing} ${key}"
  done
  if [ -n "$missing" ]; then
    echo "ERROR: cloud runtime env is missing required keys:${missing}" >&2
    exit 1
  fi
  echo "Validated cloud runtime env (no credential was generated or persisted)"
else
  # Drop the legacy Logto/keycloak.yml-era overlay ONLY. This used to delete any
  # COMPOSE_FILE, which in cloud mode would silently drop the release lock and
  # the resource overlay and start an unpinned stack.
  if grep -qE '^COMPOSE_FILE=.*(logto|keycloak\.yml)' .env 2>/dev/null; then
    sed -i.bak '/^COMPOSE_FILE=.*\(logto\|keycloak\.yml\)/d' .env
    echo "Removed legacy Logto-era COMPOSE_FILE overlay from .env"
  fi

  prompt_openai_api_key
fi

if [ "$MODE" = "dev" ]; then
# Chart-managed passwords (Helm templates/secret.yaml auto-gen set) — randAlphaNum 32.
ensure_secret TETRIX_PASSWORD alnum
ensure_secret AIDB_PASSWORD alnum
ensure_secret POSTGRES_PASSWORD alnum
ensure_secret NEO4J_PASSWORD alnum
ensure_secret MEILI_MASTER_KEY alnum
ensure_secret MINIO_ROOT_PASSWORD alnum
ensure_secret KEYCLOAK_DB_PASSWORD alnum
ensure_secret KEYCLOAK_ADMIN_PASSWORD alnum
ensure_secret CONTROL_PLANE_DB_PASSWORD alnum
# Helm twins: keycloak-admin-client (48) / keycloak-owner (32).
ensure_secret KEYCLOAK_ADMIN_CLIENT_SECRET alnum48
ensure_secret KEYCLOAK_PASSWORD_VERIFY_CLIENT_SECRET alnum48
ensure_secret KEYCLOAK_OWNER_PASSWORD alnum
sync_derived_urls

# Release pin-set version — versioned release tarballs (deploy-docker-<version>.tgz)
# ship a VERSION file at this root; stamp it into .env for licensing probe telemetry.
# Empty / missing = unknown (git checkout or manual download). Never overwrite an
# explicit non-empty value (Helm twin: chart .Chart.Version is authoritative there).
if [ -f VERSION ] && [ -z "$(get_env_key TETRIX_RELEASE_VERSION)" ]; then
  release_version="$(tr -d '[:space:]' < VERSION)"
  if [ -n "${release_version}" ]; then
    set_env_key TETRIX_RELEASE_VERSION "${release_version}"
    echo "Stamped TETRIX_RELEASE_VERSION=${release_version} from VERSION file"
  fi
fi

# Absolute HOST path of this project. The updater mounts the project at the fixed
# in-container path /compose; this value is handed to it separately
# (TETRIX_UPDATER_COMPOSE_PROJECT_HOST_DIR) so its transient apply sibling
# (`docker run -v $HOST_DIR:$HOST_DIR`) names a directory the host daemon can
# actually resolve (ADR-0022 D3). Stamped even though the `updater` service is
# behind the opt-in `updater` compose profile — it costs nothing and is one less
# step when an operator enables it.
set_env_key COMPOSE_PROJECT_DIR "${ROOT}"

rm -f .env.bak
fi  # end dev-only credential generation

mkdir -p runtime certs
materialize_chart_scripts
# Drop legacy Logto runtime artifact if present.
# Do not pre-create an empty runtime/vault.env — collectors-worker reads it at
# start; an empty file can race ahead of vault-init and omit VAULT_TOKEN.
rm -f runtime/logto.env

# Baseline for a failed in-app upgrade (the updater re-snapshots before applying).
write_pin_snapshot

TETRIX_HOST="$(get_env_key TETRIX_HOST)"
TETRIX_HOST="${TETRIX_HOST:-tetrix.local}"
TETRIX_IMAGE_TAG="$(get_env_key TETRIX_IMAGE_TAG)"
# Match docker-compose.yml default (do not fall back to :latest).
TETRIX_IMAGE_TAG="${TETRIX_IMAGE_TAG:-sha-44b61f9}"
KEYCLOAK_OWNER_EMAIL="$(get_env_key KEYCLOAK_OWNER_EMAIL)"
AIDB_USERNAME="$(get_env_key AIDB_USERNAME)"

certs_generated=false
if [ "$MODE" = "cloud" ]; then
  # ACME (Traefik HTTP-01) owns the certificate in cloud mode; there is no
  # self-signed material and nothing to add to /etc/hosts. Cloud TLS rendering
  # lands with the Traefik template task.
  echo "Cloud mode: skipping self-signed certificate generation"
elif [ ! -f certs/cert.pem ] || [ ! -f certs/key.pem ]; then
  echo "Generating self-signed TLS certificate for ${TETRIX_HOST}..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout certs/key.pem -out certs/cert.pem \
    -subj "/CN=${TETRIX_HOST}" \
    -addext "subjectAltName=DNS:${TETRIX_HOST}" \
    2>/dev/null
  certs_generated=true
  echo "TLS certs written to certs/"
fi

if [ "$MODE" = "dev" ] && { [ "${certs_generated}" = true ] || [ ! -f certs/ca-bundle.pem ]; }; then
  echo "Building CA bundle for daemon HTTPS trust..."
  docker run --rm --entrypoint cat "deskree/tetrixaidb:${TETRIX_IMAGE_TAG}" \
    /etc/ssl/certs/ca-certificates.crt > certs/ca-bundle.pem 2>/dev/null || true
  cat certs/cert.pem >> certs/ca-bundle.pem
fi

export TETRIX_HOST
# SPA upstream — default is the compose frontend service. frontend-local.sh exports
# host.docker.internal for host-Vite hot reload without mutating this tpl.
export FRONTEND_UPSTREAM="${FRONTEND_UPSTREAM:-http://frontend:8080}"

# ── Traefik ───────────────────────────────────────────────────────────────────
# One output tree. TETRIX_TRAEFIK_DIR is unset in dev, so everything renders in
# place under traefik/ exactly as it always has (frontend-local.sh's
# zz-frontend-local.yml and baseline-vm-refresh.sh still work unchanged). Cloud
# points it at /run/tetrix/runtime/traefik, and the whole edge configuration —
# static file, ACME block, TLS block, routes — lands there together, because
# compose can bind ONE directory at /etc/traefik/dynamic.
TRAEFIK_SRC="${ROOT}/traefik"
if [ "$MODE" = "cloud" ]; then
  # Same derivation compose.sh uses, so the bind source and the render target
  # cannot disagree. /etc/tetrix/cloud.env carries TETRIX_RUNTIME_DIR and
  # TETRIX_STATE_DIR; these two are derived rather than added to that contract.
  TETRIX_TRAEFIK_DIR="${TETRIX_TRAEFIK_DIR:-${TETRIX_RUNTIME_DIR:-/run/tetrix/runtime}/traefik}"
  TETRIX_ACME_DIR="${TETRIX_ACME_DIR:-${TETRIX_STATE_DIR:-/var/lib/tetrix}/acme}"
  # Cloud TLS mode is whatever the frozen cloud config said; the renderer
  # re-validates it against the hostname.
  TETRIX_TLS_MODE="${TETRIX_TLS_MODE:-$(get_env_key TETRIX_TLS_MODE)}"
  TETRIX_ACME_EMAIL="${TETRIX_ACME_EMAIL:-$(get_env_key TETRIX_ACME_EMAIL)}"
  TETRIX_ACME_CA_SERVER="${TETRIX_ACME_CA_SERVER:-$(get_env_key TETRIX_ACME_CA_SERVER)}"
  export TETRIX_TRAEFIK_DIR TETRIX_ACME_DIR TETRIX_ACME_EMAIL TETRIX_ACME_CA_SERVER
fi
TRAEFIK_DIR="${TETRIX_TRAEFIK_DIR:-${TRAEFIK_SRC}}"
install -d -m 0755 "${TRAEFIK_DIR}/dynamic"
envsubst '${TETRIX_HOST} ${FRONTEND_UPSTREAM}' < "${TRAEFIK_SRC}/dynamic/routes.yml.tpl" > "${TRAEFIK_DIR}/dynamic/routes.yml"
envsubst '${TETRIX_HOST}' < "${TRAEFIK_SRC}/dynamic/routes-admin-api.yml.tpl" > "${TRAEFIK_DIR}/dynamic/routes-admin-api.yml"
envsubst '${TETRIX_HOST}' < "${TRAEFIK_SRC}/dynamic/routes-audit.yml.tpl" > "${TRAEFIK_DIR}/dynamic/routes-audit.yml"
envsubst '${TETRIX_HOST}' < "${TRAEFIK_SRC}/dynamic/routes-collectors.yml.tpl" > "${TRAEFIK_DIR}/dynamic/routes-collectors.yml"

# TETRIX_TLS_MODE=self_signed stays the default everywhere, including cloud: a
# tenant only gets ACME because /etc/tetrix/cloud.env says so, and the renderer
# refuses acme outside cloud mode or for a non-platform hostname.
TETRIX_TLS_MODE="${TETRIX_TLS_MODE:-self_signed}" \
TETRIX_HOST="${TETRIX_HOST}" \
TETRIX_TRAEFIK_DIR="${TRAEFIK_DIR}" \
TETRIX_DEPLOYMENT_MODE="${MODE}" \
  bash "${ROOT}/scripts/render-traefik-tls.sh"

# ACME account + certificate state. Created in both modes so the compose bind
# always has a source; only ACME mode ever writes to it.
# shellcheck disable=SC2153  # TETRIX_ACME_DIR is the cloud override, not a typo
ACME_DIR="${TETRIX_ACME_DIR:-${ROOT}/runtime/acme}"
install -d -m 0700 "${ACME_DIR}"
[ -f "${ACME_DIR}/acme.json" ] || : > "${ACME_DIR}/acme.json"
chmod 0600 "${ACME_DIR}/acme.json"

if [ "$MODE" = "dev" ]; then
  ensure_hosts_entry 127.0.0.1 "${TETRIX_HOST}" || true
fi

# Always refresh ops verify keys before compose up (Helm baked-keys twin).
# Fail hard on network/parse errors — do not leave an empty or image-default keyset.
fetch_ops_license_keys

chmod +x postgres/initdb/*.sh scripts/*.sh 2>/dev/null || true

cat <<EOF

Bootstrap complete (Keycloak full stack).

  Web UI:     https://${TETRIX_HOST}/
  Sign-in:    https://${TETRIX_HOST}/auth
  MCP:        https://${TETRIX_HOST}/mcp
  Collectors: https://${TETRIX_HOST}/api/v1
  Audit:      https://${TETRIX_HOST}/api/audit
  Daemon:     tcp://localhost:7779

  SPA Owner:  ${KEYCLOAK_OWNER_EMAIL:-owner@tetrix.local} / (see KEYCLOAK_OWNER_PASSWORD in .env)
  Daemon SDK: ${AIDB_USERNAME:-developer} / (see AIDB_PASSWORD in .env)

  License:    paste a real Deskree-issued token in the SPA (or set LICENSE_TOKEN in .env).
              Verify keys are in .local-license-keys/ (ops keyset; kid k1).

EOF

if [ "${NO_START}" = true ]; then
  echo "Skipped docker compose (passed --no-start). Start with: docker compose up -d"
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker, then run: docker compose up -d"
  exit 1
fi

# Ubuntu docker.io 29 ships the engine only. Without docker-compose-v2,
# `docker compose` is not a command and a cloud `pull --quiet` becomes
# `docker --quiet` (unknown global flag) — tetrix_registry_pull_failed.
ensure_compose_plugin() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose plugin is present"
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || {
    echo "ERROR: docker compose is not a command and apt-get is not available." >&2
    echo "Install Docker Compose v2.24+ (plugin), then re-run." >&2
    exit 1
  }
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends docker-compose-v2 || {
    echo "ERROR: failed to install docker-compose-v2" >&2
    exit 1
  }
  docker compose version >/dev/null 2>&1 || {
    echo "ERROR: docker compose is still missing after installing docker-compose-v2" >&2
    exit 1
  }
  echo "installed docker-compose-v2"
}
ensure_compose_plugin

# Registry credential BEFORE the pull (ADR-0024). No-ops when TETRIX_IMAGE_ORIGIN
# is empty, so a Docker Hub install is unaffected. Not fatal on failure: the
# script has already explained what went wrong, and an operator who is mid-setup
# is better served by reaching the compose step and seeing which images fail than
# by having setup abort with the stack half-configured.
if [ -x ./scripts/registry-login.sh ]; then
  if ! ./scripts/registry-login.sh; then
    echo
    echo "WARNING: could not obtain a registry credential (see above)." >&2
    echo "         Continuing — 'docker compose up' will fail on the deskree/* pulls" >&2
    echo "         until this is fixed. Re-run ./scripts/registry-login.sh then retry." >&2
    echo
  fi
fi

echo "Starting stack (docker compose up -d)..."
# MEASURED: `up -d` DOES return 1 when a `service_completed_successfully` dependency exits
# non-zero (keycloak-owner-org-resolve is one), and returns 0 when a `restart: "no"` one-shot
# that nothing depends on exits non-zero (keycloak-owner-org-sync is one). Under `set -e` the
# first case would abort here with a raw compose error, so the status is captured and folded
# into the gate below, which names the service and prints its log.
up_rc=0
docker compose up -d || up_rc=$?

# `docker compose up -d` exits 0 even when a `restart: "no"` one-shot exits non-zero — MEASURED
# on #235: keycloak-owner-org-sync printed "ERROR: could not ensure /orgs", exited 1, and this
# script still returned 0, so the install reported success over provisioning that had failed.
# Bind the install's exit status to the org one-shots' own.
#
# SCOPE — deliberately the two Owner-org one-shots, NOT every `restart: "no"` service, and in
# particular NOT keycloak-provision. MEASURED: docker-compose.yml bind-mounts
# ../../scripts/keycloak-provision-{rest,kcadm}.sh, which the release bundle
# (`git ls-files -- deploy/docker`, --strip-components=2) and scripts/download.sh do NOT ship;
# Docker materialises the missing sources as empty directories, the [ -f ] guards in
# scripts/keycloak-provision.sh both miss, and it exits 1 with "neither provision-rest.sh nor
# provision-kcadm.sh found". Gating on keycloak-provision would therefore fail EVERY bundle
# install on a pre-existing packaging defect that is not this fix's to make fatal. The two
# services gated here run scripts that live under deploy/docker/scripts/, i.e. inside every
# bundle. The packaging defect is tracked separately.
provision_failed=0
[ "${up_rc}" -eq 0 ] || provision_failed=1
for svc in keycloak-owner-org-resolve keycloak-owner-org-sync; do
  cid="$(docker compose ps -aq "${svc}" 2>/dev/null | head -n1)"
  # No container: the service never started (e.g. a dependency failed first). Not this gate's
  # call to make — say nothing rather than invent a verdict.
  [ -n "${cid}" ] || continue
  # Only `running`/`restarting` is worth waiting for. A container still `created` after
  # `up -d` has returned was never started — its dependency did not complete — so waiting on
  # it would just hang the install for the length of the timeout.
  state=""
  for _ in $(seq 1 "${ONESHOT_WAIT_ATTEMPTS:-60}"); do
    state="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || echo unknown)"
    [ "${state}" = "running" ] || [ "${state}" = "restarting" ] || break
    sleep 5
  done
  if [ "${state}" = "created" ]; then
    echo "ERROR: ${svc} never ran (a dependency did not complete) — provisioning is incomplete." >&2
    provision_failed=1
    continue
  fi
  if [ "${state}" != "exited" ]; then
    echo "ERROR: ${svc} did not finish (state=${state}) — provisioning is incomplete." >&2
    provision_failed=1
    continue
  fi
  code="$(docker inspect -f '{{.State.ExitCode}}' "${cid}" 2>/dev/null || echo 1)"
  if [ "${code}" -ne 0 ]; then
    echo "ERROR: ${svc} exited ${code} — provisioning did not complete." >&2
    docker compose logs --tail 20 "${svc}" >&2 || true
    provision_failed=1
  fi
done

# ── second pass: hand the collectors the Vault tokens vault-init just minted (chart#246) ──
#
# Compose resolves `env_file` when it PARSES the project — at the top of the `up` above, long
# before vault-init runs inside it. On a FRESH install runtime/vault.env, runtime/vault-api.env
# and runtime/vault-read.env do not exist yet, and every service that reads one declares it
# `required: false`, so the miss is SILENT: those containers are created with no VAULT_TOKEN at
# all and crash-loop from boot on
#   RuntimeError: VAULT_ADDR and VAULT_TOKEN must be set to build Vault clients
# (measured on a fresh clean room: restarts=9 within 60 s of the `up` returning). Re-creating
# them once the files exist is the whole fix, and it is only needed on the first install —
# after chart#246 vault-init keeps the tokens, so later `up`s already match.
#
# `--no-deps` is the load-bearing flag: without it Compose re-runs vault-init as a dependency
# of the services being recreated, and the files move again underneath the containers.
#
# The target list is filtered through `docker compose config --services`, which is
# profile-aware: naming a profile-gated service on a compose command line ACTIVATES its profile
# (measured), so a literal `collectors-healthcheck` here would switch on an opt-in workload for
# an operator who never asked for it. Only services that actually MOUNT a Vault env file are
# candidates — collectors-dispatcher/-mcp/-hitl/-identity-consumer mount none.
if [ -f runtime/vault.env ]; then
  active="$(docker compose config --services 2>/dev/null || true)"
  targets=""
  for svc in collectors-api collectors-worker collectors-healthcheck; do
    if printf '%s\n' "${active}" | grep -qx "${svc}"; then
      targets="${targets}${targets:+ }${svc}"
    fi
  done
  if [ -n "${targets}" ]; then
    echo "Re-creating the collectors with the Vault environment: ${targets}"
    # shellcheck disable=SC2086  # deliberate word-splitting: a list of service names
    docker compose up -d --no-deps --force-recreate ${targets}

    # Verify, do not assume. Compare the token ON DISK with the token the container was
    # actually created with. `docker inspect` is the right instrument and `docker exec
    # printenv` is the wrong one: exec fails on a restarting container, so a crash-loop from
    # any other cause would read as a Vault problem. Only fingerprints are ever printed.
    fp() { printf '%s' "${1:-}" | openssl dgst -sha256 | awk '{print substr($NF,1,12)}'; }
    bad=0
    for svc in ${targets}; do
      case "${svc}" in
        collectors-api)         file=runtime/vault-api.env ;;
        collectors-worker)      file=runtime/vault.env ;;
        collectors-healthcheck) file=runtime/vault-read.env ;;
        *) continue ;;
      esac
      cid="$(docker compose ps -q "${svc}" 2>/dev/null || true)"
      disk="$(grep -E '^VAULT_TOKEN=' "${file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
      cenv="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null \
                | grep -E '^VAULT_TOKEN=' | head -1 | cut -d= -f2- || true)"
      if [ -n "${cid}" ] && [ -n "${disk}" ] && [ "${disk}" = "${cenv}" ]; then
        echo "  ${svc}: VAULT_TOKEN matches ${file} ($(fp "${disk}"))"
      else
        echo "  ${svc}: VAULT_TOKEN on disk ($(fp "${disk}")) != in container ($(fp "${cenv}"))" >&2
        bad=1
      fi
    done
    if [ "${bad}" -ne 0 ]; then
      echo >&2
      echo "ERROR: the collectors did not pick up the Vault tokens on disk. They will crash-loop," >&2
      echo "       or fail on the first credential read with 'permission denied / invalid token'." >&2
      echo "       Retry with:" >&2
      echo "         docker compose up -d --no-deps --force-recreate ${targets}" >&2
      exit 1
    fi
  fi
fi

cat <<EOF

Stack is starting. Wait 3–6 minutes, then open https://${TETRIX_HOST}/

  docker compose ps
  docker compose logs -f keycloak daemon remote frontend collectors-api

Paste a real license token in the admin UI after sign-in (ops-signed; kid=k1).
Optional: set LICENSE_TOKEN in .env and recreate licensing.

Registry credentials expire within the hour (ADR-0024). Before a later
"docker compose pull" on this host, refresh with:

  ./scripts/registry-login.sh

Install a timer so you never have to think about it again:

  ./scripts/install-credential-timer.sh

If deskree/* pulls fail with "access denied" or "unauthorized", that credential
has expired — run registry-login.sh. (Pulling from Docker Hub instead? Set
TETRIX_IMAGE_ORIGIN= in .env and use your own docker login.)

Existing Logto volumes are unsupported — wipe with: docker compose down -v

EOF

if [ "${provision_failed}" -ne 0 ]; then
  echo "Install FAILED: one or more provisioning one-shots exited non-zero (see above)." >&2
  echo "The stack is up but is NOT correctly provisioned. Fix the cause and re-run this script —" >&2
  echo "'docker compose up -d' restarts an exited one-shot, so a fixed provisioner is re-run and" >&2
  echo "re-checked." >&2
  exit 1
fi
