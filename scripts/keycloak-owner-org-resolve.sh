#!/usr/bin/env bash
# Resolve AND VALIDATE the daemon organizations.id that the SPA Owner is joined to.
#
# ADOPT, NEVER MINT (helm-chart#235). KEYCLOAK_OWNER_ORG_ID used to live only in .env / a Helm
# value, and .env survives the `docker compose down -v` that setup.sh's own closing banner
# prescribes. On the reinstall the daemon issued a NEW organizations.id while the stale uuid was
# still handed to the provisioners; they created a Keycloak group for it, and the daemon then
# JIT-created a real tenant row named after that uuid. An id that matches no organizations row is
# therefore an INSTALL ERROR, never a group to create.
#
# BOUNDARY — do not widen this (tetrix-architecture Gate 0, verdict B on #235):
# this resolver is READ-ONLY, INSTALL-TIME, and `organizations`-ONLY. The moment it INSERTs or
# UPDATEs anything in aidb, or the read moves onto a request path, it breaks platform invariant 2
# ("AIDB is written only through the Tetrix SDK") and the change stops being architecture-legal.
# It also must never remove, disable or reconcile a Keycloak group or membership — that is
# tetrix-admin-api's (ADR-0023 D2/D3, ADR-0009 D5).
#
# TWINS: this file and the `resolve-org-id.sh` key of
# templates/keycloak-owner-org-sync-configmap.yaml are the SAME TEXT, byte for byte, modulo the
# ConfigMap's 4-space indent — scripts/assert-owner-org-adopt-or-fail.sh enforces it. They cannot
# be one file: .helmignore excludes deploy/ from the packaged chart, and the Compose release
# bundle is `git ls-files -- deploy/docker`, which excludes the chart-root scripts/.
#
# Runs on the postgres image because deskree/tetrix-iam carries no psql (measured:
# `docker run --rm --entrypoint sh deskree/tetrix-iam:latest -c 'command -v psql'` prints nothing),
# which is exactly why the sync one-shot used to take .env on trust.
set -euo pipefail

OUT="${ORG_ID_FILE:-/out/org_id}"
mkdir -p "$(dirname "${OUT}")"
# Never leave a previous run's answer behind: a failure must not look like a success to the
# sync step, which consumes this file and nothing else.
rm -f "${OUT}"

ORG_ID="${KEYCLOAK_OWNER_ORG_ID:-}"
AIDB_ORG="${AIDB_ORG:-default}"
PGHOST="${PGHOST:?}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:?}"
PGDATABASE="${PGDATABASE:-tetrixaidb}"
: "${PGPASSWORD:?}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
# Bounded, and overridable so the failure paths are provable in seconds in CI.
ATTEMPTS="${ORG_RESOLVE_ATTEMPTS:-120}"
INTERVAL="${ORG_RESOLVE_INTERVAL:-5}"

if [ -n "${ORG_ID}" ]; then
  case "${ORG_ID}" in
    *[!0-9a-fA-F-]*)
      echo "ERROR: KEYCLOAK_OWNER_ORG_ID must be a daemon organizations.id UUID (got '${ORG_ID}')" >&2
      exit 1
      ;;
  esac
fi

# NOTE: psql does not interpolate :'var' under -c/-tAc (it is sent literally -> syntax error near
# ":"). Feed the SQL on stdin so -v org_name=... / -v org_id=... + :'name' bind correctly. Pinned
# by scripts/assert-owner-org-sync-resolve.sh.
q_org_by_name() {
  printf '%s\n' "select id from public.organizations where name = :'org_name' limit 1" \
    | psql -v ON_ERROR_STOP=1 -v org_name="$1" -tA 2>/tmp/resolve-org.err | tr -d '[:space:]'
}
q_org_by_id() {
  printf '%s\n' "select id from public.organizations where id = :'org_id'" \
    | psql -v ON_ERROR_STOP=1 -v org_id="$1" -tA 2>/tmp/resolve-org.err | tr -d '[:space:]'
}

# Wait for the DAEMON's own organization first, so "row absent" can never be confused with "the
# daemon has not migrated yet" — that conflation is what makes a validation check flaky or useless.
echo "==> waiting for organizations.id where name = :'org_name' ('${AIDB_ORG}') on ${PGHOST}:${PGPORT}/${PGDATABASE}"
DEFAULT_ID=""
for _ in $(seq 1 "${ATTEMPTS}"); do
  DEFAULT_ID="$(q_org_by_name "${AIDB_ORG}" || true)"
  [ -n "${DEFAULT_ID}" ] && break
  sleep "${INTERVAL}"
done
if [ -z "${DEFAULT_ID}" ]; then
  echo "ERROR: timed out waiting for organizations row name='${AIDB_ORG}' (daemon migrate / default org)" >&2
  echo "       Nothing was created. Either the daemon never created its organization, or" >&2
  echo "       AIDB_ORG (Compose) / remote.aidb.org (Helm) does not name the organization you" >&2
  echo "       are installing into." >&2
  cat /tmp/resolve-org.err >&2 || true
  exit 1
fi

if [ -z "${ORG_ID}" ]; then
  # The supported path: resolve on every run, cache nothing, so a reinstall can never start
  # from an id the current daemon never issued.
  ORG_ID="${DEFAULT_ID}"
  echo "resolved AIDB_ORG=${AIDB_ORG} -> ${ORG_ID}"
else
  if [ "$(q_org_by_id "${ORG_ID}" || true)" != "${ORG_ID}" ]; then
    echo "ERROR: KEYCLOAK_OWNER_ORG_ID=${ORG_ID} matches no row in ${PGDATABASE}.organizations." >&2
    echo "       Adopt, never mint (#235): this installer will not create an organization for an" >&2
    echo "       id the daemon never issued — that is how a reinstall ends up with the Owner in" >&2
    echo "       two organizations and a tenant named after a UUID. Nothing was created." >&2
    echo "       The daemon's '${AIDB_ORG}' organization is ${DEFAULT_ID}." >&2
    echo "       Fix ONE of these, then re-run the install:" >&2
    echo "         Compose: set KEYCLOAK_OWNER_ORG_ID=${DEFAULT_ID} in deploy/docker/.env, or" >&2
    echo "                  clear it (KEYCLOAK_OWNER_ORG_ID=) and let the installer resolve it." >&2
    echo "         Helm   : --set keycloak.owner.orgId=${DEFAULT_ID}, or clear the pin with" >&2
    echo "                  --set keycloak.owner.orgId=\"\" and let the Job resolve it." >&2
    exit 1
  fi
  echo "validated explicit KEYCLOAK_OWNER_ORG_ID=${ORG_ID}"
fi

printf '%s\n' "${ORG_ID}" > "${OUT}"
echo "==> owner org id resolved and validated (${OUT})"
