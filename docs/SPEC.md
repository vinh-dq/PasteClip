# PasteClip — Functional Spec

PasteClip is an open-source clipboard manager for macOS 15+. It lives in the menu bar,
keeps a history of what you copy, and opens a floating shelf where you can find a clip
and paste it into the app you were using.

It is written in Swift using only public Apple APIs.

Status: ✅ done · ⚠️ done, needs a signed build to run · 🔜 planned

## 1. App shell

| # | Requirement | Status |
|---|---|---|
| 1.1 | Runs as an accessory app (`LSUIElement`): no Dock icon, no main window | ✅ |
| 1.2 | Menu bar item: Open PasteClip, Start/Stop Paste Stack, Pause/Resume Capturing, Enable Direct Paste… (only when needed), Settings…, Clear History…, Quit. Items show their global shortcuts | ✅ |
| 1.3 | Optional sounds when a clip is captured and when one is pasted (system sounds) | ✅ |

## 2. Capture

| # | Requirement | Status |
|---|---|---|
| 2.1 | Polls `NSPasteboard.general.changeCount` every 0.4 s (macOS has no change notification) | ✅ |
| 2.2 | Recognises five kinds, checked in this order: **file** (file URLs), **color** (`#RGB`, `#RRGGBB`, `#RRGGBBAA`), **link** (a single `http(s)` URL with a host), **text**, **image** (PNG/TIFF) | ✅ |
| 2.3 | Keeps the formatted version of text (RTF, else HTML) next to the plain text | ✅ |
| 2.4 | Finds text in image clips with Vision, in the background, so images are searchable (can be turned off; uses the languages from 9.8) | ✅ |
| 2.5 | Records the source app (bundle ID and name) from the frontmost app | ✅ |
| 2.6 | Skips clips marked `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` | ✅ |
| 2.7 | Skips copies made while an excluded app is frontmost (default: Keychain Access, Passwords) | ✅ |
| 2.8 | Skips anything PasteClip itself puts on the pasteboard, and does nothing while paused | ✅ |

## 3. History and storage

| # | Requirement | Status |
|---|---|---|
| 3.1 | Newest first. Copying something already in history moves it to the top and keeps its id, title, pin and pinboard (images are not de-duplicated) | ✅ |
| 3.2 | Keeps up to N unkept clips (100–5000, default 500) and optionally deletes clips older than 1–365 days. Pinned clips and clips on a pinboard are never removed this way | ✅ |
| 3.3 | Stored in `~/Library/Application Support/PasteClip/`: `history.json`, `pinboards.json`, `images/*.png`, `rich/*.rtf|html` | ✅ |
| 3.4 | Deleting a clip, trimming or clearing history also removes its files | ✅ |
| 3.5 | Clear History keeps pinned and pinboard clips and asks first | ✅ |

## 4. Pinboards

| # | Requirement | Status |
|---|---|---|
| 4.1 | Create pinboards with a name and one of eight colours; rename, recolour or delete them from the tab's right-click menu | ✅ |
| 4.2 | A clip belongs to at most one pinboard. Add or remove it from the card's right-click menu | ✅ |
| 4.3 | Shelf tabs: History, then each pinboard. Tab / ⇧Tab move between them | ✅ |
| 4.4 | Deleting a pinboard keeps its clips in history | ✅ |
| 4.5 | Reorder pinboards by dragging a tab onto another tab; new pinboards go at the end. Arrange clips within a pinboard by dragging a card onto another (a bar shows where it lands); a clip added to a pinboard goes to the front. History stays newest first. Both orders are saved and synced | ✅ |

## 5. Paste stack

| # | Requirement | Status |
|---|---|---|
| 5.1 | ⌃⌘C (configurable) or the menu turns stack mode on or off | ✅ |
| 5.2 | While on, every new copy joins the end of the stack. Cards can also be added from their right-click menu | ✅ |
| 5.3 | ⌃⌘V (configurable) pastes the next clip in the stack into the front app and removes it from the stack. Beeps when the stack is empty | ✅ |
| 5.4 | A small floating list in the top-right corner shows the stack, highlights what comes next, lets you remove items, and has Done | ✅ |
| 5.5 | Turning stack mode off empties the stack. The stack is never synced | ✅ |

## 6. Shelf (floating panel)

| # | Requirement | Status |
|---|---|---|
| 6.1 | ⇧⌘V (configurable) toggles the shelf from anywhere (Carbon `RegisterEventHotKey`, no permission needed) | ✅ |
| 6.2 | Non-activating `NSPanel` that slides in from the bottom or top edge (setting) of the screen under the mouse, on every Space and over full-screen apps. At the bottom it sits on the screen edge, over the Dock; at the top, below the menu bar. The previous app stays frontmost | ✅ |
| 6.3 | Cards show title or kind, relative time, source app icon, pin / pinboard / stack markers, a preview (text, link with page title and image, image with pixel size, file icons, colour swatch), a summary and a quick-paste badge. Clips on a pinboard have a header in the pinboard's bright colour; other clips use a dark tone of the dominant hue of the source app's icon, so saved clips stand out. Copied files show a Quick Look thumbnail (images, PDFs, documents) with the file name, falling back to icons | ✅ |
| 6.3c | Look: on macOS 26+ the shelf, tabs, search, buttons and paste stack use Liquid Glass (`NSGlassEffectView`, `glassEffect`); older systems use a blurred material. The shelf floats 10 pt from the screen edges with rounded corners | ✅ |
| 6.3a | Top bar: filter menu on the left; search, History and pinboard tabs and + in the middle; a … menu on the right (New Text Item ⌘N, Start/Stop Paste Stack, Pause, Settings ⌘,, Quit) | ✅ |
| 6.3b | New Text Item: write a text clip with an optional title; it lands in the selected pinboard | ✅ |
| 6.4 | Search matches every word, ignoring case and accents, across title, text, file paths, text found in images and source app | ✅ |
| 6.5 | Filters: type (All, Pinned, Text, Links, Images, Files, Colors), source app, date (Today, 7 days, 30 days), with Reset | ✅ |
| 6.6 | Closes on Esc, a click outside, or after pasting (the preview popup closes with it) | ✅ |
| 6.7 | Keyboard: ←/→ select, ⌘→/⌘← next/previous pinboard, Return paste, ⇧Return paste as plain text, ⌘1–⌘9 quick paste, ⌘N new text item, Space or ⌘Y preview, ⌘E edit, ⌘P pin, ⌘C copy only, the translate shortcut (⌃Space) translates the selected clips, ⌘⌫ delete, Tab next tab, ⌘F search, ⌘, settings | ✅ |
| 6.7c | Several cards: ⇧←/⇧→ and ⇧-click select a range from the last card picked, ⌘-click adds or removes one, ⌘A selects every card (empty search). Each selected card has the ring, and a bar under the row says how many and what keys do. Return (or Paste N Clips in the right-click menu) pastes them together in the row's order: text as one text a line apart (without formatting), files together, a mix with images one pasteboard item per clip; plain text turns images into their text and files into paths. ⌘C copies them the same way, ⌘⌫ or Delete N Clips deletes them all, Add to Paste Stack adds them all. Esc clears the selection; a new search, filter or tab does too | ✅ |
| 6.7a | Mouse: a click selects the card immediately; a double-click pastes it into the front app (holding the plain-text modifier, ⇧ by default, pastes plain text). Clicks never scroll the row; keyboard moves do. Dragging a card onto a pinboard tab files it there, onto History takes it off its pinboard, and into another app drops its content | ✅ |
| 6.7b | Double-clicking a card's header edits its title in place: Return or clicking elsewhere saves, Esc cancels, an empty title goes back to the clip kind. Double-clicking the rest of the card pastes. Also in the right-click menu as Rename… | ✅ |
| 6.8 | Right-click menu: Paste, Paste as Plain Text, Copy, Preview, Edit…, Rename…, Translate ▸ (automatic or into each target language), Pin, Pinboard ▸, Add to / Remove from Paste Stack, Delete | ✅ |

## 7. Preview and editing

| # | Requirement | Status |
|---|---|---|
| 7.1 | Space (or ⌘Y) opens a popup above the selected card, with an arrow pointing at it; it opens below the card when there's no room above. ←/→ move to the next clip and the popup follows. Space or Esc closes it | ✅ |
| 7.2 | Header: close button, editable title, and actions — Copy, Open in Browser (links), Show in Finder (files), Edit (text, links, colours), Paste | ✅ |
| 7.3 | Body: formatted text with its formatting; plain text selectable; images on a checkerboard; files through Quick Look (`QLPreviewView`); links with page title and image; colours as a swatch | ✅ |
| 7.4 | Footer: characters · words · lines (text), pixel size (images), path or file count (files); source app and date; Copy Text in Image when Vision found text | ✅ |
| 7.5 | Edit text, link and colour clips in place (Edit or ⌘E, ⌘S to save, Esc to cancel). The popup takes keyboard focus while editing. Saving drops the formatting and re-detects the kind | ✅ |
| 7.6 | Clicking the title lets you name the clip; Return or leaving the field saves it | ✅ |

## 8. Paste

| # | Requirement | Status |
|---|---|---|
| 8.1 | Writes the clip to the pasteboard (plain text plus RTF/HTML when there is formatting), hides the shelf, then posts ⌘V with `CGEvent` once the user has let go of modifier keys | ✅ |
| 8.2 | Paste as plain text: text without formatting, file paths for files, recognised text for images | ✅ |
| 8.3 | Needs Accessibility permission. Without it, PasteClip still copies the clip so the user can press ⌘V. Asks on first launch and from the menu | ✅ |

## 9. Settings window

Sidebar on the left (General, Text Recognition, Translation, Privacy, Shortcuts, Show Data in Finder), grouped form on the right.

| # | Requirement | Status |
|---|---|---|
| 9.1 | General: open at login (`SMAppService`), iCloud sync with status, sound effects | ✅ |
| 9.2 | General → When you choose a clip: paste into the front app, or only copy to the clipboard; always paste as plain text | ✅ |
| 9.3 | General → Keep history for: slider Day / Week / Month / Year / Forever, maximum clip count, Erase History… | ✅ |
| 9.4 | General → Shelf: bottom or top of the screen | ✅ |
| 9.5 | Privacy: hide the shelf and stack from screen sharing (`NSWindow.sharingType`), load link previews, skip passwords (`ConcealedType`), skip temporary clips (`TransientType`, `AutoGeneratedType`) | ✅ |
| 9.6 | Privacy → Ignore these apps: list with icons, + opens an app picker, − removes the selected app | ✅ |
| 9.7 | Shortcuts: record or clear the five global shortcuts (a warning shows next to one macOS has turned on for itself, read from `com.apple.symbolichotkeys`) and the next / previous pinboard keys (⌘→ / ⌘← by default); choose the quick-paste modifier (⌘, ⌥ or ⌃ + 1…9) and the plain-text modifier (⇧ or ⌥ + Return); Reset Shortcuts to Defaults… | ✅ |
| 9.8 | Text Recognition: copy-text shortcut, Screen Recording status with a link to System Settings, keep line breaks, find text in copied images, languages (English, Vietnamese, Japanese, Chinese Simplified on by default and listed first; at least one stays on; Reset to Defaults) | ✅ |
| 9.9 | Translation: shortcut; translate the selected text; translate text copied from the screen; save translations to history; target languages in order (Vietnamese, English, Japanese, Chinese by default; move up / down, remove, add, Reset to Defaults); service: one list of Google Translate and Bing Translator (Free), Apple (Offline, with a Languages… button) and Google Cloud, DeepL and Microsoft (API key); then an AI section with OpenAI, Claude, Gemini, DeepSeek and Grok (AI + API key, showing the model in use). A service without a key opens Add Key… when picked: a sheet on the Settings window (it stays open, keeping what was typed, while you switch apps or click elsewhere) with the key (show / hide) (region for Microsoft; model for AI services, empty for the default, with a menu of models: the default, then the list the provider gives for the key (fetched after the key is saved, and again with Update List from …; built-in suggestions until then), so new models appear without a PasteClip update), a link to get one, and Test & Save, which translates a sample and only then saves the key and selects the service; Edit Key… shows a saved key as dots without reading it into the field, and can replace or remove it, or test a new model with the saved key. Keys are kept together in one login-keychain item ("PasteClip Translation" / "keys"). A keychain item is tied to the build that may read it unless the app is signed by an Apple developer team, so after an update macOS asks once before reading it (Always Allow ends that until the next update); to keep that to one ask, the item is read only when a key is needed, once per launch, never when opening the app or Settings or using a service without a key. Which services have a key is kept in UserDefaults without the keys. Keys kept earlier in `api-keys.json` or in one item per service move into the shared item, and the old copies are removed | ✅ |

## 10. iCloud sync

| # | Requirement | Status |
|---|---|---|
| 10.1 | Syncs clips (with images and formatting as assets) and pinboards through `CKSyncEngine` in a custom zone of the private database | ⚠️ |
| 10.2 | Clip text, titles, file paths, recognised text, source app names and pinboard names use CloudKit encrypted fields | ⚠️ |
| 10.3 | Uploads everything on first run, then only changes. Remote changes are applied without being sent back | ⚠️ |
| 10.4 | Conflicts: the server version wins. A deleted zone is recreated from local data. Signing out keeps local history | ⚠️ |
| 10.5 | Turned off automatically when the app lacks the CloudKit entitlement (ad-hoc builds) | ✅ |

⚠️ Sync compiles and its store side is unit-tested, but it can only run in a build signed with an
Apple Developer team, an iCloud container and a provisioning profile (see README → iCloud sync).
It has not been run against CloudKit yet.

## 11. Text from the screen

| # | Requirement | Status |
|---|---|---|
| 11.1 | ⇧⌘2 (configurable) or the menu's Copy Text from Screen hides the shelf and opens the system's area picker (`screencapture -i`: drag an area, Space for a window, Esc cancels) | ✅ |
| 11.2 | Without Screen Recording permission, the first time asks macOS for it; later shows how to turn it on | ✅ |
| 11.3 | Vision (accurate, no language correction) runs one pass per writing system among the chosen languages, side by side; each line comes from the pass that reads its writing, and Latin words in mixed lines get their accents back from the Latin pass | ✅ |
| 11.4 | Areas from screens that aren't Retina (under 100 dpi) are read at twice the size | ✅ |
| 11.5 | The text becomes a clip from "Screen Text" and is put on the clipboard; a toast shows the line count and the first two lines, or "No text found" | ✅ |
| 11.6 | Vision runs once on a blank image at launch and after a language change, so macOS prepares its models before the first capture | ✅ |

## 12. Translation

| # | Requirement | Status |
|---|---|---|
| 12.1 | ⌃Space (configurable) or the menu's Translate Selection or Clipboard sends ⌘C to the front app and reads the selection; the clipboard is put back as it was and the borrowed copy isn't saved. With nothing selected, no Accessibility permission, or the setting off, it translates the clipboard (an image's recognised text if it holds an image). A clipboard marked as a password isn't translated | ✅ |
| 12.2 | With the shelf open, the translate shortcut closes it and translates the selected clip, or every selected clip a line apart (text, or the text found in an image), instead of the selection in the front app; the right-click menu's Translate ▸ does one clip, into a chosen language; Copy Text from Screen can show a translation too (setting) | ✅ |
| 12.3 | Target language: the first in the user's order that the text isn't in, using `NLLanguageRecognizer` (only when it's at least 60% sure; Apple's service also goes by the likeliest language when unsure). If the service finds the text was already in the target, it moves on to the next one, unless the user picked that language, which shows a note to pick another. Try Again appears only for errors another go could fix (network, service limits), not for a missing key or a language that can't be translated | ✅ |
| 12.4 | Panel by the pointer (below it, or above when there's no room), non-activating so the front app keeps focus; on every Space, hidden from screen sharing with the shelf setting. It can be dragged by its grip or any empty space, and then stays there, growing downwards. Numbered language chips, the translation, the original below it (shown by default; ⌘O or the button hides it, and the choice is remembered), each as tall as its text up to a limit (240 / 130 pt) and scrolling past it, so short text gives a small panel, and a footer with "source → target · service" (a menu to switch service), Save, Copy and Paste | ✅ |
| 12.5 | Keys: 1–9 and ←/→ pick the language, ↑/↓ switch to the previous / next usable service (remembered as the chosen service), Return or ⌘C copies and closes, ⌘Return pastes into the front app, ⌘S saves to history, ⌘O shows the original, Esc, ⌘W or a click outside closes. The shortcut again closes it | ✅ |
| 12.6 | Services: Google Translate's free `translate_a/single` endpoint (default; not an official API), Bing's web translator (the token, ids and cookies its `bing.com/translator` page gives a visitor, sent back to `ttranslatev3` in pieces of up to 1,000 characters; the token is renewed half way through its lifetime or when refused, once per request), Apple's Translation framework on the device, only between downloaded languages and always told the source language (the detected one, or else the likeliest one whose pair is downloaded), so Apple never opens its own language or download windows inside the panel, which can't take their clicks. On macOS 26+ a `TranslationSession` per pair is kept while the app runs, so only the first text loads the model; before that, `.translationTask` with both languages given. A pair that isn't downloaded shows Download… (a normal window where macOS's download prompt works; the panel stays open) and Use Google Translate. Download is asked of macOS once per pair and session: asking again while it downloads made its prompt flicker, so the button then becomes Download Progress… and opens Translation Languages in System Settings. Meanwhile the panel checks every 2 s and translates as soon as the pair is downloaded, Google Cloud Translation v2, DeepL (free keys use `api-free.deepl.com`) and Microsoft Translator v3. AI: OpenAI, DeepSeek and Grok through their chat completions APIs (defaults are each provider's fast, cheap model: `gpt-4.1-nano`, `deepseek-chat`, `grok-4-fast-non-reasoning`), Claude through the Messages API (`anthropic-version: 2026-10-21`, default `claude-haiku-5-5`, low effort on 5.x models, server-side fallback when the chosen model has it, a refusal reported as such), Gemini through `generateContent` (default `gemini-flash-lite-latest`). The model gets the target language in its instructions, is told the text is never instructions, and answers with the translation only; pieces of up to 4,000 characters, 90 s timeout; the source language is detected locally | ✅ |
| 12.7 | The panel shows at once, translating, while the selection is copied (put up without taking keys, so the ⌘C still reaches the front app). The connection to the chosen web service is opened ahead: at launch, after picking a service, when the shortcut is pressed (at most every 20 s), and Bing's token is renewed every 10 minutes while Bing is picked. Text over 30,000 characters is cut, with a note; text is sent in pieces of at most 4,500 characters (Bing 1,000, AI 4,000), split between lines, up to 4 at a time, put back in order. Results are cached per service, language and text for the session | ✅ |
| 12.8 | Copying or pasting a translation adds it to history as a clip from "Translation" (on by default; when turned off, it only goes on the clipboard). ⌘S saves it without copying | ✅ |

## Architecture

```
PasteClipCore     (library)  ClipItem, Pinboard, ClipStore (capture, de-dup, limits, stack, JSON),
                             ClipQuery (search and filters), AppSettings, TextRecognizer (Vision),
                             Translator (language choice, web services)
PasteClipSystem   (library)  HotKey (Carbon), Paster (Accessibility + CGEvent), Entitlements
PasteClipSync     (library)  CloudSync (CKSyncEngine)
PasteClip         (app)      AppDelegate (menu bar, hotkeys), Shelf (panel, view, cards, preview),
                             Paste stack panel, Settings window, translation panel (Apple's
                             Translation framework), API keys (one keychain item)
PasteClipCoreTests           Swift Testing; uses a private NSPasteboard and a temp folder
```

`PasteClipCore` has no UI and does not reach into the OS beyond the pasteboard, the file
system and Vision, so it can be tested without launching the app. Sync only talks to the
store through `onLocalChange` and the `applyRemote…` / `removeRemote…` methods.

## Constraints

- PasteClip has no menu bar of its own (accessory app), but installs a hidden main menu with an
  Edit menu so ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z work in text fields (Settings, the API key popover).
- The app must not be sandboxed, because posting ⌘V into another app is not allowed from
  the App Sandbox. It is distributed directly, not through the Mac App Store.
- Builds with Command Line Tools only (`swift build`); Xcode is not required. Because the
  Command Line Tools don't ship SwiftUI's macro plugin, views use `ViewState` through
  `@StateObject` instead of `@State`.
