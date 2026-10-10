import SwiftUI
import AppKit

enum AppInfo {
    static let name = "Keeper"
    static let version = "0.3"
    static let stage = "alpha"
    static let versionLabel = "Version \(version) · \(stage)"

    static let website = URL(string: "https://jflowermedia.com/")!
    static let instagram = URL(string: "https://www.instagram.com/jflowermedia/")!
}

@main
struct KeeperApp: App {
    @StateObject private var state = AppState()
    // Same UserDefaults key as ContentView's, so the menu item and the toolbar button
    // stay in step with each other.
    @AppStorage("showTagging") private var showTagging = true

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Keeper") {
            ContentView(state: state)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Keeper") { Self.showAbout() }
            }
            CommandMenu("Mark") {
                Button("Toggle KEEP on Previewed Clip") {
                    if let clip = state.previewClip { state.toggleKeep(clip) }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(state.previewClip == nil)

                Divider()
                Button("Mark Selection KEEP") { state.setKeepInScope(true) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(state.dragClips.isEmpty)
                Button("Mark Selection NOT KEEP") { state.setKeepInScope(false) }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(state.dragClips.isEmpty)
                Button("Revert Selection to Camera Flags") { state.revertKeepInScope() }
                    .disabled(state.dragClips.isEmpty)
            }

            CommandGroup(after: .newItem) {
                Button("Choose Folder…") { state.chooseCard() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan") { state.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.root == nil)
                Divider()
                Button("Export…") { state.requestExport() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.visible.isEmpty || state.isCopying || state.isScanning)
                Button("Edit Filename Presets…") { state.showPresetEditor = true }
            }
            CommandGroup(after: .sidebar) {
                Toggle("Tagging Panel", isOn: $showTagging)
                    .keyboardShortcut("e", modifiers: .command)
                Toggle("Debug Log", isOn: $state.debugMode)
                    .keyboardShortcut("d", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("JFlowerMedia Website") { NSWorkspace.shared.open(AppInfo.website) }
                Button("JFlowerMedia on Instagram") { NSWorkspace.shared.open(AppInfo.instagram) }
            }
        }
    }

    // MARK: - Credits

    /// The standard About panel, with the byline and clickable links in the credits area.
    private static func showAbout() {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred
        ]

        func link(_ text: String, _ url: URL) -> NSAttributedString {
            var attrs = body
            attrs[.link] = url
            return NSAttributedString(string: text, attributes: attrs)
        }

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Sorts camera clips by the KEEP flag in their XML sidecars.\n\n"
                  + "\(AppInfo.versionLabel) — expect rough edges.\n\nBuilt by JFlowerMedia\n",
            attributes: body))
        credits.append(link("jflowermedia.com", AppInfo.website))
        credits.append(NSAttributedString(string: "   ·   ", attributes: body))
        credits.append(link("Instagram", AppInfo.instagram))

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
