#!/bin/bash
# Audit trail database (tetrix-audit-logs) — mirrors the Helm initdb script.
# Runs in initdb (fresh volume) and postgres-ensure / migrate Job (PGHOST set).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "postgres" --dbname "postgres" <<EOSQL
SELECT 'CREATE DATABASE audit_logs OWNER tetrix'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'audit_logs')\gexec
EOSQL
