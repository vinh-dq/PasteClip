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
    private let keys: APIKeys
    private let page = ViewState(SettingsPage.general)

    init(settings: AppSettings, store: ClipStore, sync: CloudSync, keys: APIKeys) {
        self.settings = settings
        self.store = store
        self.sync = sync
        self.keys = keys
    }

    func show(_ initialPage: SettingsPage? = nil) {
        if let initialPage { page.value = initialPage }
        if window == nil {
            let root = SettingsView(settings: settings, store: store, sync: sync, keys: keys, page: page)
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
    case general, text, translation, privacy, shortcuts
    var id: String { rawValue }

    var title: String { self == .text ? "Text Recognition" : rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .text: return "text.viewfinder"
        case .translation: return "character.bubble"
        case .privacy: return "hand.raised"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let store: ClipStore
    @ObservedObject var sync: CloudSync
    let keys: APIKeys
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
                case .text: TextRecognitionPage(settings: settings)
                case .translation: TranslationPage(settings: settings, keys: keys)
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

// MARK: - Text recognition

private struct TextRecognitionPage: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var hasAccess = ViewState(ScreenTextCapture.hasAccess)
    /// English, Vietnamese, Japanese and Chinese first, then the rest by name.
    private let languages = TextRecognizer.defaultLanguages + TextRecognizer.supportedLanguages
        .filter { !TextRecognizer.defaultLanguages.contains($0) }
        .sorted { TextRecognizer.name(of: $0).localizedStandardCompare(TextRecognizer.name(of: $1)) == .orderedAscending }

    var body: some View {
        Form {
            Section {
                LabeledContent("Copy text from screen") { ShortcutField(combo: $settings.captureTextHotKey, settings: settings) }
                LabeledContent {
                    if hasAccess.value {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…", action: ScreenTextCapture.openPrivacySettings)
                    }
                } label: {
                    Text("Screen recording")
                    Text(hasAccess.value
                         ? "Only the area you pick is read, on this Mac."
                         : "Needed to read the screen. After turning it on, quit and reopen PasteClip.")
                }
                Toggle(isOn: $settings.keepLineBreaks) {
                    Text("Keep line breaks")
                    Text("Turn off to join wrapped lines into paragraphs.")
                }
                Toggle(isOn: $settings.findTextInImages) {
                    Text("Find text in copied images")
                    Text("Copied images can be searched, and pasted as text with \(settings.plainTextModifier.symbol) Return.")
                }
            } footer: {
                Text("Press the shortcut, then drag over the text, or press Space and click a window. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(languages, id: \.self) { language in
                    Toggle(TextRecognizer.name(of: language), isOn: binding(for: language))
                        .disabled(settings.textLanguages == [language])
                }
            } header: {
                HStack {
                    Text("Languages")
                    Spacer()
                    Button("Reset to Defaults") { settings.textLanguages = TextRecognizer.defaultLanguages }
                        .disabled(settings.textLanguages == TextRecognizer.defaultLanguages)
                }
                Text("Turn on only the languages you read, for the most accurate text.")
                    .font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccess.value = ScreenTextCapture.hasAccess
        }
    }

    private func binding(for language: String) -> Binding<Bool> {
        Binding(get: { settings.textLanguages.contains(language) }, set: { on in
            settings.textLanguages.removeAll { $0 == language }
            if on { settings.textLanguages.append(language) }
        })
    }
}

// MARK: - Translation

private struct TranslationPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var keys: APIKeys

    var body: some View {
        Form {
            Section {
                LabeledContent("Translate") { ShortcutField(combo: $settings.translateHotKey, settings: settings) }
                Toggle(isOn: $settings.translateSelection) {
                    Text("Translate the selected text")
                    Text("The shortcut translates what's selected in the app you're using, or the clipboard if nothing is. "
                         + "The clipboard is left as it was.")
                }
                Toggle(isOn: $settings.translateScreenText) {
                    Text("Translate text copied from the screen")
                    Text("Show a translation after \(settings.captureTextHotKey?.display ?? "Copy Text from Screen").")
                }
                Toggle(isOn: $settings.saveTranslations) {
                    Text("Save translations to history")
                    Text("Translations you copy or paste are added to the clip list, from “Translation”. Turn off to only put them on the clipboard.")
                }
            } footer: {
                Text("In a translation, 1–\(min(settings.translationTargets.count, 9)) picks the language, ↑ ↓ the service, Return copies, "
                     + "⌘Return pastes into the app, ⌘S saves to history, Esc closes. With the shelf open, the shortcut translates the selected clips.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Array(settings.translationTargets.enumerated()), id: \.element) { i, language in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14)
                        Text(Translator.name(of: language))
                        Spacer()
                        Group {
                            Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(i == settings.translationTargets.count - 1)
                            Button { settings.translationTargets.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .disabled(settings.translationTargets.count <= 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add Language") {
                    ForEach(Translator.languages.filter { !settings.translationTargets.contains($0) }, id: \.self) { language in
                        Button(Translator.name(of: language)) { settings.translationTargets.append(language) }
                    }
                }
                .fixedSize()
                .disabled(settings.translationTargets.count == Translator.languages.count)
            } header: {
                HStack {
                    Text("Translate into")
                    Spacer()
                    Button("Reset to Defaults") { settings.translationTargets = Translator.defaultTargets }
                        .disabled(settings.translationTargets == Translator.defaultTargets)
                }
                Text(orderHint).font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
            }

            Section {
                ForEach(TranslationService.allCases.filter { !$0.isAI }) { service in
                    ServiceRow(service: service, settings: settings, keys: keys)
                }
            } header: {
                Text("Service")
                Text("Google, Bing and Apple work without setup. The others use your own API key, which is checked before "
                     + "it's saved and kept in your keychain. After a PasteClip update, macOS may ask once before "
                     + "reading it; choose Always Allow.")
                    .font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
            }

            Section {
                ForEach(TranslationService.allCases.filter(\.isAI)) { service in
                    ServiceRow(service: service, settings: settings, keys: keys)
                }
            } header: {
                Text("AI")
                Text("Language models follow context and keep the tone, but take a few seconds and bill each "
                     + "translation to your API key. Pick the model when you add the key.")
                    .font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
            }
        }
    }

    /// "Vietnamese text goes into English; anything else into Vietnamese."
    private var orderHint: String {
        let targets = settings.translationTargets
        guard targets.count > 1 else { return "Everything is translated into \(targets.first.map(Translator.name(of:)) ?? "")." }
        return "Text goes into the first language it isn't already in: \(Translator.name(of: targets[0])) text into "
            + "\(Translator.name(of: targets[1])), anything else into \(Translator.name(of: targets[0]))."
    }

    private func move(_ i: Int, by delta: Int) {
        let j = i + delta
        guard settings.translationTargets.indices.contains(j) else { return }
        settings.translationTargets.swapAt(i, j)
    }
}

/// One translation service: pick it, see what it means for your text, and add its key if it needs one.
private struct ServiceRow: View {
    let service: TranslationService
    @ObservedObject var settings: AppSettings
    @ObservedObject var keys: APIKeys
    @StateObject private var editingKey = ViewState(false)

    private var selected: Bool { settings.translationService == service }
    private var hasKey: Bool { keys.hasKey(service) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .opacity(service.needsKey && !hasKey ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(service.title)
                            if service.isAI { Self.badge("AI", .purple) }
                            badge
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if service == .apple {
                Button("Languages…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
                .help("Download or remove translation languages in System Settings")
            } else if service.needsKey {
                Button(hasKey ? "Edit Key…" : "Add Key…") { editingKey.value = true }
                    .sheet(isPresented: $editingKey.value) {
                        APIKeyEditor(service: service, keys: keys, settings: settings) { editingKey.value = false }
                    }
            }
        }
        .controlSize(.small)
        .padding(.vertical, 3)
    }

    /// A service without a key can't be picked yet; choosing it asks for one.
    private func select() {
        if service.needsKey && !hasKey { editingKey.value = true } else { settings.translationService = service }
    }

    private var badge: some View {
        let (label, color): (String, Color) = switch service {
        case .google, .bing: ("Free", .green)
        case .apple: ("Offline", .blue)
        default: hasKey ? ("Key saved", .green) : ("API key", .secondary)
        }
        return Self.badge(label, color)
    }

    private static func badge(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var detail: String {
        switch service {
        case .google: return "No setup, and strong with Vietnamese. Text is sent to Google through an unofficial API that Google may limit."
        case .bing: return "No setup, with Microsoft's engine. Text is sent to Microsoft through Bing's web translator, which Microsoft may limit."
        case .apple: return "Runs on this Mac, so text never leaves it. Each language downloads the first time it's used."
        case .googleCloud: return "Google's official API, billed to your Google Cloud account after a free monthly allowance."
        case .deepL: return "Very natural wording. The DeepL API Free plan has a monthly allowance."
        case .microsoft: return "Microsoft's Azure Translator, with a free monthly allowance."
        default:
            let model = settings.translationModels[service.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? service.defaultModel ?? ""
            let maker = ["openAI": "OpenAI", "claude": "Anthropic", "gemini": "Google", "deepSeek": "DeepSeek", "grok": "xAI"][service.rawValue] ?? ""
            return "Uses \(model). Text is sent to \(maker) with your API key."
        }
    }
}

/// A sheet on the Settings window for a service's API key (and region or model). A sheet stays
/// open while you switch to another app to copy the key, and keeps what you've typed.
/// The key is saved only after a test translation works.
private struct APIKeyEditor: View {
    let service: TranslationService
    @ObservedObject var keys: APIKeys
    @ObservedObject var settings: AppSettings
    let close: () -> Void
    @StateObject private var draft: ViewState<String>
    @StateObject private var model: ViewState<String>
    @StateObject private var showsKey = ViewState(false)
    @StateObject private var testing = ViewState(false)
    @StateObject private var error = ViewState<String?>(nil)
    @StateObject private var refreshing = ViewState(false)
    @FocusState private var focus: Field?

    private enum Field { case key, region, model }

    init(service: TranslationService, keys: APIKeys, settings: AppSettings, close: @escaping () -> Void) {
        self.service = service
        self.keys = keys
        self.settings = settings
        self.close = close
        // A saved key isn't put back in the field: it shows as dots, and stays unless a new one is typed.
        _draft = StateObject(wrappedValue: ViewState(""))
        let saved = settings.translationModels[service.rawValue] ?? ""
        _model = StateObject(wrappedValue: ViewState(saved.isEmpty ? service.defaultModel ?? "" : saved))
    }

    private var hasKey: Bool { keys.hasKey(service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: service.isAI ? "sparkles" : "key.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(service.isAI ? Color.purple : Color.accentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(service.title) API Key").font(.title3.weight(.semibold))
                    Text(hasKey ? "Your key is saved. Change the key or the model, then test again to save the change."
                                : "PasteClip translates “Hello” with the key to check it, then keeps it in your keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                row("API key") {
                    Group {
                        if showsKey.value {
                            TextField(keyPlaceholder, text: $draft.value)
                        } else {
                            SecureField(keyPlaceholder, text: $draft.value)
                        }
                    }
                    .focused($focus, equals: .key)
                    .roomyField(focused: focus == .key)
                    .onSubmit(test)
                } accessory: {
                    Button { showsKey.value.toggle() } label: {
                        Image(systemName: showsKey.value ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showsKey.value ? "Hide the key" : "Show the key")
                } note: {
                    if hasKey {
                        let kept = draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Label(kept ? "Key saved in your keychain. Paste a new one only to replace it." : "New key — Test & Save to keep it",
                              systemImage: kept ? "checkmark.circle.fill" : "pencil.circle")
                            .foregroundStyle(kept ? Color.green : Color.orange)
                    }
                }
                if service == .microsoft {
                    row("Region") {
                        TextField("southeastasia", text: $settings.microsoftRegion)
                            .focused($focus, equals: .region)
                            .roomyField(focused: focus == .region, monospaced: false)
                    } accessory: {
                        EmptyView()
                    } note: {
                        Text("The Azure region of your Translator resource. Leave empty for a global one.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let defaultModel = service.defaultModel {
                    row("Model") {
                        TextField(defaultModel, text: $model.value)
                            .focused($focus, equals: .model)
                            .roomyField(focused: focus == .model)
                            .onSubmit(test)
                    } accessory: {
                        Menu {
                            Button("\(defaultModel) (default)") { model.value = defaultModel }
                            Divider()
                            let listed = settings.translationModelLists[service.rawValue] ?? []
                            Section(listed.isEmpty ? "Suggested" : "From \(service.title)") {
                                ForEach((listed.isEmpty ? service.suggestedModels : listed).filter { $0 != defaultModel }, id: \.self) { name in
                                    Button(name) { model.value = name }
                                }
                            }
                            Divider()
                            Button("Update List from \(service.title)", action: refreshModels)
                                .disabled(!canTest || refreshing.value)
                        } label: {
                            Image(systemName: refreshing.value ? "arrow.triangle.2.circlepath" : "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Pick a model")
                    } note: {
                        Text("\(defaultModel) is the default: fast and cheap. Pick another from the list, or type any model name \(service.title) offers. "
                             + "The list comes from \(service.title) when the key is saved; Update List in the menu fetches it again.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            Group {
                if testing.value {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Testing the key…") }
                        .foregroundStyle(.secondary)
                } else if let message = error.value {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.bottom, testing.value || error.value != nil ? 16 : 0)

            Divider()

            HStack {
                if let url = service.keyURL {
                    Link(destination: url) { Label("Get a Key", systemImage: "arrow.up.right.square") }
                }
                Spacer()
                if hasKey {
                    Button("Remove Key", role: .destructive) {
                        keys.set("", for: service)
                        if settings.translationService == service { settings.translationService = .google }
                        close()
                    }
                }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Test & Save", action: test)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canTest || testing.value)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .onAppear { focus = .key }
    }

    /// A labelled field: the label on the left, the field filling the width, a button beside it
    /// (each row keeps the same room for one, so the fields line up), and a note underneath.
    private func row<Field: View, Accessory: View, Note: View>(
        _ label: String, @ViewBuilder field: () -> Field, @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder note: () -> Note
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(label).frame(width: 64, alignment: .trailing)
                field().frame(maxWidth: .infinity)
                accessory().frame(width: 28)
            }
            note()
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 74)
                .padding(.trailing, 38)
        }
    }

    private var keyPlaceholder: String {
        hasKey ? String(repeating: "•", count: 24) : "Paste your API key"
    }

    /// A key was typed, or one is saved. Doesn't read the keychain, so drawing the sheet never asks for the password.
    private var canTest: Bool {
        hasKey || !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The key typed in, or else the saved one, read from the keychain.
    private var keyToTest: String {
        let typed = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? keys.key(for: service) : typed
    }

    /// Asks the provider which models the key can use, for the menu.
    private func refreshModels() {
        let translator = WebTranslator(service: service, key: keyToTest)
        refreshing.value = true
        error.value = nil
        Task { @MainActor in
            do {
                let names = try await translator.models()
                if !names.isEmpty { settings.translationModelLists[service.rawValue] = names }
            } catch {
                self.error.value = "Couldn't get the list of models: \(error.localizedDescription)"
            }
            refreshing.value = false
        }
    }

    private func test() {
        let key = keyToTest
        guard !key.isEmpty, !testing.value else { return }
        let model = model.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let translator = WebTranslator(service: service, key: key, region: settings.microsoftRegion, model: model)
        testing.value = true
        error.value = nil
        Task { @MainActor in
            do {
                _ = try await translator.translate("Hello", to: "vi")
                guard keys.set(key, for: service) else {
                    self.error.value = "The key works, but PasteClip couldn't save it in your keychain. Try again, and allow access if macOS asks."
                    testing.value = false
                    return
                }
                // The default is stored as empty, so a newer default reaches it later.
                if let defaultModel = service.defaultModel {
                    settings.translationModels[service.rawValue] = model == defaultModel ? "" : model
                }
                settings.translationService = service
                close()
                // A fresh list of models for the menu, after the sheet has closed.
                if service.isAI, let names = try? await WebTranslator(service: service, key: key).models(), !names.isEmpty {
                    settings.translationModelLists[service.rawValue] = names
                }
            } catch {
                self.error.value = error.localizedDescription
            }
            testing.value = false
        }
    }
}

private extension View {
    /// A tall text field with room around the text, for keys and model names.
    func roomyField(focused: Bool, monospaced: Bool = true) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: focused ? 2 : 1))
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
                LabeledContent("Copy text from screen") { ShortcutField(combo: $settings.captureTextHotKey, settings: settings) }
                LabeledContent("Translate selection or clipboard") { ShortcutField(combo: $settings.translateHotKey, settings: settings) }
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
            if let combo, !recording.value, combo.isUsedBySystem() {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("macOS uses \(combo.display) too, so it won't reach PasteClip. Turn it off in System Settings → "
                          + "Keyboard → Keyboard Shortcuts, or pick another shortcut.")
            }
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
