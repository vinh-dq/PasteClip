import AppKit
import Combine
import PasteClipCore
import PasteClipSystem
import ScriptingBridge
import SwiftUI

/// Images floated above every window, for keeping something in view while you work. Scrolling
/// over one makes it clearer or fainter; pinching or ⌘-scrolling zooms; T shows it translated.
/// They aren't kept when PasteClip quits.
final class FloatingImages {
    private let store: ClipStore
    private let settings: AppSettings
    private let translator: ImageTranslator
    private var windows: [FloatingImageWindow] = []
    /// Watches the pointer while an image is locked, which gets no mouse events then, so its
    /// strip still shows (with the button that unlocks it) when the pointer is over it.
    private var lockTimer: Timer?
    /// macOS sends a pinch to the app in front, not to the window under the pointer, so a
    /// floating image (PasteClip stays in the background) never gets it. This tap sees every
    /// pinch while images float, zooms the one under the pointer, and keeps the pinch from the
    /// app behind. Without Accessibility permission it can only watch, not keep it.
    /// The same tap gives keys to the image under the pointer, so T, ← → and the rest work
    /// without clicking it first, while the app in front keeps its focus: from when the pointer
    /// comes onto an image, until a key the image doesn't take. Typing on in another app with
    /// the pointer resting on an image is left alone, as the pointer got there before the typing.
    private var pinchTap: CFMachPort?
    private var pinchSource: CFRunLoopSource?
    /// When the last key went to another app.
    private var keyElsewhere = Date.distantPast
    /// The image that was clicked last, if no click has been anywhere else since. Only it takes
    /// ⌘C from the keyboard: with the pointer merely resting on an image, ⌘C is for the app in
    /// front (the text selected behind a floating image), not for the image.
    private weak var clicked: FloatingImageWindow?
    private var clickMonitor: Any?
    /// Space held down over an image, which gets its release too, wherever the pointer is then.
    private weak var spaceHeldBy: FloatingImageWindow?
    var onEdit: (ClipItem) -> Void = { _ in }

    init(store: ClipStore, settings: AppSettings, keys: APIKeys) {
        self.store = store
        self.settings = settings
        translator = ImageTranslator(settings: settings, keys: keys)
    }

    var count: Int { windows.count }
    var hasLocked: Bool { windows.contains { $0.state.locked } }

    /// Floats an image clip, translated straight away if `translate` (into `target`, or the
    /// first language in Settings it isn't in). A screenshot taken by PasteClip floats over the
    /// spot it was taken from, others by the pointer.
    func show(_ item: ClipItem, translate: Bool = false, target: String? = nil) {
        guard let url = store.pictureURL(for: item), let image = item.kind == .image ? store.image(for: item) : NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return NSSound.beep() }
        let window = open(cgImage, item: item, placement: item.screenFrame.flatMap { Self.placement(of: cgImage, at: $0) })
        if translate { self.translate(window, to: target) }
    }

    /// Floats a screenshot of an area exactly over that area (`placement`, on screen), and
    /// translates it, so the translation reads in place of the text there.
    func showTranslated(_ image: CGImage, over placement: NSRect?) {
        translate(open(image, item: nil, placement: placement), to: nil)
    }

    /// `frame` on screen, sized exactly as `image` shows there, when the image is that size
    /// (within a few points) on the screen holding it; nil otherwise, or when no screen shows
    /// that spot any more.
    static func placement(of image: CGImage, at frame: CGRect) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })
        else { return nil }
        let scale = screen.backingScaleFactor
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard abs(frame.width - size.width) <= 3, abs(frame.height - size.height) <= 3 else { return nil }
        return NSRect(origin: frame.origin, size: size)
    }

    private func open(_ image: CGImage, item: ClipItem?, placement: NSRect?) -> FloatingImageWindow {
        let window = FloatingImageWindow(item: item, image: image, cascade: windows.count, placement: placement)
        window.panel.sharingType = settings.hideDuringScreenSharing ? .none : .readOnly
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
            self?.watchPinches()
        }
        window.onEdit = { [weak self, weak window] in
            guard let self, let window else { return }
            // What's on screen: the translation, kept as a clip, or the image floated.
            if let clip = window.shownClip.flatMap({ self.store.item(withID: $0.id) }) { return self.onEdit(clip) }
            // A translation not saved (Settings) is saved now: the editor works on clips.
            if window.state.showsTranslation, let image = window.translated, let target = window.state.language,
               let clip = self.save(image, of: window, in: target) {
                window.translatedClip = clip
                return self.onEdit(clip)
            }
            NSSound.beep()
        }
        window.panel.onClick = { [weak self, weak window] in self?.clicked = window }
        window.onCopy = { [weak self, weak window] in
            guard let self, let window else { return }
            self.copy(window.shownClip, image: window.shownImage)
        }
        // The text read in one part of the image, as text copied from the screen is: a clip
        // from "Screen Text".
        window.recognitionLanguages = { [weak self] in self?.store.recognitionLanguages ?? TextRecognizer.defaultLanguages }
        window.startReading()
        window.onCopyText = { [weak self] text in
            guard let self else { return }
            if let item = self.store.addText(text, source: "Screen Text") {
                self.store.copyToPasteboard(item)
            } else {
                self.store.copyWithoutSaving(text)
            }
        }
        window.onTranslate = { [weak self, weak window] target in
            guard let self, let window else { return }
            self.translate(window, to: target)
        }
        window.onGoogle = { [weak self, weak window] target in
            guard let self, let window else { return }
            self.openInGoogleTranslate(window, into: target)
        }
        window.onLockChange = { [weak self] in self?.watchLocks() }
        window.translationTargets = { [settings] in settings.translationTargets }
        windows.append(window)
        window.show()
        watchPinches()
        return window
    }

    /// Translates what a floating image shows and saves the translated image as a new clip. A
    /// clip saved for an earlier language of the same image is replaced, unless it's been kept.
    /// The text is read once per image, and each language translated once.
    private func translate(_ window: FloatingImageWindow, to target: String?) {
        let generation = window.beginTranslating()
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                let reading: ImageTranslator.Reading
                if let read = window.reading {
                    reading = read
                } else {
                    reading = try await self.translator.read(window.original)
                    window.reading = reading
                }
                let target = target ?? self.translator.defaultTarget(for: reading)
                let image: CGImage
                let spots: [ImageTranslation.Spot]
                var problem: String?
                if let done = window.translations[target] {
                    (image, spots) = done
                } else {
                    (image, spots, problem) = try await self.translator.translate(window.original, reading: reading, to: target)
                    // Kept only when all of it went, so a language that failed is tried again next time.
                    if problem == nil { window.translations[target] = (image, spots) }
                }
                guard window.isCurrent(generation) else { return }
                // The clip saved for another language is replaced; one saved by editing it, with
                // saving turned off, was asked for and stays.
                if self.settings.saveImageTranslations,
                   let old = window.translatedClip.flatMap({ self.store.item(withID: $0.id) }), !old.isKept {
                    self.store.delete(old)
                }
                let clip = self.settings.saveImageTranslations ? self.save(image, of: window, in: target) : nil
                window.showTranslation(image, spots: spots, clip: clip, target: target, problem: problem)
            } catch {
                guard window.isCurrent(generation) else { return }
                window.translationFailed(error.localizedDescription)
            }
        }
    }

    private func watchPinches() {
        // Clicks in other apps (or on the desktop) end the image's claim on ⌘C. Clicks on the
        // images themselves never reach a global monitor.
        if windows.isEmpty {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            clicked = nil
        } else if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.clicked = nil
            }
        }
        if windows.isEmpty {
            if let pinchTap {
                CGEvent.tapEnable(tap: pinchTap, enable: false)
                CFMachPortInvalidate(pinchTap)
            }
            if let pinchSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), pinchSource, .commonModes) }
            pinchTap = nil
            pinchSource = nil
            return
        }
        guard pinchTap == nil else { return }
        // Trackpad gestures arrive as CGEvent type 29; AppKit turns pinches among them into .magnify.
        // Keys only with Accessibility, which handling them needs: listening to them without it
        // would have macOS ask for Input Monitoring as well.
        var gesture = CGEventMask(1) << 29
        if Paster.isTrusted {
            gesture |= CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: Paster.isTrusted ? .defaultTap : .listenOnly,
                                          eventsOfInterest: gesture, callback: { _, type, event, owner in
            guard let owner else { return Unmanaged.passUnretained(event) }
            let images = Unmanaged<FloatingImages>.fromOpaque(owner).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = images.pinchTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown || type == .keyUp { return images.key(event) ? nil : Unmanaged.passUnretained(event) }
            return images.pinch(event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pinchTap = tap
        pinchSource = source
    }

    /// Zooms the floating image under the pointer for a pinch; false for any other gesture, or
    /// one that isn't over an image, which then goes on as usual.
    private func pinch(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.type == .magnify else { return false }
        let mouse = NSEvent.mouseLocation
        guard let window = windows.last(where: { !$0.state.locked && $0.panel.frame.contains(mouse) }) else { return false }
        window.setZoom(window.state.zoom * (1 + ns.magnification), around: mouse)
        return true
    }

    /// A key for the image under the pointer, as above; false lets it go on to the app in front.
    private func key(_ event: CGEvent) -> Bool {
        guard Paster.isTrusted, let ns = NSEvent(cgEvent: event) else { return false }
        if ns.type == .keyUp, ns.keyCode == 49, let window = spaceHeldBy {
            spaceHeldBy = nil
            return window.handle(ns)
        }
        guard let window = windows.last(where: { $0.pointerOver && !$0.state.locked }),
              window.pointerArrived > keyElsewhere else {
            if ns.type == .keyDown { keyElsewhere = Date() }
            return false
        }
        // ⌘C copies the image only once it has been clicked; before that it is the front app's.
        if ns.type == .keyDown, ns.keyCode == 8, ns.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           clicked !== window {
            return false
        }
        guard window.handle(ns) else {
            if ns.type == .keyDown { keyElsewhere = Date() }
            return false
        }
        if ns.type == .keyDown, ns.keyCode == 49 { spaceHeldBy = window }
        return true
    }

    func closeAll() { windows.forEach { $0.close() } }

    func unlockAll() { windows.forEach { $0.setLocked(false) } }

    /// Google Translate's web page translates images well too, but has no API for it. The
    /// original image goes on the clipboard (not into history), the page's Images tab opens, and
    /// once the page has loaded, ⌘V pastes it there, again until the page shows it. The floating
    /// image closes, out of the way of the page and of the ⌘V.
    private func openInGoogleTranslate(_ window: FloatingImageWindow, into target: String) {
        let code = Translator.code(for: target, in: .google)
        guard let png = MarkupRenderer.pngData(window.original),
              let url = URL(string: "https://translate.google.com/?sl=auto&tl=\(code)&op=images") else { return NSSound.beep() }
        store.copyImageWithoutSaving(png)
        let browser = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard Paster.isTrusted, let browser else {
            NSWorkspace.shared.open(url)
            return window.flash("Copied · press ⌘V on the Google Translate page")
        }
        window.close()
        Self.reuseTab(in: browser, for: url) { [weak self] reused in
            if !reused { NSWorkspace.shared.open(url) }
            self?.paste(into: browser, reloading: reused)
        }
    }

    /// Brings up a Google Translate tab already open in `browser`, loading `url` in it, and
    /// says whether there was one. Tabs are only told apart by their addresses, which only the
    /// browser's scripting gives (macOS asks once to let PasteClip control the browser; without
    /// that, or in a browser it doesn't know, a new tab opens as before). Each copy of the
    /// browser running is asked: another one (started by some tool) may have no windows.
    private static func reuseTab(in browser: String, for url: URL, done: @escaping (Bool) -> Void) {
        let chromium = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi"]
        guard chromium.contains(browser) || browser == "com.apple.Safari" else { return done(false) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: browser)
        // Off the main thread: macOS's question about controlling the browser waits for an answer.
        DispatchQueue.global(qos: .userInitiated).async {
            let found = running.first { app in
                guard let scripting = SBApplication(processIdentifier: app.processIdentifier) else { return false }
                return Self.showTranslateTab(in: scripting, safari: browser == "com.apple.Safari", url: url)
            }
            DispatchQueue.main.async {
                found?.activate()
                done(found != nil)
            }
        }
    }

    private static func showTranslateTab(in browser: SBApplication, safari: Bool, url: URL) -> Bool {
        guard let windows = browser.value(forKey: "windows") as? SBElementArray else { return false }
        for case let window as SBObject in windows {
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            for (i, element) in tabs.enumerated() {
                guard let tab = element as? SBObject,
                      (tab.value(forKey: "URL") as? String)?.hasPrefix("https://translate.google.") == true else { continue }
                tab.setValue(url.absoluteString, forKey: "URL")
                if safari { window.setValue(tab, forKey: "currentTab") } else { window.setValue(i + 1, forKey: "activeTabIndex") }
                window.setValue(1, forKey: "index")
                return true
            }
        }
        return false
    }

    /// Pastes the image on the clipboard into the Google Translate page once it's ready, as
    /// below. `reloading`: a tab reused, which shows its earlier page until the new one starts.
    private func paste(into browser: String, reloading: Bool) {
        let changeCount = NSPasteboard.general.changeCount
        let deadline = Date().addingTimeInterval(20)
        // The page's address and loading state come from Accessibility (a window title won't do:
        // Chrome's always has "Google Chrome" in it). The page's scripts, which take the paste,
        // may start a little after it has loaded, so a paste that leaves the page as it was is
        // tried again. The page changes at once when it takes an image, long before the
        // translation is in; pasting again then would only start that over. A slow start (the
        // browser restoring its tabs, a slow network) just waits longer.
        var exposed = false
        var sawLoading = !reloading
        var inFront: Date?
        var loaded: (at: Date, url: URL?)?
        var pasted: (at: Date, elements: Int)?
        var tries = 0
        func step() {
            guard Date() < deadline, NSPasteboard.general.changeCount == changeCount else { return }
            let next = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: step) }
            guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == browser else { return next() }
            if !exposed { Paster.exposePages(of: front); exposed = true }
            inFront = inFront ?? Date()
            let waited = Date().timeIntervalSince(inFront!)
            guard let page = Paster.frontPage(of: front) else {
                // A browser that doesn't show its pages: paste once, after a while.
                guard waited > 3 else { return next() }
                return Paster.pasteIntoFrontApp()
            }
            guard page.loaded, page.url?.host?.hasPrefix("translate.google.") == true else {
                sawLoading = true
                loaded = nil
                return next()
            }
            // A reused tab: not the page it showed before, still there for a moment.
            guard sawLoading || waited > 3 else { return next() }
            // Another tab came to the front: start over there.
            if loaded?.url != page.url { (loaded, pasted) = ((Date(), page.url), nil) }
            guard Date().timeIntervalSince(loaded!.at) > 0.4 else { return next() }
            if let pasted {
                if page.elements != pasted.elements { return } // In.
                guard Date().timeIntervalSince(pasted.at) > 1.5 else { return next() }
            }
            guard tries < 4 else { return }
            tries += 1
            pasted = (Date(), page.elements)
            self.windows.forEach { $0.panel.giveUpKey() }
            Paster.pasteIntoFrontApp()
            next()
        }
        step()
    }

    /// Adds a translated image to history, named after the clip it came from and the language.
    private func save(_ image: CGImage, of window: FloatingImageWindow, in target: String) -> ClipItem? {
        guard let png = MarkupRenderer.pngData(image) else { return nil }
        let name = Translator.name(of: target)
        return store.addImage(png, title: window.item?.title.map { "\($0) · \(name)" } ?? "\(name) translation",
                              source: "Translation", screenFrame: window.placement)
    }

    private func copy(_ item: ClipItem?, image: CGImage) {
        if let current = item.flatMap({ store.item(withID: $0.id) }) { return store.copyToPasteboard(current) }
        // The clip was deleted, or there never was one; the image is still on screen.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    private func watchLocks() {
        guard hasLocked else {
            lockTimer?.invalidate()
            lockTimer = nil
            return
        }
        guard lockTimer == nil else { return }
        lockTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            let mouse = NSEvent.mouseLocation
            for window in self?.windows ?? [] where window.state.locked {
                let inside = window.panel.frame.contains(mouse)
                if window.state.hovering != inside { window.state.hovering = inside }
            }
        }
    }
}

final class FloatingImageState: ObservableObject {
    @Published var opacity: CGFloat = 1
    /// Size compared with the image's own size on screen.
    @Published var zoom: CGFloat = 1
    /// The pointer is over the image.
    @Published var hovering = false
    /// The pointer is over the strip of controls.
    @Published var stripHovering = false
    /// Clicks go through to the windows behind.
    @Published var locked = false
    /// Shows the opacity and zoom for a moment after they change.
    @Published var flashing = false
    @Published var message: String?
    /// Stays up until it's cleared: "Translating…".
    @Published var status: String?
    /// The translation is showing rather than the image as it was.
    @Published var showsTranslation = false
    /// The language of the translation, once there is one.
    @Published var language: String?
    /// The image is narrower than the full strip: the readouts shrink to the zoom alone, so the
    /// strip is about as wide as the image instead of sticking out on both sides.
    @Published var compactStrip = false

    /// The strip shows: while the pointer is over the image or the strip (locked or not), or to say something.
    var showsStrip: Bool { hovering || stripHovering || flashing || status != nil }
}

final class FloatingImagePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    private var refusesKey = false
    override var canBecomeKey: Bool { !refusesKey }

    /// Lets keys go to the app in front again. A panel that doesn't activate PasteClip stays key
    /// when another app comes to the front, and would take keys sent to that app (a ⌘V meant
    /// for a browser, say); it's key again once clicked.
    func giveUpKey() {
        guard isKeyWindow else { return }
        refusesKey = true
        orderOut(nil)
        orderFrontRegardless()
        refusesKey = false
    }

    /// Keys for the image, whichever view has the focus (a clicked button can take it).
    var onKey: ((NSEvent) -> Bool)?

    /// A click in the image.
    var onClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown { onClick?() }
        if event.type == .keyDown || event.type == .keyUp, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

final class FloatingImageWindow {
    let panel = FloatingImagePanel()
    let state = FloatingImageState()
    /// The clip floated; nil for a screenshot taken to be translated.
    let item: ClipItem?
    let original: CGImage
    private(set) var translated: CGImage?
    /// The translated image, saved as a clip (unless Settings says not to, until it's edited).
    var translatedClip: ClipItem?
    /// Counts translations asked for, so only the latest one shows.
    private var generation = 0
    /// The text found in the image, once read.
    var reading: ImageTranslator.Reading?
    /// Translations already drawn, by language, with where each part went.
    var translations: [String: (image: CGImage, spots: [ImageTranslation.Spot])] = [:]
    /// The pointer is over the image or its strip.
    var pointerOver: Bool { state.hovering || state.stripHovering }
    /// When the pointer last came onto the image or its strip.
    private(set) var pointerArrived = Date.distantPast
    /// Where on screen the image was taken from, when it floats over that spot.
    let placement: NSRect?
    /// The language last asked for or shown, which ← → step from.
    private var chosenLanguage: String?
    /// The image's size on screen at 100%: its pixels on a Retina display.
    private let baseSize: CGSize
    private let content: FloatingImageView
    private var strip: FloatStripPanel!
    private var halo: GlowHalo?
    private var stripHalo: GlowHalo?
    private let stripTone = GlowTone()
    private var subscriptions = Set<AnyCancellable>()
    /// Hides the strip a moment after the pointer leaves, so it can cross from image to strip.
    private var hideStrip: DispatchWorkItem?
    private var flashTimer: Timer?
    /// Where each part of the translation showing went, with its original.
    private(set) var spots: [ImageTranslation.Spot] = []
    /// The original of the part under the pointer, in a bubble of its own beside the image.
    private var tip: FloatTipPanel?
    private var tipTimer: Timer?
    var onClose: () -> Void = {}
    var onEdit: () -> Void = {}
    var onCopy: () -> Void = {}
    /// Copies the text read in one part of the image.
    var onCopyText: (String) -> Void = { _ in }
    /// The languages text is read in (Settings → Text Recognition).
    var recognitionLanguages: () -> [String] = { TextRecognizer.defaultLanguages }
    /// Opens Google Translate's Images page for the original image, into a language.
    var onGoogle: (String) -> Void = { _ in }
    /// Asks for a translation into a language, or the first one the text isn't in.
    var onTranslate: (String?) -> Void = { _ in }
    var onLockChange: () -> Void = {}
    /// The languages to translate into, in the order of Settings.
    var translationTargets: () -> [String] = { [] }

    /// `placement` puts it exactly there (on screen) instead of by the pointer.
    init(item: ClipItem?, image: CGImage, cascade: Int, placement: NSRect? = nil) {
        self.item = item
        self.placement = placement
        original = image
        let point = placement.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main!
        let scale = screen.backingScaleFactor
        baseSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        content = FloatingImageView(image: image, state: state, cornerRadius: 10)
        content.window_ = self
        panel.contentView = content
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        setUpStrip()
        if let placement {
            state.zoom = placement.width / baseSize.width
            panel.setFrame(placement, display: false)
            return
        }

        // As large as the image, up to most of the screen, centred on the pointer.
        let visible = screen.visibleFrame
        state.zoom = min(1, visible.width * 0.6 / baseSize.width, visible.height * 0.6 / baseSize.height)
        let size = self.size(at: state.zoom)
        let mouse = NSEvent.mouseLocation
        let offset = CGFloat(cascade % 8) * 24
        var frame = NSRect(x: mouse.x - size.width / 2 + offset, y: mouse.y - size.height / 2 - offset,
                           width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    // MARK: Strip

    private func setUpStrip() {
        var view = FloatStrip(state: state,
                              close: { [weak self] in self?.close() },
                              zoom: { [weak self] factor in
                                  guard let self else { return }
                                  self.setZoom(self.state.zoom * factor, animate: true)
                              },
                              translate: { [weak self] in self?.toggleTranslation() },
                              google: { [weak self] in self?.openInGoogleTranslate() },
                              edit: { [weak self] in self?.onEdit() },
                              copy: { [weak self] in
                                  self?.onCopy()
                                  self?.flash("Copied")
                              },
                              lock: { [weak self] in
                                  guard let self else { return }
                                  self.setLocked(!self.state.locked)
                              })
        view.tone = stripTone
        strip = FloatStripPanel(strip: view)
        strip.hosting.onHover = { [weak self] inside in self?.state.stripHovering = inside }
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStrip() }
            .store(in: &subscriptions)
        state.$hovering.combineLatest(state.$stripHovering)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] over in if over { self?.pointerArrived = Date() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel))
            .sink { [weak self] _ in self?.placeStrip() }
            .store(in: &subscriptions)
    }

    /// Under the image, or above it when there's no room below; centred, on screen.
    private func placeStrip() {
        let compact = panel.frame.width < 480
        if state.compactStrip != compact { state.compactStrip = compact }
        strip.hosting.layoutSubtreeIfNeeded()
        let size = strip.hosting.fittingSize
        let image = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? image
        let gap: CGFloat = 8
        var y = image.minY - gap - size.height
        if y < visible.minY { y = min(image.maxY + gap, visible.maxY - size.height) }
        // Neither below nor above (an image filling the screen): along its bottom edge, inside.
        if y + size.height > image.minY, y < image.maxY, image.minY - gap - size.height < visible.minY,
           image.maxY + gap + size.height > visible.maxY {
            y = max(image.minY, visible.minY) + gap
        }
        let x = min(max(image.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        strip.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    private func updateStrip() {
        let visible = state.showsStrip
        if visible {
            hideStrip?.cancel()
            hideStrip = nil
            placeStrip()
            setStrip(visible: true)
        } else if hideStrip == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideStrip = nil
                if !self.state.showsStrip { self.setStrip(visible: false) }
            }
            hideStrip = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func setStrip(visible: Bool) {
        strip.ignoresMouseEvents = !visible
        let alpha: CGFloat = visible ? 1 : 0
        guard strip.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.25
            strip.animator().alphaValue = alpha
        }
    }

    func show() {
        panel.alphaValue = 0
        strip.sharingType = panel.sharingType
        panel.addChildWindow(strip, ordered: .above)
        placeStrip()
        panel.orderFrontRegardless()
        // A soft light around it, so it doesn't sink into what's behind it.
        halo = GlowHalo(around: panel, kind: .picture, cornerRadius: 10)
        halo?.intensity = state.opacity
        stripHalo = GlowHalo(around: strip, kind: .panel, cornerRadius: 15, tone: stripTone)
        panel.makeKey()
        panel.makeFirstResponder(content)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        flash()
    }

    /// Starts reading the picture's text, so it can be selected.
    func startReading() { content.beginReading(languages: recognitionLanguages()) }

    func close() {
        flashTimer?.invalidate()
        content.stopAnalysing()
        hover(nil)
        if let tip { panel.removeChildWindow(tip); tip.orderOut(nil) }
        hideStrip?.cancel()
        subscriptions.removeAll()
        panel.removeChildWindow(strip)
        strip.orderOut(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel, self] in
            panel.orderOut(nil)
            halo = nil
            stripHalo = nil
        })
        onClose()
        if state.locked { state.locked = false; onLockChange() }
    }

    // MARK: Size and opacity

    private func size(at zoom: CGFloat) -> CGSize {
        CGSize(width: (baseSize.width * zoom).rounded(), height: (baseSize.height * zoom).rounded())
    }

    /// Zooms around `anchor` (a point on screen), which stays where it is; the middle if nil.
    func setZoom(_ zoom: CGFloat, around anchor: NSPoint? = nil, animate: Bool = false) {
        // Never smaller than 48 points on its shorter side, nor larger than 8 times.
        let smallest = 48 / min(baseSize.width, baseSize.height)
        let zoom = min(max(zoom, min(smallest, 1)), 8)
        guard zoom != state.zoom else { return }
        let old = panel.frame
        let size = self.size(at: zoom)
        let a = anchor.flatMap { old.contains($0) ? $0 : nil } ?? NSPoint(x: old.midX, y: old.midY)
        let fx = (a.x - old.minX) / old.width, fy = (a.y - old.minY) / old.height
        let frame = NSRect(x: (a.x - fx * size.width).rounded(), y: (a.y - fy * size.height).rounded(),
                           width: size.width, height: size.height)
        state.zoom = zoom
        panel.setFrame(frame, display: true, animate: animate)
        panel.invalidateShadow()
        flash()
    }

    func toggleActualSize() {
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let fit = min(1, screen.width * 0.6 / baseSize.width, screen.height * 0.6 / baseSize.height)
        setZoom(abs(state.zoom - 1) < 0.01 ? fit : 1, around: NSEvent.mouseLocation, animate: true)
    }

    func setOpacity(_ opacity: CGFloat) {
        let opacity = min(max(opacity, FloatOpacity.range.lowerBound), FloatOpacity.range.upperBound)
        guard opacity != state.opacity else { return }
        state.opacity = opacity
        content.setImageOpacity(opacity)
        halo?.intensity = opacity
        panel.invalidateShadow()
        flash()
    }

    /// Shows the opacity and zoom for a moment.
    func flash(_ message: String? = nil) {
        state.message = message
        state.flashing = true
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: message == nil ? 1.1 : 2.2, repeats: false) { [weak self] _ in
            self?.state.flashing = false
            self?.state.message = nil
        }
    }

    // MARK: Translation

    /// The image on screen: the translation or the original.
    var shownImage: CGImage { state.showsTranslation ? translated ?? original : original }

    /// The clip of what's on screen, if it is one.
    var shownClip: ClipItem? { state.showsTranslation ? translatedClip : item }

    func beginTranslating() -> Int {
        generation += 1
        state.status = "Translating…"
        return generation
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// `problem` says what part couldn't be translated, if any.
    func showTranslation(_ image: CGImage, spots: [ImageTranslation.Spot], clip: ClipItem?, target: String, problem: String? = nil) {
        translated = image
        self.spots = spots
        translatedClip = clip
        state.status = nil
        state.language = target
        chosenLanguage = target
        // Also when a translation into another language replaces the one showing.
        state.showsTranslation = true
        // After the state changes: Live Text must be hidden by now, or it takes the clicks meant for the parts.
        content.refreshHover()
        content.setImage(image)
        flash(problem.map { "Partly translated: \($0)" }
              ?? "\(Translator.name(of: target))\(clip == nil ? "" : " · saved as a clip") · T for the original")
    }

    /// Google Translate's web page translates images well too: the image goes on the clipboard
    /// and its Images tab opens, ready for ⌘V. Nothing is sent until it's pasted there.
    func openInGoogleTranslate() {
        onGoogle(state.language ?? translationTargets().first ?? "vi")
    }

    func translationFailed(_ message: String) {
        state.status = nil
        flash(message)
    }

    /// Switches between the translation and the image as it was.
    func show(translation: Bool) {
        let showing = translation && translated != nil
        guard showing != state.showsTranslation else { return }
        state.showsTranslation = showing
        content.setImage(showing ? translated! : original)
        content.refreshHover()
    }

    // MARK: Parts of the translation

    /// Shows the original of a part of the translation above it (below it near the top of the
    /// screen), or hides it for nil. `rect` is the part on screen.
    func hover(_ spot: ImageTranslation.Spot?, at rect: NSRect = .zero) {
        guard let spot else {
            tipTimer?.invalidate()
            if let tip { fade(tip, to: 0) }
            return
        }
        let tip = self.tip ?? {
            let made = FloatTipPanel()
            made.sharingType = panel.sharingType
            panel.addChildWindow(made, ordered: .above)
            self.tip = made
            return made
        }()
        tipTimer?.invalidate()
        tip.model.original = spot.original
        tip.model.copied = false
        tip.hosting.layoutSubtreeIfNeeded()
        let size = tip.hosting.fittingSize
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? rect
        let gap: CGFloat = 8
        var y = rect.maxY + gap
        if y + size.height > visible.maxY { y = rect.minY - gap - size.height }
        let x = min(max(rect.minX, visible.minX + 4), visible.maxX - size.width - 4)
        tip.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        fade(tip, to: 1)
    }

    /// Copies a part's original text (what was read there, as its bubble shows), and says so
    /// in the bubble for a moment.
    func copy(_ spot: ImageTranslation.Spot) {
        onCopyText(spot.original)
        guard let tip else { return }
        tip.model.copied = true
        tipTimer?.invalidate()
        tipTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak tip] _ in
            MainActor.assumeIsolated { tip?.model.copied = false }
        }
    }

    private func fade(_ window: NSWindow, to alpha: CGFloat) {
        guard window.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = alpha > 0 ? 0.14 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        }
    }

    // MARK: Locking

    func setLocked(_ locked: Bool) {
        guard locked != state.locked else { return }
        state.locked = locked
        panel.ignoresMouseEvents = locked
        content.refreshHover()
        if locked {
            flash("Locked · clicks pass through")
        } else {
            flash()
        }
        onLockChange()
    }


    // MARK: Keys

    func handle(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Holding Space shows the original under a translation.
        if event.keyCode == 49, f.isEmpty, translated != nil {
            if event.type == .keyDown, !event.isARepeat { show(translation: false) }
            if event.type == .keyUp { show(translation: true) }
            return true
        }
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 53: close(); return true                                  // Esc
        case 126: setOpacity(state.opacity + 0.1); return true         // ↑
        case 125: setOpacity(state.opacity - 0.1); return true         // ↓
        case 123 where f.isEmpty: stepLanguage(by: -1); return true    // ←
        case 124 where f.isEmpty: stepLanguage(by: 1); return true     // →
        default: break
        }
        if f == .command {
            switch chars {
            case "w": close()
            case "c":
                if content.copySelectedText() { flash("Copied text") } else { onCopy(); flash("Copied") }
            case "a": if !content.selectAllText() { return false }
            case "=", "+": setZoom(state.zoom * 1.25, animate: true)
            case "-": setZoom(state.zoom * 0.8, animate: true)
            case "0": setZoom(1, animate: true)
            default: return false
            }
            return true
        }
        guard f.isEmpty else { return false }
        switch chars {
        case "e": onEdit()
        case "l": setLocked(!state.locked)
        case "t": toggleTranslation()
        case "g": openInGoogleTranslate()
        default:
            // 1…9: into that language of Settings' list.
            let targets = translationTargets()
            guard let n = Int(chars), (1...min(9, targets.count)).contains(n) else { return false }
            translate(into: targets[n - 1])
        }
        return true
    }

    private func translate(into language: String) {
        chosenLanguage = language
        onTranslate(language)
    }

    /// Translates into the previous or next language of Settings' list, going round and passing
    /// over any the text is all in already; into the first language the text isn't in, when
    /// there's no translation yet.
    private func stepLanguage(by step: Int) {
        let targets = translationTargets()
        guard let current = chosenLanguage ?? state.language, let i = targets.firstIndex(of: current) else {
            if state.status == nil { onTranslate(nil) }
            return
        }
        let read = reading?.languages.compactMap { $0 } ?? []
        for n in 1..<max(targets.count, 1) {
            let target = targets[(i + step * n + targets.count * n) % targets.count]
            if read.isEmpty || !read.allSatisfy({ ImageTranslation.isAlready($0, in: target) }) {
                return translate(into: target)
            }
        }
        flash("No other language to translate into")
    }

    /// Shows the translation, translating first if need be, or the original again.
    func toggleTranslation() {
        if translated != nil { return show(translation: !state.showsTranslation) }
        if state.status == nil { onTranslate(nil) }
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            let target = MenuAction(action)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        add("Edit Image…", "e") { [weak self] in self?.onEdit() }
        add("Copy", "c", .command) { [weak self] in self?.onCopy() }
        add(state.showsTranslation ? "Show Original" : "Translate", "t") { [weak self] in self?.toggleTranslation() }
        add("Open in Google Translate", "g") { [weak self] in self?.openInGoogleTranslate() }
        menu.addItem(.separator())
        add(abs(state.zoom - 1) < 0.01 ? "Fit on Screen" : "Actual Size", "0", .command) { [weak self] in self?.toggleActualSize() }
        add("Lock (Clicks Pass Through)", "l") { [weak self] in self?.setLocked(true) }
        menu.addItem(.separator())
        add("Close", "w", .command) { [weak self] in self?.close() }
        return menu
    }
}

/// Runs a closure from a menu item.
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

// MARK: - View

/// The image, rounded. Its controls are in a strip of their own beside it (`FloatStripPanel`),
/// so they never cover the picture, however small it is.
final class FloatingImageView: NSView {
    weak var window_: FloatingImageWindow?
    private let imageLayer = CALayer()
    private let rim = RimLayer()
    private let cornerRadius: CGFloat
    private let state: FloatingImageState
    /// The size of the picture in pixels, which the parts of a translation are measured in.
    private let pixels: CGSize
    /// Rings the part of the translation under the pointer.
    private let ring = CAShapeLayer()
    private let ringGlow = CAShapeLayer()
    private var hovered: Int?
    private let source: CGImage
    /// The text of the picture laid out for selecting, from the same reading translation uses (not
    /// Live Text's, which garbles a phrase in another writing inside a sentence). Empty until read.
    private var text = SelectableText(lines: [])
    private var reading: Task<Void, Never>?
    private let selectionLayer = CAShapeLayer()
    private var selection: (SelectableText.Position, SelectableText.Position)? { didSet { drawSelection() } }

    init(image: CGImage, state: FloatingImageState, cornerRadius: CGFloat) {
        pixels = CGSize(width: image.width, height: image.height)
        source = image
        self.state = state
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        // Light along the top edge, as on the panels; the glow and shadow are outside (`GlowHalo`).
        layer?.addSublayer(rim)
        for shape in [ringGlow, ring] {
            shape.opacity = 0
            layer?.addSublayer(shape)
        }
        colourRing()
        selectionLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        layer?.insertSublayer(selectionLayer, above: imageLayer)
    }

    /// Reads the text of the picture, in the background, so it can be selected. A small image is
    /// read at twice its size, as translation does.
    func beginReading(languages: [String]) {
        guard reading == nil else { return }
        reading = Task { @MainActor [weak self, source] in
            let lines = await Task.detached(priority: .utility) { () -> [TextRecognizer.Line] in
                let small = max(source.width, source.height) < 1200
                return TextRecognizer.lines(in: small ? TextRecognizer.upscaled(source, by: 2) : source, languages: languages)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.text = SelectableText(lines: lines)
            self.window?.invalidateCursorRects(for: self)
        }
    }

    /// Stops reading the image, when it's closed before that's done.
    func stopAnalysing() { reading?.cancel() }

    /// Text can be selected on the original only, and not through a locked image.
    private var selectable: Bool { !state.showsTranslation && !state.locked && !text.isEmpty }

    private func updateSelectable() {
        if !selectable, selection != nil { selection = nil }
        window?.invalidateCursorRects(for: self)
    }

    /// Copies the selected text, if any.
    func copySelectedText() -> Bool {
        guard selectable, let (a, b) = selection else { return false }
        let string = text.string(from: a, to: b)
        guard !string.isEmpty else { return false }
        window_?.onCopyText(string)
        return true
    }

    /// Selects all the text, if there is any to select.
    func selectAllText() -> Bool {
        guard selectable, let all = text.all else { return false }
        selection = all
        return true
    }

    private func drawSelection() {
        let path = CGMutablePath()
        if let (a, b) = selection {
            for rect in text.rects(from: a, to: b) {
                let box = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                                 width: rect.width * bounds.width, height: rect.height * bounds.height).insetBy(dx: -1.5, dy: -1)
                path.addRoundedRect(in: box, cornerWidth: 3, cornerHeight: 3)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.path = path
        CATransaction.commit()
    }

    /// Where `point` (in the view) is on the picture, 0…1 from the bottom left.
    private func normalized(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1))
    }

    /// The I-beam over text that can be selected.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard selectable else { return }
        for rect in text.rects(from: SelectableText.Position(unit: 0, char: 0), to: text.all!.1) {
            addCursorRect(CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                                 width: rect.width * bounds.width, height: rect.height * bounds.height), cursor: .iBeam)
        }
    }

    private func colourRing() {
        let accent = NSColor.controlAccentColor
        ring.fillColor = accent.withAlphaComponent(0.1).cgColor
        ring.strokeColor = accent.blended(withFraction: 0.3, of: .white)?.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 1.5
        ringGlow.fillColor = nil
        ringGlow.strokeColor = accent.withAlphaComponent(0.22).cgColor
        ringGlow.lineWidth = 7
    }

    /// The system appearance is light; the rim follows it, as the glow around does.
    private var isLight: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rim.update(cornerRadius: cornerRadius, light: isLight)
        colourRing()
    }


    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Swaps the picture with a short fade, as between the original and its translation.
    func setImage(_ image: CGImage) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        imageLayer.add(fade, forKey: "contents")
        imageLayer.contents = image
    }

    func setImageOpacity(_ opacity: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        imageLayer.opacity = Float(opacity)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        rim.frame = bounds
        rim.update(cornerRadius: cornerRadius, light: isLight)
        ring.frame = bounds
        ringGlow.frame = bounds
        selectionLayer.frame = bounds
        drawSelection()
        if let hovered, let spot = window_?.spots[safe: hovered] {
            ring.path = path(of: spot)
            ringGlow.path = ring.path
            // Zooming: the bubble goes along.
            if let window { window_?.hover(spot, at: window.convertToScreen(convert(spot.bounds.applying(toView), to: nil))) }
        }
        CATransaction.commit()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { state.hovering = true; refreshHover() }
    override func mouseExited(with event: NSEvent) { state.hovering = false; setHovered(nil) }
    override func mouseMoved(with event: NSEvent) { setHovered(spot(at: convert(event.locationInWindow, from: nil))) }

    /// A click on a part of the translation copies its original text; dragging from it moves the image, as
    /// from anywhere else.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let start = event.locationInWindow
        let here = normalized(convert(start, from: nil))
        // On text of the original: select it (a double click a word, a triple click the row), as
        // in any text; dragging from anywhere else moves the image.
        if selectable, text.isOverText(here) {
            switch event.clickCount {
            case 2: selection = text.word(at: here)
            case 3...: selection = text.line(at: here)
            default:
                guard let window, let anchor = text.position(at: here) else { return }
                selection = nil
                while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                    if let head = text.position(at: normalized(convert(next.locationInWindow, from: nil))), head != anchor {
                        selection = (anchor, head)
                    }
                    if next.type == .leftMouseUp { break }
                }
            }
            return
        }
        if selection != nil { selection = nil }
        if event.clickCount == 2 { return window_?.toggleActualSize() ?? () }
        guard let i = spot(at: convert(start, from: nil)), let spot = window_?.spots[safe: i], let window else {
            return window?.performDrag(with: event) ?? ()
        }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { return window_?.copy(spot) ?? () }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                setHovered(nil)
                return window.performDrag(with: event)
            }
        }
    }

    // MARK: Parts of the translation

    /// Checks the pointer again: after the translation is shown or hidden, or the image moves.
    func refreshHover() {
        updateSelectable()
        guard let window, state.hovering else { return setHovered(nil) }
        setHovered(spot(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    /// Which part of the translation showing is at `point`.
    private func spot(at point: NSPoint) -> Int? {
        guard state.showsTranslation, !state.locked, bounds.width > 0, bounds.height > 0, let spots = window_?.spots else { return nil }
        let p = CGPoint(x: point.x * pixels.width / bounds.width, y: (bounds.height - point.y) * pixels.height / bounds.height)
        // The smallest under the pointer, when parts overlap.
        return spots.indices.filter { spots[$0].contains(p) }
            .min { spots[$0].rect.width * spots[$0].rect.height < spots[$1].rect.width * spots[$1].rect.height }
    }

    /// From the picture's pixels (top left) to this view's points (bottom left).
    private var toView: CGAffineTransform {
        CGAffineTransform(a: bounds.width / pixels.width, b: 0, c: 0, d: -bounds.height / pixels.height, tx: 0, ty: bounds.height)
    }

    private func path(of spot: ImageTranslation.Spot) -> CGPath {
        let scale = bounds.width / pixels.width
        let corner = min(5 / max(scale, 0.01), spot.rect.height / 2, spot.rect.width / 2)
        var transform = CGAffineTransform(translationX: spot.pivot.x, y: spot.pivot.y).rotated(by: spot.angle)
            .translatedBy(x: -spot.pivot.x, y: -spot.pivot.y).concatenating(toView)
        return CGPath(roundedRect: spot.rect, cornerWidth: corner, cornerHeight: corner, transform: &transform)
    }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        let spot = index.flatMap { window_?.spots[safe: $0] }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let spot {
            CATransaction.setDisableActions(ring.opacity == 0)      // A new ring appears in place, then fades in.
            ring.path = path(of: spot)
            ringGlow.path = ring.path
            CATransaction.setDisableActions(false)
        }
        ring.opacity = spot == nil ? 0 : 1
        ringGlow.opacity = ring.opacity
        CATransaction.commit()
        guard let spot, let window else { return window_?.hover(nil) ?? () }
        let onScreen = window.convertToScreen(convert(spot.bounds.applying(toView), to: nil))
        window_?.hover(spot, at: onScreen)
    }

    override func menu(for event: NSEvent) -> NSMenu? { window_?.menu() }

    override func scrollWheel(with event: NSEvent) {
        guard let owner = window_ else { return }
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 150 : event.scrollingDeltaY / 15
            owner.setZoom(owner.state.zoom * (1 + max(min(delta, 0.25), -0.25)), around: NSEvent.mouseLocation)
            return
        }
        // The fling after lifting the fingers would carry on changing it; only the swipe itself counts.
        guard event.momentumPhase.isEmpty else { return }
        owner.setOpacity(FloatOpacity.after(owner.state.opacity, delta: event.scrollingDeltaY,
                                            precise: event.hasPreciseScrollingDeltas,
                                            inverted: event.isDirectionInvertedFromDevice))
    }

    override func magnify(with event: NSEvent) {
        guard let owner = window_ else { return }
        owner.setZoom(owner.state.zoom * (1 + event.magnification), around: NSEvent.mouseLocation)
    }
}

// MARK: - Original of a part

final class FloatTipModel: ObservableObject {
    @Published var original = "" { didSet { width = Self.width(of: original) } }
    @Published var copied = false
    /// As wide as the text, up to 300 pt, where a longer one wraps.
    @Published private(set) var width: CGFloat = 200

    static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let hint = "Click to copy this text"

    private static func width(of text: String) -> CGFloat {
        let natural = (text as NSString).size(withAttributes: [.font: font]).width
        let hint = (Self.hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width + 20
        return min(max(natural, hint) + 2, 278).rounded(.up)
    }
}

/// The bubble with the original of the part of a translated image under the pointer. It never
/// takes the mouse, so it can't come between the pointer and the image.
final class FloatTipPanel: NSPanel {
    let model = FloatTipModel()
    let hosting: NSHostingView<FloatTip>

    init() {
        hosting = NSHostingView(rootView: FloatTip(model: model))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        alphaValue = 0
        ignoresMouseEvents = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
}

struct FloatTip: View {
    @ObservedObject var model: FloatTipModel
    var tone = GlowTone()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.original)
                .font(Font(FloatTipModel.font))
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
            Label(model.copied ? "Copied" : FloatTipModel.hint,
                  systemImage: model.copied ? "checkmark" : "cursorarrow.click")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(model.copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .animation(.easeOut(duration: 0.12), value: model.copied)
        }
        .frame(width: model.width, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .lightRim(cornerRadius: 12, tone: tone)
        .background(GlassBackground(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Controls

/// The strip of controls under a floating image (above it at the bottom of the screen). It's a
/// window of its own, attached to the image's, so it moves with it and never covers it.
final class FloatStripPanel: NSPanel {
    let hosting: StripHostingView

    init(strip: FloatStrip) {
        hosting = StripHostingView(rootView: strip)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        alphaValue = 0
        ignoresMouseEvents = true
        contentView = hosting
    }

    /// Keys stay with the image.
    override var canBecomeKey: Bool { false }
}

/// Hosts the strip: takes the first click with PasteClip in the background, and says when the
/// pointer is over it, so the strip stays up while it's being used.
final class StripHostingView: NSHostingView<FloatStrip> {
    var onHover: (Bool) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// Close · what's showing (language, opacity, zoom) or a message · Translate, Google, Edit,
/// Copy · Lock. Buttons show their keys.
struct FloatStrip: View {
    static let infoWidth: CGFloat = 196
    /// For a narrow image: the zoom alone (opacity shows while it changes, in the same room).
    static let compactInfoWidth: CGFloat = 76
    @ObservedObject var state: FloatingImageState
    var close: () -> Void = {}
    var zoom: (CGFloat) -> Void = { _ in }
    var translate: () -> Void = {}
    var google: () -> Void = {}
    var edit: () -> Void = {}
    var copy: () -> Void = {}
    var lock: () -> Void = {}
    var tone = GlowTone()

    var body: some View {
        HStack(spacing: 2) {
            StripButton(symbol: "xmark", keys: "esc", help: "Close (Esc)", action: close)
            separator
            info.padding(.horizontal, 6)
            separator
            StripButton(symbol: "character.bubble", keys: "T", selected: state.showsTranslation,
                        help: state.showsTranslation ? "Show the original (T, or hold Space)" : "Translate the text where it is (T)",
                        action: translate)
            StripButton(symbol: "globe", keys: "G", help: "Open in Google Translate: copies the image to paste there (G)", action: google)
            StripButton(symbol: "pencil", keys: "E", help: "Edit (E)", action: edit)
            StripButton(symbol: "doc.on.doc", keys: "⌘C", help: "Copy (⌘C)", action: copy)
            separator
            StripButton(symbol: state.locked ? "lock.fill" : "lock.open", keys: "L", selected: state.locked,
                        help: state.locked ? "Unlock (L)" : "Lock: clicks pass through to the windows behind (L)", action: lock)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .lightRim(cornerRadius: 15, tone: tone)
        .background(GlassBackground(cornerRadius: 15))
        .clipShape(Capsule())
        .foregroundStyle(.primary)
        .fixedSize()
    }

    @ViewBuilder
    private var info: some View {
        Group {
            if let status = state.status {
                Label(status, systemImage: "character.bubble").help(status)
            } else if let message = state.message {
                Text(message).help(message)
            } else if state.compactStrip {
                // Opacity while it's being changed, otherwise the zoom; ⌘ scroll or pinch zooms.
                if state.flashing, state.opacity < 1 {
                    Label("\(Int((state.opacity * 100).rounded()))%", systemImage: "circle.lefthalf.filled")
                } else {
                    Label("\(Int((state.zoom * 100).rounded()))%", systemImage: "magnifyingglass")
                        .help("Zoom: pinch, ⌘ scroll or ⌘+ ⌘−. Scroll for clearer or fainter (↑ ↓)")
                }
            } else {
                HStack(spacing: 8) {
                    if state.showsTranslation, let language = state.language {
                        Label(Translator.shortName(of: language), systemImage: "character.bubble")
                            .help("\(Translator.name(of: language)) · ← → or 1–9 for another language")
                    }
                    Label("\(Int((state.opacity * 100).rounded()))%", systemImage: "circle.lefthalf.filled")
                        .help("Scroll up or down over the image to make it clearer or fainter (↑ ↓)")
                    HStack(spacing: 2) {
                        zoomButton("minus", factor: 0.8, help: "Zoom out (⌘−)")
                        Text("\(Int((state.zoom * 100).rounded()))%").frame(minWidth: 32)
                        zoomButton("plus", factor: 1.25, help: "Zoom in (⌘+). Pinch or ⌘ scroll also zoom")
                    }
                }
            }
        }
        .labelStyle(ReadoutLabelStyle())
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        // Always this wide, whatever it says, so the buttons never move under the pointer.
        .frame(width: state.compactStrip ? Self.compactInfoWidth : Self.infoWidth)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 15).padding(.horizontal, 2)
    }

    private func zoomButton(_ symbol: String, factor: CGFloat, help: String) -> some View {
        Button { zoom(factor) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// An icon with its key beside it.
private struct StripButton: View {
    let symbol: String
    var keys: String?
    var selected = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                if let keys {
                    Text(keys)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, keys == nil ? 0 : 7)
            .frame(minWidth: 24, minHeight: 24)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.clear)
                .shadow(color: Color.accentColor.opacity(selected ? 0.35 : 0), radius: 5, y: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(StripButtonStyle())
        .help(help)
    }
}

/// A soft highlight while pressed.
private struct StripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)))
    }
}

private struct ReadoutLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
            configuration.title.lineLimit(1)
        }
    }
}

