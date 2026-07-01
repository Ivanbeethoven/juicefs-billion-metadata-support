#!/usr/bin/env bash
set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/${JFS_NAME:-juicefs-prod}}"
if [ -n "${FILE_WRITE_TEST_PREFIX:-}" ]; then
  TEST_PREFIX="$FILE_WRITE_TEST_PREFIX"
elif [ "${TEST_PREFIX:-}" = "mdtest" ]; then
  TEST_PREFIX="filewrite"
else
  TEST_PREFIX="${TEST_PREFIX:-filewrite}"
fi
TEST_RUN_ID="${TEST_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
TEST_DIR="${TEST_DIR:-}"
TARGET_FILES="${TARGET_FILES:-${FILE_WRITE_TARGET_PER_NODE:-${TARGET_FILES_PER_NODE:-1000000}}}"
FILE_SIZE_BYTES="${FILE_SIZE_BYTES:-${FILE_WRITE_SIZE_BYTES:-${WRITE_SIZE:-1}}}"
FILES_PER_DIR="${FILES_PER_DIR:-10000}"
WORKERS="${WORKERS:-${FILE_WRITE_WORKERS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}}"
MAX_SECONDS="${MAX_SECONDS:-${FILE_WRITE_MAX_SECONDS:-0}}"
REPORT_FILE="${REPORT_FILE:-}"
SYNC_EVERY="${SYNC_EVERY:-${FILE_WRITE_SYNC_EVERY:-0}}"
REQUIRE_MOUNT="${REQUIRE_MOUNT:-1}"
RESUME_TEST="${RESUME_TEST:-0}"

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

export MOUNT_POINT TEST_PREFIX TEST_RUN_ID TEST_DIR TARGET_FILES FILE_SIZE_BYTES FILES_PER_DIR WORKERS MAX_SECONDS REPORT_FILE SYNC_EVERY RESUME_TEST

python3 <<'PY'
import multiprocessing as mp
import os
import socket
import sys
import time

mount_point = os.environ["MOUNT_POINT"]
prefix = os.environ["TEST_PREFIX"]
run_id = os.environ["TEST_RUN_ID"]
test_dir_override = os.environ.get("TEST_DIR", "")
target_files = int(os.environ["TARGET_FILES"])
file_size = int(os.environ["FILE_SIZE_BYTES"])
files_per_dir = max(1, int(os.environ["FILES_PER_DIR"]))
workers = max(1, int(os.environ["WORKERS"]))
max_seconds = max(0, int(os.environ["MAX_SECONDS"]))
report_file = os.environ["REPORT_FILE"]
sync_every = max(0, int(os.environ["SYNC_EVERY"]))
resume = os.environ.get("RESUME_TEST", "0") == "1"

hostname = socket.gethostname().split(".")[0]
base_dir = test_dir_override or os.path.join(mount_point, f"{prefix}-{hostname}-{run_id}")
os.makedirs(base_dir, exist_ok=True)

payload = b"x" * file_size
per_worker = [(target_files + workers - 1 - i) // workers for i in range(workers)]
deadline = time.monotonic() + max_seconds if max_seconds > 0 else None


def write_worker(worker_id: int, count: int):
    created = 0
    skipped = 0
    errors = 0
    bytes_created = 0
    bytes_skipped = 0
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
            if resume and os.path.exists(file_path):
                if os.path.getsize(file_path) == file_size:
                    skipped += 1
                    bytes_skipped += file_size
                    continue

            with open(file_path, "wb", buffering=0) as handle:
                handle.write(payload)
                if sync_every > 0 and created > 0 and created % sync_every == 0:
                    os.fsync(handle.fileno())
            created += 1
            bytes_created += file_size
        except Exception as exc:  # noqa: BLE001 - report and keep pressure on the filesystem.
            errors += 1
            print(f"worker={worker_id} error={exc}", file=sys.stderr, flush=True)

    return created, skipped, bytes_created, bytes_skipped, errors


started_at = time.time()
with mp.Pool(processes=workers) as pool:
    results = pool.starmap(write_worker, [(i, per_worker[i]) for i in range(workers)])
ended_at = time.time()

files_created = sum(item[0] for item in results)
files_skipped = sum(item[1] for item in results)
bytes_created = sum(item[2] for item in results)
bytes_skipped = sum(item[3] for item in results)
errors = sum(item[4] for item in results)
files_present = files_created + files_skipped
bytes_present = bytes_created + bytes_skipped
elapsed = max(ended_at - started_at, 0.001)
created_files_per_sec = files_created / elapsed
created_mb_per_sec = bytes_created / elapsed / 1024 / 1024
present_files_per_sec = files_present / elapsed

lines = [
    ("test_kind", "file_write"),
    ("host", hostname),
    ("run_id", run_id),
    ("mount_point", mount_point),
    ("test_dir", base_dir),
    ("resume", "1" if resume else "0"),
    ("target_files", str(target_files)),
    ("files_created", str(files_created)),
    ("files_skipped", str(files_skipped)),
    ("files_present", str(files_present)),
    ("bytes_created", str(bytes_created)),
    ("bytes_skipped", str(bytes_skipped)),
    ("bytes_present", str(bytes_present)),
    ("files_written", str(files_created)),
    ("bytes_written", str(bytes_created)),
    ("file_size_bytes", str(file_size)),
    ("files_per_dir", str(files_per_dir)),
    ("workers", str(workers)),
    ("max_seconds", str(max_seconds)),
    ("errors", str(errors)),
    ("elapsed_seconds", f"{elapsed:.3f}"),
    ("files_per_second", f"{created_files_per_sec:.2f}"),
    ("mb_per_second", f"{created_mb_per_sec:.2f}"),
    ("present_files_per_second", f"{present_files_per_sec:.2f}"),
    ("exit_code", "1" if errors else "0"),
]

with open(report_file, "w", encoding="utf-8") as report:
    for key, value in lines:
        report.write(f"{key}={value}\n")

for key, value in lines:
    print(f"{key}={value}")

sys.exit(1 if errors else 0)
PY
