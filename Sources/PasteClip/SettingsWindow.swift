import AppKit
import PasteClipCore
import PasteClipSync
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let store: ClipStore
    private let sync: CloudSync
    private let page = ViewState(SettingsPage.general)

    init(settings: AppSettings, store: ClipStore, sync: CloudSync) {
        self.settings = settings
        self.store = store
        self.sync = sync
    }

    func show(_ initialPage: SettingsPage? = nil) {
        if let initialPage { page.value = initialPage }
        if window == nil {
            let root = SettingsView(settings: settings, store: store, sync: sync, page: page)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "PasteClip Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, privacy, shortcuts
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .privacy: return "hand.raised"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let store: ClipStore
    @ObservedObject var sync: CloudSync
    @ObservedObject var page: ViewState<SettingsPage>

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 720, height: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 52) // room for the traffic lights
            List(selection: Binding(get: { page.value }, set: { if let p = $0 { page.value = p } })) {
                ForEach(SettingsPage.allCases) { p in
                    Label(p.title, systemImage: p.symbol)
                        .font(.system(size: 13))
                        .padding(.vertical, 3)
                        .tag(p)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.directory])
            } label: {
                Label("Show Data in Finder", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
            .padding(16)
        }
        .frame(width: 210)
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.value.title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 28)
                .padding(.top, 22)
            Group {
                switch page.value {
                case .general: GeneralPage(settings: settings, store: store, sync: sync)
                case .privacy: PrivacyPage(settings: settings)
                case .shortcuts: ShortcutsPage(settings: settings)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    let store: ClipStore
    @ObservedObject var sync: CloudSync
    @StateObject private var launchAtLogin = ViewState(SMAppService.mainApp.status == .enabled)

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin.value)
                    .onChange(of: launchAtLogin.value) { _, on in setLaunchAtLogin(on) }
                LabeledContent {
                    HStack(spacing: 8) {
                        if settings.iCloudSync, CloudSync.isAvailable {
                            Text(sync.status).foregroundStyle(.secondary)
                        }
                        Toggle("iCloud sync", isOn: $settings.iCloudSync)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!CloudSync.isAvailable)
                    }
                } label: {
                    Text("iCloud sync")
                    if !CloudSync.isAvailable {
                        Text("Needs a signed build. See “iCloud sync” in the README.")
                    }
                }
                Toggle("Sound effects", isOn: $settings.playSounds)
            }

            Section("When you choose a clip") {
                PasteModeRow(mode: .frontApp, selection: $settings.pasteMode,
                             title: "Paste into the front app",
                             detail: "PasteClip pastes it straight into the app you were using.",
                             symbol: "arrow.down.doc")
                PasteModeRow(mode: .clipboard, selection: $settings.pasteMode,
                             title: "Copy to the clipboard",
                             detail: "PasteClip only copies it. Press ⌘V yourself where you want it.",
                             symbol: "doc.on.clipboard")
                Toggle("Always paste as plain text", isOn: $settings.alwaysPlainText)
            }

            Section("Keep history for") {
                RetentionSlider(days: $settings.retentionDays)
                Picker("Keep at most", selection: $settings.historyLimit) {
                    ForEach(AppSettings.historyLimits, id: \.self) { Text("\($0) clips").tag($0) }
                }
                HStack {
                    Text("Pinned clips and pinboards are always kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Erase History…", action: eraseHistory)
                }
            }

            Section("Shelf") {
                Picker("Show at", selection: $settings.shelfEdge) {
                    ForEach(ShelfEdge.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin.value = SMAppService.mainApp.status == .enabled
            NSAlert(error: error).runModal()
        }
    }

    private func eraseHistory() {
        let alert = NSAlert()
        alert.messageText = "Erase clipboard history?"
        alert.informativeText = "Pinned clips and clips on a pinboard are kept. This can't be undone."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }
}

/// One choice of a radio group, with a description and an icon.
private struct PasteModeRow: View {
    let mode: PasteMode
    @Binding var selection: PasteMode
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        Button { selection = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selection == mode ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selection == mode ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(selection == mode ? Color.accentColor : Color.secondary)
                    .frame(width: 40, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill((selection == mode ? Color.accentColor : Color.secondary).opacity(0.12)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Day / Week / Month / Year / Forever.
private struct RetentionSlider: View {
    @Binding var days: Int
    private let steps = RetentionStep.allCases

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { Double(steps.firstIndex(of: RetentionStep(days: days)) ?? steps.count - 1) },
                set: { days = steps[Int($0.rounded())].rawValue }
            ), in: 0...Double(steps.count - 1), step: 1) {
                Text("Keep history for")
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            HStack {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(RetentionStep(days: days) == step ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity,
                               alignment: i == 0 ? .leading : i == steps.count - 1 ? .trailing : .center)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Privacy

private struct PrivacyPage: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var selection = ViewState<String?>(nil)

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.hideDuringScreenSharing) {
                    Text("Hide during screen sharing")
                    Text("Keep the shelf and the paste stack out of screen recordings and shared screens.")
                }
                Toggle(isOn: $settings.linkPreviews) {
                    Text("Load link previews")
                    Text("Fetch page titles and images for copied links. Opening a link this way can count as a visit.")
                }
            }

            Section {
                Toggle(isOn: $settings.skipConcealed) {
                    Text("Skip passwords")
                    Text("Don't save clips that password managers mark as private.")
                }
                Toggle(isOn: $settings.skipTransient) {
                    Text("Skip temporary clips")
                    Text("Don't save clips that apps mark as temporary or generated automatically.")
                }
            }

            Section {
                ForEach(settings.excludedBundleIDs, id: \.self) { id in
                    HStack(spacing: 10) {
                        Image(nsImage: Self.icon(id)).resizable().frame(width: 24, height: 24)
                        Text(Self.name(id))
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .background(selection.value == id ? Color.accentColor.opacity(0.15) : Color.clear)
                    .onTapGesture { selection.value = id }
                }
                HStack(spacing: 12) {
                    Button(action: addApp) { Image(systemName: "plus") }
                    Divider().frame(height: 14)
                    Button {
                        settings.excludedBundleIDs.removeAll { $0 == selection.value }
                        selection.value = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection.value == nil)
                    Spacer()
                }
                .buttonStyle(.plain)
            } header: {
                Text("Ignore these apps")
                Text("Nothing you copy while one of these apps is in front is saved.")
                    .font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
            }
        }
    }

    private static func appURL(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    private static func name(_ id: String) -> String {
        appURL(id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
    }

    private static func icon(_ id: String) -> NSImage {
        appURL(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(id) {
                settings.excludedBundleIDs.append(id)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Open PasteClip") { ShortcutField(combo: $settings.shelfHotKey, settings: settings) }
                LabeledContent("Start or stop paste stack") { ShortcutField(combo: $settings.stackHotKey, settings: settings) }
                LabeledContent("Paste next from stack") { ShortcutField(combo: $settings.pasteNextHotKey, settings: settings) }
            } footer: {
                Text("These work from any app.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Next pinboard") { ShortcutField(combo: $settings.nextPinboardKey, settings: settings) }
                LabeledContent("Previous pinboard") { ShortcutField(combo: $settings.previousPinboardKey, settings: settings) }
                Picker("Quick paste", selection: $settings.quickPasteModifier) {
                    ForEach([ModifierKey.command, .option, .control]) { Text("\($0.title) + 1…9").tag($0) }
                }
                Picker("Paste as plain text", selection: $settings.plainTextModifier) {
                    ForEach([ModifierKey.shift, .option]) { Text("\($0.title) + Return").tag($0) }
                }
            } footer: {
                Text("These work while the shelf is open.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Shortcuts to Defaults…") {
                        let alert = NSAlert()
                        alert.messageText = "Reset all shortcuts?"
                        alert.addButton(withTitle: "Reset")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { settings.resetShortcuts() }
                    }
                }
            }
        }
    }
}

/// Field that records the next key combination pressed.
private struct ShortcutField: View {
    @Binding var combo: KeyCombo?
    let settings: AppSettings
    @StateObject private var recording = ViewState(false)
    @StateObject private var monitor = ViewState<Any?>(nil)

    var body: some View {
        HStack(spacing: 6) {
            Text(recording.value ? "Type shortcut…" : combo?.display ?? "None")
                .foregroundStyle(recording.value || combo == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity)
            if combo != nil, !recording.value {
                Button { combo = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .font(.system(size: 13, design: .rounded))
        .padding(.horizontal, 10)
        .frame(width: 170, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(recording.value ? Color.accentColor : Color.primary.opacity(0.15),
                          lineWidth: recording.value ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { recording.value ? stop() : start() }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording.value = true
        settings.isRecordingShortcut = true
        monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            var mods = 0
            if flags.contains(.command) { mods |= KeyCombo.command }
            if flags.contains(.shift) { mods |= KeyCombo.shift }
            if flags.contains(.option) { mods |= KeyCombo.option }
            if flags.contains(.control) { mods |= KeyCombo.control }
            combo = KeyCombo(keyCode: Int(event.keyCode), modifiers: mods, keyName: Self.keyName(event))
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor.value { NSEvent.removeMonitor(m) }
        monitor.value = nil
        if recording.value { settings.isRecordingShortcut = false }
        recording.value = false
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = specialKeys[event.keyCode] { return name }
        return (event.characters(byApplyingModifiers: []) ?? "?").uppercased()
    }
}
