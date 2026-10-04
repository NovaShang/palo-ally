import CryptoKit
import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Crypto")
struct CryptoTests {
    @Test func base64url() {
        let d = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
        let s = d.base64URLEncodedString()
        #expect(!s.contains("+") && !s.contains("/") && !s.contains("="))
        #expect(Data(base64URLEncoded: s) == d)
        #expect(Data(base64URLEncoded: d.base64EncodedString()) == d)
        #expect(Data(hex: "00ff10") == Data([0, 255, 16]))
        #expect(Data([0, 255, 16]).hexString == "00ff10")
    }

    @Test func sshWireRoundTrip() throws {
        let id = DeviceIdentity(privateKey: .init())
        let wire = SSHWire.ed25519PublicKey(raw: id.publicKeyRaw)
        #expect(wire.count == 51)
        #expect(Array(wire.prefix(4)) == [0, 0, 0, 11])
        #expect(String(data: wire[4..<15], encoding: .ascii) == "ssh-ed25519")
        #expect(Array(wire[15..<19]) == [0, 0, 0, 32])
        #expect(SSHWire.rawEd25519(fromWire: wire) == id.publicKeyRaw)
        // Matches what the relay's extractRawEd25519FromSSHWire reads (bytes 19..51 of the base64 payload).
        let decoded = Data(base64Encoded: id.sshWirePublicKeyBase64)!
        #expect(decoded[19..<51] == id.publicKeyRaw)
        #expect(SSHWire.rawEd25519(fromWire: Data(count: 51)) == nil)
    }

    @Test func identityPersistsInStore() throws {
        let store = InMemorySecretStore()
        let a = try DeviceIdentity.loadOrCreate(store: store)
        let b = try DeviceIdentity.loadOrCreate(store: store)
        #expect(a.publicKeyRaw == b.publicKeyRaw)
        try store.delete(DeviceIdentity.storageAccount)
        let c = try DeviceIdentity.loadOrCreate(store: store)
        #expect(c.publicKeyRaw != a.publicKeyRaw)
    }

    @Test func tunnelChallengeSignature() throws {
        let id = DeviceIdentity(privateKey: .init())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = try id.tunnelQuery(daemonID: "d1", deviceID: "dev9", now: now)
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(q["ts"] == "1800000000")
        #expect(q["daemon_id"] == "d1")
        #expect(q["device_id"] == "dev9")
        let pub = Data(base64URLEncoded: q["pubkey"]!)!
        let sig = Data(base64URLEncoded: q["sig"]!)!
        #expect(pub == id.publicKeyRaw)
        #expect(sig.count == 64)
        #expect(!q["sig"]!.contains("=") && !q["pubkey"]!.contains("+"))
        let msg = Data("bento-device-attach:d1:dev9:1800000000".utf8)
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: pub).isValidSignature(sig, for: msg))
    }

    @Test func nonceLayout() {
        let n = Data(E2E.nonce(counter: 0x0102030405060708))
        #expect(Array(n) == [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(Array(Data(E2E.nonce(counter: 0))) == Array(repeating: 0, count: 12))
        #expect(Array(Data(E2E.nonce(counter: 1))) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    struct Pair {
        let device: DeviceIdentity
        let host: Curve25519.Signing.PrivateKey
        let client: ClientHandshake
        let responder: HostHandshakeResponder
    }

    func makePair(deviceID: String = "dev-1") -> Pair {
        let device = DeviceIdentity(privateKey: .init())
        let host = Curve25519.Signing.PrivateKey()
        let devicePub = device.privateKey.publicKey
        let client = ClientHandshake(identity: device, deviceID: deviceID, hostKey: host.publicKey)
        let responder = HostHandshakeResponder(hostKey: host) { $0 == deviceID ? devicePub : nil }
        return Pair(device: device, host: host, client: client, responder: responder)
    }

    @Test func helloUnitShape() throws {
        let p = makePair()
        let unit = try p.client.helloUnit()
        #expect(unit.first == 0x01)
        let obj = try JSONDecoder().decode(JSONValue.self, from: unit.dropFirst())
        #expect(obj["t"] == "hello")
        #expect(obj["v"] == .number(1))
        #expect(obj["device_id"] == "dev-1")
        // eph / sig are STANDARD base64 of 32 / 64 bytes.
        let eph = Data(base64Encoded: obj["eph"]!.stringValue!)!
        let sig = Data(base64Encoded: obj["sig"]!.stringValue!)!
        #expect(eph == p.client.ephemeralPublicRaw)
        #expect(eph.count == 32 && sig.count == 64)
        #expect(p.device.privateKey.publicKey.isValidSignature(sig, for: Data("paloally-hs1|c|".utf8) + eph))
    }

    @Test func handshakeAndBidirectionalSealing() throws {
        let p = makePair()
        let r = try p.responder.respond(to: try p.client.helloUnit())
        #expect(r.deviceID == "dev-1")
        #expect(r.welcomeUnit.first == 0x01)
        var c = try p.client.finish(welcomeUnit: r.welcomeUnit)
        var h = r.channel

        // Directional keys differ and mirror each other.
        #expect(c.sendKey == h.receiveKey)
        #expect(c.receiveKey == h.sendKey)
        #expect(c.sendKey != c.receiveKey)

        for i in 0..<5 {
            let pt = Data("c2h \(i) 你好".utf8)
            let unit = try c.seal(pt)
            #expect(unit.first == 0x02)
            #expect(unit.count == 1 + pt.count + 16)
            #expect(try h.open(unit) == pt)
        }
        #expect(c.sendCounter == 5 && h.receiveCounter == 5)
        let back = try h.seal(Data("h2c".utf8))
        #expect(try c.open(back) == Data("h2c".utf8))
        #expect(h.sendCounter == 1 && c.receiveCounter == 1)
    }

    @Test func keysMatchManualDerivation() throws {
        let p = makePair()
        let r = try p.responder.respond(to: try p.client.helloUnit())
        let c = try p.client.finish(welcomeUnit: r.welcomeUnit)
        let ephC = p.client.ephemeralPublicRaw
        let ephH = p.responder.ephemeral.publicKey.rawRepresentation
        let shared = try p.client.ephemeral.sharedSecretFromKeyAgreement(with: p.responder.ephemeral.publicKey)
        let ikm = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let manual = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: ephC + ephH, info: Data("paloally c2h".utf8), outputByteCount: 32)
        #expect(manual == c.sendKey)
        let manual2 = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: ephC + ephH, info: Data("paloally h2c".utf8), outputByteCount: 32)
        #expect(manual2 == c.receiveKey)
        // And the ciphertext is plain ChaChaPoly with the counter nonce.
        var c2 = c
        let unit = try c2.seal(Data("x".utf8))
        let box = try ChaChaPoly.seal(Data("x".utf8), using: manual, nonce: E2E.nonce(counter: 0))
        #expect(unit == Data([0x02]) + box.ciphertext + box.tag)
    }

    @Test func outOfOrderOrReplayedUnitsFail() throws {
        let p = makePair()
        let r = try p.responder.respond(to: try p.client.helloUnit())
        var c = try p.client.finish(welcomeUnit: r.welcomeUnit)
        var h = r.channel
        let u0 = try c.seal(Data("a".utf8))
        let u1 = try c.seal(Data("b".utf8))
        #expect(throws: E2EError.decryptFailed) { try h.open(u1) }   // skipped counter
        #expect(h.receiveCounter == 0)
        #expect(try h.open(u0) == Data("a".utf8))
        #expect(throws: E2EError.decryptFailed) { try h.open(u0) }   // replay
        #expect(try h.open(u1) == Data("b".utf8))
    }

    @Test func tamperedUnitFails() throws {
        let p = makePair()
        let r = try p.responder.respond(to: try p.client.helloUnit())
        var c = try p.client.finish(welcomeUnit: r.welcomeUnit)
        var h = r.channel
        var unit = try c.seal(Data("hello".utf8))
        unit[3] ^= 0x01
        #expect(throws: E2EError.decryptFailed) { try h.open(unit) }
        #expect(throws: E2EError.unexpectedUnitType(0x01)) { try h.open(Data([0x01, 0x00])) }
        #expect(throws: E2EError.decryptFailed) { try h.open(Data([0x02, 0x00])) }
    }

    @Test func wrongHostKeyRejected() throws {
        let p = makePair()
        let impostor = HostHandshakeResponder(hostKey: .init()) { _ in p.device.privateKey.publicKey }
        let r = try impostor.respond(to: try p.client.helloUnit())
        #expect(throws: E2EError.badSignature) { try p.client.finish(welcomeUnit: r.welcomeUnit) }
    }

    @Test func wrongDeviceKeyRejected() throws {
        let p = makePair()
        let other = Curve25519.Signing.PrivateKey().publicKey
        let responder = HostHandshakeResponder(hostKey: p.host) { _ in other }
        #expect(throws: E2EError.badSignature) { try responder.respond(to: try p.client.helloUnit()) }
        let unknown = HostHandshakeResponder(hostKey: p.host) { _ in nil }
        #expect(throws: E2EError.unknownDevice) { try unknown.respond(to: try p.client.helloUnit()) }
    }

    @Test func errorUnitSurfacesAsRejected() throws {
        let p = makePair()
        let unit = HostHandshakeResponder.errorUnit("unknown device")
        #expect(unit.first == 0x01)
        #expect(throws: E2EError.rejected("unknown device")) { try p.client.finish(welcomeUnit: unit) }
    }

    @Test func welcomeAcceptsUnpaddedBase64() throws {
        // Hosts may emit base64 without padding; we accept either.
        let p = makePair()
        let r = try p.responder.respond(to: try p.client.helloUnit())
        var msg = try HandshakeMessage.parse(unit: r.welcomeUnit)
        msg.eph = msg.eph?.replacingOccurrences(of: "=", with: "")
        msg.sig = msg.sig?.replacingOccurrences(of: "=", with: "")
        _ = try p.client.finish(welcomeUnit: try msg.unit())
    }
}

