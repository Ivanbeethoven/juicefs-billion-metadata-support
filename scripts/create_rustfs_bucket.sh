#!/usr/bin/env bash
set -euo pipefail

RUSTFS_ENDPOINT="${RUSTFS_ENDPOINT:-http://127.0.0.1:9000}"
RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-rustfsadmin}"
RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-rustfsadmin}"
RUSTFS_BUCKET="${RUSTFS_BUCKET:-juicefs-prod}"
MC_DOWNLOAD_URL="${MC_DOWNLOAD_URL:-https://dl.min.io/client/mc/release/linux-amd64/mc}"
MC_BIN="${MC_BIN:-/usr/local/bin/mc}"

download() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
}

run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [ ! -x "$MC_BIN" ]; then
  tmp_mc="$(mktemp)"
  download "$MC_DOWNLOAD_URL" "$tmp_mc"
  run install -m 0755 "$tmp_mc" "$MC_BIN"
  rm -f "$tmp_mc"
fi

for _ in $(seq 1 60); do
  if "$MC_BIN" alias set rustfs "$RUSTFS_ENDPOINT" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

"$MC_BIN" alias set rustfs "$RUSTFS_ENDPOINT" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY"
"$MC_BIN" mb --ignore-existing "rustfs/${RUSTFS_BUCKET}"
"$MC_BIN" ls "rustfs/${RUSTFS_BUCKET}"
