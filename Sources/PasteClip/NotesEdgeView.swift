import AppKit
import PasteClipCore
import SwiftUI

/// State of one edge bar that its view and its window both follow.
final class EdgeModel: ObservableObject {
    @Published var open = false
    /// The tab the pointer is on.
    @Published var hovered: UUID?
    /// The note being edited from this bar, whose tab stays lit.
    @Published var current: UUID?
    /// A note that was just added: its tab is lit for a moment.
    @Published var flashed: UUID?
    /// A tab being dragged to a new place, how far it has been moved and which place it is over.
    @Published var dragID: UUID?
    @Published var dragOffset: CGFloat = 0
    @Published var dragTarget = 0
}

/// The bar on a screen edge. At rest it is a slim dark strip with a thin coloured pill per note.
/// With the pointer on it, the pills widen into titled tabs. Every row keeps its place while it
/// opens (only the width changes), and the window never changes size, so nothing jumps.
struct NotesEdgeView: View {
    static let railWidth: CGFloat = 16
    static let pillWidth: CGFloat = 6
    static let rowHeight: CGFloat = 30
    static let rowGap: CGFloat = 6
    static let pitch: CGFloat = rowHeight + rowGap
    static let padding: CGFloat = 8
    static let tabWidth: CGFloat = 164
    static let tabHotWidth: CGFloat = 178
    static let openWidth: CGFloat = 196
    /// Room under the tabs for the new-note button.
    static let footer: CGFloat = 46
    /// Tabs shown before the list scrolls.
    static let maxTabs = 8

    /// Height of the strip, and of the column of tabs, for `count` notes.
    static func columnHeight(count: Int) -> CGFloat {
        let rows = CGFloat(max(1, min(count, maxTabs)))
        return rows * rowHeight + (rows - 1) * rowGap + padding * 2
    }

    @ObservedObject var store: NoteStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: EdgeModel
    let onHover: (Bool) -> Void
    let onTabHover: (Note?) -> Void
    let onOpen: (Note) -> Void
    let onNew: () -> Void
    let onMove: (UUID, Int) -> Void
    let onPin: (UUID) -> Void
    let onColor: (UUID, NoteColor) -> Void
    let onArchive: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onCopy: (UUID) -> Void

    private var edge: NotesEdge { settings.notesEdge }
    private var open: Bool { model.open }
    private var trailing: Bool { edge == .right }

    var body: some View {
        let notes = store.active
        let height = Self.columnHeight(count: notes.count)
        let column = VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            if notes.isEmpty {
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: Self.pillWidth, height: Self.rowHeight)
                    .padding(.vertical, Self.rowGap / 2)
                    .padding(trailing ? .trailing : .leading, open ? 0 : 5)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                tab(note, index: index, count: notes.count)
            }
        }
        .padding(.vertical, Self.padding - Self.rowGap / 2)

        return VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            ZStack(alignment: trailing ? .topTrailing : .topLeading) {
                rail.frame(width: Self.railWidth, height: height).opacity(open ? 0 : 1)
                Group {
                    if notes.count > Self.maxTabs {
                        ScrollView { column }.scrollIndicators(.never)
                    } else {
                        column
                    }
                }
                .frame(height: height, alignment: .top)
                .clipped()
            }
            newButton(empty: notes.isEmpty)
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: trailing ? .topTrailing : .topLeading)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.2), value: open)
        .animation(.easeOut(duration: 0.14), value: model.hovered)
        .animation(.easeOut(duration: 0.18), value: model.current)
        .animation(.easeOut(duration: 0.15), value: model.dragTarget)
    }

    /// The dark glass strip behind the pills.
    @ViewBuilder
    private var rail: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: trailing ? 8 : 0, bottomLeadingRadius: trailing ? 8 : 0,
                                           bottomTrailingRadius: trailing ? 0 : 8, topTrailingRadius: trailing ? 0 : 8,
                                           style: .continuous)
        if #available(macOS 26.0, *) {
            // A window that isn't key draws glass without its tint, so the shade is laid over it.
            Color.clear.glassEffect(Glass.regular, in: shape).overlay(shape.fill(Color.black.opacity(0.4)))
        } else {
            shape.fill(Color.black.opacity(0.4))
        }
    }

    /// How far a tab is moved aside while another is dragged past it.
    private func shift(_ index: Int, _ dragIndex: Int?) -> CGFloat {
        guard let d = dragIndex else { return 0 }
        let t = model.dragTarget
        if d < t, index > d, index <= t { return -Self.pitch }
        if d > t, index < d, index >= t { return Self.pitch }
        return 0
    }

    private func tab(_ note: Note, index: Int, count: Int) -> some View {
        let dragging = model.dragID == note.id
        let dragIndex = model.dragID.flatMap { id in store.active.firstIndex { $0.id == id } }
        let hot = model.hovered == note.id || model.current == note.id || model.flashed == note.id || dragging
        let width = open ? (hot ? Self.tabHotWidth : Self.tabWidth) : Self.pillWidth
        let r: CGFloat = open ? 10 : Self.pillWidth / 2
        let edgeR: CGFloat = open ? 0 : Self.pillWidth / 2
        let shape = UnevenRoundedRectangle(topLeadingRadius: trailing ? r : edgeR, bottomLeadingRadius: trailing ? r : edgeR,
                                           bottomTrailingRadius: trailing ? edgeR : r, topTrailingRadius: trailing ? edgeR : r,
                                           style: .continuous)
        let tint = open ? (hot ? 0.82 : 0.62) : 0.95
        return HStack(spacing: 0) {
            if !trailing { Spacer(minLength: 0) }
            Text(note.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .opacity(open ? 1 : 0)
            if trailing { Spacer(minLength: 0) }
        }
        .frame(width: width, height: Self.rowHeight, alignment: trailing ? .leading : .trailing)
        .background { tabFill(note, shape: shape, tint: tint) }
        .clipShape(shape)
        .contentShape(shape)
        .padding(trailing ? .trailing : .leading, open ? 0 : 5)
        // The whole row answers the pointer, the gap between tabs included, so crossing it doesn't blink the preview.
        .padding(.vertical, Self.rowGap / 2)
        .contentShape(Rectangle())
        .offset(y: dragging ? model.dragOffset : shift(index, dragIndex))
        .zIndex(dragging ? 1 : 0)
        .animation(dragging ? nil : .easeOut(duration: 0.15), value: model.dragOffset)
        .onTapGesture { onOpen(note) }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard open else { return }
                if model.dragID == nil { model.dragID = note.id; model.dragTarget = index; onTabHover(nil) }
                let low = -CGFloat(index) * Self.pitch, high = CGFloat(count - 1 - index) * Self.pitch
                let offset = min(max(value.translation.height, low), high)
                model.dragOffset = offset
                model.dragTarget = min(max(Int((CGFloat(index) + offset / Self.pitch).rounded()), 0), count - 1)
            }
            .onEnded { _ in
                guard model.dragID == note.id else { return }
                let target = model.dragTarget
                withAnimation(.easeOut(duration: 0.15)) { model.dragOffset = CGFloat(target - index) * Self.pitch }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    if target != index { onMove(note.id, target) }
                    model.dragID = nil
                    model.dragOffset = 0
                }
            })
        .onHover { inside in if model.dragID == nil { onTabHover(inside ? note : nil) } }
        .contextMenu { menu(for: note) }
        .accessibilityLabel(note.title)
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        Button(note.pinned ? "Stop Keeping on Screen" : "Keep on Screen") { onPin(note.id) }
        Menu("Color") {
            ForEach(NoteColor.allCases) { color in
                Toggle(color.label, isOn: Binding(get: { note.color == color }, set: { _ in onColor(note.id, color) }))
            }
        }
        Button("Copy Text") { onCopy(note.id) }
        Divider()
        Button("Archive") { onArchive(note.id) }
        Button("Delete", role: .destructive) { onDelete(note.id) }
    }

    private let rim = LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0)], startPoint: .top, endPoint: .bottom)

    /// Glass under a soft wash of the note's colour, like the note itself; at rest only the colour.
    @ViewBuilder
    private func tabFill(_ note: Note, shape: UnevenRoundedRectangle, tint: Double) -> some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(Glass.regular, in: shape).opacity(open ? 1 : 0)
            }
            shape.fill(LinearGradient(colors: [note.color.color.opacity(min(1, tint + 0.12)), note.color.color.opacity(tint - 0.04)],
                                      startPoint: .top, endPoint: .bottom))
            shape.stroke(rim, lineWidth: 2).opacity(open ? 1 : 0)
        }
    }

    private func newButton(empty: Bool) -> some View {
        Button(action: onNew) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                if empty {
                    Text("New Note").font(.system(size: 12, weight: .medium))
                    if let combo = settings.newNoteHotKey {
                        Text(combo.display).font(.system(size: 10, weight: .semibold, design: .rounded)).opacity(0.55)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, empty ? 12 : 0)
            .frame(width: empty ? nil : 30, height: 30)
            .glassCapsule()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(trailing ? .trailing : .leading, 10)
        .padding(.top, 8)
        .help("New note" + (settings.newNoteHotKey.map { " (\($0.display))" } ?? ""))
    }
}
