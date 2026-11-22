import PaloAllyKit
import SwiftUI

/// A chat message of kind "ally" (allies-prd §5): an Ally's words coming in,
/// or the card for a message going out to one. The newest words and state
/// are the exchange's (`entryId`), not the message's own text.
struct AllyMessageRow: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    private var entry: AllyEntry? { message.entryId.flatMap { store.allyEntry(id: $0) } }
    private var outgoing: Bool { (entry?.dir ?? message.dir) == .outgoing }
    /// Who they are: the list's name, else what the message says.
    private var name: String {
        if let id = message.allyId ?? entry?.allyId, let a = store.ally(id: id) { return a.displayName }
        return message.allyName ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if outgoing {
                AllyDraftCard(entry: entry ?? fallbackEntry, name: name, known: entry != nil)
            } else {
                AllyIncoming(message: message, entry: entry, name: name)
            }
            Spacer(minLength: AssistantMessageLayout.trailingRoom)
        }
    }

    /// Before its exchange has loaded: the words the message carries, no buttons.
    private var fallbackEntry: AllyEntry {
        AllyEntry(id: message.entryId ?? message.id, allyId: message.allyId, dir: .outgoing, ts: message.ts,
                  text: message.text, status: .unknown)
    }
}

/// What an Ally's assistant passed on: labelled 「家人的助理」, their words as
/// they were, set off by a quiet rule. Tapping the label opens that Ally.
private struct AllyIncoming: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let entry: AllyEntry?
    let name: String

    private var text: String { entry?.text ?? message.text }
    private var byThemselves: Bool { (entry?.author ?? message.author) == .owner && !name.isEmpty }
    private var allyID: String? { message.allyId ?? entry?.allyId }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if let allyID, store.ally(id: allyID) != nil { model.openAlly(allyID) }
                } label: {
                    // Their own words, or their assistant's (§11.2).
                    Label(byThemselves ? name : AllyInfo.assistantLabel(name),
                          systemImage: byThemselves ? "person.fill" : "person.2.fill")
                        .labelStyle(AllyLabelStyle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("看和 TA 的来往")
                if entry?.urgent == true {
                    Text("急").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(.quaternary).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(text) }
                        }
                    if let slots = entry?.slots, !slots.isEmpty {
                        AllySlotList(slots: slots)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The small label over an Ally's words: glyph and name, quiet.
private struct AllyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.caption2)
            configuration.title.font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

/// Proposed times, in this device's time zone.
struct AllySlotList: View {
    let slots: [AllySlot]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                Label(Copy.allySlot(slot), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A message to a contact, on the one card for what waits on the owner
/// (PendingCard) while it's a draft: the contact · 发给 TA？ · its full words
/// (改一下 edits them in place), then 不发 / 改一下 / 发送; only 发送 carries
/// the theme color. Once decided (or one that went out directly) it folds
/// to one line with its state; tapping it shows the words.
struct AllyDraftCard: View {
    @Environment(AppStore.self) private var store
    let entry: AllyEntry
    /// Who it goes to.
    let name: String
    /// The exchange is loaded (else only its words show, without buttons).
    var known = true

    #if DEBUG
    /// `-demoDraftEdit YES`: drafts open in 改一下 (snapshots).
    @State private var editing = UserDefaults.standard.bool(forKey: "demoDraftEdit")
    #else
    @State private var editing = false
    #endif
    @State private var text = ""
    @State private var decision = PendingDecider()
    @FocusState private var focused: Bool

    private var pending: Bool { known && entry.isPendingDraft }
    private var item: PendingItem? { store.pendingItem(for: .allyDraft(entry.id)) }
    private var who: String { name.isEmpty ? String(localized: "对方") : name }

    var body: some View {
        Group {
            if pending { open } else { folded }
        }
        .animation(.snappy, value: entry.status)
        .animation(.snappy, value: editing)
        .onAppear { if editing && text.isEmpty { text = entry.text } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ally-draft-\(entry.id)")
    }

    private var open: some View {
        PendingCard(header: PendingCardHeader(item: item, who: who, createdAt: entry.ts, blocking: false),
                    title: Copy.spaced(String(localized: "发给\(who)？")), error: decision.error) {
            if editing {
                TextField("要发的话", text: $text, axis: .vertical)
                    .lineLimit(2...10)
                    .focused($focused)
                    .accessibilityIdentifier("ally-draft-text")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
            } else {
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let slots = entry.slots, !slots.isEmpty {
                AllySlotList(slots: slots)
            }
            if entry.urgent {
                Label("急，对方会马上收到提醒", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            buttons
        }
    }

    /// 「✓ 已发出：今晚七点到…」, 「没发：…」; tapping shows the words whole.
    private var folded: some View {
        let state = known ? (Copy.allyStatus(entry) ?? "") : ""
        let words = entry.text.replacingOccurrences(of: "\n", with: " ")
        let line = Copy.spaced(String(localized: "发给\(who)：\(words)"))
        return PendingFoldedLine(text: state.isEmpty ? line : "\(state) · \(line)", done: entry.status != .rejected, hasDetail: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.callout)
                    .foregroundStyle(entry.status == .rejected ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let slots = entry.slots, !slots.isEmpty { AllySlotList(slots: slots) }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if editing {
            HStack(spacing: 10) {
                Button {
                    editing = false
                    decision.error = nil
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button {
                    focused = false
                    decide(.sendEdited(text))
                } label: {
                    Text("发送").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .lineLimit(1)
            .disabled(decision.working != nil || !store.connection.isOnline)
        } else {
            PendingChoiceButtons(choices: [PendingChoiceButton(title: String(localized: "不发"), choice: .decline),
                                           PendingChoiceButton(title: String(localized: "改一下"), choice: .option("")),
                                           PendingChoiceButton(title: String(localized: "发送"), choice: .accept, primary: true)],
                                 working: decision.working, enabled: store.connection.isOnline) { choice in
                if choice == .option("") {
                    text = entry.text
                    decision.error = nil
                    editing = true
                    focused = true
                } else {
                    decide(choice)
                }
            }
        }
    }

    private func decide(_ choice: PendingChoice) {
        PendingDecider.run(store, .allyDraft(entry.id), choice, into: $decision) { reason in
            choice == .decline ? String(localized: "没改成：\(reason)") : String(localized: "没发出去：\(reason)")
        }
    }
}
