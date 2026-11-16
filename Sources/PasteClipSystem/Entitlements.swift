import Security

/// Reads this process's code-signing entitlements, so features that need them can be
/// switched off cleanly in ad-hoc builds instead of crashing.
public enum Entitlements {
    public static func value(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    public static var iCloudContainers: [String] {
        value("com.apple.developer.icloud-container-identifiers") as? [String] ?? []
    }

    public static var hasCloudKit: Bool {
        let services = value("com.apple.developer.icloud-services") as? [String] ?? []
        return services.contains("CloudKit") && !iCloudContainers.isEmpty
    }
}
