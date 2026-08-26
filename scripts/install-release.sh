#!/usr/bin/env bash
# install-release.sh — verify and install an exact release bundle. OFFLINE.
#
# This is the only code path that turns bytes into an installed Tetrix project.
# It takes files, never URLs: on a tenant VM the OCI installer image has already
# been pulled by digest and its contents are mounted read-only, so anything this
# script could fetch would be a second, weaker trust path. On-prem, download.sh
# does the fetching and hands the local file here.
#
# It also refuses a populated destination. In-place upgrades belong to the
# updater (ADR-0022): it snapshots pins, backs the stack up, applies, health-
# gates and rolls back. Untarring a new release over a running project skips all
# of that, so "install" means "install", once.
#
# Verification order — every step happens BEFORE a single member is extracted:
#   1. arguments are files, the version is plausible, the destination is empty
#   2. the Deskree Ops Ed25519 signature over the exact manifest bytes
#   3. the manifest's own SHA-256, when the envelope carries one
#   4. the manifest's compose.bundle_sha256 == --sha256 == sha256(bundle)
#   5. tar safety: one expected root, no absolute path, no "..", no links out
#   6. the bundle's VERSION equals --version
set -euo pipefail
umask 077

VERSION=""
BUNDLE=""
SHA256=""
MANIFEST=""
SIGNATURE=""
KID=""
KEYS="${TETRIX_RELEASE_KEYS:-/opt/tetrix-installer/deskree-ops-release-keys.json}"
DESTINATION=""
ALLOW_UNSIGNED=0

die()  { echo "ERROR: $*" >&2; exit 1; }
usage_die() { echo "ERROR: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: install-release.sh --version <x.y.z> --bundle <file> --sha256 <hex64>
                          --destination <empty-or-absent-dir>
                          [--manifest <file> --signature <file> --kid <id>
                           --keys <json>] [--allow-unsigned]

  --bundle       Local deploy-docker-<version>.tgz. A URL is refused.
  --sha256       Expected SHA-256 of that file (compose.bundle_sha256).
  --manifest     The exact release-manifest.json bytes Deskree Ops signed.
  --signature    Detached Ed25519 signature over those bytes (raw or base64).
  --kid          Key id naming the verifying key in --keys.
  --keys         {"kid": "<PEM public key>"} trust store. Default:
                 /opt/tetrix-installer/deskree-ops-release-keys.json
  --allow-unsigned
                 On-prem escape hatch: install with checksum verification only.
                 Refused when TETRIX_DEPLOYMENT_MODE=cloud.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --sha256) SHA256="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --signature) SIGNATURE="${2:-}"; shift 2 ;;
    --kid) KID="${2:-}"; shift 2 ;;
    --keys) KEYS="${2:-}"; shift 2 ;;
    --destination) DESTINATION="${2:-}"; shift 2 ;;
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done

# ── 1. Arguments ──────────────────────────────────────────────────────────────
[ -n "$VERSION" ] || usage_die "--version is required"
[ -n "$BUNDLE" ] || usage_die "--bundle is required"
[ -n "$SHA256" ] || usage_die "--sha256 is required"
[ -n "$DESTINATION" ] || usage_die "--destination is required"

case "$VERSION" in
  *[!0-9.a-zA-Z-]*) usage_die "implausible version: ${VERSION}" ;;
esac
printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' \
  || usage_die "--sha256 must be 64 lowercase hex characters"

for arg in "$BUNDLE" "$MANIFEST" "$SIGNATURE" "$KEYS"; do
  case "$arg" in
    ""|/*|./*|../*) ;;
    *://*) usage_die "network arguments are refused; pass a local file: ${arg}" ;;
  esac
  case "$arg" in
    http://*|https://*|ftp://*|file://*) usage_die "network arguments are refused: ${arg}" ;;
  esac
done
[ -f "$BUNDLE" ] || usage_die "--bundle is not a file: ${BUNDLE}"

if [ -e "$DESTINATION" ]; then
  [ -d "$DESTINATION" ] || die "destination exists and is not a directory: ${DESTINATION}"
  if [ -n "$(ls -A "$DESTINATION" 2>/dev/null)" ]; then
    die "destination is not empty: ${DESTINATION}
  In-place upgrades are the updater's job (ADR-0022): it snapshots pins, takes a
  full pre-upgrade backup, applies, health-gates and rolls back. Extracting over
  a live project does none of that. Remove or move the directory to reinstall."
  fi
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ── 2 and 3. Signed envelope ──────────────────────────────────────────────────
if [ -n "$MANIFEST" ] || [ -n "$SIGNATURE" ] || [ -n "$KID" ]; then
  [ -n "$MANIFEST" ] && [ -n "$SIGNATURE" ] && [ -n "$KID" ] \
    || usage_die "--manifest, --signature and --kid must be supplied together"
  [ -f "$MANIFEST" ] || die "manifest is not a file: ${MANIFEST}"
  [ -f "$SIGNATURE" ] || die "signature is not a file: ${SIGNATURE}"
  [ -f "$KEYS" ] || die "release key store is not a file: ${KEYS}"
  command -v openssl >/dev/null 2>&1 || die "openssl is required to verify the release signature"

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/tetrix-verify.XXXXXX")"
  trap 'rm -rf "$workdir"' EXIT

  # The key store is {kid: PEM}; extract exactly the named key and nothing else.
  if ! python3 - "$KEYS" "$KID" "${workdir}/key.pem" <<'PY'
import json, pathlib, sys
store = json.loads(pathlib.Path(sys.argv[1]).read_text())
keys = store.get("keys", store)
pem = keys.get(sys.argv[2])
if not isinstance(pem, str) or "PUBLIC KEY" not in pem:
    sys.exit(1)
pathlib.Path(sys.argv[3]).write_text(pem if pem.endswith("\n") else pem + "\n")
PY
  then
    die "release signing key '${KID}' is not in the trust store"
  fi

  # Accept a raw 64-byte signature or a base64 one; normalise to raw bytes.
  if ! python3 - "$SIGNATURE" "${workdir}/sig.bin" <<'PY'
import base64, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
if len(raw) != 64:
    try:
        raw = base64.b64decode(raw.strip(), validate=True)
    except Exception:
        sys.exit(1)
if len(raw) != 64:
    sys.exit(1)
pathlib.Path(sys.argv[2]).write_bytes(raw)
PY
  then
    die "release signature is not a 64-byte Ed25519 signature"
  fi

  if ! openssl pkeyutl -verify -pubin -inkey "${workdir}/key.pem" \
        -rawin -in "$MANIFEST" -sigfile "${workdir}/sig.bin" >/dev/null 2>&1; then
    die "release signature does not verify for kid ${KID}"
  fi
  echo "Verified Deskree Ops release signature (kid ${KID})"

  # The manifest must describe THIS version and THIS bundle. A valid signature
  # over some other release is exactly the substitution this check exists for.
  manifest_sha="$(sha256_of "$MANIFEST")"
  if ! python3 - "$MANIFEST" "$VERSION" "$SHA256" <<'PY'
import json, pathlib, sys
m = json.loads(pathlib.Path(sys.argv[1]).read_text())
if m.get("schema") != "tetrix-release-manifest.v1":
    sys.exit(1)
if str(m.get("version")) != sys.argv[2]:
    sys.exit(1)
if (m.get("compose") or {}).get("bundle_sha256") != sys.argv[3]:
    sys.exit(1)
PY
  then
    die "signed manifest does not describe version ${VERSION} with the given bundle checksum"
  fi
  echo "Manifest sha256:${manifest_sha} describes ${VERSION}"
elif [ "$ALLOW_UNSIGNED" -eq 1 ]; then
  [ "${TETRIX_DEPLOYMENT_MODE:-dev}" = "cloud" ] \
    && die "--allow-unsigned is refused in cloud mode"
  echo "WARNING: installing with checksum verification only (--allow-unsigned)." >&2
else
  usage_die "supply --manifest/--signature/--kid, or --allow-unsigned outside cloud mode"
fi

# ── 4. Bundle checksum ────────────────────────────────────────────────────────
actual="$(sha256_of "$BUNDLE")"
if [ "$actual" != "$SHA256" ]; then
  echo "ERROR: bundle checksum mismatch" >&2
  echo "  expected ${SHA256}" >&2
  echo "  actual   ${actual}" >&2
  exit 1
fi
echo "Bundle checksum matches (sha256:${actual})"

# ── 5. Tar safety ─────────────────────────────────────────────────────────────
EXPECTED_ROOT="deploy-docker-${VERSION}"
if ! python3 - "$BUNDLE" "$EXPECTED_ROOT" <<'PY'
import posixpath, sys, tarfile

path, root = sys.argv[1], sys.argv[2]
problems = []
with tarfile.open(path, "r:gz") as tf:
    members = tf.getmembers()
    if not members:
        problems.append("archive is empty")
    for m in members:
        name = m.name
        if name.startswith("/") or ":" in name.split("/")[0]:
            problems.append(f"absolute member: {name}")
            continue
        parts = posixpath.normpath(name).split("/")
        if ".." in parts:
            problems.append(f"traversing member: {name}")
            continue
        if parts[0] != root:
            problems.append(f"unexpected archive root: {parts[0]}")
            continue
        if m.isdev() or m.ischr() or m.isblk() or m.isfifo():
            problems.append(f"device/fifo member: {name}")
        if m.issym() or m.islnk():
            target = m.linkname
            if target.startswith("/"):
                problems.append(f"absolute link: {name} -> {target}")
            else:
                resolved = posixpath.normpath(
                    posixpath.join(posixpath.dirname(name), target))
                if resolved.startswith("..") or resolved.split("/")[0] != root:
                    problems.append(f"escaping link: {name} -> {target}")
for p in problems[:10]:
    print(p, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
then
  die "release bundle contains unsafe tar members; nothing was extracted"
fi
echo "Archive members are safe (single root ${EXPECTED_ROOT}/)"

# ── 6. Extract to staging, verify VERSION, then install atomically ────────────
parent="$(dirname "$DESTINATION")"
mkdir -p "$parent"
stage="$(mktemp -d "${parent}/.tetrix-install.XXXXXX")"
cleanup_stage() { rm -rf "$stage"; }
trap 'cleanup_stage' EXIT

tar -xzf "$BUNDLE" -C "$stage"
bundle_dir="${stage}/${EXPECTED_ROOT}"
[ -d "$bundle_dir" ] || die "extracted archive has no ${EXPECTED_ROOT}/ directory"

got_version="$(tr -d '[:space:]' <"${bundle_dir}/VERSION" 2>/dev/null || true)"
[ "$got_version" = "$VERSION" ] \
  || die "bundle VERSION is '${got_version}', expected '${VERSION}'"

chmod 0755 "$bundle_dir"
find "${bundle_dir}/scripts" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
find "${bundle_dir}/chart-scripts" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
find "${bundle_dir}/postgres/initdb" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true

if [ -d "$DESTINATION" ]; then
  # Empty directory (checked above) — move the contents in, keeping the
  # caller's inode, ownership and any mount point.
  (cd "$bundle_dir" && tar -cf - .) | (cd "$DESTINATION" && tar -xf -)
else
  mv "$bundle_dir" "$DESTINATION"
fi

echo "Installed Tetrix ${VERSION} into ${DESTINATION}"
