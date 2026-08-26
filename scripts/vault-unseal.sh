#!/usr/bin/env sh
# Keep Vault usable across restarts, in both modes.
#
# dev    file storage + Shamir. There is a local unseal key in the runtime env
#        file, and a restarted Vault comes back SEALED, so this watches and
#        unseals — the Helm sidecar twin, unchanged.
# cloud  Cloud KMS auto-unseal. There is NO unseal key anywhere on the VM; that
#        is the point. Vault unseals itself, and this only observes: it reports
#        seal state and fails loudly if Vault stays sealed, which is the signal
#        that KMS or the VM identity broke rather than something to fix here.
#
# Either way the runtime env file is CONSUMED, not kept: it is read once into
# this shell, never echoed, and never re-exported into a child.
set -eu
umask 077
export VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
ENV_FILE="${VAULT_ENV_FILE:-/vault-init/vault.env}"
DEPLOY_MODE="${TETRIX_DEPLOYMENT_MODE:-dev}"
POLL_SECONDS="${VAULT_UNSEAL_POLL_SECONDS:-5}"

seal_state() {
  # 0 = unsealed, 2 = sealed, anything else = API unreachable.
  set +e
  vault status >/dev/null 2>&1
  _st=$?
  set -e
  printf '%s' "$_st"
}

if [ "$DEPLOY_MODE" = "cloud" ]; then
  echo "cloud mode: Cloud KMS auto-unseal owns the seal; observing $VAULT_ADDR"
  i=0
  while [ "$i" -lt 60 ]; do
    st="$(seal_state)"
    if [ "$st" -eq 0 ]; then
      echo "Sealed false"
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  if [ "${st:-1}" -ne 0 ]; then
    echo "tetrix_vault_bootstrap_failed" >&2
    echo "Sealed true — Vault did not auto-unseal (check the KMS key and the VM identity)" >&2
    exit 1
  fi
  # Report seal state only. No unseal key exists to apply, so a later reseal is
  # an incident, not something this loop can paper over.
  while true; do
    st="$(seal_state)"
    if [ "$st" -eq 2 ]; then
      echo "tetrix_vault_bootstrap_failed" >&2
      echo "Sealed true — auto-unseal stopped working" >&2
    fi
    sleep "$POLL_SECONDS"
  done
fi

echo "waiting for $ENV_FILE..."
while [ ! -s "$ENV_FILE" ]; do
  sleep 2
done
# shellcheck disable=SC1090  # a runtime path, by design
. "$ENV_FILE"
: "${VAULT_UNSEAL_KEY:?VAULT_UNSEAL_KEY missing in $ENV_FILE}"

echo "watching Vault seal state at $VAULT_ADDR"
while true; do
  if [ "$(seal_state)" -eq 2 ]; then
    echo "Sealed true — unsealing"
    vault operator unseal "$VAULT_UNSEAL_KEY" >/dev/null || true
  fi
  sleep "$POLL_SECONDS"
done
