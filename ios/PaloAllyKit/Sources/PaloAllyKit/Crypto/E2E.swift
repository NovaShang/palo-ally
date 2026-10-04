import CryptoKit
import Foundation

// End-to-end encryption over a relay stream — design.md §5.2.
//
// Every WebSocket message is one unit whose first byte is the type:
//   0x01 handshake: UTF-8 JSON
//   0x02 sealed:    ChaCha20-Poly1305 ciphertext || tag(16), empty AAD,
//                   nonce = 4 zero bytes || u64 big-endian counter.
// Counters are per direction, start at 0, and advance by one per sealed unit
// (handshake units do not advance them).

public enum UnitType: UInt8, Sendable {
    case handshake = 0x01
    case sealed = 0x02
}

public enum E2EError: Error, Equatable, LocalizedError, Sendable {
    case emptyUnit
    case unexpectedUnitType(UInt8)
    case malformedHandshake(String)
    case badSignature
    case unknownDevice
    case rejected(String)
    case decryptFailed
    case counterExhausted

    public var errorDescription: String? {
        switch self {
        case .emptyUnit: "empty unit"
        case .unexpectedUnitType(let t): "unexpected unit type 0x\(String(t, radix: 16))"
        case .malformedHandshake(let m): "malformed handshake: \(m)"
        case .badSignature: "handshake signature invalid"
        case .unknownDevice: "unknown device"
        case .rejected(let m): "host rejected handshake: \(m)"
        case .decryptFailed: "decrypt failed"
        case .counterExhausted: "nonce counter exhausted"
        }
    }
}

/// The handshake JSON (both directions; fields depend on `t`).
public struct HandshakeMessage: Codable, Sendable, Equatable {
    public var t: String
    public var v: Int?
    public var device_id: String?
    public var eph: String?
    public var sig: String?
    public var error: String?

    public init(t: String, v: Int? = 1, device_id: String? = nil, eph: String? = nil, sig: String? = nil, error: String? = nil) {
        self.t = t; self.v = v; self.device_id = device_id; self.eph = eph; self.sig = sig; self.error = error
    }

    public func unit() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data([UnitType.handshake.rawValue]) + (try enc.encode(self))
    }

    public static func parse(unit: Data) throws -> HandshakeMessage {
        guard let first = unit.first else { throw E2EError.emptyUnit }
        guard first == UnitType.handshake.rawValue else { throw E2EError.unexpectedUnitType(first) }
        do {
            return try JSONDecoder().decode(HandshakeMessage.self, from: unit.dropFirst())
        } catch {
            throw E2EError.malformedHandshake("json")
        }
    }
}

public enum E2E {
    public static let clientSigPrefix = Data("paloally-hs1|c|".utf8)
    public static let hostSigPrefix = Data("paloally-hs1|h|".utf8)
    public static let infoC2H = Data("paloally c2h".utf8)
    public static let infoH2C = Data("paloally h2c".utf8)

    public static func clientSignedBytes(ephC: Data) -> Data { clientSigPrefix + ephC }
    public static func hostSignedBytes(ephC: Data, ephH: Data) -> Data { hostSigPrefix + ephC + ephH }

    /// HKDF-SHA256(ikm = X25519 shared, salt = eph_c ‖ eph_h, info, 32).
    public static func deriveKeys(shared: SharedSecret, ephC: Data, ephH: Data) -> (c2h: SymmetricKey, h2c: SymmetricKey) {
        let salt = ephC + ephH
        let c2h = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: infoC2H, outputByteCount: 32)
        let h2c = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: infoH2C, outputByteCount: 32)
        return (c2h, h2c)
    }

    /// 12-byte nonce: 4 zero bytes followed by the big-endian counter.
    public static func nonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { bytes[4 + i] = UInt8((counter >> (8 * UInt64(7 - i))) & 0xff) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func decodeB64(_ s: String?, _ field: String, length: Int) throws -> Data {
        guard let s, let d = Data(base64URLEncoded: s), d.count == length else {
            throw E2EError.malformedHandshake(field)
        }
        return d
    }
}

/// Bidirectional sealed channel after a successful handshake. Not thread
/// safe — the owner must serialise `seal` (send order == counter order) and
/// `open` (receive order).
public struct SecureChannel: Sendable {
    public let sendKey: SymmetricKey
    public let receiveKey: SymmetricKey
    public private(set) var sendCounter: UInt64 = 0
    public private(set) var receiveCounter: UInt64 = 0

    public init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    /// Returns a full `0x02` unit.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter < UInt64.max else { throw E2EError.counterExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: E2E.nonce(counter: sendCounter))
        sendCounter += 1
        return Data([UnitType.sealed.rawValue]) + box.ciphertext + box.tag
    }

    /// Opens a full `0x02` unit. A failure leaves the counter untouched; the
    /// caller should treat it as fatal for the stream.
    public mutating func open(_ unit: Data) throws -> Data {
        guard let first = unit.first else { throw E2EError.emptyUnit }
        guard first == UnitType.sealed.rawValue else { throw E2EError.unexpectedUnitType(first) }
        let body = unit.dropFirst()
        guard body.count >= 16 else { throw E2EError.decryptFailed }
        guard receiveCounter < UInt64.max else { throw E2EError.counterExhausted }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: E2E.nonce(counter: receiveCounter),
                ciphertext: body.dropLast(16),
                tag: body.suffix(16)
            )
            let pt = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return pt
        } catch {
            throw E2EError.decryptFailed
        }
    }
}

/// Client (device) side of the handshake.
public struct ClientHandshake: Sendable {
    public let identity: DeviceIdentity
    public let deviceID: String
    public let hostKey: Curve25519.Signing.PublicKey
    public let ephemeral: Curve25519.KeyAgreement.PrivateKey

    public init(identity: DeviceIdentity, deviceID: String, hostKey: Curve25519.Signing.PublicKey,
                ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.identity = identity; self.deviceID = deviceID; self.hostKey = hostKey; self.ephemeral = ephemeral
    }

    public var ephemeralPublicRaw: Data { ephemeral.publicKey.rawRepresentation }

    public func helloMessage() throws -> HandshakeMessage {
        let ephC = ephemeralPublicRaw
        let sig = try identity.sign(E2E.clientSignedBytes(ephC: ephC))
        return HandshakeMessage(t: "hello", v: 1, device_id: deviceID, eph: ephC.base64EncodedString(),
                                sig: sig.base64EncodedString())
    }

    public func helloUnit() throws -> Data { try helloMessage().unit() }

    /// Verifies the host's `welcome` and derives the channel. A `0x01 error`
    /// unit surfaces as `.rejected`.
    public func finish(welcomeUnit: Data) throws -> SecureChannel {
        let msg = try HandshakeMessage.parse(unit: welcomeUnit)
        if msg.t == "error" { throw E2EError.rejected(msg.error ?? "unknown") }
        guard msg.t == "welcome" else { throw E2EError.malformedHandshake("expected welcome, got \(msg.t)") }
        let ephH = try E2E.decodeB64(msg.eph, "eph", length: 32)
        let sig = try E2E.decodeB64(msg.sig, "sig", length: 64)
        let ephC = ephemeralPublicRaw
        guard hostKey.isValidSignature(sig, for: E2E.hostSignedBytes(ephC: ephC, ephH: ephH)) else {
            throw E2EError.badSignature
        }
        let hostEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephH)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: hostEph)
        let keys = E2E.deriveKeys(shared: shared, ephC: ephC, ephH: ephH)
        return SecureChannel(sendKey: keys.c2h, receiveKey: keys.h2c)
    }
}

/// Host side of the handshake. Lives in the kit as the reference
/// implementation used by tests and the in-process fake host.
public struct HostHandshakeResponder: Sendable {
    public let hostKey: Curve25519.Signing.PrivateKey
    public let ephemeral: Curve25519.KeyAgreement.PrivateKey
    public let deviceKey: @Sendable (String) -> Curve25519.Signing.PublicKey?

    public init(hostKey: Curve25519.Signing.PrivateKey,
                ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
                deviceKey: @escaping @Sendable (String) -> Curve25519.Signing.PublicKey?) {
        self.hostKey = hostKey; self.ephemeral = ephemeral; self.deviceKey = deviceKey
    }

    public struct Result: Sendable {
        public let welcomeUnit: Data
        public let channel: SecureChannel
        public let deviceID: String
    }

    /// On failure throws; `errorUnit(for:)` builds the `0x01 {"t":"error"}` reply.
    public func respond(to helloUnit: Data) throws -> Result {
        let msg = try HandshakeMessage.parse(unit: helloUnit)
        guard msg.t == "hello" else { throw E2EError.malformedHandshake("expected hello") }
        guard let deviceID = msg.device_id, let devicePub = deviceKey(deviceID) else { throw E2EError.unknownDevice }
        let ephC = try E2E.decodeB64(msg.eph, "eph", length: 32)
        let sig = try E2E.decodeB64(msg.sig, "sig", length: 64)
        guard devicePub.isValidSignature(sig, for: E2E.clientSignedBytes(ephC: ephC)) else { throw E2EError.badSignature }
        let ephH = ephemeral.publicKey.rawRepresentation
        let hostSig = try hostKey.signature(for: E2E.hostSignedBytes(ephC: ephC, ephH: ephH))
        let welcome = HandshakeMessage(t: "welcome", v: 1, eph: ephH.base64EncodedString(), sig: hostSig.base64EncodedString())
        let clientEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephC)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: clientEph)
        let keys = E2E.deriveKeys(shared: shared, ephC: ephC, ephH: ephH)
        return Result(welcomeUnit: try welcome.unit(),
                      channel: SecureChannel(sendKey: keys.h2c, receiveKey: keys.c2h),
                      deviceID: deviceID)
    }

    public static func errorUnit(_ message: String) -> Data {
        (try? HandshakeMessage(t: "error", v: nil, error: message).unit()) ?? Data([UnitType.handshake.rawValue])
    }
}
