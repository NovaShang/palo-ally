import PaloAllyKit
import SwiftUI

// The one card for everything that waits on the owner (docs/structure-
// proposals-2026-11.md §2): a question, a permission prompt, the assistant's
// proposal, a message to a contact, an item of 等你的事. Who · what to
// decide · a line of background · the options; each kind keeps its own
// buttons (and what's between: a command, the questions' choices, a
// draft's words). Once decided it folds to one gray line. The same card in
// the conversation and in the list (PendingRow), and every button decides
// through one method (`AppStore.decide`).

/// Who it's from, whether that one is stopped on it, and when: the card's first line.
struct PendingCardHeader {
    var who: String
    var blocking: Bool
    var createdAt: Int64

    /// From the card's item when it has one (the list's words), else the card's own.
    @MainActor
    init(item: PendingItem?, who: String, createdAt: Int64, blocking: Bool) {
        let name = item?.source.name ?? ""
        self.who = name.isEmpty ? (who.isEmpty ? String(localized: "助理") : who) : name
        self.blocking = item?.blocking ?? blocking
        self.createdAt = item?.createdAt ?? createdAt
    }

    var line: String {
        let age = Copy.relative(createdAt)
        var parts = [who]
        if blocking { parts.append(String(localized: "卡着它")) }
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }
}

/// The shell: on the conversation's secondary background with a thin
/// outline while it waits (content, not chrome: no glass).
struct PendingCard<Content: View, Actions: View>: View {
    let header: PendingCardHeader
    /// What to decide.
    let title: String
    /// One line of background (a few when it's all there is).
    var background: String? = nil
    var error: String? = nil
    /// Inside a list row: a little tighter.
    var compact = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 6) {
                Circle().fill(StatusDot.color(.waiting)).frame(width: 7, height: 7)
                Text(header.line).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !title.isEmpty {
                Text(title)
                    .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let background, !background.isEmpty {
                Text(background)
                    .font(compact ? .footnote : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 3 : 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
            actions()
                .padding(.top, 4)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 12 : 14)
        .background(.background.secondary, in: .rect(cornerRadius: compact ? 14 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

extension PendingCard where Content == EmptyView {
    init(header: PendingCardHeader, title: String, background: String? = nil, error: String? = nil, compact: Bool = false,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(header: header, title: title, background: background, error: error, compact: compact,
                  content: { EmptyView() }, actions: actions)
    }
}

/// A decided card: one gray line (「✓ 已定：允许 · 撤回」). Tapping it shows
/// what was decided on, when there's more than the line (`detail`).
struct PendingFoldedLine<Detail: View>: View {
    let text: String
    /// Decided as asked (a check), or left / gone (a turn-back arrow).
    var done = true
    /// 撤回 / 放回 / 去看看它, after the line.
    var action: (title: String, run: () -> Void)? = nil
    var hasDetail = false
    @ViewBuilder var detail: () -> Detail
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The line reads as one; its action stays a button of its own.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: done ? "checkmark" : "arrow.uturn.backward")
                        .foregroundStyle(done ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    Text(text)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                    if hasDetail {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                if let action {
                    Text("·").accessibilityHidden(true)
                    Button(action.title, action: action.run)
                        .buttonStyle(.plain)
                        .underline()
                        .fixedSize()
                }
            }
            .contentShape(.rect)
            .onTapGesture { if hasDetail { withAnimation(.snappy) { expanded.toggle() } } }
            if expanded {
                detail()
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

extension PendingFoldedLine where Detail == EmptyView {
    init(text: String, done: Bool = true, action: (title: String, run: () -> Void)? = nil) {
        self.init(text: text, done: done, action: action, hasDetail: false, detail: { EmptyView() })
    }
}

/// A decision's buttons: side by side while they fit, else one under
/// another as wide as the card (a long option reads whole). Only the
/// primary one carries the theme color.
struct PendingChoiceButtons: View {
    let choices: [PendingChoiceButton]
    var working: PendingChoice? = nil
    var enabled = true
    /// The conversation's cards: large buttons; the list's rows: regular.
    var large = true
    let pick: (PendingChoice) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons(wide: false) }
            VStack(alignment: .leading, spacing: 6) { buttons(wide: true) }
        }
        .controlSize(large ? .large : .regular)
        .buttonBorderShape(.capsule)
        .disabled(working != nil || !enabled)
    }

    @ViewBuilder private func buttons(wide: Bool) -> some View {
        // Beside a primary one the others step back; options of equal weight stay plain.
        let quiet: Color = choices.contains(where: \.primary) ? .secondary : .primary
        ForEach(choices) { c in
            let label = Text(working == c.choice ? String(localized: "稍等…") : c.title)
                .lineLimit(wide ? nil : 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: !wide, vertical: wide)
                .frame(maxWidth: .infinity)
            if c.primary {
                Button { pick(c.choice) } label: { label }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pending-choice-\(c.title)")
            } else {
                Button { pick(c.choice) } label: { label }
                    .buttonStyle(.bordered)
                    .tint(quiet)
                    .accessibilityIdentifier("pending-choice-\(c.title)")
            }
        }
    }
}

/// 其他…: a line for the owner's own words, sent with ↑.
struct PendingOwnWords: View {
    @Binding var typing: Bool
    /// The button that opens the line: 其他…, or 直接回答 when there are no options.
    var label = String(localized: "其他…")
    var prompt = String(localized: "写你的回答")
    let send: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if typing {
            HStack(spacing: 6) {
                TextField(prompt, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                    .onSubmit(submit)
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(String(localized: "发送"))
            }
            .onAppear { focused = true }
        } else {
            Button { typing = true } label: {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        typing = false
        send(text)
    }
}

// MARK: - deciding

/// One decision under way on a card: what was tapped, and why it didn't go.
@MainActor
struct PendingDecider {
    var working: PendingChoice?
    var error: String?

    /// Every card's buttons and every row's options go here.
    static func run(_ store: AppStore, _ subject: PendingSubject, _ choice: PendingChoice, into state: Binding<PendingDecider>,
                    failure: @escaping (String) -> String = { String(localized: "没发出去：\($0)") }) {
        state.wrappedValue.working = choice
        state.wrappedValue.error = nil
        Task {
            do {
                try await store.decide(subject, choice)
            } catch {
                state.wrappedValue.error = failure(Copy.error(error))
            }
            state.wrappedValue.working = nil
        }
    }
}
