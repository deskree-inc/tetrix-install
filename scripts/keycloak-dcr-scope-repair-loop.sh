#!/bin/sh
# Periodic DCR MCP scope repair (Keycloak #50807 / KC 26.1.4).
# Compose twin of helm keycloak.provision.dcrScopeRepair CronJob.
set -eu

INTERVAL="${DCR_REPAIR_INTERVAL_SECONDS:-120}"
SCRIPT="${DCR_REPAIR_SCRIPT:-/scripts/dcr-scope-repair.sh}"

echo "keycloak-dcr-scope-repair loop (interval=${INTERVAL}s; KC #50807 workaround until KC 26.8)"

while true; do
  if /bin/sh "${SCRIPT}"; then
    :
  else
    echo "WARN: dcr-scope-repair failed — retry in ${INTERVAL}s" >&2
  fi
  sleep "${INTERVAL}"
done
