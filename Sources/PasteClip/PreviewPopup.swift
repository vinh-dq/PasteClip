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

    init(state: ShelfState, store: ClipStore) {
        self.store = store
        panel.contentView = HostingView(rootView: PreviewPopup(state: state, selection: state.selectionModel,
                                                                 store: store, geometry: geometry))
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

    /// Header, footer, arrow and the padding around an image.
    private static let chrome = CGSize(width: 20, height: 42 + 32 + arrowHeight + 20)
    private static let minWidth: CGFloat = 460

    /// Full width for text and documents; for pictures, just wide enough to show the whole
    /// image at the popup's height (or at its own size when smaller), so there are no wide margins.
    private func size(for item: ClipItem, on screen: NSScreen) -> NSSize {
        let bounds = screen.visibleFrame
        let full = NSSize(width: min(980, bounds.width - 40), height: min(430, bounds.height * 0.55))
        if item.kind == .text { return textSize(for: item, max: full) }
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
    @ObservedObject var geometry: PopupGeometry

    var body: some View {
        VStack(spacing: 0) {
            if !geometry.pointsDown { arrow.rotationEffect(.degrees(180)) }
            Group {
                // Built only while shown: a hidden popup would otherwise rebuild on every move.
                if state.previewing, let item = state.selectedItem {
                    PreviewCard(item: item, state: state, store: store)
                        .id(item.id)
                } else {
                    Color.clear
                }
            }
            .background(VisualEffect(material: .popover))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.15)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            if geometry.pointsDown { arrow }
        }
    }

    private var arrow: some View {
        GeometryReader { g in
            VisualEffect(material: .popover)
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

    private enum Field { case title, body }
    @FocusState private var focus: Field?
    @StateObject private var titleDraft = ViewState("")
    @StateObject private var textDraft = ViewState("")
    /// The edited formatted text, set once it changes. Not published: only saving reads it.
    @StateObject private var richDraft = RichDraft()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
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
            if field != .title { commitTitle() }
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
        HStack(spacing: 10) {
            Button { state.closePreview() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Space)")

            Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
            TextField(item.kind.label, text: $titleDraft.value)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused($focus, equals: .title)
                .onSubmit { commitTitle(); focus = nil }
                .help("Click to name this clip")

            Spacer()

            if state.editing {
                Button("Cancel") { state.editing = false }
                Button("Save") {
                    saveText()
                    state.editing = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            } else {
                Button { store.copyToPasteboard(item) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy")
                if item.kind == .link, let url = URL(string: item.text ?? "") {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                        .help("Open in Browser")
                }
                if item.kind == .file, let path = item.filePaths?.first {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show in Finder")
                }
                if item.isTextual {
                    Button("Edit") { state.editing = true }
                        .help("Edit text (⌘E)")
                }
                Button("Paste") { state.onPaste(item, false) }
                    .buttonStyle(.borderedProminent)
                    .help("Paste (Return)")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 42)
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
                .background(Color(nsColor: .textBackgroundColor))
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
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        case .link:
            linkContent
        case .image:
            if let image = store.image(for: item) { picture(image) }
        case .file:
            if let path = item.filePaths?.first {
                // Image files are drawn like copied images, sized to the popup with no extra margins.
                if FileThumbnails.pixelSize(of: path) != nil, let image = Self.fileImage(at: path) {
                    picture(image)
                } else {
                    QuickLookView(url: URL(fileURLWithPath: path))
                }
            }
        case .color:
            ColorSwatch(hex: item.text ?? "").padding(20)
        }
    }

    private var plainEditor: some View {
        TextEditor(text: $textDraft.value)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(10)
            .focused($focus, equals: .body)
            .background(Color(nsColor: .textBackgroundColor))
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Checkerboard())
    }

    @ViewBuilder
    private var linkContent: some View {
        let preview = LinkPreviews.shared.preview(for: item.text ?? "")
        HStack(alignment: .top, spacing: 18) {
            if let image = preview?.image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                if let title = preview?.title {
                    Text(title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                }
                Text(item.text ?? "").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
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
        // A clip synced from another Mac rewrites its file under the same name, so key on the text too.
        let key = "\(file)|\(item.contentKey.hashValue)" as NSString
        if let cached = richCache.object(forKey: key) { return cached }
        guard let text = store.formattedText(for: item) else { return nil }
        richCache.setObject(text, forKey: key)
        return text
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
            if let app = item.sourceName { Text("From \(app)") }
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
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
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
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
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = true
        view.isRichText = true
        view.allowsUndo = true
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
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
