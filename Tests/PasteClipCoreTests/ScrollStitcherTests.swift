import CoreGraphics
import Foundation
import Testing
@testable import PasteClipCore

/// A tall page of pseudo-random blocks, so every stretch of rows is different.
private func page(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var seed: UInt64 = 42
    func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 256) / 255 }
    for y in stride(from: 0, to: height, by: 6) {
        for x in stride(from: 0, to: width, by: 9) {
            ctx.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 9, height: 6))
        }
    }
    return ctx.makeImage()!
}

/// The window onto the page that starts `top` rows from its top.
private func frame(of page: CGImage, top: Int, height: Int) -> CGImage {
    page.cropping(to: CGRect(x: 0, y: top, width: page.width, height: height))!
}

@Test func stitchesScrolledFramesIntoTheWholePage() throws {
    let whole = page(width: 240, height: 1400)
    let stitcher = try #require(ScrollStitcher(first: frame(of: whole, top: 0, height: 500)))
    for top in [130, 260, 410, 600, 800, 900] {
        let expected = top - (stitcher.height - 500)
        #expect(stitcher.add(frame(of: whole, top: top, height: 500)) == .added(rows: expected))
    }
    #expect(stitcher.height == 1400)
    #expect(stitcher.frameCount == 7)
    let joined = try #require(stitcher.render())
    #expect(joined.height == 1400)
    // Row for row the same as the page.
    let a = NSDataFromImage(joined), b = NSDataFromImage(whole)
    #expect(a == b)
}

@Test func ignoresFramesThatDidNotMoveOrWentUp() throws {
    let whole = page(width: 240, height: 1000)
    let stitcher = try #require(ScrollStitcher(first: frame(of: whole, top: 200, height: 500)))
    #expect(stitcher.add(frame(of: whole, top: 200, height: 500)) == .unchanged)
    #expect(stitcher.add(frame(of: whole, top: 100, height: 500)) == .lost)
    #expect(stitcher.height == 500)
    // Scrolled farther than the frames share: wait for it to come back into range.
    #expect(stitcher.add(frame(of: whole, top: 590, height: 400)) == .lost)
}

private func NSDataFromImage(_ image: CGImage) -> Data {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: ctx.data!, count: image.width * image.height * 4)
}
