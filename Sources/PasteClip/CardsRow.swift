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
                    LazyHStack(spacing: 14) {
                        // Each day label is a child of the row of its own, beside the cards.
                        ForEach(entries(items)) { entry in
                            switch entry {
                            case .day(let date): DayLabel(date: date)
                            case .card(let index, let item): card(item, index: index, inStack: stack.contains(item.id))
                            }
                        }
                    }
                    // Room for the selected card's lift and ring.
                    .padding(.vertical, 12)
                    // Room for the reorder bar beside the first and last cards.
                    .padding(.horizontal, 12)
                    // The row's very ends, scrolled to for the first and last cards so that room
                    // shows too; scrolling to the card itself leaves its edge flush and cut.
                    .background(alignment: .leading) { Color.clear.frame(width: 1).id(RowEnd.start) }
                    .background(alignment: .trailing) { Color.clear.frame(width: 1).id(RowEnd.end) }
                }
                .background { ScrollFollower(selection: selection, items: items, proxy: proxy) }
            }
            .overlay(alignment: .bottom) { SelectionHint(selection: selection) }
        }
    }

    private func card(_ item: ClipItem, index: Int, inStack: Bool) -> some View {
        ClipCard(item: item, store: store, index: index,
                        board: item.pinboardID.flatMap(store.pinboard(withID:)),
                        inStack: inStack,
                        showLinkPreview: settings.linkPreviews,
                        renaming: state.renamingID == item.id,
                        onEndRenaming: { if state.renamingID == item.id { state.renamingID = nil } })
            .equatable()
            .modifier(QuickPasteNumber(keys: state.heldKeys, index: index, symbol: settings.quickPasteModifier.symbol))
            .modifier(HoverLift())
            .modifier(SelectionRing(selection: selection, index: index, id: item.id,
                                    cardFrame: state.previewing ? state.cardFrame : nil))
            .id(item.id)
            .modifier(ReorderBar(reorder: state.reorder, id: item.id, index: index))
            .onDrag {
                state.reorder.start(item.id, at: index)
                return ClipDrag.provider(for: item, store: store)
            }
            .onDrop(of: [ClipDrag.type], delegate: ReorderDropDelegate(target: item, index: index, state: state, store: store))
            // A single click selects at once; the double-click is recognised alongside it
            // instead of making every click wait to see whether a second one follows.
            // Double-clicking its label renames the clip; anywhere else pastes it.
            .gesture(TapGesture().onEnded { state.click(index) })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                if tap.location.y < ClipCard.labelHeight {
                    state.startRenaming(index)
                } else {
                    state.onPaste(item, Self.isHeld(settings.plainTextModifier))
                }
            })
            .contextMenu { CardMenu(selection: selection, state: state, store: store, settings: settings, item: item, index: index) }
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

    /// The cards, and in History (newest first) a day's label before the first card of each
    /// day. Pinboards keep their own order, so they go without.
    private func entries(_ items: [ClipItem]) -> [RowEntry] {
        let history = state.query.pinboardID == nil
        var entries: [RowEntry] = []
        entries.reserveCapacity(items.count + 8)
        for (index, item) in items.enumerated() {
            if history, index == 0 || !Calendar.current.isDate(items[index - 1].date, inSameDayAs: item.date) {
                entries.append(.day(item.date))
            }
            entries.append(.card(index, item))
        }
        return entries
    }

    private var emptyMessage: String {
        if !state.query.text.isEmpty || state.query.hasFilters { return "No matches" }
        if state.query.pinboardID != nil { return "This pinboard is empty. Drag a clip onto its tab to add it." }
        return "Nothing copied yet"
    }

}

/// A card's right-click menu. On a card among several selected ones, it acts on all of them.
/// It watches the selection itself, as the row doesn't.
private struct CardMenu: View {
    @ObservedObject var selection: SelectionModel
    @ObservedObject var state: ShelfState
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings
    let item: ClipItem
    let index: Int

    var body: some View {
        let picked = selection.picked.contains(item.id) ? state.selectedItems : []
        if picked.count > 1 {
            Button("Paste \(picked.count) Clips") { state.onPasteMany(picked, false) }
            Button("Paste as Plain Text") { state.onPasteMany(picked, true) }
            Button("Copy \(picked.count) Clips") { store.copyToPasteboard(picked) }
            let images = picked.filter(\.isImage)
            if !images.isEmpty {
                Button(images.count == 1 ? "Float Image on Screen" : "Float \(images.count) Images on Screen") {
                    state.onFloatImages(images)
                }
                .keyboardShortcut(settings.floatImageKey)
            }
            Divider()
            Button("Add to Paste Stack") { picked.forEach(store.addToStack) }
            Divider()
            Button("Delete \(picked.count) Clips", role: .destructive) {
                store.delete(picked)
                selection.clearPicks()
            }
        } else {
            menu(for: item, index: index)
        }
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
        if item.isImage {
            Button("Edit Image…") { state.onEditImage(item) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Float on Screen") { state.onFloatImages([item]) }
                .keyboardShortcut(settings.floatImageKey)
        }
        Button("Rename…") { state.startRenaming(index) }
        if item.translatableText?.isEmpty == false || item.isImage {
            Menu("Translate") {
                Button("Translate") { state.onTranslate(item, nil) }
                if item.isImage {
                    Button("Translate on the Image") { state.onTranslateImages([item]) }
                        .keyboardShortcut(settings.translateImageKey)
                }
                Divider()
                ForEach(settings.translationTargets, id: \.self) { language in
                    Button("Into \(Translator.name(of: language))") { state.onTranslate(item, language) }
                }
            }
        }
        Divider()
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
    let id: UUID
    /// Set while the preview is open, to report where the selected card is.
    let cardFrame: CardFrameTracker?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let selected = selection.isSelected(index, id: id)
        let focused = index == selection.index
        let several = selected && selection.picked.count > 1
        content
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: ClipCard.cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.3))
                        .blur(radius: 12)
                        .offset(y: 5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: ClipCard.cornerRadius + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .opacity(selected ? 1 : 0)
            )
            // Several selected: a tick on each, as in Photos.
            .overlay(alignment: .topTrailing) {
                if several {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(7)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            // With Reduce Motion on, the ring alone marks the selection: nothing grows or springs.
            .scaleEffect(selected && !reduceMotion ? 1.03 : 1)
            .offset(y: selected && !reduceMotion ? -3 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: selected)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: several)
            .background { if focused, let cardFrame { frameReporter(cardFrame) } }
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

/// One child of the card row: a card, or the label of the day the cards after it were copied.
private enum RowEntry: Identifiable {
    case day(Date)
    case card(Int, ClipItem)

    var id: String {
        switch self {
        case .day(let date): return "day-\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"
        case .card(_, let item): return item.id.uuidString
        }
    }
}

/// A card rises a little under the pointer. Each card watches its own hover, so moving over
/// the row redraws only the cards entered and left.
private struct HoverLift: ViewModifier {
    @StateObject private var hovering = ViewState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .scaleEffect(hovering.value ? 1.015 : 1)
                .offset(y: hovering.value ? -2 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering.value)
                .onHover { hovering.value = $0 }
        }
    }
}

/// The card's quick-paste key (⌘1…⌘9), only while that modifier is held, so the cards stay
/// clear otherwise.
private struct QuickPasteNumber: ViewModifier {
    @ObservedObject var keys: HeldKeys
    let index: Int
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if index < 9, keys.quickPaste {
                Text("\(symbol)\(index + 1)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.black.opacity(0.68)))
                    .padding(9)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.7), value: keys.quickPaste)
    }
}

/// The day the cards after it were copied, written up the side between two cards.
private struct DayLabel: View {
    let date: Date

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: 12, height: ClipCard.size.height)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Scrolls the row to follow keyboard moves; clicks leave the row where it is.
/// "3 clips selected" and what can be done with them, while several are selected.
private struct SelectionHint: View {
    @ObservedObject var selection: SelectionModel

    var body: some View {
        let count = selection.picked.count
        if count > 1 {
            HStack(spacing: 14) {
                Text("\(count) clips selected").fontWeight(.semibold)
                Text("Return  Paste").foregroundStyle(.secondary)
                Text("⌘C  Copy").foregroundStyle(.secondary)
                Text("⌘⌫  Delete").foregroundStyle(.secondary)
                Text("Esc  Clear").foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassCapsule()
            .padding(.bottom, 2)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// The shelf's keys, shown in its top bar while the quick-paste modifier is held a moment, as
/// the cards show their numbers: there to find without cluttering the shelf the rest of the time.
struct ShelfKeysHint: View {
    @ObservedObject var keys: HeldKeys
    @ObservedObject var selection: SelectionModel
    let translateKey: String?

    var body: some View {
        if keys.showsKeys, selection.picked.count <= 1 {
            HStack(spacing: 12) {
                hint("Space", "Preview")
                hint("⌘E", "Edit")
                hint("⌘R", "Rename")
                if let translateKey { hint(translateKey, "Translate") }
                hint("⌘C", "Copy")
                hint("⌘⌫", "Delete")
                hint("Tab", "Pinboards")
                hint("⌘F", "Search")
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassCapsule()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            KeyHint(keys: key)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

private enum RowEnd: Hashable { case start, end }

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
            let scroll = {
                switch selection.index {
                case 0: proxy.scrollTo(RowEnd.start, anchor: .leading)
                case items.count - 1: proxy.scrollTo(RowEnd.end, anchor: .trailing)
                default: proxy.scrollTo(id)
                }
            }
            if repeating {
                scroll()
            } else {
                withAnimation(.easeOut(duration: 0.12)) { scroll() }
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
