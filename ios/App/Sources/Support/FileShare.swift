import PaloAllyKit
import SwiftUI

/// Share a file out of a conversation, a 成果 item or a computer file
/// (docs/files-prd.md), at any size: it is downloaded to the device through
/// the same downloader that opens files (`AppStore.downloadFile`: chunks
/// straight to disk, never the whole file in memory), with a progress bar
/// and 取消, then the system share sheet opens (`ShareLink`: the activity
/// controller on the phone and iPad, the picker on the Mac). A file already
/// downloaded is shared from the cache at once.
struct FileShareTarget: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64?
    let source: Source

    enum Source {
        /// On the computer: downloaded first.
        case remote(RemoteFileSource)
        /// Already on the device: share it as it is.
        case url(URL)
    }
}

/// The download-then-share sheet, presented over whatever opened the file.
struct FileShareSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: FileShareTarget

    @State private var url: URL?
    @State private var progress: (Int64, Int64)?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("分享文件", tableName: "Files").font(.headline).multilineTextAlignment(.center)
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
                    if let progress, progress.1 > 0 {
                        ProgressView(value: min(1, Double(progress.0) / Double(progress.1)))
                        Text(verbatim: DownloadText.progress(progress.0, progress.1))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        ProgressView()
                    }
                }
                cancel
            }
        }
        .padding(24)
        .frame(minWidth: 260)
        .presentationDetents([.medium])
        .task { await download() }
        .accessibilityIdentifier("file-share-sheet")
    }

    /// 取消: stops the download (its task ends with the sheet; what came stays for next time) and closes.
    private var cancel: some View {
        Button { dismiss() } label: { Text("取消", tableName: "Files") }
            .buttonStyle(.glass)
            .tint(.primary)
            .accessibilityIdentifier("file-share-cancel")
    }

    private func download() async {
        switch target.source {
        case .url(let u):
            url = u
        case .remote(let source):
            do {
                url = try await store.downloadFile(source, name: target.name, size: target.size) { got, total in
                    progress = (got, total)
                }
            } catch is FileStreamTooLarge {
                failure = String(localized: "主机上的 Palo 版本较旧，发不了这么大的文件。更新它以后再试。", table: "Files")
            } catch is CancellationError {
                dismiss()
            } catch {
                failure = Copy.error(error)
            }
        }
    }
}

extension View {
    /// Present the download-then-share sheet: `.sheet(item: $target) { FileShareSheet(target: $0) }`.
    /// Kept as a convenience so each entry point writes the same presentation.
    @MainActor func fileShareSheet(item: Binding<FileShareTarget?>) -> some View {
        sheet(item: item) { FileShareSheet(target: $0) }
    }
}
