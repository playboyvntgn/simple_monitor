#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="vps-heartbeat"
CONFIG_DIR="/etc/vps-heartbeat"
CONFIG_FILE="${CONFIG_DIR}/config"
UNIT_DIR="/etc/systemd/system"

usage() {
  printf 'Usage: sudo bash %s [HEALTHCHECK_URL]\n' "$0"
  printf 'If HEALTHCHECK_URL is omitted, the installer prompts for it.\n'
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  printf 'Error: run this installer as root (sudo).\n' >&2
  exit 1
fi

if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
  printf 'Error: this VPS is not running systemd.\n' >&2
  exit 1
fi

healthcheck_url=${1:-}
if [[ -z "$healthcheck_url" ]]; then
  if [[ ! -r /dev/tty ]]; then
    printf 'Error: pass the Healthchecks.io ping URL as the first argument.\n' >&2
    usage >&2
    exit 1
  fi
  read -r -p 'Healthchecks.io ping URL: ' healthcheck_url </dev/tty
fi

if [[ ! "$healthcheck_url" =~ ^https://hc-ping\.com/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?/?$ ]]; then
  printf 'Error: invalid Healthchecks.io ping URL.\n' >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl
  else
    printf 'Error: curl is missing and no supported package manager was found.\n' >&2
    exit 1
  fi
fi

install -d -m 0755 "$CONFIG_DIR"
printf 'HEALTHCHECK_URL=%s\n' "$healthcheck_url" >"$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

cat >"${UNIT_DIR}/${SERVICE_NAME}.service" <<'EOF'
[Unit]
Description=Send VPS heartbeat to Healthchecks.io
Wants=network-online.target
After=network-online.target tailscaled.service

[Service]
Type=oneshot
EnvironmentFile=/etc/vps-heartbeat/config
ExecStart=/usr/bin/curl --fail --silent --show-error --max-time 20 --retry 2 --request POST ${HEALTHCHECK_URL}
DynamicUser=yes
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
EOF

cat >"${UNIT_DIR}/${SERVICE_NAME}.timer" <<'EOF'
[Unit]
Description=Send VPS heartbeat every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=5s
RandomizedDelaySec=10s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemd-analyze verify \
  "${UNIT_DIR}/${SERVICE_NAME}.service" \
  "${UNIT_DIR}/${SERVICE_NAME}.timer"
systemctl enable --now "${SERVICE_NAME}.timer"
systemctl start "${SERVICE_NAME}.service"

result=$(systemctl show "${SERVICE_NAME}.service" --property=Result --value)
status=$(systemctl show "${SERVICE_NAME}.service" --property=ExecMainStatus --value)
if [[ "$result" != "success" || "$status" != "0" ]]; then
  journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager >&2
  printf 'Error: heartbeat test failed.\n' >&2
  exit 1
fi

printf '\nInstalled successfully.\n'
printf '  Heartbeat test: OK\n'
printf '  Timer: enabled and running\n'
printf '  Config: %s\n' "$CONFIG_FILE"
printf '\nCheck status with:\n'
printf '  systemctl status %s.timer --no-pager\n' "$SERVICE_NAME"
printf '  journalctl -u %s.service -n 20 --no-pager\n' "$SERVICE_NAME"
