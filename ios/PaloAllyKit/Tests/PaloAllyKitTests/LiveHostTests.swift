import Foundation
import Testing
@testable import PaloAllyKit

/// End-to-end against a real host + bento relay. Opt-in:
///   PALOALLY_LIVE_LINK=<paloally://pair… link or a file containing it> swift test --filter LiveHost
/// The pairing code is single-use, so each run needs a fresh link.
@MainActor
@Suite("Live host", .serialized)
struct LiveHostTests {
    nonisolated static var linkText: String? {
        guard let v = ProcessInfo.processInfo.environment["PALOALLY_LIVE_LINK"], !v.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: v) { return try? String(contentsOfFile: v, encoding: .utf8) }
        return v
    }

    @Test(.enabled(if: linkText != nil, "set PALOALLY_LIVE_LINK to run"))
    func pairConnectSyncChat() async throws {
        let link = try PairingLink.parse(try #require(Self.linkText), requireCode: true)
        let identity = DeviceIdentity(privateKey: .init())
        let host = try await PairingClient().pair(link: link, identity: identity, deviceLabel: "swift live test")
        #expect(!host.deviceID.isEmpty)

        let transport = RelayTransport(host: host, identity: identity)
        let store = AppStore(transport: transport, clientKind: "ios", clientVersion: "test")
        store.start()
        #expect(await until(10) { store.connection == .online }, "connection: \(store.connection)")
        #expect(!store.hostName.isEmpty)
        #expect(store.settings != nil)
        #expect(store.status != nil)

        let before = store.messages.count
        store.send("你好，live")
        #expect(await until(10) { store.messages.count >= before + 2 && !store.isBusy })
        let user = try #require(store.messages.first { $0.role == .user && $0.text == "你好，live" })
        #expect(user.seq > 0 && user.delivery == .sent)
        #expect(store.messages.filter { $0.text == "你好，live" }.count == 1)
        let reply = try #require(store.messages.last)
        #expect(reply.role == .assistant && reply.seq > user.seq && !reply.isStreaming)
        #expect(store.lastSeq == reply.seq)

        let files = try await store.memoryFiles()
        #expect(!files.isEmpty)
        try await store.updateSettings(patch: ["probeIntervalMinutes": 4])
        #expect(store.settings?.probeIntervalMinutes == 4)
        let w = try #require(try await store.addWatch(WatchDraft(title: "live", kind: .check, instruction: "看看", intervalMinutes: 60)))
        try await store.removeWatch(id: w.id)

        // Reconnect: a fresh E2E session + sync{sinceSeq} catches up.
        await transport.stop()
        #expect(await until(5) { store.connection != .online })
        await transport.start()
        #expect(await until(10) { store.connection == .online })
        #expect(store.lastSeq == reply.seq)
        store.shutdown()
    }
}
