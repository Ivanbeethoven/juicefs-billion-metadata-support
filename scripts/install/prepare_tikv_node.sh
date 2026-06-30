#!/usr/bin/env bash
set -euo pipefail

TIKV_USER="${TIKV_USER:-tikv}"
DATA_ROOT="${DATA_ROOT:-/data/tikv}"

run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! id "$TIKV_USER" >/dev/null 2>&1; then
  run useradd -m -s /bin/bash "$TIKV_USER"
fi

run mkdir -p "${DATA_ROOT}/deploy" "${DATA_ROOT}/data"
run chown -R "${TIKV_USER}:${TIKV_USER}" "$DATA_ROOT"

run swapoff -a || true
if [ -f /etc/fstab ]; then
  run sed -i.bak '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
fi

tmp_sysctl="$(mktemp)"
cat >"$tmp_sysctl" <<'EOF'
vm.swappiness = 0
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
EOF
run install -m 0644 "$tmp_sysctl" /etc/sysctl.d/99-tikv.conf
rm -f "$tmp_sysctl"
run sysctl --system

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never | run tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
fi

if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo never | run tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null
fi

echo "prepared TiKV node at ${DATA_ROOT} for user ${TIKV_USER}"
