import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI
import UIKit

/// The toolbar button that flips a Markdown file between its rendered page
/// and its source text.
struct MarkdownSourceToggle: View {
    @Binding var raw: Bool

    var body: some View {
        Button {
            raw.toggle()
        } label: {
            Image(systemName: raw ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
        }
        .tint(.primary)
        .accessibilityLabel(raw ? "看排版" : "看源文本")
        .help(raw ? "看排版" : "看源文本")
    }
}

extension AppStore {
    /// A library item's Markdown pulls its relative images from the same item
    /// — only files the item lists, and none too big to inline.
    func markdownImages(artifactID: String, documentPath: String) -> FilePreviewWebView.ImageSource {
        .init(directory: (documentPath as NSString).deletingLastPathComponent) { [weak self] path in
            guard let self,
                  let file = self.artifact(id: artifactID)?.files.first(where: { $0.path == path }),
                  file.size <= FilePreviewWebView.imageMaxBytes
            else { return nil }
            return try? await self.readArtifact(id: artifactID, path: path).data
        }
    }
}

/// A Markdown file sent in the conversation, over the chat: rendered by the
/// renderer ported from Bento Term, with its source and the system share
/// sheet one tap away. Every other file still opens in Quick Look.
struct MarkdownFileSheet: View {
    let url: URL
    let title: String
    /// Set for library items: offers 「在产出物库中查看」.
    let artifactID: String?
    let imageSource: FilePreviewWebView.ImageSource?
    let openInLibrary: (String) -> Void
    let close: () -> Void

    @State private var text: String?
    @State private var raw = false

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    MarkdownPreview(fileName: url.lastPathComponent, text: text, raw: raw, imageSource: imageSource)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close, action: close)
                        .tint(.primary)
                        .accessibilityLabel("关闭")
                }
                if let artifactID {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            openInLibrary(artifactID)
                        } label: {
                            Image(systemName: "books.vertical")
                        }
                        .tint(.primary)
                        .accessibilityLabel("在产出物库中查看")
                        .help("在产出物库中查看")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    MarkdownSourceToggle(raw: $raw)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The file itself, under its own name — never the text on screen.
                    ShareLink(item: url)
                        .tint(.primary)
                }
            }
        }
        .task {
            let data = (try? Data(contentsOf: url)) ?? Data()
            text = String(decoding: data, as: UTF8.self)
        }
    }
}

@MainActor
enum MarkdownFilePresenter {
    static func present(url: URL, title: String, artifactID: String?,
                        imageSource: FilePreviewWebView.ImageSource?,
                        openInLibrary: @escaping (String) -> Void) {
        guard let top = QuickLookPresenter.topController() else { return }
        weak var presented: UIViewController?
        let sheet = MarkdownFileSheet(
            url: url, title: title, artifactID: artifactID, imageSource: imageSource,
            openInLibrary: { id in presented?.dismiss(animated: true) { openInLibrary(id) } },
            close: { presented?.dismiss(animated: true) })
        let controller = MarkdownSheetController(rootView: sheet)
        #if targetEnvironment(macCatalyst)
        // The Mac: a large sheet, like Quick Look's, closed by 关闭 / Esc / ⌘W.
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 960, height: 720)
        #else
        controller.modalPresentationStyle = .pageSheet
        #endif
        presented = controller
        top.present(controller, animated: true)
    }
}

private final class MarkdownSheetController: UIHostingController<MarkdownFileSheet> {
    #if targetEnvironment(macCatalyst)
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputEscape, "w", "["].map { input in
            let k = UIKeyCommand(input: input, modifierFlags: input == UIKeyCommand.inputEscape ? [] : .command,
                                 action: #selector(closeCommand))
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
    }

    @objc private func closeCommand() { dismiss(animated: true) }
    #endif
}
