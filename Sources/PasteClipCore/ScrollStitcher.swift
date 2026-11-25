import CoreGraphics
import Foundation

/// Joins screenshots of one region taken while the content scrolls down into a single tall image.
/// Each new frame is matched against the previous one to find how far the content moved; only the
/// rows that are new are kept. Frames that didn't move, moved up or sideways, or can't be matched
/// (scrolled further than the overlap) are ignored, and the next one is tried against the same frame.
public final class ScrollStitcher {
    public enum Result: Equatable {
        case added(rows: Int)
        /// Nothing new: the content hasn't moved.
        case unchanged
        /// Moved up, or too far (less than a fifth of the frame in common) to be sure where it joins.
        case lost
    }

    /// Pixels; the width of the first frame, which every later frame must share.
    public let width: Int
    private let frameHeight: Int
    private var strips: [CGImage]
    private var last: Gray
    private var lastCoarse: Gray
    public private(set) var height: Int
    public private(set) var frameCount = 1

    public init?(first: CGImage) {
        guard first.width >= 16, first.height >= 16,
              let full = Gray(first, scale: 1), let coarse = Gray(first, scale: Self.coarseScale)
        else { return nil }
        width = first.width
        frameHeight = first.height
        height = first.height
        strips = [first]
        last = full
        lastCoarse = coarse
    }

    private static let coarseScale = 4

    @discardableResult
    public func add(_ frame: CGImage) -> Result {
        guard frame.width == width, frame.height == frameHeight,
              let full = Gray(frame, scale: 1), let coarse = Gray(frame, scale: Self.coarseScale)
        else { return .lost }
        // Same picture: nothing to add (a blank page matches at every shift, so this goes first).
        if Gray.difference(lastCoarse, coarse, shift: 0) < 0.4, Gray.difference(last, full, shift: 0) < 0.6 { return .unchanged }

        // Coarse search over the whole range, then the exact row around the best.
        let minOverlap = max(8, coarse.height / 5)
        var best = (shift: 0, error: Double.infinity)
        for shift in 1...(coarse.height - minOverlap) {
            let error = Gray.difference(lastCoarse, coarse, shift: shift)
            if error < best.error { best = (shift, error) }
        }
        // Shrunk, a shift that isn't a multiple of the scale blurs the match, so this one is loose.
        guard best.error < Self.maxError * 2.5 else { return .lost }
        let approx = best.shift * Self.coarseScale
        var exact = (shift: 0, error: Double.infinity)
        for shift in max(1, approx - Self.coarseScale)...min(full.height - minOverlap * Self.coarseScale, approx + Self.coarseScale) {
            let error = Gray.difference(last, full, shift: shift)
            if error < exact.error { exact = (shift, error) }
        }
        guard exact.shift > 0, exact.error < Self.maxError,
              let strip = frame.cropping(to: CGRect(x: 0, y: frameHeight - exact.shift, width: width, height: exact.shift))
        else { return .lost }
        strips.append(strip)
        height += exact.shift
        frameCount += 1
        last = full
        lastCoarse = coarse
        return .added(rows: exact.shift)
    }

    /// Mean difference (of 255) above which two frames are not taken to overlap. Sticky bars and
    /// animated spots add some, so it is not close to zero.
    private static let maxError = 14.0

    /// The joined image, or nil if it is too tall to draw.
    public func render() -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: strips[0].colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var top = height
        for strip in strips {
            top -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: top, width: strip.width, height: strip.height))
        }
        return context.makeImage()
    }

    /// An 8-bit grey copy of an image, optionally shrunk by `scale`.
    struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ image: CGImage, scale: Int) {
            let w = image.width / scale, h = image.height / scale
            guard w > 0, h > 0 else { return nil }
            var data = [UInt8](repeating: 0, count: w * h)
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w
            height = h
            pixels = data
        }

        /// Mean absolute difference between `b`'s rows from the top and `a`'s rows from `shift` down:
        /// what `b` shows if the content moved up by `shift`. Every second row and fourth column.
        static func difference(_ a: Gray, _ b: Gray, shift: Int) -> Double {
            let rows = a.height - shift
            guard rows > 0 else { return .infinity }
            var total = 0, count = 0
            a.pixels.withUnsafeBufferPointer { pa in
                b.pixels.withUnsafeBufferPointer { pb in
                    var row = 0
                    while row < rows {
                        let ia = (row + shift) * a.width, ib = row * b.width
                        var x = 0
                        while x < a.width {
                            total += abs(Int(pa[ia + x]) - Int(pb[ib + x]))
                            count += 1
                            x += 4
                        }
                        row += 2
                    }
                }
            }
            return Double(total) / Double(max(count, 1))
        }
    }
}
