import AppKit
import Combine
import PasteClipCore
import SwiftUI
import UniformTypeIdentifiers

/// An app that clips came from, for the filter menu.
struct SourceApp: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Frame of the selected card while the preview popup is open. Kept outside `ShelfState`
/// so that scrolling doesn't redraw the whole shelf.
final class CardFrameTracker: ObservableObject {
    @Published var frame: CGRect?
}

/// Which card is selected. Separate from `ShelfState` so that selecting a card only
/// redraws the card row, not the whole shelf.
final class SelectionModel: ObservableObject {
    /// The card the keyboard is on.
    @Published var index = 0
    /// Clips picked with ⇧ or ⌘, by id. Empty when only the card at `index` is selected.
    @Published private(set) var picked: Set<UUID> = []
    /// Bumped when the row should scroll to the selection (keyboard moves, not clicks).
    @Published private(set) var scrollRequest = 0
    /// Where a ⇧ range starts: the last card selected without ⇧.
    private var anchor = 0

    /// Selects just this card.
    func select(_ index: Int, scroll: Bool) {
        if self.index != index { self.index = index }
        if !picked.isEmpty { picked = [] }
        anchor = index
        if scroll { scrollRequest += 1 }
    }

    /// ⇧: selects every card from the anchor to this one.
    func extend(to index: Int, in items: [ClipItem], scroll: Bool) {
        guard items.indices.contains(index) else { return }
        let anchor = min(self.anchor, items.count - 1)
        picked = Set(items[min(anchor, index)...max(anchor, index)].map(\.id))
        if self.index != index { self.index = index }
        if scroll { scrollRequest += 1 }
    }

    /// ⌘: adds this card to the selection, or takes it out.
    func toggle(_ index: Int, in items: [ClipItem]) {
        guard items.indices.contains(index) else { return }
        if picked.isEmpty, items.indices.contains(self.index) { picked = [items[self.index].id] }
        let id = items[index].id
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        if self.index != index { self.index = index }
        anchor = index
    }

    func selectAll(_ items: [ClipItem]) {
        picked = Set(items.map(\.id))
    }

    func clearPicks() {
        if !picked.isEmpty { picked = [] }
    }

    func isSelected(_ index: Int, id: UUID) -> Bool {
        picked.isEmpty ? index == self.index : picked.contains(id)
    }
}

/// The card being dragged within the row and the card it is over. Separate from `ShelfState`
/// so that hovering over cards doesn't redraw the whole shelf.
final class ReorderModel: ObservableObject {
    @Published private(set) var dragging: UUID?
    @Published private(set) var target: UUID?
    private(set) var draggingIndex: Int?

    func start(_ id: UUID, at index: Int) {
        draggingIndex = index
        dragging = id
    }

    func hover(_ id: UUID) {
        if target != id { target = id }
    }

    func leave(_ id: UUID) {
        if target == id { target = nil }
    }

    func end() {
        draggingIndex = nil
        if dragging != nil { dragging = nil }
        if target != nil { target = nil }
    }
}

/// UI state for the shelf, shared with the panel controller for keyboard handling.
final class ShelfState: ObservableObject {
    @Published var query = ClipQuery()
    @Published var focusToken = UUID()
    @Published var previewing = false
    @Published var editing = false
    /// Writing a new text clip.
    @Published var composing = false
    /// A text field inside the preview or composer has focus, so typing should reach it.
    @Published var textInputActive = false
    /// The clip whose title is being edited on its card. Keys go to the title field meanwhile.
    @Published var renamingID: UUID?
    /// Saves the text being edited in the popup; set while editing.
    var commitEdit: (() -> Void)?
    /// Clips matching the query. Recomputed only when the clips or the query change.
    @Published private(set) var visible: [ClipItem] = []
    /// Apps that clips came from, sorted by name.
    @Published private(set) var sourceApps: [SourceApp] = []

    let cardFrame = CardFrameTracker()
    let reorder = ReorderModel()
    let selectionModel = SelectionModel()
    let store: ClipStore
    var onPaste: (ClipItem, Bool) -> Void = { _, _ in }
    /// Pastes several clips together.
    var onPasteMany: ([ClipItem], Bool) -> Void = { _, _ in }
    /// Translates a clip, into the given language or the first one it isn't in.
    var onTranslate: (ClipItem, String?) -> Void = { _, _ in }
    var onOpenSettings: () -> Void = {}
    /// Opens an image clip in the image editor.
    var onEditImage: (ClipItem) -> Void = { _ in }
    /// Floats image clips on the screen.
    var onFloatImages: ([ClipItem]) -> Void = { _ in }
    /// Floats images with their text translated where it is.
    var onTranslateImages: ([ClipItem]) -> Void = { _ in }
    private var subscriptions = Set<AnyCancellable>()

    init(store: ClipStore) {
        self.store = store
        store.$items.combineLatest($query)
            .sink { [weak self] items, query in self?.visible = query.apply(items) }
            .store(in: &subscriptions)
        // A new search, filter or tab starts a new selection.
        $query.removeDuplicates()
            .sink { [weak self] _ in self?.selectionModel.clearPicks() }
            .store(in: &subscriptions)
        store.$items
            .sink { [weak self] items in self?.sourceApps = Self.apps(in: items) }
            .store(in: &subscriptions)
    }

    private static func apps(in items: [ClipItem]) -> [SourceApp] {
        var seen = Set<String>()
        var apps: [SourceApp] = []
        for item in items {
            guard let id = item.sourceBundleID, seen.insert(id).inserted else { continue }
            apps.append(SourceApp(id: id, name: item.sourceName ?? id))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selection: Int {
        get { selectionModel.index }
        set { selectionModel.select(newValue, scroll: true) }
    }

    var selectedItem: ClipItem? {
        visible.indices.contains(selection) ? visible[selection] : nil
    }

    /// The clips picked with ⇧ or ⌘, in the row's order, or else the selected one.
    var selectedItems: [ClipItem] {
        let picked = selectionModel.picked
        let items = picked.isEmpty ? [] : visible.filter { picked.contains($0.id) }
        return items.isEmpty ? [selectedItem].compactMap { $0 } : items
    }

    /// ⇧← / ⇧→: grows or shrinks the selection one card at a time.
    func extend(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selectionModel.extend(to: min(max(selection + delta, 0), visible.count - 1), in: visible, scroll: true)
        if editing { editing = false }
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
        if editing { editing = false }
    }

    /// Selecting with the mouse: the card is already in view, so don't scroll.
    func click(_ index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selectionModel.toggle(index, in: visible)
        } else if flags.contains(.shift) {
            selectionModel.extend(to: index, in: visible, scroll: false)
        } else {
            selectionModel.select(index, scroll: false)
        }
        // Assigning a @Published value notifies even when it doesn't change, which would
        // redraw the whole shelf on every click.
        if editing { editing = false }
        if renamingID != nil, renamingID != visible[safe: index]?.id { renamingID = nil }
    }

    /// Edits the title on the card itself.
    func startRenaming(_ index: Int) {
        guard let item = visible[safe: index] else { return }
        if previewing { closePreview() }
        selectionModel.select(index, scroll: false)
        renamingID = item.id
    }

    /// Steps through History and each pinboard.
    func cycleBoard(_ delta: Int) {
        let ids: [UUID?] = [nil] + store.pinboards.map(\.id)
        let current = ids.firstIndex(of: query.pinboardID) ?? 0
        query.pinboardID = ids[(current + delta + ids.count) % ids.count]
        selection = 0
    }

    func select(board: UUID?) {
        query.pinboardID = board
        selection = 0
    }

    /// Shows only images, or every type again.
    func toggleImagesOnly() {
        query.type = query.type == .image ? .all : .image
    }

    func togglePreview() {
        if previewing { closePreview() } else if selectedItem != nil { previewing = true }
    }

    func startComposing() {
        previewing = false
        editing = false
        composing = true
    }

    func closePreview() {
        cardFrame.frame = nil
        previewing = false
        editing = false
        composing = false
        textInputActive = false
        renamingID = nil
        commitEdit = nil
        focusToken = UUID()
    }

    func reset() {
        reorder.end()
        query = ClipQuery()
        selection = 0
        closePreview()
    }
}

struct ShelfView: View {
    @ObservedObject var state: ShelfState
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings
    @FocusState private var searchFocused: Bool
    @StateObject private var newBoardShown = ViewState(false)
    @StateObject private var editingBoard = ViewState<Pinboard?>(nil)
    /// Tab a card is being dragged over: "history" or a pinboard id.
    @StateObject private var dropTarget = ViewState<String?>(nil)

    var body: some View {
        VStack(spacing: 12) {
            topBar
            Group {
                if state.composing {
                    ComposeView(state: state, store: store)
                } else {
                    CardsRow(state: state, selection: state.selectionModel, store: store, settings: settings)
                }
            }
            .transition(.opacity)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(GlassBackground(cornerRadius: 26).ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .onChange(of: state.focusToken) { searchFocused = true }
        .onChange(of: state.query) { state.selection = 0 }
        .onAppear { searchFocused = true }
    }

    // MARK: - Top bar

    /// Filters on the left, search and pinboard tabs in the middle, actions on the right.
    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                filterMenu
                imagesToggle
                Spacer()
                if store.paused {
                    Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                }
                if store.stackMode {
                    Label("\(store.stack.count)", systemImage: "square.stack.3d.up.fill")
                        .foregroundStyle(Color.accentColor)
                        .help("Paste stack")
                }
                moreMenu
            }
            HStack(spacing: 6) {
                searchField
                boardTabs
            }
            .padding(.horizontal, 200) // keep clear of the side controls
        }
        .font(.system(size: 13))
        .frame(height: 30)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $state.query.text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !state.query.text.isEmpty {
                Button { state.query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: searchFocused || !state.query.text.isEmpty ? 220 : 130, height: 30)
        .glassCapsule()
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private var boardTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(title: "History", icon: "clock.arrow.circlepath", color: nil, tint: .accentColor,
                    selected: state.query.pinboardID == nil, dropOnto: nil) {
                    state.select(board: nil)
                }
                ForEach(store.pinboards) { board in
                    tab(title: board.name, icon: nil, color: board.color, tint: board.color,
                        selected: state.query.pinboardID == board.id, dropOnto: board) {
                        state.select(board: board.id)
                    }
                    .onDrag { PinboardDrag.provider(for: board) }
                    .contextMenu {
                        Button("Edit Pinboard…") { editingBoard.value = board }
                        Button("Delete Pinboard", role: .destructive) {
                            if state.query.pinboardID == board.id { state.select(board: nil) }
                            store.deletePinboard(board)
                        }
                    }
                    .popover(isPresented: Binding(get: { editingBoard.value?.id == board.id },
                                                  set: { if !$0 { editingBoard.value = nil } })) {
                        PinboardEditor(board: board) { name, color in
                            var updated = board
                            updated.name = name
                            updated.colorIndex = color
                            store.updatePinboard(updated)
                            editingBoard.value = nil
                        }
                    }
                }
                Button { newBoardShown.value = true } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Pinboard")
                .popover(isPresented: $newBoardShown.value) {
                    PinboardEditor(board: nil) { name, color in
                        let board = store.createPinboard(name: name, colorIndex: color)
                        state.select(board: board.id)
                        newBoardShown.value = false
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A tab. Dropping a card on a pinboard tab moves the clip there; dropping it on History
    /// (`dropOnto` nil) takes it off its pinboard. Dropping a pinboard tab on another moves it there.
    private func tab(title: String, icon: String?, color: Color?, tint: Color, selected: Bool,
                     dropOnto board: Pinboard?, action: @escaping () -> Void) -> some View {
        let key = board?.id.uuidString ?? "history"
        let targeted = dropTarget.value == key
        // Not a Button: a button keeps the mouse-down to itself, so the tab couldn't be dragged.
        return HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            if let color {
                Circle().fill(color).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            }
            Text(title).lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(height: 30)
        .contentShape(Capsule())
        .modifier(TabBackground(selected: selected || targeted, tint: tint))
        .onTapGesture(perform: action)
        .fontWeight(selected ? .semibold : .regular)
        .scaleEffect(targeted ? 1.1 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: targeted)
        .onDrop(of: [ClipDrag.type, PinboardDrag.type], isTargeted: Binding(
            get: { targeted },
            set: { dropTarget.value = $0 ? key : (dropTarget.value == key ? nil : dropTarget.value) }
        )) { providers in
            if PinboardDrag.receive(providers, { id in
                guard let board, let to = store.pinboards.firstIndex(where: { $0.id == board.id }) else { return }
                withAnimation(.snappy(duration: 0.2)) { store.movePinboard(id, to: to) }
            }) { return board != nil }
            state.reorder.end()
            return ClipDrag.receive(providers) { id in
                guard let item = store.item(withID: id) else { return }
                store.setPinboard(item, board)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $state.query.type) {
                ForEach(TypeFilter.allCases) { Text($0.title).tag($0) }
            }
            Picker("App", selection: $state.query.sourceBundleID) {
                Text("All Apps").tag(String?.none)
                ForEach(state.sourceApps) { Text($0.name).tag(String?.some($0.id)) }
            }
            Picker("Date", selection: $state.query.dateRange) {
                ForEach(DateRange.allCases) { Text($0.title).tag($0) }
            }
            if state.query.hasFilters {
                Divider()
                Button("Reset Filters") {
                    state.query.type = .all
                    state.query.sourceBundleID = nil
                    state.query.dateRange = .any
                }
            }
        } label: {
            Label(filterSummary, systemImage: state.query.hasFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(state.query.hasFilters ? Color.accentColor : Color.secondary)
    }

    /// One click (or ⌘I) for images only, and again for everything.
    private var imagesToggle: some View {
        let on = state.query.type == .image
        return Button { state.toggleImagesOnly() } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "photo.fill" : "photo")
                Text("Images").font(.system(size: 12, weight: .medium))
                KeyHint(keys: "⌘I")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .contentShape(Capsule())
            .glassCapsule(selected: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Show every type (⌘I)" : "Show only images (⌘I)")
    }

    private var filterSummary: String {
        var parts: [String] = []
        if state.query.type != .all { parts.append(state.query.type.title) }
        if let id = state.query.sourceBundleID { parts.append(state.sourceApps.first { $0.id == id }?.name ?? id) }
        if state.query.dateRange != .any { parts.append(state.query.dateRange.title) }
        return parts.isEmpty ? "Filter" : parts.joined(separator: " · ")
    }

    private var moreMenu: some View {
        Menu {
            Button("New Text Item") { state.startComposing() }
                .keyboardShortcut("n")
            Button(store.stackMode ? "Stop Paste Stack" : "Start Paste Stack") { store.stackMode.toggle() }
            Divider()
            Button(store.paused ? "Resume Capturing" : "Pause Capturing") { store.paused.toggle() }
            Button("Settings…") { state.onOpenSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Quit PasteClip") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .glassCircle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

}

/// Writes a new text clip. It lands in the current pinboard when one is selected.
struct ComposeView: View {
    @ObservedObject var state: ShelfState
    let store: ClipStore
    @FocusState private var focused: Bool
    @StateObject private var title = ViewState("")
    @StateObject private var text = ViewState("")

    var body: some View {
        HStack(spacing: 14) {
            TextEditor(text: $text.value)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .focused($focused)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            VStack(alignment: .leading, spacing: 10) {
                Text("New Text Item").font(.headline)
                TextField("Title (optional)", text: $title.value)
                    .textFieldStyle(.roundedBorder)
                Text("Saved clips can be pasted like anything you copied.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Button("Cancel") { state.closePreview() }
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(width: 250)
        }
        .onAppear {
            focused = true
            state.textInputActive = true
        }
    }

    private func save() {
        let t = title.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = store.addText(text.value, title: t.isEmpty ? nil : t) else { return }
        if let id = state.query.pinboardID, let board = store.pinboard(withID: id) {
            store.setPinboard(item, board)
        }
        state.closePreview()
        state.selection = 0
    }
}

/// Glass behind the selected tab only, so unselected tabs read as plain labels.
private struct TabBackground: ViewModifier {
    let selected: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if selected { content.glassCapsule(selected: true, tint: tint) } else { content }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
