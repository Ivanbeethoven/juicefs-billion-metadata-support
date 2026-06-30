#!/usr/bin/env bash
set -euo pipefail

RUSTFS_DOWNLOAD_URL="${RUSTFS_DOWNLOAD_URL:-https://dl.rustfs.com/artifacts/rustfs/release/rustfs-linux-x86_64-musl-latest.zip}"
RUSTFS_INSTALL_DIR="${RUSTFS_INSTALL_DIR:-/usr/local/bin}"

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

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

need_cmd unzip
need_cmd install

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

download "$RUSTFS_DOWNLOAD_URL" "${workdir}/rustfs.zip"
unzip -q "${workdir}/rustfs.zip" -d "$workdir"

rustfs_bin="$(find "$workdir" -type f -name rustfs -perm -u+x | head -n 1)"
if [ -z "$rustfs_bin" ]; then
  rustfs_bin="$(find "$workdir" -type f -name rustfs | head -n 1)"
fi

if [ -z "$rustfs_bin" ]; then
  echo "rustfs binary not found in archive" >&2
  exit 1
fi

sudo_cmd=""
if [ "$(id -u)" -ne 0 ]; then
  sudo_cmd="sudo"
fi

$sudo_cmd mkdir -p "$RUSTFS_INSTALL_DIR"
$sudo_cmd install -m 0755 "$rustfs_bin" "${RUSTFS_INSTALL_DIR}/rustfs"
"${RUSTFS_INSTALL_DIR}/rustfs" --help >/dev/null || true
echo "installed ${RUSTFS_INSTALL_DIR}/rustfs"
