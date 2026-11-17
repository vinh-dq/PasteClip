import AppKit
import Combine
import PasteClipCore
import PasteClipSync
import PasteClipSystem

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    /// `--store <folder>` keeps history somewhere else, for trying things out without touching your own.
    private let store = ClipStore(directory: CommandLine.arguments.firstIndex(of: "--store")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil })
    private lazy var sync = CloudSync(store: store)
    private lazy var apiKeys = APIKeys(directory: store.directory)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store, sync: sync, keys: apiKeys)
    private lazy var shelf = ShelfController(store: store, settings: settings) { [weak self] in
        self?.settingsWindow.show()
    }
    private lazy var stackPanel = StackController(store: store, settings: settings)
    private lazy var screenText = ScreenTextCapture(store: store, settings: settings)
    private lazy var screenshot = ScreenshotCapture(store: store, settings: settings)
    private let screenshotOffer = ScreenshotOffer()
    private lazy var screenTranslation = ScreenTranslation()
    private lazy var translation = TranslationController(store: store, settings: settings, keys: apiKeys)
    private lazy var imageEditors = ImageEditors(store: store, settings: settings)
    private lazy var floatingImages = FloatingImages(store: store, settings: settings, keys: apiKeys)
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var subscriptions = Set<AnyCancellable>()
    private var lastWarmUp = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        bindSettings()
        store.onCapture = { [weak self] _ in self?.play("Tink") }
        shelf.onPasted = { [weak self] in self?.play("Pop") }
        screenText.onCopied = { [weak self] in self?.play("Tink") }
        screenText.onTranslate = { [weak self] text in self?.translation.show(text) }
        shelf.onTranslateItems = { [weak self] items in self?.translation.show(items) }
        shelf.onTranslate = { [weak self] item, target in self?.translation.show([item], target: target) }
        shelf.onEditImage = { [weak self] item in self?.imageEditors.edit(item) }
        shelf.onFloatImages = { [weak self] items in items.forEach { self?.floatingImages.show($0) } }
        imageEditors.onFloat = { [weak self] item in self?.floatingImages.show(item) }
        floatingImages.onEdit = { [weak self] item in self?.imageEditors.edit(item) }
        shelf.onTranslateImages = { [weak self] items in items.forEach { self?.floatingImages.show($0, translate: true) } }
        translation.onShowOnImage = { [weak self] item, target in self?.floatingImages.show(item, translate: true, target: target) }
        screenTranslation.onCaptured = { [weak self] image, placement in self?.floatingImages.showTranslated(image, over: placement) }
        screenshot.onCaptured = { [weak self] item in
            guard let self else { return }
            self.play("Tink")
            switch self.settings.screenshotAction {
            case .offer:
                guard let image = self.store.image(for: item) else { return }
                self.screenshotOffer.sharingType = self.settings.hideDuringScreenSharing ? .none : .readOnly
                self.screenshotOffer.show(item, image: image) { [weak self] choice in
                    guard let self, let current = self.store.item(withID: item.id) else { return }
                    switch choice {
                    case .edit: self.imageEditors.edit(current)
                    case .float: self.floatingImages.show(current)
                    case .translate: self.floatingImages.show(current, translate: true)
                    }
                }
            case .copy: break
            case .edit: self.imageEditors.edit(item)
            case .float: self.floatingImages.show(item)
            }
        }
        store.start()
        // Text in images reads at once the first time too, instead of after most of a minute.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [languages = settings.textLanguages] in
            TextRecognizer.warmUp(languages: languages)
        }
        // Moves keys left in a plain file by earlier builds into the keychain, without reading it otherwise.
        _ = apiKeys
        setupStatusItem()

        if !Paster.isTrusted { Paster.requestTrust() }
        openFromArguments()
    }

    /// Lets you jump straight to a screen while working on the UI:
    /// `PasteClip --open shelf|preview|editor|float|general|text|translation|privacy|shortcuts`, or `--translate "some text"`.
    private func openFromArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--translate"), args.indices.contains(i + 1) {
            translation.show(args[i + 1])
            return
        }
        guard let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) else { return }
        if args[i + 1] == "shelf" {
            shelf.show()
        } else if args[i + 1] == "preview" {
            shelf.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.shelf.showPreview() }
        } else if args[i + 1] == "editor" || args[i + 1] == "float", let image = store.items.first(where: \.isImage) {
            args[i + 1] == "editor" ? imageEditors.edit(image) : floatingImages.show(image)
        } else if let page = SettingsPage(rawValue: args[i + 1]) {
            settingsWindow.show(page)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    private func bindSettings() {
        settings.$historyLimit.sink { [store] in store.historyLimit = $0 }.store(in: &subscriptions)
        settings.$retentionDays.sink { [store] in store.retentionDays = $0 }.store(in: &subscriptions)
        settings.$excludedBundleIDs.sink { [store] in store.excludedBundleIDs = Set($0) }.store(in: &subscriptions)
        settings.$skipConcealed.sink { [store] in store.skipConcealed = $0 }.store(in: &subscriptions)
        settings.$skipTransient.sink { [store] in store.skipTransient = $0 }.store(in: &subscriptions)
        settings.$textLanguages.sink { [store] in store.recognitionLanguages = $0 }.store(in: &subscriptions)
        settings.$textLanguages
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { TextRecognizer.prepare(languages: $0) }
            .store(in: &subscriptions)
        settings.$findTextInImages.sink { [store] in store.recognizesText = $0 }.store(in: &subscriptions)
        // The connection to the translation service (and Bing's token) is ready before it's needed:
        // at launch, after picking a service, and every 10 minutes for Bing, whose token lasts an hour.
        settings.$translationService
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.warmUpTranslation(force: true) }
            .store(in: &subscriptions)
        Timer.publish(every: 600, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                if self?.settings.translationService == .bing { self?.warmUpTranslation(force: true) }
            }
            .store(in: &subscriptions)

        // Re-register shortcuts when they change; drop them while a shortcut field is recording.
        let shortcuts = [settings.$shelfHotKey, settings.$stackHotKey, settings.$pasteNextHotKey,
                         settings.$captureTextHotKey, settings.$screenshotHotKey, settings.$translateHotKey,
                         settings.$translateScreenHotKey, settings.$floatImageKey]
        Publishers.MergeMany(shortcuts.map { $0.map { _ in () }.eraseToAnyPublisher() }
                             + [settings.$isRecordingShortcut.map { _ in () }.eraseToAnyPublisher()])
            .debounce(for: .milliseconds(10), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &subscriptions)

        store.$stackMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.stackPanel.setVisible(on) }
            .store(in: &subscriptions)

        settings.$iCloudSync
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                guard let self, CloudSync.isAvailable else { return }
                on ? self.sync.start() : self.sync.stop()
            }
            .store(in: &subscriptions)
    }

    private func registerHotKeys() {
        hotKeys.removeAll()
        guard !settings.isRecordingShortcut else { return }
        let bindings: [(KeyCombo?, () -> Void)] = [
            (settings.shelfHotKey, { [weak self] in self?.shelf.toggle() }),
            (settings.stackHotKey, { [weak self] in self?.toggleStack() }),
            (settings.pasteNextHotKey, { [weak self] in self?.pasteNextFromStack() }),
            (settings.captureTextHotKey, { [weak self] in self?.captureText() }),
            (settings.screenshotHotKey, { [weak self] in self?.captureScreenshot() }),
            (settings.translateScreenHotKey, { [weak self] in self?.translateScreen() }),
            (settings.floatImageKey, { [weak self] in self?.floatImage() }),
            (settings.translateHotKey, { [weak self] in self?.translate() }),
        ]
        for (combo, action) in bindings {
            guard let combo else { continue }
            if let hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers, action: {
                DispatchQueue.main.async(execute: action)
            }) {
                hotKeys.append(hotKey)
            } else {
                NSLog("PasteClip: shortcut %@ is already in use", combo.display)
            }
        }
    }

    private func play(_ sound: String) {
        guard settings.playSounds else { return }
        NSSound(named: sound)?.play()
    }

    // MARK: - Paste stack

    @objc private func toggleStack() {
        store.stackMode.toggle()
    }

    private func pasteNextFromStack() {
        guard let item = store.popStack() else {
            NSSound.beep()
            return
        }
        store.copyToPasteboard(item, plainText: settings.alwaysPlainText)
        Paster.pasteIntoFrontApp()
        play("Pop")
    }

    // MARK: - Text from the screen

    @objc private func captureText() {
        shelf.hide()
        screenText.start()
    }

    @objc private func translateScreen() {
        shelf.hide()
        screenTranslation.start()
    }

    /// The image being edited, the images selected in the shelf, or else the latest image.
    @objc private func floatImage() {
        if imageEditors.floatFromFrontEditor() { return }
        if shelf.isVisible { return shelf.floatSelection() }
        guard let item = store.items.first(where: \.isImage) else { return NSSound.beep() }
        floatingImages.show(item)
    }

    @objc private func captureScreenshot() {
        shelf.hide()
        screenshot.start()
    }

    // MARK: - Translation

    /// With the shelf open, translates the clips selected there; otherwise the text selected in
    /// the front app, or the clipboard.
    @objc private func translate() {
        // Opens the connection while the selected text is read, so the request doesn't wait for it.
        warmUpTranslation(force: false)
        if shelf.isVisible { return shelf.translateSelection() }
        translation.translateSelectionOrClipboard()
    }

    /// The app shows no menu bar, but text fields (Settings, the key popover) only get ⌘X, ⌘C, ⌘V,
    /// ⌘A and ⌘Z through the key equivalents of an Edit menu in the main menu.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "PasteClip", action: nil, keyEquivalent: ""))
        main.addItem(item)
        return main
    }

    /// Opens the connection to the chosen web service. Skipped if done in the last 20 seconds,
    /// when the connection is still open, unless `force`.
    private func warmUpTranslation(force: Bool) {
        let service = settings.translationService
        guard service != .apple, force || Date().timeIntervalSince(lastWarmUp) > 20 else { return }
        lastWarmUp = Date()
        Task { await WebTranslator(service: service).warmUp() }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item("Open PasteClip", #selector(openShelf), settings.shelfHotKey))
        menu.addItem(item(store.stackMode ? "Stop Paste Stack" : "Start Paste Stack", #selector(toggleStack),
                          settings.stackHotKey))
        menu.addItem(item("Copy Text from Screen", #selector(captureText), settings.captureTextHotKey))
        menu.addItem(item("Capture Screen Area", #selector(captureScreenshot), settings.screenshotHotKey))
        menu.addItem(item("Translate Screen Area", #selector(translateScreen), settings.translateScreenHotKey))
        menu.addItem(item("Float Latest Image", #selector(floatImage), settings.floatImageKey))
        menu.addItem(item("Translate Selection or Clipboard", #selector(translate), settings.translateHotKey))
        if floatingImages.count > 0 {
            menu.addItem(.separator())
            if floatingImages.hasLocked { menu.addItem(item("Unlock Floating Images", #selector(unlockFloatingImages), nil)) }
            menu.addItem(item(floatingImages.count == 1 ? "Close Floating Image" : "Close \(floatingImages.count) Floating Images",
                              #selector(closeFloatingImages), nil))
        }
        menu.addItem(.separator())
        menu.addItem(item(store.paused ? "Resume Capturing" : "Pause Capturing", #selector(togglePause), nil))
        if !Paster.isTrusted {
            menu.addItem(item("Enable Direct Paste…", #selector(requestAccessibility), nil))
        }
        menu.addItem(item("Settings…", #selector(openSettings), nil, key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Clear History…", #selector(clearHistory), nil))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit PasteClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Menu item that shows a global shortcut as a hint (it fires through the hotkey, not the menu).
    private func item(_ title: String, _ action: Selector, _ combo: KeyCombo?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let combo, combo.keyName.count == 1 || combo.keyName == "Space" {
            item.keyEquivalent = combo.keyName == "Space" ? " " : combo.keyName.lowercased()
            var mask: NSEvent.ModifierFlags = []
            if combo.modifiers & KeyCombo.command != 0 { mask.insert(.command) }
            if combo.modifiers & KeyCombo.shift != 0 { mask.insert(.shift) }
            if combo.modifiers & KeyCombo.option != 0 { mask.insert(.option) }
            if combo.modifiers & KeyCombo.control != 0 { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    @objc private func openShelf() { shelf.show() }

    @objc private func closeFloatingImages() { floatingImages.closeAll() }

    @objc private func unlockFloatingImages() { floatingImages.unlockAll() }

    @objc private func openSettings() { settingsWindow.show() }

    @objc private func togglePause() { store.paused.toggle() }

    @objc private func requestAccessibility() { Paster.requestTrust() }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned clips and clips on a pinboard are kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }
}
