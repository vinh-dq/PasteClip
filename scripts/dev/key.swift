// key <keycode> [cmd,shift,ctrl,opt] — press and release one key, with modifiers if given
// (124 →, 123 ←, 53 Esc, 49 Space, 36 Return, 48 Tab, 14 E).
import AppKit
let code = CGKeyCode(CommandLine.arguments[1])!
var flags: CGEventFlags = []
for m in (CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "").split(separator: ",") {
  switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "ctrl": flags.insert(.maskControl); case "opt": flags.insert(.maskAlternate); default: break }
}
for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!; e.flags = flags; e.post(tap: .cghidEventTap); usleep(30_000) }
usleep(300_000)
