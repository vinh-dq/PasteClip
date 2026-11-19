import AppKit
import Combine
import PasteClipCore
import QuickLookUI
import SwiftUI

/// Floating panel that previews the selected clip above its card (Space).
/// It can become key so the title field and the text editor can take typing.
final class PreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}

/// Where the popup's arrow sits, in popup coordinates.
final class PopupGeometry: ObservableObject {
    @Published var arrowX: CGFloat = 0
    @Published var pointsDown = true
}

final class PreviewPopupController {
    let panel = PreviewPanel()
    private let geometry = PopupGeometry()
    private let store: ClipStore
    static let arrowHeight: CGFloat = 10

    init(state: ShelfState, store: ClipStore, settings: AppSettings) {
        self.store = store
        panel.contentView = HostingView(rootView: PreviewPopup(state: state, selection: state.selectionModel,
                                                                 store: store, settings: settings, geometry: geometry))
    }

    var isKey: Bool { panel.isKeyWindow }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Places the popup above the card (or below it when the shelf is at the top of the screen),
    /// with its arrow pointing at the card's centre. `card` is in the shelf's SwiftUI global space.
    func show(_ item: ClipItem, over card: CGRect, in shelf: NSPanel, sharingType: NSWindow.SharingType) {
        guard let screen = shelf.screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        let size = size(for: item, on: screen)
        let cardMidX = shelf.frame.minX + card.midX
        let cardTop = shelf.frame.maxY - card.minY
        let cardBottom = shelf.frame.maxY - card.maxY

        let x = min(max(cardMidX - size.width / 2, bounds.minX + 12), bounds.maxX - size.width - 12)
        let fitsAbove = cardTop + 4 + size.height <= bounds.maxY
        let y = fitsAbove ? cardTop + 4 : cardBottom - 4 - size.height

        geometry.pointsDown = fitsAbove
        geometry.arrowX = min(max(cardMidX - x, 24), size.width - 24)
        panel.sharingType = sharingType
        // Following the card while the row scrolls only moves the popup; resizing re-lays out its content.
        if panel.frame.size == size {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            // Laid out with the next frame rather than right away, so it happens once per move.
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        }
        if panel.parent == nil { shelf.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// Header, footer, arrow and the margins around the sheet the clip sits on.
    private static let chrome = CGSize(width: 20, height: 48 + 30 + arrowHeight + 20)
    private static let minWidth: CGFloat = 460

    /// Full width for text and documents; for pictures, just wide enough to show the whole
    /// image at the popup's height (or at its own size when smaller), so there are no wide margins.
    private func size(for item: ClipItem, on screen: NSScreen) -> NSSize {
        let bounds = screen.visibleFrame
        let full = NSSize(width: min(980, bounds.width - 40), height: min(430, bounds.height * 0.55))
        if item.kind == .text { return textSize(for: item, max: full) }
        // A colour needs only room for its swatch and code.
        if item.kind == .color { return NSSize(width: Self.minWidth, height: 250) }
        if item.kind == .link {
            // Just the site, the title and the link, with the page's picture beside them when it has one.
            let picture = LinkPreviews.shared.preview(for: item.text ?? "")?.image.map(PreviewCard.isSharp) ?? false
            return NSSize(width: min(picture ? 680 : 560, full.width), height: picture ? 300 : 230)
        }
        guard let pixels = imagePixelSize(of: item), pixels.width > 0, pixels.height > 0 else { return full }
        let points = CGSize(width: pixels.width / screen.backingScaleFactor,
                            height: pixels.height / screen.backingScaleFactor)
        let maxImage = CGSize(width: full.width - Self.chrome.width, height: full.height - Self.chrome.height)
        let scale = min(1, maxImage.width / points.width, maxImage.height / points.height)
        let image = CGSize(width: points.width * scale, height: points.height * scale)
        return NSSize(width: max(Self.minWidth, image.width + Self.chrome.width),
                      height: max(260, image.height + Self.chrome.height))
    }

    /// Measured text sizes, so moving the popup while the shelf scrolls doesn't re-lay out the text.
    private var textSizes: [UUID: (key: String, size: NSSize)] = [:]

    /// Wide enough for the longest line and tall enough for every line, with a little room to
    /// spare, up to the full popup size (longer text scrolls).
    private func textSize(for item: ClipItem, max full: NSSize) -> NSSize {
        let key = "\(item.contentKey)|\(full)"
        if let cached = textSizes[item.id], cached.key == key { return cached.size }
        let text: NSAttributedString
        if let rich = PreviewCard.richText(of: item, store: store) {
            text = rich
        } else {
            text = NSAttributedString(string: item.text ?? "", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        }
        let inset = CGSize(width: 2 * 14 + 24, height: 2 * 14 + 20)
        let bounds = text.boundingRect(with: NSSize(width: full.width - inset.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: min(full.width, max(Self.minWidth, ceil(bounds.width) + inset.width)),
                          height: min(full.height, max(220, ceil(bounds.height) + inset.height + Self.chrome.height)))
        textSizes[item.id] = (key, size)
        return size
    }

    private func imagePixelSize(of item: ClipItem) -> CGSize? {
        switch item.kind {
        case .image: return store.imageURL(for: item).flatMap { FileThumbnails.pixelSize(of: $0.path) }
        case .file: return item.filePaths?.first.flatMap(FileThumbnails.pixelSize(of:))
        default: return nil
        }
    }
}

// MARK: - View

struct PreviewPopup: View {
    @ObservedObject var state: ShelfState
    @ObservedObject var selection: SelectionModel
    @ObservedObject var store: ClipStore
    let settings: AppSettings
    @ObservedObject var geometry: PopupGeometry

    var body: some View {
        VStack(spacing: 0) {
            if !geometry.pointsDown { arrow.rotationEffect(.degrees(180)) }
            Group {
                // Built only while shown: a hidden popup would otherwise rebuild on every move.
                if state.previewing, let item = state.selectedItem {
                    PreviewCard(item: item, state: state, store: store, settings: settings)
                        .id(item.id)
                } else {
                    Color.clear
                }
            }
            .background(GlassBackground(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glassEdge(cornerRadius: 22)
            if geometry.pointsDown { arrow }
        }
    }

    private var arrow: some View {
        GeometryReader { g in
            GlassBackground(cornerRadius: 0)
                .clipShape(Triangle())
                .frame(width: 22, height: PreviewPopupController.arrowHeight)
                .position(x: geometry.arrowX, y: g.size.height / 2)
        }
        .frame(height: PreviewPopupController.arrowHeight)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Header with title and actions, the clip itself, and a line of details.
private struct PreviewCard: View {
    let item: ClipItem
    @ObservedObject var state: ShelfState
    let store: ClipStore
    let settings: AppSettings
    @StateObject private var hovering = ViewState(false)

    private enum Field { case title, body }
    @FocusState private var focus: Field?
    @StateObject private var titleDraft = ViewState("")
    /// The name is a field only once clicked, so the popup doesn't take the keys meant for the shelf.
    @StateObject private var naming = ViewState(false)
    @StateObject private var textDraft = ViewState("")
    /// The edited formatted text, set once it changes. Not published: only saving reads it.
    @StateObject private var richDraft = RichDraft()

    var body: some View {
        VStack(spacing: 0) {
            header
            // The clip on a sheet of its own, like its card; ringed while it's being edited.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Softer than plain white: a little of the glass shows through.
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(state.editing ? Color.accentColor : Color.primary.opacity(0.07),
                                  lineWidth: state.editing ? 2 : 0.5))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .padding(.horizontal, 10)
                .animation(.easeOut(duration: 0.15), value: state.editing)
            footer
        }
        .onHover { hovering.value = $0 }
        .onAppear {
            titleDraft.value = item.title ?? ""
            textDraft.value = item.text ?? ""
            if state.editing {
                focus = .body
                state.textInputActive = true
                state.commitEdit = saveText
            }
        }
        .onChange(of: state.editing) { _, editing in
            // The formatted editor is an AppKit view outside SwiftUI focus, so editing counts as typing throughout.
            state.textInputActive = editing || focus != nil
            if editing {
                textDraft.value = item.text ?? ""
                richDraft.text = nil
                focus = .body
                state.commitEdit = saveText
            } else {
                state.commitEdit = nil
                if focus == .body { focus = nil }
            }
        }
        // The popup stays mounted while hidden, so follow renames made on the card; otherwise the
        // stale draft would be saved over the new title when this view goes away.
        .onChange(of: item.title) { _, title in
            if focus != .title { titleDraft.value = title ?? "" }
        }
        .onChange(of: focus) { _, field in
            state.textInputActive = field != nil || state.editing
            if field != .title {
                commitTitle()
                naming.value = false
            }
        }
        .onDisappear {
            commitTitle()
            state.textInputActive = false
        }
    }

    /// Saves the edited text, if it changed. Kept in `state.commitEdit` while editing.
    private func saveText() {
        if let rich = richDraft.text {
            store.updateText(item, rich)
            richDraft.text = nil
        } else if textDraft.value != item.text {
            store.updateText(item, textDraft.value)
        }
    }

    private func commitTitle() {
        if titleDraft.value != (item.title ?? "") { store.setTitle(item, titleDraft.value) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            nameLabel
            Spacer(minLength: 8)
            if state.editing {
                CapsuleButton(title: "Discard", key: "⌥esc", help: "Discard the changes (⌥Esc)") { state.editing = false }
                CapsuleButton(title: "Save", key: "esc", prominent: true, help: "Save and finish editing (Esc or ⌘S)") {
                    saveText()
                    state.editing = false
                }
                .keyboardShortcut("s", modifiers: .command)
            } else {
                // Actions used now and then show their symbol and key; the name is in the tooltip.
                CapsuleButton(symbol: "doc.on.doc", key: "⌘C", help: "Copy (⌘C)") { state.onCopy(item) }
                if item.isTextual || item.isImage {
                    CapsuleButton(symbol: "character.bubble", key: settings.translateHotKey?.display,
                                  help: "Translate" + (settings.translateHotKey.map { " (\($0.display))" } ?? "")) {
                        state.onTranslate(item, nil)
                    }
                }
                CapsuleButton(symbol: item.pinned ? "pin.slash" : "pin", key: "⌘P",
                              help: item.pinned ? "Unpin (⌘P)" : "Pin, so it's kept (⌘P)") { store.togglePin(item) }
                if item.kind == .link, let url = URL(string: item.text ?? "") {
                    CapsuleButton(symbol: "safari", help: "Open in Browser") { NSWorkspace.shared.open(url) }
                }
                if item.kind == .file, let path = item.filePaths?.first {
                    CapsuleButton(symbol: "folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                if item.isImage {
                    CapsuleButton(symbol: "pip", key: settings.floatImageKey?.display,
                                  help: "Float on screen" + (settings.floatImageKey.map { " (\($0.display))" } ?? "")) {
                        state.onFloatImages([item])
                    }
                }
                if item.isTextual || item.isImage {
                    CapsuleButton(title: "Edit", symbol: "pencil", key: "⌘E",
                                  help: item.isImage ? "Mark up the image (⌘E)" : "Edit the text (⌘E)") {
                        if item.isImage { state.onEditImage(item) } else { state.editing = true }
                    }
                }
                CapsuleButton(title: "Paste", key: "↩", prominent: true) { state.onPaste(item, false) }
            }
            Button { state.closePreview() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .help("Close (Space)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: 48)
    }

    /// The app it came from and its name, as on its card; typing in it names the clip.
    private var nameLabel: some View {
        HStack(spacing: 6) {
            if let icon = AppTint.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: item.isImage ? ClipKind.image.symbol : item.kind.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(AppTint.color(for: item)))
            }
            if naming.value {
                TextField("Name this clip", text: $titleDraft.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .focused($focus, equals: .title)
                    .onSubmit { focus = nil }
                    .frame(width: 200)
                    .onAppear { DispatchQueue.main.async { focus = .title } }
            } else {
                Text(titleDraft.value.isEmpty ? "Name this clip" : titleDraft.value)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(titleDraft.value.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .frame(minWidth: 40, maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: titleDraft.value.count < 32, vertical: false)
                    .contentShape(Rectangle())
                    .onTapGesture { naming.value = true }
                    .help("Click to name this clip")
            }
            Text(item.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 4)
        .padding(.trailing, 11)
        .frame(height: 28)
        .layoutPriority(1)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(focus == .title ? 1 : 0.7)))
        .overlay(Capsule().strokeBorder(focus == .title ? Color.accentColor : Color.primary.opacity(0.06),
                                        lineWidth: focus == .title ? 1.5 : 0.5))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text where state.editing, .link where state.editing:
            if let rich = Self.richText(of: item, store: store) {
                RichTextEditor(text: rich) { edited in
                    richDraft.text = edited
                    textDraft.value = edited.string
                }
            } else {
                plainEditor
            }
        case .color where state.editing:
            plainEditor
        case .text:
            if let rich = Self.richText(of: item, store: store) {
                RichTextView(text: rich)
            } else {
                ScrollView {
                    Text(item.text ?? "")
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        case .link:
            linkContent
        case .image:
            if let path = store.imageURL(for: item)?.path,
               let image = FileThumbnails.image(at: path, maxPixels: Self.maxPicturePixels) ?? store.image(for: item) {
                picture(image, backdrop: FileThumbnails.image(at: path, maxPixels: Self.backdropPixels))
            }
        case .file:
            if let path = item.filePaths?.first {
                // Image files are drawn like copied images, sized to the popup with no extra margins.
                if FileThumbnails.pixelSize(of: path) != nil,
                   let image = FileThumbnails.image(at: path, maxPixels: Self.maxPicturePixels) ?? Self.fileImage(at: path) {
                    picture(image, backdrop: FileThumbnails.image(at: path, maxPixels: Self.backdropPixels))
                } else {
                    QuickLookView(url: URL(fileURLWithPath: path))
                }
            }
        case .color:
            colorContent
        }
    }

    private var plainEditor: some View {
        TextEditor(text: $textDraft.value)
            .font(.system(size: 13))
            .lineSpacing(2)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(12)
            .focused($focus, equals: .body)
    }

    /// Enough for the largest popup on a Retina screen; pictures are decoded no larger.
    private static let maxPicturePixels = 2000
    /// The blurred copy behind a picture needs very few pixels.
    private static let backdropPixels = 160

    /// The whole picture over a blurred copy of itself, as on its card.
    private func picture(_ image: NSImage, backdrop: NSImage? = nil) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A background, so the blurred copy spilling over doesn't make the popup any bigger.
            .background {
                Image(nsImage: backdrop ?? image).resizable().scaledToFill().blur(radius: 30).saturation(1.3).opacity(0.85)
                    .allowsHitTesting(false)
            }
            .clipped()
    }

    /// The colour filling the sheet, with its code on it, as on its card.
    private var colorContent: some View {
        let rgba = RGBA(hex: item.text ?? "")
        let color = rgba.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } ?? .clear
        let light = rgba.map { 0.299 * $0.r + 0.587 * $0.g + 0.114 * $0.b > 0.6 } ?? false
        return ZStack(alignment: .bottomLeading) {
            color
            Text((item.text ?? "").uppercased())
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(light ? Color.black.opacity(0.75) : Color.white)
                .textSelection(.enabled)
                .padding(20)
        }
    }

    /// The site's icon and name, the page's title and the link, with the page's picture beside
    /// them when it's sharp enough, as on the card.
    @ViewBuilder
    private var linkContent: some View {
        let preview = LinkPreviews.shared.preview(for: item.text ?? "")
        let host = URL(string: item.text ?? "")?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let picture = preview?.image.flatMap { Self.isSharp($0) ? $0 : nil }
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06))
                        if let icon = preview?.icon {
                            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().padding(4)
                        } else {
                            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(host).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let title = preview?.title {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text(item.text ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(preview?.title == nil ? 4 : 2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 220, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A page picture shows only when it has the pixels for it; small ones (often the site's
    /// logo blown up) look blurred.
    static func isSharp(_ image: NSImage) -> Bool {
        let pixels = image.representations.map { CGFloat($0.pixelsWide) }.max() ?? image.size.width
        return pixels >= 400
    }

    private static let richCache = NSCache<NSString, NSAttributedString>()
    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    /// The clip's formatted text, read and parsed once. Parsing HTML is slow, and the popup
    /// redraws often, so doing it in `body` made moving between clips stutter.
    static func richText(of item: ClipItem, store: ClipStore) -> NSAttributedString? {
        guard let file = item.pasteboardFile ?? item.richFile else { return nil }
        // An edited clip may keep its file name, so key on the text too.
        let key = "\(file)|\(item.contentKey.hashValue)" as NSString
        if let cached = richCache.object(forKey: key) { return cached }
        guard let formatted = store.formattedText(for: item) else { return nil }
        let text = readable(formatted)
        richCache.setObject(text, forKey: key)
        return text
    }

    /// Formatted text as it reads on the sheet: text copied from a dark app (an editor, a chat)
    /// keeps its own black or white text and background, which shows as dark bars or vanishes on
    /// a light sheet. Backgrounds go, and black, white and grey text takes the sheet's text colour;
    /// bold, italics, links and coloured text stay.
    private static func readable(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: result.length)
        result.removeAttribute(.backgroundColor, range: all)
        result.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            if max(r, g, b) - min(r, g, b) < 0.08 {
                result.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            }
        }
        return result
    }

    private static func fileImage(at path: String) -> NSImage? {
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(details.joined(separator: "  ·  ")).lineLimit(1)
            Spacer()
            if let ocr = item.ocrText, !state.editing {
                Button("Copy Text in Image") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ocr, forType: .string)
                }
                .buttonStyle(.link)
            }
            if let app = item.sourceName { Text("From \(app)").fontWeight(.medium) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
        // Small print, shown while the pointer is over the popup (or while editing, for the counts).
        .opacity(hovering.value || state.editing ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering.value)
    }

    private var details: [String] {
        switch item.kind {
        case .text, .link, .color:
            let text = state.editing ? textDraft.value : (item.text ?? "")
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            var parts = ["\(text.count.formatted()) characters", "\(words.formatted()) words",
                         "\(lines.formatted()) lines"]
            if item.hasFormatting, !state.editing {
                parts.append(item.richType?.uppercased() ?? "Formatting from \(item.sourceName ?? "its app")")
            }
            return parts
        case .image:
            guard let path = store.imageURL(for: item)?.path,
                  let size = FileThumbnails.pixelSize(of: path) else { return ["Image"] }
            return ["\(Int(size.width)) × \(Int(size.height))"]
        case .file:
            let paths = item.filePaths ?? []
            return paths.count == 1 ? [paths[0]] : ["\(paths.count) files", paths.first ?? ""]
        }
    }
}

/// Read-only, selectable view of formatted text.
struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = OverlayScrollView.withTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 14)
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The text is cached, so the same object means nothing changed; resetting it re-lays it out.
        guard context.coordinator.shown !== text else { return }
        context.coordinator.shown = text
        (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: NSAttributedString?
    }
}

/// The formatted text being edited, kept apart from the view so typing doesn't redraw it.
final class RichDraft: ObservableObject {
    var text: NSAttributedString?
}

/// Editable formatted text. Styles and links are kept, and pasting into it keeps formatting too.
struct RichTextEditor: NSViewRepresentable {
    let text: NSAttributedString
    let onChange: (NSAttributedString) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = OverlayScrollView.withTextView()
        view.isEditable = true
        view.isRichText = true
        view.allowsUndo = true
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.textStorage?.setAttributedString(text)
        view.delegate = context.coordinator
        scroll.drawsBackground = false
        // Take the keyboard once the popup (which becomes key for editing) is on screen.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (NSAttributedString) -> Void

        init(onChange: @escaping (NSAttributedString) -> Void) { self.onChange = onChange }

        /// Typing next to a mention or emoji shouldn't become part of it.
        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if view.typingAttributes[.slackMention] != nil { view.typingAttributes[.foregroundColor] = NSColor.textColor }
            for key in [NSAttributedString.Key.slackMention, .slackEmbed, .slackLine] { view.typingAttributes[key] = nil }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange(NSAttributedString(attributedString: view.attributedString()))
        }
    }
}

/// Quick Look preview of a file.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

/// A button in the popup's header: glass, with its key; the main action filled with the accent.
