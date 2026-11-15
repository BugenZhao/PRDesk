import SwiftUI

/// Dashboard, Parity and Inbox as tabs, each a list that pushes an item's detail.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.mode) {
            Tab("Dashboard", systemImage: "rectangle.stack", value: AppModel.ListMode.dashboard) {
                ItemListView(mode: .dashboard)
            }
            Tab("Parity", systemImage: "arrow.triangle.branch", value: AppModel.ListMode.parity) {
                ItemListView(mode: .parity)
            }
            .badge(model.parityWaitingCount)
            Tab("Inbox", systemImage: "tray", value: AppModel.ListMode.inbox) {
                ItemListView(mode: .inbox)
            }
            .badge(model.unreadInboxCount)
        }
        .modifier(ModelAlerts())
    }
}
