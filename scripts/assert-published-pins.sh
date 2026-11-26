#!/usr/bin/env bash
# Guest / public compose must not pin unpublished first-party tags.
#
# A customer install's 0.8.41 lock wanted tetrix-licensing:sha-48d76f3 (amd64 child
# sha256:8b99820c… moved → MANIFEST_UNKNOWN) and tetrixaidb{,-remote}:sha-7dd9f22
# (also unpublished on GHCR). sha-48d76f3 resolves again, but not to the bytes that
# lock recorded, so it stays forbidden. Current pins match Helm 1.1.37 (collectors sha-1361407 is
# tetrix-collectors main 1361407f, the merge of #1680, publish-image run 45694645014, still baking the
# cli-v0.6.8 CLI (GHCR index sha256:51510227ea39); it adds NO migration — the control-plane schema
# stays at 0052_sandbox_refusal_counts, where 1.1.36 left it; the pack runner sha-1361407 is the same
# merge, publish-pack-runner-image run 45694644970 (GHCR index sha256:d43c2a86a02f); front-end
# sha-02d1f72 is front-end main 02d1f72a, the merge of #387, publish-image run 45700788768 (GHCR index
# sha256:bfb20c204f5a); the collectors pin is deliberately NOT main's tip 1928ed20 — 1361407f..1928ed20
# is three markdown files and published no image, so the newest published ancestor is the pin;
# daemon/remote sha-fbd9dbe is tetrix-ee main fbd9dbe, docker-build-push run 44203307177, the indexer's
# Vue/Svelte parser fix and no store migration; gateway sha-0d55284 is gateway#53, docker-build-push run
# 42860903238, a CI-only rebuild of sha-6fd804d; sha-3f7baca and sha-d83d976 were cancelled before they
# pushed, so they are forbidden; the admin-api trio sha-349d602, audit-logs sha-2a150cc and iam sha-04b1e55
# (Keycloak 26.8.1, tetrix-iam#64) are unchanged;
# each tag resolved on ghcr.io/deskree-inc for linux/amd64 + linux/arm64):
#   daemon/remote      sha-fbd9dbe
#   licensing/updater  sha-349d602  (do not republish 8b99820c)
#   collectors         sha-1361407
#   pack-runner        sha-1361407
#   frontend           sha-02d1f72
#   iam                sha-04b1e55
#   admin-api          sha-349d602
#   audit-logs         sha-2a150cc
#   gateway            sha-0d55284
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
# For 1.1.36 the same trap is every default-branch tip past the pinned builds: iam master
# cde9c26/5bf7494/5a6e1d8/7b88cdf (docs and CI), admin-api main f3778e4/ebc212a (CI) and audit-logs
# main a952d6e/46199f0 (CI) published no image.
# For 1.1.37 it is tetrix-collectors main 1928ed20: 1361407f..1928ed20 is three markdown files, the
# publish path filter skipped them, and neither tetrix-collectors nor tetrix-pack-runner carries a
# sha-1928ed2 tag on GHCR. Pinning git HEAD here would break every pull.
UNPUBLISHED = ("sha-48d76f3", "sha-7dd9f22", "sha-09a15db", "sha-d35e356", "sha-423c2c9", "sha-baaaa5a", "sha-3f7baca", "sha-d83d976",
               "sha-cde9c26", "sha-5bf7494", "sha-5a6e1d8", "sha-7b88cdf", "sha-f3778e4", "sha-ebc212a", "sha-a952d6e", "sha-46199f0",
               "sha-1928ed2")
for name, text, forbidden in (
    (".env.example", uncomment(env), UNPUBLISHED),
    ("docker-compose.yml", compose, UNPUBLISHED),
    ("scripts/setup.sh", uncomment(setup), ("sha-7dd9f22",)),
):
    for tag in forbidden:
        if tag in text:
            errors.append(f"{name} still pins unpublished {tag}")

required_env = (
    ("TETRIX_IMAGE_TAG=sha-fbd9dbe", "TETRIX_IMAGE_TAG"),
    ("KEYCLOAK_IMAGE_TAG=sha-04b1e55", "KEYCLOAK_IMAGE_TAG"),
    ("FRONTEND_IMAGE_TAG=sha-02d1f72", "FRONTEND_IMAGE_TAG"),
    ("AUDIT_LOGS_IMAGE_TAG=sha-2a150cc", "AUDIT_LOGS_IMAGE_TAG"),
    ("COLLECTORS_IMAGE_TAG=sha-1361407", "COLLECTORS_IMAGE_TAG"),
    ("PACK_RUNNER_IMAGE_TAG=sha-1361407", "PACK_RUNNER_IMAGE_TAG"),
    ("ADMIN_API_IMAGE_TAG=sha-349d602", "ADMIN_API_IMAGE_TAG"),
    ("LICENSING_IMAGE_TAG=sha-349d602", "LICENSING_IMAGE_TAG"),
    ("UPDATER_IMAGE_TAG=sha-349d602", "UPDATER_IMAGE_TAG"),
    ("GATEWAY_IMAGE_TAG=sha-0d55284", "GATEWAY_IMAGE_TAG"),
)
for needle, label in required_env:
    if needle not in env:
        errors.append(f".env.example must pin {needle} (Helm 1.1.37)")

# Collectors and the pack runner are two images built from one tetrix-collectors commit, so they
# share a tag. Each gets its own needle: a future release may publish one without the other, and a
# single shared needle would pass while only one of them had moved.
required_compose = (
    (":-sha-fbd9dbe}", "daemon/remote"),
    (":-sha-04b1e55}", "iam"),
    ("${FRONTEND_IMAGE_TAG:-sha-02d1f72}", "frontend"),
    (":-sha-2a150cc}", "audit-logs"),
    ("${COLLECTORS_IMAGE_TAG:-sha-1361407}", "collectors"),
    ("${PACK_RUNNER_IMAGE_TAG:-sha-1361407}", "pack-runner"),
    (":-sha-349d602}", "admin-api/licensing/updater"),
    (":-sha-0d55284}", "gateway"),
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
if "TETRIX_IMAGE_TAG:-sha-fbd9dbe" not in setup:
    errors.append("scripts/setup.sh must fall back to the compose daemon pin sha-fbd9dbe")

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
  ok "public compose pins match Helm 1.1.37 published tags and does not pass --quiet"
fi
exit "$fail"
