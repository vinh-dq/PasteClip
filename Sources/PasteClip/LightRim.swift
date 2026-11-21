import AppKit
import Combine
import SwiftUI

/// PasteClip's glass, lit from above: a rim of light strongest on the top edge and fading down
/// the sides, none at the bottom (`lightRim`), and outside (`GlowHalo`) a faint glow above only,
/// with a wide, soft shadow underneath for depth. The glass inside is left see-through. Light all
/// round looked cheap; a shade or sheen over the glass turned it milky. Light or dark with the system's appearance, so it stays the same wherever
/// the window is.
enum GlowKind {
    /// A glass panel: the shelf, the preview, the translation panel, the screenshot card.
    case panel
    /// A floating image, which gets less: a picture is busier than glass.
    case picture
}

/// Whether the system appearance is light, for the panel's own drawing of the inner light.
final class GlowTone: ObservableObject {
    @Published var light = false
}

/// A window that stays where it's put: macOS would push one that reaches above the menu bar back
/// down, and the halo of a window dragged to the top of the screen would slide off it.
private final class HaloWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The halo outside a window, drawn by a window of its own just behind it: the window itself is
/// only as large as its content, which would cut the halo off. It follows the window as it moves,
/// resizes, fades and switches between light and dark, and never takes clicks.
final class GlowHalo {
    private struct Glow {
        let radius: CGFloat
        let opacity: Float
        var color = NSColor.white
        var offsetY: CGFloat = 0
        /// Shrinks the shape that casts it, so with an offset it shows on one side only.
        var inset: CGFloat = 0
    }

    /// Room around the window for the halo to fade out in.
    private static let margin: CGFloat = 56

    private weak var parent: NSWindow?
    private let kind: GlowKind
    /// The panel's corners, for windows whose shape changes with what they show.
    var cornerRadius: CGFloat { didSet { layout() } }
    private let window: NSWindow
    private let host = CALayer()
    private let shape = CAShapeLayer()
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var alphaObservation: NSKeyValueObservation?
    private var attached = false
    /// Told whether what's behind is light, for the inner light drawn by the window itself.
    let tone: GlowTone

    /// Edges of the window the panel doesn't reach, such as the preview's arrow.
    var insets = NSEdgeInsetsZero { didSet { layout() } }
    /// Fades the halo with what it's around, as a floating image made fainter.
    var intensity: CGFloat = 1 { didSet { syncAlpha() } }

    init(around parent: NSWindow, kind: GlowKind, cornerRadius: CGFloat, tone: GlowTone = GlowTone()) {
        self.parent = parent
        self.kind = kind
        self.cornerRadius = cornerRadius
        self.tone = tone
        window = HaloWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(host)
        window.contentView = view
        // Only the halo: inside the outline it's cut away, so a see-through panel or a faded
        // image doesn't show a glow through itself.
        shape.fillRule = .evenOdd
        host.mask = shape

        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in self?.layout() })
        }
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: parent,
                                            queue: .main) { [weak self] _ in self?.syncVisibility() })
        appearanceObservation = parent.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.restyle() }
        }
        alphaObservation = parent.observe(\.alphaValue) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncAlpha() }
        }
        restyle()
        syncVisibility()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    /// Puts the halo up with its window, or takes it down; call after showing the window when it
    /// might not have been noticed yet.
    func syncVisibility() {
        guard let parent else { return }
        if parent.isVisible, !attached {
            attached = true
            window.level = parent.level
            window.collectionBehavior = parent.collectionBehavior
            layout()
            syncAlpha()
            parent.addChildWindow(window, ordered: .below)
        } else if !parent.isVisible, attached {
            attached = false
            parent.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    private var isDark: Bool {
        parent?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var glows: [Glow] {
        // Narrowed by a tenth from the first take, which spread too wide.
        // Each brings its own shadow: the system's window shadow draws a hairline around the
        // window, which reads as a dark border.
        let shade = NSColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 1)
        let black = NSColor.black
        let glow = (NSColor.controlAccentColor.blended(withFraction: 0.3, of: .white) ?? .controlAccentColor)
        switch (kind, isDark) {
        case (.panel, false): return [Glow(radius: 7.2, opacity: 0.6, offsetY: 5.4, inset: 5.4),
                                      Glow(radius: 0.9, opacity: 0.06, color: shade, offsetY: -0.9),
                                      Glow(radius: 19.8, opacity: 0.22, color: shade, offsetY: -16.2, inset: 9)]
        case (.panel, true): return [Glow(radius: 9, opacity: 0.28, offsetY: 5.4, inset: 7.2),
                                     Glow(radius: 0.9, opacity: 0.3, color: black, offsetY: -0.9),
                                     Glow(radius: 22.5, opacity: 0.6, color: black, offsetY: -19.8, inset: 10.8)]
        // A picture also glows in the accent, all round, so a white capture on a white page (or a
        // light one on black) still has an edge: lightened so it shows on black too, and wide
        // enough to read on white.
        case (.picture, false): return [Glow(radius: 6.3, opacity: 0.6, offsetY: 4.5, inset: 5.4),
                                        Glow(radius: 0.9, opacity: 0.08, color: shade, offsetY: -0.9),
                                        Glow(radius: 11, opacity: 0.16, color: shade, inset: 1),
                                        Glow(radius: 14, opacity: 0.5, color: glow, inset: 1),
                                        Glow(radius: 18, opacity: 0.25, color: shade, offsetY: -14.4, inset: 9)]
        case (.picture, true): return [Glow(radius: 8.1, opacity: 0.3, offsetY: 4.5, inset: 7.2),
                                       Glow(radius: 0.9, opacity: 0.35, color: black, offsetY: -0.9),
                                       Glow(radius: 15, opacity: 0.7, color: glow, inset: 1),
                                       Glow(radius: 7, opacity: 0.35, color: glow, inset: 1),
                                       Glow(radius: 20.7, opacity: 0.65, color: black, offsetY: -18, inset: 10.8)]
        }
    }

    private func restyle() {
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        for glow in glows {
            let layer = CALayer()
            layer.shadowColor = glow.color.cgColor
            layer.shadowOpacity = glow.opacity
            layer.shadowRadius = glow.radius
            layer.shadowOffset = CGSize(width: 0, height: glow.offsetY)
            layer.setValue(glow.inset, forKey: "glowInset")
            host.addSublayer(layer)
        }
        parent?.hasShadow = false
        if tone.light != !isDark { tone.light = !isDark }
        layout()
    }

    private func layout() {
        guard let parent else { return }
        let m = Self.margin
        window.setFrame(parent.frame.insetBy(dx: -m, dy: -m), display: false)
        window.sharingType = parent.sharingType
        let bounds = CGRect(origin: .zero, size: window.frame.size)
        let panel = CGRect(x: m + insets.left, y: m + insets.bottom,
                           width: parent.frame.width - insets.left - insets.right,
                           height: parent.frame.height - insets.top - insets.bottom)
        let outline = CGPath(roundedRect: panel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = bounds
        for layer in host.sublayers ?? [] {
            let inset = layer.value(forKey: "glowInset") as? CGFloat ?? 0
            let radius = max(cornerRadius - inset, 0)
            layer.frame = bounds
            layer.shadowPath = CGPath(roundedRect: panel.insetBy(dx: inset, dy: inset), cornerWidth: radius,
                                      cornerHeight: radius, transform: nil)
        }
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(outline)
        shape.path = mask
        CATransaction.commit()
    }

    private func syncAlpha() {
        window.alphaValue = (parent?.alphaValue ?? 1) * intensity
    }
}

extension View {
    /// The edge of PasteClip's glass, lit from above: a rim of light strongest on the top edge,
    /// fading down the sides. The glow and shadow are outside (`GlowHalo`, which tells `tone`);
    /// the glass inside stays as it is.
    func lightRim(cornerRadius: CGFloat, tone: GlowTone) -> some View {
        modifier(LightRim(cornerRadius: cornerRadius, tone: tone))
    }
}

/// The rim of light along a top-lit edge: white at the top, fading down the sides, none at the bottom.
enum TopLight {
    static func rim(light: Bool) -> Gradient {
        let a: [Double] = light ? [0.95, 0.35, 0.12] : [0.45, 0.14, 0.04]
        return Gradient(stops: [.init(color: .white.opacity(a[0]), location: 0), .init(color: .white.opacity(a[1]), location: 0.22),
                                .init(color: .white.opacity(a[2]), location: 0.6), .init(color: .white.opacity(0), location: 1)])
    }
}

private struct LightRim: ViewModifier {
    let cornerRadius: CGFloat
    @ObservedObject var tone: GlowTone

    // The glass itself is left as it is, see-through: a shade or sheen over it turned it milky white.
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.overlay {
            shape.strokeBorder(LinearGradient(gradient: TopLight.rim(light: tone.light), startPoint: .top, endPoint: .bottom),
                               lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// The rim of light on a floating image, lit from above like the panels: strongest on the top
/// edge, fading down the sides.
final class RimLayer: CALayer {
    private let gradient = CAGradientLayer()
    private let line = CAShapeLayer()

    override init() {
        super.init()
        // Unflipped: (0.5, 1) is the top.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.22, 0.6, 1]
        line.fillColor = nil
        line.strokeColor = NSColor.black.cgColor
        line.lineWidth = 2
        gradient.mask = line
        addSublayer(gradient)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func update(cornerRadius: CGFloat, light: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // About half the panels' rim: on a picture a full-strength line read as a heavy white edge.
        let a: [CGFloat] = light ? [0.5, 0.18, 0.06, 0] : [0.28, 0.09, 0.025, 0]
        gradient.colors = a.map { NSColor.white.withAlphaComponent($0).cgColor }
        gradient.frame = bounds
        line.frame = bounds
        // Stroked on the outline, so half of it shows inside the picture's rounded clip: 1 pt.
        line.path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }
}
