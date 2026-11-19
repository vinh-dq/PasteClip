#!/bin/sh
# Builds a universal, signed PasteClip.app and packages it for a GitHub release:
#   dist/PasteClip-<version>.dmg   disk image with a shortcut to Applications
#   dist/PasteClip-<version>.zip   the app, zipped
# Signing works as in scripts/bundle.sh.
set -e
cd "$(dirname "$0")/.."
VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
./scripts/bundle.sh --universal

rm -rf dist
mkdir -p dist/dmg
cp -R build/PasteClip.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "PasteClip $VERSION" -srcfolder dist/dmg -ov -format UDZO \
    "dist/PasteClip-$VERSION.dmg" >/dev/null
rm -rf dist/dmg
ditto -c -k --keepParent build/PasteClip.app "dist/PasteClip-$VERSION.zip"

cd dist
shasum -a 256 "PasteClip-$VERSION.dmg" "PasteClip-$VERSION.zip" > SHA256SUMS.txt
cat SHA256SUMS.txt
echo "Packaged dist/PasteClip-$VERSION.dmg and .zip"
