import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// Window background: Liquid Glass on macOS 26 and later, a blurred material before that.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tint: NSColor?
    /// Clear glass lets more of what's behind the window show through.
    var clear = false

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = cornerRadius
            view.tintColor = tint
            view.style = clear ? .clear : .regular
            return view
        }
        let view = NSVisualEffectView()
        view.material = clear ? .underWindowBackground : .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.style = clear ? .clear : .regular
        }
    }
}

extension View {
    /// A capsule of glass behind small controls (tabs, search). Tinted when selected.
    @ViewBuilder
    func glassCapsule(selected: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(selected ? Glass.regular.tint(tint.opacity(0.45)).interactive() : Glass.regular.interactive(),
                        in: Capsule())
        } else {
            background(Capsule().fill(selected ? tint.opacity(0.28) : Color.primary.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0.35 : 0.15), lineWidth: 0.5))
        }
    }

    /// A circle of glass behind an icon button.
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.interactive(), in: Circle())
        } else {
            background(Circle().fill(Color.primary.opacity(0.07)))
        }
    }
}

/// Light checkerboard behind images so transparent areas are visible. Tiled from one small image.
struct Checkerboard: View {
    private static let tile: NSImage = {
        let s: CGFloat = 8
        return NSImage(size: NSSize(width: s * 2, height: s * 2), flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.05).setFill()
            NSRect(x: 0, y: 0, width: s, height: s).fill()
            NSRect(x: s, y: s, width: s, height: s).fill()
            return true
        }
    }()

    var body: some View {
        Image(nsImage: Self.tile).resizable(resizingMode: .tile)
    }
}

/// Quick Look thumbnails for copied files (images, PDFs, documents), cached for the session.
final class FileThumbnails: ObservableObject {
    static let shared = FileThumbnails()

    @Published private(set) var images: [String: NSImage] = [:]
    private var requested = Set<String>()

    func thumbnail(for path: String) -> NSImage? { images[path] }

    private static var sizes: [String: CGSize] = [:]
    private static var icons: [String: NSImage] = [:]

    /// Pixel size from the image file's header, without decoding the image.
    static func pixelSize(of path: String) -> CGSize? {
        if let size = sizes[path] { return size }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = CGSize(width: w, height: h)
        sizes[path] = size
        return size
    }

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    func load(_ path: String, size: CGSize = CGSize(width: 480, height: 380)) {
        guard requested.insert(path).inserted else { return }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size,
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.images[path] = image }
        }
    }
}
