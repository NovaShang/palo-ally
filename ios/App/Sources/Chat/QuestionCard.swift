import PaloAllyKit
import SwiftUI

/// The assistant asks the owner to choose (Claude Code's AskUserQuestion):
/// each question with its options, single or multi select, plus 「其他…」 for
/// the owner's own words. Plain in-content controls; only 发送 carries the
/// theme color. Once answered it folds into a short summary.
struct QuestionCard: View {
    @Environment(AppStore.self) private var store
    let question: Question

    /// Per question (by index): chosen option labels, and the 「其他」 text.
    @State private var picked: [Int: Set<String>] = [:]
    @State private var otherOn: [Int: Bool] = [:]
    @State private var otherText: [Int: String] = [:]
    @State private var working = false
    @State private var error: String?
    @FocusState private var focusedOther: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.secondary)
                Text(question.isPending ? "想问你" : "问过你")
                    .font(.headline)
                Spacer(minLength: 0)
                if !question.isPending {
                    Text(question.status == .answered ? "已回答" : "没等到回答")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if question.isPending {
                ForEach(Array(question.items.enumerated()), id: \.offset) { i, item in
                    itemPicker(i, item)
                }
                meta
                Button {
                    send()
                } label: {
                    Text(working ? "发送中…" : "发送").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!complete || working)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else {
                summary
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(question.isPending ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
        }
        .animation(.snappy, value: question.status)
    }

    // MARK: one question

    @ViewBuilder
    private func itemPicker(_ i: Int, _ item: QuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = item.header, !header.isEmpty {
                Text(item.multiSelect ? "\(header) · 可多选" : header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.multiSelect {
                Text("可多选").font(.caption).foregroundStyle(.secondary)
            }
            Text(item.question)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
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

    private var meta: some View {
        HStack(spacing: 6) {
            if let taskId = question.taskId, let task = store.task(id: taskId) {
                Text("为了「\(task.title)」 ·")
            }
            Text(Copy.relative(question.createdAt))
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
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

    private var complete: Bool {
        question.items.enumerated().allSatisfy { answer($0.offset, $0.element) != nil }
    }

    private func send() {
        var answers: [String: String] = [:]
        for (i, item) in question.items.enumerated() {
            guard let a = answer(i, item) else { return }
            answers[item.question] = a
        }
        working = true
        error = nil
        focusedOther = nil
        Task {
            do {
                try await store.answer(question, answers: answers)
            } catch {
                self.error = "没发出去：\(Friendly.message(error))"
            }
            working = false
        }
    }
}
