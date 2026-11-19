import AppKit
import Foundation
import Testing
@testable import PasteClipCore

/// A line as Vision gives it: `rect` in pixels from the top left of a 1000 × 1000 image.
private func line(_ text: String, _ rect: CGRect, size: CGFloat = 1000) -> TextRecognizer.Line {
    TextRecognizer.Line(text: text, box: CGRect(x: rect.minX / size, y: 1 - rect.maxY / size,
                                                width: rect.width / size, height: rect.height / size), script: .latin)
}

@Test func linesOfAParagraphJoinButLabelsStayApart() {
    let lines = [
        // A paragraph wrapped over three lines.
        line("PasteClip keeps everything you copy so you can", CGRect(x: 40, y: 100, width: 600, height: 24)),
        line("find it again later and paste it into any app", CGRect(x: 40, y: 130, width: 580, height: 24)),
        line("without leaving the keyboard.", CGRect(x: 40, y: 160, width: 330, height: 24)),
        // A menu: short entries one under another.
        line("Copy", CGRect(x: 40, y: 300, width: 60, height: 20)),
        line("Paste", CGRect(x: 40, y: 326, width: 64, height: 20)),
        // A heading above text, much larger.
        line("Settings", CGRect(x: 700, y: 100, width: 200, height: 48)),
        line("Choose how PasteClip pastes clips into apps", CGRect(x: 700, y: 156, width: 280, height: 20)),
    ]
    let blocks = ImageTranslation.blocks(from: lines, size: CGSize(width: 1000, height: 1000))
    #expect(blocks.map(\.text) == [
        "PasteClip keeps everything you copy so you can find it again later and paste it into any app without leaving the keyboard.",
        "Settings",
        "Choose how PasteClip pastes clips into apps",
        "Copy",
        "Paste",
    ])
    let paragraph = blocks[0]
    #expect(paragraph.lineCount == 3)
    #expect(abs(paragraph.rect.minY - 100) < 0.5 && abs(paragraph.rect.maxY - 184) < 0.5)
    #expect(abs(paragraph.lineHeight - 24) < 0.5)
}

@Test func translationsComeBackOnePerBlock() {
    let blocks = [TextBlock(text: "Hello\nthere", rect: .zero, lineHeight: 10, lineCount: 1),
                  TextBlock(text: "World", rect: .zero, lineHeight: 10, lineCount: 1)]
    #expect(ImageTranslation.joined(blocks) == "Hello there\nWorld")
    #expect(ImageTranslation.split("Xin chào\n\n Thế giới ", count: 2) == ["Xin chào", "Thế giới"])
    // A service that merged the lines can't be matched up.
    #expect(ImageTranslation.split("Xin chào thế giới", count: 2) == nil)
}

@Test func theTranslationCoversTheOriginalInItsColours() throws {
    // Dark blue background with white text, as in a dark app.
    let width = 400, height = 120
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.15, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("WWWWWWWW" as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 30),
                                                                         .foregroundColor: NSColor.white])
    NSGraphicsContext.restoreGraphicsState()
    let image = try #require(ctx.makeImage())
    // The text sits about 34–70 from the top.
    let block = TextBlock(text: "WWWWWWWW", rect: CGRect(x: 18, y: 36, width: 190, height: 34), lineHeight: 34, lineCount: 1)
    let translated = try #require(ImageTranslation.render(image, blocks: [block], translations: ["i"]))
    #expect(translated.width == width && translated.height == height)
    let rep = NSBitmapImageRep(cgImage: translated)
    // Where the wide W's were, past the short translation, is background again.
    let covered = try #require(rep.colorAt(x: 180, y: 52)?.usingColorSpace(.sRGB))
    let background = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 380, y: 10)?.usingColorSpace(.sRGB))
    #expect(abs(covered.redComponent - background.redComponent) < 0.03)
    #expect(abs(covered.blueComponent - background.blueComponent) < 0.03)
    // Nothing translated, nothing changes.
    let untouched = try #require(ImageTranslation.render(image, blocks: [block], translations: [""]))
    let w = try #require(NSBitmapImageRep(cgImage: untouched).colorAt(x: 180, y: 52)?.usingColorSpace(.sRGB))
    let original = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 180, y: 52)?.usingColorSpace(.sRGB))
    #expect(abs(w.redComponent - original.redComponent) < 0.02)
}

@Test func translatingTheScreenTakesShiftCommand2() throws {
    let fresh = AppSettings(defaults: Scratch.defaults())
    #expect(fresh.translateScreenHotKey?.display == "⇧⌘2")
    #expect(fresh.captureTextHotKey?.display == "⌥⇧⌘2")
    // Someone who saved ⇧⌘2 for copying text (Reset Shortcuts saves every default) gets it moved.
    let defaults = Scratch.defaults()
    defaults.set(try JSONEncoder().encode(KeyCombo.translateScreen), forKey: "captureTextHotKey")
    let updated = AppSettings(defaults: defaults)
    #expect(updated.captureTextHotKey == .captureText)
    #expect(updated.translateScreenHotKey == .translateScreen)
    // A shortcut of their own choosing stays.
    let own = Scratch.defaults()
    let mine = KeyCombo(keyCode: 0, modifiers: KeyCombo.control | KeyCombo.option, keyName: "A")
    own.set(try JSONEncoder().encode(mine), forKey: "captureTextHotKey")
    #expect(AppSettings(defaults: own).captureTextHotKey == mine)
}

@Test func eachBlockIsInOneOfTheLanguagesTextIsReadIn() {
    let read = ["en-US", "vi-VT", "ja-JP", "zh-Hans"]
    func language(_ text: String) -> String? { ImageTranslation.language(of: text, allowed: read) }
    #expect(language("設定を開く") == "ja-JP")
    #expect(language("ドリアとグラタン各2食セットST_testing 6") == "ja-JP")
    #expect(language("Đăng nhập") == "vi-VT")
    #expect(language("Our team finished the new search feature this week.") == "en-US")
    // Short words go by the likeliest language read, never a made-up one.
    #expect(language("Yes") == "en-US")
    #expect(language("[website]") == "en-US")
    #expect(language("Default") == "en-US")
    // Nothing to translate in a number, an address or a file name.
    #expect(language("2,480") == nil)
    #expect(language("vinh.dang+3@classmethod.vn") == nil)
    #expect(language("https://example.com/a") == nil)
    #expect(language("www.example.com") == nil)
    #expect(language("report.xlsx") == nil)
    // But a sentence with an address in it, or a word ending a sentence, is translated.
    #expect(language("Write to us at help@example.com") == "en-US")
    #expect(language("Done.") == "en-US")
    // Only languages that are read count: no Korean in the list, no Korean answer.
    #expect(ImageTranslation.language(of: "Hello there", allowed: ["vi-VT", "ja-JP"]).map { ["vi-VT", "ja-JP"].contains($0) } == true)
    // A mostly Vietnamese image with Japanese in it goes into Vietnamese, leaving the Vietnamese alone.
    let languages: [String?] = ["vi-VT", "ja-JP", "vi-VT", "en-US", nil]
    #expect(ImageTranslation.target(for: languages, priority: ["vi", "en", "ja"]) == "vi")
    #expect(ImageTranslation.isAlready("vi-VT", in: "vi") && !ImageTranslation.isAlready("ja-JP", in: "vi"))
    // All of it in Vietnamese: into the next language.
    #expect(ImageTranslation.target(for: ["vi-VT", "vi-VT"], priority: ["vi", "en", "ja"]) == "en")
}

@Test func aLongTranslationOfALineNeverCoversTheLineBelow() throws {
    // Two lines of small dark text on white, close together.
    let width = 300, height = 60
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(.black)
    ctx.fill(CGRect(x: 10, y: height - 22, width: 100, height: 10))   // line 1, 12…22 from the top
    ctx.fill(CGRect(x: 10, y: height - 38, width: 100, height: 10))   // line 2, 28…38 from the top
    let image = try #require(ctx.makeImage())
    let first = TextBlock(text: "one", rect: CGRect(x: 10, y: 12, width: 100, height: 10), lineHeight: 10, lineCount: 1)
    let second = TextBlock(text: "two", rect: CGRect(x: 10, y: 28, width: 100, height: 10), lineHeight: 10, lineCount: 1)
    let long = "a translation much longer than the line it replaces, which can't wrap onto the next one"
    let result = try #require(ImageTranslation.render(image, blocks: [first, second], translations: [long, ""]))
    // The second line, left untranslated, is still all there.
    let rep = NSBitmapImageRep(cgImage: result)
    for x in stride(from: 12, to: 108, by: 8) {
        let c = try #require(rep.colorAt(x: x, y: 33)?.usingColorSpace(.sRGB))
        #expect(c.redComponent < 0.2, "x \(x)")
    }
}

@Test func listEntriesStaySeparateEvenWhenLong() {
    let lines = [
        line("Quarterly budget review.xlsx", CGRect(x: 20, y: 184, width: 170, height: 14)),
        line("Design system tokens.fig", CGRect(x: 20, y: 200, width: 150, height: 14)),
        line("Meeting notes - product sync.docx", CGRect(x: 20, y: 216, width: 200, height: 14)),
        line("アカウント情報を更新する", CGRect(x: 20, y: 52, width: 160, height: 14)),
        line("通知を受け取る", CGRect(x: 20, y: 70, width: 92, height: 14)),
    ]
    let blocks = ImageTranslation.blocks(from: lines, size: CGSize(width: 1000, height: 1000))
    #expect(blocks.count == 5)
}

@Test func linesOfAListGetTheSameSize() {
    let list = [12.0, 15.0, 13.0, 18.0].enumerated().map { i, h in
        TextBlock(text: "Item \(i)", rect: CGRect(x: 20, y: 50 + Double(i) * 18, width: 100, height: h), lineHeight: h, lineCount: 1)
    }
    let heading = TextBlock(text: "Title", rect: CGRect(x: 20, y: 10, width: 100, height: 30), lineHeight: 30, lineCount: 1)
    let evened = ImageTranslation.evenedOut(list + [heading])
    #expect(Set(evened.prefix(4).map(\.lineHeight)) == [15])
    // A heading twice the size keeps its own.
    #expect(evened[4].lineHeight == 30)
}

@Test func labelsLinedUpOnTheRightStayThatWay() throws {
    let width = 400, height = 100
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(ctx.makeImage())
    // Two labels ending at x = 300, one much shorter, as beside a form's fields.
    let long = TextBlock(text: "Enable Product", rect: CGRect(x: 150, y: 10, width: 150, height: 20), lineHeight: 20, lineCount: 1)
    let short = TextBlock(text: "Name", rect: CGRect(x: 240, y: 60, width: 60, height: 20), lineHeight: 20, lineCount: 1)
    let result = try #require(ImageTranslation.render(image, blocks: [long, short], translations: ["", "Tên"]))
    // The translation of the short one ends where it did, so ink sits just left of x = 300…
    let rep = NSBitmapImageRep(cgImage: result)
    let inkNearRight = (240..<300).contains { x in (60..<80).contains { y in
        (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5 } }
    #expect(inkNearRight)
    // …and none at its old left edge, where a left-aligned "Tên" would have started.
    let inkAtLeft = (240..<250).contains { x in (60..<80).contains { y in
        (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5 } }
    #expect(!inkAtLeft)
}

@Test func savingTranslatedImagesCanBeTurnedOff() {
    let defaults = Scratch.defaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.saveImageTranslations)
    settings.saveImageTranslations = false
    #expect(!AppSettings(defaults: defaults).saveImageTranslations)
    // Text translations keep their own setting.
    #expect(AppSettings(defaults: defaults).saveTranslations)
}

@Test func translatingImagesInTheShelfHasItsOwnShortcut() throws {
    let defaults = Scratch.defaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.translateImageKey?.display == "⌃⌥Space")
    settings.translateImageKey = KeyCombo(keyCode: 17, modifiers: KeyCombo.control | KeyCombo.shift, keyName: "T")
    #expect(AppSettings(defaults: defaults).translateImageKey?.display == "⌃⇧T")
    settings.translateImageKey = nil
    #expect(AppSettings(defaults: defaults).translateImageKey == nil)
    settings.resetShortcuts()
    #expect(AppSettings(defaults: defaults).translateImageKey == .translateImage)
}

@Test func lettersOnAGradientAreTakenOutWithoutAPatch() throws {
    // A horizontal gradient from dark red to light yellow, with black text across it.
    let width = 400, height = 100
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(srgbRed: 0.5, green: 0.1, blue: 0.1, alpha: 1),
                                       CGColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("MMMMMMMMMM" as NSString).draw(at: NSPoint(x: 40, y: 34), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28),
                                                                           .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    let image = try #require(ctx.makeImage())
    let block = TextBlock(text: "MMMMMMMMMM", rect: CGRect(x: 38, y: 30, width: 270, height: 38), lineHeight: 38, lineCount: 1)
    let translated = try #require(ImageTranslation.render(image, blocks: [block], translations: ["."]))
    let rep = NSBitmapImageRep(cgImage: translated)
    // Along the middle of where the letters were, the gradient carries on: each point close to
    // the gradient's colour there (read just above the text), the left end darker than the right.
    let original = NSBitmapImageRep(cgImage: image)
    for x in [120, 200, 290] {
        let now = try #require(rep.colorAt(x: x, y: 50)?.usingColorSpace(.sRGB))
        let above = try #require(original.colorAt(x: x, y: 12)?.usingColorSpace(.sRGB))
        #expect(abs(now.redComponent - above.redComponent) < 0.06, "x \(x)")
        #expect(abs(now.greenComponent - above.greenComponent) < 0.06, "x \(x)")
    }
}

@Test func aTurnedLineKeepsItsAngle() throws {
    // A line turned 30° clockwise on the image (Vision's corners, origin at the bottom left).
    let angle = CGFloat.pi / 6
    let centre = CGPoint(x: 500, y: 500), w: CGFloat = 300, h: CGFloat = 40
    func corner(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        let x = centre.x + dx * cos(angle) - dy * sin(angle), y = centre.y + dx * sin(angle) + dy * cos(angle)
        return CGPoint(x: x / 1000, y: 1 - y / 1000)
    }
    let quad = [corner(-w / 2, -h / 2), corner(w / 2, -h / 2), corner(w / 2, h / 2), corner(-w / 2, h / 2)]
    var turned = line("Grand opening sale", CGRect(x: 350, y: 400, width: 300, height: 200))
    turned.quad = quad
    let blocks = ImageTranslation.blocks(from: [turned, line("Open daily", CGRect(x: 350, y: 640, width: 120, height: 24))],
                                         size: CGSize(width: 1000, height: 1000))
    let block = try #require(blocks.first { $0.text == "Grand opening sale" })
    #expect(abs(block.angle - angle) < 0.01)
    #expect(abs(block.rect.width - w) < 1 && abs(block.rect.height - h) < 1)
    #expect(abs(block.rect.midX - centre.x) < 1 && abs(block.rect.midY - centre.y) < 1)
    #expect(blocks.count == 2)
}

@Test func verticalColumnsBecomeOneBlockReadFromTheRight() {
    func column(_ text: String, x: CGFloat) -> TextRecognizer.Line {
        TextRecognizer.Line(text: text, box: CGRect(x: x / 1000, y: 1 - 400.0 / 1000, width: 0.03, height: 0.3), script: .hanAndKana)
    }
    let blocks = ImageTranslation.blocks(from: [column("右の列です", x: 540), column("左の列です", x: 500),
                                                column("離れた列", x: 100)],
                                         size: CGSize(width: 1000, height: 1000))
    #expect(blocks.count == 2)
    let bubble = blocks.first { $0.lineCount == 2 }
    #expect(bubble?.text == "右の列です左の列です")
    #expect(bubble?.vertical == true)
    // Read from the bottom up, as Vision gives a column, with "ー" taken for an I.
    var upward = column("ルIセな別特", x: 300)
    upward.quad = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.3, y: 0.6), CGPoint(x: 0.33, y: 0.6), CGPoint(x: 0.33, y: 0.3)]
    #expect(ImageTranslation.blocks(from: [upward], size: CGSize(width: 1000, height: 1000)).first?.text == "特別なセール")
    // A digit after a kanji stays a digit.
    #expect(ImageTranslation.blocks(from: [column("第1章です", x: 300)], size: CGSize(width: 1000, height: 1000)).first?.text == "第1章です")
}

@Test func paragraphsVisionFoundKeepColumnsApart() {
    // Two columns of one sentence each, close enough that the lines alone would join them.
    let lines = [
        line("The first column runs on and on across", CGRect(x: 40, y: 100, width: 400, height: 24)),
        line("and ends here.", CGRect(x: 40, y: 130, width: 160, height: 24)),
    ]
    let size = CGSize(width: 1000, height: 1000)
    #expect(ImageTranslation.blocks(from: lines, size: size).count == 1)
    // Vision says they're different paragraphs (boxes from the bottom left).
    let regions = [CGRect(x: 0.03, y: 1 - 0.126, width: 0.42, height: 0.03), CGRect(x: 0.03, y: 1 - 0.156, width: 0.42, height: 0.03)]
    #expect(ImageTranslation.blocks(from: lines, size: size, regions: regions).count == 2)
    // And a centred title over two lines that Vision calls one paragraph joins.
    let title = [line("Welcome to the", CGRect(x: 420, y: 300, width: 160, height: 30)),
                 line("Summer Festival 2026", CGRect(x: 370, y: 336, width: 260, height: 30))]
    #expect(ImageTranslation.blocks(from: title, size: size, regions: [CGRect(x: 0.36, y: 1 - 0.37, width: 0.28, height: 0.08)]).count == 1)
    #expect(ImageTranslation.blocks(from: title, size: size).count == 2)
}

@Test func codesAndUnsureReadingsStayAsTheyAre() {
    for code in ["SKU-48213", "v2.4.1", "#3A7BD5", "12kg", "x", "→ 3", "2024/11/19"] {
        #expect(ImageTranslation.language(of: code, allowed: ["en", "vi"]) == nil, "\(code)")
    }
    for words in ["Open", "iPhone15 Pro", "COVID-19 vaccine", "日", "毎日8:00～20:00営業しています"] {
        #expect(ImageTranslation.language(of: words, allowed: ["en", "vi", "ja"]) != nil, "\(words)")
    }
    var unsure = line("lIlI", CGRect(x: 40, y: 100, width: 100, height: 24))
    unsure.confidence = 0.1
    #expect(ImageTranslation.blocks(from: [unsure], size: CGSize(width: 1000, height: 1000)).isEmpty)
}

@Test func eachTranslationSaysWhereItWentAndWhatItReplaced() throws {
    let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    let image = try #require(ctx.makeImage())
    let blocks = [TextBlock(text: "Open", rect: CGRect(x: 20, y: 20, width: 60, height: 24), lineHeight: 24, lineCount: 1),
                  TextBlock(text: "Sale", rect: CGRect(x: 200, y: 100, width: 80, height: 30), lineHeight: 30, lineCount: 1, angle: .pi / 4),
                  TextBlock(text: "SKU-1", rect: CGRect(x: 20, y: 160, width: 60, height: 20), lineHeight: 20, lineCount: 1)]
    let spots = try #require(ImageTranslation.rendered(image, blocks: blocks, translations: ["Mở cửa hằng ngày", "Giảm giá", ""])?.spots)
    // A block left as it was can be copied from too.
    #expect(spots.map(\.original) == ["Open", "Sale", "SKU-1"])
    #expect(spots[2].translation.isEmpty && spots[2].contains(CGPoint(x: 50, y: 170)))
    #expect(spots[0].translation == "Mở cửa hằng ngày")
    // A longer translation's spot runs on past the original.
    #expect(spots[0].rect.maxX > 80)
    // A turned one is found along its angle, not in its unturned box's corner.
    let turned = spots[1]
    #expect(turned.contains(CGPoint(x: turned.pivot.x, y: turned.pivot.y)))
    let along = CGPoint(x: turned.pivot.x + 30 * cos(.pi / 4), y: turned.pivot.y + 30 * sin(.pi / 4))
    #expect(turned.contains(along))
    #expect(!turned.contains(CGPoint(x: turned.rect.minX + 2, y: turned.rect.minY + 2)))
}
