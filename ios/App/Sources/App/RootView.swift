import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.launch.screen == "avatars" {
                AvatarGallery()
            } else if let store = model.store {
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
        #if DEBUG
        .modifier(DemoCapture(demo: model.mode == .demo))
        #endif
    }
}

#if DEBUG
/// Screenshot automation for the demo, where tools may not capture or resize
/// windows: `-demoWindow 1440x900` sizes the Mac window, `-demoOrientation
/// landscape` turns an iPad, and `-demoSnapshot <name>` writes the window to
/// <app tmp>/<name>.png a few seconds after launch (the app is sandboxed).
private struct DemoCapture: ViewModifier {
    let demo: Bool

    func body(content: Content) -> some View {
        content.task {
            guard demo else { return }
            let d = UserDefaults.standard
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if let size = d.string(forKey: "demoWindow")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                scene?.sizeRestrictions?.minimumSize = CGSize(width: min(size[0], 400), height: min(size[1], 400))
                // The window must be up first, and an early request is sometimes dropped.
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let scene, abs(scene.effectiveGeometry.coordinateSpace.bounds.width - size[0]) > 1 else { break }
                    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 60, y: 40, width: size[0], height: size[1]))) {
                        print("[demo] window: \($0)")
                    }
                }
            }
            if d.string(forKey: "demoOrientation") == "landscape" {
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            guard let name = d.string(forKey: "demoSnapshot") else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let window = scene?.keyWindow ?? scene?.windows.first else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try? image.pngData()?.write(to: url)
            print("[demo] snapshot \(url.path)")
        }
    }
}
#endif

/// The three places — 「它」 (the assistant), the conversation, 「成果」 (the
/// library) — with one set of content views and one navigation state. Only
/// the container changes with the window's actual width: narrow windows
/// (phones, iPad slide-over, a narrow Mac window) slide between the places;
/// wider ones show 「它」 as the system sidebar and 「成果」 as the system
/// inspector beside the conversation.
struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var voice = VoiceInputController()
    /// The unsent message, here so a layout switch (which rebuilds the
    /// conversation) doesn't lose it.
    @State private var draft = ""

    var body: some View {
        GeometryReader { geo in
            let layout = Self.layout(width: geo.size.width, sizeClass: sizeClass)
            Group {
                if layout == .phone {
                    SpatialPlaces()
                } else {
                    SplitPlaces()
                }
            }
            .onAppear { model.setLayout(layout) }
            .onChange(of: layout) { _, l in model.setLayout(l) }
        }
        .environment(voice)
        .environment(\.chatDraft, $draft)
        .modifier(MacWindowChrome(model: model))
        .animation(.easeOut(duration: 0.15), value: voice.isActive)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && voice.previewText == nil { voice.abort() }
        }
        .onChange(of: model.place) { _, place in
            // Leaving the conversation (only phones hide it): put the
            // keyboard and any recording away.
            guard place != .chat, model.layout == .phone else { return }
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

    /// Narrow (< 700 pt, or a compact size class): the phone layout.
    /// Medium: sidebar and inspector float over the conversation. Wide
    /// (≥ 1100 pt): they sit beside it.
    static func layout(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> AppModel.Layout {
        guard sizeClass == .regular, width >= 700 else { return .phone }
        return width >= 1100 ? .wide : .medium
    }
}

/// Narrow windows: one horizontal space, one place on screen at a time. The
/// top buttons push the conversation aside; the button facing the
/// conversation, or a swipe from that edge, slides it back. All three stay
/// alive so scroll positions survive.
private struct SpatialPlaces: View {
    @Environment(AppModel.self) private var model
    /// Live edge-swipe translation toward the conversation (points).
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                pane(.assistant) { AssistantPlace() }
                    .frame(width: w)
                pane(.chat) { NavigationStack { ChatView().modifier(InContentNavigationBar()) } }
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

/// Wider windows: 「它」 is the system sidebar (collapsible; open by default
/// when wide, closed when medium, then as the user leaves it), the
/// conversation is the detail column, and 「成果」 is the system inspector —
/// a trailing column when there's room, floating when there isn't. Same
/// content views as the phone layout; only their back buttons are hidden.
private struct SplitPlaces: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarShown ? .all : .detailOnly },
            set: { visibility in
                let shown = visibility != .detailOnly
                guard shown != model.sidebarShown else { return }
                model.sidebarShown = shown
                model.rememberSidebar()
            }
        )) {
            AssistantPlace()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                // The conversation's own 「它」 button is the toggle (on the
                // Mac, the window toolbar's), always in the same place.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack { ChatView().modifier(InContentNavigationBar()) }
                .inspector(isPresented: $model.inspectorShown) {
                    // Presented outside this hierarchy on some platforms: pass what it reads.
                    LibraryPlace()
                        .environment(model)
                        .environment(store)
                        .environment(\.placesAsColumns, true)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
        // The system decides whether the sidebar sits beside the
        // conversation or floats over it (iPad portrait); one style keeps the
        // conversation's identity when the window crosses a width.
        .navigationSplitViewStyle(.automatic)
        .environment(\.placesAsColumns, true)
    }
}

/// The way from one item opened from the conversation to its collection.
/// It lives in the bottom toolbar, except in a column on the Mac, where the
/// window shares one toolbar and it would land under the conversation.
private struct ItemFooter: ViewModifier {
    let title: String
    let action: () -> Void
    @Environment(\.placesAsColumns) private var asColumn

    func body(content: Content) -> some View {
        if asColumn && UIDevice.current.userInterfaceIdiom == .mac {
            content.safeAreaInset(edge: .bottom) {
                Button(title, action: action)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.primary)
                    .padding(.bottom, 12)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(title, action: action).tint(.primary)
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// The places are columns beside the conversation (large screens), so
    /// they don't show their 「对话」 back buttons.
    @Entry var placesAsColumns = false
    /// The conversation's unsent text (owned by MainScreen).
    @Entry var chatDraft: Binding<String> = .constant("")
}

/// 「它」: the assistant's tabs, or one task opened from the conversation.
private struct AssistantPlace: View {
    @Environment(AppModel.self) private var model
    @Environment(\.placesAsColumns) private var asColumn

    var body: some View {
        NavigationStack {
            Group {
                switch model.assistantRoot {
                case .tabs:
                    AssistantView()
                case .task(let id):
                    TaskDetailView(taskID: id)
                        .modifier(ItemFooter(title: "全部任务") { model.showAllTasks() })
                }
            }
            .modifier(InContentNavigationBar())
            .toolbar {
                if !asColumn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.place = .chat } label: {
                            HStack(spacing: 3) { Text("对话"); Image(systemName: "chevron.right") }
                        }
                        .tint(.primary)
                        .accessibilityLabel("回到对话")
                    }
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
    @Environment(\.placesAsColumns) private var asColumn

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.libraryPath) {
            Group {
                switch model.libraryRoot {
                case .list:
                    LibraryView()
                case .artifact(let id):
                    ArtifactDetailView(artifactID: id)
                        .modifier(ItemFooter(title: "在产出物库中查看") { model.showInLibrary(id) })
                }
            }
            .modifier(InContentNavigationBar())
            .background {
                // Beside the conversation, the 成果 button closes it again;
                // Esc does too.
                if asColumn {
                    Button("关闭成果") { model.inspectorShown = false }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .toolbar {
                if !asColumn {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.place = .chat } label: {
                            HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("对话") }
                        }
                        .tint(.primary)
                        .accessibilityLabel("回到对话")
                    }
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
