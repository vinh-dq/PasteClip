# PasteClip

<img src="docs/icon.png" width="128" align="right" alt="PasteClip icon">

A free, open-source clipboard manager for macOS, written in Swift (AppKit + SwiftUI).

PasteClip keeps everything you copy (text, links, images, files, colours) and brings it back with
one shortcut: press **⇧⌘V**, pick a card, and it is pasted into the app you were using.

## Install

1. Download **`PasteClip-<version>.dmg`** from the [latest release](https://github.com/vinh-dq/PasteClip/releases/latest).
2. Open it and drag **PasteClip** into **Applications**.
3. Open PasteClip from Applications. It runs in the menu bar (there is no Dock icon).

Requires macOS 15 Sequoia or later, on Apple silicon or Intel.

### First launch

PasteClip is not notarized by Apple yet, so macOS blocks the first launch: open the app once
and close the warning, then go to **System Settings → Privacy & Security**, scroll down and
click **Open Anyway**.

Or, from Terminal: `xattr -dr com.apple.quarantine /Applications/PasteClip.app`

### Permissions

To paste straight into other apps, PasteClip needs **Accessibility** access. It asks the first
time you paste; turn it on in **System Settings → Privacy & Security → Accessibility**.
Without it, PasteClip still copies the clip, and you press ⌘V yourself.

### Update and uninstall

- **Update:** quit PasteClip from the menu bar, then replace it in Applications with the new version.
  Your history and pinboards are kept. Coming from 1.1.x or earlier, macOS asks for
  Accessibility again once (the app's identifier changed in 1.2.0); remove the old PasteClip
  entry in System Settings › Privacy & Security › Accessibility and turn on the new one.
- **Uninstall:** quit PasteClip, move it to the Trash, and delete
  `~/Library/Application Support/PasteClip` to remove your history.

## Features

- **History** of text, formatted text (RTF/HTML), links, colours, images and files, with the app each clip came from
- **Shelf**: ⇧⌘V slides in a panel of cards from the bottom (or top) of the screen
- **Search** across text, titles, file paths, source apps and text found in images (Vision), plus filters by type, app and date
- **Pinboards**: named, coloured collections for clips you want to keep
- **Paste stack**: copy several things, then paste them one by one in the same order
- **Copy text from the screen**: ⌥⇧⌘2, pick an area, and its text is copied. English, Vietnamese, Japanese and Chinese by default; more languages in Settings → Text Recognition. Read on your Mac with Vision (needs Screen Recording permission)
- **Translate**: ⌃Space translates the selected text (or the clipboard) in a small panel by the pointer. It picks the language for you: Vietnamese text into English, anything else into Vietnamese; 1–4 switch between Vietnamese, English, Japanese and Chinese. Return copies, ⌘Return pastes the translation back into the app. With the shelf open, ⌃Space translates the selected clips instead. Uses Google Translate or Bing Translator (free, no key) or Apple's on-device translation; Google Cloud, DeepL and Microsoft, and the AI models of OpenAI, Claude, Gemini, DeepSeek and Grok, work with your own API key (the model can be chosen)
- **Preview and edit**: Space for a large preview (Quick Look for images and files), give clips a title, edit text clips
- **Mark up images**: ⌘E on an image clip opens an editor with arrows, boxes, text, highlighter, numbers, pixelate and crop, each on one key. Esc saves the result as a new clip
- **Screenshots**: ⇧⌘1 captures an area as an image clip and copies it; a card in the corner then offers Edit (E), Float (P) and Translate (T)
- **Translate images**: the translation drawn where the text is, like a camera translator. ⇧⌘2 does it for an area of the screen, in place; ⌃⌥Space for images in the shelf; T on a floating image. The translated image is saved as a clip (can be turned off in Settings → Translation)
- **Float images**: ⌥⌘P keeps an image above every window. Scroll up or down to make it clearer or fainter, pinch to zoom, L to let clicks pass through
- **Direct paste** into the current app, or paste as plain text (needs Accessibility permission)
- **Privacy**: skips clips that password managers mark as private, and anything copied in apps you exclude
- **Settings**: paste into the front app or only copy, always plain text, history retention, translation (languages and their order, service, API keys), privacy options (screen sharing, link previews, passwords, temporary clips, ignored apps), shortcuts, sounds, launch at login
- **iCloud sync** of clips and pinboards (needs a signed build, see below)

See [docs/SPEC.md](docs/SPEC.md) for the full functional spec.

## Build from source

Only Command Line Tools are needed (Xcode is not required):

```sh
./scripts/bundle.sh          # creates build/PasteClip.app
open build/PasteClip.app
./scripts/test.sh            # run the tests
./scripts/release.sh         # universal build, packaged as dist/PasteClip-<version>.dmg and .zip
```

The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`. The app icon is
drawn by `swift scripts/make-icon.swift`, which writes `Resources/AppIcon.icns`.

Run `./scripts/make-signing-cert.sh` once before building. It creates a self-signed
"PasteClip Local Signing" certificate in your login keychain, and `bundle.sh` signs with it, so
every build has the same identity and macOS keeps the Accessibility permission. Without it the
app is signed ad hoc, macOS treats each rebuild as a new app, and asks for permission again
(`tccutil reset Accessibility io.github.vinh-dq.pasteclip` clears the stale entries).

## Global shortcuts

All eight can be changed or removed in Settings → Shortcuts. They come before the app in front's own
shortcuts, so change any that get in the way.

| Key | Action |
|---|---|
| ⇧⌘V | Open or close the shelf |
| ⌃⌘C | Start or stop the paste stack |
| ⌃⌘V | Paste the next clip from the stack |
| ⇧⌘1 | Screenshot of an area (or a window, with Space), saved as a clip and copied; a card in the corner offers Edit E, Float P, Translate T (Settings → General can instead always copy, edit or float) |
| ⇧⌘2 | Translate an area of the screen: the translation floats over it, where the text was |
| ⌥⇧⌘2 | Copy text from an area of the screen |
| ⌥⌘P | Float the latest image (with the shelf open: the selected images) |
| ⌃Space | Translate the selected text, or the clipboard |

⌃Space is also macOS's shortcut for switching input sources. If that one is turned on
(System Settings → Keyboard → Keyboard Shortcuts → Input Sources), macOS takes the key first:
turn it off there or pick another shortcut. Settings shows a warning next to any shortcut macOS uses.

## In a translation

| Key | Action |
|---|---|
| 1…9 / ← → | Translate into another language |
| ↑ ↓ | Switch to the previous / next translation service |
| Return / ⌘C | Copy the translation |
| ⌘Return | Paste it into the app you were using, replacing the selection |
| ⌘S | Save it to history |
| ⌘O | Show or hide the original |
| ⌘I | Show on Image: the image floated with the translation where its text was (when translating an image) |
| Esc / click outside | Close |

## In the image editor

| Key | Action |
|---|---|
| V R O L A T P H B N C | Select, rectangle, ellipse, line, arrow, text, pen, highlighter, pixelate, number, crop |
| 1…6 / [ ] / F | Colour / size / fill |
| ⇧ while drawing | Square, circle, 45° line |
| ⌫ / arrows | Delete / nudge the selected mark |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘+ ⌘− ⌘0 | Zoom in, out, fit |
| Esc / Return / ⌘S | Save as a new clip and close (in crop: Esc cancels, Return applies) |
| ⌘C / ⌥⌘P | Save, then copy / float it |
| ⌥Esc | Close without saving |

## On a floating image

These work with the pointer over the image, without clicking it first.

| Key | Action |
|---|---|
| Scroll up / down, ↑ ↓ | Clearer / fainter |
| Pinch, ⌘ scroll, ⌘+ ⌘−, − + in the readout | Zoom |
| ⌘0 / double-click | Actual size / fit |
| T / hold Space / ← → or 1…9 | Translate where the text is, or back to the original / peek at the original / into the previous, next or that language |
| G | Open the original image in Google Translate's Images page: it's opened (in the Google Translate tab already open, if there is one) and pasted there for you, and the floating image closes |
| E / ⌘C | Edit / copy |
| L | Lock: clicks pass through. The strip under it still shows when the pointer is over it, with the button to unlock it |
| Esc / ⌘W | Close |

## Shortcuts in the shelf

| Key | Action |
|---|---|
| ← → | Select a card |
| ⇧← ⇧→ / ⇧-click | Select several cards in a row |
| ⌘-click | Add a card to the selection, or take it out |
| ⌘A | Select every card (when the search is empty) |
| Return / double-click | Paste into the app you were using (hold ⇧ for plain text). With several cards selected, Return pastes them together, a line apart |
| ⌘R / double-click a card's label | Name the clip; the name shows on the card instead of the time (Return saves, Esc cancels, empty removes it) |
| ⌘1…⌘9 | Paste a card quickly (hold ⌘ to see the numbers) |
| Space / ⌘Y | Preview in a popup above the card; ← → move it to the next clip (Space works when the search field is empty) |
| ⌘E | Edit a text clip (⌘S saves, Esc cancels), or mark up an image (also a single copied image file) |
| ⌥⌘P | Float the selected images on the screen (configurable) |
| ⌘P | Pin / unpin |
| ⌘C | Copy without pasting (several cards: copied together) |
| ⌃Space (the translate shortcut) | Translate the selected clips: text, or the text in an image (read on the spot if it hasn't been yet) |
| ⌘I | Show only images (the Images button), or every type again |
| ⌃⌥Space | Float the selected images, translated where their text is (configurable) |
| ⌘⌫ | Delete (every selected card) |
| ⌘→ / ⌘← or Tab / ⇧Tab | Next / previous pinboard |
| ⌘N | New text item |
| ⌘F | Search |
| ⌘, | Settings |
| Esc / click outside | Clear a selection of several cards, then close |

Right-click a card to add it to a pinboard or the paste stack. Right-click a pinboard tab to edit or delete it.
Drag a pinboard tab onto another to reorder the pinboards, and drag cards within a pinboard to arrange them.

## iCloud sync

Sync uses CloudKit, which only works in an app signed by an Apple Developer team. Ad-hoc
builds hide the option. To build a copy that can sync:

1. In the Apple Developer site, register the App ID `io.github.vinh-dq.pasteclip` (or change
   `CFBundleIdentifier` in `Resources/Info.plist`) with iCloud (CloudKit) enabled, and create
   the container `iCloud.<bundle id>`.
2. Create a Developer ID provisioning profile for that App ID and download it.
3. Build and sign:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID \
   PROVISIONING_PROFILE=~/Downloads/PasteClip.provisionprofile ./scripts/bundle.sh
   ```

4. Turn on Settings → Sync on each Mac signed in to the same Apple Account.

Clip contents are stored in CloudKit encrypted fields. The paste stack is never synced.

## Architecture

```
Sources/
  PasteClipCore/          Library, no UI
    ClipItem.swift        Clip model, kind detection, hex colours
    Pinboard.swift        Pinboard model
    ClipStore.swift       Polls NSPasteboard.changeCount, de-duplicates, limits, stack, pinboards, JSON files
    ClipQuery.swift       Search and filters
    AppSettings.swift     Preferences and shortcut definitions (UserDefaults)
    TextRecognizer.swift  Text in images through Vision, one pass per writing system, merged line by line
    ImageMarkup.swift     Image marks, drawing and saving them; opacity steps of floating images
    ImageTranslation.swift  Lines into paragraphs, and translations drawn where the text was
  PasteClipSystem/        Library, OS integration
    HotKey.swift          Global hotkeys through Carbon RegisterEventHotKey
    Paster.swift          Sends ⌘V through CGEvent
    Entitlements.swift    Reads the app's signing entitlements
  PasteClipSync/          Library
    CloudSync.swift       iCloud sync through CKSyncEngine
  PasteClip/              The app
    main.swift            Entry point; runs as an accessory app (no Dock icon)
    AppDelegate.swift     Menu bar item, hotkeys, wiring
    ShelfPanel.swift      Non-activating NSPanel and keyboard handling
    ShelfView.swift       Toolbar, pinboard tabs, filters, cards
    CardsRow.swift        Row of cards: selection, clicks, drag, right-click menu
    ClipCard.swift        Card (content edge to edge, name label, details on hover), drag provider, colour swatch, pinboard editor
    LinkPreviews.swift    Page titles and images for links (LinkPresentation)
    PreviewPopup.swift    Preview popup above the selected card: title, editing, Quick Look
    StackPanel.swift      Floating paste stack list
    ScreenTextCapture.swift  Copy text from the screen: system area picker, Vision, confirmation toast
    SettingsWindow.swift  Settings window and shortcut recorder
    ImageEditor.swift     Image editor window: canvas, tools, undo, saving as a new clip
    FloatingImage.swift   Images floated above every window: opacity, zoom, lock, translation
    ImageTranslator.swift Reads, translates and redraws an image with the chosen service
    ViewState.swift       Stand-in for @State (see below)
Tests/
  PasteClipCoreTests/     Capture, rich text, de-dup, limits, pinboards and their order, stack, query, sync hooks
```

How it works: macOS has no notification for clipboard changes, so `ClipStore` checks
`changeCount` every 0.4 seconds. When the shelf is open, the panel is `nonactivatingPanel`, which keeps
the app you were using frontmost. When you choose a clip, PasteClip writes it to the pasteboard,
closes the shelf, waits until you let go of modifier keys, and then sends ⌘V to that app.

### Building without Xcode

With the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode, so
views keep local state in a `ViewState` object through `@StateObject` instead. Likewise,
`swift test` doesn't find the Swift Testing macro plugin from the Command Line Tools on its
own, so `scripts/test.sh` passes its path.

Run `PasteClip --open shelf|preview|general|text|privacy|shortcuts` (the binary inside the app, or from
`swift build --show-bin-path`) to jump straight to a screen while working on the UI.

## License

PasteClip is released under the [MIT License](LICENSE).
