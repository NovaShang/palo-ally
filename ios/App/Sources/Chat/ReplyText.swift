import os
import PaloAllyKit
import SwiftUI
import UIKit

/// An answer's text: prose in selectable text views, tables as grids. While
/// the reply is being written, each new piece goes straight from the store
/// (`StreamingReply.listen`) into the text view of its last, still open
/// paragraph run; SwiftUI is involved only when the shape changes (a table
/// starts, a run is finished) or the text's height does, a few times a
/// second instead of on every piece (design §3.3). Finished, the same views
/// stay: the text view drops the cursor in place.
struct ReplyText: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    @State private var model = ReplyTextModel()
    @Environment(\.appTheme) private var theme

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.note("text \(message.id)")
        #endif
        // Reads the store's set of replies being written (changes when one
        // starts or ends), not the text.
        let live = message.isStreaming ? store.stream(for: message.id) : nil
        let _ = model.show(live, text: message.text, streaming: message.isStreaming, linkColor: theme.uiColor)
        ReplyBody(model: model,
                  onQuote: { store.quote(message, excerpt: $0) },
                  trailingRoom: AssistantMessageLayout.trailingRoom)
    }
}

enum AssistantMessageLayout {
    /// Kept free beside replies; tables scroll through it.
    static let trailingRoom: CGFloat = 24
}

/// What an answer is made of, and the live end of it.
@MainActor
@Observable
final class ReplyTextModel {
    enum Piece: Equatable {
        /// Finished prose.
        case text(String)
        /// The last prose run: its text goes straight to its view.
        case live
        case table(MarkdownTable)
    }

    /// Changes only when the shape does.
    private(set) var pieces: [Piece] = []
    /// The live run's height; a change has SwiftUI lay it out again.
    private(set) var liveHeight: CGFloat = 0

    @ObservationIgnored private(set) var liveText = ""
    @ObservationIgnored private(set) var streaming = false
    @ObservationIgnored private(set) var linkColor: UIColor = .link
    @ObservationIgnored private let segments = MarkdownSegmentCache()
    @ObservationIgnored private weak var liveHost: LiveTextHost?
    @ObservationIgnored private var following: StreamingReply?
    @ObservationIgnored private var token: Int?

    /// A reply being written (followed as it grows), or a finished text.
    func show(_ live: StreamingReply?, text: String, streaming: Bool, linkColor: UIColor) {
        self.linkColor = linkColor
        if live !== following {
            if let following, let token { following.stopListening(token) }
            following = live
            token = live?.listen { [weak self] text in self?.apply(text, streaming: true) }
        }
        apply(live?.current ?? text, streaming: streaming)
    }

    private func apply(_ text: String, streaming: Bool) {
        // A table being written grows by whole rows, not by the cell.
        let split = segments.split(streaming ? String(MarkdownSegments.completeTableRows(text)) : text)
        var next: [Piece] = split.map {
            switch $0 {
            case .text(let t): .text(t)
            case .table(let t): .table(t)
            }
        }
        var live = ""
        if case .text(let t)? = split.last {
            next[next.count - 1] = .live
            live = t
        }
        if next != pieces {
            pieces = next
            // A table row (or a table starting): the reply changes shape.
            if streaming { RevealTickNote.note(.tableRow) }
        }
        guard live != liveText || streaming != self.streaming else { return }
        liveText = live
        self.streaming = streaming
        push()
    }

    /// The live run's view, as it's made.
    func attach(_ host: LiveTextHost) {
        liveHost = host
        host.text.heightMayHaveChanged = { [weak self] in self?.measure() }
        host.text.render(source: liveText, streaming: streaming, linkColor: linkColor)
    }

    /// The new text into the view; SwiftUI hears only of a new height.
    private func push() {
        guard let host = liveHost else { return }
        host.text.render(source: liveText, streaming: streaming, linkColor: linkColor)
        if !streaming { host.setNeedsLayout() }
        measure()
    }

    /// The live run's height at the width SwiftUI last gave it.
    private func measure() {
        guard let view = liveHost?.text, let width = view.measuredWidth else { return }
        let height = view.fittingSize(width: width).height
        if height != liveHeight {
            ChatSignposts.chat.emitEvent("grew")
            RevealTickNote.note(.newLine)
            liveHeight = height
        }
    }
}

private struct ReplyBody: View {
    let model: ReplyTextModel
    let onQuote: (String) -> Void
    let trailingRoom: CGFloat

    var body: some View {
        let pieces = model.pieces
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let text):
                    SelectableMarkdown(source: text, streaming: false, onQuote: onQuote)
                case .live:
                    LivePiece(model: model, onQuote: onQuote)
                case .table(let table):
                    MarkdownTableView(table: table, trailingRoom: trailingRoom)
                }
            }
        }
    }
}

/// Reads only the live run's height.
private struct LivePiece: View {
    let model: ReplyTextModel
    let onQuote: (String) -> Void

    var body: some View {
        LiveMarkdown(model: model, height: model.liveHeight, onQuote: onQuote)
    }
}

private struct LiveMarkdown: UIViewRepresentable {
    let model: ReplyTextModel
    /// Unused here: a new value is what makes SwiftUI measure again.
    let height: CGFloat
    let onQuote: (String) -> Void

    func makeUIView(context: Context) -> LiveTextHost {
        let host = LiveTextHost()
        host.text.onQuote = onQuote
        host.text.reportsHeightItself = true
        model.attach(host)
        return host
    }

    func updateUIView(_ host: LiveTextHost, context: Context) {
        host.text.onQuote = onQuote
        // Unchanged text returns at once.
        host.text.render(source: model.liveText, streaming: model.streaming, linkColor: model.linkColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: LiveTextHost, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        guard width > 0, width.isFinite else { return nil }
        host.text.render(source: model.liveText, streaming: model.streaming, linkColor: model.linkColor)
        let fit = host.text.fittingSize(width: width)
        return CGSize(width: proposal.width ?? ceil(fit.width), height: ceil(fit.height))
    }
}

/// Holds the live run's text view. SwiftUI resizes it on each new line;
/// while the reply is written, the text view inside grows in steps, so a
/// new line doesn't have its whole canvas drawn again (only the lines that
/// change are). Finished, it fits exactly.
final class LiveTextHost: UIView {
    let text = MarkdownTextView.make()
    private static let step: CGFloat = 480

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("not from a coder") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let writing = !text.isSelectable
        let height = writing ? max(bounds.height, (bounds.height / Self.step).rounded(.up) * Self.step) : bounds.height
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        if text.frame != frame { text.frame = frame }
    }
}
