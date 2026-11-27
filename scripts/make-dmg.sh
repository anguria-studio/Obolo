#!/bin/bash
#
# Packages build/Release/Obolo.app into dist/Obolo-<version>.dmg.
#
# Run scripts/build-release.sh first; this one only packages, so a failed build can
# never be quietly shipped as a stale DMG.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Release/Obolo.app"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/build-release.sh first" >&2
    exit 1
fi

# The single source of truth for the version is project.yml, so the DMG cannot drift
# from the bundle it contains.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from the app" >&2
    exit 1
fi

DIST="$ROOT/dist"
DMG="$DIST/Obolo-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DIST"
rm -f "$DMG"

# The staged folder is what the user sees when the DMG opens: the app, and the place
# to drag it to.
cp -R "$APP" "$STAGE/Obolo.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create"
hdiutil create \
    -volname "Obolo" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

echo
echo "Wrote $DMG"
