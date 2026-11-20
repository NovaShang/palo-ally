import AVKit
import CryptoKit
import Network
import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI
import UIKit

// Opening a file from the computer, the same way from every place that opens
// one (docs/large-files-design.md): 成果, the file page, a file sent in a
// conversation, a workspace's document card. `RemoteFileView` downloads it
// to the device's disk through the one downloader (preparing → downloading
// with 12.3 / 27.0 MB and 取消 → shown; a failure retries from the bytes
// already there), and `LocalFilePreview` shows it from that file, chosen by
// one classifier (`PreviewKind`), never with the whole file in memory.

/// Whether the network costs (cellular, a hotspot): a big download asks first.
@MainActor
final class NetworkCost {
    static let shared = NetworkCost()
    private(set) var isExpensive = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive
            Task { @MainActor in NetworkCost.shared.isExpensive = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "paloally.network-cost"))
    }

    /// Over this, on a network that costs, a download asks first.
    static let askAbove: Int64 = 50 * 1024 * 1024
}

/// "12.3 / 27.0 MB".
enum DownloadText {
    static func megabytes(_ n: Int64) -> String { String(format: "%.1f", Double(n) / 1_000_000) }

    static func progress(_ got: Int64, _ total: Int64) -> String {
        total > 0 ? "\(megabytes(got)) / \(megabytes(total)) MB" : "\(megabytes(got)) MB"
    }
}

// MARK: - downloading

/// A file on the computer, downloaded to the device (or found in its cache)
/// and then shown by `content`. A file already shown stays while a newer
/// version of it comes (a live library item, a file changed on the computer).
struct RemoteFileView<Content: View>: View {
    @Environment(AppStore.self) private var store
    let source: RemoteFileSource
    let name: String
    /// The size when known beforehand (a library item's, a sent file's).
    var size: Int64? = nil
    /// The version when known beforehand (a library item's: its time and size).
    var version: String? = nil
    /// Bumped to ask the computer again (the file page following the file).
    var refresh: Int = 0
    @ViewBuilder var content: (URL) -> Content

    private enum Phase: Equatable {
        case preparing
        case asking(Int64)
        case downloading(Int64, Int64)
        case stopped
        case failed(String)
        case done
    }

    @State private var phase = Phase.preparing
    @State private var shown: URL?
    @State private var shownFor: RemoteFileSource?
    /// The owner said yes to a download over a network that costs.
    @State private var allowedExpensive = false
    /// 取消 pressed: the download stops (what came stays on disk for 继续).
    @State private var stopped = false
    @State private var attempt = 0

    private struct Key: Hashable {
        let source: RemoteFileSource
        let version: String?
        let refresh: Int
        let attempt: Int
        let stopped: Bool
    }

    var body: some View {
        Group {
            if let shown {
                content(shown)
                    .overlay(alignment: .bottom) { updatingCapsule }
            } else {
                placeholder
            }
        }
        .task(id: Key(source: source, version: version, refresh: refresh, attempt: attempt, stopped: stopped)) { await run() }
    }

    @ViewBuilder private var updatingCapsule: some View {
        if case .downloading(let got, let total) = phase, total > 0 {
            (Text("正在更新", tableName: "Files") + Text(verbatim: " \(Int(Double(got) / Double(total) * 100))%"))
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(verbatim: name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if let size, size > 0 {
                    Text(verbatim: Copy.byteSize(size)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            switch phase {
            case .preparing, .done:
                ProgressView().controlSize(.regular)
            case .downloading(let got, let total):
                VStack(spacing: 8) {
                    ProgressView(value: total > 0 ? min(1, Double(got) / Double(total)) : 0)
                        .frame(maxWidth: 260)
                    Text(verbatim: DownloadText.progress(got, total))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("download-progress")
                }
                Button { stopped = true } label: { Text("取消", tableName: "Files") }
                    .buttonStyle(.glass)
                    .tint(.primary)
                    .accessibilityIdentifier("download-cancel")
            case .asking(let bytes):
                Text("这个文件 \(DownloadText.megabytes(bytes)) MB，用移动网络下载吗？", tableName: "Files")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { stopped = true } label: { Text("取消", tableName: "Files") }
                        .buttonStyle(.glass)
                        .tint(.primary)
                    Button { allowedExpensive = true; attempt += 1 } label: { Text("下载", tableName: "Files") }
                        .buttonStyle(.glassProminent)
                }
            case .stopped:
                Text("已停止下载", tableName: "Files").font(.subheadline).foregroundStyle(.secondary)
                Button { allowedExpensive = true; stopped = false } label: { Text("继续下载", tableName: "Files") }
                    .buttonStyle(.glass)
                    .tint(.primary)
                    .accessibilityIdentifier("download-resume")
            case .failed(let why):
                Text(verbatim: why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { attempt += 1 } label: { Text("再试一次", tableName: "Files") }
                    .buttonStyle(.glass)
                    .tint(.primary)
                    .accessibilityIdentifier("download-retry")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch PreviewKind.classify(name: name) {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .office: "doc.text"
        default: "doc"
        }
    }

    private func run() async {
        if shownFor != source {
            shown = nil
            shownFor = source
        }
        if stopped {
            if shown == nil { phase = .stopped }
            return
        }
        let began = Date()
        // In the cache in this version: at once, nothing asked.
        if let url = store.cachedFile(source, name: name, version: version) {
            shown = url
            phase = .done
            debugLog("[files] \(name): opened from the cache in \(Int(Date().timeIntervalSince(began) * 1000)) ms, nothing downloaded")
            return
        }
        var size = size
        var version = version
        do {
            if case .file(let scope, let path) = source {
                // A copy kept from before: shown at once while the computer
                // says whether it changed.
                if shown == nil, let latest = store.latestCachedFile(source) {
                    shown = latest.url
                    debugLog("[files] \(name): showing the kept copy while asking for its version")
                }
                if shown == nil { phase = .preparing }
                let info = try await store.probeFile(scope, path: path)
                if let url = store.cachedFile(source, name: name, version: info.version) {
                    shown = url
                    phase = .done
                    debugLog("[files] \(name): unchanged, opened from the cache in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
                    return
                }
                size = info.size
                version = info.version
            }
            if let bytes = size, bytes > NetworkCost.askAbove, NetworkCost.shared.isExpensive, !allowedExpensive {
                phase = .asking(bytes)
                return
            }
            phase = .downloading(0, size ?? 0)
            let url = try await store.downloadFile(source, name: name, size: size, version: version) { got, total in
                if case .downloading = phase { phase = .downloading(got, total) }
            }
            try Task.checkCancellation()
            shown = url
            phase = .done
            debugLog("[files] \(name): downloaded and opened in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        } catch is CancellationError {
            if stopped, shown == nil { phase = .stopped }
        } catch is FileStreamTooLarge {
            phase = .failed(String(localized: "电脑上的 PaloAlly 版本较旧，发不了这么大的文件。更新它以后再试。", table: "Files"))
        } catch {
            guard !Task.isCancelled else { return }
            debugLog("[files] \(name): download failed: \(error)")
            if shown == nil { phase = .failed(Copy.error(error)) } else { phase = .done }
        }
    }
}

// MARK: - showing a file from the device's disk

/// A file on the device, shown by its kind: Markdown and text in the web
/// renderer (the start of a text over 1 MB only), web pages sandboxed, PDFs
/// in PDFKit, pictures decoded at the size shown, videos and sound in the
/// system's player, Office documents in AppKit's previewer on the Mac, the rest in
/// Quick Look. All from the file's URL.
struct LocalFilePreview: View {
    let url: URL
    let kind: PreviewKind
    /// The file's name (decides highlighting).
    let name: String
    var revision: Int64 = 0
    /// Markdown or a web page as its source text.
    var raw = false
    /// The text already read (the file page's, or its unsaved edit).
    var text: String? = nil
    var imageSource: FilePreviewWebView.ImageSource? = nil
    /// The web page's own sandbox (a library item's id; a file's path otherwise).
    var sandbox: String = ""

    /// Over this, a text shows its start only.
    nonisolated static let textWhole: Int64 = 1024 * 1024
    nonisolated static let textHead = 256 * 1024
    /// Over this, a web page loads from its file instead of from a string.
    nonisolated static let htmlInline: Int64 = 5 * 1024 * 1024

    struct Loaded: Equatable {
        let key: String
        let text: String
        let head: Bool
    }
    @State private var loaded: Loaded?

    private var key: String { "\(url.path)|\(revision)" }

    var body: some View {
        switch kind {
        case .markdown, .text:
            textBody
        case .html:
            if raw {
                textBody
            } else if fileSize > Self.htmlInline {
                SandboxedHTMLView(html: "", artifactID: sandbox, fileURL: url)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                htmlBody
            }
        case .pdf:
            PDFPreview(url: url, revision: revision)
                .ignoresSafeArea(edges: .bottom)
        case .image:
            ImagePreview(url: url, revision: revision)
                .ignoresSafeArea(edges: .bottom)
        case .video, .audio:
            MediaPlayerView(url: url)
        case .office:
            #if targetEnvironment(macCatalyst)
            OfficeDocumentView(url: url, revision: revision)
                .ignoresSafeArea(edges: .bottom)
            #else
            QuickLookView(url: url, revision: revision)
                .ignoresSafeArea(edges: .bottom)
            #endif
        case .quickLook:
            #if targetEnvironment(macCatalyst)
            EmbeddedPreview(url: url, revision: revision)
                .ignoresSafeArea(edges: .bottom)
            #else
            QuickLookView(url: url, revision: revision)
                .ignoresSafeArea(edges: .bottom)
            #endif
        }
    }

    private var fileSize: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    @ViewBuilder private var textBody: some View {
        Group {
            if let text {
                // Read whole by the file page (up to 5 MB): its start only past 1 MB.
                if text.utf8.count > Self.textWhole {
                    rendered(String(decoding: Data(text.utf8.prefix(Self.textHead)), as: UTF8.self), head: true)
                } else {
                    rendered(text, head: false)
                }
            } else if let loaded, loaded.key == key {
                rendered(loaded.text, head: loaded.head)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) { if text == nil { await load() } }
    }

    @ViewBuilder private func rendered(_ text: String, head: Bool) -> some View {
        if head {
            // The start of a big text: plain (no highlighting), with a note.
            FileTextPreview(fileName: "file.txt", text: text, raw: true)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("文件很大，只显示开头 256 KB", tableName: "Files")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 16)
                        .accessibilityIdentifier("text-head-note")
                }
        } else {
            FileTextPreview(fileName: kind == .markdown ? FilePreviewRoute.markdownRenderName(name) : name,
                            text: text, raw: raw, imageSource: kind == .markdown ? imageSource : nil)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private var htmlBody: some View {
        Group {
            // A new revision keeps the old page up until it's read, so the
            // web view stays and keeps its place (it scrolls back to it).
            if let page = text ?? loaded?.text {
                SandboxedHTMLView(html: page, artifactID: sandbox, images: imageSource)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) { if text == nil { await load(whole: true) } }
    }

    /// The text off the main thread: whole up to 1 MB (a web page up to
    /// 5 MB), else its first 256 KB.
    private func load(whole: Bool = false) async {
        let url = url
        let key = key
        let limit = whole ? Self.htmlInline : Self.textWhole
        let r: Loaded? = await Task.detached(priority: .userInitiated) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            let size = Int64((try? h.seekToEnd()) ?? 0)
            try? h.seek(toOffset: 0)
            let head = size > limit
            guard let data = try? h.read(upToCount: head ? Self.textHead : Int(size)) else { return Loaded(key: key, text: "", head: false) }
            return Loaded(key: key, text: String(decoding: data, as: UTF8.self), head: head)
        }.value
        if let r { loaded = r }
    }
}

/// A video or sound, played from its file by the system's player.
struct MediaPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .task(id: url) {
                let duration = try? await AVURLAsset(url: url).load(.duration)
                debugLog("[files] media: \(url.lastPathComponent), \(duration.map { String(format: "%.1f s", $0.seconds) } ?? "unreadable")")
            }
            .onChange(of: url) { player = AVPlayer(url: url) }
            .onDisappear { player?.pause() }
            .accessibilityIdentifier("media-player")
    }
}

/// An Office or iWork document on the Mac: AppKit's own previewer in the
/// pane (`NativeQuickLookView`), crisp and scrolling, its text selectable.
/// Quick Look embedded by UIKit drew Office files as one still blurred
/// picture (11-12); WebKit on the Mac doesn't open them (it can't show their
/// types: the bytes came out as text), and AppKit's Word reader fails inside
/// the app (Cocoa error 256). Without the AppKit bundle: Quick Look's own
/// window, opened on its own the first time the document shows, again from
/// the button.
struct OfficeDocumentView: View {
    let url: URL
    let revision: Int64
    /// Opened on its own once per file and version.
    @State private var opened: String?
    @Environment(\.documentCard) private var card

    var body: some View {
        #if targetEnvironment(macCatalyst)
        if NativeQuickLookView.available {
            // AppKit's view is drawn over the window: in the right pane it
            // starts below the page's ⋯ (floating at its top corner), which
            // it would cover. A card's ⋯ is in its header.
            NativeQuickLookView(url: url, revision: revision)
                .padding(.top, card == nil ? 52 : 0)
                .background(Color(.systemBackground))
                .task(id: "\(url.path)|\(revision)") {
                    debugLog("[files] office: \(url.lastPathComponent) in the pane (AppKit's previewer)")
                }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(verbatim: url.lastPathComponent).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Button { Self.quickLook(url) } label: { Text("用快速查看打开", tableName: "Files") }
                .buttonStyle(.glass)
                .tint(.primary)
                .accessibilityIdentifier("office-quick-look")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(url.path)|\(revision)") {
            let key = "\(url.path)|\(revision)"
            guard opened != key else { return }
            opened = key
            debugLog("[files] office: \(url.lastPathComponent) in Quick Look")
            Self.quickLook(url)
        }
    }

    static func quickLook(_ url: URL) {
        QuickLookPresenter.present([.init(url: url, title: url.lastPathComponent, artifactID: nil)], startAt: 0, openInLibrary: { _ in })
    }
}

// MARK: - a file opened over the conversation

/// A big file sent in a conversation (or a library item on a phone): its
/// own page over the conversation, downloading with progress, then shown,
/// with 共享 and 关闭.
@MainActor
enum RemoteFilePresenter {
    static func present(source: RemoteFileSource, name: String, size: Int64?, title: String?,
                        store: AppStore, in scene: UIWindowScene? = nil) {
        guard let top = QuickLookPresenter.topController(in: scene) else { return }
        weak var presented: UIViewController?
        let page = NavigationStack {
            RemoteFilePage(source: source, name: name, size: size, title: title ?? name, close: { presented?.dismiss(animated: true) })
        }
        .environment(store)
        let controller = UIHostingController(rootView: AnyView(page))
        #if targetEnvironment(macCatalyst)
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 960, height: 720)
        #else
        controller.modalPresentationStyle = .pageSheet
        #endif
        presented = controller
        top.present(controller, animated: true)
    }
}

struct RemoteFilePage: View {
    @Environment(AppStore.self) private var store
    let source: RemoteFileSource
    let name: String
    let size: Int64?
    let title: String
    let close: () -> Void
    @State private var url: URL?
    @State private var shareTarget: FileShareTarget?

    var body: some View {
        RemoteFileView(source: source, name: name, size: size) { url in
            LocalFilePreview(url: url, kind: PreviewKind.classify(name: name), name: name,
                             sandbox: "file-" + FileCache.hashKey(url.path))
                .onAppear { self.url = url }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .close, action: close)
                    .tint(.primary)
                    .accessibilityLabel(Text("关闭", tableName: "Files"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let url {
                    ShareLink(item: url).tint(.primary)
                } else {
                    Button { shareTarget = FileShareTarget(name: name, size: size, source: .remote(source)) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(.primary)
                    .accessibilityLabel(Text("分享 / 导出"))
                }
            }
        }
        .fileShareSheet(item: $shareTarget)
        .accessibilityIdentifier("remote-file-page")
    }
}

/// 已下载的文件 in Settings: how much the downloaded files take, and 清除.
struct DownloadedFilesRow: View {
    @State private var bytes: Int64?
    @State private var confirming = false

    var body: some View {
        HStack {
            Text("已下载的文件", tableName: "Files")
            Spacer()
            if let bytes {
                Text(verbatim: Copy.byteSize(bytes)).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Button { confirming = true } label: { Text("清除", tableName: "Files") }
                .buttonStyle(.borderless)
                .tint(.primary)
                .disabled((bytes ?? 0) == 0)
                .accessibilityIdentifier("downloaded-files-clear")
        }
        .task { bytes = await AppStore.downloadedFilesBytes() }
        .confirmationDialog(Text("清除已下载的文件？", tableName: "Files"), isPresented: $confirming, titleVisibility: .visible) {
            Button(role: .destructive) {
                Task {
                    await AppStore.clearDownloadedFiles()
                    bytes = await AppStore.downloadedFilesBytes()
                }
            } label: { Text("清除", tableName: "Files") }
        } message: {
            Text("文件还在电脑上，再打开时重新下载。", tableName: "Files")
        }
    }
}
