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

@Test func aSentenceMixingWritingsKeepsTheLatinWordsAndTakesOnlyTheRunFromTheOtherPass() {
    func word(_ text: String, _ minX: CGFloat, _ maxX: CGFloat) -> TextRecognizer.Word {
        .init(text: text, minX: minX, maxX: maxX)
    }
    var latin = line("Hôm nay tired đÃSE b đ $ (cố lên) nhé!", y: 0.5)
    latin.words = [word("Hôm", 0.05, 0.1), word("nay", 0.11, 0.15), word("tired", 0.16, 0.22), word("đÃSE", 0.23, 0.3),
                   word("b", 0.31, 0.33), word("đ", 0.34, 0.36), word("$", 0.37, 0.4), word("(cố", 0.45, 0.5),
                   word("lên)", 0.51, 0.55), word("nhé!", 0.56, 0.6)]
    var cjk = line("Hom nay tired 頑張ります（co len）nhe！", y: 0.5, .hanAndKana)
    cjk.words = [word("頑張ります", 0.23, 0.42)]
    let merged = TextRecognizer.merge([[cjk], [latin]])
    #expect(merged.map(\.text) == ["Hôm nay tired 頑張ります (cố lên) nhé!"])
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
    #expect(settings.captureTextHotKey?.display == "⌥Space")
    settings.textLanguages.append("ko-KR")
    #expect(AppSettings(defaults: defaults).textLanguages.last == "ko-KR")
}

@Test func linesCrossToAnotherProcessIntact() throws {
    // Read elsewhere when reading here fails, lines come back as JSON.
    let lines = [line("特定原材料", y: 0.5, .hanAndKana), line("Allergy", y: 0.3)]
    let back = try JSONDecoder().decode([Line].self, from: JSONEncoder().encode(lines))
    #expect(back == lines)
    #expect(back[0].isHanOrKana && !back[1].isHanOrKana)
}

@Test func aMergedLineKeepsWhichWayItRuns() {
    // A column of vertical Japanese, read bottom up, over Latin guesses at the same place.
    var column = Line(text: "間時業営", box: CGRect(x: 0.7, y: 0.4, width: 0.04, height: 0.3), script: .hanAndKana)
    column.quad = [CGPoint(x: 0.7, y: 0.4), CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.74, y: 0.7), CGPoint(x: 0.74, y: 0.4)]
    let latin = [Line(text: "I", box: CGRect(x: 0.7, y: 0.45, width: 0.04, height: 0.2), script: .latin)]
    let merged = TextRecognizer.merge([latin, [column]])
    #expect(merged.map(\.quad) == [column.quad])
}


@Test func piecesInOtherWritingsAreFoundInsideASentence() {
    let text = "Hôm nay đi làm hơi bị tired một chút, nhưng mà 頑張ります (cố lên) nhé!"
    let english: Set<String> = ["tired", "coding", "and", "traveling"]
    let runs = MixedText.foreignRuns(in: text, target: "vi") { english.contains($0) }
    #expect(runs.map(\.text) == ["tired", "頑張ります"])
    #expect(runs.map(\.language) == ["en", "ja"])
    #expect(MixedText.replacing(runs, with: ["mệt", "cố gắng"], in: text)
            == "Hôm nay đi làm hơi bị mệt một chút, nhưng mà cố gắng (cố lên) nhé!")
    let phrase = MixedText.foreignRuns(in: "Yêu thích coding and traveling, 毎日楽しく過ごしています (mỗi", target: "vi") { english.contains($0) }
    #expect(phrase.map(\.text) == ["coding and traveling", "毎日楽しく過ごしています"])
    // Nothing to find in text that is all one language.
    #expect(MixedText.foreignRuns(in: "Tối nay đi ăn", target: "vi").isEmpty)
}

@Test func brackets_marksAndSeparatorsAroundAJapaneseRunSurvive() {
    func word(_ text: String, _ minX: CGFloat, _ maxX: CGFloat) -> TextRecognizer.Word {
        .init(text: text, minX: minX, maxX: maxX)
    }
    // "Made in Japan (日本製) chất lượng cao." where the Latin pass garbles the run and its brackets.
    var latin = line("Made in Japan (E 4*\") chất", y: 0.5)
    latin.words = [word("Made", 0.1, 0.15), word("in", 0.16, 0.18), word("Japan", 0.19, 0.25), word("(E", 0.26, 0.28),
                   word("4*\")", 0.29, 0.33), word("chất", 0.34, 0.38)]
    var cjk = line("Made in Japan（日本製） chất", y: 0.5, .hanAndKana)
    cjk.words = [word("（日本製）", 0.255, 0.335)]
    #expect(TextRecognizer.merge([[cjk], [latin]]).map(\.text) == ["Made in Japan (日本製) chất"])

    // "…しました！ Please" where the Latin pass reads the mark as "Ut!" and the Japanese pass as "！".
    var latin2 = line("Ut! Please", y: 0.5)
    latin2.words = [word("Ut!", 0.30, 0.33), word("Please", 0.34, 0.38)]
    var cjk2 = line("緊急事態が発生しました！ Please", y: 0.5, .hanAndKana)
    cjk2.words = [word("緊急事態が発生しました！", 0.17, 0.337)]
    #expect(TextRecognizer.merge([[cjk2], [latin2]]).map(\.text) == ["緊急事態が発生しました！ Please"])
}

@Test func lookalikeLettersAndPipesAreTidied() {
    #expect(TextRecognizer.Line.tidied("Мã đơn hàng") == "Mã đơn hàng")
    #expect(TextRecognizer.Line.tidied("a |SL: 02") == "a | SL: 02")
    #expect(TextRecognizer.Line.tidied("Привет") == "Привет")
    #expect(TextRecognizer.Line.tidied("ТР.НСМ.") == "TP.HCM.")
}


// MARK: - Selecting text on an image

private func word(_ text: String, _ minX: CGFloat, _ maxX: CGFloat) -> TextRecognizer.Word {
    .init(text: text, minX: minX, maxX: maxX)
}

private func selectable() -> SelectableText {
    var first = line("Hôm nay 頑張ります (cố lên)", y: 0.7, x: 0.1, width: 0.6)
    first.words = [word("Hôm", 0.1, 0.16), word("nay", 0.17, 0.22), word("頑張ります", 0.23, 0.43), word("(cố", 0.44, 0.5), word("lên)", 0.51, 0.7)]
    var second = line("Tối nay đi ăn", y: 0.5, x: 0.1, width: 0.4)
    second.words = [word("Tối", 0.1, 0.16), word("nay", 0.17, 0.22), word("đi", 0.23, 0.27), word("ăn", 0.28, 0.5)]
    return SelectableText(lines: [second, first])
}

@Test func draggingAcrossJapaneseTextCopiesWhatWasRead() {
    let t = selectable()
    // From the left edge of 頑張ります to its right edge (the row's y is 0.7 + half the height).
    let y = 0.725
    let a = t.position(at: CGPoint(x: 0.231, y: y))!, b = t.position(at: CGPoint(x: 0.429, y: y))!
    #expect(t.string(from: a, to: b) == "頑張ります")
    // Dragging backwards gives the same text.
    #expect(t.string(from: b, to: a) == "頑張ります")
    // Across two rows: a line break between them.
    let c = t.position(at: CGPoint(x: 0.17, y: 0.525))!
    #expect(t.string(from: t.position(at: CGPoint(x: 0.231, y: y))!, to: c) == "頑張ります (cố lên)\nTối")
}

@Test func wordsRowsAndAllAreSelectable() {
    let t = selectable()
    let word = t.word(at: CGPoint(x: 0.33, y: 0.725))!
    #expect(t.string(from: word.0, to: word.1) == "頑張り")  // a word as Japanese is segmented
    let row = t.line(at: CGPoint(x: 0.19, y: 0.525))!
    #expect(t.string(from: row.0, to: row.1) == "Tối nay đi ăn")
    let all = t.all!
    #expect(t.string(from: all.0, to: all.1) == "Hôm nay 頑張ります (cố lên)\nTối nay đi ăn")
    #expect(t.rects(from: all.0, to: all.1).count == 2)
    #expect(t.isOverText(CGPoint(x: 0.3, y: 0.725)))
    #expect(!t.isOverText(CGPoint(x: 0.9, y: 0.1)))
}
