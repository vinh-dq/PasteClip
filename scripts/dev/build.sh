#!/bin/sh
# Compiles the GUI test helpers in this folder into .build/dev-tools/.
# They post synthetic events and read Accessibility, so the terminal needs Accessibility access.
set -e
cd "$(dirname "$0")"
OUT=../../.build/dev-tools
mkdir -p "$OUT"
for f in *.swift; do swiftc -O "$f" -o "$OUT/${f%.swift}"; done
echo "Built into .build/dev-tools: $(ls "$OUT" | tr '\n' ' ')"
