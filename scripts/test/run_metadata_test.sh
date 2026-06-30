#!/usr/bin/env bash
set -euo pipefail

JUICEFS="${JUICEFS:-juicefs}"
META_URL="${META_URL:-}"
TEST_PREFIX="${TEST_PREFIX:-mdtest}"
TARGET_FILES="${TARGET_FILES:-${TARGET_FILES_PER_NODE:-1000000}}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
DEPTH="${DEPTH:-2}"
THREADS="${THREADS:-64}"
WRITE_SIZE="${WRITE_SIZE:-1}"
MDTEST_DIRS="${MDTEST_DIRS:-}"
EXTRA_MDTEST_ARGS="${EXTRA_MDTEST_ARGS:-}"

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
run_id="$(date +%Y%m%d-%H%M%S)"
test_dir="${TEST_PREFIX}-${node_name}-${run_id}"

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

"$JUICEFS" mdtest "$META_URL" "$test_dir" \
  --depth "$DEPTH" \
  --dirs "$dirs" \
  --files "$files_arg" \
  --threads "$THREADS" \
  --write "$WRITE_SIZE" \
  $EXTRA_MDTEST_ARGS
