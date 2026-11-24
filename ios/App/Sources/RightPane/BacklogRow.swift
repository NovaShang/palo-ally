import PaloAllyKit
import SwiftUI

// 待办's rows (docs/workbench-design/backlog-v2.html): one being done, one in
// line, the same one opened in place to change its words, one done. Every
// row of a kind looks the same.

/// The draft's measures: the Mac's pane, and a finger's everywhere else.
enum BacklogMetrics {
    static var mac: Bool { Platform.isMac }
    static var circle: CGFloat { mac ? 18 : 24 }
    static var gap: CGFloat { mac ? 10 : 13 }
    static var leading: CGFloat { mac ? 12 : 16 }
    static var trailing: CGFloat { mac ? 10 : 14 }
    static var vertical: CGFloat { mac ? 9 : 13 }
    static var play: CGFloat { mac ? 26 : 32 }
    static var chip: CGFloat { mac ? 28 : 36 }
    static var headerTop: CGFloat { mac ? 12 : 16 }
    static var headerBottom: CGFloat { mac ? 6 : 7 }
    /// A separator starts where the words do.
    static var separatorInset: CGFloat { leading + circle + gap }
    /// A round or capsule control on a card.
    static var fill: Color { Color(.secondarySystemFill) }
    /// The second line.
    static var second: Font { mac ? .subheadline : .system(.subheadline).scaled(by: 14.0 / 15.0) }
}

/// Who does an item, or will.
struct BacklogAgent: Identifiable, Hashable {
    /// nil: the assistant.
    let id: String?
    let name: String
    let state: StatusDotKind
    let running: Int

    /// Picked in the chip's menu.
    enum Choice { case agent(String?), new }

    init(id: String?, name: String, state: StatusDotKind, running: Int) {
        self.id = id; self.name = name; self.state = state; self.running = running
    }

    init(_ pal: Pal) { self.init(id: pal.id, name: pal.displayName, state: pal.dot, running: pal.tasksRunning) }

    /// Its live glyph, as in the sidebar, `size` across (the glyph itself is 0.8 of its frame).
    @MainActor func glyph(_ size: CGFloat) -> some View {
        SessionIndicator(flat: state, size: size / 0.8, running: running).frame(width: size, height: size)
    }

    /// The glyph for a menu, which takes images only.
    var menuImage: Image {
        let (name, color): (String, Color) = switch state {
        case .working: ("play.circle.fill", StatusDot.color(.working))
        case .waiting: ("questionmark.circle.fill", StatusDot.color(.waiting))
        case .done: ("checkmark.circle.fill", StatusDot.color(.done))
        case .idle: ("smallcircle.filled.circle", StatusDot.color(.idle))
        }
        let ui = UIImage(systemName: name)?.withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
        return ui.map { Image(uiImage: $0).renderingMode(.original) } ?? Image(systemName: name)
    }
}

/// What's typed in the open row. Saved after a pause and whenever the row,
/// the pane or the app goes away; Esc puts back what was there.
@MainActor @Observable
final class BacklogDraft {
    let id: String
    var text: String { didSet { if text != oldValue { typed() } } }
    var note: String { didSet { if note != oldValue { typed() } } }
    @ObservationIgnored private let owner: String?
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private var original: (text: String, note: String)
    @ObservationIgnored private var saved: (text: String, note: String)
    @ObservationIgnored private var pause: Task<Void, Never>?

    init(_ item: BacklogItem, owner: String?, store: AppStore) {
        id = item.id
        text = item.text
        note = item.note ?? ""
        self.owner = owner
        self.store = store
        original = (item.text, item.note ?? "")
        saved = original
    }

    private func typed() {
        pause?.cancel()
        pause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { self?.save() }
        }
    }

    /// `closing`: words all taken away stay as they were.
    func save(closing: Bool = false) {
        pause?.cancel()
        var t = Self.line(text)
        if t.isEmpty { t = closing ? original.text : saved.text }
        send((t, note.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func discard() {
        pause?.cancel()
        send(original)
    }

    private func send(_ new: (text: String, note: String)) {
        guard new != saved else { return }
        store.editBacklog(id: id, text: new.text == saved.text ? nil : new.text, note: new.note == saved.note ? nil : new.note, forPal: owner)
        saved = new
    }

    /// The item changed elsewhere (an agent, another device): what wasn't typed over here follows.
    func follow(_ item: BacklogItem) {
        if item.text != saved.text, Self.line(text) == saved.text {
            saved.text = item.text
            original.text = item.text
            text = item.text
        }
        let n = item.note ?? ""
        if n != saved.note, note.trimmingCharacters(in: .whitespacesAndNewlines) == saved.note {
            saved.note = n
            original.note = n
            note = n
        }
    }

    private static func line(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - headers

struct BacklogHeader: View {
    let title: String
    let first: Bool
    init(_ title: String, first: Bool) { self.title = title; self.first = first }

    var body: some View {
        Text(title).modifier(BacklogHeaderStyle(top: BacklogMetrics.headerTop + (first ? 6 : 0)))
    }
}

struct BacklogHeaderStyle: ViewModifier {
    let top: CGFloat
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            // Not `.secondary`: a header is already that, and it would fade twice.
            .foregroundStyle(Color(.secondaryLabel))
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BacklogMetrics.leading)
            .padding(.top, top)
            .padding(.bottom, BacklogMetrics.headerBottom)
            .listRowInsets(EdgeInsets())
    }
}

// MARK: - rows

/// The circle at the left: empty (a tap: done), or ticked.
private struct BacklogCheck: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if on {
                    Circle().fill(StatusDot.color(.done))
                    Image(systemName: "checkmark").font(.system(size: BacklogMetrics.circle * 0.5, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                }
            }
            .frame(width: BacklogMetrics.circle, height: BacklogMetrics.circle)
            // A finger's worth around it, the layout as drawn.
            .padding(BacklogMetrics.mac ? 4 : 10)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .padding(BacklogMetrics.mac ? -4 : -10)
        .padding(.vertical, BacklogMetrics.mac ? -0.5 : -1)
        .accessibilityLabel(on ? String(localized: "放回排队", table: "Files") : String(localized: "做完了", table: "Files"))
        .accessibilityIdentifier("backlog-check")
    }
}

/// The card's insets, and (the Mac) a darker ground under the pointer.
private struct BacklogRowFrame<Content: View>: View {
    @Binding var hovering: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: BacklogMetrics.gap) { content }
            .padding(.leading, BacklogMetrics.leading)
            .padding(.trailing, BacklogMetrics.trailing)
            .padding(.vertical, BacklogMetrics.vertical)
            // A cell a hair taller than its row (one with a field in it) keeps the row at its top.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The card itself is the system's, as 成果's.
            .background { if hovering { Color.primary.opacity(0.045) } }
            .contentShape(.rect)
            .onHover { if BacklogMetrics.mac { hovering = $0 } }
    }
}

private struct BacklogWords: View {
    let text: String
    let second: String
    var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(done ? .secondary : .primary)
                .strikethrough(done)
                .lineLimit(2)
            if !second.isEmpty {
                Text(second).font(BacklogMetrics.second).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

/// Being done: whose, live; a tap opens that agent.
struct BacklogDoingRow: View {
    let item: BacklogItem
    let agent: BacklogAgent
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            BacklogRowFrame(hovering: $hovering) {
                agent.glyph(BacklogMetrics.circle)
                BacklogWords(text: item.text, second: agent.name)
            }
        }
        .buttonStyle(.plain)
    }
}

/// In line: ○ done, the words open it, ▶ starts it.
struct BacklogQueuedRow: View {
    let item: BacklogItem
    /// Who it's meant for, if anyone.
    let agent: BacklogAgent?
    let startTitle: String
    let check: () -> Void
    let open: () -> Void
    let start: () -> Void
    @State private var hovering = false

    private var second: String {
        [agent?.name ?? "", (item.note ?? "").replacingOccurrences(of: "\n", with: " ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        BacklogRowFrame(hovering: $hovering) {
            BacklogCheck(on: false, action: check)
            Button(action: open) {
                BacklogWords(text: item.text, second: second).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backlog-words")
            let shown = !BacklogMetrics.mac || hovering
            Button(action: start) {
                Image(systemName: "play.fill")
                    .font(.system(size: BacklogMetrics.mac ? 9 : 11))
                    .offset(x: 0.5)
                    .frame(width: BacklogMetrics.play, height: BacklogMetrics.play)
                    .background(BacklogMetrics.fill, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -4)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .help(startTitle)
            .accessibilityLabel(startTitle)
            .accessibilityIdentifier("backlog-start")
        }
        #if DEBUG || PERF_HARNESS
        // `-demoBacklogHover <id>`: as if the pointer were on that row (screenshots).
        .onAppear { if UserDefaults.standard.string(forKey: "demoBacklogHover") == item.id { hovering = true } }
        #endif
    }
}

/// Open in place: its words and its note to change, its agent, 🗑 and 开始.
struct BacklogOpenRow: View {
    @Bindable var draft: BacklogDraft
    let item: BacklogItem
    /// false: the host is from before editing; the words are only read.
    let editable: Bool
    let agent: BacklogAgent
    let agents: [BacklogAgent]
    let pick: (BacklogAgent.Choice) -> Void
    let check: () -> Void
    let remove: () -> Void
    let start: () -> Void
    let close: () -> Void
    let discard: () -> Void

    private enum Field { case text, note }
    @FocusState private var focus: Field?
    @State private var hovering = false

    var body: some View {
        BacklogRowFrame(hovering: $hovering) {
            BacklogCheck(on: false, action: check)
            VStack(alignment: .leading, spacing: 0) {
                if editable { fields } else { words }
                bar.padding(.top, 11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard editable else { return }
            Task { @MainActor in focus = .text }
        }
        .onChange(of: item) { _, now in draft.follow(now) }
        .onChange(of: focus) { was, now in if was != nil, now == nil { draft.save() } }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var fields: some View {
        TextField("", text: $draft.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body.weight(.medium))
            // A line of Chinese needs more than the system font's own: the cell is measured with it there.
            .frame(minHeight: BacklogMetrics.mac ? 17 : 22)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focus, equals: .text)
            .submitLabel(.done)
            .onKeyPress(.return, phases: .down) { _ in
                guard !HardwareKeyboard.isComposing else { return .ignored }
                close()
                return .handled
            }
            .onKeyPress(.escape) { escape() }
            // The on-screen keyboard's Return is a new line here.
            .onChange(of: draft.text) { _, now in
                guard now.contains(where: \.isNewline) else { return }
                draft.text = now.split(whereSeparator: \.isNewline).joined(separator: " ")
                close()
            }
            .accessibilityIdentifier("backlog-edit-text")
        TextField("", text: $draft.note, prompt: Text(String(localized: "备注", table: "Files")).foregroundStyle(Color(.tertiaryLabel)), axis: .vertical)
            .textFieldStyle(.plain)
            .font(BacklogMetrics.mac ? .system(size: 12) : .subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: BacklogMetrics.mac ? 17 : 21)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focus, equals: .note)
            .onKeyPress(.escape) { escape() }
            .padding(.top, 5)
            .accessibilityIdentifier("backlog-edit-note")
    }

    private func escape() -> KeyPress.Result {
        guard !HardwareKeyboard.isComposing else { return .ignored }
        discard()
        return .handled
    }

    @ViewBuilder private var words: some View {
        Text(item.text).font(.body.weight(.medium))
        if let note = item.note, !note.isEmpty {
            Text(note).font(BacklogMetrics.mac ? .system(size: 12) : .subheadline).foregroundStyle(.secondary).padding(.top, 5)
        }
    }

    private var bar: some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(agents) { a in
                    Button { pick(.agent(a.id)) } label: { Label { Text(verbatim: a.name) } icon: { a.menuImage } }
                }
                Button { pick(.new) } label: { Label(String(localized: "新建 agent", table: "Files"), systemImage: "plus") }
            } label: {
                HStack(spacing: 6) {
                    agent.glyph(BacklogMetrics.mac ? 15 : 18)
                    Text(verbatim: agent.name).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: BacklogMetrics.mac ? 8 : 10, weight: .bold))
                }
                .font(chipFont.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, BacklogMetrics.mac ? 11 : 14)
                .frame(height: BacklogMetrics.chip)
                .background(BacklogMetrics.fill, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backlog-agent")
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(chipFont)
                    .foregroundStyle(.red)
                    .frame(width: BacklogMetrics.chip, height: BacklogMetrics.chip)
                    .background(BacklogMetrics.fill, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "删除", table: "Files"))
            .accessibilityIdentifier("backlog-remove")
            Button(action: start) {
                Text(String(localized: "开始", table: "Files"))
                    .font(chipFont.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .frame(height: BacklogMetrics.chip)
                    .background(Color.accentColor, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backlog-open-start")
        }
    }

    private var chipFont: Font { BacklogMetrics.mac ? .system(size: 12) : .subheadline }
}

/// Done: ticked and struck through; a tap on the tick puts it back in line.
struct BacklogDoneRow: View {
    let item: BacklogItem
    let uncheck: () -> Void
    @State private var hovering = false

    var body: some View {
        BacklogRowFrame(hovering: $hovering) {
            BacklogCheck(on: true, action: uncheck)
            BacklogWords(text: item.text, second: [item.palName ?? "", (item.note ?? "").replacingOccurrences(of: "\n", with: " ")]
                .filter { !$0.isEmpty }.joined(separator: " · "), done: true)
        }
    }
}
