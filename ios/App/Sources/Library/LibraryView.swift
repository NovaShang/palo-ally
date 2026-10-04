import PaloAllyKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            if store.artifacts.isEmpty {
                ContentUnavailableView("这里还空着",
                                       systemImage: "books.vertical",
                                       description: Text("助理整理出来的东西——晨报、比价、表格、文档——都会放在这里。"))
                    .listRowBackground(Color.clear)
            }
            if !store.pinnedArtifacts.isEmpty {
                Section("置顶") {
                    ForEach(store.pinnedArtifacts) { row($0) }
                }
            }
            if !store.recentArtifacts.isEmpty {
                Section("最近更新") {
                    ForEach(store.recentArtifacts) { row($0) }
                }
            }
        }
        .navigationTitle("资料库")
        .refreshable { try? await store.refreshArtifacts() }
        .navigationDestination(for: String.self) { id in
            ArtifactDetailView(artifactID: id)
        }
    }

    private func row(_ a: Artifact) -> some View {
        NavigationLink(value: a.id) {
            HStack(spacing: 12) {
                Image(systemName: a.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title.isEmpty ? a.mainFile : a.title)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(Copy.relative(a.updatedAt))更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if a.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { try? await store.setPinned(a, !a.pinned) }
            } label: {
                Label(a.pinned ? "取消置顶" : "置顶", systemImage: a.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                Task { try? await store.setPinned(a, !a.pinned) }
            } label: {
                Label(a.pinned ? "取消置顶" : "置顶", systemImage: a.pinned ? "pin.slash" : "pin")
            }
        }
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { LibraryView() }
        .environment(model)
        .environment(model.store!)
}
