import AppKit
import PasteClipCore
import SwiftUI

/// A scrolling screenshot of a region. The user scrolls the content themselves; the region is
/// photographed about ten times a second and the frames are joined (`ScrollStitcher`) into one
/// tall picture. A frame around the region and a small panel beside it show how far it has got;
/// Space or ↩ finishes, Esc cancels.
final class ScrollCapture: @unchecked Sendable {
    private let rect: NSRect
    private let model = ScrollModel()
    private var border: NSWindow?
    private var panel: StripPanel?
    private var timer: Timer?
    private var grabber: ScreenGrabber?
    /// The stitcher is only touched on this queue.
    private let queue = DispatchQueue(label: "PasteClip.scroll-stitch", qos: .userInitiated)
    private var stitcher: ScrollStitcher?
    private var busy = false
    private var finished = false
    private let frontApp: NSRunningApplication?
    var sharingType = NSWindow.SharingType.readOnly
    /// The finished picture and the pixels per point it was taken at, or nil when cancelled.
    var onFinish: ((CGImage?, CGFloat) -> Void)?

    /// Taller than this and the picture is closed as it is (an image can only be so large).
    private static let maxHeight = 30_000

    init(rect: NSRect, frontApp: NSRunningApplication?) {
        self.rect = rect
        self.frontApp = frontApp
    }

    func start() {
        showChrome()
        Task {
            guard let grabber = await ScreenGrabber.region(rect), let first = await grabber.grab() else {
                return DispatchQueue.main.async { NSSound.beep(); self.end(nil) }
            }
            self.grabber = grabber
            queue.async { [self] in
                stitcher = ScrollStitcher(first: first)
                DispatchQueue.main.async {
                    self.model.pixelsHigh = first.height
                    self.model.frameHeight = first.height
                    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
                    RunLoop.main.add(timer, forMode: .common)
                    self.timer = timer
                }
            }
        }
    }

    private func tick() {
        guard !busy, !finished, let grabber else { return }
        busy = true
        Task {
            let frame = await grabber.grab()
            queue.async { [self] in
                var result: ScrollStitcher.Result?
                if let frame, let stitcher { result = stitcher.add(frame) }
                let height = stitcher?.height ?? 0, count = stitcher?.frameCount ?? 0
                DispatchQueue.main.async {
                    self.busy = false
                    guard !self.finished else { return }
                    self.model.apply(result, height: height, frames: count)
                    if height >= Self.maxHeight { self.finish() }
                }
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        model.finishing = true
        queue.async { [self] in
            let image = stitcher?.render()
            DispatchQueue.main.async { self.end(image) }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        end(nil)
    }

    private func end(_ image: CGImage?) {
        border?.orderOut(nil)
        panel?.orderOut(nil)
        border = nil
        panel = nil
        onFinish?(image, grabber?.scale ?? NSScreen.main?.backingScaleFactor ?? 2)
        onFinish = nil
    }

    // MARK: - Chrome

    private func showChrome() {
        // A line just outside the region, so it never is in the pictures. Mouse events go through it:
        // the content under it is scrolled with the wheel.
        let margin: CGFloat = 4
        let border = NSWindow(contentRect: rect.insetBy(dx: -margin, dy: -margin), styleMask: .borderless, backing: .buffered, defer: false)
        border.level = .statusBar
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.isReleasedWhenClosed = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.sharingType = sharingType
        border.contentView = FrameView(margin: margin)
        border.orderFrontRegardless()
        self.border = border

        let panel = StripPanel()
        let tone = GlowTone()
        let hosting = NSHostingView(rootView: StripView(model: model, tone: tone,
                                                        done: { [weak self] in self?.finish() },
                                                        cancel: { [weak self] in self?.cancel() }))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 16
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setFrame(Self.panelFrame(size: size, beside: rect), display: true)
        panel.sharingType = sharingType
        panel.onKey = { [weak self] event in self?.key(event) }
        panel.orderFrontRegardless()
        // Keys other than Space, ↩ and Esc are passed on to the app being scrolled (needs the
        // permission pasting uses; without it they are dropped, and the wheel does the scrolling).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// To the right of the region, else the left, else over its right edge; in view of the screen.
    private static func panelFrame(size: NSSize, beside rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        var x = rect.maxX + gap
        if x + size.width > visible.maxX - 8 { x = rect.minX - gap - size.width }
        if x < visible.minX + 8 { x = visible.maxX - size.width - 8 }
        let y = min(max(rect.maxY - size.height, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func key(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.type == .keyDown, plain {
            switch event.keyCode {
            case 49, 36, 76: return finish()      // Space, ↩, enter
            case 53: return cancel()
            default: break
            }
        }
        // Anything else is for the app being scrolled.
        if let pid = frontApp?.processIdentifier { event.cgEvent?.copy()?.postToPid(pid) }
    }
}

/// What the panel shows.
final class ScrollModel: ObservableObject {
    @Published var pixelsHigh = 0
    @Published var frames = 1
    @Published var lostFor = 0
    @Published var finishing = false
    var frameHeight = 1

    func apply(_ result: ScrollStitcher.Result?, height: Int, frames: Int) {
        pixelsHigh = height
        self.frames = frames
        switch result {
        case .lost, nil: lostFor += 1
        default: lostFor = 0
        }
    }
}

/// Takes the keyboard for Space, ↩ and Esc; every other key is passed on.
private final class StripPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp { return onKey?(event) ?? () }
        super.sendEvent(event)
    }
}

/// A rounded line in the accent colour, `margin` from the window's edge.
private final class FrameView: NSView {
    private let margin: CGFloat
    init(margin: CGFloat) {
        self.margin = margin
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: margin - 1, dy: margin - 1), xRadius: 5, yRadius: 5)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

/// The height so far, the frames joined, the buttons, and a column that grows as the picture does.
private struct StripView: View {
    @ObservedObject var model: ScrollModel
    let tone: GlowTone
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.pixelsHigh.formatted()) px")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.lostFor >= 8 ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            column
            HStack(spacing: 4) {
                CapsuleButton(title: "Done", key: "Space", prominent: true, expands: true, action: done)
                CapsuleButton(title: "Cancel", key: "Esc", expands: true, action: cancel)
            }
            .disabled(model.finishing)
        }
        .padding(14)
        .frame(width: 210)
        .lightRim(cornerRadius: 16, tone: tone)
        .background(GlassBackground(cornerRadius: 16))
    }

    private var status: String {
        if model.finishing { return "Joining…" }
        if model.lostFor >= 8 { return "Scroll down, a little slower" }
        return model.frames > 1 ? "\(model.frames) frames joined" : "Scroll down in the frame"
    }

    /// Stripes, one band per screenful, filling up as the picture grows.
    private var column: some View {
        let screens = Double(model.pixelsHigh) / Double(max(model.frameHeight, 1))
        let fill = min(1, 0.12 + (screens - 1) / 6)
        return GeometryReader { proxy in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.3)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: proxy.size.height * fill)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(height: 96)
        .animation(.easeOut(duration: 0.12), value: fill)
    }
}
