#!/usr/bin/env bash
set -euo pipefail

VERSION=""
ARCH=""
TARBALL=""
OUT_FILE=""

PKG_NAME="nytgames-cli"
BIN_NAME="nytgames"
HOMEPAGE="https://github.com/ph8n/nytgames-cli"
SUMMARY="CLI tool to play NYT Games in your terminal"
LICENSE="MIT"

usage() {
  cat <<EOF
Build an .rpm package from a release tarball containing ${BIN_NAME} and LICENSE.

Usage:
  build-rpm.sh --version X.Y.Z --arch amd64|arm64 --tar PATH --out FILE

Example:
  ./scripts/build-rpm.sh --version 0.1.0 --arch amd64 --tar dist/nytgames-cli_0.1.0_linux_amd64.tar.gz --out dist/nytgames-cli_0.1.0_linux_amd64.rpm
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
    --tar)
      TARBALL="$2"
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
if [[ -z "$VERSION" || -z "$ARCH" || -z "$TARBALL" || -z "$OUT_FILE" ]]; then
  usage >&2
  exit 1
fi
if [[ ! -f "$TARBALL" ]]; then
  echo "tarball not found: $TARBALL" >&2
  exit 1
fi
if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "rpmbuild not found" >&2
  exit 1
fi

case "$ARCH" in
  amd64) rpm_target="x86_64" ;;
  arm64) rpm_target="aarch64" ;;
  *)
    echo "unsupported arch: $ARCH (expected amd64 or arm64)" >&2
    exit 1
    ;;
esac

topdir="$(mktemp -d)"
cleanup() { rm -rf "$topdir"; }
trap cleanup EXIT

mkdir -p "${topdir}/"{BUILD,RPMS,SOURCES,SPECS,SRPMS}

srcfile="$(basename "$TARBALL")"
cp -f "$TARBALL" "${topdir}/SOURCES/${srcfile}"

spec="${topdir}/SPECS/${PKG_NAME}.spec"
cat >"$spec" <<EOF
Name:           ${PKG_NAME}
Version:        ${VERSION}
Release:        1
Summary:        ${SUMMARY}

License:        ${LICENSE}
URL:            ${HOMEPAGE}
Source0:        ${srcfile}

BuildArch:      ${rpm_target}

%description
${SUMMARY}

%prep
%setup -q -c -T
tar -xzf %{SOURCE0}

%install
mkdir -p %{buildroot}/usr/bin
install -m 0755 ${BIN_NAME} %{buildroot}/usr/bin/${BIN_NAME}
mkdir -p %{buildroot}/usr/share/licenses/%{name}
install -m 0644 LICENSE %{buildroot}/usr/share/licenses/%{name}/LICENSE

%files
/usr/bin/${BIN_NAME}
%license /usr/share/licenses/%{name}/LICENSE
EOF

rpmbuild --define "_topdir ${topdir}" --target "${rpm_target}" -bb "$spec" >/dev/null

rpm_path="$(find "${topdir}/RPMS" -type f -name "${PKG_NAME}-${VERSION}-1.${rpm_target}.rpm" | head -n 1 || true)"
if [[ -z "$rpm_path" || ! -f "$rpm_path" ]]; then
  echo "failed to find built rpm output" >&2
  find "${topdir}/RPMS" -type f -maxdepth 3 >&2 || true
  exit 1
fi

cp -f "$rpm_path" "$OUT_FILE"
echo "Wrote ${OUT_FILE}"

