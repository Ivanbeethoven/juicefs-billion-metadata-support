#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME:-slayerfs-rustfs}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/juicefs-existing-bootstrap}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env file not found: ${ENV_FILE}" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

JUICEFS_TEST_HOSTS="${JUICEFS_TEST_HOSTS:-}"
TIKV_SSH_HOSTS="${TIKV_SSH_HOSTS:-}"
SSH_USER="${SSH_USER:-}"
SSH_KEY="${SSH_KEY:-}"
JUICEFS_VERSION="${JUICEFS_VERSION:-1.3.1}"
JUICEFS_ARCH="${JUICEFS_ARCH:-amd64}"
JUICEFS_INSTALL_DIR="${JUICEFS_INSTALL_DIR:-/usr/local/bin}"
TIKV_DATA_ROOT="${TIKV_DATA_ROOT:-/data/tikv}"
CACHE_DIR="${CACHE_DIR:-/var/lib/juicefs/cache}"

if [ -z "$JUICEFS_TEST_HOSTS" ]; then
  echo "JUICEFS_TEST_HOSTS is required in ${ENV_FILE}" >&2
  exit 1
fi

if [ -z "$TIKV_SSH_HOSTS" ]; then
  echo "TIKV_SSH_HOSTS is required in ${ENV_FILE}" >&2
  exit 1
fi

if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then
  echo "SSH_KEY points to a missing private key: ${SSH_KEY}" >&2
  exit 1
fi

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ssh_target() {
  if [ -n "$SSH_USER" ]; then
    printf '%s@%s' "$SSH_USER" "$1"
  else
    printf '%s' "$1"
  fi
}

contains_word() {
  needle="$1"
  shift
  for value in "$@"; do
    [ "$value" = "$needle" ] && return 0
  done
  return 1
}

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

read -r -a tikv_hosts <<<"$TIKV_SSH_HOSTS"

pids=""
for host in $JUICEFS_TEST_HOSTS; do
  target="$(ssh_target "$host")"
  echo "bootstrap existing node ${target}"
  (
    ssh "${ssh_opts[@]}" "$target" "rm -rf $(shell_quote "$REMOTE_DIR") && mkdir -p $(shell_quote "$REMOTE_DIR")"
    scp "${ssh_opts[@]}" \
      "${REPO_ROOT}/scripts/install/install_juicefs_binary.sh" \
      "${REPO_ROOT}/scripts/install/prepare_tikv_node.sh" \
      "$target:${REMOTE_DIR}/"

    is_tikv=0
    if contains_word "$host" "${tikv_hosts[@]}"; then
      is_tikv=1
    fi

    remote_cmd=$(cat <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl wget tar gzip unzip xfsprogs jq fuse3 fio python3 sysstat numactl irqbalance selinux-utils policycoreutils
  sudo systemctl enable --now irqbalance >/dev/null 2>&1 || true
fi
cd $(shell_quote "$REMOTE_DIR")
chmod +x install_juicefs_binary.sh prepare_tikv_node.sh
JUICEFS_VERSION=$(shell_quote "$JUICEFS_VERSION") JUICEFS_ARCH=$(shell_quote "$JUICEFS_ARCH") JUICEFS_INSTALL_DIR=$(shell_quote "$JUICEFS_INSTALL_DIR") ./install_juicefs_binary.sh
if [ "$is_tikv" = "1" ]; then
  DATA_ROOT=$(shell_quote "$TIKV_DATA_ROOT") ./prepare_tikv_node.sh
fi
sudo mkdir -p $(shell_quote "$CACHE_DIR")
sudo chmod 777 $(shell_quote "$CACHE_DIR")
echo "existing node bootstrap complete: \$(hostname) role=$([ "$is_tikv" = "1" ] && printf tikv || printf client)" | sudo tee /var/log/juicefs-bootstrap.done >/dev/null
EOF
)
    ssh "${ssh_opts[@]}" "$target" "$remote_cmd"
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
