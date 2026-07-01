#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME:-slayerfs-rustfs}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/juicefs-aws-deploy}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env file not found: ${ENV_FILE}" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

if [ -z "${CONTROL_HOST:-}" ]; then
  echo "CONTROL_HOST is required in ${ENV_FILE}" >&2
  exit 1
fi

if [ -z "${SSH_USER:-}" ]; then
  echo "SSH_USER is required in ${ENV_FILE}" >&2
  exit 1
fi

if [ -z "${SSH_KEY:-}" ] || [ ! -f "$SSH_KEY" ]; then
  echo "SSH_KEY must point to a readable private key" >&2
  exit 1
fi

if [ -n "${TOPOLOGY:-}" ] && [ ! -f "$TOPOLOGY" ] && [ -f "${REPO_ROOT}/${TOPOLOGY}" ]; then
  TOPOLOGY="${REPO_ROOT}/${TOPOLOGY}"
fi

if [ -z "${TOPOLOGY:-}" ] || [ ! -f "$TOPOLOGY" ]; then
  echo "TOPOLOGY must point to a readable TiUP topology file" >&2
  exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY")
control="${SSH_USER}@${CONTROL_HOST}"
remote_key="${REMOTE_DIR}/ssh_key.pem"

"${SCRIPT_DIR}/wait_aws_nodes.sh"

ssh "${ssh_opts[@]}" "$control" "rm -rf '${REMOTE_DIR}' && mkdir -p '${REMOTE_DIR}'"
scp "${ssh_opts[@]}" "${REPO_ROOT}/scripts/install/install_tiup_binary.sh" "${REPO_ROOT}/scripts/cluster/deploy_3tikv_cluster.sh" "${REPO_ROOT}/scripts/cluster/format_juicefs.sh" "$control:${REMOTE_DIR}/"
scp "${ssh_opts[@]}" "$TOPOLOGY" "$control:${REMOTE_DIR}/topology.yaml"
scp "${ssh_opts[@]}" "$SSH_KEY" "$control:${remote_key}"

tmp_env="$(mktemp)"
trap 'rm -f "$tmp_env"' EXIT

cat >"$tmp_env" <<EOF
TIDB_VERSION=${TIDB_VERSION}
TIDB_ARCH=${TIDB_ARCH}
TIUP_INSTALL_MODE=${TIUP_INSTALL_MODE:-offline}
CLUSTER_NAME=${CLUSTER_NAME}
TOPOLOGY=${REMOTE_DIR}/topology.yaml
SSH_USER=${SSH_USER}
SSH_KEY=${remote_key}
PD_ENDPOINT=${PD_ENDPOINT}
JFS_NAME=${JFS_NAME}
META_URL=${META_URL}
JFS_STORAGE=${JFS_STORAGE}
JFS_BUCKET=${JFS_BUCKET}
JFS_ACCESS_KEY=${JFS_ACCESS_KEY}
JFS_SECRET_KEY=${JFS_SECRET_KEY}
JFS_TRASH_DAYS=${JFS_TRASH_DAYS:-0}
EOF

scp "${ssh_opts[@]}" "$tmp_env" "$control:${REMOTE_DIR}/deploy.env"
ssh "${ssh_opts[@]}" "$control" "chmod 600 '${remote_key}' '${REMOTE_DIR}/deploy.env' && chmod +x '${REMOTE_DIR}'/*.sh"
ssh "${ssh_opts[@]}" "$control" "cd '${REMOTE_DIR}' && set -a && . ./deploy.env && set +a && trap 'rm -f \"\$SSH_KEY\" ./deploy.env' EXIT && ./install_tiup_binary.sh && ./deploy_3tikv_cluster.sh && ./format_juicefs.sh"
