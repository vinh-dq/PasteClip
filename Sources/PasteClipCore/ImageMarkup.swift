import AppKit
import CoreImage

/// What a drag or click does in the image editor.
public enum MarkupTool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, line, arrow, text, pen, highlighter, pixelate, step, crop

    public var id: String { rawValue }

    /// The key that picks the tool.
    public var key: String {
        switch self {
        case .select: return "V"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .line: return "L"
        case .arrow: return "A"
        case .text: return "T"
        case .pen: return "P"
        case .highlighter: return "H"
        case .pixelate: return "B"
        case .step: return "N"
        case .crop: return "C"
        }
    }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .pixelate: return "Pixelate"
        case .step: return "Number"
        case .crop: return "Crop"
        }
    }

    public var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .pen: return "scribble.variable"
        case .highlighter: return "highlighter"
        case .pixelate: return "checkerboard.rectangle"
        case .step: return "1.circle"
        case .crop: return "crop"
        }
    }

    /// The mark the tool draws; nil for selecting and cropping.
    public var kind: Markup.Kind? { Markup.Kind(rawValue: rawValue) }

    /// Tools whose shapes can be filled instead of outlined.
    public var canFill: Bool { self == .rectangle || self == .ellipse }
}

/// One thing drawn on an image, in the image's pixels with the origin at the top left.
public struct Markup: Identifiable, Equatable {
    public enum Kind: String {
        case rectangle, ellipse, line, arrow, text, pen, highlighter, pixelate, step

        /// Kinds drawn between two points, which a drag on a corner resizes.
        public var isTwoPoint: Bool { [.rectangle, .ellipse, .line, .arrow, .pixelate].contains(self) }
        public var isBox: Bool { [.rectangle, .ellipse, .pixelate].contains(self) }
        /// Kinds a drag on a corner makes larger or smaller as a whole.
        public var isScalable: Bool { self == .text || self == .step }
    }

    public var id = UUID()
    public var kind: Kind
    /// Start and end for two-point kinds, every point for the pen and highlighter, the top left of
    /// text and the centre of a number.
    public var points: [CGPoint]
    /// Index into `MarkupStyle.colors`.
    public var color: Int
    /// Index into the stroke widths and text sizes, 0…2.
    public var size: Int
    public var filled = false
    /// How much larger than its size a text or number has been dragged, 1 if never.
    public var scale: CGFloat = 1
    public var text = ""
    public var number = 0

    public init(kind: Kind, points: [CGPoint], color: Int, size: Int, filled: Bool = false) {
        self.kind = kind
        self.points = points
        self.color = color
        self.size = size
        self.filled = filled
    }

    public func moved(by d: CGVector) -> Markup {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return copy
    }
}

public enum MarkupStyle {
    /// Red, orange, yellow, green, blue, black.
    public static let colors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (1.0, 0.23, 0.19), (1.0, 0.58, 0.0), (1.0, 0.8, 0.0), (0.2, 0.78, 0.35), (0.04, 0.52, 1.0), (0.11, 0.11, 0.12),
    ]
    public static let sizeNames = ["Thin", "Medium", "Thick"]

    public static func cgColor(_ index: Int, alpha: CGFloat = 1) -> CGColor {
        let c = colors[min(max(index, 0), colors.count - 1)]
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    public static func nsColor(_ index: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(cgColor: cgColor(index, alpha: alpha)) ?? .systemRed
    }

    /// Light colours get a dark outline behind text and numbers, dark ones a white one.
    public static func isLight(_ index: Int) -> Bool {
        let c = colors[min(max(index, 0), colors.count - 1)]
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6
    }
}

/// Draws marks on an image, both in the editor and for the saved copy, so they look the same.
/// Every drawing call expects a context whose units are image pixels with the origin at the top left.
public final class MarkupRenderer {
    public let image: CGImage
    public let size: CGSize
    /// Scale for widths and text, so marks look alike on small and large images.
    public let unit: CGFloat
    private var pixelatedImage: CGImage??

    public init(image: CGImage) {
        self.image = image
        size = CGSize(width: image.width, height: image.height)
        unit = max(1, max(size.width, size.height) / 1200)
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    public func lineWidth(_ mark: Markup) -> CGFloat {
        let width = [3, 5.5, 9][min(max(mark.size, 0), 2)] * unit
        return mark.kind == .highlighter ? width * 3.2 : width
    }

    public func fontSize(_ mark: Markup) -> CGFloat { [18, 28, 44][min(max(mark.size, 0), 2)] * unit * mark.scale }

    /// Radius of a number's circle.
    public func stepRadius(_ mark: Markup) -> CGFloat { fontSize(mark) * 0.72 }

    /// Smallest and largest `Markup.scale`.
    public static let scaleRange: ClosedRange<CGFloat> = 0.3...12

    /// A text or number made larger or smaller by dragging corner `handle` (clockwise from the top
    /// left) of `box`, its area when the drag began, to `point`. The opposite corner stays put.
    public func scaled(_ original: Markup, box: CGRect, handle: Int, to point: CGPoint) -> Markup {
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let fixed = corners[(handle + 2) % 4]
        let dragged = corners[handle]
        // The box keeps its shape, so it grows by whichever way the pointer went further.
        let along = CGPoint(x: (point.x - fixed.x) / (dragged.x - fixed.x == 0 ? 1 : dragged.x - fixed.x),
                            y: (point.y - fixed.y) / (dragged.y - fixed.y == 0 ? 1 : dragged.y - fixed.y))
        var factor = max(along.x, along.y)
        factor = min(max(original.scale * factor, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) / original.scale
        var mark = original
        mark.scale = original.scale * factor
        let size = CGSize(width: box.width * factor, height: box.height * factor)
        let x = dragged.x >= fixed.x ? fixed.x : fixed.x - size.width
        let y = dragged.y >= fixed.y ? fixed.y : fixed.y - size.height
        let area = CGRect(origin: CGPoint(x: x, y: y), size: size)
        mark.points = [mark.kind == .step ? CGPoint(x: area.midX, y: area.midY) : area.origin]
        return mark
    }

    // MARK: Drawing

    public func draw(_ marks: [Markup], in ctx: CGContext) {
        for mark in marks { draw(mark, in: ctx) }
    }

    public func draw(_ mark: Markup, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = MarkupStyle.cgColor(mark.color)
        let width = lineWidth(mark)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark.kind {
        case .rectangle, .ellipse:
            let path = self.path(for: mark)
            if mark.filled {
                ctx.addPath(path)
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                ctx.addPath(path)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }
        case .line, .pen:
            ctx.addPath(path(for: mark))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.strokePath()
        case .highlighter:
            ctx.addPath(path(for: mark))
            ctx.setStrokeColor(MarkupStyle.cgColor(mark.color, alpha: 0.38))
            ctx.setLineWidth(width)
            ctx.setBlendMode(.multiply)
            ctx.strokePath()
        case .arrow:
            drawArrow(mark, color: color, width: width, in: ctx)
        case .pixelate:
            let rect = Self.rect(mark.points)
            guard rect.width >= 1, rect.height >= 1, let pixelated = pixelated() else { return }
            ctx.clip(to: rect)
            Self.drawImage(pixelated, in: bounds, ctx: ctx)
        case .text:
            drawText(mark, in: ctx)
        case .step:
            drawStep(mark, color: color, in: ctx)
        }
    }

    private func drawArrow(_ mark: Markup, color: CGColor, width: CGFloat, in ctx: CGContext) {
        guard mark.points.count >= 2 else { return }
        let a = mark.points[0], b = mark.points[mark.points.count - 1]
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let head = min(max(width * 3.6, 12 * unit), length * 0.6)
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let base = CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8)
        ctx.move(to: a)
        ctx.addLine(to: base)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
        let half = head * 0.48
        let back = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: back.x - uy * half, y: back.y + ux * half))
        ctx.addLine(to: CGPoint(x: back.x + uy * half, y: back.y - ux * half))
        ctx.closePath()
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width * 0.5)
        ctx.drawPath(using: .fillStroke)
    }

    public func textAttributes(_ mark: Markup, halo: Bool) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: fontSize(mark), weight: .bold)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MarkupStyle.nsColor(mark.color)]
        if halo {
            attributes[.strokeColor] = MarkupStyle.isLight(mark.color)
                ? NSColor.black.withAlphaComponent(0.75) : NSColor.white
            attributes[.strokeWidth] = 22
        }
        return attributes
    }

    private func textRect(_ mark: Markup) -> CGRect {
        let origin = mark.points.first ?? .zero
        let text = mark.text.isEmpty ? " " : mark.text
        let size = (text as NSString).boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                                   options: [.usesLineFragmentOrigin], attributes: textAttributes(mark, halo: false)).size
        return CGRect(origin: origin, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
    }

    private func drawText(_ mark: Markup, in ctx: CGContext) {
        guard !mark.text.isEmpty else { return }
        let rect = textRect(mark)
        withAppKit(ctx) {
            // An outline in a contrasting colour first, so the text reads on any background.
            (mark.text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: textAttributes(mark, halo: true))
            (mark.text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: textAttributes(mark, halo: false))
        }
    }

    private func drawStep(_ mark: Markup, color: CGColor, in ctx: CGContext) {
        guard let centre = mark.points.first else { return }
        let r = stepRadius(mark)
        let circle = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: unit), blur: 3 * unit, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(color)
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(max(1.5, r * 0.12))
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let font = NSFont.systemFont(ofSize: r * 1.05, weight: .heavy)
        let textColor: NSColor = MarkupStyle.isLight(mark.color) ? .black : .white
        let string = NSAttributedString(string: "\(mark.number)", attributes: [.font: font, .foregroundColor: textColor])
        let size = string.size()
        withAppKit(ctx) {
            string.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
        }
    }

    /// Runs AppKit text drawing in `ctx`, which is flipped (origin at the top left).
    private func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws an image upright in a context whose origin is at the top left.
    public static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// The image in large squares, made once and shared by every pixelate mark.
    public func pixelated() -> CGImage? {
        if let pixelatedImage { return pixelatedImage }
        let input = CIImage(cgImage: image)
        let scale = max(8, 10 * unit)
        let output = input.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: input.extent)
        let result = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent)
        pixelatedImage = result
        return result
    }

    // MARK: Geometry

    public static func rect(_ points: [CGPoint]) -> CGRect {
        guard let a = points.first, let b = points.last else { return .null }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    public func path(for mark: Markup) -> CGPath {
        let path = CGMutablePath()
        switch mark.kind {
        case .rectangle:
            let rect = Self.rect(mark.points)
            let radius = min(lineWidth(mark) * 1.2, rect.width / 2, rect.height / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            path.addEllipse(in: Self.rect(mark.points))
        case .pixelate:
            path.addRect(Self.rect(mark.points))
        case .line, .arrow:
            if let a = mark.points.first, let b = mark.points.last {
                path.move(to: a)
                path.addLine(to: b)
            }
        case .pen, .highlighter:
            Self.addSmoothCurve(through: mark.points, to: path)
        case .text:
            path.addRect(textRect(mark))
        case .step:
            if let c = mark.points.first {
                let r = stepRadius(mark)
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
        return path
    }

    /// A curve through the midpoints of the points, which smooths the jitter of a hand-drawn line.
    static func addSmoothCurve(through points: [CGPoint], to path: CGMutablePath) {
        guard let first = points.first else { return }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.count == 2 ? points[1] : CGPoint(x: first.x + 0.01, y: first.y))
            return
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
    }

    /// The area a mark covers, including its stroke.
    public func bounds(of mark: Markup) -> CGRect {
        let box = path(for: mark).boundingBoxOfPath
        switch mark.kind {
        case .text, .step, .pixelate: return box
        case .arrow: return box.insetBy(dx: -lineWidth(mark) * 2, dy: -lineWidth(mark) * 2)
        default: return box.insetBy(dx: -lineWidth(mark) / 2, dy: -lineWidth(mark) / 2)
        }
    }

    /// Whether `point` is on the mark, within `tolerance` image pixels.
    public func hitTest(_ mark: Markup, at point: CGPoint, tolerance: CGFloat) -> Bool {
        switch mark.kind {
        case .text, .step, .pixelate:
            return bounds(of: mark).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rectangle, .ellipse:
            return (mark.filled && path(for: mark).contains(point)) || stroke(of: mark, tolerance: tolerance).contains(point)
        default:
            return stroke(of: mark, tolerance: tolerance).contains(point)
        }
    }

    private func stroke(of mark: Markup, tolerance: CGFloat) -> CGPath {
        path(for: mark).copy(strokingWithWidth: lineWidth(mark) + tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// The topmost mark at `point`.
    public func mark(at point: CGPoint, in marks: [Markup], tolerance: CGFloat) -> Markup? {
        marks.last { hitTest($0, at: point, tolerance: tolerance) }
    }

    // MARK: Saving

    /// The image with its marks, cut to `crop` if given.
    public func render(_ marks: [Markup], crop: CGRect? = nil) -> CGImage? {
        let area = (crop ?? bounds).intersection(bounds).integral
        guard area.width >= 1, area.height >= 1 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        Self.drawImage(image, in: bounds, ctx: ctx)
        draw(marks, in: ctx)
        return ctx.makeImage()
    }

    public static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// How scrolling over a floating image changes its opacity: up makes it clearer (more opaque),
/// down fainter, slowly enough to stop where you want.
public enum FloatOpacity {
    public static let range: ClosedRange<CGFloat> = 0.1...1

    /// `delta` is the event's vertical scroll, `inverted` whether natural scrolling flipped it,
    /// and `precise` whether it came from a trackpad (points) rather than a mouse wheel (lines).
    public static func after(_ opacity: CGFloat, delta: CGFloat, precise: Bool, inverted: Bool) -> CGFloat {
        // The direction the fingers or the wheel moved, whatever the scrolling setting.
        let up = inverted ? -delta : delta
        guard up != 0 else { return opacity }
        // A trackpad gives many small steps: 100 points of swipe is 20%. A wheel notch is 5%.
        let change = precise ? max(min(up * 0.002, 0.04), -0.04) : (up > 0 ? 0.05 : -0.05)
        return min(max(opacity + change, range.lowerBound), range.upperBound)
    }
}
