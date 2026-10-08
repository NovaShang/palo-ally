import QuickLook
import SwiftUI
import UIKit

/// The system previewer, embedded (the library's artifact detail uses it for
/// everything that isn't markdown or a web page).
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    let revision: Int64

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        context.coordinator.url = url
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url || context.coordinator.revision != revision {
            context.coordinator.url = url
            context.coordinator.revision = revision
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL?
        var revision: Int64 = 0

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
        }
    }
}

/// Full-screen system preview for things sent in the conversation: zoom, pan,
/// double-tap, swipe down to close, share / save / markup — all QuickLook's
/// own. Several attachments of one message page left and right.
@MainActor
enum QuickLookPresenter {
    struct Item {
        let url: URL
        let title: String?
        /// Set for library items: offers 「在产出物库中查看」.
        let artifactID: String?
    }

    static func present(_ items: [Item], startAt start: Int, openInLibrary: @escaping (String) -> Void) {
        guard !items.isEmpty, let top = topController() else { return }
        let preview = AttachmentPreviewController(items: items, start: min(max(start, 0), items.count - 1), openInLibrary: openInLibrary)
        #if targetEnvironment(macCatalyst)
        // The Mac: full screen would put the preview's own bar (and its Done)
        // under the window toolbar, leaving no way out. A large sheet with its
        // bar inside it, a visible 关闭, and Esc / ⌘W / ⌘[ to close.
        let nav = MacPreviewNavigationController(rootViewController: preview)
        nav.navigationBar.preferredBehavioralStyle = .pad
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 960, height: 720)
        top.present(nav, animated: true)
        #else
        top.present(preview, animated: true)
        #endif
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// A stable local file for a preview (QuickLook caches by URL): a new
    /// `revision` gets a new path so an updated artifact isn't shown stale.
    static func file(key: String, revision: Int64 = 0, name: String, data: () async throws -> Data) async throws -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent("\(safeKey)-\(revision)", isDirectory: true)
        let safeName = (name as NSString).lastPathComponent.isEmpty ? "file" : (name as NSString).lastPathComponent
        let url = dir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let bytes = try await data()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return url
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String?) { previewItemURL = url; previewItemTitle = title }
}

private final class AttachmentPreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let items: [QuickLookPresenter.Item]
    private let previewItems: [PreviewItem]
    private let openInLibrary: (String) -> Void
    private var libraryButton: UIBarButtonItem?
    private var indexObservation: NSKeyValueObservation?

    init(items: [QuickLookPresenter.Item], start: Int, openInLibrary: @escaping (String) -> Void) {
        self.items = items
        self.previewItems = items.map { PreviewItem(url: $0.url, title: $0.title) }
        self.openInLibrary = openInLibrary
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        currentPreviewItemIndex = start
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard libraryButton == nil, items.contains(where: { $0.artifactID != nil }) else { return }
        let button = UIBarButtonItem(title: "在产出物库中查看", image: UIImage(systemName: "books.vertical"), primaryAction: UIAction { [weak self] _ in
            guard let self, let id = self.items[safe: self.currentPreviewItemIndex]?.artifactID else { return }
            self.dismiss(animated: true) { self.openInLibrary(id) }
        })
        button.accessibilityLabel = "在产出物库中查看"
        libraryButton = button
        navigationItem.leftBarButtonItems = (navigationItem.leftBarButtonItems ?? []) + [button]
        updateLibraryButton()
        indexObservation = observe(\.currentPreviewItemIndex, options: [.new]) { controller, _ in
            MainActor.assumeIsolated { (controller as? AttachmentPreviewController)?.updateLibraryButton() }
        }
    }

    /// Only shown while the current page is a library item.
    private func updateLibraryButton() {
        libraryButton?.isHidden = items[safe: currentPreviewItemIndex]?.artifactID == nil
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewItems.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        updateLibraryButton()
        return previewItems[index]
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

#if targetEnvironment(macCatalyst)
/// The Mac's preview sheet: a 关闭 button in its own bar, and the keys a Mac
/// owner reaches for to close it.
private final class MacPreviewNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let close = UIBarButtonItem(title: "关闭", primaryAction: UIAction { [weak self] _ in self?.close() })
        topViewController?.navigationItem.rightBarButtonItems = [close] + (topViewController?.navigationItem.rightBarButtonItems ?? [])
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputEscape, "w", "["].map { input in
            let k = UIKeyCommand(input: input, modifierFlags: input == UIKeyCommand.inputEscape ? [] : .command,
                                 action: #selector(closeCommand))
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
    }

    @objc private func closeCommand() { close() }

    private func close() { dismiss(animated: true) }
}
#endif
