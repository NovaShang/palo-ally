import PaloAllyKit
import SwiftUI

/// 待办 (docs/workbench-design/backlog.html): the list of the folder the
/// pane is for, shared by the agents working in it; in the assistant's
/// pane the assistant's own. 正在做, then 排队 in the owner's order (the
/// first three in full, the rest a line each), then 做完 folded. Rows are
/// dragged to reorder (a long press first on a phone); a row's menu starts
/// it, gives it to one of the folder's agents, marks it done or removes
/// it. A field at the bottom adds one.
struct BacklogView: View {
    /// The agent whose folder's list it is; nil: the assistant's.
    let palID: String?
    /// The phone's pane: its glass tab bar floats over the bottom, the field sits above it.
    var bottomClearance: CGFloat = 0

    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var showDone = false
    @State private var error: String?
    /// The queued row a dragged one hovers over (a line shows where it lands).
    @State private var dropTarget: String?
    @FocusState private var adding: Bool

    /// What a dragged row carries: its id, marked as ours (text dropped from elsewhere isn't taken).
    private static let dragPrefix = "palo-backlog:"

    private var backlog: Backlog? { store.backlog(forPal: palID) }

    var body: some View {
        Group {
            if store.backlogSupported == false {
                ContentUnavailableView(String(localized: "主机还不支持待办", table: "Files"), systemImage: "checklist",
                                       description: Text(String(localized: "更新主机后就能用", table: "Files")))
            } else if let backlog {
                list(backlog)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if store.backlogSupported != false { addField } }
        .task(id: "\(palID ?? "palo")|\(store.connection.isOnline)") {
            if store.connection.isOnline { await store.loadBacklog(forPal: palID) }
        }
        .accessibilityIdentifier("backlog")
    }

    // MARK: the list

    private func list(_ b: Backlog) -> some View {
        // Headings are rows of their own: a section's header would stick to the top on a white bar.
        List {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).modifier(PlainRow())
            }
            if !b.doing.isEmpty {
                header(String(localized: "正在做", table: "Files"))
                ForEach(b.doing) { row($0, place: nil, queue: nil) }
            }
            header(String(localized: "排队 · \(b.queued.count)", table: "Files"))
            if b.queued.isEmpty {
                Text(b.items.isEmpty ? String(localized: "跟 agent 说「放进待办」，它会记在这里；也可以在下面直接加一件。", table: "Files")
                                     : String(localized: "排队的都做完了", table: "Files"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .modifier(PlainRow())
            }
            // Dragged onto another queued row, a row takes its place (the
            // system's drag: the pointer on a Mac, a long press then a move
            // on a phone or an iPad). List.onMove works in edit mode only there.
            ForEach(Array(b.queued.enumerated()), id: \.element.id) { i, item in row(item, place: i, queue: b.queued) }
            if !b.done.isEmpty {
                Button {
                    withAnimation(.snappy) { showDone.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(String(localized: "做完 · \(b.done.count)", table: "Files"))
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                    }
                    .modifier(SectionHeaderStyle())
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .modifier(PlainRow(top: 10))
                .accessibilityIdentifier("backlog-done-toggle")
                if showDone { ForEach(b.done) { row($0, place: nil, queue: nil) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 26)
        .animation(.snappy, value: b.items)
        .accessibilityIdentifier("backlog-list")
    }

    private func header(_ s: String) -> some View {
        Text(s).modifier(SectionHeaderStyle()).modifier(PlainRow(top: 10))
    }

    /// `place`: its place in the queue (the first three show in full);
    /// `queue`: the queue it is in, for a queued row (dragged and dropped on).
    @ViewBuilder private func row(_ item: BacklogItem, place: Int?, queue: [BacklogItem]?) -> some View {
        let full = item.state == .doing || (place ?? 0) < 3 && item.state == .queued
        BacklogRow(item: item, place: place, full: full)
            .modifier(QueueDrag(item: item, queue: queue, target: $dropTarget, prefix: Self.dragPrefix) { id, to in
                guard let dragged = queue?.first(where: { $0.id == id }) else { return }
                act { try await store.moveBacklog(dragged, to: to, forPal: palID) }
            })
            .listRowInsets(EdgeInsets(top: full ? 3 : 0, leading: 10, bottom: full ? 3 : 0, trailing: 10))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contentShape(.rect)
            .contextMenu { menu(item) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { act { try await store.removeBacklog(item, forPal: palID) } } label: {
                    Label(String(localized: "删除", table: "Files"), systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                if item.state != .done {
                    Button { act { try await store.doneBacklog(item, forPal: palID) } } label: {
                        Label(String(localized: "做完了", table: "Files"), systemImage: "checkmark")
                    }
                    .tint(.green)
                }
            }
            .accessibilityIdentifier("backlog-row-\(item.id)")
    }

    @ViewBuilder private func menu(_ item: BacklogItem) -> some View {
        switch item.state {
        case .done:
            Button { act { try await store.doneBacklog(item, done: false, forPal: palID) } } label: {
                Label(String(localized: "放回排队", table: "Files"), systemImage: "arrow.uturn.backward")
            }
        case .doing:
            Button { act { try await store.doneBacklog(item, forPal: palID) } } label: {
                Label(String(localized: "做完了", table: "Files"), systemImage: "checkmark")
            }
            Button { act { try await store.moveBacklog(item, to: 0, forPal: palID) } } label: {
                Label(String(localized: "放回排队", table: "Files"), systemImage: "arrow.uturn.backward")
            }
        default:
            Button {
                store.startBacklog(item, by: palID, words: String(localized: "开始做待办里的这件", table: "Files"))
            } label: {
                Label(startTitle, systemImage: "play")
            }
            let agents = store.backlogAgents(forPal: palID)
            if !agents.isEmpty {
                Menu {
                    Button(String(localized: "谁都行", table: "Files")) { act { try await store.assignBacklog(item, to: nil, forPal: palID) } }
                    ForEach(agents) { a in
                        Button { act { try await store.assignBacklog(item, to: a.id, forPal: palID) } } label: {
                            if item.pal == a.id { Label(a.displayName, systemImage: "checkmark") } else { Text(verbatim: a.displayName) }
                        }
                    }
                } label: {
                    Label(String(localized: "交给…", table: "Files"), systemImage: "person.crop.circle")
                }
            }
            Button { act { try await store.moveBacklog(item, to: 0, forPal: palID) } } label: {
                Label(String(localized: "放到最前", table: "Files"), systemImage: "arrow.up.to.line")
            }
            Button { act { try await store.doneBacklog(item, forPal: palID) } } label: {
                Label(String(localized: "做完了", table: "Files"), systemImage: "checkmark")
            }
        }
        Button(role: .destructive) { act { try await store.removeBacklog(item, forPal: palID) } } label: {
            Label(String(localized: "删除", table: "Files"), systemImage: "trash")
        }
    }

    /// 开始: to this agent, or the assistant.
    private var startTitle: String {
        if let palID, let name = store.pal(id: palID)?.displayName {
            return String(localized: "让\(name)开始做", table: "Files")
        }
        return String(localized: "让助理开始做", table: "Files")
    }

    private func act(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = Friendly.message(error) }
        }
    }

    // MARK: adding

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.secondary)
            TextField(String(localized: "加一件", table: "Files"), text: $draft)
                .textFieldStyle(.plain)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(add)
                .accessibilityIdentifier("backlog-add")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8 + bottomClearance)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        act { try await store.addBacklog(text, forPal: palID) }
        // Typing on: the next one.
        adding = true
    }
}

/// A queued row's drag and drop: it can be picked up, and another dropped on
/// it takes its place (moving down: after it; up: before it). A line over
/// the row while one hovers.
private struct QueueDrag: ViewModifier {
    let item: BacklogItem
    let queue: [BacklogItem]?
    @Binding var target: String?
    let prefix: String
    let move: (_ id: String, _ to: Int) -> Void

    func body(content: Content) -> some View {
        if let queue, let at = queue.firstIndex(where: { $0.id == item.id }) {
            content
                .draggable(prefix + item.id)
                .dropDestination(for: String.self) { ids, _ in
                    target = nil
                    guard let raw = ids.first, raw.hasPrefix(prefix) else { return false }
                    let id = String(raw.dropFirst(prefix.count))
                    guard id != item.id, queue.contains(where: { $0.id == id }) else { return false }
                    move(id, at)
                    return true
                } isTargeted: { on in
                    if on { target = item.id } else if target == item.id { target = nil }
                }
                .overlay(alignment: .top) {
                    if target == item.id {
                        Capsule().fill(Color.primary.opacity(0.35)).frame(height: 2).offset(y: -3)
                    }
                }
        } else {
            content
        }
    }
}

/// A row with no background, separator or drag of its own (a heading, a line of text).
private struct PlainRow: ViewModifier {
    var top: CGFloat = 2
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: top, leading: 10, bottom: 2, trailing: 10))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.horizontal, 6)
    }
}

/// One item: its place, its words (and note, in full rows), who does it or
/// who it's for. Being done: a dot in the working color and the agent.
private struct BacklogRow: View {
    let item: BacklogItem
    let place: Int?
    /// The first three of the queue and the ones being done: a card with the note.
    let full: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            lead
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(full ? .subheadline : .footnote)
                    .foregroundStyle(item.state == .done ? .secondary : full ? .primary : .secondary)
                    .strikethrough(item.state == .done, color: .secondary)
                    .lineLimit(full ? 3 : 1)
                if full, let note = item.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let who = whoLine {
                    Text(who).font(.caption2).foregroundStyle(item.state == .doing ? StatusDot.color(.working) : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, full ? 10 : 8)
        .padding(.vertical, full ? 8 : 5)
        .background {
            if full {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.state == .doing ? StatusDot.color(.working).opacity(0.12) : Color.primary.opacity(0.06))
            }
        }
    }

    @ViewBuilder private var lead: some View {
        if item.state == .doing {
            Circle().fill(StatusDot.color(.working)).frame(width: 7, height: 7)
                .frame(width: 18)
        } else if item.state == .done {
            Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 18)
        } else if let place {
            Text(verbatim: "\(place + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
        }
    }

    private var whoLine: String? {
        guard let name = item.palName, !name.isEmpty else { return nil }
        switch item.state {
        case .doing: return name
        case .queued: return String(localized: "给\(name)", table: "Files")
        default: return nil
        }
    }
}
