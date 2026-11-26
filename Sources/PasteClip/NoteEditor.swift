import AppKit
import PasteClipCore
import SwiftUI

/// Six dots in the margin beside a line: its handle for dragging. Never takes the mouse itself.
private final class GripView: NSView {
    var hot = false { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if hot {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        NSColor.secondaryLabelColor.withAlphaComponent(hot ? 0.95 : 0.6).setFill()
        for col in [-1.0, 1.0] {
            for row in [-1.0, 0.0, 1.0] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + col * 2.6 - 1.05, y: bounds.midY + row * 4.2 - 1.05, width: 2.1, height: 2.1)).fill()
            }
        }
    }
}

/// What the toolbar and the shortcuts ask the text of a note to do.
enum NoteCommand {
    case bold, italic, strike, code, highlight
    case line(NoteLineStyle)
    case find
}

/// The text of a note. Styles Markdown as it's typed, continues lists with Return, indents them
/// with Tab, ticks a task when its box is clicked, and takes the formatting shortcuts itself:
/// PasteClip stays in the background while its panels take keys, so no menu gets them.
final class NoteTextView: NSTextView {
    var onClose: () -> Void = {}
    var onPin: () -> Void = {}
    var settings: AppSettings?
    private var boxTracking: NSTrackingArea?
    private var arrowShown = false
    /// The line the pointer is on and whether it is on that line's grip; the grip shows only there.
    private var hoverLine: Int?
    private var overGrip = false
    private var isReordering = false
    private let gripView = GripView()

    override func cancelOperation(_ sender: Any?) {
        if slashStart != nil { closeSlash() } else { onClose() }
    }

    // MARK: Slash menu, selection bar, hint

    weak var proxy: NoteEditorProxy?
    private let slashModel = SlashModel()
    private var slashHost: NSHostingView<SlashMenuView>?
    private var slashStart: Int?
    private var selectionHost: NSHostingView<FormatBar>?

    private func lineIsEmpty(at location: Int) -> Bool {
        let ns = string as NSString
        let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        return range.length == 0 || (range.length == 1 && ns.character(at: range.location) == 10)
    }

    /// `/` at the start of an empty line opens the menu; what's typed after it filters the menu.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let caret = selectedRange()
        let onEmptyLine = caret.length == 0 && lineIsEmpty(at: caret.location)
        super.insertText(string, replacementRange: replacementRange)
        if (string as? String) == "/", onEmptyLine, settings?.notesMarkdown != false {
            slashStart = caret.location
            slashModel.index = 0
            updateSlash()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        updateSlash()
        hideSelectionBar()
        needsDisplay = true
    }

    private func updateSlash() {
        guard let start = slashStart else { return }
        let ns = string as NSString
        let selection = selectedRange()
        guard selection.length == 0, selection.location > start, ns.length > start, ns.character(at: start) == 47 else { return closeSlash() }
        let query = ns.substring(with: NSRange(location: start + 1, length: selection.location - start - 1))
        guard !query.contains(where: { $0.isWhitespace }) else { return closeSlash() }
        let items = SlashItem.matching(query)
        guard !items.isEmpty else { return closeSlash() }
        slashModel.items = items
        slashModel.index = min(slashModel.index, items.count - 1)
        guard let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let host = slashHost ?? {
            let h = NSHostingView(rootView: SlashMenuView(model: slashModel, onPick: { [weak self] in self?.applySlash($0) }))
            addSubview(h)
            slashHost = h
            return h
        }()
        slashModel.maxHeight = .greatestFiniteMagnitude
        host.layoutSubtreeIfNeeded()
        let natural = host.fittingSize
        // Below the line if it fits, else above it, else on the side with more room, shorter and scrolling.
        let below = visibleRect.maxY - (rect.maxY + 6) - 6
        let above = rect.minY - 6 - visibleRect.minY - 6
        let placeBelow = below >= natural.height || (above < natural.height && below >= above)
        let room = max(84, placeBelow ? below : above)
        slashModel.maxHeight = room
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: natural.width, height: min(natural.height, room))
        let y = placeBelow ? rect.maxY + 6 : rect.minY - size.height - 6
        host.frame = NSRect(x: min(rect.minX, bounds.width - size.width - 8), y: y, width: size.width, height: size.height)
    }

    private func closeSlash() {
        slashStart = nil
        slashHost?.removeFromSuperview()
        slashHost = nil
    }

    /// Takes the `/` and what was typed after it off the line, then applies the chosen format.
    private func applySlash(_ index: Int) {
        guard let start = slashStart, slashModel.items.indices.contains(index) else { return }
        let command = slashModel.items[index].command
        let range = NSRange(location: start, length: selectedRange().location - start)
        closeSlash()
        if shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: start, length: 0))
        }
        perform(command)
    }

    /// A small bar of formats above the selected text.
    private func updateSelectionBar(stillSelecting: Bool) {
        let selection = selectedRange()
        guard !stillSelecting, selection.length > 0, slashStart == nil, settings?.notesMarkdown != false,
              let proxy, let layout = layoutManager, let container = textContainer else { return hideSelectionBar() }
        let glyphs = layout.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let host = selectionHost ?? {
            let h = NSHostingView(rootView: FormatBar(proxy: proxy))
            addSubview(h)
            selectionHost = h
            return h
        }()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        var y = rect.minY - size.height - 6
        if y < visibleRect.minY + 2 { y = rect.maxY + 6 }
        let x = min(max(rect.midX - size.width / 2, 6), max(6, bounds.width - size.width - 6))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func hideSelectionBar() {
        selectionHost?.removeFromSuperview()
        selectionHost = nil
    }

    /// Tab and ⇧Tab indent and outdent a list item; the window would otherwise take ⇧Tab to move focus.
    override func keyDown(with event: NSEvent) {
        if slashStart != nil {
            switch event.keyCode {
            case 125: return slashModel.move(1)
            case 126: return slashModel.move(-1)
            case 36, 76, 48: return applySlash(slashModel.index)
            default: break
            }
        }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if event.modifierFlags.contains(.shift) { insertBacktab(nil) } else { insertTab(nil) }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: List markers

    /// A list line's marker is drawn as a box, a dot or a bar over the space the styler left for it.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHint()
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y),
                                                                            in: container), actualGlyphRange: nil)
        let size = CGFloat(settings?.notesFontSize ?? 13.5)
        let font = settings?.notesBodyFont ?? NSFont.systemFont(ofSize: size)
        storage.enumerateAttribute(NoteMarker.key, in: visible) { value, range, _ in
            guard let raw = value as? Int, let kind = NoteMarker(rawValue: raw) else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let level = CGFloat((storage.string as NSString).substring(with: range).prefix { $0 == " " }.count / 2)
            let left = box.minX + origin.x + level * NoteStyler.indentUnit(fontSize: size)
            let fontHeight = ceil(font.ascender - font.descender + font.leading)
            let midY = line.minY + origin.y + fontHeight / 2
            switch kind {
            case .task, .taskDone:
                let side = size * 0.95
                let rect = NSRect(x: left, y: midY - side / 2, width: side, height: side)
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), xRadius: side * 0.28, yRadius: side * 0.28)
                if kind == .taskDone {
                    NSColor.controlAccentColor.setFill()
                    path.fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: rect.minX + side * 0.27, y: rect.midY))
                    tick.line(to: NSPoint(x: rect.minX + side * 0.44, y: rect.midY + side * 0.17 * (isFlipped ? 1 : -1)))
                    tick.line(to: NSPoint(x: rect.minX + side * 0.74, y: rect.midY - side * 0.2 * (isFlipped ? 1 : -1)))
                    tick.lineWidth = 1.6
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    tick.stroke()
                } else {
                    NSColor.secondaryLabelColor.setStroke()
                    path.lineWidth = 1.3
                    path.stroke()
                }
            case .bullet:
                let d = size * 0.3
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: left + size * 0.18, y: midY - d / 2, width: d, height: d)).fill()
            case .quote:
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: left, y: line.minY + origin.y, width: 2.5, height: line.height),
                             xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    /// A faint hint on the empty line the caret is on.
    private func drawHint() {
        guard window?.firstResponder === self, selectedRange().length == 0, slashStart == nil, lineIsEmpty(at: selectedRange().location),
              let layout = layoutManager, let container = textContainer else { return }
        let ns = string as NSString
        let location = selectedRange().location
        var rect: NSRect
        if location >= ns.length {
            rect = layout.extraLineFragmentRect
            if rect == .zero, ns.length == 0 { rect = NSRect(x: 0, y: 0, width: 10, height: (settings?.notesBodyFont.pointSize ?? 13.5) * 1.3) }
        } else {
            rect = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
        }
        guard rect != .zero else { return }
        let font = settings?.notesBodyFont ?? NSFont.systemFont(ofSize: 13.5)
        NSString(string: "Type / for formats").draw(
            at: NSPoint(x: rect.minX + textContainerOrigin.x + container.lineFragmentPadding + 1, y: rect.minY + textContainerOrigin.y),
            withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    /// The length of a task, bullet or quote marker (and its line's start) when `location` is inside it.
    private func hiddenMarker(at location: Int) -> (start: Int, end: Int)? {
        let ns = string as NSString
        guard location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        switch NoteMarkdown.style(of: line) {
        case .task?, .bullet?, .quote?:
            return (lineRange.location, lineRange.location + NoteMarkdown.markerLength(of: line))
        default: return nil
        }
    }

    /// The caret never rests inside a marker that isn't shown: it steps over it.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if ranges.count == 1, settings?.notesMarkdown != false {
            let r = ranges[0].rangeValue
            if r.length == 0, let m = hiddenMarker(at: r.location), r.location > m.start, r.location < m.end {
                let goingBack = r.location < selectedRange().location
                ranges[0] = NSValue(range: NSRange(location: goingBack ? m.start : m.end, length: 0))
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        if slashStart != nil { updateSlash() }
        updateSelectionBar(stillSelecting: stillSelecting)
    }

    /// Backspace right after a list marker takes the marker off the line.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, settings?.notesMarkdown != false, let m = hiddenMarker(at: caret.location), caret.location == m.end, m.end > m.start {
            let r = NSRange(location: m.start, length: m.end - m.start)
            if shouldChangeText(in: r, replacementString: "") {
                textStorage?.replaceCharacters(in: r, with: "")
                didChangeText()
            }
            return
        }
        super.deleteBackward(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditCommands.perform(event) { return true }
        let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard f.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let command: NoteCommand?
        switch (key, f) {
        case ("b", [.command]): command = .bold
        case ("i", [.command]): command = .italic
        case ("e", [.command]): command = .code
        case ("x", [.command, .shift]): command = .strike
        case ("h", [.command, .shift]): command = .highlight
        case ("t", [.command]): command = .line(.task)
        case ("l", [.command, .shift]): command = .line(.bullet)
        case ("n", [.command, .shift]): command = .line(.numbered)
        case ("u", [.command, .shift]): command = .line(.quote)
        case ("f", [.command]): command = .find
        case ("1", [.command, .option]): command = .line(.heading(1))
        case ("2", [.command, .option]): command = .line(.heading(2))
        case ("3", [.command, .option]): command = .line(.heading(3))
        case ("p", [.command]): onPin(); return true
        case ("w", [.command]): onClose(); return true
        default: command = nil
        }
        if let command { perform(command); return true }
        return super.performKeyEquivalent(with: event)
    }

    func perform(_ command: NoteCommand) {
        window?.makeFirstResponder(self)
        switch command {
        case .bold: wrap("**")
        case .italic: wrap("*")
        case .strike: wrap("~~")
        case .code: wrap("`")
        case .highlight: wrap("==")
        case .line(let style): toggleLines(style)
        case .find:
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
        }
    }

    private func wrap(_ marker: String) {
        let result = NoteMarkdown.wrapping(string, range: selectedRange(), with: marker)
        replaceAll(with: result.text, selecting: result.selection)
    }

    /// Replaces the whole text in one undoable step (a note is short) and selects `selection`.
    private func replaceAll(with text: String, selecting selection: NSRange) {
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: whole, with: text)
        didChangeText()
        setSelectedRange(selection)
    }

    private func toggleLines(_ style: NoteLineStyle) {
        let ns = string as NSString
        let lines = ns.paragraphRange(for: selectedRange())
        var out: [String] = []
        ns.enumerateSubstrings(in: lines, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            out.append(ns.substring(with: r))
        }
        if out.isEmpty { out = [""] }
        let ends = ns.length >= lines.location + lines.length && lines.length > 0
            && ns.substring(with: NSRange(location: lines.location + lines.length - 1, length: 1)) == "\n"
        let changed = out.map { NoteMarkdown.toggling(style, on: $0) }.joined(separator: "\n") + (ends ? "\n" : "")
        guard shouldChangeText(in: lines, replacementString: changed) else { return }
        textStorage?.replaceCharacters(in: lines, with: changed)
        didChangeText()
        setSelectedRange(NSRange(location: lines.location + (changed as NSString).length - (ends ? 1 : 0), length: 0))
    }

    private func currentLine() -> (text: String, range: NSRange)? {
        let ns = string as NSString
        let caret = selectedRange()
        guard caret.length == 0 else { return nil }
        let range = ns.lineRange(for: NSRange(location: caret.location, length: 0))
        var line = ns.substring(with: range)
        if line.hasSuffix("\n") { line.removeLast() }
        return (line, range)
    }

    override func insertNewline(_ sender: Any?) {
        guard settings?.notesMarkdown != false, let (line, range) = currentLine(),
              selectedRange().location == range.location + (line as NSString).length else { return super.insertNewline(sender) }
        switch NoteMarkdown.continuation(afterLine: line) {
        case .none: super.insertNewline(sender)
        case .insert(let marker): insertText("\n" + marker, replacementRange: selectedRange())
        case .clear(let length):
            let r = NSRange(location: range.location, length: length)
            if shouldChangeText(in: r, replacementString: "") {
                textStorage?.replaceCharacters(in: r, with: "")
                didChangeText()
            }
        }
    }

    /// Tab and ⇧Tab move the lines holding the selection two spaces in or out, on any line: a list
    /// item, a paragraph, a heading.
    private func shiftIndent(outdent: Bool) {
        let ns = string as NSString
        let selection = selectedRange()
        let lines = ns.lineRange(for: selection)
        let block = ns.substring(with: lines)
        let endsWithBreak = block.hasSuffix("\n")
        var rows = block.components(separatedBy: "\n")
        if endsWithBreak { rows.removeLast() }
        if rows.isEmpty { rows = [""] }
        func moved(_ row: String) -> String {
            guard outdent else { return "  " + row }
            if row.hasPrefix("\t") { return String(row.dropFirst()) }
            if row.hasPrefix("  ") { return String(row.dropFirst(2)) }
            if row.hasPrefix(" ") { return String(row.dropFirst()) }
            return row
        }
        let changed = rows.map(moved)
        let text = changed.joined(separator: "\n") + (endsWithBreak ? "\n" : "")
        guard text != block, shouldChangeText(in: lines, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: lines, with: text)
        didChangeText()
        if selection.length == 0 {
            let delta = (changed[0] as NSString).length - (rows[0] as NSString).length
            setSelectedRange(NSRange(location: max(lines.location, selection.location + delta), length: 0))
        } else {
            setSelectedRange(NSRange(location: lines.location, length: (text as NSString).length - (endsWithBreak ? 1 : 0)))
        }
    }

    override func insertTab(_ sender: Any?) { shiftIndent(outdent: false) }
    override func insertBacktab(_ sender: Any?) { shiftIndent(outdent: true) }

    /// The line (without its break) whose drawn task box is under `point`. Only the box itself counts:
    /// a click on the empty rest of a task line must put the caret there, not tick it.
    private func taskBox(at point: NSPoint) -> NSRange? {
        guard settings?.notesMarkdown != false, let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let ns = string as NSString
        guard index < ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        guard NoteMarkdown.isTicked(line) != nil else { return nil }
        let size = CGFloat(settings?.notesFontSize ?? 13.5)
        let level = CGFloat(line.prefix { $0 == " " }.count / 2)
        let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
        let fragment = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let left = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
            + level * NoteStyler.indentUnit(fontSize: size)
        let hit = NSRect(x: left - 2, y: fragment.minY, width: size * 0.95 + 6, height: fragment.height)
        guard hit.contains(local) else { return nil }
        return NSRange(location: lineRange.location, length: (line as NSString).length)
    }

    /// The pointer is an arrow over a task's box (it clicks like a button) and an open hand over a grip or
    /// a bullet (it drags). True when it took the event: the text view's own handling would put the
    /// text bar back on every move.
    private func showsBoxCursor(for event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        if taskBox(at: point) != nil {
            NSCursor.arrow.set()
            arrowShown = true
            return true
        }
        if overGrip || bulletLine(at: point) != nil {
            NSCursor.openHand.set()
            arrowShown = true
            return true
        }
        if arrowShown {
            arrowShown = false
            NSCursor.iBeam.set()
        }
        return false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let boxTracking { removeTrackingArea(boxTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        boxTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        if !showsBoxCursor(for: event) { super.mouseMoved(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(nil, grip: false)
    }

    override func cursorUpdate(with event: NSEvent) {
        if !showsBoxCursor(for: event) { super.cursorUpdate(with: event) }
    }

    // MARK: Reordering lines

    /// How far the pointer must travel before a press on a handle is a drag rather than a click.
    private static let dragSlop: CGFloat = 4

    private struct Lines {
        let text: [String]
        let starts: [Int]
    }

    private func splitLines() -> Lines {
        let text = string.components(separatedBy: "\n")
        var starts: [Int] = []
        var at = 0
        for line in text {
            starts.append(at)
            at += (line as NSString).length + 1
        }
        return Lines(text: text, starts: starts)
    }

    /// The area the line occupies, in this view's coordinates (all its wrapped rows).
    private func lineRect(_ k: Int, _ lines: Lines) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let ns = string as NSString
        let loc = lines.starts[k]
        let len = (lines.text[k] as NSString).length
        var rect: NSRect
        if len == 0 {
            if loc >= ns.length {
                rect = layout.extraLineFragmentRect
                if rect == .zero { return nil }
            } else {
                rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: loc), effectiveRange: nil)
            }
        } else {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: loc, length: len), actualCharacterRange: nil)
            rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The first row of the line, which is where its grip and marker sit.
    private func firstRow(_ k: Int, _ lines: Lines) -> NSRect? {
        guard let layout = layoutManager, lines.starts[k] < (string as NSString).length else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: lines.starts[k])
        return layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The line under `y`, when it has something to move.
    private func lineIndex(atY y: CGFloat, _ lines: Lines) -> Int? {
        for k in lines.text.indices where !lines.text[k].isEmpty {
            if let r = lineRect(k, lines), y >= r.minY, y < r.maxY { return k }
        }
        return nil
    }

    private func gripRect(_ k: Int, _ lines: Lines) -> NSRect? {
        guard let row = firstRow(k, lines) else { return nil }
        let size = CGFloat(settings?.notesFontSize ?? 13.5)
        let fontHeight = ceil((settings?.notesBodyFont ?? NSFont.systemFont(ofSize: size)).boundingRectForFont.height)
        let midY = row.minY + min(row.height, max(fontHeight, row.height - 3)) / 2
        return NSRect(x: textContainerOrigin.x - 25, y: midY - 11, width: 20, height: 22)
    }

    private func updateHover(at point: NSPoint) {
        guard !isReordering else { return }
        let lines = splitLines()
        let k = lineIndex(atY: point.y, lines)
        setHover(k, grip: k.flatMap { gripRect($0, lines) }?.insetBy(dx: -3, dy: 0).contains(point) ?? false)
    }

    private func setHover(_ line: Int?, grip: Bool) {
        guard line != hoverLine || grip != overGrip else { return }
        hoverLine = line
        overGrip = grip
        placeGrip()
    }

    /// Shows the grip in the left margin of the line the pointer is on. It is a view of its own because
    /// the text view clips its drawing to the text area, which leaves the margin out.
    private func placeGrip() {
        let lines = splitLines()
        guard !isReordering, let k = hoverLine, k < lines.text.count, window?.firstResponder === self,
              let rect = gripRect(k, lines) else { gripView.isHidden = true; return }
        if gripView.superview == nil { addSubview(gripView) }
        gripView.frame = rect
        gripView.hot = overGrip
        gripView.isHidden = false
    }

    /// The line whose bullet is under `point` (a bullet drags like a grip; a task box also ticks, see `taskBox`).
    private func bulletLine(at point: NSPoint) -> Int? {
        guard settings?.notesMarkdown != false else { return nil }
        let lines = splitLines()
        guard let k = lineIndex(atY: point.y, lines), NoteMarkdown.style(of: lines.text[k]) == .bullet,
              let row = firstRow(k, lines), let layout = layoutManager, let container = textContainer else { return nil }
        let size = CGFloat(settings?.notesFontSize ?? 13.5)
        let level = CGFloat(lines.text[k].prefix { $0 == " " }.count / 2)
        let glyph = layout.glyphIndexForCharacter(at: lines.starts[k])
        let left = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
            + textContainerOrigin.x + level * NoteStyler.indentUnit(fontSize: size)
        return NSRect(x: left - 2, y: row.minY, width: size * 0.95 + 6, height: row.height).contains(point) ? k : nil
    }

    /// The line a press at `point` would pick up: its grip in the margin, its bullet or its task box.
    private func handleLine(at point: NSPoint) -> Int? {
        let lines = splitLines()
        if let k = lineIndex(atY: point.y, lines), let g = gripRect(k, lines), g.insetBy(dx: -3, dy: 0).contains(point) { return k }
        if let k = bulletLine(at: point) { return k }
        if let r = taskBox(at: point) { return lines.starts.lastIndex { $0 <= r.location } }
        return nil
    }

    /// Holds the press on a handle: a short press is a click (it ticks a task box), a longer one lifts the
    /// line and its sub-items as a glass chip and drops them where the accent bar is when the button goes up.
    private func trackHandle(line: Int, event: NSEvent) {
        let lines = splitLines()
        let block = NoteMarkdown.block(in: lines.text, at: line)
        guard let first = lineRect(block.lowerBound, lines), let last = lineRect(block.upperBound - 1, lines) else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let wasBox = taskBox(at: origin)
        let area = NSRect(x: 4, y: first.minY - 1, width: bounds.width - 8, height: last.maxY - first.minY + 2)
        var chip: NSView?
        var bar: NSView?
        var slot: Int?
        var cancelled = false
        defer { chip?.removeFromSuperview(); bar?.removeFromSuperview(); isReordering = false; NSCursor.arrow.set() }

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseUp { break }
            if next.type == .keyDown {
                if next.keyCode == 53 { cancelled = true; break }
                continue
            }
            let now = convert(next.locationInWindow, from: nil)
            if chip == nil {
                guard hypot(now.x - origin.x, now.y - origin.y) >= Self.dragSlop else { continue }
                isReordering = true
                gripView.isHidden = true
                displayIfNeeded()
                chip = makeChip(of: area)
                bar = makeBar()
                addSubview(bar!)
                addSubview(chip!)
            }
            autoscroll(with: next)
            NSCursor.closedHand.set()
            let point = convert(next.locationInWindow, from: nil)
            let top = min(max(area.minY + point.y - origin.y, textContainerOrigin.y - 4), bounds.height - area.height)
            chip?.frame.origin.y = top
            // The nearest gap between lines to the chip's middle.
            let mid = top + area.height / 2
            var target = lines.text.count
            for k in lines.text.indices where !block.contains(k) {
                if let r = lineRect(k, lines), mid < r.midY { target = k; break }
            }
            slot = NoteMarkdown.moving(block, toSlot: target, in: lines.text) == nil ? nil : target
            if let slot, let bar {
                let y = slot < lines.text.count ? (lineRect(slot, lines)?.minY ?? 0) - 1 : (lineRect(slot - 1, lines)?.maxY ?? 0) + 1
                bar.isHidden = false
                bar.frame = NSRect(x: textContainerOrigin.x - 6, y: y - 1.25, width: bounds.width - textContainerOrigin.x - 8, height: 2.5)
            } else {
                bar?.isHidden = true
            }
        }

        if chip == nil, !cancelled {
            // A click: a task's box ticks, anywhere else puts the caret on the line.
            if let r = wasBox {
                let toggled = NoteMarkdown.togglingTask((string as NSString).substring(with: r))
                if shouldChangeText(in: r, replacementString: toggled) {
                    textStorage?.replaceCharacters(in: r, with: toggled)
                    didChangeText()
                }
            } else {
                setSelectedRange(NSRange(location: lines.starts[line] + (lines.text[line] as NSString).length, length: 0))
            }
            return
        }
        guard !cancelled, let slot, let moved = NoteMarkdown.moving(block, toSlot: slot, in: lines.text) else { return }
        let newFirst = slot > block.upperBound ? slot - block.count : slot
        let caret = moved.prefix(newFirst).reduce(0) { $0 + ($1 as NSString).length + 1 } + (moved[newFirst] as NSString).length
        replaceAll(with: moved.joined(separator: "\n"), selecting: NSRange(location: caret, length: 0))
    }

    /// The lifted line: a picture of its rows on a see-through card with a soft shadow.
    private func makeChip(of area: NSRect) -> NSView {
        let view = NSView(frame: area)
        view.wantsLayer = true
        if let rep = bitmapImageRepForCachingDisplay(in: area) {
            cacheDisplay(in: area, to: rep)
            view.layer?.contents = rep.cgImage
        }
        view.layer?.contentsGravity = .resize
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.22
        view.layer?.shadowRadius = 12
        view.layer?.shadowOffset = CGSize(width: 0, height: -5)
        return view
    }

    /// The accent bar that shows where the line will land.
    private func makeBar() -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.layer?.cornerRadius = 1.25
        view.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        view.layer?.shadowOpacity = 0.45
        view.layer?.shadowRadius = 3
        view.layer?.shadowOffset = .zero
        view.isHidden = true
        return view
    }

    /// A press on a grip, a bullet or a task's box picks the line up; a click on a box still ticks it.
    override func mouseDown(with event: NSEvent) {
        closeSlash()
        hideSelectionBar()
        // ⌘-click opens a link; a plain click only puts the caret in it, so a link can be edited.
        if event.modifierFlags.contains(.command), let layout = layoutManager, let container = textContainer, let storage = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            var fraction: CGFloat = 0
            let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            if index < storage.length, let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let k = handleLine(at: convert(event.locationInWindow, from: nil)) {
            trackHandle(line: k, event: event)
            return
        }
        super.mouseDown(with: event)
    }
}

/// Lets the toolbar reach the text view of the editor next to it.
final class NoteEditorProxy {
    weak var textView: NoteTextView?
    func run(_ command: NoteCommand) { textView?.perform(command) }
}

struct NoteTextEditor: NSViewRepresentable {
    let text: String
    let settings: AppSettings
    let proxy: NoteEditorProxy
    let onChange: (String) -> Void
    let onClose: () -> Void
    let onPin: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NoteTextView(frame: .zero)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 26, height: 8)
        view.insertionPointColor = .controlAccentColor
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        view.settings = settings
        view.proxy = proxy
        view.onClose = onClose
        view.onPin = onPin
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        context.coordinator.view = view
        proxy.textView = view
        view.string = text
        context.coordinator.restyleAll()
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        // Take the keyboard once the panel (which becomes key for editing) is on screen.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        guard let view = c.view else { return }
        view.onClose = onClose
        view.onPin = onPin
        // A change of font or Markdown styling in Settings.
        let key = "\(settings.notesFont.rawValue)|\(settings.notesFontSize)|\(settings.notesMarkdown)"
        if key != c.styleKey { c.styleKey = key; c.restyleAll() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(settings: settings, onChange: onChange) }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        weak var view: NoteTextView?
        let settings: AppSettings
        var onChange: (String) -> Void
        var styleKey = ""
        var lastSelection = NSRange(location: 0, length: 0)

        init(settings: AppSettings, onChange: @escaping (String) -> Void) {
            self.settings = settings
            self.onChange = onChange
        }

        func restyleAll() {
            guard let storage = view?.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            if whole.length == 0 { storage.endEditing(); return }
            NoteStyler.apply(to: storage, range: whole, settings: settings, active: view?.selectedRange() ?? NSRange(location: 0, length: 0))
            storage.endEditing()
            view?.typingAttributes = [.font: settings.notesBodyFont, .foregroundColor: NSColor.labelColor]
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing actions: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard actions.contains(.editedCharacters) else { return }
            NoteStyler.apply(to: storage, range: range, settings: settings, active: view?.selectedRange() ?? range)
        }

        /// Moving the caret to another line shows that line's markers and hides the old one's.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view, let storage = view.textStorage, storage.length > 0 else { return }
            let ns = storage.string as NSString
            let now = view.selectedRange()
            let old = lastSelection
            lastSelection = now
            func lines(_ r: NSRange) -> NSRange {
                let loc = min(r.location, ns.length)
                return ns.lineRange(for: NSRange(location: loc, length: min(r.length, ns.length - loc)))
            }
            let a = lines(old), b = lines(now)
            guard a != b else { return }
            storage.beginEditing()
            for r in [a, b] where r.location < ns.length { NoteStyler.apply(to: storage, range: r, settings: settings, active: now) }
            storage.endEditing()
            view.typingAttributes = [.font: settings.notesBodyFont, .foregroundColor: NSColor.labelColor]
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            // New text typed after a styled span shouldn't carry its style.
            view.typingAttributes = [.font: settings.notesBodyFont, .foregroundColor: NSColor.labelColor]
            onChange(view.string)
        }
    }
}
