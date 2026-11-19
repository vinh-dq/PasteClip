// drag <x1> <y1> <x2> <y2> — press, drag and release, top-left coordinates.
import AppKit
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let p1 = CGPoint(x: a[0], y: a[1]), p2 = CGPoint(x: a[2], y: a[3])
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p1, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(100_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p1, mouseButton: .left)!.post(tap: .cghidEventTap)
for i in 1...20 { let t = Double(i)/20; CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: p1.x + (p2.x-p1.x)*t, y: p1.y + (p2.y-p1.y)*t), mouseButton: .left)!.post(tap: .cghidEventTap); usleep(20_000) }
usleep(100_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p2, mouseButton: .left)!.post(tap: .cghidEventTap)
