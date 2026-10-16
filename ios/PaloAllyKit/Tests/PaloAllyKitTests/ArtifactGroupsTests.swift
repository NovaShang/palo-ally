import Foundation
import Testing
@testable import PaloAllyKit

struct ArtifactGroupsTests {
    static func at(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    static func make(_ id: String, _ folder: String, _ iso: String) -> Artifact {
        Artifact(id: id, title: id, type: "markdown", mainFile: "\(id).md", folder: folder, updatedAt: at(iso))
    }

    @Test func foldersByNewestChangeWithTheUngroupedLast() {
        let items = [
            Self.make("a", "旅行", "2026-10-01T08:00:00Z"),
            Self.make("b", "理财", "2026-10-03T08:00:00Z"),
            Self.make("c", "", "2026-10-04T08:00:00Z"),
            Self.make("d", "旅行", "2026-10-02T08:00:00Z"),
        ]
        let groups = ArtifactGroups.folders(items)
        #expect(groups.map(\.name) == ["理财", "旅行", ""])
        #expect(groups[1].items.map(\.id) == ["d", "a"])
        #expect(groups[2].isUngrouped)
        #expect(ArtifactGroups.folders([]).isEmpty)
        // Only artifacts without a folder: one group, not a pretend name.
        #expect(ArtifactGroups.folders([Self.make("x", "", "2026-10-01T08:00:00Z")]).map(\.name) == [""])
    }

    @Test func daysNewestFirstInTheCallersCalendar() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let items = [
            Self.make("a", "", "2026-10-01T15:30:00Z"), // 23:30 on the 1st there
            Self.make("b", "", "2026-10-01T16:30:00Z"), // 00:30 on the 2nd
            Self.make("c", "", "2026-10-02T02:00:00Z"), // 10:00 on the 2nd
            Self.make("d", "", "2026-09-20T02:00:00Z"),
        ]
        let days = ArtifactGroups.days(items, calendar: cal)
        #expect(days.count == 3)
        #expect(days[0].items.map(\.id) == ["c", "b"])
        #expect(days[1].items.map(\.id) == ["a"])
        #expect(days[2].items.map(\.id) == ["d"])
    }

    @Test func aMissingFolderDecodesAsNone() throws {
        let a = try JSONDecoder().decode(Artifact.self, from: Data(#"{"id":"a","title":"t","type":"md","mainFile":"a.md","pinned":false,"updatedAt":1,"files":[]}"#.utf8))
        #expect(a.folder == "")
        let b = try JSONDecoder().decode(Artifact.self, from: Data(#"{"id":"a","folder":" 理财 ","updatedAt":1}"#.utf8))
        #expect(b.folder == "理财")
    }
}
