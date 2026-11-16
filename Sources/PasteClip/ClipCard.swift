import AppKit
import PasteClipCore
import SwiftUI
import UniformTypeIdentifiers

/// One clip in the shelf. `Equatable` so SwiftUI skips redrawing it unless what it shows
/// changed; the selection ring is drawn by `CardsRow` on top.
struct ClipCard: View, Equatable {
    let item: ClipItem
    let store: ClipStore
    let index: Int
    let board: Pinboard?
    let inStack: Bool
    let showLinkPreview: Bool
    let quickPasteSymbol: String
    var renaming = false
    var onEndRenaming: () -> Void = {}
    @ObservedObject var links = LinkPreviews.shared
    @ObservedObject var thumbnails = FileThumbnails.shared

    private static let size = CGSize(width: 236, height: 236)
    static let headerHeight: CGFloat = 50

    static func == (a: ClipCard, b: ClipCard) -> Bool {
        a.shown == b.shown && a.shortcutIndex == b.shortcutIndex && a.board == b.board && a.inStack == b.inStack
            && a.showLinkPreview == b.showLinkPreview && a.quickPasteSymbol == b.quickPasteSymbol
            && a.renaming == b.renaming
    }

    /// The clip without its place on the pinboard, which the card doesn't show; reordering a
    /// pinboard renumbers every clip on it and would otherwise redraw them all.
    private var shown: ClipItem {
        var item = item
        item.boardOrder = nil
        return item
    }

    /// Only the first nine cards show their position, as a quick-paste shortcut.
    private var shortcutIndex: Int { min(index, 9) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Slightly see-through so the shelf's glass shows behind the card.
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Flatten the card first so the shadow is drawn once, not for every layer inside it.
        .flattened(!renaming)
        .shadow(color: .black.opacity(0.14), radius: 5, y: 3)
        .onAppear {
            if showLinkPreview, item.kind == .link, let link = item.text { links.load(link) }
            if item.kind == .file, let path = item.filePaths?.first { thumbnails.load(path) }
            if item.kind == .image, let url = store.imageURL(for: item) { thumbnails.load(url.path) }
        }
    }

    // MARK: - Header

    /// "Image" for a single copied image file, otherwise the clip kind.
    private var kindLabel: String {
        if item.kind == .file, let paths = item.filePaths, paths.count == 1,
           UTType(filenameExtension: (paths[0] as NSString).pathExtension)?.conforms(to: .image) == true {
            return "Image"
        }
        return item.kind.label
    }

    /// The pinboard's colour for clips on a pinboard, otherwise the source app's colour.
    private var tint: Color {
        board?.color ?? AppTint.color(for: item)
    }

    private var header: some View {
        let tint = self.tint
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if renaming {
                        TitleField(item: item, store: store, placeholder: kindLabel, onEnd: onEndRenaming)
                    } else {
                        Text(item.title ?? kindLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    if inStack { Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9)) }
                }
                Text(item.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 10.5))
                    .opacity(0.85)
            }
            Spacer(minLength: 4)
            appBadge
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Self.headerHeight)
        .background(
            ZStack {
                LinearGradient(colors: [tint, tint.deeper],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Faint sheen along the top edge.
                LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0)], startPoint: .top, endPoint: .center)
            }
        )
    }

    @ViewBuilder
    private var appBadge: some View {
        if let icon = AppTint.icon(for: item) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.2)))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            // Only the start is ever visible; laying out a whole long text on each redraw is slow.
            Text(String((item.text ?? "").prefix(600)))
                .font(.system(size: 12))
                .lineLimit(9)
                .padding(12)
        case .link:
            linkContent
        case .image:
            if let path = store.imageURL(for: item)?.path, let thumb = thumbnails.thumbnail(for: path) {
                picture(thumb, badge: FileThumbnails.pixelSize(of: path).map { "\(Int($0.width)) × \(Int($0.height))" })
            } else {
                Checkerboard()
            }
        case .file:
            if let path = item.filePaths?.first, let thumb = thumbnails.thumbnail(for: path) {
                let count = item.filePaths?.count ?? 1
                picture(thumb, badge: count > 1 ? "\((path as NSString).lastPathComponent) +\(count - 1)"
                                                 : (path as NSString).lastPathComponent)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((item.filePaths ?? []).prefix(4)), id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: FileThumbnails.icon(for: path)).resizable().frame(width: 28, height: 28)
                            Text((path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                }
                .padding(12)
            }
        case .color:
            ColorSwatch(hex: item.text ?? "").padding(12)
        }
    }

    /// An image fitted on a checkerboard, with a small glass label at the bottom.
    private func picture(_ image: NSImage, badge: String?) -> some View {
        ZStack(alignment: .bottom) {
            Checkerboard()
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let badge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .padding(.horizontal, 30)
                    .padding(.bottom, 6)
            }
        }
        .frame(width: Self.size.width)
    }

    @ViewBuilder
    private var linkContent: some View {
        let preview = showLinkPreview ? links.preview(for: item.text ?? "") : nil
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.primary.opacity(0.05)
                if let image = preview?.image {
                    // Fitted, not filled, so the whole image shows (as image clips do).
                    Image(nsImage: image).resizable().scaledToFit().padding(6)
                } else {
                    Image(systemName: "safari").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.size.width, height: 104)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                if let title = preview?.title {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }
                Text(item.text ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(preview?.title == nil ? 3 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Footer

    private var hasThumbnail: Bool {
        item.filePaths?.first.flatMap(thumbnails.thumbnail(for:)) != nil
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if item.richFile != nil {
                Image(systemName: "textformat").help("Keeps formatting")
            }
            if item.kind != .image, !(item.kind == .file && hasThumbnail) { Text(item.summary).lineLimit(1) }
            Spacer()
            if index < 9 {
                Text("\(quickPasteSymbol)\(index + 1)")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private extension View {
    /// Draws the card into one layer, so scrolling the row moves a few layers instead of
    /// syncing every gradient, text and image inside each card. The title field can't be drawn
    /// that way (it is an AppKit view), so a card being renamed is only grouped.
    @ViewBuilder func flattened(_ flat: Bool) -> some View {
        if flat { drawingGroup() } else { compositingGroup() }
    }
}

/// Edits a clip's title in its card header. Return or clicking elsewhere saves; Esc cancels;
/// an empty title goes back to the clip kind.
private struct TitleField: View {
    let item: ClipItem
    let store: ClipStore
    let placeholder: String
    let onEnd: () -> Void
    @StateObject private var draft: ViewState<String>
    @StateObject private var done = ViewState(false)
    @FocusState private var focused: Bool

    init(item: ClipItem, store: ClipStore, placeholder: String, onEnd: @escaping () -> Void) {
        self.item = item
        self.store = store
        self.placeholder = placeholder
        self.onEnd = onEnd
        _draft = StateObject(wrappedValue: ViewState(item.title ?? ""))
    }

    var body: some View {
        TextField(placeholder, text: $draft.value)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.22)))
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in if !isFocused { finish(save: true) } }
            .onDisappear { finish(save: true) }
    }

    private func finish(save: Bool) {
        guard !done.value else { return }
        done.value = true
        if save, draft.value != (item.title ?? "") { store.setTitle(item, draft.value) }
        onEnd()
    }
}

/// Header colours for clips not on a pinboard: a dark tone of the source app's icon colour, so clips
/// from one app look alike and the bright pinboard colours stand out.
enum AppTint {
    private static var colors: [String: Color] = [:]
    private static var icons: [String: NSImage] = [:]

    static func icon(for item: ClipItem) -> NSImage? {
        guard let id = item.sourceBundleID else { return nil }
        if let icon = icons[id] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[id] = icon
        return icon
    }

    static func color(for item: ClipItem) -> Color {
        let key = item.sourceBundleID ?? item.kind.rawValue
        if let color = colors[key] { return color }
        let color = icon(for: item).flatMap(dominantColor) ?? fallback(key)
        colors[key] = color
        return color
    }

    /// The icon's dominant hue: saturated pixels vote into hue buckets and the biggest bucket wins.
    /// Averaging instead would turn multicoloured icons into mud. Mostly grey icons get nil.
    private static func dominantColor(_ image: NSImage) -> Color? {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let buckets = 24
        var votes = [Double](repeating: 0, count: buckets)
        var hueSum = [Double](repeating: 0, count: buckets)
        var total = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                total += 1
                let s = c.saturationComponent, b = c.brightnessComponent
                guard s > 0.3, b > 0.25 else { continue }
                let i = min(Int(c.hueComponent * Double(buckets)), buckets - 1)
                votes[i] += s * b
                hueSum[i] += c.hueComponent * s * b
            }
        }
        guard let best = votes.indices.max(by: { votes[$0] < votes[$1] }),
              votes[best] > total * 0.04 else { return nil }
        return Color(hue: hueSum[best] / votes[best], saturation: 0.5, brightness: 0.36)
    }

    /// A stable dark hue per app (or kind) for grey icons and clips without an app.
    private static func fallback(_ key: String) -> Color {
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.36)
    }
}

struct ColorSwatch: View {
    let hex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            Text(hex.uppercased()).font(.system(size: 13, design: .monospaced))
        }
    }

    private var color: Color {
        guard let c = RGBA(hex: hex) else { return .clear }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension Pinboard {
    /// Bright colours that keep white header text readable.
    static let palette: [Color] = [
        Color(hue: 0.0, saturation: 0.72, brightness: 0.92),    // red
        Color(hue: 0.07, saturation: 0.8, brightness: 0.95),    // orange
        Color(hue: 0.12, saturation: 0.85, brightness: 0.88),   // amber
        Color(hue: 0.38, saturation: 0.7, brightness: 0.75),    // green
        Color(hue: 0.5, saturation: 0.75, brightness: 0.78),    // teal
        Color(hue: 0.6, saturation: 0.75, brightness: 0.92),    // blue
        Color(hue: 0.76, saturation: 0.62, brightness: 0.88),   // purple
        Color(hue: 0.9, saturation: 0.6, brightness: 0.92),     // pink
    ]

    var color: Color { Self.palette[((colorIndex % Self.palette.count) + Self.palette.count) % Self.palette.count] }
}

/// Name and colour form used to create or edit a pinboard.
struct PinboardEditor: View {
    let board: Pinboard?
    let onSave: (String, Int) -> Void
    @StateObject private var name = ViewState("")
    @StateObject private var colorIndex = ViewState(0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(board == nil ? "New Pinboard" : "Edit Pinboard").font(.headline)
            TextField("Name", text: $name.value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(save)
            HStack(spacing: 8) {
                ForEach(Pinboard.palette.indices, id: \.self) { i in
                    Circle()
                        .fill(Pinboard.palette[i])
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary, lineWidth: colorIndex.value == i ? 2 : 0).padding(-3))
                        .onTapGesture { colorIndex.value = i }
                }
            }
            HStack {
                Spacer()
                Button(board == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            name.value = board?.name ?? ""
            colorIndex.value = board?.colorIndex ?? Int.random(in: 0..<Pinboard.palette.count)
        }
    }

    private func save() {
        let trimmed = name.value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, colorIndex.value)
    }
}

extension Color {
    /// The same hue, a little darker and richer, for the far end of a gradient.
    var deeper: Color {
        let c = NSColor(self).usingColorSpace(.deviceRGB) ?? .systemBlue
        return Color(hue: c.hueComponent, saturation: min(c.saturationComponent * 1.05, 1),
                     brightness: c.brightnessComponent * 0.85)
    }
}

/// Dragging a card: other apps get the clip's content, PasteClip's pinboard tabs get its id.
enum ClipDrag {
    static let type = UTType(exportedAs: "io.github.vinh-dq.pasteclip.clip")

    /// The clip's id comes first, for dropping on a pinboard tab, then its content for other apps.
    /// Built by hand: `NSItemProvider(contentsOf:)` turns the drag into a plain file drag, which
    /// leaves out the id, so images and files couldn't be dropped on a pinboard.
    static func provider(for item: ClipItem, store: ClipStore) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(item.id.uuidString.utf8), nil)
            return nil
        }
        switch item.kind {
        case .text, .link, .color:
            provider.registerObject((item.text ?? "") as NSString, visibility: .all)
        case .image:
            if let url = store.imageURL(for: item) { registerFile(url, as: .png, on: provider) }
        case .file:
            if let path = item.filePaths?.first {
                let url = URL(fileURLWithPath: path)
                registerFile(url, as: UTType(filenameExtension: url.pathExtension) ?? .data, on: provider)
            }
        }
        return provider
    }

    private static func registerFile(_ url: URL, as contentType: UTType, on provider: NSItemProvider) {
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        provider.registerObject(url as NSURL, visibility: .all)
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier, visibility: .all) { done in
            done(url, false, nil)
            return nil
        }
    }

    /// Reads the dragged clip's id and hands it over on the main thread.
    static func receive(_ providers: [NSItemProvider], _ handle: @escaping (UUID) -> Void) -> Bool {
        receiveID(providers, of: type, handle)
    }

    /// Reads an id dragged as `type` and hands it over on the main thread. False if there is none.
    static func receiveID(_ providers: [NSItemProvider], of type: UTType, _ handle: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) })
        else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            DispatchQueue.main.async { handle(id) }
        }
        return true
    }
}

/// Dragging a pinboard tab onto another tab, to reorder the pinboards. Only PasteClip accepts it.
enum PinboardDrag {
    static let type = UTType(exportedAs: "io.github.vinh-dq.pasteclip.pinboard")

    static func provider(for board: Pinboard) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(board.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Reads the dragged pinboard's id and hands it over on the main thread. False if it isn't one.
    static func receive(_ providers: [NSItemProvider], _ handle: @escaping (UUID) -> Void) -> Bool {
        ClipDrag.receiveID(providers, of: type, handle)
    }
}
