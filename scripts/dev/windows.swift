// windows <pid> — list the app's on-screen windows and their bounds.
import AppKit
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid { print(w[kCGWindowNumber as String]!, w[kCGWindowBounds as String]!) }
