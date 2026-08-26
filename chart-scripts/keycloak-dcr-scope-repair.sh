#!/bin/sh
# Lightweight DCR MCP scope repair (Keycloak #50807 / KC 26.1.4) PLUS ADR-0027
# access.token.lifespan stamp on the same UUID DCR client set.
# Re-attaches basic, res:mcp, graph:read, sessions:write, hitl:write defaults and the
# offline_access optional scope on anonymous public DCR clients (UUID clientIds).
# Also stamps access.token.lifespan when KEYCLOAK_DCR_ACCESS_TOKEN_LIFESPAN is a
# positive integer (default 3600) AND the client qualifies for the exception:
# public, with a redirect URI matching KEYCLOAK_DCR_ATL_REDIRECT_PREFIXES (Cursor's
# two callbacks by default). The lifespan population is deliberately NARROWER than
# the scope-repair population — see client_is_atl_eligible. Skips clients already OK.
#
# Why the WRITE scopes are defaults and not optional: a generic MCP client (Claude Code,
# Cursor) discovers this resource via RFC 9728 and requests what the server advertises —
# and the server advertises only graph:read, so a write scope offered as *optional* is
# never requested and every MCP write tool 403s ("insufficient scope: save_session
# requires sessions:write"). Verified both ways on a live stack: optional → 403, default →
# works. The privilege stays user-bounded regardless: these are authorization-code clients,
# so a real user authenticates, and the MCP server still enforces org membership plus the
# per-tool scope check (ADR-0057 §3). Once the server advertises the full set in its PRM,
# these can move back to optional.
# Used by the optional keycloak.provision.dcrScopeRepair CronJob and safe to run
# repeatedly. Requires: curl, jq, sh.
set -eu

KC="${KEYCLOAK_INTERNAL_URL:?}"
REALM="${KEYCLOAK_REALM:-tetrix}"
ADMIN="${KEYCLOAK_ADMIN_USERNAME:-admin}"
ADMIN_PW="${KEYCLOAK_ADMIN_PASSWORD:?}"
DCR_ACCESS_TOKEN_LIFESPAN="${KEYCLOAK_DCR_ACCESS_TOKEN_LIFESPAN:-3600}"
# Space-separated redirect-URI prefixes that qualify a client for the ADR-0027 lifespan
# exception. Cursor's two callbacks by default; empty disables the stamp entirely.
DCR_ATL_REDIRECT_PREFIXES="${KEYCLOAK_DCR_ATL_REDIRECT_PREFIXES:-cursor:// https://www.cursor.com/}"
# ADR-0027 D3 ceiling for the stamped value (see client_needs_atl).
DCR_ACCESS_TOKEN_LIFESPAN_MAX="${KEYCLOAK_DCR_ACCESS_TOKEN_LIFESPAN_MAX:-7200}"

ADMIN_BASE="${KC}/admin"
REALM_BASE="${ADMIN_BASE}/realms/${REALM}"
TOKEN=""

http() {
  _method="$1"
  shift
  _path="$1"
  shift
  case "${_path}" in
    /admin/*) _url="${KC}${_path}" ;;
    /*) _url="${ADMIN_BASE}${_path}" ;;
    *) _url="${REALM_BASE}/${_path}" ;;
  esac
  HTTP_CODE="$(curl -sS -o /tmp/kc-body -w '%{http_code}' \
    -X "${_method}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" \
    "${_url}" 2>/dev/null || echo "000")"
}

obtain_token() {
  curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=admin-cli&username=${ADMIN}&password=${ADMIN_PW}" \
    -o /tmp/kc-token.json 2>/dev/null || return 1
  TOKEN="$(jq -r '.access_token // empty' /tmp/kc-token.json)"
  [ -n "${TOKEN}" ]
}

client_scope_id() {
  jq -r --arg n "$1" '.[] | select(.name==$n) | .id' /tmp/kc-scopes.json | head -n1
}

ensure_client_default_scope() {
  _uuid="$1"
  _scope="$2"
  _sid="$(client_scope_id "${_scope}")"
  [ -n "${_sid}" ] || return 0
  http DELETE "clients/${_uuid}/optional-client-scopes/${_sid}" || true
  http PUT "clients/${_uuid}/default-client-scopes/${_sid}" -d '' \
    || http POST "clients/${_uuid}/default-client-scopes/${_sid}" -d '' || true
}

ensure_client_optional_scope() {
  _uuid="$1"
  _scope="$2"
  _sid="$(client_scope_id "${_scope}")"
  [ -n "${_sid}" ] || return 0
  http PUT "clients/${_uuid}/optional-client-scopes/${_sid}" -d '' \
    || http POST "clients/${_uuid}/optional-client-scopes/${_sid}" -d '' || true
}

remove_client_default_scope() {
  _uuid="$1"
  _scope="$2"
  _sid="$(client_scope_id "${_scope}")"
  [ -n "${_sid}" ] || return 0
  http DELETE "clients/${_uuid}/default-client-scopes/${_sid}" || true
}

client_has_mcp_defaults() {
  _uuid="$1"
  http GET "clients/${_uuid}/default-client-scopes" || return 1
  [ "${HTTP_CODE}" = "200" ] || return 1
  grep -q graph:read /tmp/kc-body && grep -q res:mcp /tmp/kc-body || return 1
  # Require a WRITE scope only when the realm actually has it. Both scopes are created by
  # provisioning now (hitl:write since chart 0.7.129 / #189), but the guard stays: a realm
  # that has not been re-provisioned yet still lacks it, and ensure_client_default_scope
  # no-ops for a scope with no id — so requiring it unconditionally would make this check
  # never pass and every DCR client would be "repaired" on every tick forever (~6 needless
  # round trips each, and a misleading repaired=N). client_scope_id is a pure jq read of the
  # realm scope list, no HTTP, so it cannot clobber /tmp/kc-body mid-check.
  for _want in sessions:write hitl:write; do
    if [ -n "$(client_scope_id "${_want}")" ]; then
      grep -q "${_want}" /tmp/kc-body || return 1
    fi
  done
}

# ADR-0027 D1 scopes the lifespan exception to the clients that actually need it. The scope
# repair above deliberately walks a WIDER set (confidential claude.ai included — see the jq
# filter below), because a missing MCP scope is a functional break for every vendor. A longer
# bearer is not: it is a security exception, so it gets the narrower population.
#   · public client only — the exception is for apps that keep the token on disk
#   · a redirect URI matching DCR_ATL_REDIRECT_PREFIXES — Cursor is the client with the
#     refresh bug; Claude Code measured 3 refreshes / 0 errors on the realm's 300s
# Empty prefixes ⇒ nothing qualifies, so the exception cannot widen by being forgotten.
# Mirrors DcrDefaultScopesPolicy.isLifespanEligible in tetrix-iam — keep the two in step.
client_is_atl_eligible() {
  _row="$1"
  [ "$(echo "${_row}" | jq -r '.publicClient')" = "true" ] || return 1
  [ -n "${DCR_ATL_REDIRECT_PREFIXES}" ] || return 1
  for _prefix in ${DCR_ATL_REDIRECT_PREFIXES}; do
    if echo "${_row}" | jq -e --arg p "${_prefix}" \
      '(.redirectUris // []) | any(startswith($p))' >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

client_needs_atl() {
  _uuid="$1"
  case "${DCR_ACCESS_TOKEN_LIFESPAN}" in
    ""|0) return 1 ;;
  esac
  echo "${DCR_ACCESS_TOKEN_LIFESPAN}" | grep -Eq '^[0-9]+$' || return 1
  # ADR-0027 D3 ceiling. Refuse rather than clamp: a values typo (36000, 604800) must not
  # silently issue a week-long MCP bearer, and "keep the realm 300s" is the safe failure.
  if [ "${DCR_ACCESS_TOKEN_LIFESPAN}" -gt "${DCR_ACCESS_TOKEN_LIFESPAN_MAX}" ]; then
    echo "WARN: refusing KEYCLOAK_DCR_ACCESS_TOKEN_LIFESPAN=${DCR_ACCESS_TOKEN_LIFESPAN} — above the" \
      "ADR-0027 ceiling of ${DCR_ACCESS_TOKEN_LIFESPAN_MAX}s; clients keep the realm lifespan" >&2
    return 1
  fi
  http GET "clients/${_uuid}" || return 1
  [ "${HTTP_CODE}" = "200" ] || return 1
  _cur="$(jq -r '.attributes["access.token.lifespan"] // empty' /tmp/kc-body)"
  [ "${_cur}" = "${DCR_ACCESS_TOKEN_LIFESPAN}" ] && return 1
  cp /tmp/kc-body /tmp/kc-client-atl-src.json
  return 0
}

# Returns 0 only when Keycloak accepted the write. The previous version PUT the FULL
# ClientRepresentation with `|| true` and the caller counted a stamp unconditionally — but
# http() can never fail (curl's failure is swallowed into HTTP_CODE=000), so `atl_repaired=N`
# was a count of attempts, not of stamps, and an operator reading it would believe clients
# were on 3600 while they sat on realm 300.
#
# The payload is now attributes-ONLY. Keycloak merges a partial ClientRepresentation, so a
# field we do not send cannot be changed: this write is structurally incapable of rotating a
# confidential client's secret or dropping its redirectUris, which a full-representation
# round-trip could do on a shape we did not anticipate.
ensure_client_atl() {
  _uuid="$1"
  jq --arg atl "${DCR_ACCESS_TOKEN_LIFESPAN}" \
    '{attributes: ((.attributes // {}) + {"access.token.lifespan": $atl})}' \
    /tmp/kc-client-atl-src.json > /tmp/kc-client-atl.json
  http PUT "clients/${_uuid}" --data-binary @/tmp/kc-client-atl.json
  case "${HTTP_CODE}" in
    200|204) return 0 ;;
  esac
  echo "WARN: access.token.lifespan PUT rejected for client ${_uuid} http=${HTTP_CODE}" >&2
  head -c 500 /tmp/kc-body >&2 2>/dev/null || true
  echo >&2
  return 1
}

obtain_token || exit 1
http GET client-scopes || exit 1
cp /tmp/kc-body /tmp/kc-scopes.json

repaired=0
atl_repaired=0
atl_failed=0
http GET "clients?max=500" || exit 0
# CONFIDENTIAL DCR clients must be included. claude.ai registers with
# token_endpoint_auth_method=client_secret_post, so its client is confidential; a
# .publicClient==true filter skipped every one of them forever while Cursor (public) was
# healed within one tick. The remaining guards still bound this to DCR-registered
# interactive clients: UUID-shaped clientId, standard flow on, no service account.
jq -c '.[] | select(.standardFlowEnabled==true and (.serviceAccountsEnabled|not))
  | select(.clientId|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
  | select(.clientId as $c | ["tetrix-frontend","tetrix-admin-api","tetrix-account-verify","wellclaudecode000001"] | index($c) | not)' \
  /tmp/kc-body > /tmp/kc-dcr-rows.jsonl
# Read from a FILE, not a pipe: `... | while read` runs the loop body in a subshell, so every
# `repaired=$((repaired + 1))` was lost and the summary always printed repaired=0 even when it
# had just logged repairs. A redirect keeps the loop in this shell.
while read -r row; do
  [ -n "${row}" ] || continue
  _uuid="$(echo "${row}" | jq -r '.id')"
  _cid="$(echo "${row}" | jq -r '.clientId')"
  if ! client_has_mcp_defaults "${_uuid}"; then
    ensure_client_default_scope "${_uuid}" basic
    ensure_client_default_scope "${_uuid}" res:mcp
    ensure_client_default_scope "${_uuid}" graph:read
    ensure_client_default_scope "${_uuid}" sessions:write
    ensure_client_default_scope "${_uuid}" hitl:write
    ensure_client_optional_scope "${_uuid}" offline_access
    echo "DCR MCP scopes repaired client=${_cid}"
    repaired=$((repaired + 1))
  fi
  if client_is_atl_eligible "${row}" && client_needs_atl "${_uuid}"; then
    if ensure_client_atl "${_uuid}"; then
      echo "DCR access.token.lifespan=${DCR_ACCESS_TOKEN_LIFESPAN} stamped client=${_cid}"
      atl_repaired=$((atl_repaired + 1))
    else
      echo "DCR access.token.lifespan NOT stamped client=${_cid} (see WARN above)"
      atl_failed=$((atl_failed + 1))
    fi
  fi
done < /tmp/kc-dcr-rows.jsonl
echo "dcr-scope-repair done repaired=${repaired} atl_repaired=${atl_repaired} atl_failed=${atl_failed}"
