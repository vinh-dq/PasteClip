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

## Recording the README demos

The pictures in `docs/media` come from the real app on sample content, never your own clipboard.

```sh
# A clean set: a soft wallpaper over every window and the Dock, PasteClip on a copy of a sample
# history and settings of its own (defaults, English first). Options in demo.sh.
DEMO_STORE=/path/to/sample-store ./scripts/dev/demo.sh --open offer
$T/front Stage PasteClip || exit 1         # stop before sending keys to another app
screencapture -v -V 15 -R x,y,w,h out.mov  # record an area
$T/gif out.mov grid.png 1 300              # check it: frames in a grid on one image
$T/gif out.mov docs/media/demo.gif 10 760 0 - 1.2  # then the GIF (fps, width, start, end, speed)
```

Other ways in for a demo: `--open shelf|preview|editor|float|offer|stack`, `--translate "text"`,
`--translate-image file.png` and `--read-text-from file.png`. Type into fields with `key` and real
key codes: `type` sends every character as the A key, which the shelf's search reads as "a".
