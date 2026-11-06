import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI
import UIKit

// Paths in the assistant's and a Pal's replies become links (docs/files-prd.md,
// entry 2): PathDetector finds them in the laid-out text, the computer says
// which are files (`files.resolve`, relative ones against the Pal's folder, or
// the assistant's home and artifacts), and only those get a link. The rest
// stay plain text. A tapped one opens the file over the conversation.

/// Which files a reply's paths may be: the conversation's scope, and who resolves them.
struct FileLinkContext: Equatable {
    let scope: FileScope
    let resolver: FileLinkResolver

    static func == (a: FileLinkContext, b: FileLinkContext) -> Bool {
        a.scope == b.scope && a.resolver === b.resolver
    }
}

extension EnvironmentValues {
    /// Set in the assistant's and the Pals' conversations only.
    @Entry var fileLinks: FileLinkContext? = nil
}

/// What the computer said about the paths seen so far (per assistant), and
/// the asks in flight, batched a moment so one reply is one request. Only
/// an answer counts (`FileResolveCache`): an ask that failed (the link to
/// the computer down a moment) is tried again a little later, and so are
/// the paths it had no time to look for; once they're known, the text
/// views that asked link them.
@MainActor
final class FileLinkResolver {
    typealias Lookup = FileResolveCache.Lookup

    private static var byStore: [ObjectIdentifier: FileLinkResolver] = [:]
    private static var byID: [String: FileLinkResolver] = [:]

    static func shared(for store: AppStore) -> FileLinkResolver {
        if let r = byStore[ObjectIdentifier(store)], r.store != nil { return r }
        let r = FileLinkResolver(store: store)
        byStore[ObjectIdentifier(store)] = r
        byID[r.id] = r
        return r
    }

    static func find(_ id: String) -> FileLinkResolver? { byID[id] }

    let id = UUID().uuidString
    private(set) weak var store: AppStore?
    private var cache = FileResolveCache()
    private var asked: [FileScope: [String]] = [:]
    private var waiting: [FileScope: [() -> Void]] = [:]
    private var flush: Task<Void, Never>?
    /// Asks that failed in a row: the next waits longer (1, 2, 4 … 30 s).
    private var failures = 0

    private init(store: AppStore) { self.store = store }

    func lookup(_ scope: FileScope, _ path: String) -> Lookup {
        cache.lookup(scope, path)
    }

    /// Ask about `paths`; `then` runs once the computer has answered (and
    /// again after a retry, for the paths still not known).
    func resolve(_ scope: FileScope, _ paths: [String], then: @escaping () -> Void) {
        let new = cache.unknown(scope, paths)
        guard !new.isEmpty else { return }
        var list = asked[scope] ?? []
        list += new.filter { !list.contains($0) }
        asked[scope] = list
        waiting[scope, default: []].append(then)
        guard flush == nil else { return }
        let delay: Duration = failures == 0 ? .milliseconds(60) : .seconds(min(30, 1 << min(failures - 1, 5)))
        flush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.send()
        }
    }

    private func send() async {
        flush = nil
        let batches = asked
        let callbacks = waiting
        asked = [:]
        waiting = [:]
        for (scope, paths) in batches {
            var failed = false
            for chunk in stride(from: 0, to: paths.count, by: 40).map({ Array(paths[$0..<min($0 + 40, paths.count)]) }) {
                guard let store else { return }
                do {
                    cache.answered(scope, asked: chunk, try await store.resolveFiles(scope, paths: chunk))
                } catch {
                    cache.failed(scope, asked: chunk)
                    failed = true
                }
            }
            failures = failed ? failures + 1 : 0
            #if DEBUG
            let linked = paths.filter { if case .file = cache.lookup(scope, $0) { true } else { false } }.count
            debugLog("[filelinks] \(scope.kind.rawValue): asked \(paths.count), \(linked) files\(failed ? ", failed (try \(failures))" : "")")
            #endif
            // Each view links what is known now and asks again for the rest.
            for cb in callbacks[scope] ?? [] { cb() }
        }
    }
}

/// The links themselves: `paloally-file://open?r=<resolver>&k=<kind>&i=<id>&p=<path>`,
/// never handed to the system (the text view's tap goes to `action`).
enum FileLinks {
    static let scheme = "paloally-file"

    static func url(_ ctx: FileLinkContext, _ file: ResolvedFile) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        c.queryItems = [
            URLQueryItem(name: "r", value: ctx.resolver.id),
            URLQueryItem(name: "k", value: ctx.scope.kind.rawValue),
            URLQueryItem(name: "i", value: ctx.scope.id ?? ""),
            URLQueryItem(name: "p", value: file.path),
        ] + (file.abs.map { [URLQueryItem(name: "a", value: $0)] } ?? [])
        return c.url
    }

    static func isFileLink(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

    /// What a tapped file link does: the file, over the conversation.
    @MainActor static func action(for url: URL) -> UIAction? {
        guard isFileLink(url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let kind = FileScope.Kind(rawValue: q["k"] ?? ""), let path = q["p"], !path.isEmpty,
              let store = FileLinkResolver.find(q["r"] ?? "")?.store else { return nil }
        let target = FileTarget(scope: FileScope(kind: kind, id: q["i"]), path: path, absolute: q["a"].flatMap { $0.hasPrefix("/") ? $0 : nil })
        #if DEBUG
        debugLog("[filelinks] open \(kind.rawValue) \(path)")
        #endif
        return UIAction { _ in FilePagePresenter.present(target, store: store) }
    }
}

extension MarkdownTextView {
    /// Links the paths in the text that are files on the computer. Runs after
    /// every render (attributes only: the layout doesn't change), and again
    /// once the computer has answered about paths it hadn't seen. What's
    /// looked at: the text, its code spans (a path with spaces is whole in
    /// one) and its Markdown links to a path (Claude Code's
    /// `[ListPage.tsx:12](src/pages/ListPage.tsx#L12)`), which become file
    /// links when the computer has the file. Web links stay as they are.
    func applyFileLinks() {
        // Nothing while a reply is being written: links work once it's finished.
        guard let ctx = fileLinks, !isWriting else { return }
        let storage = textStorage
        guard storage.length > 0, storage.length < 200_000 else { return }
        let all = NSRange(location: 0, length: storage.length)
        var code: [NSRange] = []
        storage.enumerateAttribute(.paloCode, in: all) { value, range, _ in
            if value != nil { code.append(range) }
        }
        var pathLinks: [(range: NSRange, url: URL)] = []
        var webLinks: [NSRange] = []
        storage.enumerateAttribute(.link, in: all) { value, range, _ in
            guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
            if FileLinks.isFileLink(url) { return }
            if PathDetector.linkedPath(url) != nil { pathLinks.append((range, url)) } else { webLinks.append(range) }
        }
        let guesses = PathDetector.guesses(in: storage.string, codeSpans: code, links: pathLinks)
        guard !guesses.isEmpty else { return }
        var unknown: [String] = []
        var links: [(NSRange, URL)] = []
        for g in guesses {
            // A web link the reply already has wins.
            if webLinks.contains(where: { NSIntersectionRange($0, g.range).length > 0 }) { continue }
            var linked = false
            for r in g.readings {
                switch ctx.resolver.lookup(ctx.scope, r.path) {
                case .file(let f):
                    // The first reading that's a file (one before it still unknown
                    // takes over when it turns out to be one).
                    if !linked, let url = FileLinks.url(ctx, f) { links.append((r.range, url)) }
                    linked = true
                case .missing: break
                case .unknown: if !linked { unknown.append(r.path) }
                }
            }
        }
        if !links.isEmpty {
            storage.beginEditing()
            for (range, url) in links where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.link, value: url, range: range)
            }
            storage.endEditing()
        }
        if !unknown.isEmpty {
            ctx.resolver.resolve(ctx.scope, unknown) { [weak self] in self?.applyFileLinks() }
        }
    }
}
