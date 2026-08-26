#!/usr/bin/env bash
# Keep the registry credential fresh on a compose host (ADR-0024).
#
# The credential expires within the hour. Kubernetes gets a CronJob for this; a
# compose host has no scheduler, so this installs one — a systemd timer where
# systemd is available, a crontab entry otherwise. Both run
# ./scripts/registry-login.sh every 30 minutes, matching the chart's
# `registryBroker.schedule` default.
#
# WHY 30 MINUTES AND NOT 55: a single missed run must not be an outage. At */55
# one failure leaves the host unable to pull until someone notices.
#
# The units are GENERATED rather than checked in, because they need absolute
# paths and the invoking user, neither of which is knowable in the repo.
#
# Idempotent. Run with --uninstall to remove everything it created.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── Cloud mode is refused outright ────────────────────────────────────────────
# A Tetrix Cloud VM has no long-lived registry credential to keep fresh: the
# deployment license IS the credential and registry-login.sh uses it just in time,
# in tmpfs, for the duration of one pull. Installing this timer there would
# create exactly what the design removes — a credential sitting in a persistent
# Docker config, refreshed on a schedule, outside any pull that needed it. It
# would also fight cloud-up.sh, which deletes /run/tetrix/docker after each pull.
CLOUD_ENV="${TETRIX_CLOUD_ENV:-/etc/tetrix/cloud.env}"
CRED_MODE="${TETRIX_DEPLOYMENT_MODE:-}"
if [ -z "$CRED_MODE" ] && [ -r "$CLOUD_ENV" ]; then
  CRED_MODE="$(sed -n 's/^TETRIX_DEPLOYMENT_MODE=//p' "$CLOUD_ENV" | head -1)"
fi
if [ "${CRED_MODE:-dev}" = "cloud" ]; then
  cat >&2 <<'EOF'
ERROR: this timer is refused in cloud mode.

Tetrix Cloud has no broker credential to refresh. The deployment license is the
registry password and the deployment UUID is the username; scripts/cloud-up.sh
calls registry-login.sh --pull, which logs in to a tmpfs Docker config, pulls the
pinned digests, logs out, and deletes the config. Nothing is left to expire.

Use the installed units instead:
  sudo /opt/tetrix/scripts/install-cloud-units.sh
EOF
  exit 2
fi

UNIT_NAME="tetrix-registry-login"
LOGIN_SH="${ROOT}/scripts/registry-login.sh"
RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
UNINSTALL=false

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/install-credential-timer.sh [--uninstall]

  Installs a systemd timer (or a crontab entry) that re-runs
  scripts/registry-login.sh every 30 minutes, so 'docker compose pull' on this
  host always has a valid credential.

  Needs sudo for the systemd path (it writes /etc/systemd/system/${UNIT_NAME}.*).
  Without systemd it falls back to the crontab of ${RUN_USER}.

  --uninstall  remove the timer/unit or the crontab line.
EOF
      exit 0 ;;
  esac
done

have_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

# ── cron fallback ─────────────────────────────────────────────────────────────
CRON_MARK="# tetrix-registry-login (ADR-0024 credential refresh)"
cron_install() {
  local line="*/30 * * * * cd ${ROOT} && ${LOGIN_SH} >/dev/null 2>&1 ${CRON_MARK}"
  local current
  current="$(crontab -l 2>/dev/null || true)"
  # Strip any previous entry first so re-running never stacks duplicates.
  printf '%s\n' "$current" | grep -vF "$CRON_MARK" | grep -v '^$' > /tmp/tetrix-cron.$$ || true
  printf '%s\n' "$line" >> /tmp/tetrix-cron.$$
  crontab /tmp/tetrix-cron.$$
  rm -f /tmp/tetrix-cron.$$
  echo "Installed a crontab entry for ${RUN_USER} (every 30 minutes)."
  echo "Remove it with: ./scripts/install-credential-timer.sh --uninstall"
}
cron_uninstall() {
  local current
  current="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$current" | grep -qF "$CRON_MARK"; then
    # `|| true` goes on the FILTER only, never on the write — same shape as
    # cron_install above. When our line is the crontab's ONLY entry (the normal
    # case, since this script is the only thing that adds one) grep -v matches
    # nothing and exits 1; pipefail would promote that to the pipeline's status and
    # set -e would abort AFTER the removal succeeded, so --uninstall reported
    # failure on success. Wrapping the whole pipeline instead would fix that by
    # also swallowing a genuine `crontab -` write failure — reporting "Removed"
    # when nothing was removed. Filter separately, then write with its status live.
    local remaining
    remaining="$(printf '%s\n' "$current" | grep -vF "$CRON_MARK" || true)"
    printf '%s\n' "$remaining" | crontab -
    echo "Removed the crontab entry."
  else
    echo "No crontab entry to remove."
  fi
}

# ── systemd ───────────────────────────────────────────────────────────────────
systemd_install() {
  local svc="/etc/systemd/system/${UNIT_NAME}.service"
  local tmr="/etc/systemd/system/${UNIT_NAME}.timer"

  sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=Refresh the Tetrix registry pull credential (ADR-0024)
Documentation=https://github.com/deskree-inc/tetrix-install/blob/main/README.md
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
# Runs as the operator, NOT root: 'docker login' writes to that user's
# ~/.docker/config.json, and that is the config 'docker compose pull' reads.
User=${RUN_USER}
WorkingDirectory=${ROOT}
ExecStart=${LOGIN_SH}
EOF

  sudo tee "$tmr" >/dev/null <<EOF
[Unit]
Description=Refresh the Tetrix registry pull credential every 30 minutes
Documentation=https://github.com/deskree-inc/tetrix-install/blob/main/README.md

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
# A host that was asleep past the credential's lifetime must refresh on wake
# rather than wait out the next interval.
Persistent=true
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now "${UNIT_NAME}.timer"
  echo "Installed and started ${UNIT_NAME}.timer (every 30 minutes, as ${RUN_USER})."
  echo "  status:  systemctl status ${UNIT_NAME}.timer"
  echo "  logs:    journalctl -u ${UNIT_NAME}.service"
  echo "  remove:  ./scripts/install-credential-timer.sh --uninstall"
}
systemd_uninstall() {
  sudo systemctl disable --now "${UNIT_NAME}.timer" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/${UNIT_NAME}.service" "/etc/systemd/system/${UNIT_NAME}.timer"
  sudo systemctl daemon-reload
  echo "Removed ${UNIT_NAME}.service and .timer."
}

if [ ! -x "$LOGIN_SH" ]; then
  echo "ERROR: ${LOGIN_SH} is missing or not executable." >&2
  exit 1
fi

if $UNINSTALL; then
  if have_systemd; then systemd_uninstall; else cron_uninstall; fi
  exit 0
fi

if have_systemd; then
  systemd_install
else
  echo "systemd not detected — falling back to cron."
  if ! command -v crontab >/dev/null 2>&1; then
    echo "ERROR: neither systemd nor crontab is available." >&2
    echo "Re-run ./scripts/registry-login.sh by hand before 'docker compose pull'." >&2
    exit 1
  fi
  cron_install
fi
