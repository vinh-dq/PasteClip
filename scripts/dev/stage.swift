// stage [--editor <text>] [--editor-frame x,y,w,h] [--select start,length] [--level normal] — a clean set for recording demos: a soft
// wallpaper over the whole screen (hiding every other window and the desktop), and optionally a
// plain "Notes" window holding <text> to select, translate or paste into. Coordinates in points
// from the top left. Built as .build/dev-tools/Stage.app too (`open -n` it to come to the front);
// quit with `pkill -x Stage`.
import AppKit

let args = CommandLine.arguments
func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }

final class Wallpaper: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colours = dark
            ? [NSColor(srgbRed: 0.16, green: 0.13, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.32, green: 0.16, blue: 0.30, alpha: 1)]
            : [NSColor(srgbRed: 0.74, green: 0.70, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.97, green: 0.76, blue: 0.86, alpha: 1)]
        NSGradient(colors: colours)?.draw(in: bounds, angle: -35)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!

let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
backdrop.contentView = Wallpaper()
// Above every app's ordinary windows, whichever is active (so none shows through), and
// below PasteClip's floating images (.floating) and panels (.statusBar).
// With --level normal it sits with other windows instead, under PasteClip windows that open after it
// at that level (the image editor).
let stageLevel = value("--level") == "normal" ? NSWindow.Level.normal : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
backdrop.level = stageLevel
backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary]
backdrop.orderFrontRegardless()

// The Dock, covered by the same wallpaper just above its level: PasteClip's panels (status bar
// level) still come over it.
let dockHeight = screen.visibleFrame.minY - screen.frame.minY
if dockHeight > 0 {
    let cover = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: dockHeight + 8),
                         styleMask: .borderless, backing: .buffered, defer: false)
    let view = Wallpaper(frame: screen.frame)
    view.frame.origin = .zero
    cover.contentView = NSView()
    cover.contentView?.addSubview(view)
    cover.level = NSWindow.Level(rawValue: NSWindow.Level.dock.rawValue + 1)
    cover.collectionBehavior = [.canJoinAllSpaces, .stationary]
    cover.ignoresMouseEvents = true
    cover.orderFrontRegardless()
}

var editor: NSWindow?
if let text = value("--editor") {
    let parts = (value("--editor-frame") ?? "290,170,700,300").split(separator: ",").compactMap { Double($0) }
    let top = screen.frame.maxY - parts[1] - parts[3]
    let window = NSWindow(contentRect: NSRect(x: parts[0], y: top, width: parts[2], height: parts[3]),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Notes"
    let scroll = NSTextView.scrollableTextView()
    let view = scroll.documentView as! NSTextView
    view.font = .systemFont(ofSize: 17)
    view.textContainerInset = NSSize(width: 18, height: 16)
    view.string = text.replacingOccurrences(of: "\\n", with: "\n")
    view.isRichText = false
    window.contentView = scroll
    window.level = stageLevel
    window.makeKeyAndOrderFront(nil)
    // Placed again once shown: macOS moves a new window to where it thinks best.
    window.setFrame(NSRect(x: parts[0], y: top, width: parts[2], height: parts[3]), display: true)
    window.makeFirstResponder(view)
    // --select start,length shows part of the text selected, as before a translation.
    if let range = value("--select")?.split(separator: ",").compactMap({ Int($0) }), range.count == 2 {
        view.setSelectedRange(NSRange(location: range[0], length: range[1]))
    }
    editor = window
}
app.activate(ignoringOtherApps: true)
// --hide-others (with --level normal): other apps are hidden, as ⌥⌘H does, so none shows between
// the stage and a PasteClip window at the same level; they come back when the stage quits.
if args.contains("--hide-others") {
    app.hideOtherApplications(nil)
    signal(SIGTERM, SIG_IGN)
    let quit = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    quit.setEventHandler {
        app.unhideAllApplications(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
    quit.resume()
    withExtendedLifetime(quit) { app.run() }
} else {
    app.run()
}
