import AppKit
import PasteClipCore

// Run as a helper that reads the text in one image, PasteClip quits once it has.
TextReadingProcess.runIfAsked()
TextRecognizer.readElsewhere = TextReadingProcess.read

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// `--appearance dark` or `light` overrides the system's, for checking the look in both.
if let i = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.indices.contains(i + 1) {
    app.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
}
app.run()
