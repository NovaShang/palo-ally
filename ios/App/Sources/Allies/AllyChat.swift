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
    @Environment(AppModel.self) private var model
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

/// A message to an Ally. While it's a draft: its full words, then 发送 /
/// 改一下 (edit in place) / 不发. Once decided it stays, with its state. The
/// same place and look as an approval card; only 发送 carries the theme color.
struct AllyDraftCard: View {
    @Environment(AppStore.self) private var store
    let entry: AllyEntry
    /// Who it goes to.
    let name: String
    /// The exchange is loaded (else only its words show, without buttons).
    var known = true
    /// Inside a list row: the row is the card.
    var framed = true

    #if DEBUG
    /// `-demoDraftEdit YES`: drafts open in 改一下 (snapshots).
    @State private var editing = UserDefaults.standard.bool(forKey: "demoDraftEdit")
    #else
    @State private var editing = false
    #endif
    @State private var text = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var pending: Bool { known && entry.isPendingDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "paperplane")
                    .foregroundStyle(.secondary)
                Text(Copy.spaced(String(localized: "发给\(name.isEmpty ? String(localized: "对方") : name)")))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !pending, known, let status = Copy.allyStatus(entry) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }

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
                    .foregroundStyle(entry.status == .rejected ? .secondary : .primary)
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

            if pending {
                buttons
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(framed ? 16 : 0)
        .background {
            if framed {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary)
            }
        }
        .overlay {
            if framed {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(pending ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
            }
        }
        .animation(.snappy, value: entry.status)
        .animation(.snappy, value: editing)
        .onAppear { if editing && text.isEmpty { text = entry.text } }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if editing {
                Button {
                    editing = false
                    error = nil
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button {
                    send(text)
                } label: {
                    Text("发送").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button {
                    discard()
                } label: {
                    Text("不发").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button {
                    text = entry.text
                    error = nil
                    editing = true
                    focused = true
                } label: {
                    Text("改一下").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button {
                    send(nil)
                } label: {
                    Text("发送").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .lineLimit(1)
        .disabled(working || !store.connection.isOnline)
    }

    private func send(_ words: String?) {
        working = true
        error = nil
        focused = false
        Task {
            do {
                try await store.send(draft: entry, text: words)
                editing = false
            } catch {
                self.error = String(localized: "没发出去：\(Copy.error(error))")
            }
            working = false
        }
    }

    private func discard() {
        working = true
        error = nil
        Task {
            do { try await store.decide(entry, .discard) } catch { self.error = String(localized: "没改成：\(Copy.error(error))") }
            working = false
        }
    }
}
