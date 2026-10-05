#!/bin/sh
# Installs the TokenCensus menu-bar app into /Applications.
# Replaces any previous TokenCensusApp.app after keeping a dated backup.
# Usage: ./scripts/install-app.sh   (run from the repo root)
set -eu

cd "$(dirname "$0")/.."

APP_NAME="TokenCensusApp"
STAGE=".build/app/${APP_NAME}.app"

echo "==> packaging app bundle"
./scripts/package-app.sh

echo "==> preserving any existing installation before replacement"
if [ -e "/Applications/${APP_NAME}.app" ]; then
  BACKUP="/Applications/${APP_NAME}.app.backup-$(date +%Y%m%d-%H%M%S)"
  echo "==> preserving existing app at ${BACKUP}"
  mv "/Applications/${APP_NAME}.app" "${BACKUP}"
fi

echo "==> installing to /Applications"
if ! cp -R "${STAGE}" "/Applications/${APP_NAME}.app"; then
  echo "Installation failed; restoring the previous app."
  if [ -n "${BACKUP:-}" ] && [ -e "${BACKUP}" ]; then
    rm -rf "/Applications/${APP_NAME}.app"
    mv "${BACKUP}" "/Applications/${APP_NAME}.app"
  else
    rm -rf "/Applications/${APP_NAME}.app"
  fi
  exit 1
fi

echo "installed: /Applications/${APP_NAME}.app"
ls -d "/Applications/${APP_NAME}.app"
