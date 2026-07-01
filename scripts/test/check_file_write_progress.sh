#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run/${PROJECT_NAME:-slayerfs-rustfs}}"
ENV_FILE="${ENV_FILE:-${RUN_DIR}/juicefs-aws.env}"

override_vars=(
  TEST_RUN_ID REPORT_DIR REPORT_ROOT JUICEFS_TEST_HOSTS SSH_USER SSH_KEY
  REMOTE_REPORT_ROOT FILE_WRITE_TEST_PREFIX TEST_PREFIX MOUNT_POINT CACHE_DIR
  EXACT_COUNT COUNT_HOST COUNT_TIMEOUT PREVIOUS_REPORTED_FILES
  TARGET_CUMULATIVE_FILES RUSTFS_BACKEND_HOSTS RUSTFS_BACKEND_JUMP_TARGET
  RUSTFS_BACKEND_DATA_DIRS
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
MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME:-juicefs-prod}}"
CACHE_DIR="${CACHE_DIR:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
EXACT_COUNT="${EXACT_COUNT:-0}"
COUNT_HOST="${COUNT_HOST:-}"
COUNT_TIMEOUT="${COUNT_TIMEOUT:-0}"
PREVIOUS_REPORTED_FILES="${PREVIOUS_REPORTED_FILES:-}"
TARGET_CUMULATIVE_FILES="${TARGET_CUMULATIVE_FILES:-}"
RUSTFS_BACKEND_HOSTS="${RUSTFS_BACKEND_HOSTS:-}"
RUSTFS_BACKEND_JUMP_TARGET="${RUSTFS_BACKEND_JUMP_TARGET:-}"
RUSTFS_BACKEND_DATA_DIRS="${RUSTFS_BACKEND_DATA_DIRS:-/data/rustfs1 /data/rustfs2 /data/rustfs3 /data/rustfs4}"

if [ -z "$PREVIOUS_REPORTED_FILES" ] && [ -s "${REPORT_DIR}/target.kv" ]; then
  PREVIOUS_REPORTED_FILES="$(kv_get previous_reported_files "${REPORT_DIR}/target.kv")"
fi
if [ -z "$TARGET_CUMULATIVE_FILES" ] && [ -s "${REPORT_DIR}/target.kv" ]; then
  TARGET_CUMULATIVE_FILES="$(kv_get target_cumulative_files "${REPORT_DIR}/target.kv")"
fi

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

first_host() {
  for host in $JUICEFS_TEST_HOSTS; do
    printf '%s\n' "$host"
    return 0
  done
}

echo "# JuiceFS file write progress"
echo
echo "run_id=${TEST_RUN_ID}"
echo "checked_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "mount_point=${MOUNT_POINT}"
echo "report_dir=${REPORT_DIR}"
if [ -n "$PREVIOUS_REPORTED_FILES" ]; then
  echo "previous_reported_files=${PREVIOUS_REPORTED_FILES}"
fi
if [ -n "$TARGET_CUMULATIVE_FILES" ]; then
  echo "target_cumulative_files=${TARGET_CUMULATIVE_FILES}"
fi

echo
echo "## client processes"
for host in $JUICEFS_TEST_HOSTS; do
  safe_host="$(safe_name "$host")"
  target="$(ssh_target "$SSH_USER" "$host")"
  remote_dir="${REMOTE_REPORT_ROOT}/${TEST_RUN_ID}"
  remote_report="${remote_dir}/${TEST_PREFIX}-${safe_host}.kv"
  remote_pid_file="${remote_dir}/${TEST_PREFIX}-${safe_host}.pid"
  remote_stderr="${remote_dir}/${TEST_PREFIX}-${safe_host}.stderr.log"

  echo
  echo "### ${host}"
  ssh "${ssh_opts[@]}" "$target" \
    "REMOTE_REPORT=$(shell_quote "$remote_report") REMOTE_PID_FILE=$(shell_quote "$remote_pid_file") REMOTE_STDERR=$(shell_quote "$remote_stderr") MOUNT_POINT=$(shell_quote "$MOUNT_POINT") CACHE_DIR=$(shell_quote "$CACHE_DIR") bash -s" <<'REMOTE'
set +e
pid=""
if [ -s "$REMOTE_PID_FILE" ]; then
  pid="$(cat "$REMOTE_PID_FILE" 2>/dev/null)"
fi
if [ -z "$pid" ]; then
  pid="$(pgrep -f "$REMOTE_REPORT|$(basename "$REMOTE_REPORT" .kv)" 2>/dev/null | head -1)"
fi

echo "pid=${pid:-}"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  echo "status=running"
  ps -o pid,ppid,etime,stat,pcpu,pmem,cmd -p "$pid" 2>/dev/null || true
  child_count="$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ')"
  echo "child_processes=${child_count:-0}"
else
  echo "status=not-running"
fi

if [ -s "$REMOTE_REPORT" ]; then
  echo "result=complete"
  grep -E '^(files_created|files_skipped|files_present|bytes_created|elapsed_seconds|files_per_second|errors|exit_code)=' "$REMOTE_REPORT" 2>/dev/null || true
else
  echo "result=pending"
fi

if [ -s "$REMOTE_STDERR" ]; then
  echo "stderr_tail:"
  tail -5 "$REMOTE_STDERR" 2>/dev/null || true
fi

echo "df:"
if [ -n "$CACHE_DIR" ]; then
  df -h "$MOUNT_POINT" "$CACHE_DIR" 2>/dev/null || true
else
  df -h "$MOUNT_POINT" 2>/dev/null || true
fi
REMOTE
done

if [ "$EXACT_COUNT" = "1" ]; then
  count_host="${COUNT_HOST:-$(first_host)}"
  count_target="$(ssh_target "$SSH_USER" "$count_host")"
  echo
  echo "## exact file count"
  echo "count_host=${count_host}"
  echo "note=exact counting scans JuiceFS metadata; avoid running it too frequently during a stress test"

  count_output="$(
    ssh "${ssh_opts[@]}" "$count_target" \
      "MOUNT_POINT=$(shell_quote "$MOUNT_POINT") TEST_PREFIX=$(shell_quote "$TEST_PREFIX") TEST_RUN_ID=$(shell_quote "$TEST_RUN_ID") COUNT_TIMEOUT=$(shell_quote "$COUNT_TIMEOUT") bash -s" <<'REMOTE'
set -euo pipefail
total=0
count_one() {
  dir="$1"
  if [ "${COUNT_TIMEOUT}" != "0" ] && command -v timeout >/dev/null 2>&1; then
    timeout "${COUNT_TIMEOUT}" find "$dir" -type f 2>/dev/null | wc -l
  else
    find "$dir" -type f 2>/dev/null | wc -l
  fi
}

for dir in "${MOUNT_POINT}/${TEST_PREFIX}-"*-"${TEST_RUN_ID}"-*; do
  [ -d "$dir" ] || continue
  count="$(count_one "$dir" | tr -d ' ')"
  total=$((total + count))
  printf 'dir=%s files=%s\n' "$(basename "$dir")" "$count"
done
printf 'current_run_visible_files=%s\n' "$total"
REMOTE
  )"
  printf '%s\n' "$count_output"
  visible="$(printf '%s\n' "$count_output" | awk -F= '$1 == "current_run_visible_files" {print $2; exit}')"
  if [ -n "${visible:-}" ] && [ -n "$PREVIOUS_REPORTED_FILES" ]; then
    cumulative=$((PREVIOUS_REPORTED_FILES + visible))
    echo "estimated_cumulative_files=${cumulative}"
    if [ -n "$TARGET_CUMULATIVE_FILES" ]; then
      remaining=$((TARGET_CUMULATIVE_FILES - cumulative))
      [ "$remaining" -lt 0 ] && remaining=0
      echo "estimated_remaining_files=${remaining}"
    fi
  fi
fi

if [ -n "$RUSTFS_BACKEND_HOSTS" ]; then
  echo
  echo "## RustFS backend disks"
  for backend_host in $RUSTFS_BACKEND_HOSTS; do
    echo
    echo "### ${backend_host}"
    backend_cmd="hostname -s; df -h ${RUSTFS_BACKEND_DATA_DIRS} 2>/dev/null || true"
    if [ -n "$RUSTFS_BACKEND_JUMP_TARGET" ]; then
      ssh "${ssh_opts[@]}" "$RUSTFS_BACKEND_JUMP_TARGET" \
        "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 $(shell_quote "$backend_host") $(shell_quote "$backend_cmd")" || true
    else
      ssh "${ssh_opts[@]}" "$backend_host" "$backend_cmd" || true
    fi
  done
fi
