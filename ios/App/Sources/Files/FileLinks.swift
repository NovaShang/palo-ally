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
/// the asks in flight, batched a moment so one reply is one request.
@MainActor
final class FileLinkResolver {
    enum Lookup: Equatable {
        case file(ResolvedFile)
        case missing
        case unknown
    }

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
    private var known: [FileScope: [String: ResolvedFile?]] = [:]
    private var asked: [FileScope: Set<String>] = [:]
    private var waiting: [FileScope: [() -> Void]] = [:]
    private var flush: Task<Void, Never>?

    private init(store: AppStore) { self.store = store }

    func lookup(_ scope: FileScope, _ path: String) -> Lookup {
        guard let entry = known[scope]?[path] else { return .unknown }
        return entry.map(Lookup.file) ?? .missing
    }

    /// Ask about `paths`; `then` runs once they're known (or the ask failed: missing).
    func resolve(_ scope: FileScope, _ paths: [String], then: @escaping () -> Void) {
        let new = paths.filter { known[scope]?[$0] == nil }
        guard !new.isEmpty else { return }
        asked[scope, default: []].formUnion(new)
        waiting[scope, default: []].append(then)
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            await self?.send()
        }
    }

    private func send() async {
        flush = nil
        let batches = asked
        let callbacks = waiting
        asked = [:]
        waiting = [:]
        for (scope, set) in batches {
            let paths = Array(set)
            var found: [ResolvedFile] = []
            for chunk in stride(from: 0, to: paths.count, by: 40).map({ Array(paths[$0..<min($0 + 40, paths.count)]) }) {
                if let r = try? await store?.resolveFiles(scope, paths: chunk) { found += r }
            }
            var table = known[scope] ?? [:]
            for p in paths { table[p] = .some(nil) }
            for f in found { table[f.text] = f }
            known[scope] = table
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
        ]
        return c.url
    }

    static func isFileLink(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

    /// What a tapped file link does: the file, over the conversation.
    @MainActor static func action(for url: URL) -> UIAction? {
        guard isFileLink(url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let kind = FileScope.Kind(rawValue: q["k"] ?? ""), let path = q["p"], !path.isEmpty,
              let store = FileLinkResolver.find(q["r"] ?? "")?.store else { return nil }
        let target = FileTarget(scope: FileScope(kind: kind, id: q["i"]), path: path)
        return UIAction { _ in FilePagePresenter.present(target, store: store) }
    }
}

extension MarkdownTextView {
    /// Links the paths in the text that are files on the computer. Runs after
    /// every render (attributes only: the layout doesn't change), and again
    /// once the computer has answered about paths it hadn't seen.
    func applyFileLinks() {
        // Nothing while a reply is being written: links work once it's finished.
        guard let ctx = fileLinks, !isWriting else { return }
        let storage = textStorage
        guard storage.length > 0, storage.length < 200_000 else { return }
        let candidates = PathDetector.candidates(in: storage.string)
        guard !candidates.isEmpty else { return }
        var unknown: [String] = []
        var links: [(NSRange, URL)] = []
        for c in candidates {
            // A link the reply already has (a URL, Markdown) wins.
            if let existing = storage.attribute(.link, at: c.range.location, effectiveRange: nil) {
                let url = (existing as? URL) ?? (existing as? String).flatMap(URL.init(string:))
                if url.map(FileLinks.isFileLink) != true { continue }
            }
            switch ctx.resolver.lookup(ctx.scope, c.path) {
            case .file(let f): if let url = FileLinks.url(ctx, f) { links.append((c.range, url)) }
            case .missing: break
            case .unknown: unknown.append(c.path)
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
