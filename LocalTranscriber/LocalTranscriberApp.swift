import SwiftUI

@main
struct LocalTranscriberApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .frame(minWidth: 760, idealWidth: 820, minHeight: 680, idealHeight: 760)
        }
        .windowResizability(.automatic)
    }
}
