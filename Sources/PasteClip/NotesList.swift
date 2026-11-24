import AppKit
import PasteClipCore
import SwiftUI

final class NotesListModel: ObservableObject {
    enum Scope: String { case all = "All Notes", archived = "Archived" }
    @Published var scope = Scope.all
    @Published var query = ""
}

/// All notes, or the archived ones: a glass list with search. Click a note to open it.
struct NotesListView: View {
    static let size = NSSize(width: 400, height: 480)
    static let cornerRadius: CGFloat = 24
    @ObservedObject var store: NoteStore
    @ObservedObject var model: NotesListModel
    let tone: GlowTone
    let onOpen: (Note) -> Void
    let onNew: () -> Void
    let onDelete: (Note) -> Void
    let onClose: () -> Void

    private var shown: [Note] {
        let list = model.scope == .all ? store.active : store.archived
        let q = model.query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach([NotesListModel.Scope.all, .archived], id: \.self) { scope in
                    Button { withAnimation(.easeOut(duration: 0.12)) { model.scope = scope } } label: {
                        Text(scope.rawValue).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 28)
                            .glassCapsule(selected: model.scope == scope)
                    }
                    .buttonStyle(.plain).focusable(false)
                }
                Spacer()
                if model.scope == .all { CapsuleButton(title: "New", symbol: "plus", key: nil, action: onNew) }
                CapsuleButton(title: "Close", key: "esc", action: onClose)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search notes", text: $model.query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.07)))

            let notes = shown
            if notes.isEmpty {
                Text(model.query.isEmpty ? (model.scope == .all ? "No notes yet." : "Nothing archived.") : "No match.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(notes) { note in
                            NoteRow(note: note, archived: model.scope == .archived,
                                    onOpen: { onOpen(note) },
                                    onToggleArchive: { store.setArchived(note.id, model.scope == .all) },
                                    onDelete: { onDelete(note) })
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(NoteGlassPlain(cornerRadius: Self.cornerRadius, tone: tone))
    }
}

/// Untinted glass with the top-lit rim, for windows that aren't one note.
struct NoteGlassPlain: View {
    let cornerRadius: CGFloat
    @ObservedObject var tone: GlowTone
    var body: some View {
        GlassBackground(cornerRadius: cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(gradient: TopLight.rim(light: tone.light), startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false))
    }
}

private struct NoteRow: View {
    let note: Note
    let archived: Bool
    let onOpen: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(note.color.color).frame(width: 5, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Text(note.snippet.isEmpty ? note.modified.formatted(.relative(presentation: .named)) : note.snippet)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering.value {
                NoteIconButton(symbol: archived ? "tray.and.arrow.up" : "archivebox", help: archived ? "Unarchive" : "Archive",
                               action: onToggleArchive)
                NoteIconButton(symbol: "trash", help: "Delete", action: onDelete)
            } else {
                Text(note.modified.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering.value ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering.value = $0 }
    }
}

/// "Note deleted · Undo": a small glass capsule that goes by itself.
struct NotesToastView: View {
    static let height: CGFloat = 40
    let message: String
    let undo: () -> Void
    let tone: GlowTone

    var body: some View {
        HStack(spacing: 10) {
            Text(message).font(.system(size: 12.5, weight: .medium))
            CapsuleButton(title: "Undo", key: "⌘Z", action: undo)
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(height: Self.height)
        .background(NoteGlassPlain(cornerRadius: Self.height / 2, tone: tone))
    }
}
