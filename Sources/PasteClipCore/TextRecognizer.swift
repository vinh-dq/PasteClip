import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

/// Finds text in images with Vision, on the device.
///
/// Vision reads with the model of the first language it's given: with Vietnamese first it skips
/// Japanese, with Japanese first it drops Vietnamese accents. So each writing system gets its own
/// pass, the passes run side by side, and each line is taken from the pass that reads its writing.
public enum TextRecognizer {
    public static let defaultLanguages = ["en-US", "vi-VT", "ja-JP", "zh-Hans"]

    /// Languages Vision can read, in its own order.
    public static let supportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? defaultLanguages
    }()

    /// "Vietnamese", "Chinese, Simplified", …
    public static func name(of language: String) -> String {
        let parts = language.split(separator: "-")
        // Drop the region ("vi-VT" → "vi") but keep a script ("zh-Hans").
        let id = parts.count > 1 && parts[1].count == 4 ? parts.prefix(2).joined(separator: "-") : String(parts[0])
        return Locale(identifier: "en").localizedString(forIdentifier: id) ?? language
    }

    public static func recognize(imageAt url: URL, languages: [String], keepLineBreaks: Bool = true,
                                 completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let text = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                .flatMap { recognize($0, languages: languages, keepLineBreaks: keepLineBreaks) }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Reads a small image of text in the background, so the models for `languages` are ready
    /// before text is first read for real: the first run after each install takes most of a
    /// minute while macOS prepares them for the app. Later runs take a moment.
    public static func prepare(languages: [String]) {
        DispatchQueue.global(qos: .utility).async {
            prepareLock.withLock {
                guard let image = sampleImage() else { return }
                _ = lines(in: image, languages: languages)
            }
        }
    }

    /// One preparation at a time: two preparing the same models at once can leave them broken.
    private static let prepareLock = NSLock()

    /// A line of Latin, Japanese, Chinese and Korean text, so each writing system's model loads.
    private static func sampleImage() -> CGImage? {
        let width = 900, height = 80
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let text = NSAttributedString(string: "Hello world こんにちは 你好 안녕하세요",
                                      attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                   kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 16, y: 26)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    /// Reads an image in a process of its own, for when reading here fails: once macOS's text
    /// recognition breaks in a process (an "e5rt" error from the Neural Engine runtime), it stays
    /// broken there until the process ends, while a new one reads fine. The app sets it; nil, as
    /// in that other process, reading just fails.
    nonisolated(unsafe) public static var readElsewhere: ((CGImage, [String]) -> [Line]?)?

    /// The text in `image`, or nil if there is none. Blocks while Vision runs, so call it off the main thread.
    public static func recognize(_ image: CGImage, languages: [String], keepLineBreaks: Bool = true) -> String? {
        let text = Self.text(of: lines(in: image, languages: languages), keepLineBreaks: keepLineBreaks)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Every line of text in `image` and where it is. Blocks while Vision runs, so call it off the main thread.
    public static func lines(in image: CGImage, languages: [String]) -> [Line] {
        // A menu bar app with no window open gets napped by macOS. Preparing the models (most of
        // a minute the first time) then ran so slowly it failed, and kept failing until PasteClip
        // was restarted; holding off naps while reading keeps it at full speed.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Reading text in an image")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let supported = Set(supportedLanguages)
        var groups: [[String]] = []
        for language in languages where supported.contains(language) {
            if let i = groups.firstIndex(where: { Script(of: $0[0]) == Script(of: language) }) {
                groups[i].append(language)
            } else {
                groups.append([language])
            }
        }
        if groups.isEmpty { groups = [defaultLanguages] }

        var passes = [[Line]](repeating: [], count: groups.count)
        var failed = false
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            let script = Script(of: groups[i][0])
            var observations: [VNRecognizedTextObservation]?
            do {
                observations = try perform(.accurate, languages: groups[i], on: image)
            } catch {
                lock.withLock { failed = true }
            }
            let lines = (observations ?? []).compactMap { observation -> Line? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return Line(text: candidate.string, box: observation.boundingBox, script: script,
                            quad: [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft],
                            confidence: candidate.confidence)
            }
            lock.withLock { passes[i] = lines }
        }
        // Part of the text unread would be translated as if it were all of it: read it elsewhere,
        // or not at all. (macOS's fast model still reads Latin writing then, but badly, and
        // nothing else, so it isn't used.)
        if failed, let read = readElsewhere?(image, languages) {
            failureLock.withLock { lastRunFailed = false }
            return read
        }
        failureLock.withLock { lastRunFailed = failed }
        return failed ? [] : merge(passes)
    }

    /// Where the paragraphs, list items and table cells of `image` are (Vision's boxes, the origin
    /// at the bottom left), as macOS 26's document reader lays the page out: lines in different
    /// ones are never one paragraph, which keeps columns and cells apart. Empty before macOS 26
    /// or when it can't tell.
    public static func layout(in image: CGImage) async -> [CGRect] {
        guard #available(macOS 26, *),
              let document = try? await RecognizeDocumentsRequest().perform(on: image).first?.document
        else { return [] }
        // Vision works out these parts on reading them, recursing deeply on a busy page, more
        // than a task's small stack holds (it crashed there): they're read on a thread with a
        // large one. A list item or a table cell counts as one region, without looking inside.
        return await withCheckedContinuation { done in
            let thread = Thread {
                func box(_ region: NormalizedRegion) -> CGRect {
                    let b = region.boundingBox
                    return CGRect(origin: b.origin, size: CGSize(width: b.width, height: b.height))
                }
                var found = document.paragraphs.map { box($0.boundingRegion) }
                for list in document.lists {
                    for item in list.items { found.append(box(item.content.boundingRegion)) }
                }
                for table in document.tables {
                    for row in table.rows {
                        for cell in row { found.append(box(cell.content.boundingRegion)) }
                    }
                }
                done.resume(returning: found)
            }
            thread.stackSize = 64 << 20
            thread.start()
        }
    }

    private static func perform(_ level: VNRequestTextRecognitionLevel, languages: [String],
                                on image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = languages
        // Correction swaps letters for dictionary words ("userID" → "userlD"), which breaks
        // code, links and IDs, and made no difference to Vietnamese, Japanese or Chinese.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var lastRunFailed = false

    /// Whether macOS couldn't run text recognition the last time it was asked to, so "no text"
    /// may only mean it isn't working. Restarting the Mac fixes that.
    public static var isFailing: Bool { failureLock.withLock { lastRunFailed } }

    /// What to say when no text came back: there was none, or recognition isn't working.
    public static var nothingFoundMessage: String {
        isFailing ? "Couldn't read the text: macOS text recognition isn't working right now. Restarting PasteClip usually fixes it."
            : "No text found in the image"
    }

    /// `image` drawn `factor` times larger, unless that would be more than 24 megapixels.
    /// Text from a screen that isn't Retina reads better at twice the size.
    public static func upscaled(_ image: CGImage, by factor: Int) -> CGImage {
        let width = image.width * factor, height = image.height * factor
        guard factor > 1, width * height <= 24_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: - Merging passes

    /// A line of text and where it is, in Vision's coordinates (0…1, origin at the bottom left).
    public struct Line: Equatable, Codable {
        public var text: String
        public var box: CGRect
        var script: Script
        /// Its corners as Vision gives them (top left, top right, bottom right, bottom left of the
        /// text, the origin at the bottom left), which show how far it's turned; empty when unknown.
        public var quad: [CGPoint] = []
        /// How sure Vision is of the reading, 0–1.
        public var confidence: Float = 1

        /// Chinese or Japanese, which is written without spaces between words.
        public var isHanOrKana: Bool { script == .hanAndKana }
    }

    /// The writing systems Vision reads with separate models.
    enum Script: String, Hashable, Codable {
        case latin, hanAndKana, hangul, cyrillic, thai, arabic, devanagari

        init(of language: String) {
            switch Locale.Language(identifier: language).maximalIdentifier.split(separator: "-").dropFirst().first {
            case "Hans", "Hant", "Jpan": self = .hanAndKana
            case "Kore": self = .hangul
            case "Cyrl": self = .cyrillic
            case "Thai": self = .thai
            case "Arab": self = .arabic
            case "Deva": self = .devanagari
            default: self = .latin
            }
        }

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            let v = scalar.value
            switch self {
            case .latin: return v < 0x0370 || (0x1E00...0x1EFF).contains(v)
            case .hanAndKana:
                return (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0x3400...0x4DBF).contains(v)
                    || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF66...0xFF9D).contains(v)
                    || (0x20000...0x3FFFF).contains(v)
            case .hangul: return (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) || (0xAC00...0xD7AF).contains(v)
            case .cyrillic: return (0x0400...0x052F).contains(v)
            case .thai: return (0x0E00...0x0E7F).contains(v)
            case .arabic:
                return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
                    || (0xFB50...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
            case .devanagari: return (0x0900...0x097F).contains(v)
            }
        }

        /// How much of `text` (ignoring spaces) is in this writing system.
        func share(of text: String) -> Double {
            let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
            guard !scalars.isEmpty else { return 0 }
            return Double(scalars.filter(contains).count) / Double(scalars.count)
        }
    }

    /// Lines from the Latin pass, with lines another pass read in its own writing put in their place.
    static func merge(_ passes: [[Line]]) -> [Line] {
        guard let baseIndex = passes.indices.first(where: { passes[$0].first?.script == .latin }) ?? passes.indices.first
        else { return [] }
        var result = passes[baseIndex]
        for (i, pass) in passes.enumerated() where i != baseIndex {
            for line in pass where line.script != .latin {
                let share = line.script.share(of: line.text)
                guard share > 0 else { continue }
                let overlapping = result.indices.filter { overlaps(result[$0].box, line.box) }
                // A line another pass read in its own writing stays unless this pass reads more of it.
                if overlapping.contains(where: { result[$0].script != .latin && result[$0].script.share(of: result[$0].text) >= share }) {
                    continue
                }
                var merged = line
                let latin = overlapping.filter { result[$0].script == .latin }.map { result[$0].text }
                merged.text = restoringAccents(in: line.text, from: latin.joined(separator: " "))
                merged.box = overlapping.reduce(line.box) { $0.union(result[$1].box) }
                // The corners stay this pass's own: which way the line runs (bottom up for a
                // column of vertical writing) is what they tell.
                for j in overlapping.reversed() { result.remove(at: j) }
                result.append(merged)
            }
        }
        return result
    }

    /// Same row and touching: at least half of the shorter line's height overlaps.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let vertical = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let horizontal = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return vertical >= min(a.height, b.height) / 2 && horizontal > 0
    }

    /// Other passes read Latin words without accents ("Nguyen"); takes them back from the Latin pass ("Nguyễn").
    static func restoringAccents(in text: String, from latin: String) -> String {
        var candidates = latin.split(separator: " ").map(String.init)
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let word = String(word)
            let key = folded(word)
            guard !key.isEmpty, let i = candidates.firstIndex(where: { folded($0) == key }) else { return word }
            let match = candidates[i]
            candidates.removeFirst(i + 1)
            return match
        }.joined(separator: " ")
    }

    private static func folded(_ word: String) -> String {
        word.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Reading order

    /// Lines top to bottom, left to right on a row. Without line breaks, lines join into paragraphs
    /// that end where there is a gap above the next line.
    static func text(of lines: [Line], keepLineBreaks: Bool) -> String {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.last, abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var result = ""
        var previous: CGRect?
        for row in rows {
            let row = row.sorted { $0.box.minX < $1.box.minX }
            let text = row.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let box = row.dropFirst().reduce(row[0].box) { $0.union($1.box) }
            if let previous {
                if keepLineBreaks || previous.minY - box.maxY > min(previous.height, box.height) * 0.8 {
                    result += "\n"
                } else if let end = result.unicodeScalars.last, let start = text.unicodeScalars.first,
                          !(Script.hanAndKana.contains(end) && Script.hanAndKana.contains(start)) {
                    result += " "
                }
            }
            result += text
            previous = box
        }
        return result
    }
}
