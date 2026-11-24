import PaloAllyKit
import SwiftUI

/// 待办 (docs/workbench-design/backlog-v2.html): the list of the folder the
/// pane is for, shared by the agents working in it; in the assistant's pane
/// the assistant's own. 正在做, 排队 in the owner's order, 做完 folded, on
/// 成果's cards. A row's circle says it's done, ▶ has its agent start it, a
/// tap on its words opens it in place (BacklogRow.swift). Rows are dragged
/// to reorder (a long press first on a phone); swiped away on a phone; a
/// menu has the rest. A field at the bottom adds one.
struct BacklogView: View {
    /// The agent whose folder's list it is; nil: the assistant's.
    let palID: String?
    /// The phone's pane: its glass tab bar floats over the bottom, the field sits above it.
    var bottomClearance: CGFloat = 0
    /// The phone's pane: put away when a page opens under it.
    var dismiss: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(WindowModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var showDone = false
    /// The row open for editing, with what's typed in it.
    @State private var open: BacklogDraft?
    /// The open row's frame: a tap outside closes it. nil until it's laid out.
    @State private var openFrame: CGRect?
    @State private var toast: BacklogToast?
    /// The queued row a dragged one hovers over (a line shows where it lands).
    @State private var dropTarget: String?
    /// 新建 agent for an item.
    @State private var newAgent: NewSessionPanel.FirstWords?
    /// The item just added: the list scrolls to it.
    @State private var added: String?
    @FocusState private var adding: Bool

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
        .overlay(alignment: .bottom) {
            if let toast {
                BacklogToastView(toast: toast) { self.toast = nil }
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: toast?.id)
        .safeAreaInset(edge: .bottom, spacing: 0) { if store.backlogSupported != false { addField } }
        .task(id: "\(palID ?? "palo")|\(store.connection.isOnline)") {
            if store.connection.isOnline { await store.loadBacklog(forPal: palID) }
        }
        .task(id: toast?.id) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { toast = nil }
        }
        // What's typed is never only here: saved when the app goes away, the
        // pane changes, or the open row's item is no longer in line.
        .onChange(of: scenePhase) { _, phase in if phase != .active { open?.save() } }
        .onDisappear { close() }
        .onChange(of: backlog?.queued.map(\.id)) { _, ids in
            if let open, ids?.contains(open.id) != true { close() }
        }
        #if DEBUG || PERF_HARNESS
        .onReceive(NotificationCenter.default.publisher(for: .demoBacklog)) { demo($0.object as? String ?? "") }
        #endif
        .sheet(item: $newAgent) { first in
            NewSessionPanel(first: first, opened: dismiss).environment(model).environment(store)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backlog")
    }

    // MARK: the list

    private func list(_ b: Backlog) -> some View {
        ScrollViewReader { scroll in
            List {
                if !b.doing.isEmpty {
                    Section {
                        ForEach(b.doing) { item in
                            BacklogDoingRow(item: item, agent: agent(of: item, else: nil)) { openAgent(item) }
                                .modifier(Row(item: item))
                                .contextMenu { menu(item) }
                                .swipeActions(edge: .trailing) { deleteAction(item) }
                        }
                    } header: {
                        BacklogHeader(String(localized: "正在做", table: "Files"), first: true)
                    }
                }
                if !b.queued.isEmpty {
                    Section {
                        ForEach(Array(b.queued.enumerated()), id: \.element.id) { i, item in
                            queued(item, at: i, in: b)
                        }
                    } header: {
                        BacklogHeader(String(localized: "排队", table: "Files"), first: b.doing.isEmpty)
                    }
                }
                if !b.done.isEmpty {
                    Section {
                        if showDone {
                            ForEach(b.done) { item in
                                BacklogDoneRow(item: item) { act { try await store.moveBacklog(item, to: b.queued.count, forPal: palID) } }
                                    .modifier(Row(item: item))
                                    .contextMenu { menu(item) }
                                    .swipeActions(edge: .trailing) { deleteAction(item) }
                            }
                        }
                    } header: {
                        doneHeader(b.done.count)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 10)
            .environment(\.defaultMinListHeaderHeight, 10)
            .contentMargins(.bottom, 12, for: .scrollContent)
            .animation(.snappy(duration: 0.25), value: b.items)
            .simultaneousGesture(tapElsewhere, including: open == nil ? .subviews : .all)
            .overlay {
                if b.items.isEmpty {
                    Text(String(localized: "没有待办", table: "Files"))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: added) { _, id in
                guard let id else { return }
                // Once its row is there.
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.snappy) { scroll.scrollTo(id, anchor: .bottom) }
                    added = nil
                }
            }
            .accessibilityIdentifier("backlog-list")
        }
    }

    @ViewBuilder private func queued(_ item: BacklogItem, at i: Int, in b: Backlog) -> some View {
        if let open, open.id == item.id {
            BacklogOpenRow(draft: open, item: item, editable: b.editable == true, agent: agent(of: item, else: palID),
                           agents: choices, pick: { pick($0, for: item) }, check: { finish(item) },
                           remove: { remove(item) }, start: { start(item) },
                           close: { close() }, discard: { close(saving: false) })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { openFrame = $0 }
                .modifier(Row(item: item))
                .id(item.id)
        } else {
            BacklogQueuedRow(item: item, agent: item.pal == nil ? nil : agent(of: item, else: palID),
                             startTitle: startTitle(item),
                             check: { finish(item) }, open: { openRow(item) }, start: { start(item) })
                .modifier(QueueDrag(item: item, queue: b.queued, target: $dropTarget) { id, to in
                    guard let dragged = b.queued.first(where: { $0.id == id }) else { return }
                    act { try await store.moveBacklog(dragged, to: to, forPal: palID) }
                })
                .modifier(Row(item: item))
                .contextMenu { menu(item) }
                .swipeActions(edge: .trailing) { deleteAction(item) }
                .id(item.id)
        }
    }

    /// What every row has: the card edge to edge, its separator from the words on, its name.
    private struct Row: ViewModifier {
        let item: BacklogItem
        func body(content: Content) -> some View {
            content
                .listRowInsets(EdgeInsets())
                .alignmentGuide(.listRowSeparatorLeading) { _ in BacklogMetrics.separatorInset }
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("backlog-row-\(item.id)")
        }
    }

    private func doneHeader(_ n: Int) -> some View {
        Button {
            withAnimation(.snappy) { showDone.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(String(localized: "做完 \(n)", table: "Files"))
                Image(systemName: "chevron.right")
                    .font(.system(size: BacklogMetrics.mac ? 8 : 11, weight: .bold))
                    .rotationEffect(.degrees(showDone ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(BacklogHeaderStyle(top: BacklogMetrics.headerTop + 2))
        .accessibilityIdentifier("backlog-done-toggle")
    }

    /// A tap on the list that isn't in the open row.
    private var tapElsewhere: some Gesture {
        SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            guard let frame = openFrame, !frame.contains(tap.location) else { return }
            close()
        }
    }

    // MARK: the open row

    private func openRow(_ item: BacklogItem) {
        close()
        openFrame = nil
        withAnimation(.snappy(duration: 0.2)) { open = BacklogDraft(item, owner: palID, store: store) }
    }

    private func close(saving: Bool = true) {
        guard let open else { return }
        if saving { open.save(closing: true) } else { open.discard() }
        openFrame = nil
        withAnimation(.snappy(duration: 0.2)) { self.open = nil }
    }

    // MARK: the owner's hand

    /// The item as it is now (the words just saved).
    private func now(_ item: BacklogItem) -> BacklogItem {
        backlog?.items.first { $0.id == item.id } ?? item
    }

    private func finish(_ item: BacklogItem) {
        close()
        let item = now(item)
        let place = item.state == .queued ? backlog?.place(of: item.id) ?? 0 : 0
        act({ try await store.doneBacklog(item, forPal: palID) }, says: String(localized: "做完了", table: "Files")) {
            try await store.undoDoneBacklog(item, place: place, forPal: palID)
        }
    }

    private func remove(_ item: BacklogItem) {
        close()
        let item = now(item)
        let place = backlog?.place(of: item.id) ?? 0
        act({ try await store.removeBacklog(item, forPal: palID) }, says: String(localized: "删了", table: "Files")) {
            try await store.restoreBacklog(item, place: place, forPal: palID)
        }
    }

    /// To its agent, else the pane's. The words are on their way: nothing to take back.
    private func start(_ item: BacklogItem) {
        close()
        let item = now(item)
        let agent = agent(of: item, else: palID)
        toast = BacklogToast(text: String(localized: "交给了\(agent.name)", table: "Files"))
        store.startBacklog(item, by: agent.id, forPal: palID, words: String(localized: "开始做待办里的这件", table: "Files"))
    }

    private func pick(_ choice: BacklogAgent.Choice, for item: BacklogItem) {
        switch choice {
        case .agent(let id):
            act { try await store.assignBacklog(item, to: id, forPal: palID) }
        case .new:
            close()
            let item = now(item)
            newAgent = .init(item: item, owner: palID, folder: palID == nil ? nil : backlog?.folder)
        }
    }

    private func openAgent(_ item: BacklogItem) {
        guard let id = item.pal else {
            dismiss()
            return model.openPalo()
        }
        guard store.pal(id: id) != nil else { return }
        dismiss()
        if case .workspace(let ws)? = model.selection, model.layout != .phone, store.workspace(id: ws)?.memberIds.contains(id) == true {
            model.activate(tile: id, in: ws)
        } else {
            model.openPal(id)
        }
    }

    private func act(_ work: @escaping () async throws -> Void, says: String? = nil, undo: (() async throws -> Void)? = nil) {
        if let says { toast = BacklogToast(text: says, undo: undo.map { undo in { act(undo) } }) }
        Task {
            do { try await work() } catch { toast = BacklogToast(text: Friendly.message(error)) }
        }
    }

    // MARK: who

    /// Who has it: its agent, else `other` (nil: the assistant).
    private func agent(of item: BacklogItem, else other: String?) -> BacklogAgent {
        if let id = item.pal {
            if let pal = store.pal(id: id) { return BacklogAgent(pal) }
            // It's gone: its name on the one being done; the pane's agent starts a queued one.
            if item.state != .queued { return BacklogAgent(id: id, name: item.palName ?? "", state: .idle, running: 0) }
        }
        if let pal = other.flatMap({ store.pal(id: $0) }) { return BacklogAgent(pal) }
        return BacklogAgent(id: nil, name: store.assistantName, state: store.paloDot, running: 0)
    }

    /// Who it can be given to: the folder's agents (and the assistant, on its own list).
    private var choices: [BacklogAgent] {
        (palID == nil ? [BacklogAgent(id: nil, name: store.assistantName, state: store.paloDot, running: 0)] : [])
            + store.backlogAgents(forPal: palID).map { BacklogAgent($0) }
    }

    // MARK: the menu

    @ViewBuilder private func deleteAction(_ item: BacklogItem) -> some View {
        // Not the destructive role: the row would leave before the list says so.
        Button { remove(item) } label: {
            Label(String(localized: "删除", table: "Files"), systemImage: "trash")
        }
        .tint(.red)
    }

    @ViewBuilder private func menu(_ item: BacklogItem) -> some View {
        switch item.state {
        case .done:
            Button { act { try await store.moveBacklog(item, to: backlog?.queued.count ?? 0, forPal: palID) } } label: {
                Label(String(localized: "放回排队", table: "Files"), systemImage: "arrow.uturn.backward")
            }
        case .doing:
            Button { finish(item) } label: {
                Label(String(localized: "做完了", table: "Files"), systemImage: "checkmark")
            }
            Button { act { try await store.moveBacklog(item, to: 0, forPal: palID) } } label: {
                Label(String(localized: "放回排队", table: "Files"), systemImage: "arrow.uturn.backward")
            }
        default:
            Button { start(item) } label: {
                Label(String(localized: "开始", table: "Files"), systemImage: "play")
            }
            Menu {
                Button(String(localized: "谁都行", table: "Files")) { act { try await store.assignBacklog(item, to: nil, forPal: palID) } }
                ForEach(store.backlogAgents(forPal: palID)) { a in
                    Button { act { try await store.assignBacklog(item, to: a.id, forPal: palID) } } label: {
                        if item.pal == a.id { Label(a.displayName, systemImage: "checkmark") } else { Text(verbatim: a.displayName) }
                    }
                }
            } label: {
                Label(String(localized: "交给", table: "Files"), systemImage: "person.crop.circle")
            }
            Button { act { try await store.moveBacklog(item, to: 0, forPal: palID) } } label: {
                Label(String(localized: "放到最前", table: "Files"), systemImage: "arrow.up.to.line")
            }
            Button { finish(item) } label: {
                Label(String(localized: "做完了", table: "Files"), systemImage: "checkmark")
            }
        }
        Button(role: .destructive) { remove(item) } label: {
            Label(String(localized: "删除", table: "Files"), systemImage: "trash")
        }
    }

    /// 让X开始做 (what ▶ says to VoiceOver and the pointer).
    private func startTitle(_ item: BacklogItem) -> String {
        String(localized: "让\(agent(of: item, else: palID).name)开始做", table: "Files")
    }

    // MARK: adding

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.tertiary)
            TextField(String(localized: "加一件", table: "Files"), text: $draft)
                .textFieldStyle(.plain)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(add)
                .accessibilityIdentifier("backlog-add")
        }
        .padding(.horizontal, 14)
        .frame(height: BacklogMetrics.mac ? 40 : 50)
        .contentShape(.capsule)
        .onTapGesture { adding = true }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, BacklogMetrics.mac ? 12 : 8 + bottomClearance)
        .onChange(of: adding) { _, on in if on { close() } }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // Typing on: the next one.
        adding = true
        Task {
            do {
                added = try await store.addBacklog(text, forPal: palID)?.id
            } catch {
                toast = BacklogToast(text: Friendly.message(error))
                if draft.isEmpty { draft = text }
            }
        }
    }

    #if DEBUG || PERF_HARNESS
    /// `-demoActions backlog-do:<what>[:<id>]`: the owner's hand on this list.
    private func demo(_ step: String) {
        let parts = step.split(separator: ":").map(String.init)
        let item = parts.count > 1 ? backlog?.items.first { $0.id == parts[1] } : nil
        switch parts.first {
        case "done": showDone.toggle()
        case "open": if let item { openRow(item) }
        case "close": close()
        case "check": if let item { finish(item) }
        case "start": if let item { start(item) }
        case "remove": if let item { remove(item) }
        case "undo": toast?.undo?(); toast = nil
        case "type": open?.text = parts.dropFirst().joined(separator: ":")
        case "note": open?.note = parts.dropFirst().joined(separator: ":")
        case "new": if let item { pick(.new, for: item) }
        case "add": draft = parts.dropFirst().joined(separator: ":"); add()
        default: break
        }
    }
    #endif
}

#if DEBUG || PERF_HARNESS
extension Notification.Name {
    /// `-demoActions backlog-do:…`
    static let demoBacklog = Notification.Name("demoBacklog")
}
#endif

/// A queued row's drag and drop: it can be picked up, and another dropped on
/// it takes its place (moving down: after it; up: before it). A line over
/// the row while one hovers. The system's drag (the pointer on a Mac, a long
/// press then a move on a phone); List.onMove works in edit mode only there.
private struct QueueDrag: ViewModifier {
    let item: BacklogItem
    let queue: [BacklogItem]
    @Binding var target: String?
    let move: (_ id: String, _ to: Int) -> Void

    /// What a dragged row carries: its id, marked as ours (text dropped from elsewhere isn't taken).
    private static let prefix = "palo-backlog:"

    /// Asked for as the drag begins.
    private func payload() -> String {
        debugLog("[backlog] drag began")
        return Self.prefix + item.id
    }

    func body(content: Content) -> some View {
        content
            .draggable(payload())
            .dropDestination(for: String.self) { ids, _ in
                target = nil
                guard let raw = ids.first, raw.hasPrefix(Self.prefix) else { return false }
                let id = String(raw.dropFirst(Self.prefix.count))
                guard id != item.id, queue.contains(where: { $0.id == id }),
                      let at = queue.firstIndex(where: { $0.id == item.id }) else { return false }
                debugLog("[backlog] dropped at \(at)")
                move(id, at)
                return true
            } isTargeted: { on in
                if on { target = item.id } else if target == item.id { target = nil }
            }
            .overlay(alignment: .top) {
                if target == item.id {
                    Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 12).offset(y: -1)
                }
            }
    }
}

// MARK: - the line at the bottom

/// What just happened, and 撤回 when it can be taken back.
struct BacklogToast: Identifiable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)? = nil
}

private struct BacklogToastView: View {
    let toast: BacklogToast
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).lineLimit(1)
            if let undo = toast.undo {
                Button {
                    close()
                    undo()
                } label: {
                    Text(String(localized: "撤回", table: "Files")).fontWeight(.semibold).foregroundStyle(Color(rgb: 0xFF9AD8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("backlog-undo")
            }
        }
        .font(BacklogMetrics.mac ? .system(size: 12) : .subheadline)
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, BacklogMetrics.mac ? 6 : 9)
        .background(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 0.96) : UIColor(white: 0.11, alpha: 0.92) }), in: .capsule)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backlog-toast")
    }
}
