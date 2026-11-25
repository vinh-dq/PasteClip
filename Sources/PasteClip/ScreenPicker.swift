import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

enum PickMode: CaseIterable {
    case area, scroll, window

    var title: String {
        switch self {
        case .area: "Area"
        case .scroll: "Scroll"
        case .window: "Window"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .scroll: "arrow.down.to.line"
        case .window: "macwindow"
        }
    }

    var hint: String {
        switch self {
        case .area: "Drag an area  ·  Space for Scroll  ·  Esc cancels"
        case .scroll: "Drag the region, then scroll it yourself  ·  Space for Window"
        case .window: "Click a window  ·  Space for Area"
        }
    }

    /// What Space switches to.
    var next: PickMode {
        switch self {
        case .area: .scroll
        case .scroll: .window
        case .window: .area
        }
    }
}

final class PickModel: ObservableObject {
    @Published var mode = PickMode.area
}

/// A screenshot, and where on screen it was taken when that is the area dragged.
struct PickedScreenshot {
    let image: CGImage
    let scale: CGFloat
    let frame: NSRect?
}

/// PasteClip's own picker for ⇧⌘1, in place of the system's: the screen dims, and Space moves
/// between Area (drag), Scroll (drag a region, then scroll it by hand) and Window (click one).
/// Esc cancels. It starts in Area, as the system's does.
final class ScreenPicker: @unchecked Sendable {
    private let model = PickModel()
    private var windows: [PickWindow] = []
    private var completion: ((PickedScreenshot?) -> Void)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hovered: WindowInfo?
    private var shareable: [CGWindowID: SCWindow] = [:]
    private var scrollCapture: ScrollCapture?
    private var frontApp: NSRunningApplication?
    var sharingType = NSWindow.SharingType.readOnly

    private struct WindowInfo {
        let id: CGWindowID
        let frame: NSRect
        let owner: String
    }

    var mode: PickMode { model.mode }

    func start(_ completion: @escaping (PickedScreenshot?) -> Void) {
        self.completion = completion
        model.mode = .area
        frontApp = NSWorkspace.shared.frontmostApplication
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = Dictionary(content?.windows.map { ($0.windowID, $0) } ?? [], uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async { self.shareable = windows }
        }
        windows = NSScreen.screens.map { PickWindow(screen: $0, picker: self, model: model, sharingType: sharingType) }
        NSApp.activate()
        windows.forEach { $0.orderFrontRegardless() }
        let current = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        current?.makeKey()
        current?.makeFirstResponder(current?.contentView)
    }

    // MARK: - What the views draw

    /// The part left undimmed: the area being dragged, or the window under the pointer.
    var hole: NSRect? { selection ?? (mode == .window ? hovered?.frame : nil) }
    var holeLabel: String? {
        if let selection { return "\(Int(selection.width)) × \(Int(selection.height))" }
        if mode == .window, let hovered { return hovered.owner }
        return nil
    }
    var isDragging: Bool { selection != nil }

    private var selection: NSRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }

    // MARK: - Input

    func key(_ event: NSEvent) {
        switch event.keyCode {
        case 53: finish(nil)
        case 49:
            guard !event.isARepeat, dragStart == nil else { return }
            model.mode = model.mode.next
            hovered = nil
            if model.mode == .window { hovered = window(at: NSEvent.mouseLocation) }
            windows.forEach { $0.invalidateCursorRects(for: $0.contentView!) }
            redraw()
        default: break
        }
    }

    func mouseDown(_ point: NSPoint) {
        guard mode != .window else { return }
        dragStart = point
        dragCurrent = point
        redraw()
    }

    func mouseDragged(_ point: NSPoint) {
        guard let start = dragStart else { return }
        // Stays on the screen it began on.
        let frame = NSScreen.screens.first { NSMouseInRect(start, $0.frame, false) }?.frame ?? .infinite
        dragCurrent = NSPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
        redraw()
    }

    func mouseMoved(_ point: NSPoint) {
        guard mode == .window else { return }
        let found = window(at: point)
        if found?.id != hovered?.id { hovered = found; redraw() }
    }

    func mouseUp(_ point: NSPoint) {
        if mode == .window {
            if let hovered { capture(window: hovered) }
            return
        }
        guard let rect = selection?.integral, rect.width >= 8, rect.height >= 8 else {
            dragStart = nil
            dragCurrent = nil
            return redraw()
        }
        if mode == .area { capture(area: rect) } else { scroll(rect) }
    }

    /// The front-most ordinary window under `point` that isn't PasteClip's.
    private func window(at point: NSPoint) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let box = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  box.width > 40, box.height > 40,
                  let id = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            // Quartz counts from the top left of the main screen.
            let frame = NSRect(x: box.minX, y: primary.frame.height - box.maxY, width: box.width, height: box.height)
            if frame.contains(point) {
                return WindowInfo(id: id, frame: frame, owner: info[kCGWindowOwnerName as String] as? String ?? "Window")
            }
        }
        return nil
    }

    // MARK: - Taking the picture

    private func capture(area rect: NSRect) {
        closeWindows()
        Task {
            // A moment for the dimming to leave the screen.
            try? await Task.sleep(nanoseconds: 80_000_000)
            let grabber = await ScreenGrabber.region(rect)
            let image = await grabber?.grab()
            DispatchQueue.main.async {
                self.finish(image.map { PickedScreenshot(image: $0, scale: grabber?.scale ?? 2, frame: rect) })
            }
        }
    }

    private func capture(window info: WindowInfo) {
        closeWindows()
        let scale = NSScreen.screens.first { NSMouseInRect(NSPoint(x: info.frame.midX, y: info.frame.midY), $0.frame, false) }?.backingScaleFactor ?? 2
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            var image: CGImage?
            if let window = shareable[info.id] { image = await ScreenGrabber.window(window, scale: scale).grab() }
            DispatchQueue.main.async { self.finish(image.map { PickedScreenshot(image: $0, scale: scale, frame: nil) }) }
        }
    }

    private func scroll(_ rect: NSRect) {
        closeWindows()
        // PasteClip stays the active app while scrolling, so the panel beside the region has the
        // keyboard from the start (Space, ↩, Esc); the wheel still scrolls whatever is under it.
        let capture = ScrollCapture(rect: rect, frontApp: frontApp)
        capture.sharingType = sharingType
        capture.onFinish = { [weak self] image, scale in
            self?.scrollCapture = nil
            self?.finish(image.map { PickedScreenshot(image: $0, scale: scale, frame: nil) })
        }
        scrollCapture = capture
        capture.start()
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        dragStart = nil
        dragCurrent = nil
        hovered = nil
    }

    private func finish(_ shot: PickedScreenshot?) {
        closeWindows()
        // Back to the app that was in front, so typing carries on there.
        if scrollCapture == nil { frontApp?.activate() }
        let done = completion
        completion = nil
        done?(shot)
    }
}

// MARK: - Windows and views

private final class PickWindow: NSWindow {
    init(screen: NSScreen, picker: ScreenPicker, model: PickModel, sharingType: NSWindow.SharingType) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.sharingType = sharingType
        let view = PickView(picker: picker)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = view
        let chrome = ClickThroughHostingView(rootView: PickerChrome(model: model))
        chrome.frame = view.bounds
        chrome.autoresizingMask = [.width, .height]
        view.addSubview(chrome)
    }

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PickView: NSView {
    private unowned let picker: ScreenPicker

    init(picker: ScreenPicker) {
        self.picker = picker
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func global(_ event: NSEvent) -> NSPoint { window!.convertPoint(toScreen: event.locationInWindow) }
    override func mouseDown(with event: NSEvent) { picker.mouseDown(global(event)) }
    override func mouseDragged(with event: NSEvent) { picker.mouseDragged(global(event)) }
    override func mouseMoved(with event: NSEvent) { picker.mouseMoved(global(event)) }
    override func mouseUp(with event: NSEvent) { picker.mouseUp(global(event)) }
    override func keyDown(with event: NSEvent) { picker.key(event) }
    override func cancelOperation(_ sender: Any?) { picker.key(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: picker.mode == .window ? .arrow : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        let origin = window.frame.origin
        let hole = picker.hole.map { NSRect(x: $0.minX - origin.x, y: $0.minY - origin.y, width: $0.width, height: $0.height) }
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.append(NSBezierPath(roundedRect: hole, xRadius: 6, yRadius: 6)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(hole == nil ? 0.3 : 0.42).setFill()
        dim.fill()
        guard let hole, bounds.intersects(hole) else { return }

        let line = NSBezierPath(roundedRect: hole, xRadius: 6, yRadius: 6)
        line.lineWidth = picker.isDragging ? 1.5 : 2.5
        (picker.isDragging ? NSColor.white : NSColor.controlAccentColor).setStroke()
        line.stroke()

        if let label = picker.holeLabel { drawLabel(label, near: hole) }
    }

    /// A small dark pill with the size, or the window's app, just under the hole (inside it when there's no room).
    private func drawLabel(_ text: String, near hole: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = NSSize(width: size.width + 16, height: size.height + 6)
        var y = hole.minY - pill.height - 8
        if y < 6 { y = hole.minY + 8 }
        let rect = NSRect(x: min(max(hole.minX, 6), bounds.maxX - pill.width - 6), y: y, width: pill.width, height: pill.height)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: attributes)
    }
}

/// The mode switch at the top and the hint at the bottom; the pointer passes through both.
private struct PickerChrome: View {
    @ObservedObject var model: PickModel
    @StateObject private var tone = GlowTone()

    var body: some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(PickMode.allCases, id: \.self) { mode in
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 11, weight: .medium))
                        Text(mode.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(model.mode == mode ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(model.mode == mode ? Color.accentColor : Color.clear))
                }
            }
            .padding(5)
            .lightRim(cornerRadius: 20, tone: tone)
            .background(GlassBackground(cornerRadius: 20))
            .padding(.top, 54)
            Spacer()
            Text(model.mode.hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .lightRim(cornerRadius: 15, tone: tone)
                .background(GlassBackground(cornerRadius: 15))
                .padding(.bottom, 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }
}
