import AppKit
import PasteClipCore
import SwiftUI

/// The scrolling row of cards. It is the only part of the shelf that watches the selection,
/// and each card is `Equatable`, so changing the selection only redraws two selection rings.
struct CardsRow: View {
    @ObservedObject var state: ShelfState
    @ObservedObject var selection: SelectionModel
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        let items = state.visible
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: state.query.pinboardID == nil ? "tray" : "pin").font(.system(size: 32))
                Text(emptyMessage)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            card(item, index: index)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
                // Follow keyboard moves; clicks leave the row where it is.
                .onChange(of: selection.scrollRequest) {
                    guard items.indices.contains(selection.index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(items[selection.index].id) }
                }
            }
        }
    }

    private func card(_ item: ClipItem, index: Int) -> some View {
        let selected = index == selection.index
        let stack = Set(store.stack)
        return ClipCard(item: item, store: store, index: index,
                        board: item.pinboardID.flatMap(store.pinboard(withID:)),
                        inStack: stack.contains(item.id),
                        showLinkPreview: settings.linkPreviews,
                        quickPasteSymbol: settings.quickPasteModifier.symbol)
            .equatable()
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-1.5)
                    .opacity(selected ? 1 : 0)
            )
            .scaleEffect(selected ? 1 : 0.97)
            .animation(.easeOut(duration: 0.1), value: selected)
            .id(item.id)
            .background { if state.previewing && selected { frameReporter } }
            .onDrag { ClipDrag.provider(for: item, store: store) }
            // A single click selects at once; the double-click is recognised alongside it
            // instead of making every click wait to see whether a second one follows.
            .gesture(TapGesture().onEnded { state.click(index) })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                state.onPaste(item, Self.isHeld(settings.plainTextModifier))
            })
            .contextMenu { menu(for: item, index: index) }
    }

    private static func isHeld(_ key: ModifierKey) -> Bool {
        let flags = NSEvent.modifierFlags
        switch key {
        case .command: return flags.contains(.command)
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .shift: return flags.contains(.shift)
        }
    }

    /// Reports where the selected card is while the preview is open, including while the row scrolls.
    private var frameReporter: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { state.cardFrame.frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, frame in state.cardFrame.frame = frame }
        }
    }

    private var emptyMessage: String {
        if !state.query.text.isEmpty || state.query.hasFilters { return "No matches" }
        if state.query.pinboardID != nil { return "This pinboard is empty. Drag a clip onto its tab to add it." }
        return "Nothing copied yet"
    }

    @ViewBuilder
    private func menu(for item: ClipItem, index: Int) -> some View {
        Button("Paste") { state.onPaste(item, false) }
        Button("Paste as Plain Text") { state.onPaste(item, true) }
        Button("Copy") { store.copyToPasteboard(item) }
        Divider()
        Button("Preview") {
            state.click(index)
            state.previewing = true
        }
        if item.isTextual {
            Button("Edit…") {
                state.click(index)
                state.previewing = true
                state.editing = true
            }
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
        Menu("Pinboard") {
            ForEach(store.pinboards) { board in
                Toggle(board.name, isOn: Binding(get: { item.pinboardID == board.id },
                                                 set: { store.setPinboard(item, $0 ? board : nil) }))
            }
            if item.pinboardID != nil {
                Divider()
                Button("Remove from Pinboard") { store.setPinboard(item, nil) }
            }
        }
        .disabled(store.pinboards.isEmpty)
        if store.stack.contains(item.id) {
            Button("Remove from Paste Stack") { store.removeFromStack(item) }
        } else {
            Button("Add to Paste Stack") { store.addToStack(item) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item) }
    }
}
