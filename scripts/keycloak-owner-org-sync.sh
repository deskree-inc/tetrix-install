#!/usr/bin/env bash
# Join SPA Owner to /orgs/<daemon-org-uuid>/{admins,members}.
# The org id comes from ORG_ID_FILE, written by keycloak-owner-org-resolve, which has already
# proved it exists in the daemon's organizations table — ADOPT, NEVER MINT (#235).
# Helm twin: templates/keycloak-owner-org-sync-*.yaml (keycloak.owner.orgSync Job), same contract.
# This script only ADDS: it must never remove or reconcile a membership (ADR-0023 D2/D3 put that
# in tetrix-admin-api), so a broken install's stale /orgs/<old-uuid> groups are left untouched.
set -euo pipefail

KC="${KEYCLOAK_INTERNAL_URL:?}"
REALM="${KEYCLOAK_REALM:-tetrix}"
ADMIN="${KEYCLOAK_ADMIN_USERNAME:-admin}"
ADMIN_PW="${KEYCLOAK_ADMIN_PASSWORD:?}"
OWNER_EMAIL="${KEYCLOAK_OWNER_EMAIL:?}"
# #235: read the VALIDATED id, and only that. Taking KEYCLOAK_OWNER_ORG_ID straight out of .env
# is what let a uuid that survived `docker compose down -v` mint a group for an organization the
# new daemon had never issued.
ORG_ID_FILE="${ORG_ID_FILE:-/out/org_id}"
if [ -s "${ORG_ID_FILE}" ]; then
  OWNER_ORG_ID="$(tr -d '[:space:]' < "${ORG_ID_FILE}")"
else
  echo "ERROR: no validated org id at ${ORG_ID_FILE} — run keycloak-owner-org-resolve first:" >&2
  echo "         docker compose run --rm keycloak-owner-org-resolve" >&2
  echo "       Adopt, never mint (#235): refusing to create /orgs/<unvalidated>." >&2
  exit 1
fi
KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"

case "${OWNER_ORG_ID}" in
  *[!0-9a-fA-F-]*|"")
    echo "ERROR: KEYCLOAK_OWNER_ORG_ID must be a daemon organizations.id UUID (got '${OWNER_ORG_ID}')" >&2
    exit 1
    ;;
esac

echo "==> waiting for Keycloak admin API"
ready=0
for i in $(seq 1 60); do
  if "${KCADM}" config credentials \
        --server "${KC}" --realm master \
        --user "${ADMIN}" --password "${ADMIN_PW}" >/tmp/kcadm-login.log 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "${ready}" -ne 1 ]; then
  echo "ERROR: Keycloak admin login failed" >&2
  cat /tmp/kcadm-login.log >&2 || true
  exit 1
fi

ensure_child_group() {
  local parent_id="$1" child_name="$2"
  local child_id=""
  if "${KCADM}" get "groups/${parent_id}/children" -r "${REALM}" \
        >/tmp/kc-group-children.json 2>/tmp/kc-group-children.err; then
    local id="" name="" line val
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *'"id"'*)
          val="${line#*\"id\"}"; val="${val#*:}"; val="${val#*\"}"; id="${val%%\"*}"
          ;;
        *'"name"'*)
          val="${line#*\"name\"}"; val="${val#*:}"; val="${val#*\"}"; name="${val%%\"*}"
          if [ "$name" = "$child_name" ] && [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
          fi
          ;;
      esac
    done < /tmp/kc-group-children.json
  fi
  child_id="$("${KCADM}" create "groups/${parent_id}/children" -r "${REALM}" \
        -s "name=${child_name}" -i 2>/tmp/kc-group-create.log | tr -d '\r' || true)"
  if [ -z "${child_id}" ]; then
    echo "ERROR: failed to create group child ${child_name}" >&2
    cat /tmp/kc-group-create.log >&2 || true
    return 1
  fi
  printf '%s\n' "${child_id}"
}

ORGS_ID=""
if "${KCADM}" get groups -r "${REALM}" -q search=orgs \
      >/tmp/kc-groups-orgs.json 2>/tmp/kc-groups-orgs.err; then
  id=""; name=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"id"'*)
        val="${line#*\"id\"}"; val="${val#*:}"; val="${val#*\"}"; id="${val%%\"*}"
        ;;
      *'"name"'*)
        val="${line#*\"name\"}"; val="${val#*:}"; val="${val#*\"}"; name="${val%%\"*}"
        if [ "$name" = "orgs" ] && [ -n "$id" ]; then
          ORGS_ID="$id"
          break
        fi
        ;;
    esac
  done < /tmp/kc-groups-orgs.json
fi
if [ -z "${ORGS_ID}" ]; then
  ORGS_ID="$("${KCADM}" create groups -r "${REALM}" -s name=orgs -i \
        2>/tmp/kc-orgs-create.log | tr -d '\r' || true)"
fi
if [ -z "${ORGS_ID}" ]; then
  echo "ERROR: could not ensure /orgs" >&2
  exit 1
fi

echo "==> ensuring /orgs/${OWNER_ORG_ID}/{admins,members} + Owner ${OWNER_EMAIL}"
ORG_NODE_ID="$(ensure_child_group "${ORGS_ID}" "${OWNER_ORG_ID}")"
ensure_child_group "${ORG_NODE_ID}" "members" >/dev/null
ADMINS_ID="$(ensure_child_group "${ORG_NODE_ID}" "admins")"

OWNER_ID="$("${KCADM}" get users -r "${REALM}" -q "username=${OWNER_EMAIL}" \
      --fields id --format csv --noquotes 2>/dev/null | head -n1 | tr -d '\r' || true)"
if [ -z "${OWNER_ID}" ] || [ "${OWNER_ID}" = "id" ]; then
  echo "ERROR: Owner user ${OWNER_EMAIL} not found — run keycloak-provision first" >&2
  exit 1
fi
if "${KCADM}" update "users/${OWNER_ID}/groups/${ADMINS_ID}" -r "${REALM}" \
      >/tmp/kc-owner-group.log 2>&1; then
  echo "Owner ${OWNER_EMAIL} -> /orgs/${OWNER_ORG_ID}/admins"
else
  echo "ERROR: join Owner to admins failed" >&2
  cat /tmp/kc-owner-group.log >&2 || true
  exit 1
fi

echo "==> keycloak-owner-org-sync complete"
