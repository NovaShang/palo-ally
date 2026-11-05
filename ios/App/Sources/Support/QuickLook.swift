import PDFKit
import QuickLook
import SwiftUI
import UIKit

/// A file shown inside a page or a pane tab: QuickLook, except a PDF on the
/// Mac. There QuickLook embedded in a pane showed the first page only and
/// didn't scroll (10-27); PDFKit lays the pages one under another, as wide as
/// the pane, and scrolls with the wheel or trackpad.
struct EmbeddedPreview: View {
    let url: URL
    let revision: Int64

    var body: some View {
        #if targetEnvironment(macCatalyst)
        if url.pathExtension.lowercased() == "pdf" {
            PDFPreview(url: url, revision: revision)
        } else if ImagePreview.handles(url) {
            ImagePreview(url: url, revision: revision)
        } else {
            QuickLookView(url: url, revision: revision)
        }
        #else
        QuickLookView(url: url, revision: revision)
        #endif
    }
}

/// A picture at its full resolution, fitted to the pane, that zooms (a
/// trackpad's pinch, a double click between fitted and its own size). On the
/// Mac QuickLook embedded in a pane drew pictures small and blurred and
/// didn't zoom (11-05).
struct ImagePreview: UIViewRepresentable {
    let url: URL
    let revision: Int64

    static func handles(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }

    func makeUIView(context: Context) -> ZoomingImageView { ZoomingImageView() }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        view.show(url: url, revision: revision)
    }

    final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
        private let imageView = UIImageView()
        private var shown: (URL, Int64)?
        private var fittedFor: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            backgroundColor = .secondarySystemBackground
            showsHorizontalScrollIndicator = true
            showsVerticalScrollIndicator = true
            decelerationRate = .fast
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            let twice = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            twice.numberOfTapsRequired = 2
            addGestureRecognizer(twice)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(url: URL, revision: Int64) {
            guard shown?.0 != url || shown?.1 != revision else { return }
            shown = (url, revision)
            imageView.image = UIImage(contentsOfFile: url.path)
            fittedFor = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image, image.size.width > 0, image.size.height > 0, bounds.width > 0 else { return }
            if fittedFor != bounds.size {
                fittedFor = bounds.size
                // Fitted to the pane (never blown up past its own size), up to
                // 4 times its own size zoomed.
                zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: image.size)
                contentSize = image.size
                let fit = min(bounds.width / image.size.width, bounds.height / image.size.height, 1)
                minimumZoomScale = fit
                maximumZoomScale = max(4, fit)
                zoomScale = fit
            }
            center()
        }

        /// A picture smaller than the pane sits in its middle.
        private func center() {
            let dx = max(0, (bounds.width - contentSize.width) / 2)
            let dy = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
            let target = zoomScale > minimumZoomScale + 0.01 ? minimumZoomScale : min(max(1, minimumZoomScale * 2), maximumZoomScale)
            if target == minimumZoomScale {
                setZoomScale(target, animated: true)
            } else {
                let p = tap.location(in: imageView)
                let size = CGSize(width: bounds.width / target, height: bounds.height / target)
                zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// A PDF, its pages in one column, fitted to the width.
struct PDFPreview: UIViewRepresentable {
    let url: URL
    let revision: Int64

    final class Coordinator {
        var url: URL?
        var revision: Int64 = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .secondarySystemBackground
        load(view, context: context)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url || context.coordinator.revision != revision { load(view, context: context) }
    }

    /// A new revision of the same document keeps the page that was showing.
    private func load(_ view: PDFView, context: Context) {
        let page = view.currentPage.flatMap { view.document?.index(for: $0) }
        context.coordinator.url = url
        context.coordinator.revision = revision
        view.document = PDFDocument(url: url)
        if let page, let doc = view.document, page < doc.pageCount, let p = doc.page(at: page) { view.go(to: p) }
    }
}

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

    static func present(_ items: [Item], startAt start: Int, in scene: UIWindowScene? = nil,
                        openInLibrary: @escaping (String) -> Void) {
        guard !items.isEmpty, let top = topController(in: scene) else { return }
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
        // A picture: our own viewer, at its full resolution and zooming
        // (QuickLook inside our page drew it small and blurred, 11-05).
        let tapped = items[min(max(start, 0), items.count - 1)]
        if ImagePreview.handles(tapped.url) {
            let nav = UINavigationController(rootViewController: PhoneImagePage(url: tapped.url, title: tapped.title))
            nav.modalPresentationStyle = .fullScreen
            top.present(nav, animated: true)
            return
        }
        // A page of ours with QuickLook inside it, so the bar (and its ✕) is
        // ours: on its own, QuickLook went full screen on a long docx and
        // hid its Done for good, leaving no way out.
        let nav = UINavigationController(rootViewController: PhonePreviewPage(preview: preview))
        nav.modalPresentationStyle = .fullScreen
        top.present(nav, animated: true)
        #endif
    }

    /// The controller to present from: in `scene` (the window the tap came
    /// from) when given; else the window in front. With several windows on
    /// the Mac, "a key window" alone found another window's.
    static func topController(in scene: UIWindowScene? = nil) -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let front = scenes.first { $0.activationState == .foregroundActive && ($0.keyWindow?.isKeyWindow ?? false) }
        let window = (scene ?? front).flatMap { $0.keyWindow ?? $0.windows.first }
            ?? scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
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

    /// Whose bar holds the buttons: the phone's page around it, or its own.
    private var barItem: UINavigationItem {
        #if targetEnvironment(macCatalyst)
        navigationItem
        #else
        (parent as? PhonePreviewPage)?.navigationItem ?? navigationItem
        #endif
    }

    var currentURL: URL? { items[safe: currentPreviewItemIndex]?.url }
    var currentTitle: String? { items[safe: currentPreviewItemIndex].map { $0.title ?? $0.url.lastPathComponent } }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard libraryButton == nil, items.contains(where: { $0.artifactID != nil }) else { return }
        let button = UIBarButtonItem(title: String(localized: "在产出物库中查看"), image: UIImage(systemName: "books.vertical"), primaryAction: UIAction { [weak self] _ in
            guard let self, let id = self.items[safe: self.currentPreviewItemIndex]?.artifactID else { return }
            self.dismiss(animated: true) { self.openInLibrary(id) }
        })
        button.accessibilityLabel = String(localized: "在产出物库中查看")
        libraryButton = button
        barItem.leftBarButtonItems = (barItem.leftBarButtonItems ?? []) + [button]
        updateLibraryButton()
        indexObservation = observe(\.currentPreviewItemIndex, options: [.new]) { controller, _ in
            MainActor.assumeIsolated { (controller as? AttachmentPreviewController)?.updateLibraryButton() }
        }
    }

    /// Only shown while the current page is a library item.
    private func updateLibraryButton() {
        libraryButton?.isHidden = items[safe: currentPreviewItemIndex]?.artifactID == nil
        #if !targetEnvironment(macCatalyst)
        (parent as? PhonePreviewPage)?.pageChanged()
        #endif
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewItems.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        updateLibraryButton()
        return previewItems[index]
    }
}

#if !targetEnvironment(macCatalyst)
/// The phone's preview page: our bar with ✕, the title, 共享 and
/// 在产出物库中查看; QuickLook inside it shows the file (zoom, paging) and
/// can't take the way out away when it goes full screen.
/// A picture full screen on a phone or iPad: ✕, its name, 共享, and the
/// picture fitted, pinching and double tapping to zoom.
private final class PhoneImagePage: UIViewController {
    private let url: URL
    private let name: String?

    init(url: URL, title: String?) {
        self.url = url
        self.name = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let image = ImagePreview.ZoomingImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            image.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        image.show(url: url, revision: 0)
        navigationItem.title = name ?? url.lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = [UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })]
        let share = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let sheet = UIActivityViewController(activityItems: [self.url], applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?.first
            self.present(sheet, animated: true)
        })
        share.accessibilityLabel = String(localized: "共享")
        navigationItem.rightBarButtonItems = [share]
    }
}

private final class PhonePreviewPage: UIViewController {
    private let preview: AttachmentPreviewController

    init(preview: AttachmentPreviewController) {
        self.preview = preview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        preview.didMove(toParent: self)
        navigationItem.leftBarButtonItems = [UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })]
        let share = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.share() })
        share.accessibilityLabel = String(localized: "共享")
        navigationItem.rightBarButtonItems = [share]
        navigationItem.largeTitleDisplayMode = .never
        pageChanged()
    }

    func pageChanged() {
        navigationItem.title = preview.currentTitle
    }

    private func share() {
        guard let url = preview.currentURL else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }
}
#endif

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

#if targetEnvironment(macCatalyst)
/// The Mac's preview sheet: a 关闭 button in its own bar, and the keys a Mac
/// owner reaches for to close it.
private final class MacPreviewNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let close = UIBarButtonItem(title: String(localized: "关闭"), primaryAction: UIAction { [weak self] _ in self?.close() })
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
