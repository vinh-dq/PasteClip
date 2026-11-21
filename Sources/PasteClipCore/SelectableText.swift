import CoreGraphics
import Foundation
import NaturalLanguage

/// The text of an image laid out for selecting with the pointer, from the lines read here (the
/// same reading translation uses), so what is copied is what was read and not what Live Text made
/// of the picture. Positions and boxes are Vision's: 0…1, the origin at the bottom left.
public struct SelectableText {
    /// A piece of a line that can be selected: a word, or a run of Japanese, with where it sits.
    struct Unit {
        var text: String
        var rect: CGRect
        var row: Int

        var count: Int { text.count }
        /// Where the boundary before character `index` is, by the unit's width shared out evenly.
        func x(at index: Int) -> CGFloat { rect.minX + rect.width * CGFloat(index) / CGFloat(max(count, 1)) }
    }

    /// A boundary between two characters: before character `char` of unit `unit`.
    public struct Position: Comparable, Equatable {
        public var unit: Int
        public var char: Int
        public init(unit: Int, char: Int) { self.unit = unit; self.char = char }
        public static func < (a: Position, b: Position) -> Bool { (a.unit, a.char) < (b.unit, b.char) }
    }

    let units: [Unit]

    public var isEmpty: Bool { units.isEmpty }

    public init(lines: [TextRecognizer.Line]) {
        var units: [Unit] = []
        for (r, row) in TextRecognizer.readingRows(of: lines).enumerated() {
            for line in row {
                units += Self.units(of: line).map { Unit(text: $0.text, rect: $0.rect, row: r) }
            }
        }
        self.units = units
    }

    /// The words of a line when they make up its text, else the whole line as one piece.
    private static func units(of line: TextRecognizer.Line) -> [(text: String, rect: CGRect)] {
        func squeezed(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined() }
        let words = line.words
        guard !words.isEmpty, squeezed(words.map(\.text).joined()) == squeezed(line.text) else {
            return [(line.text.trimmingCharacters(in: .whitespaces), line.box)]
        }
        return words.map { word in
            (word.text, CGRect(x: word.minX, y: line.box.minY, width: max(word.maxX - word.minX, 0.001), height: line.box.height))
        }
    }

    // MARK: Finding text

    /// Whether `point` is on a piece of text (a little around it counts).
    public func isOverText(_ point: CGPoint) -> Bool {
        units.contains { $0.rect.insetBy(dx: -0.004, dy: -0.004).contains(point) }
    }

    /// Where a boundary nearest `point` is: in the row of text there (or the closest one), in the
    /// piece nearest along it.
    public func position(at point: CGPoint) -> Position? {
        guard !units.isEmpty else { return nil }
        let rows = Dictionary(grouping: units.indices, by: { units[$0].row })
        let row = rows.min { a, b in distance(of: point.y, toRow: a.value) < distance(of: point.y, toRow: b.value) }!.value
        let unit = row.min { a, b in gap(of: point.x, to: units[a].rect) < gap(of: point.x, to: units[b].rect) }!
        let u = units[unit]
        let offset = u.rect.width > 0 ? (point.x - u.rect.minX) / u.rect.width : 0
        return Position(unit: unit, char: min(max(Int((offset * CGFloat(u.count)).rounded()), 0), u.count))
    }

    private func distance(of y: CGFloat, toRow row: [Int]) -> CGFloat {
        let low = row.map { units[$0].rect.minY }.min()!, high = row.map { units[$0].rect.maxY }.max()!
        return y < low ? low - y : y > high ? y - high : 0
    }

    private func gap(of x: CGFloat, to rect: CGRect) -> CGFloat {
        x < rect.minX ? rect.minX - x : x > rect.maxX ? x - rect.maxX : 0
    }

    /// The word under `point`, as the selection it makes.
    public func word(at point: CGPoint) -> (Position, Position)? {
        guard isOverText(point), let p = position(at: point) else { return nil }
        let u = units[p.unit]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = u.text
        var found: (Int, Int)?
        let chars = Array(u.text.indices)
        tokenizer.enumerateTokens(in: u.text.startIndex..<u.text.endIndex) { range, _ in
            let a = chars.firstIndex(of: range.lowerBound) ?? 0
            let b = range.upperBound == u.text.endIndex ? chars.count : (chars.firstIndex(of: range.upperBound) ?? chars.count)
            if p.char >= a, p.char <= b || a == 0 && p.char == 0 { found = (a, b); return false }
            return true
        }
        let (a, b) = found ?? (0, u.count)
        return (Position(unit: p.unit, char: a), Position(unit: p.unit, char: b))
    }

    /// The whole row of text under `point`.
    public func line(at point: CGPoint) -> (Position, Position)? {
        guard isOverText(point), let p = position(at: point) else { return nil }
        let row = units[p.unit].row
        let members = units.indices.filter { units[$0].row == row }
        return (Position(unit: members.first!, char: 0), Position(unit: members.last!, char: units[members.last!].count))
    }

    public var all: (Position, Position)? {
        guard let last = units.indices.last else { return nil }
        return (Position(unit: 0, char: 0), Position(unit: last, char: units[last].count))
    }

    // MARK: Text and highlight

    private func ordered(_ a: Position, _ b: Position) -> (Position, Position) { a <= b ? (a, b) : (b, a) }

    /// The text between two boundaries, a space between pieces on a row and a line break between rows.
    public func string(from a: Position, to b: Position) -> String {
        let (start, end) = ordered(a, b)
        var result = ""
        var previous: Unit?
        for k in start.unit...end.unit {
            let u = units[k]
            let from = k == start.unit ? start.char : 0, to = k == end.unit ? end.char : u.count
            guard to > from else { continue }
            let piece = String(u.text.dropFirst(from).prefix(to - from))
            if let previous {
                let closing = from == 0 && piece.allSatisfy { ")]}\"”'.,!?;:".contains($0) }
                result += previous.row != u.row ? "\n" : closing ? "" : " "
            }
            result += piece
            previous = u
        }
        return result
    }

    /// Boxes to highlight for the text between two boundaries, one per row.
    public func rects(from a: Position, to b: Position) -> [CGRect] {
        let (start, end) = ordered(a, b)
        var byRow: [Int: CGRect] = [:]
        for k in start.unit...end.unit {
            let u = units[k]
            let from = k == start.unit ? start.char : 0, to = k == end.unit ? end.char : u.count
            guard to > from else { continue }
            let box = CGRect(x: u.x(at: from), y: u.rect.minY, width: u.x(at: to) - u.x(at: from), height: u.rect.height)
            byRow[u.row] = byRow[u.row].map { $0.union(box) } ?? box
        }
        return byRow.keys.sorted().map { byRow[$0]! }
    }
}
