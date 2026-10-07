import Foundation
import Security

/// This device's voice install id: a random UUID minted on first use and sent
/// to the relay as `x-bento-install`, so each device gets its own voice quota
/// (and one person's can be raised without raising a whole network's).
///
/// It is random, never derived from hardware ids, identifierForVendor or the
/// Apple ID. Stored in the Keychain this-device-only (no iCloud sync), so it
/// survives app updates and usually reinstalls, but not a new device.
public enum VoiceInstallID {
    /// The relay header that carries it.
    public static let header = "x-bento-install"

    private static let service = "com.novashang.paloally"
    private static let account = "voice.install-id"
    private static let lock = NSLock()
    private static var cached: String?

    /// The id, minted and saved on first call.
    public static var current: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let id = resolve(load: loadFromKeychain, save: saveToKeychain)
        cached = id
        return id
    }

    /// The first 8 characters, for showing in Settings.
    public static var short: String { String(current.prefix(8)) }

    /// A stored id when it's a valid UUID, otherwise a fresh one (saved).
    /// Lower-case, the form the relay keys its ledger by.
    static func resolve(load: () -> String?, save: (String) -> Void) -> String {
        if let stored = load(), let uuid = UUID(uuidString: stored) {
            return uuid.uuidString.lowercased()
        }
        let fresh = UUID().uuidString.lowercased()
        save(fresh)
        return fresh
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func loadFromKeychain() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToKeychain(_ id: String) {
        let data = Data(id.utf8)
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(q as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}
