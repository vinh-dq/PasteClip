import Foundation

/// A block style a line of a note can have, for the format menu and its shortcuts.
public enum NoteLineStyle: Equatable {
    case heading(Int), bullet, numbered, quote, task
}

/// What Return does at the end of a list line.
public enum NoteContinuation: Equatable {
    case none
    /// Insert this after the line break (the next marker).
    case insert(String)
    /// The line is only a marker: remove this many characters from its start instead.
    case clear(Int)
}

/// Text rules for notes: titles, list markers, tasks. No UI, so they can be tested.
public enum NoteMarkdown {
    private static let task = try! NSRegularExpression(pattern: #"^(\s*)- \[( |x|X)\] "#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)[-*•] "#)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\s*)(\d+)\. "#)
    private static let quote = try! NSRegularExpression(pattern: #"^(\s*)> ?"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,3}) "#)

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    /// Length in UTF-16 units of the marker at the start of a line (0 when it has none).
    public static func markerLength(of line: String) -> Int {
        for regex in [task, bullet, numbered, quote, heading] {
            if let m = match(regex, line) { return m.range.length }
        }
        return 0
    }

    public static func stripMarker(_ line: String) -> String {
        let n = markerLength(of: line)
        return n == 0 ? line : (line as NSString).substring(from: n)
    }

    public static func title(of text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let t = stripMarker(String(line)).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return "New Note"
    }

    public static func style(of line: String) -> NoteLineStyle? {
        if match(task, line) != nil { return .task }
        if let m = match(heading, line) { return .heading(m.range.length - 1) }
        if match(bullet, line) != nil { return .bullet }
        if match(numbered, line) != nil { return .numbered }
        if match(quote, line) != nil { return .quote }
        return nil
    }

    /// Whether a task line is ticked; nil for any other line.
    public static func isTicked(_ line: String) -> Bool? {
        guard let m = match(task, line) else { return nil }
        return (line as NSString).substring(with: m.range(at: 2)) != " "
    }

    /// The line with its task ticked or unticked; unchanged if it isn't a task.
    public static func togglingTask(_ line: String) -> String {
        guard let m = match(task, line) else { return line }
        let box = m.range(at: 2)
        return (line as NSString).replacingCharacters(in: box, with: box.length == 1 && isTicked(line) == false ? "x" : " ")
    }

    /// The line in `style`, or with it taken off when it already has it; another marker is replaced.
    public static func toggling(_ style: NoteLineStyle, on line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        // The marker's own match includes its indent, so what's left is the text.
        let body = String(stripMarker(line).drop { $0 == " " || $0 == "\t" })
        if Self.style(of: line) == style { return indent + body }
        let prefix: String
        switch style {
        case .heading(let n): prefix = String(repeating: "#", count: n) + " "
        case .bullet: prefix = "- "
        case .numbered: prefix = "1. "
        case .quote: prefix = "> "
        case .task: prefix = "- [ ] "
        }
        // A heading has no indent; lists keep theirs.
        if case .heading = style { return prefix + body.trimmingCharacters(in: .whitespaces) }
        return indent + prefix + body
    }

    /// What Return should do at the end of `line`.
    public static func continuation(afterLine line: String) -> NoteContinuation {
        let marker = markerLength(of: line)
        guard marker > 0 else { return .none }
        let rest = (line as NSString).substring(from: marker).trimmingCharacters(in: .whitespaces)
        // Headings end with the line; they don't continue.
        if case .heading? = style(of: line) { return .none }
        if rest.isEmpty { return .clear(marker) }
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        switch style(of: line) {
        case .task?: return .insert(indent + "- [ ] ")
        case .bullet?:
            let m = match(bullet, line)!
            return .insert((line as NSString).substring(with: m.range))
        case .numbered?:
            let m = match(numbered, line)!
            let n = Int((line as NSString).substring(with: m.range(at: 2))) ?? 0
            return .insert(indent + "\(n + 1). ")
        case .quote?: return .insert(indent + "> ")
        default: return .none
        }
    }

    /// `text` with `marker` (`**`, `*`, `~~`, `` ` ``, `==`) put around `range`, or taken off when it's
    /// already there. With nothing selected the marker goes in twice and the caret between them.
    /// Returns the new text and the range to select.
    public static func wrapping(_ text: String, range: NSRange, with marker: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let m = marker.utf16.count
        let before = range.location >= m ? ns.substring(with: NSRange(location: range.location - m, length: m)) : ""
        let afterStart = range.location + range.length
        let after = afterStart + m <= ns.length ? ns.substring(with: NSRange(location: afterStart, length: m)) : ""
        if before == marker && after == marker {
            let out = ns.replacingCharacters(in: NSRange(location: afterStart, length: m), with: "")
            let out2 = (out as NSString).replacingCharacters(in: NSRange(location: range.location - m, length: m), with: "")
            return (out2, NSRange(location: range.location - m, length: range.length))
        }
        let selected = ns.substring(with: range)
        let out = ns.replacingCharacters(in: range, with: marker + selected + marker)
        return (out, NSRange(location: range.location + m, length: range.length))
    }

    /// A note as a Markdown file's contents.
    public static func exportText(_ note: Note) -> String { note.text }
}
