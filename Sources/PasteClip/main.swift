import AppKit
import PasteClipCore

// Run as a helper that reads the text in one image, PasteClip quits once it has.
TextReadingProcess.runIfAsked()
TextRecognizer.readElsewhere = TextReadingProcess.read

// The bundle ID changed in 1.2.0 (GitHub account renamed); carry settings over from the old one.
if let old = UserDefaults(suiteName: "io.github.vinhquang3004.pasteclip")?.persistentDomain(forName: "io.github.vinhquang3004.pasteclip") {
    for (key, value) in old where UserDefaults.standard.object(forKey: key) == nil {
        UserDefaults.standard.set(value, forKey: key)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
