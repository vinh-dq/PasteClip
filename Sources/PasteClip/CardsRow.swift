import AppKit
import PasteClipCore
import SwiftUI

/// The scrolling row of cards. The row itself doesn't watch the selection: each card's
/// `SelectionRing` does, and each card is `Equatable`, so moving the selection only redraws
/// two rings instead of rebuilding every card.
struct CardsRow: View {
    @ObservedObject var state: ShelfState
    let selection: SelectionModel
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
            let stack = Set(store.stack)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            card(item, index: index, inStack: stack.contains(item.id))
                        }
                    }
                    .padding(.vertical, 8)
                    // Room for the reorder bar beside the first and last cards.
                    .padding(.horizontal, 12)
                }
                .background { ScrollFollower(selection: selection, items: items, proxy: proxy) }
            }
        }
    }

    private func card(_ item: ClipItem, index: Int, inStack: Bool) -> some View {
        ClipCard(item: item, store: store, index: index,
                        board: item.pinboardID.flatMap(store.pinboard(withID:)),
                        inStack: inStack,
                        showLinkPreview: settings.linkPreviews,
                        quickPasteSymbol: settings.quickPasteModifier.symbol,
                        renaming: state.renamingID == item.id,
                        onEndRenaming: { if state.renamingID == item.id { state.renamingID = nil } })
            .equatable()
            .modifier(SelectionRing(selection: selection, index: index, cardFrame: state.previewing ? state.cardFrame : nil))
            .id(item.id)
            .modifier(ReorderBar(reorder: state.reorder, id: item.id, index: index))
            .onDrag {
                state.reorder.start(item.id, at: index)
                return ClipDrag.provider(for: item, store: store)
            }
            .onDrop(of: [ClipDrag.type], delegate: ReorderDropDelegate(target: item, index: index, state: state, store: store))
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

    private static func isHeld(_ key: ModifierKey) -> Bool {
        let flags = NSEvent.modifierFlags
        switch key {
        case .command: return flags.contains(.command)
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .shift: return flags.contains(.shift)
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

/// The ring and slight lift on the selected card. Each card watches the selection on its own,
/// so a move redraws this small view on each card rather than the whole row.
private struct SelectionRing: ViewModifier {
    @ObservedObject var selection: SelectionModel
    let index: Int
    /// Set while the preview is open, to report where the selected card is.
    let cardFrame: CardFrameTracker?

    func body(content: Content) -> some View {
        let selected = index == selection.index
        content
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-1.5)
                    .opacity(selected ? 1 : 0)
            )
            .scaleEffect(selected ? 1 : 0.97)
            .animation(.easeOut(duration: 0.1), value: selected)
            .background { if selected, let cardFrame { frameReporter(cardFrame) } }
    }

    /// Reports where the selected card is while the preview is open, including while the row scrolls.
    private func frameReporter(_ tracker: CardFrameTracker) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { tracker.frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, frame in tracker.frame = frame }
        }
    }
}

/// Scrolls the row to follow keyboard moves; clicks leave the row where it is.
private struct ScrollFollower: View {
    @ObservedObject var selection: SelectionModel
    let items: [ClipItem]
    let proxy: ScrollViewProxy
    @StateObject private var lastMove = ViewState(Date.distantPast)

    var body: some View {
        Color.clear.onChange(of: selection.scrollRequest) {
            guard items.indices.contains(selection.index) else { return }
            let id = items[selection.index].id
            // A held arrow key repeats faster than the animation runs; animating every step
            // re-lays out the row on each frame and falls behind, so repeats just jump.
            let repeating = Date().timeIntervalSince(lastMove.value) < 0.15
            lastMove.value = Date()
            if repeating {
                proxy.scrollTo(id)
            } else {
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }
}

/// The insertion bar beside a card while another card is dragged over it. It watches the drag
/// on its own, so hovering over cards redraws these bars rather than the shelf.
private struct ReorderBar: ViewModifier {
    @ObservedObject var reorder: ReorderModel
    let id: UUID
    let index: Int

    func body(content: Content) -> some View {
        // A dragged card takes the target's place: before it when coming from the right, after it
        // when coming from the left. The bar shows on that side.
        let edge: Alignment = (reorder.draggingIndex ?? Int.max) > index ? .leading : .trailing
        content.overlay(alignment: edge) {
            if reorder.target == id, reorder.dragging != id {
                Capsule().fill(Color.accentColor).frame(width: 4).padding(.vertical, 6)
                    .offset(x: edge == .leading ? -10 : 10)
            }
        }
    }
}

/// Dropping a card on another card of the same pinboard moves it there. History keeps its order.
private struct ReorderDropDelegate: DropDelegate {
    let target: ClipItem
    let index: Int
    let state: ShelfState
    let store: ClipStore

    func validateDrop(info: DropInfo) -> Bool {
        state.query.pinboardID != nil && info.hasItemsConforming(to: [ClipDrag.type])
    }

    func dropEntered(info: DropInfo) { state.reorder.hover(target.id) }

    func dropExited(info: DropInfo) { state.reorder.leave(target.id) }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        // A card dragged within the shelf is known already; moving it now, rather than after the
        // item provider has loaded its id, keeps the card from jumping once the drop has settled.
        if let id = state.reorder.dragging {
            state.reorder.end()
            withAnimation(.snappy(duration: 0.22)) { store.moveClip(id, to: target.id) }
            return true
        }
        state.reorder.end()
        return ClipDrag.receive(info.itemProviders(for: [ClipDrag.type])) { [store, target] id in
            withAnimation(.snappy(duration: 0.22)) { store.moveClip(id, to: target.id) }
        }
    }
}
