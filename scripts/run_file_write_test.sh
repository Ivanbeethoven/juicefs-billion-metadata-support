#!/usr/bin/env bash
set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME:-juicefs-prod}}"
TEST_PREFIX="${TEST_PREFIX:-filewrite}"
TARGET_FILES="${TARGET_FILES:-${FILE_WRITE_TARGET_PER_NODE:-${TARGET_FILES_PER_NODE:-1000000}}}"
FILE_SIZE_BYTES="${FILE_SIZE_BYTES:-${FILE_WRITE_SIZE_BYTES:-${WRITE_SIZE:-1}}}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
WORKERS="${WORKERS:-${FILE_WRITE_WORKERS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}}"
MAX_SECONDS="${MAX_SECONDS:-${FILE_WRITE_MAX_SECONDS:-0}}"
REPORT_FILE="${REPORT_FILE:-}"
SYNC_EVERY="${SYNC_EVERY:-${FILE_WRITE_SYNC_EVERY:-0}}"
REQUIRE_MOUNT="${REQUIRE_MOUNT:-1}"

if [ ! -d "$MOUNT_POINT" ]; then
  echo "MOUNT_POINT does not exist: ${MOUNT_POINT}" >&2
  exit 1
fi

if [ "$REQUIRE_MOUNT" = "1" ] && command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$MOUNT_POINT"; then
  echo "MOUNT_POINT is not a mounted filesystem: ${MOUNT_POINT}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for high-concurrency file write test" >&2
  exit 1
fi

if [ -z "$REPORT_FILE" ]; then
  REPORT_FILE="/tmp/${TEST_PREFIX}-$(hostname -s 2>/dev/null || hostname)-$(date +%Y%m%d-%H%M%S).kv"
fi

mkdir -p "$(dirname "$REPORT_FILE")"

export MOUNT_POINT TEST_PREFIX TARGET_FILES FILE_SIZE_BYTES FILES_PER_DIR WORKERS MAX_SECONDS REPORT_FILE SYNC_EVERY

python3 <<'PY'
import multiprocessing as mp
import os
import socket
import sys
import time

mount_point = os.environ["MOUNT_POINT"]
prefix = os.environ["TEST_PREFIX"]
target_files = int(os.environ["TARGET_FILES"])
file_size = int(os.environ["FILE_SIZE_BYTES"])
files_per_dir = max(1, int(os.environ["FILES_PER_DIR"]))
workers = max(1, int(os.environ["WORKERS"]))
max_seconds = max(0, int(os.environ["MAX_SECONDS"]))
report_file = os.environ["REPORT_FILE"]
sync_every = max(0, int(os.environ["SYNC_EVERY"]))

run_id = time.strftime("%Y%m%d-%H%M%S")
hostname = socket.gethostname().split(".")[0]
base_dir = os.path.join(mount_point, f"{prefix}-{hostname}-{run_id}")
os.makedirs(base_dir, exist_ok=True)

payload = b"x" * file_size
per_worker = [(target_files + workers - 1 - i) // workers for i in range(workers)]
deadline = time.monotonic() + max_seconds if max_seconds > 0 else None


def write_worker(worker_id: int, count: int):
    written = 0
    errors = 0
    bytes_written = 0
    worker_dir = os.path.join(base_dir, f"w{worker_id:04d}")
    os.makedirs(worker_dir, exist_ok=True)

    for index in range(count):
        if deadline is not None and time.monotonic() >= deadline:
            break

        dir_id = index // files_per_dir
        dir_path = os.path.join(worker_dir, f"d{dir_id:08d}")
        try:
            os.makedirs(dir_path, exist_ok=True)
            file_path = os.path.join(dir_path, f"f{index:012d}")
            with open(file_path, "wb", buffering=0) as handle:
                handle.write(payload)
                if sync_every > 0 and written > 0 and written % sync_every == 0:
                    os.fsync(handle.fileno())
            written += 1
            bytes_written += file_size
        except Exception as exc:  # noqa: BLE001 - report and keep pressure on the filesystem.
            errors += 1
            print(f"worker={worker_id} error={exc}", file=sys.stderr, flush=True)

    return written, bytes_written, errors


started_at = time.time()
with mp.Pool(processes=workers) as pool:
    results = pool.starmap(write_worker, [(i, per_worker[i]) for i in range(workers)])
ended_at = time.time()

files_written = sum(item[0] for item in results)
bytes_written = sum(item[1] for item in results)
errors = sum(item[2] for item in results)
elapsed = max(ended_at - started_at, 0.001)
files_per_sec = files_written / elapsed
mb_per_sec = bytes_written / elapsed / 1024 / 1024

lines = [
    ("host", hostname),
    ("mount_point", mount_point),
    ("test_dir", base_dir),
    ("target_files", str(target_files)),
    ("files_written", str(files_written)),
    ("bytes_written", str(bytes_written)),
    ("file_size_bytes", str(file_size)),
    ("files_per_dir", str(files_per_dir)),
    ("workers", str(workers)),
    ("max_seconds", str(max_seconds)),
    ("errors", str(errors)),
    ("elapsed_seconds", f"{elapsed:.3f}"),
    ("files_per_second", f"{files_per_sec:.2f}"),
    ("mb_per_second", f"{mb_per_sec:.2f}"),
]

with open(report_file, "w", encoding="utf-8") as report:
    for key, value in lines:
        report.write(f"{key}={value}\n")

for key, value in lines:
    print(f"{key}={value}")

sys.exit(1 if errors else 0)
PY
