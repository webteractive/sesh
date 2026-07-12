import SwiftUI
import SwiftData
import SSHConfigCore

@main
struct SSHConfigApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environment(model)
                .onAppear { model.onLaunch(); model.windowAppeared() }
                .onDisappear { model.windowDisappeared() }
        }
        .modelContainer(AppModel.container)
        // Menu-bar app: don't force a window at launch; open on demand.
        .defaultLaunchBehavior(.suppressed)

        Window("Raw Config", id: "raw-config") {
            RawConfigView()
                .environment(model)
                .onAppear { model.windowAppeared() }
                .onDisappear { model.windowDisappeared() }
        }
        .defaultSize(width: 560, height: 480)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra("Sesh", systemImage: "terminal") {
            MenuBarView()
                .environment(model)
                .modelContainer(AppModel.container)
        }
        .menuBarExtraStyle(.window)
    }
}
