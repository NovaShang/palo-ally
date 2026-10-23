import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// PaloAlly in the system share sheet: 「发给谁」 (Palo, then the recent
/// sessions, as the app last wrote them), an optional note, and 发送. What
/// was shared is copied into the App Group (`ShareInbox`); the app then opens
/// on that conversation with it staged in the composer, to send with one tap.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        model.finish = { [weak self] link in self?.finish(opening: link) }
        let host = UIHostingController(rootView: ShareSheet(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Done: the app opened on the share (where the system lets an extension
    /// open it), then the sheet goes. Cancelled: `link` is nil.
    private func finish(opening link: URL?) {
        guard let link else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }
        openApp(link)
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// An extension has no `UIApplication.shared`; the application is still
    /// up the responder chain, and opening the app's own link through it is
    /// what share extensions do. Where it isn't (or refuses), the app takes
    /// the share the next time it comes up.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
    }
}

@MainActor @Observable
final class ShareModel {
    var targets: [ShareInbox.Target] = []
    var selected: ShareInbox.Target?
    var note = ""
    /// What came in: files and pictures to copy, links and words for the text.
    var files: [(NSItemProvider, UTType)] = []
    var texts: [String] = []
    var sending = false
    var problem: String?
    @ObservationIgnored var finish: (URL?) -> Void = { _ in }

    func load(_ items: [NSExtensionItem]) {
        targets = ShareInbox.readTargets()
        if targets.isEmpty { targets = [ShareInbox.Target(host: nil, key: "palo", name: "Palo")] }
        selected = targets.first
        for item in items {
            for p in item.attachments ?? [] {
                let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
                if let file = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .pdf) })
                    ?? types.first(where: { $0.conforms(to: .fileURL) })
                    ?? types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }) {
                    if files.count < ShareInbox.maxItems { files.append((p, file)) }
                } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    load(p, UTType.url) { [weak self] value in
                        if let url = value as? URL ?? (value as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) {
                            self?.texts.append(url.absoluteString)
                        }
                    }
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    load(p, UTType.plainText) { [weak self] value in
                        if let s = value as? String ?? (value as? Data).flatMap({ String(data: $0, encoding: .utf8) }), !s.isEmpty {
                            self?.texts.append(s)
                        }
                    }
                }
            }
        }
    }

    private func load(_ p: NSItemProvider, _ type: UTType, _ done: @escaping @MainActor (Any?) -> Void) {
        p.loadItem(forTypeIdentifier: type.identifier) { value, _ in
            nonisolated(unsafe) let value = value
            Task { @MainActor in done(value) }
        }
    }

    var summary: String {
        var parts: [String] = []
        let pictures = files.filter { $0.1.conforms(to: .image) }.count
        let others = files.count - pictures
        if pictures > 0 { parts.append(String(localized: "\(pictures) 张图片")) }
        if others > 0 { parts.append(String(localized: "\(others) 个文件")) }
        if !texts.isEmpty { parts.append(String(localized: "\(texts.count) 段文字或链接")) }
        return parts.joined(separator: " · ")
    }

    func send() {
        guard let target = selected, !sending else { return }
        sending = true
        let files = files
        let text = (texts + [note.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "\n")
        Task {
            guard let (id, folder) = ShareInbox.newShareFolder() else {
                problem = String(localized: "先打开一次 PaloAlly 再分享")
                sending = false
                return
            }
            var names: [ShareInbox.Manifest.File] = []
            var skipped = false
            for (p, type) in files {
                if let name = await Self.copy(p, type, into: folder, taken: Set(names.map(\.name))) {
                    names.append(.init(name: name))
                } else {
                    skipped = true
                }
            }
            let manifest = ShareInbox.Manifest(id: id, host: target.host, key: target.key, text: text,
                                               files: names, created: Date())
            guard ShareInbox.commit(manifest, in: folder) else {
                ShareInbox.remove(folder)
                problem = String(localized: "没存下来，再试一次")
                sending = false
                return
            }
            if skipped && names.isEmpty && text.isEmpty {
                ShareInbox.remove(folder)
                problem = String(localized: "文件读不了，或者太大（最多 100MB）")
                sending = false
                return
            }
            finish(ShareInbox.link(id))
        }
    }

    /// Copies one shared thing into the share's folder under its own name;
    /// nil when it can't be read or is over the composer's limit.
    private static func copy(_ p: NSItemProvider, _ type: UTType, into folder: URL, taken: Set<String>) async -> String? {
        let fallbackExt = type.preferredFilenameExtension ?? "dat"
        let suggested = p.suggestedName.map { n in n.contains(".") ? n : "\(n).\(fallbackExt)" }
        // A file (by far the common case): copied by the system, never read into memory.
        let viaFile: String? = await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return c.resume(returning: nil) }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= ShareInbox.maxFileBytes else { return c.resume(returning: nil) }
                let name = unique(url.lastPathComponent, taken)
                let ok = (try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))) != nil
                c.resume(returning: ok ? name : nil)
            }
        }
        if let viaFile { return viaFile }
        // Something held in memory (a screenshot, an edited photo).
        let data: Data? = await withCheckedContinuation { c in
            _ = p.loadDataRepresentation(forTypeIdentifier: type.identifier) { d, _ in c.resume(returning: d) }
        }
        var bytes = data
        if bytes == nil, type.conforms(to: .image) {
            bytes = await withCheckedContinuation { c in
                p.loadItem(forTypeIdentifier: type.identifier) { v, _ in c.resume(returning: (v as? UIImage)?.pngData()) }
            }
        }
        guard let bytes, bytes.count <= ShareInbox.maxFileBytes else { return nil }
        let ext = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : fallbackExt
        let name = unique(suggested ?? "\(String(localized: "分享"))-\(Int(Date().timeIntervalSince1970)).\(ext)", taken)
        return (try? bytes.write(to: folder.appendingPathComponent(name))) != nil ? name : nil
    }

    private nonisolated static func unique(_ name: String, _ taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var i = 2
        while taken.contains(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)") { i += 1 }
        return ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
    }
}

struct ShareSheet: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if !model.summary.isEmpty {
                    Section { Label(model.summary, systemImage: "paperclip").foregroundStyle(.secondary) }
                }
                Section("发给谁") {
                    ForEach(model.targets) { t in
                        Button { model.selected = t } label: {
                            HStack {
                                Image(systemName: t.key == "palo" ? "sparkles" : "circle.fill")
                                    .font(t.key == "palo" ? .body : .system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.name).foregroundStyle(.primary).lineLimit(1)
                                    if let d = t.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if model.selected == t { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section {
                    TextField("说点什么（可选）", text: $model.note, axis: .vertical).lineLimit(1...5)
                } footer: {
                    if let p = model.problem { Text(p).foregroundStyle(.red) }
                    else { Text("会放进 PaloAlly 的输入框，你看过再发。") }
                }
            }
            .navigationTitle("PaloAlly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.sending { ProgressView() }
                    else { Button("发送") { model.send() }.disabled(model.selected == nil) }
                }
            }
        }
    }
}
