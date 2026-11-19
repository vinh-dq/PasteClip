import AppKit
import PasteClipSystem
import PasteClipCore
import SwiftUI

/// After a screenshot: a small card in the bottom corner of the screen with the picture and what
/// can be done with it next, Edit E, Float P and Translate T, so there's no setting to change
/// first. It takes those keys at once, wherever the pointer is. Any other key closes it and goes
/// on to the app in front, so typing there carries on without losing a letter; Esc just closes it.
/// It goes on its own after a few seconds unless the pointer is over it.
final class ScreenshotOffer {
    enum Choice { case edit, float, translate }

    private var panel: OfferPanel?
    private var halo: GlowHalo?
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
        let tone = GlowTone()
        let hosting = NSHostingView(rootView: OfferView(
            image: image, tone: tone, choose: pick,
            close: { [weak self] in self?.close() },
            hover: { [weak self] inside in self?.hover(inside) }))
        // Rounded as its glass, so the window's shadow is too.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 16
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.onKey = { [weak self] event in
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            switch plain ? event.charactersIgnoringModifiers?.lowercased() : nil {
            case "e": pick(.edit)
            case "p": pick(.float)
            case "t": pick(.translate)
            case _ where event.keyCode == 53: self?.close()              // Esc only closes.
            default:
                // At once, so the keyboard is back with the app in front for the key.
                self?.close(animated: false)
                Self.passOn(event)
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
        // It takes the keyboard only when other keys can be sent on to the app in front
        // (Accessibility); without that, typing would lose its first key here. Clicks still work.
        if Paster.isTrusted { panel.makeKey() }
        halo = GlowHalo(around: panel, kind: .panel, cornerRadius: 16, tone: tone)
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

    /// Stays while the pointer is over it.
    private func hover(_ inside: Bool) {
        if inside { closeWork?.cancel() } else { closeLater() }
    }

    /// Sends a key the card didn't want on to the app in front, once the card has let the
    /// keyboard go back to it. Needs the Accessibility permission that pasting uses.
    private static func passOn(_ event: NSEvent) {
        guard let key = event.cgEvent?.copy() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { key.post(tap: .cghidEventTap) }
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
    let tone: GlowTone
    let choose: (ScreenshotOffer.Choice) -> Void
    let close: () -> Void
    let hover: (Bool) -> Void
    @StateObject private var hovering = ViewState(false)

    private static let width: CGFloat = 292

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            HStack(spacing: 4) {
                CapsuleButton(title: "Edit", symbol: "pencil.tip", key: "E", expands: true,
                              help: "Edit (E)") { choose(.edit) }
                CapsuleButton(title: "Float", symbol: "pip", key: "P", expands: true,
                              help: "Float (P)") { choose(.float) }
                CapsuleButton(title: "Translate", symbol: "character.bubble", key: "T", expands: true,
                              help: "Translate (T)") { choose(.translate) }
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .lightRim(cornerRadius: 16, tone: tone)
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
        // Double-clicking the picture floats it, as P does.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { choose(.float) }
        .help("Double-click to float (P)")
    }
}
