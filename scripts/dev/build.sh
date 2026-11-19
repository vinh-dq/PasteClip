#!/bin/sh
# Compiles the GUI test helpers in this folder into .build/dev-tools/.
# They post synthetic events and read Accessibility, so the terminal needs Accessibility access.
set -e
cd "$(dirname "$0")"
OUT=../../.build/dev-tools
mkdir -p "$OUT"
for f in *.swift; do swiftc -O "$f" -o "$OUT/${f%.swift}"; done
# The demo stage as an app, so `open` brings it to the front like any other.
APP="$OUT/Stage.app/Contents"
mkdir -p "$APP/MacOS"
cp "$OUT/stage" "$APP/MacOS/Stage"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Stage</string>
<key>CFBundleIdentifier</key><string>io.github.cmdn-vinhdang.pasteclip.stage</string>
<key>CFBundleName</key><string>Stage</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
echo "Built into .build/dev-tools: $(ls "$OUT" | tr '\n' ' ')"
