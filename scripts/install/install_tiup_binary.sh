#!/usr/bin/env bash
set -euo pipefail

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TIDB_ARCH="${TIDB_ARCH:-}"
TIUP_INSTALL_MODE="${TIUP_INSTALL_MODE:-offline}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-.downloads}"
PINGCAP_BASE_URL="${PINGCAP_BASE_URL:-https://download.pingcap.com}"
TIUP_HOME="${TIUP_HOME:-$HOME/.tiup}"

detect_arch() {
  if [ -n "$TIDB_ARCH" ]; then
    printf '%s\n' "$TIDB_ARCH"
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
  if [ -f "$output" ]; then
    echo "using existing ${output}"
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
}

install_online() {
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://tiup-mirrors.pingcap.com/install.sh | sh
  else
    echo "curl or wget is required" >&2
    exit 1
  fi

  "${TIUP_HOME}/bin/tiup" update --self
  "${TIUP_HOME}/bin/tiup" update cluster
  "${TIUP_HOME}/bin/tiup" cluster --help >/dev/null
}

install_offline() {
  arch="$(detect_arch)"
  mkdir -p "$DOWNLOAD_DIR"

  server_pkg="tidb-community-server-${TIDB_VERSION}-linux-${arch}.tar.gz"
  toolkit_pkg="tidb-community-toolkit-${TIDB_VERSION}-linux-${arch}.tar.gz"

  download "${PINGCAP_BASE_URL}/${server_pkg}" "${DOWNLOAD_DIR}/${server_pkg}"
  download "${PINGCAP_BASE_URL}/${toolkit_pkg}" "${DOWNLOAD_DIR}/${toolkit_pkg}"

  extract_dir="${DOWNLOAD_DIR}/extract-${TIDB_VERSION}-linux-${arch}"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  tar -zxf "${DOWNLOAD_DIR}/${server_pkg}" -C "$extract_dir"
  tar -zxf "${DOWNLOAD_DIR}/${toolkit_pkg}" -C "$extract_dir"

  server_dir="${extract_dir}/tidb-community-server-${TIDB_VERSION}-linux-${arch}"
  toolkit_dir="${extract_dir}/tidb-community-toolkit-${TIDB_VERSION}-linux-${arch}"

  sh "${server_dir}/local_install.sh"
  mkdir -p "$TIUP_HOME"
  cp -rp "${server_dir}/keys" "$TIUP_HOME/"
  "${TIUP_HOME}/bin/tiup" mirror merge "$toolkit_dir"
  "${TIUP_HOME}/bin/tiup" cluster --help >/dev/null
}

case "$TIUP_INSTALL_MODE" in
  offline) install_offline ;;
  online) install_online ;;
  *) echo "TIUP_INSTALL_MODE must be offline or online" >&2; exit 1 ;;
esac

"${TIUP_HOME}/bin/tiup" list tikv
