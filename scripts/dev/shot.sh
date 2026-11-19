#!/bin/sh
# Capture one window by its id (from windows.swift) or the whole screen, downscaled so a review
# screenshot costs a few hundred tokens instead of thousands. Usage: shot.sh out.png [window-id] [max-px]
out=${1:?out.png}; id=$2; max=${3:-1000}
if [ -n "$id" ]; then screencapture -x -o -l"$id" "$out"; else screencapture -x "$out"; fi
sips -Z "$max" "$out" >/dev/null && echo "$out"
