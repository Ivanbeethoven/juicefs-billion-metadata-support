#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-juicefs-prod}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/juicefs-prod}"
CACHE_DIR="${CACHE_DIR:-/var/lib/juicefs/cache}"
CACHE_SIZE="${CACHE_SIZE:-102400}"
JUICEFS_BIN="${JUICEFS_BIN:-/usr/local/bin/juicefs}"

if [ -z "${META_URL:-}" ]; then
  echo "META_URL is required" >&2
  exit 1
fi

run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

run mkdir -p "$MOUNT_POINT" "$CACHE_DIR"

tmp_service="$(mktemp)"
cat >"$tmp_service" <<EOF
[Unit]
Description=JuiceFS mount ${SERVICE_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=META_URL=${META_URL}
ExecStart=${JUICEFS_BIN} mount -d --cache-dir ${CACHE_DIR} --cache-size ${CACHE_SIZE} \${META_URL} ${MOUNT_POINT}
ExecStop=${JUICEFS_BIN} umount ${MOUNT_POINT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

run install -m 0644 "$tmp_service" "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "$tmp_service"

run systemctl daemon-reload
run systemctl enable --now "${SERVICE_NAME}.service"
run systemctl status "${SERVICE_NAME}.service" --no-pager
