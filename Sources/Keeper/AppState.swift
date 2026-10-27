import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by the key monitor when an arrow key should move the preview. A notification
    /// rather than a call, because the monitor runs outside the main actor and `AppState`
    /// lives on it — `ContentView` picks this up and does the move where it's safe to.
    /// `userInfo["delta"]` is -1 or 1.
    static let keeperMoveSelection = Notification.Name("keeperMoveSelection")
    static let keeperClearTags = Notification.Name("keeperClearTags")

    /// Posted by `TagLibrary` when it has just written a rolling backup, so the Restore
    /// menu's cached list picks it up without the menus listing the folder on every rebuild.
    static let keeperLibraryBackedUp = Notification.Name("keeperLibraryBackedUp")
}

@MainActor
final class AppState: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case isKeep = "IS KEEP"
        case isNotKeep = "IS NOT KEEP"
        case all = "ALL"
        var id: String { rawValue }
    }

    /// How a copy lays out its destination folder.
    enum Grouping: String, CaseIterable, Identifiable {
        case flat = "One folder"
        case byPlayer = "Folder per player"
        case byCategory = "Folder per category"
        var id: String { rawValue }
    }

    let library = TagLibrary.shared

    @Published var root: URL?
    @Published var clips: [Clip] = []
    @Published var unmatchedXML: [URL] = []
    @Published var videosWithoutXML: [URL] = []
    @Published var isScanning = false
    /// Both of the long jobs recompute the sleep hold when they start and stop, rather than
    /// taking and releasing it inside their own bodies. See `refreshSleepHold`.
    @Published var isCopying = false {
        didSet { refreshSleepHold() }
    }

    // Copy progress, measured in bytes rather than file count so a 470 MB clip
    // doesn't count the same as its 3 KB sidecar.
    @Published var copyFilesDone = 0
    @Published var copyFilesTotal = 0
    @Published var copyBytesDone: Int64 = 0
    @Published var copyBytesTotal: Int64 = 0

    var copyFraction: Double {
        guard copyBytesTotal > 0 else { return 0 }
        return min(1, Double(copyBytesDone) / Double(copyBytesTotal))
    }

    /// Whether to hold the Mac awake during a transfer. On unless you turn it off, and the
    /// switch takes effect straight away — turning it off mid-copy lets go immediately rather
    /// than waiting for that copy to finish.
    ///
    /// Nothing about the hold outlives the app: the assertion belongs to the process, so
    /// quitting Keeper releases it whatever this is set to.
    @Published var keepAwakeDuringTransfer = true {
        didSet {
            UserDefaults.standard.set(keepAwakeDuringTransfer, forKey: "keepAwakeDuringTransfer")
            refreshSleepHold()
        }
    }

    /// Holds the Mac awake while either long job is running, and lets go when neither is — or
    /// when you've switched it off.
    ///
    /// Driven from `didSet` on all three inputs rather than from inside the jobs, so no early
    /// return, thrown error or aborted copy can leave the assertion held — a leaked one is
    /// invisible and would quietly keep the machine awake until Keeper quits.
    ///
    /// It only holds off *idle* sleep. Closing a laptop lid still sleeps the Mac mid-copy,
    /// which is worth knowing before trusting a long transfer to a closed MacBook.
    private func refreshSleepHold() {
        let wanted = SleepGuard.shouldHold(copying: isCopying,
                                           verifying: isVerifying,
                                           enabled: keepAwakeDuringTransfer)
        guard SleepGuard.shared.keepAwake(wanted) else { return }

        // Only the moments it actually changes, not every recomputation.
        if wanted {
            addLog("Keeping the Mac awake for the transfer (idle sleep only — closing the "
                   + "lid will still sleep it)")
        } else if isCopying || isVerifying {
            // The hold went away while a job is still running, so the setting is what moved.
            // Worth saying loudly: this is the one combination that can cost you a transfer.
            addLog("⚠︎ Keep Awake switched off while a transfer is running — the Mac can now "
                   + "idle to sleep before it finishes")
        } else {
            addLog("Letting the Mac sleep normally again")
        }
    }
    @Published var log: [String] = []
    @Published var status = "Choose a card, drive or folder to begin."

    /// Switching filter clears the selection, so the drag set never silently means
    /// "everything in the new filter" while stale rows are still ticked.
    @Published var filter: Filter = .isKeep {
        didSet {
            guard filter != oldValue else { return }
            selection = []
            // Also the preview: keeping it would show a clip from the filter you just left.
            // A KEEP toggle deliberately doesn't do this — see `previewClip`.
            lastSelected = nil
        }
    }

    /// Tracks the most recently added row so the preview follows the clip you just clicked.
    @Published private(set) var lastSelected: URL? {
        didSet {
            // No preview means no place to carry on from. Six things clear this — a filter
            // change, each tag filter, a rescan — and every one of them is a fresh start,
            // so the positional anchor has to go with it or the arrows resume at a stale
            // index. Doing it here rather than at each site means a seventh can't forget.
            if lastSelected == nil { lastVisibleIndex = nil }
        }
    }
    @Published var selection = Set<URL>() {
        didSet {
            if let added = selection.subtracting(oldValue).first {
                lastSelected = added
            } else if let last = lastSelected, !selection.contains(last) {
                lastSelected = selection.first
            }
        }
    }

    @Published var debugMode: Bool = false {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }
    @Published var includeXML: Bool = true {
        didSet { UserDefaults.standard.set(includeXML, forKey: "includeXML") }
    }
    @Published var keepWord: String {
        didSet { UserDefaults.standard.set(keepWord, forKey: "keepWord") }
    }

    // Tag filtering and export layout
    /// Narrows the clip list and, more usefully, the player menu — one roster at a time
    /// instead of every player of every team in one list.
    @Published var filterTeamID: String? {
        didSet {
            guard filterTeamID != oldValue else { return }
            // A player filter from another team would make the list permanently empty.
            if let player = filterPlayerID, let team = filterTeamID, !player.hasPrefix("\(team)/") {
                filterPlayerID = nil
            }
            selection = []
        }
    }
    @Published var filterPlayerID: String? { didSet { if filterPlayerID != oldValue { selection = [] } } }
    @Published var filterCategory: String? { didSet { if filterCategory != oldValue { selection = [] } } }
    @Published var filterPosition: String? { didSet { if filterPosition != oldValue { selection = [] } } }
    @Published var grouping: Grouping = .flat
    @Published var renamePresetID: UUID?

    // MARK: Tagging flow

    /// The rosters in play, in the order they were chosen. See `activeTeams` in TagFlow.swift.
    @Published var activeTeamIDs: [String] = [] {
        didSet { UserDefaults.standard.set(activeTeamIDs, forKey: "activeTeamIDs") }
    }

    /// Which of the rosters in play is showing on its own, or nil for all of them. Both
    /// benches at once is a long grid to read; this narrows it without taking the other
    /// team out of play.
    @Published var focusedTeamID: String? {
        didSet {
            guard focusedTeamID != oldValue else { return }
            UserDefaults.standard.set(focusedTeamID, forKey: "focusedTeamID")
            // The cursor indexes the grid, and the grid just changed length.
            playerCursor = 0
            numberEntry = ""
            categoryEntry = ""
            subjectsOnly = false
        }
    }

    /// Whether ⌘K on the previewed clip moves to the next one afterwards. On by default:
    /// marking is a pass down the card, and stopping on each clip you just dealt with means
    /// a second keystroke every time. ⌘Z takes a mark back either way.
    @Published var advanceAfterMark: Bool = true {
        didSet { UserDefaults.standard.set(advanceAfterMark, forKey: "advanceAfterMark") }
    }

    /// Hands the keyboard to the tagging flow: clip, player, category, next clip.
    @Published var keyboardFlow: Bool = false {
        didSet {
            UserDefaults.standard.set(keyboardFlow, forKey: "keyboardFlow")
            FlowKeyState.shared.active = keyboardFlow
            if keyboardFlow {
                // A mode that takes over Tab, Return and the arrows must not be invisible,
                // and the strip saying where the keyboard is lives in the tagging panel —
                // which ⌘E can hide. Same key `@AppStorage` reads, so the panel opens.
                UserDefaults.standard.set(true, forKey: "showTagging")
            } else {
                resetFlow()
            }
        }
    }

    /// Mirrored for the key monitor, which can't read this class — see `FlowKeyState`.
    @Published var tagStage: TagStage = .clips {
        didSet { FlowKeyState.shared.stage = tagStage }
    }

    @Published var playerCursor = 0
    @Published var categoryCursor = 0
    /// Which category section ← → have landed on. Survives leaving and re-entering the
    /// stage, so tagging a run of crowd shots doesn't mean arrowing back each time.
    @Published var categorySectionIndex = 0
    /// Digits typed at the player stage, shown on screen so a half-typed number is never
    /// a mystery.
    @Published var numberEntry = ""
    /// Digits typed at the category stage, narrowing the grid by position the way
    /// `numberEntry` narrows the bench by shirt number.
    @Published var categoryEntry = ""
    /// Narrows the bench to the subjects — mascot, crowd, anthem and the rest — leaving the
    /// players out. Toggled by the key bound to `.subjectsOnly`, and only at the bench.
    @Published var subjectsOnly = false

    /// Whether the subjects key is held down rather than pressed to toggle. Off by default:
    /// a toggle is the gentler of the two, and a hold is only better once you know the key
    /// well enough to want it under a finger.
    @Published var subjectsKeyIsHold = false {
        didSet {
            UserDefaults.standard.set(subjectsKeyIsHold, forKey: "subjectsKeyIsHold")
            FlowKeyState.shared.holdSubjects = subjectsKeyIsHold
            // Switching modes with the filter up would leave it stuck on in hold mode, with
            // no key-up ever coming to clear it.
            subjectsOnly = false
        }
    }
    @Published var flowPlayerID: String?

    /// One key press acts once, however many windows heard about it.
    var lastFlowToken = 0

    // MARK: Export

    enum ExportScope: String, CaseIterable, Identifiable {
        case selection, shown
        var id: String { rawValue }
    }

    enum ExportDestination: String, CaseIterable, Identifiable {
        case inPlace, copy
        var id: String { rawValue }
    }

    @Published var exportScope: ExportScope = .shown
    @Published var exportDestination: ExportDestination = .copy
    @Published var exportFolder: URL?
    /// Drive the sheets. They live here rather than in the view so the menus can open them.
    @Published var showExportSheet = false
    @Published var showPresetEditor = false
    @Published var showRosterEditor = false
    @Published var showShortcutsSheet = false

    // MARK: - The welcome sheet

    /// Opens by itself on a first launch, and from Help → Welcome & Tutorial after that.
    @Published var showWelcome = false

    /// What the tutorial offered to do for you, held until the sheet has closed. Deliberately
    /// not `@Published`: it's read once, by `ContentView`'s `onDismiss`, and republishing the
    /// whole state to announce it would be noise.
    var pendingWelcomeAction: WelcomeAction?

    /// Guards against offering the tutorial twice in one run. `ContentView.onAppear` can fire
    /// again for the same state, and a second window gets its own `onAppear` over the same
    /// `AppState` — two views racing to present one sheet is how you get a sheet that doesn't
    /// appear at all.
    private var welcomeOffered = false

    /// Offers the tutorial on a first launch. Called from `onAppear` rather than decided in
    /// `init`, so the window exists before a sheet is asked to sit on it — a sheet presented
    /// during the very first layout pass is the kind of thing that works on one macOS version
    /// and silently doesn't on the next.
    ///
    /// `bool(forKey:)` would read false for a key that was never set and for one set to false
    /// alike, which is why the absence is what's checked.
    func offerWelcomeIfFirstLaunch() {
        guard !welcomeOffered else { return }
        welcomeOffered = true
        guard UserDefaults.standard.object(forKey: "welcomeShown") == nil else { return }
        showWelcome = true
    }

    /// Called when the sheet is finished with — either button, or Skip at any step.
    ///
    /// The flag is written here rather than when the sheet opens, so a first launch that's
    /// force-quit or crashes while the sheet is up still offers the tutorial next time. The
    /// cost of getting that wrong is asymmetric: being asked twice is a shrug, never being
    /// offered it at all is the feature silently not existing.
    func finishWelcome() {
        showWelcome = false
        UserDefaults.standard.set(true, forKey: "welcomeShown")
    }

    /// Run from the sheet's `onDismiss`, once the sheet has actually gone — both of these open
    /// a modal panel, which can't be put up from inside a sheet that's still on screen.
    /// Clears as it fires, so reopening the tutorial and skipping doesn't repeat the last one.
    func runPendingWelcomeAction() {
        guard let action = pendingWelcomeAction else { return }
        pendingWelcomeAction = nil
        switch action {
        case .chooseFolder: chooseCard()
        case .importRoster: importRoster()
        }
    }

    /// Set by a successful import so the tagging panel can jump to the roster that just
    /// arrived. It lives here because importing is now a File menu command as well as a
    /// button in the panel, and the panel isn't always on screen to run it.
    @Published var lastImportedTeamID: String?
    @Published var importMessage: String?

    // MARK: - Verifying a card reached its destinations

    @Published var showVerifySheet = false
    @Published var verifyDestinations: [URL] = []
    @Published var verifyReport: Verifier.Report?
    @Published var isVerifying = false {
        didSet { refreshSleepHold() }
    }

    func addVerifyDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Where did you copy this card's footage?"
        guard panel.runModal() == .OK else { return }

        var refused: [String] = []
        for url in panel.urls where !verifyDestinations.contains(url) {
            // The card can't vouch for itself. Comparing a folder against itself, or against
            // anything containing it, matches every clip and reports the card safe to format
            // — the exact outcome this feature exists to prevent.
            if let root, overlaps(url, root) {
                refused.append(url.lastPathComponent)
                continue
            }
            verifyDestinations.append(url)
        }

        if !refused.isEmpty {
            status = "\(refused.joined(separator: ", ")): that's the footage you scanned, not a "
                + "copy of it. Add the folder you copied it to."
        }
        verifyReport = nil
    }

    /// True when either folder is the other, or sits inside it.
    private func overlaps(_ a: URL, _ b: URL) -> Bool {
        let one = FileUtil.folderPath(a), two = FileUtil.folderPath(b)
        return one.hasPrefix(two) || two.hasPrefix(one)
    }

    func runVerify() {
        guard !isVerifying, !isScanning, !clips.isEmpty, !verifyDestinations.isEmpty else { return }
        if let root, let clash = verifyDestinations.first(where: { overlaps($0, root) }) {
            status = "\(clash.lastPathComponent) is the footage you scanned, not a copy of it. "
                + "Remove it before checking."
            return
        }
        isVerifying = true
        verifyReport = nil
        status = "Checking \(clips.count) clips against \(verifyDestinations.count) folder(s)…"
        let source = clips
        let destinations = verifyDestinations
        let word = keepWord
        Task.detached(priority: .userInitiated) {
            let report = Verifier.verify(source: source, destinations: destinations, keepWord: word)
            await MainActor.run {
                self.verifyReport = report
                self.isVerifying = false
                self.status = report.summary
                self.addLog("Verify: " + report.summary)
                self.appendLog(report.log)
                for result in report.missing {
                    self.addLog("✗ \(result.name) is not in any of those folders")
                }
                for result in report.wrongSize {
                    if case .wrongSize(let found) = result.outcome {
                        self.addLog("✗ \(result.name): \(FileUtil.sizeText(found)) there, "
                                    + "\(FileUtil.sizeText(result.sourceSize)) on the card")
                    }
                }
            }
        }
    }

    /// The tag filters point at a team, a player or a position by value, and a roster edit
    /// can move or remove any of them — renumbering #15 changes that player's id, deleting a
    /// team takes its players with it. A filter aimed at something that no longer exists
    /// shows an empty clip list with nothing in the menus to explain why, so it's dropped.
    func dropDanglingFilters() {
        if let id = filterTeamID, library.team(id: id) == nil {
            filterTeamID = nil
        }
        if let id = filterPlayerID, !library.allPlayers.contains(where: { $0.id == id }) {
            filterPlayerID = nil
        }
        if let position = filterPosition,
           !library.allPlayers.contains(where: { $0.position == position }) {
            filterPosition = nil
        }
        // Removing a section takes its categories with it, and a one-off ages out on its
        // own. Either way the filter bar would go on claiming to filter by something the
        // menu no longer offers, with no way to clear it but Clear.
        if let category = filterCategory, !library.allCategories.contains(category) {
            filterCategory = nil
        }
    }

    func importRoster() {
        // As with `requestExport`: don't put a file picker in front of someone who was
        // trying to record ⌘I.
        guard !showShortcutsSheet else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.message = "Choose a roster CSV: team, number, name"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try library.importRoster(from: url)
            importMessage = "Imported \(result.players) players."
            status = "Imported \(result.players) players from \(result.team)."
                + (result.tagsUpdated > 0 ? " Updated \(result.tagsUpdated) existing tag(s)." : "")
            // A multi-team file reports "13 teams" rather than a name, which won't resolve —
            // the panel falls back to whatever's first in that case.
            let imported = Team.slug(result.team)
            lastImportedTeamID = library.team(id: imported) != nil ? imported : library.teams.first?.id
        } catch {
            importMessage = error.localizedDescription
            status = "Roster import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Library backups

    /// The past versions the Restore menu offers.
    ///
    /// Cached rather than read from the folder on demand: the menus are rebuilt every time
    /// anything here changes, including each file of a copy, and a directory listing per
    /// progress tick is the kind of cost that doesn't show up until a card is full.
    /// `ContentView` refreshes it on launch and whenever a new backup is written.
    @Published private(set) var libraryBackups: [TagLibrary.Backup] = []

    func refreshBackups() {
        libraryBackups = library.backups()
    }

    private static let backupLabelFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func backupLabel(_ backup: TagLibrary.Backup) -> String {
        "\(backupLabelFormat.string(from: backup.date))  ·  \(FileUtil.sizeText(backup.size))"
    }

    /// Asks first, because it replaces every tag in one go, and then says what it did.
    func restoreLibrary(from backup: TagLibrary.Backup) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore the tag library from "
            + "\(Self.backupLabelFormat.string(from: backup.date))?"
        alert.informativeText = "Every team, player, tag, category and preset goes back to how "
            + "it was then, and anything added since is gone from the library.\n\nThe version "
            + "you have now is backed up first, so this can be undone the same way. Nothing on "
            + "your cards or drives is touched either way."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let summary = try library.restore(from: backup.url)
            addLog("Restored the tag library from \(backup.url.lastPathComponent)")
            status = summary
            // The filters point at teams and players by value, and the restored roster
            // may not have them.
            dropDanglingFilters()
            selection = []
            refreshBackups()      // restoring takes a backup of its own first
        } catch {
            addLog("Restore failed: \(error.localizedDescription)")
            status = error.localizedDescription
        }
    }

    func revealBackups() {
        NSWorkspace.shared.activateFileViewerSelecting([TagLibrary.backupFolder])
    }

    /// What the export sheet will act on. Unlike `dragClips`, which infers a scope from
    /// the selection, this is whatever the sheet says it is — chosen deliberately.
    var exportClips: [Clip] {
        switch exportScope {
        case .selection: return visible.filter { selection.contains($0.id) }
        case .shown:     return visible
        }
    }

    var selectedCount: Int { visible.filter { selection.contains($0.id) }.count }

    /// Plain-English description of what the filters are currently showing.
    var filterSummary: String {
        var parts = [filter.rawValue]
        if let id = filterTeamID, let team = library.team(id: id) { parts.append(team.name) }
        if let id = filterPlayerID,
           let player = library.allPlayers.first(where: { $0.id == id }) { parts.append(player.label) }
        if let position = filterPosition { parts.append(position) }
        if let category = filterCategory { parts.append(category) }
        return parts.joined(separator: " · ")
    }

    /// The folder in-place renaming would act on, when they're all in one.
    var exportSourceFolder: URL? {
        let folders = Set(exportClips.map { $0.videoURL.deletingLastPathComponent() })
        return folders.count == 1 ? folders.first : nil
    }

    var exportIsOnCard: Bool {
        exportClips.contains { FileUtil.looksLikeCameraCard($0.videoURL) }
    }

    /// One example of the renaming, for the sheet's preview.
    var exportNameExample: (from: String, to: String)? {
        guard let preset = activePreset, let clip = exportClips.first else { return nil }
        let tags = library.tags(forUMID: clip.umid)
        let rosterCode = library
            .team(id: Renamer.topTag(of: tags, priority: library.allCategories)?.teamID)
            .flatMap(\.code)
        let base = Renamer.baseName(for: clip, tags: tags, preset: preset,
                                    priority: library.allCategories, rosterCode: rosterCode)
        return (clip.name, "\(base).\(clip.videoURL.pathExtension)")
    }

    /// How many copies of one clip this layout makes. Only per-player ever makes more than
    /// one, and only for a clip tagged to several players. Must agree with `copyPlan()`.
    private func copiesPerClip(_ clip: Clip) -> Int {
        guard grouping == .byPlayer else { return 1 }
        let players = Set(library.tags(forUMID: clip.umid).compactMap(\.folderSafePlayer))
        return max(1, players.count)
    }

    /// Both of these run on every redraw of the sheet, so they use the sizes the scan
    /// already recorded rather than stat'ing every file again — which on a card full of
    /// clips made the radio buttons feel sticky.
    var exportFileCount: Int {
        guard exportDestination == .copy else { return exportClips.count }
        let perCopy = includeXML ? 2 : 1
        return exportClips.reduce(0) { $0 + perCopy * copiesPerClip($1) }
    }

    var exportSize: Int64 {
        guard exportDestination == .copy else { return exportClips.reduce(0) { $0 + $1.totalSize } }
        return exportClips.reduce(Int64(0)) { running, clip in
            let each = clip.videoSize + (includeXML ? clip.xmlSize : 0)
            return running + each * Int64(copiesPerClip(clip))
        }
    }

    var exportFlagChanges: Int { exportClips.filter { isKeepChanged($0) }.count }

    /// How many clips would actually get a new name. Anything already named correctly is
    /// left alone, so the button can say the real number rather than the scope's.
    var exportRenameCount: Int {
        guard let preset = activePreset else { return 0 }
        return exportClips.filter { clip in
            let tags = library.tags(forUMID: clip.umid)
            let rosterCode = library
                .team(id: Renamer.topTag(of: tags, priority: library.allCategories)?.teamID)
                .flatMap(\.code)
            let base = Renamer.baseName(for: clip, tags: tags, preset: preset,
                                        priority: library.allCategories, rosterCode: rosterCode)
            return base != clip.videoURL.deletingPathExtension().lastPathComponent
        }.count
    }

    /// Clips in this export that already live in the copy destination, or anywhere under it.
    /// Copying those is how you end up with the footage twice — the original under the
    /// camera's name and a copy under the new one — which is the whole reason renaming in
    /// place exists. It's remembering the last destination that makes this easy to walk
    /// into: offload to Cam A, come back later to tag Cam A, and the sheet is still aimed
    /// at Cam A.
    var exportClipsInsideDestination: Int {
        guard exportDestination == .copy, let dest = exportFolder else { return 0 }
        let destPath = FileUtil.folderPath(dest)
        // Resolving a path touches the disk, and this runs on every redraw of the sheet,
        // so each distinct folder is judged once — usually there's only one.
        var verdicts: [URL: Bool] = [:]
        return exportClips.filter { clip in
            let folder = clip.videoURL.deletingLastPathComponent()
            if let known = verdicts[folder] { return known }
            let inside = FileUtil.folderPath(folder).hasPrefix(destPath)
            verdicts[folder] = inside
            return inside
        }.count
    }

    /// Something worth reading before pressing the button, but the caller's decision to make.
    /// Unlike `exportBlocker` this doesn't disable anything — it only takes away the Return
    /// key, so the action has to be clicked deliberately.
    var exportCaution: String? {
        let inside = exportClipsInsideDestination
        guard inside > 0 else { return nil }
        let all = inside == exportClips.count
        return (all ? "These clips are already in that folder" :
                      "\(inside) of these clips are already in that folder")
            + ". Copying them there leaves you with the same footage twice, once under each "
            + "name. To get the new names without a second copy, choose “Rename them where "
            + "they already are”."
    }

    var exportBlocker: String? {
        if exportClips.isEmpty {
            return exportScope == .selection
                ? "Nothing is selected. Pick some clips, or switch to everything the filter is showing."
                : "Nothing to export — the filter isn't showing any clips."
        }
        if exportDestination == .inPlace {
            if exportIsOnCard {
                return "These files are on a camera card. Keeper only reads cards, so copy them off first."
            }
            if activePreset == nil {
                return "Renaming needs a filename preset."
            }
            if exportRenameCount == 0, exportFlagChanges == 0 {
                return "Nothing to do — these clips are already named correctly."
            }
        }
        if exportDestination == .copy {
            guard let folder = exportFolder else {
                return "Choose where the copies should go."
            }
            if !FileUtil.isReachableFolder(folder) {
                return "That folder isn't there any more. Is the drive still plugged in?"
            }
            // Writing into a camera's own folder structure is the one thing Keeper promises
            // never to do, and a changed flag would otherwise be written into the sidecar
            // sitting there — which is the original.
            if FileUtil.looksLikeCameraCard(folder) {
                return "That folder is inside a camera card's own structure. Keeper only ever "
                     + "reads those — pick somewhere else to copy to."
            }
        }
        return nil
    }

    /// Opens the sheet. The scope starts as whatever you'd expect from what you were just
    /// doing: a selection if you made one, otherwise everything in view.
    func requestExport() {
        // While the shortcuts sheet is recording a key, a ⌘ combo is meant for the recorder.
        // The event monitor should get it first, but this is cheap and means the worst case
        // is a key that didn't record rather than an export sheet appearing underneath.
        guard !showShortcutsSheet else { return }
        guard !isCopying, !isScanning, !visible.isEmpty else { return }
        exportScope = selectedCount > 0 ? .selection : .shown
        // Scope first, because this reads it. Footage on a card can only be copied off, so
        // the sheet doesn't open on an option that's already blocked.
        if exportIsOnCard { exportDestination = .copy }
        showExportSheet = true
    }

    func runExport() {
        guard exportBlocker == nil else { return }
        switch exportDestination {
        case .inPlace:
            renameInPlace()
        case .copy:
            if let folder = exportFolder { copy(to: folder) }
        }
    }

    init() {
        keepWord = UserDefaults.standard.string(forKey: "keepWord") ?? "KEEP"
        if UserDefaults.standard.object(forKey: "includeXML") != nil {
            includeXML = UserDefaults.standard.bool(forKey: "includeXML")
        }
        debugMode = UserDefaults.standard.bool(forKey: "debugMode")

        // Which teams you're shooting outlasts a relaunch — a game doesn't end because
        // the app was quit between periods.
        if UserDefaults.standard.object(forKey: "advanceAfterMark") != nil {
            advanceAfterMark = UserDefaults.standard.bool(forKey: "advanceAfterMark")
        }
        activeTeamIDs = UserDefaults.standard.stringArray(forKey: "activeTeamIDs") ?? []
        focusedTeamID = UserDefaults.standard.string(forKey: "focusedTeamID")
        keyboardFlow = UserDefaults.standard.bool(forKey: "keyboardFlow")
        subjectsKeyIsHold = UserDefaults.standard.bool(forKey: "subjectsKeyIsHold")
        // On unless it's been turned off, so the absence of the key is what's tested —
        // `bool(forKey:)` reads false for never-set and for false alike.
        if UserDefaults.standard.object(forKey: "warnBeforeClearingTags") != nil {
            warnBeforeClearingTags = UserDefaults.standard.bool(forKey: "warnBeforeClearingTags")
        }
        // On unless it's been turned off, so the absence of the key has to be the test —
        // `bool(forKey:)` reads false for never-set and for false alike.
        if UserDefaults.standard.object(forKey: "keepAwakeDuringTransfer") != nil {
            keepAwakeDuringTransfer = UserDefaults.standard.bool(forKey: "keepAwakeDuringTransfer")
        }
        // Whatever stage it was left at means nothing now: the flow always starts on clips.
        tagStage = .clips

    }

    // MARK: - Derived state

    /// What the app treats as KEEP: your own mark if you've set one, otherwise the camera's.
    func isKeep(_ clip: Clip) -> Bool {
        library.keepOverride(for: clip.umid) ?? clip.isKeep
    }

    /// True when you've changed it from what the card says.
    func isKeepChanged(_ clip: Clip) -> Bool {
        library.keepOverride(for: clip.umid) != nil
    }

    var visible: [Clip] {
        var list: [Clip]
        switch filter {
        case .isKeep:    list = clips.filter { isKeep($0) }
        case .isNotKeep: list = clips.filter { !isKeep($0) }
        case .all:       list = clips
        }
        if let filterTeamID {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.teamID == filterTeamID }
            }
        }
        if let filterPlayerID {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.playerID == filterPlayerID }
            }
        }
        if let filterCategory {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.category == filterCategory }
            }
        }
        if let filterPosition {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.playerPosition == filterPosition }
            }
        }
        return list
    }

    /// Moves the preview one clip up or down the list you're looking at, replacing whatever
    /// was selected. This is what the arrow keys do, and what auto-advance does after a tag.
    ///
    /// Clamped rather than wrapped: running off the end of a card and landing back at the top
    /// loses your place in a way that isn't obvious until you've tagged the wrong clip.
    /// Returns false when there was nowhere to go, so the key press can fall through.
    /// `selectRelative`, but acting on each key press only once however many windows heard
    /// about it. The token comes from the key monitor, which counts the presses.
    private var lastMoveToken = 0
    private var lastClearToken = 0

    /// Whether clearing tags asks first. On unless you've turned it off, because the one
    /// press that wipes tags off a whole card is worth a question the first few times.
    @Published var warnBeforeClearingTags = true {
        didSet {
            UserDefaults.standard.set(warnBeforeClearingTags,
                                      forKey: "warnBeforeClearingTags")
        }
    }

    func moveSelection(_ delta: Int, token: Int) {
        guard token != lastMoveToken else { return }
        lastMoveToken = token
        selectRelative(delta)
    }

    /// Anything of ours that's taken over the window. The export and verify sheets both
    /// show a count of what they're about to act on, and that count must not move under them.
    var aSheetIsUp: Bool {
        showExportSheet || showVerifySheet || showRosterEditor
            || showPresetEditor || showShortcutsSheet || showWelcome
    }

    @discardableResult
    func selectRelative(_ delta: Int) -> Bool {
        // Second line of defence behind the key monitor's own guards. Picking an export
        // folder with the arrow keys used to land here and replace the whole selection with
        // one clip — the sheet went on saying "the 1 clip you've selected" over a set you'd
        // just assembled. Whatever reaches this while a sheet is deciding what to act on,
        // the answer is no.
        guard !aSheetIsUp else { return false }

        let list = visible
        guard !list.isEmpty, delta != 0 else { return false }

        let target: Int
        if let current = lastSelected, let index = list.firstIndex(where: { $0.id == current }) {
            target = index + delta
            guard target >= 0, target < list.count else { return false }   // already at the end
            lastVisibleIndex = index
        } else if let anchor = lastVisibleIndex {
            // The previewed clip has left the filter, which is exactly what marking it KEEP
            // while filtering by KEEP does. Carry on from where it was sitting: the clip
            // that was after it has slid into its place, so the anchor *is* the next one.
            // Without this the lookup fails, the "nothing selected yet" case below takes
            // over, and marking a clip sends you back to the top of the card.
            let clamped = max(0, min(anchor, list.count - 1))
            target = delta > 0 ? clamped : max(0, clamped - 1)
        } else {
            // Nothing selected yet, so start at whichever end you were heading for.
            target = delta > 0 ? 0 : list.count - 1
        }

        let clip = list[target]
        selection = [clip.id]
        // The didSet above infers this from what was added, but only when the id wasn't
        // already in the set. Setting it outright means the preview follows even then.
        lastSelected = clip.id
        lastVisibleIndex = target
        return true
    }

    /// Where the previewed clip sits in the filtered list, remembered so the arrows can
    /// carry on from there after it has dropped out of the filter. See `selectRelative`.
    private var lastVisibleIndex: Int?

    /// ⌘K on the previewed clip: flip the flag and move on. That's the review pass — watch,
    /// mark, next — and it's why this exists rather than the menu calling `toggleKeep`
    /// directly. Clicking a row's badge deliberately doesn't advance: that click is aimed at
    /// one clip, and moving the preview off it would be a surprise.
    func toggleKeepOnPreview() {
        guard let clip = previewClip else { return }
        // Only moves on if the flag actually changed. A clip with no UMID can't be marked,
        // and advancing anyway would walk silently past it.
        guard toggleKeep(clip) else { return }
        if advanceAfterMark { advanceAfterAction() }
    }

    /// Moves to the next clip after something that finished on its own — a mark, a tag.
    ///
    /// Refuses while several clips are picked out by hand. Advancing replaces the whole
    /// selection with one clip, so a set you'd assembled for export would quietly become a
    /// single clip the moment you marked or tagged one of them. An arrow key still
    /// collapses it, because that one is you asking to move.
    @discardableResult
    func advanceAfterAction() -> Bool {
        guard selectedCount <= 1 else { return false }
        return selectRelative(1)
    }

    var isTagFiltered: Bool {
        filterTeamID != nil || filterPlayerID != nil || filterCategory != nil || filterPosition != nil
    }

    func clearTagFilters() {
        filterTeamID = nil
        filterPlayerID = nil
        filterCategory = nil
        filterPosition = nil
    }

    /// The rosters the player menu should offer: just the chosen team, or all of them.
    var teamsForFilter: [Team] {
        guard let filterTeamID, let team = library.team(id: filterTeamID) else { return library.teams }
        return [team]
    }

    var keepCount: Int { clips.filter { isKeep($0) }.count }
    var notKeepCount: Int { clips.count - keepCount }
    var taggedCount: Int { clips.filter { library.isTagged($0.umid) }.count }
    var changedKeepCount: Int { clips.filter { isKeepChanged($0) }.count }

    // MARK: Sizes
    //
    // Video plus sidecar, from the figures taken during the scan — the same basis as the
    // export sheet's total, so the two agree. Nothing here stats a file.

    private func bytes(of list: [Clip]) -> Int64 {
        list.reduce(Int64(0)) { $0 + $1.totalSize }
    }

    var keepBytes: Int64 { bytes(of: clips.filter { isKeep($0) }) }
    var notKeepBytes: Int64 { bytes(of: clips.filter { !isKeep($0) }) }
    var allBytes: Int64 { bytes(of: clips) }
    /// What the filter is showing, tag filters included.
    var visibleBytes: Int64 { bytes(of: visible) }

    /// All three at once, for the tooltip — the question is usually "will this fit", and
    /// that's easier to answer with the other two in front of you.
    var sizeBreakdown: String {
        """
        KEEP: \(FileUtil.sizeText(keepBytes)) over \(keepCount) clip(s)
        NOT KEEP: \(FileUtil.sizeText(notKeepBytes)) over \(notKeepCount) clip(s)
        Everything: \(FileUtil.sizeText(allBytes)) over \(clips.count) clip(s)

        The figure beside this is what the filter is showing.
        """
    }

    // MARK: - Marking KEEP

    /// Flips one clip. Nothing is written to the card — the change lives in the library
    /// until the clip is copied out, and then only the copied sidecar is edited.
    ///
    /// Returns false when there was nothing to flip, so a caller that moves on afterwards
    /// doesn't walk past a clip it never marked.
    @discardableResult
    func toggleKeep(_ clip: Clip) -> Bool {
        guard let umid = clip.umid else {
            status = "\(clip.name) has no UMID in its XML, so its flag can't be changed."
            return false
        }
        // Noted before the flag changes, and only for the clip in the viewer: flipping it
        // can take it out of the filtered list, and the arrows then have nowhere to carry
        // on from — which is how marking a clip used to send you back to the top. A badge
        // click on some other row deliberately leaves the anchor where the preview is.
        if lastSelected == clip.id,
           let index = visible.firstIndex(where: { $0.id == clip.id }) {
            lastVisibleIndex = index
        }

        let next = !isKeep(clip)
        library.setKeep(next, umid: umid, cameraFlag: clip.isKeep,
                        undoLabel: "Mark \(clip.name) \(next ? "KEEP" : "NOT KEEP")")
        status = "\(clip.name) marked \(next ? "KEEP" : "NOT KEEP")"
            + (next == clip.isKeep ? " (back to the camera's flag)." : ", applied when you copy it.")
            + undoHint
        return true
    }

    /// Sets every clip in scope the same way, rather than flipping each individually.
    func setKeepInScope(_ keep: Bool) {
        let targets = dragClips.compactMap { clip -> (umid: String, cameraFlag: Bool)? in
            guard let umid = clip.umid else { return nil }
            return (umid, clip.isKeep)
        }
        guard !targets.isEmpty else { return }
        let word = keep ? "KEEP" : "NOT KEEP"
        let changed = library.setKeep(keep, for: targets,
                                      undoLabel: "Mark \(targets.count) Clip(s) \(word)")
        guard changed > 0 else {
            status = "Those \(targets.count) clip(s) are already \(word)."
            return
        }
        let scope = hasExplicitSelection ? "selected" : "shown"
        status = "Marked \(targets.count) \(scope) clip(s) \(word)." + undoHint
    }

    func revertKeepInScope() {
        let umids = dragClips.compactMap(\.umid)
        let reverted = library.clearKeepOverrides(
            umids: umids,
            undoLabel: "Revert \(umids.count) Clip(s) to the Camera's Flags")
        guard reverted > 0 else { return }
        status = "Reverted \(reverted) clip(s) to the camera's own flag." + undoHint
    }

    // MARK: - Undo

    /// Appended to the status after anything undoable, so the way back is on screen at the
    /// moment it's wanted rather than only in a menu. Hardcoded because ⌘Z isn't one of the
    /// bindable shortcuts — "z" is reserved, so nothing else can take it and undo can't move.
    private var undoHint: String { " ⌘Z to undo." }

    var undoMenuTitle: String {
        library.undoLabel.map { "Undo \($0)" } ?? "Undo"
    }

    var redoMenuTitle: String {
        library.redoLabel.map { "Redo \($0)" } ?? "Redo"
    }

    var canUndo: Bool { library.undoLabel != nil }
    var canRedo: Bool { library.redoLabel != nil }

    /// Undo covers the flags and tags — the things a stray keystroke changes. A roster edit
    /// or a restore is a bigger change than this stack is for; those go back through
    /// File ▸ Restore Tags.
    func undo() {
        guard let label = library.undo() else { return }
        addLog("Undid: \(label)")
        status = "Undid: \(label)."
        afterHistoryChange()
    }

    func redo() {
        guard let label = library.redo() else { return }
        addLog("Redid: \(label)")
        status = "Redid: \(label)."
        afterHistoryChange()
    }

    /// Restoring a tag can bring back a team or position the filters had stopped offering,
    /// and removing one can take the last of them away.
    private func afterHistoryChange() {
        dropDanglingFilters()
    }

    /// The clip shown in the preview pane: the one clicked most recently.
    ///
    /// Falls back to the full scan when that clip is no longer in view. The case that matters
    /// is toggling KEEP while filtering by it: the clip stops matching and leaves the list,
    /// and looking it up only in `visible` would empty the viewer — losing your place and
    /// collapsing the split pane you'd sized. `visible` itself stays strictly filtered, so
    /// the list and anything that exports are unaffected.
    var previewClip: Clip? {
        if let last = lastSelected {
            if let clip = visible.first(where: { $0.id == last }) { return clip }
            if let clip = clips.first(where: { $0.id == last }) { return clip }
        }
        return visible.first { selection.contains($0.id) }
    }

    /// The implicit scope: the selected clips, or everything in the current view when
    /// nothing is selected. Used by the Mark menu and the tag buttons. Export doesn't use
    /// it — the export sheet makes you say which you mean.
    var dragClips: [Clip] {
        let selected = visible.filter { selection.contains($0.id) }
        return selected.isEmpty ? visible : selected
    }

    /// The clips a tag clear acts on: the tagged ones among those you've actually selected.
    ///
    /// Deliberately without the fallback `dragClips` has. Exporting or marking everything on
    /// screen when nothing is picked is a reasonable default — you can see what you're about
    /// to get, and both are reversible in an obvious way. Wiping the tags off everything on
    /// screen is not, and with the warning turned off it would sit one keystroke away at all
    /// times. So clearing tags needs you to say which clips, every time.
    var taggedInScope: [Clip] {
        guard hasExplicitSelection else { return [] }
        return dragClips.filter { library.isTagged($0.umid) }
    }

    var hasExplicitSelection: Bool {
        !visible.filter { selection.contains($0.id) }.isEmpty
    }

    var removeTagsLabel: String {
        let count = taggedInScope.count
        guard count > 0 else { return "No tags to remove" }
        return "Remove tags from \(count) selected"
    }

    /// Destructive and unpickable from the clip list in bulk, so it asks first and spells
    /// out the scope — "all shown" is easy to trigger by not selecting anything.
    /// `token` is only passed when a key press got here, and only to stop a second window
    /// putting up a second alert for the same one. The button passes nothing.
    func removeTagsInScope(token: Int? = nil) {
        if let token {
            guard token != lastClearToken else { return }
            lastClearToken = token
        }
        // A sheet is already asking you something; a second alert over the top of it isn't
        // an answer to anything you did.
        guard !aSheetIsUp else { return }

        // Refused outright rather than falling back to everything on screen. The two
        // reasons read very differently to someone who just pressed the key, so they're
        // told apart rather than sharing one message.
        guard hasExplicitSelection else {
            status = "Select the clips you want to clear tags from first."
            return
        }

        let targets = taggedInScope
        guard !targets.isEmpty else {
            // Said rather than ignored. The button is hidden when there's nothing to remove,
            // so a key press is the only way to get here, and silence would read as broken.
            status = "Nothing tagged in the clips you've selected."
            return
        }
        let tagCount = targets.reduce(0) { $0 + library.tags(forUMID: $1.umid).count }

        let plural = targets.count == 1 ? "" : "s"

        if warnBeforeClearingTags {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove \(tagCount) tag\(tagCount == 1 ? "" : "s")?"
            alert.informativeText =
                "This clears every tag from the \(targets.count) selected clip\(plural)."
                + "\n\n⌘Z puts them back. If you turn this question off, you can bring it "
                + "back with View → Warn Before Clearing Tags."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Remove Tags")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"

            let answer = alert.runModal()
            guard answer != .alertFirstButtonReturn else { return }

            // Only once you've gone through with it. Ticking the box and then cancelling
            // reads as "not this one" at least as much as "stop asking", and of the two
            // readings the safe one is to keep asking.
            if alert.suppressionButton?.state == .on {
                warnBeforeClearingTags = false
                addLog("Clearing tags will no longer ask first "
                       + "(View → Warn Before Clearing Tags puts it back)")
            }
        }

        let removed = library.removeAllTags(
            forUMIDs: targets.compactMap(\.umid),
            undoLabel: "Remove the Tags from \(targets.count) Clip\(plural)")
        addLog("Removed \(removed) tag(s) from \(targets.count) clip(s)")
        // With the warning turned off this line is the only account of what just happened,
        // so it names the clips rather than only counting the tags.
        status = "Removed \(removed) tag\(removed == 1 ? "" : "s") from "
            + "\(targets.count) selected clip\(plural)." + undoHint
    }

    // MARK: - Filing a tag

    /// Builds one tag. The only place a `Tag` is made, so the panel and the keyboard flow
    /// can't drift apart on what goes into one.
    ///
    /// The team comes from the player rather than from whatever the panel is showing. With
    /// two rosters in play those are different things, and a tag that named the wrong bench
    /// would put the clip in the wrong folder on export.
    private func makeTag(for clip: Clip,
                         umid: String,
                         player: Player?,
                         fallbackTeam: Team?,
                         category: String) -> Tag {
        // A subject's team id is a reserved marker, not a team. Filed as-is it would put
        // `subject:mascot` in the tag's teamID, where nothing would ever match it again —
        // so the team is the one you were looking at, exactly as for a tag with no one
        // against it at all.
        let isSubject = player?.isSubject ?? false
        let team = isSubject
            ? fallbackTeam
            : (player.flatMap { library.team(id: $0.teamID) } ?? fallbackTeam)

        return Tag(umid: umid,
                   clipName: clip.name,
                   volumeName: clip.volumeName,
                   path: clip.videoURL.path,
                   teamID: isSubject ? team?.id : (player?.teamID ?? team?.id),
                   teamName: team?.name,
                   // Nil rather than the empty string a subject carries, so the filename
                   // builder and anything matching on a number see "no number", not "".
                   playerNumber: isSubject ? nil : player?.number,
                   playerName: player?.name,
                   playerPosition: player.flatMap { $0.position.isEmpty ? nil : $0.position },
                   category: category)
    }

    /// What came of filing a tag. The no-player case can't be reported through a list of
    /// players, and "nothing landed" has to be distinguishable from "nothing was asked for".
    struct TagResult {
        /// The players whose tags landed. The rest already carried that category.
        var players: [Player] = []
        /// A tag on the clip itself, with no player against it.
        var clipTag = false

        var landed: Bool { !players.isEmpty || clipTag }
    }

    /// Files one category against a set of players on one clip, as a single undo step —
    /// three players tagged with one click have to come off again with one ⌘Z. An empty
    /// `players` tags the clip itself.
    @discardableResult
    func applyTags(to clip: Clip,
                   umid: String,
                   players: [Player],
                   fallbackTeam: Team?,
                   category: String) -> TagResult {
        // A category that isn't in the permanent list is a one-off, and this is the moment
        // it earns its place in the recents — when a tag is actually filed, not when the
        // word was typed. `noteRecent` ignores anything already permanent.
        library.noteRecent(category)

        let label = "Tag \(clip.name) as \(category)"

        if players.isEmpty {
            let tag = makeTag(for: clip, umid: umid, player: nil,
                              fallbackTeam: fallbackTeam, category: category)
            return TagResult(clipTag: library.add(tag, undoLabel: label))
        }

        let wanted = players.map { player -> (player: Player, tag: Tag) in
            (player, makeTag(for: clip, umid: umid, player: player,
                             fallbackTeam: fallbackTeam, category: category))
        }
        let landedIDs = Set(library.add(wanted.map(\.tag), undoLabel: label).map(\.id))
        return TagResult(players: wanted.filter { landedIDs.contains($0.tag.id) }.map(\.player))
    }

    /// The files for one row's drag handle, honouring the Include XML setting.
    func urls(for clip: Clip) -> [URL] {
        includeXML ? [clip.videoURL, clip.xmlURL] : [clip.videoURL]
    }

    // MARK: - Logging

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Appends in one batch, so a 200-clip scan redraws the panel once instead of 200 times.
    func appendLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let stamp = Self.timeFormatter.string(from: Date())
        let stamped = lines.map { "\(stamp)  \($0)" }
        for line in stamped { print(line) }
        log.append(contentsOf: stamped)
    }

    func addLog(_ line: String) { appendLog([line]) }

    var logText: String { log.joined(separator: "\n") }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
        status = "Debug log copied to the clipboard."
    }

    // MARK: - Scanning

    func chooseCard() {
        guard !isScanning, !isCopying else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.message = "Choose a card, drive, or folder of clips"
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            root = url
            scan()
        }
    }

    func scan() {
        guard let root, !isScanning else { return }
        isScanning = true
        clips = []
        selection = []
        lastSelected = nil
        log = []
        verifyReport = nil        // it belonged to whatever was scanned before
        status = "Scanning \(root.lastPathComponent)…"
        addLog("Scan started")
        let word = keepWord
        Task.detached(priority: .userInitiated) {
            let result = ClipScanner.scan(root: root, keepWord: word)
            await MainActor.run {
                self.clips = result.clips
                self.unmatchedXML = result.unmatchedXML
                self.videosWithoutXML = result.videosWithoutXML
                self.appendLog(result.log)
                self.isScanning = false
                self.status = result.clips.isEmpty
                    ? "No clips with XML sidecars were found in there."
                    : "Found \(result.clips.count) clips, "
                      + "\(result.clips.filter { self.isKeep($0) }.count) marked KEEP."
            }
        }
    }

    // MARK: - Copying

    /// One clip's files heading into one folder. They travel as a set so the video and its
    /// sidecar can be given the same base name — resolved once, after any clash is settled.
    /// A clip tagged with two players produces two jobs when grouping by player, which is
    /// the point: each gets a full set.
    /// One clip's files heading into one folder. They travel as a set so the video and its
    /// sidecar get the same base name — resolved once, after any clash is settled.
    /// A clip tagged with two players produces two jobs when grouping by player, which is
    /// the point: each gets a full set.
    struct CopyJob: Sendable {
        let sources: [URL]         // video first, sidecar after it when included
        let subfolder: String
        let baseName: String?      // nil keeps each file's own name
        /// Set when you've changed this clip's flag: the copied sidecar gets it written in.
        let writeKeep: Bool?
    }

    /// nil means "keep original names".
    var activePreset: RenamePreset? {
        guard let renamePresetID else { return nil }
        return library.presets.first { $0.id == renamePresetID }
    }

    func copyPlan() -> [CopyJob] {
        let preset = activePreset
        var jobs: [CopyJob] = []

        for clip in exportClips {
            let tags = library.tags(forUMID: clip.umid)

            let folders: [String]
            switch grouping {
            case .flat:
                folders = [""]
            case .byPlayer:
                // Still one folder per player the clip is tagged with: a player's folder
                // should hold every clip they appear in.
                let names = Set(tags.compactMap(\.folderSafePlayer))
                folders = names.isEmpty ? ["Untagged"] : names.sorted()
            case .byCategory:
                // Exactly one folder, matching the tag the file is being named after, so a
                // clip exists once rather than copied into every category it carries.
                let top = Renamer.topTag(of: tags, priority: library.allCategories)?.category
                folders = [top ?? "Untagged"]
            }

            // The video and its sidecar must share a base name, or they stop pairing up
            // when this folder is scanned later.
            let winningTeam = Renamer.topTag(of: tags, priority: library.allCategories)?.teamID
            let rosterCode = library.team(id: winningTeam).flatMap(\.code)
            let base = preset.map {
                Renamer.baseName(for: clip,
                                 tags: tags,
                                 preset: $0,
                                 priority: library.allCategories,
                                 rosterCode: rosterCode)
            }

            let sources = includeXML ? [clip.videoURL, clip.xmlURL] : [clip.videoURL]
            let override = isKeepChanged(clip) ? isKeep(clip) : nil
            for folder in folders {
                jobs.append(CopyJob(sources: sources,
                                    subfolder: folder,
                                    baseName: base,
                                    writeKeep: override))
            }
        }
        return jobs
    }

    private func fileCount(_ jobs: [CopyJob]) -> Int {
        jobs.reduce(0) { $0 + $1.sources.count }
    }

    // MARK: - Renaming where the files already are

    /// For footage already offloaded: rename it where it sits rather than copying it again.
    /// Without this, getting named files means a second copy of the same footage — one set
    /// under the camera's names from the rush edit, one renamed.
    ///
    /// Only `ExportSheet` calls this, and the sheet is the confirmation: it states the
    /// counts, the folder and the broken-links warning before the button is pressed.
    func renameInPlace() {
        guard !isCopying, !isScanning else { return }
        guard let preset = activePreset else {
            status = "Pick a filename preset first — renaming uses the same preset as copying."
            return
        }

        let scope = exportClips
        guard !scope.isEmpty else { return }

        // The sheet blocks this already. It stays as a last line of defence, because this is
        // the one mistake that would write to a card.
        if scope.contains(where: { FileUtil.looksLikeCameraCard($0.videoURL) }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "These files are on a camera card"
            alert.informativeText = "Keeper only ever reads cards. Copy the footage off first, "
                + "then rename it where it lands."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Work out the new names first, so the confirmation can be specific and nothing
        // is touched if there's nothing to do.
        var plan: [(clip: Clip, base: String)] = []
        for clip in scope {
            let tags = library.tags(forUMID: clip.umid)
            let rosterCode = library
                .team(id: Renamer.topTag(of: tags, priority: library.allCategories)?.teamID)
                .flatMap(\.code)
            let base = Renamer.baseName(for: clip,
                                        tags: tags,
                                        preset: preset,
                                        priority: library.allCategories,
                                        rosterCode: rosterCode)
            if base != clip.videoURL.deletingPathExtension().lastPathComponent {
                plan.append((clip, base))
            }
        }

        let flagChanges = scope.filter { isKeepChanged($0) }.count
        guard !plan.isEmpty || flagChanges > 0 else {
            status = "Everything in view is already named correctly."
            return
        }

        performRename(plan, flagWord: keepWord)
    }

    private func performRename(_ plan: [(clip: Clip, base: String)], flagWord: String) {
        let fm = FileManager.default
        var renamed = 0
        var flagged = 0
        var failed = 0
        var lines: [String] = []
        var handled = Set<URL>()

        addLog("Renaming \(plan.count) clip(s) in place")

        for entry in plan {
            let clip = entry.clip
            let folder = clip.videoURL.deletingLastPathComponent()
            let extensions = [clip.videoURL.pathExtension, clip.xmlURL.pathExtension]
            let base = FileUtil.freeBase(entry.base, in: folder, extensions: extensions)

            var movedAll = true
            for source in [clip.videoURL, clip.xmlURL] {
                let target = source.deletingLastPathComponent()
                    .appendingPathComponent("\(base).\(source.pathExtension)")
                guard target != source else { continue }
                do {
                    try fm.moveItem(at: source, to: target)
                } catch {
                    movedAll = false
                    failed += 1
                    lines.append("✗ \(source.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if movedAll {
                renamed += 1
                lines.append("→ \(clip.name) renamed to \(base).\(clip.videoURL.pathExtension)")
                handled.insert(clip.id)

                // While we're editing this folder, make the sidecar say what the app says.
                if isKeepChanged(clip), let umid = clip.umid {
                    let xml = folder.appendingPathComponent("\(base).\(clip.xmlURL.pathExtension)")
                    do {
                        if try KeepWriter.apply(keep: isKeep(clip), word: flagWord, toXMLAt: xml) {
                            flagged += 1
                        }
                        // No undo label on purpose: the flag is now written into the
                        // file on disk, so putting the override back would only make the
                        // library disagree with it.
                        library.clearKeepOverride(umid: umid, undoLabel: nil)
                    } catch {
                        lines.append("✗ \(base): flag couldn't be written — \(error.localizedDescription)")
                    }
                }
            }
        }

        // Clips that only needed a flag change, with no rename.
        for clip in exportClips where !handled.contains(clip.id) && isKeepChanged(clip) {
            guard let umid = clip.umid else { continue }
            do {
                if try KeepWriter.apply(keep: isKeep(clip), word: flagWord, toXMLAt: clip.xmlURL) {
                    flagged += 1
                    lines.append("✎ \(clip.xmlURL.lastPathComponent): flag set to "
                                 + (isKeep(clip) ? flagWord : "not \(flagWord)"))
                }
                library.clearKeepOverride(umid: umid, undoLabel: nil)   // written to the file
            } catch {
                lines.append("✗ \(clip.xmlURL.lastPathComponent): flag couldn't be written — "
                             + error.localizedDescription)
            }
        }

        appendLog(lines + ["In-place rename finished: \(renamed) renamed, "
                           + "\(flagged) flag(s) written, \(failed) failed"])
        status = "Renamed \(renamed) clip(s) in place"
            + (flagged > 0 ? ", wrote \(flagged) flag(s)" : "")
            + (failed > 0 ? ", \(failed) FAILED — see the debug log" : "")
            + "."
        scan()   // the names on disk have changed, so the list has to be rebuilt
    }

    @discardableResult
    func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should the copies go?"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        exportFolder = url
        return url
    }

    func copy(to dest: URL) {
        guard !isCopying, !isScanning else { return }
        let picked = exportClips
        guard !picked.isEmpty else { return }
        let jobs = copyPlan()
        let totalFiles = fileCount(jobs)
        let needed = jobs.reduce(Int64(0)) { running, job in
            running + job.sources.reduce(Int64(0)) { $0 + max(0, FileUtil.size(of: $1)) }
        }

        // A half-finished offload is worse than none, so check the space first.
        // The APFS-aware figure is the accurate one, but it reads 0 on exFAT and other
        // non-APFS volumes — which is how most external video drives are formatted. Fall back
        // to the plain figure, and treat "can't tell" as fine rather than as full, so a
        // perfectly healthy SSD is never reported as out of space.
        let freeSpace = FileUtil.freeSpace(at: dest)
        let readings = FileUtil.freeSpaceReadings(at: dest)
        addLog("Destination free space — "
               + "important usage: \(readings.important.map(FileUtil.sizeText) ?? "unavailable"), "
               + "plain: \(readings.plain.map(FileUtil.sizeText) ?? "unavailable"), "
               + "using: \(freeSpace.map(FileUtil.sizeText) ?? "neither, so the check is skipped")")

        if let free = freeSpace, needed > free {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Not enough free space"
            alert.informativeText = "This copy needs \(FileUtil.sizeText(needed)), but only "
                + "\(FileUtil.sizeText(free)) is free on that disk."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Copy Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                addLog("Copy cancelled: needs \(FileUtil.sizeText(needed)), only \(FileUtil.sizeText(free)) free")
                status = "Copy cancelled, not enough free space."
                return
            }
        }

        copyFilesDone = 0
        copyFilesTotal = totalFiles
        copyBytesDone = 0
        copyBytesTotal = needed
        status = "Copying \(totalFiles) file(s)…"
        addLog("Copying \(totalFiles) file(s) (\(FileUtil.sizeText(needed))) to \(dest.path)"
               + (grouping == .flat ? "" : ", \(grouping.rawValue.lowercased())"))
        if let preset = activePreset, let first = jobs.first, let base = first.baseName,
           let video = first.sources.first {
            addLog("Renaming with \"\(preset.name)\" — e.g. \(video.lastPathComponent) → \(base).\(video.pathExtension)")
        }

        let changedInBatch = jobs.filter { $0.writeKeep != nil }.count
        if changedInBatch > 0 {
            addLog(includeXML
                   ? "\(changedInBatch) clip(s) have a changed flag, written into the copied XML"
                   : "⚠︎ \(changedInBatch) clip(s) have a changed flag, but Include XML is off so "
                     + "it can't travel with them")
        }

        let flagWord = keepWord

        // Raised last, immediately before the work starts, for two reasons: it's the flag
        // that holds the Mac awake, so the log reads in the order things happen rather than
        // announcing the sleep hold before the copy it's for; and if anything above ever
        // grows an early return, the gate won't already be up with no job behind it.
        // Everything from here to the `Task` runs synchronously on the main actor, so the
        // UI never sees a half-set state.
        isCopying = true

        Task.detached(priority: .userInitiated) {
            var copied = 0
            var skipped = 0
            var failed = 0
            var lines: [String] = []
            let fm = FileManager.default

            var fileIndex = 0

            // A destination that has filled up, gone offline or turned out to be read-only
            // fails every single file, and the old behaviour was to keep going and write one
            // identical error per file — seventy lines of log for one problem, with the copy
            // still claiming to be in progress. Five in a row is taken as the destination
            // itself being the problem, and the whole copy stops there.
            var consecutiveFailures = 0
            var stoppedEarly = false
            let failureLimit = 5

            // Deliberately no early `continue` anywhere in here: every path has to reach the
            // progress update at the bottom, or the bar stalls on the first skipped file.
            copying: for job in jobs {
                var folder = dest
                var folderReady = true
                if !job.subfolder.isEmpty {
                    folder = dest.appendingPathComponent(job.subfolder, isDirectory: true)
                    do {
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    } catch {
                        failed += 1
                        folderReady = false
                        lines.append("✗ \(job.subfolder): couldn't make that folder — \(error.localizedDescription)")
                        // Counted here rather than per file: with no folder the loop below
                        // neither succeeds nor fails, so it would reset the tally each time
                        // and a destination refusing every folder would never trip the limit.
                        consecutiveFailures += 1
                        if consecutiveFailures >= failureLimit {
                            stoppedEarly = true
                            break copying
                        }
                    }
                }

                // Settle the shared base name once per clip, before any of its files move,
                // so the video and its sidecar can't end up named differently.
                var base = job.baseName
                if folderReady, let wanted = job.baseName, let video = job.sources.first {
                    let candidate = folder.appendingPathComponent("\(wanted).\(video.pathExtension)")
                    let sameClipAlreadyHere = fm.fileExists(atPath: candidate.path)
                        && FileUtil.size(of: candidate) == FileUtil.size(of: video)

                    if sameClipAlreadyHere {
                        // Keep the name rather than bumping it: the per-file checks below skip
                        // what matches and still fill in a sidecar that never made it last time.
                        base = wanted
                    } else {
                        let free = FileUtil.freeBase(wanted,
                                                     in: folder,
                                                     extensions: job.sources.map(\.pathExtension))
                        base = free
                        if free != wanted {
                            lines.append("⚠︎ \(wanted) was taken, this clip went in as \(free)")
                        }
                    }
                }

                for src in job.sources {
                    let name = base.map { "\($0).\(src.pathExtension)" } ?? src.lastPathComponent
                    let srcSize = FileUtil.size(of: src)
                    fileIndex += 1
                    let position = fileIndex
                    let failedBefore = failed

                    await MainActor.run {
                        self.status = "Copying \(position) of \(totalFiles): \(name)"
                    }

                    if folderReady {
                        var target = folder.appendingPathComponent(name)
                        var shouldCopy = true
                        let isSidecar = src.pathExtension.lowercased() == "xml"

                        // A sidecar carrying a changed flag that's already at the destination
                        // gets the flag applied in place. Otherwise copying the same selection
                        // twice would skip it as a duplicate and quietly lose the change.
                        //
                        // `sameFile` is the guard that keeps this honest. Copy into the folder
                        // the clips are already in and the target IS the source, so this would
                        // edit the original — and on a card, that would break the one promise
                        // Keeper makes. The sheet blocks a card destination; this makes sure
                        // the originals are never touched wherever they are.
                        if isSidecar, let wanted = job.writeKeep, fm.fileExists(atPath: target.path),
                           !FileUtil.sameFile(target, src) {
                            shouldCopy = false
                            do {
                                let edited = try KeepWriter.apply(keep: wanted,
                                                                  word: flagWord,
                                                                  toXMLAt: target)
                                skipped += 1
                                lines.append(edited
                                    ? "✎ \(name): already there, flag set to "
                                      + (wanted ? flagWord : "not \(flagWord)")
                                    : "– \(name): already there with the right flag, skipped")
                            } catch {
                                failed += 1
                                lines.append("✗ \(name): already there, but the flag couldn't be "
                                             + "changed — \(error.localizedDescription)")
                            }
                        } else if fm.fileExists(atPath: target.path) {
                            if FileUtil.size(of: target) == srcSize {
                                skipped += 1
                                shouldCopy = false
                                lines.append("– \(name): already in the destination, skipped")
                            } else if job.baseName != nil {
                                // Renaming: the base was already settled for the whole clip, so
                                // bumping one file now would split it from its sidecar.
                                skipped += 1
                                shouldCopy = false
                                lines.append("⚠︎ \(name): a different file of that name is already "
                                             + "there, left alone")
                            } else {
                                // Original names: never overwrite, never silently skip.
                                target = FileUtil.uniqueURL(for: target)
                                lines.append("⚠︎ \(name): a different file of that name was already there, "
                                             + "copied as \(target.lastPathComponent)")
                            }
                        }

                        if shouldCopy {
                            do {
                                try fm.copyItem(at: src, to: target)
                                let wrote = FileUtil.size(of: target)
                                if wrote == srcSize {
                                    copied += 1

                                    // The flag you changed in the app goes into the copy, never
                                    // the card. Done after the size check so a bad copy is still
                                    // reported as a bad copy.
                                    if isSidecar, let wanted = job.writeKeep {
                                        do {
                                            let edited = try KeepWriter.apply(keep: wanted,
                                                                              word: flagWord,
                                                                              toXMLAt: target)
                                            if edited {
                                                lines.append("✎ \(name): flag set to "
                                                             + (wanted ? flagWord : "not \(flagWord)"))
                                            }
                                        } catch {
                                            failed += 1
                                            lines.append("✗ \(name): copied, but the flag couldn't "
                                                         + "be changed — \(error.localizedDescription)")
                                        }
                                    }
                                } else {
                                    failed += 1
                                    lines.append("✗ \(name): copied \(wrote) bytes but the source is \(srcSize) bytes")
                                }
                            } catch {
                                failed += 1
                                lines.append("✗ \(name): \(error.localizedDescription)")
                            }
                        }
                    }

                    // Only while there's a folder to write into: with a dead folder nothing
                    // here succeeded or failed, and resetting would hide the folder's own
                    // failures counted above.
                    if folderReady {
                        consecutiveFailures = failed > failedBefore ? consecutiveFailures + 1 : 0
                    }

                    let moved = max(0, srcSize)
                    await MainActor.run {
                        self.copyFilesDone = position
                        self.copyBytesDone += moved
                    }

                    // After the progress update, so the bar shows how far it actually got.
                    if consecutiveFailures >= failureLimit {
                        stoppedEarly = true
                        break copying
                    }
                }
            }

            // Everything the closure below reads has to be a `let`. Capturing a `var` from
            // out here in concurrently-executing code is a warning now and an error under
            // Swift 6, which is what the rest of these copies are for.
            let finalCopied = copied, finalSkipped = skipped, finalFailed = failed
            let reachedFile = fileIndex
            let halted = stoppedEarly

            var assembled = lines
            if halted {
                assembled.append("■ STOPPED after \(failureLimit) failures in a row, at file "
                                 + "\(reachedFile) of \(totalFiles). The destination is most "
                                 + "likely full, disconnected or read-only. Nothing already "
                                 + "copied was removed, and nothing was touched at the source.")
            }
            assembled.append("Copy finished: \(finalCopied) copied, "
                             + "\(finalSkipped) skipped, \(finalFailed) failed")
            let finalLines = assembled

            await MainActor.run {
                self.appendLog(finalLines)
                self.isCopying = false
                self.copyFilesDone = 0
                self.copyFilesTotal = 0
                self.copyBytesDone = 0
                self.copyBytesTotal = 0
                if halted {
                    // Said plainly and first: this copy is incomplete, and the card it came
                    // from must not be formatted on the strength of it.
                    self.status = "Copy STOPPED after \(failureLimit) failures in a row — "
                        + "\(finalCopied) of \(totalFiles) file(s) had copied. Check the "
                        + "destination has room and is still connected, then run it again. "
                        + "Turn on Debug for the errors."
                    return
                }
                var message = "Copied \(finalCopied) file(s)"
                if finalSkipped > 0 { message += ", skipped \(finalSkipped) already there" }
                if finalFailed > 0 { message += ", \(finalFailed) FAILED — turn on Debug for details" }
                self.status = message + "."
            }
        }
    }
}
