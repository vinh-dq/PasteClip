// type <text> — type text into the focused field as Unicode key events.
import AppKit
for ch in CommandLine.arguments[1].utf16 {
  for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!; var c = ch; e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); e.post(tap: .cghidEventTap) }
  usleep(15_000)
}
