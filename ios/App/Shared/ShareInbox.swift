import Foundation

/// Files, pictures, links and words shared into PaloAlly from another app's
/// share sheet (the PaloAllyShare extension), handed to the app through the
/// App Group container. Compiled into both the app and the extension.
///
/// - `Share/targets.json`: where a share can go (Palo, then the recent
///   sessions), written by the app whenever it goes to the background or its
///   lists change, read by the extension's 「发给谁」.
/// - `Share/Inbox/<id>/`: one share: its files and `manifest.json`, written
///   last, so the app only takes complete ones. The app takes them when it
///   becomes active (and on `paloally://share/<id>`), stages them in the
///   chosen conversation's composer and removes the folder.
enum ShareInbox {
    static let group = "group.com.novashang.paloally"
    /// The composer's limits: at most this many attachments, each at most `maxFileBytes`.
    static let maxItems = 6
    static let maxFileBytes = 100 * 1024 * 1024

    /// Somewhere a share can go.
    struct Target: Codable, Hashable, Identifiable {
        /// The computer (its daemon id); nil: the one used last.
        var host: String?
        /// The conversation, as a window stores it: `palo` or `pal:<id>`.
        var key: String
        var name: String
        /// The computer's name, when there are several.
        var detail: String?
        var id: String { "\(host ?? "")|\(key)" }
    }

    struct Manifest: Codable {
        struct File: Codable {
            /// The file's name in the share's folder (also what it's called in the message).
            var name: String
        }
        var id: String
        var host: String?
        var key: String
        var text: String
        var files: [File]
        var created: Date
    }

    static var root: URL? {
        // The Mac without the extension in this build: never touch the group
        // (macOS asks the owner about a container the app isn't entitled to).
        #if targetEnvironment(macCatalyst)
        guard Bundle.main.bundleURL.pathExtension == "appex"
            || FileManager.default.fileExists(atPath: Bundle.main.builtInPlugInsURL?.appendingPathComponent("PaloAllyShare.appex").path ?? "")
        else { return nil }
        #endif
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Share", isDirectory: true)
    }
    static var inbox: URL? { root?.appendingPathComponent("Inbox", isDirectory: true) }
    private static var targetsURL: URL? { root?.appendingPathComponent("targets.json") }

    static func writeTargets(_ targets: [Target]) {
        guard let root, let url = targetsURL, let data = try? JSONEncoder().encode(targets) else { return }
        if let old = try? Data(contentsOf: url), old == data { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func readTargets() -> [Target] {
        guard let url = targetsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Target].self, from: data)) ?? []
    }

    /// A new share's folder (the extension copies its files in, then `commit`s).
    static func newShareFolder() -> (id: String, url: URL)? {
        guard let inbox else { return nil }
        let id = UUID().uuidString
        let url = inbox.appendingPathComponent(id, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { return nil }
        return (id, url)
    }

    static func commit(_ manifest: Manifest, in folder: URL) -> Bool {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(manifest) else { return false }
        return (try? data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)) != nil
    }

    /// Complete shares waiting for the app, oldest first, with their folders.
    /// Folders without a manifest older than a day (an extension that died
    /// half-way) are removed.
    static func pending() -> [(manifest: Manifest, folder: URL)] {
        guard let inbox, let dirs = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [(Manifest, URL)] = []
        for dir in dirs {
            let m = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: m), let manifest = try? dec.decode(Manifest.self, from: data) {
                out.append((manifest, dir))
            } else if let made = try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      made < Date().addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        return out.sorted { $0.0.created < $1.0.created }
    }

    static func remove(_ folder: URL) { try? FileManager.default.removeItem(at: folder) }

    /// `paloally://share/<id>`: opens the app on that share.
    static func link(_ id: String) -> URL? { URL(string: "paloally://share/\(id)") }
    static func isShareLink(_ url: URL) -> Bool { url.host() == "share" }
}
