import Foundation
import Testing
@testable import PaloAllyKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite("Model decoding")
struct ModelDecodingTests {
    @Test func chatMessageFull() throws {
        let m = try decode(ChatMessage.self, """
        {"seq":42,"id":"m42","role":"assistant","kind":"task","text":"收到","channel":"wechat","ts":1759550000123,
         "proactive":true,"taskId":"t1","approvalId":"a1","extra":{"nested":[1,2]}}
        """)
        #expect(m.seq == 42)
        #expect(m.id == "m42")
        #expect(m.role == .assistant)
        #expect(m.kind == .task)
        #expect(m.channel == .wechat)
        #expect(m.ts == 1759550000123)
        #expect(m.proactive == true)
        #expect(m.taskId == "t1")
        #expect(m.approvalId == "a1")
        #expect(m.isStreaming == false)
        #expect(m.delivery == .sent)
    }

    @Test func chatMessageUnknownEnumsAndMissingFields() throws {
        let m = try decode(ChatMessage.self, #"{"seq":1,"id":"x","role":"robot","kind":"poll","channel":"telegram"}"#)
        #expect(m.role == .unknown)
        #expect(m.kind == .unknown)
        #expect(m.channel == .unknown)
        #expect(m.text == "")
        #expect(m.ts == 0)
    }

    @Test func chatMessageWrongTypesDoNotThrow() throws {
        let m = try decode(ChatMessage.self, #"{"seq":"7","id":12,"role":"user","text":"hi","ts":"2026-10-04T08:00:00Z","proactive":"yes"}"#)
        #expect(m.seq == 7)
        #expect(m.id == "12")
        #expect(m.ts == 1_791_100_800_000)
        #expect(m.proactive == nil)
    }

    @Test func taskStatuses() throws {
        let t = try decode(AllyTask.self, #"{"id":"t","title":"x","summary":"s","status":"needs_input","source":"auto","createdAt":1,"updatedAt":2,"activityCount":3}"#)
        #expect(t.status == .needsInput)
        #expect(t.source == .auto)
        #expect(t.isActive)
        let u = try decode(AllyTask.self, #"{"id":"t","status":"paused"}"#)
        #expect(u.status == .unknown)
        #expect(u.activityCount == 0)
    }

    @Test func taskActivity() throws {
        let a = try decode([TaskActivity].self, #"[{"ts":1,"kind":"tool_use","tool":"Bash","text":"ls"},{"ts":2,"kind":"tool_result","text":"ok"},{"ts":3,"kind":"thinking","text":"?"}]"#)
        #expect(a.map(\.kind) == [.toolUse, .toolResult, .unknown])
        #expect(a[0].tool == "Bash")
    }

    @Test func approval() throws {
        let a = try decode(Approval.self, #"{"id":"a","tool":"send","title":"t","detail":"d","irreversible":false,"status":"pending","createdAt":5,"suggestedScope":"example.com"}"#)
        #expect(a.isPending)
        #expect(a.canRemember)
        #expect(a.suggestedScope == "example.com")
        // Missing irreversible flag is treated as irreversible (fail safe).
        let b = try decode(Approval.self, #"{"id":"b","status":"allowed"}"#)
        #expect(b.irreversible)
        #expect(!b.canRemember)
        #expect(b.status == .allowed)
        let c = try decode(Approval.self, #"{"id":"c","status":"withdrawn","irreversible":true}"#)
        #expect(c.status == .unknown)
    }

    @Test func watch() throws {
        let w = try decode(Watch.self, #"{"id":"w","title":"晨报","kind":"schedule","instruction":"i","at":["08:30","22:30"],"enabled":false,"createdBy":"agent","lastCheckedAt":10,"skipIfActiveMinutes":45}"#)
        #expect(w.kind == .schedule)
        #expect(w.at == ["08:30", "22:30"])
        #expect(!w.enabled)
        #expect(w.createdBy == .agent)
        #expect(w.skipIfActiveMinutes == 45)
        let v = try decode(Watch.self, #"{"id":"v","kind":"webhook","intervalMinutes":15.0}"#)
        #expect(v.kind == .unknown)
        #expect(v.intervalMinutes == 15)
        #expect(v.enabled)
    }

    @Test func artifact() throws {
        let a = try decode(Artifact.self, #"{"id":"a","title":"晨报","type":"markdown","mainFile":"x.md","pinned":true,"updatedAt":9,"files":[{"path":"x.md","size":10},{"bad":true}]}"#)
        #expect(a.pinned)
        #expect(a.files.count == 2)
        #expect(a.files[0].size == 10)
        #expect(a.previewStyle == .markdown)
        #expect(Artifact(id: "1", title: "", type: "report", mainFile: "index.HTML", updatedAt: 0).previewStyle == .html)
        #expect(Artifact(id: "1", title: "", type: "pdf", mainFile: "r.pdf", updatedAt: 0).previewStyle == .quickLook)
    }

    @Test func settingsQuietHoursNullRoundTrip() throws {
        let s = try decode(HostSettings.self, #"{"timezone":"Asia/Shanghai","quietHours":null,"maxProactivePerDay":5,"probeIntervalMinutes":10,"approvalTimeoutMinutes":30}"#)
        #expect(s.quietHours == nil)
        #expect(s.maxProactivePerDay == 5)
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        #expect(json.contains(#""quietHours":null"#))
        let q = try decode(HostSettings.self, #"{"quietHours":{"start":"23:00","end":"07:30"}}"#)
        #expect(q.quietHours == QuietHours(start: "23:00", end: "07:30"))
    }

    @Test func status() throws {
        let s = try decode(HostStatus.self, #"{"online":true,"killed":true,"busy":false,"model":"glm","wechat":"expired","version":"1"}"#)
        #expect(s.killed)
        #expect(s.wechat == .expired)
        let t = try decode(HostStatus.self, #"{"wechat":"pending_qr"}"#)
        #expect(t.wechat == .unknown)
    }

    @Test func memoryFile() throws {
        let f = try decode([MemoryFile].self, #"[{"path":"user.md","scope":"core","size":10,"updatedAt":1},{"path":"x","scope":"shared"}]"#)
        #expect(f[0].scope == .core)
        #expect(f[1].scope == .unknown)
    }

    @Test func syncResultSkipsBadElements() throws {
        let r = try decode(SyncResult.self, """
        {"seq":10,"messages":[{"seq":9,"id":"a","role":"user","text":"x"},42,{"seq":10,"id":"b","role":"assistant"}],
         "tasks":[],"approvals":[{"id":"p","status":"pending","irreversible":false}],"watches":[],"artifacts":[],
         "settings":{"maxProactivePerDay":3},"status":{"busy":true},"future":"field"}
        """)
        #expect(r.seq == 10)
        #expect(r.messages.map(\.id) == ["a", "b"])
        #expect(r.approvals?.count == 1)
        #expect(r.settings?.maxProactivePerDay == 3)
        #expect(r.status?.busy == true)
    }

    @Test func wireMessageParsing() throws {
        #expect(WireMessage.parse(Data(#"{"id":3,"result":{"ok":true}}"#.utf8)) == .response(id: 3, result: ["ok": true]))
        #expect(WireMessage.parse(Data(#"{"id":4,"error":{"message":"nope"}}"#.utf8)) == .errorResponse(id: 4, message: "nope"))
        #expect(WireMessage.parse(Data(#"{"id":5,"result":null}"#.utf8)) == .response(id: 5, result: .null))
        #expect(WireMessage.parse(Data(#"{"event":"status","data":{"busy":true}}"#.utf8)) == .event(name: "status", data: ["busy": true]))
        #expect(WireMessage.parse(Data("not json".utf8)) == nil)
        #expect(WireMessage.parse(Data("[1,2]".utf8)) == nil)
    }

    @Test func watchUpdatePayloads() throws {
        if case .removed(let id) = WatchUpdate(json: ["removed": "w1"]) { #expect(id == "w1") } else { Issue.record("expected removed") }
        if case .upsert(let w) = WatchUpdate(json: ["watch": ["id": "w2", "title": "t", "kind": "check"]]) {
            #expect(w.id == "w2")
        } else { Issue.record("expected upsert") }
        if case .unknown = WatchUpdate(json: ["foo": 1]) {} else { Issue.record("expected unknown") }
    }

    @Test func requestEnvelopeEncoding() throws {
        let data = try JSONEncoder().encode(RequestEnvelope(id: 7, method: "sync", params: SyncParams(sinceSeq: 12)))
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(v["id"] == .number(7))
        #expect(v["method"] == "sync")
        #expect(v["params"]?["sinceSeq"] == .number(12))
        // nil sinceSeq is omitted (= "no sinceSeq").
        let d2 = try JSONEncoder().encode(SyncParams(sinceSeq: nil))
        #expect(String(data: d2, encoding: .utf8) == "{}")
    }

    @Test func jsonValueIntegersEncodeWithoutFraction() throws {
        let s = String(data: try JSONEncoder().encode(JSONValue.number(5)), encoding: .utf8)
        #expect(s == "5")
    }
}
