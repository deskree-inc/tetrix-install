#!/usr/bin/env bash
set -euo pipefail
KC="${KEYCLOAK_INTERNAL_URL:?}"
REALM="${KEYCLOAK_REALM:-tetrix}"
ADMIN="${KEYCLOAK_ADMIN_USERNAME:-admin}"
ADMIN_PW="${KEYCLOAK_ADMIN_PASSWORD:?}"
TRUSTED_HOSTS="${KEYCLOAK_TRUSTED_HOSTS:-}"
# sessions:write is in the DEFAULT allowlist because the MCP write tools (save_session,
# report_agent_usage) are unusable without it and a generic MCP client cannot request a
# scope the resource does not advertise — see keycloak-dcr-scope-repair.sh for the full
# reasoning. hitl:write is here for the same reason (the four HITL mutation tools), and this
# script now creates that client scope below so the allowlist entry is not a no-op (#189).
ALLOWED_DCR_SCOPES="${KEYCLOAK_ALLOWED_DCR_SCOPES:-res:mcp graph:read sessions:write hitl:write basic profile email offline_access}"
ISSUER="${KEYCLOAK_ISSUER:?}"
AUD_DAEMON="${KEYCLOAK_AUDIENCE_DAEMON:?}"
AUD_API="${KEYCLOAK_AUDIENCE_API:?}"
AUD_MCP="${KEYCLOAK_AUDIENCE_MCP:?}"
PUBLIC_URL="${TETRIX_PUBLIC_URL:?}"
SPA_BASE="${TETRIX_SPA_BASE_PATH:-}"
CLIENT_ID="${KEYCLOAK_CLIENT_ID:-tetrix-frontend}"
KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"

if [ ! -x "${KCADM}" ]; then
  echo "ERROR: kcadm not found at ${KCADM} (tetrix-iam image required)" >&2
  exit 1
fi

echo "==> waiting for Keycloak admin API + realm ${REALM} at ${KC}"
ready=0
for i in $(seq 1 90); do
  if "${KCADM}" config credentials \
        --server "${KC}" --realm master \
        --user "${ADMIN}" --password "${ADMIN_PW}" >/tmp/kcadm-login.log 2>&1 \
     && "${KCADM}" get "realms/${REALM}" >/tmp/realm.json 2>/tmp/kcadm-realm.log; then
    ready=1
    break
  fi
  sleep 5
done
if [ "${ready}" -ne 1 ]; then
  echo "ERROR: Keycloak realm discovery not ready" >&2
  echo "---- kcadm login (last) ----" >&2
  cat /tmp/kcadm-login.log >&2 || true
  echo "---- kcadm get realm (last) ----" >&2
  cat /tmp/kcadm-realm.log >&2 || true
  exit 1
fi
echo "realm ready (issuer desired: ${ISSUER})"

echo "==> desired-state (scaffold markers — apply via Admin REST / kcadm)"
echo "    issuer=${ISSUER}"
echo "    audiences: res:daemon=${AUD_DAEMON} res:api=${AUD_API} res:mcp=${AUD_MCP}"
echo "    spa_client=${CLIENT_ID} redirects+=${PUBLIC_URL}${SPA_BASE}/* ${PUBLIC_URL}${SPA_BASE}/callback"
echo "    dcr.trusted_hosts=${TRUSTED_HOSTS}"
echo "    dcr.allowed_scopes=${ALLOWED_DCR_SCOPES}"

# ------------------------------------------------------------------
# Session lifetimes + refresh rotation (architecture ADR-0017)
# (TEMPORARY — remove when deskree-inc/tetrix-iam#22 ships ALL FIVE values)
# ------------------------------------------------------------------
# Kept in lockstep with keycloak-provision-rest.sh: the two scripts are
# desired-state equivalents, so a fix landing in only one of them silently
# depends on which path a deploy chose (fast=true/false).
#
# ADR-0017 target: 48h sliding idle, 7d absolute, refresh rotation on, 5-minute
# access tokens. Enforcement model (D2): FLOOR the two windows (raise only,
# never shorten an operator's longer value), SET the access-token lifespan, and
# FORCE the booleans — a boolean has no "longer", and leaving rotation
# operator-controlled silently disables it.
# Best-effort — never abort provisioning over a session setting.
ATL_DESIRED="${ACCESS_TOKEN_LIFESPAN:-300}"
IDLE_MIN="${SSO_SESSION_IDLE_MIN:-172800}"   # 48h — ADR-0017 D1
MAX_MIN="${SSO_SESSION_MAX_MIN:-604800}"     # 7d  — ADR-0017 D1
case "${ATL_DESIRED}" in ''|*[!0-9]*) echo "WARN: ACCESS_TOKEN_LIFESPAN='${ATL_DESIRED}' is not a number — using 300" >&2; ATL_DESIRED=300 ;; esac
case "${IDLE_MIN}" in ''|*[!0-9]*) echo "WARN: SSO_SESSION_IDLE_MIN='${IDLE_MIN}' is not a number — using 172800" >&2; IDLE_MIN=172800 ;; esac
case "${MAX_MIN}" in ''|*[!0-9]*) echo "WARN: SSO_SESSION_MAX_MIN='${MAX_MIN}' is not a number — using 604800" >&2; MAX_MIN=604800 ;; esac

CUR_IDLE="$(jq -r '.ssoSessionIdleTimeout // empty' /tmp/realm.json 2>/dev/null || echo "")"
CUR_MAX="$(jq -r '.ssoSessionMaxLifespan // empty' /tmp/realm.json 2>/dev/null || echo "")"
IDLE_TARGET="${CUR_IDLE}"
case "${CUR_IDLE}" in
  ''|*[!0-9]*) IDLE_TARGET="${IDLE_MIN}" ;;
  *) [ "${CUR_IDLE}" -lt "${IDLE_MIN}" ] && IDLE_TARGET="${IDLE_MIN}" ;;
esac
MAX_TARGET="${CUR_MAX}"
case "${CUR_MAX}" in
  ''|*[!0-9]*) MAX_TARGET="${MAX_MIN}" ;;
  *) [ "${CUR_MAX}" -lt "${MAX_MIN}" ] && MAX_TARGET="${MAX_MIN}" ;;
esac
# An absolute cap below the idle window ends the session before the idle window
# ever elapses — "48h idle" would be a lie. Never let that stand.
if [ "${MAX_TARGET}" -lt "${IDLE_TARGET}" ]; then
  echo "WARN: ssoSessionMaxLifespan (${MAX_TARGET}s) is below ssoSessionIdleTimeout (${IDLE_TARGET}s) — raising the cap to match (ADR-0017 D1)" >&2
  MAX_TARGET="${IDLE_TARGET}"
fi
if "${KCADM}" update "realms/${REALM}" \
      -s "accessTokenLifespan=${ATL_DESIRED}" \
      -s "ssoSessionIdleTimeout=${IDLE_TARGET}" \
      -s "ssoSessionMaxLifespan=${MAX_TARGET}" \
      -s "revokeRefreshToken=true" \
      -s "refreshTokenMaxReuse=0" >/tmp/kcadm-lifespan.log 2>&1; then
  echo "realm session settings -> accessTokenLifespan=${ATL_DESIRED}s idle=${IDLE_TARGET}s max=${MAX_TARGET}s rotation=on reuse=0"
else
  echo "WARN: could not set realm session settings — sessions may expire early; see tetrix-iam#22" >&2
  cat /tmp/kcadm-lifespan.log >&2 || true
fi

# ADR-0017 D1: a client-level cap silently falsifies the realm window. ASSERT
# only — warn, never rewrite a client someone deliberately tuned.
#
# access.token.lifespan rides the same loop but is NOT session death — a shorter
# access token just refreshes more often. It still warns because the SPA renews
# inside a fixed 60s skew (RENEW_SKEW_S), so a client ATL at or under that skew
# renews on every call, and with rotation on that churn can race the
# single-flight renew into a reuse collision that ends the whole session
# (review follow-up, 2026-07-28).
SPA_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-tetrix-frontend}"
FE_RENEW_SKEW_S=60
if "${KCADM}" get clients -r "${REALM}" -q "clientId=${SPA_CLIENT_ID}" >/tmp/kcadm-spa-client.json 2>/dev/null; then
  for attr in client.session.idle.timeout client.session.max.lifespan access.token.lifespan; do
    VAL="$(jq -r --arg a "${attr}" '.[0].attributes[$a] // empty' /tmp/kcadm-spa-client.json 2>/dev/null || echo "")"
    case "${VAL}" in
      ''|'0') : ;;
      *[!0-9]*) echo "WARN: ${SPA_CLIENT_ID} ${attr}='${VAL}' is not numeric — cannot verify against the realm window (ADR-0017 D1)" >&2 ;;
      *)
        LIMIT="${IDLE_TARGET}"
        [ "${attr}" = "client.session.max.lifespan" ] && LIMIT="${MAX_TARGET}"
        [ "${attr}" = "access.token.lifespan" ] && LIMIT="${ATL_DESIRED}"
        if [ "${VAL}" -lt "${LIMIT}" ]; then
          if [ "${attr}" = "access.token.lifespan" ]; then
            echo "WARN: ${SPA_CLIENT_ID} sets ${attr}=${VAL}s, SHORTER than the realm's ${LIMIT}s — the SPA refreshes more often than intended (ADR-0017 D1). Clear it (unset/0) or raise it." >&2
            if [ "${VAL}" -le "${FE_RENEW_SKEW_S}" ]; then
              echo "WARN: ${SPA_CLIENT_ID} ${attr}=${VAL}s is at or under the SPA's ${FE_RENEW_SKEW_S}s renew skew — every call triggers a renew, and the rotation churn can collide with itself and end the session (ADR-0017 D1/D3b)." >&2
            fi
          else
            echo "WARN: ${SPA_CLIENT_ID} sets ${attr}=${VAL}s, SHORTER than the realm's ${LIMIT}s — SPA sessions end early and the realm setting is misleading (ADR-0017 D1). Clear it (unset/0) or raise it." >&2
          fi
        fi
        ;;
    esac
  done
else
  echo "WARN: could not read client ${SPA_CLIENT_ID} for the session-override check — skipping" >&2
fi

# ------------------------------------------------------------------
# Anonymous DCR policies (best-effort; never abort the rest of provision)
# ------------------------------------------------------------------
if "${KCADM}" get components -r "${REALM}" \
      -q type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy \
      >/tmp/dcr-components.json 2>/tmp/kcadm-components.log; then
  dcr_component_id() {
    local provider="$1" subtype="$2"
    local id="" pid="" st="" line val
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *'"id"'*)
          val="${line#*\"id\"}"; val="${val#*:}"; val="${val#*\"}"; id="${val%%\"*}"
          ;;
        *'"providerId"'*)
          val="${line#*\"providerId\"}"; val="${val#*:}"; val="${val#*\"}"; pid="${val%%\"*}"
          ;;
        *'"subType"'*)
          val="${line#*\"subType\"}"; val="${val#*:}"; val="${val#*\"}"; st="${val%%\"*}"
          ;;
        *'}'*)
          if [ "$pid" = "$provider" ] && [ "$st" = "$subtype" ] && [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
          fi
          id=""; pid=""; st=""
          ;;
      esac
    done < /tmp/dcr-components.json
    return 1
  }

  TH_ID="$(dcr_component_id trusted-hosts anonymous || true)"
  if [ -n "${TH_ID}" ] && [ -n "${TRUSTED_HOSTS}" ]; then
    TH_ARGS=()
    for h in ${TRUSTED_HOSTS}; do
      TH_ARGS+=(-s "config.trusted-hosts+=${h}")
    done
    if "${KCADM}" update "components/${TH_ID}" -r "${REALM}" \
          -s 'config.trusted-hosts=[]' \
          "${TH_ARGS[@]}" \
          -s 'config.host-sending-registration-request-must-match=["false"]' \
          -s 'config.client-uris-must-match=["true"]' \
          >/tmp/kcadm-th.log 2>&1; then
      echo "PUT trusted-hosts -> ok (${TH_ID})"
    else
      echo "WARN: trusted-hosts update failed" >&2
      cat /tmp/kcadm-th.log >&2 || true
    fi
  else
    echo "WARN: skipping trusted-hosts (id='${TH_ID}' hosts='${TRUSTED_HOSTS}')"
  fi

  SC_ID="$(dcr_component_id allowed-client-templates anonymous || true)"
  if [ -n "${SC_ID}" ] && [ -n "${ALLOWED_DCR_SCOPES}" ]; then
    SC_ARGS=()
    for s in ${ALLOWED_DCR_SCOPES}; do
      SC_ARGS+=(-s "config.allowed-client-scopes+=${s}")
    done
    if "${KCADM}" update "components/${SC_ID}" -r "${REALM}" \
          -s 'config.allowed-client-scopes=[]' \
          "${SC_ARGS[@]}" \
          -s 'config.allow-default-scopes=["true"]' \
          >/tmp/kcadm-sc.log 2>&1; then
      echo "PUT allowed-client-scopes -> ok (${SC_ID})"
    else
      echo "WARN: allowed-client-scopes update failed" >&2
      cat /tmp/kcadm-sc.log >&2 || true
    fi
  else
    echo "WARN: skipping allowed-client-scopes (id='${SC_ID}')"
  fi
else
  echo "WARN: could not list DCR policy components — skipping DCR PUT" >&2
  cat /tmp/kcadm-components.log >&2 || true
fi

# ------------------------------------------------------------------
# Audience mappers on res:daemon / res:api / res:mcp
# ------------------------------------------------------------------
# Prefer csv — pretty JSON field order / blank lines break line-pairing parsers
# in the tetrix-iam image (no jq/python).
client_scope_id() {
  local want="$1" id name
  if ! "${KCADM}" get client-scopes -r "${REALM}" --fields id,name \
        --format csv --noquotes \
        >/tmp/kc-client-scopes.csv 2>/tmp/kc-client-scopes.err; then
    return 1
  fi
  while IFS=, read -r id name || [ -n "$id" ]; do
    [ "$id" = "id" ] && continue
    if [ "$name" = "$want" ] && [ -n "$id" ]; then
      printf '%s\n' "$id"
      return 0
    fi
  done < /tmp/kc-client-scopes.csv
  return 1
}

# ------------------------------------------------------------------
# Standard OIDC client scopes (email / profile)
# ------------------------------------------------------------------
# tetrix-iam realm import ships custom scopes (basic, res:*, collector:*)
# but omits Keycloak's built-in email/profile client scopes. The SPA
# requests KEYCLOAK_SCOPES=openid email profile via /api/config; without
# these scopes Keycloak returns invalid_scope at /authorize.
# openid is always accepted by Keycloak (not a client-scope assignment).
# Idempotent create + protocol mappers (no jq/python in tetrix-iam image).
# ------------------------------------------------------------------
ensure_oidc_builtin_scope() {
  local scope_name="$1"
  local sid mapper_name protocol_mapper
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -z "${sid}" ]; then
    printf '%s\n' \
      '{' \
      "  \"name\": \"${scope_name}\"," \
      "  \"description\": \"OpenID Connect built-in scope: ${scope_name}\"," \
      '  "protocol": "openid-connect",' \
      '  "attributes": {' \
      '    "include.in.token.scope": "true",' \
      '    "display.on.consent.screen": "true"' \
      '  }' \
      '}' >/tmp/kc-oidc-scope.json
    sid="$("${KCADM}" create client-scopes -r "${REALM}" \
          -f /tmp/kc-oidc-scope.json -i 2>/tmp/kc-oidc-scope-create.log | tr -d '\r' || true)"
    if [ -z "${sid}" ]; then
      echo "WARN: could not create client scope ${scope_name}" >&2
      cat /tmp/kc-oidc-scope-create.log >&2 || true
      return 0
    fi
    echo "CREATE client-scope ${scope_name} id=${sid}"
  else
    echo "client-scope ${scope_name} already exists id=${sid}"
  fi

  write_usermodel_mapper_json() {
    local out="$1" mname="$2" uattr="$3" claim="$4" jtype="${5:-String}"
    printf '%s\n' \
      '{' \
      "  \"name\": \"${mname}\"," \
      '  "protocol": "openid-connect",' \
      '  "protocolMapper": "oidc-usermodel-property-mapper",' \
      '  "consentRequired": false,' \
      '  "config": {' \
      "    \"user.attribute\": \"${uattr}\"," \
      "    \"claim.name\": \"${claim}\"," \
      "    \"jsonType.label\": \"${jtype}\"," \
      '    "id.token.claim": "true",' \
      '    "access.token.claim": "true",' \
      '    "userinfo.token.claim": "true"' \
      '  }' \
      '}' >"${out}"
  }

  ensure_scope_mapper() {
    local scope_id="$1" mname="$2" body_file="$3"
    if "${KCADM}" get "client-scopes/${scope_id}/protocol-mappers/models" -r "${REALM}" \
          >/tmp/kc-oidc-mappers.json 2>/tmp/kc-oidc-mappers.err \
       && grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${mname}\"" /tmp/kc-oidc-mappers.json 2>/dev/null; then
      return 0
    fi
    if "${KCADM}" create "client-scopes/${scope_id}/protocol-mappers/models" -r "${REALM}" \
          -f "${body_file}" >/tmp/kc-oidc-mapper-create.log 2>&1; then
      echo "  mapper += ${mname}"
    else
      echo "WARN: could not create mapper ${mname} on ${scope_name}" >&2
      cat /tmp/kc-oidc-mapper-create.log >&2 || true
    fi
  }

  case "${scope_name}" in
    email)
      write_usermodel_mapper_json /tmp/kc-oidc-mapper.json email email email String
      ensure_scope_mapper "${sid}" email /tmp/kc-oidc-mapper.json
      write_usermodel_mapper_json /tmp/kc-oidc-mapper.json "email verified" emailVerified email_verified boolean
      ensure_scope_mapper "${sid}" "email verified" /tmp/kc-oidc-mapper.json
      ;;
    profile)
      write_usermodel_mapper_json /tmp/kc-oidc-mapper.json username username preferred_username String
      ensure_scope_mapper "${sid}" username /tmp/kc-oidc-mapper.json
      write_usermodel_mapper_json /tmp/kc-oidc-mapper.json "given name" firstName given_name String
      ensure_scope_mapper "${sid}" "given name" /tmp/kc-oidc-mapper.json
      write_usermodel_mapper_json /tmp/kc-oidc-mapper.json "family name" lastName family_name String
      ensure_scope_mapper "${sid}" "family name" /tmp/kc-oidc-mapper.json
      printf '%s\n' \
        '{' \
        '  "name": "full name",' \
        '  "protocol": "openid-connect",' \
        '  "protocolMapper": "oidc-full-name-mapper",' \
        '  "consentRequired": false,' \
        '  "config": {' \
        '    "id.token.claim": "true",' \
        '    "access.token.claim": "true",' \
        '    "userinfo.token.claim": "true"' \
        '  }' \
        '}' >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${sid}" "full name" /tmp/kc-oidc-mapper.json
      ;;
  esac
}

echo "==> ensuring OIDC built-in client scopes (email profile)"
ensure_oidc_builtin_scope email
ensure_oidc_builtin_scope profile

# ------------------------------------------------------------------
# MCP write client scopes (hitl:write)
# ------------------------------------------------------------------
# The four MCP HITL mutation tools (answer/route/dismiss/decline_hitl_question) demand
# scope hitl:write server-side (collectors mcp_service/app/auth.py::TOOL_SCOPES), but the
# scope shipped in neither realm import — measured absent on a hosted
# realm. With no such scope in the realm no token can ever carry it, so all four
# tools failed authorization for every caller, and every hitl:write line in the DCR
# attachment paths was a silent no-op.
#
# Created here rather than in the realm import for the reason the collectors M2M scope is:
# Keycloak's --import-realm does NOT re-import into a realm that already exists, so an
# upgraded install would never receive a newly added scope. Provisioning has to patch the
# live realm. WARN-and-continue on failure (like ensure_oidc_builtin_scope) — failing this
# post-install/post-upgrade hook would abort the release and skip every later step.
#
# Deliberately NO audience mapper: hitl:write mirrors sessions:write, which carries none.
# aud=<mcp> arrives via res:mcp / graph:read (see patch_scope_audience below) and every MCP
# client that gets hitl:write also gets graph:read, so a second aud mapper would only
# duplicate the claim. Same reason it is not added to realm defaultDefaultClientScopes:
# the write scopes are attached per-DCR-client below, not realm-wide.
#
# printf-built JSON, no jq: the tetrix-iam image ships neither jq nor python.
# ------------------------------------------------------------------
ensure_mcp_write_scope() {
  local scope_name="$1" scope_desc="$2"
  local sid
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -n "${sid}" ]; then
    echo "client-scope ${scope_name} already exists id=${sid}"
    return 0
  fi
  echo "client-scope ${scope_name} absent from realm ${REALM} -- creating"
  printf '%s\n' \
    '{' \
    "  \"name\": \"${scope_name}\"," \
    "  \"description\": \"${scope_desc}\"," \
    '  "protocol": "openid-connect",' \
    '  "attributes": {' \
    '    "include.in.token.scope": "true",' \
    '    "display.on.consent.screen": "false"' \
    '  }' \
    '}' >/tmp/kcadm-mcp-write-scope.json
  sid="$("${KCADM}" create client-scopes -r "${REALM}" \
        -f /tmp/kcadm-mcp-write-scope.json -i 2>/tmp/kcadm-mcp-write-scope.log | tr -d '\r' || true)"
  if [ -z "${sid}" ]; then
    echo "WARN: could not create client scope ${scope_name}" >&2
    cat /tmp/kcadm-mcp-write-scope.log >&2 || true
    return 0
  fi
  echo "CREATE client-scope ${scope_name} id=${sid}"
}

echo "==> ensuring MCP write client scopes (hitl:write)"
ensure_mcp_write_scope hitl:write \
  "Mutate human-in-the-loop questions over MCP: answer/route/dismiss/decline (collectors ADR-0057). User-bounded; the MCP server still enforces org membership and the per-tool scope check."

# ------------------------------------------------------------------
# Realm defaultDefaultClientScopes: basic + res:mcp + graph:read
# Cursor / IDE MCP DCR omits RFC 7591 `scope`, then authorizes with PRM
# graph:read. Without these realm defaults Keycloak returns
# invalid_scope / Invalid scopes: graph:read at the authorize redirect.
# Idempotent; seeded clients keep their explicit scope lists.
#
# `basic` is Keycloak 26+'s replacement for the old dedicated openid
# client-scope (carries `sub` + `auth_time`). Older docs sometimes still
# say "openid" — do not look for a client-scope named openid.
# ------------------------------------------------------------------
echo "==> ensuring realm defaultDefaultClientScopes (basic res:mcp graph:read)"
ensure_realm_default_scope() {
  local scope_name="$1"
  local sid
  if "${KCADM}" get "realms/${REALM}/default-default-client-scopes" \
        --format csv --fields name --noquotes \
        >/tmp/kc-realm-defaults.csv 2>/tmp/kc-realm-defaults.err \
     && grep -qx "${scope_name}" /tmp/kc-realm-defaults.csv; then
    echo "realm default-default-client-scopes already has ${scope_name}"
    return 0
  fi
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -z "${sid}" ]; then
    echo "WARN: client scope ${scope_name} not found — skip realm default" >&2
    return 0
  fi
  if "${KCADM}" update "realms/${REALM}/default-default-client-scopes/${sid}" \
        >/tmp/kc-realm-default-scope.log 2>&1; then
    echo "realm default-default-client-scopes += ${scope_name}"
  else
    echo "WARN: could not add realm default scope ${scope_name}" >&2
    cat /tmp/kc-realm-default-scope.log >&2 || true
  fi
}
ensure_realm_default_scope basic
ensure_realm_default_scope res:mcp
ensure_realm_default_scope graph:read

# ------------------------------------------------------------------
# DCR MCP scope repair (Keycloak #50807 / KC 26.1.4)
# ------------------------------------------------------------------
# Claude Code / cloud MCP connectors send RFC 7591 scope=offline_access at DCR.
# Keycloak then drops realm defaultDefaultClientScopes (res:mcp, graph:read), so
# authorize scope=graph:read offline_access fails with invalid_scope. Re-attach
# MCP defaults on anonymous DCR public clients (UUID clientIds only).
echo "==> repairing MCP scopes on anonymous DCR clients (graph:read res:mcp)"
ensure_client_default_scope() {
  local client_uuid="$1" scope_name="$2"
  local sid
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -z "${sid}" ]; then
    return 0
  fi
  "${KCADM}" delete "clients/${client_uuid}/optional-client-scopes/${sid}" -r "${REALM}" \
        >/tmp/kc-dcr-scope-del.log 2>&1 || true
  if "${KCADM}" update "clients/${client_uuid}/default-client-scopes/${sid}" -r "${REALM}" \
        >/tmp/kc-dcr-scope-add.log 2>&1 \
     || "${KCADM}" create "clients/${client_uuid}/default-client-scopes/${sid}" -r "${REALM}" \
        >/tmp/kc-dcr-scope-add.log 2>&1 \
     || grep -qiE 'already|Conflict|exists' /tmp/kc-dcr-scope-add.log 2>/dev/null; then
    :
  else
    echo "WARN: could not add default scope ${scope_name} to client ${client_uuid}" >&2
    cat /tmp/kc-dcr-scope-add.log >&2 || true
  fi
}
ensure_client_optional_scope() {
  local client_uuid="$1" scope_name="$2"
  local sid
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -z "${sid}" ]; then
    return 0
  fi
  if "${KCADM}" update "clients/${client_uuid}/optional-client-scopes/${sid}" -r "${REALM}" \
        >/tmp/kc-dcr-opt-add.log 2>&1 \
     || "${KCADM}" create "clients/${client_uuid}/optional-client-scopes/${sid}" -r "${REALM}" \
        >/tmp/kc-dcr-opt-add.log 2>&1 \
     || grep -qiE 'already|Conflict|exists' /tmp/kc-dcr-opt-add.log 2>/dev/null; then
    :
  else
    echo "WARN: could not add optional scope ${scope_name} to client ${client_uuid}" >&2
    cat /tmp/kc-dcr-opt-add.log >&2 || true
  fi
}
remove_client_default_scope() {
  local client_uuid="$1" scope_name="$2"
  local sid
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -z "${sid}" ]; then
    return 0
  fi
  "${KCADM}" delete "clients/${client_uuid}/default-client-scopes/${sid}" -r "${REALM}" \
        >/tmp/kc-dcr-scope-rm.log 2>&1 || true
}
ensure_mcp_scopes_on_dcr_clients() {
  local uuid client_id pub std
  if ! "${KCADM}" get clients -r "${REALM}" \
        --fields id,clientId,publicClient,standardFlowEnabled,serviceAccountsEnabled \
        --format csv --noquotes \
        >/tmp/kc-dcr-clients.csv 2>/tmp/kc-dcr-clients.err; then
    echo "WARN: could not list clients for DCR MCP scope repair" >&2
    cat /tmp/kc-dcr-clients.err >&2 || true
    return 0
  fi
  while IFS=, read -r uuid client_id pub std sa || [ -n "$uuid" ]; do
    [ "$uuid" = "id" ] && continue
    [ -z "$uuid" ] && continue
    case "$client_id" in
      tetrix-frontend|tetrix-admin-api|tetrix-account-verify|wellclaudecode000001|account|account-console|security-admin-console|admin-cli|broker|realm-management) continue ;;
    esac
    # Anonymous DCR clients get UUID clientIds; skip seeded/fixed clients above.
    case "$client_id" in
      ????????-????-????-????-????????????) ;;
      *) continue ;;
    esac
    [ "$pub" = "true" ] || continue
    [ "$std" = "true" ] || continue
    [ "$sa" = "true" ] && continue
    ensure_client_default_scope "${uuid}" basic
    ensure_client_default_scope "${uuid}" res:mcp
    ensure_client_default_scope "${uuid}" graph:read
    # Write scopes must be DEFAULTS: a generic MCP client only requests what the resource
    # advertises (graph:read), so an optional write scope is never asked for and every MCP
    # write tool 403s. Still user-bounded — authorization-code flow + the server's own
    # org/per-tool checks (ADR-0057 §3). Both scopes now exist in the realm — hitl:write is
    # created above (#189), so this line is no longer the silent no-op it was.
    ensure_client_default_scope "${uuid}" sessions:write
    ensure_client_default_scope "${uuid}" hitl:write
    ensure_client_optional_scope "${uuid}" offline_access
    echo "DCR MCP scopes repaired client=${client_id}"
  done < /tmp/kc-dcr-clients.csv
}
ensure_mcp_scopes_on_dcr_clients

patch_scope_audience() {
  local scope_name="$1" aud_value="$2"
  local sid mapper_id mapper_name
  local safe_name="aud-${scope_name//:/-}"
  sid="$(client_scope_id "${scope_name}" || true)"
  if [ -z "${sid}" ]; then
    echo "WARN: client scope ${scope_name} not found — skip audience patch" >&2
    return 0
  fi
  # Keycloak Admin REST path is protocol-mappers/models (bare protocol-mappers 404s).
  if ! "${KCADM}" get "client-scopes/${sid}/protocol-mappers/models" -r "${REALM}" \
        >/tmp/kc-scope-mappers.json 2>/tmp/kc-scope-mappers.err; then
    echo "WARN: could not list mappers for ${scope_name}" >&2
    cat /tmp/kc-scope-mappers.err >&2 || true
    return 0
  fi
  mapper_id=""
  mapper_name="${safe_name}"
  local id="" name="" pmap="" line val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"id"'*)
        val="${line#*\"id\"}"; val="${val#*:}"; val="${val#*\"}"; id="${val%%\"*}"
        ;;
      *'"name"'*)
        val="${line#*\"name\"}"; val="${val#*:}"; val="${val#*\"}"; name="${val%%\"*}"
        ;;
      *'"protocolMapper"'*)
        val="${line#*\"protocolMapper\"}"; val="${val#*:}"; val="${val#*\"}"; pmap="${val%%\"*}"
        if [ "$pmap" = "oidc-audience-mapper" ] && [ -n "$id" ]; then
          mapper_id="$id"
          [ -n "$name" ] && mapper_name="$name"
        fi
        ;;
    esac
  done < /tmp/kc-scope-mappers.json

  # Nested config.* via -s fails with "Cannot parse the JSON" on KC 26 kcadm —
  # create/update from a JSON body instead (same pattern as collector-admin mapper).
  write_audience_mapper_json() {
    local out="$1" mid="${2:-}"
    if [ -n "${mid}" ]; then
      printf '%s\n' \
        '{' \
        "  \"id\": \"${mid}\"," \
        "  \"name\": \"${mapper_name}\"," \
        '  "protocol": "openid-connect",' \
        '  "protocolMapper": "oidc-audience-mapper",' \
        '  "config": {' \
        "    \"included.custom.audience\": \"${aud_value}\"," \
        '    "access.token.claim": "true",' \
        '    "id.token.claim": "false"' \
        '  }' \
        '}' >"${out}"
    else
      printf '%s\n' \
        '{' \
        "  \"name\": \"${mapper_name}\"," \
        '  "protocol": "openid-connect",' \
        '  "protocolMapper": "oidc-audience-mapper",' \
        '  "config": {' \
        "    \"included.custom.audience\": \"${aud_value}\"," \
        '    "access.token.claim": "true",' \
        '    "id.token.claim": "false"' \
        '  }' \
        '}' >"${out}"
    fi
  }

  if [ -z "${mapper_id}" ]; then
    write_audience_mapper_json /tmp/kc-aud-mapper.json
    if "${KCADM}" create "client-scopes/${sid}/protocol-mappers/models" -r "${REALM}" \
          -f /tmp/kc-aud-mapper.json \
          >/tmp/kc-aud-create.log 2>&1; then
      echo "CREATE ${scope_name} audience mapper -> ${aud_value}"
      return 0
    fi
    echo "ERROR: failed to create oidc-audience-mapper on ${scope_name}" >&2
    cat /tmp/kc-aud-create.log >&2 || true
    return 1
  fi
  write_audience_mapper_json /tmp/kc-aud-mapper.json "${mapper_id}"
  if "${KCADM}" update "client-scopes/${sid}/protocol-mappers/models/${mapper_id}" -r "${REALM}" \
        -f /tmp/kc-aud-mapper.json \
        >/tmp/kc-aud-patch.log 2>&1; then
    echo "PATCH ${scope_name} audience -> ${aud_value}"
  else
    echo "ERROR: failed to patch ${scope_name} audience" >&2
    cat /tmp/kc-aud-patch.log >&2 || true
    return 1
  fi
}

echo "==> patching res:* audience mappers"
patch_scope_audience "res:daemon" "${AUD_DAEMON}"
patch_scope_audience "res:api" "${AUD_API}"
patch_scope_audience "res:mcp" "${AUD_MCP}"
# Cloud connectors (claude.ai, chatgpt.com) send an RFC 7591 `scope` field at DCR, which
# makes Keycloak drop the realm-default res:mcp audience selector from the registered
# client — so their token never carries aud=<mcp> and the MCP server 401s. graph:read is
# the scope every MCP client DOES request (PRM scopes_supported), so stamp the MCP audience
# here too: any client granted graph:read gets aud=<mcp> regardless of the res:mcp drop.
# graph:read is MCP-only, so daemon/api/frontend tokens (no graph:read) are unaffected; the
# MCP verifier matches audience by array-contains. Cursor (omits `scope`, keeps res:mcp) is
# unchanged.
patch_scope_audience "graph:read" "${AUD_MCP}"

# ------------------------------------------------------------------
# res:mcp groups mapper (ADR-0016: DCR MCP tokens need org membership)
# ------------------------------------------------------------------
ensure_groups_mapper() {
  local scope sid mapper_name
  scope="$1"
  sid="$(client_scope_id "${scope}" || true)"
  if [ -z "${sid}" ]; then
    echo "WARN: client scope ${scope} not found — skip groups mapper" >&2
    return 0
  fi
  mapper_name="groups"
  if ! "${KCADM}" get "client-scopes/${sid}/protocol-mappers/models" -r "${REALM}" \
        >/tmp/kc-res-mcp-mappers.json 2>/tmp/kc-res-mcp-mappers.err; then
    echo "WARN: could not list ${scope} protocol-mappers" >&2
    cat /tmp/kc-res-mcp-mappers.err >&2 || true
    return 0
  fi
  if grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${mapper_name}\"" /tmp/kc-res-mcp-mappers.json 2>/dev/null \
     || grep -q "${mapper_name}" /tmp/kc-res-mcp-mappers.json 2>/dev/null; then
    echo "${scope} protocol-mapper ${mapper_name} already present"
    return 0
  fi
  printf '%s\n' \
    '{' \
    '  "name": "groups",' \
    '  "protocol": "openid-connect",' \
    '  "protocolMapper": "oidc-group-membership-mapper",' \
    '  "config": {' \
    '    "full.path": "true",' \
    '    "id.token.claim": "true",' \
    '    "access.token.claim": "true",' \
    '    "claim.name": "groups",' \
    '    "userinfo.token.claim": "true"' \
    '  }' \
    '}' >/tmp/kc-res-mcp-groups-mapper.json
  if "${KCADM}" create "client-scopes/${sid}/protocol-mappers/models" -r "${REALM}" \
        -f /tmp/kc-res-mcp-groups-mapper.json \
        >/tmp/kc-res-mcp-groups-mapper.log 2>&1; then
    echo "${scope} protocol-mapper += ${mapper_name}"
  else
    echo "WARN: could not create ${mapper_name} on ${scope}" >&2
    cat /tmp/kc-res-mcp-groups-mapper.log >&2 || true
  fi
}
# Both scopes, for the same reason patch_scope_audience covers both above: a connector that
# sends an RFC 7591 `scope` at DCR (claude.ai, chatgpt.com) loses the realm-default res:mcp,
# so a res:mcp-only groups mapper never fires and its token carries no `groups` claim — the
# multi-tenant MCP server then answers 400 "organization context required" before any tool
# runs. graph:read is the scope every MCP client does request (our PRM scopes_supported).
echo "==> ensuring groups mappers on res:mcp + graph:read (DCR MCP org tenancy)"
ensure_groups_mapper res:mcp
ensure_groups_mapper graph:read

# ------------------------------------------------------------------
# res:api — entitled collector:admin scope mutation (tetrix-iam#19)
# ------------------------------------------------------------------
ensure_collector_admin_mapper() {
  local sid mapper_name provider_id
  sid="$(client_scope_id "res:api" || true)"
  if [ -z "${sid}" ]; then
    echo "WARN: client scope res:api not found — skip collector:admin mapper" >&2
    return 0
  fi
  mapper_name="collector-admin-if-entitled"
  provider_id="script-append-collector-admin-if-entitled.js"
  if ! "${KCADM}" get "client-scopes/${sid}/protocol-mappers/models" -r "${REALM}" \
        >/tmp/kc-res-api-mappers.json 2>/tmp/kc-res-api-mappers.err; then
    echo "WARN: could not list res:api protocol-mappers" >&2
    cat /tmp/kc-res-api-mappers.err >&2 || true
    return 0
  fi
  if grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${mapper_name}\"" /tmp/kc-res-api-mappers.json 2>/dev/null \
     || grep -q "${mapper_name}" /tmp/kc-res-api-mappers.json 2>/dev/null; then
    echo "res:api protocol-mapper ${mapper_name} already present"
    return 0
  fi
  # Nested config.* via -s fails with "Cannot parse the JSON" on KC 26 kcadm —
  # create from a JSON body instead. access.token.claim=true is required for the
  # script mapper to run on access-token mint. Use printf (not a bare heredoc)
  # so Helm YAML does not treat `{` / `key:` lines as flow mappings.
  printf '%s\n' \
    '{' \
    "  \"name\": \"${mapper_name}\"," \
    '  "protocol": "openid-connect",' \
    "  \"protocolMapper\": \"${provider_id}\"," \
    '  "config": {' \
    '    "access.token.claim": "true",' \
    '    "id.token.claim": "false",' \
    '    "userinfo.token.claim": "false",' \
    '    "claim.name": "tetrix_collector_admin_gate",' \
    '    "jsonType.label": "String"' \
    '  }' \
    '}' >/tmp/kc-collector-admin-mapper.json
  if "${KCADM}" create "client-scopes/${sid}/protocol-mappers/models" -r "${REALM}" \
        -f /tmp/kc-collector-admin-mapper.json \
        >/tmp/kc-admin-mapper.log 2>&1; then
    echo "res:api protocol-mapper += ${mapper_name}"
  else
    echo "WARN: could not create ${mapper_name} on res:api (image may lack script — bump keycloak.image.tag)" >&2
    cat /tmp/kc-admin-mapper.log >&2 || true
  fi
}
ensure_collector_admin_mapper

# ------------------------------------------------------------------
# SPA client redirect URIs / webOrigins for this ingress host
# ------------------------------------------------------------------
echo "==> ensuring ${CLIENT_ID} redirectUris + webOrigins for ${PUBLIC_URL}"
SPA_UUID="$("${KCADM}" get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" \
      --fields id --format csv --noquotes 2>/dev/null | head -n1 | tr -d '\r' || true)"
if [ -n "${SPA_UUID}" ] && [ "${SPA_UUID}" != "id" ]; then
  REDIR_BASE="${PUBLIC_URL}${SPA_BASE}"
  if "${KCADM}" update "clients/${SPA_UUID}" -r "${REALM}" \
        -s "redirectUris=[\"${REDIR_BASE}/*\",\"${REDIR_BASE}/callback\",\"http://localhost/*\",\"http://127.0.0.1/*\"]" \
        -s "webOrigins=[\"${PUBLIC_URL}\",\"+\"]" \
        >/tmp/kc-spa-redirect.log 2>&1; then
    echo "SPA redirects -> ${REDIR_BASE}/* + callback"
  else
    echo "WARN: SPA redirectUri update failed" >&2
    cat /tmp/kc-spa-redirect.log >&2 || true
  fi
  # Dual-token Overview needs res:api + collector:read/write on the default
  # access token (and `basic` for `sub`). Optional→default move: delete
  # optional assignment first or Keycloak keeps the scope optional-only.
  ensure_default_scope() {
    local scope_name="$1"
    local sid
    sid="$(client_scope_id "${scope_name}" || true)"
    if [ -z "${sid}" ]; then
      echo "WARN: client scope ${scope_name} not found" >&2
      return 0
    fi
    "${KCADM}" delete "clients/${SPA_UUID}/optional-client-scopes/${sid}" -r "${REALM}" \
          >/tmp/kc-spa-scope-del.log 2>&1 || true
    if "${KCADM}" update "clients/${SPA_UUID}/default-client-scopes/${sid}" -r "${REALM}" \
          >/tmp/kc-spa-scope-add.log 2>&1 \
       || "${KCADM}" create "clients/${SPA_UUID}/default-client-scopes/${sid}" -r "${REALM}" \
          >/tmp/kc-spa-scope-add.log 2>&1 \
       || grep -qiE 'already|Conflict|exists' /tmp/kc-spa-scope-add.log 2>/dev/null; then
      echo "SPA default-client-scopes += ${scope_name}"
    else
      echo "WARN: could not add ${scope_name} as default client scope" >&2
      cat /tmp/kc-spa-scope-add.log >&2 || true
    fi
  }
  ensure_default_scope basic
  ensure_default_scope email
  ensure_default_scope profile
  ensure_default_scope res:daemon
  ensure_default_scope res:api
  ensure_default_scope collector:read
  ensure_default_scope collector:write
else
  echo "WARN: SPA client ${CLIENT_ID} not found — skip redirect patch" >&2
fi

# ------------------------------------------------------------------
# SPA Owner bootstrap (platform_admin) — secrets KEYCLOAK_OWNER_*
# ------------------------------------------------------------------
OWNER_EMAIL="${KEYCLOAK_OWNER_EMAIL:-}"
OWNER_PW="${KEYCLOAK_OWNER_PASSWORD:-}"
# ADOPT, NEVER MINT (#235). The Owner org id is NEVER read from the environment here and is
# NEVER inferred from the order of /orgs' children (ADR-0009 D6). This provisioner runs before
# the daemon has migrated — Compose: depends_on keycloak only; Helm: hook-weight 0 — so it can
# neither know organizations.id nor check one. It joins the Owner ONLY when a resolve step that
# CAN check (keycloak-owner-org-resolve / the resolve-org-id initContainer) has handed a
# validated id on in ORG_ID_FILE. No file -> no org work, and keycloak-owner-org-sync does the
# join later. It must never remove or reconcile a membership: that is tetrix-admin-api's
# (ADR-0023 D2/D3).
ORG_ID_FILE="${ORG_ID_FILE:-/out/org_id}"
OWNER_ORG_ID=""
if [ -s "${ORG_ID_FILE}" ]; then
  OWNER_ORG_ID="$(tr -d '[:space:]' < "${ORG_ID_FILE}")"
  echo "==> Owner org id ${OWNER_ORG_ID} handed on by the resolve step (${ORG_ID_FILE})"
fi
# Cloud Owner onboarding — the SAME contract the REST path implements (Wave B).
# CAVEAT: kcadm cannot merge a realm attribute map on its own, so the SMTP merge
# needs jq. When jq is absent this path reports smtp_rejected instead of writing
# a partial realm (a `-s` write would replace .attributes and drop DCR/session).
DEPLOY_MODE="${TETRIX_DEPLOYMENT_MODE:-dev}"
OWNER_INVITE_LIFESPAN="${KEYCLOAK_OWNER_INVITE_LIFESPAN_SECONDS:-86400}"
SMTP_PASSWORD="${KEYCLOAK_SMTP_PASSWORD:-}"
SMTP_HOST="${KEYCLOAK_SMTP_HOST:-smtp.resend.com}"
SMTP_PORT="${KEYCLOAK_SMTP_PORT:-465}"
SMTP_USERNAME="${KEYCLOAK_SMTP_USERNAME:-resend}"
SMTP_FROM="${KEYCLOAK_SMTP_FROM_EMAIL:-notifications@tetrix.deskree.com}"
SMTP_FROM_NAME="${KEYCLOAK_SMTP_FROM_NAME:-Tetrix Cloud}"
SMTP_SSL="${KEYCLOAK_SMTP_SSL:-true}"
SMTP_STARTTLS="${KEYCLOAK_SMTP_STARTTLS:-false}"

owner_invite_mode() {
  [ "${DEPLOY_MODE}" = "cloud" ] && return 0
  [ "${KEYCLOAK_OWNER_INVITE:-}" = "true" ] && return 0
  return 1
}

owner_invite_result() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg deployment "${TETRIX_DEPLOYMENT_ID:-}" \
      --arg slug "${TETRIX_DEPLOYMENT_SLUG:-}" \
      --arg status "$1" \
      --arg reason "${2:-}" '{
        schema: "tetrix-cloud-owner-invite.v1",
        deployment_id: (if $deployment == "" then null else $deployment end),
        slug: (if $slug == "" then null else $slug end),
        status: $status,
        reason_code: (if $reason == "" then null else $reason end)
      }'
    return 0
  fi
  _d="${TETRIX_DEPLOYMENT_ID:-}"; _s="${TETRIX_DEPLOYMENT_SLUG:-}"
  printf '{"schema":"tetrix-cloud-owner-invite.v1","deployment_id":%s,"slug":%s,"status":"%s","reason_code":%s}\n' \
    "$([ -n "$_d" ] && printf '"%s"' "$_d" || printf 'null')" \
    "$([ -n "$_s" ] && printf '"%s"' "$_s" || printf 'null')" \
    "$1" \
    "$([ -n "${2:-}" ] && printf '"%s"' "$2" || printf 'null')"
}

# Fixed reason codes: keycloak_unavailable, smtp_rejected, action_email_rejected,
# attribute_write_failed, already_sent.
owner_invite_fail() {
  owner_invite_result failed "$1"
  echo "ERROR: owner invite failed (${1})" >&2
  exit 1
}

ensure_realm_smtp() {
  [ -n "${SMTP_PASSWORD}" ] || {
    echo "==> skipping realm SMTP (KEYCLOAK_SMTP_PASSWORD unset)" >&2
    return 0
  }
  command -v jq >/dev/null 2>&1 || owner_invite_fail smtp_rejected
  "${KCADM}" get "realms/${REALM}" >/tmp/kc-realm-current.json 2>/dev/null \
    || owner_invite_fail keycloak_unavailable
  jq \
    --arg password "${SMTP_PASSWORD}" \
    --arg host "${SMTP_HOST}" \
    --arg port "${SMTP_PORT}" \
    --arg user "${SMTP_USERNAME}" \
    --arg from "${SMTP_FROM}" \
    --arg fromName "${SMTP_FROM_NAME}" \
    --arg ssl "${SMTP_SSL}" \
    --arg starttls "${SMTP_STARTTLS}" '
      .smtpServer = {
        host: $host,
        port: $port,
        from: $from,
        fromDisplayName: $fromName,
        replyTo: "",
        user: $user,
        password: $password,
        auth: "true",
        authType: "basic",
        ssl: $ssl,
        starttls: $starttls
      }
      | .attributes = ((.attributes // {}) + {"tetrix.smtpPassword": $password})
    ' /tmp/kc-realm-current.json > /tmp/kc-realm-smtp.json
  if ! "${KCADM}" update "realms/${REALM}" -f /tmp/kc-realm-smtp.json \
       >/tmp/kcadm-smtp.log 2>&1; then
    rm -f /tmp/kc-realm-smtp.json
    owner_invite_fail smtp_rejected
  fi
  rm -f /tmp/kc-realm-smtp.json
  echo "realm smtpServer configured (${SMTP_HOST}:${SMTP_PORT}) + tetrix.smtpPassword mirrored" >&2
}

send_owner_action_email() {
  _owner_id="$1"
  command -v jq >/dev/null 2>&1 || owner_invite_fail attribute_write_failed
  "${KCADM}" get "users/${_owner_id}" -r "${REALM}" >/tmp/kc-owner-current.json 2>/dev/null \
    || owner_invite_fail keycloak_unavailable
  if jq -e '.attributes["tetrix.ownerInviteSentAt"] // empty' \
       /tmp/kc-owner-current.json >/dev/null 2>&1; then
    echo "Owner invite already sent — skipping (tetrix.ownerInviteSentAt present)" >&2
    owner_invite_result sent already_sent
    return 0
  fi

  if ! "${KCADM}" update "users/${_owner_id}" -r "${REALM}" \
        -s 'requiredActions=["UPDATE_PASSWORD"]' >/tmp/kcadm-owner-ra.log 2>&1; then
    owner_invite_fail action_email_rejected
  fi

  _redirect="$(printf '%s/' "${PUBLIC_URL%/}" | jq -sRr @uri)"
  printf '%s\n' '["UPDATE_PASSWORD"]' >/tmp/kc-owner-actions.json
  if ! "${KCADM}" update \
        "users/${_owner_id}/execute-actions-email?client_id=${CLIENT_ID}&redirect_uri=${_redirect}&lifespan=${OWNER_INVITE_LIFESPAN}" \
        -r "${REALM}" -f /tmp/kc-owner-actions.json >/tmp/kcadm-owner-email.log 2>&1; then
    if grep -qiE 'smtp|mail|send' /tmp/kcadm-owner-email.log 2>/dev/null; then
      owner_invite_fail smtp_rejected
    fi
    owner_invite_fail action_email_rejected
  fi

  _sent_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  "${KCADM}" get "users/${_owner_id}" -r "${REALM}" >/tmp/kc-owner-current.json 2>/dev/null \
    || owner_invite_fail attribute_write_failed
  jq --arg at "${_sent_at}" \
    '.attributes = ((.attributes // {}) + {"tetrix.ownerInviteSentAt": $at})' \
    /tmp/kc-owner-current.json > /tmp/kc-owner-sent.json
  if ! "${KCADM}" update "users/${_owner_id}" -r "${REALM}" -f /tmp/kc-owner-sent.json \
       >/tmp/kcadm-owner-attr.log 2>&1; then
    owner_invite_fail attribute_write_failed
  fi
  echo "Owner action email sent (UPDATE_PASSWORD, lifespan ${OWNER_INVITE_LIFESPAN}s)" >&2
  owner_invite_result sent ""
}

if [ -n "${OWNER_EMAIL}" ] && { [ -n "${OWNER_PW}" ] || owner_invite_mode; }; then
  ensure_realm_smtp
  echo "==> ensuring SPA Owner user ${OWNER_EMAIL} (platform_admin)"
  OWNER_ID="$("${KCADM}" get users -r "${REALM}" -q "username=${OWNER_EMAIL}" \
        --fields id --format csv --noquotes 2>/dev/null | head -n1 | tr -d '\r' || true)"
  CREATED=0
  if [ -z "${OWNER_ID}" ] || [ "${OWNER_ID}" = "id" ]; then
    OWNER_ID="$("${KCADM}" create users -r "${REALM}" \
          -s "username=${OWNER_EMAIL}" \
          -s "email=${OWNER_EMAIL}" \
          -s 'enabled=true' \
          -s 'emailVerified=true' \
          -i 2>/tmp/kcadm-owner-create.log | tr -d '\r' || true)"
    if [ -z "${OWNER_ID}" ]; then
      echo "ERROR: failed to create Owner user" >&2
      cat /tmp/kcadm-owner-create.log >&2 || true
      exit 1
    fi
    CREATED=1
    echo "created Owner user id=${OWNER_ID}"
  else
    echo "Owner user already exists id=${OWNER_ID}"
  fi
  if [ "${CREATED}" -eq 1 ] && [ -n "${OWNER_PW}" ]; then
    if ! "${KCADM}" set-password -r "${REALM}" --userid "${OWNER_ID}" \
          --new-password "${OWNER_PW}" >/tmp/kcadm-owner-pw.log 2>&1; then
      echo "ERROR: failed to set Owner password" >&2
      cat /tmp/kcadm-owner-pw.log >&2 || true
      exit 1
    fi
  elif owner_invite_mode; then
    echo "email-invite mode: leaving the Owner without a preset credential" >&2
  fi
  if ! "${KCADM}" add-roles -r "${REALM}" --uid "${OWNER_ID}" \
        --rolename platform_admin >/tmp/kcadm-owner-role.log 2>&1; then
    # Idempotent: already assigned is OK
    if ! grep -qiE 'already|Conflict|exists' /tmp/kcadm-owner-role.log 2>/dev/null; then
      echo "WARN: add-roles platform_admin failed" >&2
      cat /tmp/kcadm-owner-role.log >&2 || true
    fi
  else
    echo "Owner realm role platform_admin ensured"
  fi

  # SPA callback requires at least one /orgs/<id>/(admins|members) group claim. That group is
  # created on a VALIDATED organizations.id — by keycloak-owner-org-sync, or here only when a
  # resolve step handed one on in ORG_ID_FILE. Never guessed from existing children (#235).
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
      echo "ERROR: failed to create group child ${child_name} under ${parent_id}" >&2
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

  # REMOVED (#235, ADR-0009 D6): the kcadm twin of the `head -n1` adoption — it scanned /orgs'
  # children and took the first non-"orgs" name as the Owner's organization. The org is never
  # inferred from list order; a blank id means "not my job".

  # Group path segment MUST be the daemon organizations.id UUID (Wave 1 /
  # ADR-0009), not the org display name (e.g. AIDB_ORG=default). Seeding a
  # non-UUID name yields /orgs/default/… claims the daemon cannot resolve.
  # Local Compose: keycloak-owner-org-resolve + keycloak-owner-org-sync do this after the
  # daemon is healthy, on an id checked against organizations (#235).
  if [ -n "${OWNER_ORG_ID}" ] && [ -n "${ORGS_ID}" ]; then
    echo "==> ensuring Owner org groups /orgs/${OWNER_ORG_ID}/{admins,members}"
    ORG_NODE_ID="$(ensure_child_group "${ORGS_ID}" "${OWNER_ORG_ID}" || true)"
    if [ -n "${ORG_NODE_ID}" ]; then
      ensure_child_group "${ORG_NODE_ID}" "members" >/dev/null || true
      ADMINS_ID="$(ensure_child_group "${ORG_NODE_ID}" "admins" || true)"
      if [ -n "${ADMINS_ID}" ]; then
        if "${KCADM}" update "users/${OWNER_ID}/groups/${ADMINS_ID}" -r "${REALM}" \
              >/tmp/kc-owner-group.log 2>&1; then
          echo "Owner added to /orgs/${OWNER_ORG_ID}/admins"
        else
          echo "WARN: join Owner to admins group failed" >&2
          cat /tmp/kc-owner-group.log >&2 || true
        fi
      fi
    fi
  elif [ -z "${OWNER_ORG_ID}" ]; then
    echo "==> /orgs ensured; Owner org membership is keycloak-owner-org-sync's job — it validates the id against the daemon organizations table first (#235)"
  else
    echo "WARN: could not ensure /orgs group — skipping Owner org membership" >&2
  fi

  # Seed first/last name so VERIFY_PROFILE (Keycloak default) does not block
  # the first SPA login for auto-provisioned Owners.
  if ! "${KCADM}" update "users/${OWNER_ID}" -r "${REALM}" \
        -s 'firstName=Tetrix' -s 'lastName=Owner' \
        >/tmp/kc-owner-name.log 2>&1; then
    echo "WARN: could not set Owner first/last name" >&2
    cat /tmp/kc-owner-name.log >&2 || true
  fi

  if owner_invite_mode; then
    send_owner_action_email "${OWNER_ID}"
  fi
else
  echo "==> skipping SPA Owner seed (KEYCLOAK_OWNER_EMAIL/PASSWORD unset)"
fi

# ------------------------------------------------------------------
# admin-api confidential client (HttpKeycloakAdmin) — KEYCLOAK_ADMIN_*
# ------------------------------------------------------------------
ADMIN_API_CLIENT_ID="${KEYCLOAK_ADMIN_API_CLIENT_ID:-}"
ADMIN_API_CLIENT_SECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET:-}"
if [ -n "${ADMIN_API_CLIENT_ID}" ] && [ -n "${ADMIN_API_CLIENT_SECRET}" ]; then
  echo "==> ensuring confidential client ${ADMIN_API_CLIENT_ID} + realm-management roles"
  ADMIN_API_UUID="$("${KCADM}" get clients -r "${REALM}" -q "clientId=${ADMIN_API_CLIENT_ID}" \
        --fields id --format csv --noquotes 2>/dev/null | head -n1 | tr -d '\r' || true)"
  if [ -z "${ADMIN_API_UUID}" ] || [ "${ADMIN_API_UUID}" = "id" ]; then
    ADMIN_API_UUID="$("${KCADM}" create clients -r "${REALM}" \
          -s "clientId=${ADMIN_API_CLIENT_ID}" \
          -s 'enabled=true' \
          -s 'publicClient=false' \
          -s 'serviceAccountsEnabled=true' \
          -s 'standardFlowEnabled=false' \
          -s 'directAccessGrantsEnabled=false' \
          -s 'implicitFlowEnabled=false' \
          -s 'fullScopeAllowed=true' \
          -s "secret=${ADMIN_API_CLIENT_SECRET}" \
          -i 2>/tmp/kcadm-admin-api-create.log | tr -d '\r' || true)"
    if [ -z "${ADMIN_API_UUID}" ]; then
      echo "ERROR: failed to create client ${ADMIN_API_CLIENT_ID}" >&2
      cat /tmp/kcadm-admin-api-create.log >&2 || true
      exit 1
    fi
    echo "created client ${ADMIN_API_CLIENT_ID} id=${ADMIN_API_UUID}"
  else
    echo "client ${ADMIN_API_CLIENT_ID} already exists id=${ADMIN_API_UUID}"
  fi
  # Always sync secret + fullScopeAllowed so client_credentials Admin REST
  # (group-by-path) works. fullScopeAllowed=false + empty client-scope
  # mappings yields 403 on realm-management group APIs.
  if "${KCADM}" update "clients/${ADMIN_API_UUID}" -r "${REALM}" \
        -s 'publicClient=false' \
        -s 'serviceAccountsEnabled=true' \
        -s 'standardFlowEnabled=false' \
        -s 'directAccessGrantsEnabled=false' \
        -s 'implicitFlowEnabled=false' \
        -s 'fullScopeAllowed=true' \
        -s "secret=${ADMIN_API_CLIENT_SECRET}" \
        >/tmp/kcadm-admin-api-secret.log 2>&1; then
    echo "synced client secret + fullScopeAllowed for ${ADMIN_API_CLIENT_ID}"
  else
    echo "WARN: failed to sync client secret for ${ADMIN_API_CLIENT_ID}" >&2
    cat /tmp/kcadm-admin-api-secret.log >&2 || true
  fi
  # Idempotent service-account roles for org groups + realm SMTP.
  # kcadm add-roles targets a *user* (--uusername/--uid), not a client id.
  # Keycloak service-account username is service-account-<clientId>.
  SA_USERNAME="service-account-${ADMIN_API_CLIENT_ID}"
  for ROLE in manage-users view-users query-users query-groups manage-realm view-realm; do
    if "${KCADM}" add-roles -r "${REALM}" \
          --uusername "${SA_USERNAME}" \
          --cclientid realm-management \
          --rolename "${ROLE}" \
          >/tmp/kcadm-admin-api-role.log 2>&1 \
       || grep -qiE 'already|Conflict|exists' /tmp/kcadm-admin-api-role.log 2>/dev/null; then
      echo "service-account realm-management += ${ROLE}"
    else
      echo "WARN: could not assign realm-management/${ROLE} to ${SA_USERNAME}" >&2
      cat /tmp/kcadm-admin-api-role.log >&2 || true
    fi
  done
else
  echo "==> skipping admin-api client seed (KEYCLOAK_ADMIN_API_CLIENT_ID/SECRET unset)"
fi

# ------------------------------------------------------------------
# admin-api -> collectors M2M client — KEYCLOAK_COLLECTORS_M2M_*
# kcadm twin of the block in keycloak-provision-rest.sh; see that file for the full
# reasoning. Summary: a SEPARATE client from the admin-api Admin-REST one above,
# because the sub=client_id mapper here rewrites `sub` unconditionally while Admin
# REST resolves the acting service-account user BY `sub`, and the two need opposite
# fullScopeAllowed. Verified end-to-end against a live Keycloak on the rest.sh path.
# ------------------------------------------------------------------
COLL_M2M_CLIENT_ID="${KEYCLOAK_COLLECTORS_M2M_CLIENT_ID:-}"
COLL_M2M_CLIENT_SECRET="${KEYCLOAK_COLLECTORS_M2M_SECRET:-}"
COLL_M2M_SCOPE="${KEYCLOAK_COLLECTORS_M2M_SCOPE:-collector:identity:offboard}"
if [ -n "${COLL_M2M_CLIENT_ID}" ] && [ -n "${COLL_M2M_CLIENT_SECRET}" ]; then
  echo "==> ensuring collectors M2M client ${COLL_M2M_CLIENT_ID}"

  # scope name -> uuid. The realm import owns collector:* scopes; fail LOUDLY when one
  # is missing rather than WARN-skipping like the SPA's collector:read assignment: a
  # missing scope here shows up only as a 403 at collectors, and the offboard is the
  # platform's only seat decrement.
  "${KCADM}" get client-scopes -r "${REALM}" --fields id,name --format csv --noquotes \
    >/tmp/kcadm-scopes.csv 2>/dev/null || true
  # Pure-shell field splitting, NOT awk: the tetrix-iam Keycloak image ships neither awk
  # nor jq nor python (only sed/cut/grep/head/tr). Verified by running this script inside
  # the image — an awk-based version died with "awk: command not found" right here.
  # `--noquotes` csv is `<id>,<name>` with no header row.
  # `|| [ -n "$id" ]` so a final record without a trailing newline is not dropped —
  # matching the file's own client_scope_id helper.
  scope_uuid() {
    local want="$1" id name
    while IFS=, read -r id name || [ -n "${id}" ]; do
      name="$(printf '%s' "${name}" | tr -d '\r')"
      if [ "${name}" = "${want}" ]; then
        printf '%s' "${id}"
        return 0
      fi
    done </tmp/kcadm-scopes.csv
    return 0
  }
  COLL_M2M_SCOPE_UUID="$(scope_uuid "${COLL_M2M_SCOPE}")"

  # CREATE the offboard scope when the realm lacks it -- do not fail. Keycloak's
  # --import-realm does NOT re-import into an existing realm, so an upgraded install never
  # receives a newly added scope; this chart already learned that
  # (docs/changelog.d/2026-07-28-mcp-dcr-groups-mapper-provision.md) and answered it by
  # patching the live realm from provisioning. Aborting here would fail this
  # post-install/post-upgrade hook and therefore the whole helm release.
  if [ -z "${COLL_M2M_SCOPE_UUID}" ]; then
    echo "client-scope ${COLL_M2M_SCOPE} absent from realm ${REALM} -- creating"
    printf '%s\n' \
      '{' \
      "  \"name\": \"${COLL_M2M_SCOPE}\"," \
      '  "description": "Cross-owner identity mapping cleanup for account offboarding (collectors ADR-0087). Service credentials only.",' \
      '  "protocol": "openid-connect",' \
      '  "attributes": {' \
      '    "include.in.token.scope": "true",' \
      '    "display.on.consent.screen": "false"' \
      '  }' \
      '}' >/tmp/kcadm-coll-m2m-scope.json
    COLL_M2M_SCOPE_UUID="$("${KCADM}" create client-scopes -r "${REALM}" \
          -f /tmp/kcadm-coll-m2m-scope.json -i 2>/tmp/kcadm-coll-m2m-scope.log | tr -d '\r' || true)"
    if [ -z "${COLL_M2M_SCOPE_UUID}" ]; then
      echo "ERROR: could not create client scope ${COLL_M2M_SCOPE}" >&2
      cat /tmp/kcadm-coll-m2m-scope.log >&2 || true
      exit 1
    fi
    echo "CREATE client-scope ${COLL_M2M_SCOPE} id=${COLL_M2M_SCOPE_UUID}"
    "${KCADM}" get client-scopes -r "${REALM}" --fields id,name --format csv --noquotes \
      >/tmp/kcadm-scopes.csv 2>/dev/null || true
  fi

  # res:api is NOT safe to synthesise: it carries the collectors audience mapper, and a
  # bare scope of that name would mint a token the frozen verifier rejects on aud. It has
  # shipped in both realm imports since Wave 1, so its absence means this is not a tetrix
  # realm -- WARN and skip the credential rather than fail the release over it.
  RES_API_SCOPE_UUID="$(scope_uuid "res:api")"
  if [ -z "${RES_API_SCOPE_UUID}" ]; then
    echo "WARN: client scope res:api absent from realm ${REALM} -- skipping the collectors" >&2
    echo "      M2M credential. It carries the collectors aud mapper and cannot be" >&2
    echo "      synthesised here, so the offboard will answer 503 until the realm has it." >&2
    COLL_M2M_READY=0
  else
    COLL_M2M_READY=1
  fi
else
  COLL_M2M_READY=0
  echo "==> skipping collectors M2M client (KEYCLOAK_COLLECTORS_M2M_CLIENT_ID/SECRET unset)"
fi

if [ "${COLL_M2M_READY}" = "1" ]; then

  COLL_M2M_UUID="$("${KCADM}" get clients -r "${REALM}" -q "clientId=${COLL_M2M_CLIENT_ID}" \
        --fields id --format csv --noquotes 2>/dev/null | head -n1 | tr -d '\r' || true)"
  if [ -z "${COLL_M2M_UUID}" ] || [ "${COLL_M2M_UUID}" = "id" ]; then
    COLL_M2M_UUID="$("${KCADM}" create clients -r "${REALM}" \
          -s "clientId=${COLL_M2M_CLIENT_ID}" \
          -s 'name=Tetrix admin-api -> collectors (ADR-0087 identity offboard)' \
          -s 'enabled=true' \
          -s 'publicClient=false' \
          -s 'serviceAccountsEnabled=true' \
          -s 'standardFlowEnabled=false' \
          -s 'directAccessGrantsEnabled=false' \
          -s 'implicitFlowEnabled=false' \
          -s 'fullScopeAllowed=false' \
          -s "secret=${COLL_M2M_CLIENT_SECRET}" \
          -s 'attributes."access.token.signed.response.alg"=ES384' \
          -s 'attributes."use.refresh.tokens"=false' \
          -s 'attributes."client_credentials.use_refresh_token"=false' \
          -i 2>/tmp/kcadm-coll-m2m-create.log | tr -d '\r' || true)"
    if [ -z "${COLL_M2M_UUID}" ]; then
      echo "ERROR: failed to create client ${COLL_M2M_CLIENT_ID}" >&2
      cat /tmp/kcadm-coll-m2m-create.log >&2 || true
      exit 1
    fi
    echo "created client ${COLL_M2M_CLIENT_ID} id=${COLL_M2M_UUID}"
  else
    echo "client ${COLL_M2M_CLIENT_ID} already exists id=${COLL_M2M_UUID}"
  fi

  # Always re-sync secret + flags so a rotated chart Secret takes effect on upgrade.
  # ES384 is not optional: the frozen collectors verifier pins it.
  if "${KCADM}" update "clients/${COLL_M2M_UUID}" -r "${REALM}" \
        -s 'publicClient=false' \
        -s 'serviceAccountsEnabled=true' \
        -s 'standardFlowEnabled=false' \
        -s 'directAccessGrantsEnabled=false' \
        -s 'implicitFlowEnabled=false' \
        -s 'fullScopeAllowed=false' \
        -s "secret=${COLL_M2M_CLIENT_SECRET}" \
        -s 'attributes."access.token.signed.response.alg"=ES384' \
        -s 'attributes."use.refresh.tokens"=false' \
        -s 'attributes."client_credentials.use_refresh_token"=false' \
        >/tmp/kcadm-coll-m2m-sync.log 2>&1; then
    echo "synced secret + ES384 + flags for ${COLL_M2M_CLIENT_ID}"
  else
    echo "WARN: failed to sync ${COLL_M2M_CLIENT_ID} -- the Keycloak client may still hold" >&2
    echo "      a STALE secret, in which case admin-api's token request returns" >&2
    echo "      invalid_client and every offboard answers 503." >&2
    cat /tmp/kcadm-coll-m2m-sync.log >&2 || true
  fi

  # sub=client_id mapper. Without it is_m2m is FALSE, the caller reads as human, and
  # require_service refuses it — the credential would verify and still be rejected.
  #
  # Located by id and then REPAIRED, not merely detected: a mapper of the right provider
  # with drifted config (access.token.claim=false, a different claim.name) yields the same
  # "already present" verdict while sub stays the service-account UUID.
  COLL_M2M_MAPPER_UUID="$("${KCADM}" get "clients/${COLL_M2M_UUID}/protocol-mappers/models" \
        -r "${REALM}" --fields id,protocolMapper --format csv --noquotes 2>/dev/null \
        | grep 'script-sub-equals-client-id.js' | head -n1 | cut -d, -f1 | tr -d '\r' || true)"
  if [ -n "${COLL_M2M_MAPPER_UUID}" ]; then
    if "${KCADM}" update "clients/${COLL_M2M_UUID}/protocol-mappers/models/${COLL_M2M_MAPPER_UUID}" \
          -r "${REALM}" \
          -s 'name=m2m-sub-and-client-id' \
          -s 'protocol=openid-connect' \
          -s 'protocolMapper=script-sub-equals-client-id.js' \
          -s 'config."claim.name"=client_id' \
          -s 'config."jsonType.label"=String' \
          -s 'config."access.token.claim"=true' \
          -s 'config."id.token.claim"=false' \
          -s 'config."userinfo.token.claim"=false' \
          >/tmp/kcadm-coll-m2m-mapper-fix.log 2>&1; then
      echo "sub=client_id mapper present on ${COLL_M2M_CLIENT_ID}, config re-asserted"
    else
      echo "ERROR: sub=client_id mapper exists on ${COLL_M2M_CLIENT_ID} but its config could" >&2
      echo "       not be corrected. A drifted mapper leaves sub as the service-account" >&2
      echo "       UUID, so is_m2m is false and every offboard is refused." >&2
      cat /tmp/kcadm-coll-m2m-mapper-fix.log >&2 || true
      exit 1
    fi
  else
    if "${KCADM}" create "clients/${COLL_M2M_UUID}/protocol-mappers/models" -r "${REALM}" \
          -s 'name=m2m-sub-and-client-id' \
          -s 'protocol=openid-connect' \
          -s 'protocolMapper=script-sub-equals-client-id.js' \
          -s 'config."claim.name"=client_id' \
          -s 'config."jsonType.label"=String' \
          -s 'config."access.token.claim"=true' \
          -s 'config."id.token.claim"=false' \
          -s 'config."userinfo.token.claim"=false' \
          >/tmp/kcadm-coll-m2m-mapper.log 2>&1 \
       || grep -qiE 'already|Conflict|exists' /tmp/kcadm-coll-m2m-mapper.log 2>/dev/null; then
      echo "added sub=client_id mapper to ${COLL_M2M_CLIENT_ID}"
    else
      echo "ERROR: failed to add sub=client_id mapper to ${COLL_M2M_CLIENT_ID}" >&2
      echo "       The tetrix-iam image must ship the scripts provider with feature" >&2
      echo "       scripts enabled; without the mapper the credential is verified but" >&2
      echo "       refused as a non-m2m principal." >&2
      cat /tmp/kcadm-coll-m2m-mapper.log >&2 || true
      exit 1
    fi
  fi

  # DEFAULT (not optional) scopes: a client_credentials grant naming no scope receives
  # only the defaults, so the credential must work without asking.
  #
  # The delete from optional-client-scopes first is load-bearing, not tidying. Keycloak
  # treats a scope as EITHER default or optional, and assigning it as default while it is
  # already OPTIONAL is a silent no-op (verified against keycloak:26.1.4). Without this, a
  # pre-existing client keeps the offboard scope optional forever, a grant naming no scope
  # omits it, and every offboard 403s while provisioning reports success.
  for SCOPE_PAIR in "res:api ${RES_API_SCOPE_UUID}" "${COLL_M2M_SCOPE} ${COLL_M2M_SCOPE_UUID}"; do
    SCOPE_NAME="${SCOPE_PAIR% *}"
    SCOPE_UUID="${SCOPE_PAIR##* }"
    "${KCADM}" delete "clients/${COLL_M2M_UUID}/optional-client-scopes/${SCOPE_UUID}" \
      -r "${REALM}" >/dev/null 2>&1 || true
    if "${KCADM}" update "clients/${COLL_M2M_UUID}/default-client-scopes/${SCOPE_UUID}" \
          -r "${REALM}" >/tmp/kcadm-coll-m2m-scope.log 2>&1 \
       || grep -qiE 'already|Conflict|exists' /tmp/kcadm-coll-m2m-scope.log 2>/dev/null; then
      echo "default scope ${SCOPE_NAME} assigned to ${COLL_M2M_CLIENT_ID}"
    else
      echo "ERROR: failed to assign ${SCOPE_NAME} to ${COLL_M2M_CLIENT_ID}" >&2
      cat /tmp/kcadm-coll-m2m-scope.log >&2 || true
      exit 1
    fi
  done

  # Prune every OTHER scope. A client created through the Admin API inherits the realm's
  # defaultDefaultClientScopes (basic, res:mcp, graph:read here) — the realm-import client
  # escapes that only because its JSON lists defaultClientScopes explicitly. Leaving them
  # is not cosmetic: res:mcp is an AUDIENCE selector, so the credential mints
  # aud=["…/mcp","…/api-collectors"] — a multi-audience M2M token that breaks the frozen
  # single-string-aud contract AND hands the offboard credential a valid MCP audience.
  # Measured against a live Keycloak on the rest.sh path, not hypothetical.
  # `basic` is kept (stock sub/auth_time mappers, not an audience). Optional scopes are
  # pruned too — this credential must not be able to ASK for more than it needs.
  for SCOPE_KIND in default optional; do
    "${KCADM}" get "clients/${COLL_M2M_UUID}/${SCOPE_KIND}-client-scopes" -r "${REALM}" \
      --fields id,name --format csv --noquotes >/tmp/kcadm-coll-m2m-assigned.csv 2>/dev/null || true
    : >/tmp/kcadm-coll-m2m-prune.txt
    while IFS=, read -r ASSIGNED_UUID ASSIGNED_NAME || [ -n "${ASSIGNED_UUID}" ]; do
      ASSIGNED_NAME="$(printf '%s' "${ASSIGNED_NAME}" | tr -d '\r')"
      case "${ASSIGNED_NAME}" in
        "" | name | basic | res:api | "${COLL_M2M_SCOPE}") continue ;;
      esac
      printf '%s %s\n' "${ASSIGNED_UUID}" "${ASSIGNED_NAME}" >>/tmp/kcadm-coll-m2m-prune.txt
    done </tmp/kcadm-coll-m2m-assigned.csv
    while read -r PRUNE_UUID PRUNE_NAME; do
      [ -n "${PRUNE_UUID}" ] || continue
      if "${KCADM}" delete "clients/${COLL_M2M_UUID}/${SCOPE_KIND}-client-scopes/${PRUNE_UUID}" \
            -r "${REALM}" >/tmp/kcadm-coll-m2m-prune.log 2>&1 \
         || grep -qiE 'not found|404' /tmp/kcadm-coll-m2m-prune.log 2>/dev/null; then
        echo "pruned inherited ${SCOPE_KIND} scope ${PRUNE_NAME} from ${COLL_M2M_CLIENT_ID}"
      else
        echo "ERROR: could not prune ${SCOPE_KIND} scope ${PRUNE_NAME} from" >&2
        echo "       ${COLL_M2M_CLIENT_ID}. Leaving it would give the credential a" >&2
        echo "       second audience or an unintended capability." >&2
        cat /tmp/kcadm-coll-m2m-prune.log >&2 || true
        exit 1
      fi
    done </tmp/kcadm-coll-m2m-prune.txt
  done
fi

# ------------------------------------------------------------------
# account password-verify confidential client (ADR-0015) — KEYCLOAK_PASSWORD_VERIFY_*
# DAG on; no standard flow / service account. Secret must match admin-api mount.
# ------------------------------------------------------------------
PASSWORD_VERIFY_CLIENT_ID="${KEYCLOAK_PASSWORD_VERIFY_CLIENT_ID:-}"
PASSWORD_VERIFY_CLIENT_SECRET="${KEYCLOAK_PASSWORD_VERIFY_CLIENT_SECRET:-}"
if [ -n "${PASSWORD_VERIFY_CLIENT_ID}" ] && [ -n "${PASSWORD_VERIFY_CLIENT_SECRET}" ]; then
  echo "==> ensuring confidential client ${PASSWORD_VERIFY_CLIENT_ID} (password-grant verify)"
  PASSWORD_VERIFY_UUID="$("${KCADM}" get clients -r "${REALM}" -q "clientId=${PASSWORD_VERIFY_CLIENT_ID}" \
        --fields id --format csv --noquotes 2>/dev/null | head -n1 | tr -d '\r' || true)"
  if [ -z "${PASSWORD_VERIFY_UUID}" ] || [ "${PASSWORD_VERIFY_UUID}" = "id" ]; then
    PASSWORD_VERIFY_UUID="$("${KCADM}" create clients -r "${REALM}" \
          -s "clientId=${PASSWORD_VERIFY_CLIENT_ID}" \
          -s 'enabled=true' \
          -s 'publicClient=false' \
          -s 'serviceAccountsEnabled=false' \
          -s 'standardFlowEnabled=false' \
          -s 'directAccessGrantsEnabled=true' \
          -s 'implicitFlowEnabled=false' \
          -s 'fullScopeAllowed=false' \
          -s "secret=${PASSWORD_VERIFY_CLIENT_SECRET}" \
          -i 2>/tmp/kcadm-password-verify-create.log | tr -d '\r' || true)"
    if [ -z "${PASSWORD_VERIFY_UUID}" ]; then
      echo "ERROR: failed to create client ${PASSWORD_VERIFY_CLIENT_ID}" >&2
      cat /tmp/kcadm-password-verify-create.log >&2 || true
      exit 1
    fi
    echo "created client ${PASSWORD_VERIFY_CLIENT_ID} id=${PASSWORD_VERIFY_UUID}"
  else
    echo "client ${PASSWORD_VERIFY_CLIENT_ID} already exists id=${PASSWORD_VERIFY_UUID}"
  fi
  # Always sync secret + DAG flags so chart Secret and realm client stay aligned.
  if "${KCADM}" update "clients/${PASSWORD_VERIFY_UUID}" -r "${REALM}" \
        -s 'publicClient=false' \
        -s 'serviceAccountsEnabled=false' \
        -s 'standardFlowEnabled=false' \
        -s 'directAccessGrantsEnabled=true' \
        -s 'implicitFlowEnabled=false' \
        -s 'fullScopeAllowed=false' \
        -s "secret=${PASSWORD_VERIFY_CLIENT_SECRET}" \
        >/tmp/kcadm-password-verify-secret.log 2>&1; then
    echo "synced client secret + DAG flags for ${PASSWORD_VERIFY_CLIENT_ID}"
  else
    echo "WARN: failed to sync client secret for ${PASSWORD_VERIFY_CLIENT_ID}" >&2
    cat /tmp/kcadm-password-verify-secret.log >&2 || true
  fi
else
  echo "==> skipping password-verify client seed (KEYCLOAK_PASSWORD_VERIFY_CLIENT_ID/SECRET unset)"
fi

# VERIFY_PROFILE blocks first login when first/last name are empty. Disable
# it for headless / Owner-seeded installs (email verified is already set).
if "${KCADM}" get "authentication/required-actions/VERIFY_PROFILE" -r "${REALM}" \
      >/tmp/kc-vp.json 2>/tmp/kc-vp.err; then
  if "${KCADM}" update "authentication/required-actions/VERIFY_PROFILE" -r "${REALM}" \
        -s 'enabled=false' -s 'defaultAction=false' \
        >/tmp/kc-vp-upd.log 2>&1; then
    echo "VERIFY_PROFILE required action disabled"
  else
    echo "WARN: could not disable VERIFY_PROFILE" >&2
    cat /tmp/kc-vp-upd.log >&2 || true
  fi
fi

# UPDATE_EMAIL (ADR-0018): register if unregistered, then enable + Force Email
# Verification. Realm verifyEmail stays false. Set config on the required-action
# object (KC 26.1 /config subpath returns "not configurable"). No jq here —
# kcadm path runs on tetrix-iam which may lack it; REST path uses curl-jq.
if ! "${KCADM}" get "authentication/required-actions/UPDATE_EMAIL" -r "${REALM}" \
      >/tmp/kc-ue.json 2>/tmp/kc-ue.err; then
  if "${KCADM}" get "authentication/unregistered-required-actions" -r "${REALM}" \
        >/tmp/kc-ue-unreg.json 2>/tmp/kc-ue-unreg.err \
      && grep -q 'UPDATE_EMAIL' /tmp/kc-ue-unreg.json 2>/dev/null; then
    printf '%s\n' '{"providerId":"UPDATE_EMAIL","name":"Update Email"}' >/tmp/kc-ue-reg.json
    if "${KCADM}" create "authentication/register-required-action" -r "${REALM}" \
          -f /tmp/kc-ue-reg.json >/tmp/kc-ue-reg.log 2>&1; then
      echo "UPDATE_EMAIL required action registered"
    else
      echo "WARN: could not register UPDATE_EMAIL" >&2
      cat /tmp/kc-ue-reg.log >&2 || true
    fi
  else
    echo "WARN: UPDATE_EMAIL required action missing (enable KC feature update-email?)" >&2
    cat /tmp/kc-ue.err >&2 || true
  fi
fi
if "${KCADM}" get "authentication/required-actions/UPDATE_EMAIL" -r "${REALM}" \
      >/tmp/kc-ue.json 2>/tmp/kc-ue.err; then
  # Preserve priority/name from GET when present; always force enable + verifyEmail.
  printf '%s\n' '{"alias":"UPDATE_EMAIL","name":"Update Email","providerId":"UPDATE_EMAIL","enabled":true,"defaultAction":false,"config":{"verifyEmail":"true"}}' \
    >/tmp/kc-ue-upd.json
  if "${KCADM}" update "authentication/required-actions/UPDATE_EMAIL" -r "${REALM}" \
        -f /tmp/kc-ue-upd.json >/tmp/kc-ue-upd.log 2>&1; then
    echo "UPDATE_EMAIL enabled + forceEmailVerification (verifyEmail=true)"
  else
    echo "WARN: could not enable/configure UPDATE_EMAIL" >&2
    cat /tmp/kc-ue-upd.log >&2 || true
  fi
fi

echo "==> provision scaffold complete (realm ready; DCR/audiences/Owner/admin-api/password-verify best-effort via kcadm)"
