import AppKit
import Combine
import PasteClipCore
import SwiftUI

/// A borderless panel for notes. It takes the keyboard (to write) without making PasteClip the
/// front app, and stays exactly where it's put, edges of the screen included.
final class NotesPanel: NSPanel {
    var allowsKey = true
    var onEscape: (() -> Void)?

    init(size: NSSize, allowsKey: Bool, fullScreen: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = fullScreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Rounds a hosting view as its glass, so the window's shadow follows.
private func rounded<V: View>(_ view: V, radius: CGFloat) -> NSHostingView<V> {
    let hosting = HostingView(rootView: view)
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = radius
    hosting.layer?.cornerCurve = .continuous
    hosting.layer?.masksToBounds = true
    return hosting
}

private func screenUnderPointer() -> NSScreen {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - Edge bar

/// The bar on one screen. Its window never changes size: it is as big as the open bar, and takes
/// the mouse only while open. At rest the pointer is found by watching where it is, so the strip
/// of screen under the window stays usable.
final class NotesEdgeBar {
    let screen: NSScreen
    let model = EdgeModel()
    let panel: NotesPanel
    private unowned let controller: NotesController
    private var openTimer: DispatchWorkItem?
    private var closeTimer: DispatchWorkItem?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var menuTracking = false
    private var holdOpenUntil = Date.distantPast
    /// Height of the strip for the notes now, kept so that watching the pointer costs no more than a comparison.
    private var stripHeight = NotesEdgeView.columnHeight(count: 0)

    init(controller: NotesController, screen: NSScreen) {
        self.controller = controller
        self.screen = screen
        let settings = controller.settings
        panel = NotesPanel(size: NSSize(width: NotesEdgeView.openWidth, height: 100), allowsKey: false,
                           fullScreen: settings.notesShowInFullScreen)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.contentView = HostingView(rootView: NotesEdgeView(
            store: controller.store, settings: settings, model: model,
            onHover: { [weak self] _ in self?.pointerMoved() },
            onTabHover: { [weak self] note in guard let self else { return }; controller.tabHover(note, bar: self) },
            onOpen: { [weak self] note in guard let self else { return }; controller.open(note.id, from: self) },
            onNew: { [weak self] in guard let self else { return }; controller.newNote(from: self) },
            onMove: { [controller] id, index in controller.store.move(id, toActiveIndex: index) },
            onPin: { [weak self] id in guard let self else { return }; controller.togglePin(id, from: self) },
            onColor: { [controller] id, color in controller.store.setColor(id, color) },
            onArchive: { [controller] id in controller.archive(id) },
            onDelete: { [controller] id in controller.delete(id) },
            onCopy: { [controller] id in controller.copyText(id) }))
        // A menu opened from a tab keeps the bar open while it's showing.
        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.menuTracking = tracking
                if !tracking { self.closeSoon() }
            })
        }
        refit()
        panel.orderFrontRegardless()
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
        panel.orderOut(nil)
    }

    /// The window's frame: the bar open, on the edge and place chosen in Settings, with the
    /// strip's centre (or top, or bottom) where the place says.
    func frame() -> NSRect {
        let settings = controller.settings
        let strip = stripHeight
        let size = NSSize(width: NotesEdgeView.openWidth, height: strip + NotesEdgeView.footer)
        let visible = screen.visibleFrame
        let x = settings.notesEdge == .right ? screen.frame.maxX - size.width : screen.frame.minX
        let top: CGFloat
        switch settings.notesPlacement {
        case .top: top = visible.maxY - 90
        case .center: top = visible.midY + strip / 2
        case .bottom: top = visible.minY + 90 + size.height
        }
        return NSRect(origin: NSPoint(x: x, y: max(visible.minY, top - size.height)), size: size)
    }

    func refit() {
        stripHeight = NotesEdgeView.columnHeight(count: controller.store.active.count)
        panel.setFrame(frame(), display: true)
    }

    /// The vertical middle of the strip of tabs, which the preview and the editor line up with.
    var stripMidY: CGFloat { frame().maxY - stripHeight / 2 }

    /// Where the closed strip is, in screen coordinates.
    private var stripFrame: NSRect {
        let f = panel.frame
        let height = stripHeight
        let width = NotesEdgeView.railWidth
        let x = controller.settings.notesEdge == .right ? f.maxX - width : f.minX
        return NSRect(x: x, y: f.maxY - height, width: width, height: height)
    }

    private var keepOpen: Bool {
        controller.hasEditor(on: self) || Date() < holdOpenUntil || model.dragID != nil || menuTracking
    }

    /// Called whenever the pointer moves: opens the bar after it has rested on the strip, and
    /// folds it a moment after it has left the bar.
    func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        if model.open {
            let inside = panel.frame.insetBy(dx: -4, dy: -4).contains(mouse)
            if inside {
                closeTimer?.cancel(); closeTimer = nil
            } else {
                controller.tabHover(nil, bar: self)
                closeSoon()
            }
        } else {
            let hot = stripFrame.insetBy(dx: -2, dy: -4).contains(mouse)
            if hot {
                guard openTimer == nil else { return }
                schedule(&openTimer, after: Double(controller.settings.notesHoverDelay) / 1000) { [weak self] in
                    self?.openTimer = nil
                    // Not while something is being dragged or a button is held (scrolling, drag and drop).
                    guard let self, NSEvent.pressedMouseButtons == 0, self.stripFrame.insetBy(dx: -2, dy: -4).contains(NSEvent.mouseLocation)
                    else { return }
                    self.setOpen(true)
                }
            } else {
                openTimer?.cancel(); openTimer = nil
            }
        }
    }

    func closeSoon() {
        guard model.open, !keepOpen, closeTimer == nil else { return }
        schedule(&closeTimer, after: 0.25) { [weak self] in
            guard let self else { return }
            self.closeTimer = nil
            guard !self.keepOpen, !self.panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }
            self.setOpen(false)
        }
    }

    /// Opens the bar for a moment, to show something that happened in it (a note added).
    func flash(_ id: UUID) {
        holdOpenUntil = Date().addingTimeInterval(1.8)
        model.flashed = id
        setOpen(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
            self?.model.flashed = nil
            self?.closeSoon()
        }
    }

    func setOpen(_ open: Bool) {
        guard model.open != open else { return }
        model.open = open
        if open {
            panel.ignoresMouseEvents = false
        } else {
            // After the tabs have folded away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, !self.model.open else { return }
                self.panel.ignoresMouseEvents = true
            }
        }
    }

    private func schedule(_ slot: inout DispatchWorkItem?, after delay: Double, _ work: @escaping () -> Void) {
        slot?.cancel()
        let item = DispatchWorkItem(block: work)
        slot = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

// MARK: - One note's window

private final class NoteWindow {
    let id: UUID
    let panel: NotesPanel
    let proxy = NoteEditorProxy()
    let tone = GlowTone()
    weak var bar: NotesEdgeBar?
    private var halo: GlowHalo?
    private var observer: NSObjectProtocol?

    init(id: UUID, controller: NotesController, bar: NotesEdgeBar?) {
        self.id = id
        self.bar = bar
        let settings = controller.settings
        panel = NotesPanel(size: NoteEditorView.size, allowsKey: true, fullScreen: true)
        panel.isMovableByWindowBackground = true
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.contentView = rounded(NoteEditorView(
            store: controller.store, settings: settings, id: id, tone: tone, proxy: proxy,
            onClose: { [weak controller] in controller?.closeEditor(id) },
            onDelete: { [weak controller] in controller?.delete(id) },
            onPin: { [weak controller] in controller?.togglePin(id) }), radius: NoteEditorView.cornerRadius)
        panel.onEscape = { [weak controller] in controller?.closeEditor(id) }
        halo = GlowHalo(around: panel, kind: .panel, cornerRadius: NoteEditorView.cornerRadius, tone: tone)
        // Clicking anywhere else closes a note that isn't kept on screen.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak controller] _ in controller?.editorResigned(id)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func show(at frame: NSRect) {
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        halo?.syncVisibility()
    }

    func hide() {
        panel.orderOut(nil)
        halo?.syncVisibility()
    }
}

// MARK: - Controller

final class NotesController {
    let store: NoteStore
    let settings: AppSettings
    private var bars: [NotesEdgeBar] = []
    private var editors: [UUID: NoteWindow] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private let previewPanel: NotesPanel
    private let previewTone = GlowTone()
    private var previewHalo: GlowHalo?
    private var previewToken = 0
    private var previewID: UUID?
    private var previewNote: Note?
    private var hideWork: DispatchWorkItem?
    private var listPanel: NotesPanel?
    private var listHalo: GlowHalo?
    private let listModel = NotesListModel()
    private let listTone = GlowTone()
    private var toastPanel: NotesPanel?
    private var toastHalo: GlowHalo?
    private let toastTone = GlowTone()

    init(store: NoteStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        previewPanel = NotesPanel(size: NSSize(width: NotePreviewView.width, height: 120), allowsKey: false, fullScreen: true)
        previewPanel.ignoresMouseEvents = true
        previewPanel.alphaValue = 0
        previewHalo = GlowHalo(around: previewPanel, kind: .panel, cornerRadius: NotePreviewView.cornerRadius, tone: previewTone)

        let layout: [AnyPublisher<Void, Never>] = [
            settings.$notesEnabled.map { _ in }.eraseToAnyPublisher(),
            settings.$notesEdge.map { _ in }.eraseToAnyPublisher(),
            settings.$notesPlacement.map { _ in }.eraseToAnyPublisher(),
            settings.$notesOnAllScreens.map { _ in }.eraseToAnyPublisher(),
            settings.$notesShowInFullScreen.map { _ in }.eraseToAnyPublisher(),
            settings.$hideDuringScreenSharing.map { _ in }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(layout)
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &subscriptions)
        // The bar grows and shrinks with the notes.
        store.$notes.map { $0.lazy.filter { !$0.archived }.count }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.bars.forEach { $0.refit() } }
            .store(in: &subscriptions)
    }

    var isEnabled: Bool { settings.notesEnabled }

    private func rebuild() {
        bars.removeAll()
        guard settings.notesEnabled else {
            closeAllEditors()
            return
        }
        if !settings.notesWelcomeAdded {
            settings.notesWelcomeAdded = true
            if store.notes.isEmpty { store.addWelcomeNotes() }
        }
        let screens = settings.notesOnAllScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        bars = screens.map { NotesEdgeBar(controller: self, screen: $0) }
    }

    func start() { rebuild() }

    func flush() { store.flush() }

    private func bar(on screen: NSScreen) -> NotesEdgeBar? { bars.first { $0.screen == screen } ?? bars.first }

    func hasEditor(on bar: NotesEdgeBar) -> Bool { editors.values.contains { $0.bar === bar && !(store.note($0.id)?.pinned ?? false) } }

    // MARK: Preview

    func tabHover(_ note: Note?, bar: NotesEdgeBar) {
        if bar.model.hovered != note?.id { bar.model.hovered = note?.id }
        guard let note, !hasEditor(on: bar) else { hidePreviewSoon(); return }
        hideWork?.cancel()
        hideWork = nil
        showPreview(note, beside: bar)
    }

    /// The preview goes a moment after the pointer leaves a tab, so crossing to the next one
    /// (or the gap between them) moves it instead of blinking it.
    private func hidePreviewSoon() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hidePreview() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func showPreview(_ note: Note, beside bar: NotesEdgeBar) {
        if previewID == note.id, previewPanel.isVisible, previewPanel.alphaValue > 0.5, let shown = previewNote, shown == note { return }
        previewNote = note
        previewToken += 1
        let wasShown = previewPanel.isVisible && previewPanel.alphaValue > 0.5
        previewID = note.id
        let hosting = rounded(NotePreviewView(note: note, tone: previewTone, settings: settings), radius: NotePreviewView.cornerRadius)
        previewPanel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: NotePreviewView.width, height: min(hosting.fittingSize.height, 460))
        let barFrame = bar.frame()
        let visible = bar.screen.visibleFrame
        let x = settings.notesEdge == .right ? barFrame.minX - size.width - 10 : barFrame.maxX + 10
        let y = min(max(bar.stripMidY - size.height / 2, visible.minY + 10), visible.maxY - size.height - 10)
        previewPanel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        previewPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        previewPanel.orderFrontRegardless()
        previewHalo?.syncVisibility()
        if wasShown { previewPanel.alphaValue = 1 } else {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; previewPanel.animator().alphaValue = 1 }
        }
    }

    private func hidePreview() {
        hideWork?.cancel()
        hideWork = nil
        previewID = nil
        let token = previewToken
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; previewPanel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, token == self.previewToken else { return }
            self.previewPanel.orderOut(nil)
            self.previewHalo?.syncVisibility()
        }
    }

    // MARK: Editing

    /// Opens a note beside its bar. Another note that isn't kept on screen closes first.
    func open(_ id: UUID, from bar: NotesEdgeBar?) {
        guard store.note(id) != nil else { return }
        hidePreview()
        listPanel?.orderOut(nil)
        for other in editors.keys where other != id && !(store.note(other)?.pinned ?? false) { closeEditor(other) }
        if let existing = editors[id] {
            existing.panel.makeKeyAndOrderFront(nil)
            return
        }
        let bar = bar ?? self.bar(on: screenUnderPointer())
        let window = NoteWindow(id: id, controller: self, bar: bar)
        editors[id] = window
        window.show(at: editorFrame(beside: bar))
        bar?.model.current = id
        bar?.setOpen(true)
    }

    private func editorFrame(beside bar: NotesEdgeBar?) -> NSRect {
        let size = NoteEditorView.size
        guard let bar else {
            let v = screenUnderPointer().visibleFrame
            return NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        }
        let barFrame = bar.frame()
        let visible = bar.screen.visibleFrame
        let x = settings.notesEdge == .right ? barFrame.minX - size.width - 10 : barFrame.maxX + 10
        let y = min(max(bar.stripMidY - size.height / 2, visible.minY + 10), visible.maxY - size.height - 10)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func newNote(from bar: NotesEdgeBar? = nil) {
        guard settings.notesEnabled else { return }
        let bar = bar ?? self.bar(on: screenUnderPointer())
        let note = store.add()
        open(note.id, from: bar)
    }

    func closeEditor(_ id: UUID) {
        guard let window = editors.removeValue(forKey: id) else { return }
        window.hide()
        for bar in bars where bar.model.current == id { bar.model.current = nil }
        store.removeEmpty(except: Set(editors.keys))
        bars.forEach { $0.closeSoon() }
    }

    private func closeAllEditors() {
        for id in Array(editors.keys) { closeEditor(id) }
    }

    func editorResigned(_ id: UUID) {
        guard editors[id] != nil, store.note(id)?.pinned != true else { return }
        // Moving to another note's window or to the list closes this one through them.
        closeEditor(id)
    }

    func togglePin(_ id: UUID) {
        guard let note = store.note(id) else { return }
        store.setPinned(id, !note.pinned)
    }

    /// Pinning from a tab puts the note on the screen at once; unpinning one that is shown lets it close as any other.
    func togglePin(_ id: UUID, from bar: NotesEdgeBar) {
        togglePin(id)
        if store.note(id)?.pinned == true { open(id, from: bar) }
    }

    func archive(_ id: UUID) {
        closeEditor(id)
        store.setArchived(id, true)
    }

    func copyText(_ id: UUID) {
        guard let text = store.note(id)?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func delete(_ id: UUID) {
        closeEditor(id)
        remove(id)
    }

    /// Deletes a note and offers Undo for a few seconds.
    func remove(_ id: UUID) {
        guard let note = store.delete(id) else { return }
        showToast("Note deleted") { [weak self] in
            self?.store.restore(note)
            self?.hideToast()
        }
    }

    // MARK: Save as Note

    /// Makes a note of text taken from the shelf, and shows it among the tabs for a moment.
    func saveAsNote(_ text: String) {
        guard settings.notesEnabled else { return }
        let note = store.add(text: text)
        bars.forEach { $0.flash(note.id) }
    }

    // MARK: List

    func showList(_ scope: NotesListModel.Scope) {
        guard settings.notesEnabled else { return }
        listModel.scope = scope
        listModel.query = ""
        hidePreview()
        if listPanel == nil {
            let panel = NotesPanel(size: NotesListView.size, allowsKey: true, fullScreen: true)
            panel.isMovableByWindowBackground = true
            panel.onEscape = { [weak self] in self?.listPanel?.orderOut(nil) }
            panel.contentView = rounded(NotesListView(
                store: store, model: listModel, tone: listTone,
                onOpen: { [weak self] note in
                    guard let self else { return }
                    if note.archived { self.store.setArchived(note.id, false) }
                    self.open(note.id, from: self.bar(on: screenUnderPointer()))
                },
                onNew: { [weak self] in self?.listPanel?.orderOut(nil); self?.newNote() },
                onDelete: { [weak self] note in self?.remove(note.id) },
                onClose: { [weak self] in self?.listPanel?.orderOut(nil) }), radius: NotesListView.cornerRadius)
            listHalo = GlowHalo(around: panel, kind: .panel, cornerRadius: NotesListView.cornerRadius, tone: listTone)
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
                [weak self] _ in self?.listPanel?.orderOut(nil); self?.listHalo?.syncVisibility()
            }
            listPanel = panel
        }
        guard let panel = listPanel else { return }
        let v = screenUnderPointer().visibleFrame
        let size = NotesListView.size
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        listHalo?.syncVisibility()
    }

    // MARK: Toast

    private func showToast(_ message: String, undo: @escaping () -> Void) {
        let panel = toastPanel ?? NotesPanel(size: NSSize(width: 230, height: NotesToastView.height), allowsKey: false, fullScreen: true)
        toastPanel = panel
        let hosting = rounded(NotesToastView(message: message, undo: undo, tone: toastTone), radius: NotesToastView.height / 2)
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: hosting.fittingSize.width, height: NotesToastView.height)
        let v = screenUnderPointer().visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 28, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        if toastHalo == nil { toastHalo = GlowHalo(around: panel, kind: .panel, cornerRadius: NotesToastView.height / 2, tone: toastTone) }
        toastHalo?.cornerRadius = NotesToastView.height / 2
        toastHalo?.syncVisibility()
        let stamp = Date()
        toastStamp = stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.toastStamp == stamp { self?.hideToast() }
        }
    }

    private var toastStamp = Date.distantPast

    private func hideToast() {
        toastPanel?.orderOut(nil)
        toastHalo?.syncVisibility()
    }
}
