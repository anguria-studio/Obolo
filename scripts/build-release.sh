#!/bin/bash
#
# Builds a Release Obolo.app into build/Release/.
#
# The project file is generated, so this regenerates it first: a source file added
# since the last `xcodegen generate` would otherwise be silently left out of the
# build, which is a bug you find after shipping.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DERIVED="$ROOT/build/Release"
OUTPUT="$DERIVED/Obolo.app"

command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found — brew install xcodegen" >&2
    exit 1
}

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild (Release)"
xcodebuild \
    -project Obolo.xcodeproj \
    -scheme Obolo \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build

BUILT="$DERIVED/Build/Products/Release/Obolo.app"
if [ ! -d "$BUILT" ]; then
    echo "error: build succeeded but $BUILT is missing" >&2
    exit 1
fi

# Copied up out of DerivedData so make-dmg.sh, and anyone reading this, has one
# predictable path to point at.
rm -rf "$OUTPUT"
cp -R "$BUILT" "$OUTPUT"

echo
echo "Built $OUTPUT"
