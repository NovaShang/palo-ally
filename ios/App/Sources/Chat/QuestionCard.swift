import PaloAllyKit
import SwiftUI

/// The assistant, an agent or a session asks the owner to choose (Claude
/// Code's AskUserQuestion), on the one card for what waits on the owner
/// (PendingCard): who asks · the question (or how many) · its header, then
/// each question with its options, single or multi select, plus 「其他…」
/// for the owner's own words. Any question can be left out, and 跳过 skips
/// the card: the asker is told in words that those went unanswered. Only
/// 发送 carries the theme color. Answered, it folds to one line; tapping it
/// shows the answers.
struct QuestionCard: View {
    @Environment(AppStore.self) private var store
    let question: Question
    /// Kept for the callers (the session's page no longer differs).
    var linksSource = true

    /// A session's question that expired here: the session asks at the computer now.
    private var waitsAtComputer: Bool { store.waitsAtComputer(question) }
    private var item: PendingItem? { store.pendingItem(for: .question(question.id)) }

    /// Per question (by index): chosen option labels, and the 「其他」 text.
    @State private var picked: [Int: Set<String>] = [:]
    @State private var otherOn: [Int: Bool] = [:]
    @State private var otherText: [Int: String] = [:]
    @State private var decision = PendingDecider()
    @FocusState private var focusedOther: Int?

    var body: some View {
        Group {
            if question.isPending || waitsAtComputer { open } else { folded }
        }
        .animation(.snappy, value: question.status)
        .accessibilityIdentifier("question-\(question.id)")
    }

    private var header: PendingCardHeader {
        PendingCardHeader(item: item, who: question.source?.name ?? store.assistantName, createdAt: question.createdAt, blocking: true)
    }

    /// One question: it is the title (its header the background); several: how many.
    private var one: Bool { question.items.count == 1 }
    private var title: String {
        if one { return question.items.first?.question ?? "" }
        return String(localized: "想问你 \(question.items.count) 个问题")
    }

    private var background: String? {
        guard one, let item = question.items.first else { return nil }
        let header = item.header ?? ""
        if item.multiSelect { return header.isEmpty ? String(localized: "可多选") : String(localized: "\(header) · 可多选") }
        return header.isEmpty ? nil : header
    }

    private var open: some View {
        PendingCard(header: header, title: title, background: background, error: decision.error) {
            if waitsAtComputer {
                asked
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(question.items.enumerated()), id: \.offset) { i, item in
                        itemPicker(i, item)
                    }
                }
                if let taskId = question.taskId, let task = store.task(id: taskId) {
                    Text("为了「\(task.title)」")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        } actions: {
            if waitsAtComputer {
                Label(Copy.waitsAtComputer(question.note), systemImage: "laptopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button {
                        send(skippingAll: true)
                    } label: {
                        Text(question.items.count > 1 ? String(localized: "全部跳过") : String(localized: "跳过"))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    Button {
                        send()
                    } label: {
                        Text(sendTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(answeredCount == 0)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(decision.working != nil)
            }
        }
    }

    /// Answered: 「✓ 已回答：四个人；日料, 粤菜」; tapping shows each question with its answer.
    private var folded: some View {
        PendingFoldedLine(text: foldedText, done: question.status == .answered && !(question.answers ?? [:]).isEmpty,
                          hasDetail: true) { summary }
    }

    private var foldedText: String {
        guard question.status == .answered else { return String(localized: "没等到回答：\(title)") }
        let answers = question.items.compactMap { question.answers?[$0.question] }.filter { !$0.isEmpty }
        if answers.isEmpty { return String(localized: "跳过了：\(title)") }
        return String(localized: "已回答：\(answers.joined(separator: "；"))")
    }

    // MARK: one question

    @ViewBuilder
    private func itemPicker(_ i: Int, _ item: QuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // One question: the card's title and background already say it.
            if !one {
                if let header = item.header, !header.isEmpty {
                    Text(item.multiSelect ? String(localized: "\(header) · 可多选") : header)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.multiSelect {
                    Text("可多选").font(.caption).foregroundStyle(.secondary)
                }
                Text(item.question)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 2) {
                ForEach(item.options, id: \.label) { option in
                    optionRow(i, item, option)
                }
                otherRow(i, item)
            }
        }
    }

    private func optionRow(_ i: Int, _ item: QuestionItem, _ option: QuestionOption) -> some View {
        let on = picked[i, default: []].contains(option.label)
        return Button {
            toggle(i, item, option.label)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: mark(item, on))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).foregroundStyle(.primary)
                    if let d = option.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(on ? Color.primary.opacity(0.06) : Color.clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func otherRow(_ i: Int, _ item: QuestionItem) -> some View {
        let on = otherOn[i] ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                setOther(i, item, !on)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: mark(item, on))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    Text("其他…").foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(on ? Color.primary.opacity(0.06) : Color.clear, in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if on {
                TextField("说说你的想法", text: Binding(get: { otherText[i] ?? "" }, set: { otherText[i] = $0 }), axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focusedOther, equals: i)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
                    .padding(.leading, 34)
            }
        }
    }

    // MARK: waiting at the computer

    /// The questions and their options as they were asked, nothing to tap.
    private var asked: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(question.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.question)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(item.options, id: \.label) { option in
                        Text("· \(option.label)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: answered

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(question.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let a = question.answers?[item.question], !a.isEmpty {
                        Text(a).font(.callout)
                    } else if question.skipped?.contains(item.question) == true {
                        Text("跳过了").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: choosing

    private func mark(_ item: QuestionItem, _ on: Bool) -> String {
        item.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
    }

    private func toggle(_ i: Int, _ item: QuestionItem, _ label: String) {
        var set = picked[i, default: []]
        if item.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
            otherOn[i] = false // one choice: the options and 「其他」 exclude each other
            focusedOther = nil
        }
        picked[i] = set
    }

    private func setOther(_ i: Int, _ item: QuestionItem, _ on: Bool) {
        otherOn[i] = on
        if on && !item.multiSelect { picked[i] = [] }
        focusedOther = on ? i : nil
    }

    /// The answer for question i: chosen labels in option order (", "), then
    /// the owner's own words; nil while nothing is chosen.
    private func answer(_ i: Int, _ item: QuestionItem) -> String? {
        let chosen = item.options.map(\.label).filter { picked[i, default: []].contains($0) }
        let own = (otherOn[i] ?? false) ? (otherText[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let parts = chosen + (own.isEmpty ? [] : [own])
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var answeredCount: Int {
        question.items.enumerated().filter { answer($0.offset, $0.element) != nil }.count
    }

    /// 发送, or what it leaves out when some questions are unanswered.
    private var sendTitle: String {
        if decision.working != nil { return String(localized: "发送中…") }
        let left = question.items.count - answeredCount
        return answeredCount > 0 && left > 0 ? String(localized: "发送，跳过 \(left) 题") : String(localized: "发送")
    }

    /// Unanswered questions are left out, which the host passes on as skipped.
    private func send(skippingAll: Bool = false) {
        var answers: [String: String] = [:]
        if !skippingAll {
            for (i, item) in question.items.enumerated() {
                if let a = answer(i, item) { answers[item.question] = a }
            }
            guard !answers.isEmpty else { return }
        }
        focusedOther = nil
        PendingDecider.run(store, .question(question.id), .answers(answers), into: $decision)
    }
}
