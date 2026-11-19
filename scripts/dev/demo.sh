#!/bin/sh
# Opens PasteClip for a demo on a clean stage, on a copy of the sample history in $DEMO_STORE and
# settings of its own (defaults, English first), never your own. Usage: demo.sh [app args…]
# STAGE_LEVEL=normal puts the stage among ordinary windows (under the image editor), hiding other
# apps until the stage quits.
# NO_STAGE=1 skips the stage, for windows below its level captured on their own.
# EDITOR_TEXT (and EDITOR_FRAME, EDITOR_SELECT) add the stage's Notes window; APPEARANCE is light or dark.
# Example: DEMO_STORE=/tmp/demo-store ./scripts/dev/demo.sh --open shelf
cd "$(dirname "$0")/../.."
T=.build/dev-tools
pkill -x PasteClip; pkill -x Stage
RUN="${DEMO_STORE:?sample history folder}-run"
rm -rf "$RUN"; cp -R "$DEMO_STORE" "$RUN"
if [ -n "$NO_STAGE" ]; then
    :   # A window captured on its own (screencapture -l) needs no stage behind it.
elif [ -n "$EDITOR_TEXT" ]; then
    open -n "$T/Stage.app" --args --editor "$EDITOR_TEXT" --editor-frame "${EDITOR_FRAME:-405,120,900,300}" --select "${EDITOR_SELECT:-0,0}"
else
    if [ "$STAGE_LEVEL" = normal ]; then
        open -n "$T/Stage.app" --args --level normal --hide-others
    else
        open -n "$T/Stage.app"
    fi
fi
sleep 1.2
open -n build/PasteClip.app --args --store "$RUN" --settings pasteclip.demo --appearance "${APPEARANCE:-light}" "$@"
sleep "${WAIT:-3}"
