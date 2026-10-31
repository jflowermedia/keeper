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
    /// The OK key. KEEP is a menu command and doesn't need this; OK is a bare press, so it
    /// comes through the key monitor like the other review keys.
    static let keeperToggleOK = Notification.Name("keeperToggleOK")

    /// Posted by `TagLibrary` when it has just written a rolling backup, so the Restore
    /// menu's cached list picks it up without the menus listing the folder on every rebuild.
    static let keeperLibraryBackedUp = Notification.Name("keeperLibraryBackedUp")
}

@MainActor
final class AppState: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        // The labels on the segmented control. Never stored, so renaming them is safe.
        case picks = "Picks"
        case unpicked = "Unpicked"
        case all = "All"
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
    @Published var filter: Filter = .picks {
        didSet {
            guard filter != oldValue else { return }
            selection = []
            // Also the preview: keeping it would show a clip from the filter you just left.
            // A flag toggle deliberately doesn't do this — see `previewClip`.
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
            if selection.count == 1 { selectionAnchor = selection.first }
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

    /// The camera menu in the toolbar, which sets `keepWord` for a brand whose flag is known
    /// and shows the word box for Other. `keepWord` stays the one thing the scanner reads.
    @Published var camera: CameraPreset = .sony {
        didSet {
            guard camera != oldValue else { return }
            UserDefaults.standard.set(camera.rawValue, forKey: "camera")
            if let word = camera.word, keepWord != word {
                keepWord = word
                scan()
            }
        }
    }

    /// The folders a copy just finished into, offered to Check Copied — two when it was split
    /// by flag, since neither half on its own accounts for the card. Cleared by a rescan and
    /// once it's been used, so it only ever points at the copy of the card in front of you.
    @Published var verifySuggestions: [URL] = []

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
    // Neither is remembered between launches, on purpose: every session's export starts
    // from the defaults rather than from whatever the last card needed.
    @Published var grouping: Grouping = .flat
    @Published var renamePresetID: UUID?

    // MARK: Tagging flow

    /// The rosters in play, in the order they were chosen. See `activeTeams` in TagFlow.swift.
    @Published var activeTeamIDs: [String] = [] {
        didSet { UserDefaults.standard.set(activeTeamIDs, forKey: "activeTeamIDs") }
    }

    /// Two benches in play for a game, or one. Off, ticking a roster swaps it in; on, a
    /// second can join the first — from the same league only. See `TeamPick`.
    @Published var bothTeams = false {
        didSet {
            UserDefaults.standard.set(bothTeams, forKey: "bothTeams")
            guard bothTeams != oldValue, !bothTeams else { return }
            // Back to one: keep the bench that's on screen, not whichever was ticked first.
            if let shown = shownTeamID, activeTeamIDs.count > 1 { setActiveTeams([shown]) }
        }
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

    /// Whether marking the previewed clip KEEP or OK moves to the next one afterwards. On by default:
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
    /// The Subjects pill is the one showing — mascot, crowd, anthem and the rest, as a bench
    /// of their own beside the teams. Reached by the pill, by ← → past the last team, or by
    /// the key bound to `.subjectsOnly`. The team pills stay as they were underneath, which is
    /// what a subject's tag records as its team.
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
    /// Copy the picks to `exportFolder` and the unpicked to `notKeptFolder`, in one
    /// pass, rather than exporting twice with the filter flipped in between. Like the layout,
    /// not remembered between launches.
    @Published var splitByKeep = false
    @Published var notKeptFolder: URL?
    /// Drive the sheets. They live here rather than in the view so the menus can open them.
    @Published var showExportSheet = false
    @Published var showPresetEditor = false
    @Published var showRosterEditor = false
    @Published var showShortcutsSheet = false

    // MARK: - The welcome sheet

    /// Opens by itself on a first launch, and from Help → Welcome & Tutorial after that.
    @Published var showWelcome = false

    // MARK: - Downloading a roster

    @Published var showRosterDownload = false
    /// Changing league drops the team list and fetches the new one. Disabled in the picker
    /// while a fetch is running, so a slow answer can't land under the wrong league.
    @Published var rosterSource: RosterSource = .nhl {
        didSet {
            guard rosterSource != oldValue else { return }
            leagueTeams = []
            rosterDownloadNote = nil
            previewCache = [:]
            previewTeam = nil
            loadLeagueTeams()
        }
    }
    @Published var leagueTeams: [LeagueTeam] = []

    /// The team whose players the download sheet is showing, and what it found.
    @Published var previewTeam: LeagueTeam?
    @Published var previewRows: [RosterFeed.Row] = []
    @Published var previewNote: String?
    @Published var isPreviewing = false
    /// Per league session, so clicking back and forth between two teams doesn't ask the
    /// league twice. The import still fetches fresh — a preview from ten minutes ago isn't
    /// what "today's numbers" promises.
    /// Not private only because its reader lives in AppState+Rosters.swift.
    var previewCache: [String: [RosterFeed.Row]] = [:]

    @Published var isFetchingRosters = false
    @Published var rosterDownloadNote: String?

    // MARK: - Reviewing a re-import

    /// Teams you already have that an import would change, waiting on Merge, Replace or Skip.
    /// Nothing in here has been written yet.
    @Published var rosterReview: [TagLibrary.RosterConflict]?
    @Published var rosterReviewModes: [String: TagLibrary.ImportMode] = [:]
    /// Which sheet shows the review. SwiftUI won't reliably put a sheet up over another from
    /// the window, so a review that comes out of the download sheet is shown from inside it.
    var rosterReviewFromDownload = false

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

    /// Run from the sheet's `onDismiss`, once the sheet has actually gone — most of these open
    /// a modal panel, which can't be put up from inside a sheet that's still on screen.
    /// Clears as it fires, so reopening the tutorial and skipping doesn't repeat the last one.
    func runPendingWelcomeAction() {
        guard let action = pendingWelcomeAction else { return }
        pendingWelcomeAction = nil
        switch action {
        case .chooseFolder: chooseCard()
        case .importRoster: importRoster()
        case .downloadRoster: showRosterDownload = true
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

    // MARK: - Library backups

    /// The past versions the Restore menu offers.
    ///
    /// Cached rather than read from the folder on demand: the menus are rebuilt every time
    /// anything here changes, including each file of a copy, and a directory listing per
    /// progress tick is the kind of cost that doesn't show up until a card is full.
    /// `ContentView` refreshes it on launch and whenever a new backup is written.
    /// Written only by `refreshBackups`, in AppState+Backups.swift — the setter can't be
    /// private with the writer in another file.
    @Published var libraryBackups: [TagLibrary.Backup] = []

    init() {
        keepWord = UserDefaults.standard.string(forKey: "keepWord") ?? "KEEP"
        // Before the menu there was only the word. A library that has one but no camera
        // starts on whichever preset that word belongs to — Other, for anything but KEEP.
        camera = UserDefaults.standard.string(forKey: "camera").flatMap(CameraPreset.init(rawValue:))
            ?? CameraPreset.matching(keepWord)
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
        // Before this was a setting, two ticked rosters *was* both-teams mode — so a library
        // that has never stored it starts in whichever state it was already in.
        if UserDefaults.standard.object(forKey: "bothTeams") != nil {
            bothTeams = UserDefaults.standard.bool(forKey: "bothTeams")
        } else {
            bothTeams = activeTeamIDs.count > 1
        }
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

    /// The flag the app goes by: your own if you've set one, otherwise the camera's.
    func flag(_ clip: Clip) -> ClipFlag? {
        // Unwrapped by hand: `?.flag ?? clip.flag` would flatten a flag you cleared into
        // "not changed" and hand back the camera's.
        if let mark = library.flagOverride(for: clip.umid) { return mark.flag }
        return clip.flag
    }

    /// KEEP or OK, by the flag the app goes by.
    func isPick(_ clip: Clip) -> Bool { flag(clip).isPick }

    /// True when you've changed it from what the card says.
    func isFlagChanged(_ clip: Clip) -> Bool {
        library.flagOverride(for: clip.umid) != nil
    }

    var visible: [Clip] {
        let list: [Clip]
        switch filter {
        case .picks:    list = clips.filter { isPick($0) }
        case .unpicked: list = clips.filter { !isPick($0) }
        case .all:      list = clips
        }
        return matchingTagFilters(list)
    }

    /// The tag half of `visible`, without the Picks filter. Splitting an export by flag needs
    /// both halves of whatever the tag filters show, whichever flag the list is set to.
    func matchingTagFilters(_ clips: [Clip]) -> [Clip] {
        var list = clips
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
    private var lastOKToken = 0

    /// Whether clearing tags asks first. On unless you've turned it off, because the one
    /// press that wipes tags off a whole card is worth a question the first few times.
    @Published var warnBeforeClearingTags = true {
        didSet {
            UserDefaults.standard.set(warnBeforeClearingTags,
                                      forKey: "warnBeforeClearingTags")
        }
    }

    func moveSelection(_ delta: Int, token: Int, extend: Bool = false) {
        guard token != lastMoveToken else { return }
        lastMoveToken = token
        if extend {
            extendSelection(delta)
        } else {
            selectRelative(delta)
        }
    }

    /// Where a ⇧-arrow range started. Set whenever the selection comes down to one clip —
    /// a click, a plain arrow — which is where a range begins in every Mac list.
    private var selectionAnchor: URL?

    /// ⇧↑ ⇧↓ grow or shrink a range from the anchor; a delta of 0 selects everything in view.
    func extendSelection(_ delta: Int) {
        guard !aSheetIsUp else { return }
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        if delta == 0 {
            selection = Set(ids)
            status = "Selected all \(ids.count) clip\(ids.count == 1 ? "" : "s") in view."
            return
        }
        guard let range = ClipRange.extend(ids, anchor: selectionAnchor,
                                           cursor: lastSelected, delta: delta) else { return }
        selection = Set(range.selection)
        // Set outright: the didSet can only guess which of several added clips is the newest,
        // and the preview should follow the end of the range that's moving.
        lastSelected = range.cursor
        selectionAnchor = range.anchor
    }

    /// Anything of ours that's taken over the window. The export and verify sheets both
    /// show a count of what they're about to act on, and that count must not move under them.
    var aSheetIsUp: Bool {
        showExportSheet || showVerifySheet || showRosterEditor
            || showPresetEditor || showShortcutsSheet || showWelcome
            || showRosterDownload || rosterReview != nil
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
            // The previewed clip has left the filter, which is exactly what clearing a flag
            // while looking at Picks does. Carry on from where it was sitting: the clip
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

    /// ⌘Return (KEEP) or O (OK) on the previewed clip: flip the flag and move on. That's the
    /// review pass — watch, mark, next — and it's why this exists rather than calling
    /// `toggle` directly. Clicking a row's badge deliberately doesn't advance: that click is
    /// aimed at one clip, and moving the preview off it would be a surprise.
    /// From the OK key. The token stops a second window marking the clip twice — which,
    /// since it's a toggle, would undo the first.
    func toggleOKOnPreview(token: Int) {
        guard token != lastOKToken else { return }
        lastOKToken = token
        toggleOnPreview(.ok)
    }

    func toggleOnPreview(_ flag: ClipFlag) {
        guard let clip = previewClip else {
            status = "Select a clip to mark it \(flag.rawValue)."
            return
        }
        // Only moves on if the flag actually changed. A clip with no UMID can't be marked,
        // and advancing anyway would walk silently past it.
        guard toggle(flag, on: clip) else { return }
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

    func count(_ flag: ClipFlag) -> Int { clips.filter { self.flag($0) == flag }.count }
    var pickCount: Int { clips.filter { isPick($0) }.count }
    var unpickedCount: Int { clips.count - pickCount }
    var taggedCount: Int { clips.filter { library.isTagged($0.umid) }.count }
    var changedFlagCount: Int { clips.filter { isFlagChanged($0) }.count }

    // MARK: Sizes
    //
    // Video plus sidecar, from the figures taken during the scan — the same basis as the
    // export sheet's total, so the two agree. Nothing here stats a file.

    private func bytes(of list: [Clip]) -> Int64 {
        list.reduce(Int64(0)) { $0 + $1.totalSize }
    }

    var pickBytes: Int64 { bytes(of: clips.filter { isPick($0) }) }
    var unpickedBytes: Int64 { bytes(of: clips.filter { !isPick($0) }) }
    var allBytes: Int64 { bytes(of: clips) }
    /// What the filter is showing, tag filters included.
    var visibleBytes: Int64 { bytes(of: visible) }

    /// All three at once, for the tooltip — the question is usually "will this fit", and
    /// that's easier to answer with the other two in front of you.
    var sizeBreakdown: String {
        """
        Picks: \(FileUtil.sizeText(pickBytes)) over \(pickCount) clip(s)
        Unpicked: \(FileUtil.sizeText(unpickedBytes)) over \(unpickedCount) clip(s)
        Everything: \(FileUtil.sizeText(allBytes)) over \(clips.count) clip(s)

        The figure beside this is what the filter is showing.
        """
    }

    // MARK: - Marking flags

    /// Sets one clip's flag, or takes it off if it already has that one. Nothing is written
    /// to the card — the change lives in the library until the clip is copied out, and then
    /// only the copied sidecar is edited.
    ///
    /// Returns false when there was nothing to change, so a caller that moves on afterwards
    /// doesn't walk past a clip it never marked.
    @discardableResult
    func toggle(_ flag: ClipFlag, on clip: Clip) -> Bool {
        set(self.flag(clip) == flag ? nil : flag, on: clip)
    }

    @discardableResult
    func set(_ next: ClipFlag?, on clip: Clip) -> Bool {
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

        let word = next?.rawValue ?? "unflagged"
        library.setFlag(next, umid: umid, cameraFlag: clip.flag,
                        undoLabel: next == nil ? "Clear the Flag on \(clip.name)" : "Mark \(clip.name) \(word)")
        status = "\(clip.name) \(next == nil ? "unflagged" : "marked \(word)")"
            + (next == clip.flag ? " (back to the camera's flag)." : ", applied when you copy it.")
            + undoHint
        return true
    }

    /// Sets every clip in scope the same way, rather than flipping each individually. nil
    /// clears the flag.
    func setFlagInScope(_ flag: ClipFlag?) {
        setFlag(flag, on: dragClips, scope: hasExplicitSelection ? "selected" : "shown")
    }

    /// The clips a right-click acts on. See `ContextTargets`.
    func contextTargets(for clip: Clip) -> [Clip] {
        ContextTargets.clips(clicked: clip, selection: selection,
                             selected: ContextTargets.selected(selection, in: visible))
    }

    /// The right-click menu's marks. One clip goes through `set`, which keeps the arrows'
    /// place if the clip drops out of the list; several go through the bulk path the Mark
    /// menu uses, so a selection is one write and one undo step.
    func setFlag(_ flag: ClipFlag?, onContextOf clip: Clip) {
        let targets = contextTargets(for: clip)
        if targets.count == 1, let only = targets.first {
            set(flag, on: only)
        } else {
            setFlag(flag, on: targets, scope: "selected")
        }
    }

    func revertFlags(onContextOf clip: Clip) {
        revertFlags(on: contextTargets(for: clip))
    }

    private func setFlag(_ flag: ClipFlag?, on clips: [Clip], scope: String) {
        let targets = clips.compactMap { clip -> (umid: String, cameraFlag: ClipFlag?)? in
            guard let umid = clip.umid else { return nil }
            return (umid, clip.flag)
        }
        guard !targets.isEmpty else {
            status = clips.isEmpty
                ? "No clips to mark."
                : "None of those clips has a UMID in its XML, so their flags can't be changed."
            return
        }
        let doing = flag.map { "Mark \(targets.count) Clip(s) \($0.rawValue)" }
            ?? "Clear the Flags on \(targets.count) Clip(s)"
        var changed = 0
        keepingPlace { changed = library.setFlag(flag, for: targets, undoLabel: doing) }
        guard changed > 0 else {
            status = "Those \(targets.count) clip(s) are already \(flag.map(\.rawValue) ?? "unflagged")."
            return
        }
        status = (flag.map { "Marked \(targets.count) \(scope) clip(s) \($0.rawValue)." }
                  ?? "Cleared the flags on \(targets.count) \(scope) clip(s).") + undoHint
    }

    func revertFlagsInScope() {
        revertFlags(on: dragClips)
    }

    private func revertFlags(on clips: [Clip]) {
        let umids = clips.compactMap(\.umid)
        var reverted = 0
        keepingPlace {
            reverted = library.clearFlagOverrides(
                umids: umids,
                undoLabel: "Revert \(umids.count) Clip(s) to the Camera's Flags")
        }
        guard reverted > 0 else {
            status = "Those clips already have the camera's flags."
            return
        }
        status = "Reverted \(reverted) clip(s) to the camera's own flag." + undoHint
    }

    /// The bulk version of what `set` does before a mark: keep the arrows' place when the
    /// previewed clip leaves the list. Several clips can go at once, some above it, so the
    /// place is found afterwards — the first clip that was after the preview and is still
    /// listed — rather than taken as an index beforehand, which would be off by however
    /// many left above it.
    private func keepingPlace(_ change: () -> Void) {
        let before = visible
        let at = lastSelected.flatMap { id in before.firstIndex { $0.id == id } }
        change()
        guard let at else { return }
        lastVisibleIndex = ContextTargets.place(of: at, before: before.map(\.id),
                                                after: visible.map(\.id))
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
        // Here rather than at each caller: a rescan empties the clip list, and a copy still
        // running from it would carry on while the window showed nothing. The toolbar
        // disables its own triggers too, but the Camera menu showed how easily a new one
        // arrives without that.
        guard !isCopying else {
            status = "A copy is running — rescan once it's finished."
            return
        }
        isScanning = true
        clips = []
        selection = []
        lastSelected = nil
        log = []
        verifyReport = nil        // it belonged to whatever was scanned before
        verifySuggestions = []
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
                self.status = ScanSummary.text(
                    clips: result.clips.count,
                    keeps: result.clips.filter { self.flag($0) == .keep }.count,
                    oks: result.clips.filter { self.flag($0) == .ok }.count,
                    withoutSidecar: result.videosWithoutXML.count)
            }
        }
    }

}

/// A ⇧-arrow range over the clip list, as every Mac list does it: one end fixed where the
/// range started, the other moving. Pure, so the self-check can run it.
enum ClipRange {
    static func extend<ID: Hashable>(_ ids: [ID], anchor: ID?, cursor: ID?,
                                     delta: Int) -> (selection: [ID], anchor: ID, cursor: ID)? {
        guard !ids.isEmpty, delta != 0 else { return nil }
        guard let at = cursor.flatMap({ ids.firstIndex(of: $0) }) else {
            // Nothing to extend from yet: start at whichever end you were heading for.
            let start = ids[delta > 0 ? 0 : ids.count - 1]
            return ([start], start, start)
        }
        let next = at + delta
        guard ids.indices.contains(next) else { return nil }        // already at the end
        // An anchor that's left the filter falls back to where the cursor was.
        let from = anchor.flatMap { ids.firstIndex(of: $0) } ?? at
        let range = Array(ids[min(from, next)...max(from, next)])
        return (range, ids[from], ids[next])
    }
}

/// Which clips a right-click acts on: the whole selection when you click inside it, as
/// Finder does, or just the clip you clicked when it's outside. Without this, right-clicking
/// one of six selected clips marked one, and the other five looked marked until you checked.
/// Pure and apart from `AppState` so the rule can be checked.
///
/// `selected` is passed in rather than worked out here because the list builds every row's
/// menu each time it redraws: worked out per row, a whole card selected meant filtering the
/// card once per selected clip, on every redraw.
enum ContextTargets {
    /// The selection as it stands on screen. A selected clip a filter has since hidden
    /// mustn't be marked unseen.
    static func selected(_ selection: Set<URL>, in visible: [Clip]) -> [Clip] {
        selection.isEmpty ? [] : visible.filter { selection.contains($0.id) }
    }

    /// Where the arrows carry on from once a mark has taken clips out of the list: the first
    /// clip that was at or after `at` and is still listed. Past the end when none is left,
    /// which `selectRelative` clamps.
    static func place(of at: Int, before: [URL], after: [URL]) -> Int {
        let index = Dictionary(after.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return before[at...].lazy.compactMap { index[$0] }.first ?? after.count
    }

    static func clips(clicked: Clip, selection: Set<URL>, selected: [Clip]) -> [Clip] {
        guard selection.contains(clicked.id), selected.count > 1 else { return [clicked] }
        return selected
    }
}
