#!/bin/bash
# Keycloak role + database — Helm 04-keycloak.sh twin (no CREATEROLE).
# Runs in initdb (fresh volume) and postgres-ensure-keycloak (existing volumes).
set -euo pipefail

if [ -n "${KEYCLOAK_DB_PASSWORD:-}" ]; then
  psql -v ON_ERROR_STOP=1 --username "postgres" --dbname "postgres" <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'keycloak') THEN
    CREATE ROLE keycloak WITH LOGIN PASSWORD '${KEYCLOAK_DB_PASSWORD}';
  END IF;
END
\$\$;
ALTER ROLE keycloak WITH PASSWORD '${KEYCLOAK_DB_PASSWORD}';
SELECT 'CREATE DATABASE keycloak OWNER keycloak'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
EOSQL
fi
