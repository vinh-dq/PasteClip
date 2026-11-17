import AppKit
import Foundation
import Testing
@testable import PasteClipCore

/// A white image of the given size.
private func blankImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func isWhite(_ c: (r: Int, g: Int, b: Int)) -> Bool { min(c.r, c.g, c.b) >= 250 }

/// The colour at a pixel, counted from the top left.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let rep = NSBitmapImageRep(cgImage: image)
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

@Test func rendersMarksWhereTheyWereDrawn() throws {
    let renderer = MarkupRenderer(image: blankImage(width: 200, height: 100))
    // A filled red box in the top left quarter, measured from the top.
    let box = Markup(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], color: 0, size: 1, filled: true)
    let image = try #require(renderer.render([box]))
    #expect(image.width == 200 && image.height == 100)
    let inside = pixel(image, 35, 25)
    #expect(inside.r > 240 && inside.g < 90 && inside.b < 90)
    let outside = pixel(image, 35, 80)
    #expect(isWhite(outside))
}

@Test func cropsTheSavedImage() throws {
    let renderer = MarkupRenderer(image: blankImage(width: 200, height: 100))
    let box = Markup(kind: .rectangle, points: [CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 100)], color: 4, size: 1, filled: true)
    let image = try #require(renderer.render([box], crop: CGRect(x: 90, y: 40, width: 40, height: 30)))
    #expect(image.width == 40 && image.height == 30)
    // The crop's top left is outside the box, its bottom right inside.
    #expect(isWhite(pixel(image, 2, 2)))
    #expect(pixel(image, 35, 25).b > 200)
    #expect(MarkupRenderer.pngData(image) != nil)
}

@Test func findsTheMarkUnderThePointer() {
    let renderer = MarkupRenderer(image: blankImage(width: 400, height: 300))
    let line = Markup(kind: .line, points: [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 10)], color: 0, size: 1)
    let outline = Markup(kind: .rectangle, points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)], color: 1, size: 1)
    var filled = outline
    filled.id = UUID()
    filled.filled = true
    let marks = [line, outline]
    #expect(renderer.mark(at: CGPoint(x: 100, y: 12), in: marks, tolerance: 3)?.id == line.id)
    #expect(renderer.mark(at: CGPoint(x: 50, y: 100), in: marks, tolerance: 3)?.id == outline.id)
    // The middle of an outlined box is empty, of a filled one isn't.
    #expect(renderer.mark(at: CGPoint(x: 100, y: 100), in: marks, tolerance: 3) == nil)
    #expect(renderer.mark(at: CGPoint(x: 100, y: 100), in: [filled], tolerance: 3)?.id == filled.id)
}

@Test func toolsMapToTheirMarksAndKeys() {
    #expect(MarkupTool.select.kind == nil)
    #expect(MarkupTool.crop.kind == nil)
    #expect(MarkupTool.arrow.kind == .arrow)
    #expect(MarkupTool.step.kind == .step)
    // Every tool has a key of its own.
    #expect(Set(MarkupTool.allCases.map(\.key)).count == MarkupTool.allCases.count)
}

@Test func scrollingUpMakesAFloatingImageClearer() {
    // A trackpad swipe up with natural scrolling arrives as a negative, inverted delta.
    #expect(FloatOpacity.after(0.5, delta: -10, precise: true, inverted: true) > 0.5)
    #expect(FloatOpacity.after(0.5, delta: 10, precise: true, inverted: true) < 0.5)
    // A mouse wheel without natural scrolling: up is positive, one notch is 5%.
    #expect(abs(FloatOpacity.after(0.5, delta: 1, precise: false, inverted: false) - 0.55) < 0.001)
    // A fast swipe changes it a little at a time, and it stays in range.
    #expect(FloatOpacity.after(0.5, delta: -500, precise: true, inverted: true) <= 0.54 + 0.001)
    #expect(FloatOpacity.after(0.12, delta: -5, precise: false, inverted: false) == FloatOpacity.range.lowerBound)
    #expect(FloatOpacity.after(1, delta: 5, precise: false, inverted: false) == 1)
}

@Test func addsAnEditedImageAsANewClip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PasteClipTests-\(UUID().uuidString)", isDirectory: true)
    let store = ClipStore(directory: dir, pasteboard: NSPasteboard(name: .init("PasteClipTests-\(UUID().uuidString)")))
    let png = try #require(MarkupRenderer.pngData(blankImage(width: 20, height: 10)))
    let first = try #require(store.addImage(png, title: "Shot"))
    let second = try #require(store.addImage(png))
    // Images are never merged, even when they're the same.
    #expect(store.items.map(\.id) == [second.id, first.id])
    #expect(first.kind == .image && first.title == "Shot")
    let url = try #require(store.imageURL(for: first))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(store.image(for: first)?.size.width == 20)
}

@Test func aCopiedImageFileCountsAsAnImage() {
    #expect(ClipItem(kind: .file, filePaths: ["/tmp/Screenshot@2x.png"]).isImage)
    #expect(ClipItem(kind: .file, filePaths: ["/tmp/photo.JPG"]).copiedImagePath == "/tmp/photo.JPG")
    #expect(!ClipItem(kind: .file, filePaths: ["/tmp/notes.txt"]).isImage)
    #expect(!ClipItem(kind: .file, filePaths: ["/tmp/a.png", "/tmp/b.png"]).isImage)
    #expect(ClipItem(kind: .image).isImage)
    #expect(!ClipItem(kind: .text, text: "a.png").isImage)
}

@Test func imageShortcutsDefaultAndCanBeChanged() {
    let defaults = UserDefaults(suiteName: "PasteClipTests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.floatImageKey?.display == "⇧⌘P")
    #expect(settings.screenshotHotKey?.display == "⇧⌘1")
    #expect(settings.screenshotAction == .copy)
    settings.screenshotHotKey = KeyCombo(keyCode: 0, modifiers: KeyCombo.control | KeyCombo.shift, keyName: "A")
    settings.screenshotAction = .edit
    settings.floatImageKey = nil
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.screenshotHotKey?.display == "⌃⇧A")
    #expect(reloaded.screenshotAction == .edit)
    #expect(reloaded.floatImageKey == nil)
    reloaded.resetShortcuts()
    #expect(reloaded.floatImageKey?.display == "⇧⌘P" && reloaded.screenshotHotKey?.display == "⇧⌘1")
}

@Test func draggingACornerScalesTextFromTheOppositeCorner() {
    let renderer = MarkupRenderer(image: blankImage(width: 800, height: 600))
    var text = Markup(kind: .text, points: [CGPoint(x: 100, y: 100)], color: 0, size: 1)
    text.text = "Hello"
    let box = renderer.bounds(of: text)
    // The bottom right corner (2) dragged to twice the size: the top left stays where it was.
    let bigger = renderer.scaled(text, box: box, handle: 2,
                                 to: CGPoint(x: box.minX + box.width * 2, y: box.minY + box.height * 2))
    #expect(abs(bigger.scale - 2) < 0.001)
    #expect(bigger.points == [CGPoint(x: 100, y: 100)])
    #expect(abs(renderer.fontSize(bigger) - renderer.fontSize(text) * 2) < 0.001)
    // The top left corner (0) dragged inwards to half: the bottom right stays put.
    let smaller = renderer.scaled(text, box: box, handle: 0,
                                  to: CGPoint(x: box.maxX - box.width / 2, y: box.maxY - box.height / 2))
    #expect(abs(smaller.scale - 0.5) < 0.001)
    #expect(abs(smaller.points[0].x - (box.maxX - box.width / 2)) < 0.001)
    // Never smaller than the limit, even dragged past the opposite corner.
    let tiny = renderer.scaled(text, box: box, handle: 2, to: CGPoint(x: 0, y: 0))
    #expect(tiny.scale == MarkupRenderer.scaleRange.lowerBound)
    // A number grows around the corner too, and its circle with it.
    var step = Markup(kind: .step, points: [CGPoint(x: 300, y: 300)], color: 4, size: 1)
    step.number = 1
    let stepBox = renderer.bounds(of: step)
    let bigStep = renderer.scaled(step, box: stepBox, handle: 1, to: CGPoint(x: stepBox.maxX + stepBox.width, y: stepBox.minY - stepBox.height))
    #expect(abs(bigStep.scale - 2) < 0.001)
    #expect(abs(renderer.bounds(of: bigStep).minX - stepBox.minX) < 0.5)
    #expect(abs(renderer.bounds(of: bigStep).maxY - stepBox.maxY) < 0.5)
}

@Test func theImagesFilterIncludesCopiedImageFiles() {
    #expect(TypeFilter.image.matches(ClipItem(kind: .image)))
    #expect(TypeFilter.image.matches(ClipItem(kind: .file, filePaths: ["/tmp/Screenshot@2x.png"])))
    #expect(!TypeFilter.image.matches(ClipItem(kind: .file, filePaths: ["/tmp/notes.txt"])))
    #expect(!TypeFilter.image.matches(ClipItem(kind: .text, text: "photo.png")))
}

@Test func textInAnImageIsReadOnDemandAndKept() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PasteClipTests-\(UUID().uuidString)", isDirectory: true)
    let store = ClipStore(directory: dir, pasteboard: NSPasteboard(name: .init("PasteClipTests-\(UUID().uuidString)")))
    store.recognizesText = false
    // An image with a line of text, as a screenshot would have.
    let size = NSSize(width: 700, height: 100)
    let picture = NSImage(size: size)
    picture.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    ("Translate this sentence" as NSString).draw(at: NSPoint(x: 20, y: 30),
                                                 withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
    picture.unlockFocus()
    let cgImage = try #require(picture.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let png = try #require(MarkupRenderer.pngData(cgImage))
    let item = try #require(store.addImage(png))
    // Not read when it was added, since reading is turned off.
    #expect(item.translatableText == nil)
    let text: String? = await withCheckedContinuation { done in
        DispatchQueue.main.async { store.readText(in: item) { done.resume(returning: $0) } }
    }
    #expect(text?.contains("Translate this sentence") == true)
    // Kept with the clip, so translating it again needs no second read.
    #expect(store.item(withID: item.id)?.translatableText == text)
    // A clip that isn't a picture has nothing to read.
    let none: String? = await withCheckedContinuation { done in
        store.readText(in: ClipItem(kind: .text, text: "hi")) { done.resume(returning: $0) }
    }
    #expect(none == nil)
}

@Test func anImageLentToTheClipboardIsntSaved() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PasteClipTests-\(UUID().uuidString)", isDirectory: true)
    let pasteboard = NSPasteboard(name: .init("PasteClipTests-\(UUID().uuidString)"))
    let store = ClipStore(directory: dir, pasteboard: pasteboard)
    let png = try #require(MarkupRenderer.pngData(blankImage(width: 20, height: 10)))
    store.copyImageWithoutSaving(png)
    #expect(pasteboard.data(forType: .png) == png)
    #expect(pasteboard.data(forType: .tiff) != nil)
    store.poll()
    #expect(store.items.isEmpty)
}
