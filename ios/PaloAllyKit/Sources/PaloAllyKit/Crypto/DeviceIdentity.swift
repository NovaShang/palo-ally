import CryptoKit
import Foundation
import Security

// MARK: - Secret storage

/// Small blob storage for secrets. Keychain in the app, in-memory in tests.
public protocol SecretStore: Sendable {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(_ account: String) throws -> Data? { lock.withLock { items[account] } }
    public func save(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    public func delete(_ account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? { "这台设备没法安全保存配对信息" }
}

/// Generic-password Keychain storage. Items are device-only and readable after
/// first unlock so a background reconnect (e.g. after a push) still works.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.novashang.paloally") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        q[kSecUseDataProtectionKeychain as String] = true
        return q
    }

    public func load(_ account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    public func save(_ data: Data, for account: String) throws {
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

// MARK: - Device identity

/// The device's long-lived Ed25519 identity. Its public key is registered with
/// the relay + host at pairing time; it signs relay attach challenges and the
/// E2E handshake.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) { self.privateKey = privateKey }

    public init(seed: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    public static let storageAccount = "device-ed25519"

    /// Loads the identity from storage, creating and persisting one if absent.
    public static func loadOrCreate(store: SecretStore) throws -> DeviceIdentity {
        if let raw = try store.load(storageAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        {
            return DeviceIdentity(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try store.save(key.rawRepresentation, for: storageAccount)
        return DeviceIdentity(privateKey: key)
    }

    public var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }

    /// `device_pubkey` for `POST /v1/pair`: SSH wire format, standard base64.
    public var sshWirePublicKeyBase64: String {
        SSHWire.ed25519PublicKey(raw: publicKeyRaw).base64EncodedString()
    }

    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message)
    }

    /// Relay tunnel attach challenge: `bento-device-attach:<daemon_id>:<device_id>:<ts>`.
    public static func attachChallenge(daemonID: String, deviceID: String, ts: Int64) -> Data {
        Data("bento-device-attach:\(daemonID):\(deviceID):\(ts)".utf8)
    }

    /// Query items for `GET wss /v1/tunnel` (pubkey/sig base64url, no padding).
    public func tunnelQuery(daemonID: String, deviceID: String, now: Date = Date()) throws -> [URLQueryItem] {
        let ts = Int64(now.timeIntervalSince1970)
        let sig = try sign(Self.attachChallenge(daemonID: daemonID, deviceID: deviceID, ts: ts))
        return [
            URLQueryItem(name: "daemon_id", value: daemonID),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "ts", value: String(ts)),
            URLQueryItem(name: "pubkey", value: publicKeyRaw.base64URLEncodedString()),
            URLQueryItem(name: "sig", value: sig.base64URLEncodedString()),
        ]
    }
}
