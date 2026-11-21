import Foundation

/// Pieces of a text that aren't in its main language: a Japanese phrase in a Vietnamese
/// sentence, an English word among Vietnamese ones. When the text is already in the language
/// picked, these are what's left to translate.
public enum MixedText {
    public struct Run: Equatable {
        public var range: Range<String.Index>
        public var text: String
        /// The language to translate it from.
        public var language: String
    }

    /// The pieces of `text` in another writing than `target`'s (Japanese, Chinese, Korean,
    /// Cyrillic…), found by their letters, and, when the target is Vietnamese and the text carries
    /// Vietnamese accents, runs of English words, as `isEnglish` says.
    public static func foreignRuns(in text: String, target: String,
                                   isEnglish: (String) -> Bool = { _ in false }) -> [Run] {
        let own = TextRecognizer.Script(of: target)
        let scripts: [TextRecognizer.Script] = [.hanAndKana, .hangul, .cyrillic, .thai, .arabic, .devanagari]
            .filter { $0 != own }
        let hasKana = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        var runs: [Run] = []

        // Writings other than the target's: a run goes from one such letter to the last before
        // the next stretch of anything else, with spaces and punctuation inside it.
        var start: String.Index?
        var end: String.Index?
        var found = Set<TextRecognizer.Script>()
        func close() {
            guard let s = start, let e = end else { return }
            let piece = String(text[s..<e])
            if let language = language(of: piece, scripts: found, hasKana: hasKana),
               Translator.base(of: language) != Translator.base(of: target) {
                runs.append(Run(range: s..<e, text: piece, language: language))
            }
            start = nil; end = nil; found = []
        }
        for i in text.indices {
            let scalar = text.unicodeScalars[i]
            let next = text.index(after: i)
            if let script = scripts.first(where: { $0.contains(scalar) }) {
                if start == nil { start = i }
                end = next
                found.insert(script)
            } else if start != nil, scalar.properties.isWhitespace || isPunctuation(scalar) {
                continue
            } else {
                close()
            }
        }
        close()

        if Translator.base(of: target) == "vi", hasVietnameseAccents(text) {
            runs += englishRuns(in: text, isEnglish: isEnglish, avoiding: runs.map(\.range))
        }
        return runs.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `text` with each run replaced by its translation.
    public static func replacing(_ runs: [Run], with translations: [String], in text: String) -> String {
        var result = text
        for (run, translation) in zip(runs, translations).sorted(by: { $0.0.range.lowerBound > $1.0.range.lowerBound }) {
            result.replaceSubrange(run.range, with: translation)
        }
        return result
    }

    private static func language(of piece: String, scripts: Set<TextRecognizer.Script>, hasKana: Bool) -> String? {
        if scripts.contains(.hangul) { return "ko" }
        if scripts.contains(.hanAndKana) { return hasKana ? "ja" : "zh-Hans" }
        if scripts.contains(.cyrillic) { return "ru" }
        if scripts.contains(.thai) { return "th" }
        if scripts.contains(.arabic) { return "ar" }
        if scripts.contains(.devanagari) { return "hi" }
        return nil
    }

    /// Punctuation and symbols that may sit inside a run: ASCII, and the full-width forms of
    /// Japanese and Chinese writing.
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3000...0x303F).contains(v) || (0xFF00...0xFF65).contains(v)
            || (v < 0x80 && !scalar.properties.isAlphabetic && !(0x30...0x39).contains(v) && v != 0x22 && v != 0x27)
    }

    private static func hasVietnameseAccents(_ text: String) -> Bool {
        text.unicodeScalars.contains { "đĐ".unicodeScalars.contains($0) || (0x1EA0...0x1EF9).contains($0.value)
            || "ăâêôơưĂÂÊÔƠƯ".unicodeScalars.contains($0) }
    }

    /// Words of four letters or more that English has and Vietnamese hasn't, with the short
    /// words between neighbouring ones ("coding and traveling").
    private static func englishRuns(in text: String, isEnglish: (String) -> Bool, avoiding: [Range<String.Index>]) -> [Run] {
        var words: [(range: Range<String.Index>, english: Bool, strong: Bool)] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, text[j].isLetter { j = text.index(after: j) }
            let word = String(text[i..<j])
            let plain = word.unicodeScalars.allSatisfy { $0.isASCII }
            let outside = !avoiding.contains { $0.overlaps(i..<j) }
            let english = plain && outside && word.count >= 3 && isEnglish(word.lowercased())
            words.append((i..<j, english, english && word.count >= 4))
            i = j
        }
        var runs: [Run] = []
        var k = 0
        while k < words.count {
            guard words[k].strong else { k += 1; continue }
            var first = k, last = k
            // Join neighbours separated by a single space.
            func gap(_ a: Int, _ b: Int) -> Bool { text[words[a].range.upperBound..<words[b].range.lowerBound] == " " }
            while first > 0, words[first - 1].english, gap(first - 1, first) { first -= 1 }
            while last + 1 < words.count, words[last + 1].english, gap(last, last + 1) { last += 1 }
            let range = words[first].range.lowerBound..<words[last].range.upperBound
            runs.append(Run(range: range, text: String(text[range]), language: "en"))
            k = last + 1
        }
        return runs
    }
}
