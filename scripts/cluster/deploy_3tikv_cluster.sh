#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-juicefs-tikv-3}"
TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TOPOLOGY="${TOPOLOGY:-tiup/topology.3tikv.example.yaml}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
PD_ENDPOINT="${PD_ENDPOINT:-}"
TIUP="${TIUP:-}"

if [ -z "$TIUP" ]; then
  if [ -x "$HOME/.tiup/bin/tiup" ]; then
    TIUP="$HOME/.tiup/bin/tiup"
  else
    TIUP="tiup"
  fi
fi

if [ ! -f "$TOPOLOGY" ]; then
  echo "topology file not found: ${TOPOLOGY}" >&2
  exit 1
fi

cluster_exists() {
  "$TIUP" cluster list 2>/dev/null | awk -v name="$CLUSTER_NAME" 'NR > 1 && $1 == name { found = 1 } END { exit(found ? 0 : 1) }'
}

ssh_args=(--user "$SSH_USER")
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  ssh_args+=(-i "$SSH_KEY")
fi

if cluster_exists; then
  echo "cluster exists: ${CLUSTER_NAME}; skip deploy"
else
  "$TIUP" cluster check "$TOPOLOGY" "${ssh_args[@]}"
  "$TIUP" cluster check "$TOPOLOGY" --apply "${ssh_args[@]}"
  "$TIUP" cluster deploy "$CLUSTER_NAME" "$TIDB_VERSION" "$TOPOLOGY" "${ssh_args[@]}" --yes
fi

"$TIUP" cluster start "$CLUSTER_NAME"
"$TIUP" cluster display "$CLUSTER_NAME"

if [ -n "$PD_ENDPOINT" ]; then
  "$TIUP" "ctl:${TIDB_VERSION}" pd -u "$PD_ENDPOINT" member
  "$TIUP" "ctl:${TIDB_VERSION}" pd -u "$PD_ENDPOINT" store
fi
