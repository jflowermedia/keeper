import SwiftUI
import AppKit

// MARK: - Where the keyboard is

/// The three things the keyboard flow can be pointed at. Tab moves forward through them,
/// ⇧Tab and Escape come back.
enum TagStage: String {
    case clips, players, categories

    var title: String {
        switch self {
        case .clips:      return "Clips"
        case .players:    return "Player"
        case .categories: return "Category"
        }
    }
}

/// A plain, non-isolated mirror of two facts the key monitor needs before it can decide
/// whether to swallow a keystroke: whether the flow is on, and which stage it's at.
///
/// The monitor runs outside the main actor and `AppState` lives on it, so the monitor can't
/// ask. Mirroring two values is the smallest thing that works: `AppState` writes them in a
/// `didSet`, the monitor only reads them, and both only ever happen on the main thread.
/// Same shape as `Playback.shared` and `TagLibrary.shared`.
final class FlowKeyState {
    static let shared = FlowKeyState()

    var active = false
    var stage: TagStage = .clips

    private init() {
        // The toggle is stored, so the monitor has to start out agreeing with it — the
        // first keystroke can arrive before any view has had a chance to set this.
        active = UserDefaults.standard.bool(forKey: "keyboardFlow")
    }

    /// Whether the flow wants this key, given where it is. Everything the flow doesn't
    /// claim falls through to the ordinary review keys, which is what keeps Space playing
    /// the clip while you tag.
    static func claims(_ key: String, stage: TagStage, shift: Bool) -> Bool {
        // ⇧↑ and ⇧↓ extend the clip selection — that's the list's own gesture, and the one
        // you use to pick a range before exporting. Taking it collapsed the selection to a
        // single clip on every press, because the flow's answer to ↓ is "move to the next
        // clip". The flow keeps plain arrows; Shift belongs to the list.
        if shift, key == "up" || key == "down", stage == .clips {
            return false
        }

        switch key {
        case "tab", "return", "up", "down":
            return true
        case "left", "right":
            // Switches bench at the clips and players steps, moves the cursor at the
            // categories step. Claimed at the clip step as well because that's the resting
            // position — the one you're in when you reach for them — and having them work
            // only after Tab was the whole of the bug.
            return true
        case "escape", "delete":
            // Swallowing Escape at the clip step would take away the way out of the
            // full-screen preview, which is the one thing Escape is for everywhere else.
            return stage != .clips
        default:
            // A digit picks a jersey number, a letter jumps to a category — but only at the
            // stage that uses them, so 1 and 3 still shuttle the clip everywhere else.
            guard key.count == 1, let character = key.first else { return false }
            switch stage {
            case .players:    return character.isNumber
            case .categories: return character.isLetter
            case .clips:      return false
            }
        }
    }
}

// MARK: - Grid identity

/// How a player chip identifies itself in the roster grid.
///
/// Defined once because two places need it to agree: the grid builds it, and `scrollTo`
/// looks it up. It carries the position as well as the player for two separate reasons —
/// a bare index repeats across rosters, so switching bench would hand the new roster the
/// old one's identities and SwiftUI would reuse the views rather than update them; and
/// `Player.id` is `teamID/number`, which two players wearing the same number would share.
enum GridID {
    static func player(at index: Int, _ player: Player) -> String {
        "\(index)-\(player.id)"
    }
}

// MARK: - Showing where it is

extension View {
    /// An outline round the whole section the keyboard flow is pointed at — the clip list,
    /// the roster, or the categories.
    ///
    /// The ring on a single chip says which one is under the cursor; this says which of the
    /// three areas the keys are going to at all, which is the thing you need at a glance
    /// when Tab has just moved it somewhere else.
    func flowSection(_ stage: TagStage, current: TagStage, active: Bool) -> some View {
        let here = active && current == stage
        return padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(here ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 2)
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(here ? Color.accentColor.opacity(0.05) : .clear)
            )
    }
}

extension Notification.Name {
    /// Posted by the key monitor with a key the flow claimed. `userInfo` carries "key",
    /// "shift" and "token" — the token because every window's view hears this and they
    /// share one `AppState`.
    static let keeperFlowKey = Notification.Name("keeperFlowKey")
}

// MARK: - The machine

extension AppState {

    // MARK: What's in play

    /// The rosters showing in the panel, in order. One for a practice, two for a game —
    /// which is the case that matters: a game's tags come off both benches, and dropping a
    /// thirteen-team league menu between every tag is what makes tagging slow.
    ///
    /// Falls back to the first roster so the panel is never empty merely because nothing
    /// has been chosen yet.
    var activeTeams: [Team] {
        let picked = activeTeamIDs.compactMap { library.team(id: $0) }
        return picked.isEmpty ? Array(library.teams.prefix(1)) : picked
    }

    /// The rosters actually drawn in the grid: one when a bench is focused, otherwise all
    /// of them. Everything that indexes the grid goes through this rather than
    /// `activeTeams`, so the cursor and a typed number can't reach a player who isn't on
    /// screen.
    /// Always exactly one roster — there's no "both" view. Two benches at once was 40-odd
    /// chips to read, and the pills switch between them in one key or one click.
    var shownTeams: [Team] {
        let teams = activeTeams
        if let focusedTeamID, let one = teams.first(where: { $0.id == focusedTeamID }) {
            return [one]
        }
        return Array(teams.prefix(1))
    }

    /// The bench actually on screen. Nothing reads `focusedTeamID` directly to decide what's
    /// lit, because it's nil until something is picked and the first roster shows anyway.
    var shownTeamID: String? { shownTeams.first?.id }

    /// Every player across the rosters in play, whichever bench is showing and whatever a
    /// typed number is hiding. What a hand-made selection is resolved against.
    var allActivePlayers: [Player] { activeTeams.flatMap(\.players) + library.subjectEntries }

    /// The roster on screen, before the number filter, with the subjects on the end.
    ///
    /// Subjects live in the bench rather than in a section of their own because that's where
    /// your hand already is — the cursor, Return, and the outline all work on them unchanged.
    /// They have no number, so the moment you start typing one they drop out of the grid,
    /// which is what you want: typing a number means you're after a person.
    var rosterPlayers: [Player] { shownTeams.flatMap(\.players) + library.subjectEntries }

    /// What the grid shows: the roster narrowed to the number being typed. The cursor
    /// indexes this, so a filtered grid and the cursor can't drift apart.
    var flowPlayers: [Player] {
        guard !numberEntry.isEmpty else { return rosterPlayers }
        return rosterPlayers.filter { $0.number.hasPrefix(numberEntry) }
    }

    /// Flips between the benches: all of them, then each in turn. This is what ← → do at
    /// the player stage, and what the pills in the panel click through.
    func cycleFocus(forward: Bool) {
        let teams = activeTeams
        guard teams.count > 1 else {
            // Said rather than ignored: a key that does nothing with no explanation is how
            // "it doesn't switch between the teams" starts.
            status = "Only one roster is in play — tick a second one in the roster menu."
            return
        }

        // Straight between the benches. There's no "all of them" position any more: two
        // rosters at once was 40-odd chips to read, which is what the switch is for.
        let ids = teams.map(\.id)
        let at = shownTeamID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = forward
            ? (at + 1) % ids.count
            : (at - 1 + ids.count) % ids.count
        focusedTeamID = ids[next]
        status = "Showing \(teams[next].name)."
    }

    /// A short form that fits a pill or a 200pt button: the filename code if there is one,
    /// otherwise the first word of the name. `Team.code` is optional and plenty of rosters
    /// are typed in without one, so "Virden Oil Capitals vs Winnipeg Blues" is the case
    /// this exists to avoid.
    static func shortName(_ team: Team) -> String {
        let code = team.code?.trimmingCharacters(in: .whitespaces) ?? ""
        if !code.isEmpty { return code }
        let first = team.name.split(separator: " ").first.map(String.init) ?? team.name
        return first.isEmpty ? team.name : first
    }

    func focusLabel(for team: Team) -> String { Self.shortName(team) }

    /// The sections ← → step between: the real ones, then the one-offs if there are any.
    ///
    /// Recents are a section rather than a tail on the last one, so a list you curated never
    /// quietly fills with words you typed once.
    var categorySections: [CategorySection] {
        let real = library.categorySections
        guard !library.recentCategories.isEmpty else { return real }
        return real + [CategorySection(name: "Recent", items: library.recentCategories)]
    }

    /// The section the cursor is in, clamped — sections can be removed while the flow sits
    /// on one, and the Recent section disappears the moment its last word is forgotten.
    var currentCategorySection: CategorySection? {
        let sections = categorySections
        guard !sections.isEmpty else { return nil }
        return sections[min(max(categorySectionIndex, 0), sections.count - 1)]
    }

    /// What the grid draws and the cursor walks: one section at a time.
    var flowCategories: [String] { currentCategorySection?.items ?? [] }

    /// ← → at the category stage, mirroring what they do between benches.
    func cycleCategorySection(forward: Bool) {
        let sections = categorySections
        guard sections.count > 1 else {
            status = "Only one section of categories — add another with + beside them."
            return
        }
        let current = min(max(categorySectionIndex, 0), sections.count - 1)
        categorySectionIndex = (current + (forward ? 1 : -1) + sections.count) % sections.count
        // A fresh section starts at its first label rather than wherever the last one left
        // the cursor, which would otherwise land you somewhere arbitrary.
        categoryCursor = 0
    }

    /// "VIR vs WPG", "Virden Oil Capitals", "3 rosters" — what the picker reads. Two full
    /// club names won't fit the button, which is what the filename code is good for.
    var activeTeamsLabel: String {
        let teams = activeTeams
        switch teams.count {
        case 0:  return "No roster"
        case 1:  return teams[0].name
        case 2:  return "\(Self.shortName(teams[0])) vs \(Self.shortName(teams[1]))"
        default: return "\(teams.count) rosters"
        }
    }

    func isActiveTeam(_ id: String) -> Bool { activeTeamIDs.contains(id) }

    /// Puts a roster in or out of play. Order is kept, so the first one chosen stays first
    /// and the grid doesn't reshuffle under the cursor.
    ///
    /// Idempotent on purpose — see the note on `teamChoice`. Anything driving this from a
    /// binding must be able to call it twice without undoing itself.
    func setActiveTeam(_ id: String, on wanted: Bool) {
        let already = activeTeamIDs.contains(id)
        guard already != wanted else { return }
        if wanted {
            activeTeamIDs.append(id)
        } else {
            activeTeamIDs.removeAll { $0 == id }
        }
        clampFlowCursors()
    }

    func setActiveTeams(_ ids: [String]) {
        activeTeamIDs = ids
        clampFlowCursors()
    }

    /// A roster can be deleted or renumbered under the cursor, which would otherwise leave
    /// it pointing past the end of the grid.
    func clampFlowCursors() {
        // Only when it actually changed: the setter persists, and this runs on every
        // library change.
        let live = activeTeamIDs.filter { library.team(id: $0) != nil }
        if live != activeTeamIDs { activeTeamIDs = live }

        // A bench that's been unticked or deleted can't go on being the focused one.
        // Cleared rather than repointed: `shownTeams` falls back to the first roster, and
        // `shownTeamID` is what lights a pill, so one is still lit.
        if let focused = focusedTeamID, !live.contains(focused) {
            focusedTeamID = nil
        }

        // Guarded for the same reason: `@Published` republishes on every set, equal or not,
        // and this runs whenever the library changes.
        let players = max(0, min(playerCursor, max(0, flowPlayers.count - 1)))
        if players != playerCursor { playerCursor = players }
        let categories = max(0, min(categoryCursor, max(0, flowCategories.count - 1)))
        if categories != categoryCursor { categoryCursor = categories }
        // Against the whole bench, not the filtered grid: a player picked a moment ago is
        // still a valid pick while a typed number happens to be hiding them.
        if let picked = flowPlayerID, !rosterPlayers.contains(where: { $0.id == picked }) {
            flowPlayerID = nil
            if tagStage == .categories { tagStage = .players }
        }
    }

    // MARK: Cursors

    var cursorPlayer: Player? {
        let players = flowPlayers
        guard players.indices.contains(playerCursor) else { return nil }
        return players[playerCursor]
    }

    /// What the grid gives the chip under the cursor, so `scrollTo` can find it.
    var cursorScrollID: String? {
        guard let player = cursorPlayer else { return nil }
        return GridID.player(at: playerCursor, player)
    }

    var cursorCategory: String? {
        let categories = flowCategories
        guard categories.indices.contains(categoryCursor) else { return nil }
        return categories[categoryCursor]
    }

    /// The player the flow is tagging against — the one picked at the player stage. Found
    /// in the whole roster, not the filtered grid: by the time this is read the filter has
    /// been cleared, and a pick must not evaporate because of one.
    var flowPlayer: Player? {
        guard let flowPlayerID else { return nil }
        return rosterPlayers.first { $0.id == flowPlayerID }
    }

    func resetFlow() {
        tagStage = .clips
        numberEntry = ""
        flowPlayerID = nil
    }

    // MARK: The keys

    /// Acts on a key the monitor claimed for the flow. One press acts once, however many
    /// windows heard about it — same token trick as the arrow keys.
    func handleFlowKey(_ key: String, shift: Bool, token: Int) {
        guard token != lastFlowToken else { return }
        lastFlowToken = token
        guard keyboardFlow else { return }

        switch tagStage {
        case .clips:      clipsStageKey(key, shift: shift)
        case .players:    playersStageKey(key, shift: shift)
        case .categories: categoriesStageKey(key, shift: shift)
        }
    }

    /// Tab moves between the three sections and does nothing else — Return is what commits.
    /// A plain rotation, both ways: clips → players → categories → clips.
    private func rotateStage(forward: Bool) {
        let order: [TagStage] = [.clips, .players, .categories]
        guard let at = order.firstIndex(of: tagStage) else { return }
        let next = forward
            ? order[(at + 1) % order.count]
            : order[(at - 1 + order.count) % order.count]
        go(to: next)
    }

    /// Points the keyboard at a section, refusing the ones with nothing to work with and
    /// saying why. The stage is left alone when it refuses, so Tab never lands you
    /// somewhere unusable.
    private func go(to stage: TagStage) {
        switch stage {
        case .clips:
            // Back at the start, so nothing stays armed: a player picked two Tabs ago
            // shouldn't still be the one a later tag lands on.
            flowPlayerID = nil
            numberEntry = ""
            tagStage = .clips

        case .players:
            guard previewClip != nil else {
                status = "Pick a clip first."
                return
            }
            // Cleared first, then checked: the roster is only empty-looking while a
            // number from last time is still narrowing it.
            numberEntry = ""
            guard !rosterPlayers.isEmpty else {
                status = library.teams.isEmpty
                    ? "No roster yet — import one with ⌘I."
                    : "Choose this game's teams in the tagging panel first."
                return
            }
            playerCursor = min(playerCursor, max(0, rosterPlayers.count - 1))
            tagStage = .players

        case .categories:
            guard previewClip != nil else {
                status = "Pick a clip first."
                return
            }
            guard !flowCategories.isEmpty else {
                status = "No categories left to choose from."
                return
            }
            numberEntry = ""
            tagStage = .categories
        }
    }

    private func clipsStageKey(_ key: String, shift: Bool) {
        switch key {
        case "up":     selectRelative(-1)
        case "down":   selectRelative(1)
        case "tab":    rotateStage(forward: !shift)
        case "return": go(to: .players)      // this is the clip — on to the roster
        case "left", "right":
            // Works from here too, not just at the player step. This is the resting
            // position, so it's where the key gets reached for.
            cycleFocus(forward: key == "right")
        default:       break
        }
    }

    private func playersStageKey(_ key: String, shift: Bool) {
        let players = flowPlayers

        switch key {
        case "escape":
            go(to: .clips)
        case "tab":
            // Navigation only. Tabbing past the roster without picking anyone is a real
            // path — a B-Roll or Interview tag has no player against it — so the category
            // strip names whoever it will tag, or says there's nobody.
            rotateStage(forward: !shift)
        case "up":
            // The arrows move within whatever the number has narrowed the grid to, so
            // they leave the filter alone.
            playerCursor = max(0, playerCursor - 1)
        case "down":
            // The guard matters: a roster can be deleted while the cursor is sitting in it,
            // and `min(count - 1, …)` on an empty list is -1.
            guard !players.isEmpty else { return }
            playerCursor = min(players.count - 1, playerCursor + 1)
        case "left", "right":
            // Flip which bench is showing, since ↑ ↓ are busy stepping through players.
            // With one roster in play there's nowhere to go and this does nothing.
            cycleFocus(forward: key == "right")
        case "delete":
            // One digit at a time, the way backspace works everywhere else.
            guard !numberEntry.isEmpty else { return }
            numberEntry.removeLast()
            playerCursor = 0
        case "return":
            guard let player = cursorPlayer else { return }
            flowPlayerID = player.id
            go(to: .categories)
        default:
            guard let character = key.first, character.isNumber else { return }
            // A typed number narrows the grid rather than moving a cursor through it:
            // 1 leaves #1 and #10–#19 on screen, 7 then leaves #17 alone. With twenty-odd
            // chips, seeing the shortlist beats hunting for a ring.
            let attempt = numberEntry + key
            guard rosterPlayers.contains(where: { $0.number.hasPrefix(attempt) }) else {
                // Refused rather than applied, so the grid is never filtered to nothing
                // and the digits already typed survive a fat finger.
                status = "No #\(attempt) on \(shownTeams.first?.name ?? "this roster")."
                return
            }
            numberEntry = attempt
            playerCursor = 0
        }
    }

    private func categoriesStageKey(_ key: String, shift: Bool) {
        let categories = flowCategories

        switch key {
        case "escape":
            // Back a step, keeping whoever was picked, so a wrong category is one key to fix.
            go(to: .players)
        case "tab":
            rotateStage(forward: !shift)
        case "up":
            categoryCursor = max(0, categoryCursor - 1)
        case "down":
            // Every category can be removed by hand, and then `count - 1` is -1.
            guard !categories.isEmpty else { return }
            categoryCursor = min(categories.count - 1, categoryCursor + 1)
        case "left", "right":
            // Between sections, exactly as they move between benches a stage earlier. They
            // used to duplicate ↑ ↓, which left the app using the same keys for two
            // different jobs depending on which stage you were in.
            cycleCategorySection(forward: key == "right")
        case "return":
            // Return files it and moves on; ⇧Return files it and comes back to the players
            // on the same clip, which is the goal-then-assist case. Tab no longer files
            // anything — it only moves between sections.
            applyFlowTag(stayOnClip: shift)
        case "delete":
            break
        default:
            guard let character = key.first, character.isLetter else { return }
            jumpCategory(startingWith: character)
        }
    }

    /// First letter jumps, and pressing it again moves to the next match — so S goes Save,
    /// then Shot, then back to Save.
    private func jumpCategory(startingWith character: Character) {
        let categories = flowCategories
        guard !categories.isEmpty else { return }
        let wanted = String(character).lowercased()

        let matches = categories.indices.filter {
            categories[$0].lowercased().hasPrefix(wanted)
        }
        guard !matches.isEmpty else { return }
        if let after = matches.first(where: { $0 > categoryCursor }) {
            categoryCursor = after
        } else {
            categoryCursor = matches[0]
        }
    }

    // MARK: Filing it

    private func applyFlowTag(stayOnClip: Bool) {
        guard let clip = previewClip else {
            status = "No clip in the viewer to tag."
            resetFlow()
            return
        }
        // A clip with no UMID can't be tagged at all — the same message the panel gives,
        // rather than one that sounds like nothing is selected.
        guard let umid = clip.umid else {
            status = "\(clip.name) has no UMID in its XML, so it can't be tagged."
            return
        }
        guard let category = cursorCategory else {
            // Said rather than ignored, the same rule as switching benches with one roster:
            // a section can be emptied by moving its last category elsewhere, and Return
            // doing nothing in silence is how "tagging stopped working" starts.
            status = currentCategorySection.map {
                "\($0.name) has no categories in it — ← → to another section."
            } ?? "No categories to tag with."
            return
        }

        let player = flowPlayer
        let result = applyTags(to: clip,
                               umid: umid,
                               players: player.map { [$0] } ?? [],
                               // The bench on screen, not the first one in play: a tag with
                               // no player against it belongs to the team you're looking at.
                               fallbackTeam: shownTeams.first,
                               category: category)

        if result.landed {
            status = "Tagged \(clip.name) as \(category)"
                + (player.map { " — \($0.label)" } ?? "")
                + ". ⌘Z to undo."
        } else {
            status = "\(clip.name) is already tagged \(category)"
                + (player.map { " for \($0.label)" } ?? "") + "."
        }

        flowPlayerID = nil
        numberEntry = ""
        if stayOnClip {
            tagStage = .players       // same clip, next player
        } else {
            tagStage = .clips
            // Deliberately after the tag, and it stops at the end of the list rather than
            // wrapping — running off the end and landing back at the top is how you tag
            // the wrong clip without noticing. It also stands still while several clips are
            // selected by hand; see `advanceAfterAction`.
            advanceAfterAction()
        }
    }

    /// What the strip at the top of the panel says to press next. Tab moves between
    /// sections; Return is the one that does something.
    var flowPrompt: String {
        switch tagStage {
        case .clips:
            return "↑ ↓ clips · Return to the roster · Tab moves between sections"
        case .players:
            let bench = activeTeams.count > 1 ? " · ← → bench" : ""
            guard !numberEntry.isEmpty else {
                return "Type a number to narrow the roster · ↑ ↓ · Return picks" + bench
            }
            let n = flowPlayers.count
            return "#\(numberEntry) — \(n) player\(n == 1 ? "" : "s")"
                + " · ⌫ to go back · Return picks"
        case .categories:
            // Names the target, because Tab can now reach here without a player and a
            // tag with nobody against it would otherwise look identical.
            let who = flowPlayer.map { $0.label } ?? "this clip, no player"
            return "↑ ↓ or first letter · Return tags \(who) · ⇧Return keeps this clip"
        }
    }
}
