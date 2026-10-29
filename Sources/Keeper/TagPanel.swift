import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The tagging panel: pick a player, click a category, the clip is tagged.
struct TagPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject private var library = TagLibrary.shared
    // Which rosters are in play is `AppState.activeTeamIDs` now, not view state: the
    // keyboard flow walks the same grid and has to agree with what's on screen.
    @State private var selectedPlayerIDs: Set<String> = []
    @State private var newCategory = ""
    @State private var showingCategoryField = false
    @State private var newSubject = ""
    @State private var showingSubjectField = false
    @State private var newSection = ""
    @State private var addingSection = false
    /// Same key as the menu item's, so the two stay in step.
    @AppStorage("advanceAfterTag") private var advanceAfterTag = false

    private var clip: Clip? { state.previewClip }

    /// The one roster in play, when there's exactly one. Nil for a game with two benches,
    /// which is why anything that acts on "the team" is hidden in that case.
    private var soleTeam: Team? {
        let teams = state.activeTeams
        return teams.count == 1 ? teams[0] : nil
    }

    /// In roster order, so "Goal" on three selected players reads sensibly in the log.
    ///
    /// Resolved against every roster in play, not the grid. The grid shows one bench and
    /// hides whoever a typed number excludes, so reading the selection off it would quietly
    /// drop hand-picked players from the tag — select three, type a number, click a
    /// category, and only the ones still on screen would be tagged. A hit involves both
    /// benches too, so a selection that spans them has to survive the switch.
    private var selectedPlayers: [Player] {
        state.allActivePlayers.filter { selectedPlayerIDs.contains($0.id) }
    }

    private var currentTags: [Tag] {
        library.tags(forUMID: clip?.umid).sorted { $0.created < $1.created }
    }

    /// Categories already on the clip in the viewer. Clicking a category tags instantly and
    /// clears the player selection, so there's no lasting "selected" state to show — what's
    /// worth showing is what's already been applied.
    private var categoriesOnClip: Set<String> {
        Set(currentTags.map(\.category))
    }

    /// Players already tagged on the clip in the viewer. `Tag.playerID` is built the same way
    /// as `Player.id`, so the two compare directly.
    private var playersOnClip: Set<String> {
        Set(currentTags.compactMap(\.playerID))
    }

    /// Accent means "picked, about to be tagged". Green means "already on this clip". Picking
    /// wins the fill when a player is both, because that's the state you're about to act on —
    /// the tick keeps the other half visible.
    private func playerTint(picked: Bool, onClip: Bool) -> Color? {
        if picked { return .accentColor }
        if onClip { return .green }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.keyboardFlow {
                flowStrip
            }

            if library.teams.isEmpty {
                emptyRoster
            } else {
                teamPicker
                focusPills
                if state.subjectsOnly { subjectField }
                playerGrid
                    .flowSection(.players, current: state.tagStage, active: state.keyboardFlow)
                Divider()
                categoryRow
                    .flowSection(.categories, current: state.tagStage, active: state.keyboardFlow)
            }

            if !currentTags.isEmpty {
                Divider()
                tagList
            }

            Spacer(minLength: 0)

            if !state.taggedInScope.isEmpty {
                Divider()
                Button(role: .destructive) {
                    state.removeTagsInScope()
                } label: {
                    Label(state.removeTagsLabel, systemImage: "tag.slash")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .help("Clears every tag from the clips you have selected · "
                      + "\(Shortcuts.shared.display(.clearTags)) does the same")
            }
        }
        .padding(12)
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 380,
               maxHeight: .infinity, alignment: .top)
        // A picked player is armed for the clip you're looking at, so it doesn't follow you
        // to the next one: the ring would sit on a player who has nothing to do with it,
        // and hide the green of whoever is actually tagged on the clip now in view.
        .onChange(of: clip?.id) { _ in
            selectedPlayerIDs = []
        }
        // Which benches an import brings into play is `AppState.adoptImported`; all the
        // panel has to do is let go of players picked from the roster before it.
        .onChange(of: state.lastImportedTeamID) { _ in
            selectedPlayerIDs = []
        }
    }

    // MARK: Keyboard flow

    /// A mode that takes over Tab, Return and the arrows can't be invisible. This says
    /// where the keyboard is and what the next press does, and the stage names double as
    /// buttons so it's still usable with the mouse.
    private var flowStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ForEach([TagStage.clips, .players, .categories], id: \.rawValue) { stage in
                    let here = state.tagStage == stage
                    Text(stage.title)
                        .font(.caption2.weight(here ? .bold : .regular))
                        .foregroundStyle(here ? Color.accentColor : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(here ? Color.accentColor.opacity(0.14) : .clear)
                        .clipShape(Capsule())
                    if stage != .categories {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    state.keyboardFlow = false
                } label: {
                    Text("Off").font(.caption2)
                }
                .buttonStyle(.link)
                .help("Give the keyboard back — Tab, Return and the arrows go back to normal")
            }

            Text(state.flowPrompt)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Tagging", systemImage: "number").font(.headline)
            Spacer()
            Menu {
                Button("Import Roster CSV…") { importRoster() }
                // No shortcut here: the File menu owns ⌘⇧R, and declaring it twice leaves
                // two views competing for the same key.
                Button("Edit Rosters…") { state.showRosterEditor = true }
                Button("Update Tags from Roster") {
                    let n = library.refreshTagsFromRoster()
                    state.status = n == 0
                        ? "Tags already match the roster."
                        : "Updated \(n) tag(s) from the roster."
                }
                .disabled(library.teams.isEmpty)

                Divider()
                Toggle("Keyboard Tagging", isOn: $state.keyboardFlow)
                    .help("Tab from the clips to the players, type a number, Return, "
                          + "Return. See the Keeper guide.")
                Toggle("Move On After Tagging", isOn: $advanceAfterTag)
                    .help("Go to the next clip as soon as a tag lands. Leave it off when a "
                          + "clip gets more than one tag — a goal and an assist, say.")

                // Only with one roster in play: with two it would be ambiguous which this
                // means, and deleting the wrong roster takes its tags' names with it.
                if let team = soleTeam {
                    Divider()
                    Button("Remove \(team.name)", role: .destructive) {
                        // Clear any filter pointing at it, or the list goes empty with no
                        // way to see why: the menus no longer offer what's filtering it.
                        if state.filterTeamID == team.id { state.filterTeamID = nil }
                        if state.filterPlayerID?.hasPrefix("\(team.id)/") == true {
                            state.filterPlayerID = nil
                        }
                        library.deleteTeam(id: team.id)
                        state.setActiveTeams([])
                        selectedPlayerIDs = []
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var emptyRoster: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No roster yet.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Download a Roster…") { state.showRosterDownload = true }
                Button("Import Roster CSV…") { importRoster() }
                Button("Type One In…") { state.showRosterEditor = true }
            }
            Text("Columns: team, number, name. A header row is optional, and without a team column the file's name is used.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let message = state.importMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Roster

    private var teamPicker: some View {
        HStack(spacing: 8) {
            // Ticks rather than a single choice: a game is two benches, and dropping a
            // thirteen-team league menu between every tag is what makes tagging slow.
            // A Menu rather than a Picker, because only a menu takes section headings.
            Menu {
                if library.leaguesAreWorthShowing {
                    ForEach(library.teamsByLeague) { group in
                        Section(group.name) {
                            ForEach(group.teams) { teamChoice($0) }
                        }
                    }
                } else {
                    ForEach(library.teams) { teamChoice($0) }
                }
                // No "just this one" item here: the pills below narrow the grid to one
                // bench without taking the other out of play, and two near-identical
                // actions a few pixels apart is how you pick the wrong one. Untick to
                // take a roster out.
            } label: {
                Text(state.activeTeamsLabel)
            }
            .frame(maxWidth: 200)
            .help(state.bothTeams
                  ? "Tick both teams for a game — two at most, from the same league"
                  : "Pick the roster you're shooting. Turn on Both teams for a game.")

            Toggle("Both teams", isOn: $state.bothTeams)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Two benches in play at once, from the same league. Off, picking a "
                      + "roster swaps it in.")

            if !selectedPlayerIDs.isEmpty {
                Button("Clear \(selectedPlayerIDs.count)") { selectedPlayerIDs = [] }
                    .buttonStyle(.link)
                    .help("Deselect every player")
            }
        }
    }

    /// With two benches in play, 40-odd chips is a lot to read. These narrow the grid to
    /// one of them without taking the other out of play — a typed number still only reaches
    /// what's on screen, which is the point. ← → do the same thing from the keyboard.
    @ViewBuilder
    private var focusPills: some View {
        // Always shown now, even with one roster: the Subjects pill is the only way to
        // the subjects with the mouse, and it sits to the right of the teams the way a
        // second team's does.
        HStack(spacing: 4) {
            ForEach(state.activeTeams) { focusPill(for: $0) }
            subjectsPill

            Spacer(minLength: 0)

            // The typed number lives here, beside the bench it's filtering, because
            // this is where you're looking while you type it.
            if !state.numberEntry.isEmpty {
                Text("#\(state.numberEntry)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                    .help("Showing numbers starting \(state.numberEntry) · ⌫ to go back")
            } else if state.keyboardFlow {
                Text("← →")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Switch bench from the keyboard")
            }
        }
    }

    private var subjectsPill: some View {
        let on = state.subjectsOnly
        return Button {
            state.show(.subjects)
        } label: {
            Text("Subjects")
                .font(.caption2.weight(on ? .bold : .regular))
                .italic()
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(on ? Color.accentColor.opacity(0.16)
                               : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("The mascot, the crowd, the anthem — things you shoot that aren't on a roster · "
              + "\(Shortcuts.shared.display(.subjectsOnly)) at the bench")
    }

    private func focusPill(for team: Team) -> some View {
        // Reads the bench actually on screen rather than `focusedTeamID`, which is nil
        // until something is picked even though a roster is showing.
        let on = !state.subjectsOnly && state.shownTeamID == team.id
        return Button {
            state.show(.team(team.id))
        } label: {
            Text(state.focusLabel(for: team))
                .font(.caption2.weight(on ? .bold : .regular))
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(on ? Color.accentColor.opacity(0.16)
                               : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show \(team.name)")
    }

    /// Ticking a roster off clears any armed selection — some of those players may have
    /// just left the grid.
    ///
    /// The setter uses the value it's handed rather than toggling. A binding's setter is not
    /// promised to be called exactly once per click, and a setter that flips the state would
    /// come out where it started on the second call — the tick appears to take and doesn't,
    /// so the second roster never joins, the pills never appear, and ← → have nothing to
    /// switch between. Written this way it's idempotent and can't care how often it runs.
    private func teamChoice(_ item: Team) -> some View {
        Toggle(isOn: Binding(
            get: { state.isActiveTeam(item.id) },
            set: { wanted in
                state.setActiveTeam(item.id, on: wanted)
                selectedPlayerIDs = []
            }
        )) {
            Text(item.name)
        }
        // Greyed rather than hidden: a team vanishing from the menu reads as it having been
        // deleted. The league headings say why it's grey. `setActiveTeam` refuses with a
        // reason either way, for any path that isn't this menu.
        .disabled(!state.isActiveTeam(item.id) && !state.canActivateTeam(item.id))
    }

    /// A player with its place in the flattened grid. The identity comes from `GridID`,
    /// which is also what the cursor's `scrollTo` asks for — see the note there.
    private struct GridPlayer: Identifiable {
        let index: Int
        let player: Player
        var id: String { GridID.player(at: index, player) }
    }

    /// One roster, one grid.
    ///
    /// It used to draw every active roster with a `Section` header each, and that didn't
    /// hold up — sections nested inside a `ForEach` inside a `LazyVGrid` never drew their
    /// headers, and the grid went on showing rosters that had left the data. There's only
    /// ever one bench on screen now, so none of that is needed: the pills say which, and
    /// `flowPlayers` is the same list the cursor indexes.
    /// Adding a subject — the mascot, the crowd, the anthem. Shown on the Subjects pill it
    /// appends to, and hidden until asked for, because it's a once-a-season job rather than
    /// something to step past on every clip.
    @ViewBuilder
    private var subjectField: some View {
        HStack(spacing: 6) {
            Button {
                showingSubjectField.toggle()
                if !showingSubjectField { newSubject = "" }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: showingSubjectField ? "minus.circle" : "plus.circle")
                    Text("Subject")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Something you shoot that isn't on a roster — the mascot, the crowd, the "
                  + "anthem. They tag like a player, so the category is still free to say "
                  + "what happened.")

            if showingSubjectField {
                TextField("Mascot", text: $newSubject)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitSubject)
                Button("Add", action: commitSubject)
                    .disabled(newSubject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
    }

    private func commitSubject() {
        let clean = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = library.subjects.count
        library.addSubject(clean)
        guard library.subjects.count > before else {
            state.status = Team.slug(clean).isEmpty
                ? "A subject needs a name with letters or numbers in it."
                : "There's already a subject called \"\(clean)\"."
            return
        }
        newSubject = ""
        showingSubjectField = false
    }

    private var playerGrid: some View {
        // Resolved once for the whole grid rather than per chip.
        let onClip = playersOnClip
        let players = state.flowPlayers

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], spacing: 6) {
                    playerChips(players, onClip: onClip)
                }
                if players.isEmpty {
                    // Two different empties: a number that matches nobody, and a roster
                    // with nobody in it. The first can't normally happen — a digit that
                    // would empty the grid is refused — but a roster edit underneath can
                    // do it, and "wears #." would be nonsense for the second.
                    Text(state.subjectsOnly
                         ? "No subjects yet. + Subject adds one."
                         : state.numberEntry.isEmpty
                         ? "This roster has no players yet. ⌘⇧R to add some."
                         : "Nobody on this bench wears #\(state.numberEntry).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            .frame(maxHeight: 190)
            .onChange(of: state.playerCursor) { _ in
                guard state.keyboardFlow, state.tagStage == .players,
                      let target = state.cursorScrollID
                else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func playerChips(_ list: [Player], onClip: Set<String>) -> some View {
        let rows = list.enumerated().map { GridPlayer(index: $0.offset, player: $0.element) }
        ForEach(rows) { row in
            let player = row.player
            let index = row.index
            Button {
                if selectedPlayerIDs.contains(player.id) {
                    selectedPlayerIDs.remove(player.id)
                } else {
                    selectedPlayerIDs.insert(player.id)
                }
            } label: {
                let picked = selectedPlayerIDs.contains(player.id)
                let tagged = onClip.contains(player.id)
                TagChip(tint: playerTint(picked: picked, onClip: tagged)) {
                    HStack(spacing: 6) {
                        Text(player.number.isEmpty ? "–" : player.number)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(minWidth: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.name)
                                .font(.caption.weight(picked ? .semibold : .regular))
                                .lineLimit(1)
                                // Semibold is wider, so a long name shrinks slightly
                                // instead of truncating the moment it's picked.
                                .minimumScaleFactor(0.85)
                            if !player.position.isEmpty {
                                Text(player.position)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        // Always green, so "green tick = already on this clip" holds
                        // whether the chip is picked or not.
                        if tagged {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.green)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .id(row.id)
            .overlay(cursorRing(on: isCursor(.players, index)))
            // Only subjects, because a player is removed in the roster editor where the
            // warning about their tags belongs. Removing a subject takes nothing away from
            // the clips already tagged with it — the name was recorded on the tag.
            .contextMenu {
                if player.isSubject {
                    Button("Remove \"\(player.name)\"", role: .destructive) {
                        selectedPlayerIDs.remove(player.id)
                        library.removeSubject(player.name)
                    }
                }
            }
        }
    }

    /// Where the keyboard flow is pointing. A heavier ring than "picked", because this one
    /// moves with every key press and has to be findable at a glance.
    private func isCursor(_ stage: TagStage, _ index: Int) -> Bool {
        guard state.keyboardFlow, state.tagStage == stage else { return false }
        switch stage {
        case .players:    return state.playerCursor == index
        case .categories: return state.categoryCursor == index
        case .clips:      return false
        }
    }

    @ViewBuilder
    private func cursorRing(on showing: Bool) -> some View {
        if showing {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
        }
    }

    // MARK: Categories

    private var categoryRow: some View {
        // Resolved once for the whole grid rather than per chip.
        let onThisClip = categoriesOnClip
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingCategoryField.toggle()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add a category")
            }

            if showingCategoryField {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        TextField("Dancing", text: $newCategory)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(tagOnce)
                        // Return does the common thing. The word lands in the one-offs by
                        // being used, so there's nothing to decide at the moment of typing —
                        // which is the whole point of a one-off.
                        Button("Tag", action: tagOnce)
                            .disabled(clip == nil || typedCategory.isEmpty)
                        Button("Add", action: commitCategory)
                            .disabled(typedCategory.isEmpty)
                    }
                    Text("Tag uses it once and keeps it to hand. Add puts it in the list for good.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            sectionPills

            // 96, not 84: an adaptive grid packs in as many columns of at least the minimum
            // as will fit and only then widens them, so a wider panel gives *narrower*
            // cells. At 84 a 300pt panel lands on 88pt cells, and the tick on an applied
            // chip then costs a letter off "Celebration". 96 keeps three columns at worst.
            if state.flowCategories.isEmpty {
                Text(!state.categoryEntry.isEmpty
                     ? "Nothing numbered \(state.categoryEntry) here."
                     : state.currentCategorySection?.id == CategorySection.reservedID
                        ? "Nothing used once yet."
                        : "No categories in this section. Type one above, or ← → to another.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(Array(state.flowCategoryItems.enumerated()), id: \.element.id) { index, item in
                    let category = item.name
                    let applied = onThisClip.contains(category)
                    let oneOff = library.recentCategories.contains(category)
                    Button { tag(with: category) } label: {
                        TagChip(tint: applied ? Color.green : nil, alignment: .center) {
                            HStack(spacing: 4) {
                                if applied {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                }
                                // Only while the keyboard flow is on. A positional number
                                // is a way of typing at a chip, so it's clutter to anyone
                                // reaching for the mouse.
                                if state.keyboardFlow {
                                    Text("\(item.number)")
                                        .font(.caption2.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(category)
                                    .font(.caption.weight(applied ? .semibold : .medium))
                                    .lineLimit(1)
                                    // A long category you've added yourself shrinks a little
                                    // rather than losing its end to an ellipsis.
                                    .minimumScaleFactor(0.85)
                                    // A one-off reads as lighter than the permanent list, so
                                    // the set you actually curated still stands out in a grid
                                    // that now holds both.
                                    .italic(oneOff)
                                    .foregroundStyle(oneOff && !applied ? .secondary : .primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(clip == nil)
                    .opacity(clip == nil ? 0.4 : 1)
                    .overlay(cursorRing(on: isCursor(.categories, index)))
                    .help(applied
                          ? "\(category) is already on this clip. Clicking again adds it for "
                            + "whoever you've got selected."
                          : "Tag this clip as \(category)")
                    .contextMenu {
                        if oneOff {
                            Menu("Keep \"\(category)\" in") {
                                ForEach(library.categorySections) { target in
                                    Button(target.name) {
                                        library.keepCategory(category, to: target.id)
                                    }
                                }
                            }
                            Button("Forget \"\(category)\"", role: .destructive) {
                                if state.filterCategory == category { state.filterCategory = nil }
                                library.forgetRecent(category)
                            }
                        } else {
                            if library.categorySections.count > 1 {
                                Menu("Move \"\(category)\" to") {
                                    ForEach(library.categorySections) { target in
                                        Button(target.name) {
                                            library.moveCategory(category, toSection: target.id)
                                            state.categoryCursor = 0
                                        }
                                        .disabled(target.items.contains(category))
                                    }
                                }
                                Divider()
                            }
                            Button("Remove \"\(category)\"", role: .destructive) {
                                if state.filterCategory == category { state.filterCategory = nil }
                                library.removeCategory(category)
                            }
                        }
                    }
                }
            }
        }
    }

    private var hint: String {
        if clip == nil { return "Select a clip to tag" }
        switch selectedPlayers.count {
        case 0:
            // Clicking a category uses the player the keyboard flow has armed when nothing
            // is picked by hand, so the hint has to name them rather than ask for a player.
            if let armed = state.flowPlayer {
                return "Click a category to tag \(armed.label)"
            }
            return currentTags.isEmpty ? "Pick a player, then a category" : "Pick the next player"
        case 1:  return "Click a category to tag \(selectedPlayers[0].number.isEmpty ? selectedPlayers[0].name : "#" + selectedPlayers[0].number)"
        default: return "Click a category to tag \(selectedPlayers.count) players"
        }
    }

    /// One pill per section, with ← → the keyboard equivalent. The same shape as the bench
    /// pills a stage earlier, because it's the same idea: which set am I looking at.
    private var sectionPills: some View {
        let sections = state.categorySections
        return VStack(alignment: .leading, spacing: 6) {
            pillRow(sections)
            // Its own row rather than an overlay. As an overlay it floated down across the
            // first line of chips, covering the categories you were about to look at.
            if addingSection {
                HStack(spacing: 6) {
                    TextField("Fans", text: $newSection)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitSection)
                    Button("Add", action: commitSection)
                        .disabled(newSection.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { addingSection = false; newSection = "" }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func pillRow(_ sections: [CategorySection]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let on = index == min(max(state.categorySectionIndex, 0), sections.count - 1)
                Button {
                    state.categorySectionIndex = index
                    state.categoryCursor = 0
                    // The numbers belong to the section on screen, so digits typed against
                    // the one you're leaving would quietly narrow the one you arrive at.
                    state.categoryEntry = ""
                } label: {
                    Text(section.name)
                        .font(.caption2.weight(on ? .bold : .regular))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(section.id == CategorySection.reservedID
                      ? "Words you've used once. The last \(TagLibrary.recentLimit) are kept."
                      : "\(section.items.count) categor\(section.items.count == 1 ? "y" : "ies")")
                .contextMenu {
                    // Recent isn't a real section — it's a view of the one-offs — so it has
                    // nothing to rename, reorder or delete.
                    if section.id != CategorySection.reservedID {
                        // The index follows the section. Without this, moving the one
                        // you're looking at leaves you looking at whatever took its place.
                        Button("Move Left") { moveSection(section.id, by: -1) }
                            .disabled(index == 0)
                        Button("Move Right") { moveSection(section.id, by: 1) }
                            .disabled(index >= library.categorySections.count - 1)
                        Divider()
                        Button("Remove \"\(section.name)\"", role: .destructive) {
                            library.removeSection(section.id)
                            state.categorySectionIndex = 0
                            state.categoryCursor = 0
                            state.categoryEntry = ""
                            // Its categories went with it, one of which may have been the
                            // filter the clip list is currently narrowed by.
                            state.dropDanglingFilters()
                        }
                        .disabled(library.categorySections.count < 2)
                    }
                }
            }

            Button {
                addingSection.toggle()
                if !addingSection { newSection = "" }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("Add a section of categories")

            Spacer(minLength: 0)

            if !state.categoryEntry.isEmpty {
                Text(state.categoryEntry)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                    .help("Showing categories starting \(state.categoryEntry) · ⌫ to go back")
            } else if state.keyboardFlow && sections.count > 1 {
                Text("← →")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Switch section from the keyboard")
            }
        }
    }

    private func moveSection(_ id: String, by offset: Int) {
        let wasOn = state.currentCategorySection?.id == id
        library.moveSection(id, by: offset)
        if wasOn, let index = library.categorySections.firstIndex(where: { $0.id == id }) {
            state.categorySectionIndex = index
        }
    }

    private func commitSection() {
        let clean = newSection.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = Team.slug(clean)
        let before = library.categorySections.count
        library.addSection(clean)

        // Counted rather than looked up: a duplicate name finds the *existing* section, so
        // searching for it would read as success. Refusals used to close the field as if it
        // had worked, which looks exactly like the feature being broken.
        guard library.categorySections.count > before,
              let index = library.categorySections.firstIndex(where: { $0.id == wanted })
        else {
            state.status = wanted == CategorySection.reservedID
                ? "\"Recent\" is kept for the one-off tags — pick another name."
                : wanted.isEmpty
                    ? "A section needs a name with letters or numbers in it."
                    : "There's already a section called \"\(clean)\"."
            return          // the field stays open with what you typed still in it
        }

        // Jump to it. You made a section to put things in, so leaving you looking at the
        // one you were on means an arrow press before you can do anything with it.
        state.categorySectionIndex = index
        state.categoryCursor = 0
        newSection = ""
        addingSection = false
    }

    private var typedCategory: String {
        newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitCategory() {
        let clean = typedCategory
        let before = library.categories.count
        // Into the section on screen, which is the one you were looking at when you decided
        // it was missing. Never into Recent, which isn't a real section.
        library.addCategory(clean,
                            to: library.sectionForNewCategory(
                                viewing: state.currentCategorySection?.id))
        guard library.categories.count > before else {
            // A category has to be unique across every section, so the one it clashes with
            // may not even be on screen. Naming it is the difference between "that didn't
            // work" and knowing why.
            if let existing = library.categorySections.first(where: {
                $0.items.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
            }) {
                state.status = "\"\(clean)\" is already in \(existing.name)."
            } else {
                state.status = "A category needs a name."
            }
            return
        }
        newCategory = ""
        showingCategoryField = false
    }

    /// Tags the clip with whatever's typed without adding it to the permanent list. The word
    /// is recorded as a one-off by `applyTags` itself, so it only sticks around if it was
    /// actually used — and the oldest falls off once there are more than a dozen.
    private func tagOnce() {
        let name = typedCategory
        guard !name.isEmpty, clip != nil else { return }
        tag(with: name)
        newCategory = ""
        showingCategoryField = false
    }

    // MARK: Tags on this clip

    private var tagList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("On this clip").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(currentTags) { tag in
                HStack(spacing: 6) {
                    Text(tag.category)
                        .font(.caption.weight(.semibold))
                    if let who = tag.playerLabel {
                        Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // The green chips above only cover the roster on show, so a tag belonging
                    // to another team would otherwise look like nothing was highlighted.
                    if let other = tag.teamName,
                       let teamID = tag.teamID, !state.isActiveTeam(teamID) {
                        Text(other)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                            .lineLimit(1)
                            .help("Tagged under \(other). Switch the team picker to see it "
                                  + "highlighted in the roster.")
                    }
                    if let position = tag.playerPosition {
                        Text(position).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        library.remove(tag, undoLabel: "Remove \(tag.category) "
                                       + "from \(tag.clipName)")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Actions

    /// One tag per selected player, so a play involving three of them is three clicks, not nine.
    /// With nobody selected it tags the clip itself.
    private func tag(with category: String) {
        guard let clip else { return }
        guard let umid = clip.umid else {
            state.status = "\(clip.name) has no UMID in its XML, so it can't be tagged."
            return
        }

        // Building the tag itself lives on `AppState` now, so the keyboard flow and this
        // panel file identical tags.
        //
        // With nothing picked by hand, a player the keyboard flow has armed counts: picking
        // #17 with the keyboard and then reaching for the mouse should still tag #17, not
        // tag the clip with nobody against it.
        let chosen = selectedPlayers.isEmpty
            ? (state.flowPlayer.map { [$0] } ?? [])
            : selectedPlayers
        let result = state.applyTags(to: clip,
                                     umid: umid,
                                     players: chosen,
                                     // The bench on screen — see the note in `applyFlowTag`.
                                     fallbackTeam: state.shownTeams.first,
                                     category: category)

        if chosen.isEmpty {
            state.status = result.clipTag
                ? "Tagged \(clip.name) as \(category). ⌘Z to undo."
                : "\(clip.name) is already tagged \(category)."
            if state.keyboardFlow { state.resetFlow() }
            if result.clipTag { moveOnIfAsked() }
            return
        }

        let added = result.players
        if added.isEmpty {
            state.status = "Already tagged \(category) — nothing to add."
        } else {
            let who = added.count == 1
                ? added[0].label
                : added.map { $0.number.isEmpty ? $0.name : "#\($0.number)" }.joined(separator: ", ")
            let skipped = chosen.count - added.count
            state.status = "Tagged \(clip.name) as \(category) — \(who)."
                + (skipped > 0 ? " \(skipped) already had it." : "")
                + " ⌘Z to undo."
        }

        // Cleared on purpose: the next category is usually for a different player
        // (one scores, another assists), so carrying the selection over invites mistakes.
        selectedPlayerIDs = []

        // Reaching for the mouse mid-flow puts the keyboard back at the clips rather than
        // leaving it pointed at a category on a clip that may have just moved on.
        if state.keyboardFlow { state.resetFlow() }

        if !added.isEmpty { moveOnIfAsked() }
    }

    /// Off by default, and deliberately so: the usual case is one clip taking two tags — a
    /// goal for one player and an assist for another — and moving on after the first would
    /// put the second on the wrong clip. On, it's for a pass where each clip gets one tag,
    /// which is most of a warmups or B-roll run.
    ///
    /// Only called when a tag actually landed, so clicking a category the clip already has
    /// doesn't quietly skip past it.
    private func moveOnIfAsked() {
        guard advanceAfterTag else { return }
        state.advanceAfterAction()
    }

    /// The import itself lives on `AppState`, because it's a File menu command too and the
    /// panel isn't always on screen. The panel's job is just to follow it to the new roster.
    private func importRoster() {
        state.importRoster()
    }
}

/// One pill for players and categories alike, so the panel reads as a single system.
///
/// `tint` nil is the resting state — a plain grey chip. A tint means the chip is on, shown
/// as a stronger fill *and* a ring around the edge. The ring is what makes it unmistakable:
/// a fill alone, at any opacity that still leaves the text readable, is easy to miss at a
/// glance mid-game, and it disappears entirely for a colour-blind viewer. Call sites add a
/// checkmark on top where there's room for one.
///
/// The colours mean different things and shouldn't be swapped: accent is "picked, about to
/// be tagged", green is "already on this clip".
private struct TagChip<Content: View>: View {
    var tint: Color?
    var alignment: Alignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(tint?.opacity(0.28) ?? Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // strokeBorder draws inside the shape, so the ring isn't half-clipped.
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint ?? .clear, lineWidth: 2)
            )
    }
}

/// Small coloured chips shown on each clip row.
struct TagChips: View {
    let tags: [Tag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    Text(chipText(tag))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.22))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chipText(_ tag: Tag) -> String {
        if let number = tag.playerNumber, !number.isEmpty {
            return "\(number) · \(tag.category)"
        }
        return tag.category
    }
}
