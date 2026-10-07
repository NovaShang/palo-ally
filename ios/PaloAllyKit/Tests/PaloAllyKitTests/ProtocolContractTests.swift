import Foundation
import Testing
@testable import PaloAllyKit

/// Strict contract test against the host.
///
/// `Fixtures/protocol.json` is written by the host test suite by driving a
/// real Hub through every RPC method and event:
/// `{ "methods": { "<method>": { "params": …, "result": … } }, "events": { "<event>": <payload> } }`.
/// The client owns only `Fixtures/protocol.sample.json`, a hand-written copy
/// used while protocol.json is absent. protocol.json wins when present.
///
/// Production decoders are tolerant (a missing field falls back to a default).
/// Here every sample is decoded under `LenientDiagnostics`, and any fallback
/// on a field the client treats as required fails the test.
enum ProtocolFixture {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let hostURL = dir.appendingPathComponent("protocol.json")
    static let sampleURL = dir.appendingPathComponent("protocol.sample.json")

    static var hostFixtureExists: Bool { FileManager.default.fileExists(atPath: hostURL.path) }
    static var url: URL? {
        // PALOALLY_PROTOCOL_FIXTURE=sample checks the hand-written sample even when protocol.json exists.
        if ProcessInfo.processInfo.environment["PALOALLY_PROTOCOL_FIXTURE"] == "sample" {
            return FileManager.default.fileExists(atPath: sampleURL.path) ? sampleURL : nil
        }
        if hostFixtureExists { return hostURL }
        return FileManager.default.fileExists(atPath: sampleURL.path) ? sampleURL : nil
    }
    static var exists: Bool { url != nil }

    static func load() throws -> (methods: [String: JSONValue], events: [String: JSONValue], source: String) {
        let url = try #require(url)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let methods)? = json["methods"], case .object(let events)? = json["events"] else {
            throw ContractError("\(url.lastPathComponent): expected top-level \"methods\" and \"events\" objects")
        }
        return (methods, events, url.lastPathComponent)
    }

    /// Some entries may hold several samples as an array.
    static func samples(_ v: JSONValue) -> [JSONValue] {
        if case .array(let a) = v { return a }
        return [v]
    }
}

struct ContractError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Decodes `json` as `T` and returns every fallback the tolerant decoder took.
private func strictIssues<T: Decodable>(_ type: T.Type, _ json: JSONValue) -> [String] {
    do {
        let (_, issues) = try LenientDiagnostics.collect { try json.decode(T.self) }
        return issues
    } catch {
        return ["does not decode as \(T.self): \(error)"]
    }
}

private typealias Check = @Sendable (JSONValue) -> [String]
private func strict<T: Decodable & SendableMetatype>(_ type: T.Type) -> Check { { strictIssues(T.self, $0) } }

/// Method → the Swift result type the client decodes it into.
private let resultTypes: [String: Check] = [
    RPCMethod.hello: strict(HelloResult.self),
    RPCMethod.sync: strict(SyncResult.self),
    RPCMethod.chatSend: strict(ChatSendResult.self),
    RPCMethod.chatHistory: strict(MessagesResult.self),
    RPCMethod.chatSearch: strict(ChatSearchResult.self),
    RPCMethod.chatAround: strict(MessagesResult.self),
    RPCMethod.commandsList: strict(CommandsResult.self),
    RPCMethod.modelGet: strict(ModelInfo.self),
    RPCMethod.modelSet: strict(StatusResult.self),
    RPCMethod.taskGet: strict(TaskDetail.self),
    RPCMethod.taskStop: strict(OKResult.self),
    RPCMethod.approvalAnswer: strict(StatusStringResult.self),
    RPCMethod.questionAnswer: strict(QuestionResult.self),
    RPCMethod.watchAdd: strict(WatchResult.self),
    RPCMethod.watchUpdate: strict(WatchResult.self),
    RPCMethod.watchRemove: strict(OKResult.self),
    RPCMethod.artifactList: strict(ArtifactsResult.self),
    RPCMethod.artifactRead: strict(ArtifactChunk.self),
    RPCMethod.artifactPin: strict(ArtifactResult.self),
    RPCMethod.memoryList: strict(MemoryFilesResult.self),
    RPCMethod.memoryRead: strict(MemoryContentResult.self),
    RPCMethod.memoryWrite: strict(MemoryWriteResult.self),
    RPCMethod.settingsUpdate: strict(SettingsResult.self),
    RPCMethod.stop: strict(StatusResult.self),
    RPCMethod.pushRegister: strict(OKResult.self),
    RPCMethod.pushUnregister: strict(OKResult.self),
    RPCMethod.deviceUnpair: strict(OKResult.self),
    RPCMethod.auditTail: strict(AuditResult.self),
    RPCMethod.mediaUpload: strict(Attachment.self),
    RPCMethod.mediaGet: strict(MediaData.self),
    RPCMethod.mediaUploadChunk: strict(MediaUploadChunkResult.self),
    RPCMethod.mediaRead: strict(ArtifactChunk.self),
    RPCMethod.suggestionsList: strict(SuggestionsResult.self),
    RPCMethod.suggestionsDismiss: strict(OKResult.self),
    RPCMethod.hostUpdate: strict(HostUpdateResult.self),
]

/// Event → how AppStore.apply(event:) reads the payload.
private let eventTypes: [String: Check] = [
    RPCEventName.chatMessage: strict(ChatMessage.self),
    RPCEventName.chatDelta: strict(ChatDelta.self),
    RPCEventName.taskUpdated: strict(AllyTask.self),
    RPCEventName.approvalUpdated: strict(Approval.self),
    RPCEventName.questionUpdated: strict(Question.self),
    RPCEventName.watchUpdated: { json in
        if json["removed"] != nil {
            return json["removed"]?.stringValue == nil ? ["\"removed\" is not a string"] : []
        }
        guard let w = json["watch"] else { return ["neither \"watch\" nor \"removed\""] }
        let issues = strictIssues(Watch.self, w)
        if case .unknown = WatchUpdate(json: json) { return issues + ["WatchUpdate did not recognise the payload"] }
        return issues
    },
    RPCEventName.artifactUpdated: { strictIssues(Artifact.self, $0["artifact"] ?? $0) },
    RPCEventName.settingsUpdated: { strictIssues(HostSettings.self, $0["settings"] ?? $0) },
    RPCEventName.status: { strictIssues(HostStatus.self, $0["status"] ?? $0) },
    RPCEventName.commandsUpdated: strict(CommandsResult.self),
    RPCEventName.suggestionsUpdated: strict(SuggestionsResult.self),
]

@Suite("Protocol contract")
struct ProtocolContractTests {
    @Test func mappingCoversEveryKnownName() {
        #expect(Set(resultTypes.keys) == Set(RPCMethod.all))
        #expect(Set(eventTypes.keys) == Set(RPCEventName.all))
        #expect(RPCMethod.all.count == Set(RPCMethod.all).count)
    }

    @Test(.enabled(if: ProtocolFixture.exists, "no protocol fixture"))
    func methodSetMatchesHost() throws {
        let f = try ProtocolFixture.load()
        print("ProtocolContract: using \(f.source)")
        let host = Set(f.methods.keys)
        let client = Set(RPCMethod.all)
        #expect(host.subtracting(client).isEmpty, "host methods the client doesn't know: \(host.subtracting(client).sorted())")
        #expect(client.subtracting(host).isEmpty, "client methods the host doesn't have: \(client.subtracting(host).sorted())")
    }

    @Test(.enabled(if: ProtocolFixture.exists, "no protocol fixture"))
    func eventSetMatchesHost() throws {
        let f = try ProtocolFixture.load()
        let host = Set(f.events.keys)
        let client = Set(RPCEventName.all)
        #expect(host.subtracting(client).isEmpty, "host events the client doesn't know: \(host.subtracting(client).sorted())")
        #expect(client.subtracting(host).isEmpty, "client events the host never sends: \(client.subtracting(host).sorted())")
    }

    @Test(.enabled(if: ProtocolFixture.exists, "no protocol fixture"))
    func everyResultDecodesStrictly() throws {
        let f = try ProtocolFixture.load()
        for (method, entry) in f.methods.sorted(by: { $0.key < $1.key }) {
            guard let check = resultTypes[method] else { continue } // reported by methodSetMatchesHost
            for (i, sample) in ProtocolFixture.samples(entry).enumerated() {
                guard let result = sample["result"] else {
                    Issue.record("\(f.source) \(method)[\(i)]: no \"result\"")
                    continue
                }
                let issues = check(result)
                #expect(issues.isEmpty, "\(f.source) \(method) result: \(issues.joined(separator: "; "))")
            }
        }
    }

    @Test(.enabled(if: ProtocolFixture.exists, "no protocol fixture"))
    func everyEventDecodesStrictly() throws {
        let f = try ProtocolFixture.load()
        for (event, payload) in f.events.sorted(by: { $0.key < $1.key }) {
            guard let check = eventTypes[event] else { continue } // reported by eventSetMatchesHost
            for sample in ProtocolFixture.samples(payload) {
                let issues = check(sample)
                #expect(issues.isEmpty, "\(f.source) event \(event): \(issues.joined(separator: "; "))")
            }
        }
    }

    /// The strict mode itself must catch what it is meant to catch.
    @Test func strictModeFlagsFallbacks() {
        let ok: JSONValue = ["id": "a", "tool": "Bash", "title": "t", "detail": "d", "careful": false,
                             "status": "pending", "createdAt": 1]
        #expect(strictIssues(Approval.self, ok).isEmpty)

        var renamed = ok
        if case .object(var o) = renamed { o["careful"] = nil; o["irreversible"] = true; renamed = .object(o) }
        #expect(strictIssues(Approval.self, renamed).contains { $0.contains("careful") })

        var badEnum = ok
        if case .object(var o) = badEnum { o["status"] = "withdrawn"; badEnum = .object(o) }
        #expect(strictIssues(Approval.self, badEnum).contains { $0.contains("withdrawn") })

        // Nested: a message missing "channel" inside a sync result.
        let sync: JSONValue = ["seq": 1, "messages": [["seq": 1, "id": "m", "role": "user", "kind": "text", "text": "x", "ts": 1]],
                               "tasks": [], "approvals": [], "watches": [], "artifacts": []]
        let issues = strictIssues(SyncResult.self, sync)
        #expect(issues.contains { $0.contains("channel") })
        #expect(issues.contains { $0.contains("settings") })
        #expect(issues.contains { $0.contains("status") })

        // memory.write must report the new stamp.
        #expect(strictIssues(MemoryWriteResult.self, ["ok": true]).contains { $0.contains("updatedAt") })
        // Production decoding outside `collect` records nothing and still succeeds.
        #expect((try? renamed.decode(Approval.self))?.careful == true)
    }
}
