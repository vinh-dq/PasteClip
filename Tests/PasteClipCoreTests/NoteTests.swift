import Foundation
import Testing
@testable import PasteClipCore

@Test func noteTitleSkipsMarkersAndBlankLines() {
    #expect(NoteMarkdown.title(of: "") == "New Note")
    #expect(NoteMarkdown.title(of: "\n\n# Weekend\n- milk") == "Weekend")
    #expect(NoteMarkdown.title(of: "- [ ] Buy milk") == "Buy milk")
    #expect(NoteMarkdown.title(of: "3. third") == "third")
    #expect(Note(text: "A\n- b\n- c").snippet == "b · c")
}

@Test func tasksToggleBothWays() {
    #expect(NoteMarkdown.togglingTask("- [ ] milk") == "- [x] milk")
    #expect(NoteMarkdown.togglingTask("  - [x] milk") == "  - [ ] milk")
    #expect(NoteMarkdown.togglingTask("milk") == "milk")
    #expect(NoteMarkdown.isTicked("- [X] a") == true)
    #expect(NoteMarkdown.isTicked("- a") == nil)
}

@Test func lineStylesToggleAndReplace() {
    #expect(NoteMarkdown.toggling(.task, on: "milk") == "- [ ] milk")
    #expect(NoteMarkdown.toggling(.task, on: "- [ ] milk") == "milk")
    #expect(NoteMarkdown.toggling(.bullet, on: "- [x] milk") == "- milk")
    #expect(NoteMarkdown.toggling(.heading(2), on: "milk") == "## milk")
    #expect(NoteMarkdown.toggling(.heading(1), on: "## milk") == "# milk")
    #expect(NoteMarkdown.toggling(.quote, on: "> hi") == "hi")
    #expect(NoteMarkdown.toggling(.numbered, on: "  hi") == "  1. hi")
}

@Test func returnContinuesLists() {
    #expect(NoteMarkdown.continuation(afterLine: "- [ ] milk") == .insert("- [ ] "))
    #expect(NoteMarkdown.continuation(afterLine: "- [x] milk") == .insert("- [ ] "))
    #expect(NoteMarkdown.continuation(afterLine: "  - milk") == .insert("  - "))
    #expect(NoteMarkdown.continuation(afterLine: "9. milk") == .insert("10. "))
    #expect(NoteMarkdown.continuation(afterLine: "> milk") == .insert("> "))
    #expect(NoteMarkdown.continuation(afterLine: "- ") == .clear(2))
    #expect(NoteMarkdown.continuation(afterLine: "# Title") == .none)
    #expect(NoteMarkdown.continuation(afterLine: "plain") == .none)
}

@Test func wrapsAndUnwrapsSelection() {
    let wrapped = NoteMarkdown.wrapping("hello world", range: NSRange(location: 0, length: 5), with: "**")
    #expect(wrapped.text == "**hello** world")
    #expect(wrapped.selection == NSRange(location: 2, length: 5))
    let back = NoteMarkdown.wrapping(wrapped.text, range: wrapped.selection, with: "**")
    #expect(back.text == "hello world")
    #expect(back.selection == NSRange(location: 0, length: 5))
    #expect(NoteMarkdown.wrapping("ab", range: NSRange(location: 1, length: 0), with: "`").text == "a``b")
}

@Test func noteStoreKeepsOrderAndSurvivesRestart() {
    let dir = Scratch.folder()
    let store = NoteStore(directory: dir)
    let a = store.add(text: "first")
    let b = store.add(text: "second")
    let c = store.add(text: "third")
    // A new note goes first; editing doesn't reorder.
    store.setText(a.id, "first, edited")
    #expect(store.active.map(\.id) == [c.id, b.id, a.id])
    store.move(a.id, toActiveIndex: 0)
    #expect(store.active.map(\.id) == [a.id, c.id, b.id])
    store.move(a.id, toActiveIndex: 99)
    #expect(store.active.map(\.id) == [c.id, b.id, a.id])
    store.setPinned(b.id, true)
    #expect(store.active.map(\.id) == [c.id, b.id, a.id])
    store.setArchived(b.id, true)
    #expect(store.archived.first?.pinned == false)
    store.flush()

    let again = NoteStore(directory: dir)
    #expect(again.notes.count == 3)
    #expect(again.active.map(\.id) == [c.id, a.id])
    #expect(again.note(a.id)?.text == "first, edited")
    #expect(again.archived.count == 1)
}

@Test func noteStoreDeleteUndoAndEmpty() {
    let store = NoteStore(directory: Scratch.folder())
    let a = store.add(text: "keep")
    let blank = store.add()
    store.removeEmpty()
    #expect(store.note(blank.id) == nil)
    let gone = store.delete(a.id)
    #expect(store.notes.isEmpty)
    store.restore(gone!)
    #expect(store.note(a.id)?.text == "keep")
}

@Test func noteStoreImportSkipsKnown() {
    let store = NoteStore(directory: Scratch.folder())
    store.add(text: "one")
    let data = store.exportData()!
    #expect(store.importData(data) == 0)
    let other = NoteStore(directory: Scratch.folder())
    #expect(other.importData(data) == 1)
    #expect(other.notes.first?.text == "one")
}

@Test func unreadableNotesFileIsKeptAside() throws {
    let dir = Scratch.folder()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("notes.json"))
    let store = NoteStore(directory: dir)
    #expect(store.notes.isEmpty)
    store.add(text: "new")
    store.flush()
    let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("notes-unreadable-") }
    #expect(kept.count == 1)
    #expect(try String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8) == "not json")
}

@Test func welcomeNotesGoInOrderWithTitles() {
    let store = NoteStore(directory: Scratch.folder())
    store.addWelcomeNotes()
    #expect(store.active.count == NoteStore.welcome.count)
    #expect(store.active.first?.title == "Welcome to Notes")
    #expect(store.active.map(\.title).allSatisfy { $0 != "New Note" && $0.count < 28 })
}

@Test func noteLineBlockBringsItsSubItems() {
    let lines = ["- a", "  - a1", "  - a2", "- b", "plain"]
    #expect(NoteMarkdown.block(in: lines, at: 0) == 0..<3)
    #expect(NoteMarkdown.block(in: lines, at: 1) == 1..<2)
    #expect(NoteMarkdown.block(in: lines, at: 4) == 4..<5)
}

@Test func noteMovingABlockKeepsEveryLine() {
    let lines = ["- a", "  - a1", "- b", "- c"]
    #expect(NoteMarkdown.moving(0..<2, toSlot: 4, in: lines) == ["- b", "- c", "- a", "  - a1"])
    #expect(NoteMarkdown.moving(3..<4, toSlot: 0, in: lines) == ["- c", "- a", "  - a1", "- b"])
    #expect(NoteMarkdown.moving(2..<3, toSlot: 2, in: lines) == nil)
    #expect(NoteMarkdown.moving(2..<3, toSlot: 3, in: lines) == nil)
}
