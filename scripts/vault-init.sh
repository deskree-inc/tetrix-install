#!/usr/bin/env sh
# Idempotent Vault bootstrap for local Compose (Helm vault-init Job twin).
# Writes VAULT_UNSEAL_KEY / VAULT_ROOT_TOKEN / COLLECTORS_VAULT_TOKEN to OUT_FILE, the
# collectors-api ONBOARDING profile to API_OUT_FILE (collectors#553 — see the block at the end),
# and the READ-ONLY profile to READ_OUT_FILE (collectors#603 — the healthcheck's, and any other
# profile that only ever resolves a credential to use it).
#
# Cloud (TETRIX_DEPLOYMENT_MODE=cloud) is a different contract: generate-local-secrets.py
# already initialized Vault with Cloud KMS auto-unseal and revoked the bootstrap root.
# This script must not `vault operator init` and must not write VAULT_UNSEAL_KEY. It waits
# for auto-unseal and hands off the collectors token(s) from the rendered runtime env into
# all three files compose mounts. keep_broker_token() below is the Shamir/dev path only
# and must stay byte-identical to templates/vault-init-job.yaml (assert-vault-init-idempotent).
set -eu
# Everything this script writes is key material. 077 first, before any file is
# created, so a race between `>` and `chmod` cannot expose it.
umask 077

export VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
OUT="${OUT_FILE:-/out/vault.env}"
API_OUT="${API_OUT_FILE:-/out/vault-api.env}"
READ_OUT="${READ_OUT_FILE:-/out/vault-read.env}"
EXISTING="${EXISTING_ENV:-/out/existing.env}"
KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
TOKEN_PERIOD="${VAULT_TOKEN_PERIOD:-768h}"
CHILD_MAX_TTL="${VAULT_CHILD_MAX_TTL:-600}"
DEPLOY_MODE="${TETRIX_DEPLOYMENT_MODE:-dev}"
WAIT_ATTEMPTS="${VAULT_INIT_WAIT_ATTEMPTS:-90}"
WAIT_SLEEP="${VAULT_INIT_WAIT_SLEEP:-2}"

# ── Cloud: this script must NOT initialize Vault ───────────────────────────────
# In cloud mode generate-local-secrets.py already initialized Vault with Cloud KMS
# auto-unseal, wrote the allowlisted KV set, configured GCP auth for this VM's
# identity, and revoked the bootstrap root token. A second `vault operator init`
# here would fail; worse, the Shamir path would mint an unseal key and write it to
# a file, which is precisely the persistent seal material auto-unseal exists to
# avoid. So cloud waits for auto-unseal and hands off the collectors token it was
# given — it never produces one, and it never writes an unseal key.
#
# Wave B (2/3): plan's early-exit wrote only vault.env. Main's compose mounts
# vault.env (worker), vault-api.env (API) and vault-read.env (healthcheck). The
# cloud runtime allowlist has COLLECTORS_VAULT_TOKEN only; optional
# COLLECTORS_API_VAULT_TOKEN / COLLECTORS_WEBHOOK_VAULT_TOKEN are used if already
# in the environment and are never invented. Mapping matches the Shamir comments
# below: worker unprefixed VAULT_TOKEN = webhook broker; API = reader +
# onboarding; read = reader. One token is copied into all three slots.
if [ "$DEPLOY_MODE" = "cloud" ]; then
  i=0
  st=1
  while [ "$i" -lt "$WAIT_ATTEMPTS" ]; do
    set +e
    vault status >/dev/null 2>&1
    st=$?
    set -e
    [ "$st" -eq 0 ] && break
    i=$((i + 1))
    sleep "$WAIT_SLEEP"
  done
  if [ "$st" -ne 0 ]; then
    echo "tetrix_vault_bootstrap_failed" >&2
    echo "vault did not auto-unseal at $VAULT_ADDR" >&2
    exit 1
  fi
  : "${COLLECTORS_VAULT_TOKEN:?COLLECTORS_VAULT_TOKEN must come from the rendered runtime env in cloud mode}"
  # Do not invent tokens. Distinct brokers only when the runtime env already has them.
  COLLECTORS_API_VAULT_TOKEN="${COLLECTORS_API_VAULT_TOKEN:-$COLLECTORS_VAULT_TOKEN}"
  COLLECTORS_WEBHOOK_VAULT_TOKEN="${COLLECTORS_WEBHOOK_VAULT_TOKEN:-$COLLECTORS_VAULT_TOKEN}"

  write_cloud_file() { # $1 = path
    chmod 600 "$1"
    echo "wrote $1"
  }

  tmp="${OUT}.tmp"
  {
    printf 'COLLECTORS_VAULT_TOKEN=%s\n' "$COLLECTORS_VAULT_TOKEN"
    printf 'COLLECTORS_API_VAULT_TOKEN=%s\n' "$COLLECTORS_API_VAULT_TOKEN"
    printf 'COLLECTORS_WEBHOOK_VAULT_TOKEN=%s\n' "$COLLECTORS_WEBHOOK_VAULT_TOKEN"
    # Worker profile — same mapping as the Shamir block at the end of this file:
    # unprefixed VAULT_TOKEN is the webhook broker. Cloud has one token today.
    printf 'VAULT_TOKEN=%s\n' "$COLLECTORS_WEBHOOK_VAULT_TOKEN"
    printf 'VAULT_KV_MOUNT=%s\n' "$KV_MOUNT"
    if [ -n "${VAULT_TOKEN_MOUNT_ACCESSOR:-}" ]; then
      printf 'VAULT_TOKEN_MOUNT_ACCESSOR=%s\n' "$VAULT_TOKEN_MOUNT_ACCESSOR"
    fi
    printf 'VAULT_TENANT_TOKEN_ROLE=%s\n' "tetrix-collector-tenant"
    printf 'VAULT_WEBHOOK_TOKEN_ROLE=%s\n' "tetrix-collector-webhook"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$OUT"
  write_cloud_file "$OUT"

  tmp="${API_OUT}.tmp"
  {
    printf 'VAULT_TOKEN=%s\n' "$COLLECTORS_VAULT_TOKEN"
    printf 'VAULT_KV_MOUNT=%s\n' "$KV_MOUNT"
    if [ -n "${VAULT_TOKEN_MOUNT_ACCESSOR:-}" ]; then
      printf 'VAULT_TOKEN_MOUNT_ACCESSOR=%s\n' "$VAULT_TOKEN_MOUNT_ACCESSOR"
    fi
    printf 'VAULT_TENANT_TOKEN_ROLE=%s\n' "tetrix-collector-tenant"
    printf 'VAULT_ONBOARDING_TOKEN=%s\n' "$COLLECTORS_API_VAULT_TOKEN"
    printf 'VAULT_ONBOARDING_TOKEN_ROLE=%s\n' "tetrix-onboarding"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$API_OUT"
  write_cloud_file "$API_OUT"

  tmp="${READ_OUT}.tmp"
  {
    printf 'VAULT_TOKEN=%s\n' "$COLLECTORS_VAULT_TOKEN"
    printf 'VAULT_KV_MOUNT=%s\n' "$KV_MOUNT"
    if [ -n "${VAULT_TOKEN_MOUNT_ACCESSOR:-}" ]; then
      printf 'VAULT_TOKEN_MOUNT_ACCESSOR=%s\n' "$VAULT_TOKEN_MOUNT_ACCESSOR"
    fi
    printf 'VAULT_TENANT_TOKEN_ROLE=%s\n' "tetrix-collector-tenant"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$READ_OUT"
  write_cloud_file "$READ_OUT"
  echo "vault is initialized and auto-unsealed; wrote the collectors token handoff (3 files)"
  exit 0
fi

if [ -f "$EXISTING" ]; then
  # shellcheck disable=SC1090
  . "$EXISTING"
fi

i=0
while [ "$i" -lt 90 ]; do
  set +e
  vault status >/dev/null 2>&1
  st=$?
  set -e
  # 0 = unsealed, 2 = sealed — API is up either way
  if [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; then
    break
  fi
  i=$((i + 1))
  sleep 2
done

set +e
vault status >/dev/null 2>&1
st=$?
set -e
if [ "$st" -eq 1 ]; then
  echo "vault API not reachable at $VAULT_ADDR" >&2
  exit 1
fi

if ! vault status | grep -q 'Initialized.*true'; then
  echo "initializing vault (1 key share)"
  out=$(vault operator init -key-shares=1 -key-threshold=1)
  VAULT_UNSEAL_KEY=$(echo "$out" | awk '/Unseal Key 1:/ {print $NF}')
  VAULT_ROOT_TOKEN=$(echo "$out" | awk '/Initial Root Token:/ {print $NF}')
  [ -n "$VAULT_UNSEAL_KEY" ] && [ -n "$VAULT_ROOT_TOKEN" ] || {
    echo "init parse failed" >&2
    exit 1
  }
fi
: "${VAULT_UNSEAL_KEY:?no unseal key — vault was initialized outside this stack}"
: "${VAULT_ROOT_TOKEN:?no root token — vault was initialized outside this stack}"

if vault status | grep -q 'Sealed.*true'; then
  vault operator unseal "$VAULT_UNSEAL_KEY" >/dev/null
  echo "unsealed"
fi
export VAULT_TOKEN="$VAULT_ROOT_TOKEN"

if ! vault secrets list | grep -q "^${KV_MOUNT}/"; then
  vault secrets enable -path="$KV_MOUNT" -version=2 kv
  echo "mounted kv-v2 at ${KV_MOUNT}/"
fi

# ══ least-privilege policies (ADR-0033 §3 + amendment A1; collectors#553) ══
#
# This file is the Compose twin of templates/vault-init-job.yaml and must stay byte-equivalent
# in POLICY, so read the long explanation there. In one paragraph: this used to write ONE
# policy granting create/read/update/delete over "${KV_MOUNT}/data/*" — every tenant AND
# platform/* — and hand the resulting non-expiring token to every collector. MEASURED on
# hashicorp/vault:1.21.4: cross-tenant read and WRITE both succeeded, platform read succeeded,
# and `kv list ${KV_MOUNT}/tenants/` enumerated the customer list.
#
# Swapping in the narrow policies alone would have been WORSE: they are templated on the
# calling identity, and a token created with -orphan -no-default-policy has no identity
# entity, so the template resolves to nothing and the collectors are denied their OWN secrets.
# Hence the broker wiring below.
#
# SOURCE OF TRUTH: tetrix-collectors deploy/vault/policies/*.hcl (their render_policies.sh
# performs the same mount substitution).
vault policy write tenant-read - <<EOF
path "${KV_MOUNT}/data/tenants/{{identity.entity.metadata.owner}}/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/tenants/{{identity.entity.metadata.owner}}/*" {
  capabilities = ["read", "list"]
}
EOF
vault policy write onboarding-write - <<EOF
path "${KV_MOUNT}/data/tenants/{{identity.entity.metadata.owner}}/*" {
  capabilities = ["create", "update", "patch", "read"]
}
# NO \`delete\` on metadata/: on KV v2 that permanently removes every version AND the
# metadata, unrecoverably (\`undelete\` is withheld). The soft delete is the delete/ endpoint.
path "${KV_MOUNT}/metadata/tenants/{{identity.entity.metadata.owner}}/*" {
  capabilities = ["create", "update", "read", "list"]
}
path "${KV_MOUNT}/delete/tenants/{{identity.entity.metadata.owner}}/*" {
  capabilities = ["update"]
}
EOF
# collectors#597 — the WORKER's narrow write scope. ADR-0072 Lane 2 puts `register_webhook` in
# the worker saga, where it mints an HMAC signing secret and must PERSIST it; under the brokered
# wiring the worker holds only `read` there, and because ADR-0072 D3 makes registration DEGRADE
# rather than fail, the hook is created at the source anyway while this install records
# `hook_id: null, provisioned: false` — a live orphaned webhook signing deliveries with a secret
# we do not hold. Source credentials at tenants/<owner>/<source_type>/<instance> are NOT matched.
vault policy write webhook-write - <<EOF
path "${KV_MOUNT}/data/tenants/{{identity.entity.metadata.owner}}/webhooks/*" {
  capabilities = ["create", "update", "read"]
}
path "${KV_MOUNT}/metadata/tenants/{{identity.entity.metadata.owner}}/webhooks/*" {
  capabilities = ["create", "update", "read", "list"]
}
path "${KV_MOUNT}/delete/tenants/{{identity.entity.metadata.owner}}/webhooks/*" {
  capabilities = ["update"]
}
EOF
# Installed but attached to NO collector role.
vault policy write platform-read - <<EOF
path "${KV_MOUNT}/data/platform/*"     { capabilities = ["read", "list"] }
path "${KV_MOUNT}/metadata/platform/*" { capabilities = ["read", "list"] }
EOF

# ══ the wiring: per-tenant tokens minted at resolve time ══
# The `token/` mount's accessor. Extracted by its `auth_token_` PREFIX rather than by
# position inside the JSON: `vault auth list -format=json` is pretty-printed multi-line and
# the token/ object nests a `config` object, so a positional sed silently matched nothing —
# which is why this is checked for emptiness immediately below instead of being trusted.
# Exactly one token auth mount can exist, so the prefix is unambiguous. No jq/python in the
# hashicorp/vault image; tr+grep+sed only.
TOKEN_ACCESSOR=$(vault auth list -format=json | tr -d " \n" |
  grep -o '"accessor":"auth_token_[^"]*"' | head -n 1 | sed 's/.*:"//; s/"$//')
[ -n "$TOKEN_ACCESSOR" ] || {
  echo "could not resolve the token auth accessor" >&2
  exit 1
}

# allowed_policies is load-bearing: a reader broker can only ever mint tenant-read, so no
# compromised worker can reach a write or destroy capability in any tenant.
vault write auth/token/roles/tetrix-collector-tenant \
  allowed_policies=tenant-read disallowed_policies=default \
  allowed_entity_aliases='tenant-*' orphan=true renewable=false \
  token_explicit_max_ttl="$CHILD_MAX_TTL" >/dev/null
vault write auth/token/roles/tetrix-onboarding \
  allowed_policies=onboarding-write disallowed_policies=default \
  allowed_entity_aliases='tenant-*' orphan=true renewable=false \
  token_explicit_max_ttl="$CHILD_MAX_TTL" >/dev/null
vault write auth/token/roles/tetrix-collector-webhook \
  allowed_policies=webhook-write disallowed_policies=default \
  allowed_entity_aliases='tenant-*' orphan=true renewable=false \
  token_explicit_max_ttl="$CHILD_MAX_TTL" >/dev/null

vault policy write tetrix-collectors-broker - <<'EOF'
path "auth/token/create/tetrix-collector-tenant" { capabilities = ["update"] }
path "identity/entity"        { capabilities = ["create", "update"] }
path "identity/entity/name/*" { capabilities = ["read"] }
path "identity/entity-alias"  { capabilities = ["create", "update"] }
EOF
# collectors#597 — a THIRD broker, for the WORKER alone. Deliberately not folded into
# tetrix-collectors-broker, which dispatcher/mcp/relay/session-consumer share.
vault policy write tetrix-webhook-broker - <<'EOF'
path "auth/token/create/tetrix-collector-tenant"  { capabilities = ["update"] }
path "auth/token/create/tetrix-collector-webhook" { capabilities = ["update"] }
path "identity/entity"        { capabilities = ["create", "update"] }
path "identity/entity/name/*" { capabilities = ["read"] }
path "identity/entity-alias"  { capabilities = ["create", "update"] }
EOF
vault policy write tetrix-onboarding-broker - <<'EOF'
path "auth/token/create/tetrix-collector-tenant" { capabilities = ["update"] }
path "auth/token/create/tetrix-onboarding"       { capabilities = ["update"] }
path "identity/entity"        { capabilities = ["create", "update"] }
path "identity/entity/name/*" { capabilities = ["read"] }
path "identity/entity-alias"  { capabilities = ["create", "update"] }
EOF

# A pre-#553 wildcard token would pass the keep probe below (it IS valid — that is the
# problem), so it would survive the upgrade with its old policy. Check the policy name and
# revoke it. This is the ONE place a validating-but-wrong token is actively revoked; the keep
# probe only declines to keep.
if [ -n "${COLLECTORS_VAULT_TOKEN:-}" ] &&
  vault token lookup -format=json "$COLLECTORS_VAULT_TOKEN" 2>/dev/null |
  grep -q '"tetrix-collectors"'; then
  echo "revoking the pre-#553 wildcard collectors token"
  vault token revoke "$COLLECTORS_VAULT_TOKEN" >/dev/null 2>&1 || true
  vault policy delete tetrix-collectors >/dev/null 2>&1 || true
  COLLECTORS_VAULT_TOKEN=""
fi

# ── keep an existing broker token when it is still OURS and still alive (chart#246) ────────
# What used to be here called `vault token renew-self`, which IS NOT A VAULT CLI SUBCOMMAND:
# it exits 1 with the `vault token` usage banner — as root and as the broker — so the branch
# was dead and EVERY run minted a new generation of all three brokers. Compose reads
# `env_file` when it PARSES the project, so the containers were then permanently one
# generation behind the file (and, on a fresh install, held no token at all). MEASURED in
# this container on hashicorp/vault:1.21.4: `vault token renew-self` -> rc 1 (usage);
# `vault write -f auth/token/renew-self` as a broker -> rc 2, 403 (the brokers are minted
# -no-default-policy, and renew-self is a default-policy grant).
#
# The probe runs on the ROOT token this script already exported (line 63) and asserts three
# things, in this order:
#   1. NON-EMPTY — see the guard below. It is the FIRST of three independent layers that each
#      refuse a blank, not the only one: MEASURED on hashicorp/vault:1.21.4, `vault token
#      lookup ""` self-looks-up as ROOT and exits 0 (so a lookup-only probe WOULD keep a blank),
#      but `vault token renew ""` exits 2 and the policy check below cannot match. Verified by
#      building the mutant: with the guard AND the policy check removed, a blanked token is
#      still re-minted, because `renew` refuses it. Keep the guard — it is correct, free and
#      first — but the defence is layered, and no single line is all that stands between a blank
#      variable and a kept credential.
#   2. THE RIGHT POLICY. A token that is valid but carries another policy — the pre-#553
#      wildcard, or an operator's own token — must not be kept. Exact-array match, so a token
#      that gained an extra policy is re-minted rather than trusted (collectors ADR-0033 A1
#      item 4: the read/write split is a property of the credential).
#   3. RENEWABLE. `vault token renew` resets the -period, and nothing else in this install
#      ever renews these tokens: the dead line above was also the only renewal they had, so a
#      stack left running longer than VAULT_TOKEN_PERIOD would have expired. rc 2 on a
#      revoked, expired or non-renewable token (MEASURED), so anything we cannot keep alive is
#      re-minted rather than kept until it silently dies.
keep_broker_token() { # $1 = token value, $2 = the policy it must carry
  # LOAD-BEARING, NOT DECORATION: `vault token lookup ""` does NOT fail. The real CLI falls
  # back to a SELF-lookup — and at this point in the script that self is the ROOT token — so it
  # exits 0 (MEASURED on hashicorp/vault:1.21.4). Without this guard a blank or unset variable
  # therefore "validates" and is KEPT. Measured against a probe with this guard and the policy
  # check both removed: a blanked COLLECTORS_VAULT_TOKEN printed "existing collectors broker
  # token renewed — keeping it" and an EMPTY token was written to runtime/vault.env, so the
  # collectors get no credential at all, silently, and blanking a key stops being the way to
  # force a rotation. With the guard, the same input prints "minted a new collectors broker
  # token" and only that broker is replaced. Never remove it.
  [ -n "${1:-}" ] || return 1
  vault token lookup -format=json "$1" 2>/dev/null | tr -d ' \n' |
    grep -qF "\"policies\":[\"$2\"]" || return 1
  vault token renew "$1" >/dev/null 2>&1
}
if keep_broker_token "${COLLECTORS_VAULT_TOKEN:-}" tetrix-collectors-broker; then
  echo "existing collectors broker token renewed — keeping it"
else
  COLLECTORS_VAULT_TOKEN=$(vault token create -policy=tetrix-collectors-broker \
    -orphan -no-default-policy -period="$TOKEN_PERIOD" \
    -display-name=tetrix-collectors-broker -field=token)
  echo "minted a new collectors broker token (no KV capability of its own)"
fi
if keep_broker_token "${COLLECTORS_API_VAULT_TOKEN:-}" tetrix-onboarding-broker; then
  echo "existing onboarding broker token renewed — keeping it"
else
  COLLECTORS_API_VAULT_TOKEN=$(vault token create -policy=tetrix-onboarding-broker \
    -orphan -no-default-policy -period="$TOKEN_PERIOD" \
    -display-name=tetrix-onboarding-broker -field=token)
  echo "minted a new onboarding broker token (collectors-api only)"
fi
if keep_broker_token "${COLLECTORS_WEBHOOK_VAULT_TOKEN:-}" tetrix-webhook-broker; then
  echo "existing webhook broker token renewed — keeping it"
else
  COLLECTORS_WEBHOOK_VAULT_TOKEN=$(vault token create -policy=tetrix-webhook-broker \
    -orphan -no-default-policy -period="$TOKEN_PERIOD" \
    -display-name=tetrix-webhook-broker -field=token)
  echo "minted a new webhook broker token (collectors-worker only)"
fi

# Post-condition, checked LOUDLY rather than assumed. BOTH brokers are probed — the worker's
# webhook broker is a separate credential and would otherwise be invisible to this check.
for p in "${KV_MOUNT}/data/tenants/probe/github/x" \
  "${KV_MOUNT}/metadata/tenants/probe/github/x" \
  "${KV_MOUNT}/data/platform/github-app/private-key" \
  "${KV_MOUNT}/data/tenants/probe/webhooks/github__x"; do
  for t in "$COLLECTORS_VAULT_TOKEN" "$COLLECTORS_WEBHOOK_VAULT_TOKEN"; do
    caps=$(vault token capabilities "$t" "$p")
    echo "broker capabilities on $p: $caps"
    [ "$caps" = "deny" ] || {
      echo "FATAL: broker token is over-privileged on $p" >&2
      exit 1
    }
  done
done
# POSITIVE CONTROL: a probe that can only ever print `deny` is not a check — it would pass
# against a broker that had been deleted. Assert the capability that MUST exist, and its absence
# on the credential that must NOT have it.
caps=$(vault token capabilities "$COLLECTORS_WEBHOOK_VAULT_TOKEN" \
  auth/token/create/tetrix-collector-webhook)
echo "webhook broker on auth/token/create/tetrix-collector-webhook: $caps"
case "$caps" in *update*) : ;; *)
  echo "FATAL: the webhook broker cannot mint tetrix-collector-webhook" >&2
  exit 1 ;;
esac
caps=$(vault token capabilities "$COLLECTORS_VAULT_TOKEN" \
  auth/token/create/tetrix-collector-webhook)
echo "reader broker on auth/token/create/tetrix-collector-webhook: $caps"
[ "$caps" = "deny" ] || {
  echo "FATAL: the reader broker can mint a write role" >&2
  exit 1
}

tmp="${OUT}.tmp"
{
  printf 'VAULT_UNSEAL_KEY=%s\n' "$VAULT_UNSEAL_KEY"
  printf 'VAULT_ROOT_TOKEN=%s\n' "$VAULT_ROOT_TOKEN"
  printf 'COLLECTORS_VAULT_TOKEN=%s\n' "$COLLECTORS_VAULT_TOKEN"
  printf 'COLLECTORS_API_VAULT_TOKEN=%s\n' "$COLLECTORS_API_VAULT_TOKEN"
  printf 'COLLECTORS_WEBHOOK_VAULT_TOKEN=%s\n' "$COLLECTORS_WEBHOOK_VAULT_TOKEN"
  # ── the ACTIVE wiring below is collectors-worker's ──
  # This file is mounted, in docker-compose.yml, into collectors-worker and NOTHING else, so
  # every unprefixed VAULT_* key here is the WORKER's configuration. It gets the WEBHOOK broker
  # (collectors#597): ADR-0072 Lane 2 runs register_webhook in the worker saga, where an HMAC
  # signing secret is minted and must be persisted, and VAULT_WEBHOOK_TOKEN_ROLE has no token
  # twin by design — the worker's own broker is what mints it. The webhook broker can also mint
  # the tenant READ role, so the worker's read half is unchanged.
  printf 'VAULT_TOKEN=%s\n' "$COLLECTORS_WEBHOOK_VAULT_TOKEN"
  printf 'VAULT_KV_MOUNT=%s\n' "$KV_MOUNT"
  printf 'VAULT_TOKEN_MOUNT_ACCESSOR=%s\n' "$TOKEN_ACCESSOR"
  printf 'VAULT_TENANT_TOKEN_ROLE=%s\n' "tetrix-collector-tenant"
  printf 'VAULT_WEBHOOK_TOKEN_ROLE=%s\n' "tetrix-collector-webhook"
  # NOT written, deliberately: VAULT_ONBOARDING_TOKEN / VAULT_ONBOARDING_TOKEN_ROLE. Nothing in
  # this Compose file mounts this env file into collectors-api, so writing them here would put
  # them on the WORKER — and vault_clients_from_env ranks VAULT_ONBOARDING_TOKEN_ROLE ABOVE
  # VAULT_WEBHOOK_TOKEN_ROLE, which would both disable the narrow webhook role and hand the
  # worker full write over every source credential in the tenant. An operator wiring the API
  # sets them on THAT service, from COLLECTORS_API_VAULT_TOKEN above.
} >"$tmp"
mv -f "$tmp" "$OUT"
echo "wrote $OUT"

# ── collectors-api's OWN profile (collectors#553) ──
# The API is the ONLY service that receives a user's credential at connect time, so it is the
# only one that may mint `onboarding-write`. In Kubernetes that split is expressed per
# Deployment (templates/_helpers.tpl envRefsFor). Compose has no per-service view of one env
# file, and `environment:` cannot reach a value that only exists inside another file — so the
# API needs a file of its OWN. Without it collectors-api has no VAULT_TOKEN, and it does NOT
# fall back to an in-memory secret store: docker-compose.yml sets VAULT_ADDR in `environment:`,
# so api/app/main.py's lifespan takes the Vault branch and `vault_clients_from_env()` raises
# `VAULT_ADDR and VAULT_TOKEN must be set to build Vault clients` — the container crash-loops
# from boot instead of coming up and losing credentials quietly. MEASURED on a fresh clean room
# built by this chart's own setup.sh: 20 of that line in the API's log, RestartCount=10 within
# 60 s of the `up` returning (chart#246; the older wording here predates that measurement).
#
# VAULT_TOKEN here is the READ-ONLY broker, not the onboarding one: `vault_clients_from_env`
# uses VAULT_ONBOARDING_TOKEN for the write half only, so even inside the one service allowed to
# write, a read still runs on a credential that cannot. VAULT_WEBHOOK_TOKEN_ROLE is deliberately
# absent — the API is not a registrar, and the write-role lookup ranks onboarding above webhook.
tmp="${API_OUT}.tmp"
{
  printf 'VAULT_TOKEN=%s\n' "$COLLECTORS_VAULT_TOKEN"
  printf 'VAULT_KV_MOUNT=%s\n' "$KV_MOUNT"
  printf 'VAULT_TOKEN_MOUNT_ACCESSOR=%s\n' "$TOKEN_ACCESSOR"
  printf 'VAULT_TENANT_TOKEN_ROLE=%s\n' "tetrix-collector-tenant"
  printf 'VAULT_ONBOARDING_TOKEN=%s\n' "$COLLECTORS_API_VAULT_TOKEN"
  printf 'VAULT_ONBOARDING_TOKEN_ROLE=%s\n' "tetrix-onboarding"
} >"$tmp"
mv -f "$tmp" "$API_OUT"
echo "wrote $API_OUT"

# ── the READ-ONLY profile (collectors#603) ──
# collectors-healthcheck (compose profile `healthcheck`) resolves a credential only to re-probe
# it: it never writes a secret and never writes AIDB, so it must hold nothing but the reader
# broker — the twin of `tetrixaidb.collectors.envRefs` in the k8s chart, which is what
# dispatcher / mcp / relay / session-consumer get. Neither existing file fits: vault.env's
# unprefixed VAULT_TOKEN is the WEBHOOK broker (a write role), and vault-api.env carries
# VAULT_ONBOARDING_TOKEN (full tenant write). Handing either to a probe-only loop is exactly the
# over-grant collectors#553 removed. So it gets a file of its own, with the four keys
# `vault_clients_from_env` needs for a brokered read and not one more.
tmp="${READ_OUT}.tmp"
{
  printf 'VAULT_TOKEN=%s\n' "$COLLECTORS_VAULT_TOKEN"
  printf 'VAULT_KV_MOUNT=%s\n' "$KV_MOUNT"
  printf 'VAULT_TOKEN_MOUNT_ACCESSOR=%s\n' "$TOKEN_ACCESSOR"
  printf 'VAULT_TENANT_TOKEN_ROLE=%s\n' "tetrix-collector-tenant"
} >"$tmp"
mv -f "$tmp" "$READ_OUT"
echo "wrote $READ_OUT"
