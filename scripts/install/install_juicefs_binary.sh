#!/usr/bin/env bash
set -euo pipefail

JUICEFS_VERSION="${JUICEFS_VERSION:-1.3.1}"
JUICEFS_OS="${JUICEFS_OS:-linux}"
JUICEFS_ARCH="${JUICEFS_ARCH:-}"
JUICEFS_INSTALL_DIR="${JUICEFS_INSTALL_DIR:-/usr/local/bin}"
JUICEFS_BASE_URL="${JUICEFS_BASE_URL:-https://github.com/juicedata/juicefs/releases/download/v${JUICEFS_VERSION}}"

detect_arch() {
  if [ -n "$JUICEFS_ARCH" ]; then
    printf '%s\n' "$JUICEFS_ARCH"
    return
  fi

  case "$(uname -m)" in
    x86_64 | amd64) printf '%s\n' "amd64" ;;
    aarch64 | arm64) printf '%s\n' "arm64" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

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

need_cmd tar
need_cmd sha256sum
need_cmd install

arch="$(detect_arch)"
pkg="juicefs-${JUICEFS_VERSION}-${JUICEFS_OS}-${arch}.tar.gz"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

download "${JUICEFS_BASE_URL}/${pkg}" "${workdir}/${pkg}"
download "${JUICEFS_BASE_URL}/checksums.txt" "${workdir}/checksums.txt"

(
  cd "$workdir"
  grep " ${pkg}$" checksums.txt | sha256sum -c -
  tar -zxf "$pkg"
)

if [ ! -x "${workdir}/juicefs" ]; then
  echo "juicefs binary not found in ${pkg}" >&2
  exit 1
fi

sudo_cmd=""
if [ ! -w "$JUICEFS_INSTALL_DIR" ] || [ ! -d "$JUICEFS_INSTALL_DIR" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    sudo_cmd="sudo"
  fi
fi

$sudo_cmd mkdir -p "$JUICEFS_INSTALL_DIR"
$sudo_cmd install -m 0755 "${workdir}/juicefs" "${JUICEFS_INSTALL_DIR}/juicefs"

"${JUICEFS_INSTALL_DIR}/juicefs" version
