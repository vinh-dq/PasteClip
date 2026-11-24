import Foundation

/// The colour of a note: tints its glass, its tab on the screen edge and its dot.
public enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case yellow, orange, purple, blue, green, slate, graphite, gray
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    /// The colours a new note takes in turn, so the edge bar isn't one colour.
    public static let rotation: [NoteColor] = [.yellow, .orange, .purple, .blue, .green]
}

/// A note. The text is plain Markdown: bold, headings, lists and tasks stay editable as text, and
/// the editor only styles them while it's shown, so a note is readable in any other app too.
public struct Note: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var text: String
    public var color: NoteColor
    /// Kept on the screen above other windows.
    public var pinned = false
    public var archived = false
    public var created = Date()
    public var modified = Date()

    public init(text: String = "", color: NoteColor = .yellow) {
        self.text = text
        self.color = color
    }

    /// The first line with its Markdown marker taken off; "New Note" while it's empty.
    public var title: String { NoteMarkdown.title(of: text) }

    /// The lines after the title, joined, for a preview under it.
    public var snippet: String {
        text.split(whereSeparator: \.isNewline).dropFirst()
            .map { NoteMarkdown.stripMarker(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
