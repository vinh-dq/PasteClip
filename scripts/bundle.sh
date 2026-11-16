#!/bin/sh
# Build release binary and wrap it in build/PasteClip.app
#
# Signing, in order of preference:
#   1. SIGN_IDENTITY (Apple Developer), needed for iCloud sync, see below.
#   2. "PasteClip Local Signing" from scripts/make-signing-cert.sh, which keeps the
#      Accessibility permission across rebuilds.
#   3. Ad hoc, which works but loses the permission on every rebuild.
# For iCloud sync, sign with your Apple Developer team and a provisioning profile that
# includes the iCloud container iCloud.<bundle id>:
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID \
#   PROVISIONING_PROFILE=~/Downloads/PasteClip.provisionprofile ./scripts/bundle.sh
#
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
    : "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
    BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)
    sed -e "s/\$(TEAM_ID)/$TEAM_ID/g" -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" \
        Resources/PasteClip.entitlements > build/PasteClip.entitlements
    if [ -n "$PROVISIONING_PROFILE" ]; then
        cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    fi
    codesign --force --options runtime --timestamp \
        --entitlements build/PasteClip.entitlements -s "$SIGN_IDENTITY" "$APP"
elif security find-identity -p codesigning | grep -q "PasteClip Local Signing"; then
    # Same identity on every build, so macOS keeps the Accessibility permission.
    codesign --force --deep -s "PasteClip Local Signing" "$APP"
else
    echo "Note: signing ad hoc. macOS will ask for Accessibility again after each rebuild;"
    echo "      run ./scripts/make-signing-cert.sh once to avoid that."
    codesign --force --deep -s - "$APP"
fi
echo "Built $APP"
