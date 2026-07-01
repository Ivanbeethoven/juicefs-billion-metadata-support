#!/usr/bin/env bash
set -euo pipefail

JUICEFS="${JUICEFS:-juicefs}"
JFS_NAME="${JFS_NAME:-juicefs-prod}"
JFS_STORAGE="${JFS_STORAGE:-s3}"
JFS_TRASH_DAYS="${JFS_TRASH_DAYS:-0}"

required_vars="META_URL JFS_BUCKET JFS_ACCESS_KEY JFS_SECRET_KEY"
for var in $required_vars; do
  if [ -z "${!var:-}" ]; then
    echo "${var} is required" >&2
    exit 1
  fi
done

if "$JUICEFS" status "$META_URL" >/dev/null 2>&1; then
  echo "JuiceFS volume already formatted: ${META_URL}"
  exit 0
fi

"$JUICEFS" format \
  --storage "$JFS_STORAGE" \
  --bucket "$JFS_BUCKET" \
  --access-key "$JFS_ACCESS_KEY" \
  --secret-key "$JFS_SECRET_KEY" \
  --trash-days "$JFS_TRASH_DAYS" \
  "$META_URL" \
  "$JFS_NAME"
