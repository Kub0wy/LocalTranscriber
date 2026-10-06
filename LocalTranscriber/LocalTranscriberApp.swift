import SwiftUI

@main
struct LocalTranscriberApp: App {
    @StateObject private var managedRuntime = ManagedRuntimeSetupModel()

    var body: some Scene {
        WindowGroup {
            RootView(setup: managedRuntime)
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(managedRuntime: managedRuntime)
                .frame(minWidth: 760, idealWidth: 820, minHeight: 680, idealHeight: 760)
        }
        .windowResizability(.automatic)
    }
}
