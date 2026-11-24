import AppKit
import Combine
import PasteClipCore
import SwiftUI

/// Glass tinted with a note's colour, lit from above like the other panels. The glass stays
/// see-through; the tint is only enough to read as that colour.
struct NoteGlass: View {
    let color: NoteColor
    let cornerRadius: CGFloat
    @ObservedObject var tone: GlowTone
    /// For a window that isn't key (the preview): it draws glass without its tint, so the colour is laid over it.
    var shaded = false

    var body: some View {
        GlassBackground(cornerRadius: cornerRadius, tint: color.glassTint)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.color.opacity(shaded ? 0.30 : 0)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(gradient: TopLight.rim(light: tone.light), startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false))
    }
}

/// A small round icon button of the editor's toolbar.
struct NoteIconButton: View {
    let symbol: String
    var label: String?
    var active = false
    let help: String
    let action: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            Group {
                if let label { Text(label).font(.system(size: 12, weight: .semibold)) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.7))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(hovering.value ? 0.10 : (active ? 0.08 : 0))))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering.value = inside } }
        .help(help)
    }
}

/// The editor of one note: text, a slim toolbar, colours and the actions at the foot.
struct NoteEditorView: View {
    static let cornerRadius: CGFloat = 24
    static let size = NSSize(width: 372, height: 430)
    @ObservedObject var store: NoteStore
    @ObservedObject var settings: AppSettings
    let id: UUID
    let tone: GlowTone
    let proxy: NoteEditorProxy
    let onClose: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    @StateObject private var formatting = ViewState(false)

    var body: some View {
        let note = store.note(id)
        VStack(spacing: 0) {
            header(note)
            NoteTextEditor(text: note?.text ?? "", settings: settings, proxy: proxy,
                           onChange: { store.setText(id, $0) }, onClose: onClose, onPin: onPin)
                .overlay(alignment: .topTrailing) {
                    if formatting.value { FormatBar(proxy: proxy).padding(.trailing, 10).padding(.top, 2).transition(.opacity) }
                }
            footer(note)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(NoteGlass(color: note?.color ?? .yellow, cornerRadius: Self.cornerRadius, tone: tone))
    }

    private func header(_ note: Note?) -> some View {
        HStack(spacing: 2) {
            Text(note?.title ?? "")
                .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Saved").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 4)
            NoteIconButton(symbol: "textformat.size.smaller", help: "Smaller text") {
                settings.notesFontSize = max(AppSettings.notesFontSizes.lowerBound, settings.notesFontSize - 0.5)
            }
            NoteIconButton(symbol: "textformat.size.larger", help: "Larger text") {
                settings.notesFontSize = min(AppSettings.notesFontSizes.upperBound, settings.notesFontSize + 0.5)
            }
            NoteIconButton(symbol: "", label: "Aa", active: formatting.value, help: "Format") {
                withAnimation(.easeOut(duration: 0.15)) { formatting.value.toggle() }
            }
            NoteIconButton(symbol: "checklist", help: "Checklist (⌘T)") { proxy.run(.line(.task)) }
            NoteIconButton(symbol: note?.pinned == true ? "pin.fill" : "pin", active: note?.pinned == true,
                           help: "Keep on screen (⌘P)") { onPin() }
            NoteIconButton(symbol: "magnifyingglass", help: "Find (⌘F)") { proxy.run(.find) }
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 2)
    }

    private func footer(_ note: Note?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                ForEach(NoteColor.allCases) { c in
                    Button { store.setColor(id, c) } label: {
                        Circle().fill(c.color).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(note?.color == c ? 0.75 : 0), lineWidth: 1.5).padding(-3))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).focusable(false).help(c.label)
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            NoteIconButton(symbol: "archivebox", help: "Archive") {
                store.setArchived(id, true)
                onClose()
            }
            NoteIconButton(symbol: "trash", help: "Delete") { onDelete() }
            CapsuleButton(title: "Close", key: "esc", action: onClose)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
    }
}

/// The format menu under the Aa button: glass, with every format and its shortcut in the tooltip.
struct FormatBar: View {
    let proxy: NoteEditorProxy

    private struct Item: Identifiable {
        let id: String
        let label: String?
        let symbol: String?
        let help: String
        let command: NoteCommand
    }

    private let items: [Item] = [
        Item(id: "b", label: "B", symbol: nil, help: "Bold (⌘B)", command: .bold),
        Item(id: "i", label: nil, symbol: "italic", help: "Italic (⌘I)", command: .italic),
        Item(id: "s", label: nil, symbol: "strikethrough", help: "Strikethrough (⇧⌘X)", command: .strike),
        Item(id: "h", label: nil, symbol: "highlighter", help: "Highlight (⇧⌘H)", command: .highlight),
        Item(id: "c", label: nil, symbol: "chevron.left.forwardslash.chevron.right", help: "Code (⌘E)", command: .code),
        Item(id: "h1", label: "H1", symbol: nil, help: "Heading 1 (⌥⌘1)", command: .line(.heading(1))),
        Item(id: "h2", label: "H2", symbol: nil, help: "Heading 2 (⌥⌘2)", command: .line(.heading(2))),
        Item(id: "t", label: nil, symbol: "checklist", help: "Checklist (⌘T)", command: .line(.task)),
        Item(id: "ul", label: nil, symbol: "list.bullet", help: "Bulleted list (⇧⌘L)", command: .line(.bullet)),
        Item(id: "ol", label: nil, symbol: "list.number", help: "Numbered list (⇧⌘N)", command: .line(.numbered)),
        Item(id: "q", label: nil, symbol: "text.quote", help: "Quote (⇧⌘U)", command: .line(.quote)),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                NoteIconButton(symbol: item.symbol ?? "", label: item.label, help: item.help) { proxy.run(item.command) }
            }
        }
        .padding(4)
        .glassCapsule()
    }
}

/// What a note looks like while the pointer is on its tab: its first lines, tasks as boxes, faded
/// at the bottom when there's more. It never takes the mouse.
struct NotePreviewView: View {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 22
    static let maxBodyHeight: CGFloat = 340
    let note: Note
    let tone: GlowTone
    @ObservedObject var settings: AppSettings
    @StateObject private var contentHeight = ViewState<CGFloat>(0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight.value = $0 }
            .frame(maxWidth: .infinity, maxHeight: Self.maxBodyHeight, alignment: .topLeading)
            // Faded at the bottom only when there is more than fits; a short note is shown whole.
            .mask(LinearGradient(stops: [.init(color: .black, location: contentHeight.value > Self.maxBodyHeight ? 0.88 : 1),
                                         .init(color: contentHeight.value > Self.maxBodyHeight ? .clear : .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            Text(note.modified.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: Self.width, alignment: .topLeading)
        .background(NoteGlass(color: note.color, cornerRadius: Self.cornerRadius, tone: tone, shaded: true))
    }

    private var lines: [String] {
        Array(note.text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().prefix(30)).map(String.init)
    }

    /// A line's text with its inline Markdown shown (bold, italic, code, strikethrough) and not its marks.
    private func styled(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        func parsed(_ s: String) -> AttributedString { (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s) }
        // ==highlight== is cut out first, since Markdown has nothing for it, and shown with a yellow ground.
        let parts = text.components(separatedBy: "==")
        guard parts.count >= 3, parts.count % 2 == 1 else { return Text(parsed(text.replacingOccurrences(of: "==", with: ""))) }
        var result = AttributedString()
        for (i, part) in parts.enumerated() {
            var piece = parsed(part)
            if i % 2 == 1 { piece.backgroundColor = Color.yellow.opacity(0.4) }
            result += piece
        }
        return Text(result)
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        let size = CGFloat(settings.notesFontSize) - 1
        let body = NoteMarkdown.stripMarker(line).trimmingCharacters(in: .whitespaces)
        if let ticked = NoteMarkdown.isTicked(line) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ticked ? "checkmark.square.fill" : "square").font(.system(size: size))
                    .foregroundStyle(ticked ? Color.secondary : Color.primary)
                styled(body).strikethrough(ticked).foregroundStyle(ticked ? Color.secondary : Color.primary)
            }.font(.system(size: size))
        } else if case .heading? = NoteMarkdown.style(of: line) {
            styled(body).font(.system(size: size + 1, weight: .semibold))
        } else if NoteMarkdown.style(of: line) == .bullet {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Color.secondary).frame(width: 4, height: 4).offset(y: -1.5)
                styled(body)
            }.font(.system(size: size))
        } else if NoteMarkdown.style(of: line) == .quote {
            HStack(spacing: 7) {
                Capsule().fill(Color.primary.opacity(0.25)).frame(width: 2.5)
                styled(body).foregroundStyle(.secondary)
            }.font(.system(size: size)).fixedSize(horizontal: false, vertical: true)
        } else {
            styled(line).font(.system(size: size))
        }
    }
}
