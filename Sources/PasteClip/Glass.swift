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

    /// A light edge around a glass panel, for the blurred material before macOS 26. Liquid Glass
    /// draws its own edge, and a second one there reads as a white border.
    @ViewBuilder
    func glassEdge(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
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

/// The app's button: a capsule with an optional symbol, a title and the key that does the same.
/// The prominent one is filled with the accent colour, the others with a light fill that
/// brightens on hover. Every surface uses it, so buttons look and behave the same everywhere.
struct CapsuleButton: View {
    var title: String?
    var symbol: String?
    var key: String?
    var prominent = false
    /// Takes the width it's given, as in a row of equal choices.
    var expands = false
    var help: String?
    let action: () -> Void
    @StateObject private var hovering = ViewState(false)
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                if let title {
                    Text(title).font(.system(size: 12, weight: prominent ? .semibold : .medium)).lineLimit(1).fixedSize()
                }
                if let key {
                    Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).opacity(0.55).fixedSize()
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, title == nil ? 8 : 11)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 28, maxHeight: 28)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(hovering.value && isEnabled ? 0.85 : 1)
                                                 : Color.primary.opacity(hovering.value && isEnabled ? 0.11 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize(horizontal: !expands, vertical: true)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering.value = inside } }
        .help(help ?? [title, key.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
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

/// ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V and ⌘A for the focused text field of a PasteClip panel. PasteClip stays
/// in the background while its panels take keys, so the Edit menu's key equivalents never reach them.
enum EditCommands {
    /// True when the key was one of these and was sent to the field.
    static func perform(_ event: NSEvent) -> Bool {
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
}

/// A scroll view whose scroll bar is always the thin one that shows only while scrolling, even
/// with "Show scroll bars: Always" (or a mouse) set in System Settings, whose bar sits on a white
/// track that looks out of place on glass.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// A text view filling a scroll view like this one, laid out as `NSTextView.scrollableTextView()` does.
    static func withTextView() -> (OverlayScrollView, NSTextView) {
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return (scroll, view)
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

    /// The same checks on white, for layers with nothing behind them.
    static let opaqueTile: NSImage = {
        let size = tile.size
        return NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            tile.draw(in: rect)
            return true
        }
    }()

    var body: some View {
        Image(nsImage: Self.tile).resizable(resizingMode: .tile)
    }
}

/// Quick Look thumbnails for copied files (images, PDFs, documents), cached for the session.
/// Each path has a slot of its own that its card watches, so a thumbnail arriving redraws that
/// card only, not every card on the shelf.
final class FileThumbnails {
    static let shared = FileThumbnails()

    final class Slot: ObservableObject {
        @Published fileprivate(set) var image: NSImage?
    }

    private var slots: [String: Slot] = [:]
    private var requested = Set<String>()

    func thumbnail(for path: String) -> NSImage? { slots[path]?.image }

    func slot(for path: String) -> Slot {
        if let slot = slots[path] { return slot }
        let slot = Slot()
        slots[path] = slot
        return slot
    }

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

    private static let downsampled = NSCache<NSString, NSImage>()

    /// The image file decoded no larger than `maxPixels` on its longer side, and cached. A 5K
    /// screenshot decoded whole for a popup a fifth its size, and blurred, is slow to show.
    static func image(at path: String, maxPixels: Int) -> NSImage? {
        let key = "\(path)|\(maxPixels)" as NSString
        if let cached = downsampled.object(forKey: key) { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        downsampled.setObject(image, forKey: key)
        return image
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
            DispatchQueue.main.async { self?.slot(for: path).image = image }
        }
    }
}
