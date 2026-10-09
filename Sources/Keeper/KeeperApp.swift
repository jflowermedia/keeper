import SwiftUI

@main
struct KeeperApp: App {
    @StateObject private var state = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Keeper") {
            ContentView(state: state)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Card…") { state.chooseCard() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan") { state.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.root == nil)
                Divider()
                Button("Copy to Folder…") { state.copyToFolder() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.dragClips.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Toggle("Debug Log", isOn: $state.debugMode)
                    .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
