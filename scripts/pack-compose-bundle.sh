#!/usr/bin/env bash
# Pack this repository as deploy-docker-<version>.tgz.
#
# The repo root IS the public Compose twin. download.sh verifies this asset.
# Cloud guests do not clone this repo and do not extract this tarball: module
# 1.0.10 pulls registry.deskree.com/deskree/tetrix-deploy-docker@$RELEASE_DIGEST
# (helm-packed, includes install-cloud-units.sh). The version/tag this script
# stamps is what Deskree Ops may approve (cron or Support › Releases), not helm.
#
# This script never calls ops ingest/finalize and never prints secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=""
VERSION=""
SELF_TEST=0

usage() {
  cat <<'EOF'
Usage:
  scripts/pack-compose-bundle.sh [--version x.y.z] [--output-dir DIR]
  scripts/pack-compose-bundle.sh --self-test

  Packs git-tracked files at the repository root (excluding .github/) as
  deploy-docker-<version>.tgz. Writes VERSION inside the tarball and a
  public-release.json sidecar next to it (version, commit, bundle sha256).

  Default --version is the VERSION file. Default --output-dir is dist/release.
EOF
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --output-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$SELF_TEST" -eq 1 ]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/tetrix-install-pack-self-test.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  bash "$0" --version 0.0.0-self-test --output-dir "$WORK"
  TAR="$WORK/deploy-docker-0.0.0-self-test.tgz"
  test -s "$TAR"
  test -s "$WORK/public-release.json"
  LISTING="$WORK/listing.txt"
  tar -tzf "$TAR" >"$LISTING"
  grep -qx 'deploy-docker-0.0.0-self-test/VERSION' "$LISTING"
  grep -qx 'deploy-docker-0.0.0-self-test/docker-compose.yml' "$LISTING"
  grep -qx 'deploy-docker-0.0.0-self-test/scripts/download.sh' "$LISTING"
  if grep -q '/\.github/' "$LISTING"; then
    echo "ERROR: pack included .github/" >&2
    exit 1
  fi
  got="$(tar -xOf "$TAR" deploy-docker-0.0.0-self-test/VERSION | tr -d '[:space:]')"
  test "$got" = "0.0.0-self-test"
  python3 - "$WORK/public-release.json" "$TAR" <<'PY'
import hashlib, json, sys
meta = json.load(open(sys.argv[1], encoding="utf-8"))
raw = open(sys.argv[2], "rb").read()
actual = hashlib.sha256(raw).hexdigest()
assert meta["version"] == "0.0.0-self-test", meta
assert meta["bundle"] == "deploy-docker-0.0.0-self-test.tgz", meta
assert meta["bundle_sha256"] == actual, (meta["bundle_sha256"], actual)
assert meta["source"] == "https://github.com/deskree-inc/tetrix-install", meta
print("ok")
PY
  echo "pack-compose-bundle.sh --self-test ok"
  exit 0
fi

if [ -z "$VERSION" ]; then
  VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "ERROR: version must be semver (got ${VERSION:-empty})" >&2
  exit 2
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="${ROOT}/dist/release"
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: must run from a git checkout (pack uses git ls-files)." >&2
  exit 1
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
BUNDLE_NAME="deploy-docker-${VERSION}.tgz"
staging="$(mktemp -d "${TMPDIR:-/tmp}/tetrix-install-pack.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle_root="${staging}/deploy-docker-${VERSION}"
mkdir -p "$bundle_root"

# Tracked files only — same contract as helm generate-release-manifest.sh.
# .github/ is CI, not the customer bundle.
export PACK_ROOT="$ROOT"
export PACK_DEST="$bundle_root"
git -C "$ROOT" ls-files -z \
  | python3 -c '
import os, shutil, sys
root = os.environ["PACK_ROOT"]
dest = os.environ["PACK_DEST"]
for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw:
        continue
    rel = raw.decode("utf-8")
    if rel == ".github" or rel.startswith(".github/"):
        continue
    src = os.path.join(root, rel)
    if not os.path.isfile(src):
        continue
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    shutil.copy2(src, out)
'

printf '%s\n' "$VERSION" > "${bundle_root}/VERSION"
COPYFILE_DISABLE=1 tar -C "$staging" -czf "${OUT_DIR}/${BUNDLE_NAME}" "deploy-docker-${VERSION}"
BUNDLE_SHA256="$(sha256_file "${OUT_DIR}/${BUNDLE_NAME}")"

python3 - "$OUT_DIR/public-release.json" <<PY
import json, sys
doc = {
    "source": "https://github.com/deskree-inc/tetrix-install",
    "version": "${VERSION}",
    "tag": "v${VERSION}",
    "commit": "${COMMIT}",
    "bundle": "${BUNDLE_NAME}",
    "bundle_sha256": "${BUNDLE_SHA256}",
    "catalog_contract": (
        "ops cron /api/cron/approve-public-install and Support > Releases > "
        "Approve are the sanctioned approve. Cloud release_catalog is a second "
        "store after that. This repo has no ingest/finalize secrets. Helm-only "
        "tags without this GitHub Release must not be finalized or stamped."
    ),
}
json.dump(doc, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
open(sys.argv[1], "a", encoding="utf-8").write("\n")
PY

echo "Compose bundle: ${OUT_DIR}/${BUNDLE_NAME} (sha256:${BUNDLE_SHA256})"
echo "public-release.json: ${OUT_DIR}/public-release.json"
