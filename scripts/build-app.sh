#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Configure zero-sudo CLT SwiftPM environment & SDKROOT
source "${REPO_ROOT}/scripts/swiftpm-env.sh"

APP_NAME="MetalPie"
BUNDLE_ID="com.metalpie.app"
VERSION="${METALPIE_VERSION:-1.0.0}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${METALPIE_BUILD_NUMBER:-1}"
SCRATCH_PATH="${METALPIE_RELEASE_SCRATCH:-.build-release}"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
CODESIGN_ID="${CODESIGN_IDENTITY:--}"

echo "==> [1/5] Building ${APP_NAME} (release) with scratch path '${SCRATCH_PATH}'..."
swift build -c release --scratch-path "${SCRATCH_PATH}" --product "${APP_NAME}"
BIN_DIR="$(swift build -c release --scratch-path "${SCRATCH_PATH}" --show-bin-path)"
EXECUTABLE_SRC="${BIN_DIR}/${APP_NAME}"

if [ ! -x "${EXECUTABLE_SRC}" ]; then
  echo "error: Release executable not found at ${EXECUTABLE_SRC}" >&2
  exit 1
fi

echo "==> [2/5] Generating macOS AppIcon.icns..."
mkdir -p "${DIST_DIR}"
ICON_TMP="${DIST_DIR}/AppIcon.icns"
swift "${REPO_ROOT}/scripts/generate-icon.swift" "${ICON_TMP}"

echo "==> [3/5] Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE_SRC}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
cp "${ICON_TMP}" "${RESOURCES_DIR}/AppIcon.icns"
rm -f "${ICON_TMP}"

# Copy all SwiftPM resource bundles (notably MetalPie_MetalPieShaders.bundle)
BUNDLE_COUNT=0
for bundle_path in "${BIN_DIR}"/*.bundle; do
  if [ -d "${bundle_path}" ]; then
    cp -R "${bundle_path}" "${RESOURCES_DIR}/"
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
  fi
done

SHADERS_BUNDLE="${RESOURCES_DIR}/MetalPie_MetalPieShaders.bundle"
if [ ! -d "${SHADERS_BUNDLE}" ]; then
  echo "error: Expected resource bundle missing: ${SHADERS_BUNDLE}" >&2
  exit 1
fi

METAL_COUNT="$(find "${SHADERS_BUNDLE}" -name '*.metal' | wc -l | tr -d ' ')"
echo "    Copied ${BUNDLE_COUNT} resource bundle(s); verified ${METAL_COUNT} .metal shader file(s) inside MetalPie_MetalPieShaders.bundle."
if [ "${METAL_COUNT}" -lt 10 ]; then
  echo "error: Expected 10 .metal shader files in bundle, found ${METAL_COUNT}." >&2
  exit 1
fi

printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MetalPie requires Screen Recording permission to capture target game and application windows via ScreenCaptureKit with zero-copy GPU performance.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

plutil -lint "${CONTENTS_DIR}/Info.plist"

echo "==> [4/5] Code signing ${APP_BUNDLE} (identity: '${CODESIGN_ID}')..."
codesign --force --deep --sign "${CODESIGN_ID}" --identifier "${BUNDLE_ID}" "${APP_BUNDLE}"

echo "==> [5/5] Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo ""
echo "Successfully built and signed: ${APP_BUNDLE}"
du -sh "${APP_BUNDLE}"
file "${MACOS_DIR}/${APP_NAME}"
