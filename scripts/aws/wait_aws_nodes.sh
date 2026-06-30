#!/usr/bin/env bash
set -euo pipefail

JUICEFS_TEST_HOSTS="${JUICEFS_TEST_HOSTS:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"
WAIT_INTERVAL="${WAIT_INTERVAL:-15}"

if [ -z "$JUICEFS_TEST_HOSTS" ]; then
  echo "JUICEFS_TEST_HOSTS is required" >&2
  exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))

for host in $JUICEFS_TEST_HOSTS; do
  target="${SSH_USER}@${host}"
  echo "waiting for bootstrap on ${target}"
  while true; do
    if ssh "${ssh_opts[@]}" "$target" "test -f /var/log/juicefs-bootstrap.done && juicefs version" >/dev/null 2>&1; then
      echo "ready: ${target}"
      break
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timeout waiting for ${target}" >&2
      exit 1
    fi
    sleep "$WAIT_INTERVAL"
  done
done
