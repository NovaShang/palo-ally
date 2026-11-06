import PaloAllyFilePreview
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
            // `-bandProbe YES`: every view lying across the window's top (a band under the title bar row).
            if d.bool(forKey: "bandProbe") {
                func walk(_ v: UIView, _ depth: Int) {
                    let f = v.convert(v.bounds, to: window)
                    if (f.minY <= 1 && f.height >= 20 && f.height <= 140 || f.minY > 30 && f.minY < 70 && f.height <= 3), f.width >= 300, !v.isHidden {
                        NSLog("[band] %@ %@ %d,%d %dx%d alpha %.2f", String(repeating: " ", count: depth), String(describing: type(of: v)), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height), v.alpha)
                        NSLog("[band]    = %@", v.description.prefix(300).description)
                        func layers(_ l: CALayer, _ d: Int) {
                            NSLog("[band]    %@%@ %@ %@ filters %@ bg %@ op %.2f", String(repeating: " ", count: d), String(describing: type(of: l)), l.name ?? "-", NSCoder.string(for: l.frame), String(describing: (l.filters ?? []).map { String(describing: $0).prefix(60) }), l.backgroundColor.map { "\($0.alpha)" } ?? "-", l.opacity)
                            for c in l.sublayers ?? [] where d < 4 { layers(c, d + 1) }
                        }
                        layers(v.layer, 0)
                        for sub in v.subviews { NSLog("[band]    sub %@ %@", String(describing: type(of: sub)), NSCoder.string(for: sub.frame)) }
                        var p = v.superview
                        var n = 0
                        while let up = p, n < 10 {
                            let g = up.convert(up.bounds, to: window)
                            NSLog("[band]    < %@ %d,%d %dx%d", String(describing: type(of: up)).prefix(120).description, Int(g.minX), Int(g.minY), Int(g.width), Int(g.height))
                            p = up.superview; n += 1
                        }
                    }
                    for s in v.subviews { walk(s, depth + 1) }
                }
                walk(window, 0)
            }
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
                if PerfProbe.on { debugLog("[perfstep] start | \(PerfProbe.takeStep())") }
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
                    // `sidebar-anim`: the same, animated, as the capsule's button and ⌃⌘S do.
                    case "sidebar-anim": w.toggleSidebar()
                    // `w2.pane`: that window's right pane, as its button (⌘2).
                    case "pane": if w.launch.screen == "splitLab" { w.paneCover.toggle() } else { w.togglePane() }
                    case "list": w.showList()
                    // `w2.close`: that window closed, as its close button does.
                    case "close":
                        if let scene = w.scene { UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) }
                    // `palo`: the collapsed sidebar's Palo orb clicked (the Mac: Palo's popover, open or closed).
                    case "palo": NotificationCenter.default.post(name: .demoTogglePaloPopover, object: w)
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
                    // `docsplit:2`: 在分屏中打开 on the open workspace's right pane tab at that index;
                    // `docsplit:/abs/path`: that file (a tab or not); `docback:/abs/path`: its card's 在右侧栏打开;
                    // `docclose:/abs/path`: its card's 关闭卡片.
                    case _ where a.hasPrefix("docsplit:") || a.hasPrefix("docback:") || a.hasPrefix("docclose:"):
                        guard case .workspace(let ws)? = w.selection, let store = w.store else { break }
                        let arg = String(a.split(separator: ":", maxSplits: 1).last ?? "")
                        let tabs = PaneTabsHub.shared(for: store).state(for: PaneTabsKey.workspace(ws)).tabs
                        let doc = Int(arg).flatMap { tabs.indices.contains($0) ? DocumentLeaf(tab: tabs[$0]) : nil }
                            ?? DocumentLeaf(id: arg.hasPrefix("artifact:") ? "doc:" + arg : "doc:" + arg)
                        guard let doc else { debugLog("[nav] \(a): no document"); break }
                        do {
                            if a.hasPrefix("docsplit:") { try await w.openInSplit(doc, in: ws) }
                            else if a.hasPrefix("docback:") { try await w.documentToPane(doc.id, in: ws) }
                            else { try await w.closeDocumentCard(doc.id, in: ws) }
                        } catch {
                            debugLog("[nav] \(a): \(error)")
                        }
                        let layout = store.workspace(id: ws).flatMap { w.tree(of: $0) }.map(LayoutTree.leafOrder(of:)) ?? []
                        let left = PaneTabsHub.shared(for: store).state(for: PaneTabsKey.workspace(ws)).tabs.map { $0.path ?? $0.url ?? $0.kind }
                        debugLog("[nav] \(a): layout \(layout) tabs \(left)")
                    // `artifact:ar1`: that artifact's card tapped in the conversation (an artifact card's pane path).
                    case _ where a.hasPrefix("artifact:"):
                        w.openArtifact(String(a.dropFirst(9)))
                    // `w2.size:1440x1100`: that window resized, as a drag of its corner.
                    case _ where a.hasPrefix("size:"):
                        let wh = a.dropFirst(5).split(separator: "x").compactMap { Double($0) }
                        if wh.count == 2, let scene = w.scene {
                            let f = scene.frameOnScreen
                            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: f.minX, y: f.minY, width: wh[0], height: wh[1])))
                        }
                    // `live:1600:1100`: the window's edge dragged from 1600 to 1100 pt
                    // wide, a step a frame (a live resize).
                    case _ where a.hasPrefix("live:"):
                        let ws = a.dropFirst(5).split(separator: ":").compactMap { Double($0) }
                        if ws.count == 2, let scene = w.scene {
                            let f = scene.frameOnScreen
                            for i in 0...60 {
                                let width = ws[0] + (ws[1] - ws[0]) * Double(i) / 60
                                scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: f.minX, y: f.minY, width: width, height: f.height)))
                                try? await Task.sleep(for: .milliseconds(16))
                            }
                        }
                    // `pane-drag:400:800`: the right pane's divider dragged from 400 to 800 pt, a step a frame.
                    case _ where a.hasPrefix("pane-drag:"):
                        let ws = a.dropFirst(10).split(separator: ":").compactMap { Double($0) }
                        func splits(_ vc: UIViewController) -> [UISplitViewController] {
                            ((vc as? UISplitViewController).map { [$0] } ?? []) + vc.children.flatMap(splits)
                        }
                        // The outermost split view holds the inspector (the sidebar's is inside it).
                        if ws.count == 2, let root = w.scene?.windows.first?.rootViewController, let split = splits(root).first {
                            for i in 0...60 {
                                split.preferredInspectorColumnWidth = ws[0] + (ws[1] - ws[0]) * Double(i) / 60
                                try? await Task.sleep(for: .milliseconds(16))
                            }
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
                    // `click:650;26`: a left click there in the key window, as AppKit delivers one.
                    case _ where a.hasPrefix("click:"):
                        let r = AppKitBundle.object?.perform(NSSelectorFromString("click:"), with: a.dropFirst(6).replacingOccurrences(of: ";", with: ","))?
                            .takeUnretainedValue() as? String
                        debugLog("[nav] \(r ?? "no AppKit bundle")")
                    // `drag:1200;500;900;500`: a left drag from the one point to the other (a divider dragged);
                    // `drag:1200;500;900;500;2`: the same taking 2 s.
                    // `selectpreview`: everything in the file preview selected (as a drag over it would).
                    case "selectpreview":
                        if let win = w.scene?.windows.first {
                            var queue: [UIView] = [win]
                            while !queue.isEmpty {
                                let v = queue.removeFirst()
                                if let web = v as? FilePreviewWebView { web.notePressed(); web.evaluateJavaScript("document.execCommand('selectAll')", completionHandler: nil); break }
                                queue.append(contentsOf: v.subviews)
                            }
                        }
                    // `fileedit`: 编辑 / 预览 in the file tab shown (⌘E); `filesave`: its 保存 (⌘S).
                    // `fileopen:/abs/path`: that file picked from the path at the editor's top.
                    case "fileedit", "filesave", _ where a.hasPrefix("fileopen:"): NotificationCenter.default.post(name: .demoFileEdit, object: a)
                    // `filetype:text`: typed into the file being edited, at its cursor.
                    case _ where a.hasPrefix("filetype:"):
                        if let win = w.scene?.windows.first {
                            var queue: [UIView] = [win]
                            while !queue.isEmpty {
                                let v = queue.removeFirst()
                                if let editor = v as? FileEditorWebView, editor.window != nil, !editor.isHidden {
                                    editor.focusText()
                                    let text = String(a.dropFirst(9)).replacingOccurrences(of: "\\n", with: "\n")
                                    let json = String(data: (try? JSONEncoder().encode([text])) ?? Data(), encoding: .utf8) ?? "[\"\"]"
                                    editor.evaluateJavaScript("paEditorInsert(\(json)[0])", completionHandler: nil)
                                    break
                                }
                                queue.append(contentsOf: v.subviews)
                            }
                        }
                    // `keys:nihao `: those keys pressed, as the keyboard does (`⌘s`: with ⌘; `\n`: Return).
                    case _ where a.hasPrefix("keys:"):
                        let spec = String(a.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\n")
                        let r = AppKitBundle.object?.perform(NSSelectorFromString("pressKeys:"), with: spec)?.takeUnretainedValue() as? String
                        debugLog("[nav] \(r ?? "no AppKit bundle")")
                        try? await Task.sleep(for: .seconds(0.1 * Double(spec.count) + 0.5))
                    // `compose:nihao:你好`: an input method's composition in the text that has
                    // the keyboard, as UIKit hands it on (marked text a letter at a time, then the commit).
                    case _ where a.hasPrefix("compose:"):
                        let parts = a.dropFirst(8).split(separator: ":").map(String.init)
                        func responder(_ v: UIView) -> UIView? {
                            v.isFirstResponder ? v : v.subviews.lazy.compactMap(responder).first
                        }
                        guard parts.count == 2, let win = w.scene?.windows.first, let input = responder(win) as? (UIView & UITextInput) else {
                            debugLog("[nav] compose: nothing has the keyboard"); break
                        }
                        for i in 1...parts[0].count {
                            input.setMarkedText(String(parts[0].prefix(i)), selectedRange: NSRange(location: i, length: 0))
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                        input.insertText(parts[1])
                        try? await Task.sleep(for: .milliseconds(300))
                    // `copy`: ⌘C pressed.
                    case "copy":
                        debugLog("[nav] \((AppKitBundle.object?.perform(NSSelectorFromString("pressCopy"))?.takeUnretainedValue() as? String) ?? "no AppKit bundle")")
                    // `composerfocus`: the conversation's composer takes the keyboard, as a click in it does.
                    case "composerfocus":
                        NotificationCenter.default.post(name: ComposerFocus.request, object: nil,
                                                        userInfo: ["window": ObjectIdentifier(w), "tile": ""])
                    // `scroll:700;780;-30`: the mouse wheel turned there (negative: down).
                    case _ where a.hasPrefix("scroll:"):
                        let r = AppKitBundle.object?.perform(NSSelectorFromString("scroll:"), with: a.dropFirst(7).replacingOccurrences(of: ";", with: ","))?
                            .takeUnretainedValue() as? String
                        debugLog("[nav] \(r ?? "no AppKit bundle")")
                        try? await Task.sleep(for: .seconds(1))
                        if let win = w.scene?.windows.first {
                            func find(_ v: UIView) -> [UITextView] { ((v as? UITextView).map { [$0] } ?? []) + v.subviews.flatMap(find) }
                            for t in find(win) where t.isEditable {
                                debugLog("[nav] composer text \(Int(t.bounds.height)) of \(Int(t.contentSize.height)) pt, at \(Int(t.contentOffset.y)), \(t.isFirstResponder ? "editing" : "not editing")")
                            }
                        }
                    case _ where a.hasPrefix("drag:"):
                        let r = AppKitBundle.object?.perform(NSSelectorFromString("drag:"), with: a.dropFirst(5).replacingOccurrences(of: ";", with: ","))?
                            .takeUnretainedValue() as? String
                        debugLog("[nav] \(r ?? "no AppKit bundle")")
                        let seconds = a.split(separator: ";").count == 5 ? Double(a.split(separator: ";")[4]) ?? 0.5 : 0.5
                        try? await Task.sleep(for: .seconds(1 + seconds))
                    // `hover:650;300`: the pointer moved there (no click).
                    case _ where a.hasPrefix("hover:"):
                        let r = AppKitBundle.object?.perform(NSSelectorFromString("move:"), with: a.dropFirst(6).replacingOccurrences(of: ";", with: ","))?
                            .takeUnretainedValue() as? String
                        debugLog("[nav] \(r ?? "no AppKit bundle")")
                    // `rpress:650;300;1.5` a right press there held 1.5 s (a short one: 0.1);
                    // `rpress:650;300;2;400;600` moved to 400,600 while held (MacRightHold).
                    case _ where a.hasPrefix("rpress:"):
                        let r = AppKitBundle.object?.perform(NSSelectorFromString("rightPress:"), with: a.dropFirst(7).replacingOccurrences(of: ";", with: ","))?
                            .takeUnretainedValue() as? String
                        debugLog("[nav] \(r ?? "no AppKit bundle")")
                    #endif
                    // `tick:pal-site:busy`: that session's status ticks (`busy`/`idle`: its state too).
                    case _ where a.hasPrefix("tick:"):
                        let parts = a.split(separator: ":").map(String.init)
                        if parts.count > 1, let id = w.activeHostID, let host = model.app.demoHost(id) {
                            await host.perfTick(parts[1], state: parts.count > 2 ? parts[2] : nil)
                        }
                    // `stream:pal-blog`: a reply streams into that session.
                    case _ where a.hasPrefix("stream:"):
                        if let id = w.activeHostID, let host = model.app.demoHost(id) {
                            let pal = String(a.dropFirst(7))
                            Task { await host.perfStream(pal) }
                        }
                    // `tab:2`: the right pane's tab at that index shown (its chip clicked).
                    case _ where a.hasPrefix("tab:"):
                        if let key = w.paneKey, let i = Int(a.dropFirst(4)) { w.paneHub?.activate(key, at: i) }
                    // `type:字`: typed into the open page's (the active pane's) draft.
                    case _ where a.hasPrefix("type:"):
                        let page: WindowModel.Conversation = {
                            if case .workspace(let id)? = w.selection, let tile = w.activeTile(in: id) {
                                return tile == LayoutTree.paloPane ? .palo : .pal(tile)
                            }
                            return w.selection ?? .palo
                        }()
                        w.draftBox(page).text += String(a.dropFirst(5))
                    // `web:http://localhost:8765/a.html`: a page opened in the right pane, as a link in a reply does.
                    case _ where a.hasPrefix("web:"):
                        if let url = URL(string: String(a.dropFirst(4))) { w.openWebInPane(url) }
                    // `file:pal-site:README.md`: that session's file opened in the right pane, as a link in a reply does.
                    case _ where a.hasPrefix("file:"):
                        let parts = a.split(separator: ":", maxSplits: 2).map(String.init)
                        if parts.count == 3 { _ = w.openFileInPane(FileTarget(scope: .pal(parts[1]), path: parts[2])) }
                    // `filetap:pal-site:docs/home.png`: that path tapped in a reply (FilePagePresenter).
                    case _ where a.hasPrefix("filetap:"):
                        let parts = a.split(separator: ":", maxSplits: 2).map(String.init)
                        if parts.count == 3, let store = w.store { FilePagePresenter.present(FileTarget(scope: .pal(parts[1]), path: parts[2]), store: store) }
                    // `unfocus`: the keyboard leaves whatever has it.
                    case "unfocus":
                        w.scene?.windows.first?.endEditing(true)
                    // `where`: the split workspace's panes' frames in the window, and its width (for `click:`).
                    case "where":
                        for c in PaneCanvasController.all.allObjects where c.view.window?.windowScene === w.scene {
                            c.demo("where")
                        }
                        debugLog("[nav] window \(w.windowWidth) pt")
                    // `split`: each window's split view controllers and their inspector widths.
                    case "split":
                        func walk(_ vc: UIViewController, _ depth: Int) {
                            if let s = vc as? UISplitViewController {
                                debugLog("[nav] split \(type(of: s)) depth \(depth): inspector preferred \(s.preferredInspectorColumnWidth) fraction \(s.preferredInspectorColumnWidthFraction) min \(s.minimumInspectorColumnWidth) max \(s.maximumInspectorColumnWidth); primary \(s.primaryColumnWidth) preferred \(s.preferredPrimaryColumnWidth) fraction \(s.preferredPrimaryColumnWidthFraction) min \(s.minimumPrimaryColumnWidth) max \(s.maximumPrimaryColumnWidth) edge \(s.primaryEdge.rawValue) style \(s.style.rawValue) mode \(s.displayMode.rawValue) supplementary \(s.supplementaryColumnWidth)")
                            }
                            for c in vc.children { walk(c, depth + 1) }
                        }
                        if let root = w.scene?.windows.first?.rootViewController { walk(root, 0) }
                    // `presented`: what each window presents now (popovers don't show in snapshots).
                    case "presented":
                        for (i, w) in model.app.windows.enumerated() {
                            var chain: [String] = []
                            var vc = w.scene?.windows.first?.rootViewController?.presentedViewController
                            while let p = vc {
                                var anchor = ""
                                if let pc = p.popoverPresentationController, let source = pc.sourceView, let window = source.window {
                                    let r = source.convert(pc.sourceRect.isEmpty ? source.bounds : pc.sourceRect, to: window)
                                    anchor = " from \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
                                }
                                chain.append("\(type(of: p)) \(p.modalPresentationStyle == .popover ? "popover" : "style \(p.modalPresentationStyle.rawValue)") \(Int(p.preferredContentSize.width))x\(Int(p.preferredContentSize.height))\(anchor)")
                                // Its content as drawn, to <app tmp>/presented-<n>.png (window snapshots leave popovers out).
                                let view = p.view!
                                let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                                    _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                                }
                                try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("presented-\(i + 1).png"))
                                vc = p.presentedViewController
                            }
                            debugLog("[nav] window \(i + 1) presents \(chain.isEmpty ? "nothing" : chain.joined(separator: " > "))")
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
                        debugLog("[nav] after \(step): window \(i + 1)\(w === model.app.frontWindow ? " (front)" : "") frame \(w.scene.map { "\($0.frameOnScreen) state \($0.activationState.rawValue) key \($0.keyWindow != nil)" } ?? "-") sidebar \(w.columnVisibility == .detailOnly ? "away" : "shown") host \(w.activeHostID ?? "-") (\(w.store?.assistantName ?? "") store \(w.store?.traceID ?? 0)) last \(model.app.lastHostID ?? "-") layout \(w.layout.rawValue) selection \(String(describing: w.selection)) management \(w.showManagement) pane \(w.paneIsOpen) settings \(w.showSettings)")
                    }
                    #if targetEnvironment(macCatalyst)
                    for (i, w) in model.app.windows.enumerated() {
                        let items = w.scene?.titlebar?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
                        debugLog("[nav] after \(step): window \(i + 1) toolbar \(items)")
                    }
                    #endif
                    try? await Task.sleep(for: .seconds(0.5))
                    // The bodies this step ran (with `-perfMeter YES`).
                    if PerfProbe.on { debugLog("[perfstep] \(step) | \(PerfProbe.takeStep())") }
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
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("MainScreen")
        #endif
        NavigationSplitView(columnVisibility: Binding(get: { model.columnVisibility }, set: { v in
            // The system's own toggle (the toolbar's button) too: what is in
            // the columns keeps its size while they move.
            if v != model.columnVisibility { model.columnsMove(for: 0.55) }
            model.columnVisibility = v
        }), preferredCompactColumn: $model.compactColumn) {
            ConversationList()
                .modifier(FreezesWhileResized(model: model, name: "list"))
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
            .onChange(of: model.columnVisibility) { _, _ in
                log("sidebar \(model.sidebarCollapsed ? "away" : "shown")")
                logTitlebar()
            }
            .task { logTitlebar() }
            .onChange(of: model.paneIsOpen) { _, open in log("pane \(open ? "open" : "closed") (ours)") }
    }

    /// The Mac: the title bar's views as AppKit has them, once the sidebar has moved.
    private func logTitlebar() {
        #if targetEnvironment(macCatalyst)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if let facts = AppKitBundle.call("titlebarFacts") {
                debugLog("[titlebar] \(model.traceName), sidebar \(model.sidebarCollapsed ? "away" : "shown"):\n\(facts)")
            }
        }
        #endif
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
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("ConversationDetail")
        #endif
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
        .chatDraft(model.draftBox(current))
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
        .modifier(FreezesWhileResized(model: model, name: "detail"))
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
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("RightPaneHost")
        #endif
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
                    // Its edge is at the left: held there by the window's.
                    .modifier(FreezesWhileResized(model: model, name: "pane", alignment: .topTrailing,
                                                  ground: Color(.systemGroupedBackground), leadingLine: true))
                    .environment(model)
                    .environment(store)
                    // No real cap: the owner drags it wide for a browser (2026-10-20).
                    .inspectorColumnWidth(min: 320, ideal: Self.idealWidth, max: 4000)
                    // The Mac took none of it (a bare split view neither, the
                    // split lab): the pane opened at 280 pt and couldn't be
                    // dragged wider. Set on the split view itself.
                    .background {
                        InspectorWidth(ideal: Self.idealWidth, open: model.paneIsOpen, sidebarShown: !model.sidebarCollapsed)
                    }
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
                        // The width it was left at (dragged), for the next time it opens.
                        if model.paneIsOpen, w >= 320 { InspectorWidth.remember(CGFloat(w)) }
                        InspectorWidth.check()
                    }
            }
        }
    }

    /// `-demoPaneWidth 1000` (DEBUG): the pane opens that wide, as if dragged.
    /// Else the width it was last left at, else 400.
    private static var idealWidth: CGFloat {
        #if DEBUG
        let w = UserDefaults.standard.double(forKey: "demoPaneWidth")
        if w > 0 { return w }
        #endif
        return InspectorWidth.remembered ?? 400
    }
}

/// The Mac (11-05, the owner: nothing should update while things move): a
/// column's content keeps the size it had while the column is resized, the
/// sidebar's or the right pane's edge or the window's dragged (a second new
/// size within 0.1 s of the last), or the columns move in an animation we
/// started (`WindowModel.columnsMoving`). Laid out again at every step, a
/// conversation, the right pane or the list took the frame past its time.
/// It is held at its corner, clipped at the column's sides (or with the
/// column's ground beyond it), a little washed out, and once no new size
/// has come for 0.15 s (or the animation is over) it is laid out once at
/// the new size and the wash fades.
struct FreezesWhileResized: ViewModifier {
    let model: WindowModel
    /// For the debug log.
    let name: String
    var alignment: Alignment = .topLeading
    /// Beyond the content while it is held smaller than its column, with
    /// the column's edge drawn as a hairline (the right pane's own is on
    /// its content, held away from the edge).
    var ground: Color? = nil
    var leadingLine = false
    /// The size it was last laid out at.
    @State private var size: CGSize = .zero
    /// What doesn't change what is drawn: the column's size now, when it
    /// last changed, the latest wait for it to settle.
    @State private var track = Track()
    private final class Track {
        var container: CGSize = .zero
        var lastChange: CFTimeInterval = 0
        var run = 0
    }
    /// Held at this size since a resize was seen.
    @State private var held: CGSize?

    /// The size the content is held at now, if any.
    private var pinned: CGSize? {
        #if DEBUG
        if Self.off { return nil }
        #endif
        guard Platform.isMac else { return nil }
        if let held { return held }
        return model.columnsMoving && size.width > 0 && size.height > 0 ? size : nil
    }

    #if DEBUG
    /// `-freezeOff YES`: laid out at every step, as before (to compare).
    private static let off = UserDefaults.standard.bool(forKey: "freezeOff")
    #endif

    func body(content: Content) -> some View {
        let pinned = pinned
        content
            .frame(width: pinned?.width, height: pinned?.height, alignment: alignment)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
            .clipShape(SidesClip(active: pinned != nil))
            .background {
                if let ground { ground.ignoresSafeArea() }
            }
            .overlay(alignment: .leading) {
                if leadingLine {
                    Rectangle().fill(Color(.separator)).frame(width: 1)
                        .opacity(pinned == nil ? 0 : 1)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                Color(.systemBackground)
                    .opacity(pinned == nil ? 0 : 0.3)
                    .animation(.easeInOut(duration: pinned == nil ? 0.2 : 0.18), value: pinned == nil)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { new in resized(to: new) }
            .onChange(of: model.columnsMoving) { _, moving in
                guard Platform.isMac else { return }
                if moving {
                    debugLog("[freeze] \(name) held at \(Int(size.width))x\(Int(size.height)) while the columns move")
                } else {
                    size = track.container
                    debugLog("[freeze] \(name) laid out at \(Int(track.container.width))x\(Int(track.container.height))")
                }
            }
    }

    private func resized(to new: CGSize) {
        track.container = new
        guard Platform.isMac else { size = new; return }
        #if DEBUG
        if Self.off { size = new; return }
        #endif
        let now = CACurrentMediaTime()
        defer { track.lastChange = now }
        if model.columnsMoving, size.width > 0, size.height > 0 {
            #if DEBUG || PERF_HARNESS
            PerfProbe.count("held \(name)")
            #endif
            return
        }
        if held == nil {
            guard now - track.lastChange < 0.1, size.width > 0, size.height > 0 else { size = new; return }
            // The second step of a resize: held at the size it has now.
            held = new
            size = new
            debugLog("[freeze] \(name) held at \(Int(new.width))x\(Int(new.height))")
        }
        #if DEBUG || PERF_HARNESS
        PerfProbe.count("held \(name)")
        #endif
        track.run += 1
        let mine = track.run
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [track] in
            guard mine == track.run, held != nil else { return }
            held = nil
            size = track.container
            debugLog("[freeze] \(name) laid out at \(Int(track.container.width))x\(Int(track.container.height))")
        }
    }
}

/// Clips at the sides only, and only while held: what is drawn under the
/// title bar (above the column's safe area) stays.
private struct SidesClip: Shape {
    let active: Bool
    func path(in rect: CGRect) -> Path {
        Path(active ? rect.insetBy(dx: 0, dy: -10_000) : rect.insetBy(dx: -10_000, dy: -10_000))
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
    /// The same words' box: what the composer reads (`ComposerView.draftBox`).
    @Entry var chatDraftBox: DraftBox? = nil
}

extension View {
    /// The open conversation's unsent words, for the page and its composer.
    func chatDraft(_ box: DraftBox) -> some View {
        environment(\.chatDraft, box.binding).environment(\.chatDraftBox, box)
    }
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


/// The Mac: the right pane's widths set on the split view that shows it
/// (`inspectorColumnWidth` never reached it there): at least 320 pt, at most
/// what leaves the conversation 360 pt beside the sidebar, opening at
/// `ideal`. SwiftUI puts its own back whenever it updates the pane (opening
/// it, the sidebar coming or going), so they are checked again then, and as
/// the window is resized.
struct InspectorWidth: UIViewRepresentable {
    let ideal: CGFloat
    /// The pane shown: each time it opens it starts at `ideal`.
    let open: Bool
    let sidebarShown: Bool

    static let minimum: CGFloat = 320
    /// The conversation keeps at least this beside the pane.
    static let conversationMinimum: CGFloat = 360

    private static let key = "rightPaneWidth"
    private static let checkNote = Notification.Name("PaloAlly.inspectorWidthCheck")
    static var remembered: CGFloat? {
        let w = UserDefaults.standard.double(forKey: key)
        return w >= minimum ? w : nil
    }
    @MainActor private static var pendingWrite: DispatchWorkItem?
    /// Kept once the pane has stopped changing for 0.3 s: written at each
    /// step of a drag it was a round trip to the preferences a frame.
    static func remember(_ w: CGFloat) {
        guard Platform.isMac else { return }
        pendingWrite?.cancel()
        let write = DispatchWorkItem {
            guard abs(UserDefaults.standard.double(forKey: key) - w) >= 1 else { return }
            UserDefaults.standard.set(Double(w), forKey: key)
        }
        pendingWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: write)
    }
    /// The pane's width changed: SwiftUI may have put its own widths back.
    static func check() {
        guard Platform.isMac else { return }
        NotificationCenter.default.post(name: checkNote, object: nil)
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.ideal = ideal
        let opened = open && !view.open
        let sidebarChanged = view.sidebarShown != sidebarShown
        view.open = open
        view.sidebarShown = sidebarShown
        if opened || sidebarChanged { view.applySoon(opening: opened) }
    }

    final class Probe: UIView {
        var ideal: CGFloat = 400
        var open = false
        var sidebarShown = true
        private var observers: [NSObjectProtocol] = []
        private var resize: NSKeyValueObservation?
        /// The split view whose widths are held (`holdWidths`).
        private weak var held: UISplitViewController?
        private var holds: [NSKeyValueObservation] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard Platform.isMac, let scene = window?.windowScene else {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                resize = nil
                return
            }
            if observers.isEmpty {
                observers.append(NotificationCenter.default.addObserver(forName: InspectorWidth.checkNote, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(opening: false) }
                })
            }
            resize = scene.observe(\.effectiveGeometry) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applySoon(opening: false) } }
            }
            applySoon(opening: true)
        }

        /// Now, and after SwiftUI's own pass over the split view.
        func applySoon(opening: Bool) {
            guard Platform.isMac, window != nil else { return }
            apply(opening: opening)
            DispatchQueue.main.async { [weak self] in self?.apply(opening: opening) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply(opening: opening) }
        }

        private func apply(opening: Bool) {
            guard open, window != nil, let split = inspectorSplit else { return }
            holdWidths(of: split)
            // The sidebar's split view is inside the inspector's; its own
            // width, not what a squeeze left it.
            let sidebar = Self.splits(under: split).first { $0 !== split }
            let sidebarWidth = sidebar.map { s in
                s.displayMode == .secondaryOnly ? 0 : (s.preferredPrimaryColumnWidth > 0 ? s.preferredPrimaryColumnWidth : s.primaryColumnWidth)
            } ?? 0
            let most = max(InspectorWidth.minimum, split.view.bounds.width - sidebarWidth - InspectorWidth.conversationMinimum)
            let reset = split.minimumInspectorColumnWidth != InspectorWidth.minimum
            guard reset || opening || abs(split.maximumInspectorColumnWidth - most) >= 1 else { return }
            split.minimumInspectorColumnWidth = InspectorWidth.minimum
            split.maximumInspectorColumnWidth = most
            // Opening, or SwiftUI just put its own back: where it was left.
            let start = min(opening ? ideal : max(ideal, InspectorWidth.remembered ?? 0), most)
            if reset || opening { split.preferredInspectorColumnWidth = start }
            debugLog("[layout] inspector widths: \(Int(InspectorWidth.minimum)) to \(Int(most)) pt (window \(Int(split.view.bounds.width)), sidebar \(Int(sidebarWidth)))\(reset || opening ? ", at \(Int(start))" : "")")
        }

        /// SwiftUI resets the pane's widths to the system's (280 pt) each
        /// time it updates the inspector: a click that moves the keyboard,
        /// a pane becoming the active one, a tab. Put back later, the pane
        /// went 400 → 280 → 400 pt and every conversation beside it laid
        /// out twice. Put back here, as SwiftUI sets them (before any
        /// layout), nothing moves.
        private func holdWidths(of split: UISplitViewController) {
            guard held !== split else { return }
            held = split
            // The width SwiftUI just replaced with the system's, else nil.
            func replaced(_ change: NSKeyValueObservedChange<CGFloat>) -> CGFloat? {
                guard let old = change.oldValue, let new = change.newValue, new < 0, old > 0 else { return nil }
                return old
            }
            holds = [
                split.observe(\.minimumInspectorColumnWidth, options: [.old, .new]) { [weak self] split, change in
                    MainActor.assumeIsolated {
                        if self?.holding == true, let w = replaced(change) { split.minimumInspectorColumnWidth = w }
                    }
                },
                split.observe(\.maximumInspectorColumnWidth, options: [.old, .new]) { [weak self] split, change in
                    MainActor.assumeIsolated {
                        if self?.holding == true, let w = replaced(change) { split.maximumInspectorColumnWidth = w }
                    }
                },
                split.observe(\.preferredInspectorColumnWidth, options: [.old, .new]) { [weak self] split, change in
                    MainActor.assumeIsolated {
                        if self?.holding == true, let w = replaced(change) { split.preferredInspectorColumnWidth = w }
                    }
                },
            ]
        }

        private var holding: Bool { open && window != nil }

        private var inspectorSplit: UISplitViewController? {
            var r = next
            while let responder = r {
                if let split = responder as? UISplitViewController,
                   split.viewController(for: .inspector) != nil || String(describing: type(of: split)).contains("Inspector") {
                    return split
                }
                r = responder.next
            }
            return nil
        }

        private static func splits(under vc: UIViewController) -> [UISplitViewController] {
            ((vc as? UISplitViewController).map { [$0] } ?? []) + vc.children.flatMap { splits(under: $0) }
        }
    }
}
