#!/usr/bin/env bash
set -euo pipefail

JUICEFS_TEST_HOSTS="${JUICEFS_TEST_HOSTS:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/tmp/run_metadata_test.sh}"
TARGET_FILES_PER_NODE="${TARGET_FILES_PER_NODE:-1000000}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
THREADS="${THREADS:-64}"
WRITE_SIZE="${WRITE_SIZE:-1}"
DEPTH="${DEPTH:-2}"
MDTEST_DIRS="${MDTEST_DIRS:-}"
EXTRA_MDTEST_ARGS="${EXTRA_MDTEST_ARGS:-}"
TEST_PREFIX="${TEST_PREFIX:-mdtest}"
META_URL="${META_URL:-}"

if [ -z "$JUICEFS_TEST_HOSTS" ]; then
  echo "JUICEFS_TEST_HOSTS is required, use space separated host list" >&2
  exit 1
fi

if [ -z "$META_URL" ]; then
  echo "META_URL is required" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_opts=(-o StrictHostKeyChecking=accept-new)
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

pids=""
for host in $JUICEFS_TEST_HOSTS; do
  target="${SSH_USER}@${host}"
  echo "copy benchmark script to ${target}"
  scp "${ssh_opts[@]}" "${script_dir}/run_metadata_test.sh" "${target}:${REMOTE_SCRIPT}"

  echo "start metadata test on ${target}"
  ssh "${ssh_opts[@]}" "$target" \
    "chmod +x '${REMOTE_SCRIPT}' && META_URL='${META_URL}' TEST_PREFIX='${TEST_PREFIX}' TARGET_FILES_PER_NODE='${TARGET_FILES_PER_NODE}' FILES_PER_DIR='${FILES_PER_DIR}' THREADS='${THREADS}' WRITE_SIZE='${WRITE_SIZE}' DEPTH='${DEPTH}' MDTEST_DIRS='${MDTEST_DIRS}' EXTRA_MDTEST_ARGS='${EXTRA_MDTEST_ARGS}' '${REMOTE_SCRIPT}'" &
  pids="${pids} $!"
done

failed=0
for pid in $pids; do
  if ! wait "$pid"; then
    failed=1
  fi
done

exit "$failed"
