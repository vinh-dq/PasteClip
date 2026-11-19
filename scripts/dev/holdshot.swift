// holdshot <out.png> — hold ⌘ and take a screenshot (for small print shown while a key is held).
import AppKit
let e = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true)!; e.flags = .maskCommand; e.post(tap: .cghidEventTap)
usleep(700_000)
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); task.arguments = ["-x", "-C", CommandLine.arguments[1]]; try! task.run(); task.waitUntilExit()
let u = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)!; u.flags = []; u.post(tap: .cghidEventTap)
usleep(200_000)
