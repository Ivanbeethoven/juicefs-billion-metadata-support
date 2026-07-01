#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME:-slayerfs-rustfs}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

JUICEFS_TEST_HOSTS="${JUICEFS_TEST_HOSTS:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/tmp/run_file_write_test.sh}"
TEST_PREFIX="${TEST_PREFIX:-filewrite}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME:-juicefs-prod}}"
FILE_WRITE_TOTAL_FILES="${FILE_WRITE_TOTAL_FILES:-}"
TARGET_FILES_PER_NODE="${FILE_WRITE_TARGET_PER_NODE:-${TARGET_FILES_PER_NODE:-}}"
FILE_SIZE_BYTES="${FILE_WRITE_SIZE_BYTES:-${WRITE_SIZE:-1}}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
WORKERS="${FILE_WRITE_WORKERS:-${THREADS:-64}}"
MAX_SECONDS="${FILE_WRITE_MAX_SECONDS:-0}"
SYNC_EVERY="${FILE_WRITE_SYNC_EVERY:-0}"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/reports/file-write-$(date +%Y%m%d-%H%M%S)}"
DRY_RUN="${DRY_RUN:-0}"

if [ -z "$JUICEFS_TEST_HOSTS" ]; then
  echo "JUICEFS_TEST_HOSTS is required, use space separated host list" >&2
  exit 1
fi

host_count="$(printf '%s\n' $JUICEFS_TEST_HOSTS | wc -l | tr -d ' ')"
if [ -z "$TARGET_FILES_PER_NODE" ]; then
  if [ -n "$FILE_WRITE_TOTAL_FILES" ]; then
    TARGET_FILES_PER_NODE=$(( (FILE_WRITE_TOTAL_FILES + host_count - 1) / host_count ))
  else
    TARGET_FILES_PER_NODE=1000000
  fi
fi

echo "file write test target:"
echo "  hosts: ${host_count}"
echo "  target total files: ${FILE_WRITE_TOTAL_FILES:-auto}"
echo "  target files per node: ${TARGET_FILES_PER_NODE}"
echo "  file size bytes: ${FILE_SIZE_BYTES}"
echo "  workers per node: ${WORKERS}"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run only; skip SSH execution"
  exit 0
fi

mkdir -p "$REPORT_DIR"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

pids=""
hosts_file="${REPORT_DIR}/hosts.txt"
: >"$hosts_file"

for host in $JUICEFS_TEST_HOSTS; do
  safe_host="$(printf '%s' "$host" | tr -c 'A-Za-z0-9_.-' '_')"
  target="${SSH_USER}@${host}"
  remote_report="/tmp/${TEST_PREFIX}-${safe_host}.kv"
  local_kv="${REPORT_DIR}/${safe_host}.kv"
  local_err="${REPORT_DIR}/${safe_host}.err"

  echo "${safe_host} ${host}" >>"$hosts_file"
  echo "copy write test script to ${target}"
  scp "${ssh_opts[@]}" "${SCRIPT_DIR}/run_file_write_test.sh" "${target}:${REMOTE_SCRIPT}" >/dev/null

  remote_cmd="chmod +x $(shell_quote "$REMOTE_SCRIPT") && MOUNT_POINT=$(shell_quote "$MOUNT_POINT") TEST_PREFIX=$(shell_quote "$TEST_PREFIX") TARGET_FILES=$(shell_quote "$TARGET_FILES_PER_NODE") FILE_SIZE_BYTES=$(shell_quote "$FILE_SIZE_BYTES") FILES_PER_DIR=$(shell_quote "$FILES_PER_DIR") WORKERS=$(shell_quote "$WORKERS") MAX_SECONDS=$(shell_quote "$MAX_SECONDS") SYNC_EVERY=$(shell_quote "$SYNC_EVERY") REPORT_FILE=$(shell_quote "$remote_report") $(shell_quote "$REMOTE_SCRIPT")"

  echo "start file write test on ${target}"
  ssh "${ssh_opts[@]}" "$target" "$remote_cmd" >"$local_kv" 2>"$local_err" &
  pids="${pids} $!"
done

failed=0
for pid in $pids; do
  if ! wait "$pid"; then
    failed=1
  fi
done

report_md="${REPORT_DIR}/summary.md"
total_files=0
total_bytes=0
total_errors=0

{
  echo "# JuiceFS file write test report"
  echo
  echo "- Generated at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Mount point: \`${MOUNT_POINT}\`"
  echo "- Hosts: \`${host_count}\`"
  echo "- Target total files: \`${FILE_WRITE_TOTAL_FILES:-auto}\`"
  echo "- Target files per node: \`${TARGET_FILES_PER_NODE}\`"
  echo "- File size bytes: \`${FILE_SIZE_BYTES}\`"
  echo "- Files per directory: \`${FILES_PER_DIR}\`"
  echo "- Workers per node: \`${WORKERS}\`"
  echo "- Max seconds: \`${MAX_SECONDS}\`"
  echo
  echo "| Host | Files | Bytes | Errors | Elapsed seconds | Files/s | MiB/s | Test directory |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"

  while read -r safe_host host; do
    kv="${REPORT_DIR}/${safe_host}.kv"
    if [ ! -s "$kv" ]; then
      echo "| ${host} | 0 | 0 | 1 | 0 | 0 | 0 | failed before report |"
      total_errors=$((total_errors + 1))
      continue
    fi

    files="$(awk -F= '$1=="files_written"{print $2}' "$kv")"
    bytes="$(awk -F= '$1=="bytes_written"{print $2}' "$kv")"
    errors="$(awk -F= '$1=="errors"{print $2}' "$kv")"
    elapsed="$(awk -F= '$1=="elapsed_seconds"{print $2}' "$kv")"
    fps="$(awk -F= '$1=="files_per_second"{print $2}' "$kv")"
    mbps="$(awk -F= '$1=="mb_per_second"{print $2}' "$kv")"
    test_dir="$(awk -F= '$1=="test_dir"{print $2}' "$kv")"

    files="${files:-0}"
    bytes="${bytes:-0}"
    errors="${errors:-0}"
    total_files=$((total_files + files))
    total_bytes=$((total_bytes + bytes))
    total_errors=$((total_errors + errors))

    echo "| ${host} | ${files} | ${bytes} | ${errors} | ${elapsed:-0} | ${fps:-0} | ${mbps:-0} | \`${test_dir:-unknown}\` |"
  done <"$hosts_file"

  echo
  echo "## Totals"
  echo
  echo "- Files written: \`${total_files}\`"
  echo "- Bytes written: \`${total_bytes}\`"
  echo "- Errors: \`${total_errors}\`"
  echo "- Raw node reports: \`${REPORT_DIR}\`"
} >"$report_md"

cat "$report_md"

if [ "$failed" -ne 0 ] || [ "$total_errors" -ne 0 ]; then
  exit 1
fi
