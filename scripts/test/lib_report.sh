#!/usr/bin/env bash

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

kv_get() {
  key="$1"
  file="$2"
  [ -s "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

kv_exit_code() {
  value="$(kv_get exit_code "$1")"
  printf '%s\n' "${value:-1}"
}

kv_success() {
  [ -s "$1" ] && [ "$(kv_exit_code "$1")" = "0" ]
}

max_number() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { print (b > a ? b : a) }'
}

rate_number() {
  awk -v n="${1:-0}" -v d="${2:-0}" 'BEGIN { if (d > 0) printf "%.2f", n / d; else printf "0.00" }'
}

mib_rate_number() {
  awk -v n="${1:-0}" -v d="${2:-0}" 'BEGIN { if (d > 0) printf "%.2f", n / d / 1024 / 1024; else printf "0.00" }'
}

collect_node_info() {
  target="$1"
  output_file="$2"
  error_file="$3"
  phase="$4"

  [ "${COLLECT_NODE_INFO:-1}" = "1" ] || return 0

  ssh "${ssh_opts[@]}" "$target" \
    "META_URL=$(shell_quote "${META_URL:-}") MOUNT_POINT=$(shell_quote "${MOUNT_POINT:-}") PHASE=$(shell_quote "$phase") bash -s" \
    >"$output_file" 2>"$error_file" <<'REMOTE'
set +e
echo "phase=${PHASE}"
echo "captured_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo
echo "## host"
hostname -f 2>/dev/null || hostname
uptime
nproc 2>/dev/null || true
free -h 2>/dev/null || true

echo
echo "## juicefs"
command -v juicefs >/dev/null 2>&1 && juicefs version || true
if [ -n "$META_URL" ] && command -v juicefs >/dev/null 2>&1; then
  timeout 30 juicefs status "$META_URL" 2>&1 || true
fi

if [ -n "$MOUNT_POINT" ]; then
  echo
  echo "## mount"
  df -h "$MOUNT_POINT" 2>&1 || true
  mount | grep " $MOUNT_POINT " || true
fi

echo
echo "## top processes"
ps -eo pid,ppid,pcpu,pmem,etime,comm,args --sort=-pcpu 2>/dev/null | head -30 || true

echo
echo "## disk"
df -h 2>/dev/null || true
if command -v iostat >/dev/null 2>&1; then
  iostat -dx 1 2 2>/dev/null || true
fi

echo
echo "## network"
ss -s 2>/dev/null || true
REMOTE
}
