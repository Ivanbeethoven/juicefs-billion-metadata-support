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

mount_point="$(findmnt -no TARGET --target "$DATA_ROOT" 2>/dev/null | head -n 1 || true)"
mount_opts="$(findmnt -no OPTIONS --target "$DATA_ROOT" 2>/dev/null | head -n 1 || true)"
if [ -n "$mount_point" ] && [ "$mount_point" != "/" ]; then
  case ",${mount_opts}," in
    *,noatime,*) ;;
    *) run mount -o remount,noatime "$mount_point" || true ;;
  esac

  if [ -f /etc/fstab ]; then
    tmp_fstab="$(mktemp)"
    awk -v mp="$mount_point" '
      $2 == mp && $4 !~ /(^|,)noatime(,|$)/ {
        $4 = $4 ",noatime"
      }
      { print }
    ' /etc/fstab >"$tmp_fstab"
    run install -m 0644 "$tmp_fstab" /etc/fstab
    rm -f "$tmp_fstab"
  fi
fi

tmp_limits="$(mktemp)"
cat >"$tmp_limits" <<EOF
${TIKV_USER} soft nofile 1000000
${TIKV_USER} hard nofile 1000000
${TIKV_USER} soft stack 10240
EOF
run install -m 0644 "$tmp_limits" /etc/security/limits.d/99-tikv.conf
rm -f "$tmp_limits"

run mkdir -p /etc/selinux
tmp_selinux="$(mktemp)"
cat >"$tmp_selinux" <<'EOF'
SELINUX=disabled
SELINUXTYPE=targeted
EOF
run install -m 0644 "$tmp_selinux" /etc/selinux/config
rm -f "$tmp_selinux"
if command -v getenforce >/dev/null 2>&1 && command -v setenforce >/dev/null 2>&1; then
  selinux_status="$(getenforce 2>/dev/null || true)"
  if [ "$selinux_status" = "Enforcing" ] || [ "$selinux_status" = "Permissive" ]; then
    run setenforce 0 || true
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  run systemctl enable --now irqbalance >/dev/null 2>&1 || true
fi

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
