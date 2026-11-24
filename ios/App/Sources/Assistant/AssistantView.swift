import PaloAllyKit
import SwiftUI

/// The assistant's details as a page of their own: management (the orb on a
/// phone pushes it; ⌘1 and large screens show it as a sheet with 完成). The
/// same tiles as the details popover (Detail/DetailTiles), here with 设置 of
/// the app (the gear) and a task opened from elsewhere.
struct AssistantView: View {
    /// Shown as a sheet (large screens): it closes with 完成.
    var inSheet = false
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        DetailTiles(agent: nil)
            .navigationTitle(store.assistantName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if inSheet {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { model.showManagement = false }
                            .tint(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(.primary)
                    .accessibilityLabel("设置")
                }
            }
            .navigationDestination(isPresented: $model.showSettings) {
                SettingsView().modifier(InSidebarColumn())
            }
            // A task opened from the conversation (large screens) or a notification.
            .navigationDestination(item: $model.openTaskID) { id in
                TaskDetailView(taskID: id).modifier(InSidebarColumn())
            }
    }
}

#Preview {
    let model = WindowModel.demo()
    NavigationStack { AssistantView() }
        .environment(model)
        .environment(model.store!)
}

/// A page pushed inside management. On the Mac: no sidebar toggle, and the
/// grouped background rather than the Mac form's lighter gray.
struct InSidebarColumn: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content
                .toolbar(removing: .sidebarToggle)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        } else {
            content
        }
    }
}
