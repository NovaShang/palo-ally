import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let store = model.store {
                MainScreen()
                    .environment(store)
                    .id(ObjectIdentifier(store))
            } else {
                PairingView(isSheet: false)
            }
        }
        // Each assistant has its own color; switching re-tints the whole app.
        .appTheme(model.currentTheme)
        .animation(.snappy, value: model.activeHostID)
    }
}

/// One horizontal space with three places: 「它」 (the assistant) on the left,
/// the conversation in the middle, 「成果」 (the library) on the right. The top
/// buttons push the conversation aside; the button facing the conversation,
/// or a swipe from that edge, slides it back. Each place keeps its own
/// navigation stack, and all three stay alive so scroll positions survive.
struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = VoiceInputController()
    /// Live edge-swipe translation toward the conversation (points).
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                pane(.assistant) { AssistantPlace() }
                    .frame(width: w)
                pane(.chat) { NavigationStack { ChatView() } }
                    .frame(width: w)
                pane(.library) { LibraryPlace() }
                    .frame(width: w)
            }
            .offset(x: offset(for: model.place, width: w) + drag)
            .animation(.spring(response: 0.38, dampingFraction: 0.9), value: model.place)
            .overlay(alignment: .leading) {
                // 成果: swipe right from the left edge to return — only at the
                // stack's root, so the system's back swipe works deeper in.
                if model.place == .library && model.libraryPath.isEmpty {
                    edgeStrip(towardChat: +1, width: w)
                }
            }
            .overlay(alignment: .trailing) {
                // 它: swipe left from the right edge to return (the left edge
                // stays the system's back swipe inside the place).
                if model.place == .assistant { edgeStrip(towardChat: -1, width: w) }
            }
        }
        // No clipping: the window already hides the off-screen places, and
        // clipping would cut each place's content off at the safe area.
        .environment(voice)
        .animation(.easeOut(duration: 0.15), value: voice.isActive)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && voice.previewText == nil { voice.abort() }
        }
        .onChange(of: model.place) { _, place in
            guard place != .chat else { return }
            // Leaving the conversation: put the keyboard and any recording away.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            if voice.previewText == nil { voice.abort() }
        }
        .onAppear {
            if model.launch.screen == "voice" { voice.showPreview("你好，你好，你好，我正在说话") }
            model.markSeen()
        }
        // Everything on screen counts as seen (drives the other assistants' unread dots).
        .onChange(of: store.lastSeq) { model.markSeen() }
        .sheet(isPresented: Binding(get: { model.showPairingSheet }, set: { if !$0 { model.showPairingSheet = false } })) {
            PairingView(isSheet: true).environment(model).environment(store)
        }
        // Right after pairing, once: 「给它起个名字」.
        .sheet(isPresented: Binding(get: { needsNaming }, set: { if !$0 { model.namingDone = true } })) {
            IdentityEditor(purpose: .firstTime).environment(model).environment(store)
        }
    }

    /// Asked once per computer: it's paired, its settings arrived and it has no name yet.
    private var needsNaming: Bool {
        guard !model.namingDone, !model.showPairingSheet else { return false }
        if model.launch.screen == "naming" { return store.settings != nil }
        guard model.mode == .paired, let s = store.settings else { return false }
        return s.assistantName.isEmpty
    }

    /// The x offset that puts `place` on screen.
    private func offset(for place: AppModel.Place, width w: CGFloat) -> CGFloat {
        switch place {
        case .assistant: 0
        case .chat: -w
        case .library: -2 * w
        }
    }

    /// Only the place on screen is interactive and visible to VoiceOver.
    private func pane<Content: View>(_ place: AppModel.Place, @ViewBuilder content: () -> Content) -> some View {
        let current = model.place == place
        return content()
            .allowsHitTesting(current && drag == 0)
            .accessibilityHidden(!current)
    }

    /// A thin strip on one screen edge that drags the whole space back toward
    /// the conversation with the finger, like the system back swipe.
    /// `towardChat` is +1 when the conversation is to the right, -1 when left.
    private func edgeStrip(towardChat sign: CGFloat, width w: CGFloat) -> some View {
        Color.clear
            .frame(width: 22)
            .contentShape(.rect)
            .padding(.top, 110) // keep clear of the top bar's buttons
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) || drag != 0 else { return }
                        drag = min(max(v.translation.width * sign, 0), w) * sign
                    }
                    .onEnded { v in
                        let moved = v.translation.width * sign
                        let flung = v.predictedEndTranslation.width * sign
                        let back = moved > w * 0.35 || flung > w * 0.6
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                            if back { model.place = .chat }
                            drag = 0
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

/// 「它」: the assistant's tabs, or one task opened from the conversation.
private struct AssistantPlace: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                switch model.assistantRoot {
                case .tabs:
                    AssistantView()
                case .task(let id):
                    TaskDetailView(taskID: id)
                        .toolbar {
                            ToolbarItem(placement: .bottomBar) {
                                Button("全部任务") { model.showAllTasks() }.tint(.primary)
                            }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.place = .chat } label: {
                        HStack(spacing: 3) { Text("对话"); Image(systemName: "chevron.right") }
                    }
                    .tint(.primary)
                    .accessibilityLabel("回到对话")
                }
            }
        }
        .id(model.assistantRoot == .tabs ? "tabs" : "item")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// 「成果」: the library, or one artifact opened from the conversation.
private struct LibraryPlace: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.libraryPath) {
            Group {
                switch model.libraryRoot {
                case .list:
                    LibraryView()
                case .artifact(let id):
                    ArtifactDetailView(artifactID: id)
                        .toolbar {
                            ToolbarItem(placement: .bottomBar) {
                                Button("在产出物库中查看") { model.showInLibrary(id) }.tint(.primary)
                            }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.place = .chat } label: {
                        HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("对话") }
                    }
                    .tint(.primary)
                    .accessibilityLabel("回到对话")
                }
            }
        }
        .id(model.libraryRoot == .list ? "list" : "item")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

#Preview("Demo") {
    let model = AppModel.demo()
    RootView().environment(model)
}
