#!/bin/sh
# Builds a drag-to-install TokenCensus .dmg (no external deps, hdiutil only).
# Output: .build/TokenCensus-<VERSION>-macOS-arm64.dmg containing:
#   TokenCensusApp.app + /Applications symlink + tok CLI binary
# Usage: ./scripts/build-dmg.sh            (version from latest git tag)
#        VERSION=1.1.0 BUILD=42 ./scripts/build-dmg.sh
set -eu

cd "$(dirname "$0")/.."

APP_NAME="TokenCensusApp"

GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0")"
GIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
VERSION="${VERSION:-$(printf '%s' "$GIT_TAG" | sed 's/^v//')}"
BUILD="${BUILD:-$GIT_COUNT}"

DMG_BASENAME="TokenCensus-${VERSION}-macOS-arm64"
STAGING=".build/dmg-staging"
OUTPUT=".build/${DMG_BASENAME}.dmg"

echo "==> packaging app bundle (version ${VERSION} build ${BUILD})"
VERSION="$VERSION" BUILD="$BUILD" ./scripts/package-app.sh

echo "==> building tok CLI (release)"
swift build -c release --product tok

echo "==> staging DMG contents"
rm -rf "${STAGING}" "${OUTPUT}"
mkdir -p "${STAGING}"
cp -R ".build/app/${APP_NAME}.app" "${STAGING}/"
cp ".build/release/tok" "${STAGING}/tok"
ln -s /Applications "${STAGING}/Applications"
cat > "${STAGING}/Install tok CLI (optional).txt" <<TXT
TokenCensus ${VERSION} — install

App (recommended):
  1. Drag TokenCensusApp.app onto Applications.
  2. Open it from Applications or Spotlight.
  3. First launch (unsigned build): right-click the app >
     Open > Open, to bypass Gatekeeper once.

Optional CLI:
  sudo cp tok /usr/local/bin/tok
  tok ingest && tok today
TXT

echo "==> creating DMG at ${OUTPUT}"
hdiutil create \
  -volname "TokenCensus ${VERSION}" \
  -srcfolder "${STAGING}" \
  -ov -format UDZO "${OUTPUT}" >/dev/null

rm -rf "${STAGING}"
echo "dmg: ${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"
hdiutil verify "${OUTPUT}" >/dev/null && echo "verify: OK"
