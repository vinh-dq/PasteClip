import AppKit
import Combine
import ImageIO
import PasteClipCore
import SwiftUI

/// Opens image clips for marking up, one window per clip. Esc, Return or Done saves the result
/// as a new clip and closes; ⌥Esc discards.
final class ImageEditors {
    private let store: ClipStore
    private let settings: AppSettings
    private var open: [UUID: ImageEditorController] = [:]
    /// Floats an image on the screen (the edited copy, from the editor's Float button).
    var onFloat: (ClipItem) -> Void = { _ in }

    init(store: ClipStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /// For the float shortcut, which reaches PasteClip before the editor's own keys: floats the
    /// image in the editor in front, if one is. False when no editor is in front.
    func floatFromFrontEditor() -> Bool {
        guard let editor = open.values.first(where: \.isKey) else { return false }
        editor.finish(.float)
        return true
    }

    func edit(_ item: ClipItem) {
        if let controller = open[item.id] { return controller.show() }
        guard let url = store.pictureURL(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return NSSound.beep() }
        let controller = ImageEditorController(item: item, image: image, store: store, settings: settings)
        controller.onFloat = { [weak self] in self?.onFloat($0) }
        controller.onClose = { [weak self] in self?.open[item.id] = nil }
        open[item.id] = controller
        controller.show()
    }
}

// MARK: - Window

final class ImageEditorController: NSObject, NSWindowDelegate {
    enum Finish { case save, copy, float, discard }

    private let item: ClipItem
    private let store: ClipStore
    private let settings: AppSettings
    private let model: ImageEditorModel
    private let canvas: MarkupCanvasView
    private let window: NSWindow
    private var keyMonitor: Any?
    private var closing = false
    /// The app that was in front, which gets the focus back when the editor closes.
    private var previousApp: NSRunningApplication?
    var onFloat: (ClipItem) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(item: ClipItem, image: CGImage, store: ClipStore, settings: AppSettings) {
        self.item = item
        self.store = store
        self.settings = settings
        model = ImageEditorModel(renderer: MarkupRenderer(image: image))
        canvas = MarkupCanvasView(model: model)
        window = ImageEditorPanel(contentRect: Self.initialFrame(for: image))
        super.init()
        window.title = item.title ?? "Edit Image"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 860, height: 540)
        window.delegate = self
        window.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        let view = ImageEditorView(model: model, settings: settings, canvas: canvas) { [weak self] in self?.finish($0) }
        window.contentView = NSHostingView(rootView: view)
        window.center()
    }

    /// The image at its size on screen, with room for the bars, within most of the screen.
    private static func initialFrame(for image: CGImage) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let scale = screen.backingScaleFactor
        let visible = screen.visibleFrame
        let width = min(max(CGFloat(image.width) / scale + 80, 860), visible.width * 0.85)
        let height = min(max(CGFloat(image.height) / scale + 150, 540), visible.height * 0.85)
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }

    var isKey: Bool { window.isKeyWindow }

    func show() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // In front and taking keys at once, without waiting for macOS to bring PasteClip forward.
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvas)
        installKeyMonitor()
    }

    // MARK: Finishing

    func finish(_ action: Finish) {
        canvas.endTextEditing()
        if action == .discard {
            guard model.hasChanges else { return close() }
            let alert = NSAlert()
            alert.messageText = "Discard your changes?"
            alert.informativeText = "The original clip stays as it was."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.close() }
            }
            return
        }
        var result = store.item(withID: item.id) ?? item
        if model.hasChanges {
            // The marked-up image is a new clip; the original is left alone.
            guard let image = model.renderer.render(model.marks, crop: model.crop),
                  let png = MarkupRenderer.pngData(image),
                  // Uncropped, it still floats over the spot it was taken from.
                  let saved = store.addImage(png, title: item.title, screenFrame: model.crop == nil ? item.screenFrame : nil)
            else { return NSSound.beep() }
            result = saved
        }
        switch action {
        case .copy: store.copyToPasteboard(result)
        case .float: onFloat(result)
        case .save, .discard: break
        }
        close()
    }

    private func close() {
        closing = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window.close()
        onClose()
        // Back to the app you were in if PasteClip came forward (a click on the discard question
        // can bring it), unless another PasteClip window is still open.
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if NSApp.isActive, !others { previousApp?.activate() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        // The close button saves, like Esc.
        finish(.save)
        return false
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil else { return event }
            // Typing in a text mark: its field handles Return and Esc itself.
            if self.window.firstResponder is NSTextView { return self.performEditCommand(event) ? nil : event }
            return self.handle(event) ? nil : event
        }
    }

    /// ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z in a text mark. PasteClip stays in the background while the editor
    /// is open, so the Edit menu's key equivalents don't reach the field.
    private func performEditCommand(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
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

    private func handle(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if ShortcutMatch.matches(settings.floatImageKey, event) { finish(.float); return true }
        switch event.keyCode {
        case 53:                                                       // Esc
            if f.contains(.option) { finish(.discard) } else if model.tool == .crop { model.cancelCrop() } else { finish(.save) }
            return true
        case 36, 76:                                                   // Return
            if model.tool == .crop { model.applyCrop() } else { finish(.save) }
            return true
        case 51, 117:                                                  // ⌫, ⌦
            model.deleteSelected()
            return true
        case 123, 124, 125, 126:                                       // Arrows nudge the selected mark
            let step = (f.contains(.shift) ? 10 : 1) / canvas.scale
            let d: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                               125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][event.keyCode]!
            model.nudgeSelected(by: d)
            return true
        default: break
        }
        if f == .command {
            switch chars {
            case "z": model.undo()
            case "c": finish(.copy)
            case "s": finish(.save)
            case "w": finish(.save)
            case "=", "+": model.zoom(by: 1.25)
            case "-": model.zoom(by: 0.8)
            case "0": model.setZoom(1)
            default: return false
            }
            return true
        }
        if f == [.command, .shift], chars == "z" { model.redo(); return true }
        guard f.isEmpty || f == .shift else { return false }
        if let tool = MarkupTool.allCases.first(where: { $0.key.lowercased() == chars }) { model.choose(tool); return true }
        if let n = Int(chars), (1...MarkupStyle.colors.count).contains(n) { model.setColor(n - 1); return true }
        switch chars {
        case "[": model.setSize(max(model.size - 1, 0))
        case "]": model.setSize(min(model.size + 1, 2))
        case "f": model.toggleFill()
        default: return false
        }
        return true
    }
}

/// The editor's window. It takes keys without bringing PasteClip forward, like the shelf, so it
/// opens in front at once rather than waiting for macOS to switch apps.
final class ImageEditorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.fullScreenAuxiliary]
        // Clear, so the glass behind the canvas shows the desktop through it.
        isOpaque = false
        backgroundColor = .clear
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Compares a key event with a shortcut set in Settings.
enum ShortcutMatch {
    static func matches(_ combo: KeyCombo?, _ event: NSEvent) -> Bool {
        guard let combo, Int(event.keyCode) == combo.keyCode else { return false }
        let f = event.modifierFlags
        var mods = 0
        if f.contains(.command) { mods |= KeyCombo.command }
        if f.contains(.shift) { mods |= KeyCombo.shift }
        if f.contains(.option) { mods |= KeyCombo.option }
        if f.contains(.control) { mods |= KeyCombo.control }
        return mods == combo.modifiers
    }
}

extension View {
    /// Shows a shortcut from Settings next to a menu item, when it's a single character or Space.
    @ViewBuilder
    func keyboardShortcut(_ combo: KeyCombo?) -> some View {
        if let combo, combo.keyName == "Space" {
            keyboardShortcut(.space, modifiers: Self.modifiers(of: combo))
        } else if let combo, combo.keyName.count == 1, let key = combo.keyName.lowercased().first {
            keyboardShortcut(KeyEquivalent(key), modifiers: Self.modifiers(of: combo))
        } else {
            self
        }
    }

    private static func modifiers(of combo: KeyCombo) -> EventModifiers {
        var modifiers: EventModifiers = []
        if combo.modifiers & KeyCombo.command != 0 { modifiers.insert(.command) }
        if combo.modifiers & KeyCombo.shift != 0 { modifiers.insert(.shift) }
        if combo.modifiers & KeyCombo.option != 0 { modifiers.insert(.option) }
        if combo.modifiers & KeyCombo.control != 0 { modifiers.insert(.control) }
        return modifiers
    }
}

// MARK: - Model

final class ImageEditorModel: ObservableObject {
    struct Snapshot: Equatable {
        var marks: [Markup]
        var crop: CGRect?
    }

    let renderer: MarkupRenderer
    @Published var marks: [Markup] = []
    /// The part of the image kept, in pixels; nil keeps all of it.
    @Published var crop: CGRect?
    @Published private(set) var tool: MarkupTool = .arrow
    @Published private(set) var color = 0
    @Published private(set) var size = 1
    @Published private(set) var filled = false
    @Published var selectedID: UUID?
    /// The crop being drawn while the crop tool is on.
    @Published var cropDraft: CGRect?
    /// The text mark being typed, which the canvas hides while its field is showing.
    @Published var editingTextID: UUID?
    /// Zoom on top of fitting the image in the window.
    @Published private(set) var zoom: CGFloat = 1
    /// Screen points per image pixel when fitted; set by the canvas, for the zoom label.
    @Published var fitScale: CGFloat = 1
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [Snapshot] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [Snapshot] = [] { didSet { canRedo = !redoStack.isEmpty } }
    private var pending: Snapshot?
    private var toolBeforeCrop: MarkupTool = .arrow

    init(renderer: MarkupRenderer) {
        self.renderer = renderer
    }

    var hasChanges: Bool { !marks.isEmpty || crop != nil }

    var selected: Markup? { selectedID.flatMap { id in marks.first { $0.id == id } } }

    /// The part of the image on screen: all of it while cropping, so the crop can grow again.
    var displayRect: CGRect { tool == .crop ? renderer.bounds : (crop ?? renderer.bounds) }

    var zoomLabel: String { zoom == 1 ? "Fit" : "\(Int((fitScale * zoom * 100).rounded()))%" }

    var nextNumber: Int { (marks.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    // MARK: Undo

    private var snapshot: Snapshot { Snapshot(marks: marks, crop: crop) }

    /// Starts a change made over several events, such as dragging a mark; `endChange` records it.
    func beginChange() {
        if pending == nil { pending = snapshot }
    }

    func endChange() {
        guard let before = pending else { return }
        pending = nil
        guard before != snapshot else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }

    /// A change made at once. Inside a change already started, it becomes part of that one.
    func change(_ body: () -> Void) {
        if pending != nil { return body() }
        beginChange()
        body()
        endChange()
    }

    func undo() {
        guard pending == nil, let last = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(snapshot)
        restore(last)
    }

    func redo() {
        guard pending == nil, let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        marks = snapshot.marks
        crop = snapshot.crop
        if selected == nil { selectedID = nil }
        if tool == .crop { cropDraft = crop ?? renderer.bounds }
    }

    // MARK: Tools and style

    func choose(_ tool: MarkupTool) {
        guard tool != self.tool else { return }
        if tool == .crop {
            toolBeforeCrop = self.tool
            cropDraft = crop ?? renderer.bounds
            selectedID = nil
        } else {
            cropDraft = nil
        }
        if tool != .select, let selected, selected.kind != tool.kind { selectedID = nil }
        self.tool = tool
    }

    func applyCrop() {
        guard let draft = cropDraft?.integral.intersection(renderer.bounds), draft.width >= 2, draft.height >= 2 else { return }
        change { crop = draft == renderer.bounds ? nil : draft }
        setZoom(1)
        choose(toolBeforeCrop)
    }

    func cancelCrop() { choose(toolBeforeCrop) }

    /// Picks a colour, and gives it to the selected mark.
    func setColor(_ index: Int) {
        color = index
        updateSelected { $0.color = index }
    }

    func setSize(_ size: Int) {
        self.size = size
        updateSelected { $0.size = size }
    }

    func toggleFill() {
        filled.toggle()
        updateSelected { mark in
            if mark.kind == .rectangle || mark.kind == .ellipse { mark.filled = filled }
        }
    }

    private func updateSelected(_ body: (inout Markup) -> Void) {
        guard let id = selectedID, let i = marks.firstIndex(where: { $0.id == id }) else { return }
        change { body(&marks[i]) }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        change { marks.removeAll { $0.id == id } }
        selectedID = nil
    }

    func nudgeSelected(by d: CGVector) {
        guard let id = selectedID, let i = marks.firstIndex(where: { $0.id == id }) else { return }
        change { marks[i] = marks[i].moved(by: d) }
    }

    func zoom(by factor: CGFloat) { setZoom(zoom * factor) }

    /// Zoom between a quarter and eight times the fitted size. (Clamping in `didSet` would set
    /// the published value again from inside its own setter, over and over.)
    func setZoom(_ value: CGFloat) {
        let value = min(max(value, 0.25), 8)
        if value != zoom { zoom = value }
    }

    /// A new mark in the current colour, size and fill.
    func newMark(_ kind: Markup.Kind, at points: [CGPoint]) -> Markup {
        var mark = Markup(kind: kind, points: points, color: color, size: size,
                          filled: filled && (kind == .rectangle || kind == .ellipse))
        if kind == .step { mark.number = nextNumber }
        return mark
    }
}

// MARK: - Canvas

/// Shows the image with its marks and turns drags into marks. The image sits in a layer of its
/// own, so drawing a mark redraws only the marks.
final class MarkupCanvasView: NSView, NSTextFieldDelegate {
    private enum Drag {
        case drawing(start: CGPoint)
        case moving(id: UUID, last: CGPoint)
        case resizing(id: UUID, handle: Int)
        /// A text or number, from how it was and the area it covered when the drag began.
        case scaling(original: Markup, box: CGRect, handle: Int)
        case cropNew(start: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(handle: Int)
    }

    private let model: ImageEditorModel
    private var renderer: MarkupRenderer { model.renderer }
    private let imageHost = PassThroughView()
    private let imageLayer = CALayer()
    /// The image's shadow, on a layer of its own: the image itself is clipped to its rounded
    /// corners, which would clip a shadow of its own too.
    private let shadowLayer = CALayer()
    private let overlay = MarkupOverlay()
    private var subscription: AnyCancellable?
    private var drag: Drag?
    /// The mark being drawn, before it's added.
    private var draft: Markup?
    private var textField: NSTextField?
    private var pan = CGPoint.zero
    private(set) var scale: CGFloat = 1
    /// Where the top left of `model.displayRect` is, in the view.
    private var origin = CGPoint.zero
    /// Room kept clear for the bars over the canvas.
    private let insets = NSEdgeInsets(top: 66, left: 28, bottom: 72, right: 28)

    init(model: ImageEditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        imageHost.wantsLayer = true
        imageHost.layer?.masksToBounds = true
        imageHost.layer?.backgroundColor = NSColor.white.cgColor
        imageHost.layer?.cornerRadius = 8
        imageHost.layer?.cornerCurve = .continuous
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.28
        shadowLayer.shadowRadius = 9
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(shadowLayer)
        imageLayer.contents = model.renderer.image
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .nearest
        imageHost.layer?.addSublayer(imageLayer)
        addSubview(imageHost)
        overlay.canvas = self
        addSubview(overlay)
        subscription = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.modelChanged() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func modelChanged() {
        if model.zoom <= 1 { pan = .zero }
        if let id = model.editingTextID, let mark = model.marks.first(where: { $0.id == id }) { styleField(for: mark) }
        needsLayout = true
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let region = model.displayRect
        let available = CGRect(x: insets.left, y: insets.top, width: bounds.width - insets.left - insets.right,
                               height: bounds.height - insets.top - insets.bottom)
        let fit = max(min(available.width / region.width, available.height / region.height, 1), 0.01)
        if model.fitScale != fit { DispatchQueue.main.async { [model] in model.fitScale = fit } }
        scale = fit * model.zoom
        let size = CGSize(width: region.width * scale, height: region.height * scale)
        // Zoomed in, the image can be moved until its edge reaches the middle of the view.
        pan.x = min(max(pan.x, -size.width / 2), size.width / 2)
        pan.y = min(max(pan.y, -size.height / 2), size.height / 2)
        origin = CGPoint(x: (available.midX - size.width / 2 + pan.x).rounded(), y: (available.midY - size.height / 2 + pan.y).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageHost.frame = CGRect(origin: origin, size: size)
        shadowLayer.frame = imageHost.frame
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil)
        // The host isn't flipped, so the image is placed from its bottom edge.
        imageLayer.frame = CGRect(x: -region.minX * scale, y: -(renderer.size.height - region.maxY) * scale,
                                  width: renderer.size.width * scale, height: renderer.size.height * scale)
        CATransaction.commit()
        overlay.frame = bounds
        if let id = model.editingTextID, let mark = model.marks.first(where: { $0.id == id }) { styleField(for: mark) }
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let region = model.displayRect
        return CGPoint(x: origin.x + (p.x - region.minX) * scale, y: origin.y + (p.y - region.minY) * scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        let a = toView(r.origin)
        return CGRect(x: a.x, y: a.y, width: r.width * scale, height: r.height * scale)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        let region = model.displayRect
        return CGPoint(x: region.minX + (p.x - origin.x) / scale, y: region.minY + (p.y - origin.y) / scale)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(imageHost.frame, cursor: cursor)
    }

    // MARK: Drawing

    func drawMarks(in ctx: CGContext) {
        let region = model.displayRect
        ctx.saveGState()
        ctx.clip(to: imageHost.frame)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        var marks = model.marks.filter { $0.id != model.editingTextID }
        if let draft { marks.append(draft) }
        renderer.draw(marks, in: ctx)
        ctx.restoreGState()

        if let selected = model.selected, selected.id != model.editingTextID, drag.map(isDrawing) != true {
            drawSelection(of: selected, in: ctx)
        }
        if model.tool == .crop, let crop = model.cropDraft { drawCrop(crop, in: ctx) }
    }

    private func isDrawing(_ drag: Drag) -> Bool {
        if case .drawing = drag { return true }
        return false
    }

    private func drawSelection(of mark: Markup, in ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let box = toView(renderer.bounds(of: mark)).insetBy(dx: -4, dy: -4)
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
        for handle in handles(of: mark) { drawHandle(at: toView(handle), in: ctx) }
    }

    private func drawHandle(at p: CGPoint, in ctx: CGContext) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: r.insetBy(dx: 1, dy: 1))
    }

    private func drawCrop(_ crop: CGRect, in ctx: CGContext) {
        let area = toView(crop)
        ctx.saveGState()
        ctx.addRect(imageHost.frame)
        ctx.addRect(area)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.5)
        ctx.stroke(area)
        // Thirds, to help line things up.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let x = area.minX + area.width * CGFloat(i) / 3, y = area.minY + area.height * CGFloat(i) / 3
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: area.minY), CGPoint(x: x, y: area.maxY),
                                             CGPoint(x: area.minX, y: y), CGPoint(x: area.maxX, y: y)])
        }
        ctx.restoreGState()
        for corner in Self.corners(of: area) { drawHandle(at: corner, in: ctx) }
        // The size it will be.
        let label = NSAttributedString(string: "\(Int(crop.width)) × \(Int(crop.height))",
                                       attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white])
        let size = label.size()
        let pill = CGRect(x: area.midX - size.width / 2 - 8, y: max(area.minY - size.height - 14, imageHost.frame.minY + 6),
                          width: size.width + 16, height: size.height + 6)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3))
    }

    /// Corners clockwise from the top left.
    private static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Points that resize a mark when dragged, in image pixels.
    private func handles(of mark: Markup) -> [CGPoint] {
        if mark.kind.isBox { return Self.corners(of: MarkupRenderer.rect(mark.points)) }
        if mark.kind.isScalable { return Self.corners(of: renderer.bounds(of: mark)) }
        if mark.kind == .line || mark.kind == .arrow, let a = mark.points.first, let b = mark.points.last { return [a, b] }
        return []
    }

    /// The handle under a point in the view, within reach of the pointer.
    private func handle(at v: CGPoint, in points: [CGPoint]) -> Int? {
        points.indices.first { hypot(points[$0].x - v.x, points[$0].y - v.y) <= 8 }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        endTextEditing()
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        let p = toImage(v)
        let tolerance = 6 / scale

        switch model.tool {
        case .crop:
            let crop = model.cropDraft ?? renderer.bounds
            if let h = handle(at: v, in: Self.corners(of: toView(crop))) {
                drag = .cropResize(handle: h)
            } else if crop.contains(p) {
                drag = .cropMove(last: p)
            } else {
                drag = .cropNew(start: clamped(p))
            }
            return
        default: break
        }

        // The selected mark's handles and body come first, whatever the tool.
        if let selected = model.selected {
            if let h = handle(at: v, in: handles(of: selected).map(toView)) {
                model.beginChange()
                drag = selected.kind.isScalable ? .scaling(original: selected, box: renderer.bounds(of: selected), handle: h)
                                                : .resizing(id: selected.id, handle: h)
                return
            }
            if renderer.hitTest(selected, at: p, tolerance: tolerance) {
                if event.clickCount == 2, selected.kind == .text { return editText(selected) }
                model.beginChange()
                drag = .moving(id: selected.id, last: p)
                return
            }
        }

        switch model.tool {
        case .select:
            if let mark = renderer.mark(at: p, in: model.marks, tolerance: tolerance) {
                model.selectedID = mark.id
                if event.clickCount == 2, mark.kind == .text { return editText(mark) }
                model.beginChange()
                drag = .moving(id: mark.id, last: p)
            } else {
                model.selectedID = nil
            }
        case .text:
            if let mark = renderer.mark(at: p, in: model.marks, tolerance: tolerance), mark.kind == .text {
                model.selectedID = mark.id
                return editText(mark)
            }
            guard renderer.bounds.contains(p) else { return }
            let mark = model.newMark(.text, at: [p])
            model.beginChange()
            model.marks.append(mark)
            model.selectedID = mark.id
            startEditing(mark)
        case .step:
            if let mark = renderer.mark(at: p, in: model.marks, tolerance: tolerance), mark.kind == .step {
                model.selectedID = mark.id
                model.beginChange()
                drag = .moving(id: mark.id, last: p)
                return
            }
            // A number goes down at once, and can be dragged into place before letting go.
            let mark = model.newMark(.step, at: [p])
            model.beginChange()
            model.marks.append(mark)
            model.selectedID = mark.id
            drag = .moving(id: mark.id, last: p)
        default:
            guard let kind = model.tool.kind else { return }
            model.selectedID = nil
            draft = model.newMark(kind, at: kind == .pen || kind == .highlighter ? [p] : [p, p])
            drag = .drawing(start: p)
        }
        overlay.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .drawing(let start):
            guard var mark = draft else { return }
            if mark.kind == .pen || mark.kind == .highlighter {
                if shift {
                    mark.points = [start, p]
                } else if let last = mark.points.last, hypot(p.x - last.x, p.y - last.y) * scale >= 1.5 {
                    mark.points.append(p)
                }
            } else {
                mark.points = [start, shift ? Self.constrained(p, from: start, box: mark.kind.isBox) : p]
            }
            draft = mark
        case .moving(let id, let last):
            guard let i = model.marks.firstIndex(where: { $0.id == id }) else { return }
            model.marks[i] = model.marks[i].moved(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            drag = .moving(id: id, last: p)
        case .resizing(let id, let h):
            guard let i = model.marks.firstIndex(where: { $0.id == id }) else { return }
            var mark = model.marks[i]
            if mark.kind.isBox {
                let opposite = Self.corners(of: MarkupRenderer.rect(mark.points))[(h + 2) % 4]
                mark.points = [opposite, shift ? Self.constrained(p, from: opposite, box: true) : p]
            } else {
                let fixed = h == 0 ? mark.points[mark.points.count - 1] : mark.points[0]
                let moved = shift ? Self.constrained(p, from: fixed, box: false) : p
                mark.points = h == 0 ? [moved, fixed] : [fixed, moved]
            }
            model.marks[i] = mark
        case .scaling(let original, let box, let h):
            guard let i = model.marks.firstIndex(where: { $0.id == original.id }) else { return }
            model.marks[i] = renderer.scaled(original, box: box, handle: h, to: p)
        case .cropNew(let start):
            model.cropDraft = MarkupRenderer.rect([start, clamped(p)])
        case .cropMove(let last):
            guard var crop = model.cropDraft else { return }
            let bounds = renderer.bounds
            crop.origin.x = min(max(crop.minX + p.x - last.x, 0), bounds.width - crop.width)
            crop.origin.y = min(max(crop.minY + p.y - last.y, 0), bounds.height - crop.height)
            model.cropDraft = crop
            drag = .cropMove(last: p)
        case .cropResize(let h):
            guard let crop = model.cropDraft else { return }
            let opposite = Self.corners(of: crop)[(h + 2) % 4]
            model.cropDraft = MarkupRenderer.rect([opposite, clamped(p)])
        case nil:
            return
        }
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .drawing:
            if let mark = draft, isBigEnough(mark) {
                model.change { model.marks.append(mark) }
                model.selectedID = mark.id
            }
            draft = nil
        case .moving, .resizing, .scaling:
            model.endChange()
        case .cropNew, .cropResize:
            // A click without a drag keeps the crop there was.
            if let crop = model.cropDraft, crop.width * scale < 4 || crop.height * scale < 4 {
                model.cropDraft = model.crop ?? renderer.bounds
            }
        default: break
        }
        drag = nil
        overlay.needsDisplay = true
    }

    private func isBigEnough(_ mark: Markup) -> Bool {
        if mark.kind == .pen || mark.kind == .highlighter { return mark.points.count > 1 }
        let r = MarkupRenderer.rect(mark.points)
        return max(r.width, r.height) * scale >= 4
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), renderer.size.width), y: min(max(p.y, 0), renderer.size.height))
    }

    /// With ⇧: a square or circle for boxes, a line at a multiple of 45° otherwise.
    private static func constrained(_ p: CGPoint, from start: CGPoint, box: Bool) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        if box {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    // MARK: Zoom and scroll

    override func magnify(with event: NSEvent) {
        model.zoom(by: 1 + event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            model.zoom(by: 1 + max(min(delta, 0.3), -0.3))
            return
        }
        guard model.zoom > 1 else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        pan.x += event.scrollingDeltaX * factor
        pan.y += event.scrollingDeltaY * factor
        needsLayout = true
        overlay.needsDisplay = true
    }

    // MARK: Text

    private func editText(_ mark: Markup) {
        model.beginChange()
        startEditing(mark)
    }

    private func startEditing(_ mark: Markup) {
        model.editingTextID = mark.id
        let field = NSTextField(string: mark.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Type here"
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.delegate = self
        textField = field
        addSubview(field)
        styleField(for: mark)
        window?.makeFirstResponder(field)
        overlay.needsDisplay = true
    }

    private func styleField(for mark: Markup) {
        guard let field = textField else { return }
        let font = NSFont.systemFont(ofSize: renderer.fontSize(mark) * scale, weight: .bold)
        if field.font != font { field.font = font }
        field.textColor = MarkupStyle.nsColor(mark.color)
        field.sizeToFit()
        let origin = toView(mark.points.first ?? .zero)
        // The field's text starts a couple of points in from its frame.
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: max(field.frame.width + 12, 60), height: field.frame.height)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let id = model.editingTextID, let i = model.marks.firstIndex(where: { $0.id == id }) else { return }
        model.marks[i].text = textField?.stringValue ?? ""
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return and Esc finish the text; ⌥Return adds a line.
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { endTextEditing() }

    /// Keeps the text typed so far, or removes the mark if there is none.
    func endTextEditing() {
        guard let field = textField else { return }
        textField = nil
        let id = model.editingTextID
        model.editingTextID = nil
        if let id, let i = model.marks.firstIndex(where: { $0.id == id }) {
            let text = field.stringValue
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.marks.remove(at: i)
                model.selectedID = nil
            } else {
                model.marks[i].text = text
            }
        }
        model.endChange()
        field.delegate = nil
        field.removeFromSuperview()
        overlay.needsDisplay = true
    }
}

/// Draws the marks above the image layer; clicks go through to the canvas.
private final class MarkupOverlay: NSView {
    weak var canvas: MarkupCanvasView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawMarks(in: ctx)
    }
}

/// A view that clicks pass through.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Bars

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    @ObservedObject var settings: AppSettings
    let canvas: MarkupCanvasView
    let finish: (ImageEditorController.Finish) -> Void

    var body: some View {
        ZStack {
            CanvasHost(canvas: canvas)
            VStack(spacing: 0) {
                toolbar.padding(.top, 9)
                Spacer()
                bottomBar.padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        // Glass like the shelf and the preview, a little darker so the picture stands out.
        .background {
            ZStack {
                GlassBackground(cornerRadius: 0)
                Color.black.opacity(0.06)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Tools

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(MarkupTool.allCases) { tool in
                ToolButton(symbol: tool.symbol, key: tool.key, selected: model.tool == tool, help: "\(tool.title) (\(tool.key))") {
                    model.choose(tool)
                }
            }
            divider
            ForEach(MarkupStyle.colors.indices, id: \.self) { i in
                Button { model.setColor(i) } label: {
                    Circle()
                        .fill(Color(nsColor: MarkupStyle.nsColor(i)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == i ? 0.75 : 0), lineWidth: 1.5))
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Colour (\(i + 1))")
            }
            divider
            ForEach(0..<3) { size in
                Button { model.setSize(size) } label: {
                    Circle()
                        .fill(Color.primary.opacity(model.size == size ? 0.9 : 0.4))
                        .frame(width: [5, 8, 12][size], height: [5, 8, 12][size])
                        .frame(width: 24, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(model.size == size ? 0.1 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(MarkupStyle.sizeNames[size]) ([ and ])")
            }
            ToolButton(symbol: model.filled ? "square.fill" : "square", key: "F", selected: false,
                       help: "Fill rectangles and ellipses (F)") { model.toggleFill() }
                .opacity(fillable ? 1 : 0.4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glassCapsule()
    }

    private var fillable: Bool {
        model.tool.canFill || model.selected.map { $0.kind == .rectangle || $0.kind == .ellipse } == true
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 5)
    }

    // MARK: Actions

    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }.disabled(!model.canUndo)
                IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.redo() }.disabled(!model.canRedo)
                Button { model.setZoom(1) } label: {
                    Text(model.zoomLabel)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 40)
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fit in window (⌘0). Pinch or ⌘ scroll to zoom")
            }
            .padding(.horizontal, 6)
            .glassCapsule()

            Spacer()
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer()

            HStack(spacing: 4) {
                BarButton(title: "Discard", keys: "⌥Esc") { finish(.discard) }
                BarButton(title: "Copy", keys: "⌘C") { finish(.copy) }
                BarButton(title: "Float", keys: settings.floatImageKey?.display) { finish(.float) }
                BarButton(title: "Done", keys: "↩", prominent: true) { finish(.save) }
            }
            .padding(4)
            .glassCapsule()
        }
    }

    private var hint: String {
        if model.tool == .crop { return "Drag to crop · ↩ Apply · Esc Cancel" }
        if model.editingTextID != nil { return "↩ Done · ⌥↩ New line" }
        if model.selectedID != nil { return "Drag to move · ⌫ Delete · 1–6 Colour" }
        return "⇧ Straight lines and squares · Esc Save and close"
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: MarkupCanvasView
    func makeNSView(context: Context) -> MarkupCanvasView { canvas }
    func updateNSView(_ view: MarkupCanvasView, context: Context) {}
}

/// A tool with its key in the corner.
private struct ToolButton: View {
    let symbol: String
    let key: String
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 32, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    Text(key)
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.8))
                        .padding(.trailing, 3)
                        .padding(.bottom, 2)
                }
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}

/// A text button with its shortcut beside the title.
struct BarButton: View {
    let title: String
    var keys: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: prominent ? .semibold : .medium))
                if let keys {
                    Text(keys)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .opacity(0.55)
                }
            }
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// A shortcut shown small next to what it does.
struct KeyHint: View {
    let keys: String
    var onAccent = false

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(onAccent ? Color.white.opacity(0.8) : Color.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(onAccent ? Color.white.opacity(0.4) : Color.secondary.opacity(0.35), lineWidth: 0.5))
    }
}
