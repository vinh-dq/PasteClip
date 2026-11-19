// click <x> <y> — left click at a point, top-left screen coordinates.
import AppKit
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(50000) }
