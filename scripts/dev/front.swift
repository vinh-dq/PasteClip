// front [name…] — prints the frontmost app; with names, exits 1 unless it's one of them, so a
// demo script can stop before sending keys to the wrong app.
import AppKit
let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
print(name)
let allowed = CommandLine.arguments.dropFirst()
exit(allowed.isEmpty || allowed.contains(name) ? 0 : 1)
