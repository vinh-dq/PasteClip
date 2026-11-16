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
    @Published public var iCloudSync: Bool { didSet { defaults.set(iCloudSync, forKey: "iCloudSync") } }
    @Published public var shelfHotKey: KeyCombo? { didSet { store(shelfHotKey, "shelfHotKey") } }
    @Published public var stackHotKey: KeyCombo? { didSet { store(stackHotKey, "stackHotKey") } }
    @Published public var pasteNextHotKey: KeyCombo? { didSet { store(pasteNextHotKey, "pasteNextHotKey") } }
    @Published public var nextPinboardKey: KeyCombo? { didSet { store(nextPinboardKey, "nextPinboardKey") } }
    @Published public var previousPinboardKey: KeyCombo? { didSet { store(previousPinboardKey, "previousPinboardKey") } }
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
        iCloudSync = defaults.bool(forKey: "iCloudSync")
        shelfHotKey = Self.load(defaults, "shelfHotKey", default: .openShelf)
        stackHotKey = Self.load(defaults, "stackHotKey", default: .toggleStack)
        pasteNextHotKey = Self.load(defaults, "pasteNextHotKey", default: .pasteNext)
        nextPinboardKey = Self.load(defaults, "nextPinboardKey", default: .nextPinboard)
        previousPinboardKey = Self.load(defaults, "previousPinboardKey", default: .previousPinboard)
        quickPasteModifier = ModifierKey(rawValue: defaults.string(forKey: "quickPasteModifier") ?? "") ?? .command
        plainTextModifier = ModifierKey(rawValue: defaults.string(forKey: "plainTextModifier") ?? "") ?? .shift
        pasteMode = PasteMode(rawValue: defaults.string(forKey: "pasteMode") ?? "") ?? .frontApp
        alwaysPlainText = defaults.bool(forKey: "alwaysPlainText")
        hideDuringScreenSharing = defaults.bool(forKey: "hideDuringScreenSharing")
        linkPreviews = defaults.object(forKey: "linkPreviews") as? Bool ?? true
        skipConcealed = defaults.object(forKey: "skipConcealed") as? Bool ?? true
        skipTransient = defaults.object(forKey: "skipTransient") as? Bool ?? true
    }

    public func resetShortcuts() {
        shelfHotKey = .openShelf
        stackHotKey = .toggleStack
        pasteNextHotKey = .pasteNext
        nextPinboardKey = .nextPinboard
        previousPinboardKey = .previousPinboard
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
