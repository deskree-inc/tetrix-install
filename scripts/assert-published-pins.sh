#!/usr/bin/env bash
# Guest / public compose must not pin unpublished first-party tags.
#
# Sangam-class 0.8.41 lock wanted tetrix-licensing:sha-48d76f3 (amd64 child
# sha256:8b99820c… moved → MANIFEST_UNKNOWN) and tetrixaidb{,-remote}:sha-7dd9f22
# (also unpublished on GHCR). sha-48d76f3 resolves again, but not to the bytes that
# lock recorded, so it stays forbidden. Current pins match Helm 1.1.27 (the large-graph snapshot
# fix: collectors sha-763739e is the 1.1.26 collectors bundle, tetrix-collectors#1383 on 60087ad, with
# migrations 0044_graph_snapshot_shards and 0045_graph_snapshot_shards_vacuum; daemon/remote sha-89456c6
# and gateway sha-6fd804d are CI-only rebuilds of the same source (tetrix-ee#223, gateway#52); the
# admin-api trio stays one build, sha-349d602; front-end sha-fb128fa, audit-logs sha-2a150cc and iam
# sha-7f0c138 stay (iam HELD: sha-04b1e55, Keycloak 26.8.1, waits on chart#480's review blocker);
# each tag resolved on ghcr.io/deskree-inc for linux/amd64 + linux/arm64):
#   daemon/remote      sha-89456c6
#   licensing/updater  sha-349d602  (do not republish 8b99820c)
#   collectors         sha-763739e
#   frontend           sha-fb128fa
#   iam                sha-7f0c138
#   admin-api          sha-349d602
#   audit-logs         sha-2a150cc
#   gateway            sha-6fd804d
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
import re
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
# sha-09a15db (collectors #1294, a test-only merge, 2026-10-08; an ancestor of the published
# sha-6e4d334) and sha-d35e356 (audit-logs main tip, CODEOWNERS only) are git commits that never
# published an image (MANIFEST_UNKNOWN on ghcr.io/deskree-inc): a repin that takes git HEAD
# instead of the newest published build lands on them.
# sha-423c2c9 (front-end main 2026-10-21, its publish failed) and sha-baaaa5a (collectors #1368's
# merge, never published on its own) are the same trap for this repin.
UNPUBLISHED = ("sha-48d76f3", "sha-7dd9f22", "sha-09a15db", "sha-d35e356", "sha-423c2c9", "sha-baaaa5a")
for name, text, forbidden in (
    (".env.example", uncomment(env), UNPUBLISHED),
    ("docker-compose.yml", compose, UNPUBLISHED),
    ("scripts/setup.sh", uncomment(setup), ("sha-7dd9f22",)),
):
    for tag in forbidden:
        if tag in text:
            errors.append(f"{name} still pins unpublished {tag}")

required_env = (
    ("TETRIX_IMAGE_TAG=sha-89456c6", "TETRIX_IMAGE_TAG"),
    ("KEYCLOAK_IMAGE_TAG=sha-7f0c138", "KEYCLOAK_IMAGE_TAG"),
    ("FRONTEND_IMAGE_TAG=sha-fb128fa", "FRONTEND_IMAGE_TAG"),
    ("AUDIT_LOGS_IMAGE_TAG=sha-2a150cc", "AUDIT_LOGS_IMAGE_TAG"),
    ("COLLECTORS_IMAGE_TAG=sha-763739e", "COLLECTORS_IMAGE_TAG"),
    ("ADMIN_API_IMAGE_TAG=sha-349d602", "ADMIN_API_IMAGE_TAG"),
    ("LICENSING_IMAGE_TAG=sha-349d602", "LICENSING_IMAGE_TAG"),
    ("UPDATER_IMAGE_TAG=sha-349d602", "UPDATER_IMAGE_TAG"),
    ("GATEWAY_IMAGE_TAG=sha-6fd804d", "GATEWAY_IMAGE_TAG"),
)
for needle, label in required_env:
    if needle not in env:
        errors.append(f".env.example must pin {needle} (Helm 1.1.27)")

required_compose = (
    (":-sha-89456c6}", "daemon/remote"),
    (":-sha-7f0c138}", "iam"),
    (":-sha-fb128fa}", "frontend"),
    (":-sha-2a150cc}", "audit-logs"),
    (":-sha-763739e}", "collectors"),
    (":-sha-349d602}", "admin-api/licensing/updater"),
    (":-sha-6fd804d}", "gateway"),
)
for needle, label in required_compose:
    if needle not in compose:
        errors.append(f"docker-compose.yml must default {label} to {needle}")

# One pin set: every first-party `${X_IMAGE_TAG:-sha-…}` default in compose and every active
# `X_IMAGE_TAG=sha-…` line in .env.example must be the tag required above. A stale default
# left on a second service (the collectors image appears on ten) would otherwise pass the
# presence checks.
expected = {label: needle.split("=", 1)[1] for needle, label in required_env}
for var, tag in re.findall(r"\$\{([A-Z_]+_IMAGE_TAG):-(sha-[0-9a-f]+)\}", compose):
    if var in expected and tag != expected[var]:
        errors.append(f"docker-compose.yml defaults {var} to {tag}, not {expected[var]}")
for var, tag in re.findall(r"^([A-Z_]+_IMAGE_TAG)=(sha-[0-9a-f]+)\s*$", uncomment(env), re.M):
    if var in expected and tag != expected[var]:
        errors.append(f".env.example pins {var}={tag}, not {expected[var]}")

# setup.sh's CA-bundle fallback must be the same daemon tag as compose.
if "TETRIX_IMAGE_TAG:-sha-89456c6" not in setup:
    errors.append("scripts/setup.sh must fall back to the compose daemon pin sha-89456c6")

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
  ok "public compose pins match Helm 1.1.27 published tags and does not pass --quiet"
fi
exit "$fail"
