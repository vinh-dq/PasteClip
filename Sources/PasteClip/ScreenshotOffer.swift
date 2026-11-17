import AppKit
import PasteClipCore
import SwiftUI

/// After a screenshot: a small card in the bottom corner of the screen with the picture and what
/// can be done with it next, Edit E, Float P and Translate T, so there's no setting to change
/// first. It takes those keys at once (the app in front keeps its focus otherwise), goes on its
/// own after a few seconds unless the pointer is over it, and Esc or any other key closes it.
final class ScreenshotOffer {
    enum Choice { case edit, float, translate }

    private var panel: OfferPanel?
    private var closeWork: DispatchWorkItem?
    var sharingType = NSWindow.SharingType.readOnly

    /// From the screen's edges.
    private static let margin: CGFloat = 10

    func show(_ item: ClipItem, image: NSImage, onChoose: @escaping (Choice) -> Void) {
        close(animated: false)
        let panel = OfferPanel()
        let pick: (Choice) -> Void = { [weak self] choice in
            self?.close()
            onChoose(choice)
        }
        let hosting = NSHostingView(rootView: OfferView(
            image: image, choose: pick,
            close: { [weak self] in self?.close() },
            hover: { [weak self] inside in
                if inside { self?.closeWork?.cancel() } else { self?.closeLater() }
            }))
        // Rounded as its glass, so the window's shadow is too.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 16
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.onKey = { [weak self] event in
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "e": pick(.edit)
            case "p": pick(.float)
            case "t": pick(.translate)
            default: self?.close()
            }
        }
        // In the corner of the screen itself: the Dock sits in the middle of the bottom edge.
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - Self.margin, y: screen.frame.minY + Self.margin,
                           width: size.width, height: size.height)
        panel.setFrame(frame.offsetBy(dx: 24, dy: 0), display: true)
        panel.sharingType = sharingType
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { panel.invalidateShadow() })
        self.panel = panel
        closeLater()
    }

    func close(animated: Bool = true) {
        closeWork?.cancel()
        closeWork = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: 24, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func closeLater() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

private final class OfferPanel: NSPanel {
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
        if event.type == .keyDown { return onKey?(event) ?? () }
        super.sendEvent(event)
    }
}

/// The picture on top, with a close button on hover, and the three choices under it.
private struct OfferView: View {
    let image: NSImage
    let choose: (ScreenshotOffer.Choice) -> Void
    let close: () -> Void
    let hover: (Bool) -> Void
    @StateObject private var hovering = ViewState(false)

    private static let width: CGFloat = 292

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            HStack(spacing: 4) {
                OfferButton(title: "Edit", symbol: "pencil.tip", key: "E") { choose(.edit) }
                OfferButton(title: "Float", symbol: "pin", key: "P") { choose(.float) }
                OfferButton(title: "Translate", symbol: "character.bubble", key: "T") { choose(.translate) }
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(GlassBackground(cornerRadius: 16))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering.value = inside }
            hover(inside)
        }
    }

    private var thumbnail: some View {
        let inner = Self.width - 12
        let height = min(max(inner * image.size.height / max(image.size.width, 1), 64), 150)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.06)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: inner, height: height)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hovering.value ? 1 : 0)
            .help("Close (Esc)")
        }
        .frame(width: inner, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

private struct OfferButton: View {
    let title: String
    let symbol: String
    let key: String
    let action: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
                Text(key)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering.value ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering.value = inside } }
        .help("\(title) (\(key))")
    }
}
