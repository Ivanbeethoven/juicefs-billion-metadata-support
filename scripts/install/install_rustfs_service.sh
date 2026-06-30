#!/usr/bin/env bash
set -euo pipefail

RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-rustfsadmin}"
RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-rustfsadmin}"
RUSTFS_DATA_DIR="${RUSTFS_DATA_DIR:-/data/rustfs/data}"
RUSTFS_LOG_DIR="${RUSTFS_LOG_DIR:-/var/logs/rustfs}"
RUSTFS_ADDRESS="${RUSTFS_ADDRESS:-:9000}"
RUSTFS_CONSOLE_ADDRESS="${RUSTFS_CONSOLE_ADDRESS:-:9001}"
RUSTFS_BIN="${RUSTFS_BIN:-/usr/local/bin/rustfs}"

run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [ ! -x "$RUSTFS_BIN" ]; then
  echo "rustfs binary not found: ${RUSTFS_BIN}" >&2
  exit 1
fi

run mkdir -p "$RUSTFS_DATA_DIR" "$RUSTFS_LOG_DIR"
run chmod 750 "$RUSTFS_DATA_DIR" "$RUSTFS_LOG_DIR"

tmp_env="$(mktemp)"
cat >"$tmp_env" <<EOF
RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY}
RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY}
RUSTFS_VOLUMES="${RUSTFS_DATA_DIR}"
RUSTFS_ADDRESS="${RUSTFS_ADDRESS}"
RUSTFS_CONSOLE_ADDRESS="${RUSTFS_CONSOLE_ADDRESS}"
RUSTFS_CONSOLE_ENABLE=true
RUST_LOG=error
RUSTFS_OBS_LOG_DIRECTORY="${RUSTFS_LOG_DIR}"
EOF
run install -m 0600 "$tmp_env" /etc/default/rustfs
rm -f "$tmp_env"

tmp_service="$(mktemp)"
cat >"$tmp_service" <<'EOF'
[Unit]
Description=RustFS Object Storage Server
Documentation=https://docs.rustfs.com/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=main
User=root
Group=root
WorkingDirectory=/usr/local
EnvironmentFile=-/etc/default/rustfs
ExecStart=/usr/local/bin/rustfs $RUSTFS_VOLUMES
LimitNOFILE=1048576
LimitNPROC=32768
TasksMax=infinity
Restart=always
RestartSec=10s
OOMScoreAdjust=-1000
SendSIGKILL=no
TimeoutStartSec=60s
TimeoutStopSec=60s
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
StandardOutput=append:/var/logs/rustfs/rustfs.log
StandardError=append:/var/logs/rustfs/rustfs-err.log

[Install]
WantedBy=multi-user.target
EOF

run install -m 0644 "$tmp_service" /etc/systemd/system/rustfs.service
rm -f "$tmp_service"

run systemctl daemon-reload
run systemctl enable --now rustfs.service
run systemctl status rustfs.service --no-pager
