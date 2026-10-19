import PaloAllyKit
import SwiftUI

/// The pieces the details page shares between a session and Palo: the
/// header, the row of big actions, and the context line.

// MARK: - header

struct DetailHeader: View {
    /// The round indicator (a `SessionIndicator`), large.
    let indicator: AnyView
    let name: String
    /// The folder (a session); nil for Palo.
    var folder: String?
    /// What it is doing now (or the state, when it is not).
    let line: String
    /// Palo's line is a button (jump to the sessions waiting).
    var lineAction: (() -> Void)?
    @Binding var editing: Bool
    @Binding var draft: String
    var canRename = true
    var onRename: () -> Void
    var onBeginRename: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            indicator.padding(.bottom, 4)
            if editing {
                HStack {
                    TextField("名字", text: $draft)
                        .focused($focused)
                        .submitLabel(.done)
                        .multilineTextAlignment(.center)
                        .font(.title2.bold())
                        .onSubmit(onRename)
                        .accessibilityIdentifier("detail-name-field")
                    Button("好", action: onRename)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onAppear { focused = true }
            } else {
                Button {
                    onBeginRename()
                } label: {
                    Text(name).font(.title2.bold()).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .disabled(!canRename)
                .accessibilityHint(canRename ? Text("改名字") : Text(""))
                .accessibilityIdentifier("detail-rename")
            }
            if let folder, !folder.isEmpty {
                Text(folder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let lineAction {
                Button(action: lineAction) {
                    Text(line).font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - actions

struct DetailAction: Identifiable {
    let id: String
    let title: Text
    let icon: String
    var enabled = true
    let run: () -> Void
}

/// Four big buttons in a row; unavailable ones dim.
struct DetailActionRow: View {
    let actions: [DetailAction]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(actions) { a in
                Button(action: a.run) {
                    VStack(spacing: 5) {
                        Image(systemName: a.icon).font(.title3).frame(height: 24)
                        a.title.font(.caption)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!a.enabled)
                .opacity(a.enabled ? 1 : 0.35)
                .accessibilityIdentifier("detail-action-\(a.id)")
            }
        }
    }
}

extension View {
    /// A section row with no card behind it (the header, the action row).
    func detailBare() -> some View {
        self.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

// MARK: - context

enum DetailTokens {
    /// 82_000 -> "82k", 1_000_000 -> "1M".
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

    static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }
}

/// 「上下文」: the bar, "82k / 200k", and 压缩 when the caller gives one.
struct DetailContextSection: View {
    let percent: Int?
    let tokens: Int?
    let window: Int?
    var lastCompactAt: Int64?
    var compact: (() -> Void)?
    var compacting = false
    var canCompact = true

    var body: some View {
        if let percent {
            Section("上下文") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(min(max(percent, 0), 100)) / 100)
                        .tint(percent >= 95 ? .red : percent >= 80 ? .orange : .secondary)
                    HStack {
                        if let tokens, let window, window > 0 {
                            Text("\(DetailTokens.short(tokens)) / \(DetailTokens.short(window))")
                        } else {
                            Text("\(percent)%")
                        }
                        Spacer()
                        if let at = lastCompactAt, at > 0 {
                            Text("上次压缩 \(Copy.relative(at))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                if let compact {
                    Button(compacting ? String(localized: "正在压缩…") : String(localized: "压缩"), action: compact)
                        .disabled(!canCompact || compacting)
                        .accessibilityIdentifier("detail-compact")
                }
            }
        }
    }
}
