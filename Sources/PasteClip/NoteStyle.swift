import AppKit
import PasteClipCore
import SwiftUI

extension NoteColor {
    /// The colour of its dot and its tab. The glass of a note is tinted with it, softly.
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 0.96, green: 0.76, blue: 0.20, alpha: 1)
        case .orange: return NSColor(srgbRed: 0.96, green: 0.52, blue: 0.22, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.58, green: 0.40, blue: 0.93, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1)
        case .green: return NSColor(srgbRed: 0.25, green: 0.70, blue: 0.45, alpha: 1)
        case .slate: return NSColor(srgbRed: 0.38, green: 0.46, blue: 0.58, alpha: 1)
        case .graphite: return NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1)
        case .gray: return NSColor(srgbRed: 0.58, green: 0.58, blue: 0.62, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Tint for a note's glass: enough to read as that colour, still see-through.
    var glassTint: NSColor { nsColor.withAlphaComponent(self == .graphite ? 0.5 : 0.30) }
}

extension AppSettings {
    var notesBodyFont: NSFont {
        let size = CGFloat(notesFontSize)
        let base = NSFont.systemFont(ofSize: size)
        switch notesFont {
        case .system: return base
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .rounded: return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .serif: return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
    }
}

/// Marks the leading marker of a list line, which is drawn by the text view as a box, a dot or a bar.
enum NoteMarker: Int {
    case task = 1, taskDone, bullet, quote
    static let key = NSAttributedString.Key("PasteClipNoteMarker")
}

/// Styles the Markdown of a note as it's typed. The text itself stays plain, so a note reads the
/// same anywhere. Nothing raw gets in the way of reading: list markers become a box, a dot or a
/// bar, and the other markers (`**`, `#`, `` ` ``…) are hidden, except on the line being edited,
/// where they show dimmed so they can be changed.
enum NoteStyler {
    private static let inline: [(NSRegularExpression, (inout [NSAttributedString.Key: Any], NSFont) -> Void)] = {
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            (rx(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#), { a, f in a[.font] = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }),
            (rx(#"(?<![\*\w])(\*)(?=[^\s\*])(.+?)(?<=[^\s\*])(\*)(?![\*\w])"#), { a, f in a[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }),
            (rx(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#), { a, _ in a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }),
            (rx(#"(==)(?=\S)(.+?)(?<=\S)(==)"#), { a, _ in a[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.4) }),
            (rx(#"(`)([^`\n]+)(`)"#), { a, f in
                a[.font] = NSFont.monospacedSystemFont(ofSize: f.pointSize * 0.92, weight: .regular)
                a[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.09) }),
        ]
    }()

    private static let links = try! NSRegularExpression(pattern: #"https?://[^\s<>\"]+"#)

    /// Width the marker of a list line takes, so the text after it lines up on every line.
    static func markerWidth(_ kind: NoteLineStyle, fontSize: CGFloat) -> CGFloat {
        switch kind {
        case .task: return fontSize * 1.75
        case .bullet: return fontSize * 1.75
        case .quote: return fontSize * 1.1
        default: return 0
        }
    }

    static func indentUnit(fontSize: CGFloat) -> CGFloat { fontSize * 1.3 }

    /// Restyles the paragraphs touching `range`. `active` is the selection: its lines show their markers.
    static func apply(to storage: NSTextStorage, range: NSRange, settings: AppSettings, active: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let font = settings.notesBodyFont
        let start = min(range.location, text.length - 1)
        let paragraphs = text.paragraphRange(for: NSRange(location: start, length: max(0, min(range.length, text.length - start))))
        text.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, lineRange, _, _ in
            let isActive = active.location <= lineRange.location + lineRange.length && active.location + active.length >= lineRange.location
            style(storage, text.substring(with: lineRange), lineRange, font, settings.notesMarkdown, isActive)
        }
    }

    /// Clear text in a small font, spaced to take exactly `width`.
    private static func collapse(_ storage: NSTextStorage, _ range: NSRange, width: CGFloat, font: NSFont) {
        let small = NSFont.systemFont(ofSize: max(1, font.pointSize * 0.5))
        let natural = (storage.attributedSubstring(from: range).string as NSString).size(withAttributes: [.font: small]).width
        storage.addAttributes([.font: small, .foregroundColor: NSColor.clear, .kern: (width - natural) / CGFloat(max(1, range.length))],
                              range: range)
    }

    private static func hide(_ storage: NSTextStorage, _ range: NSRange) {
        storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: range)
    }

    private static func style(_ storage: NSTextStorage, _ line: String, _ range: NSRange, _ font: NSFont, _ markdown: Bool, _ active: Bool) {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        let marker = markdown ? NoteMarkdown.markerLength(of: line) : 0
        let kind = markdown ? NoteMarkdown.style(of: line) : nil
        let size = font.pointSize
        if case .heading(let n)? = kind {
            let scale: CGFloat = [1.5, 1.3, 1.15][max(0, min(2, n - 1))]
            base[.font] = NSFontManager.shared.convert(NSFont(descriptor: font.fontDescriptor, size: size * scale) ?? font,
                                                       toHaveTrait: .boldFontMask)
            para.paragraphSpacingBefore = 4
        }
        var width: CGFloat = 0
        if let kind, marker > 0 {
            let level = CGFloat(line.prefix { $0 == " " }.count / 2)
            width = Self.markerWidth(kind, fontSize: size)
            if width > 0 { width += level * indentUnit(fontSize: size) }
            if kind == .numbered {
                width = (String(line.prefix(marker)) as NSString).size(withAttributes: [.font: font]).width
            }
            para.headIndent = width
        }
        if case .quote? = kind { base[.foregroundColor] = NSColor.secondaryLabelColor }
        let ticked = kind == .task && NoteMarkdown.isTicked(line) == true
        if ticked {
            base[.foregroundColor] = NSColor.secondaryLabelColor
            base[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // A line with nothing but a hidden marker would be as tall as its small font and cut the line off.
        if let f = base[.font] as? NSFont { para.minimumLineHeight = ceil(f.ascender - f.descender + f.leading) }
        storage.setAttributes(base, range: range)
        guard markdown else { return }
        if marker > 0, let kind {
            let mr = NSRange(location: range.location, length: marker)
            storage.removeAttribute(.strikethroughStyle, range: mr)
            switch kind {
            case .task:
                collapse(storage, mr, width: width, font: font)
                storage.addAttribute(NoteMarker.key, value: (ticked ? NoteMarker.taskDone : NoteMarker.task).rawValue, range: mr)
            case .bullet:
                collapse(storage, mr, width: width, font: font)
                storage.addAttribute(NoteMarker.key, value: NoteMarker.bullet.rawValue, range: mr)
            case .quote:
                collapse(storage, mr, width: width, font: font)
                storage.addAttribute(NoteMarker.key, value: NoteMarker.quote.rawValue, range: mr)
            case .numbered:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: mr)
            case .heading:
                if active { storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: mr) } else { hide(storage, mr) }
            }
        }
        for m in links.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            var found = m.range
            // Punctuation after a link belongs to the sentence.
            while found.length > 1,
                  let last = (line as NSString).substring(with: NSRange(location: found.location + found.length - 1, length: 1)).first,
                  ".,;:!?)]}'\"".contains(last) { found.length -= 1 }
            guard let url = URL(string: (line as NSString).substring(with: found)) else { continue }
            storage.addAttribute(.link, value: url, range: NSRange(location: range.location + found.location, length: found.length))
        }
        for (regex, attrs) in inline {
            regex.enumerateMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) { m, _, _ in
                guard let m else { return }
                let whole = NSRange(location: range.location + m.range.location, length: m.range.length)
                var a: [NSAttributedString.Key: Any] = [:]
                attrs(&a, (storage.attribute(.font, at: whole.location, effectiveRange: nil) as? NSFont) ?? font)
                storage.addAttributes(a, range: whole)
                for g in [1, 3] {
                    let r = NSRange(location: range.location + m.range(at: g).location, length: m.range(at: g).length)
                    if active { storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r) } else { hide(storage, r) }
                }
            }
        }
    }
}
