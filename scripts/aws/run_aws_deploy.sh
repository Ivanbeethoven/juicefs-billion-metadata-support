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

if [ -n "${SSH_KEY:-}" ] && [ ! -f "$SSH_KEY" ]; then
  echo "SSH_KEY points to a missing private key: ${SSH_KEY}" >&2
  exit 1
fi

if [ -n "${TOPOLOGY:-}" ] && [ ! -f "$TOPOLOGY" ] && [ -f "${REPO_ROOT}/${TOPOLOGY}" ]; then
  TOPOLOGY="${REPO_ROOT}/${TOPOLOGY}"
fi

if [ -z "${TOPOLOGY:-}" ] || [ ! -f "$TOPOLOGY" ]; then
  echo "TOPOLOGY must point to a readable TiUP topology file" >&2
  exit 1
fi

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TIDB_ARCH="${TIDB_ARCH:-amd64}"
TIUP_INSTALL_MODE="${TIUP_INSTALL_MODE:-offline}"
CLUSTER_NAME="${CLUSTER_NAME:-juicefs-tikv-3}"
JFS_NAME="${JFS_NAME:-juicefs-prod}"
JFS_STORAGE="${JFS_STORAGE:-s3}"
JFS_TRASH_DAYS="${JFS_TRASH_DAYS:-0}"
SERVICE_NAME="${SERVICE_NAME:-$JFS_NAME}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME}}"
CACHE_DIR="${CACHE_DIR:-/var/lib/juicefs/cache}"
CACHE_SIZE="${CACHE_SIZE:-102400}"
JUICEFS_VERSION="${JUICEFS_VERSION:-1.3.1}"
JUICEFS_ARCH="${JUICEFS_ARCH:-amd64}"
JUICEFS_INSTALL_DIR="${JUICEFS_INSTALL_DIR:-/usr/local/bin}"

for required_var in PD_ENDPOINT META_URL JFS_BUCKET JFS_ACCESS_KEY JFS_SECRET_KEY RUSTFS_ENDPOINT JUICEFS_TEST_HOSTS; do
  if [ -z "${!required_var:-}" ]; then
    echo "${required_var} is required in ${ENV_FILE}" >&2
    exit 1
  fi
done

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ssh_target() {
  if [ -n "${SSH_USER:-}" ]; then
    printf '%s@%s' "$SSH_USER" "$1"
  else
    printf '%s' "$1"
  fi
}

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "${SSH_KEY:-}" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi
control="$(ssh_target "$CONTROL_HOST")"
remote_key=""

if [ "${SKIP_WAIT:-0}" != "1" ]; then
  "${SCRIPT_DIR}/wait_aws_nodes.sh"
else
  echo "skip node bootstrap wait"
fi

ssh "${ssh_opts[@]}" "$control" "rm -rf '${REMOTE_DIR}' && mkdir -p '${REMOTE_DIR}'"
scp "${ssh_opts[@]}" "${REPO_ROOT}/scripts/install/install_tiup_binary.sh" "${REPO_ROOT}/scripts/install/install_juicefs_binary.sh" "${REPO_ROOT}/scripts/cluster/deploy_3tikv_cluster.sh" "${REPO_ROOT}/scripts/cluster/create_rustfs_bucket.sh" "${REPO_ROOT}/scripts/cluster/format_juicefs.sh" "$control:${REMOTE_DIR}/"
scp "${ssh_opts[@]}" "$TOPOLOGY" "$control:${REMOTE_DIR}/topology.yaml"
if [ -n "${SSH_KEY:-}" ]; then
  remote_key="${REMOTE_DIR}/ssh_key.pem"
  scp "${ssh_opts[@]}" "$SSH_KEY" "$control:${remote_key}"
fi

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
JUICEFS_VERSION=${JUICEFS_VERSION:-1.3.1}
JUICEFS_ARCH=${JUICEFS_ARCH:-amd64}
JUICEFS_INSTALL_DIR=${JUICEFS_INSTALL_DIR}
JFS_NAME=${JFS_NAME}
META_URL=${META_URL}
JFS_STORAGE=${JFS_STORAGE}
JFS_BUCKET=${JFS_BUCKET}
JFS_ACCESS_KEY=${JFS_ACCESS_KEY}
JFS_SECRET_KEY=${JFS_SECRET_KEY}
JFS_TRASH_DAYS=${JFS_TRASH_DAYS:-0}
RUSTFS_ENDPOINT=${RUSTFS_ENDPOINT}
RUSTFS_BUCKET=${RUSTFS_BUCKET:-juicefs-prod}
RUSTFS_ACCESS_KEY=${JFS_ACCESS_KEY}
RUSTFS_SECRET_KEY=${JFS_SECRET_KEY}
EOF

scp "${ssh_opts[@]}" "$tmp_env" "$control:${REMOTE_DIR}/deploy.env"
if [ -n "$remote_key" ]; then
  ssh "${ssh_opts[@]}" "$control" "chmod 600 '${remote_key}' '${REMOTE_DIR}/deploy.env' && chmod +x '${REMOTE_DIR}'/*.sh"
  cleanup_cmd='rm -f "$SSH_KEY" ./deploy.env'
else
  ssh "${ssh_opts[@]}" "$control" "chmod 600 '${REMOTE_DIR}/deploy.env' && chmod +x '${REMOTE_DIR}'/*.sh"
  cleanup_cmd='rm -f ./deploy.env'
fi
ssh "${ssh_opts[@]}" "$control" "cd '${REMOTE_DIR}' && set -a && . ./deploy.env && set +a && trap '${cleanup_cmd}' EXIT && ./install_tiup_binary.sh && ./deploy_3tikv_cluster.sh && ./install_juicefs_binary.sh && ./create_rustfs_bucket.sh && ./format_juicefs.sh"

if [ "${SKIP_MOUNT:-0}" = "1" ]; then
  echo "skip JuiceFS mount service installation"
  exit 0
fi

mount_env="$(mktemp)"
trap 'rm -f "$tmp_env" "$mount_env"' EXIT

cat >"$mount_env" <<EOF
SERVICE_NAME=${SERVICE_NAME}
MOUNT_POINT=${MOUNT_POINT}
CACHE_DIR=${CACHE_DIR}
CACHE_SIZE=${CACHE_SIZE}
JUICEFS_VERSION=${JUICEFS_VERSION:-1.3.1}
JUICEFS_ARCH=${JUICEFS_ARCH:-amd64}
JUICEFS_INSTALL_DIR=${JUICEFS_INSTALL_DIR}
JUICEFS_BIN=${JUICEFS_INSTALL_DIR}/juicefs
META_URL=${META_URL}
EOF

pids=""
for host in $JUICEFS_TEST_HOSTS; do
  target="$(ssh_target "$host")"
  echo "install JuiceFS mount service on ${target}"
  (
    ssh "${ssh_opts[@]}" "$target" "mkdir -p $(shell_quote "$REMOTE_DIR")"
    scp "${ssh_opts[@]}" "${REPO_ROOT}/scripts/install/install_juicefs_binary.sh" "${REPO_ROOT}/scripts/install/install_juicefs_mount_service.sh" "$mount_env" "$target:${REMOTE_DIR}/"
    ssh "${ssh_opts[@]}" "$target" "cd $(shell_quote "$REMOTE_DIR") && mv $(shell_quote "$(basename "$mount_env")") mount.env && chmod +x install_juicefs_binary.sh install_juicefs_mount_service.sh && set -a && . ./mount.env && set +a && ./install_juicefs_binary.sh && ./install_juicefs_mount_service.sh"
  ) &
  pids="${pids} $!"
done

failed=0
for pid in $pids; do
  if ! wait "$pid"; then
    failed=1
  fi
done

exit "$failed"
