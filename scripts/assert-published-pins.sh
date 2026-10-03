#!/usr/bin/env bash
# Guest / public compose must not pin unpublished first-party tags.
#
# Sangam-class 0.8.41 lock wanted tetrix-licensing:sha-48d76f3 (amd64 child
# sha256:8b99820c… moved → MANIFEST_UNKNOWN) and tetrixaidb{,-remote}:sha-7dd9f22
# (also unpublished on GHCR). sha-48d76f3 resolves again, but not to the bytes that
# lock recorded, so it stays forbidden. Current pins match Helm 1.1.14
# (collectors sha-382c138 is the Graph/Resources dogfood fix; front-end
# sha-d5173ed stays the Observability pin;
# daemon/remote, gateway, iam, audit-logs, and the admin-api trio stay at the
# 1.1.9 set; each tag resolved on ghcr.io/deskree-inc for linux/amd64 + linux/arm64):
#   daemon/remote      sha-56bdabf
#   licensing/updater  sha-2f0f436  (do not republish 8b99820c)
#   collectors         sha-382c138
#   frontend           sha-d5173ed
#   iam                sha-3cbe20c
#   admin-api          sha-2f0f436
#   audit-logs         sha-2a150cc
#   gateway            sha-a8582b0
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
    ("TETRIX_IMAGE_TAG=sha-56bdabf", "TETRIX_IMAGE_TAG"),
    ("KEYCLOAK_IMAGE_TAG=sha-3cbe20c", "KEYCLOAK_IMAGE_TAG"),
    ("FRONTEND_IMAGE_TAG=sha-d5173ed", "FRONTEND_IMAGE_TAG"),
    ("AUDIT_LOGS_IMAGE_TAG=sha-2a150cc", "AUDIT_LOGS_IMAGE_TAG"),
    ("COLLECTORS_IMAGE_TAG=sha-382c138", "COLLECTORS_IMAGE_TAG"),
    ("ADMIN_API_IMAGE_TAG=sha-2f0f436", "ADMIN_API_IMAGE_TAG"),
    ("LICENSING_IMAGE_TAG=sha-2f0f436", "LICENSING_IMAGE_TAG"),
    ("UPDATER_IMAGE_TAG=sha-2f0f436", "UPDATER_IMAGE_TAG"),
    ("GATEWAY_IMAGE_TAG=sha-a8582b0", "GATEWAY_IMAGE_TAG"),
)
for needle, label in required_env:
    if needle not in env:
        errors.append(f".env.example must pin {needle} (Helm 1.1.14)")

required_compose = (
    (":-sha-56bdabf}", "daemon/remote"),
    (":-sha-3cbe20c}", "iam"),
    (":-sha-d5173ed}", "frontend"),
    (":-sha-2a150cc}", "audit-logs"),
    (":-sha-382c138}", "collectors"),
    (":-sha-2f0f436}", "admin-api/licensing/updater"),
    (":-sha-a8582b0}", "gateway"),
)
for needle, label in required_compose:
    if needle not in compose:
        errors.append(f"docker-compose.yml must default {label} to {needle}")

# setup.sh's CA-bundle fallback must be the same daemon tag as compose.
if "TETRIX_IMAGE_TAG:-sha-56bdabf" not in setup:
    errors.append("scripts/setup.sh must fall back to the compose daemon pin sha-56bdabf")

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
  ok "public compose pins match Helm 1.1.14 published tags and does not pass --quiet"
fi
exit "$fail"
