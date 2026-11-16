import AppKit
import PasteClipCore
import SwiftUI

/// Small floating list of the paste stack, shown in the top-right corner while stack mode is on.
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
        panel.contentView = NSHostingView(rootView: StackView(store: store, settings: settings))
    }

    func setVisible(_ visible: Bool) {
        guard visible else { panel.orderOut(nil); return }
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.orderFrontRegardless()
    }
}

struct StackView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Paste Stack", systemImage: "square.stack.3d.up.fill").font(.headline)
                Spacer()
                Text("\(store.stack.count)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }

            let items = store.stackItems
            if items.isEmpty {
                Text("Copy things one after another. They line up here, then paste them in the same order.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 6) {
                                Text("\(index + 1)").font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                                Image(systemName: item.kind.symbol).frame(width: 16)
                                Text(item.title ?? preview(item)).lineLimit(1)
                                Spacer(minLength: 0)
                                Button { store.removeFromStack(item) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(index == 0 ? Color.accentColor.opacity(0.2) : Color.clear))
                        }
                    }
                }
            }

            Divider()
            HStack {
                if let combo = settings.pasteNextHotKey {
                    Text("\(combo.display) pastes next").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { store.stackMode = false }
            }
        }
        .padding(14)
        .frame(width: 290, height: 300)
        .background(GlassBackground(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
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
