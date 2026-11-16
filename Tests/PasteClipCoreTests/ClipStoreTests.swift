import AppKit
import Foundation
import Testing
@testable import PasteClipCore

/// Each test gets its own history folder and a private pasteboard, so the user's
/// real clipboard and history are never touched.
private func makeStore() -> (ClipStore, NSPasteboard, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteClipTests-\(UUID().uuidString)", isDirectory: true)
    let pasteboard = NSPasteboard(name: .init("PasteClipTests-\(UUID().uuidString)"))
    return (ClipStore(directory: dir, pasteboard: pasteboard), pasteboard, dir)
}

@Test func detectsLinks() {
    #expect(ClipKind.isLink("https://example.com/a?b=1"))
    #expect(ClipKind.isLink("  http://example.com  "))
    #expect(!ClipKind.isLink("example.com"))
    #expect(!ClipKind.isLink("see https://example.com"))
    #expect(!ClipKind.isLink("ftp://example.com"))
}

@Test func capturesTextAndLinksFromPasteboard() {
    let (store, pb, _) = makeStore()
    pb.clearContents()
    pb.setString("hello", forType: .string)
    store.poll()
    pb.clearContents()
    pb.setString("https://swift.org", forType: .string)
    store.poll()

    #expect(store.items.map(\.kind) == [.link, .text])
    #expect(store.items.map(\.text) == ["https://swift.org", "hello"])
}

@Test func ignoresConcealedAndUnchangedPasteboard() {
    let (store, pb, _) = makeStore()
    pb.clearContents()
    pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
    pb.setString("secret", forType: .string)
    store.poll()
    #expect(store.items.isEmpty)

    pb.clearContents()
    pb.setString("visible", forType: .string)
    store.poll()
    store.poll() // same changeCount: no duplicate
    #expect(store.items.count == 1)
}

@Test func skipsCaptureWhilePaused() {
    let (store, pb, _) = makeStore()
    store.paused = true
    pb.clearContents()
    pb.setString("hello", forType: .string)
    store.poll()
    #expect(store.items.isEmpty)
}

@Test func deduplicatesAndKeepsPin() {
    let (store, _, _) = makeStore()
    store.insert(ClipItem(kind: .text, text: "a"))
    store.togglePin(store.items[0])
    store.insert(ClipItem(kind: .text, text: "b"))
    store.insert(ClipItem(kind: .text, text: "a"))

    #expect(store.items.map(\.text) == ["a", "b"])
    #expect(store.items[0].pinned)
}

@Test func trimsUnpinnedOnly() {
    let (store, _, _) = makeStore()
    store.historyLimit = 2
    store.insert(ClipItem(kind: .text, text: "pinned"))
    store.togglePin(store.items[0])
    for t in ["1", "2", "3"] { store.insert(ClipItem(kind: .text, text: t)) }

    #expect(store.items.map(\.text) == ["3", "2", "pinned"])
}

@Test func clearHistoryKeepsPinned() {
    let (store, _, _) = makeStore()
    store.insert(ClipItem(kind: .text, text: "keep"))
    store.togglePin(store.items[0])
    store.insert(ClipItem(kind: .text, text: "drop"))
    store.clearHistory()

    #expect(store.items.map(\.text) == ["keep"])
}

@Test func copyBackMovesToTopWithoutRecapturing() {
    let (store, pb, _) = makeStore()
    store.insert(ClipItem(kind: .text, text: "old"))
    store.insert(ClipItem(kind: .text, text: "new"))
    store.copyToPasteboard(store.items[1])
    store.poll()

    #expect(pb.string(forType: .string) == "old")
    #expect(store.items.map(\.text) == ["old", "new"])
}

@Test func persistsHistoryAcrossLaunches() {
    let (store, pb, dir) = makeStore()
    store.insert(ClipItem(kind: .link, text: "https://swift.org"))
    store.togglePin(store.items[0])
    store.flush()

    let reloaded = ClipStore(directory: dir, pasteboard: pb)
    #expect(reloaded.items.count == 1)
    #expect(reloaded.items[0].kind == .link)
    #expect(reloaded.items[0].pinned)
}

// MARK: - Kinds and rich text

@Test func detectsColors() {
    #expect(ClipKind.detect("#FF8800") == .color)
    #expect(ClipKind.detect("#f80") == .color)
    #expect(ClipKind.detect("#11223344") == .color)
    #expect(ClipKind.detect("FF8800") == .text)
    #expect(ClipKind.detect("#GG0000") == .text)
    #expect(RGBA(hex: "#f80") == RGBA(hex: "#FF8800"))
    #expect(RGBA(hex: "#FF000080")?.a == 128.0 / 255)
}

@Test func keepsAndRestoresRichText() throws {
    let (store, pb, _) = makeStore()
    let rtf = try NSAttributedString(string: "bold").data(
        from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    pb.clearContents()
    pb.setString("bold", forType: .string)
    pb.setData(rtf, forType: .rtf)
    store.poll()

    let item = try #require(store.items.first)
    #expect(item.richType == "rtf")
    #expect(store.richData(for: item)?.0 == rtf)

    store.copyToPasteboard(item)
    #expect(pb.data(forType: .rtf) == rtf)
    store.copyToPasteboard(item, plainText: true)
    #expect(pb.data(forType: .rtf) == nil)
    #expect(pb.string(forType: .string) == "bold")
}

@Test func editingTextDropsFormattingAndRedetectsKind() throws {
    let (store, pb, _) = makeStore()
    pb.clearContents()
    pb.setString("hello", forType: .string)
    pb.setData(Data("<b>hello</b>".utf8), forType: .html)
    store.poll()
    let item = try #require(store.items.first)
    let richURL = try #require(store.richURL(for: item))

    store.updateText(item, "https://swift.org")
    store.setTitle(item, "  Swift  ")
    let edited = try #require(store.item(withID: item.id))
    #expect(edited.kind == .link)
    #expect(edited.richFile == nil)
    #expect(edited.title == "Swift")
    #expect(!FileManager.default.fileExists(atPath: richURL.path))
}

// MARK: - Pinboards

@Test func pinboardClipsSurviveTrimAndClear() {
    let (store, _, _) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 2)
    store.insert(ClipItem(kind: .text, text: "keep"))
    store.setPinboard(store.items[0], board)
    store.historyLimit = 1
    store.insert(ClipItem(kind: .text, text: "1"))
    store.insert(ClipItem(kind: .text, text: "2"))
    #expect(store.items.map(\.text) == ["2", "keep"])

    store.clearHistory()
    #expect(store.items.map(\.text) == ["keep"])
}

@Test func deletingPinboardKeepsItsClips() {
    let (store, _, _) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 0)
    store.insert(ClipItem(kind: .text, text: "a"))
    store.setPinboard(store.items[0], board)
    store.deletePinboard(board)

    #expect(store.pinboards.isEmpty)
    #expect(store.items.first?.pinboardID == nil)
}

@Test func duplicateKeepsIdentityTitleAndBoard() {
    let (store, _, _) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 0)
    store.insert(ClipItem(kind: .text, text: "a"))
    let id = store.items[0].id
    store.setTitle(store.items[0], "Greeting")
    store.setPinboard(store.items[0], board)
    store.insert(ClipItem(kind: .text, text: "b"))
    store.insert(ClipItem(kind: .text, text: "a"))

    #expect(store.items[0].id == id)
    #expect(store.items[0].title == "Greeting")
    #expect(store.items[0].pinboardID == board.id)
}

@Test func persistsPinboards() {
    let (store, pb, dir) = makeStore()
    store.createPinboard(name: "Snippets", colorIndex: 5)
    store.flush()
    let reloaded = ClipStore(directory: dir, pasteboard: pb)
    #expect(reloaded.pinboards.map(\.name) == ["Snippets"])
}

// MARK: - Retention

@Test func dropsClipsOlderThanRetention() {
    let (store, _, _) = makeStore()
    var old = ClipItem(kind: .text, text: "old")
    old.date = Date().addingTimeInterval(-3 * 86_400)
    store.insert(old)
    var oldPinned = ClipItem(kind: .text, text: "old pinned")
    oldPinned.date = old.date
    oldPinned.pinned = true
    store.insert(oldPinned)
    store.insert(ClipItem(kind: .text, text: "new"))

    store.retentionDays = 1
    #expect(store.items.map(\.text) == ["new", "old pinned"])
}

// MARK: - Paste stack

@Test func stackCollectsInCopyOrderAndPopsOldestFirst() {
    let (store, pb, _) = makeStore()
    store.stackMode = true
    for t in ["one", "two", "three"] {
        pb.clearContents()
        pb.setString(t, forType: .string)
        store.poll()
    }
    #expect(store.stackItems.map(\.text) == ["one", "two", "three"])
    #expect(store.popStack()?.text == "one")
    #expect(store.popStack()?.text == "two")
    #expect(store.stack.count == 1)

    store.stackMode = false
    #expect(store.stack.isEmpty)
    #expect(store.popStack() == nil)
}

@Test func stackSkipsDeletedClips() {
    let (store, _, _) = makeStore()
    store.insert(ClipItem(kind: .text, text: "a"))
    store.insert(ClipItem(kind: .text, text: "b"))
    store.addToStack(store.items[1])
    store.addToStack(store.items[0])
    store.delete(store.items[1])
    #expect(store.popStack()?.text == "b")
}

// MARK: - Sync hooks

@Test func reportsLocalChangesButNotRemoteOnes() {
    let (store, _, _) = makeStore()
    var saved: [SyncRecord] = []
    var deleted: [SyncRecord] = []
    store.onLocalChange = { saved += $0; deleted += $1 }

    store.insert(ClipItem(kind: .text, text: "a"))
    let id = store.items[0].id
    store.delete(store.items[0])
    #expect(saved == [.clip(id)])
    #expect(deleted == [.clip(id)])

    saved = []
    var remote = ClipItem(kind: .text, text: "from another Mac")
    remote.date = Date().addingTimeInterval(-60)
    store.applyRemote(remote, imageSource: nil, richSource: nil)
    store.applyRemote(Pinboard(name: "Shared", colorIndex: 1))
    #expect(saved.isEmpty)
    #expect(store.items.map(\.text) == ["from another Mac"])
    #expect(store.pinboards.count == 1)

    store.removeRemoteClip(remote.id)
    #expect(store.items.isEmpty)
    #expect(deleted == [.clip(id)])
}

@Test func remoteClipsAreOrderedByDate() {
    let (store, _, _) = makeStore()
    store.insert(ClipItem(kind: .text, text: "now"))
    var older = ClipItem(kind: .text, text: "older")
    older.date = Date().addingTimeInterval(-3600)
    store.applyRemote(older, imageSource: nil, richSource: nil)
    #expect(store.items.map(\.text) == ["now", "older"])
}

// MARK: - Query

@Test func queryMatchesAllWordsAcrossFields() {
    var item = ClipItem(kind: .text, text: "Café meeting notes", sourceName: "Notes")
    item.title = "Agenda"
    var q = ClipQuery()
    q.text = "cafe agenda"
    #expect(q.matches(item))
    q.text = "cafe budget"
    #expect(!q.matches(item))
    q.text = "notes"
    #expect(q.matches(item))
}

@Test func queryFiltersByTypeAppDateAndBoard() {
    let board = UUID()
    var a = ClipItem(kind: .link, text: "https://a.com", sourceBundleID: "com.apple.Safari")
    a.pinboardID = board
    var b = ClipItem(kind: .text, text: "b", sourceBundleID: "com.apple.Notes")
    b.date = Date().addingTimeInterval(-10 * 86_400)

    var q = ClipQuery()
    q.type = .link
    #expect(q.apply([a, b]).map(\.id) == [a.id])
    q = ClipQuery()
    q.sourceBundleID = "com.apple.Notes"
    #expect(q.apply([a, b]).map(\.id) == [b.id])
    q = ClipQuery()
    q.dateRange = .week
    #expect(q.apply([a, b]).map(\.id) == [a.id])
    q = ClipQuery()
    q.pinboardID = board
    #expect(q.apply([a, b]).map(\.id) == [a.id])
}

@Test func settingsKeepClearedShortcutsCleared() {
    let defaults = UserDefaults(suiteName: "PasteClipTests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.shelfHotKey == .openShelf)
    settings.shelfHotKey = nil
    settings.historyLimit = 1000
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.shelfHotKey == nil)
    #expect(reloaded.historyLimit == 1000)
    #expect(KeyCombo.openShelf.display == "⇧⌘V")
}

// MARK: - Settings page helpers

@Test func retentionStepsSnapToNearest() {
    #expect(RetentionStep(days: 0) == .forever)
    #expect(RetentionStep(days: 1) == .day)
    #expect(RetentionStep(days: 10) == .week)
    #expect(RetentionStep(days: 90) == .month)
    #expect(RetentionStep(days: 300) == .year)
}

@Test func resetShortcutsRestoresDefaults() {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "PasteClipTests-\(UUID().uuidString)")!)
    settings.shelfHotKey = nil
    settings.nextPinboardKey = nil
    settings.quickPasteModifier = .option
    settings.resetShortcuts()
    #expect(settings.shelfHotKey == .openShelf)
    #expect(settings.nextPinboardKey == .nextPinboard)
    #expect(settings.quickPasteModifier == .command)
}

@Test func addsTypedTextClips() {
    let (store, _, _) = makeStore()
    #expect(store.addText("   ") == nil)
    let item = store.addText("#00FF00", title: "Green")
    #expect(item?.kind == .color)
    #expect(store.items.first?.title == "Green")
}

@Test func transientAndConcealedSkippingCanBeTurnedOff() {
    let (store, pb, _) = makeStore()
    pb.clearContents()
    pb.declareTypes([.string, .init("org.nspasteboard.TransientType")], owner: nil)
    pb.setString("temp", forType: .string)
    store.poll()
    #expect(store.items.isEmpty)

    store.skipTransient = false
    pb.clearContents()
    pb.declareTypes([.string, .init("org.nspasteboard.AutoGeneratedType")], owner: nil)
    pb.setString("generated", forType: .string)
    store.poll()
    #expect(store.items.map(\.text) == ["generated"])

    store.skipConcealed = false
    pb.clearContents()
    pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
    pb.setString("secret", forType: .string)
    store.poll()
    #expect(store.items.first?.text == "secret")
}
