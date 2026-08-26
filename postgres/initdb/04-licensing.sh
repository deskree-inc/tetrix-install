#!/bin/bash
# Licensing control-plane database (tetrix-admin-api services/licensing) — its OWN
# database on the bundled Postgres (licensing state != AIDB, same reuse pattern as
# 03-control-plane.sh / 04-keycloak.sh), owned by the existing "tetrix" role. The
# licensing service runs its own Alembic migrations against it. Runs in two places
# with the same idempotent \gexec guard:
#   - initdb on first volume create (local socket, no PGHOST)
#   - the postgres-ensure-licensing one-shot (PGHOST set), covering volumes that
#     predate the admin-api/licensing services.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "postgres" --dbname "postgres" <<EOSQL
SELECT 'CREATE DATABASE licensing OWNER tetrix'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'licensing')\gexec
EOSQL
