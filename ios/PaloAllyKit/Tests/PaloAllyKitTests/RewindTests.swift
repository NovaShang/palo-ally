import Foundation
import Testing
@testable import PaloAllyKit

/// 回到这里重来 (docs/rewind-prd.md): the wire shapes, and the store going
/// back to just before one of the owner's messages, in the assistant's
/// conversation and in a Pal's.
@MainActor
@Suite("回到这里重来", .serialized)
struct RewindTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> (T, [String]) {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LenientDiagnostics.collect { try v.decode(T.self) }
    }

    @Test func wireShapes() throws {
        let (m, mi) = try decode(ChatMessage.self, #"{"seq":3,"id":"m3","role":"user","kind":"text","text":"订餐厅","channel":"app","ts":1,"uuid":"6f1c"}"#)
        #expect(mi.isEmpty && m.uuid == "6f1c")
        let (r, ri) = try decode(ChatRewound.self, #"{"id":"m3","ids":["m3","m4"],"pal":"p1"}"#)
        #expect(ri.isEmpty && r == ChatRewound(id: "m3", ids: ["m3", "m4"], pal: "p1"))
        let (s, si) = try decode(SyncResult.self, #"{"seq":9,"messages":[],"tasks":[],"approvals":[],"watches":[],"artifacts":[],"settings":{"timezone":"UTC","quietHours":null,"maxProactivePerDay":5,"probeIntervalMinutes":10,"approvalTimeoutMinutes":30,"wechatProactive":"hint"},"status":{"online":true,"busy":false,"model":"m","wechat":"off","version":"1"},"rewound":["m3"]}"#)
        #expect(s.rewound == ["m3"])
        _ = si
        let (pr, pri) = try decode(PalRewindResult.self, #"{"text":"改成 two","filesRestored":true}"#)
        #expect(pri.isEmpty && pr.text == "改成 two" && pr.filesRestored)
        let (pc, pci) = try decode(PalRewindCheck.self, #"{"canRestoreFiles":false}"#)
        #expect(pci.isEmpty && !pc.canRestoreFiles)
        let (_, missing) = try decode(PalRewindResult.self, #"{}"#)
        #expect(missing.count == 2)
    }

    private func paloStore(speed: Double = 0) async -> (AppStore, DemoHost) {
        let host = DemoHost(speed: speed, seeded: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online }
        return (store, host)
    }

    @Test func offeredOnlyOnTheOwnersSentWordsTheHostKnows() async throws {
        let (store, _) = await paloStore()
        let own = try #require(store.messages.first { $0.role == .user })
        #expect(own.uuid != nil && store.canRewind(to: own))
        let reply = try #require(store.messages.first { $0.role == .assistant })
        #expect(!store.canRewind(to: reply))
        var older = own
        older.uuid = nil // kept before it had one, and not matched in the transcript
        #expect(!store.canRewind(to: older))
        var unsent = own
        unsent.seq = 0
        unsent.delivery = .sending
        #expect(!store.canRewind(to: unsent))
    }

    @Test func goingBackDropsThatMessageAndWhatCameAfterAndGivesItsWordsBack() async throws {
        let (store, host) = await paloStore()
        var animated = 0
        store.animateRewind = { apply in animated += 1; apply() }
        let users = store.messages.filter { $0.role == .user && store.canRewind(to: $0) }
        let target = try #require(users.dropFirst().first ?? users.first)
        let i = try #require(store.messages.firstIndex { $0.id == target.id })
        let kept = store.messages[..<i].map(\.id)
        store.rewindTarget = target
        let outcome = try await store.rewind(to: target)
        #expect(outcome == RewindOutcome(text: target.text, filesRestored: false))
        #expect(store.messages.map(\.id) == kept)
        #expect(store.rewindTarget == nil)
        #expect(animated == 1)
        #expect(await host.messages.map(\.id) == kept)
        #expect(await host.lastParams["chat.rewind"] == ["messageId": .string(target.id)])
        // The host's event, after the answer, finds nothing more to drop.
        #expect(await until { store.messages.map(\.id) == kept })
        // The next message goes on from there (the gap the rewind's seq left is caught up).
        store.send("改过的话")
        #expect(await until { store.messages.last?.role == .assistant && store.messages.last?.isStreaming == false })
        #expect(store.messages.filter { $0.text == "改过的话" }.count == 1)
    }

    @Test func whileItsWorkingItIsStoppedFirst() async throws {
        let (store, host) = await paloStore(speed: 1)
        store.send("帮我写一封很长的邮件")
        #expect(await until { store.messages.contains { $0.text == "帮我写一封很长的邮件" && $0.seq > 0 } && store.status?.busy == true })
        let target = try #require(store.messages.last { $0.text == "帮我写一封很长的邮件" })
        #expect(store.busyForRewind)
        let outcome = try await store.rewind(to: target)
        #expect(outcome.text == "帮我写一封很长的邮件")
        let log = await host.requestLog
        let stop = try #require(log.lastIndex(of: "stop"))
        #expect(log.firstIndex(of: "chat.rewind")! < stop && log.lastIndex(of: "chat.rewind")! > stop)
        #expect(!store.messages.contains { $0.id == target.id })
    }

    @Test func anotherDevicesRewindAndOneMissedWhileAway() async throws {
        let (store, _) = await paloStore()
        let ids = store.messages.map(\.id)
        // chat.rewound from the host: that message and everything after it
        store.apply(event: RPCEventName.chatRewound, data: ["id": .string(ids[5]), "ids": .array([])])
        #expect(store.messages.map(\.id) == Array(ids[..<5]))
        // sync's rewound: those ids, wherever they are
        store.applySync(SyncResult(seq: store.lastSeq + 1, messages: [], rewound: [ids[1]]), since: store.lastSeq)
        #expect(store.messages.map(\.id) == [ids[0]] + Array(ids[2..<5]))
    }

    private func palStore() async -> (AppStore, AppStore, DemoHost) {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        _ = await until { store.connection == .online && store.pals.count == 4 }
        let site = store.palStore("pal-site")
        _ = await until { site.hasSynced }
        return (store, site, host)
    }

    @Test func aPalGoesBackWithItsFilesAndItsPageIsReadAgain() async throws {
        let (store, site, host) = await palStore()
        let own = site.messages.filter { $0.role == .user && site.canRewind(to: $0) }
        #expect(own.count >= 2)
        // the assistant's words to it aren't the owner's
        let palo = try #require(site.messages.first { !($0.from ?? "").isEmpty })
        #expect(!site.canRewind(to: palo))
        // its first one predates the file checkpoints; a later one has them
        let first = try #require(own.first), target = try #require(own.last)
        #expect(await site.canRestoreFiles(to: first) == false)
        #expect(await site.canRestoreFiles(to: target) == true)
        let i = try #require(site.messages.firstIndex { $0.id == target.id })
        let kept = site.messages[..<i].map(\.id)
        let outcome = try await site.rewind(to: target, restoreFiles: true)
        #expect(outcome == RewindOutcome(text: target.text, filesRestored: true))
        #expect(site.messages.map(\.id) == kept)
        #expect(await host.lastParams["pals.rewind"] == ["id": "pal-site", "messageId": .string(target.id), "restoreFiles": true])
        #expect(await host.requestLog.last == "pals.history")
        // Nothing of it in the assistant's conversation; its event went to the Pal's store.
        #expect(!store.messages.contains { $0.pal != nil })
        // The files can't go back past the checkpoints: said, and nothing changes.
        await #expect(throws: RPCError.remote("这一步之前的代码没法恢复")) { _ = try await site.rewind(to: first, restoreFiles: true) }
        #expect(site.messages.map(\.id) == kept)
    }
}
