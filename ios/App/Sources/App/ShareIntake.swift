import Foundation
import PaloAllyKit
import SwiftUI

/// What another app's share sheet sent (the PaloAlly share extension,
/// `ShareInbox`), on its way to a conversation's composer: staged there
/// as if picked, its words in the field; the owner sends.
struct ShareRequest: Equatable {
    let id: String
    let host: String
    let conversation: WindowModel.Conversation
    let items: [Staged]
    let text: String
    /// What to say of files that couldn't be taken.
    var problem: String? = nil

    static func == (a: ShareRequest, b: ShareRequest) -> Bool { a.id == b.id }

    /// The conversation a store shows is this one.
    func matches(_ scope: AppStore.Scope) -> Bool {
        switch (conversation, scope) {
        case (.palo, .palo): true
        case (.pal(let a), .pal(let b)): a == b
        default: false
        }
    }
}

extension AppModel {
    /// Shares waiting in the App Group: each opens its conversation in a
    /// window on its computer and is staged there. Called when the app
    /// becomes active and on a `paloally://share/…` link.
    func takeShares() {
        guard mode != .unpaired else { return }
        for (manifest, folder) in ShareInbox.pending() {
            defer { ShareInbox.remove(folder) }
            guard let host = manifest.host.flatMap({ hostIDs.contains($0) ? $0 : nil }) ?? lastHostID ?? hostIDs.first else { continue }
            var conversation = WindowModel.Conversation(storageKey: manifest.key) ?? .palo
            // A session that went away goes to Palo (one not listed yet, right after launch, is kept).
            if case .pal(let id) = conversation, let pals = stores[host]?.pals, !pals.isEmpty, !pals.contains(where: { $0.id == id }) {
                conversation = .palo
            }
            var items: [Staged] = []
            var unread = 0
            for f in manifest.files.prefix(ShareInbox.maxItems) {
                let url = folder.appendingPathComponent(f.name)
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                   let s = ComposerIntake.staged(Data(data), name: f.name) {
                    items.append(s)
                } else {
                    unread += 1
                }
            }
            let request = ShareRequest(id: manifest.id, host: host, conversation: conversation, items: items, text: manifest.text,
                                       problem: unread > 0 ? String(localized: "有文件读不了") : nil)
            debugLog("[share] \(items.count) attachment(s), \(unread) unreadable, \(manifest.text.count) characters → \(conversation.storageKey)")
            inWindow(showing: host) { w in w.receiveShare(request) }
        }
    }

    /// Where a share can go, for the extension's 「发给谁」: each computer's
    /// Palo (the one used last first), then its sessions, latest first.
    func writeShareTargets() {
        guard mode == .paired else { return }
        let several = hostIDs.count > 1
        var targets: [ShareInbox.Target] = []
        var sessions: [ShareInbox.Target] = []
        let order = (lastHostID.map { [$0] } ?? []) + hostIDs.filter { $0 != lastHostID }
        for id in order {
            guard let store = stores[id] else { continue }
            let name = store.assistantName.trimmingCharacters(in: .whitespaces)
            let detail = several ? displayName(id) : nil
            targets.append(.init(host: id, key: "palo", name: name.isEmpty ? "Palo" : name, detail: detail))
            let recent = store.pals.filter { !$0.folded }.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }.prefix(12)
            sessions += recent.map { .init(host: id, key: "pal:\($0.id)", name: $0.displayName, detail: detail) }
        }
        ShareInbox.writeTargets(targets + sessions)
    }

    /// Keeps the extension's list current: rewritten whenever a computer's
    /// sessions or its assistant's name change (and when the app goes away).
    func watchShareTargets() {
        withObservationTracking {
            _ = lastHostID
            for id in hostIDs { _ = stores[id]?.pals; _ = stores[id]?.assistantName }
        } onChange: { [weak self] in
            Task { @MainActor in
                // Settle a burst of changes (a list arriving) into one write.
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.writeShareTargets()
                self.watchShareTargets()
            }
        }
    }
}

extension WindowModel {
    /// A file another app handed over (「用 Palo 打开」): staged in the
    /// conversation on screen, else the assistant's. Only read where it is;
    /// a copy the system put in the app's Inbox is removed once read.
    func takeOpenedFile(_ url: URL) {
        guard mode != .unpaired, let host = activeHostID ?? app.lastHostID else {
            debugLog("[share] a file opened with nothing paired")
            Self.removeInboxCopy(url)
            return
        }
        // Where it goes is settled now; reading it may take a moment.
        let target: Conversation = switch (compactColumn, selection) {
        case (.detail, .pal(let id)?): .pal(id)
        default: .palo
        }
        Task {
            let (data, tooBig) = await Task.detached(priority: .userInitiated) { () -> (Data?, Bool) in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Over the composer's limit: nothing read.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= ShareInbox.maxFileBytes else { return (nil, true) }
                // Coordinated: one still in iCloud is brought down first.
                var bytes: Data?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { bytes = try? Data(contentsOf: $0) }
                return (bytes, false)
            }.value
            Self.removeInboxCopy(url)
            let item = data.flatMap { ComposerIntake.staged($0, name: url.lastPathComponent) }
            debugLog("[share] opened a file: \(data?.count ?? -1) bytes, \(item == nil ? "not staged" : "staged") → \(target.storageKey)")
            receiveShare(ShareRequest(id: UUID().uuidString, host: host, conversation: target,
                                      items: item.map { [$0] } ?? [], text: "",
                                      problem: item != nil ? nil : tooBig ? String(localized: "文件太大（最多 100MB）")
                                          : String(localized: "有文件读不了")))
        }
    }

    /// Only the system's own copy: never the owner's file.
    private static func removeInboxCopy(_ url: URL) {
        let inbox = URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A share for this window (on its computer): its conversation opens and
    /// the conversation's composer takes it (ChatView).
    func receiveShare(_ request: ShareRequest) {
        if activeHostID != request.host { switchTo(request.host) }
        showManagement = false
        open(request.conversation)
        // Several files come one after the other: what the conversation
        // hasn't taken yet goes with the next.
        if let waiting = shareRequest, waiting.host == request.host, waiting.conversation == request.conversation {
            shareRequest = ShareRequest(id: request.id, host: request.host, conversation: request.conversation,
                                        items: waiting.items + request.items,
                                        text: [waiting.text, request.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                                        problem: request.problem ?? waiting.problem)
        } else {
            shareRequest = request
        }
        bringToFront()
    }
}

/// A conversation taking what was shared to it (`WindowModel.shareRequest`):
/// the files and pictures staged in its composer, the words added to its
/// field. Its own view, so only it follows the request.
struct ShareTaker: ViewModifier {
    let intake: ComposerIntake
    let draft: DraftBox
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.onChange(of: model.shareRequest?.id, initial: true) { _, id in
            guard id != nil, let r = model.shareRequest, r.host == model.activeHostID, r.matches(store.scope) else { return }
            model.shareRequest = nil
            if !r.items.isEmpty { intake.incoming.append(contentsOf: r.items) }
            if let problem = r.problem { intake.problem = problem }
            if !r.text.isEmpty { draft.text = draft.text.isEmpty ? r.text : draft.text + "\n" + r.text }
            debugLog("[share] staged in \(r.conversation.storageKey): \(r.items.count) attachment(s), \(r.text.count) characters")
        }
    }
}
