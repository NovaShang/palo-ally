import Foundation
import Testing
@testable import PaloAllyKit

@Suite struct HistoryListTests {
    func item(_ k: EarlierItem.Kind, _ sid: String, name: String = "", cwd: String = "/tmp/a", at: Int64) -> EarlierItem {
        EarlierItem(kind: k, key: "\(k.rawValue):\(sid)", sessionId: sid, name: name, cwd: cwd, at: at)
    }
    func live(_ id: String, cwd: String = "/tmp/b", at: Int64 = 5) -> CCSession {
        let json = "{\"id\":\"\(id)\",\"name\":\"live \(id)\",\"cwd\":\"\(cwd)\"}"
        var s: CCSession = decodeSession(json)
        s.updatedAt = at
        return s
    }
    func decodeSession(_ json: String) -> CCSession {
        do { return try JSONDecoder().decode(CCSession.self, from: Data(json.utf8)) } catch { fatalError("\(error)") }
    }

    @Test func sectionsInOrderNewestFirst() {
        let s = HistoryList.build(earlier: [item(.recent, "r", at: 1), item(.ended, "e1", at: 2), item(.ended, "e2", at: 9),
                                            item(.folded, "f", at: 3)], live: [live("l")])
        #expect(s.map(\.kind) == [.ended, .folded, .live, .older])
        #expect(s[0].entries.map(\.sessionId) == ["e2", "e1"])
    }

    @Test func runningTerminalSessionShowsOnce() {
        let s = HistoryList.build(earlier: [item(.recent, "l", at: 1)], live: [live("l")])
        #expect(s.count == 1 && s[0].kind == .live)
    }

    @Test func queryMatchesTitleOrFolder() {
        let e = [item(.ended, "1", name: "Fix Login", at: 1), item(.ended, "2", name: "x", cwd: "/tmp/login-app", at: 2),
                 item(.ended, "3", name: "other", at: 3)]
        let s = HistoryList.build(earlier: e, live: [], query: " login ")
        #expect(Set(s.flatMap(\.entries).map(\.sessionId)) == ["1", "2"])
        #expect(HistoryList.build(earlier: e, live: [], query: "zzz").isEmpty)
    }
}
