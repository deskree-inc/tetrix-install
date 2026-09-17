#!/usr/bin/env bash
# Every ${VAR} in the compose daemon's config.yaml must actually be supplied to
# the daemon SERVICE.
#
# WHY: the daemon expands that file with Go's os.ExpandEnv, which substitutes the
# EMPTY STRING for anything unset and reports nothing. A variable the daemon
# cannot see therefore becomes `endpoint: ""` or `password: ""` — a silent
# misconfiguration, not an error.
#
# This exists because of a real mistake: OBJECT_STORE_ENDPOINT was added to the
# compose file by matching on a `KEYCLOAK_ISSUER:` line, and the first such line
# belongs to keycloak-provision, not daemon. The rendered value looked correct in
# `docker compose config` — it was simply attached to the wrong service, so the
# daemon kept resolving the endpoint to "" and the store switch did nothing.
# Checking that a value renders is not the same as checking who receives it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${ROOT}/docker-compose.yml"
CONFIG="${ROOT}/daemon/config.yaml"
ENV_EXAMPLE="${ROOT}/.env.example"
for f in "$COMPOSE" "$CONFIG"; do
  [ -f "$f" ] || { echo "ERROR: $f is missing" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

python3 - "$COMPOSE" "$CONFIG" "$ENV_EXAMPLE" <<'PY'
import re, sys, yaml

compose_path, config_path, env_example = sys.argv[1], sys.argv[2], sys.argv[3]
compose = yaml.safe_load(open(compose_path))

services = compose.get("services") or {}
# The daemon is whichever service mounts config.yaml — derived, not hardcoded, so
# a rename cannot make this assertion quietly stop checking anything.
owners = [
    name for name, svc in services.items()
    if any(isinstance(v, str) and "daemon/config.yaml" in v for v in ((svc or {}).get("volumes") or []))
]
if len(owners) != 1:
    print(f"FAIL: expected exactly one service mounting daemon/config.yaml, found {owners}")
    raise SystemExit(1)
daemon = owners[0]
print(f"  the daemon service is {daemon!r} (derived from who mounts config.yaml)")

# Comments are stripped first: this file explains os.ExpandEnv's lack of a
# `:-default` form, and that prose contains a literal ${VAR}.
body = "\n".join(l for l in open(config_path).read().split("\n") if not l.lstrip().startswith("#"))
needed = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", body)))

env = (services[daemon] or {}).get("environment") or {}
have = set(env.keys() if isinstance(env, dict) else [e.split("=", 1)[0] for e in env])

try:
    for line in open(env_example):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            have.add(line.split("=", 1)[0])
except FileNotFoundError:
    pass

# A variable an OLDER .env does not contain must still resolve. env_file cannot
# help there — an existing install upgrading in place keeps its own .env — so
# anything introduced after the first release needs a compose-level `:-default`
# on the daemon service itself, which takes precedence over env_file. Without it
# the upgrade silently yields `endpoint: ""`.
NEEDS_COMPOSE_DEFAULT = ["OBJECT_STORE_ENDPOINT", "OBJECT_STORE_BUCKET"]
undefaulted = []
for v in NEEDS_COMPOSE_DEFAULT:
    if v not in needed:
        continue
    decl = env.get(v) if isinstance(env, dict) else None
    if not (isinstance(decl, str) and f"${{{v}:-" in decl):
        undefaulted.append(v)
if undefaulted:
    for v in undefaulted:
        print(f"    NO DEFAULT: {v} is not declared on {daemon} as ${{{v}:-...}}; an existing .env that predates it would resolve to the empty string")
    print("FAIL: a variable introduced after the first release has no compose-level default")
    raise SystemExit(1)
print(f"  OK: {', '.join(NEEDS_COMPOSE_DEFAULT)} carry compose-level defaults, so an older .env cannot blank them")

missing = [v for v in needed if v not in have]
print(f"  config.yaml expands {len(needed)} variables; {len(missing)} unreachable by {daemon}")
if missing:
    for v in missing:
        print(f"    MISSING: ${{{v}}} — os.ExpandEnv will substitute the empty string, silently")
    print("FAIL: the daemon cannot see every variable its config expands")
    raise SystemExit(1)
print("  OK: every variable daemon/config.yaml expands reaches the daemon service")
PY
