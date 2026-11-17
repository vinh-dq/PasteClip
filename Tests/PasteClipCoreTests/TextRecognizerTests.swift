import AppKit
import Foundation
import Testing
@testable import PasteClipCore

private typealias Line = TextRecognizer.Line

/// White image with one line of black text per entry, as Vision would see a screenshot.
private func image(of lines: [String]) -> CGImage {
    let size = NSSize(width: 1000, height: 60 * lines.count + 20)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 20, y: size.height - CGFloat(60 * (i + 1))),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black])
    }
    image.unlockFocus()
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

private func line(_ text: String, y: CGFloat, x: CGFloat = 0.1, width: CGFloat = 0.5, _ script: TextRecognizer.Script = .latin) -> Line {
    Line(text: text, box: CGRect(x: x, y: y, width: width, height: 0.05), script: script)
}

@Test func readsVietnameseEnglishJapaneseAndChineseOnTheSameScreen() throws {
    let text = try #require(TextRecognizer.recognize(image(of: [
        "Meeting: Họp dự án lúc 10 giờ",
        "会議は東京で行います",
        "会议在上海举行",
        "Tên: Nguyễn Thị Hương, 東京 office",
    ]), languages: TextRecognizer.defaultLanguages))
    // Fails (rather than crashing) when macOS's text recognition isn't working on this Mac.
    #expect(!TextRecognizer.isFailing, "macOS text recognition is failing; restart the Mac and run again")
    let lines = text.components(separatedBy: "\n")
    try #require(lines.count == 4)
    #expect(lines[0] == "Meeting: Họp dự án lúc 10 giờ")
    #expect(lines[1] == "会議は東京で行います")
    #expect(lines[2] == "会议在上海举行")
    #expect(lines[3].contains("Nguyễn Thị Hương"))
    #expect(lines[3].contains("東京"))
}

@Test func linesInAnotherWritingReplaceTheLatinPassGuess() {
    let latin = [line("Hello", y: 0.8), line("₴ìXÆL", y: 0.6), line("Tên: Nguyễn - #Ă office", y: 0.4)]
    let cjk = [line("Hello", y: 0.8, .hanAndKana), line("会議は東京で", y: 0.6, .hanAndKana),
               line("Ten: Nguyen - 東京 office", y: 0.4, .hanAndKana)]
    let merged = TextRecognizer.merge([cjk, latin])
    #expect(TextRecognizer.text(of: merged, keepLineBreaks: true) == "Hello\n会議は東京で\nTên: Nguyễn - 東京 office")
}

@Test func theLineWithMoreOfItsOwnWritingWins() {
    let latin = [line("garbage", y: 0.5)]
    let korean = [line("ExOF자", y: 0.5, .hangul)]
    let cjk = [line("日本語のテキスト", y: 0.5, .hanAndKana)]
    #expect(TextRecognizer.merge([latin, korean, cjk]).map(\.text) == ["日本語のテキスト"])
    #expect(TextRecognizer.merge([latin, cjk, korean]).map(\.text) == ["日本語のテキスト"])
}

@Test func accentsComeBackOnlyForMatchingWords() {
    #expect(TextRecognizer.restoringAccents(in: "Gia 1.250.000d (約8000円)", from: "Giá 1.250.000đ (#8000F)")
        == "Giá 1.250.000đ (約8000円)")
    #expect(TextRecognizer.restoringAccents(in: "Ten Ten", from: "Tên") == "Tên Ten")
}

@Test func rowsReadLeftToRightAndCanJoinIntoParagraphs() {
    let lines = [line("world", y: 0.80, x: 0.6, width: 0.2), line("Hello", y: 0.80, x: 0.1, width: 0.2),
                 line("wrapped", y: 0.74), line("日本語の", y: 0.5, .hanAndKana), line("段落", y: 0.44, .hanAndKana)]
    #expect(TextRecognizer.text(of: lines, keepLineBreaks: true) == "Hello world\nwrapped\n日本語の\n段落")
    #expect(TextRecognizer.text(of: lines, keepLineBreaks: false) == "Hello world wrapped\n日本語の段落")
}

@Test func smallTextFromScreensThatArentRetinaIsReadAtTwiceTheSize() {
    let small = image(of: ["x"])
    let large = TextRecognizer.upscaled(small, by: 2)
    #expect(large.width == small.width * 2 && large.height == small.height * 2)
    #expect(TextRecognizer.upscaled(small, by: 1).width == small.width)
    let huge = CGContext(data: nil, width: 5000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
    #expect(TextRecognizer.upscaled(huge, by: 2).width == 5000)
}

@Test func codeAndLinksAreNotSpellCorrected() throws {
    let text = try #require(TextRecognizer.recognize(image(of: ["let userID = config.apiKey", "git cherry-pick 17d6cad"]),
                                                     languages: TextRecognizer.defaultLanguages))
    #expect(text == "let userID = config.apiKey\ngit cherry-pick 17d6cad")
}

@Test func languagesAreGroupedByWritingSystem() {
    #expect(TextRecognizer.Script(of: "vi-VT") == .latin)
    #expect(TextRecognizer.Script(of: "ja-JP") == TextRecognizer.Script(of: "zh-Hans"))
    #expect(TextRecognizer.Script(of: "ko-KR") == .hangul)
    #expect(TextRecognizer.name(of: "vi-VT") == "Vietnamese")
    #expect(Set(TextRecognizer.defaultLanguages).isSubset(of: TextRecognizer.supportedLanguages))
}

@Test func screenTextSettingsDefaultToFourLanguages() {
    let defaults = Scratch.defaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.textLanguages == ["en-US", "vi-VT", "ja-JP", "zh-Hans"])
    #expect(settings.keepLineBreaks)
    #expect(settings.captureTextHotKey?.display == "⌥⇧⌘2")
    settings.textLanguages.append("ko-KR")
    #expect(AppSettings(defaults: defaults).textLanguages.last == "ko-KR")
}
