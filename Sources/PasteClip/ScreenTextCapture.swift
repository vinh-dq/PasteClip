import AppKit
import PasteClipCore
import SwiftUI

/// Copies the text in a part of the screen. The area is picked with the system's own selection
/// (as with ⇧⌘4: drag an area, Space for a window, Esc to cancel), then read with Vision.
final class ScreenTextCapture {
    private let store: ClipStore
    private let settings: AppSettings
    private let toast = Toast()
    private var running = false
    /// Called after the text is on the clipboard.
    var onCopied: (() -> Void)?
    /// Shows a translation of the text, when that's turned on.
    var onTranslate: ((String) -> Void)?

    init(store: ClipStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func start() {
        guard !running else { return }
        guard Self.hasAccess else { return askForAccess() }
        running = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PasteClip-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: pick an area or window, -x: no shutter sound, -o: no window shadow.
        process.arguments = ["-i", "-x", "-o", file.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.recognize(file) }
        }
        do {
            try process.run()
        } catch {
            running = false
            NSSound.beep()
        }
    }

    private func recognize(_ file: URL) {
        // No file means the selection was cancelled.
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            try? FileManager.default.removeItem(at: file)
            running = false
            return
        }
        // 144 dpi from a Retina screen, 72 from one that isn't.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 144
        let languages = settings.textLanguages
        let keepLineBreaks = settings.keepLineBreaks
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = TextRecognizer.recognize(dpi < 100 ? TextRecognizer.upscaled(image, by: 2) : image,
                                                languages: languages, keepLineBreaks: keepLineBreaks)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async { self?.finish(text) }
        }
    }

    private func finish(_ text: String?) {
        running = false
        toast.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        guard let text, let item = store.addText(text, source: "Screen Text") else {
            toast.show("No text found", symbol: "text.viewfinder")
            return
        }
        store.copyToPasteboard(item)
        onCopied?()
        if settings.translateScreenText, let onTranslate { return onTranslate(text) }
        let lines = text.split(separator: "\n").count
        toast.show(lines > 1 ? "Copied \(lines) lines of text" : "Copied text", symbol: "checkmark.circle.fill",
                   preview: text)
    }

    /// The first time, macOS asks by itself; after that, point to System Settings.
    private func askForAccess() {
        let key = "askedForScreenAccess"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            CGRequestScreenCaptureAccess()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow PasteClip to read the screen"
        alert.informativeText = """
            To copy text from the screen, turn on PasteClip in Privacy & Security → Screen & System Audio Recording, \
            then quit and reopen PasteClip. The screen is only read when you use this shortcut, and never leaves your Mac.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { Self.openPrivacySettings() }
    }
}

/// A short message near the bottom of the screen with the mouse, that fades on its own.
final class Toast {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()
    private var hideWork: DispatchWorkItem?
    var sharingType = NSWindow.SharingType.readOnly

    func show(_ message: String, symbol: String, preview: String? = nil) {
        let excerpt = preview.map(Self.excerpt)
        let view = NSHostingView(rootView: ToastView(message: message, symbol: symbol, preview: excerpt,
                                                     previewWidth: excerpt.map(Self.width) ?? 0))
        let size = view.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        panel.contentView = view
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height),
                       display: true)
        panel.alphaValue = 1
        panel.sharingType = sharingType
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
        }
        hideWork = work
        // Long enough to read the text.
        DispatchQueue.main.asyncAfter(deadline: .now() + (preview == nil ? 1.6 : 3), execute: work)
    }

    /// The first lines of `text`, on one line each.
    private static func excerpt(_ text: String) -> String {
        text.split(separator: "\n").prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// Width for the excerpt: as wide as its longest line, up to the toast's limit. Text given
    /// only a maximum width is measured on one line, so a line that wraps got cut off.
    private static func width(of excerpt: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: ToastView.previewFontSize)
        let widest = excerpt.split(separator: "\n").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(widest) + 2, ToastView.maxPreviewWidth)
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String
    var preview: String?
    var previewWidth: CGFloat = 0

    static let previewFontSize: CGFloat = 12
    static let maxPreviewWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(message).font(.system(size: 13, weight: .medium))
            }
            if let preview {
                Text(preview)
                    .font(.system(size: Self.previewFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: previewWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(GlassBackground(cornerRadius: preview == nil ? 19 : 14))
        .fixedSize()
    }
}
