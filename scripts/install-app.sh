#!/bin/sh
# Installs the TokenCensus menu-bar app into /Applications.
# Replaces any previous TokenCensusApp.app and the legacy TokenLedgerApp.app.
# Usage: ./scripts/install-app.sh   (run from the repo root)
set -eu

cd "$(dirname "$0")/.."

APP_NAME="TokenCensusApp"
BUNDLE_ID="com.tokencensus.app"
VERSION="1.0"
BUILD="2"
STAGE=".build/app/${APP_NAME}.app"

echo "==> building release (${APP_NAME})"
swift build -c release --product "${APP_NAME}"

echo "==> assembling bundle"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/Contents/MacOS" "${STAGE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${STAGE}/Contents/MacOS/${APP_NAME}"
printf 'APPL????' > "${STAGE}/Contents/PkgInfo"
cat > "${STAGE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>TokenCensus</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force -s - "${STAGE}" 2>/dev/null || true

echo "==> removing legacy bundles"
rm -rf "/Applications/${APP_NAME}.app" "/Applications/TokenLedgerApp.app"

echo "==> installing to /Applications"
cp -R "${STAGE}" "/Applications/${APP_NAME}.app"

echo "installed: /Applications/${APP_NAME}.app"
ls -d "/Applications/${APP_NAME}.app"
