import Foundation

/// A global shortcut. `modifiers` uses Carbon's flags so it can go straight to RegisterEventHotKey.
public struct KeyCombo: Codable, Equatable {
    public static let command = 0x100, shift = 0x200, option = 0x800, control = 0x1000

    public var keyCode: Int
    public var modifiers: Int
    /// What to show for the key itself, e.g. "V" or "Space".
    public var keyName: String

    public init(keyCode: Int, modifiers: Int, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + keyName
    }

    // V = 9, C = 8
    public static let openShelf = KeyCombo(keyCode: 9, modifiers: command | shift, keyName: "V")
    public static let toggleStack = KeyCombo(keyCode: 8, modifiers: control | command, keyName: "C")
    public static let pasteNext = KeyCombo(keyCode: 9, modifiers: control | command, keyName: "V")
    // → = 124, ← = 123. Only active while the shelf is open.
    public static let nextPinboard = KeyCombo(keyCode: 124, modifiers: command, keyName: "→")
    public static let previousPinboard = KeyCombo(keyCode: 123, modifiers: command, keyName: "←")
    // 2 = 19. ⇧⌘3, 4 and 5 are the system's screenshot shortcuts. ⇧⌘2 translates an area of the
    // screen; copying its text moved to ⌥⇧⌘2 in 1.7.
    public static let captureText = KeyCombo(keyCode: 19, modifiers: option | command | shift, keyName: "2")
    public static let translateScreen = KeyCombo(keyCode: 19, modifiers: command | shift, keyName: "2")
    // Space = 49.
    public static let translate = KeyCombo(keyCode: 49, modifiers: control, keyName: "Space")
    // 1 = 18, next to ⇧⌘2 for text.
    public static let captureArea = KeyCombo(keyCode: 18, modifiers: command | shift, keyName: "1")
    // Space = 49. Only active while the shelf is open, where ⌃Space translates text.
    public static let translateImage = KeyCombo(keyCode: 49, modifiers: control | option, keyName: "Space")
    // P = 35. Floats the latest image, or the ones selected in the shelf.
    public static let floatImage = KeyCombo(keyCode: 35, modifiers: command | option, keyName: "P")

    /// Whether macOS has this shortcut turned on for itself (System Settings → Keyboard → Keyboard
    /// Shortcuts), such as ⌃Space for switching input sources. macOS gets the key first then.
    public func isUsedBySystem(_ symbolicHotKeys: [String: Any]? = Self.systemHotKeys()) -> Bool {
        var cocoa = 0
        if modifiers & Self.shift != 0 { cocoa |= 0x20000 }
        if modifiers & Self.control != 0 { cocoa |= 0x40000 }
        if modifiers & Self.option != 0 { cocoa |= 0x80000 }
        if modifiers & Self.command != 0 { cocoa |= 0x100000 }
        return (symbolicHotKeys ?? [:]).values.contains { value in
            guard let entry = value as? [String: Any], (entry["enabled"] as? Bool) == true,
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count >= 3
            else { return false }
            // Parameters are the character, the key code and the modifiers; the function-key flag
            // (0x800000) that arrows and F-keys carry doesn't matter here.
            return parameters[1] == keyCode && parameters[2] & ~0x800000 == cocoa
        }
    }

    public static func systemHotKeys() -> [String: Any]? {
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    }
}

/// What happens to a screenshot of an area once it's saved and copied.
public enum ScreenshotAction: String, CaseIterable, Identifiable {
    case offer, copy, edit, float
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .offer: return "Copy it and offer Edit, Float and Translate"
        case .copy: return "Copy it"
        case .edit: return "Copy it and open it for marking up"
        case .float: return "Copy it and float it on the screen"
        }
    }
}

/// What choosing a clip does.
public enum PasteMode: String, CaseIterable, Identifiable {
    /// Put it on the clipboard and send ⌘V to the app you were using.
    case frontApp
    /// Only put it on the clipboard.
    case clipboard
    public var id: String { rawValue }
}

/// A single modifier key, used for quick paste and plain-text paste.
public enum ModifierKey: String, CaseIterable, Identifiable {
    case command, option, control, shift
    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    public var title: String {
        switch self {
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        }
    }
}

/// Steps of the "Keep history" slider, in days (0 = forever).
public enum RetentionStep: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30, year = 365, forever = 0
    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .forever: return "Forever"
        }
    }

    /// The closest step for a number of days.
    public init(days: Int) {
        if days <= 0 { self = .forever; return }
        self = [RetentionStep.day, .week, .month, .year].min { abs($0.rawValue - days) < abs($1.rawValue - days) }!
    }
}

public enum ShelfEdge: String, CaseIterable, Identifiable {
    case bottom, top
    public var id: String { rawValue }
    public var title: String { self == .bottom ? "Bottom of screen" : "Top of screen" }
}

/// User preferences, saved in UserDefaults as they change.
public final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published public var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    /// 0 keeps history forever.
    @Published public var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published public var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published public var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published public var shelfEdge: ShelfEdge { didSet { defaults.set(shelfEdge.rawValue, forKey: "shelfEdge") } }
    @Published public var shelfHotKey: KeyCombo? { didSet { store(shelfHotKey, "shelfHotKey") } }
    @Published public var stackHotKey: KeyCombo? { didSet { store(stackHotKey, "stackHotKey") } }
    @Published public var pasteNextHotKey: KeyCombo? { didSet { store(pasteNextHotKey, "pasteNextHotKey") } }
    @Published public var nextPinboardKey: KeyCombo? { didSet { store(nextPinboardKey, "nextPinboardKey") } }
    @Published public var previousPinboardKey: KeyCombo? { didSet { store(previousPinboardKey, "previousPinboardKey") } }
    @Published public var captureTextHotKey: KeyCombo? { didSet { store(captureTextHotKey, "captureTextHotKey") } }
    /// In the shelf: floats the selected images, translated where their text is.
    @Published public var translateImageKey: KeyCombo? { didSet { store(translateImageKey, "translateImageKey") } }
    /// Translates an area of the screen, shown over it.
    @Published public var translateScreenHotKey: KeyCombo? { didSet { store(translateScreenHotKey, "translateScreenHotKey") } }
    /// Takes a screenshot of an area, saved as an image clip.
    @Published public var screenshotHotKey: KeyCombo? { didSet { store(screenshotHotKey, "screenshotHotKey") } }
    @Published public var screenshotAction: ScreenshotAction {
        didSet { defaults.set(screenshotAction.rawValue, forKey: "screenshotAction") }
    }
    /// Floats the latest image clip, or the ones selected in the shelf, or the image being edited.
    @Published public var floatImageKey: KeyCombo? { didSet { store(floatImageKey, "floatImageKey") } }
    @Published public var quickPasteModifier: ModifierKey { didSet { defaults.set(quickPasteModifier.rawValue, forKey: "quickPasteModifier") } }
    @Published public var plainTextModifier: ModifierKey { didSet { defaults.set(plainTextModifier.rawValue, forKey: "plainTextModifier") } }

    @Published public var pasteMode: PasteMode { didSet { defaults.set(pasteMode.rawValue, forKey: "pasteMode") } }
    @Published public var alwaysPlainText: Bool { didSet { defaults.set(alwaysPlainText, forKey: "alwaysPlainText") } }

    @Published public var hideDuringScreenSharing: Bool { didSet { defaults.set(hideDuringScreenSharing, forKey: "hideDuringScreenSharing") } }
    @Published public var linkPreviews: Bool { didSet { defaults.set(linkPreviews, forKey: "linkPreviews") } }
    /// Skip clips marked `org.nspasteboard.ConcealedType` (passwords).
    @Published public var skipConcealed: Bool { didSet { defaults.set(skipConcealed, forKey: "skipConcealed") } }
    /// Skip clips marked `org.nspasteboard.TransientType` or `AutoGeneratedType`.
    @Published public var skipTransient: Bool { didSet { defaults.set(skipTransient, forKey: "skipTransient") } }

    /// Languages to read on screen and in copied images, most likely first.
    @Published public var textLanguages: [String] { didSet { defaults.set(textLanguages, forKey: "textLanguages") } }
    /// Keep the lines of text read from the screen as they are, rather than joining them into paragraphs.
    @Published public var keepLineBreaks: Bool { didSet { defaults.set(keepLineBreaks, forKey: "keepLineBreaks") } }
    /// Look for text in copied images so they can be searched and pasted as text.
    @Published public var findTextInImages: Bool { didSet { defaults.set(findTextInImages, forKey: "findTextInImages") } }

    @Published public var translateHotKey: KeyCombo? { didSet { store(translateHotKey, "translateHotKey") } }
    /// Languages to translate into, in order: text goes into the first one it isn't already in.
    @Published public var translationTargets: [String] { didSet { defaults.set(translationTargets, forKey: "translationTargets") } }
    @Published public var translationService: TranslationService {
        didSet { defaults.set(translationService.rawValue, forKey: "translationService") }
    }
    /// The translate shortcut takes the text selected in the front app, if there is any, before the clipboard.
    @Published public var translateSelection: Bool { didSet { defaults.set(translateSelection, forKey: "translateSelection") } }
    /// Show a translation of text copied from the screen.
    @Published public var translateScreenText: Bool { didSet { defaults.set(translateScreenText, forKey: "translateScreenText") } }
    /// Add copied and pasted translations to history.
    @Published public var saveTranslations: Bool { didSet { defaults.set(saveTranslations, forKey: "saveTranslations") } }
    /// Add images translated where their text is to history.
    @Published public var saveImageTranslations: Bool {
        didSet { defaults.set(saveImageTranslations, forKey: "saveImageTranslations") }
    }
    /// The model chosen for each AI service, by its raw value; a missing one uses the service's default.
    @Published public var translationModels: [String: String] {
        didSet { defaults.set(translationModels, forKey: "translationModels") }
    }
    /// Models each AI provider listed for the user's key, by the service's raw value, newest first.
    @Published public var translationModelLists: [String: [String]] {
        didSet { defaults.set(translationModelLists, forKey: "translationModelLists") }
    }
    /// Show the original text under its translation. Remembers the last choice made in the panel.
    @Published public var translationShowsOriginal: Bool {
        didSet { defaults.set(translationShowsOriginal, forKey: "translationShowsOriginal") }
    }
    /// Azure region of the Microsoft Translator key; empty for a global resource.
    @Published public var microsoftRegion: String { didSet { defaults.set(microsoftRegion, forKey: "microsoftRegion") } }

    /// True while a shortcut field is listening, so global hotkeys can step aside. Not saved.
    @Published public var isRecordingShortcut = false

    public static let historyLimits = [100, 250, 500, 1000, 5000]
    public static let retentionChoices = [0, 1, 7, 30, 90, 365]
    public static let defaultExcluded = ["com.apple.keychainaccess", "com.apple.Passwords"]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyLimit = defaults.object(forKey: "historyLimit") as? Int ?? 500
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 0
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? Self.defaultExcluded
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? false
        shelfEdge = ShelfEdge(rawValue: defaults.string(forKey: "shelfEdge") ?? "") ?? .bottom
        shelfHotKey = Self.load(defaults, "shelfHotKey", default: .openShelf)
        stackHotKey = Self.load(defaults, "stackHotKey", default: .toggleStack)
        pasteNextHotKey = Self.load(defaults, "pasteNextHotKey", default: .pasteNext)
        nextPinboardKey = Self.load(defaults, "nextPinboardKey", default: .nextPinboard)
        previousPinboardKey = Self.load(defaults, "previousPinboardKey", default: .previousPinboard)
        captureTextHotKey = Self.load(defaults, "captureTextHotKey", default: .captureText)
        floatImageKey = Self.load(defaults, "floatImageKey", default: .floatImage)
        screenshotHotKey = Self.load(defaults, "screenshotHotKey", default: .captureArea)
        translateScreenHotKey = Self.load(defaults, "translateScreenHotKey", default: .translateScreen)
        translateImageKey = Self.load(defaults, "translateImageKey", default: .translateImage)
        screenshotAction = ScreenshotAction(rawValue: defaults.string(forKey: "screenshotAction") ?? "") ?? .offer
        quickPasteModifier = ModifierKey(rawValue: defaults.string(forKey: "quickPasteModifier") ?? "") ?? .command
        plainTextModifier = ModifierKey(rawValue: defaults.string(forKey: "plainTextModifier") ?? "") ?? .shift
        pasteMode = PasteMode(rawValue: defaults.string(forKey: "pasteMode") ?? "") ?? .frontApp
        alwaysPlainText = defaults.bool(forKey: "alwaysPlainText")
        hideDuringScreenSharing = defaults.bool(forKey: "hideDuringScreenSharing")
        linkPreviews = defaults.object(forKey: "linkPreviews") as? Bool ?? true
        skipConcealed = defaults.object(forKey: "skipConcealed") as? Bool ?? true
        skipTransient = defaults.object(forKey: "skipTransient") as? Bool ?? true
        textLanguages = defaults.stringArray(forKey: "textLanguages") ?? TextRecognizer.defaultLanguages
        keepLineBreaks = defaults.object(forKey: "keepLineBreaks") as? Bool ?? true
        findTextInImages = defaults.object(forKey: "findTextInImages") as? Bool ?? true
        translateHotKey = Self.load(defaults, "translateHotKey", default: .translate)
        translationTargets = defaults.stringArray(forKey: "translationTargets") ?? Translator.defaultTargets
        translationService = TranslationService(rawValue: defaults.string(forKey: "translationService") ?? "") ?? .google
        translateSelection = defaults.object(forKey: "translateSelection") as? Bool ?? true
        translateScreenText = defaults.bool(forKey: "translateScreenText")
        saveTranslations = defaults.object(forKey: "saveTranslations") as? Bool ?? true
        saveImageTranslations = defaults.object(forKey: "saveImageTranslations") as? Bool ?? true
        microsoftRegion = defaults.string(forKey: "microsoftRegion") ?? ""
        translationModelLists = defaults.dictionary(forKey: "translationModelLists") as? [String: [String]] ?? [:]
        translationShowsOriginal = defaults.object(forKey: "translationShowsOriginal") as? Bool ?? true
        translationModels = defaults.dictionary(forKey: "translationModels") as? [String: String] ?? [:]
        // ⇧⌘2 copied text from the screen before it translated it; a copy of that shortcut saved
        // then (by resetting shortcuts) moves along with the new default.
        if defaults.data(forKey: "translateScreenHotKey") == nil, captureTextHotKey == .translateScreen {
            captureTextHotKey = .captureText
            store(captureTextHotKey, "captureTextHotKey")
        }
        // Floating an image was ⇧⌘P, VS Code's Command Palette, at first; a key kept as it was moves
        // to the new default once.
        if !defaults.bool(forKey: "floatImageKeyMoved") {
            if floatImageKey == KeyCombo(keyCode: 35, modifiers: KeyCombo.command | KeyCombo.shift, keyName: "P") {
                floatImageKey = .floatImage
            }
            defaults.set(true, forKey: "floatImageKeyMoved")
        }
    }

    public func resetShortcuts() {
        shelfHotKey = .openShelf
        stackHotKey = .toggleStack
        pasteNextHotKey = .pasteNext
        nextPinboardKey = .nextPinboard
        previousPinboardKey = .previousPinboard
        captureTextHotKey = .captureText
        floatImageKey = .floatImage
        screenshotHotKey = .captureArea
        translateScreenHotKey = .translateScreen
        translateImageKey = .translateImage
        translateHotKey = .translate
        quickPasteModifier = .command
        plainTextModifier = .shift
    }

    /// A missing key means "use the default"; a stored empty value means "no shortcut".
    private static func load(_ defaults: UserDefaults, _ key: String, default value: KeyCombo) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return value }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private func store(_ combo: KeyCombo?, _ key: String) {
        defaults.set(combo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }
}
