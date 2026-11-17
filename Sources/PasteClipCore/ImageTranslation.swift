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

    public init(text: String, rect: CGRect, lineHeight: CGFloat, lineCount: Int) {
        self.text = text
        self.rect = rect
        self.lineHeight = lineHeight
        self.lineCount = lineCount
    }
}

/// Puts a translation on an image where its text was: the lines Vision found become paragraphs,
/// each is covered with the colour around it and its translation is written in its place.
public enum ImageTranslation {
    // MARK: Paragraphs

    /// Lines joined into the paragraphs they belong to, top to bottom. A line joins the one above
    /// it when it's the same size, starts in line with it, follows closely, and the line above
    /// ran on to its end (a full line that doesn't finish a sentence) and this one carries on (in
    /// lower case); labels, menu items and list entries stay on their own.
    public static func blocks(from lines: [TextRecognizer.Line], size: CGSize) -> [TextBlock] {
        struct Row {
            var text: String
            var rect: CGRect
            var closeSet: Bool
        }
        let rows = lines.map { line -> Row in
            let b = line.box
            return Row(text: line.text.trimmingCharacters(in: .whitespaces),
                       rect: CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                                    width: b.width * size.width, height: b.height * size.height),
                       closeSet: line.isHanOrKana)
        }
        .filter { !$0.text.isEmpty }
        .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }

        var groups: [[Row]] = []
        for row in rows {
            let joins: ([Row]) -> Bool = { group in
                guard let last = group.last else { return false }
                let h = last.rect.height
                let widest = group.map(\.rect.width).max() ?? 0
                let gap = row.rect.minY - last.rect.maxY
                let sameSize = max(h, row.rect.height) / max(min(h, row.rect.height), 1) <= 1.35
                let aligned = abs(row.rect.minX - last.rect.minX) <= h * 1.2
                let ranOn = last.rect.width >= max(widest, row.rect.width) * 0.75
                    && last.text.count >= (last.closeSet ? 16 : 20)
                    && !(last.text.last.map { ".!?。！？:：".contains($0) } ?? false)
                // A wrapped sentence goes on in lower case (or after a comma or hyphen); the next
                // entry of a list starts with a capital. Chinese and Japanese have no case to go by.
                let continues = last.closeSet || row.closeSet || row.text.first?.isLowercase == true
                    || last.text.hasSuffix(",") || last.text.hasSuffix("-")
                return sameSize && aligned && ranOn && continues && gap > -h * 0.3 && gap < h * 0.9
            }
            if let i = groups.lastIndex(where: joins) {
                groups[i].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups.map { group in
            var text = group[0].text
            for (previous, row) in zip(group, group.dropFirst()) {
                // Chinese and Japanese lines run on without a space.
                text += (previous.closeSet && row.closeSet ? "" : " ") + row.text
            }
            let rect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
            let lineHeight = group.map(\.rect.height).reduce(0, +) / CGFloat(group.count)
            return TextBlock(text: text, rect: rect, lineHeight: lineHeight, lineCount: group.count)
        }
    }

    // MARK: Drawing

    /// `image` with each block covered and its translation written in its place, the same size
    /// as the image. A missing or empty translation leaves its block as it was.
    public static func render(_ image: CGImage, blocks: [TextBlock], translations: [String]) -> CGImage? {
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
        // font size for large letters to nearly twice it for small ones.
        let blocks = evenedOut(blocks.enumerated().map { i, block in
            var sized = block
            if let size = pixels.fontSize(of: block, background: backgrounds[i]) {
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
            let others = blocks.filter { $0 != block }
            func overlapsColumn(_ other: TextBlock) -> Bool {
                other.rect.minX < block.rect.maxX && other.rect.maxX > block.rect.minX
            }
            // How far right it may run: to the next block on its row, the edge of what it sits
            // on (a button, a box), or the image's edge.
            let next = others.filter { $0.rect.minX >= block.rect.maxX - 1
                && $0.rect.minY < block.rect.maxY && $0.rect.maxY > block.rect.minY }.map(\.rect.minX).min()
            let edge = pixels.edge(rightOf: block, background: colours[i].background)
            // Labels lined up on their right edges (as beside a form's fields) stay that way,
            // growing to the left, up to the block before them on their row.
            let alignsRight = block.lineCount == 1 && others.contains {
                abs($0.rect.maxX - block.rect.maxX) < block.lineHeight * 0.4
                    && abs($0.rect.minX - block.rect.minX) > block.lineHeight * 0.5
                    && abs($0.rect.midY - block.rect.midY) < block.lineHeight * 8
            }
            let previous = others.filter { $0.rect.maxX <= block.rect.minX + 1
                && $0.rect.minY < block.rect.maxY && $0.rect.maxY > block.rect.minY }.map(\.rect.maxX).max()
            let room = alignsRight
                ? max(block.rect.maxX - (previous ?? 0) - block.lineHeight * 0.5, block.rect.width)
                : max(min(next ?? CGFloat(width), edge) - block.lineHeight * 0.5 - block.rect.minX, block.rect.width)
            // How tall a line may be without reaching the lines above and below it: the distance
            // between the middles of neighbouring lines, which is even down a list where
            // Vision's boxes aren't.
            let pitches = others.filter { overlapsColumn($0) && abs($0.rect.midY - block.rect.midY) > block.lineHeight * 0.5 }
                .map { abs($0.rect.midY - block.rect.midY) }
            let tallest = max(min(block.lineHeight * 1.6, pitches.min() ?? .greatestFiniteMagnitude), block.lineHeight * 0.9)
            fits[i] = (room, tallest, alignsRight)
            placed[i] = place(text, over: block, room: room, tallest: tallest, colours: colours[i], alignsRight: alignsRight)
        }
        // Lines of one list come out one size: the smallest any of them needed.
        let lists = listGroups(blocks)
        for (i, item) in placed where blocks[i].lineCount == 1 {
            let smallest = placed.filter { lists[$0.key] == lists[i] }.map(\.value.size).min() ?? item.size
            guard smallest < item.size, let fit = fits[i] else { continue }
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            placed[i] = place(text, over: blocks[i], room: fit.room, tallest: fit.tallest, colours: colours[i],
                              alignsRight: fit.alignsRight, size: smallest)
        }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        // Every background first, then every text, so no block's background covers another's text.
        for item in placed.values {
            ctx.setFillColor(item.background)
            ctx.addPath(CGPath(roundedRect: item.area, cornerWidth: item.corner, cornerHeight: item.corner, transform: nil))
            ctx.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for item in placed.values { item.draw(ctx) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Lines of a list or column (one under another, starting at the same place, about the same
    /// size) given the same height, the middle of theirs, so their translations come out the same
    /// size: Vision's boxes for lines of one size vary, more so for small letters.
    static func evenedOut(_ blocks: [TextBlock]) -> [TextBlock] {
        let lists = listGroups(blocks)
        return blocks.enumerated().map { i, block in
            guard block.lineCount == 1 else { return block }
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
        for i in blocks.indices where blocks[i].lineCount == 1 {
            for j in blocks.indices where j > i && blocks[j].lineCount == 1 {
                let a = blocks[i], b = blocks[j]
                let h = max(a.lineHeight, b.lineHeight)
                guard abs(a.rect.minX - b.rect.minX) <= h, abs(a.rect.midY - b.rect.midY) <= h * 2.2,
                      h / max(min(a.lineHeight, b.lineHeight), 1) <= 1.35 else { continue }
                group[root(j)] = root(i)
            }
        }
        return blocks.indices.map(root)
    }

    /// A translation laid out over its block: the background to cover it with, and the text.
    private struct Placed {
        var size: CGFloat
        var area: CGRect
        var corner: CGFloat
        var background: CGColor
        var draw: (CGContext) -> Void
    }

    /// Lays out a translation. A line stays one line, as large as the original, then smaller
    /// (to fit `room` across and `tallest` down), then narrower, never onto the lines around it.
    /// A paragraph wraps within its own width, smaller until it fits, and only past that runs
    /// wider, then below.
    private static func place(_ text: String, over block: TextBlock, room: CGFloat, tallest: CGFloat,
                              colours: Colours, alignsRight: Bool = false, size given: CGFloat? = nil) -> Placed {
        let pad = max(2, block.lineHeight * 0.15)
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
            let left = min(x, block.rect.minX)
            let area = CGRect(x: left - pad * 0.6, y: block.rect.minY - pad * 0.4,
                              width: max(block.rect.maxX, x + width) - left + pad * 1.2, height: block.rect.height + pad * 0.8)
            return Placed(size: size, area: area, corner: pad, background: colours.background) { ctx in
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
        // Lines of the original as far apart as these will be.
        size = min(size, block.rect.height / CGFloat(block.lineCount) / 1.2)
        let smallest = max(block.lineHeight * 0.5, 6)
        let fits = block.rect.height * 1.08
        var measured = measure(size)
        while measured.height > fits, size > smallest {
            size = max(size * 0.93, smallest)
            measured = measure(size)
        }
        if measured.height > fits, room > width {
            width = room
            measured = measure(size)
        }
        var area = block.rect.insetBy(dx: -pad * 0.6, dy: -pad * 0.4)
        area.size.width = max(area.width, measured.width + pad * 1.2)
        area.size.height = max(area.height, measured.height + pad)
        let frame = CGRect(x: block.rect.minX, y: block.rect.minY, width: width, height: measured.height + 1)
        return Placed(size: size, area: area, corner: pad, background: colours.background) { _ in
            (text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin], attributes: attributes(size))
        }
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
            let ring = block.rect.insetBy(dx: -pad, dy: -pad)
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
            let r = block.rect
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
        guard text.contains(where: \.isLetter), !isAddress(text) else { return nil }
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
