#!/usr/bin/env bash
# Guest / public compose must not pin unpublished first-party tags.
#
# Sangam-class 0.8.41 lock wanted tetrix-licensing:sha-48d76f3 (amd64 child
# sha256:8b99820c… moved → MANIFEST_UNKNOWN) and tetrixaidb{,-remote}:sha-7dd9f22
# (also unpublished). Current pins match Helm 1.1.2 (the trio moved sha-3aaba81 -> sha-7927db5;
# daemon/remote, collectors and frontend moved to their latest main publishes):
#   daemon/remote      sha-253966c
#   licensing/updater  sha-7927db5  (do not republish 8b99820c)
#   collectors         sha-1c50594
#   frontend           sha-415174c
#   iam                sha-3cbe20c
#   admin-api          sha-7927db5
#   audit-logs         sha-2a150cc
#   gateway            sha-6fb4e73
#
# Ubuntu docker.io 29 has no compose plugin. `compose.sh pull --quiet` is parsed
# as `docker --quiet` → tetrix_registry_pull_failed. Cloud guests get compose-v2
# from helm 0.8.43+; this public tree must not reintroduce --quiet or assume
# compose exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()  { echo "OK: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

python3 - "$ROOT" <<'PY' || fail=1
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
env = (root / ".env.example").read_text()
compose = (root / "docker-compose.yml").read_text()
setup = (root / "scripts/setup.sh").read_text()
login = (root / "scripts/registry-login.sh").read_text()

def uncomment(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

errors = []

# Active pin values (comments may mention the unpublished tags as history).
for name, text, forbidden in (
    (".env.example", uncomment(env), ("sha-48d76f3", "sha-7dd9f22")),
    ("docker-compose.yml", compose, ("sha-48d76f3", "sha-7dd9f22")),
    ("scripts/setup.sh", uncomment(setup), ("sha-7dd9f22",)),
):
    for tag in forbidden:
        if tag in text:
            errors.append(f"{name} still pins unpublished {tag}")

required_env = (
    ("TETRIX_IMAGE_TAG=sha-253966c", "TETRIX_IMAGE_TAG"),
    ("KEYCLOAK_IMAGE_TAG=sha-3cbe20c", "KEYCLOAK_IMAGE_TAG"),
    ("FRONTEND_IMAGE_TAG=sha-415174c", "FRONTEND_IMAGE_TAG"),
    ("AUDIT_LOGS_IMAGE_TAG=sha-2a150cc", "AUDIT_LOGS_IMAGE_TAG"),
    ("COLLECTORS_IMAGE_TAG=sha-1c50594", "COLLECTORS_IMAGE_TAG"),
    ("ADMIN_API_IMAGE_TAG=sha-7927db5", "ADMIN_API_IMAGE_TAG"),
    ("LICENSING_IMAGE_TAG=sha-7927db5", "LICENSING_IMAGE_TAG"),
    ("UPDATER_IMAGE_TAG=sha-7927db5", "UPDATER_IMAGE_TAG"),
    ("GATEWAY_IMAGE_TAG=sha-6fb4e73", "GATEWAY_IMAGE_TAG"),
)
for needle, label in required_env:
    if needle not in env:
        errors.append(f".env.example must pin {needle} (Helm 1.1.2)")

required_compose = (
    (":-sha-253966c}", "daemon/remote"),
    (":-sha-3cbe20c}", "iam"),
    (":-sha-415174c}", "frontend"),
    (":-sha-2a150cc}", "audit-logs"),
    (":-sha-1c50594}", "collectors"),
    (":-sha-7927db5}", "admin-api/licensing/updater"),
    (":-sha-6fb4e73}", "gateway"),
)
for needle, label in required_compose:
    if needle not in compose:
        errors.append(f"docker-compose.yml must default {label} to {needle}")

login_active = uncomment(login)
if "pull --quiet" in login_active or "pull -q" in login_active:
    errors.append(
        "scripts/registry-login.sh passes --quiet/-q; "
        "Docker 29 without compose-v2 treats that as a global docker flag"
    )
if "docker-compose-v2" not in setup and "docker compose version" not in setup:
    errors.append(
        "scripts/setup.sh must ensure the compose v2 plugin "
        "(docker compose version / docker-compose-v2) before compose up"
    )

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    raise SystemExit(1)
print("ok")
PY

if [[ "$fail" -eq 0 ]]; then
  ok "public compose pins match Helm 1.1.2 published tags and does not pass --quiet"
fi
exit "$fail"
