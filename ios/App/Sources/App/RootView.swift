import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            #if DEBUG
            if model.launch.screen == "glassDrops" {
                GlassDropsDemo(theme: model.currentTheme)
            } else if model.launch.screen == "scrollLab" {
                ScrollLab()
            } else {
                screens
            }
            #else
            screens
            #endif
        }
        // Each assistant has its own color; switching re-tints the whole app.
        .appTheme(model.currentTheme)
        .animation(.snappy, value: model.activeHostID)
        #if DEBUG
        .modifier(DemoCapture(demo: model.mode == .demo))
        .modifier(LayoutStressTest(model: model))
        #endif
    }

    @ViewBuilder private var screens: some View {
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
    }
}

#if DEBUG
/// Screenshot automation for the demo, where tools may not capture or resize
/// windows: `-demoWindow 1440x900` sizes the Mac window, `-demoOrientation
/// landscape` turns an iPad, `-demoAppearance dark` forces an appearance, and
/// `-demoSnapshot <name>` writes the window to
/// <app tmp>/<name>.png a few seconds after launch (the app is sandboxed).
private struct DemoCapture: ViewModifier {
    let demo: Bool

    func body(content: Content) -> some View {
        content.task {
            guard demo else { return }
            let d = UserDefaults.standard
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            // `-demoAppearance dark|light`: the system setting isn't reachable from a launch argument.
            if let look = d.string(forKey: "demoAppearance") {
                for w in scene?.windows ?? [] { w.overrideUserInterfaceStyle = look == "dark" ? .dark : .light }
            }
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
            let delay = d.double(forKey: "demoSnapshotDelay")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
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

#if DEBUG
/// DEBUG automation for checks without a usable screen:
/// `-resizeTest YES` walks the Mac window through a series of widths and
/// toggles the sidebar and inspector, logging each step (the stall watchdog
/// logs any hang in between); `-demoActions "goal,back,..."` performs
/// navigation steps two seconds apart (back = ⌘[; assistant / library: the
/// places; settings; sidebar: toggle 「它」), logging what's on screen after each.
private struct LayoutStressTest: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.task {
            let d = UserDefaults.standard
            if let actions = d.string(forKey: "demoActions") {
                try? await Task.sleep(for: .seconds(d.double(forKey: "demoActionsDelay") > 0 ? d.double(forKey: "demoActionsDelay") : 4))
                for a in actions.split(separator: ",").map(String.init) {
                    guard model.store != nil else { break }
                    switch a {
                    case "back": model.goBack()
                    case "assistant": model.place = .assistant
                    case "library": model.place = .library
                    case "settings": model.openSettings()
                    case "sidebar": model.sidebarShown.toggle()
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    debugLog("[nav] after \(a): layout \(model.layout.rawValue) place \(model.place) sidebar \(model.sidebarShown) inspector \(model.inspectorShown) settings \(model.showSettings)")
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
            guard d.bool(forKey: "resizeTest") else { return }
            try? await Task.sleep(for: .seconds(6))
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 500)
            @MainActor func size(_ w: CGFloat) async {
                debugLog("[resize] → \(Int(w))")
                scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 60, y: 40, width: w, height: 860)))
                try? await Task.sleep(for: .milliseconds(120))
            }
            // A live drag: many small steps, both ways, around the widths that matter.
            for w in stride(from: 1450.0, through: 640.0, by: -18.0) { await size(w) }
            for w in stride(from: 640.0, through: 1450.0, by: 18.0) { await size(w) }
            try? await Task.sleep(for: .seconds(1))
            for w: CGFloat in [1450, 1000, 820] {
                await size(w)
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<2 {
                    debugLog("[resize] sidebar toggle at \(Int(w))")
                    model.sidebarShown.toggle()
                    try? await Task.sleep(for: .seconds(1.2))
                    debugLog("[resize] inspector toggle at \(Int(w))")
                    model.inspectorShown.toggle()
                    try? await Task.sleep(for: .seconds(1.2))
                }
            }
            debugLog("[resize] done")
        }
    }
}
#endif

/// The three places — 「它」 (the assistant), the conversation, 「成果」 (the
/// library) — with one set of content views and one navigation state. Only
/// the container changes with the window's actual width: narrow windows
/// (phones, iPad slide-over, a narrow Mac window) slide between the places;
/// wider ones keep the conversation on screen and open 「它」 and 「成果」 as
/// panels on either side.
struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var voice = VoiceInputController()
    /// The unsent message, here so a layout switch (which rebuilds the
    /// conversation) doesn't lose it.
    @State private var draft = ""

    /// The container in use; it can trail the width for a moment (below).
    @State private var container: AppModel.Layout?
    /// What the width asks for right now.
    @State private var wanted: AppModel.Layout?

    var body: some View {
        GeometryReader { geo in
            let layout = Self.layout(width: geo.size.width, sizeClass: sizeClass)
            Group {
                if (container ?? layout) == .phone {
                    SpatialPlaces()
                } else {
                    PanelPlaces()
                }
            }
            .onAppear { wanted = layout; container = layout; model.setLayout(layout) }
            .onChange(of: layout) { _, l in wanted = l; switchContainer(to: l) }
        }
        .environment(voice)
        .environment(\.chatDraft, $draft)
        // Voice input hears better with the conversation's names and terms.
        .task(id: ObjectIdentifier(store)) {
            voice.dictation.contextProvider = { [store] in
                VoiceContext.build(
                    messages: store.messages,
                    assistantName: store.assistantName,
                    goalTitles: store.watches.map(\.title),
                    artifactTitles: store.artifacts.sorted { $0.updatedAt > $1.updatedAt }.map(\.title),
                    quote: store.replyDraft?.excerpt)
            }
        }
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

    private func switchContainer(to l: AppModel.Layout) {
        container = l
        model.setLayout(l)
    }

    /// Asked once per computer: it's paired, its settings arrived and it has no name yet.
    private var needsNaming: Bool {
        guard !model.namingDone, !model.showPairingSheet else { return false }
        if model.launch.screen == "naming" { return store.settings != nil }
        guard model.mode == .paired, let s = store.settings else { return false }
        return s.assistantName.isEmpty
    }

    /// Narrow (< 700 pt, or a compact size class): the phone layout.
    /// Medium: 「它」 lays over the conversation and one panel is open at a
    /// time. Wide (≥ 1100 pt): the panels sit beside it.
    static func layout(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> AppModel.Layout {
        guard sizeClass == .regular, width >= 700 else { return .phone }
        return width >= 1100 ? .wide : .medium
    }
}

/// Narrow windows: one horizontal space, one place on screen at a time. The
/// top buttons push the conversation aside; the button facing the
/// conversation, or a swipe from that edge, slides it back. The
/// conversation is always there; 「它」 and 成果 are made when first slid to,
/// and stay while the app is open, so their scroll positions survive a trip
/// to the conversation.
private struct SpatialPlaces: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Live edge-swipe translation toward the conversation (points).
    @State private var drag: CGFloat = 0
    /// The places beside the conversation that are made (see `pane`).
    @State private var kept: Set<AppModel.Place> = []

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
        .onChange(of: model.place, initial: true) { _, place in kept.insert(place) }
        // Leaving the app lets go of the places off screen. The system lays
        // the whole window out again for each of its app-switcher snapshots
        // (in the dark appearance and the light), and the places' lists
        // cost about as much as the conversation itself.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { kept = [model.place] }
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
    /// A place beside the conversation is made when it's slid to (it's on
    /// screen from the first frame of the slide) and kept until the app
    /// leaves the screen; until then its slot is empty.
    private func pane<Content: View>(_ place: AppModel.Place, @ViewBuilder content: () -> Content) -> some View {
        let current = model.place == place
        return Group {
            if place == .chat || current || kept.contains(place) { content() } else { Color.clear }
        }
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

/// Wider windows: the conversation always owns the window — nothing replaces
/// it. 「它」 and 「成果」 are panels on either side, closed by default and
/// opened from the toolbar (the bar's buttons on iPad, ⌘1 / ⌘2): glanced at,
/// then put away, like the phone's places. Details open inside the panel
/// with their own back; the panel's ✕, its toolbar button again, Esc or ⌘[
/// closes it. Wide windows make room for a panel beside the conversation;
/// medium ones lay 「它」 over it, and only one panel is open at a time.
private struct PanelPlaces: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    private static let assistantWidth: CGFloat = 340

    var body: some View {
        @Bindable var model = model
        let beside = model.layout == .wide
        HStack(spacing: 0) {
            if beside && model.sidebarShown {
                AssistantPlace()
                    .frame(width: Self.assistantWidth)
                    .transition(.move(edge: .leading))
                Divider().ignoresSafeArea()
            }
            NavigationStack { ChatView().modifier(InContentNavigationBar()) }
                // Opened only on demand: the system may close it (too narrow)
                // but its restored state from the last run doesn't reopen it.
                .inspector(isPresented: Binding(
                    get: { model.inspectorShown },
                    set: { if !$0 { model.inspectorShown = false } }
                )) {
                    // Presented outside this hierarchy on some platforms: pass what it reads.
                    LibraryPlace()
                        .environment(model)
                        .environment(store)
                        .environment(\.placesAsColumns, true)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
        .overlay(alignment: .leading) {
            if !beside && model.sidebarShown {
                ZStack(alignment: .leading) {
                    // A click beside the panel puts it away.
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { model.sidebarShown = false }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    AssistantPlace()
                        .frame(width: Self.assistantWidth)
                        .clipShape(.rect)
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 4)
                        .transition(.move(edge: .leading))
                }
            }
        }
        .background {
            // Esc puts the open panel away: 成果 first, like ⌘[.
            if model.sidebarShown || model.inspectorShown {
                Button("关闭面板") { model.closeTopPanel() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.92), value: model.sidebarShown)
        .onChange(of: model.sidebarShown) { _, shown in
            // The panel lays over the composer on medium windows: let go of it.
            if shown && !beside { model.composerUnfocusRequests += 1 }
        }
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
                if asColumn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.sidebarShown = false } label: { Image(systemName: "xmark") }
                            .tint(.primary)
                            .accessibilityLabel("关闭「它」")
                    }
                }
                // Narrow: back to the conversation (on the Mac too — the
                // toolbar toggle alone isn't an obvious way out).
                if !asColumn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.place = .chat } label: {
                            HStack(spacing: 3) { Text("对话"); Image(systemName: "chevron.right") }
                        }
                        .tint(.primary)
                        .accessibilityLabel("回到对话")
                    }
                } else if case .task = model.assistantRoot {
                    // The sidebar showing one task opened from the conversation: back to the tabs.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.showAllTasks() } label: {
                            HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("履历") }
                        }
                        .tint(.primary)
                        .accessibilityLabel("回到履历")
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
            .toolbar {
                if asColumn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.inspectorShown = false } label: { Image(systemName: "xmark") }
                            .tint(.primary)
                            .accessibilityLabel("关闭成果")
                    }
                }
                if !asColumn {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.place = .chat } label: {
                            HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("对话") }
                        }
                        .tint(.primary)
                        .accessibilityLabel("回到对话")
                    }
                } else if case .artifact = model.libraryRoot {
                    // The inspector showing one item opened from the conversation: back to the list.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.showInLibrary() } label: {
                            HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("成果") }
                        }
                        .tint(.primary)
                        .accessibilityLabel("回到成果")
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
