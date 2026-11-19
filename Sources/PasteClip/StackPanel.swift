import AppKit
import Combine
import PasteClipCore
import SwiftUI

/// Small floating list of the paste stack, shown in the top-right corner of the screen with the
/// pointer while stack mode is on. As tall as what it lists, keeping its top edge where it is.
final class StackController {
    private let panel: NSPanel
    private let settings: AppSettings
    private let size = NSSize(width: StackView.width, height: 120)
    private let hosting: NSHostingView<StackView>
    private var subscription: AnyCancellable?
    private let tone = GlowTone()
    private lazy var halo = GlowHalo(around: panel, kind: .panel, cornerRadius: StackView.cornerRadius, tone: tone)

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
        hosting = NSHostingView(rootView: StackView(store: store, settings: settings, tone: tone))
        // Rounded as its glass, so the window's shadow is too.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = StackView.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        // After the list has been laid out with its new clips.
        subscription = store.$stack.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    private func fit() {
        guard panel.isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        guard height != panel.frame.height else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height), display: true)
    }

    func setVisible(_ visible: Bool) {
        guard visible else { panel.orderOut(nil); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        panel.setFrame(NSRect(x: frame.maxX - size.width - 16, y: frame.maxY - height - 16, width: size.width, height: height),
                       display: false)
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.orderFrontRegardless()
        halo.syncVisibility()
    }
}

struct StackView: View {
    static let cornerRadius: CGFloat = 18
    static let width: CGFloat = 290
    /// The tallest the list gets; more clips scroll.
    static let maxListHeight: CGFloat = 220
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings
    let tone: GlowTone

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
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let list = VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        StackRow(index: index, item: item, text: item.title ?? preview(item)) {
                            store.removeFromStack(item)
                        }
                    }
                }
                // Its own height while it fits, then capped and scrolling.
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView { list }.scrollIndicators(.never)
                }
                .frame(maxHeight: Self.maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: Self.width)
        .lightRim(cornerRadius: Self.cornerRadius, tone: tone)
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
