#!/usr/bin/env bash
# Guest / public compose must not pin unpublished first-party tags.
#
# Sangam-class 0.8.41 lock wanted tetrix-licensing:sha-48d76f3 (amd64 child
# sha256:8b99820c… moved → MANIFEST_UNKNOWN) and tetrixaidb{,-remote}:sha-7dd9f22
# (also unpublished). Leftover-class published linux/amd64 pins:
#   licensing/updater  sha-a9ccf90  (child sha256:d6eb42a4… — do not republish 8b99820c)
#   daemon/remote      sha-44b61f9
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

if "LICENSING_IMAGE_TAG=sha-a9ccf90" not in env:
    errors.append(".env.example must pin LICENSING_IMAGE_TAG=sha-a9ccf90 (leftover-class)")
if "UPDATER_IMAGE_TAG=sha-a9ccf90" not in env:
    errors.append(".env.example must pin UPDATER_IMAGE_TAG=sha-a9ccf90")
if "TETRIX_IMAGE_TAG=sha-44b61f9" not in env:
    errors.append(".env.example must pin TETRIX_IMAGE_TAG=sha-44b61f9")
if ":-sha-a9ccf90}" not in compose:
    errors.append("docker-compose.yml must default licensing/updater to sha-a9ccf90")
if ":-sha-44b61f9}" not in compose:
    errors.append("docker-compose.yml must default daemon/remote to sha-44b61f9")

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
  ok "public compose pins leftover-class published tags and does not pass --quiet"
fi
exit "$fail"
