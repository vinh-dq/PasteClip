import AppKit
import Combine
import PasteClipCore
import PasteClipSystem
import SwiftUI
import Translation

/// Shows the translation of a clip, the selected text or the clipboard in a small panel by the
/// pointer. It takes keys without taking focus from the app in front, so a translation can be
/// pasted straight back into it.
final class TranslationController {
    private let store: ClipStore
    private let settings: AppSettings
    private let keys: APIKeys
    private let model: TranslationModel
    private let panel = TranslationPanel()
    private let hosting: NSHostingView<TranslationView>
    private let toast = Toast()
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    /// The edge of the panel next to the pointer, which stays put as the content grows.
    private var anchor: CGFloat = 0
    private var opensUpward = false
    /// True while PasteClip itself places the panel, so only moves by the user are noticed.
    private var placing = false
    private var reading = false

    init(store: ClipStore, settings: AppSettings, keys: APIKeys) {
        self.store = store
        self.settings = settings
        self.keys = keys
        model = TranslationModel(settings: settings, keys: keys)
        hosting = NSHostingView(rootView: TranslationView(model: model, settings: settings, keys: keys))
        // Clipped to the glass's rounded corners, so nothing square shows behind them and the
        // window's shadow takes the same shape.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = TranslationView.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        hosting.rootView.onCopy = { [weak self] in self?.copy() }
        hosting.rootView.onPaste = { [weak self] in self?.paste() }
        hosting.rootView.onSave = { [weak self] in self?.save() }
        hosting.rootView.onDownload = { [weak self] source, target in self?.download(source, target) }
        // Once dragged, the panel stays where it was put, growing downwards from there.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, !self.placing else { return }
                self.opensUpward = false
                self.anchor = self.panel.frame.maxY
            }
            .store(in: &subscriptions)
        // Fit the panel to its content after each change has been laid out.
        model.objectWillChange.merge(with: keys.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fit() }
            .store(in: &subscriptions)
    }

    var isVisible: Bool { panel.isVisible }

    /// For the shortcut: the text selected in the front app, or else the clipboard.
    func translateSelectionOrClipboard() {
        guard !reading else { return }
        if panel.isVisible { return hide() }
        guard settings.translateSelection, Paster.isTrusted, !NSApp.isActive else { return translateClipboard() }
        let pasteboard = NSPasteboard.general
        let saved = Self.contents(of: pasteboard)
        let before = pasteboard.changeCount
        reading = true
        // The panel shows at once, translating, while the selection is copied.
        showWaiting()
        // The copy is only borrowed: it isn't saved, and the clipboard is put back afterwards.
        store.captureSuspended = true
        Paster.copyInFrontApp { [weak self] in
            self?.waitForCopy(since: before, until: Date().addingTimeInterval(0.3)) { copied in
                guard let self else { return }
                let text = copied ? pasteboard.string(forType: .string) : nil
                if copied { Self.restore(saved, to: pasteboard) }
                self.store.captureSuspended = false
                self.reading = false
                if let text, !Self.isBlank(text) { self.show(text) } else { self.translateClipboard() }
            }
        }
    }

    func show(_ text: String, target: String? = nil) {
        // Already up while the selection was read: it stays where it is.
        let placed = panel.isVisible
        model.start(text, target: target)
        if !placed { position() }
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        fit()
    }

    /// Puts the panel up, translating, before there's text. It isn't made key, so the ⌘C that
    /// copies the selection still goes to the app in front.
    private func showWaiting() {
        model.wait()
        position()
        panel.orderFrontRegardless()
    }

    private func position() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        // Below the pointer, or above it when there isn't room for the panel at its tallest.
        opensUpward = mouse.y - 16 - TranslationView.maxHeight < visible.minY
        anchor = opensUpward ? min(mouse.y + 16, visible.maxY - TranslationView.maxHeight - 8) : min(mouse.y - 16, visible.maxY - 8)
        let x = min(max(mouse.x - 24, visible.minX + 8), visible.maxX - size.width - 8)
        place(frame(x: x, size: size))
        panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        panel.alphaValue = 1
    }

    func hide() {
        removeMonitors()
        model.stop()
        panel.orderOut(nil)
    }

    private func translateClipboard() {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        if types.contains(.init("org.nspasteboard.ConcealedType")) {
            hide()
            return showToast("The clipboard holds a password", symbol: "lock.fill")
        }
        if !types.contains(.fileURL), let text = pasteboard.string(forType: .string), !Self.isBlank(text) {
            return show(text)
        }
        // An image on the clipboard: the text found in it.
        if let text = store.items.first?.translatableText, !Self.isBlank(text) { return show(text) }
        hide()
        showToast("Nothing to translate", symbol: "character.bubble")
    }

    private func showToast(_ message: String, symbol: String) {
        toast.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        toast.show(message, symbol: symbol)
    }

    private func waitForCopy(since changeCount: Int, until deadline: Date, _ completion: @escaping (Bool) -> Void) {
        if NSPasteboard.general.changeCount != changeCount { return completion(true) }
        if Date() > deadline { return completion(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForCopy(since: changeCount, until: deadline, completion)
        }
    }

    private static func contents(of pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    }

    private static func restore(_ contents: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = contents.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fit() {
        guard panel.isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size != panel.frame.size else { return }
        place(frame(x: panel.frame.minX, size: size))
    }

    private func place(_ frame: NSRect) {
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
        // The shadow follows what's drawn; recomputed once the new size is on screen.
        DispatchQueue.main.async { [panel] in panel.invalidateShadow() }
    }

    private func frame(x: CGFloat, size: NSSize) -> NSRect {
        NSRect(x: x, y: opensUpward ? anchor : anchor - size.height, width: size.width, height: size.height)
    }

    // MARK: - Actions

    private func copy() {
        guard let text = model.translation else { return NSSound.beep() }
        if settings.saveTranslations, let item = store.addText(text, source: "Translation") {
            store.copyToPasteboard(item)
        } else {
            store.copyWithoutSaving(text)
        }
    }

    private func paste() {
        guard model.translation != nil else { return NSSound.beep() }
        copy()
        hide()
        guard Paster.isTrusted else { return Paster.requestTrust() }
        Paster.pasteIntoFrontApp(after: 0.05)
    }

    private var downloader: NSWindow?

    /// Downloads Apple's languages in a window of its own: macOS asks there, where its prompt can
    /// take clicks. The panel stays open meanwhile and translates once the download is done.
    private func download(_ source: String, _ target: String) {
        // Asked already: macOS may still be downloading, and asking again makes its prompt flicker.
        // Its own list in System Settings shows the progress.
        if model.requestedDownload(from: source, to: target) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
            return
        }
        model.noteDownloadRequested(from: source, to: target)
        removeClickMonitor()
        downloader?.close()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Download Languages"
        window.isReleasedWhenClosed = false
        // Above the panel, which sits at status bar level.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        var ready = false
        window.contentView = NSHostingView(rootView: AppleLanguageDownload(source: source, target: target) { [weak window] done in
            ready = done
            window?.close()
        })
        // However the window closes (its close button too), the panel goes back to normal.
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let self else { return }
            self.downloader = nil
            guard self.panel.isVisible else { return }
            self.installClickMonitor()
            self.panel.makeKey()
            if ready { self.model.retry() }
        }
        window.center()
        downloader = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func save() {
        guard let text = model.translation else { return NSSound.beep() }
        if store.addText(text, source: "Translation") != nil { model.saved = true }
    }

    // MARK: - Keyboard

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
        installClickMonitor()
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    /// Key codes of 1…9 on the number row.
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.isEmpty, let n = Self.digitKeys.firstIndex(of: event.keyCode) {
            if settings.translationTargets.indices.contains(n) { model.choose(settings.translationTargets[n]) }
            return true
        }
        switch event.keyCode {
        case 53: hide(); return true                                   // Esc
        case 123 where flags.isEmpty: model.cycle(-1); return true     // ←
        case 124 where flags.isEmpty: model.cycle(1); return true      // →
        case 126 where flags.isEmpty: model.cycleService(-1); return true // ↑
        case 125 where flags.isEmpty: model.cycleService(1); return true  // ↓
        case 36, 76:                                                   // Return
            if flags.contains(.command) { paste() } else { copy(); hide() }
            return true
        default: break
        }
        guard flags == .command else { return false }
        switch key {
        case "c": copy(); hide(); return true
        case "s": save(); return true
        case "o": model.showsOriginal.toggle(); return true
        case "w": hide(); return true
        default: return false
        }
    }
}

/// A panel that can take keys without making PasteClip the active app.
private final class TranslationPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
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

// MARK: - Model

final class TranslationModel: ObservableObject {
    enum Phase: Equatable {
        case working
        case done(TranslationResult)
        /// What went wrong, and whether trying again could help (a network error) or not (a missing key).
        case failed(String, retryable: Bool = true)
        /// Apple could translate this once both languages are downloaded.
        case needsDownload(source: String, target: String)
    }

    @Published private(set) var text = ""
    @Published private(set) var target = Translator.defaultTargets[0]
    /// The language the text is in, once known.
    @Published private(set) var source: String?
    @Published private(set) var phase = Phase.working
    @Published var showsOriginal = true {
        didSet { if settings.translationShowsOriginal != showsOriginal { settings.translationShowsOriginal = showsOriginal } }
    }
    /// The text was longer than `Translator.maxLength` and only its start is translated.
    @Published private(set) var shortened = false
    @Published var saved = false
    /// Language pairs ("ja>vi") whose download was asked for in this session. Asking macOS again
    /// while it's still downloading makes its prompt flicker, so later asks show its progress instead.
    @Published private(set) var requestedDownloads: Set<String> = []
    /// Checks every few seconds whether the languages being waited for are downloaded yet.
    private var downloadWatch: Task<Void, Never>?
    /// Set when Apple's service should translate; the view hands it to `.translationTask`.
    @Published private(set) var appleConfiguration: TranslationSession.Configuration?

    let settings: AppSettings
    private let keys: APIKeys
    private var task: Task<Void, Never>?
    /// The target was picked by hand, so it's kept even if the text turns out to be in it.
    private var picked = false
    /// Counts runs, so a late answer for an earlier text or language is dropped.
    private var generation = 0
    private var cache: [String: TranslationResult] = [:]

    init(settings: AppSettings, keys: APIKeys) {
        self.settings = settings
        self.keys = keys
    }

    var service: TranslationService { settings.translationService }

    var translation: String? {
        if case .done(let result) = phase { return result.text }
        return nil
    }

    func start(_ text: String, target: String? = nil) {
        shortened = text.count > Translator.maxLength
        self.text = String(text.prefix(Translator.maxLength))
        showsOriginal = settings.translationShowsOriginal
        source = Translator.detectLanguage(self.text)
        picked = target != nil
        self.target = target ?? Translator.target(for: source, priority: settings.translationTargets)
        run()
    }

    /// Translating, before the text has arrived.
    func wait() {
        stop()
        text = ""
        source = nil
        phase = .working
    }

    func choose(_ target: String) {
        picked = true
        guard target != self.target || phase != .working else { return }
        self.target = target
        run()
    }

    func cycle(_ delta: Int) {
        let targets = settings.translationTargets
        guard !targets.isEmpty else { return }
        let i = targets.firstIndex(of: target) ?? 0
        choose(targets[(i + delta + targets.count) % targets.count])
    }

    /// Moves to the previous or next service that can be used now.
    func cycleService(_ delta: Int) {
        let services = keys.available
        guard services.count > 1 else { return }
        let i = services.firstIndex(of: service) ?? 0
        use(services[(i + delta + services.count) % services.count])
    }

    func use(_ service: TranslationService) {
        settings.translationService = service
        run()
    }

    func retry() {
        cache[cacheKey] = nil
        run()
    }

    func requestedDownload(from source: String, to target: String) -> Bool {
        requestedDownloads.contains("\(source)>\(target)")
    }

    func noteDownloadRequested(from source: String, to target: String) {
        requestedDownloads.insert("\(source)>\(target)")
    }

    func stop() {
        downloadWatch?.cancel()
        task?.cancel()
        generation += 1
        appleConfiguration = nil
    }

    private var cacheKey: String { "\(service.rawValue)|\(target)|\(text)" }

    private func run() {
        downloadWatch?.cancel()
        task?.cancel()
        generation += 1
        saved = false
        if let cached = cache[cacheKey] { return phase = .done(cached) }
        phase = .working
        if service == .apple { return runApple() }
        appleConfiguration = nil
        let key = keys.key(for: service)
        guard !service.needsKey || !key.isEmpty else {
            return phase = .failed("Add an API key for \(service.title) in Settings → Translation.", retryable: false)
        }
        let translator = WebTranslator(service: service, key: key, region: settings.microsoftRegion,
                                       model: settings.translationModels[service.rawValue] ?? "")
        let generation = generation, text = text, target = target
        task = Task { @MainActor [weak self] in
            do {
                let result = try await translator.translate(text, to: target)
                self?.finish(result, generation)
            } catch is CancellationError {
            } catch {
                self?.fail(error, generation)
            }
        }
    }

    /// Apple's service, only between languages already downloaded, and always told the language
    /// of the text: asked to work either out, Apple opens its own windows inside this panel, which
    /// can't take their clicks. A language that isn't downloaded gets PasteClip's own offer instead.
    private func runApple() {
        appleConfiguration = nil
        let target = target, generation = generation
        let likely = source == nil ? Translator.likelyLanguages(text) : []
        // The language found, or the likeliest one when unsure (a Vietnamese text full of English words).
        if let guess = source ?? likely.first, Translator.base(of: guess) == Translator.base(of: target) {
            // Into the next language, as with the other services, unless this one was picked.
            let next = Translator.target(for: guess, priority: settings.translationTargets)
            if !picked, Translator.base(of: next) != Translator.base(of: target) {
                self.target = next
                return run()
            }
            return phase = .failed("The text is already in \(Translator.name(of: target)). Pick another language above.",
                                   retryable: false)
        }
        // The language found for the text, or else the likeliest ones, however unsure.
        let candidates = (source.map { [$0] } ?? likely)
            .filter { Translator.base(of: $0) != Translator.base(of: target) }
        guard !candidates.isEmpty else {
            return phase = .failed("Apple can't tell which language this is. Try another service with ↑ or ↓.", retryable: false)
        }
        task = Task { @MainActor [weak self] in
            let availability = LanguageAvailability()
            var installed: String?
            var supported: String?
            for candidate in candidates {
                let status = await availability.status(from: Locale.Language(identifier: candidate),
                                                       to: Locale.Language(identifier: target))
                if status == .installed { installed = candidate; break }
                if status == .supported, supported == nil { supported = candidate }
            }
            guard let self, generation == self.generation else { return }
            guard let source = installed else {
                if let source = supported {
                    self.phase = .needsDownload(source: source, target: target)
                    return self.watchDownload(from: source, to: target, generation: generation)
                }
                return self.phase = .failed("Apple can't translate \(Translator.name(of: candidates[0])) into "
                                            + "\(Translator.name(of: target)). Try another service with ↑ or ↓.", retryable: false)
            }
            if #available(macOS 26.0, *), let session = await AppleSessions.shared.session(from: source, to: target) {
                guard generation == self.generation else { return }
                return await self.translate(with: session)
            }
            // Before macOS 26, through the view's task, with both languages given so there's nothing to ask.
            self.appleConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                       target: Locale.Language(identifier: target))
        }
    }

    /// Translates as soon as the languages are downloaded, however that happens: from the
    /// Download window, System Settings, or another app. Gives up after half an hour.
    private func watchDownload(from source: String, to target: String, generation: Int) {
        downloadWatch?.cancel()
        downloadWatch = Task { @MainActor [weak self] in
            let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
            for _ in 0..<900 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                if await LanguageAvailability().status(from: from, to: to) == .installed {
                    guard generation == self.generation else { return }
                    return self.retry()
                }
            }
        }
    }

    /// Translates with Apple's service, through a kept session or the view's translation task.
    @MainActor
    func translate(with session: TranslationSession) async {
        let generation = generation, text = text
        do {
            var parts: [String] = []
            var source: String?
            for chunk in Translator.chunks(of: text) {
                if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(chunk)
                    continue
                }
                let response = try await session.translate(chunk)
                parts.append(response.targetText)
                source = source ?? Translator.normalized(response.sourceLanguage.minimalIdentifier)
            }
            finish(TranslationResult(text: parts.joined(separator: "\n"), source: source), generation)
        } catch is CancellationError {
        } catch {
            fail(error, generation)
        }
    }

    private func finish(_ result: TranslationResult, _ generation: Int) {
        guard generation == self.generation else { return }
        if let found = result.source { source = found }
        // The text was already in this language: move on to the next one.
        if !picked, let found = result.source, Translator.base(of: found) == Translator.base(of: target) {
            let next = Translator.target(for: found, priority: settings.translationTargets)
            if next != target {
                target = next
                return run()
            }
        }
        cache[cacheKey] = result
        if cache.count > 50 { cache.removeAll() }
        phase = .done(result)
    }

    private func fail(_ error: Error, _ generation: Int) {
        guard generation == self.generation else { return }
        var message = error.localizedDescription
        if service == .apple, #available(macOS 26.0, *) {
            // A session that failed may stay broken; Try Again starts afresh.
            Task { @MainActor in AppleSessions.shared.removeAll() }
        }
        if service == .apple {
            message += " You can download languages in System Settings → General → Language & Region → Translation Languages."
        }
        phase = .failed(message)
    }
}

/// Apple translation sessions for language pairs that are downloaded, kept while PasteClip runs.
@available(macOS 26.0, *)
@MainActor
private final class AppleSessions {
    static let shared = AppleSessions()
    private var sessions: [String: TranslationSession] = [:]

    /// A session from `source` to `target`, or nil if the pair isn't downloaded.
    func session(from source: String, to target: String) async -> TranslationSession? {
        let key = "\(source)>\(target)"
        if let session = sessions[key] { return session }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return nil }
        let session = TranslationSession(installedSource: from, target: to)
        sessions[key] = session
        return session
    }

    func removeAll() {
        sessions.removeAll()
    }
}

/// Moves its window when dragged, for a panel without a title bar.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Asks macOS to download two languages for Apple's translation, in an ordinary window where
/// its prompt works, then reports whether they're ready.
private struct AppleLanguageDownload: View {
    let source: String
    let target: String
    let finish: (Bool) -> Void
    @StateObject private var configuration = ViewState<TranslationSession.Configuration?>(nil)
    @StateObject private var error = ViewState<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download \(Translator.name(of: source)) and \(Translator.name(of: target))").font(.headline)
                    Text("Apple translates on this Mac once both languages are downloaded. Choose Download when macOS asks; "
                         + "it can take a few minutes, and the translation appears when it's done.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = error.value {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Translation Languages…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
                Spacer()
                Button("Close") { finish(false) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .translationTask(configuration.value) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { finish(true) }
            } catch {
                await MainActor.run { self.error.value = error.localizedDescription }
            }
        }
        .onAppear {
            configuration.value = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                   target: Locale.Language(identifier: target))
        }
    }
}

// MARK: - View

struct TranslationView: View {
    static let width: CGFloat = 552
    static let cornerRadius: CGFloat = 16
    /// The tallest the translation and the original get; longer text scrolls inside them.
    static let maxTranslationHeight: CGFloat = 240
    static let maxOriginalHeight: CGFloat = 130
    /// The tallest the panel gets.
    static let maxHeight: CGFloat = 520

    @ObservedObject var model: TranslationModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var keys: APIKeys
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onSave: () -> Void = {}
    var onDownload: (String, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            languages
            content
            if model.showsOriginal, !model.text.isEmpty {
                Divider()
                Self.fitting(maxHeight: Self.maxOriginalHeight) {
                    Text(model.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        // Empty space anywhere in the panel moves it, and the grip at the top shows that it can be moved.
        .overlay(alignment: .top) {
            ZStack {
                WindowDragArea()
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 4).allowsHitTesting(false)
            }
            .frame(height: 12)
            .help("Drag to move")
        }
        .background(WindowDragArea())
        .background(GlassBackground(cornerRadius: Self.cornerRadius))
        .translationTask(model.appleConfiguration) { session in
            await model.translate(with: session)
        }
    }

    /// The target languages, numbered for the keys that pick them.
    private var languages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(settings.translationTargets.enumerated()), id: \.element) { i, language in
                    Button { model.choose(language) } label: {
                        HStack(spacing: 5) {
                            if i < 9 { Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                            Text(Translator.name(of: language)).font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                        .glassCapsule(selected: language == model.target)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        case .done(let result):
            VStack(alignment: .leading, spacing: 6) {
                Self.fitting(maxHeight: Self.maxTranslationHeight) { translation(result.text) }
                if model.shortened {
                    Text("Only the first \(Translator.maxLength.formatted()) characters were translated.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Only where another go could turn out differently.
                if retryable { Button("Try Again") { model.retry() } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .needsDownload(let source, let target):
            VStack(alignment: .leading, spacing: 10) {
                Label("To translate \(Translator.name(of: source)) into \(Translator.name(of: target)) on this Mac, "
                      + "Apple needs both languages downloaded.", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(model.requestedDownload(from: source, to: target) ? "Download Progress…" : "Download…") {
                        onDownload(source, target)
                    }
                    Button("Use Google Translate") { model.use(.google) }
                }
                if model.requestedDownload(from: source, to: target) {
                    Text("The translation appears here as soon as the download is done.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `content` at its own height when it fits in `maxHeight`, so short text gives a short panel;
    /// past that, it stays `maxHeight` tall and scrolls.
    private static func fitting<Content: View>(maxHeight: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        let content = content()
        return ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func translation(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(keys.available) { service in
                    Toggle(service.title, isOn: Binding(get: { model.service == service }, set: { if $0 { model.use(service) } }))
                }
            } label: {
                Text(sourceLine).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("Translation service (↑ ↓)")
            Spacer(minLength: 4)
            Button { model.showsOriginal.toggle() } label: {
                Image(systemName: model.showsOriginal ? "text.badge.minus" : "text.quote")
            }
            .help(model.showsOriginal ? "Hide original (⌘O)" : "Show original (⌘O)")
            Button(action: onSave) { Image(systemName: model.saved ? "checkmark" : "tray.and.arrow.down") }
                .help("Save to history (⌘S)")
            Group {
                Button("Copy", action: onCopy).help("Copy (Return)")
                Button("Paste", action: onPaste).help("Paste into the app (⌘Return)")
            }
            .buttonStyle(.bordered)
            .disabled(model.translation == nil)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// "English → Vietnamese · Google Translate".
    private var sourceLine: String {
        let from = model.source.map(Translator.name(of:)) ?? "Detected"
        let service = model.service == .apple ? "Apple" : model.service.title
        return "\(from) → \(Translator.name(of: model.target)) · \(service)"
    }
}
