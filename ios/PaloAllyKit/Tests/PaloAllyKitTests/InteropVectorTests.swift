import CryptoKit
import Foundation
import Testing
@testable import PaloAllyKit

/// Cross-implementation vectors produced by the host (TypeScript) side.
/// See Fixtures/README.md for the format. Skipped when the file is absent.
struct E2EVector: Decodable {
    var name: String?
    var device_seed_hex: String
    var device_pub_b64: String?
    var host_pub_b64: String?
    var device_ssh_wire_b64: String?
    var host_seed_hex: String
    var eph_c_seed_hex: String
    var eph_h_seed_hex: String
    var eph_c_pub_b64: String
    var eph_h_pub_b64: String
    var client_sig_b64: String?
    var host_sig_b64: String?
    var k_c2h_hex: String
    var k_h2c_hex: String
    var plaintext: String
    var c2h_unit0_hex: String
    var h2c_unit0_hex: String?
}

enum VectorFile {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/e2e-vectors.json")

    static func load() throws -> [E2EVector]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if let list = try? JSONDecoder().decode([E2EVector].self, from: data) { return list }
        struct Wrapped: Decodable { var vectors: [E2EVector] }
        if let w = try? JSONDecoder().decode(Wrapped.self, from: data) { return w.vectors }
        return [try JSONDecoder().decode(E2EVector.self, from: data)]
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Suite("Interop vectors")
struct InteropVectorTests {
    @Test(.enabled(if: VectorFile.exists, "Fixtures/e2e-vectors.json not present yet"))
    func hostGeneratedVectors() throws {
        let vectors = try #require(try VectorFile.load())
        #expect(!vectors.isEmpty)
        for v in vectors {
            try check(v)
        }
    }

    func check(_ v: E2EVector) throws {
        let label = v.name ?? "vector"
        let device = try DeviceIdentity(seed: try #require(Data(hex: v.device_seed_hex)))
        let host = try Curve25519.Signing.PrivateKey(rawRepresentation: try #require(Data(hex: v.host_seed_hex)))
        let ephC = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try #require(Data(hex: v.eph_c_seed_hex)))
        let ephH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try #require(Data(hex: v.eph_h_seed_hex)))
        let ephCPub = ephC.publicKey.rawRepresentation
        let ephHPub = ephH.publicKey.rawRepresentation

        if let s = v.device_pub_b64 { #expect(Data(base64URLEncoded: s) == device.publicKeyRaw, "\(label): device pub") }
        if let s = v.host_pub_b64 { #expect(Data(base64URLEncoded: s) == host.publicKey.rawRepresentation, "\(label): host pub") }
        if let s = v.device_ssh_wire_b64 {
            #expect(s == device.sshWirePublicKeyBase64 || Data(base64URLEncoded: s) == SSHWire.ed25519PublicKey(raw: device.publicKeyRaw),
                    "\(label): device ssh wire")
        }
        #expect(Data(base64URLEncoded: v.eph_c_pub_b64) == ephCPub, "\(label): eph_c pub")
        #expect(Data(base64URLEncoded: v.eph_h_pub_b64) == ephHPub, "\(label): eph_h pub")

        // Ed25519 signatures are deterministic per RFC 8032 but CryptoKit
        // randomises; so we VERIFY the host-produced signatures.
        if let s = v.client_sig_b64 {
            let sig = try #require(Data(base64URLEncoded: s))
            #expect(device.privateKey.publicKey.isValidSignature(sig, for: E2E.clientSignedBytes(ephC: ephCPub)),
                    "\(label): client sig")
        }
        if let s = v.host_sig_b64 {
            let sig = try #require(Data(base64URLEncoded: s))
            #expect(host.publicKey.isValidSignature(sig, for: E2E.hostSignedBytes(ephC: ephCPub, ephH: ephHPub)),
                    "\(label): host sig")
        }

        // Full handshake with the fixed ephemerals must land on the same keys.
        let client = ClientHandshake(identity: device, deviceID: "vector", hostKey: host.publicKey, ephemeral: ephC)
        let devicePub = device.privateKey.publicKey
        let responder = HostHandshakeResponder(hostKey: host, ephemeral: ephH) { _ in devicePub }
        let r = try responder.respond(to: try client.helloUnit())
        var channel = try client.finish(welcomeUnit: r.welcomeUnit)

        let kc2h = channel.sendKey.withUnsafeBytes { Data($0) }
        let kh2c = channel.receiveKey.withUnsafeBytes { Data($0) }
        #expect(kc2h.hexString == v.k_c2h_hex.lowercased(), "\(label): k_c2h")
        #expect(kh2c.hexString == v.k_h2c_hex.lowercased(), "\(label): k_h2c")

        let unit0 = try channel.seal(Data(v.plaintext.utf8))
        #expect(unit0.hexString == v.c2h_unit0_hex.lowercased(), "\(label): c2h unit 0 (incl. 0x02 type byte)")

        if let h2c = v.h2c_unit0_hex, let unit = Data(hex: h2c) {
            #expect(try channel.open(unit) == Data(v.plaintext.utf8), "\(label): h2c unit 0")
        }
    }

    /// Self-check of the vector format: generate a vector in Swift and run it
    /// through the same checker, so the format and checker stay honest even
    /// before the host-side file exists.
    @Test func selfGeneratedVectorRoundTrips() throws {
        let device = Curve25519.Signing.PrivateKey()
        let host = Curve25519.Signing.PrivateKey()
        let ephC = Curve25519.KeyAgreement.PrivateKey()
        let ephH = Curve25519.KeyAgreement.PrivateKey()
        let ephCPub = ephC.publicKey.rawRepresentation
        let ephHPub = ephH.publicKey.rawRepresentation
        let shared = try ephC.sharedSecretFromKeyAgreement(with: ephH.publicKey)
        let keys = E2E.deriveKeys(shared: shared, ephC: ephCPub, ephH: ephHPub)
        var ch = SecureChannel(sendKey: keys.c2h, receiveKey: keys.h2c)
        var hostCh = SecureChannel(sendKey: keys.h2c, receiveKey: keys.c2h)
        let plaintext = #"{"id":1,"method":"hello","params":{"client":"ios","version":"1"}}"#
        let v = E2EVector(
            name: "swift-self",
            device_seed_hex: device.rawRepresentation.hexString,
            device_pub_b64: device.publicKey.rawRepresentation.base64EncodedString(),
            host_pub_b64: host.publicKey.rawRepresentation.base64EncodedString(),
            device_ssh_wire_b64: SSHWire.ed25519PublicKey(raw: device.publicKey.rawRepresentation).base64EncodedString(),
            host_seed_hex: host.rawRepresentation.hexString,
            eph_c_seed_hex: ephC.rawRepresentation.hexString,
            eph_h_seed_hex: ephH.rawRepresentation.hexString,
            eph_c_pub_b64: ephCPub.base64EncodedString(),
            eph_h_pub_b64: ephHPub.base64EncodedString(),
            client_sig_b64: try device.signature(for: E2E.clientSignedBytes(ephC: ephCPub)).base64EncodedString(),
            host_sig_b64: try host.signature(for: E2E.hostSignedBytes(ephC: ephCPub, ephH: ephHPub)).base64EncodedString(),
            k_c2h_hex: keys.c2h.withUnsafeBytes { Data($0) }.hexString,
            k_h2c_hex: keys.h2c.withUnsafeBytes { Data($0) }.hexString,
            plaintext: plaintext,
            c2h_unit0_hex: try ch.seal(Data(plaintext.utf8)).hexString,
            h2c_unit0_hex: try hostCh.seal(Data(plaintext.utf8)).hexString
        )
        try check(v)
    }
}
