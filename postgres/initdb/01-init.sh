#!/bin/bash
# TetrixAIDb PostgreSQL initialization — runs once on first volume create.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "postgres" --dbname "${POSTGRES_DB:-tetrixaidb}" <<EOSQL
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'tetrix') THEN
    CREATE USER tetrix WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;
  END IF;
END
\$\$;

ALTER USER tetrix WITH PASSWORD '${POSTGRES_PASSWORD}';
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB:-tetrixaidb} TO tetrix;
GRANT ALL ON SCHEMA public TO tetrix;
EOSQL
