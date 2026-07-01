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
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/tmp/run_metadata_test.sh}"
REMOTE_REPORT_ROOT="${REMOTE_REPORT_ROOT:-/tmp/juicefs-test-reports}"
TARGET_TOTAL_FILES="${TARGET_TOTAL_FILES:-}"
TARGET_FILES_PER_NODE="${TARGET_FILES_PER_NODE:-}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
THREADS="${THREADS:-64}"
WRITE_SIZE="${WRITE_SIZE:-1}"
DEPTH="${DEPTH:-2}"
MDTEST_DIRS="${MDTEST_DIRS:-}"
EXTRA_MDTEST_ARGS="${EXTRA_MDTEST_ARGS:-}"
TEST_PREFIX="${METADATA_TEST_PREFIX:-${TEST_PREFIX:-mdtest}}"
META_URL="${META_URL:-}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME:-juicefs-prod}}"
REPORT_ROOT="${REPORT_ROOT:-${REPO_ROOT}/reports}"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
REPORT_DIR="${REPORT_DIR:-${REPORT_ROOT}/metadata/${TEST_RUN_ID}}"
RESUME_TEST="${RESUME_TEST:-0}"
COLLECT_NODE_INFO="${COLLECT_NODE_INFO:-1}"
DRY_RUN="${DRY_RUN:-0}"

if [ -z "$JUICEFS_TEST_HOSTS" ]; then
  echo "JUICEFS_TEST_HOSTS is required, use space separated host list" >&2
  exit 1
fi

if [ -z "$META_URL" ]; then
  echo "META_URL is required" >&2
  exit 1
fi

host_count="$(printf '%s\n' $JUICEFS_TEST_HOSTS | wc -l | tr -d ' ')"
if [ -z "$TARGET_FILES_PER_NODE" ]; then
  if [ -n "$TARGET_TOTAL_FILES" ]; then
    TARGET_FILES_PER_NODE=$(( (TARGET_TOTAL_FILES + host_count - 1) / host_count ))
  else
    TARGET_FILES_PER_NODE=1000000
  fi
fi

echo "metadata test target:"
echo "  hosts: ${host_count}"
echo "  target total files: ${TARGET_TOTAL_FILES:-auto}"
echo "  target files per node: ${TARGET_FILES_PER_NODE}"
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
  node_run_id="${TEST_RUN_ID}-${safe_host}"

  mkdir -p "$node_dir"

  if [ "$RESUME_TEST" = "1" ] && kv_success "$local_kv"; then
    echo "skip completed metadata test on ${target}"
    echo "skipped=1" >"${node_dir}/resume.log"
    return 0
  fi

  if [ "$RESUME_TEST" = "1" ]; then
    node_run_id="${node_run_id}-retry-$(date +%H%M%S)"
  fi

  echo "copy metadata test script to ${target}"
  scp "${ssh_opts[@]}" "${SCRIPT_DIR}/run_metadata_test.sh" "${target}:${REMOTE_SCRIPT}" >"${node_dir}/scp.log" 2>"${node_dir}/scp.err"

  collect_node_info "$target" "${node_dir}/pre-node-info.log" "${node_dir}/pre-node-info.err" "before-metadata-test"

  remote_cmd="mkdir -p $(shell_quote "$remote_report_dir") && chmod +x $(shell_quote "$REMOTE_SCRIPT") && META_URL=$(shell_quote "$META_URL") TEST_PREFIX=$(shell_quote "$TEST_PREFIX") TEST_RUN_ID=$(shell_quote "$node_run_id") TARGET_FILES_PER_NODE=$(shell_quote "$TARGET_FILES_PER_NODE") FILES_PER_DIR=$(shell_quote "$FILES_PER_DIR") THREADS=$(shell_quote "$THREADS") WRITE_SIZE=$(shell_quote "$WRITE_SIZE") DEPTH=$(shell_quote "$DEPTH") MDTEST_DIRS=$(shell_quote "$MDTEST_DIRS") EXTRA_MDTEST_ARGS=$(shell_quote "$EXTRA_MDTEST_ARGS") REPORT_FILE=$(shell_quote "$remote_report") $(shell_quote "$REMOTE_SCRIPT")"

  echo "start metadata test on ${target}"
  set +e
  ssh "${ssh_opts[@]}" "$target" "$remote_cmd" >"${node_dir}/stdout.log" 2>"${node_dir}/stderr.log"
  status=$?
  scp "${ssh_opts[@]}" "${target}:${remote_report}" "$local_kv" >"${node_dir}/result-scp.log" 2>"${node_dir}/result-scp.err"
  scp_status=$?
  set -e

  collect_node_info "$target" "${node_dir}/post-node-info.log" "${node_dir}/post-node-info.err" "after-metadata-test"

  if [ "$scp_status" -ne 0 ] || [ ! -s "$local_kv" ]; then
    if [ "$status" -eq 0 ]; then
      status=1
    fi
    {
      echo "test_kind=metadata"
      echo "host=${host}"
      echo "run_id=${node_run_id}"
      echo "estimated_files=0"
      echo "elapsed_seconds=0"
      echo "files_per_second=0"
      echo "exit_code=${status}"
      echo "error=missing remote result file"
    } >"$local_kv"
    return 1
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
total_estimated=0
successful_hosts=0
failed_hosts=0
max_elapsed=0

{
  echo "# JuiceFS metadata test report"
  echo
  echo "- Generated at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Run ID: \`${TEST_RUN_ID}\`"
  echo "- Metadata URL: \`${META_URL}\`"
  echo "- Hosts: \`${host_count}\`"
  echo "- Target total files: \`${TARGET_TOTAL_FILES:-auto}\`"
  echo "- Target files per node: \`${TARGET_FILES_PER_NODE}\`"
  echo "- Files per directory target: \`${FILES_PER_DIR}\`"
  echo "- Threads per node: \`${THREADS}\`"
  echo "- Depth: \`${DEPTH}\`"
  echo "- Write size: \`${WRITE_SIZE}\`"
  echo "- Resume mode: \`${RESUME_TEST}\`"
  echo
  echo "| Host | Status | Estimated files | Elapsed seconds | Files/s | Test directory | Logs |"
  echo "| --- | --- | ---: | ---: | ---: | --- | --- |"

  while IFS="$(printf '\t')" read -r safe_host host; do
    kv="${REPORT_DIR}/nodes/${safe_host}/result.kv"
    exit_code="$(kv_exit_code "$kv")"
    estimated="$(kv_get estimated_files "$kv")"
    elapsed="$(kv_get elapsed_seconds "$kv")"
    fps="$(kv_get files_per_second "$kv")"
    test_dir="$(kv_get test_dir "$kv")"
    estimated="${estimated:-0}"
    elapsed="${elapsed:-0}"
    fps="${fps:-0}"

    if [ "$exit_code" = "0" ]; then
      status="ok"
      successful_hosts=$((successful_hosts + 1))
      total_estimated=$((total_estimated + estimated))
      max_elapsed="$(max_number "$max_elapsed" "$elapsed")"
    else
      status="failed(${exit_code})"
      failed_hosts=$((failed_hosts + 1))
    fi

    echo "| ${host} | ${status} | ${estimated} | ${elapsed} | ${fps} | \`${test_dir:-unknown}\` | [node](nodes/${safe_host}/) |"
  done <"$hosts_file"

  aggregate_fps="$(rate_number "$total_estimated" "$max_elapsed")"
  echo
  echo "## Totals"
  echo
  echo "- Successful hosts: \`${successful_hosts}\`"
  echo "- Failed hosts: \`${failed_hosts}\`"
  echo "- Estimated files on successful hosts: \`${total_estimated}\`"
  echo "- Slowest successful node elapsed seconds: \`${max_elapsed}\`"
  echo "- Aggregate estimated files/s: \`${aggregate_fps}\`"
  echo "- Raw node reports: \`${REPORT_DIR}/nodes\`"
} >"$report_md"

aggregate_fps="$(rate_number "$total_estimated" "$max_elapsed")"
{
  echo "test_kind=metadata"
  echo "run_id=${TEST_RUN_ID}"
  echo "report_dir=${REPORT_DIR}"
  echo "hosts=${host_count}"
  echo "successful_hosts=${successful_hosts}"
  echo "failed_hosts=${failed_hosts}"
  echo "estimated_files=${total_estimated}"
  echo "max_elapsed_seconds=${max_elapsed}"
  echo "aggregate_files_per_second=${aggregate_fps}"
  echo "exit_code=${failed}"
} >"$summary_kv"

cat "$report_md"

if [ "$failed" -ne 0 ] || [ "$failed_hosts" -ne 0 ]; then
  exit 1
fi
