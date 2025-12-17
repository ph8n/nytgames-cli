#!/usr/bin/env bash
set -euo pipefail

REPO_DEFAULT="ph8n/nytgames-cli"
REPO="$REPO_DEFAULT"
VERSION=""
CHECKSUMS_FILE=""
OUT_FILE=""

usage() {
  cat <<EOF
Generate a Homebrew formula for a GitHub release.

Usage:
  generate-homebrew-formula.sh --version X.Y.Z --checksums checksums.txt [--repo OWNER/REPO] [--out FILE]

Example:
  ./scripts/generate-homebrew-formula.sh --version 0.1.0 --checksums dist/checksums.txt --out dist/nytgames-cli.rb
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
    --checksums)
      CHECKSUMS_FILE="$2"
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

if [[ -z "$VERSION" || -z "$CHECKSUMS_FILE" ]]; then
  usage >&2
  exit 1
fi

VERSION="${VERSION#v}"
if [[ ! -f "$CHECKSUMS_FILE" ]]; then
  echo "checksums file not found: $CHECKSUMS_FILE" >&2
  exit 1
fi

sha_for() {
  local file="$1"
  awk -v f="$file" '$2 == f { print $1 }' "$CHECKSUMS_FILE" | head -n 1
}

darwin_amd64="nytgames-cli_${VERSION}_darwin_amd64.tar.gz"
darwin_arm64="nytgames-cli_${VERSION}_darwin_arm64.tar.gz"
linux_amd64="nytgames-cli_${VERSION}_linux_amd64.tar.gz"
linux_arm64="nytgames-cli_${VERSION}_linux_arm64.tar.gz"

sha_darwin_amd64="$(sha_for "$darwin_amd64")"
sha_darwin_arm64="$(sha_for "$darwin_arm64")"
sha_linux_amd64="$(sha_for "$linux_amd64")"
sha_linux_arm64="$(sha_for "$linux_arm64")"

for v in sha_darwin_amd64 sha_darwin_arm64 sha_linux_amd64 sha_linux_arm64; do
  if [[ -z "${!v}" ]]; then
    echo "missing checksum for ${v#sha_}" >&2
    exit 1
  fi
done

formula="$(
  cat <<EOF
class NytgamesCli < Formula
  desc "CLI tool to play NYT Games in your terminal"
  homepage "https://github.com/${REPO}"
  license "MIT"
  version "${VERSION}"

  on_macos do
    on_arm do
      url "https://github.com/${REPO}/releases/download/v${VERSION}/${darwin_arm64}"
      sha256 "${sha_darwin_arm64}"
    end
    on_intel do
      url "https://github.com/${REPO}/releases/download/v${VERSION}/${darwin_amd64}"
      sha256 "${sha_darwin_amd64}"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/${REPO}/releases/download/v${VERSION}/${linux_arm64}"
      sha256 "${sha_linux_arm64}"
    end
    on_intel do
      url "https://github.com/${REPO}/releases/download/v${VERSION}/${linux_amd64}"
      sha256 "${sha_linux_amd64}"
    end
  end

  def install
    bin.install "nytgames"
  end

  test do
    system "#{bin}/nytgames", "--version"
  end
end
EOF
)"

if [[ -n "$OUT_FILE" ]]; then
  printf "%s\n" "$formula" >"$OUT_FILE"
else
  printf "%s\n" "$formula"
fi

