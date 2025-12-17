#!/usr/bin/env bash
set -euo pipefail

VERSION=""
ARCH=""
BIN_PATH=""
OUT_FILE=""

PKG_NAME="nytgames-cli"
BIN_NAME="nytgames"
MAINTAINER="ph8n"
HOMEPAGE="https://github.com/ph8n/nytgames-cli"
DESCRIPTION="CLI tool to play NYT Games in your terminal"

usage() {
  cat <<EOF
Build a .deb package from a prebuilt binary.

Usage:
  build-deb.sh --version X.Y.Z --arch amd64|arm64 --bin PATH --out FILE

Example:
  ./scripts/build-deb.sh --version 0.1.0 --arch amd64 --bin dist/nytgames --out dist/nytgames-cli_0.1.0_linux_amd64.deb
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --bin)
      BIN_PATH="$2"
      shift 2
      ;;
    --out)
      OUT_FILE="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

VERSION="${VERSION#v}"
if [[ -z "$VERSION" || -z "$ARCH" || -z "$BIN_PATH" || -z "$OUT_FILE" ]]; then
  usage >&2
  exit 1
fi
if [[ ! -f "$BIN_PATH" ]]; then
  echo "binary not found: $BIN_PATH" >&2
  exit 1
fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb not found" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "${tmp}/pkg/DEBIAN"
mkdir -p "${tmp}/pkg/usr/bin"
mkdir -p "${tmp}/pkg/usr/share/doc/${PKG_NAME}"

install -m 0755 "$BIN_PATH" "${tmp}/pkg/usr/bin/${BIN_NAME}"
if [[ -f "LICENSE" ]]; then
  install -m 0644 "LICENSE" "${tmp}/pkg/usr/share/doc/${PKG_NAME}/LICENSE"
fi
if [[ -f "README.md" ]]; then
  install -m 0644 "README.md" "${tmp}/pkg/usr/share/doc/${PKG_NAME}/README.md"
fi

cat >"${tmp}/pkg/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Homepage: ${HOMEPAGE}
Description: ${DESCRIPTION}
EOF

dpkg-deb --build "${tmp}/pkg" "${OUT_FILE}" >/dev/null
echo "Wrote ${OUT_FILE}"

