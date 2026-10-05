#!/bin/sh
# Builds the TokenCensus menu-bar .app bundle into .build/app/TokenCensusApp.app
# Shared by install-app.sh (local /Applications install) and build-dmg.sh (release DMG).
# Env overrides: VERSION (e.g. 1.1.0), BUILD (e.g. 42).
# Defaults: VERSION from latest git tag (strip leading v), BUILD = commit count.
set -eu

cd "$(dirname "$0")/.."

APP_NAME="TokenCensusApp"
BUNDLE_ID="com.tokencensus.app"

GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0")"
GIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
VERSION="${VERSION:-$(printf '%s' "$GIT_TAG" | sed 's/^v//')}"
BUILD="${BUILD:-$GIT_COUNT}"
STAGE=".build/app/${APP_NAME}.app"

echo "==> building release (${APP_NAME} ${VERSION} build ${BUILD})"
swift build -c release --product "${APP_NAME}"

echo "==> assembling bundle at ${STAGE}"
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
	<key>CFBundleDisplayName</key>
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

echo "bundled: ${STAGE} (${VERSION} build ${BUILD})"
