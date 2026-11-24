import AppKit
import PasteClipCore
import SwiftUI

/// One entry of the menu that opens when `/` is typed at the start of an empty line.
struct SlashItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let hint: String
    let command: NoteCommand
    /// Other words that find it.
    let keywords: String

    static let all: [SlashItem] = [
        SlashItem(id: "title", title: "Title", symbol: "textformat.size.larger", hint: "⌥⌘1", command: .line(.heading(1)), keywords: "h1 heading big"),
        SlashItem(id: "heading", title: "Heading", symbol: "textformat.size", hint: "⌥⌘2", command: .line(.heading(2)), keywords: "h2"),
        SlashItem(id: "sub", title: "Subheading", symbol: "textformat.size.smaller", hint: "⌥⌘3", command: .line(.heading(3)), keywords: "h3"),
        SlashItem(id: "task", title: "Checklist", symbol: "checklist", hint: "⌘T", command: .line(.task), keywords: "todo task check"),
        SlashItem(id: "bullet", title: "Bulleted list", symbol: "list.bullet", hint: "⇧⌘L", command: .line(.bullet), keywords: "ul dots"),
        SlashItem(id: "number", title: "Numbered list", symbol: "list.number", hint: "⇧⌘N", command: .line(.numbered), keywords: "ol ordered"),
        SlashItem(id: "quote", title: "Quote", symbol: "text.quote", hint: "⇧⌘U", command: .line(.quote), keywords: "blockquote"),
        SlashItem(id: "highlight", title: "Highlight", symbol: "highlighter", hint: "⇧⌘H", command: .highlight, keywords: "mark marker"),
        SlashItem(id: "code", title: "Code", symbol: "chevron.left.forwardslash.chevron.right", hint: "⌘E", command: .code, keywords: "mono"),
    ]

    static func matching(_ query: String) -> [SlashItem] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.keywords.contains(q) }
    }
}

final class SlashModel: ObservableObject {
    @Published var items: [SlashItem] = []
    @Published var index = 0
    /// The most height the menu may take; longer lists scroll.
    @Published var maxHeight: CGFloat = .greatestFiniteMagnitude

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        index = (index + step + items.count) % items.count
    }
}

/// The slash menu: a small glass list under the caret. Keys are handled by the text view, which
/// keeps the keyboard; the pointer can pick too.
struct SlashMenuView: View {
    static let width: CGFloat = 232
    @ObservedObject var model: SlashModel
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { rows }.scrollIndicators(.never)
                .onChange(of: model.index) { _, new in proxy.scrollTo(new, anchor: nil) }
        }
        .frame(maxHeight: min(CGFloat(model.items.count) * 29 + 10, model.maxHeight))
        .padding(5)
        .frame(width: Self.width)
        .background(GlassBackground(cornerRadius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 9) {
                    Image(systemName: item.symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(.secondary)
                    Text(item.title).font(.system(size: 13))
                    Spacer(minLength: 8)
                    Text(item.hint).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(index == model.index ? 0.22 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { onPick(index) }
                .onHover { if $0 { model.index = index } }
                .id(index)
            }
        }
    }
}
