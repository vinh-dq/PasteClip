import AppKit

public extension NSAttributedString.Key {
    /// A Slack mention, as its JSON, so it goes back to Slack unchanged.
    static let slackMention = NSAttributedString.Key("PasteClipSlackMention")
    /// Something Slack inserts that isn't text, such as an emoji, as its JSON.
    static let slackEmbed = NSAttributedString.Key("PasteClipSlackEmbed")
    /// The format of a line (list, quote, code block), as JSON, set on its line break.
    static let slackLine = NSAttributedString.Key("PasteClipSlackLine")
    /// Other Slack formatting PasteClip doesn't show, as JSON, so it isn't lost.
    static let slackOther = NSAttributedString.Key("PasteClipSlackOther")
}

/// Formatting Slack puts on the clipboard when text is copied from its message box: a Quill
/// delta (`slack/texty`) inside Chromium's custom clipboard data, with no RTF or HTML beside it.
/// PasteClip reads it to show and edit that text, and writes it back so pasting into Slack keeps
/// mentions, bold, links and the rest.
public enum SlackFormatting {
    static let customDataType = "org.chromium.web-custom-data"
    static let deltaKey = "slack/texty"
    private static let plainKey = "public.utf8-plain-text"
    /// Types in the copied item that stay valid after the text is edited.
    private static let keptTypes: Set<String> = [customDataType, "org.chromium.source-url",
                                                 "org.chromium.internal.source-rfh-token"]
    private static let lineKeys: Set<String> = ["list", "blockquote", "code-block", "header", "indent", "align"]
    private static let shownKeys: Set<String> = ["bold", "italic", "strike", "code", "link", "slackmention"]

    /// The formatted text, if the clip was copied from Slack's message box.
    public static func attributedString(from contents: [[String: Data]]) -> NSAttributedString? {
        guard let data = contents.first?[customDataType],
              let delta = ChromiumCustomData.decode(data)?.first(where: { $0.key == deltaKey })?.value,
              let root = try? JSONSerialization.jsonObject(with: Data(delta.utf8)) as? [String: Any],
              let ops = root["ops"] as? [[String: Any]] else { return nil }
        let base = NSFont.systemFont(ofSize: 13)
        let result = NSMutableAttributedString()
        for op in ops {
            let format = op["attributes"] as? [String: Any] ?? [:]
            var attributes: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.textColor]
            let text: String
            if let string = op["insert"] as? String {
                text = string
            } else if let object = op["insert"] {
                text = label(ofEmbed: object)
                attributes[.slackEmbed] = json(object)
            } else {
                continue
            }
            if !lineKeys.isDisjoint(with: format.keys) {
                attributes[.slackLine] = json(format)
                result.append(NSAttributedString(string: text, attributes: attributes))
                continue
            }
            var font = format["code"] as? Bool == true ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : base
            if format["bold"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if format["italic"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attributes[.font] = font
            if format["strike"] as? Bool == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = format["link"] as? String { attributes[.link] = URL(string: link) ?? link }
            if let mention = format["slackmention"] {
                attributes[.slackMention] = json(mention)
                attributes[.foregroundColor] = NSColor.linkColor
            }
            let other = format.filter { !shownKeys.contains($0.key) }
            if !other.isEmpty { attributes[.slackOther] = json(other) }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        indentFormattedLines(in: result)
        return result
    }

    /// The copied item with its text replaced by `text`, or nil if it wasn't copied from Slack's
    /// message box. Types that still hold the old text are left out.
    public static func contents(_ contents: [[String: Data]], replacingTextWith text: NSAttributedString) -> [[String: Data]]? {
        guard let entry = contents.first, let data = entry[customDataType],
              var pairs = ChromiumCustomData.decode(data),
              let i = pairs.firstIndex(where: { $0.key == deltaKey }) else { return nil }
        pairs[i].value = delta(from: text)
        if let j = pairs.firstIndex(where: { $0.key == plainKey }) { pairs[j].value = text.string }
        var updated = entry.filter { keptTypes.contains($0.key) }
        updated[customDataType] = ChromiumCustomData.encode(pairs)
        updated[plainKey] = Data(text.string.utf8)
        return [updated]
    }

    /// The text without Slack's own attributes and display colours, for RTF and HTML.
    public static func portable(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: result.length)
        for key in [NSAttributedString.Key.slackMention, .slackEmbed, .slackLine, .slackOther] {
            result.removeAttribute(key, range: all)
        }
        // The text colour follows light and dark mode; written out it would be fixed to one of them.
        text.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            let mention = text.attribute(.slackMention, at: range.location, effectiveRange: nil) != nil
            if mention || value as? NSColor == NSColor.textColor { result.removeAttribute(.foregroundColor, range: range) }
        }
        return result
    }

    // MARK: - Delta

    static func delta(from text: NSAttributedString) -> String {
        var ops: [[String: Any]] = []
        func add(_ insert: Any, _ format: [String: Any]) {
            if let string = insert as? String, let last = ops.last, let previous = last["insert"] as? String,
               json(last["attributes"] ?? [String: Any]()) == json(format) {
                ops[ops.count - 1]["insert"] = previous + string
                return
            }
            var op: [String: Any] = ["insert": insert]
            if !format.isEmpty { op["attributes"] = format }
            ops.append(op)
        }
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var run = string.substring(with: range)
            if let embed = (attributes[.slackEmbed] as? String).flatMap(object(from:)) {
                let label = label(ofEmbed: embed)
                // Side-by-side copies of one emoji make a single run.
                if !label.isEmpty, run == String(repeating: label, count: run.count / label.count) {
                    for _ in 0..<(run.count / label.count) { add(embed, [:]) }
                    return
                }
            }
            let line = (attributes[.slackLine] as? String).flatMap(object(from:)) as? [String: Any]
            var format = (attributes[.slackOther] as? String).flatMap(object(from:)) as? [String: Any] ?? [:]
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { format["bold"] = true }
                if traits.contains(.italicFontMask) { format["italic"] = true }
                if font.isFixedPitch { format["code"] = true }
            }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { format["strike"] = true }
            if let link = attributes[.link] { format["link"] = (link as? URL)?.absoluteString ?? "\(link)" }
            // A mention stays one only while its name is untouched; text typed after it isn't part of it.
            if let json = attributes[.slackMention] as? String, let mention = object(from: json) as? [String: Any],
               let label = mention["label"] as? String, !label.isEmpty {
                var mentionFormat = format
                mentionFormat["slackmention"] = mention
                while run.hasPrefix(label) {
                    add(label, mentionFormat)
                    run.removeFirst(label.count)
                }
            }
            // A line's format sits on its line break; anything typed after the break is plain.
            for part in run.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if part.offset > 0 { add("\n", line ?? [:]) }
                if !part.element.isEmpty { add(String(part.element), line == nil ? format : [:]) }
            }
        }
        return json(["ops": ops])
    }

    /// Lists and quotes are shown indented; their markers are Slack's to draw.
    private static func indentFormattedLines(in text: NSMutableAttributedString) {
        let string = text.string as NSString
        text.enumerateAttribute(.slackLine, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 18
            style.headIndent = 18
            text.addAttribute(.paragraphStyle, value: style, range: string.lineRange(for: NSRange(location: range.location, length: 0)))
        }
    }

    private static func label(ofEmbed object: Any) -> String {
        guard let (kind, value) = (object as? [String: Any])?.first else { return "\u{FFFC}" }
        let details = value as? [String: Any]
        if let hex = details?["unicode"] as? String {
            let scalars = hex.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap { Unicode.Scalar($0) } }
            if !scalars.isEmpty { return String(String.UnicodeScalarView(scalars)) }
        }
        if let name = details?["name"] as? String { return ":\(name):" }
        return "[\(kind)]"
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(from json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
    }
}

/// Chromium's custom clipboard data: a 32-bit payload size, then a count and that many key and
/// value pairs, each string a 32-bit length and UTF-16 units padded to four bytes, all little-endian.
enum ChromiumCustomData {
    static func decode(_ data: Data) -> [(key: String, value: String)]? {
        let bytes = [UInt8](data)
        var offset = 0
        func number() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        func string() -> String? {
            guard let count = number(), count <= (bytes.count - offset) / 2 else { return nil }
            let units = (0..<count).map { UInt16(bytes[offset + 2 * $0]) | UInt16(bytes[offset + 2 * $0 + 1]) << 8 }
            offset += (2 * count + 3) & ~3
            return String(decoding: units, as: UTF16.self)
        }
        guard number() == bytes.count - 4, let count = number() else { return nil }
        var pairs: [(key: String, value: String)] = []
        for _ in 0..<count {
            guard let key = string(), let value = string() else { return nil }
            pairs.append((key, value))
        }
        return pairs
    }

    static func encode(_ pairs: [(key: String, value: String)]) -> Data {
        var payload: [UInt8] = []
        func putNumber(_ value: Int) { payload += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        func putString(_ string: String) {
            let units = Array(string.utf16)
            putNumber(units.count)
            for unit in units { payload += [UInt8(truncatingIfNeeded: unit), UInt8(unit >> 8)] }
            while payload.count % 4 != 0 { payload.append(0) }
        }
        putNumber(pairs.count)
        for pair in pairs {
            putString(pair.key)
            putString(pair.value)
        }
        let size = payload.count
        return Data((0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) } + payload)
    }
}
