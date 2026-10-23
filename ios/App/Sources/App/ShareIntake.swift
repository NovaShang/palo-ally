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
            let request = ShareRequest(id: manifest.id, host: host, conversation: conversation, items: items, text: manifest.text)
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
            sessions += recent.map { .init(host: id, key: "pal:\($0.id)", name: $0.name.isEmpty ? String(localized: "会话") : $0.name, detail: detail) }
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
    /// A share for this window (on its computer): its conversation opens and
    /// the conversation's composer takes it (ChatView).
    func receiveShare(_ request: ShareRequest) {
        if activeHostID != request.host { switchTo(request.host) }
        showManagement = false
        open(request.conversation)
        shareRequest = request
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
            if !r.text.isEmpty { draft.text = draft.text.isEmpty ? r.text : draft.text + "\n" + r.text }
            debugLog("[share] staged in \(r.conversation.storageKey): \(r.items.count) attachment(s), \(r.text.count) characters")
        }
    }
}
