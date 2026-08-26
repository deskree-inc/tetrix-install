#!/usr/bin/env bash
# Fetch the Tetrix Compose bundle without cloning the full installer repository.
#
# TWO EXPLICIT MODES, no default. Downloading whatever is on `main` used to be
# what this script did when invoked with only a destination — convenient, and
# exactly wrong for an install someone has to support: `main` is not a release,
# has no checksum, and changes under you. The unversioned path is now opt-in and
# named `--dev-main`; production takes an exact version and the SHA-256 published
# with the GitHub release asset.
#
# Usage:
#   ./scripts/download.sh --dev-main /opt/tetrix
#   ./scripts/download.sh --version 0.8.41 --sha256 "$COMPOSE_BUNDLE_SHA256" /opt/tetrix
#
# This public repo's root IS the compose bundle. Release assets are named
# deploy-docker-<version>.tgz on deskree-inc/tetrix-install.
set -euo pipefail

REPO="${TETRIX_DOCKER_GITHUB:-deskree-inc/tetrix-install}"
BRANCH="${TETRIX_DOCKER_BRANCH:-main}"

MODE=""
VERSION=""
SHA256=""
DEST=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/download.sh --dev-main <destination-dir>
  ./scripts/download.sh --version <x.y.z> --sha256 <hex64> <destination-dir>

  --dev-main            Development only: copy this repository's default
                        branch. Unversioned and unverified.
  --version <x.y.z>     Release version to install (no leading v).
  --sha256 <hex64>      Expected SHA-256 of deploy-docker-<version>.tgz,
                        published with the GitHub release.

  Exactly one mode is required. An invocation with neither --dev-main nor both
  release arguments exits 2.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dev-main) MODE="dev-main"; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --sha256) SHA256="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) DEST="$1"; shift ;;
  esac
done

if [ -n "$VERSION" ] || [ -n "$SHA256" ]; then
  if [ "$MODE" = "dev-main" ]; then
    echo "ERROR: --dev-main cannot be combined with --version/--sha256." >&2
    exit 2
  fi
  if [ -z "$VERSION" ] || [ -z "$SHA256" ]; then
    echo "ERROR: --version and --sha256 must be supplied together." >&2
    usage >&2
    exit 2
  fi
  MODE="release"
fi

if [ -z "$MODE" ]; then
  echo "ERROR: choose a mode — --dev-main, or --version with --sha256." >&2
  usage >&2
  exit 2
fi
if [ -z "$DEST" ]; then
  echo "ERROR: a destination directory is required." >&2
  usage >&2
  exit 2
fi

if [ "$MODE" = "release" ]; then
  case "$VERSION" in
    *[!0-9.a-zA-Z-]*|"") echo "ERROR: implausible version: ${VERSION}" >&2; exit 2 ;;
  esac
  if ! printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "ERROR: --sha256 must be 64 lowercase hex characters." >&2
    exit 2
  fi

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/tetrix-release.XXXXXX")"
  trap 'rm -rf "$workdir"' EXIT
  bundle="${workdir}/deploy-docker-${VERSION}.tgz"
  url="https://github.com/${REPO}/releases/download/v${VERSION}/deploy-docker-${VERSION}.tgz"

  echo "Downloading ${url}..."
  curl -fsSL --connect-timeout 15 --max-time 600 \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "$url" -o "$bundle"

  # The download is untrusted input; install-release.sh is what verifies and
  # extracts it. This script never extracts a tar itself in release mode.
  installer=""
  self_dir=""
  if [ "${#BASH_SOURCE[@]}" -gt 0 ] && [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  for candidate in \
    ${self_dir:+"${self_dir}/install-release.sh"} \
    "${DEST}/scripts/install-release.sh"
  do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { installer="$candidate"; break; }
  done
  # curl | bash has no sibling script — fetch the verifier from this same repo.
  if [ -z "$installer" ]; then
    installer="${workdir}/install-release.sh"
    echo "Fetching install-release.sh from ${REPO}..."
    curl -fsSL --connect-timeout 15 --max-time 60 \
      "https://raw.githubusercontent.com/${REPO}/${BRANCH}/scripts/install-release.sh" \
      -o "$installer"
    chmod +x "$installer"
  fi
  # --allow-unsigned: the GitHub release asset has no signature envelope beside
  # it. The operator supplied the SHA out of band from the release notes, which
  # is the on-prem checksum trust model.
  exec "$installer" \
    --version "$VERSION" \
    --bundle "$bundle" \
    --sha256 "$SHA256" \
    --allow-unsigned \
    --destination "$DEST"
fi

# ── --dev-main ────────────────────────────────────────────────────────────────
# This repository's root IS the compose bundle (docker-compose.yml, scripts/,
# postgres/, traefik/, chart-scripts/ at the top level).
REPO_NAME="${REPO##*/}"
ARCHIVE_DIR="${REPO_NAME}-${BRANCH}"
mkdir -p "$DEST"

echo "DEVELOPMENT DOWNLOAD: unversioned ${BRANCH} of ${REPO}, no checksum." >&2

if command -v git >/dev/null 2>&1 && [[ "${TETRIX_DOCKER_METHOD:-}" == "git" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  git clone --depth 1 --branch "$BRANCH" \
    "https://github.com/${REPO}.git" "$tmpdir/repo"
  cp -a "$tmpdir/repo/." "$DEST/"
  rm -rf "$DEST/.git"
else
  tmptar="$(mktemp)"
  trap 'rm -f "$tmptar"' EXIT
  echo "Downloading ${REPO} (${BRANCH})..."
  curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" -o "$tmptar"
  tar -xzf "$tmptar" --strip-components=1 -C "$DEST" "${ARCHIVE_DIR}"
fi

chmod +x "$DEST/scripts/"*.sh "$DEST/chart-scripts/"*.sh "$DEST/postgres/initdb/"*.sh 2>/dev/null || true

cat <<EOF

Ready in: $(cd "$DEST" && pwd)

Next:
  cd $(cd "$DEST" && pwd)
  ./scripts/setup.sh

EOF
