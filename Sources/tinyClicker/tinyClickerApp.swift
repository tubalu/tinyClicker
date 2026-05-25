import SwiftUI

@main
struct tinyClickerApp: App {
    @StateObject private var state = AppState()
    @StateObject private var permissions = PermissionMonitor()

    var body: some Scene {
        WindowGroup("tinyClicker") {
            ContentView()
                .environmentObject(state)
                .environmentObject(permissions)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { state.addRecording() }
                    .keyboardShortcut("n")
            }
        }
    }
}
