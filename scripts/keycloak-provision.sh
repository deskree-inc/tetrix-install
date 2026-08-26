#!/bin/sh
# Compose entrypoint for Keycloak provision.
# Prefers fast Admin REST (curl+jq) when available; falls back to kcadm.
# Canonical scripts: ../../../scripts/keycloak-provision-{rest,kcadm}.sh
# (also mounted into the Helm provision ConfigMap via .Files.Get).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

# Inside Compose the canonical helpers are bind-mounted next to this script.
# That is now the FIRST choice, not the fallback: a released bundle has no
# repository above it, so the checkout-relative path below only ever resolves
# when someone runs this script by hand from a full clone.
if [ -f /provision/provision-rest.sh ]; then
  REST=/provision/provision-rest.sh
  KCADM_SCRIPT=/provision/provision-kcadm.sh
elif [ -f "${SCRIPT_DIR}/../chart-scripts/keycloak-provision-rest.sh" ]; then
  REST="${SCRIPT_DIR}/../chart-scripts/keycloak-provision-rest.sh"
  KCADM_SCRIPT="${SCRIPT_DIR}/../chart-scripts/keycloak-provision-kcadm.sh"
else
  CHART_SCRIPTS="${SCRIPT_DIR}/../../../scripts"
  REST="${CHART_SCRIPTS}/keycloak-provision-rest.sh"
  KCADM_SCRIPT="${CHART_SCRIPTS}/keycloak-provision-kcadm.sh"
fi

FAST="${KEYCLOAK_PROVISION_FAST:-1}"
if [ "${FAST}" = "1" ] || [ "${FAST}" = "true" ] || [ "${FAST}" = "yes" ]; then
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "${REST}" ]; then
    exec /bin/sh "${REST}" "$@"
  fi
  echo "WARN: fast provision requested but curl/jq/script missing — falling back to kcadm" >&2
fi

if [ -f "${KCADM_SCRIPT}" ]; then
  exec /bin/bash "${KCADM_SCRIPT}" "$@"
fi

echo "ERROR: neither provision-rest.sh nor provision-kcadm.sh found" >&2
exit 1
