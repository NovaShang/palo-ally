import Foundation

/// A document as a card of its own in a workspace's layout (文档分屏, the
/// Mac and iPads): a file by its absolute path on the workspace's computer,
/// or an item of 成果. Its leaf id is `doc:` and the path (`doc:/Users/…`),
/// or `doc:artifact:` and the item's id. Like Palo's pane it is a view, not
/// a member: the host keeps it in the tree as it is (docs/workbench-rpc.md,
/// "LayoutNode"), and reconciling never adds or drops it.
public enum DocumentLeaf: Hashable, Sendable {
    case file(String)
    case artifact(String)

    public static let prefix = "doc:"
    static let artifactPrefix = "doc:artifact:"

    /// The leaf's id in the layout.
    public var id: String {
        switch self {
        case .file(let path): Self.prefix + path
        case .artifact(let id): Self.artifactPrefix + id
        }
    }

    /// Reads a leaf id; nil for a session's (or Palo's).
    public init?(id: String) {
        if id.hasPrefix(Self.artifactPrefix) {
            let a = String(id.dropFirst(Self.artifactPrefix.count))
            guard !a.isEmpty else { return nil }
            self = .artifact(a)
        } else if id.hasPrefix(Self.prefix + "/") {
            self = .file(String(id.dropFirst(Self.prefix.count)))
        } else {
            return nil
        }
    }

    /// Whether a leaf id is a document's.
    public static func isDocument(_ id: String) -> Bool { DocumentLeaf(id: id) != nil }

    /// The document a right pane's tab shows (a file by its absolute path,
    /// or an item of 成果); nil for the others (web pages stay in the pane).
    public init?(tab: PaneTab) {
        if tab.isAbsolutePreview, let path = tab.path {
            self = .file(path)
        } else if let id = tab.artifactID, !id.isEmpty {
            self = .artifact(id)
        } else {
            return nil
        }
    }

    /// The right pane's tab for it (a card sent back to the pane).
    public var tab: PaneTab {
        switch self {
        case .file(let path): .previewTab(path)
        case .artifact(let id): .artifactTab(id)
        }
    }

    /// The file's name (an item of 成果 is named by the caller).
    public var fileName: String? {
        if case .file(let path) = self { return (path as NSString).lastPathComponent }
        return nil
    }
}

extension TabsState {
    /// Where the tab showing this document is, if one does.
    public func index(of doc: DocumentLeaf) -> Int? {
        tabs.firstIndex { DocumentLeaf(tab: $0) == doc }
    }
}
