import SwiftUI
import AppKit

enum AppInfo {
    static let name = "Keeper"
    static let version = "0.1"
    static let stage = "alpha"
    static let versionLabel = "Version \(version) · \(stage)"

    static let website = URL(string: "https://jflowermedia.com/")!
    static let instagram = URL(string: "https://www.instagram.com/jflowermedia/")!
}

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
            CommandGroup(replacing: .appInfo) {
                Button("About Keeper") { Self.showAbout() }
            }
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
