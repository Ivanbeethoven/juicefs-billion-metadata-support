#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME:-slayerfs-rustfs}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"

override_vars=(
  TEST_RUN_ID REPORT_DIR REPORT_ROOT JUICEFS_TEST_HOSTS SSH_USER SSH_KEY
  REMOTE_REPORT_ROOT FILE_WRITE_TEST_PREFIX TEST_PREFIX
)
for var in "${override_vars[@]}"; do
  if [ "${!var+x}" ]; then
    printf -v "__override_${var}" '%s' "${!var}"
    printf -v "__override_set_${var}" '1'
  fi
done

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

for var in "${override_vars[@]}"; do
  set_var="__override_set_${var}"
  if [ "${!set_var:-}" = "1" ]; then
    value_var="__override_${var}"
    printf -v "$var" '%s' "${!value_var}"
    export "$var"
  fi
done

# shellcheck source=scripts/test/lib_report.sh
. "${SCRIPT_DIR}/lib_report.sh"

REPORT_ROOT="${REPORT_ROOT:-${REPO_ROOT}/reports}"
if [ -z "${TEST_RUN_ID:-}" ]; then
  latest_dir="$(find "${REPORT_ROOT}/file-write" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1 || true)"
  if [ -n "$latest_dir" ]; then
    TEST_RUN_ID="$(basename "$latest_dir")"
  fi
fi

[ -n "${TEST_RUN_ID:-}" ] || {
  echo "TEST_RUN_ID is required, or provide a reports/file-write/<run-id> directory" >&2
  exit 1
}

JUICEFS_TEST_HOSTS="${JUICEFS_TEST_HOSTS:-}"
[ -n "$JUICEFS_TEST_HOSTS" ] || {
  echo "JUICEFS_TEST_HOSTS is required" >&2
  exit 1
}

REPORT_DIR="${REPORT_DIR:-${REPORT_ROOT}/file-write/${TEST_RUN_ID}}"
REMOTE_REPORT_ROOT="${REMOTE_REPORT_ROOT:-/tmp/juicefs-test-reports}"
if [ -n "${FILE_WRITE_TEST_PREFIX:-}" ]; then
  TEST_PREFIX="$FILE_WRITE_TEST_PREFIX"
elif [ "${TEST_PREFIX:-}" = "mdtest" ]; then
  TEST_PREFIX="filewrite"
else
  TEST_PREFIX="${TEST_PREFIX:-filewrite}"
fi
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

ssh_target() {
  user="$1"
  host="$2"
  if [ -n "$user" ]; then
    printf '%s@%s\n' "$user" "$host"
  else
    printf '%s\n' "$host"
  fi
}

mkdir -p "${REPORT_DIR}/nodes"
hosts_file="${REPORT_DIR}/hosts.tsv"
: >"$hosts_file"

for host in $JUICEFS_TEST_HOSTS; do
  safe_host="$(safe_name "$host")"
  target="$(ssh_target "$SSH_USER" "$host")"
  node_dir="${REPORT_DIR}/nodes/${safe_host}"
  remote_dir="${REMOTE_REPORT_ROOT}/${TEST_RUN_ID}"
  remote_base="${remote_dir}/${TEST_PREFIX}-${safe_host}"
  mkdir -p "$node_dir"
  printf '%s\t%s\n' "$safe_host" "$host" >>"$hosts_file"

  scp "${ssh_opts[@]}" "${target}:${remote_base}.kv" "${node_dir}/result.kv" >"${node_dir}/result-scp.log" 2>"${node_dir}/result-scp.err" || true
  scp "${ssh_opts[@]}" "${target}:${remote_base}.stdout.log" "${node_dir}/remote-stdout.log" >"${node_dir}/remote-stdout-scp.log" 2>"${node_dir}/remote-stdout-scp.err" || true
  scp "${ssh_opts[@]}" "${target}:${remote_base}.stderr.log" "${node_dir}/remote-stderr.log" >"${node_dir}/remote-stderr-scp.log" 2>"${node_dir}/remote-stderr-scp.err" || true
  scp "${ssh_opts[@]}" "${target}:${remote_base}.pid" "${node_dir}/remote.pid" >"${node_dir}/remote-pid-scp.log" 2>"${node_dir}/remote-pid-scp.err" || true
done

report_md="${REPORT_DIR}/summary.md"
summary_kv="${REPORT_DIR}/summary.kv"
total_created=0
total_present=0
total_bytes_created=0
total_errors=0
successful_hosts=0
failed_hosts=0
pending_hosts=0
max_elapsed=0

{
  echo "# JuiceFS file write test report"
  echo
  echo "- Generated at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Run ID: \`${TEST_RUN_ID}\`"
  echo "- Source: remote result collection"
  echo
  echo "| Host | Status | Created | Reused | Present | Errors | Elapsed seconds | Created files/s | Created MiB/s | Test directory | Logs |"
  echo "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"

  while IFS="$(printf '\t')" read -r safe_host host; do
    kv="${REPORT_DIR}/nodes/${safe_host}/result.kv"
    if [ ! -s "$kv" ]; then
      echo "| ${host} | pending | 0 | 0 | 0 | 0 | 0 | 0 | 0 | \`unknown\` | [node](nodes/${safe_host}/) |"
      pending_hosts=$((pending_hosts + 1))
      continue
    fi

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
  echo "- Pending hosts: \`${pending_hosts}\`"
  echo "- Failed hosts: \`${failed_hosts}\`"
  echo "- Files created in collected results: \`${total_created}\`"
  echo "- Files present after resume accounting: \`${total_present}\`"
  echo "- Bytes created in collected results: \`${total_bytes_created}\`"
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
  echo "successful_hosts=${successful_hosts}"
  echo "pending_hosts=${pending_hosts}"
  echo "failed_hosts=${failed_hosts}"
  echo "files_created=${total_created}"
  echo "files_present=${total_present}"
  echo "bytes_created=${total_bytes_created}"
  echo "errors=${total_errors}"
  echo "max_elapsed_seconds=${max_elapsed}"
  echo "aggregate_files_per_second=${aggregate_fps}"
  echo "aggregate_mib_per_second=${aggregate_mib}"
  echo "exit_code=$([ "$failed_hosts" -eq 0 ] && echo 0 || echo 1)"
} >"$summary_kv"

cat "$report_md"
