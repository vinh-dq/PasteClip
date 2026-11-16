# PasteClip

<img src="docs/icon.png" width="128" align="right" alt="PasteClip icon">

A free, open-source clipboard manager for macOS, written in Swift (AppKit + SwiftUI).

PasteClip keeps everything you copy (text, links, images, files, colours) and brings it back with
one shortcut: press **⇧⌘V**, pick a card, and it is pasted into the app you were using.

## Install

1. Download **`PasteClip-<version>.dmg`** from the [latest release](https://github.com/vinh-dq/PasteClip/releases/latest).
2. Open it and drag **PasteClip** into **Applications**.
3. Open PasteClip from Applications. It runs in the menu bar (there is no Dock icon).

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

### First launch

PasteClip is not notarized by Apple yet, so macOS blocks the first launch:

- **macOS 15 and later:** open the app once and close the warning, then go to
  **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
- **macOS 14:** right-click PasteClip in Applications, choose **Open**, then **Open** again.

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
- **Preview and edit**: Space for a large preview (Quick Look for images and files), give clips a title, edit text clips
- **Direct paste** into the current app, or paste as plain text (needs Accessibility permission)
- **Privacy**: skips clips that password managers mark as private, and anything copied in apps you exclude
- **Settings**: paste into the front app or only copy, always plain text, history retention, privacy options (screen sharing, link previews, passwords, temporary clips, ignored apps), shortcuts, sounds, launch at login
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

All three can be changed or removed in Settings → Shortcuts.

| Key | Action |
|---|---|
| ⇧⌘V | Open or close the shelf |
| ⌃⌘C | Start or stop the paste stack |
| ⌃⌘V | Paste the next clip from the stack |

## Shortcuts in the shelf

| Key | Action |
|---|---|
| ← → | Select a card |
| Return / double-click | Paste into the app you were using (hold ⇧ for plain text) |
| Double-click a card's title | Rename the clip (Return saves, Esc cancels, empty resets) |
| ⌘1…⌘9 | Paste a card quickly |
| Space / ⌘Y | Preview in a popup above the card; ← → move it to the next clip (Space works when the search field is empty) |
| ⌘E | Edit a text clip (⌘S saves, Esc cancels) |
| ⌘P | Pin / unpin |
| ⌘C | Copy without pasting |
| ⌘⌫ | Delete |
| ⌘→ / ⌘← or Tab / ⇧Tab | Next / previous pinboard |
| ⌘N | New text item |
| ⌘F | Search |
| ⌘, | Settings |
| Esc / click outside | Close |

Right-click a card to add it to a pinboard or the paste stack. Right-click a pinboard tab to edit or delete it.

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
    TextRecognizer.swift  Text in images through Vision
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
    ClipCard.swift        Card (pinboard or app colour header), drag provider, colour swatch, pinboard editor
    LinkPreviews.swift    Page titles and images for links (LinkPresentation)
    PreviewPopup.swift    Preview popup above the selected card: title, editing, Quick Look
    StackPanel.swift      Floating paste stack list
    SettingsWindow.swift  Settings window and shortcut recorder
    ViewState.swift       Stand-in for @State (see below)
Tests/
  PasteClipCoreTests/     Capture, rich text, de-dup, limits, pinboards, stack, query, sync hooks
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

Run `PasteClip --open shelf|preview|general|privacy|shortcuts` (the binary inside the app, or from
`swift build --show-bin-path`) to jump straight to a screen while working on the UI.

## License

PasteClip is released under the [MIT License](LICENSE).
