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
                    // Room for the reorder bar beside the first and last cards.
                    .padding(.horizontal, 12)
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
                        quickPasteSymbol: settings.quickPasteModifier.symbol,
                        renaming: state.renamingID == item.id,
                        onEndRenaming: { if state.renamingID == item.id { state.renamingID = nil } })
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
            .overlay(alignment: reorderEdge(for: item, in: index)) {
                if state.reorderTarget == item.id, state.draggingID != item.id {
                    Capsule().fill(Color.accentColor).frame(width: 4).padding(.vertical, 6)
                        .offset(x: reorderEdge(for: item, in: index) == .leading ? -10 : 10)
                }
            }
            .onDrag {
                state.draggingID = item.id
                return ClipDrag.provider(for: item, store: store)
            }
            .onDrop(of: [ClipDrag.type], delegate: ReorderDropDelegate(target: item, state: state, store: store))
            // A single click selects at once; the double-click is recognised alongside it
            // instead of making every click wait to see whether a second one follows.
            // Double-clicking the header renames the clip; anywhere else pastes it.
            .gesture(TapGesture().onEnded { state.click(index) })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                if tap.location.y < ClipCard.headerHeight {
                    state.startRenaming(index)
                } else {
                    state.onPaste(item, Self.isHeld(settings.plainTextModifier))
                }
            })
            .contextMenu { menu(for: item, index: index) }
    }

    /// A dragged card takes the target's place: before it when coming from the right, after it
    /// when coming from the left. The insertion bar shows on that side.
    private func reorderEdge(for item: ClipItem, in index: Int) -> Alignment {
        let from = state.visible.firstIndex { $0.id == state.draggingID } ?? Int.max
        return from > index ? .leading : .trailing
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
        Button("Rename…") { state.startRenaming(index) }
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

/// Dropping a card on another card of the same pinboard moves it there. History keeps its order.
private struct ReorderDropDelegate: DropDelegate {
    let target: ClipItem
    let state: ShelfState
    let store: ClipStore

    func validateDrop(info: DropInfo) -> Bool {
        state.query.pinboardID != nil && info.hasItemsConforming(to: [ClipDrag.type])
    }

    func dropEntered(info: DropInfo) { state.reorderTarget = target.id }

    func dropExited(info: DropInfo) {
        if state.reorderTarget == target.id { state.reorderTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        state.reorderTarget = nil
        return ClipDrag.receive(info.itemProviders(for: [ClipDrag.type])) { [state, store, target] id in
            state.draggingID = nil
            withAnimation(.easeOut(duration: 0.2)) { store.moveClip(id, to: target.id) }
        }
    }
}
