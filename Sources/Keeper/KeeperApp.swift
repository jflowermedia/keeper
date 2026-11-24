import SwiftUI
import AppKit

enum AppInfo {
    static let name = "Keeper"
    static let version = "1.4.0"
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
    @AppStorage("taggingBelow") private var taggingBelow = true
    @AppStorage(ThemeFlavor.storageKey) private var themeFlavor = ThemeFlavor.system.rawValue
    @AppStorage(ThemeAccent.storageKey) private var themeAccent = ThemeAccent.mauve.rawValue
    /// Observed, not just read: changing a binding has to rebuild this scene, or the menu
    /// items keep the key equivalents they were built with until the next launch.
    @ObservedObject private var shortcuts = Shortcuts.shared
    /// Also observed, because the Undo item's own name comes from the library's history and
    /// `AppState` doesn't republish when that changes.
    @ObservedObject private var library = TagLibrary.shared
    /// For the Help menu's toggle and its disabled state while a check is running.
    @ObservedObject private var updates = UpdateCheck.shared
    @ObservedObject private var rosterWatch = RosterWatch.shared

    init() {
        // `swift run Keeper --self-check` runs the checks and exits without ever opening a
        // window. They used to be an XCTest target, which couldn't run here: XCTest comes
        // with Xcode, and the Command Line Tools are all this app needs to build.
        if CommandLine.arguments.contains("--self-check") {
            exit(SelfCheck.run() ? 0 : 1)
        }
        TagLibrary.shared.fillNHLMascotsOnce()
        NSApplication.shared.setActivationPolicy(.regular)
        // Milliseconds. The system's wait is a second or two, which is too long to read who a
        // tag's number means while going down a list of clips. Undocumented, and app-wide:
        // there's no per-view delay on `.help`.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
    }

    var body: some Scene {
        // The id is what macOS files the window's size under. Without one SwiftUI uses the
        // root view's type name, and `KeeperThemed` being private puts a memory address in
        // that — different every launch, so the saved size was never found again and the
        // window opened at its minimum. Changing the id forgets everyone's size once.
        WindowGroup("Keeper", id: "main") {
            ContentView(state: state)
                .keeperThemed()
                // The theme's colours are read as views draw, so the window is rebuilt when
                // it changes rather than every view having to observe it. Open sheets close;
                // nothing else is lost, because the state lives in `AppState`.
                .id("\(themeFlavor)-\(themeAccent)")
        }
        // Fills the screen until there's a saved size, which wins from then on.
        .defaultSize(NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
        .defaultPosition(.topLeading)
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
                Button("Toggle KEEP on Previewed Clip or Selection") { state.toggleOnPreview(.keep) }
                    .keyboardShortcut(shortcuts.equivalent(.toggleKeep),
                                      modifiers: shortcuts.modifiers(.toggleKeep))
                    .disabled(state.previewClip == nil)
                // No key equivalent on the item: OK's key is a bare press, and a menu item
                // with one would fire while you typed an O into a roster. The key monitor
                // handles it; the title says what it is.
                Button("Toggle OK on Previewed Clip or Selection (\(shortcuts.display(.toggleOK)))") {
                    state.toggleOnPreview(.ok)
                }
                .disabled(state.previewClip == nil)
                Toggle("Move On After Marking", isOn: $state.advanceAfterMark)
                    .help("Go to the next clip after \(shortcuts.display(.toggleKeep)) or "
                          + "\(shortcuts.display(.toggleOK)). The badge on a row never moves the "
                          + "preview, whichever way this is set.")

                Divider()
                Button("Mark Selection KEEP") { state.setFlagInScope(.keep) }
                    .keyboardShortcut(shortcuts.equivalent(.markKeep),
                                      modifiers: shortcuts.modifiers(.markKeep))
                    .disabled(state.dragClips.isEmpty)
                Button("Mark Selection OK") { state.setFlagInScope(.ok) }
                    .disabled(state.dragClips.isEmpty)
                Button("Mark Selection NG") { state.setFlagInScope(.ng) }
                    .disabled(state.dragClips.isEmpty)
                Button("Clear Flags on Selection") { state.setFlagInScope(nil) }
                    .keyboardShortcut(shortcuts.equivalent(.markNotKeep),
                                      modifiers: shortcuts.modifiers(.markNotKeep))
                    .disabled(state.dragClips.isEmpty)
                Button("Revert Selection to Camera Flags") { state.revertFlagsInScope() }
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
                Button("Update All Rosters…") { state.updateAllRosters() }
                    .disabled(state.isFetchingRosters || state.aSheetIsUp)
                    .help("Checks every roster you have from a league Keeper can download, and "
                          + "shows what's changed. Nothing is written until you say.")
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
                // A way back to the column, for a laptop screen where the band leaves the
                // video too short to judge a clip by.
                Toggle("Tagging Panel Below Video", isOn: $taggingBelow)
                Divider()
                Picker("Theme", selection: $themeFlavor) {
                    ForEach(ThemeFlavor.allCases) { Text($0.title).tag($0.rawValue) }
                }
                // Greyed under System, whose accent is the one in System Settings — a menu
                // that took the click and changed nothing would be worse.
                Picker("Accent", selection: $themeAccent) {
                    ForEach(ThemeAccent.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(themeFlavor == ThemeFlavor.system.rawValue)
                Divider()
                Button("Next Game") { state.nextGame() }
                    .keyboardShortcut(shortcuts.equivalent(.nextGame),
                                      modifiers: shortcuts.modifiers(.nextGame))
                    .disabled(state.aSheetIsUp)
                // All of them, always, in a submenu: a key that only exists with a split card
                // would beep at you on any other, where this can say why.
                Menu("Go to Game") {
                    Button("All") { state.showGame(number: 0) }
                        .keyboardShortcut("0", modifiers: .command)
                    let games = state.cardGames
                    ForEach(1...Shortcuts.gameKeys, id: \.self) { number in
                        Button(games.indices.contains(number - 1)
                               ? state.gameLabel(games[number - 1]) : "Game \(number)") {
                            state.showGame(number: number)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    }
                }
                .disabled(state.aSheetIsUp)
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
                Toggle("Check Rosters for Changes", isOn: $rosterWatch.enabled)
                    .help("Asks the league once a day whether the rosters you have in play have "
                          + "changed, and marks the team if so. Nothing changes until you say.")
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
