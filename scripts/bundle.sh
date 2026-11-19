#!/bin/sh
# Build release binary and wrap it in build/PasteClip.app
#
# Signing, in order of preference:
#   1. SIGN_IDENTITY, an Apple Developer ID, e.g. "Developer ID Application: Your Name (TEAMID)".
#   2. "PasteClip Local Signing" from scripts/make-signing-cert.sh, which keeps the
#      Accessibility permission across rebuilds.
#   3. Ad hoc, which works but loses the permission on every rebuild.
# --universal builds for both Apple silicon and Intel Macs (slower; used for releases).
set -e
cd "$(dirname "$0")/.."
ARCHS=""
[ "$1" = "--universal" ] && ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
APP=build/PasteClip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $ARCHS --show-bin-path)/PasteClip" "$APP/Contents/MacOS/PasteClip"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
elif security find-identity -p codesigning | grep -q "PasteClip Local Signing"; then
    # Same identity on every build, so macOS keeps the Accessibility permission.
    codesign --force --deep -s "PasteClip Local Signing" "$APP"
else
    echo "Note: signing ad hoc. macOS will ask for Accessibility again after each rebuild;"
    echo "      run ./scripts/make-signing-cert.sh once to avoid that."
    codesign --force --deep -s - "$APP"
fi
echo "Built $APP"
