import SwiftUI
import AppKit

enum AppInfo {
    static let name = "Keeper"
    static let version = "0.9.4"
    static let stage = "alpha"
    static let versionLabel = "Version \(version) · \(stage)"

    static let website = URL(string: "https://jflowermedia.com/")!
    static let instagram = URL(string: "https://www.instagram.com/jflowermedia/")!

    static let repo = URL(string: "https://github.com/jflowermedia/keeper")!
    /// The guide lives in the README, under its own heading.
    static let guide = URL(string: "https://github.com/jflowermedia/keeper#guide")!
    static let issues = URL(string: "https://github.com/jflowermedia/keeper/issues")!
    /// Sony's own page on setting up Clip Flag. It's the FX3 guide — Sony has no
    /// model-neutral one — but the custom key setting reads the same across its bodies.
    static let sonyClipFlag = URL(string: "https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1001690663.html")!
}

@main
struct KeeperApp: App {
    @StateObject private var state = AppState()
    // Same UserDefaults key as ContentView's, so the menu item and the toolbar button
    // stay in step with each other.
    @AppStorage("showTagging") private var showTagging = true
    @AppStorage("advanceAfterTag") private var advanceAfterTag = false
    /// Observed, not just read: changing a binding has to rebuild this scene, or the menu
    /// items keep the key equivalents they were built with until the next launch.
    @ObservedObject private var shortcuts = Shortcuts.shared
    /// Also observed, because the Undo item's own name comes from the library's history and
    /// `AppState` doesn't republish when that changes.
    @ObservedObject private var library = TagLibrary.shared
    /// For the Help menu's toggle and its disabled state while a check is running.
    @ObservedObject private var updates = UpdateCheck.shared

    init() {
        // `swift run Keeper --self-check` runs the checks and exits without ever opening a
        // window. They used to be an XCTest target, which couldn't run here: XCTest comes
        // with Xcode, and the Command Line Tools are all this app needs to build.
        if CommandLine.arguments.contains("--self-check") {
            exit(SelfCheck.run() ? 0 : 1)
        }
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
            CommandGroup(replacing: .appSettings) {
                Button("Keyboard Shortcuts…") { state.showShortcutsSheet = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Named for what they'll actually undo — "Undo Mark 24 Clips KEEP" — so a menu
            // you open in a panic says whether it's the thing you meant.
            CommandGroup(replacing: .undoRedo) {
                Button(state.undoMenuTitle) { state.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo)
                Button(state.redoMenuTitle) { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
            }

            CommandMenu("Mark") {
                Button("Toggle KEEP on Previewed Clip") { state.toggleKeepOnPreview() }
                    .keyboardShortcut(shortcuts.equivalent(.toggleKeep),
                                      modifiers: shortcuts.modifiers(.toggleKeep))
                    .disabled(state.previewClip == nil)
                Toggle("Move On After Marking", isOn: $state.advanceAfterMark)
                    .help("Go to the next clip after ⌘K. The badge on a row never moves the "
                          + "preview, whichever way this is set.")

                Divider()
                Button("Mark Selection KEEP") { state.setKeepInScope(true) }
                    .keyboardShortcut(shortcuts.equivalent(.markKeep),
                                      modifiers: shortcuts.modifiers(.markKeep))
                    .disabled(state.dragClips.isEmpty)
                Button("Mark Selection NOT KEEP") { state.setKeepInScope(false) }
                    .keyboardShortcut(shortcuts.equivalent(.markNotKeep),
                                      modifiers: shortcuts.modifiers(.markNotKeep))
                    .disabled(state.dragClips.isEmpty)
                Button("Revert Selection to Camera Flags") { state.revertKeepInScope() }
                    .disabled(state.dragClips.isEmpty)
            }

            CommandGroup(after: .newItem) {
                Button("Choose Folder…") { state.chooseCard() }
                    .keyboardShortcut(shortcuts.equivalent(.chooseFolder),
                                      modifiers: shortcuts.modifiers(.chooseFolder))
                Button("Rescan") { state.scan() }
                    .keyboardShortcut(shortcuts.equivalent(.rescan),
                                      modifiers: shortcuts.modifiers(.rescan))
                    .disabled(state.root == nil)
                Divider()
                Button("Export…") { state.requestExport() }
                    .keyboardShortcut(shortcuts.equivalent(.export),
                                      modifiers: shortcuts.modifiers(.export))
                    .disabled(state.exportButtonCount == 0 || state.isCopying || state.isScanning)
                Button("Check the Card Copied…") { state.openVerify() }
                    .keyboardShortcut(shortcuts.equivalent(.verify),
                                      modifiers: shortcuts.modifiers(.verify))
                    .disabled(state.clips.isEmpty || state.isScanning)
                Divider()
                Button("Download a Roster…") { state.showRosterDownload = true }
                    .help("Fetches a team's current roster from the league, so the numbers "
                          + "are today's rather than whenever the file was made.")
                Button("Import Roster CSV…") { state.importRoster() }
                    .keyboardShortcut(shortcuts.equivalent(.importRoster),
                                      modifiers: shortcuts.modifiers(.importRoster))
                Button("Edit Rosters…") { state.showRosterEditor = true }
                    .keyboardShortcut(shortcuts.equivalent(.editRosters),
                                      modifiers: shortcuts.modifiers(.editRosters))
                Button("Edit Filename Presets…") { state.showPresetEditor = true }

                Divider()
                restoreMenu
            }
            CommandGroup(after: .sidebar) {
                Button("Full Screen Preview") { Playback.shared.toggleFullScreen() }
                    .keyboardShortcut(shortcuts.equivalent(.fullScreen),
                                      modifiers: shortcuts.modifiers(.fullScreen))
                    .disabled(state.previewClip == nil)
                Divider()
                Toggle("Tagging Panel", isOn: $showTagging)
                    .keyboardShortcut(shortcuts.equivalent(.taggingPanel),
                                      modifiers: shortcuts.modifiers(.taggingPanel))
                Toggle("Keyboard Tagging", isOn: $state.keyboardFlow)
                    .keyboardShortcut(shortcuts.equivalent(.keyboardFlow),
                                      modifiers: shortcuts.modifiers(.keyboardFlow))
                Toggle("Warn Before Clearing Tags", isOn: $state.warnBeforeClearingTags)
                    .help("Whether \(shortcuts.display(.clearTags)) and the Remove Tags "
                          + "button ask before clearing. ⌘Z puts the tags back either way.")
                Toggle("Hold for Subjects Only", isOn: $state.subjectsKeyIsHold)
                    .help("Whether \(shortcuts.display(.subjectsOnly)) shows the Subjects pill "
                          + "only while it's held down, rather than switching to it and back. "
                          + "Rebind the key itself in Keyboard Shortcuts.")
                Toggle("Move On After Tagging", isOn: $advanceAfterTag)
                Divider()
                // The same setting the export sheet shows, which is where it matters and
                // where it's explained. Here for the one place the sheet isn't involved:
                // dragging a row to Finder.
                Toggle("Include XML Sidecars", isOn: $state.includeXML)
                    .help("Whether a clip's XML sidecar travels with it. The export sheet "
                          + "shows this too; this is the one that applies when you drag a "
                          + "row straight to Finder.")
                Toggle("Keep the Mac Awake While Transferring",
                       isOn: $state.keepAwakeDuringTransfer)
                    .help("Stops the Mac idling to sleep part way through a copy or a check. "
                          + "Idle sleep only — closing a laptop lid will still sleep it. "
                          + "Switching this off takes effect immediately, even mid-transfer.")
                Toggle("Debug Log", isOn: $state.debugMode)
                    .keyboardShortcut(shortcuts.equivalent(.debugLog),
                                      modifiers: shortcuts.modifiers(.debugLog))
            }
            CommandGroup(replacing: .help) {
                // Help first, which is what someone opening this menu is after; the update
                // items are housekeeping and sit below.
                // Disabled while something else is up: SwiftUI doesn't reliably present two
                // sheets at once, and the menus stay live behind one, so this is reachable
                // mid-export if nothing stops it.
                Button("Welcome & Tutorial…") { state.showWelcome = true }
                    .disabled(state.aSheetIsUp)
                Button("Keeper Guide") { NSWorkspace.shared.open(AppInfo.guide) }
                Button("Keeper on GitHub") { NSWorkspace.shared.open(AppInfo.repo) }
                Button("Report a Problem") { NSWorkspace.shared.open(AppInfo.issues) }
                Divider()
                Button("Check for Updates…") { UpdateCheck.shared.check(manual: true) }
                    .disabled(updates.checking)
                Toggle("Check for Updates Automatically", isOn: $updates.enabled)
                    .help("Asks GitHub once a day whether there's a newer release. Nothing "
                          + "is sent and nothing is downloaded.")
                Divider()
                Button("JFlowerMedia Website") { NSWorkspace.shared.open(AppInfo.website) }
                Button("JFlowerMedia on Instagram") { NSWorkspace.shared.open(AppInfo.instagram) }
            }
        }
    }

    // MARK: - Restore

    /// The rolling backups of `library.json`, newest first, written automatically as you tag.
    /// Restoring replaces every tag at once, so `restoreLibrary` asks before it does.
    private var restoreMenu: some View {
        Menu("Restore Tags") {
            if state.libraryBackups.isEmpty {
                Button("No backups yet") {}
                    .disabled(true)
            } else {
                ForEach(state.libraryBackups) { backup in
                    Button(AppState.backupLabel(backup)) {
                        state.restoreLibrary(from: backup)
                    }
                }
            }
            Divider()
            Button("Reveal Backups in Finder") { state.revealBackups() }
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
