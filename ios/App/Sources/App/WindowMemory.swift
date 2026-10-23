import PaloAllyKit
import SwiftUI
import UIKit

/// One open window as the Mac app keeps it between launches.
struct SavedWindow: Codable, Equatable {
    var id: String
    /// `Conversation.storageKey`.
    var conversation: String
    var host: String?
    var sidebarCollapsed: Bool?
    /// Its right pane, open or not, per page it was opened or closed on (`WindowModel.paneOpenHere`).
    var paneOpen: [String: Bool]?
    /// The window's frame on screen (`systemFrame`): x, y, width, height.
    var frame: [Double]?
    /// An old Palo small window (retired for a popover): dropped at load.
    var mini: Bool?

    var systemFrame: CGRect? {
        guard let f = frame, f.count == 4, f[2] > 100, f[3] > 100 else { return nil }
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
}

/// The Mac: the windows open at quit come back at the next launch, each with
/// what it showed (its conversation, computer, sidebar, right pane and place on screen).
///
/// macOS's own window restoration is off for most people ("Close windows
/// when quitting an application" is on by default), so the app keeps its own
/// list, in step with the windows as they change. Closing a window by hand
/// takes it off; quitting keeps them all. At launch the window the system
/// opens takes the first one and the others are opened again; windows the
/// system restored itself (that setting off) find their own entry instead,
/// so nothing comes back twice. iPads and phones don't use it.
@MainActor
final class WindowMemory {
    static let shared = WindowMemory()

    static let enabled: Bool = {
        guard Platform.isMac else { return false }
        let d = UserDefaults.standard
        #if DEBUG || PERF_HARNESS
        // Screenshots and launch screens want one plain window; `-windowMemory YES` keeps it on anyway.
        if d.object(forKey: "windowMemory") != nil { return d.bool(forKey: "windowMemory") }
        if d.object(forKey: "demoSnapshot") != nil || d.object(forKey: "demoScreen") != nil { return false }
        #endif
        return true
    }()

    private static let key = "openWindows"
    private var records: [SavedWindow]
    /// The first window has come up (the launch's own decisions are made).
    private var launched = false
    private var terminating = false
    private var scenes: [ObjectIdentifier: String] = [:]
    private var geometry: [String: NSKeyValueObservation] = [:]
    private var framesApplied: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private weak var app: AppModel?

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        records = data.flatMap { try? JSONDecoder().decode([SavedWindow].self, from: $0) } ?? []
        records.removeAll { $0.mini == true }
        guard Self.enabled else { return }
        debugLog("[windows] saved at last quit: \(Self.describe(records))")
        let center = NotificationCenter.default
        for name in [UIApplication.willTerminateNotification, Notification.Name("NSApplicationWillTerminateNotification")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowMemory.shared.appWillTerminate() }
            }
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let scene = note.object as? UIScene
            MainActor.assumeIsolated {
                if let scene { WindowMemory.shared.sceneDisconnected(scene) }
            }
        }
    }

    // MARK: a window comes up

    /// Which entry a window that just came up is: the one it was reopened
    /// for, the one the system restored it as (`sceneID`, its scene storage),
    /// at launch the first one (the others then open again through `open`),
    /// else a new one. Returns the entry to apply (nil: a new window).
    func attach(_ model: WindowModel, target: WindowTarget?, sceneID: String,
                open: @escaping (WindowTarget) -> Void) -> SavedWindow? {
        let first = !launched
        launched = true
        app = model.app
        if first {
            // Whatever the system didn't bring back itself (it may restore
            // only some) opens again a moment later; then the list is only
            // the windows on screen.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.reopen(self.missing(), open: open)
            }
            schedulePrune()
        }
        var found: SavedWindow?
        var others: [SavedWindow] = []
        if let id = target?.restore {
            found = records.first { $0.id == id }
        } else if !sceneID.isEmpty, let r = records.first(where: { $0.id == sceneID }) {
            found = r
        } else if first, target == nil, let r = records.first {
            // The system restored nothing: this window is the first of the
            // last session, and the rest open again.
            found = r
            others = Array(records.dropFirst())
        }
        // The same entry on screen twice (the system restored it, and it was
        // also asked for again): the second one starts fresh.
        var duplicate = false
        if let r = found, Set(model.app.windows.map(\.windowID)).contains(r.id) {
            found = nil
            duplicate = true
        }
        if let r = found {
            model.windowID = r.id
            debugLog("[windows] window takes \(Self.describe([r]))")
        } else {
            model.windowID = duplicate ? UUID().uuidString : target?.restore ?? UUID().uuidString
            debugLog("[windows] new window \(model.windowID.prefix(8))")
        }
        update(model)
        reopen(others, open: open)
        return found
    }

    /// Ids already asked to open again.
    private var reopening: Set<String> = []

    private func missing() -> [SavedWindow] {
        let live = Set(app?.windows.map(\.windowID) ?? [])
        return records.filter { !live.contains($0.id) && !reopening.contains($0.id) }
    }

    private func reopen(_ list: [SavedWindow], open: @escaping (WindowTarget) -> Void) {
        let list = list.filter { !reopening.contains($0.id) }
        guard !list.isEmpty else { return }
        reopening.formUnion(list.map(\.id))
        Task { @MainActor in
            for r in list {
                try? await Task.sleep(for: .milliseconds(250))
                debugLog("[windows] reopening \(Self.describe([r]))")
                open(WindowTarget(restoring: r))
            }
        }
    }

    /// The window's scene is known: its frame is followed from now on, and a
    /// restored one goes back where it was.
    func sceneReady(_ model: WindowModel, _ scene: UIWindowScene) {
        guard Self.enabled, !model.windowID.isEmpty else { return }
        let id = model.windowID
        scenes[ObjectIdentifier(scene)] = id
        if !framesApplied.contains(id) {
            framesApplied.insert(id)
            let saved = records.first { $0.id == id }?.systemFrame
            if let frame = saved {
                // The window must be up first; an early request is sometimes dropped.
                Task { @MainActor in
                    for _ in 0..<3 {
                        scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { debugLog("[windows] frame refused: \($0)") }
                        try? await Task.sleep(for: .milliseconds(400))
                        if Self.close(scene.frameOnScreen, frame) { break }
                    }
                    debugLog("[windows] \(id.prefix(8)) frame \(Self.describe(frame)) → \(Self.describe(scene.frameOnScreen))")
                    self.follow(scene, id: id)
                }
                return
            }
        }
        follow(scene, id: id)
    }

    private func follow(_ scene: UIWindowScene, id: String) {
        guard geometry[id] == nil else { return }
        geometry[id] = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { scene, _ in
            nonisolated(unsafe) let scene = scene
            MainActor.assumeIsolated {
                WindowMemory.shared.setFrame(scene.frameOnScreen, for: id)
            }
        }
    }

    // MARK: in step with the windows

    /// What the window shows now (its conversation, computer, sidebar).
    func update(_ model: WindowModel) {
        guard Self.enabled, !model.windowID.isEmpty, !terminating else { return }
        var r = records.first { $0.id == model.windowID } ?? SavedWindow(id: model.windowID, conversation: "palo")
        r.conversation = (model.selection ?? .palo).storageKey
        r.host = model.activeHostID
        if model.layout == .split { r.sidebarCollapsed = model.columnVisibility == .detailOnly }
        r.paneOpen = model.paneOpenHere.isEmpty ? nil : model.paneOpenHere
        if let i = records.firstIndex(where: { $0.id == r.id }) {
            guard records[i] != r else { return }
            records[i] = r
        } else {
            records.append(r)
        }
        scheduleSave()
    }

    private func setFrame(_ frame: CGRect, for id: String) {
        guard !terminating, frame.width > 100, frame.height > 100,
              let i = records.firstIndex(where: { $0.id == id }) else { return }
        let f = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0.rounded()) }
        guard records[i].frame != f else { return }
        records[i].frame = f
        scheduleSave()
    }

    /// A window closed by hand goes off the list; quitting closes them all
    /// and keeps them. Which one it was shows a moment later: after a quit
    /// the app is gone by then (Catalyst disconnects every scene first, and
    /// may exit without a will-terminate notification).
    private func sceneDisconnected(_ scene: UIScene) {
        guard let id = scenes.removeValue(forKey: ObjectIdentifier(scene)) else { return }
        geometry.removeValue(forKey: id)?.invalidate()
        debugLog("[windows] \(id.prefix(8)) disconnected\(terminating ? " (quitting)" : "")")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !self.terminating else { return }
            self.records.removeAll { $0.id == id }
            debugLog("[windows] \(id.prefix(8)) closed by hand: \(Self.describe(self.records))")
            self.save()
        }
    }

    private func appWillTerminate() {
        guard !terminating else { return }
        save()
        terminating = true
        debugLog("[windows] quitting with \(Self.describe(records))")
    }

    /// Entries the launch didn't bring back (the system restored only some,
    /// or a window failed to open) don't wait for the next one.
    private func schedulePrune() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            let live = Set(app?.windows.map(\.windowID) ?? [])
            guard !live.isEmpty else { return }
            let before = records.count
            records.removeAll { !live.contains($0.id) }
            if records.count != before {
                debugLog("[windows] dropped \(before - records.count) not reopened")
                save()
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    private func save() {
        saveTask?.cancel()
        guard !terminating else { return }
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: Self.key) }
        debugLog("[windows] saved \(Self.describe(records))")
    }

    // MARK: log lines

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private static func describe(_ f: CGRect) -> String {
        "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
    }

    private static func describe(_ list: [SavedWindow]) -> String {
        guard !list.isEmpty else { return "none" }
        return list.map { r in
            "\(r.id.prefix(8)) \(r.conversation) host \(r.host ?? "-") sidebar \(r.sidebarCollapsed.map { $0 ? "away" : "shown" } ?? "-")"
                + "\(r.systemFrame.map { " frame " + describe($0) } ?? "")"
        }.joined(separator: "; ")
    }
}

extension UIWindowScene {
    /// The Mac: the window's frame on screen; elsewhere zero (unused).
    var frameOnScreen: CGRect {
        #if targetEnvironment(macCatalyst)
        effectiveGeometry.systemFrame
        #else
        .zero
        #endif
    }
}
