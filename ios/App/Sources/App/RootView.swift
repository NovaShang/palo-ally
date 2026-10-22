import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            #if DEBUG
            if model.launch.screen == "glassDrops" {
                GlassDropsDemo(theme: model.currentTheme)
            } else if model.launch.screen == "scrollLab" {
                ScrollLab()
            } else if model.launch.screen == "splitLab" {
                SplitLab()
            } else {
                screens
            }
            #else
            screens
            #endif
        }
        // Each assistant has its own color; switching re-tints the whole app.
        .appTheme(model.currentTheme)
        // Every list, form and page: the system's soft scroll edge, never the hard one.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .animation(.snappy, value: model.activeHostID)
        #if DEBUG
        .modifier(DemoCapture(demo: model.mode == .demo))
        .modifier(LayoutStressTest(model: model))
        #endif
    }

    /// The Mac: the window is on screen, so its split view may be made.
    @State private var onScreen = !Platform.isMac

    @ViewBuilder private var screens: some View {
        Group {
            if model.launch.screen == "avatars" {
                AvatarGallery()
            } else if !onScreen {
                Color.clear
            } else if let store = model.store {
                MainScreen()
                    .environment(store)
                    .id(ObjectIdentifier(store))
            } else {
                PairingView(isSheet: false)
            }
        }
        .task {
            // A split view with an inspector made before its window is on
            // screen (every window but the first: a new one, one reopened
            // at launch) never moved its columns again: the conversation
            // kept the width it was made with whatever the sidebar, the
            // right pane or the window did (SplitLab; macOS 26 and 27).
            // Made a moment after the window is up, it follows them.
            guard !onScreen else { return }
            for _ in 0..<40 where model.windowWidth == 0 { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(150))
            onScreen = true
            debugLog("[layout] \(model.traceName): main screen made, window \(model.windowWidth) pt")
        }
    }
}

#if DEBUG
/// Screenshot automation for the demo, where tools may not capture or resize
/// windows: `-demoWindow 1440x900` sizes the Mac window, `-demoOrientation
/// landscape` turns an iPad, `-demoAppearance dark` forces an appearance, and
/// `-demoSnapshot <name>` writes the window to
/// <app tmp>/<name>.png a few seconds after launch (the app is sandboxed),
/// and on a Mac <name>-window.png with the titlebar's controls drawn over it.
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
            // `-hitProbe "x,y|x,y"`: which view takes a click at each point
            // in the window (a button that answers on part of itself only).
            for spec in (d.string(forKey: "hitProbe") ?? "").split(separator: "|") {
                let xy = spec.split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { continue }
                let p = CGPoint(x: xy[0], y: xy[1])
                var chain: [String] = []
                var v = window.hitTest(p, with: nil)
                while let view = v, chain.count < 4 {
                    let f = view.convert(view.bounds, to: window)
                    chain.append("\(type(of: view)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
                    v = view.superview
                }
                NSLog("[hit] %@", "\(Int(p.x)),\(Int(p.y)): \(chain.joined(separator: " < "))")
            }
            #if targetEnvironment(macCatalyst)
            if let spec = d.string(forKey: "hitProbe"),
               let r = AppKitBundle.object?.perform(NSSelectorFromString("hitChain:"), with: spec)?.takeUnretainedValue() as? String {
                NSLog("[hit-appkit]\n%@", r)
            }
            #endif
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try? image.pngData()?.write(to: url)
            print("[demo] snapshot \(url.path)")
            #if targetEnvironment(macCatalyst)
            // The window as AppKit draws it, with its titlebar and toolbar.
            let full = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-window.png")
            if let composite = AppKitBundle.addTitlebar(to: image) {
                try? composite.pngData()?.write(to: full)
                print("[demo] window snapshot \(full.path)")
            }
            #endif
        }
    }
}
#endif

#if DEBUG
/// DEBUG automation for checks without a usable screen:
/// `-resizeTest YES` walks the Mac window through a series of widths and
/// toggles the sidebar and inspector, logging each step (the stall watchdog
/// logs any hang in between); `-demoActions "assistant,back,..."` performs
/// navigation steps two seconds apart (back = ⌘[; assistant: management;
/// library: 成果; settings; sidebar: the list's column; list), logging what's
/// on screen after each.
private struct LayoutStressTest: ViewModifier {
    let model: WindowModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let d = UserDefaults.standard
            // The first window runs them; `wN.` steps act on the N-th window.
            if let actions = d.string(forKey: "demoActions") {
                try? await Task.sleep(for: .seconds(d.double(forKey: "demoActionsDelay") > 0 ? d.double(forKey: "demoActionsDelay") : 4))
                guard model.app.windows.first === model else { return }
                for step in actions.split(separator: ",").map(String.init) {
                    guard model.store != nil else { break }
                    var w = model
                    var a = step
                    if step.hasPrefix("w"), let dot = step.firstIndex(of: "."), let n = Int(step[step.index(after: step.startIndex)..<dot]) {
                        let all = model.app.windows
                        guard n >= 1, n <= all.count else { debugLog("[nav] no window \(n)"); continue }
                        w = all[n - 1]
                        a = String(step[step.index(after: dot)...])
                    } else if step.hasPrefix("front."), let front = model.app.frontWindow {
                        // As a menu command does: the window used last.
                        w = front
                        a = String(step.dropFirst(6))
                    }
                    switch a {
                    case "back": w.goBack()
                    case "assistant": w.toggleManagement()
                    case "library": w.toggleLibrary()
                    case "settings": w.openSettings()
                    case "sidebar": w.columnVisibility = w.columnVisibility == .detailOnly ? .all : .detailOnly
                    // `w2.pane`: that window's right pane, as its button (⌘2).
                    case "pane": if w.launch.screen == "splitLab" { w.paneCover.toggle() } else { w.togglePane() }
                    case "list": w.showList()
                    // `w2.close`: that window closed, as its close button does.
                    case "close":
                        if let scene = w.scene { UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) }
                    // `mini`: the collapsed sidebar's Palo orb clicked (the Mac: Palo's small window).
                    case "mini": NotificationCenter.default.post(name: .demoOpenPaloMini, object: w)
                    // `w2.key`: that window becomes the key window, as a click in it does.
                    case "key":
                        if let scene = w.scene {
                            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
                        }
                    // `window:pal:pal-site`: 在新窗口中打开; `open:workspace:ws-site`: the list's row.
                    case _ where a.hasPrefix("window:"):
                        if let c = WindowModel.Conversation(storageKey: String(a.dropFirst(7))) { openWindow(value: WindowTarget(c, host: w.activeHostID)) }
                    // `w2.host:demo-2`: that window switches to that computer (the sidebar's switcher).
                    case _ where a.hasPrefix("host:"):
                        w.switchTo(String(a.dropFirst(5)))
                    // `notify:demo-2`: a message notification from that computer tapped.
                    case _ where a.hasPrefix("notify:"):
                        model.app.handleNotification(userInfo: ["hostId": String(a.dropFirst(7))])
                    // `canvas:<step>`: the window's split workspace (PaneCanvasController.demo).
                    case _ where a.hasPrefix("canvas:"):
                        for c in PaneCanvasController.all.allObjects where c.view.window?.windowScene === w.scene {
                            c.demo(String(a.dropFirst(7)))
                        }
                    // `artifact:ar1`: that artifact's card tapped in the conversation (an artifact card's pane path).
                    case _ where a.hasPrefix("artifact:"):
                        w.openArtifact(String(a.dropFirst(9)))
                    // `w2.size:1440x1100`: that window resized, as a drag of its corner.
                    case _ where a.hasPrefix("size:"):
                        let wh = a.dropFirst(5).split(separator: "x").compactMap { Double($0) }
                        if wh.count == 2, let scene = w.scene {
                            let f = scene.effectiveGeometry.systemFrame
                            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: f.minX, y: f.minY, width: wh[0], height: wh[1])))
                        }
                    case _ where a.hasPrefix("open:"):
                        if let c = WindowModel.Conversation(storageKey: String(a.dropFirst(5))) { w.open(c) }
                    // `snap:<name>`: this window to <app tmp>/<name>.png.
                    case _ where a.hasPrefix("snap:"):
                        if let window = w.scene?.windows.first {
                            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                            }
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(a.dropFirst(5)).png")
                            try? image.pngData()?.write(to: url)
                            debugLog("[nav] snapshot \(url.path)")
                        }
                    #if targetEnvironment(macCatalyst)
                    // `quit`: as ⌘Q (the windows are saved, to come back on the next launch).
                    case "quit":
                        if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject {
                            app.perform(NSSelectorFromString("terminate:"), with: nil)
                        }
                    // `hide`: as ⌘H (the windows go to the background).
                    case "hide":
                        if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject {
                            app.perform(NSSelectorFromString("hide:"), with: nil)
                        }
                    // `activate`: the app comes to the front (key windows only change in front).
                    case "activate":
                        if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject {
                            app.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
                        }
                    #endif
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    for (i, w) in model.app.windows.enumerated() {
                        debugLog("[nav] after \(step): window \(i + 1)\(w === model.app.frontWindow ? " (front)" : "")\(w.isMini ? " (mini)" : "") frame \(w.scene.map { "\($0.frameOnScreen) state \($0.activationState.rawValue) key \($0.keyWindow != nil)" } ?? "-") sidebar \(w.columnVisibility == .detailOnly ? "away" : "shown") host \(w.activeHostID ?? "-") (\(w.store?.assistantName ?? "") store \(w.store?.traceID ?? 0)) last \(model.app.lastHostID ?? "-") layout \(w.layout.rawValue) selection \(String(describing: w.selection)) management \(w.showManagement) pane \(w.paneIsOpen) settings \(w.showSettings)")
                    }
                    #if targetEnvironment(macCatalyst)
                    for (i, w) in model.app.windows.enumerated() {
                        let items = w.scene?.titlebar?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
                        debugLog("[nav] after \(step): window \(i + 1) toolbar \(items)")
                    }
                    #endif
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
                    model.columnVisibility = model.columnVisibility == .detailOnly ? .all : .detailOnly
                    try? await Task.sleep(for: .seconds(1.2))
                    debugLog("[resize] pane toggle at \(Int(w))")
                    model.togglePane()
                    try? await Task.sleep(for: .seconds(1.2))
                }
            }
            debugLog("[resize] done")
        }
    }
}
#endif

/// Standard navigation (pals-prd §2): the list (the assistant, its Pals, its
/// Allies) and the conversation picked in it, in a system split view.
/// Phones collapse it into one stack that opens on the assistant's
/// conversation, the list one step back; iPads and the Mac keep the list in
/// a sidebar the system toggle shows and hides. Management (the orb) and 成果
/// are pushed over the conversation on phones; on large screens management
/// is a sheet and 成果 the inspector beside the conversation.
struct MainScreen: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var voice = VoiceInputController()
    /// Local to this computer: the sidebar away or not.
    private static let sidebarCollapsedKey = "sidebarCollapsed"

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility, preferredCompactColumn: $model.compactColumn) {
            ConversationList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
                .modifier(InContentNavigationBar())
        } detail: {
            ConversationDetail()
        }
        // The right pane beside the conversation: on the split view, not in its
        // detail column (see RightPaneHost).
        .modifier(RightPaneHost(model: model, store: store))
        // The sidebar's capsule and its way back from the left edge.
        .modifier(SidebarCollapse(model: model))
        // The pane's tabs come from the computer (once online, and again on reconnect).
        .task(id: store.connection.isOnline) {
            if store.connection.isOnline { await PaneTabsHub.shared(for: store).load() }
        }
        .onChange(of: sizeClass, initial: true) { _, c in
            model.shortWindow = heightClass == .compact
            model.setLayout(c == .compact ? .phone : .split)
            // The sidebar stays as this window had it (the Mac's windows come
            // back with theirs), else as it was last left on this computer
            // (one setting, not per workspace).
            if c != .compact, model.prefersSidebarCollapsed ?? UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey) {
                model.columnVisibility = .detailOnly
            }
            model.applyLaunchScreen()
        }
        .onChange(of: heightClass) { _, h in model.shortWindow = h == .compact }
        .onChange(of: model.columnVisibility) { _, v in
            guard sizeClass == .regular else { return }
            model.prefersSidebarCollapsed = v == .detailOnly
            UserDefaults.standard.set(v == .detailOnly, forKey: Self.sidebarCollapsedKey)
        }
        .environment(voice)
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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && voice.previewText == nil { voice.abort() }
        }
        // Leaving a conversation (phones: back to the list, or a page pushed
        // over it): put the keyboard and any recording away.
        .onChange(of: model.compactColumn) { _, column in
            guard column == .sidebar, model.layout == .phone else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            if voice.previewText == nil { voice.abort() }
        }
        .modifier(LayoutTrace(model: model, store: store))
        .onAppear {
            if model.launch.screen == "voice" { voice.showPreview("你好，你好，你好，我正在说话" /* i18n-ok: demo preview text */) }
            model.markSeen()
            model.installPaneOpeners()
        }
        // Everything on screen counts as seen (drives the other assistants' unread dots).
        .onChange(of: store.lastSeq) { model.markSeen() }
        // Large screens: the assistant's management over everything.
        // ＋ → 从历史记录继续…
        .historyPicker()
        .sheet(isPresented: $model.showManagement) {
            ManagementSheet()
                .environment(model)
                .environment(store)
                .environment(voice)
        }
        // Phones: 设置 from the list.
        .sheet(isPresented: $model.showSettingsSheet) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") { model.showSettingsSheet = false }.tint(.primary)
                        }
                    }
            }
            .environment(model)
            .environment(store)
            .environment(voice)
        }
        // 新建会话 (⌘N, ＋) and 新建工作区 (⌘⇧N, ＋, a session's 并排…).
        .sheet(isPresented: $model.newSession, onDismiss: {
            model.newSessionIntoWorkspace = nil
            model.newSessionPlacement = nil
        }) {
            NewSessionPanel().environment(model).environment(store)
        }
        .sheet(isPresented: Binding(get: { model.newWorkspace != nil }, set: { if !$0 { model.newWorkspace = nil } })) {
            NewWorkspaceSheet(preselected: model.newWorkspace ?? []).environment(model).environment(store)
        }
        .sheet(isPresented: Binding(get: { model.showPairingSheet }, set: { if !$0 { model.showPairingSheet = false } })) {
            PairingView(isSheet: true).environment(model).environment(store)
        }
        // Right after pairing, once: 「给它起个名字」.
        .sheet(isPresented: Binding(get: { needsNaming }, set: { if !$0 { model.namingDone = true } })) {
            IdentityEditor(purpose: .firstTime).environment(model).environment(store)
        }
        // An Ally's invite opened from the system Camera.
        .sheet(item: Binding(get: { model.allyInvite }, set: { model.allyInvite = $0 })) { pending in
            AllyAcceptSheet(pending: pending).environment(model).environment(store)
        }
        .sheet(isPresented: $model.showAllyInvite) {
            AllyInviteSheet().environment(store)
        }
        // A pairing link for this very computer: for passing on to another device.
        .modifier(LinkForAnotherDeviceAlert(model: model))
    }

    /// Asked once per computer: it's paired, its settings arrived and it has no name yet.
    private var needsNaming: Bool {
        guard !model.namingDone, !model.showPairingSheet else { return false }
        if model.launch.screen == "naming" { return store.settings != nil }
        guard model.mode == .paired, let s = store.settings else { return false }
        return s.assistantName.isEmpty
    }
}

/// The window's layout facts in the exportable debug log, on change only
/// (sizes and states, never text): the main screen coming and going (a new
/// computer's store rebuilds it), the right pane's host switching between
/// beside and over, and the inspector actually being on screen.
private struct LayoutTrace: ViewModifier {
    let model: WindowModel
    let store: AppStore

    func body(content: Content) -> some View {
        content
            .onAppear { log("main screen up") }
            .onDisappear { log("main screen gone") }
            .onChange(of: model.libraryBeside) { _, beside in log("pane \(beside ? "beside" : "over")") }
            .onChange(of: model.layout) { _, l in log("layout \(l)") }
            .onChange(of: model.columnVisibility) { _, _ in log("sidebar \(model.sidebarCollapsed ? "away" : "shown")") }
            .onChange(of: model.paneIsOpen) { _, open in log("pane \(open ? "open" : "closed") (ours)") }
    }

    private func log(_ what: String) {
        debugLog("[layout] \(model.traceName): \(what); host \(model.activeHostID?.prefix(8) ?? "-") store \(store.traceID)\(store === model.store ? "" : " (not the window's)"), \(model.selection?.storageKey ?? "-"), sidebar \(model.sidebarCollapsed ? "away" : "shown"), pane \(model.paneIsOpen ? "open" : "closed"), inspector \(model.inspectorShown ? "shown" : "none"), window \(model.windowWidth) pt")
    }
}

extension AppStore {
    /// A short id for the logs (which store a view hierarchy holds).
    var traceID: Int { Int(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10000) }
}

extension WindowModel {
    /// "window 2 (3A5D2D12)": which window, for the logs.
    var traceName: String {
        "window \((app.windows.firstIndex { $0 === self } ?? -1) + 1) (\(windowID.prefix(8)))"
    }
    var windowWidth: Int { Int((scene?.effectiveGeometry.coordinateSpace.bounds.width ?? 0).rounded()) }
}

/// The detail column: the conversation picked in the list, with pages
/// pushed over it (phones).
private struct ConversationDetail: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        let current = model.selection ?? .palo
        NavigationStack(path: $model.detailPath) {
            Group {
                switch current {
                case .palo:
                    ChatView()
                case .pal(let id):
                    PalPage(palID: id).id("pal-\(id)")
                        // Switched from the quick-switch strip: the pages slide.
                        .transition(.asymmetric(
                            insertion: .move(edge: model.quickSwitchForward ? .trailing : .leading),
                            removal: .move(edge: model.quickSwitchForward ? .leading : .trailing)))
                case .ally(let id):
                    AllyConversationView(allyID: id).id("ally-\(id)")
                case .workspace(let id):
                    // Phones don't tile (workbench-prd §12): the sessions, one tap each.
                    if model.layout == .phone {
                        WorkspacePage(workspaceID: id).id("workspace-\(id)")
                    } else {
                        WorkspaceTilesPage(workspaceID: id).id("workspace-\(id)")
                    }
                case .earlier:
                    EarlierPage()
                case .session(let id):
                    SessionPage(sessionID: id).id("session-\(id)")
                case .devices:
                    DevicesPage()
                }
            }
            .modifier(QuickSwitchBar(current: current))
            .modifier(InContentNavigationBar())
            .modifier(HidesSystemSidebarToggle())
            // A folder's tree over 成果 (phones), and the files paths in replies link to.
            .modifier(FilesInConversation(current: current))
            .navigationDestination(for: WindowModel.Page.self) { page in
                switch page {
                case .manage: AssistantView()
                case .library: LibraryView()
                case .artifact(let id): ArtifactDetailView(artifactID: id)
                case .task(let id): TaskDetailView(taskID: id)
                }
            }
        }
        // Each conversation keeps its own unsent words.
        .environment(\.chatDraft, model.draftBinding(current))
        .background {
            // Esc puts 成果 away, like ⌘[.
            if model.libraryBeside && model.paneKey == PaneTabsKey.palo && model.paneIsOpen {
                Button("关闭成果") { model.setPane(open: false) }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        // Beside the sidebar the conversation gets roomier margins.
        .environment(\.placesAsColumns, model.layout != .phone)
        // Each window's conversation column as it changes, in the debug log
        // the owner can export (a width gone wrong without a known cause).
        .onGeometryChange(for: Int.self) { Int($0.size.width.rounded()) } action: { width in
            let i = (model.app.windows.firstIndex { $0 === model } ?? -1) + 1
            let window = Int((model.scene?.effectiveGeometry.coordinateSpace.bounds.width ?? 0).rounded())
            debugLog("[width] window \(i) (\(model.windowID.prefix(8))) \((model.selection ?? .palo).storageKey): column \(width) of \(window) pt, layout \(model.layout), sidebar \(model.sidebarCollapsed ? "away" : "shown"), pane \(model.paneIsOpen ? "open" : "closed"), short \(model.shortWindow), host \(store === model.store ? "same" : "OTHER") store \(store.traceID)")
        }
    }
}

/// The right pane (workbench-prd §7): large screens set it beside the
/// conversation as the split view's inspector; phones (and short windows) show
/// the same pane as a full page from the same button. Whose tabs it shows
/// follows the open page (`WindowModel.paneKey`). Phones don't get the inspector
/// at all (one that isn't shown still lends its toolbar and search field to
/// the conversation there).
///
/// It goes on the split view itself. Inside the detail column, the
/// inspector's own stack was taken for the column's: on the Mac a click on
/// an item only highlighted its row, and opening one from the conversation
/// crashed SwiftUI comparing paths (`AnyNavigationPath.Error.comparisonTypeMismatch`).
private struct RightPaneHost: ViewModifier {
    let model: WindowModel
    let store: AppStore

    func body(content: Content) -> some View {
        let key = model.paneKey ?? PaneTabsKey.palo
        if !model.libraryBeside {
            content.rightPaneCover(
                isPresented: Binding(get: { model.paneCover }, set: { model.paneCover = $0 }),
                key: key, activeSessionID: model.paneSessionID)
        } else {
            // Opened only on demand (its state is kept per page on the computer).
            content.inspector(isPresented: Binding(
                get: { model.paneKey != nil && model.paneIsOpen },
                set: { if !$0 { model.setPane(open: false) } }
            )) {
                // Presented outside this hierarchy on some platforms: pass what it reads.
                RightPane(key: key, activeSessionID: model.paneSessionID)
                    .id(key)
                    .environment(model)
                    .environment(store)
                    // No real cap: the owner drags it wide for a browser (2026-10-20).
                    .inspectorColumnWidth(min: 320, ideal: Self.idealWidth, max: 4000)
                    // Whether it is really on screen, and how wide (the debug log).
                    .onAppear {
                        model.inspectorShown = true
                        debugLog("[layout] \(model.traceName): inspector up")
                    }
                    .onDisappear {
                        model.inspectorShown = false
                        debugLog("[layout] \(model.traceName): inspector gone")
                    }
                    .onGeometryChange(for: Int.self) { Int($0.size.width.rounded()) } action: { w in
                        debugLog("[layout] \(model.traceName): inspector \(w) pt of \(model.windowWidth)")
                    }
            }
        }
    }

    /// `-demoPaneWidth 1000` (DEBUG): the pane opens that wide, as if dragged.
    private static var idealWidth: CGFloat {
        #if DEBUG
        let w = UserDefaults.standard.double(forKey: "demoPaneWidth")
        if w > 0 { return w }
        #endif
        return 400
    }
}

/// The assistant's management as a sheet (large screens), with its own pages.
private struct ManagementSheet: View {
    var body: some View {
        NavigationStack {
            AssistantView(inSheet: true)
                .modifier(InContentNavigationBar())
        }
        .presentationSizing(.page)
    }
}

extension EnvironmentValues {
    /// Large screens: the conversation sits beside the sidebar (or 成果 in
    /// the inspector), with roomier margins.
    @Entry var placesAsColumns = false
    /// The open conversation's unsent text (kept per conversation by WindowModel).
    @Entry var chatDraft: Binding<String> = .constant("")
}

#Preview("Demo") {
    let model = WindowModel.demo()
    RootView().environment(model)
}

#if DEBUG
/// `-demoScreen splitLab`: a bare split view with an inspector, to tell the
/// system's behaviour from the app's (a second window's columns).
private struct SplitLab: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            List { Text("list") }
        } detail: {
            Color.yellow
                .onGeometryChange(for: Int.self) { Int($0.size.width.rounded()) } action: { w in
                    debugLog("[width] lab \(model.traceName): column \(w) of \(model.windowWidth) pt, sidebar \(model.columnVisibility == .detailOnly ? "away" : "shown"), pane \(model.paneCover)")
                }
        }
        .inspector(isPresented: Binding(get: { model.paneCover }, set: { model.paneCover = $0 })) {
            Color.blue.inspectorColumnWidth(min: 320, ideal: 400, max: 4000)
        }
    }
}
#endif
