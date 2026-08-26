#!/bin/bash
# Collectors control-plane role + database (ADR-0040) — mirrors the Helm initdb script.
set -euo pipefail

if [ -n "${CONTROL_PLANE_DB_PASSWORD:-}" ]; then
  psql -v ON_ERROR_STOP=1 --username "postgres" --dbname "postgres" <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'control_plane') THEN
    CREATE ROLE control_plane WITH LOGIN PASSWORD '${CONTROL_PLANE_DB_PASSWORD}';
  END IF;
END
\$\$;
ALTER ROLE control_plane WITH PASSWORD '${CONTROL_PLANE_DB_PASSWORD}';
SELECT 'CREATE DATABASE control_plane OWNER control_plane'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'control_plane')\gexec
EOSQL
fi
