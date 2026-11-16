import Foundation
import PasteClipCore
import Security

/// API keys for translation services, kept together in one item of the login keychain.
///
/// macOS ties a keychain item to the build that may read it, and PasteClip isn't signed by an
/// Apple developer team, so after an update macOS asks for the login password before the new
/// build reads the keys ("Always Allow" ends that until the next update). To ask as little as
/// possible, all keys share one item, and it's read only when a key is needed, once per launch:
/// opening the app or Settings, or translating with a service without a key, never reads it.
/// Which services have a key is kept apart in UserDefaults, without the keys.
final class APIKeys: ObservableObject {
    private static let keychainService = "PasteClip Translation"
    private static let account = "keys"
    private static let savedKey = "translationKeysSaved"

    /// Services with a saved key.
    @Published private(set) var saved: Set<TranslationService>
    /// The keys, once read from the keychain.
    private var keys: [TranslationService: String]?
    /// Where 1.6 development builds kept keys before they went back to the keychain.
    private let legacyFile: URL

    init(directory: URL) {
        legacyFile = directory.appendingPathComponent("api-keys.json")
        let names = UserDefaults.standard.stringArray(forKey: Self.savedKey)
            ?? Self.legacyItemAccounts() + (Self.readLegacyFile(legacyFile)?.keys.map { $0 } ?? [])
        saved = Set(names.compactMap(TranslationService.init(rawValue:)))
        // Keys left in a plain file move into the keychain straight away.
        if FileManager.default.fileExists(atPath: legacyFile.path) { _ = load() }
    }

    func hasKey(_ service: TranslationService) -> Bool { saved.contains(service) }

    /// The service's key, read from the keychain the first time a key is needed. Empty if there
    /// is none, or if the keychain couldn't be read (macOS asked and was told no).
    func key(for service: TranslationService) -> String {
        guard saved.contains(service), load() else { return "" }
        return keys?[service] ?? ""
    }

    /// Services that can be used now: those without a key, and those with one saved.
    var available: [TranslationService] {
        TranslationService.allCases.filter { !$0.needsKey || saved.contains($0) }
    }

    /// Saves `key`, or removes the saved one when it's empty. False if the keychain couldn't be
    /// read or written, in which case nothing changes.
    @discardableResult
    func set(_ key: String, for service: TranslationService) -> Bool {
        guard load(), var updated = keys else { return false }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[service] = key.isEmpty ? nil : key
        guard write(updated) else { return false }
        keys = updated
        record(Set(updated.keys))
        return true
    }

    // MARK: - Keychain

    private static func query(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: account]
    }

    /// Reads the keys once. False if the keychain refused, so nothing gets overwritten.
    private func load() -> Bool {
        if keys != nil { return true }
        var query = Self.query(account: Self.account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var loaded: [TranslationService: String] = [:]
        switch status {
        case errSecSuccess:
            let names = (result as? Data).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            for (name, key) in names { if let service = TranslationService(rawValue: name) { loaded[service] = key } }
        case errSecItemNotFound:
            break
        default:
            return false
        }
        keys = loaded
        migrateLegacyKeys()
        record(Set(keys?.keys.map { $0 } ?? []))
        return true
    }

    private func write(_ keys: [TranslationService: String]) -> Bool {
        let names = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(names) else { return false }
        let query = Self.query(account: Self.account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "PasteClip translation API keys"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func record(_ services: Set<TranslationService>) {
        if saved != services { saved = services }
        UserDefaults.standard.set(services.map(\.rawValue).sorted(), forKey: Self.savedKey)
    }

    // MARK: - Earlier ways of keeping keys

    /// Keys from the plain file and from the one-item-per-service keychain entries of earlier
    /// builds move into the shared item; the old copies are then removed.
    private func migrateLegacyKeys() {
        var merged = keys ?? [:]
        let fromFile = Self.readLegacyFile(legacyFile)
        for (name, key) in fromFile ?? [:] {
            if let service = TranslationService(rawValue: name), !key.isEmpty { merged[service] = key }
        }
        // An old item is read (which can ask for the password) only for a key not found yet.
        let accounts = Self.legacyItemAccounts()
        for account in accounts {
            guard let service = TranslationService(rawValue: account), merged[service] == nil else { continue }
            var query = Self.query(account: account)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let key = (result as? Data).flatMap({ String(data: $0, encoding: .utf8) }), !key.isEmpty {
                merged[service] = key
            }
        }
        guard !accounts.isEmpty || fromFile != nil else { return }
        guard merged == keys || write(merged) else { return }
        keys = merged
        for account in accounts { SecItemDelete(Self.query(account: account) as CFDictionary) }
        try? FileManager.default.removeItem(at: legacyFile)
    }

    /// Accounts of the old per-service items, found from their attributes only, which macOS
    /// gives without asking for the password.
    private static func legacyItemAccounts() -> [String] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
                                      kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != account }
    }

    private static func readLegacyFile(_ url: URL) -> [String: String]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }
}
