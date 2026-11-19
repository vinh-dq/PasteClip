import AppKit
import NaturalLanguage

/// A paragraph, label or other run of text in an image, in the image's pixels with the origin at
/// the top left.
public struct TextBlock: Equatable {
    public var text: String
    public var rect: CGRect
    /// Height of one of its lines.
    public var lineHeight: CGFloat
    public var lineCount: Int
    /// How far it's turned clockwise, in radians, about the middle of `rect` (which is then the
    /// box along its lines, not the one it covers on the image: see `bounds`).
    public var angle: CGFloat
    /// Chinese or Japanese written in columns: `lineCount` columns, read from the right,
    /// `lineHeight` wide.
    public var vertical: Bool

    public init(text: String, rect: CGRect, lineHeight: CGFloat, lineCount: Int, angle: CGFloat = 0, vertical: Bool = false) {
        self.text = text
        self.rect = rect
        self.lineHeight = lineHeight
        self.lineCount = lineCount
        self.angle = angle
        self.vertical = vertical
    }

    /// The box it covers on the image.
    public var bounds: CGRect {
        guard angle != 0 else { return rect }
        return rect.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: angle)
            .translatedBy(x: -rect.midX, y: -rect.midY))
    }
}

/// Puts a translation on an image where its text was: the lines Vision found become paragraphs,
/// their letters are taken out (what's behind them stays) and the translation is written in
/// their place, turned or in columns as the original was.
public enum ImageTranslation {
    // MARK: Paragraphs

    /// Lines Vision is less sure of than this are left as they are: what it reads in a logo, a
    /// pattern or a photo's texture.
    static let minimumConfidence: Float = 0.3

    /// Lines joined into the paragraphs they belong to, top to bottom. A line joins the one above
    /// it when it's the same size, starts in line with it, follows closely, and the line above
    /// ran on to its end (a full line that doesn't finish a sentence) and this one carries on (in
    /// lower case); labels, menu items and list entries stay on their own. `regions` (Vision's
    /// paragraphs, list items and table cells, see `TextRecognizer.layout`) settle it where they
    /// cover the lines: lines in different ones stay apart, lines in one join more readily.
    /// Turned lines stay on their own; columns of vertical Chinese or Japanese side by side
    /// become one block, read from the right.
    public static func blocks(from lines: [TextRecognizer.Line], size: CGSize, regions: [CGRect] = []) -> [TextBlock] {
        struct Row {
            var text: String
            var rect: CGRect
            var closeSet: Bool
            var region: Int?
            var angle: CGFloat = 0
            var vertical = false
        }
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        let areas = regions.map(pixels)
        let rows = lines.filter { $0.confidence >= minimumConfidence }.map { line -> Row in
            var row = Row(text: line.text.trimmingCharacters(in: .whitespaces), rect: pixels(line.box), closeSet: line.isHanOrKana)
            // The smallest region it's in: a cell rather than the table around it.
            row.region = areas.indices.filter { areas[$0].contains(CGPoint(x: row.rect.midX, y: row.rect.midY)) }
                .min { areas[$0].width * areas[$0].height < areas[$1].width * areas[$1].height }
            if line.isHanOrKana, row.rect.height > row.rect.width * 1.8, row.text.count >= 2 {
                row.vertical = true
                // Vision reads a column as a line turned a quarter to the left, from the bottom
                // up, and takes the long-vowel mark standing upright in it for an I or a 1. The
                // mark only ever follows kana; a digit after a kanji ("第1章") is a digit.
                if line.quad.count == 4, line.quad[1].y > line.quad[0].y {
                    row.text = String(row.text.reversed())
                }
                var fixed = Array(row.text)
                for i in fixed.indices.dropFirst() where "Il|1".contains(fixed[i]) {
                    if fixed[i - 1].unicodeScalars.allSatisfy({ (0x3041...0x30FF).contains($0.value) }) { fixed[i] = "ー" }
                }
                row.text = String(fixed)
            } else if line.quad.count == 4 {
                let p = line.quad.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
                let angle = atan2(p[1].y - p[0].y, p[1].x - p[0].x)
                if abs(angle) > 0.05 {
                    let width = hypot(p[1].x - p[0].x, p[1].y - p[0].y), height = hypot(p[3].x - p[0].x, p[3].y - p[0].y)
                    let centre = CGPoint(x: p.map(\.x).reduce(0, +) / 4, y: p.map(\.y).reduce(0, +) / 4)
                    row.rect = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
                    row.angle = angle
                }
            }
            return row
        }
        .filter { !$0.text.isEmpty }
        .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }

        var groups: [[Row]] = []
        for row in rows {
            let joins: ([Row]) -> Bool = { group in
                guard let last = group.last, row.angle == 0, last.angle == 0, row.vertical == last.vertical else { return false }
                if let a = row.region, let b = last.region, a != b { return false }
                if row.vertical {
                    // The next column along: as wide, beside the others, overlapping them down the page.
                    let union = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
                    let w = last.rect.width
                    let apart = max(row.rect.minX - union.maxX, union.minX - row.rect.maxX)
                    return max(w, row.rect.width) / max(min(w, row.rect.width), 1) <= 1.4 && apart < w * 0.9
                        && row.rect.minY < union.maxY && row.rect.maxY > union.minY && abs(row.rect.minY - union.minY) < w * 2
                }
                let h = last.rect.height
                let widest = group.map(\.rect.width).max() ?? 0
                let gap = row.rect.minY - last.rect.maxY
                let sameSize = max(h, row.rect.height) / max(min(h, row.rect.height), 1) <= 1.35
                let sameRegion = row.region != nil && row.region == last.region
                let leftAligned = abs(row.rect.minX - last.rect.minX) <= h * 1.2
                let centred = sameRegion && !leftAligned && abs(row.rect.midX - last.rect.midX) <= h * 1.2
                let ranOn = last.rect.width >= max(widest, row.rect.width) * 0.75
                    && last.text.count >= (last.closeSet ? 16 : 20)
                    && !(last.text.last.map { ".!?。！？:：".contains($0) } ?? false)
                // A wrapped sentence goes on in lower case (or after a comma or hyphen); the next
                // entry of a list starts with a capital. Chinese and Japanese have no case to go by.
                let continues = last.closeSet || row.closeSet || row.text.first?.isLowercase == true
                    || last.text.hasSuffix(",") || last.text.hasSuffix("-")
                // Vision saying it's one paragraph stands in for either sign, and for both when
                // the lines are centred (a title over two lines); left-aligned short lines in
                // one of its paragraphs may still be a menu.
                let carriesOn = centred || (sameRegion ? ranOn || continues : ranOn && continues)
                return sameSize && (leftAligned || centred) && carriesOn && gap > -h * 0.3 && gap < h * 0.9
            }
            if let i = groups.lastIndex(where: joins) {
                groups[i].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups.map { group in
            let rect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
            if group[0].vertical {
                let columns = group.sorted { $0.rect.maxX > $1.rect.maxX }
                return TextBlock(text: columns.map(\.text).joined(), rect: rect,
                                 lineHeight: columns.map(\.rect.width).reduce(0, +) / CGFloat(columns.count),
                                 lineCount: columns.count, vertical: true)
            }
            var text = group[0].text
            for (previous, row) in zip(group, group.dropFirst()) {
                // Chinese and Japanese lines run on without a space.
                text += (previous.closeSet && row.closeSet ? "" : " ") + row.text
            }
            let lineHeight = group.map(\.rect.height).reduce(0, +) / CGFloat(group.count)
            return TextBlock(text: text, rect: rect, lineHeight: lineHeight, lineCount: group.count, angle: group[0].angle)
        }
    }

    // MARK: Drawing

    /// Where a block's translation was drawn and the text it took the place of, so the image
    /// can show the original of the part under the pointer. A block left as it was has an
    /// empty translation.
    public struct Spot: Equatable, Sendable {
        /// The original and its translation, in the image's pixels from the top left, before
        /// turning by `angle` about `pivot`.
        public var rect: CGRect
        public var angle: CGFloat
        public var pivot: CGPoint
        public var original: String
        public var translation: String

        /// The box it covers on the image.
        public var bounds: CGRect { angle == 0 ? rect : rect.applying(turn) }

        public func contains(_ point: CGPoint) -> Bool {
            rect.contains(angle == 0 ? point : point.applying(turn.inverted()))
        }

        private var turn: CGAffineTransform {
            CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: angle).translatedBy(x: -pivot.x, y: -pivot.y)
        }
    }

    /// `image` with each block's letters taken out (what's behind them carries on, see
    /// `Pixels.erase`) and its translation written in its place, the same size as the image. A
    /// missing or empty translation leaves its block as it was.
    public static func render(_ image: CGImage, blocks: [TextBlock], translations: [String]) -> CGImage? {
        rendered(image, blocks: blocks, translations: translations)?.image
    }

    /// `render`, with where each translation went.
    public static func rendered(_ image: CGImage, blocks: [TextBlock], translations: [String]) -> (image: CGImage, spots: [Spot])? {
        let originals = blocks
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Pixels(data: data.assumingMemoryBound(to: UInt8.self), width: width, height: height, bytesPerRow: width * 4)
        // Colours are read before anything is drawn over the image.
        let backgrounds = blocks.map { pixels.background(around: $0) }
        // The size the letters really are, from their ink: Vision's boxes run from about the
        // font size for large letters to nearly twice it for small ones. Turned and vertical
        // lines go by their boxes, which their ink isn't measured across.
        let blocks = evenedOut(blocks.enumerated().map { i, block in
            var sized = block
            if block.vertical {
                sized.lineHeight = block.lineHeight * 0.85
            } else if block.angle != 0 {
                sized.lineHeight = block.rect.height * 0.72
            } else if let size = pixels.fontSize(of: block, background: backgrounds[i]) {
                sized.lineHeight = min(max(size, block.lineHeight * 0.45), block.lineHeight * 1.2)
            }
            return sized
        })
        let colours = blocks.map { pixels.colours(around: $0) }

        var placed: [Int: Placed] = [:]
        var fits: [Int: (room: CGFloat, tallest: CGFloat, alignsRight: Bool)] = [:]
        for (i, block) in blocks.enumerated() where i < translations.count {
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if block.vertical || block.angle != 0 {
                placed[i] = placeTurned(text, over: block, colours: colours[i])
                continue
            }
            let others = blocks.filter { $0 != block }
            func overlapsColumn(_ other: TextBlock) -> Bool {
                other.bounds.minX < block.rect.maxX && other.bounds.maxX > block.rect.minX
            }
            // How far right it may run: to the next block on its row, the edge of what it sits
            // on (a button, a box), or the image's edge.
            let next = others.filter { $0.bounds.minX >= block.rect.maxX - 1
                && $0.bounds.minY < block.rect.maxY && $0.bounds.maxY > block.rect.minY }.map(\.bounds.minX).min()
            let edge = pixels.edge(rightOf: block, background: colours[i].background)
            // Labels lined up on their right edges (as beside a form's fields) stay that way,
            // growing to the left, up to the block before them on their row.
            let alignsRight = block.lineCount == 1 && others.contains {
                abs($0.rect.maxX - block.rect.maxX) < block.lineHeight * 0.4
                    && abs($0.rect.minX - block.rect.minX) > block.lineHeight * 0.5
                    && abs($0.rect.midY - block.rect.midY) < block.lineHeight * 8
            }
            let previous = others.filter { $0.bounds.maxX <= block.rect.minX + 1
                && $0.bounds.minY < block.rect.maxY && $0.bounds.maxY > block.rect.minY }.map(\.bounds.maxX).max()
            let room = alignsRight
                ? max(block.rect.maxX - (previous ?? 0) - block.lineHeight * 0.5, block.rect.width)
                : max(min(next ?? CGFloat(width), edge) - block.lineHeight * 0.5 - block.rect.minX, block.rect.width)
            // How tall a line may be without reaching the lines above and below it: the distance
            // between the middles of neighbouring lines, which is even down a list where
            // Vision's boxes aren't.
            let pitches = others.filter { overlapsColumn($0) && abs($0.bounds.midY - block.rect.midY) > block.lineHeight * 0.5 }
                .map { abs($0.bounds.midY - block.rect.midY) }
            let tallest = max(min(block.lineHeight * 1.6, pitches.min() ?? .greatestFiniteMagnitude), block.lineHeight * 0.9)
            fits[i] = (room, tallest, alignsRight)
            placed[i] = place(text, over: block, room: room, tallest: tallest, colours: colours[i], alignsRight: alignsRight)
        }
        // Lines of one list come out one size: the smallest any of them needed.
        let lists = listGroups(blocks)
        for (i, item) in placed where fits[i] != nil && blocks[i].lineCount == 1 {
            let smallest = placed.filter { lists[$0.key] == lists[i] }.map(\.value.size).min() ?? item.size
            guard smallest < item.size, let fit = fits[i] else { continue }
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            placed[i] = place(text, over: blocks[i], room: fit.room, tallest: fit.tallest, colours: colours[i],
                              alignsRight: fit.alignsRight, size: smallest)
        }

        // Every block's letters out first, then every text, so no erasing takes out another's text.
        for i in placed.keys { pixels.erase(blocks[i]) }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for item in placed.values { item.draw(ctx) }
        NSGraphicsContext.restoreGraphicsState()
        guard let made = ctx.makeImage() else { return nil }
        // Blocks left as they were (already in the target, a code, a number) get one too, so
        // every text read on the image can be copied from it.
        let spots = blocks.indices.map { i in
            let pad = (dx: -blocks[i].lineHeight * 0.2, dy: -blocks[i].lineHeight * 0.15)
            guard let item = placed[i] else {
                let rect = originals[i].rect
                return Spot(rect: rect.insetBy(dx: pad.dx, dy: pad.dy), angle: originals[i].angle,
                            pivot: CGPoint(x: rect.midX, y: rect.midY), original: originals[i].text, translation: "")
            }
            return Spot(rect: item.area.insetBy(dx: pad.dx, dy: pad.dy), angle: item.angle, pivot: item.pivot,
                        original: originals[i].text, translation: translations[i].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (made, spots)
    }

    /// Lines of a list or column (one under another, starting at the same place, about the same
    /// size) given the same height, the middle of theirs, so their translations come out the same
    /// size: Vision's boxes for lines of one size vary, more so for small letters.
    static func evenedOut(_ blocks: [TextBlock]) -> [TextBlock] {
        let lists = listGroups(blocks)
        return blocks.enumerated().map { i, block in
            guard block.lineCount == 1, block.angle == 0, !block.vertical else { return block }
            let peers = blocks.indices.filter { lists[$0] == lists[i] }.map { blocks[$0].lineHeight }.sorted()
            var evened = block
            evened.lineHeight = peers[peers.count / 2]
            return evened
        }
    }

    /// Which list each block belongs to, by number: single lines one after another down the
    /// image (no more than about two lines apart), starting in the same place, about the same
    /// size. A paragraph, or a line on its own, is a list of one.
    static func listGroups(_ blocks: [TextBlock]) -> [Int] {
        var group = Array(blocks.indices)
        func root(_ i: Int) -> Int { group[i] == i ? i : root(group[i]) }
        let straight = { (i: Int) in blocks[i].lineCount == 1 && blocks[i].angle == 0 && !blocks[i].vertical }
        for i in blocks.indices where straight(i) {
            for j in blocks.indices where j > i && straight(j) {
                let a = blocks[i], b = blocks[j]
                let h = max(a.lineHeight, b.lineHeight)
                guard abs(a.rect.minX - b.rect.minX) <= h, abs(a.rect.midY - b.rect.midY) <= h * 2.2,
                      h / max(min(a.lineHeight, b.lineHeight), 1) <= 1.35 else { continue }
                group[root(j)] = root(i)
            }
        }
        return blocks.indices.map(root)
    }

    /// A translation laid out over its block, ready to draw.
    private struct Placed {
        var size: CGFloat
        /// What the original and the translation cover, before turning by `angle` about `pivot`.
        var area: CGRect
        var angle: CGFloat = 0
        var pivot: CGPoint = .zero
        var draw: (CGContext) -> Void
    }

    /// Lays out a translation. A line stays one line, as large as the original, then smaller
    /// (to fit `room` across and `tallest` down), then narrower, never onto the lines around it.
    /// A paragraph wraps within its own width, smaller until it fits, and only past that runs
    /// wider, then below.
    private static func place(_ text: String, over block: TextBlock, room: CGFloat, tallest: CGFloat,
                              colours: Colours, alignsRight: Bool = false, size given: CGFloat? = nil) -> Placed {
        let colour = NSColor(cgColor: colours.text) ?? .black
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: size, weight: colours.bold ? .bold : .regular), .foregroundColor: colour,
             .paragraphStyle: style]
        }
        // `lineHeight` is the font size found from the ink (see `Pixels.fontSize`).
        var size = given ?? block.lineHeight

        if block.lineCount == 1 {
            let line = text.replacingOccurrences(of: "\n", with: " ")
            let smallest = min(max(block.lineHeight * 0.6, 6), tallest / 1.25)
            var natural = (line as NSString).size(withAttributes: attributes(size))
            while given == nil, natural.width > room || natural.height > tallest, size > smallest {
                size = max(size * 0.94, smallest)
                natural = (line as NSString).size(withAttributes: attributes(size))
            }
            // Still too long at the smallest size: squeezed sideways, to no less than 70%.
            let squeeze = natural.width > room ? max(room / natural.width, 0.7) : 1
            let width = natural.width * squeeze
            let x = alignsRight ? block.rect.maxX - width : block.rect.minX
            let drawn = CGRect(x: x, y: block.rect.midY - natural.height / 2, width: width, height: natural.height)
            return Placed(size: size, area: block.rect.union(drawn)) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: x, y: block.rect.midY - natural.height / 2)
                ctx.scaleBy(x: squeeze, y: 1)
                (line as NSString).draw(at: .zero, withAttributes: attributes(size))
                ctx.restoreGState()
            }
        }

        var width = block.rect.width
        func measure(_ size: CGFloat) -> CGSize {
            (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin], attributes: attributes(size)).size
        }
        // The longest word, which mustn't be broken in two: a narrow block (a column of
        // vertical writing, say) shrinks its translation until that fits across.
        // Chinese and Japanese wrap between any two characters: no word to keep whole.
        let longest = isCloseSet(text) ? "" : text.components(separatedBy: .whitespacesAndNewlines).max { $0.count < $1.count } ?? ""
        func wordFits(_ size: CGFloat) -> Bool { (longest as NSString).size(withAttributes: attributes(size)).width <= width }
        // Lines of the original as far apart as these will be.
        size = min(size, block.rect.height / CGFloat(block.lineCount) / 1.2)
        let smallest = max(block.lineHeight * 0.5, 6)
        let fits = block.rect.height * 1.08
        var measured = measure(size)
        while measured.height > fits || !wordFits(size), size > smallest {
            size = max(size * 0.93, smallest)
            measured = measure(size)
        }
        if measured.height > fits, room > width {
            width = room
            measured = measure(size)
        }
        let frame = CGRect(x: block.rect.minX, y: block.rect.minY, width: width, height: measured.height + 1)
        return Placed(size: size, area: block.rect.union(frame)) { _ in
            (text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin], attributes: attributes(size))
        }
    }

    /// Lays out the translation of a turned line or of vertical Chinese or Japanese. A turned
    /// line's translation is turned the same way. Vertical text is translated into vertical
    /// text when the translation is Chinese or Japanese; else a single column's translation
    /// runs down it, turned (as on a book's spine), and columns side by side get a paragraph
    /// across their area.
    private static func placeTurned(_ text: String, over block: TextBlock, colours: Colours) -> Placed {
        if block.vertical, isCloseSet(text) { return placeVertical(text, over: block, colours: colours) }
        var frame = block
        if block.vertical {
            if block.lineCount == 1, block.rect.height > block.rect.width * 2.5 {
                let r = block.rect
                frame.rect = CGRect(x: r.midX - r.height / 2, y: r.midY - r.width / 2, width: r.height, height: r.width)
                frame.angle = .pi / 2
            } else {
                frame.lineCount = max(2, Int((block.rect.height / (block.lineHeight * 1.25)).rounded()))
            }
        }
        let laid = place(text, over: frame, room: frame.rect.width * (frame.lineCount == 1 ? 1.15 : 1),
                         tallest: frame.rect.height * 1.1, colours: colours)
        guard frame.angle != 0 else { return laid }
        let centre = CGPoint(x: frame.rect.midX, y: frame.rect.midY)
        return Placed(size: laid.size, area: laid.area.union(frame.rect), angle: frame.angle, pivot: centre) { ctx in
            ctx.saveGState()
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: frame.angle)
            ctx.translateBy(x: -centre.x, y: -centre.y)
            laid.draw(ctx)
            ctx.restoreGState()
        }
    }

    /// Chinese or Japanese text, written in columns from the right, as large as fits the block.
    private static func placeVertical(_ text: String, over block: TextBlock, colours: Colours) -> Placed {
        let font = NSFont.systemFont(ofSize: block.lineHeight, weight: colours.bold ? .bold : .regular)
        // A column takes a little more than its letters' width (the font's line spacing).
        let area = block.rect.insetBy(dx: -block.lineHeight * 0.3, dy: 0)
        func frame(_ size: CGFloat) -> CTFrame {
            let string = NSAttributedString(string: text.replacingOccurrences(of: "\n", with: ""), attributes: [
                .font: font.withSize(size), .foregroundColor: NSColor(cgColor: colours.text) ?? .black,
                .verticalGlyphForm: true,
            ])
            let setter = CTFramesetterCreateWithAttributedString(string)
            let attributes = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: area, transform: nil), attributes)
        }
        let length = text.replacingOccurrences(of: "\n", with: "").utf16.count
        var size = block.lineHeight
        var laid = frame(size)
        while CTFrameGetVisibleStringRange(laid).length < length, size > 6 {
            size = max(size * 0.92, 6)
            laid = frame(size)
        }
        let r = block.rect
        return Placed(size: size, area: r) { ctx in
            // Core Text draws with y going up; the image context's y goes down.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: r.minY + r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            CTFrameDraw(laid, ctx)
            ctx.restoreGState()
        }
    }

    /// Mostly Chinese or Japanese characters, which can be written in columns.
    static func isCloseSet(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cjk = letters.filter { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
        return !letters.isEmpty && cjk.count * 2 >= letters.count
    }

    struct Colours {
        var background: CGColor
        var text: CGColor
        /// The letters cover a lot of their area, as bold ones do.
        var bold: Bool
    }

    /// Reads colours from the image's pixels (row 0 at the top).
    struct Pixels {
        /// The font size of a block's first line, from how tall its ink is and which letters it
        /// has: ascenders or capitals reach about 0.74 of the size above the baseline, other
        /// lower case 0.53, accents another 0.17, descenders 0.22 below; Chinese and Japanese
        /// characters fill about 0.9. Nil when there's too little ink to tell.
        func fontSize(of block: TextBlock, background: CGColor) -> CGFloat? {
            guard let c = background.components, c.count >= 3 else { return nil }
            let r = block.rect
            let line = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / CGFloat(block.lineCount))
            let step = max(1, Int(line.width / 300))
            let rows = Array(Int(line.minY)...Int(line.maxY))
            let inked = rows.map { y in
                stride(from: Int(line.minX), through: Int(line.maxX), by: step).contains { x in
                    guard let p = rgb(x, y) else { return false }
                    return sqrt(pow(p.0 - c[0], 2) + pow(p.1 - c[1], 2) + pow(p.2 - c[2], 2)) > 0.35
                }
            }
            // The run of inked rows around the middle, across the small gaps above accents; a
            // wider gap is the space between lines, past which ink belongs to the next line.
            let centre = inked.count / 2
            guard let middle = (0..<inked.count).lazy.flatMap({ [centre - $0, centre + $0] })
                .first(where: { inked.indices.contains($0) && inked[$0] }) else { return nil }
            let gap = max(2, Int(line.height * 0.12))
            var top = middle, bottom = middle
            var i = middle - 1, blank = 0
            while i >= 0, blank <= gap { if inked[i] { top = i; blank = 0 } else { blank += 1 }; i -= 1 }
            i = middle + 1; blank = 0
            while i < inked.count, blank <= gap { if inked[i] { bottom = i; blank = 0 } else { blank += 1 }; i += 1 }
            guard bottom - top >= 3 else { return nil }
            let span = CGFloat(bottom - top + 1)
            let text = block.text
            if text.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }) {
                return span / 0.9
            }
            let tall = text.contains { $0.isUppercase || $0.isNumber || "bdfhklt".contains($0) }
            let accented = text.contains { !$0.isASCII && $0.isLetter }
            let deep = text.contains { "gjpqy".contains($0) }
            let share = (tall ? 0.74 : 0.53) + (accented ? 0.17 : 0) + (deep ? 0.22 : 0)
            return span / share
        }

        /// Where the background stops to the right of a block (its button's or box's edge, or
        /// something else drawn there), looking along a few rows through it.
        func edge(rightOf block: TextBlock, background: CGColor) -> CGFloat {
            guard let c = background.components, c.count >= 3 else { return CGFloat(width) }
            let r = block.rect
            var edge = width
            for share in [0.2, 0.5, 0.8] as [CGFloat] {
                let y = Int(r.minY + r.height * share)
                var x = Int(r.maxX + block.lineHeight * 0.3)
                var differing = 0
                while x < edge {
                    if let p = rgb(x, y), sqrt(pow(p.0 - c[0], 2) + pow(p.1 - c[1], 2) + pow(p.2 - c[2], 2)) > 0.12 {
                        differing += 1
                        if differing >= 3 { edge = x - 2; break }
                    } else {
                        differing = 0
                    }
                    x += 1
                }
            }
            return CGFloat(edge)
        }

        /// Takes a block's letters out and fills where they were from the pixels around them, so
        /// a photo, gradient or texture behind the text carries on under the translation (a patch
        /// of one colour over it looked pasted on). The background is a gradient fitted to a ring
        /// just outside the block; letters are what differs from it, a little widened for their
        /// soft edges, and are filled from their edges inwards. On a plain or evenly shaded
        /// background the gradient itself fills them, which leaves no streaks.
        func erase(_ block: TextBlock) {
            let pad = max(2, block.lineHeight * 0.2)
            let inner = block.rect.insetBy(dx: -pad, dy: -pad)
            let ringWidth: CGFloat = 3
            let ring = inner.insetBy(dx: -ringWidth, dy: -ringWidth)
            let turn = CGAffineTransform(translationX: block.rect.midX, y: block.rect.midY).rotated(by: block.angle)
                .translatedBy(x: -block.rect.midX, y: -block.rect.midY)
            let back = turn.inverted()
            let area = ring.applying(turn).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !area.isNull, area.width > 2, area.height > 2 else { return }
            let x0 = Int(area.minX), y0 = Int(area.minY), w = Int(area.width), h = Int(area.height)

            // Where each pixel is: 0 outside, 1 in the ring, 2 in the block.
            var zone = [UInt8](repeating: 0, count: w * h)
            var colour = [SIMD3<Double>](repeating: .zero, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let p = CGPoint(x: CGFloat(x0 + x) + 0.5, y: CGFloat(y0 + y) + 0.5).applying(back)
                    zone[i] = inner.contains(p) ? 2 : ring.contains(p) ? 1 : 0
                    if let c = rgb(x0 + x, y0 + y) { colour[i] = SIMD3(Double(c.0), Double(c.1), Double(c.2)) }
                }
            }

            // The gradient through the ring, fitted twice: the second time without the quarter
            // that fit worst (a neighbour's letters, an icon).
            var used = (0..<w * h).filter { zone[$0] == 1 }
            guard used.count >= 6 else { return }
            var plane = (base: SIMD3<Double>.zero, dx: SIMD3<Double>.zero, dy: SIMD3<Double>.zero)
            func predicted(_ i: Int) -> SIMD3<Double> {
                plane.base + plane.dx * Double(i % w - w / 2) + plane.dy * Double(i / w - h / 2)
            }
            func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
                let d = a - b
                return (d * d).sum().squareRoot()
            }
            for pass in 0..<2 {
                plane = Self.fit(used.map { (Double($0 % w - w / 2), Double($0 / w - h / 2), colour[$0]) })
                if pass == 0 {
                    let sorted = used.sorted { distance(colour[$0], predicted($0)) < distance(colour[$1], predicted($1)) }
                    used = Array(sorted.prefix(max(6, sorted.count * 3 / 4)))
                }
            }
            let misses = used.map { distance(colour[$0], predicted($0)) }.sorted()
            let noise = misses[misses.count / 2]

            // The letters: what differs from the background, widened by a pixel or two.
            var missing = (0..<w * h).map { zone[$0] == 2 && distance(colour[$0], predicted($0)) > max(0.1, noise * 3) }
            let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1)]
            for _ in 0..<max(1, Int((block.lineHeight * 0.07).rounded())) {
                var grown = missing
                for i in missing.indices where missing[i] {
                    for (dx, dy) in neighbours {
                        let x = i % w + dx, y = i / w + dy
                        if x >= 0, y >= 0, x < w, y < h, zone[y * w + x] != 0 { grown[y * w + x] = true }
                    }
                }
                missing = grown
            }
            let filled = missing.indices.filter { missing[$0] }
            guard !filled.isEmpty else { return }

            if noise < 0.03 {
                for i in filled { colour[i] = predicted(i) }
            } else {
                // From the edges inwards, each pixel the average of those around it already known.
                var left = filled
                while !left.isEmpty {
                    var known: [(Int, SIMD3<Double>)] = []
                    var still: [Int] = []
                    for i in left {
                        var sum = SIMD3<Double>.zero, n = 0.0
                        for dy in -1...1 {
                            for dx in -1...1 where dx != 0 || dy != 0 {
                                let x = i % w + dx, y = i / w + dy
                                guard x >= 0, y >= 0, x < w, y < h, !missing[y * w + x] else { continue }
                                sum += colour[y * w + x]
                                n += 1
                            }
                        }
                        if n > 0 { known.append((i, sum / n)) } else { still.append(i) }
                    }
                    if known.isEmpty {
                        for i in still { colour[i] = predicted(i) }
                        break
                    }
                    for (i, c) in known { colour[i] = c; missing[i] = false }
                    left = still
                }
                // Softened a little, so the fill shows no streaks from the edges.
                for _ in 0..<2 {
                    let before = colour
                    for i in filled {
                        var sum = before[i], n = 1.0
                        for (dx, dy) in neighbours {
                            let x = i % w + dx, y = i / w + dy
                            guard x >= 0, y >= 0, x < w, y < h else { continue }
                            sum += before[y * w + x]
                            n += 1
                        }
                        colour[i] = sum / n
                    }
                }
            }
            for i in filled {
                let p = data + (y0 + i / w) * bytesPerRow + (x0 + i % w) * 4
                let alpha = Double(p[3]) / 255
                let c = colour[i]
                p[0] = UInt8((min(max(c.x, 0), 1) * alpha * 255).rounded())
                p[1] = UInt8((min(max(c.y, 0), 1) * alpha * 255).rounded())
                p[2] = UInt8((min(max(c.z, 0), 1) * alpha * 255).rounded())
            }
        }

        /// The colour `base + dx·x + dy·y` closest to `samples` (least squares), or their average
        /// when they don't spread out enough to tell a slope.
        static func fit(_ samples: [(x: Double, y: Double, colour: SIMD3<Double>)]) -> (base: SIMD3<Double>, dx: SIMD3<Double>, dy: SIMD3<Double>) {
            let n = Double(samples.count)
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            var sc = SIMD3<Double>.zero, sxc = SIMD3<Double>.zero, syc = SIMD3<Double>.zero
            for s in samples {
                sx += s.x; sy += s.y; sxx += s.x * s.x; syy += s.y * s.y; sxy += s.x * s.y
                sc += s.colour; sxc += s.colour * s.x; syc += s.colour * s.y
            }
            // Cramer's rule on the normal equations.
            func det(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double, _ g: Double, _ h: Double, _ i: Double) -> Double {
                a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
            }
            let d = det(n, sx, sy, sx, sxx, sxy, sy, sxy, syy)
            guard abs(d) > 1e-6 else { return (sc / max(n, 1), .zero, .zero) }
            var base = SIMD3<Double>.zero, dx = SIMD3<Double>.zero, dy = SIMD3<Double>.zero
            for k in 0..<3 {
                base[k] = det(sc[k], sx, sy, sxc[k], sxx, sxy, syc[k], sxy, syy) / d
                dx[k] = det(n, sc[k], sy, sx, sxc[k], sxy, sy, syc[k], syy) / d
                dy[k] = det(n, sx, sc[k], sx, sxx, sxc[k], sy, sxy, syc[k]) / d
            }
            return (base, dx, dy)
        }

        let data: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int

        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let p = data + y * bytesPerRow + x * 4
            let alpha = CGFloat(p[3]) / 255
            guard alpha > 0 else { return (1, 1, 1) }
            return (CGFloat(p[0]) / 255 / alpha, CGFloat(p[1]) / 255 / alpha, CGFloat(p[2]) / 255 / alpha)
        }

        /// The colour around a block: the middle value of a ring just outside it, so stray letters
        /// don't count.
        func background(around block: TextBlock) -> CGColor {
            let c = colours(around: block).background
            return c
        }

        /// The background around a block (the middle value of a ring just outside it, so stray
        /// letters don't count) and its text (what inside differs most from that background).
        func colours(around block: TextBlock) -> Colours {
            let pad = max(2, block.lineHeight * 0.15)
            let ring = block.bounds.insetBy(dx: -pad, dy: -pad)
            var edge: [(CGFloat, CGFloat, CGFloat)] = []
            let step = max(1, Int(max(ring.width, ring.height) / 120))
            for x in stride(from: Int(ring.minX), through: Int(ring.maxX), by: step) {
                if let c = rgb(x, Int(ring.minY)) { edge.append(c) }
                if let c = rgb(x, Int(ring.maxY)) { edge.append(c) }
            }
            for y in stride(from: Int(ring.minY), through: Int(ring.maxY), by: step) {
                if let c = rgb(Int(ring.minX), y) { edge.append(c) }
                if let c = rgb(Int(ring.maxX), y) { edge.append(c) }
            }
            func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
            let background = edge.isEmpty ? (1, 1, 1)
                : (median(edge.map(\.0)), median(edge.map(\.1)), median(edge.map(\.2)))

            var inside: [(colour: (CGFloat, CGFloat, CGFloat), distance: CGFloat)] = []
            let r = block.bounds
            let stepX = max(1, Int(r.width / 60)), stepY = max(1, Int(r.height / 12))
            for y in stride(from: Int(r.minY), to: Int(r.maxY), by: stepY) {
                for x in stride(from: Int(r.minX), to: Int(r.maxX), by: stepX) {
                    guard let c = rgb(x, y) else { continue }
                    let d = sqrt(pow(c.0 - background.0, 2) + pow(c.1 - background.1, 2) + pow(c.2 - background.2, 2))
                    if d > 0.25 { inside.append((c, d)) }
                }
            }
            let text: (CGFloat, CGFloat, CGFloat)
            if inside.isEmpty {
                let light = 0.299 * background.0 + 0.587 * background.1 + 0.114 * background.2 > 0.55
                text = light ? (0.1, 0.1, 0.1) : (1, 1, 1)
            } else {
                // The strongest fifth: the letters' own colour, not their soft edges.
                let strongest = inside.sorted { $0.distance > $1.distance }.prefix(max(1, inside.count / 5))
                let n = CGFloat(strongest.count)
                text = (strongest.map(\.colour.0).reduce(0, +) / n, strongest.map(\.colour.1).reduce(0, +) / n,
                        strongest.map(\.colour.2).reduce(0, +) / n)
            }
            let stroke = strokeWidth(in: block, background: background) / max(block.lineHeight, 1)
            // Small letters, and Chinese and Japanese ones, which pack strokes close together,
            // need thicker strokes still to count as bold.
            let dense = block.lineHeight < 24 || block.text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) }
            return Colours(background: CGColor(srgbRed: background.0, green: background.1, blue: background.2, alpha: 1),
                           text: CGColor(srgbRed: text.0, green: text.1, blue: text.2, alpha: 1),
                           bold: stroke > (dense ? 0.21 : Self.boldStroke))
        }

        /// Stroke width, as a share of the line's height, above which letters read as bold.
        static let boldStroke: CGFloat = 0.155

        /// How thick the letters' strokes are: the middle length of the runs of letter pixels
        /// across a few rows through the first line.
        func strokeWidth(in block: TextBlock, background: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
            var runs: [Int] = []
            let line = CGRect(x: block.rect.minX, y: block.rect.minY, width: block.rect.width, height: block.lineHeight)
            for share in [0.4, 0.5, 0.6, 0.7] as [CGFloat] {
                let y = Int(line.minY + line.height * share)
                var run = 0
                for x in Int(line.minX)...Int(line.maxX) {
                    if let c = rgb(x, y),
                       sqrt(pow(c.0 - background.0, 2) + pow(c.1 - background.1, 2) + pow(c.2 - background.2, 2)) > 0.35 {
                        run += 1
                    } else if run > 0 {
                        runs.append(run)
                        run = 0
                    }
                }
            }
            guard !runs.isEmpty else { return 0 }
            return CGFloat(runs.sorted()[runs.count / 2])
        }
    }

    // MARK: Languages

    /// The language of a block, one of `allowed` (the languages text is read in, from Settings →
    /// Text Recognition), to send it with others in the same language (a service guesses one
    /// language per request) and to leave alone what's already in the target. Nil for a block
    /// with no letters (a number, a price), which stays as it is.
    public static func language(of text: String, allowed: [String]) -> String? {
        guard text.contains(where: \.isLetter), !isAddress(text), !isCode(text) else { return nil }
        let allowed = allowed.isEmpty ? TextRecognizer.defaultLanguages : allowed
        func pick(_ base: String) -> String? { allowed.first { Translator.base(of: $0) == base } }
        let scalars = text.unicodeScalars
        // Kana only appears in Japanese, Hangul only in Korean.
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value) }),
           let japanese = pick("ja") { return japanese }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }),
           let korean = pick("ko") { return korean }
        // Otherwise the likeliest of the allowed languages, however short the text.
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = allowed.map { NLLanguage(rawValue: Translator.base(of: $0) == "zh" ? $0 : Translator.base(of: $0)) }
        recognizer.processString(text)
        guard let found = recognizer.dominantLanguage?.rawValue else { return allowed.first }
        return allowed.first { Translator.base(of: $0) == Translator.base(of: found) } ?? allowed.first
    }

    /// An email address, a link or a file name: one word with an @, ://, www. or a file
    /// extension, which reads the same in every language.
    static func isAddress(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.contains(where: \.isWhitespace) else { return false }
        if t.contains("@") || t.contains("://") || t.lowercased().hasPrefix("www.") { return true }
        // name.ext, as in a list of files.
        return t.range(of: #"^[^.]+\.[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil && t.contains(where: \.isLetter)
            && !(t.last.map { ".!?".contains($0) } ?? false)
    }

    /// A code, ID, version, measurement or stray mark ("SKU-48213", "v2.4.1", "#3A7BD5", "12kg",
    /// "x"): what reads the same in every language, or what Vision made of a logo or an icon.
    static func isCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let letters = t.filter(\.isLetter).count
        let marks = t.filter { !$0.isWhitespace }.count
        // One Latin letter on its own; Chinese and Japanese say a word in one character.
        if letters <= 1, t.unicodeScalars.allSatisfy(\.isASCII) { return true }
        // Mostly digits and symbols.
        if Double(letters) < Double(marks) * 0.3 { return true }
        // One word with digits in it, as many digits and marks as letters.
        guard !t.contains(where: \.isWhitespace), t.contains(where: \.isNumber) else { return false }
        return letters <= marks - letters
    }

    /// The first language in `priority` that some block isn't already in.
    public static func target(for languages: [String?], priority: [String]) -> String {
        let languages = languages.compactMap { $0 }
        let order = priority.isEmpty ? Translator.defaultTargets : priority
        return order.first { target in languages.contains { Translator.base(of: $0) != Translator.base(of: target) } } ?? order[0]
    }

    /// Whether a block in `language` is already in `target` and stays as it is.
    public static func isAlready(_ language: String, in target: String) -> Bool {
        Translator.base(of: language) == Translator.base(of: target)
    }

    // MARK: Sending the blocks together

    /// The blocks as one text, a line each, so they can be translated in one request.
    public static func joined(_ blocks: [TextBlock]) -> String {
        blocks.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    /// A translation of `joined(blocks)` split back into one text per block, or nil if the
    /// service didn't keep one line per block.
    public static func split(_ translation: String, count: Int) -> [String]? {
        let parts = translation.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.count == count ? parts : nil
    }
}
