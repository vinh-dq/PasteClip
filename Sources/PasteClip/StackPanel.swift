import AppKit
import PasteClipCore
import SwiftUI

/// Small floating list of the paste stack, shown in the top-right corner of the screen with the
/// pointer while stack mode is on.
final class StackController {
    private let panel: NSPanel
    private let settings: AppSettings
    private let size = NSSize(width: 290, height: 300)

    init(store: ClipStore, settings: AppSettings) {
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: StackView(store: store, settings: settings))
        // Rounded as its glass, so the window's shadow is too.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = StackView.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
    }

    func setVisible(_ visible: Bool) {
        guard visible else { panel.orderOut(nil); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.orderFrontRegardless()
    }
}

struct StackView: View {
    static let cornerRadius: CGFloat = 18
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.secondary)
                Text("Paste Stack").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.stack.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            let items = store.stackItems
            if items.isEmpty {
                Text("Copy things one after another. They line up here, then paste them in the same order.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            StackRow(index: index, item: item, text: item.title ?? preview(item)) {
                                store.removeFromStack(item)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            HStack(spacing: 6) {
                if let combo = settings.pasteNextHotKey {
                    Text("\(combo.display) pastes the next one").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                CapsuleButton(title: "Stop", key: settings.stackHotKey?.display,
                              help: "Stop collecting and empty the stack" + (settings.stackHotKey.map { " (\($0.display))" } ?? "")) {
                    store.stackMode = false
                }
            }
        }
        .padding(14)
        .frame(width: 290, height: 300)
        .background(GlassBackground(cornerRadius: Self.cornerRadius))
    }

    private func preview(_ item: ClipItem) -> String {
        switch item.kind {
        case .text, .link, .color:
            return (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
        case .file:
            return item.filePaths?.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") ?? "Files"
        case .image:
            return item.sourceName.map { "Image from \($0)" } ?? "Image"
        }
    }
}

/// One clip in the stack, numbered in paste order; the next one to paste is tinted.
private struct StackRow: View {
    let index: Int
    let item: ClipItem
    let text: String
    let remove: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        HStack(spacing: 7) {
            Text("\(index + 1)").font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            Image(systemName: item.kind.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering.value ? 1 : 0)
            .help("Remove from the stack")
        }
        .font(.system(size: 12))
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(index == 0 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering.value ? 0.06 : 0)))
        .onHover { hovering.value = $0 }
    }
}
