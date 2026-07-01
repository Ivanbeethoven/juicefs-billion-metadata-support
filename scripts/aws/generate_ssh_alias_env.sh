#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-slayerfs-rustfs}"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"
TOPOLOGY="${TOPOLOGY:-${RUN_DIR}/topology.ssh-alias.generated.yaml}"
FORCE="${FORCE:-0}"

SSH_HOSTS="${SSH_HOSTS:-aws1 aws2 aws3 aws4}"
TIKV_HOSTS="${TIKV_HOSTS:-}"
RUSTFS_HOST="${RUSTFS_HOST:-}"
RUSTFS_ENDPOINT="${RUSTFS_ENDPOINT:-}"
INPUT_SSH_KEY="${SSH_KEY:-}"
CONNECT_SSH_KEY="${CONNECT_SSH_KEY:-$INPUT_SSH_KEY}"
INSTALL_CONTROL_SSH_KEY="${INSTALL_CONTROL_SSH_KEY:-1}"
DEPLOY_KEY="${DEPLOY_KEY:-${INPUT_SSH_KEY:-${RUN_DIR}/ssh-alias-deploy-key}}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TIDB_ARCH="${TIDB_ARCH:-amd64}"
TIUP_INSTALL_MODE="${TIUP_INSTALL_MODE:-offline}"
JUICEFS_VERSION="${JUICEFS_VERSION:-1.3.1}"
JUICEFS_ARCH="${JUICEFS_ARCH:-amd64}"
JFS_NAME="${JFS_NAME:-juicefs-prod}"
RUSTFS_BUCKET="${RUSTFS_BUCKET:-juicefs-prod}"
RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-}"
RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-}"
JFS_TRASH_DAYS="${JFS_TRASH_DAYS:-0}"
CACHE_SIZE="${CACHE_SIZE:-102400}"
TARGET_TOTAL_FILES="${TARGET_TOTAL_FILES:-1000000}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
THREADS="${TEST_THREADS:-${THREADS:-64}}"
WRITE_SIZE="${WRITE_SIZE:-1}"
DEPTH="${DEPTH:-2}"
TIKV_STORAGE_RESERVE_SPACE="${TIKV_STORAGE_RESERVE_SPACE:-100GiB}"
TIKV_DATA_VOLUME_SIZE_GB="${TIKV_DATA_VOLUME_SIZE_GB:-}"
TIKV_RAFTSTORE_CAPACITY="${TIKV_RAFTSTORE_CAPACITY:-}"
TIKV_RAFTSTORE_CAPACITY_RESERVE_GB="${TIKV_RAFTSTORE_CAPACITY_RESERVE_GB:-32}"
TIKV_DATA_ROOT="${TIKV_DATA_ROOT:-}"
TIKV_DEPLOY_DIR="${TIKV_DEPLOY_DIR:-}"
TIKV_DATA_DIR="${TIKV_DATA_DIR:-}"
CACHE_DIR="${CACHE_DIR:-}"

random_string() {
  length="${1:-32}"
  bytes=$(( (length + 1) / 2 ))
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes" | cut -c "1-${length}"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n' | cut -c "1-${length}"
  fi
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

detect_ssh_user() {
  ssh -G "$1" 2>/dev/null | awk '$1 == "user" {print $2; exit}' || true
}

ssh_target() {
  if [ -n "${SSH_USER:-}" ]; then
    printf '%s@%s' "$SSH_USER" "$1"
  else
    printf '%s' "$1"
  fi
}

probe_private_ip() {
  host="$1"
  target="$(ssh_target "$host")"
  ips="$(ssh "${ssh_opts[@]}" "$target" "(hostname -I 2>/dev/null || ip -4 -o addr show scope global 2>/dev/null | awk '{split(\$4,a,\"/\"); print a[1]}')" | tr ' ' '\n' | sed '/^$/d')"
  private_ip="$(printf '%s\n' "$ips" | awk '$1 ~ /^10\./ || $1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ {print; exit}')"
  if [ -z "$private_ip" ]; then
    private_ip="$(printf '%s\n' "$ips" | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ {print; exit}')"
  fi
  [ -n "$private_ip" ] || {
    echo "failed to detect private IP for ${host}" >&2
    return 1
  }
  printf '%s\n' "$private_ip"
}

probe_mount_size_gib() {
  host="$1"
  mount_point="$2"
  target="$(ssh_target "$host")"
  quoted_mount_point="$(shell_quote "$mount_point")"
  ssh "${ssh_opts[@]}" "$target" "path=${quoted_mount_point}; while [ ! -e \"\$path\" ] && [ \"\$path\" != / ]; do path=\$(dirname \"\$path\"); done; df -BG --output=size \"\$path\" 2>/dev/null | tail -n 1 | tr -dc '0-9'" || true
}

probe_path_exists() {
  host="$1"
  path="$2"
  target="$(ssh_target "$host")"
  quoted_path="$(shell_quote "$path")"
  ssh "${ssh_opts[@]}" "$target" "[ -d ${quoted_path} ]" >/dev/null 2>&1
}

remote_rustfs_value() {
  key="$1"
  target="$(ssh_target "$RUSTFS_HOST")"
  ssh "${ssh_opts[@]}" "$target" "if [ -r /etc/default/rustfs ]; then . /etc/default/rustfs; printf '%s' \"\${${key}:-}\"; fi" || true
}

if [ -f "$ENV_FILE" ] && [ "$FORCE" != "1" ]; then
  echo "refuse to overwrite existing env: ${ENV_FILE}" >&2
  echo "set FORCE=1 to regenerate it" >&2
  exit 1
fi

read -r -a all_hosts <<<"$SSH_HOSTS"
if [ "${#all_hosts[@]}" -ne 4 ]; then
  echo "SSH_HOSTS must contain exactly 4 hosts, default: aws1 aws2 aws3 aws4" >&2
  exit 1
fi

if [ -n "$TIKV_HOSTS" ]; then
  read -r -a tikv_hosts <<<"$TIKV_HOSTS"
else
  tikv_hosts=("${all_hosts[@]:0:3}")
fi
if [ "${#tikv_hosts[@]}" -ne 3 ]; then
  echo "TIKV_HOSTS must contain exactly 3 hosts" >&2
  exit 1
fi
RUSTFS_HOST="${RUSTFS_HOST:-${all_hosts[3]}}"
CONTROL_HOST="${CONTROL_HOST:-${tikv_hosts[0]}}"

SSH_USER="${SSH_USER:-$(detect_ssh_user "${all_hosts[0]}")}"
SSH_USER="${SSH_USER:-ubuntu}"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$CONNECT_SSH_KEY" ] && [ -f "$CONNECT_SSH_KEY" ]; then
  ssh_opts+=(-i "$CONNECT_SSH_KEY")
fi

mkdir -p "$RUN_DIR"

OUTPUT_SSH_KEY="$INPUT_SSH_KEY"
if [ "$INSTALL_CONTROL_SSH_KEY" = "1" ]; then
  if [ ! -f "$DEPLOY_KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "${PROJECT_NAME}-deploy" -f "$DEPLOY_KEY"
  fi
  chmod 600 "$DEPLOY_KEY"
  if [ ! -f "${DEPLOY_KEY}.pub" ]; then
    ssh-keygen -y -f "$DEPLOY_KEY" >"${DEPLOY_KEY}.pub"
  fi

  public_key="$(cat "${DEPLOY_KEY}.pub")"
  quoted_public_key="$(shell_quote "$public_key")"
  for host in "${all_hosts[@]}"; do
    target="$(ssh_target "$host")"
    echo "install deploy public key on ${target}"
    ssh "${ssh_opts[@]}" "$target" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && if ! grep -qxF ${quoted_public_key} ~/.ssh/authorized_keys; then printf '%s\n' ${quoted_public_key} >> ~/.ssh/authorized_keys; fi && chmod 600 ~/.ssh/authorized_keys"
  done
  OUTPUT_SSH_KEY="$DEPLOY_KEY"
fi

echo "detect private IPs"
tikv_ip_1="$(probe_private_ip "${tikv_hosts[0]}")"
tikv_ip_2="$(probe_private_ip "${tikv_hosts[1]}")"
tikv_ip_3="$(probe_private_ip "${tikv_hosts[2]}")"
if [ -z "$RUSTFS_ENDPOINT" ]; then
  rustfs_private_ip="$(probe_private_ip "$RUSTFS_HOST")"
  RUSTFS_ENDPOINT="http://${rustfs_private_ip}:9000"
fi

if [ -z "$TIKV_DATA_ROOT" ]; then
  if probe_path_exists "${tikv_hosts[0]}" /data/rustfs1; then
    TIKV_DATA_ROOT=/data/rustfs1/tikv
  else
    TIKV_DATA_ROOT=/data/tikv
  fi
fi
TIKV_DEPLOY_DIR="${TIKV_DEPLOY_DIR:-${TIKV_DATA_ROOT}/deploy}"
TIKV_DATA_DIR="${TIKV_DATA_DIR:-${TIKV_DATA_ROOT}/data}"

if [ -z "$CACHE_DIR" ]; then
  if probe_path_exists "${all_hosts[0]}" /data/rustfs2; then
    CACHE_DIR=/data/rustfs2/juicefs-cache
  else
    CACHE_DIR=/var/lib/juicefs/cache
  fi
fi

if [ -z "$TIKV_DATA_VOLUME_SIZE_GB" ]; then
  TIKV_DATA_VOLUME_SIZE_GB="$(probe_mount_size_gib "${tikv_hosts[0]}" "$TIKV_DATA_ROOT")"
  TIKV_DATA_VOLUME_SIZE_GB="${TIKV_DATA_VOLUME_SIZE_GB:-$(probe_mount_size_gib "${tikv_hosts[0]}" /data/tikv)}"
  TIKV_DATA_VOLUME_SIZE_GB="${TIKV_DATA_VOLUME_SIZE_GB:-$(probe_mount_size_gib "${tikv_hosts[0]}" /data)}"
  TIKV_DATA_VOLUME_SIZE_GB="${TIKV_DATA_VOLUME_SIZE_GB:-$(probe_mount_size_gib "${tikv_hosts[0]}" /)}"
  TIKV_DATA_VOLUME_SIZE_GB="${TIKV_DATA_VOLUME_SIZE_GB:-512}"
fi
capacity_gib=$(( TIKV_DATA_VOLUME_SIZE_GB - TIKV_RAFTSTORE_CAPACITY_RESERVE_GB ))
if [ "$capacity_gib" -lt 1 ]; then
  capacity_gib=1
fi
TIKV_RAFTSTORE_CAPACITY="${TIKV_RAFTSTORE_CAPACITY:-${capacity_gib}GiB}"

if [ -z "$RUSTFS_ACCESS_KEY" ]; then
  RUSTFS_ACCESS_KEY="$(remote_rustfs_value RUSTFS_ACCESS_KEY)"
  RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-rustfsadmin}"
fi
if [ -z "$RUSTFS_SECRET_KEY" ]; then
  RUSTFS_SECRET_KEY="$(remote_rustfs_value RUSTFS_SECRET_KEY)"
fi
if [ -z "$RUSTFS_SECRET_KEY" ]; then
  if [ "${ALLOW_GENERATE_RUSTFS_SECRET:-0}" = "1" ]; then
    RUSTFS_SECRET_KEY="$(random_string 32)"
  else
    echo "failed to read RUSTFS_SECRET_KEY from ${RUSTFS_HOST}; set RUSTFS_SECRET_KEY or ALLOW_GENERATE_RUSTFS_SECRET=1" >&2
    exit 1
  fi
fi

pd_endpoint="http://${tikv_ip_1}:2379"
meta_url="tikv://${tikv_ip_1}:2379,${tikv_ip_2}:2379,${tikv_ip_3}:2379/${JFS_NAME}"
jfs_bucket="${RUSTFS_ENDPOINT%/}/${RUSTFS_BUCKET}"
target_files_per_node=$(( (TARGET_TOTAL_FILES + 3) / 4 ))

cat >"$TOPOLOGY" <<EOF
global:
  user: tikv
  ssh_port: 22
  deploy_dir: ${TIKV_DEPLOY_DIR}
  data_dir: ${TIKV_DATA_DIR}

server_configs:
  pd:
    replication.location-labels: ["zone", "host"]
    replication.max-replicas: 3
  tikv:
    storage.reserve-space: ${TIKV_STORAGE_RESERVE_SPACE}
    raftstore.capacity: ${TIKV_RAFTSTORE_CAPACITY}

pd_servers:
  - host: ${tikv_ip_1}
    name: pd-1
    client_port: 2379
    peer_port: 2380
  - host: ${tikv_ip_2}
    name: pd-2
    client_port: 2379
    peer_port: 2380
  - host: ${tikv_ip_3}
    name: pd-3
    client_port: 2379
    peer_port: 2380

tikv_servers:
  - host: ${tikv_ip_1}
    port: 20160
    status_port: 20180
    config:
      server.labels:
        zone: alias-a
        host: tikv-1
  - host: ${tikv_ip_2}
    port: 20160
    status_port: 20180
    config:
      server.labels:
        zone: alias-b
        host: tikv-2
  - host: ${tikv_ip_3}
    port: 20160
    status_port: 20180
    config:
      server.labels:
        zone: alias-c
        host: tikv-3
EOF

cat >"$ENV_FILE" <<EOF
# Generated by scripts/aws/generate_ssh_alias_env.sh.

# SSH aliases
SSH_ALIAS_HOSTS="${SSH_HOSTS}"
TIKV_SSH_HOSTS="${tikv_hosts[*]}"
RUSTFS_SSH_HOST=${RUSTFS_HOST}
CONTROL_HOST=${CONTROL_HOST}
JUICEFS_TEST_HOSTS="${all_hosts[*]}"
SSH_USER=${SSH_USER}
SSH_KEY=${OUTPUT_SSH_KEY}

# TiUP / TiKV
TIDB_VERSION=${TIDB_VERSION}
TIDB_ARCH=${TIDB_ARCH}
TIUP_INSTALL_MODE=${TIUP_INSTALL_MODE}
CLUSTER_NAME=${PROJECT_NAME}
TOPOLOGY=${TOPOLOGY}
PD_ENDPOINT=${pd_endpoint}
TIKV_DATA_ROOT=${TIKV_DATA_ROOT}
TIKV_DEPLOY_DIR=${TIKV_DEPLOY_DIR}
TIKV_DATA_DIR=${TIKV_DATA_DIR}
TIKV_DATA_VOLUME_SIZE_GB=${TIKV_DATA_VOLUME_SIZE_GB}
TIKV_STORAGE_RESERVE_SPACE=${TIKV_STORAGE_RESERVE_SPACE}
TIKV_RAFTSTORE_CAPACITY=${TIKV_RAFTSTORE_CAPACITY}

# JuiceFS binary
JUICEFS_VERSION=${JUICEFS_VERSION}
JUICEFS_ARCH=${JUICEFS_ARCH}
JUICEFS_INSTALL_DIR=/usr/local/bin

# JuiceFS filesystem
JFS_NAME=${JFS_NAME}
META_URL=${meta_url}
JFS_STORAGE=s3
JFS_BUCKET=${jfs_bucket}
JFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY}
JFS_SECRET_KEY=${RUSTFS_SECRET_KEY}
JFS_TRASH_DAYS=${JFS_TRASH_DAYS}

# RustFS
RUSTFS_ENDPOINT=${RUSTFS_ENDPOINT%/}
RUSTFS_BUCKET=${RUSTFS_BUCKET}
RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY}
RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY}

# Mount service
MOUNT_POINT=/mnt/${JFS_NAME}
CACHE_DIR=${CACHE_DIR}
CACHE_SIZE=${CACHE_SIZE}
SERVICE_NAME=${JFS_NAME}

# Metadata benchmark
METADATA_TEST_PREFIX=mdtest
FILE_WRITE_TEST_PREFIX=filewrite
TARGET_FILES_PER_NODE=${target_files_per_node}
FILES_PER_DIR=${FILES_PER_DIR}
DEPTH=${DEPTH}
MDTEST_DIRS=
THREADS=${THREADS}
WRITE_SIZE=${WRITE_SIZE}
EOF

chmod 600 "$ENV_FILE"
chmod 644 "$TOPOLOGY"

echo "wrote ${ENV_FILE}"
echo "wrote ${TOPOLOGY}"
echo "control host = ${CONTROL_HOST}"
echo "tikv private IPs = ${tikv_ip_1} ${tikv_ip_2} ${tikv_ip_3}"
echo "rustfs endpoint = ${RUSTFS_ENDPOINT%/}"
