import AppKit
import PasteClipCore
import SwiftUI

/// The shortcuts as they are set now (a cleared one is left out): the ones that work from any app,
/// then the ones of the open shelf. Glass like the preview popup, with the shelf's top-lit rim.
struct ShortcutsSheet: View {
    @ObservedObject var settings: AppSettings
    let tone: GlowTone

    private var anywhere: [(String, String?)] {
        [("Open PasteClip", settings.shelfHotKey?.display), ("Copy text from the screen", settings.captureTextHotKey?.display),
         ("Translate a screen area", settings.translateScreenHotKey?.display), ("Screenshot an area", settings.screenshotHotKey?.display),
         ("Translate selection, clipboard or image", settings.translateHotKey?.display),
         ("Float the latest image", settings.floatImageKey?.display),
         ("Start or stop paste stack", settings.stackHotKey?.display), ("Paste next from the stack", settings.pasteNextHotKey?.display)]
    }

    private var inShelf: [(String, String?)] {
        [("Paste", "↩"), ("Preview", "Space"), ("Move, extend selection", "← →  ⇧← ⇧→"),
         ("Next pinboard", settings.nextPinboardKey?.display), ("Quick paste", "\(settings.quickPasteModifier.symbol)1…9"),
         ("Search", "⌘F"), ("Delete", "⌘⌫")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shortcuts").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Esc closes").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 36) {
                column("From any app", anywhere)
                column("In the shelf", inShelf)
            }
            Text("The ones from any app can be changed in Settings › Shortcuts.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 640)
        .lightRim(cornerRadius: 22, tone: tone)
        .background(GlassBackground(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassEdge(cornerRadius: 22)
    }

    private func column(_ title: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let keys = row.1, !keys.isEmpty {
                    HStack(spacing: 12) {
                        Text(row.0).font(.system(size: 12.5))
                        Spacer(minLength: 8)
                        Text(keys).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sheet's window: made once and only ordered in and out, so opening it costs a fade.
/// It takes no clicks and no keys; the shelf closes it on the next one.
final class ShortcutsSheetController {
    private let panel = PreviewPanel()
    private let tone = GlowTone()

    init(settings: AppSettings) {
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let host = HostingView(rootView: ShortcutsSheet(settings: settings, tone: tone))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    func show(over shelf: NSPanel, atTop: Bool, sharingType: NSWindow.SharingType) {
        let size = panel.frame.size
        let x = shelf.frame.midX - size.width / 2
        let y = atTop ? shelf.frame.minY - 10 - size.height : shelf.frame.maxY + 10
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.sharingType = sharingType
        if panel.parent == nil { shelf.addChildWindow(panel, ordered: .above) }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
