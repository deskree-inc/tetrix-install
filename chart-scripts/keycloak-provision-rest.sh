#!/bin/sh
# Fast Keycloak provision via Admin REST (one access token + curl/jq).
# Desired-state equivalent of keycloak-provision-kcadm.sh:
# DCR, audiences, SPA redirects/scopes, Owner, admin-api roles, VERIFY_PROFILE,
# UPDATE_EMAIL (force email verification).
# Requires: curl, jq, sh. No kcadm/JVM per step.
set -eu

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
# Config for the tetrix-dcr-default-scopes ClientRegistrationPolicy component (#208):
# the scope split every DCR client is born with once the iam#42 SPI is active.
# Space-separated. An empty ensure-default-scopes means "the realm's default-default
# client scopes" (SPI semantics), so the default here names the full set the
# keycloak-dcr-scope-repair loop enforces today — the component and the repair loop
# must agree, or a repair tick would rewrite what the birth just did.
DCR_ENSURE_DEFAULT_SCOPES="${KEYCLOAK_DCR_ENSURE_DEFAULT_SCOPES:-basic res:mcp graph:read sessions:write hitl:write}"
DCR_ENSURE_OPTIONAL_SCOPES="${KEYCLOAK_DCR_ENSURE_OPTIONAL_SCOPES:-offline_access}"
# ADR-0027: seconds stamped as client attribute access.token.lifespan on ELIGIBLE MCP
# DCR clients. Empty / 0 leaves the realm 300s ATL in force (SPI inert). SPA is not
# a UUID DCR client and is never written by the repair loop.
DCR_ACCESS_TOKEN_LIFESPAN="${KEYCLOAK_DCR_ACCESS_TOKEN_LIFESPAN:-3600}"
# The vendor predicate for that exception (ADR-0027 D1): space-separated redirect-URI
# prefixes. The SPI stamps a client only when one of its redirect URIs starts with one of
# these AND the client is a public, UUID-named, anonymously-registered app. Empty ⇒ no
# client qualifies, so the exception cannot widen by omission. Cursor is the client with
# the refresh bug; Claude Code is measured fine on the realm's 300s.
DCR_ATL_REDIRECT_PREFIXES="${KEYCLOAK_DCR_ATL_REDIRECT_PREFIXES:-cursor:// https://www.cursor.com/}"
ISSUER="${KEYCLOAK_ISSUER:?}"
AUD_DAEMON="${KEYCLOAK_AUDIENCE_DAEMON:?}"
AUD_API="${KEYCLOAK_AUDIENCE_API:?}"
AUD_MCP="${KEYCLOAK_AUDIENCE_MCP:?}"
PUBLIC_URL="${TETRIX_PUBLIC_URL:?}"
SPA_BASE="${TETRIX_SPA_BASE_PATH:-}"
CLIENT_ID="${KEYCLOAK_CLIENT_ID:-tetrix-frontend}"
# Space-separated extra Valid Redirect URI globs (from values keycloak.provision.redirectUris).
EXTRA_REDIRECT_URIS="${KEYCLOAK_EXTRA_REDIRECT_URIS:-}"

ADMIN_BASE="${KC}/admin"
REALM_BASE="${ADMIN_BASE}/realms/${REALM}"
TOKEN=""
PROVISION_START="$(date +%s 2>/dev/null || echo 0)"

for bin in curl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: ${bin} not found (fast provision requires curl + jq)" >&2
    exit 1
  fi
done

location_id() {
  sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$1" | tr -d '\r' | sed 's:.*/::' | head -n1
}

http() {
  # http METHOD path [extra curl args...]
  _method="$1"
  shift
  _path="$1"
  shift
  case "${_path}" in
    http://*|https://*) _url="${_path}" ;;
    /admin/*) _url="${KC}${_path}" ;;
    /*) _url="${ADMIN_BASE}${_path}" ;;
    *) _url="${REALM_BASE}/${_path}" ;;
  esac
  HTTP_CODE="$(curl -sS -o /tmp/kc-body -D /tmp/kc-hdrs -w '%{http_code}' \
    -X "${_method}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" \
    "${_url}" 2>/tmp/kc-curl.err || echo "000")"
}

obtain_token() {
  curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=admin-cli&username=${ADMIN}&password=${ADMIN_PW}" \
    -o /tmp/kc-token.json 2>/tmp/kc-token.err || return 1
  TOKEN="$(jq -r '.access_token // empty' /tmp/kc-token.json)"
  [ -n "${TOKEN}" ]
}

words_to_json_array() {
  # stdin words -> JSON string array
  jq -R -s 'split("\n") | map(select(length>0)) | map(split(" ")[]) | map(select(length>0))'
}

# ==================================================================
# Cloud Owner onboarding (Tetrix Cloud M0.3, Task 6) — Wave B
# Re-expressed on helm#235's adopt-or-fail contract: this script still
# never reads KEYCLOAK_OWNER_ORG_ID from the environment.
# ==================================================================
# Cloud does NOT hand the Owner a password. It reuses the machinery this realm
# already has — realm smtpServer, the mirrored tetrix.smtpPassword attribute that
# admin-api's own invite path reads, and Keycloak's execute-actions-email — so
# there is no second mailer, no Owner table, and above all no Owner bootstrap
# credential.
#
# Idempotency is the user attribute tetrix.ownerInviteSentAt, written only AFTER
# Keycloak answers 204. Absent means "send"; present means "skip".
OWNER_INVITE_ONLY=0
for _arg in "$@"; do
  case "$_arg" in
    --owner-invite-only) OWNER_INVITE_ONLY=1 ;;
  esac
done

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
  http GET "" || owner_invite_fail keycloak_unavailable
  [ "${HTTP_CODE}" = "200" ] || owner_invite_fail keycloak_unavailable
  cp /tmp/kc-body /tmp/kc-realm-current.json

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

  if ! http PUT "" --data-binary @/tmp/kc-realm-smtp.json \
     || { [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; }; then
    rm -f /tmp/kc-realm-smtp.json
    owner_invite_fail smtp_rejected
  fi
  rm -f /tmp/kc-realm-smtp.json
  echo "realm smtpServer configured (${SMTP_HOST}:${SMTP_PORT}) + tetrix.smtpPassword mirrored" >&2
}

send_owner_action_email() {
  _owner_id="$1"
  if ! http GET "users/${_owner_id}" || [ "${HTTP_CODE}" != "200" ]; then
    owner_invite_fail keycloak_unavailable
  fi
  cp /tmp/kc-body /tmp/kc-owner-current.json

  if jq -e '.attributes["tetrix.ownerInviteSentAt"] // empty' \
       /tmp/kc-owner-current.json >/dev/null 2>&1; then
    echo "Owner invite already sent — skipping (tetrix.ownerInviteSentAt present)" >&2
    owner_invite_result sent already_sent
    return 0
  fi

  jq '.requiredActions = ((.requiredActions // []) + ["UPDATE_PASSWORD"] | unique)' \
    /tmp/kc-owner-current.json > /tmp/kc-owner-ra.json
  if ! http PUT "users/${_owner_id}" --data-binary @/tmp/kc-owner-ra.json \
     || { [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; }; then
    owner_invite_fail action_email_rejected
  fi

  _redirect="$(printf '%s/' "${PUBLIC_URL%/}" | jq -sRr @uri)"
  _client="${CLIENT_ID}"
  printf '%s\n' '["UPDATE_PASSWORD"]' >/tmp/kc-owner-actions.json
  if ! http PUT \
       "users/${_owner_id}/execute-actions-email?client_id=${_client}&redirect_uri=${_redirect}&lifespan=${OWNER_INVITE_LIFESPAN}" \
       --data-binary @/tmp/kc-owner-actions.json \
     || { [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; }; then
    case "${HTTP_CODE}" in
      500|502|503|504) owner_invite_fail smtp_rejected ;;
      *) owner_invite_fail action_email_rejected ;;
    esac
  fi

  _sent_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if ! http GET "users/${_owner_id}" || [ "${HTTP_CODE}" != "200" ]; then
    owner_invite_fail attribute_write_failed
  fi
  jq --arg at "${_sent_at}" \
    '.attributes = ((.attributes // {}) + {"tetrix.ownerInviteSentAt": $at})' \
    /tmp/kc-body > /tmp/kc-owner-sent.json
  if ! http PUT "users/${_owner_id}" --data-binary @/tmp/kc-owner-sent.json \
     || { [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; }; then
    owner_invite_fail attribute_write_failed
  fi
  echo "Owner action email sent (UPDATE_PASSWORD, lifespan ${OWNER_INVITE_LIFESPAN}s)" >&2
  owner_invite_result sent ""
}

find_or_create_owner() {
  _id=""
  if http GET "users?username=$(printf %s "${KEYCLOAK_OWNER_EMAIL}" | jq -sRr @uri)&exact=true" \
     && [ "${HTTP_CODE}" = "200" ]; then
    _id="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  if [ -z "${_id}" ]; then
    jq -n --arg e "${KEYCLOAK_OWNER_EMAIL}" '{
      username: $e, email: $e, enabled: true, emailVerified: true,
      firstName: "Tetrix", lastName: "Owner"
    }' >/tmp/kc-owner-create.json
    if http POST "users" --data-binary @/tmp/kc-owner-create.json \
       && [ "${HTTP_CODE}" = "201" ]; then
      _id="$(location_id /tmp/kc-hdrs)"
    else
      owner_invite_fail keycloak_unavailable
    fi
  fi
  printf '%s' "${_id}"
}

if [ "${OWNER_INVITE_ONLY}" -eq 1 ]; then
  : "${KEYCLOAK_OWNER_EMAIL:?KEYCLOAK_OWNER_EMAIL is required}"
  _ready=0
  _i=1
  while [ "${_i}" -le 30 ]; do
    if obtain_token && http GET "" && [ "${HTTP_CODE}" = "200" ]; then
      _ready=1
      break
    fi
    _i=$((_i + 1))
    sleep 2
  done
  [ "${_ready}" -eq 1 ] || owner_invite_fail keycloak_unavailable
  ensure_realm_smtp
  send_owner_action_email "$(find_or_create_owner)"
  exit 0
fi

echo "==> waiting for Keycloak admin API + realm ${REALM} at ${KC}"
ready=0
i=1
while [ "${i}" -le 90 ]; do
  if obtain_token && http GET "" && [ "${HTTP_CODE}" = "200" ]; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 5
done
if [ "${ready}" -ne 1 ]; then
  echo "ERROR: Keycloak realm discovery not ready" >&2
  echo "---- token (last) ----" >&2
  cat /tmp/kc-token.json >&2 2>/dev/null || cat /tmp/kc-token.err >&2 || true
  echo "---- realm get http=${HTTP_CODE:-?} ----" >&2
  cat /tmp/kc-body >&2 2>/dev/null || true
  exit 1
fi
echo "realm ready (issuer desired: ${ISSUER}) [fast/rest]"

echo "==> desired-state"
echo "    issuer=${ISSUER}"
echo "    audiences: res:daemon=${AUD_DAEMON} res:api=${AUD_API} res:mcp=${AUD_MCP}"
echo "    spa_client=${CLIENT_ID} redirects+=${PUBLIC_URL}${SPA_BASE}/* ${PUBLIC_URL}${SPA_BASE}/callback"
echo "    dcr.trusted_hosts=${TRUSTED_HOSTS}"
echo "    dcr.allowed_scopes=${ALLOWED_DCR_SCOPES}"

# Refresh after wait (TTL may have burned).
obtain_token || { echo "ERROR: could not refresh admin token" >&2; exit 1; }

# ------------------------------------------------------------------
# Session lifetimes + refresh rotation (architecture ADR-0017)
# (TEMPORARY — remove when deskree-inc/tetrix-iam#22 ships ALL FIVE values)
# ------------------------------------------------------------------
# The realm baked into deskree/tetrix-iam sets accessTokenLifespan=3600 (60m)
# and leaves every session window at Keycloak's defaults. Two failures follow:
#
#  1. 2026-07-25 "30-minute cliff": a 60-minute token vs the 1800s (30m) idle
#     window. The SSO idle timer only resets on token-endpoint activity, so a
#     client holding an hour-long token never refreshes in time — the session
#     idles out at 30 minutes and every later refresh fails
#     `invalid_token / "Token is not active"` (161 such errors in 24h).
#  2. ADR-0017: a closed laptop lid blows past a 30-minute idle window
#     overnight, and ssoSessionMaxLifespan (Keycloak default 36000 = 10h) kills
#     even a continuously-used session inside one workday. Reported as
#     "everything except the Admin API fails every morning" — the Admin API
#     rides a 90-day dat_ token, collectors ride this session.
#
# ADR-0017 target: 48h sliding idle, 7d absolute, refresh-token rotation on,
# 5-minute access tokens.
#
# ENFORCEMENT MODEL (ADR-0017 D2 — floors do not apply to booleans):
#   ssoSessionIdleTimeout / ssoSessionMaxLifespan : FLOOR  (raise if lower;
#       never shorten an operator's deliberately longer window)
#   accessTokenLifespan                           : SET
#   revokeRefreshToken / refreshTokenMaxReuse     : FORCED (a boolean has no
#       "longer"; leaving them operator-controlled silently disables rotation)
#
# Best-effort throughout: this runs inside a post-install/post-upgrade hook and
# must never abort provisioning over a session setting. Idempotent.
ATL_DESIRED="${ACCESS_TOKEN_LIFESPAN:-300}"
IDLE_MIN="${SSO_SESSION_IDLE_MIN:-172800}"     # 48h — ADR-0017 D1
MAX_MIN="${SSO_SESSION_MAX_MIN:-604800}"       # 7d  — ADR-0017 D1
# Reject non-numeric overrides rather than feeding them to jq --argjson.
case "${ATL_DESIRED}" in ''|*[!0-9]*) echo "WARN: ACCESS_TOKEN_LIFESPAN='${ATL_DESIRED}' is not a number — using 300" >&2; ATL_DESIRED=300 ;; esac
case "${IDLE_MIN}" in ''|*[!0-9]*) echo "WARN: SSO_SESSION_IDLE_MIN='${IDLE_MIN}' is not a number — using 172800" >&2; IDLE_MIN=172800 ;; esac
case "${MAX_MIN}" in ''|*[!0-9]*) echo "WARN: SSO_SESSION_MAX_MIN='${MAX_MIN}' is not a number — using 604800" >&2; MAX_MIN=604800 ;; esac

if http GET "" && [ "${HTTP_CODE}" = "200" ]; then
  CUR_ATL="$(jq -r '.accessTokenLifespan // empty' /tmp/kc-body 2>/dev/null || echo "")"
  CUR_IDLE="$(jq -r '.ssoSessionIdleTimeout // empty' /tmp/kc-body 2>/dev/null || echo "")"
  CUR_MAX="$(jq -r '.ssoSessionMaxLifespan // empty' /tmp/kc-body 2>/dev/null || echo "")"
  CUR_ROT="$(jq -r '.revokeRefreshToken // empty' /tmp/kc-body 2>/dev/null || echo "")"
  CUR_REUSE="$(jq -r '.refreshTokenMaxReuse // empty' /tmp/kc-body 2>/dev/null || echo "")"

  # Floor: raise only when the live value is smaller (or unreadable).
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
  # An absolute cap below the idle window makes "48h idle" a lie — the cap would
  # end the session first. Never let that stand, even if an operator set it.
  if [ "${MAX_TARGET}" -lt "${IDLE_TARGET}" ]; then
    echo "WARN: ssoSessionMaxLifespan (${MAX_TARGET}s) is below ssoSessionIdleTimeout (${IDLE_TARGET}s) — raising the cap to match; the idle window cannot outlive the session (ADR-0017 D1)" >&2
    MAX_TARGET="${IDLE_TARGET}"
  fi

  if [ "${CUR_ATL}" = "${ATL_DESIRED}" ] && [ "${CUR_IDLE}" = "${IDLE_TARGET}" ] \
     && [ "${CUR_MAX}" = "${MAX_TARGET}" ] && [ "${CUR_ROT}" = "true" ] && [ "${CUR_REUSE}" = "0" ]; then
    echo "realm session settings already accessTokenLifespan=${CUR_ATL}s idle=${CUR_IDLE}s max=${CUR_MAX}s rotation=on reuse=0"
  elif jq -n --arg realm "${REALM}" --argjson atl "${ATL_DESIRED}" \
        --argjson idle "${IDLE_TARGET}" --argjson max "${MAX_TARGET}" \
        '{realm: $realm, accessTokenLifespan: $atl, ssoSessionIdleTimeout: $idle,
          ssoSessionMaxLifespan: $max, revokeRefreshToken: true, refreshTokenMaxReuse: 0}' \
        >/tmp/kc-realm-tokens.json 2>/dev/null; then
    # Partial representation: Keycloak applies only the fields present (verified
    # 2026-07-25 — all 103 other realm fields byte-identical after the PUT).
    if http PUT "" --data-binary @/tmp/kc-realm-tokens.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "realm session settings -> accessTokenLifespan=${ATL_DESIRED}s idle=${IDLE_TARGET}s max=${MAX_TARGET}s rotation=on reuse=0 (was ${CUR_ATL:-?}s/${CUR_IDLE:-?}s/${CUR_MAX:-?}s/rotation=${CUR_ROT:-?}/reuse=${CUR_REUSE:-?})"
    else
      echo "WARN: could not set realm session settings (http=${HTTP_CODE}) — sessions may expire early; see tetrix-iam#22" >&2
    fi
  else
    echo "WARN: could not build the realm session-settings payload — skipping (see tetrix-iam#22)" >&2
  fi
else
  echo "WARN: could not read realm for the session-settings check (http=${HTTP_CODE}) — skipping" >&2
fi

# ADR-0017 D1: a client-level session cap silently falsifies the realm window —
# the realm reads 48h while the SPA's own sessions die sooner. ASSERT only: warn
# loudly, never rewrite a client someone deliberately tuned.
#
# access.token.lifespan is checked with the same shape but is NOT session death:
# a shorter access token only means more frequent refreshes. It still earns a
# warning because the SPA renews inside a fixed 60s skew (RENEW_SKEW_S in
# keycloakClient.ts), so a client ATL at or under that skew makes every single
# call renew — and with rotation on (revokeRefreshToken=true,
# refreshTokenMaxReuse=0) that churn is exactly what races the single-flight
# renew into a reuse collision, which Keycloak answers by killing the WHOLE
# session (review follow-up, 2026-07-28).
SPA_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-tetrix-frontend}"
FE_RENEW_SKEW_S=60
if http GET "clients?clientId=${SPA_CLIENT_ID}" && [ "${HTTP_CODE}" = "200" ]; then
  for attr in client.session.idle.timeout client.session.max.lifespan access.token.lifespan; do
    VAL="$(jq -r --arg a "${attr}" '.[0].attributes[$a] // empty' /tmp/kc-body 2>/dev/null || echo "")"
    case "${VAL}" in
      ''|'0') : ;;  # unset or 0 => inherits the realm, which is what we want
      *[!0-9]*) echo "WARN: ${SPA_CLIENT_ID} ${attr}='${VAL}' is not numeric — cannot verify it against the realm window (ADR-0017 D1)" >&2 ;;
      *)
        LIMIT="${IDLE_TARGET:-$IDLE_MIN}"
        [ "${attr}" = "client.session.max.lifespan" ] && LIMIT="${MAX_TARGET:-$MAX_MIN}"
        [ "${attr}" = "access.token.lifespan" ] && LIMIT="${ATL_DESIRED}"
        if [ "${VAL}" -lt "${LIMIT}" ]; then
          if [ "${attr}" = "access.token.lifespan" ]; then
            echo "WARN: ${SPA_CLIENT_ID} sets ${attr}=${VAL}s, SHORTER than the realm's ${LIMIT}s — the SPA will refresh more often than intended (ADR-0017 D1). Clear it (unset/0) or raise it." >&2
            if [ "${VAL}" -le "${FE_RENEW_SKEW_S}" ]; then
              echo "WARN: ${SPA_CLIENT_ID} ${attr}=${VAL}s is at or under the SPA's ${FE_RENEW_SKEW_S}s renew skew — every call will trigger a renew, and the resulting rotation churn can collide with itself and end the session (ADR-0017 D1/D3b)." >&2
            fi
          else
            echo "WARN: ${SPA_CLIENT_ID} sets ${attr}=${VAL}s, SHORTER than the realm's ${LIMIT}s — SPA sessions will end early and the realm setting is misleading (ADR-0017 D1). Clear it (unset/0) or raise it." >&2
          fi
        fi
        ;;
    esac
  done
else
  echo "WARN: could not read client ${SPA_CLIENT_ID} for the session-override check (http=${HTTP_CODE}) — skipping" >&2
fi

# ------------------------------------------------------------------
# Anonymous DCR policies (best-effort)
# ------------------------------------------------------------------
if http GET "components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
  && [ "${HTTP_CODE}" = "200" ]; then
  cp /tmp/kc-body /tmp/dcr-components.json

  TH_ID="$(jq -r '.[] | select(.providerId=="trusted-hosts" and .subType=="anonymous") | .id' /tmp/dcr-components.json | head -n1)"
  if [ -n "${TH_ID}" ] && [ "${TH_ID}" != "null" ] && [ -n "${TRUSTED_HOSTS}" ]; then
    TH_JSON="$(printf '%s\n' "${TRUSTED_HOSTS}" | words_to_json_array)"
    jq --arg id "${TH_ID}" --argjson hosts "${TH_JSON}" \
      '.[] | select(.id==$id)
       | .config["trusted-hosts"]=$hosts
       | .config["host-sending-registration-request-must-match"]=["false"]
       | .config["client-uris-must-match"]=["true"]' \
      /tmp/dcr-components.json >/tmp/kc-th.json
    if http PUT "components/${TH_ID}" --data-binary @/tmp/kc-th.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "PUT trusted-hosts -> ok (${TH_ID})"
    else
      echo "WARN: trusted-hosts update failed http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  else
    echo "WARN: skipping trusted-hosts (id='${TH_ID}' hosts='${TRUSTED_HOSTS}')"
  fi

  SC_ID="$(jq -r '.[] | select(.providerId=="allowed-client-templates" and .subType=="anonymous") | .id' /tmp/dcr-components.json | head -n1)"
  if [ -n "${SC_ID}" ] && [ "${SC_ID}" != "null" ] && [ -n "${ALLOWED_DCR_SCOPES}" ]; then
    SC_JSON="$(printf '%s\n' "${ALLOWED_DCR_SCOPES}" | words_to_json_array)"
    jq --arg id "${SC_ID}" --argjson scopes "${SC_JSON}" \
      '.[] | select(.id==$id)
       | .config["allowed-client-scopes"]=$scopes
       | .config["allow-default-scopes"]=["true"]' \
      /tmp/dcr-components.json >/tmp/kc-sc.json
    if http PUT "components/${SC_ID}" --data-binary @/tmp/kc-sc.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "PUT allowed-client-scopes -> ok (${SC_ID})"
    else
      echo "WARN: allowed-client-scopes update failed http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  else
    echo "WARN: skipping allowed-client-scopes (id='${SC_ID}')"
  fi
else
  echo "WARN: could not list DCR policy components — skipping DCR PUT (http=${HTTP_CODE:-?})" >&2
fi

# ------------------------------------------------------------------
# Client scopes (one list; refresh after creates)
# ------------------------------------------------------------------
SCOPE_JSON="/tmp/kc-client-scopes.json"
client_scopes_refresh() {
  if http GET "client-scopes" && [ "${HTTP_CODE}" = "200" ]; then
    cp /tmp/kc-body "${SCOPE_JSON}"
    return 0
  fi
  return 1
}
client_scope_id() {
  jq -r --arg n "$1" '.[] | select(.name==$n) | .id' "${SCOPE_JSON}" | head -n1
}
client_scopes_refresh || echo "WARN: could not list client-scopes" >&2

# ------------------------------------------------------------------
# OIDC built-in scopes email / profile
# ------------------------------------------------------------------
ensure_scope_mapper() {
  _scope_id="$1"
  _mname="$2"
  _body="$3"
  if http GET "client-scopes/${_scope_id}/protocol-mappers/models" && [ "${HTTP_CODE}" = "200" ] \
    && jq -e --arg n "${_mname}" 'map(select(.name==$n)) | length > 0' /tmp/kc-body >/dev/null 2>&1; then
    return 0
  fi
  if http POST "client-scopes/${_scope_id}/protocol-mappers/models" --data-binary @"${_body}" \
    && [ "${HTTP_CODE}" = "201" ]; then
    echo "  mapper += ${_mname}"
  else
    echo "WARN: could not create mapper ${_mname} http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
  fi
}

ensure_oidc_builtin_scope() {
  _scope_name="$1"
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    jq -n --arg n "${_scope_name}" '{
      name: $n,
      description: ("OpenID Connect built-in scope: " + $n),
      protocol: "openid-connect",
      attributes: {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "true"
      }
    }' >/tmp/kc-oidc-scope.json
    if http POST "client-scopes" --data-binary @/tmp/kc-oidc-scope.json && [ "${HTTP_CODE}" = "201" ]; then
      _sid="$(location_id /tmp/kc-hdrs)"
      echo "CREATE client-scope ${_scope_name} id=${_sid}"
      client_scopes_refresh || true
    else
      echo "WARN: could not create client scope ${_scope_name} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      return 0
    fi
  else
    echo "client-scope ${_scope_name} already exists id=${_sid}"
  fi

  case "${_scope_name}" in
    email)
      jq -n '{name:"email",protocol:"openid-connect",protocolMapper:"oidc-usermodel-property-mapper",consentRequired:false,config:{"user.attribute":"email","claim.name":"email","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
        >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${_sid}" email /tmp/kc-oidc-mapper.json
      jq -n '{name:"email verified",protocol:"openid-connect",protocolMapper:"oidc-usermodel-property-mapper",consentRequired:false,config:{"user.attribute":"emailVerified","claim.name":"email_verified","jsonType.label":"boolean","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
        >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${_sid}" "email verified" /tmp/kc-oidc-mapper.json
      ;;
    profile)
      jq -n '{name:"username",protocol:"openid-connect",protocolMapper:"oidc-usermodel-property-mapper",consentRequired:false,config:{"user.attribute":"username","claim.name":"preferred_username","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
        >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${_sid}" username /tmp/kc-oidc-mapper.json
      jq -n '{name:"given name",protocol:"openid-connect",protocolMapper:"oidc-usermodel-property-mapper",consentRequired:false,config:{"user.attribute":"firstName","claim.name":"given_name","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
        >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${_sid}" "given name" /tmp/kc-oidc-mapper.json
      jq -n '{name:"family name",protocol:"openid-connect",protocolMapper:"oidc-usermodel-property-mapper",consentRequired:false,config:{"user.attribute":"lastName","claim.name":"family_name","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
        >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${_sid}" "family name" /tmp/kc-oidc-mapper.json
      jq -n '{name:"full name",protocol:"openid-connect",protocolMapper:"oidc-full-name-mapper",consentRequired:false,config:{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
        >/tmp/kc-oidc-mapper.json
      ensure_scope_mapper "${_sid}" "full name" /tmp/kc-oidc-mapper.json
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
# ------------------------------------------------------------------
ensure_mcp_write_scope() {
  _scope_name="$1"
  _scope_desc="$2"
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -n "${_sid}" ] && [ "${_sid}" != "null" ]; then
    echo "client-scope ${_scope_name} already exists id=${_sid}"
    return 0
  fi
  echo "client-scope ${_scope_name} absent from realm ${REALM} -- creating"
  jq -n --arg n "${_scope_name}" --arg d "${_scope_desc}" '{
    name: $n,
    description: $d,
    protocol: "openid-connect",
    attributes: {
      "include.in.token.scope": "true",
      "display.on.consent.screen": "false"
    }
  }' >/tmp/kc-mcp-write-scope.json
  if http POST "client-scopes" --data-binary @/tmp/kc-mcp-write-scope.json \
    && [ "${HTTP_CODE}" = "201" ]; then
    _sid="$(location_id /tmp/kc-hdrs)"
    echo "CREATE client-scope ${_scope_name} id=${_sid}"
    client_scopes_refresh || true
  else
    echo "WARN: could not create client scope ${_scope_name} http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
  fi
}

echo "==> ensuring MCP write client scopes (hitl:write)"
ensure_mcp_write_scope hitl:write \
  "Mutate human-in-the-loop questions over MCP: answer/route/dismiss/decline (collectors ADR-0057). User-bounded; the MCP server still enforces org membership and the per-tool scope check."

# ------------------------------------------------------------------
# tetrix-dcr-default-scopes ClientRegistrationPolicy components (#208)
# ------------------------------------------------------------------
# iam#42 ships a ClientRegistrationPolicy SPI whose afterRegister re-attaches the
# configured default scopes to every DCR client INSIDE the registration transaction —
# the fix for clients born `default: [basic]` whenever the RFC 7591 request carries a
# `scope` member (upstream Keycloak #50807; measured in collectors#493). The jar is
# INERT until the realm carries its policy component: this section is the activation
# the iam#42 PR body named as the deliberately-excluded chart follow-up.
#
# Both registration subtypes get one: `anonymous` covers self-registering MCP clients
# (claude.ai, Claude Code, Cursor), `authenticated` covers initial-access-token /
# bearer registrations — so neither path can be born wrong.
#
# Runs AFTER ensure_mcp_write_scope so hitl:write exists in the realm before a
# component references it (#189 was the missing-scope dependency; the SPI itself
# skips absent scopes non-fatally, but a fresh run should never rely on that).
#
# Idempotent + drift-correcting: an existing component (matched by providerId+subType,
# never by name) is re-PUT with the desired config rather than trusted — same
# convention as the collectors M2M sub mapper below. On an image WITHOUT the SPI
# (pre tetrix-iam sha-7503768) the POST answers 400 "Invalid provider type or no such
# provider": WARN-and-continue, never fail the stack — the keycloak-dcr-scope-repair
# loop still heals those stacks after the fact (provider README, tetrix-iam
# providers/dcr-default-scopes). A 409 from a provisioning race is already-exists,
# not failure.
ensure_dcr_default_scopes_component() {
  _sub="$1"
  _def_json="$(printf '%s\n' "${DCR_ENSURE_DEFAULT_SCOPES}" | words_to_json_array)"
  _opt_json="$(printf '%s\n' "${DCR_ENSURE_OPTIONAL_SCOPES}" | words_to_json_array)"

  if ! http GET "" || [ "${HTTP_CODE}" != "200" ]; then
    echo "WARN: could not read the realm for the dcr-default-scopes component (http=${HTTP_CODE}) — skipping ${_sub}" >&2
    return 0
  fi
  _realm_id="$(jq -r '.id // empty' /tmp/kc-body 2>/dev/null || echo "")"
  if [ -z "${_realm_id}" ]; then
    echo "WARN: realm id unreadable — skipping the dcr-default-scopes component (${_sub})" >&2
    return 0
  fi

  if ! http GET "components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
    || [ "${HTTP_CODE}" != "200" ]; then
    echo "WARN: could not list ClientRegistrationPolicy components (http=${HTTP_CODE}) — skipping dcr-default-scopes (${_sub})" >&2
    return 0
  fi
  _existing_id="$(jq -r --arg sub "${_sub}" \
    '.[] | select(.providerId=="tetrix-dcr-default-scopes" and .subType==$sub) | .id' \
    /tmp/kc-body 2>/dev/null | head -n1)"

  _atl_prefix_json="$(printf '%s\n' "${DCR_ATL_REDIRECT_PREFIXES}" | words_to_json_array)"
  # ADR-0027 D1: the lifespan exception belongs to the ANONYMOUS registration path only.
  # The authenticated subtype gets the scope config and an empty lifespan, so an
  # authenticated DCR registration can never inherit the longer bearer even if the SPI
  # gate were removed. Defense in depth with DcrDefaultScopesPolicy.isLifespanEligible.
  if [ "${_sub}" = "anonymous" ]; then
    _sub_atl="${DCR_ACCESS_TOKEN_LIFESPAN}"
  else
    _sub_atl=""
  fi
  if ! jq -n --arg sub "${_sub}" --arg parent "${_realm_id}" \
    --arg atl "${_sub_atl}" \
    --argjson def "${_def_json}" --argjson opt "${_opt_json}" \
    --argjson atlpfx "${_atl_prefix_json}" '{
    name: ("tetrix-dcr-default-scopes-" + $sub),
    providerId: "tetrix-dcr-default-scopes",
    providerType: "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy",
    subType: $sub,
    parentId: $parent,
    config: {
      "ensure-default-scopes": $def,
      "ensure-optional-scopes": $opt,
      "access-token-lifespan": (if $atl == "" or $atl == "0" then [] else [$atl] end),
      "access-token-lifespan-redirect-prefixes": (if $atl == "" or $atl == "0" then [] else $atlpfx end)
    }
  }' >/tmp/kc-dcr-default-scopes.json 2>/dev/null; then
    echo "WARN: could not build the dcr-default-scopes component payload (${_sub}) — skipping" >&2
    return 0
  fi

  if [ -n "${_existing_id}" ] && [ "${_existing_id}" != "null" ]; then
    # Re-assert the desired config on every run so a hand-edited or drifted component
    # is corrected rather than trusted (the M2M sub mapper's reasoning).
    if ! jq --arg id "${_existing_id}" '. + {id: $id}' /tmp/kc-dcr-default-scopes.json \
      >/tmp/kc-dcr-default-scopes-put.json 2>/dev/null; then
      echo "WARN: could not build the dcr-default-scopes re-assert payload (${_sub}) — skipping" >&2
      return 0
    fi
    if http PUT "components/${_existing_id}" --data-binary @/tmp/kc-dcr-default-scopes-put.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "dcr-default-scopes component (${_sub}) re-asserted (${_existing_id})"
    else
      echo "WARN: could not re-assert the dcr-default-scopes component (${_sub}) http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
    return 0
  fi

  if http POST "components" --data-binary @/tmp/kc-dcr-default-scopes.json \
    && [ "${HTTP_CODE}" = "201" ]; then
    echo "CREATE dcr-default-scopes component (${_sub}): defaults [${DCR_ENSURE_DEFAULT_SCOPES}] optional [${DCR_ENSURE_OPTIONAL_SCOPES}]"
    return 0
  fi
  case "${HTTP_CODE}" in
    400)
      # Pre-SPI image: Keycloak has no such provider. Not fatal — DCR clients on this
      # stack keep being born [basic]-only and the keycloak-dcr-scope-repair loop keeps
      # healing them after the fact. Fixed by repinning keycloak.image.tag to
      # sha-7503768 or later, never by failing the release.
      echo "WARN: dcr-default-scopes component (${_sub}) rejected http=400 — the tetrix-iam image predates the SPI (iam#42, sha-7503768+). DCR clients stay born [basic]-only until keycloak.image.tag is repinned; the dcr-scope-repair loop still heals them post-birth." >&2
      cat /tmp/kc-body >&2 || true
      ;;
    409)
      echo "dcr-default-scopes component (${_sub}) already exists (http=409) — leaving it"
      ;;
    *)
      echo "WARN: could not create the dcr-default-scopes component (${_sub}) http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      ;;
  esac
  return 0
}

echo "==> ensuring tetrix-dcr-default-scopes policy components (anonymous + authenticated)"
ensure_dcr_default_scopes_component anonymous
ensure_dcr_default_scopes_component authenticated

# ------------------------------------------------------------------
# Realm defaultDefaultClientScopes
# ------------------------------------------------------------------
echo "==> ensuring realm defaultDefaultClientScopes (basic res:mcp graph:read)"
ensure_realm_default_scope() {
  _scope_name="$1"
  if http GET "default-default-client-scopes" && [ "${HTTP_CODE}" = "200" ] \
    && jq -e --arg n "${_scope_name}" 'map(select(.name==$n)) | length > 0' /tmp/kc-body >/dev/null 2>&1; then
    echo "realm default-default-client-scopes already has ${_scope_name}"
    return 0
  fi
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    echo "WARN: client scope ${_scope_name} not found — skip realm default" >&2
    return 0
  fi
  if http PUT "default-default-client-scopes/${_sid}" \
    && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; }; then
    echo "realm default-default-client-scopes += ${_scope_name}"
  else
    echo "WARN: could not add realm default scope ${_scope_name} http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
  fi
}
ensure_realm_default_scope basic
ensure_realm_default_scope res:mcp
ensure_realm_default_scope graph:read

# ------------------------------------------------------------------
# DCR MCP scope repair (Keycloak #50807 / KC 26.1.4)
# ------------------------------------------------------------------
echo "==> repairing MCP scopes on anonymous DCR clients (graph:read res:mcp)"
ensure_client_default_scope() {
  _client_uuid="$1"
  _scope_name="$2"
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    return 0
  fi
  http DELETE "clients/${_client_uuid}/optional-client-scopes/${_sid}" || true
  http PUT "clients/${_client_uuid}/default-client-scopes/${_sid}" -d '' \
    || http POST "clients/${_client_uuid}/default-client-scopes/${_sid}" -d '' \
    || grep -qiE 'already|Conflict|exists' /tmp/kc-body 2>/dev/null
}
ensure_client_optional_scope() {
  _client_uuid="$1"
  _scope_name="$2"
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    return 0
  fi
  http PUT "clients/${_client_uuid}/optional-client-scopes/${_sid}" -d '' \
    || http POST "clients/${_client_uuid}/optional-client-scopes/${_sid}" -d '' \
    || grep -qiE 'already|Conflict|exists' /tmp/kc-body 2>/dev/null
}
remove_client_default_scope() {
  _client_uuid="$1"
  _scope_name="$2"
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    return 0
  fi
  http DELETE "clients/${_client_uuid}/default-client-scopes/${_sid}" || true
}
ensure_mcp_scopes_on_dcr_clients() {
  if ! http GET "clients?max=500" || [ "${HTTP_CODE}" != "200" ]; then
    echo "WARN: could not list clients for DCR MCP scope repair http=${HTTP_CODE}" >&2
    return 0
  fi
  jq -c '.[] | select(.publicClient==true and .standardFlowEnabled==true and (.serviceAccountsEnabled|not))
    | select(.clientId|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    | select(.clientId as $c | ["tetrix-frontend","tetrix-admin-api","tetrix-account-verify","wellclaudecode000001"] | index($c) | not)' \
    /tmp/kc-body | while read -r row; do
    _uuid="$(echo "${row}" | jq -r '.id')"
    _cid="$(echo "${row}" | jq -r '.clientId')"
    ensure_client_default_scope "${_uuid}" basic
    ensure_client_default_scope "${_uuid}" res:mcp
    ensure_client_default_scope "${_uuid}" graph:read
    # Write scopes must be DEFAULTS: a generic MCP client only requests what the resource
    # advertises (graph:read), so an optional write scope is never asked for and every MCP
    # write tool 403s. Still user-bounded — authorization-code flow + the server's own
    # org/per-tool checks (ADR-0057 §3). Both scopes now exist in the realm — hitl:write is
    # created above (#189), so this line is no longer the silent no-op it was.
    ensure_client_default_scope "${_uuid}" sessions:write
    ensure_client_default_scope "${_uuid}" hitl:write
    ensure_client_optional_scope "${_uuid}" offline_access
    echo "DCR MCP scopes repaired client=${_cid}"
  done
}
ensure_mcp_scopes_on_dcr_clients

# ------------------------------------------------------------------
# Audience mappers
# ------------------------------------------------------------------
patch_scope_audience() {
  _scope_name="$1"
  _aud_value="$2"
  _safe_name="aud-$(echo "${_scope_name}" | tr ':' '-')"
  _sid="$(client_scope_id "${_scope_name}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    echo "WARN: client scope ${_scope_name} not found — skip audience patch" >&2
    return 0
  fi
  if ! http GET "client-scopes/${_sid}/protocol-mappers/models" || [ "${HTTP_CODE}" != "200" ]; then
    echo "WARN: could not list mappers for ${_scope_name}" >&2
    return 0
  fi
  cp /tmp/kc-body /tmp/kc-scope-mappers.json
  _mapper_id="$(jq -r '.[] | select(.protocolMapper=="oidc-audience-mapper") | .id' /tmp/kc-scope-mappers.json | head -n1)"
  _mapper_name="$(jq -r '.[] | select(.protocolMapper=="oidc-audience-mapper") | .name // empty' /tmp/kc-scope-mappers.json | head -n1)"
  [ -n "${_mapper_name}" ] || _mapper_name="${_safe_name}"

  if [ -z "${_mapper_id}" ] || [ "${_mapper_id}" = "null" ]; then
    jq -n --arg n "${_mapper_name}" --arg a "${_aud_value}" '{
      name: $n,
      protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      config: {
        "included.custom.audience": $a,
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    }' >/tmp/kc-aud-mapper.json
    if http POST "client-scopes/${_sid}/protocol-mappers/models" --data-binary @/tmp/kc-aud-mapper.json \
      && [ "${HTTP_CODE}" = "201" ]; then
      echo "CREATE ${_scope_name} audience mapper -> ${_aud_value}"
      return 0
    fi
    echo "ERROR: failed to create oidc-audience-mapper on ${_scope_name} http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
    return 1
  fi
  jq -n --arg id "${_mapper_id}" --arg n "${_mapper_name}" --arg a "${_aud_value}" '{
    id: $id,
    name: $n,
    protocol: "openid-connect",
    protocolMapper: "oidc-audience-mapper",
    config: {
      "included.custom.audience": $a,
      "access.token.claim": "true",
      "id.token.claim": "false"
    }
  }' >/tmp/kc-aud-mapper.json
  if http PUT "client-scopes/${_sid}/protocol-mappers/models/${_mapper_id}" --data-binary @/tmp/kc-aud-mapper.json \
    && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
    echo "PATCH ${_scope_name} audience -> ${_aud_value}"
  else
    echo "ERROR: failed to patch ${_scope_name} audience http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
    return 1
  fi
}

echo "==> patching res:* audience mappers"
patch_scope_audience "res:daemon" "${AUD_DAEMON}"
patch_scope_audience "res:api" "${AUD_API}"
patch_scope_audience "res:mcp" "${AUD_MCP}"
patch_scope_audience "graph:read" "${AUD_MCP}"

# ------------------------------------------------------------------
# groups mapper (ADR-0016: DCR MCP tokens need org membership)
#
# Needed on res:mcp AND graph:read, for exactly the reason patch_scope_audience is applied
# to both above: a cloud connector that sends an RFC 7591 `scope` at DCR (claude.ai,
# chatgpt.com) makes Keycloak drop the realm-default res:mcp from the registered client, so
# a res:mcp-only groups mapper never fires for them. Their token then carries no `groups`
# claim and the MCP server — multi-tenant via TETRIX_MCP_AUTH_ORG_IDENTITY — rejects the
# call with 400 "organization context required" BEFORE any tool runs. graph:read is the one
# scope every MCP client does request (it is what our PRM advertises in scopes_supported),
# so stamping groups there covers them. graph:read is MCP-only, so daemon/api/frontend
# tokens are unaffected. Cursor (omits `scope`, keeps res:mcp) is unchanged either way.
# ------------------------------------------------------------------
ensure_groups_mapper() {
  _scope="$1"
  _sid="$(client_scope_id "${_scope}")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    echo "WARN: client scope ${_scope} not found — skip groups mapper" >&2
    return 0
  fi
  _mapper_name="groups"
  jq -n '{
    name: "groups",
    protocol: "openid-connect",
    protocolMapper: "oidc-group-membership-mapper",
    config: {
      "full.path": "true",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups",
      "userinfo.token.claim": "true"
    }
  }' >/tmp/kc-groups-mapper.json
  ensure_scope_mapper "${_sid}" "${_mapper_name}" /tmp/kc-groups-mapper.json
}
echo "==> ensuring groups mappers on res:mcp + graph:read (DCR MCP org tenancy)"
ensure_groups_mapper res:mcp
ensure_groups_mapper graph:read

# ------------------------------------------------------------------
# res:api collector-admin script mapper
# ------------------------------------------------------------------
ensure_collector_admin_mapper() {
  _sid="$(client_scope_id "res:api")"
  if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
    echo "WARN: client scope res:api not found — skip collector:admin mapper" >&2
    return 0
  fi
  _mapper_name="collector-admin-if-entitled"
  if ! http GET "client-scopes/${_sid}/protocol-mappers/models" || [ "${HTTP_CODE}" != "200" ]; then
    echo "WARN: could not list res:api protocol-mappers" >&2
    return 0
  fi
  if jq -e --arg n "${_mapper_name}" 'map(select(.name==$n)) | length > 0' /tmp/kc-body >/dev/null 2>&1; then
    echo "res:api protocol-mapper ${_mapper_name} already present"
    return 0
  fi
  jq -n --arg n "${_mapper_name}" '{
    name: $n,
    protocol: "openid-connect",
    protocolMapper: "script-append-collector-admin-if-entitled.js",
    config: {
      "access.token.claim": "true",
      "id.token.claim": "false",
      "userinfo.token.claim": "false",
      "claim.name": "tetrix_collector_admin_gate",
      "jsonType.label": "String"
    }
  }' >/tmp/kc-collector-admin-mapper.json
  if http POST "client-scopes/${_sid}/protocol-mappers/models" --data-binary @/tmp/kc-collector-admin-mapper.json \
    && [ "${HTTP_CODE}" = "201" ]; then
    echo "res:api protocol-mapper += ${_mapper_name}"
  else
    echo "WARN: could not create ${_mapper_name} on res:api (image may lack script — bump keycloak.image.tag) http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
  fi
}
ensure_collector_admin_mapper

# ------------------------------------------------------------------
# SPA client (GET-merge-PUT so we do not wipe client fields)
# ------------------------------------------------------------------
echo "==> ensuring ${CLIENT_ID} redirectUris + webOrigins for ${PUBLIC_URL}"
SPA_UUID=""
if http GET "clients?clientId=${CLIENT_ID}" && [ "${HTTP_CODE}" = "200" ]; then
  SPA_UUID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
fi
if [ -n "${SPA_UUID}" ]; then
  REDIR_BASE="${PUBLIC_URL}${SPA_BASE}"
  if http GET "clients/${SPA_UUID}" && [ "${HTTP_CODE}" = "200" ]; then
    # Default loopback globs + PUBLIC_URL (may already include :port for port-forward).
    # EXTRA_REDIRECT_URIS is space-separated (chart values keycloak.provision.redirectUris).
    jq --arg a "${REDIR_BASE}/*" --arg b "${REDIR_BASE}/callback" --arg o "${PUBLIC_URL}" --arg extras "${EXTRA_REDIRECT_URIS}" '
      ($extras | split(" ") | map(select(length > 0))) as $extra
      | .redirectUris = ([$a, $b, "http://localhost/*", "http://127.0.0.1/*", "http://localhost:18080/*", "http://localhost:18080/callback", "http://127.0.0.1:18080/*", "http://127.0.0.1:18080/callback"] + $extra | unique)
      | .webOrigins = ([$o, "http://localhost:18080", "http://127.0.0.1:18080", "+"] | unique)
    ' /tmp/kc-body >/tmp/kc-spa-client.json
    if http PUT "clients/${SPA_UUID}" --data-binary @/tmp/kc-spa-client.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "SPA redirects -> ${REDIR_BASE}/* + callback"
    else
      echo "WARN: SPA redirectUri update failed http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  fi

  ensure_default_scope() {
    _scope_name="$1"
    _sid="$(client_scope_id "${_scope_name}")"
    if [ -z "${_sid}" ] || [ "${_sid}" = "null" ]; then
      echo "WARN: client scope ${_scope_name} not found" >&2
      return 0
    fi
    http DELETE "clients/${SPA_UUID}/optional-client-scopes/${_sid}" >/dev/null 2>&1 || true
    if http PUT "clients/${SPA_UUID}/default-client-scopes/${_sid}" \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "409" ]; }; then
      echo "SPA default-client-scopes += ${_scope_name}"
    else
      echo "WARN: could not add ${_scope_name} as default client scope http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
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
# SPA Owner bootstrap
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
if [ -n "${OWNER_EMAIL}" ] && { [ -n "${OWNER_PW}" ] || owner_invite_mode; }; then
  # Realm SMTP FIRST: execute-actions-email below has nowhere to send until the
  # realm knows its mail server.
  ensure_realm_smtp
  echo "==> ensuring SPA Owner user ${OWNER_EMAIL} (platform_admin)"
  OWNER_ID=""
  if http GET "users?username=$(printf %s "${OWNER_EMAIL}" | jq -sRr @uri)&exact=true" \
    && [ "${HTTP_CODE}" = "200" ]; then
    OWNER_ID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  CREATED=0
  if [ -z "${OWNER_ID}" ]; then
    jq -n --arg e "${OWNER_EMAIL}" '{
      username: $e, email: $e, enabled: true, emailVerified: true,
      firstName: "Tetrix", lastName: "Owner"
    }' >/tmp/kc-owner-create.json
    if http POST "users" --data-binary @/tmp/kc-owner-create.json && [ "${HTTP_CODE}" = "201" ]; then
      OWNER_ID="$(location_id /tmp/kc-hdrs)"
      CREATED=1
      echo "created Owner user id=${OWNER_ID}"
    else
      echo "ERROR: failed to create Owner user http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  else
    echo "Owner user already exists id=${OWNER_ID}"
  fi
  if [ "${CREATED}" -eq 1 ] && [ -n "${OWNER_PW}" ]; then
    jq -n --arg p "${OWNER_PW}" '{type:"password", value:$p, temporary:false}' >/tmp/kc-owner-pw.json
    if ! http PUT "users/${OWNER_ID}/reset-password" --data-binary @/tmp/kc-owner-pw.json \
      || { [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; }; then
      echo "ERROR: failed to set Owner password http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  elif owner_invite_mode; then
    echo "email-invite mode: leaving the Owner without a preset credential" >&2
  fi

  if http GET "roles/platform_admin" && [ "${HTTP_CODE}" = "200" ]; then
    jq '[.]' /tmp/kc-body >/tmp/kc-owner-roles.json
    if http POST "users/${OWNER_ID}/role-mappings/realm" --data-binary @/tmp/kc-owner-roles.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "409" ]; }; then
      echo "Owner realm role platform_admin ensured"
    else
      echo "WARN: add-roles platform_admin failed http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  else
    echo "WARN: realm role platform_admin not found" >&2
  fi

  ensure_child_group() {
    _parent_id="$1"
    _child_name="$2"
    if http GET "groups/${_parent_id}/children" && [ "${HTTP_CODE}" = "200" ]; then
      _existing="$(jq -r --arg n "${_child_name}" '.[] | select(.name==$n) | .id' /tmp/kc-body | head -n1)"
      if [ -n "${_existing}" ] && [ "${_existing}" != "null" ]; then
        printf '%s\n' "${_existing}"
        return 0
      fi
    fi
    jq -n --arg n "${_child_name}" '{name:$n}' >/tmp/kc-group-create.json
    if http POST "groups/${_parent_id}/children" --data-binary @/tmp/kc-group-create.json \
      && [ "${HTTP_CODE}" = "201" ]; then
      location_id /tmp/kc-hdrs
      return 0
    fi
    echo "ERROR: failed to create group child ${_child_name} under ${_parent_id} http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
    return 1
  }

  ORGS_ID=""
  if http GET "groups?search=orgs" && [ "${HTTP_CODE}" = "200" ]; then
    ORGS_ID="$(jq -r '.[] | select(.name=="orgs") | .id' /tmp/kc-body | head -n1)"
  fi
  if [ -z "${ORGS_ID}" ] || [ "${ORGS_ID}" = "null" ]; then
    printf '%s\n' '{"name":"orgs"}' >/tmp/kc-orgs-create.json
    if http POST "groups" --data-binary @/tmp/kc-orgs-create.json && [ "${HTTP_CODE}" = "201" ]; then
      ORGS_ID="$(location_id /tmp/kc-hdrs)"
    else
      ORGS_ID=""
    fi
  fi

  # REMOVED (#235, ADR-0009 D6): this used to take `head -n1` of /orgs' children as the Owner's
  # organization when the id was unset — measured adopting a uuid a tester had invented one
  # command earlier. The org is never inferred from list order; a blank id means "not my job".

  if [ -n "${OWNER_ORG_ID}" ] && [ -n "${ORGS_ID}" ]; then
    echo "==> ensuring Owner org groups /orgs/${OWNER_ORG_ID}/{admins,members}"
    ORG_NODE_ID="$(ensure_child_group "${ORGS_ID}" "${OWNER_ORG_ID}" || true)"
    if [ -n "${ORG_NODE_ID}" ]; then
      ensure_child_group "${ORG_NODE_ID}" "members" >/dev/null || true
      ADMINS_ID="$(ensure_child_group "${ORG_NODE_ID}" "admins" || true)"
      if [ -n "${ADMINS_ID}" ]; then
        if http PUT "users/${OWNER_ID}/groups/${ADMINS_ID}" \
          && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
          echo "Owner added to /orgs/${OWNER_ORG_ID}/admins"
        else
          echo "WARN: join Owner to admins group failed http=${HTTP_CODE}" >&2
          cat /tmp/kc-body >&2 || true
        fi
      fi
    fi
  elif [ -z "${OWNER_ORG_ID}" ]; then
    echo "==> /orgs ensured; Owner org membership is keycloak-owner-org-sync's job — it validates the id against the daemon organizations table first (#235)"
  else
    echo "WARN: could not ensure /orgs group — skipping Owner org membership" >&2
  fi

  if http GET "users/${OWNER_ID}" && [ "${HTTP_CODE}" = "200" ]; then
    jq '.firstName="Tetrix" | .lastName="Owner"' /tmp/kc-body >/tmp/kc-owner-name.json
    if ! http PUT "users/${OWNER_ID}" --data-binary @/tmp/kc-owner-name.json \
      || { [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; }; then
      echo "WARN: could not set Owner first/last name http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  fi

  # LAST, after roles and org membership: an Owner who follows the link before
  # they are a platform_admin in an org lands on a no-org SPA.
  if owner_invite_mode; then
    send_owner_action_email "${OWNER_ID}"
  fi
else
  echo "==> skipping SPA Owner seed (KEYCLOAK_OWNER_EMAIL/PASSWORD unset)"
fi

# ------------------------------------------------------------------
# admin-api confidential client
# ------------------------------------------------------------------
ADMIN_API_CLIENT_ID="${KEYCLOAK_ADMIN_API_CLIENT_ID:-}"
ADMIN_API_CLIENT_SECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET:-}"
if [ -n "${ADMIN_API_CLIENT_ID}" ] && [ -n "${ADMIN_API_CLIENT_SECRET}" ]; then
  echo "==> ensuring confidential client ${ADMIN_API_CLIENT_ID} + realm-management roles"
  ADMIN_API_UUID=""
  if http GET "clients?clientId=${ADMIN_API_CLIENT_ID}" && [ "${HTTP_CODE}" = "200" ]; then
    ADMIN_API_UUID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  if [ -z "${ADMIN_API_UUID}" ]; then
    jq -n --arg id "${ADMIN_API_CLIENT_ID}" --arg s "${ADMIN_API_CLIENT_SECRET}" '{
      clientId: $id, enabled: true, publicClient: false, serviceAccountsEnabled: true,
      standardFlowEnabled: false, directAccessGrantsEnabled: false, implicitFlowEnabled: false,
      fullScopeAllowed: true, secret: $s
    }' >/tmp/kc-admin-api-create.json
    if http POST "clients" --data-binary @/tmp/kc-admin-api-create.json && [ "${HTTP_CODE}" = "201" ]; then
      ADMIN_API_UUID="$(location_id /tmp/kc-hdrs)"
      echo "created client ${ADMIN_API_CLIENT_ID} id=${ADMIN_API_UUID}"
    else
      echo "ERROR: failed to create client ${ADMIN_API_CLIENT_ID} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  else
    echo "client ${ADMIN_API_CLIENT_ID} already exists id=${ADMIN_API_UUID}"
  fi

  if http GET "clients/${ADMIN_API_UUID}" && [ "${HTTP_CODE}" = "200" ]; then
    jq --arg s "${ADMIN_API_CLIENT_SECRET}" '
      .publicClient=false
      | .serviceAccountsEnabled=true
      | .standardFlowEnabled=false
      | .directAccessGrantsEnabled=false
      | .implicitFlowEnabled=false
      | .fullScopeAllowed=true
      | .secret=$s
    ' /tmp/kc-body >/tmp/kc-admin-api-secret.json
    if http PUT "clients/${ADMIN_API_UUID}" --data-binary @/tmp/kc-admin-api-secret.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "synced client secret + fullScopeAllowed for ${ADMIN_API_CLIENT_ID}"
    else
      echo "WARN: failed to sync client secret for ${ADMIN_API_CLIENT_ID} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  fi

  SA_USERNAME="service-account-${ADMIN_API_CLIENT_ID}"
  SA_ID=""
  if http GET "users?username=$(printf %s "${SA_USERNAME}" | jq -sRr @uri)&exact=true" \
    && [ "${HTTP_CODE}" = "200" ]; then
    SA_ID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  RM_UUID=""
  if http GET "clients?clientId=realm-management" && [ "${HTTP_CODE}" = "200" ]; then
    RM_UUID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  if [ -n "${SA_ID}" ] && [ -n "${RM_UUID}" ]; then
    for ROLE in manage-users view-users query-users query-groups manage-realm view-realm; do
      if http GET "clients/${RM_UUID}/roles/${ROLE}" && [ "${HTTP_CODE}" = "200" ]; then
        jq '[.]' /tmp/kc-body >/tmp/kc-sa-role.json
        if http POST "users/${SA_ID}/role-mappings/clients/${RM_UUID}" --data-binary @/tmp/kc-sa-role.json \
          && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "409" ]; }; then
          echo "service-account realm-management += ${ROLE}"
        else
          echo "WARN: could not assign realm-management/${ROLE} to ${SA_USERNAME} http=${HTTP_CODE}" >&2
          cat /tmp/kc-body >&2 || true
        fi
      else
        echo "WARN: realm-management role ${ROLE} not found" >&2
      fi
    done
  else
    echo "WARN: service-account or realm-management client missing (sa='${SA_ID}' rm='${RM_UUID}')" >&2
  fi
else
  echo "==> skipping admin-api client seed (KEYCLOAK_ADMIN_API_CLIENT_ID/SECRET unset)"
fi

# ------------------------------------------------------------------
# admin-api -> collectors M2M client (collectors ADR-0087 / architecture ADR-0023 D3)
#
# A SEPARATE client from the admin-api Admin-REST one above, for two independent
# reasons: this one needs the sub=client_id script mapper that collectors' is_m2m
# contract requires, and that mapper calls token.setSubject UNCONDITIONALLY while
# Admin REST resolves the acting service-account user BY sub -- sharing one client
# would break HttpKeycloakAdmin, which deletes the Keycloak user in the very same
# offboard route. They also need opposite fullScopeAllowed (true above; false here,
# single audience for M2M).
# ------------------------------------------------------------------
COLL_M2M_CLIENT_ID="${KEYCLOAK_COLLECTORS_M2M_CLIENT_ID:-}"
COLL_M2M_CLIENT_SECRET="${KEYCLOAK_COLLECTORS_M2M_SECRET:-}"
COLL_M2M_SCOPE="${KEYCLOAK_COLLECTORS_M2M_SCOPE:-collector:identity:offboard}"
if [ -n "${COLL_M2M_CLIENT_ID}" ] && [ -n "${COLL_M2M_CLIENT_SECRET}" ]; then
  echo "==> ensuring collectors M2M client ${COLL_M2M_CLIENT_ID}"

  # CREATE the offboard scope when the realm lacks it -- do not fail.
  #
  # The tetrix-iam realm import is the declarative source for FRESH installs, but
  # Keycloak's --import-realm does NOT re-import into a realm that already exists, so an
  # upgraded install never receives a newly added scope. This chart already learned that
  # (docs/changelog.d/2026-07-28-mcp-dcr-groups-mapper-provision.md: "realm import alone
  # does not patch existing scopes") and answered it by making provisioning patch the
  # live realm. Aborting here instead would fail this post-install/post-upgrade hook and
  # therefore the whole helm release -- and skip every later provisioning step.
  client_scopes_refresh || true
  COLL_M2M_SCOPE_UUID="$(client_scope_id "${COLL_M2M_SCOPE}")"
  if [ -z "${COLL_M2M_SCOPE_UUID}" ] || [ "${COLL_M2M_SCOPE_UUID}" = "null" ]; then
    echo "client-scope ${COLL_M2M_SCOPE} absent from realm ${REALM} -- creating"
    jq -n --arg n "${COLL_M2M_SCOPE}" '{
      name: $n,
      description: "Cross-owner identity mapping cleanup for account offboarding (collectors ADR-0087). Service credentials only.",
      protocol: "openid-connect",
      attributes: {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    }' >/tmp/kc-coll-m2m-scope.json
    if http POST "client-scopes" --data-binary @/tmp/kc-coll-m2m-scope.json \
      && [ "${HTTP_CODE}" = "201" ]; then
      COLL_M2M_SCOPE_UUID="$(location_id /tmp/kc-hdrs)"
      echo "CREATE client-scope ${COLL_M2M_SCOPE} id=${COLL_M2M_SCOPE_UUID}"
      client_scopes_refresh || true
    else
      echo "ERROR: could not create client scope ${COLL_M2M_SCOPE} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  fi

  # res:api is NOT safe to synthesise: it carries the collectors audience mapper, and a
  # bare scope of that name would mint a token the frozen verifier rejects on aud. It has
  # shipped in both realm imports since Wave 1, so its absence means this is not a tetrix
  # realm -- WARN and skip the credential rather than fail the release over it.
  RES_API_SCOPE_UUID="$(client_scope_id "res:api")"
  if [ -z "${RES_API_SCOPE_UUID}" ] || [ "${RES_API_SCOPE_UUID}" = "null" ]; then
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

  COLL_M2M_UUID=""
  if http GET "clients?clientId=${COLL_M2M_CLIENT_ID}" && [ "${HTTP_CODE}" = "200" ]; then
    COLL_M2M_UUID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  if [ -z "${COLL_M2M_UUID}" ]; then
    jq -n --arg id "${COLL_M2M_CLIENT_ID}" --arg s "${COLL_M2M_CLIENT_SECRET}" '{
      clientId: $id,
      name: "Tetrix admin-api -> collectors (ADR-0087 identity offboard)",
      enabled: true, publicClient: false, serviceAccountsEnabled: true,
      standardFlowEnabled: false, directAccessGrantsEnabled: false, implicitFlowEnabled: false,
      fullScopeAllowed: false, secret: $s,
      attributes: {
        "access.token.signed.response.alg": "ES384",
        "use.refresh.tokens": "false",
        "client_credentials.use_refresh_token": "false"
      }
    }' >/tmp/kc-coll-m2m-create.json
    if http POST "clients" --data-binary @/tmp/kc-coll-m2m-create.json && [ "${HTTP_CODE}" = "201" ]; then
      COLL_M2M_UUID="$(location_id /tmp/kc-hdrs)"
      echo "created client ${COLL_M2M_CLIENT_ID} id=${COLL_M2M_UUID}"
    else
      echo "ERROR: failed to create client ${COLL_M2M_CLIENT_ID} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  else
    echo "client ${COLL_M2M_CLIENT_ID} already exists id=${COLL_M2M_UUID}"
  fi

  # Re-sync secret + flags so a rotated chart Secret takes effect on upgrade. ES384 is
  # not optional: the collectors verifier pins it (tetrix_auth/verifier.py, frozen).
  if http GET "clients/${COLL_M2M_UUID}" && [ "${HTTP_CODE}" = "200" ]; then
    jq --arg s "${COLL_M2M_CLIENT_SECRET}" '
      .publicClient=false
      | .serviceAccountsEnabled=true
      | .standardFlowEnabled=false
      | .directAccessGrantsEnabled=false
      | .implicitFlowEnabled=false
      | .fullScopeAllowed=false
      | .secret=$s
      | .attributes=((.attributes // {}) + {
          "access.token.signed.response.alg": "ES384",
          "use.refresh.tokens": "false",
          "client_credentials.use_refresh_token": "false"
        })
    ' /tmp/kc-body >/tmp/kc-coll-m2m-sync.json
    if http PUT "clients/${COLL_M2M_UUID}" --data-binary @/tmp/kc-coll-m2m-sync.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "synced secret + ES384 + flags for ${COLL_M2M_CLIENT_ID}"
    else
      echo "WARN: failed to sync ${COLL_M2M_CLIENT_ID} http=${HTTP_CODE} -- the Keycloak" >&2
      echo "      client may still hold a STALE secret, in which case admin-api's token" >&2
      echo "      request returns invalid_client and every offboard answers 503." >&2
      cat /tmp/kc-body >&2 || true
    fi
  else
    # Not silent: without this read we cannot push the chart's secret, so a rotated
    # Secret never reaches Keycloak and admin-api authenticates with a value the client
    # no longer has.
    echo "WARN: could not read client ${COLL_M2M_CLIENT_ID} (http=${HTTP_CODE}) -- skipped" >&2
    echo "      the secret/ES384 re-sync. If the chart Secret was rotated, offboards will" >&2
    echo "      fail with invalid_client until this succeeds." >&2
  fi

  # sub=client_id mapper. Without it collectors' is_m2m is FALSE (client_id != sub), the
  # caller is treated as human, and require_service refuses it -- so the credential would
  # verify and still be rejected.
  #
  # Matched by NAME and then repaired, not merely detected by provider type: a mapper of
  # the right provider with the wrong config (e.g. access.token.claim=false, or a
  # different claim.name) produces exactly the same "already present" verdict while the
  # token still carries the service-account UUID as sub. Re-PUT the desired config
  # whenever it exists so a drifted mapper is corrected rather than trusted.
  COLL_M2M_MAPPER_UUID=""
  if http GET "clients/${COLL_M2M_UUID}/protocol-mappers/models" && [ "${HTTP_CODE}" = "200" ]; then
    COLL_M2M_MAPPER_UUID="$(jq -r '
      [.[] | select(.protocolMapper == "script-sub-equals-client-id.js")][0].id // empty
    ' /tmp/kc-body)"
  fi
  if [ -n "${COLL_M2M_MAPPER_UUID}" ]; then
    jq -n --arg id "${COLL_M2M_MAPPER_UUID}" '{
      id: $id,
      name: "m2m-sub-and-client-id",
      protocol: "openid-connect",
      protocolMapper: "script-sub-equals-client-id.js",
      config: {
        "claim.name": "client_id",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "userinfo.token.claim": "false"
      }
    }' >/tmp/kc-coll-m2m-mapper-fix.json
    if http PUT "clients/${COLL_M2M_UUID}/protocol-mappers/models/${COLL_M2M_MAPPER_UUID}" \
      --data-binary @/tmp/kc-coll-m2m-mapper-fix.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "sub=client_id mapper present on ${COLL_M2M_CLIENT_ID}, config re-asserted"
    else
      echo "ERROR: sub=client_id mapper exists on ${COLL_M2M_CLIENT_ID} but its config could" >&2
      echo "       not be corrected (http=${HTTP_CODE}). A drifted mapper leaves sub as the" >&2
      echo "       service-account UUID, so is_m2m is false and every offboard is refused." >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  else
    jq -n '{
      name: "m2m-sub-and-client-id",
      protocol: "openid-connect",
      protocolMapper: "script-sub-equals-client-id.js",
      config: {
        "claim.name": "client_id",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "userinfo.token.claim": "false"
      }
    }' >/tmp/kc-coll-m2m-mapper.json
    if http POST "clients/${COLL_M2M_UUID}/protocol-mappers/models" \
      --data-binary @/tmp/kc-coll-m2m-mapper.json \
      && { [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "409" ]; }; then
      echo "added sub=client_id mapper to ${COLL_M2M_CLIENT_ID}"
    else
      echo "ERROR: failed to add sub=client_id mapper http=${HTTP_CODE}" >&2
      echo "       The tetrix-iam image must ship the scripts provider and have" >&2
      echo "       feature scripts enabled; without the mapper the credential is" >&2
      echo "       verified but refused as a non-m2m principal." >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  fi

  # DEFAULT (not optional) scopes: a client_credentials grant that names no scope gets
  # only the defaults, so the credential must work without asking for anything.
  #
  # The DELETE from optional-client-scopes first is load-bearing, not tidying. Keycloak
  # treats a scope as EITHER default or optional, and PUT .../default-client-scopes/<id>
  # on a scope already assigned as OPTIONAL is a silent no-op (verified against
  # quay.io/keycloak/keycloak:26.1.4). Without this, a client that pre-exists with the
  # offboard scope optional -- from an older chart, a hand-edit, or the realm import
  # changing shape -- keeps it optional forever, and a grant naming no scope then omits
  # it, so every offboard 403s while provisioning reports success.
  for SCOPE_PAIR in "res:api ${RES_API_SCOPE_UUID}" "${COLL_M2M_SCOPE} ${COLL_M2M_SCOPE_UUID}"; do
    SCOPE_NAME="${SCOPE_PAIR% *}"
    SCOPE_UUID="${SCOPE_PAIR##* }"
    http DELETE "clients/${COLL_M2M_UUID}/optional-client-scopes/${SCOPE_UUID}" || true
    if http PUT "clients/${COLL_M2M_UUID}/default-client-scopes/${SCOPE_UUID}" \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "409" ]; }; then
      echo "default scope ${SCOPE_NAME} assigned to ${COLL_M2M_CLIENT_ID}"
    else
      echo "ERROR: failed to assign ${SCOPE_NAME} to ${COLL_M2M_CLIENT_ID} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  done

  # Prune every OTHER scope off this client. A client created through the Admin API
  # inherits the realm's defaultDefaultClientScopes (basic, res:mcp, graph:read here),
  # which the realm-import client avoids only because its JSON lists defaultClientScopes
  # explicitly. Leaving them is not cosmetic: `res:mcp` is an AUDIENCE selector, so the
  # credential mints aud=["https://<host>/mcp","https://<host>/api-collectors"] -- a
  # multi-audience M2M token, which breaks the frozen single-string-aud contract AND
  # hands admin-api's offboard credential a valid MCP audience. Measured against a live
  # Keycloak, not hypothetical.
  #
  # `basic` is kept: it carries the stock sub/auth_time mappers and is not an audience.
  # Optional scopes are pruned too -- this credential must not be able to ASK for more
  # than it needs.
  for SCOPE_KIND in default optional; do
    if http GET "clients/${COLL_M2M_UUID}/${SCOPE_KIND}-client-scopes" && [ "${HTTP_CODE}" = "200" ]; then
      jq -r --arg keep "${COLL_M2M_SCOPE}" '
        .[] | select(.name != "basic" and .name != "res:api" and .name != $keep)
        | "\(.name) \(.id)"
      ' /tmp/kc-body >/tmp/kc-coll-m2m-prune.txt
      while read -r PRUNE_NAME PRUNE_UUID; do
        [ -n "${PRUNE_UUID}" ] || continue
        if http DELETE "clients/${COLL_M2M_UUID}/${SCOPE_KIND}-client-scopes/${PRUNE_UUID}" \
          && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "404" ]; }; then
          echo "pruned inherited ${SCOPE_KIND} scope ${PRUNE_NAME} from ${COLL_M2M_CLIENT_ID}"
        else
          echo "ERROR: could not prune ${SCOPE_KIND} scope ${PRUNE_NAME} from" >&2
          echo "       ${COLL_M2M_CLIENT_ID} http=${HTTP_CODE}. Leaving it would give the" >&2
          echo "       credential a second audience or an unintended capability." >&2
          cat /tmp/kc-body >&2 || true
          exit 1
        fi
      done </tmp/kc-coll-m2m-prune.txt
    fi
  done
fi

# ------------------------------------------------------------------
# account password-verify confidential client (ADR-0015)
# ------------------------------------------------------------------
PASSWORD_VERIFY_CLIENT_ID="${KEYCLOAK_PASSWORD_VERIFY_CLIENT_ID:-}"
PASSWORD_VERIFY_CLIENT_SECRET="${KEYCLOAK_PASSWORD_VERIFY_CLIENT_SECRET:-}"
if [ -n "${PASSWORD_VERIFY_CLIENT_ID}" ] && [ -n "${PASSWORD_VERIFY_CLIENT_SECRET}" ]; then
  echo "==> ensuring confidential client ${PASSWORD_VERIFY_CLIENT_ID} (password-grant verify)"
  PASSWORD_VERIFY_UUID=""
  if http GET "clients?clientId=${PASSWORD_VERIFY_CLIENT_ID}" && [ "${HTTP_CODE}" = "200" ]; then
    PASSWORD_VERIFY_UUID="$(jq -r '.[0].id // empty' /tmp/kc-body)"
  fi
  if [ -z "${PASSWORD_VERIFY_UUID}" ]; then
    jq -n --arg id "${PASSWORD_VERIFY_CLIENT_ID}" --arg s "${PASSWORD_VERIFY_CLIENT_SECRET}" '{
      clientId: $id, enabled: true, publicClient: false, serviceAccountsEnabled: false,
      standardFlowEnabled: false, directAccessGrantsEnabled: true, implicitFlowEnabled: false,
      fullScopeAllowed: false, secret: $s
    }' >/tmp/kc-password-verify-create.json
    if http POST "clients" --data-binary @/tmp/kc-password-verify-create.json && [ "${HTTP_CODE}" = "201" ]; then
      PASSWORD_VERIFY_UUID="$(location_id /tmp/kc-hdrs)"
      echo "created client ${PASSWORD_VERIFY_CLIENT_ID} id=${PASSWORD_VERIFY_UUID}"
    else
      echo "ERROR: failed to create client ${PASSWORD_VERIFY_CLIENT_ID} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
      exit 1
    fi
  else
    echo "client ${PASSWORD_VERIFY_CLIENT_ID} already exists id=${PASSWORD_VERIFY_UUID}"
  fi

  if http GET "clients/${PASSWORD_VERIFY_UUID}" && [ "${HTTP_CODE}" = "200" ]; then
    jq --arg s "${PASSWORD_VERIFY_CLIENT_SECRET}" '
      .publicClient=false
      | .serviceAccountsEnabled=false
      | .standardFlowEnabled=false
      | .directAccessGrantsEnabled=true
      | .implicitFlowEnabled=false
      | .fullScopeAllowed=false
      | .secret=$s
    ' /tmp/kc-body >/tmp/kc-password-verify-secret.json
    if http PUT "clients/${PASSWORD_VERIFY_UUID}" --data-binary @/tmp/kc-password-verify-secret.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "synced client secret + DAG flags for ${PASSWORD_VERIFY_CLIENT_ID}"
    else
      echo "WARN: failed to sync client secret for ${PASSWORD_VERIFY_CLIENT_ID} http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  fi
else
  echo "==> skipping password-verify client seed (KEYCLOAK_PASSWORD_VERIFY_CLIENT_ID/SECRET unset)"
fi

# VERIFY_PROFILE
if http GET "authentication/required-actions/VERIFY_PROFILE" && [ "${HTTP_CODE}" = "200" ]; then
  jq '.enabled=false | .defaultAction=false' /tmp/kc-body >/tmp/kc-vp-upd.json
  if http PUT "authentication/required-actions/VERIFY_PROFILE" --data-binary @/tmp/kc-vp-upd.json \
    && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
    echo "VERIFY_PROFILE required action disabled"
  else
    echo "WARN: could not disable VERIFY_PROFILE http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
  fi
fi

# UPDATE_EMAIL (ADR-0018): register if still unregistered (KC leaves preview
# required-actions unregistered until Admin API register-required-action), then
# enable AIA + Force Email Verification. Realm verifyEmail stays false.
# Config key is verifyEmail on the required-action object (the /config subpath
# returns "RequiredAction is not configurable" on KC 26.1).
if ! http GET "authentication/required-actions/UPDATE_EMAIL" || [ "${HTTP_CODE}" != "200" ]; then
  if http GET "authentication/unregistered-required-actions" && [ "${HTTP_CODE}" = "200" ] \
    && jq -e '.[] | select(.providerId=="UPDATE_EMAIL")' /tmp/kc-body >/dev/null 2>&1; then
    printf '%s\n' '{"providerId":"UPDATE_EMAIL","name":"Update Email"}' >/tmp/kc-ue-reg.json
    if http POST "authentication/register-required-action" --data-binary @/tmp/kc-ue-reg.json \
      && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; }; then
      echo "UPDATE_EMAIL required action registered"
    else
      echo "WARN: could not register UPDATE_EMAIL http=${HTTP_CODE}" >&2
      cat /tmp/kc-body >&2 || true
    fi
  else
    echo "WARN: UPDATE_EMAIL required action missing (enable KC feature update-email?)" >&2
  fi
fi
if http GET "authentication/required-actions/UPDATE_EMAIL" && [ "${HTTP_CODE}" = "200" ]; then
  jq '.enabled=true | .defaultAction=false | .config = ((.config // {}) + {"verifyEmail":"true"})' \
    /tmp/kc-body >/tmp/kc-ue-upd.json
  if http PUT "authentication/required-actions/UPDATE_EMAIL" --data-binary @/tmp/kc-ue-upd.json \
    && { [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; }; then
    echo "UPDATE_EMAIL enabled + forceEmailVerification (verifyEmail=true)"
  else
    echo "WARN: could not enable/configure UPDATE_EMAIL http=${HTTP_CODE}" >&2
    cat /tmp/kc-body >&2 || true
  fi
fi

PROVISION_END="$(date +%s 2>/dev/null || echo 0)"
if [ "${PROVISION_START}" != "0" ] && [ "${PROVISION_END}" != "0" ]; then
  echo "==> provision complete (fast/rest) in $((PROVISION_END - PROVISION_START))s"
else
  echo "==> provision complete (fast/rest)"
fi
