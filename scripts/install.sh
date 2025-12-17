#!/usr/bin/env bash
set -euo pipefail

REPO_DEFAULT="ph8n/nytgames-cli"
REPO="${NYTGAMES_CLI_REPO:-$REPO_DEFAULT}"
VERSION="${NYTGAMES_CLI_VERSION:-}"
INSTALL_DIR="${NYTGAMES_CLI_INSTALL_DIR:-}"

BIN_NAME="nytgames"

usage() {
  cat <<EOF
Install nytgames-cli (binary: ${BIN_NAME}) from GitHub Releases.

Usage:
  install.sh [--repo OWNER/REPO] [--version X.Y.Z] [--dir DIR]

Env:
  NYTGAMES_CLI_REPO         (default: ${REPO_DEFAULT})
  NYTGAMES_CLI_VERSION      (default: latest)
  NYTGAMES_CLI_INSTALL_DIR  (default: ~/.local/bin)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --dir|--install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Darwin) os="darwin" ;;
  Linux) os="linux" ;;
  *)
    echo "unsupported OS: ${os}" >&2
    exit 1
    ;;
esac

case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *)
    echo "unsupported architecture: ${arch}" >&2
    exit 1
    ;;
esac

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="${HOME}/.local/bin"
fi

VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
  tag="$(
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*$/\\1/p' \
      | head -n 1
  )"
  if [[ -z "$tag" ]]; then
    echo "failed to resolve latest version from GitHub for ${REPO}" >&2
    exit 1
  fi
  VERSION="${tag#v}"
fi

asset="nytgames-cli_${VERSION}_${os}_${arch}.tar.gz"
base_url="https://github.com/${REPO}/releases/download/v${VERSION}"
url="${base_url}/${asset}"
checksums_url="${base_url}/checksums.txt"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Downloading ${url}"
curl -fL --retry 3 --retry-delay 1 -o "${tmp}/${asset}" "${url}"

if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
  if curl -fsSL -o "${tmp}/checksums.txt" "${checksums_url}"; then
    expected="$(awk -v f="${asset}" '$2 == f { print $1 }' "${tmp}/checksums.txt" | head -n 1)"
    if [[ -n "$expected" ]]; then
      if command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')"
      else
        actual="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
      fi
      if [[ "$expected" != "$actual" ]]; then
        echo "checksum mismatch for ${asset}" >&2
        echo "expected: ${expected}" >&2
        echo "actual:   ${actual}" >&2
        exit 1
      fi
    fi
  fi
fi

tar -xzf "${tmp}/${asset}" -C "${tmp}"

bin_path="${tmp}/${BIN_NAME}"
if [[ ! -f "$bin_path" ]]; then
  bin_path="$(find "${tmp}" -maxdepth 2 -type f -name "${BIN_NAME}" | head -n 1 || true)"
fi
if [[ -z "$bin_path" || ! -f "$bin_path" ]]; then
  echo "failed to find ${BIN_NAME} in archive" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
chmod +x "${bin_path}"
cp -f "${bin_path}" "${INSTALL_DIR}/${BIN_NAME}"

echo "Installed ${BIN_NAME} to ${INSTALL_DIR}/${BIN_NAME}"
if ! command -v "${BIN_NAME}" >/dev/null 2>&1; then
  echo "Note: ${INSTALL_DIR} is not on your PATH. Add it, e.g.:" >&2
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\"" >&2
fi

