#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

APP_NAME="MetalPie"
DEFAULT_GIT_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo '1.0.2')"
RAW_VERSION="${METALPIE_VERSION:-${DEFAULT_GIT_VERSION}}"
VERSION="${RAW_VERSION#v}"
DMG_LABEL_VERSION="${METALPIE_DMG_VERSION:-${VERSION}}"
DMG_LABEL_VERSION="${DMG_LABEL_VERSION#v}"
ARCH="${METALPIE_ARCH:-$(uname -m)}"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${DMG_LABEL_VERSION}-${ARCH}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"
VOLUME_NAME="${APP_NAME} ${VERSION}"
SKIP_APP_BUILD=false

for arg in "$@"; do
  case "${arg}" in
    --skip-app-build)
      SKIP_APP_BUILD=true
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: $0 [--skip-app-build]" >&2
      exit 1
      ;;
  esac
done

if [ "${SKIP_APP_BUILD}" != "true" ] || [ ! -d "${APP_BUNDLE}" ]; then
  METALPIE_VERSION="${VERSION}" "${REPO_ROOT}/scripts/build-app.sh"
fi

if [ ! -d "${APP_BUNDLE}" ]; then
  echo "error: App bundle not found at ${APP_BUNDLE}" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/metalpie-dmg.XXXXXX")"
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

echo "==> [1/4] Staging ${APP_NAME}.app and /Applications symlink..."
ditto "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> [2/4] Creating compressed DMG: ${DMG_PATH}..."
mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${SHA_PATH}"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_PATH}"

if [ -n "${CODESIGN_IDENTITY:-}" ] && [ "${CODESIGN_IDENTITY}" != "-" ]; then
  echo "==> Signing DMG with identity '${CODESIGN_IDENTITY}'..."
  codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp "${DMG_PATH}"
fi

echo "==> [3/4] Verifying DMG integrity..."
hdiutil verify "${DMG_PATH}"

echo "==> [4/4] Generating SHA-256 checksum..."
(
  cd "${DIST_DIR}"
  shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

echo ""
echo "Successfully built DMG: ${DMG_PATH}"
ls -lh "${DMG_PATH}" "${SHA_PATH}"
cat "${SHA_PATH}"
