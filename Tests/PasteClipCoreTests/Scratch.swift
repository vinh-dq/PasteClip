import AppKit
import Foundation

/// Settings, folders and pasteboards of a test's own, so the user's are never touched, and
/// nothing is left behind when the test run ends: settings are kept in memory only (a
/// UserDefaults suite would leave a file in ~/Library/Preferences, written again by macOS even
/// after it's removed), and folders and pasteboards are removed.
enum Scratch {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var folders: [URL] = []
    private nonisolated(unsafe) static var pasteboards: [NSPasteboard] = []
    private static let cleanUpAtExit: Void = { atexit { Scratch.cleanUp() } }()

    private static func name() -> String { "PasteClipTests-\(UUID().uuidString)" }

    private static func keep(_ add: () -> Void) {
        _ = cleanUpAtExit
        lock.lock()
        add()
        lock.unlock()
    }

    static func defaults() -> UserDefaults { MemoryDefaults() }

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name(), isDirectory: true)
        keep { folders.append(url) }
        return url
    }

    static func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init(name()))
        keep { pasteboards.append(pasteboard) }
        return pasteboard
    }

    private static func cleanUp() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
    }
}

/// UserDefaults that keeps its values in memory. Its getters (`bool`, `string`, `data`…) and
/// setters go through `object(forKey:)` and `set(_:forKey:)`.
final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    override func removeObject(forKey key: String) { set(nil, forKey: key) }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
