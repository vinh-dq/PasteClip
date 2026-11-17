import AppKit
import Combine
import PasteClipCore
import PasteClipSystem
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app,
/// so the previously focused app stays frontmost and receives the paste.
final class ShelfPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the Dock, which it covers at the bottom of the screen. Set after isFloatingPanel,
        // which resets the level to .floating (below the Dock).
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}

final class ShelfController {
    private let panel = ShelfPanel()
    private let state: ShelfState
    private let store: ClipStore
    private let settings: AppSettings
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var scrollMonitor: Any?
    private let height: CGFloat = 340
    /// Gap between the floating shelf and the screen edges.
    private let margin: CGFloat = 10
    private let popup: PreviewPopupController
    private var subscriptions = Set<AnyCancellable>()

    var onPasted: () -> Void = {}
    var onTranslate: (ClipItem, String?) -> Void = { _, _ in }
    /// Translates clips: their text, or the text in images.
    var onTranslateItems: ([ClipItem]) -> Void = { _ in }
    var onEditImage: (ClipItem) -> Void = { _ in }
    var onFloatImages: ([ClipItem]) -> Void = { _ in }
    /// Floats images with their text translated in place.
    var onTranslateImages: ([ClipItem]) -> Void = { _ in }

    var isVisible: Bool { panel.isVisible }

    init(store: ClipStore, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        state = ShelfState(store: store)
        popup = PreviewPopupController(state: state, store: store)
        state.onPaste = { [weak self] item, plain in self?.paste([item], plainText: plain) }
        state.onPasteMany = { [weak self] items, plain in self?.paste(items, plainText: plain) }
        state.onTranslate = { [weak self] item, target in
            guard let self else { return }
            self.hide()
            self.onTranslate(item, target)
        }
        state.onEditImage = { [weak self] item in self?.editImage(item) }
        state.onFloatImages = { [weak self] items in self?.floatImages(items) }
        state.onTranslateImages = { [weak self] items in self?.translateImages(items) }
        state.onOpenSettings = { [weak self] in
            self?.hide()
            openSettings()
        }
        panel.contentView = HostingView(rootView: ShelfView(state: state, store: store, settings: settings))
        observePreview()
    }

    // MARK: - Preview popup

    private func observePreview() {
        Publishers.CombineLatest3(state.$previewing, state.selectionModel.$index, state.cardFrame.$frame)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] previewing, _, frame in self?.updatePopup(previewing: previewing, cardFrame: frame) }
            .store(in: &subscriptions)

        // The popup takes keyboard focus while editing, and hands it back afterwards.
        state.$editing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] editing in
                guard let self, self.panel.isVisible else { return }
                if editing { self.popup.panel.makeKey() } else { self.panel.makeKey() }
            }
            .store(in: &subscriptions)

        // Close the popup if its clip goes away.
        store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.state.previewing, self.state.selectedItem == nil else { return }
                self.state.closePreview()
            }
            .store(in: &subscriptions)
    }

    private func updatePopup(previewing: Bool, cardFrame: CGRect?) {
        guard previewing, panel.isVisible, let cardFrame, let item = state.selectedItem else {
            if popup.isKey { panel.makeKey() }
            popup.hide()
            return
        }
        popup.show(item, over: cardFrame, in: panel,
                   sharingType: settings.hideDuringScreenSharing ? .none : .readOnly)
        // ⌘E on the shelf opens the popup already editing; it can only take focus once shown.
        if state.editing, !popup.isKey { popup.panel.makeKey() }
    }

    func toggle() { isVisible ? hide() : show() }

    func showPreview() { state.togglePreview() }

    func show() {
        state.reset()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        // The whole screen, so the shelf sits at the bottom edge over the Dock (the panel's level is
        // above the Dock's); at the top it stays below the menu bar.
        let frame = screen.frame
        let top = settings.shelfEdge == .top
        let target = NSRect(x: frame.minX + margin, y: top ? screen.visibleFrame.maxY - height - margin : frame.minY + margin,
                            width: frame.width - margin * 2, height: height)
        // Only the window's opacity animates. Animating its frame would re-layout the
        // whole SwiftUI view on every frame, which is what made opening feel slow.
        if panel.frame != target { panel.setFrame(target, display: false) }
        panel.alphaValue = 0
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitors()
        state.closePreview()
        popup.hide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }

    private func editImage(_ item: ClipItem) {
        guard item.isImage else { return NSSound.beep() }
        hide()
        onEditImage(item)
    }

    /// Floats the selected images; beeps if none of the selected clips is an image.
    private func floatImages(_ items: [ClipItem]) {
        let images = items.filter(\.isImage)
        guard !images.isEmpty else { return NSSound.beep() }
        hide()
        onFloatImages(images)
    }

    /// For the float shortcut while the shelf is open.
    func floatSelection() { floatImages(state.selectedItems) }

    /// The translate-image key (⌃⌥Space): the selected images, floated and translated where their text is.
    private func translateImages(_ items: [ClipItem]) {
        let images = items.filter(\.isImage)
        guard !images.isEmpty else { return NSSound.beep() }
        hide()
        onTranslateImages(images)
    }

    private func paste(_ items: [ClipItem], plainText: Bool) {
        guard !items.isEmpty else { return }
        store.copyToPasteboard(items, plainText: plainText || settings.alwaysPlainText)
        hide()
        guard settings.pasteMode == .frontApp else { return }
        // Without Accessibility permission macOS drops the ⌘V. Ask, rather than failing silently;
        // the clip is already on the clipboard either way.
        guard Paster.isTrusted else { Paster.requestTrust(); return }
        Paster.pasteIntoFrontApp(after: 0.2)
        onPasted()
    }

    // MARK: - Keyboard

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow || self.popup.isKey else { return event }
            return self.handle(event) ? nil : event
        }
        // Close when the user clicks anywhere outside the shelf.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        // Close the popup when the user clicks the shelf (or another card) outside it, keeping any edit.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.state.previewing, event.window !== self.popup.panel else { return event }
            self.state.commitEdit?()
            self.state.closePreview()
            return event
        }
        // The card row scrolls a little faster than a plain scroll view. The popup keeps normal speed.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.panel { Self.scrollFurther(for: event, in: self.panel) }
            return event
        }
    }

    /// How far the card row scrolls compared with a plain scroll view.
    private static let scrollSpeed: CGFloat = 1.5

    /// Adds the extra distance to the horizontal scroll view under the pointer. The event itself is
    /// left alone: the scroll view follows the original trackpad gesture, and a rebuilt copy of the
    /// event made it ignore most of the gesture.
    private static func scrollFurther(for event: NSEvent, in window: NSWindow) {
        guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return }
        var view: NSView? = hit
        while let v = view, !(v is NSScrollView) { view = v.superview }
        guard let scroll = view as? NSScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxX = document.frame.width - clip.bounds.width
        guard maxX > 0 else { return }
        // A mouse wheel scrolls the row with its vertical wheel, in lines rather than points.
        var delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= scroll.horizontalLineScroll }
        var origin = clip.bounds.origin
        let x = min(max(origin.x - delta * (scrollSpeed - 1), 0), maxX)
        guard x != origin.x else { return }
        origin.x = x
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        localClickMonitor = nil
        scrollMonitor = nil
    }

    /// Returns true when the key was handled and shouldn't reach the focused text field.
    private func handle(_ event: NSEvent) -> Bool {
        let typing = state.renamingID != nil || state.composing || state.textInputActive
        if typing, performEditCommand(event) { return true }
        // Renaming a card: every key goes to its title field (Return saves, Esc cancels).
        if state.renamingID != nil { return false }
        if state.composing {
            if event.keyCode == 53 { state.closePreview(); return true } // Esc
            return false
        }
        return state.previewing ? handlePreviewKey(event) : handleShelfKey(event)
    }

    /// ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V and ⌘A for the focused text field. The app has no Edit menu (it lives
    /// in the menu bar only), so nothing else turns these keys into actions.
    private func performEditCommand(_ event: NSEvent) -> Bool {
        let f = flags(event)
        guard f == .command || f == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector
        switch (key, f.contains(.shift)) {
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    private func flags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    private func isHeld(_ key: ModifierKey, in event: NSEvent) -> Bool {
        flags(event).contains(Self.flag(key))
    }

    private static func flag(_ key: ModifierKey) -> NSEvent.ModifierFlags {
        switch key {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }

    private func matches(_ combo: KeyCombo?, _ event: NSEvent) -> Bool {
        guard let combo, Int(event.keyCode) == combo.keyCode else { return false }
        var mods = 0
        let f = flags(event)
        if f.contains(.command) { mods |= KeyCombo.command }
        if f.contains(.shift) { mods |= KeyCombo.shift }
        if f.contains(.option) { mods |= KeyCombo.option }
        if f.contains(.control) { mods |= KeyCombo.control }
        return mods == combo.modifiers
    }

    /// Key codes of 1…9 on the number row.
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        if event.keyCode == 53 {                                       // Esc
            if state.editing { state.editing = false } else { state.closePreview() }
            return true
        }
        // Let typing reach the title field or the text editor.
        if state.textInputActive { return false }

        if matches(settings.translateImageKey, event) {
            translateImages(state.selectedItem.map { [$0] } ?? [])
            return true
        }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 49: state.closePreview(); return true                    // Space
        case 123: state.move(-1); return true                         // ←
        case 124: state.move(1); return true                          // →
        case 36, 76:                                                   // Return
            if let item = state.selectedItem { paste([item], plainText: isHeld(settings.plainTextModifier, in: event)) }
            return true
        default: break
        }
        if cmd, chars == "y" { state.closePreview(); return true }
        if matches(settings.floatImageKey, event), let item = state.selectedItem { floatImages([item]); return true }
        if cmd, chars == "e", let item = state.selectedItem {
            if item.isTextual { state.editing = true } else { editImage(item) }
            return true
        }
        if cmd, chars == "p", let item = state.selectedItem { store.togglePin(item); return true }
        // Swallow plain typing so it doesn't land in the hidden search field.
        return !cmd
    }

    /// For the translate shortcut while the shelf is open: closes it and hands over the selected
    /// clips with text, or images, whose text is read if it hasn't been yet.
    func translateSelection() {
        let items = state.selectedItems.filter { $0.isImage || $0.translatableText?.isEmpty == false }
        guard !items.isEmpty else { return NSSound.beep() }
        hide()
        onTranslateItems(items)
    }

    private func handleShelfKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let plain = isHeld(settings.plainTextModifier, in: event)

        if matches(settings.nextPinboardKey, event) { state.cycleBoard(1); return true }
        if matches(settings.previousPinboardKey, event) { state.cycleBoard(-1); return true }
        if matches(settings.floatImageKey, event) { floatImages(state.selectedItems); return true }
        if matches(settings.translateImageKey, event) { translateImages(state.selectedItems); return true }

        // Quick paste: modifier + 1…9 (plus the plain-text modifier, if held).
        if let n = Self.digitKeys.firstIndex(of: event.keyCode), isHeld(settings.quickPasteModifier, in: event) {
            let items = state.visible
            if items.indices.contains(n) { paste([items[n]], plainText: plain && settings.plainTextModifier != settings.quickPasteModifier) }
            return true
        }

        let picking = !state.selectionModel.picked.isEmpty
        switch event.keyCode {
        case 53:                                                       // Esc: clear a selection, then close
            if picking { state.selectionModel.clearPicks() } else { hide() }
            return true
        case 123 where shift && !cmd: state.extend(-1); return true    // ⇧←
        case 124 where shift && !cmd: state.extend(1); return true     // ⇧→
        case 123: state.move(-1); return true                         // ←
        case 124: state.move(1); return true                          // →
        case 48: state.cycleBoard(shift ? -1 : 1); return true        // Tab / ⇧Tab
        case 49 where state.query.text.isEmpty:                       // Space with an empty search
            state.togglePreview()
            return true
        case 36, 76:                                                   // Return / Enter
            paste(state.selectedItems, plainText: plain)
            return true
        case 51 where cmd:                                             // ⌘⌫
            store.delete(state.selectedItems)
            state.selectionModel.clearPicks()
            return true
        default: break
        }

        guard cmd, let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch chars {
        case "n":
            state.startComposing()
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        case "y":
            state.togglePreview()
            return true
        case "e":
            if state.selectedItem?.isTextual == true {
                state.previewing = true
                state.editing = true
            } else if let item = state.selectedItem {
                editImage(item)
            }
            return true
        case "p":
            if let item = state.selectedItem { store.togglePin(item) }
            return true
        case "c":
            let items = state.selectedItems
            if !items.isEmpty { store.copyToPasteboard(items); hide() }
            return true
        case "a" where state.query.text.isEmpty:
            state.selectionModel.selectAll(state.visible)
            return true
        case "f":
            state.focusToken = UUID()
            return true
        case "i":
            state.toggleImagesOnly()
            return true
        case ",":
            state.onOpenSettings()
            return true
        default:
            return false
        }
    }
}
