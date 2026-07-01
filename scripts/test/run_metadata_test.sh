#!/usr/bin/env bash
set -euo pipefail

JUICEFS="${JUICEFS:-juicefs}"
META_URL="${META_URL:-}"
TEST_PREFIX="${TEST_PREFIX:-mdtest}"
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
TARGET_FILES="${TARGET_FILES:-${TARGET_FILES_PER_NODE:-1000000}}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
DEPTH="${DEPTH:-2}"
THREADS="${THREADS:-64}"
WRITE_SIZE="${WRITE_SIZE:-1}"
MDTEST_DIRS="${MDTEST_DIRS:-}"
EXTRA_MDTEST_ARGS="${EXTRA_MDTEST_ARGS:-}"
REPORT_FILE="${REPORT_FILE:-}"

if [ -z "$META_URL" ]; then
  echo "META_URL is required" >&2
  exit 1
fi

if ! "$JUICEFS" mdtest --help >/dev/null 2>&1; then
  echo "juicefs mdtest is not available in $JUICEFS" >&2
  exit 1
fi

if [ "$THREADS" -lt 1 ]; then
  echo "THREADS must be >= 1" >&2
  exit 1
fi

files_arg=$(( (FILES_PER_DIR + THREADS - 1) / THREADS ))
if [ "$files_arg" -lt 1 ]; then
  files_arg=1
fi

files_per_tree_dir=$(( files_arg * THREADS ))
target_tree_dirs=$(( (TARGET_FILES + files_per_tree_dir - 1) / files_per_tree_dir ))
if [ "$target_tree_dirs" -lt 1 ]; then
  target_tree_dirs=1
fi

dir_count() {
  width="$1"
  depth="$2"
  total=1
  level=1
  i=0
  while [ "$i" -lt "$depth" ]; do
    level=$(( level * width ))
    total=$(( total + level ))
    i=$(( i + 1 ))
  done
  printf '%s\n' "$total"
}

if [ -n "$MDTEST_DIRS" ]; then
  dirs="$MDTEST_DIRS"
else
  dirs=1
  while [ "$(dir_count "$dirs" "$DEPTH")" -lt "$target_tree_dirs" ]; do
    dirs=$(( dirs + 1 ))
  done
fi

actual_tree_dirs="$(dir_count "$dirs" "$DEPTH")"
estimated_files=$(( actual_tree_dirs * THREADS * files_arg ))

node_name="$(hostname -s 2>/dev/null || hostname)"
if [ -z "$REPORT_FILE" ]; then
  REPORT_FILE="/tmp/${TEST_PREFIX}-${node_name}-${TEST_RUN_ID}.kv"
fi
mkdir -p "$(dirname "$REPORT_FILE")"

test_dir="${TEST_PREFIX}-${node_name}-${TEST_RUN_ID}"

echo "metadata test:"
echo "  meta: ${META_URL}"
echo "  dir: ${test_dir}"
echo "  target files: ${TARGET_FILES}"
echo "  mdtest dir width: ${dirs}"
echo "  mdtest depth: ${DEPTH}"
echo "  mdtest files per thread per dir: ${files_arg}"
echo "  target files per tree dir: ${FILES_PER_DIR}"
echo "  estimated created files: ${estimated_files}"
echo "  threads: ${THREADS}"
echo "  write size: ${WRITE_SIZE}"

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
started_epoch="$(date +%s)"

set +e
"$JUICEFS" mdtest "$META_URL" "$test_dir" \
  --depth "$DEPTH" \
  --dirs "$dirs" \
  --files "$files_arg" \
  --threads "$THREADS" \
  --write "$WRITE_SIZE" \
  $EXTRA_MDTEST_ARGS
exit_code=$?
set -e

ended_epoch="$(date +%s)"
ended_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
elapsed=$(( ended_epoch - started_epoch ))
if [ "$elapsed" -lt 1 ]; then
  elapsed=1
fi
files_per_second="$(awk -v files="$estimated_files" -v elapsed="$elapsed" 'BEGIN { printf "%.2f", files / elapsed }')"
juicefs_version="$("$JUICEFS" version 2>/dev/null | head -1 || true)"

{
  echo "test_kind=metadata"
  echo "host=${node_name}"
  echo "run_id=${TEST_RUN_ID}"
  echo "meta_url=${META_URL}"
  echo "test_dir=${test_dir}"
  echo "target_files=${TARGET_FILES}"
  echo "estimated_files=${estimated_files}"
  echo "files_per_dir=${FILES_PER_DIR}"
  echo "mdtest_dirs=${dirs}"
  echo "mdtest_depth=${DEPTH}"
  echo "mdtest_files_arg=${files_arg}"
  echo "threads=${THREADS}"
  echo "write_size=${WRITE_SIZE}"
  echo "started_at=${started_at}"
  echo "ended_at=${ended_at}"
  echo "elapsed_seconds=${elapsed}"
  echo "files_per_second=${files_per_second}"
  echo "juicefs_version=${juicefs_version}"
  echo "exit_code=${exit_code}"
} >"$REPORT_FILE"

cat "$REPORT_FILE"
exit "$exit_code"
