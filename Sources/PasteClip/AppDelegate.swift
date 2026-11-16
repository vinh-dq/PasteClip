import AppKit
import Combine
import PasteClipCore
import PasteClipSync
import PasteClipSystem

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let store = ClipStore()
    private lazy var sync = CloudSync(store: store)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store, sync: sync)
    private lazy var shelf = ShelfController(store: store, settings: settings) { [weak self] in
        self?.settingsWindow.show()
    }
    private lazy var stackPanel = StackController(store: store, settings: settings)
    private lazy var screenText = ScreenTextCapture(store: store, settings: settings)
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        bindSettings()
        store.onCapture = { [weak self] _ in self?.play("Tink") }
        shelf.onPasted = { [weak self] in self?.play("Pop") }
        screenText.onCopied = { [weak self] in self?.play("Tink") }
        store.start()
        setupStatusItem()

        if !Paster.isTrusted { Paster.requestTrust() }
        openFromArguments()
    }

    /// Lets you jump straight to a screen while working on the UI:
    /// `PasteClip --open shelf|preview|general|text|privacy|shortcuts`.
    private func openFromArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) else { return }
        if args[i + 1] == "shelf" {
            shelf.show()
        } else if args[i + 1] == "preview" {
            shelf.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.shelf.showPreview() }
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

        // Re-register shortcuts when they change; drop them while a shortcut field is recording.
        Publishers.CombineLatest(Publishers.CombineLatest4(settings.$shelfHotKey, settings.$stackHotKey,
                                                           settings.$pasteNextHotKey, settings.$captureTextHotKey),
                                 settings.$isRecordingShortcut)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.registerHotKeys() }
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

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "PasteClip")
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
        if let combo, combo.keyName.count == 1 {
            item.keyEquivalent = combo.keyName.lowercased()
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
