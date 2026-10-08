import PaloAllyFilePreview
import PaloAllyKit
import SwiftUI

struct MessageRow: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.note("row \(message.id)")
        #endif
        switch message.role {
        case .user:
            UserBubble(message: message)
        case .system:
            NoticeRow(text: message.text)
        case .assistant where message.kind == .clipboard:
            ClipboardCard(message: message)
        default:
            // Anything the assistant says (including pushes it sends) gets full markdown.
            AssistantMessage(message: message)
        }
    }
}

private struct UserBubble: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 48)
            if message.delivery == .failed {
                Button {
                    store.retry(message)
                } label: {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("没发出去，点一下重发")
            } else if message.delivery == .sending || (message.delivery == .queued && !store.connectionTrouble) {
                // Queued during a short drop looks like sending: the reconnect
                // (usually a moment away) sends it.
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if message.delivery == .queued {
                Image(systemName: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("还没发出去，连上后会自动发")
                    .help("连上后会自动发")
            }
            VStack(alignment: .trailing, spacing: 4) {
                if let reply = message.replyTo {
                    QuoteLine(reply: reply)
                }
                if let atts = message.attachments, !atts.isEmpty {
                    AttachmentStrip(attachments: atts)
                }
                if !message.text.isEmpty {
                // A quiet "this is mine" marker, not an accent: the owner's
                // words matter no more than the assistant's.
                Text(MarkdownBlock.attributed(message.text))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
                    }
                    .textSelection(.enabled)
                }
                if message.channel == .wechat || message.channel == .cli {
                    Label(message.channel == .wechat ? "来自微信" : "来自电脑", systemImage: message.channel == .wechat ? "message" : "laptopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(message.delivery == .sending || message.delivery == .queued ? 0.75 : 1)
    }
}

private struct AssistantMessage: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    var body: some View {
        // No avatar: it cost width on every reply and said nothing new.
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let card = message.card {
                    // A schedule goal's output (晨报 and the like).
                    GoalCard(message: message, card: card)
                } else {
                if message.proactive == true && !questionCardOnly {
                    Label(proactiveLabel, systemImage: "bell.badge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let atts = message.attachments, !atts.isEmpty {
                    AttachmentStrip(attachments: atts)
                }
                if (!message.text.isEmpty || message.isStreaming) && !questionCardOnly {
                    // One system text view per answer: free selection across
                    // paragraphs, like Notes / Safari. 「引用回复」 quotes a selection.
                    // The same view while it's written and once it's finished
                    // (the text view finishes it in place).
                    ReplyText(message: message)
                }
                if !message.isStreaming, !message.text.isEmpty, message.kind == .text {
                    // The whole answer in one tap; small and quiet.
                    HStack(spacing: 0) {
                        CopyButton(text: message.text, label: "复制这条回答", glyphAlignment: .leading)
                        ReplyButton { store.quote(message) }
                    }
                }
                }
                if message.kind == .task, let taskId = message.taskId {
                    TaskChip(taskId: taskId)
                }
                if message.kind == .approval, let id = message.approvalId, let approval = store.approval(id: id) {
                    ApprovalCard(approval: approval)
                }
                if message.kind == .question, let id = message.questionId, let question = store.question(id: id) {
                    QuestionCard(question: question)
                }
            }
            Spacer(minLength: Self.trailingRoom)
        }
    }

    static let trailingRoom = AssistantMessageLayout.trailingRoom

    /// A question card says it all: no label, no repeated text above it.
    private var questionCardOnly: Bool {
        message.kind == .question && message.questionId.flatMap { store.question(id: $0) } != nil
    }

    private var proactiveLabel: String {
        switch message.channel {
        case .schedule: "到点提醒"
        case .probe: "我留意到"
        default: "主动找你"
        }
    }
}

private struct TaskChip: View {
    @Environment(AppStore.self) private var store
    @Environment(AppModel.self) private var model
    let taskId: String

    var body: some View {
        if let task = store.task(id: taskId) {
            // Opens just this task over the conversation; closing returns here.
            Button {
                model.openTask(taskId)
            } label: {
                let (symbol, color) = Copy.taskSymbol(task.status)
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(task.title).lineLimit(1)
                    Text("· \(Copy.taskStatus(task.status))").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NoticeRow: View {
    let text: String

    var body: some View {
        Text(MarkdownBlock.attributed(text))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.quaternary, in: .capsule)
            .frame(maxWidth: .infinity)
    }
}

/// What came with a message: pictures inline, other files and library items
/// as cards. Markdown renders in its own sheet (Bento Term's renderer, with
/// the source a tap away); everything else previews in the system's QuickLook
/// (zoom, pan, share, several attachments page side by side). A library item
/// offers 「在产出物库中查看」. Web-page artifacts open in the library's web view.
private struct AttachmentStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(AppModel.self) private var model
    let attachments: [Attachment]
    @State private var loading: String?

    private var pictures: [Attachment] { attachments.filter(\.showsInline) }
    private var cards: [Attachment] { attachments.filter { !$0.showsInline } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pictures.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pictures) { a in picture(a) }
                }
            }
            ForEach(cards) { a in
                Button { open(a) } label: { FileCard(attachment: a, loading: loading == a.id) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func key(_ a: Attachment) -> String { a.kind == "artifact" ? "artifact:\(a.id)" : a.id }

    @ViewBuilder private func picture(_ a: Attachment) -> some View {
        let side: CGFloat = pictures.count == 1 ? 180 : 96
        Group {
            if let data = store.images[key(a)], let ui = UIImage(data: data) {
                Button { open(a) } label: {
                    Image(uiImage: ui).resizable().scaledToFill()
                }
                .buttonStyle(.plain)
                .overlay {
                    if loading == a.id {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .background(Color(.systemBackground).opacity(0.85), in: .circle)
                    }
                }
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { ProgressView().controlSize(.small) }
                    .task {
                        if a.kind == "artifact" { await store.loadArtifactImage(a.id) } else { await store.loadImage(a.id) }
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .accessibilityLabel(a.name ?? "图片")
        .accessibilityAddTraits(.isButton)
    }

    private func isWebPage(_ a: Attachment) -> Bool { a.kind == "artifact" && a.mediaType.contains("html") }

    /// The file name a library item opens under: its main file's.
    private func fileName(_ a: Attachment) -> String {
        if a.kind == "artifact", let main = store.artifact(id: a.id)?.mainFile, !main.isEmpty {
            return (main as NSString).lastPathComponent
        }
        return a.name ?? "file"
    }

    private func isMarkdown(_ a: Attachment) -> Bool {
        guard !a.isImage else { return false }
        if a.kind == "artifact", store.artifact(id: a.id)?.previewStyle == .markdown { return true }
        return FilePreviewRoute.forFile(name: fileName(a), mediaType: a.mediaType) == .markdown
    }

    /// QuickLook's 「在产出物库中查看」: the library, scrolled into that item.
    private func openInLibrary(_ id: String) {
        model.showInLibrary(id)
    }

    private func open(_ a: Attachment) {
        // Web pages render in the artifact view, opened on their own over the chat.
        if isWebPage(a) { return model.openArtifact(a.id) }
        guard loading == nil else { return }
        loading = a.id
        Task {
            defer { loading = nil }
            if isMarkdown(a) {
                guard let url = try? await localFile(for: a) else { return }
                let artifact = a.kind == "artifact" ? store.artifact(id: a.id) : nil
                MarkdownFilePresenter.present(
                    url: url, title: a.name ?? url.lastPathComponent, artifactID: artifact == nil ? nil : a.id,
                    imageSource: artifact.map { store.markdownImages(artifactID: $0.id, documentPath: $0.mainFile) },
                    openInLibrary: openInLibrary)
                return
            }
            // Everything else previewable in this message, so QuickLook can
            // page. Markdown stays out: QuickLook would show it as raw text.
            let previewable = attachments.filter { !isWebPage($0) && !isMarkdown($0) }
            var items: [QuickLookPresenter.Item] = []
            var start = 0
            for item in previewable {
                // The tapped one must load; the others are best effort.
                guard let url = try? await localFile(for: item) else {
                    if item.id == a.id { return }
                    continue
                }
                if item.id == a.id { start = items.count }
                items.append(.init(url: url, title: item.name, artifactID: item.kind == "artifact" ? item.id : nil))
            }
            QuickLookPresenter.present(items, startAt: start, openInLibrary: openInLibrary)
        }
    }

    /// The attachment's bytes as a local file QuickLook can open.
    private func localFile(for a: Attachment) async throws -> URL {
        switch a.kind {
        case "artifact":
            let artifact = store.artifact(id: a.id)
            return try await QuickLookPresenter.file(key: "artifact-\(a.id)", revision: artifact?.updatedAt ?? 0, name: fileName(a)) {
                if a.isImage, let d = store.images[key(a)] { return d }
                return try await store.readArtifact(id: a.id).data
            }
        case "file":
            return try await QuickLookPresenter.file(key: a.id, name: a.name ?? "file") { try await store.fileData(a.id) }
        default: // image
            let ext = a.mediaType.split(separator: "/").last.map(String.init) ?? "jpg"
            return try await QuickLookPresenter.file(key: a.id, name: a.name ?? "图片.\(ext == "jpeg" ? "jpg" : ext)") {
                if let d = store.images[a.id] { return d }
                await store.loadImage(a.id)
                guard let d = store.images[a.id] else { throw CocoaError(.fileReadUnknown) }
                return d
            }
        }
    }
}

/// A file or library item in the conversation: icon, name, size.
private struct FileCard: View {
    let attachment: Attachment
    let loading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name ?? "文件").font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        // In-content: a quiet card, not glass (glass is for chrome above content).
        .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(.rect)
    }

    private var symbol: String {
        let t = attachment.mediaType
        if t.hasPrefix("image/") { return "photo" }
        if t == "application/pdf" { return "doc.richtext" }
        if t.contains("html") { return "globe" }
        if t.contains("sheet") || t.contains("csv") || t.contains("excel") { return "tablecells" }
        if t.hasPrefix("text/") || t.contains("markdown") { return "doc.text" }
        return "doc"
    }

    private var detail: String {
        var parts: [String] = []
        if attachment.kind == "artifact" { parts.append("在产出物库") }
        if let s = attachment.size { parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        return parts.isEmpty ? "点开查看" : parts.joined(separator: " · ")
    }
}

/// 「回复」 under an answer: quotes the whole answer. Same quiet style as the copy glyph.
struct ReplyButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回复这条")
    }
}

/// What the owner quoted, above their bubble: one or two quiet lines. Tap →
/// scroll to the quoted message if it's loaded.
private struct QuoteLine: View {
    @Environment(\.chatScrollTo) private var scrollTo
    let reply: ReplyTo

    var body: some View {
        Button {
            scrollTo?(reply.messageId)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Capsule().fill(.tertiary).frame(width: 2.5)
                Text(reply.excerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回复：\(reply.excerpt)")
    }
}

/// A schedule goal's output as a card (晨报 and the like): the goal's title and
/// time, then every item expanded, each with 「聊聊」 to start a reply about it.
/// Content, not chrome: a quiet fill and hairline, no glass.
private struct GoalCard: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let card: MessageCard

    private enum Line: Hashable { case item(String), text(String) }

    private var lines: [Line] {
        message.text.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let s = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• ", "· "] where s.hasPrefix(marker) {
                return .item(String(s.dropFirst(marker.count)))
            }
            return .text(s)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title.isEmpty ? "到点提醒" : card.title).font(.headline)
                Spacer()
                Text(Copy.clock(message.ts)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .item(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("·").foregroundStyle(.secondary)
                        Text(MarkdownBlock.attributed(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Button("聊聊") { store.quote(message, excerpt: text) }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            .accessibilityLabel("聊聊：\(text)")
                    }
                case .text(let text):
                    Text(MarkdownBlock.attributed(text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

extension EnvironmentValues {
    /// Scrolls the conversation to a message id (set by ChatView).
    @Entry var chatScrollTo: ((String) -> Void)? = nil
    /// The conversation's side margin, so tables can scroll edge to edge.
    @Entry var messageGutter: CGFloat = 16
}
