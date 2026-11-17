import AppKit
import PasteClipCore
import SwiftUI
import UniformTypeIdentifiers

/// One clip in the shelf: its content edge to edge, a small label with its name (or, without
/// one, when it was copied) at the top, and its details at the bottom while the pointer is over
/// it. `Equatable` so SwiftUI skips redrawing it unless what it shows changed; the selection
/// ring and quick-paste number are drawn by `CardsRow` on top.
struct ClipCard: View, Equatable {
    let item: ClipItem
    let store: ClipStore
    let index: Int
    let board: Pinboard?
    let inStack: Bool
    let showLinkPreview: Bool
    var renaming = false
    var onEndRenaming: () -> Void = {}
    @ObservedObject var links = LinkPreviews.shared
    @ObservedObject var thumbnails = FileThumbnails.shared
    @StateObject private var hovering = ViewState(false)

    static let size = CGSize(width: 220, height: 236)
    static let cornerRadius: CGFloat = 20
    /// Double-clicking above this renames the clip, where its label is.
    static let labelHeight: CGFloat = 38

    static func == (a: ClipCard, b: ClipCard) -> Bool {
        a.shown == b.shown && a.index == b.index && a.board == b.board && a.inStack == b.inStack
            && a.showLinkPreview == b.showLinkPreview && a.renaming == b.renaming
    }

    /// The clip without its place on the pinboard, which the card doesn't show; reordering a
    /// pinboard renumbers every clip on it and would otherwise redraw them all.
    private var shown: ClipItem {
        var item = item
        item.boardOrder = nil
        return item
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .clipped()
                // Clipping hides what spills over (a wide picture's blurred backdrop) but it would
                // still take the pointer and clicks over the cards beside it.
                .allowsHitTesting(false)
            label.padding(9)
            kindMark
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .padding(.top, 13)
                .padding(.trailing, 12)
            details
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(hovering.value && !renaming ? 1 : 0)
                .offset(y: hovering.value ? 0 : 4)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        // Flatten the card first so the shadow is drawn once, not for every layer inside it.
        .flattened(!renaming)
        .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
        .onHover { inside in withAnimation(.easeOut(duration: 0.18)) { hovering.value = inside } }
        .onAppear {
            if showLinkPreview, item.kind == .link, let link = item.text { links.load(link) }
            if item.kind == .file, let path = item.filePaths?.first { thumbnails.load(path) }
            if item.kind == .image, let url = store.imageURL(for: item) { thumbnails.load(url.path) }
        }
    }

    // MARK: - Label

    /// "Image" for a single copied image file, otherwise the clip kind.
    private var kindLabel: String {
        if item.kind == .file, let paths = item.filePaths, paths.count == 1,
           UTType(filenameExtension: (paths[0] as NSString).pathExtension)?.conforms(to: .image) == true {
            return "Image"
        }
        return item.kind.label
    }

    private var symbol: String { item.isImage ? ClipKind.image.symbol : item.kind.symbol }

    /// The app it came from and its name, or, without one, when it was copied. Pinned clips,
    /// clips in the paste stack and pinboard clips (in History) say so too.
    private var label: some View {
        HStack(spacing: 5) {
            appIcon
            if let board { Circle().fill(board.color).frame(width: 7, height: 7) }
            if renaming {
                TitleField(item: item, store: store, placeholder: "Name this clip", onEnd: onEndRenaming)
            } else if let title = item.title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text(item.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(.secondary) }
            if inStack { Image(systemName: "square.stack.3d.up.fill").font(.system(size: 8.5)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 3)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(renaming ? 1 : 0.86)))
        .overlay(Capsule().strokeBorder(renaming ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: renaming ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)
        // As wide as what it says, up to clear of the kind mark.
        .frame(maxWidth: Self.size.width - 50, alignment: .leading)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = AppTint.icon(for: item) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(AppTint.color(for: item)))
        }
    }

    /// The kind of clip, faintly, in the top corner.
    private var kindMark: some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(onPicture ? Color.white.opacity(0.85) : Color.secondary.opacity(0.7))
            .shadow(color: onPicture ? .black.opacity(0.3) : .clear, radius: 2)
            .help(kindLabel)
    }

    /// The card shows a picture or a colour under its label and details.
    private var onPicture: Bool {
        switch item.kind {
        case .image, .color: return true
        case .file: return hasThumbnail
        default: return false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            // Only the start is ever visible; laying out a whole long text on each redraw is slow.
            Text(String((item.text ?? "").prefix(600)))
                .font(looksLikeCode ? .system(size: 11.5, design: .monospaced) : .system(size: 13))
                .lineSpacing(2)
                .lineLimit(10)
                .padding(.horizontal, 14)
                .padding(.top, Self.labelHeight + 4)
                // Long text fades out near the card's bottom edge instead of stopping mid-line.
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 0.96)],
                                     startPoint: .top, endPoint: .bottom))
        case .link:
            linkContent
        case .image:
            if let path = store.imageURL(for: item)?.path, let thumb = thumbnails.thumbnail(for: path) {
                picture(thumb)
            } else {
                Color.primary.opacity(0.04)
            }
        case .file:
            if let path = item.filePaths?.first, let thumb = thumbnails.thumbnail(for: path) {
                picture(thumb)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((item.filePaths ?? []).prefix(4)), id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: FileThumbnails.icon(for: path)).resizable().frame(width: 28, height: 28)
                            Text((path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, Self.labelHeight + 4)
            }
        case .color:
            colorContent
        }
    }

    /// Text that reads as code: indented lines, or braces and semicolons ending them.
    private var looksLikeCode: Bool {
        let lines = (item.text ?? "").prefix(400).split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        let codeish = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.hasSuffix("{") || $0.hasSuffix(";") || $0.hasSuffix("}") }
        return codeish.count * 2 >= lines.count
    }

    /// The whole picture, as wide as the card, over a blurred copy of itself that fills the rest.
    private func picture(_ image: NSImage) -> some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.size.width, height: Self.size.height)
                .blur(radius: 22)
                .saturation(1.3)
                .opacity(0.85)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.size.width, height: Self.size.height)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    /// The site's icon and name, the page's title, and its picture small at the bottom when
    /// it's sharp enough to be worth showing.
    @ViewBuilder
    private var linkContent: some View {
        let preview = showLinkPreview ? links.preview(for: item.text ?? "") : nil
        let host = URL(string: item.text ?? "")?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let picture = preview?.image.flatMap { Self.isSharp($0) ? $0 : nil }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                siteIcon(preview?.icon)
                Text(host).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(preview?.title ?? item.text ?? "")
                .font(.system(size: 13.5, weight: .semibold))
                .lineSpacing(1)
                .lineLimit(picture == nil ? 6 : 3)
            Spacer(minLength: 0)
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.size.width - 24, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, Self.labelHeight + 4)
        .padding(.bottom, 12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    /// The site's icon on a small rounded tile, or a globe without one.
    private func siteIcon(_ icon: NSImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06))
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().padding(4)
            } else {
                Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// A page picture shows on the card only when it has the pixels for it; small ones (often
    /// the site's logo blown up) look blurred.
    private static func isSharp(_ image: NSImage) -> Bool {
        let pixels = image.representations.map { CGFloat($0.pixelsWide) }.max() ?? image.size.width
        return pixels >= 400
    }

    /// The colour filling the card, with its code on it.
    private var colorContent: some View {
        let rgba = RGBA(hex: item.text ?? "")
        let color = rgba.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } ?? .clear
        let light = rgba.map { 0.299 * $0.r + 0.587 * $0.g + 0.114 * $0.b > 0.6 } ?? false
        return ZStack(alignment: .bottomLeading) {
            color
            Text((item.text ?? "").uppercased())
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(light ? Color.black.opacity(0.75) : Color.white)
                .padding(14)
                .padding(.bottom, 18)
        }
    }

    // MARK: - Details

    private var hasThumbnail: Bool {
        item.filePaths?.first.flatMap(thumbnails.thumbnail(for:)) != nil
    }

    /// Size, length or file name, and when it was copied if the label shows a name instead.
    private var detail: String? {
        switch item.kind {
        case .image:
            return store.imageURL(for: item).flatMap { FileThumbnails.pixelSize(of: $0.path) }
                .map { "\(Int($0.width)) × \(Int($0.height))" }
        case .file:
            guard let path = item.filePaths?.first else { return nil }
            let count = item.filePaths?.count ?? 1
            let name = (path as NSString).lastPathComponent
            return count > 1 ? "\(name) +\(count - 1)" : name
        default:
            return item.summary
        }
    }

    private var details: some View {
        HStack(spacing: 6) {
            if item.hasFormatting { Image(systemName: "textformat").help("Keeps formatting") }
            if let detail { Text(detail).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 4)
            if item.title != nil {
                Text(item.date, format: .relative(presentation: .named, unitsStyle: .abbreviated)).lineLimit(1)
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(onPicture ? Color.white : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if onPicture {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor)],
                               startPoint: .top, endPoint: .center)
            }
        }
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

/// Edits a clip's name in its card's label. Return or clicking elsewhere saves; Esc cancels;
/// an empty name takes it off.
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
            .font(.system(size: 11.5, weight: .semibold))
            .frame(width: 140)
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
            // Formatting too, for apps that take it; the rest use the plain text. Read only when
            // asked for, so starting a drag stays quick.
            let types: [NSPasteboard.PasteboardType] = item.richType == "rtf" ? [.rtf, .html] : item.richType == "html" ? [.html] : []
            for type in types {
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { done in
                    done(store.richRepresentations(for: item)[type], nil)
                    return nil
                }
            }
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
