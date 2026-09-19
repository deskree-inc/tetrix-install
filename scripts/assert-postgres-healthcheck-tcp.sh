#!/usr/bin/env bash
# The compose Postgres healthcheck must probe a real TCP connection, not the
# local unix socket.
#
# WHY: the postgres:16 image runs a socket-only TEMP server during initdb (to
# execute its init scripts) and then RESTARTS into the real server listening on
# TCP :5432. A socket `pg_isready` answers YES during that temp-server window, so
# `depends_on: postgres: service_healthy` fires while TCP is still refused — and
# the postgres-ensure-* one-shots, which connect over TCP to postgres:5432, then
# fail a fresh install with "connection refused" (tetrix-install#48). Forcing the
# probe onto TCP (`pg_isready -h 127.0.0.1 ...`) makes `healthy` mean what the
# clients need: the real server is accepting TCP.
#
# This is a static guard so a future edit that "simplifies" the probe back to the
# socket form is caught in CI rather than in a customer's first boot.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${ROOT}/docker-compose.yml"
[ -f "$COMPOSE" ] || { echo "ERROR: ${COMPOSE} is missing" >&2; exit 1; }

python3 - "$COMPOSE" <<'PY'
import sys, yaml
compose = yaml.safe_load(open(sys.argv[1]))
hc = (((compose.get("services") or {}).get("postgres") or {}).get("healthcheck") or {})
test = hc.get("test")
if not test:
    # Non-vacuous: a rename/shape change must FAIL here, not silently pass.
    print("  FAIL: no postgres healthcheck found — cannot verify the TCP fix (shape drift)")
    sys.exit(1)
probe = " ".join(test) if isinstance(test, list) else str(test)
if "pg_isready" not in probe and "psql" not in probe:
    print(f"  FAIL: postgres healthcheck is not a pg_isready/psql probe: {probe!r}")
    sys.exit(1)
if "-h " not in probe:
    print("  FAIL: postgres healthcheck does not force TCP (-h). It can pass on the")
    print("        postgres:16 init-time socket-only temp server while TCP :5432 is")
    print(f"        refused, racing the postgres-ensure-* one-shots (tetrix-install#48). Got: {probe!r}")
    sys.exit(1)
print(f"  OK: postgres healthcheck probes TCP (-h), closing the initdb temp-server race: {probe!r}")
PY
