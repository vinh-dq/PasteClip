import Foundation

/// Notes, kept in `notes.json` beside the clipboard history. Plain text on this Mac, not encrypted.
public final class NoteStore: ObservableObject {
    @Published public private(set) var notes: [Note] = []
    public let directory: URL
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "PasteClip.NoteStore.io", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    public init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("notes.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL) {
            if let loaded = try? JSONDecoder().decode([Note].self, from: data) {
                notes = loaded
            } else {
                // A file that can't be read (a newer format, damage) is kept aside, not written over by the next save.
                let stamp = Int(Date().timeIntervalSince1970)
                try? FileManager.default.copyItem(at: fileURL, to: directory.appendingPathComponent("notes-unreadable-\(stamp).json"))
            }
        }
    }

    // MARK: - Reading

    /// In the order the user arranged them (a new note goes first).
    public var active: [Note] { notes.filter { !$0.archived } }
    /// The most recently edited first.
    public var archived: [Note] { notes.filter(\.archived).sorted { $0.modified > $1.modified } }

    public func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    // MARK: - Changing

    @discardableResult
    public func add(text: String = "", color: NoteColor? = nil) -> Note {
        let note = Note(text: text, color: color ?? NoteColor.rotation[notes.count % NoteColor.rotation.count])
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    private func change(_ id: UUID, touch: Bool = true, _ edit: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        edit(&notes[i])
        if touch { notes[i].modified = Date() }
        scheduleSave()
    }

    public func setText(_ id: UUID, _ text: String) {
        guard note(id)?.text != text else { return }
        change(id) { $0.text = text }
    }
    public func setColor(_ id: UUID, _ color: NoteColor) { change(id, touch: false) { $0.color = color } }
    public func setPinned(_ id: UUID, _ pinned: Bool) { change(id, touch: false) { $0.pinned = pinned } }
    public func setArchived(_ id: UUID, _ archived: Bool) {
        change(id, touch: false) { $0.archived = archived; if archived { $0.pinned = false } }
    }

    /// Puts a note at `index` among the ones that aren't archived.
    public func move(_ id: UUID, toActiveIndex index: Int) {
        var live = active
        guard let from = live.firstIndex(where: { $0.id == id }) else { return }
        let note = live.remove(at: from)
        live.insert(note, at: max(0, min(index, live.count)))
        guard live != active else { return }
        notes = live + notes.filter(\.archived)
        scheduleSave()
    }

    /// Removes a note and returns it, so the caller can offer Undo.
    @discardableResult
    public func delete(_ id: UUID) -> Note? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let note = notes.remove(at: i)
        scheduleSave()
        return note
    }

    public func restore(_ note: Note) {
        guard self.note(note.id) == nil else { return }
        notes.insert(note, at: 0)
        scheduleSave()
    }

    /// Drops notes that are still empty (a new note closed without typing), except `keep`.
    public func removeEmpty(except keep: Set<UUID> = []) {
        let before = notes.count
        notes.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !keep.contains($0.id) }
        if notes.count != before { scheduleSave() }
    }

    // MARK: - First launch

    /// The notes a new user starts with: how the bar, the formats and the shortcuts work. Plain
    /// notes like any other, so they can be edited or deleted.
    public static let welcome: [(text: String, color: NoteColor)] = [
        ("""
        # Welcome to Notes
        A slim bar sits on the right edge of your screen.

        - Rest the pointer on it and it opens into your notes
        - Point at one to peek, click it to write
        - Drag a tab up or down to put them in order
        - Press ⌥⌘N for a new note from anywhere

        Delete these notes whenever you like.
        """, .yellow),
        ("""
        # Type / for formats
        On an empty line, type / to turn it into a title, checklist, list, quote, highlight or code.

        Select some text to get a bar of formats above it.

        ==Highlight==, **bold**, *italic*, ~~strike~~ and `code` all work. The marks fade away once you move to another line.
        """, .blue),
        ("""
        # Checklist
        - [ ] Click a box to tick it
        - [ ] Press ⌘T on any line to make it a task
        - [x] Press Return to add the next one
          - [ ] Tab indents an item, ⇧Tab outdents it
        - [ ] Press Return on an empty task to end the list
        """, .green),
        ("""
        # Keys worth knowing
        - ⌥⌘N new note, ⌥⌘A all notes, ⌥⌘L archived notes
        - ⌘P keeps a note on screen above other windows
        - ⌘F finds in a note, Esc closes it, ⌘-click opens a link
        - ⌥⌘1–3 headings, ⇧⌘L bullets, ⇧⌘N numbers
        - Change the global shortcuts in Settings → Shortcuts
        """, .purple),
        ("""
        # Save a clip as a note
        In the shelf, right-click a text clip and choose Save as Note.

        Notes are kept in a file on this Mac. Settings → Notes changes the edge, the font, and exports them.
        """, .orange),
    ]

    /// Adds the welcome notes, first one on top.
    public func addWelcomeNotes() {
        for entry in Self.welcome.reversed() { add(text: entry.text, color: entry.color) }
    }

    // MARK: - Import and export

    /// All notes as JSON, for Export.
    public func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(notes)
    }

    /// Adds the notes in an exported file that aren't here yet; returns how many.
    @discardableResult
    public func importData(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let incoming = (try? decoder.decode([Note].self, from: data)) ?? (try? JSONDecoder().decode([Note].self, from: data))
        else { return 0 }
        let known = Set(notes.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        notes.append(contentsOf: fresh)
        if !fresh.isEmpty { scheduleSave() }
        return fresh.count
    }

    // MARK: - Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes now (at quit).
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        write(sync: true)
    }

    private func write(sync: Bool = false) {
        let snapshot = notes
        let url = fileURL
        let job = {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        if sync { ioQueue.sync(execute: job) } else { ioQueue.async(execute: job) }
    }
}
