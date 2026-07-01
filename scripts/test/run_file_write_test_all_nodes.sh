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

# shellcheck source=scripts/test/lib_report.sh
. "${SCRIPT_DIR}/lib_report.sh"

JUICEFS_TEST_HOSTS="${JUICEFS_TEST_HOSTS:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/tmp/run_file_write_test.sh}"
REMOTE_REPORT_ROOT="${REMOTE_REPORT_ROOT:-/tmp/juicefs-test-reports}"
if [ -n "${FILE_WRITE_TEST_PREFIX:-}" ]; then
  TEST_PREFIX="$FILE_WRITE_TEST_PREFIX"
elif [ "${TEST_PREFIX:-}" = "mdtest" ]; then
  TEST_PREFIX="filewrite"
else
  TEST_PREFIX="${TEST_PREFIX:-filewrite}"
fi
MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME:-juicefs-prod}}"
FILE_WRITE_TOTAL_FILES="${FILE_WRITE_TOTAL_FILES:-}"
TARGET_FILES_PER_NODE="${FILE_WRITE_TARGET_PER_NODE:-${TARGET_FILES_PER_NODE:-}}"
FILE_SIZE_BYTES="${FILE_WRITE_SIZE_BYTES:-${WRITE_SIZE:-1}}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
WORKERS="${FILE_WRITE_WORKERS:-${THREADS:-64}}"
MAX_SECONDS="${FILE_WRITE_MAX_SECONDS:-0}"
SYNC_EVERY="${FILE_WRITE_SYNC_EVERY:-0}"
REPORT_ROOT="${REPORT_ROOT:-${REPO_ROOT}/reports}"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
REPORT_DIR="${REPORT_DIR:-${REPORT_ROOT}/file-write/${TEST_RUN_ID}}"
RESUME_TEST="${RESUME_TEST:-0}"
COLLECT_NODE_INFO="${COLLECT_NODE_INFO:-1}"
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
echo "  report dir: ${REPORT_DIR}"
echo "  resume: ${RESUME_TEST}"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run only; skip SSH execution"
  exit 0
fi

mkdir -p "${REPORT_DIR}/nodes"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

hosts_file="${REPORT_DIR}/hosts.tsv"
: >"$hosts_file"

run_host() {
  safe_host="$1"
  host="$2"
  node_dir="${REPORT_DIR}/nodes/${safe_host}"
  target="${SSH_USER}@${host}"
  remote_report_dir="${REMOTE_REPORT_ROOT}/${TEST_RUN_ID}"
  remote_report="${remote_report_dir}/${TEST_PREFIX}-${safe_host}.kv"
  local_kv="${node_dir}/result.kv"

  mkdir -p "$node_dir"

  if [ "$RESUME_TEST" = "1" ] && kv_success "$local_kv"; then
    echo "skip completed file write test on ${target}"
    echo "skipped=1" >"${node_dir}/resume.log"
    return 0
  fi

  echo "copy write test script to ${target}"
  scp "${ssh_opts[@]}" "${SCRIPT_DIR}/run_file_write_test.sh" "${target}:${REMOTE_SCRIPT}" >"${node_dir}/scp.log" 2>"${node_dir}/scp.err"

  collect_node_info "$target" "${node_dir}/pre-node-info.log" "${node_dir}/pre-node-info.err" "before-file-write-test"

  remote_cmd="mkdir -p $(shell_quote "$remote_report_dir") && chmod +x $(shell_quote "$REMOTE_SCRIPT") && MOUNT_POINT=$(shell_quote "$MOUNT_POINT") TEST_PREFIX=$(shell_quote "$TEST_PREFIX") TEST_RUN_ID=$(shell_quote "${TEST_RUN_ID}-${safe_host}") TARGET_FILES=$(shell_quote "$TARGET_FILES_PER_NODE") FILE_SIZE_BYTES=$(shell_quote "$FILE_SIZE_BYTES") FILES_PER_DIR=$(shell_quote "$FILES_PER_DIR") WORKERS=$(shell_quote "$WORKERS") MAX_SECONDS=$(shell_quote "$MAX_SECONDS") SYNC_EVERY=$(shell_quote "$SYNC_EVERY") RESUME_TEST=$(shell_quote "$RESUME_TEST") REPORT_FILE=$(shell_quote "$remote_report") $(shell_quote "$REMOTE_SCRIPT")"

  echo "start file write test on ${target}"
  set +e
  ssh "${ssh_opts[@]}" "$target" "$remote_cmd" >"${node_dir}/stdout.log" 2>"${node_dir}/stderr.log"
  status=$?
  scp "${ssh_opts[@]}" "${target}:${remote_report}" "$local_kv" >"${node_dir}/result-scp.log" 2>"${node_dir}/result-scp.err"
  scp_status=$?
  set -e

  collect_node_info "$target" "${node_dir}/post-node-info.log" "${node_dir}/post-node-info.err" "after-file-write-test"

  if [ "$scp_status" -ne 0 ] || [ ! -s "$local_kv" ]; then
    if [ "$status" -eq 0 ]; then
      status=1
    fi
    {
      echo "test_kind=file_write"
      echo "host=${host}"
      echo "run_id=${TEST_RUN_ID}-${safe_host}"
      echo "files_created=0"
      echo "files_skipped=0"
      echo "files_present=0"
      echo "bytes_created=0"
      echo "bytes_present=0"
      echo "errors=1"
      echo "elapsed_seconds=0"
      echo "files_per_second=0"
      echo "mb_per_second=0"
      echo "exit_code=${status}"
      echo "error=missing remote result file"
    } >"$local_kv"
  fi

  return "$status"
}

pids=""
for host in $JUICEFS_TEST_HOSTS; do
  safe_host="$(safe_name "$host")"
  printf '%s\t%s\n' "$safe_host" "$host" >>"$hosts_file"
  run_host "$safe_host" "$host" &
  pids="${pids} $!"
done

failed=0
for pid in $pids; do
  if ! wait "$pid"; then
    failed=1
  fi
done

report_md="${REPORT_DIR}/summary.md"
summary_kv="${REPORT_DIR}/summary.kv"
total_created=0
total_present=0
total_bytes_created=0
total_errors=0
successful_hosts=0
failed_hosts=0
max_elapsed=0

{
  echo "# JuiceFS file write test report"
  echo
  echo "- Generated at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Run ID: \`${TEST_RUN_ID}\`"
  echo "- Mount point: \`${MOUNT_POINT}\`"
  echo "- Hosts: \`${host_count}\`"
  echo "- Target total files: \`${FILE_WRITE_TOTAL_FILES:-auto}\`"
  echo "- Target files per node: \`${TARGET_FILES_PER_NODE}\`"
  echo "- File size bytes: \`${FILE_SIZE_BYTES}\`"
  echo "- Files per directory: \`${FILES_PER_DIR}\`"
  echo "- Workers per node: \`${WORKERS}\`"
  echo "- Max seconds: \`${MAX_SECONDS}\`"
  echo "- Resume mode: \`${RESUME_TEST}\`"
  echo
  echo "| Host | Status | Created | Reused | Present | Errors | Elapsed seconds | Created files/s | Created MiB/s | Test directory | Logs |"
  echo "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"

  while IFS="$(printf '\t')" read -r safe_host host; do
    kv="${REPORT_DIR}/nodes/${safe_host}/result.kv"
    exit_code="$(kv_exit_code "$kv")"
    created="$(kv_get files_created "$kv")"
    skipped="$(kv_get files_skipped "$kv")"
    present="$(kv_get files_present "$kv")"
    bytes_created="$(kv_get bytes_created "$kv")"
    errors="$(kv_get errors "$kv")"
    elapsed="$(kv_get elapsed_seconds "$kv")"
    fps="$(kv_get files_per_second "$kv")"
    mbps="$(kv_get mb_per_second "$kv")"
    test_dir="$(kv_get test_dir "$kv")"
    created="${created:-0}"
    skipped="${skipped:-0}"
    present="${present:-0}"
    bytes_created="${bytes_created:-0}"
    errors="${errors:-0}"
    elapsed="${elapsed:-0}"
    fps="${fps:-0}"
    mbps="${mbps:-0}"

    if [ "$exit_code" = "0" ] && [ "$errors" = "0" ]; then
      status="ok"
      successful_hosts=$((successful_hosts + 1))
      total_created=$((total_created + created))
      total_present=$((total_present + present))
      total_bytes_created=$((total_bytes_created + bytes_created))
      max_elapsed="$(max_number "$max_elapsed" "$elapsed")"
    else
      status="failed(${exit_code})"
      failed_hosts=$((failed_hosts + 1))
    fi
    total_errors=$((total_errors + errors))

    echo "| ${host} | ${status} | ${created} | ${skipped} | ${present} | ${errors} | ${elapsed} | ${fps} | ${mbps} | \`${test_dir:-unknown}\` | [node](nodes/${safe_host}/) |"
  done <"$hosts_file"

  aggregate_fps="$(rate_number "$total_created" "$max_elapsed")"
  aggregate_mib="$(mib_rate_number "$total_bytes_created" "$max_elapsed")"
  echo
  echo "## Totals"
  echo
  echo "- Successful hosts: \`${successful_hosts}\`"
  echo "- Failed hosts: \`${failed_hosts}\`"
  echo "- Files created in this run: \`${total_created}\`"
  echo "- Files present after resume accounting: \`${total_present}\`"
  echo "- Bytes created in this run: \`${total_bytes_created}\`"
  echo "- Errors: \`${total_errors}\`"
  echo "- Slowest successful node elapsed seconds: \`${max_elapsed}\`"
  echo "- Aggregate created files/s: \`${aggregate_fps}\`"
  echo "- Aggregate created MiB/s: \`${aggregate_mib}\`"
  echo "- Raw node reports: \`${REPORT_DIR}/nodes\`"
} >"$report_md"

aggregate_fps="$(rate_number "$total_created" "$max_elapsed")"
aggregate_mib="$(mib_rate_number "$total_bytes_created" "$max_elapsed")"
{
  echo "test_kind=file_write"
  echo "run_id=${TEST_RUN_ID}"
  echo "report_dir=${REPORT_DIR}"
  echo "hosts=${host_count}"
  echo "successful_hosts=${successful_hosts}"
  echo "failed_hosts=${failed_hosts}"
  echo "files_created=${total_created}"
  echo "files_present=${total_present}"
  echo "bytes_created=${total_bytes_created}"
  echo "errors=${total_errors}"
  echo "max_elapsed_seconds=${max_elapsed}"
  echo "aggregate_files_per_second=${aggregate_fps}"
  echo "aggregate_mib_per_second=${aggregate_mib}"
  echo "exit_code=${failed}"
} >"$summary_kv"

cat "$report_md"

if [ "$failed" -ne 0 ] || [ "$failed_hosts" -ne 0 ] || [ "$total_errors" -ne 0 ]; then
  exit 1
fi
