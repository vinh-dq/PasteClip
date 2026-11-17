import AppKit
import Foundation
import Testing
@testable import PasteClipCore

/// Each test gets its own history folder and a private pasteboard, so the user's
/// real clipboard and history are never touched.
private func makeStore() -> (ClipStore, NSPasteboard, URL) {
    let dir = Scratch.folder()
    let pasteboard = Scratch.pasteboard()
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

private func linked(_ label: String, to url: String) -> NSAttributedString {
    let text = NSMutableAttributedString(string: "Read \(label) now")
    text.addAttribute(.link, value: URL(string: url)!, range: NSRange(location: 5, length: label.count))
    text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 4))
    return text
}

private func hasLink(_ data: Data?, to url: String) -> Bool {
    guard let data, let text = NSAttributedString(rtf: data, documentAttributes: nil) else { return false }
    var found = false
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if (value as? URL)?.absoluteString == url || value as? String == url { found = true }
    }
    return found
}

@Test func pastesFormattingAsBothRTFAndHTML() throws {
    let (store, pb, _) = makeStore()
    let rtf = try #require(ClipStore.rtf(of: linked("docs", to: "https://swift.org/")))
    pb.clearContents()
    pb.setString("Read docs now", forType: .string)
    pb.setData(rtf, forType: .rtf)
    store.poll()

    store.copyToPasteboard(try #require(store.items.first))
    #expect(pb.data(forType: .rtf) == rtf)
    let html = String(decoding: try #require(pb.data(forType: .html)), as: UTF8.self)
    #expect(html.contains("href=\"https://swift.org/\""))
}

@Test func keepsFormattingFromRTFDAndFormattedOnlyCopies() throws {
    let (store, pb, _) = makeStore()
    let text = linked("notes", to: "https://example.com/")
    let rtfd = try #require(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
    pb.clearContents()
    pb.setString(text.string, forType: .string)
    pb.setData(rtfd, forType: .rtfd)
    store.poll()
    let fromRTFD = try #require(store.items.first)
    #expect(fromRTFD.richType == "rtf")
    #expect(hasLink(store.richData(for: fromRTFD)?.0, to: "https://example.com/"))

    // No plain text on the pasteboard at all: the text is read from the formatting.
    pb.clearContents()
    pb.setData(ClipStore.rtf(of: linked("site", to: "https://swift.org/")), forType: .rtf)
    store.poll()
    let formattedOnly = try #require(store.items.first)
    #expect(formattedOnly.text == "Read site now")
    #expect(formattedOnly.richType == "rtf")
}

@Test func linkClipsKeepTheirFormatting() throws {
    let (store, pb, _) = makeStore()
    pb.clearContents()
    pb.setString("https://swift.org", forType: .string)
    pb.setData(Data("<a href=\"https://swift.org\">https://swift.org</a>".utf8), forType: .html)
    store.poll()
    let item = try #require(store.items.first)
    #expect(item.kind == .link)
    #expect(item.richType == "html")
}

@Test func editingFormattedTextKeepsFormattingAndBoard() throws {
    let (store, pb, _) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 0)
    pb.clearContents()
    pb.setString("hello", forType: .string)
    pb.setData(Data("<b>hello</b>".utf8), forType: .html)
    store.poll()
    let item = try #require(store.items.first)
    store.setPinboard(item, board)
    let oldURL = try #require(store.richURL(for: item))

    store.updateText(item, linked("guide", to: "https://swift.org/"))
    let edited = try #require(store.item(withID: item.id))
    #expect(edited.text == "Read guide now")
    #expect(edited.richType == "rtf")
    #expect(edited.pinboardID == board.id)
    #expect(hasLink(store.richData(for: edited)?.0, to: "https://swift.org/"))
    #expect(!FileManager.default.fileExists(atPath: oldURL.path))

    // Changing only the formatting writes a new file, so cached previews update.
    store.updateText(edited, NSAttributedString(string: "Read guide now"))
    #expect(store.item(withID: item.id)?.richFile != edited.richFile)
}

@Test func keepsAppSpecificFormatsAndRestoresThem() throws {
    let (store, pb, _) = makeStore()
    let custom = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
    let blob = Data("mentions".utf8)
    pb.clearContents()
    pb.declareTypes([.string, custom], owner: nil)
    pb.setString("@team please review", forType: .string)
    pb.setData(blob, forType: custom)
    store.poll()
    let item = try #require(store.items.first)
    #expect(item.hasFormatting)
    #expect(item.richFile == nil)

    store.copyToPasteboard(item)
    #expect(pb.data(forType: custom) == blob)
    #expect(pb.string(forType: .string) == "@team please review")

    store.copyToPasteboard(item, plainText: true)
    #expect(pb.data(forType: custom) == nil)

    // Copying the same text plainly keeps the formats; editing the text drops them.
    pb.clearContents()
    pb.setString("@team please review", forType: .string)
    store.poll()
    #expect(store.items.first?.pasteboardFile == item.pasteboardFile)
    store.updateText(item, "@team please check")
    #expect(store.item(withID: item.id)?.hasFormatting == false)
}

@Test func plainAndRTFOnlyCopiesStoreNoExtraFormats() throws {
    let (store, pb, _) = makeStore()
    pb.clearContents()
    pb.setString("plain", forType: .string)
    pb.setData(ClipStore.rtf(of: NSAttributedString(string: "plain")), forType: .rtf)
    store.poll()
    #expect(store.items.first?.pasteboardFile == nil)
}

private let slackDelta = #"{"ops":[{"attributes":{"slackmention":{"id":"U1","label":"@An"}},"insert":"@An"},"#
    + #"{"insert":" please "},{"attributes":{"bold":true},"insert":"review"},{"insert":" the "},"#
    + #"{"attributes":{"link":"https://swift.org/"},"insert":"doc"},{"insert":"\n"}]}"#

private func slackCustomData(_ delta: String, plain: String) -> Data {
    ChromiumCustomData.encode([("public.utf8-plain-text", plain), ("slack/texty", delta)])
}

private func ops(in contents: [[String: Data]]?) throws -> [[String: Any]] {
    let data = try #require(contents?.first?["org.chromium.web-custom-data"])
    let delta = try #require(ChromiumCustomData.decode(data)?.first { $0.key == "slack/texty" }?.value)
    let root = try #require(try JSONSerialization.jsonObject(with: Data(delta.utf8)) as? [String: Any])
    return try #require(root["ops"] as? [[String: Any]])
}

@Test func chromiumCustomDataRoundTrips() throws {
    let data = slackCustomData(slackDelta, plain: "@An please review the doc\n")
    let pairs = try #require(ChromiumCustomData.decode(data))
    #expect(pairs.map(\.key) == ["public.utf8-plain-text", "slack/texty"])
    #expect(ChromiumCustomData.encode(pairs) == data)
}

@Test func editingSlackTextKeepsMentionsBoldAndLinks() throws {
    let (store, pb, _) = makeStore()
    let custom = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
    pb.clearContents()
    pb.declareTypes([.string, custom], owner: nil)
    pb.setString("@An please review the doc\n", forType: .string)
    pb.setData(slackCustomData(slackDelta, plain: "@An please review the doc\n"), forType: custom)
    store.poll()
    let item = try #require(store.items.first)
    // Kept as RTF too, for apps other than Slack.
    #expect(item.richType == "rtf")

    let shown = try #require(store.formattedText(for: item))
    #expect(shown.string == "@An please review the doc\n")
    #expect(shown.attribute(.slackMention, at: 0, effectiveRange: nil) != nil)

    // Change "review" to "check", as the editor would.
    let edited = NSMutableAttributedString(attributedString: shown)
    let range = (edited.string as NSString).range(of: "review")
    edited.replaceCharacters(in: range, with: "check")
    edited.insert(NSAttributedString(string: "!"), at: 3)
    store.updateText(item, edited)

    let saved = try #require(store.item(withID: item.id))
    #expect(saved.text == "@An! please check the doc\n")
    let newOps = try ops(in: store.pasteboardContents(for: saved))
    let mention = try #require(newOps.first)
    #expect(mention["insert"] as? String == "@An")
    #expect((mention["attributes"] as? [String: Any])?["slackmention"] != nil)
    #expect(newOps.contains { $0["insert"] as? String == "check" && ($0["attributes"] as? [String: Any])?["bold"] as? Bool == true })
    #expect(newOps.contains { ($0["attributes"] as? [String: Any])?["link"] as? String == "https://swift.org/" })
    #expect(!newOps.contains { ($0["insert"] as? String)?.hasPrefix("!") == true && $0["attributes"] != nil })
    #expect(hasLink(store.richData(for: saved)?.0, to: "https://swift.org/"))

    store.copyToPasteboard(saved)
    #expect(pb.string(forType: .string) == "@An! please check the doc\n")
    #expect(pb.data(forType: custom) != nil)
    #expect(pb.data(forType: .html) != nil)
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

@Test func reordersClipsOnAPinboard() {
    let (store, _, dir) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 0)
    for text in ["a", "b", "c"] {
        store.insert(ClipItem(kind: .text, text: text))
        store.setPinboard(store.items[0], board)
    }
    var query = ClipQuery()
    query.pinboardID = board.id
    func texts(_ store: ClipStore) -> [String?] { query.apply(store.items).map(\.text) }
    #expect(texts(store) == ["c", "b", "a"])

    store.moveClip(store.items.first { $0.text == "a" }!.id, to: store.items.first { $0.text == "c" }!.id)
    #expect(texts(store) == ["a", "c", "b"])
    store.moveClip(store.items.first { $0.text == "a" }!.id, to: store.items.first { $0.text == "b" }!.id)
    #expect(texts(store) == ["c", "b", "a"])

    // A clip added later goes to the front, and the order survives a relaunch.
    store.insert(ClipItem(kind: .text, text: "d"))
    store.setPinboard(store.items[0], board)
    #expect(texts(store) == ["d", "c", "b", "a"])
    store.flush()
    #expect(texts(ClipStore(directory: dir, pasteboard: NSPasteboard(name: .init(UUID().uuidString)))) == ["d", "c", "b", "a"])
    // History is still newest first.
    #expect(ClipQuery().apply(store.items).map(\.text) == ["d", "c", "b", "a"])
}

@Test func reordersPinboards() {
    let (store, _, _) = makeStore()
    let a = store.createPinboard(name: "A", colorIndex: 0)
    store.createPinboard(name: "B", colorIndex: 1)
    let c = store.createPinboard(name: "C", colorIndex: 2)
    store.movePinboard(c.id, to: 0)
    #expect(store.pinboards.map(\.name) == ["C", "A", "B"])
    store.movePinboard(c.id, to: 2)
    #expect(store.pinboards.map(\.name) == ["A", "B", "C"])
    store.movePinboard(a.id, to: 1)
    #expect(store.pinboards.map(\.name) == ["B", "A", "C"])
    // New pinboards go at the end; a synced one lands by its order.
    store.createPinboard(name: "D", colorIndex: 3)
    var remote = store.pinboards[0]
    remote.order = 10
    store.applyRemote(remote)
    #expect(store.pinboards.map(\.name) == ["A", "C", "D", "B"])
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

@Test func pinboardClipsOutliveRetention() {
    let (store, _, _) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 1)
    var old = ClipItem(kind: .text, text: "old on board")
    old.date = Date().addingTimeInterval(-30 * 86_400)
    store.insert(old)
    store.setPinboard(store.items[0], board)
    var stale = ClipItem(kind: .text, text: "old")
    stale.date = old.date
    store.insert(stale)

    store.retentionDays = 1
    store.insert(ClipItem(kind: .text, text: "new"))
    #expect(store.items.map(\.text) == ["new", "old on board"])
}

@Test func pinboardClipsDontCountTowardTheLimit() {
    let (store, _, dir) = makeStore()
    let board = store.createPinboard(name: "Work", colorIndex: 1)
    for text in ["a", "b", "c"] {
        store.insert(ClipItem(kind: .text, text: text))
        store.setPinboard(store.items[0], board)
    }
    store.historyLimit = 2
    for text in ["1", "2", "3"] { store.insert(ClipItem(kind: .text, text: text)) }

    let kept = { (s: ClipStore) in Set(s.items.compactMap(\.text)) }
    #expect(kept(store) == ["a", "b", "c", "2", "3"])

    // Still there after a restart with a tighter limit.
    store.flush()
    let reopened = ClipStore(directory: dir, pasteboard: Scratch.pasteboard())
    reopened.historyLimit = 1
    #expect(kept(reopened) == ["a", "b", "c", "3"])
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
    let defaults = Scratch.defaults()
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
    let settings = AppSettings(defaults: Scratch.defaults())
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

@Test func severalClipsPasteTogetherInTheirOrder() {
    let (store, pb, _) = makeStore()
    for text in ["one", "two", "three"] {
        pb.clearContents()
        pb.setString(text, forType: .string)
        store.poll()
    }
    // Newest first: three, two, one.
    let picked = [store.items[2], store.items[0]]
    store.copyToPasteboard(picked)
    #expect(pb.string(forType: .string) == "one\nthree")
    #expect(store.items.map(\.text) == ["one", "three", "two"])
    store.poll()
    #expect(store.items.count == 3)

    // Images can't join text, so each clip goes as its own pasteboard item; as plain text they join.
    var image = ClipItem(kind: .image)
    image.ocrText = "text in image"
    store.copyToPasteboard([store.items[0], image], plainText: true)
    #expect(pb.string(forType: .string) == "one\ntext in image")
}

@Test func severalClipsAreDeletedAtOnce() {
    let (store, pb, _) = makeStore()
    for text in ["a", "b", "c", "d"] {
        pb.clearContents()
        pb.setString(text, forType: .string)
        store.poll()
    }
    store.addToStack(store.items[0])
    var deleted: [SyncRecord] = []
    store.onLocalChange = { _, gone in deleted += gone }
    store.delete([store.items[0], store.items[2]])
    #expect(store.items.map(\.text) == ["c", "a"])
    #expect(store.stack.isEmpty)
    #expect(deleted.count == 2)
}
