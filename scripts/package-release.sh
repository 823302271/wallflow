#!/bin/sh

set -eu

RELEASE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$RELEASE_ROOT/scripts/package-app.sh"

RELEASE_APP="$RELEASE_ROOT/dist/Wallflow.app"
RELEASE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist")
RELEASE_NAME="Wallflow-$RELEASE_VERSION-macOS-arm64.dmg"
RELEASE_OUTPUT="$RELEASE_ROOT/dist/$RELEASE_NAME"
RELEASE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/wallflow-release.XXXXXX")
trap 'rm -rf "$RELEASE_STAGE"' EXIT HUP INT TERM

codesign --verify --deep --strict "$RELEASE_APP"
ditto "$RELEASE_APP" "$RELEASE_STAGE/Wallflow.app"
ln -s /Applications "$RELEASE_STAGE/Applications"
hdiutil create -volname "Wallflow $RELEASE_VERSION" -srcfolder "$RELEASE_STAGE" \
    -format UDZO -fs HFS+ -ov "$RELEASE_OUTPUT"
hdiutil verify "$RELEASE_OUTPUT"
(
    cd "$RELEASE_ROOT/dist"
    shasum -a 256 "$RELEASE_NAME" > "$RELEASE_NAME.sha256"
)
echo "$RELEASE_OUTPUT"
echo "$RELEASE_OUTPUT.sha256"
