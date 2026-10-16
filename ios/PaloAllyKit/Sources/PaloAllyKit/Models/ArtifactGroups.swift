import Foundation

/// How 成果 lays the unpinned artifacts out (docs/files-prd.md, "成果 sorted
/// by folder or by time"). Pure, so it is tested without a screen.
public enum ArtifactGroups {
    public struct Folder: Identifiable, Equatable, Sendable {
        /// The folder's name; "" is the group for artifacts with none.
        public var name: String
        public var items: [Artifact]
        public var id: String { name }
        public var isUngrouped: Bool { name.isEmpty }
    }

    public struct Day: Identifiable, Equatable, Sendable {
        public var start: Date
        public var items: [Artifact]
        public var id: Date { start }
    }

    /// By folder: the folder with the newest change first, each folder's
    /// items newest first, and the artifacts without a folder last.
    public static func folders(_ items: [Artifact]) -> [Folder] {
        let byName = Dictionary(grouping: items, by: \.folder)
        let named = byName.filter { !$0.key.isEmpty }.map { name, list in
            Folder(name: name, items: list.sorted { $0.updatedAt > $1.updatedAt })
        }
        .sorted { ($0.items[0].updatedAt, $1.name) > ($1.items[0].updatedAt, $0.name) }
        if let rest = byName[""], !rest.isEmpty {
            return named + [Folder(name: "", items: rest.sorted { $0.updatedAt > $1.updatedAt })]
        }
        return named
    }

    /// By time: one section per calendar day, newest day and newest item first.
    public static func days(_ items: [Artifact], calendar: Calendar = .current) -> [Day] {
        let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0.updatedAt) / 1000)) }
        return byDay.map { Day(start: $0.key, items: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.start > $1.start }
    }
}
