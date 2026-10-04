import CryptoKit
import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Pairing")
struct PairingTests {
    let hostKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation

    func link(code: String = "123456", relay: String = "https://relay.bentoai.dev") -> String {
        "paloally://pair?relay=\(relay)&daemon=d-abc&code=\(code)&hostkey=\(hostKey.base64URLEncodedString())"
    }

    @Test func parsesLink() throws {
        let l = try PairingLink.parse(link())
        #expect(l.relay.absoluteString == "https://relay.bentoai.dev")
        #expect(l.daemonID == "d-abc")
        #expect(l.code == "123456")
        #expect(l.hostKey == hostKey)
        // Round trip through `url`.
        #expect(try PairingLink.parse(l.url.absoluteString) == l)
    }

    @Test func parsesLinkEmbeddedInText() throws {
        let l = try PairingLink.parse("扫不了的话复制这个：\n\(link()) 谢谢")
        #expect(l.daemonID == "d-abc")
    }

    @Test func percentEncodedRelayAndPaddedHostKey() throws {
        let padded = hostKey.base64EncodedString()
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
        let s = "paloally://pair?relay=https%3A%2F%2Frelay.example.com%2Fbase&daemon=d1&code=000001&hostkey=\(padded)"
        let l = try PairingLink.parse(s)
        #expect(l.relay.absoluteString == "https://relay.example.com/base")
        #expect(l.hostKey == hostKey)
    }

    @Test func defaultsRelayWhenMissing() throws {
        let l = try PairingLink.parse("paloally://pair?daemon=d1&code=000001&hostkey=\(hostKey.base64URLEncodedString())")
        #expect(l.relay == PairingLink.defaultRelay)
    }

    @Test func rejectsBadLinks() {
        #expect(throws: PairingLink.ParseError.notAPairingLink) { try PairingLink.parse("https://example.com") }
        #expect(throws: PairingLink.ParseError.missingDaemon) {
            try PairingLink.parse("paloally://pair?code=123456&hostkey=\(hostKey.base64URLEncodedString())")
        }
        #expect(throws: PairingLink.ParseError.badHostKey) { try PairingLink.parse("paloally://pair?daemon=d&code=123456&hostkey=abc") }
        #expect(throws: PairingLink.ParseError.badCode) { try PairingLink.parse(link(code: "12ab56")) }
        #expect(throws: PairingLink.ParseError.badRelay) { try PairingLink.parse(link(relay: "ftp://x")) }
    }

    @Test func codeOptionalUnlessRequired() throws {
        let s = "paloally://pair?daemon=d1&hostkey=\(hostKey.base64URLEncodedString())"
        #expect(try PairingLink.parse(s).code == "")
        #expect(throws: PairingLink.ParseError.badCode) { try PairingLink.parse(s, requireCode: true) }
    }

    @Test func pairURLAndTunnelURL() throws {
        #expect(PairingClient.pairURL(relay: URL(string: "https://r.dev")!, daemonID: "d 1").absoluteString
                == "https://r.dev/v1/pair?daemon_id=d%201")
        let host = PairedHost(relay: URL(string: "https://r.dev/")!, daemonID: "d1", deviceID: "dev1", hostKey: hostKey,
                              hostLabel: "Mac", hostFingerprint: "SHA256:x")
        let id = DeviceIdentity(privateKey: .init())
        let url = try host.tunnelURL(identity: id, now: Date(timeIntervalSince1970: 100))
        #expect(url.scheme == "wss")
        #expect(url.path == "/v1/tunnel")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.map(\.name) == ["daemon_id", "device_id", "ts", "pubkey", "sig"])
    }

    final class FakeHTTP: HTTPClient, @unchecked Sendable {
        var lastURL: URL?
        var lastBody: Data?
        let status: Int
        let response: String
        init(status: Int, response: String) { self.status = status; self.response = response }
        func post(_ url: URL, json: Data) async throws -> (Data, Int) {
            lastURL = url; lastBody = json
            return (Data(response.utf8), status)
        }
    }

    @Test func pairingSuccess() async throws {
        let http = FakeHTTP(status: 200, response: #"{"status":"ok","device_id":"dev-7","host_fingerprint":"SHA256:abc","daemon_label":"Nova 的 Mac"}"#)
        let id = DeviceIdentity(privateKey: .init())
        let host = try await PairingClient(http: http).pair(link: try PairingLink.parse(link()), identity: id, deviceLabel: "iPhone")
        #expect(host.deviceID == "dev-7")
        #expect(host.hostLabel == "Nova 的 Mac")
        #expect(host.hostFingerprint == "SHA256:abc")
        #expect(host.hostKey == hostKey)
        #expect(http.lastURL?.absoluteString == "https://relay.bentoai.dev/v1/pair?daemon_id=d-abc")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(http.lastBody))
        #expect(body["code"] == "123456")
        #expect(body["device_label"] == "iPhone")
        #expect(body["device_pubkey"] == id.sshWirePublicKeyBase64)

        // Persist / load.
        let store = InMemorySecretStore()
        try host.save(to: store)
        #expect(PairedHost.load(from: store) == host)
        PairedHost.forget(in: store)
        #expect(PairedHost.load(from: store) == nil)
    }

    @Test func pairingErrors() async throws {
        let id = DeviceIdentity(privateKey: .init())
        let l = try PairingLink.parse(link())
        for (status, body) in [(401, #"{"error":"bad code"}"#), (429, #"{"error":"pairing locked"}"#),
                               (503, #"{"error":"daemon offline"}"#), (502, #"{"status":"error","error":"denied"}"#)] {
            await #expect(throws: PairingError.self) {
                _ = try await PairingClient(http: FakeHTTP(status: status, response: body)).pair(link: l, identity: id, deviceLabel: "x")
            }
        }
        await #expect(throws: PairingError.malformedResponse) {
            _ = try await PairingClient(http: FakeHTTP(status: 200, response: #"{"status":"ok"}"#)).pair(link: l, identity: id, deviceLabel: "x")
        }
        var noCode = l
        noCode.code = "12"
        await #expect(throws: PairingError.invalidCode) {
            _ = try await PairingClient(http: FakeHTTP(status: 200, response: "{}")).pair(link: noCode, identity: id, deviceLabel: "x")
        }
    }
}
