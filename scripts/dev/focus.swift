// focus <pid> — print the app's focused window and element roles.
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
for a in [kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXFocusedUIElementAttribute] { var v: CFTypeRef?; let r = AXUIElementCopyAttributeValue(app, a as CFString, &v); var role: CFTypeRef?; if let v { AXUIElementCopyAttributeValue(v as! AXUIElement, kAXRoleAttribute as CFString, &role) }; print(a, r.rawValue, role as? String ?? "-") }
