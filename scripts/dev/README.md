# GUI test helpers

Small command-line tools for checking PasteClip's UI by hand or from an agent: click, hover, drag,
press keys, open the menu bar menu, list windows and take screenshots.

```sh
./scripts/dev/build.sh                     # builds into .build/dev-tools/
T=.build/dev-tools
PID=$(pgrep -x PasteClip)
$T/menu $PID "Open PasteClip"              # open the shelf
$T/key 124                                 # → next card
./scripts/dev/shot.sh $TMPDIR/shelf.png <window-id>   # one window, downscaled to 1000 px
$T/key 53                                  # Esc
```

Coordinates are in points from the top-left of the main screen. Keep runs short, and never use
these to click macOS permission prompts.

Run a build on its own history and in either look without touching your own settings:

```sh
open -n build/PasteClip.app --args --store $TMPDIR/pc-test/store --appearance dark
```
