import PaloAllyKit
import SwiftUI

/// Share a file out of a conversation, a 成果 item or a computer file — the
/// one escape hatch for a file too big to preview in place (docs/files-prd.md).
/// A file over 5 MB is never read whole into memory: it is streamed from the
/// host in 256 KiB chunks into a device temp file (`AppStore.streamFile` and
/// friends), with a progress bar and 取消, then the system share sheet opens
/// (`ShareLink`: the activity controller on the phone and iPad, the picker on
/// the Mac). Over 200 MB it refuses with a plain message.
struct FileShareTarget: Identifiable {
    let id = UUID()
    /// The sheet's heading: 文件太大，无法在这里预览 for a big file, 分享文件 otherwise.
    let title: String
    let name: String
    let size: Int64?
    let source: Source

    enum Source {
        /// A computer file (scope + path).
        case file(scope: FileScope, path: String)
        /// A file sent in the conversation.
        case media(id: String)
        /// A library item's file.
        case artifact(id: String, path: String)
        /// Already on the device: share it as it is, nothing streamed.
        case url(URL)
    }
}

/// The stream-then-share sheet, presented over whatever opened the file.
struct FileShareSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: FileShareTarget

    @State private var url: URL?
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(target.title).font(.headline).multilineTextAlignment(.center)
                Text(target.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let size = target.size {
                    Text(Copy.byteSize(size)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                cancel
            } else if let url {
                // The file is on the device: the system share sheet (the
                // activity controller on the phone/iPad, the picker on the Mac).
                ShareLink(item: url) {
                    Label("分享 / 导出", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .accessibilityIdentifier("file-share-open")
                cancel
            } else {
                VStack(spacing: 10) {
                    if let progress {
                        ProgressView(value: progress)
                        Text("正在取… \(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        ProgressView("正在取…")
                    }
                }
                cancel
            }
        }
        .padding(24)
        .frame(minWidth: 260)
        .presentationDetents([.medium])
        .task { await stream() }
        .accessibilityIdentifier("file-share-sheet")
    }

    /// 取消: cancels the stream (its task ends with the sheet) and closes.
    private var cancel: some View {
        Button("取消") { dismiss() }
            .buttonStyle(.glass)
            .tint(.primary)
            .accessibilityIdentifier("file-share-cancel")
    }

    private func stream() async {
        // Already on the device: share straight away.
        if case .url(let u) = target.source { url = u; return }
        do {
            let downloaded: URL
            let report: (Int64, Int64) -> Void = { got, total in
                let total = max(total, 1)
                progress = min(1, Double(got) / Double(total))
            }
            switch target.source {
            case .file(let scope, let path):
                downloaded = try await store.streamFile(scope, path: path, name: target.name, progress: report)
            case .media(let id):
                downloaded = try await store.streamMedia(id: id, name: target.name, progress: report)
            case .artifact(let id, let path):
                downloaded = try await store.streamArtifact(id: id, path: path, name: target.name, progress: report)
            case .url:
                return
            }
            url = downloaded
        } catch is FileStreamTooLarge {
            failure = "文件太大，无法分享（最多 200 MB）"
        } catch is CancellationError {
            dismiss()
        } catch {
            failure = Copy.error(error)
        }
    }
}

extension View {
    /// Present the stream-then-share sheet: `.sheet(item: $target) { FileShareSheet(target: $0) }`.
    /// Kept as a convenience so each entry point writes the same presentation.
    @MainActor func fileShareSheet(item: Binding<FileShareTarget?>) -> some View {
        sheet(item: item) { FileShareSheet(target: $0) }
    }
}
