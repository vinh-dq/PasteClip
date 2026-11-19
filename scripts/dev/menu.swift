// menu <pid> <title> — open the app's menu bar item and choose the item with that title, e.g. "Open PasteClip".
import AppKit
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func find(_ e: AXUIElement, _ title: String, _ d: Int = 0) -> AXUIElement? {
  if attr(e, kAXTitleAttribute) as? String == title { return e }
  guard d < 8 else { return nil }
  for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(k, title, d + 1) { return f } }; return nil }
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
guard let bar = attr(app, "AXExtrasMenuBar"), let item = ((attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []).first else { print("no status item"); exit(1) }
AXUIElementPerformAction(item, kAXPressAction as CFString)
usleep(400_000)
guard let mi = find(item, CommandLine.arguments[2]) else { print("no menu item"); exit(1) }
print(AXUIElementPerformAction(mi, kAXPressAction as CFString).rawValue)
