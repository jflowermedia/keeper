import Foundation

// MARK: - Model

struct Player: Codable, Identifiable, Hashable {
    var teamID: String
    var number: String
    var name: String
    var position: String = ""

    var id: String { "\(teamID)/\(number)" }
    var label: String { number.isEmpty ? name : "#\(number)  \(name)" }

    /// Whether this bench entry is a subject rather than a person on a roster.
    var isSubject: Bool { teamID.hasPrefix(Subjects.teamIDPrefix) }
}

/// One named group of categories.
struct CategorySection: Codable, Identifiable, Hashable {
    var name: String
    var items: [String]

    /// Slugged, so two sections can't share an id in the pills. `addSection` refuses a name
    /// that would collide.
    var id: String { Team.slug(name) }

    /// The one-offs are shown as a section but aren't one — they're a view of
    /// `recentCategories`, with nothing to rename, reorder or delete. So the name is
    /// reserved: a real section called "Recent" would share its id and could never be moved
    /// or removed again.
    static let reservedID = "recent"

    /// What a new library starts with. Gameplay carries the labels that were the whole list
    /// before sections existed; Misc starts empty on purpose, as somewhere to promote a
    /// one-off into.
    static let defaults: [CategorySection] = [
        CategorySection(name: "Gameplay",
                        items: ["Goal", "Assist", "Save", "Hit", "Penalty",
                                "Faceoff", "Shot", "Celebration"]),
        CategorySection(name: "Media", items: ["Interview", "B-Roll"]),
        CategorySection(name: "Misc", items: [])
    ]

    /// Where a library from before sections lands: everything it had, in one section, under
    /// the name it would have been given anyway. Nothing is dropped and nothing is reordered.
    static func migrating(_ flat: [String]) -> [CategorySection] {
        guard !flat.isEmpty else { return defaults }
        return [CategorySection(name: "Gameplay", items: flat),
                CategorySection(name: "Media", items: []),
                CategorySection(name: "Misc", items: [])]
    }
}

/// Things you shoot that aren't on a roster — the mascot, the crowd, the anthem, the arena.
///
/// They sit in the bench and are picked exactly like a player, because that's where your
/// hand already is and because the *subject* of a clip and *what happens in it* are different
/// questions. Tagging a mascot shot as the category "Mascot" would spend the category slot
/// and leave nowhere to say it was also a Celebration.
///
/// A subject rides as a `Player` with no number and a reserved team id. That isn't a hack
/// for its own sake: `label` already renders a numberless entry as a bare name, the number
/// filter already skips anything whose number doesn't match what you're typing, and the
/// cursor already walks whatever the bench holds. The one place it has to be special-cased
/// is `makeTag`, which must not file the reserved id as if it were a real team.
enum Subjects {
    static let teamIDPrefix = "subject:"

    static let defaults = ["Mascot", "Crowd", "Anthem", "Arena", "Officials", "Bench"]

    /// A bench entry for one subject. The reserved id keeps each distinct — several entries
    /// with no number would otherwise share `teamID/number` and collide in the grid.
    static func entry(_ name: String) -> Player {
        Player(teamID: teamIDPrefix + Team.slug(name), number: "", name: name)
    }
}

struct Team: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// Short code for filenames, e.g. YWP. A preset's own code is the fallback.
    ///
    /// Optional on purpose: Swift's generated decoder throws on a missing key for a
    /// non-optional property, default value or not, so adding one as `String = ""` would
    /// make every library saved before this field existed fail to load.
    var code: String?

    /// What this roster is filed under in the team menus — "MJHL", "Bisons", whatever you
    /// like. Free text rather than a fixed list, because one person's leagues are another's
    /// clients. Optional for the same decoding reason as `code`.
    var league: String?

    var players: [Player] = []

    static func slug(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

/// One tag on one clip. Keyed by the camera's UMID, so it survives renaming, moving
/// between drives, and a card restarting its clip numbering.
struct Tag: Codable, Identifiable, Hashable {
    var id = UUID()
    var umid: String

    // Kept so tags stay readable when the drive they came from isn't plugged in.
    var clipName: String
    var volumeName: String
    var path: String

    var teamID: String?
    var teamName: String?
    var playerNumber: String?
    var playerName: String?
    var playerPosition: String?
    var category: String
    var note: String = ""
    var created = Date()

    var playerID: String? {
        guard let teamID, let playerNumber else { return nil }
        return "\(teamID)/\(playerNumber)"
    }

    var playerLabel: String? {
        guard let playerNumber, let playerName else { return nil }
        return playerNumber.isEmpty ? playerName : "#\(playerNumber) \(playerName)"
    }

    /// "17-Smith" or "Goal" — used for export folder names.
    var folderSafePlayer: String? {
        guard let playerNumber, let playerName else { return nil }
        let clean = playerName.replacingOccurrences(of: "/", with: "-")
        return playerNumber.isEmpty ? clean : "\(playerNumber)-\(clean)"
    }
}

// MARK: - Lenient decoding

// Swift's generated decoder throws on a missing key even for a property with a default
// value, so the moment a field is added, every library written before it existed stops
// loading — and a library that won't load is how a season of tagging disappears. Making
// each new field optional avoids that, but only for the fields someone remembers to make
// optional. These decoders close the hole for good: anything absent takes its default.
//
// Written in an extension rather than in the type, which keeps the memberwise initialiser.
// Encoding stays as generated.

extension Player {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? ""
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
    }
}

extension Team {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = storedName
        // A team with no id would detach every tag hanging off it, so it's rebuilt the same
        // way `importRoster` builds it rather than left empty.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Team.slug(storedName)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        league = try c.decodeIfPresent(String.self, forKey: .league)
        players = try c.decodeIfPresent([Player].self, forKey: .players) ?? []
    }
}

extension Tag {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        umid = try c.decodeIfPresent(String.self, forKey: .umid) ?? ""
        clipName = try c.decodeIfPresent(String.self, forKey: .clipName) ?? ""
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName)
        playerNumber = try c.decodeIfPresent(String.self, forKey: .playerNumber)
        playerName = try c.decodeIfPresent(String.self, forKey: .playerName)
        playerPosition = try c.decodeIfPresent(String.self, forKey: .playerPosition)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

// MARK: - Library

/// Deliberately not actor-isolated: every call comes from the UI on the main thread,
/// and a plain class keeps it simple to observe from SwiftUI views.
final class TagLibrary: ObservableObject {
    static let shared = TagLibrary()

    @Published var teams: [Team] = []
    /// Order matters: it is also the tag priority used when naming a clip that has several.
    /// Categories in sections — Gameplay, Media, Misc — which ← → step between while ↑ ↓
    /// move within one. The grouping is organisation only: with forty labels a flat grid is
    /// a search every time, and sections turn that into "which kind of thing is this".
    @Published var categorySections: [CategorySection] = CategorySection.defaults

    /// Every category, in section order. Computed rather than stored, so everything that
    /// treats the list as flat — filename priority, the preset editor, the filter menu —
    /// carries on unchanged and there is only one order to keep straight.
    var categories: [String] { categorySections.flatMap(\.items) }
    /// Non-roster subjects, on a pill of their own beside the teams. See `Subjects`.
    @Published var subjects: [String] = Subjects.defaults
    /// One-off categories, newest first and capped. See `noteRecent`.
    @Published private(set) var recentCategories: [String] = []
    @Published private(set) var tags: [Tag] = []
    @Published var presets: [RenamePreset] = [.standard()]

    /// Clips you've flagged yourself, by UMID. The card is never touched: the override is
    /// applied to the sidecar at the destination when the clip is copied out.
    @Published private(set) var flagOverrides: [String: FlagMark] = [:]

    private init() { load() }

    // MARK: - Undo

    /// What one clip's flag was before a change. `override` is nil for "no override at
    /// all", which is a state in its own right — the clip takes the camera's flag — and not
    /// the same as an override that happens to agree with it.
    struct KeepState {
        let umid: String
        let override: FlagMark?
    }

    /// One reversible change, stored as what it takes to put things back rather than as the
    /// action that caused it. Applying one returns the edit that undoes it again, so undo
    /// and redo are the same code running in opposite directions.
    struct Edit {
        var label: String
        var keeps: [KeepState] = []
        /// Tags that have to come back.
        var tagsToRestore: [Tag] = []
        /// Tags that have to go.
        var tagIDsToRemove: [UUID] = []

        var isEmpty: Bool {
            keeps.isEmpty && tagsToRestore.isEmpty && tagIDsToRemove.isEmpty
        }
    }

    @Published private(set) var undoStack: [Edit] = []
    @Published private(set) var redoStack: [Edit] = []

    /// Deep enough to cover a reviewing session's worth of mistakes, shallow enough that a
    /// bulk tag removal's worth of restored tags can't sit in memory forever.
    private static let undoDepth = 40

    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    private func push(_ edit: Edit) {
        guard !edit.isEmpty else { return }
        undoStack.append(edit)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack = []       // a new change forks the history, so there's nothing to redo
    }

    /// Puts an edit into effect and returns the one that reverses it.
    private func apply(_ edit: Edit) -> Edit {
        var inverse = Edit(label: edit.label)

        for state in edit.keeps {
            inverse.keeps.append(KeepState(umid: state.umid, override: flagOverrides[state.umid]))
            // Assigning nil to a dictionary subscript removes the key, which is exactly
            // what "no override" has to mean here.
            flagOverrides[state.umid] = state.override
        }

        if !edit.tagIDsToRemove.isEmpty {
            let doomed = Set(edit.tagIDsToRemove)
            inverse.tagsToRestore = tags.filter { doomed.contains($0.id) }
            tags.removeAll { doomed.contains($0.id) }
        }

        if !edit.tagsToRestore.isEmpty {
            inverse.tagIDsToRemove = edit.tagsToRestore.map(\.id)
            tags.append(contentsOf: edit.tagsToRestore)
        }

        rebuildIndex()
        save()
        return inverse
    }

    /// Returns what it undid, for the status line.
    @discardableResult
    func undo() -> String? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(apply(edit))
        if redoStack.count > Self.undoDepth { redoStack.removeFirst() }
        return edit.label
    }

    @discardableResult
    func redo() -> String? {
        guard let edit = redoStack.popLast() else { return nil }
        // Deliberately not `push`: that clears the redo stack, which is the one in use.
        undoStack.append(apply(edit))
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        return edit.label
    }

    /// Called when the whole library is replaced — a load, or a restore from a backup. The
    /// recorded edits describe a library that no longer exists.
    private func clearHistory() {
        undoStack = []
        redoStack = []
    }

    // MARK: Flag overrides

    /// nil when you haven't changed it. A mark whose `flag` is nil is you clearing the flag.
    func flagOverride(for umid: String?) -> FlagMark? {
        guard let umid else { return nil }
        return flagOverrides[umid]
    }

    /// Setting it back to the camera's own flag clears the override rather than storing it,
    /// so "changed" only ever means genuinely different from the card.
    ///
    /// `undoLabel` names the change for the Undo menu. Pass nil only where the change is
    /// bookkeeping that follows something already written to disk — undoing that would put
    /// the library back into disagreement with the file.
    func setFlag(_ flag: ClipFlag?, umid: String, cameraFlag: ClipFlag?, undoLabel: String?) {
        setFlag(flag, for: [(umid, cameraFlag)], undoLabel: undoLabel)
    }

    /// Bulk version: one write of the library rather than one per clip. Marking a hundred
    /// clips individually rewrote every tag a hundred times.
    @discardableResult
    func setFlag(_ flag: ClipFlag?,
                 for clips: [(umid: String, cameraFlag: ClipFlag?)],
                 undoLabel: String?) -> Int {
        guard !clips.isEmpty else { return 0 }

        // Only the clips this actually moves, so marking a selection that's already KEEP
        // doesn't write the library or leave a dead step in the undo stack.
        var changing: [KeepState] = []
        for clip in clips {
            let wanted: FlagMark? = flag == clip.cameraFlag ? nil : FlagMark(flag: flag)
            if flagOverrides[clip.umid] != wanted {
                changing.append(KeepState(umid: clip.umid, override: flagOverrides[clip.umid]))
            }
        }
        guard !changing.isEmpty else { return 0 }

        if let undoLabel { push(Edit(label: undoLabel, keeps: changing)) }
        for clip in clips {
            flagOverrides[clip.umid] = flag == clip.cameraFlag ? nil : FlagMark(flag: flag)
        }
        save()
        return changing.count
    }

    func clearFlagOverride(umid: String, undoLabel: String?) {
        clearFlagOverrides(umids: [umid], undoLabel: undoLabel)
    }

    @discardableResult
    func clearFlagOverrides(umids: [String], undoLabel: String?) -> Int {
        let hits = umids.filter { flagOverrides[$0] != nil }
        guard !hits.isEmpty else { return 0 }
        if let undoLabel {
            push(Edit(label: undoLabel,
                      keeps: hits.map { KeepState(umid: $0, override: flagOverrides[$0]) }))
        }
        for umid in hits { flagOverrides[umid] = nil }
        save()
        return hits.count
    }

    static let defaultCategories = [
        "Goal", "Assist", "Save", "Hit", "Penalty",
        "Faceoff", "Shot", "Celebration", "Interview", "B-Roll"
    ]

    private var index: [String: [Tag]] = [:]      // umid -> its tags

    // MARK: Queries

    func tags(forUMID umid: String?) -> [Tag] {
        guard let umid else { return [] }
        return index[umid] ?? []
    }

    func isTagged(_ umid: String?) -> Bool { !tags(forUMID: umid).isEmpty }

    func team(id: String?) -> Team? {
        guard let id else { return nil }
        return teams.first { $0.id == id }
    }

    /// Every player that appears in any tag or roster, for the filter menu.
    var allPlayers: [Player] { teams.flatMap(\.players) }

    /// A tag naming a player who's no longer on their roster, or whose roster is gone.
    ///
    /// Such a tag is kept on purpose: a traded or graduated player is still in the clip, and
    /// removing someone from a roster mustn't strip their name from a season of footage. But
    /// it looks identical to one made against a name that was never meant to stay — a test
    /// entry, a typo since fixed by deleting the row — and the first sign of that used to be
    /// the exported filename. So it's shown rather than changed.
    ///
    /// Subjects aren't roster players and never count. Keyed on team and number, the same
    /// way `refreshTagsFromRoster` matches a tag to its player.
    static func isFormerPlayer(_ tag: Tag, in teams: [Team]) -> Bool {
        guard let number = tag.playerNumber, let teamID = tag.teamID else { return false }
        guard let team = teams.first(where: { $0.id == teamID }) else { return true }
        return !team.players.contains { $0.number == number }
    }

    func isFormerPlayer(_ tag: Tag) -> Bool { Self.isFormerPlayer(tag, in: teams) }

    /// Positions in use across every roster, for the filter menu.
    var allPositions: [String] {
        Array(Set(allPlayers.map(\.position).filter { !$0.isEmpty })).sorted()
    }

    /// Where the position menu starts before you've typed any. Hockey's, because that's what
    /// Keeper was first used for — which is why they go after the positions you use.
    static let starterPositions = ["Forward", "Defence", "Goalie"]

    /// The roster editor's position menu: what you already use, then any starters you don't.
    ///
    /// The menu used to offer the hockey three and nothing else, so someone shooting football
    /// typed "Midfield" by hand on every player. Matching ignores case and spacing, so
    /// "defence" typed once doesn't sit beside "Defence" as a second suggestion.
    static func positionSuggestions(inUse: [String],
                                    starters: [String] = starterPositions)
        -> (used: [String], starters: [String]) {
        var seen: Set<String> = []
        var used: [String] = []
        for raw in inUse {
            let position = raw.trimmingCharacters(in: .whitespaces)
            let key = position.lowercased()
            guard !position.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            used.append(position)
        }
        used.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (used, starters.filter { !seen.contains($0.lowercased()) })
    }

    // MARK: Editing

    /// Returns false when this clip already carries that exact tag. Clicking a category
    /// twice in quick succession is easy, and two identical tags would double-count the
    /// clip on export and clutter the list.
    @discardableResult
    func add(_ tag: Tag, undoLabel: String?) -> Bool {
        !add([tag], undoLabel: undoLabel).isEmpty
    }

    /// Several at once, as one undo step: tagging three players with one click has to come
    /// back off with one press of ⌘Z, not three. Returns the tags that landed, so the caller
    /// can tell which were duplicates.
    @discardableResult
    func add(_ newTags: [Tag], undoLabel: String?) -> [Tag] {
        var landed: [Tag] = []
        for tag in newTags {
            let alreadyThere = (index[tag.umid] ?? []).contains {
                $0.category == tag.category && $0.playerID == tag.playerID
            }
            // Also against this batch, or tagging the same player twice in one call would
            // slip two identical tags through the check above.
            let inThisBatch = landed.contains {
                $0.umid == tag.umid && $0.category == tag.category && $0.playerID == tag.playerID
            }
            guard !alreadyThere, !inThisBatch else { continue }
            landed.append(tag)
        }
        guard !landed.isEmpty else { return [] }

        if let undoLabel {
            push(Edit(label: undoLabel, tagIDsToRemove: landed.map(\.id)))
        }
        for tag in landed {
            tags.append(tag)
            index[tag.umid, default: []].append(tag)
        }
        save()
        return landed
    }

    func remove(_ tag: Tag, undoLabel: String?) {
        guard tags.contains(where: { $0.id == tag.id }) else { return }
        if let undoLabel { push(Edit(label: undoLabel, tagsToRestore: [tag])) }
        tags.removeAll { $0.id == tag.id }
        index[tag.umid]?.removeAll { $0.id == tag.id }
        if index[tag.umid]?.isEmpty == true { index[tag.umid] = nil }
        save()
    }

    func removeAllTags(forUMID umid: String, undoLabel: String?) {
        let going = index[umid] ?? []
        guard !going.isEmpty else { return }
        if let undoLabel { push(Edit(label: undoLabel, tagsToRestore: going)) }
        tags.removeAll { $0.umid == umid }
        index[umid] = nil
        save()
    }

    /// Clears several clips in one pass, so a bulk delete writes the library once.
    @discardableResult
    func removeAllTags(forUMIDs umids: [String], undoLabel: String?) -> Int {
        let targets = Set(umids)
        guard !targets.isEmpty else { return 0 }
        let going = tags.filter { targets.contains($0.umid) }
        guard !going.isEmpty else { return 0 }
        if let undoLabel { push(Edit(label: undoLabel, tagsToRestore: going)) }
        tags.removeAll { targets.contains($0.umid) }
        for umid in targets { index[umid] = nil }
        save()
        return going.count
    }

    /// Re-import a roster with corrected spellings or a new column such as position, and
    /// existing tags pick the change up rather than keeping the old snapshot. Tags are matched
    /// on team and jersey number, which is what a roster is keyed by.
    @discardableResult
    func refreshTagsFromRoster() -> Int {
        var changed = 0
        for index in tags.indices {
            guard let teamID = tags[index].teamID,
                  let number = tags[index].playerNumber,
                  let team = teams.first(where: { $0.id == teamID }),
                  let player = team.players.first(where: { $0.number == number })
            else { continue }

            var updated = tags[index]
            updated.teamName = team.name
            updated.playerName = player.name
            if !player.position.isEmpty { updated.playerPosition = player.position }

            if updated != tags[index] {
                tags[index] = updated
                changed += 1
            }
        }
        if changed > 0 {
            rebuildIndex()
            save()
        }
        return changed
    }

    // MARK: - Editing a roster in the app

    /// What a roster edit is allowed to change, and what it costs.
    ///
    /// The team's `id` is deliberately not in here. It's the slug of whatever the team was
    /// first called, and every tag points at it — change it and a season of tagging detaches
    /// from its players. So renaming a team changes `name` only, and the id stays put.
    ///
    /// A player's identity *is* their number, so renumbering genuinely moves them. Tags
    /// recorded against the old number are carried over before the roster is replaced,
    /// which is the whole reason this is one call rather than a setter per field.
    struct RosterEdit {
        var name: String
        var code: String
        var league: String
        var players: [Player]
        /// Old number to new, for players whose number this edit changes.
        var renumbered: [(from: String, to: String)] = []
    }

    enum RosterEditError: LocalizedError {
        case emptyName
        case duplicateTeamName(String)
        case duplicateNumbers([String])
        case unnamedPlayers(Int)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "The team needs a name."
            case .duplicateTeamName(let name):
                return "There's already a team called \"\(name)\". Team names have to differ, "
                     + "or an import of one replaces the other."
            case .duplicateNumbers(let numbers):
                let blanks = numbers.contains("")
                let real = numbers.filter { !$0.isEmpty }.sorted()
                var parts: [String] = []
                if !real.isEmpty {
                    parts.append("\(real.count == 1 ? "number" : "numbers") \(real.joined(separator: ", "))")
                }
                if blanks { parts.append("a blank number") }
                return "Two players share \(parts.joined(separator: ", and more share ")). "
                     + "Keeper tells players apart by their number, so each has to be unique "
                     + "within the team — a blank one included."
            case .unnamedPlayers(let count):
                return "\(count) \(count == 1 ? "player has" : "players have") no name."
            }
        }
    }

    /// Applies an edit, or throws without touching anything. Returns how many tags moved.
    @discardableResult
    func apply(_ edit: RosterEdit, to teamID: String) throws -> Int {
        let name = edit.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw RosterEditError.emptyName }
        if teams.contains(where: { $0.id != teamID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw RosterEditError.duplicateTeamName(name)
        }

        let players = edit.players.map {
            Player(teamID: teamID,
                   number: $0.number.trimmingCharacters(in: .whitespaces),
                   name: $0.name.trimmingCharacters(in: .whitespaces),
                   position: $0.position.trimmingCharacters(in: .whitespaces))
        }

        let unnamed = players.filter { $0.name.isEmpty }.count
        guard unnamed == 0 else { throw RosterEditError.unnamedPlayers(unnamed) }

        // Blanks count too. A player's id is "team/number", so two players with no number
        // share an id just as surely as two wearing 15 — and a duplicate id in a SwiftUI
        // list is the one thing that misbehaves rather than merely looking wrong.
        var counts: [String: Int] = [:]
        for player in players {
            counts[player.number, default: 0] += 1
        }
        let clashes = counts.filter { $0.value > 1 }.map(\.key)
        guard clashes.isEmpty else { throw RosterEditError.duplicateNumbers(clashes) }

        // Carry the tags over before the roster changes under them. Done in one pass so a
        // swap — two players exchanging numbers — can't be applied twice.
        var moved = 0
        let moves = Dictionary(edit.renumbered.map { ($0.from, $0.to) }, uniquingKeysWith: { _, last in last })
        if !moves.isEmpty {
            for index in tags.indices where tags[index].teamID == teamID {
                guard let current = tags[index].playerNumber, let newNumber = moves[current] else { continue }
                tags[index].playerNumber = newNumber
                moved += 1
            }
        }

        let code = edit.code.trimmingCharacters(in: .whitespaces)
        let league = edit.league.trimmingCharacters(in: .whitespaces)
        let sorted = players.sorted {
            (Int($0.number) ?? Int.max, $0.name) < (Int($1.number) ?? Int.max, $1.name)
        }

        if let i = teams.firstIndex(where: { $0.id == teamID }) {
            teams[i] = Team(id: teamID,
                            name: name,
                            code: code.isEmpty ? nil : code,
                            league: league.isEmpty ? nil : league,
                            players: sorted)
            teams.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        rebuildIndex()
        // Picks up the new team name, and any player name or position that changed.
        _ = refreshTagsFromRoster()
        save()
        return moved
    }

    /// A new, empty team to type a roster into. Returns nil if the name is taken.
    /// A name `addTeam` will accept: free by name *and* by the id derived from it.
    ///
    /// Both have to be tested together, and that's the whole bug this exists to stop. A team
    /// keeps its original id for life — tags are keyed to it, so renaming a team mustn't
    /// detach them — which means the "New team" that the + button creates still has the id
    /// `new-team` after you've renamed it to something real. Search on the name alone and
    /// "New team" looks free; `addTeam` then refuses it on the id, and the + button is dead
    /// for good with nothing on screen to say why.
    ///
    /// Keeping the search here, beside the guard it has to agree with, is the point. The two
    /// drifted apart once because they lived in different files.
    func freeTeamName(startingAt base: String = "New team") -> String {
        Self.freeTeamName(in: teams, startingAt: base)
    }

    /// Which existing team an imported block belongs to, or nil for a new one.
    ///
    /// The id first, then the name. A team keeps its id for life because tags are keyed to
    /// it, so one made with the + button and renamed to "Winnipeg Jets Alumni" still has the
    /// id `new-team`. Matching on the id alone filed a CSV for that club as a *second* team
    /// of the same name — and two teams sharing a name is a state the roster editor refuses
    /// to save, so the editor was bricked by a sequence of entirely reasonable steps.
    static func importTarget(slug: String, name: String, in teams: [Team]) -> Team? {
        if let byID = teams.first(where: { $0.id == slug }) { return byID }
        return teams.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The same search over a given list, so the checks can exercise it against a handful of
    /// made-up teams rather than against your real library.
    static func freeTeamName(in teams: [Team], startingAt base: String = "New team") -> String {
        func taken(_ candidate: String) -> Bool {
            let id = Team.slug(candidate)
            return teams.contains { $0.id == id
                || $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard taken(base) else { return base }
        // Bounded rather than `while true`: a run of names that somehow all collide should
        // give up and let the caller report it, not spin.
        for n in 2...500 {
            let candidate = "\(base) \(n)"
            if !taken(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))"
    }

    func addTeam(named name: String, league: String? = nil) -> Team? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let id = Team.slug(trimmed)
        guard !teams.contains(where: { $0.id == id || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return nil }
        let team = Team(id: id, name: trimmed, code: nil, league: league, players: [])
        upsert(team: team)
        return team
    }

    /// Every league heading already in use, for the editor to offer rather than make you
    /// retype one exactly.
    var knownLeagues: [String] {
        let used = teams.compactMap { $0.league?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(used)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// One heading's worth of teams in the team menus.
    struct LeagueGroup: Identifiable {
        let id: String          // the heading, which is also what makes it unique
        var teams: [Team]
        var name: String { id }
    }

    /// The heading for rosters that haven't been filed under anything.
    static let ungroupedLeague = "Other"

    /// Which league a team counts as being in. The menu headings and the both-teams rule both
    /// read this, so a team can't sit under one heading and be paired as if it were under
    /// another. Unfiled teams count as one league together, the same as they share a heading.
    static func leagueKey(_ team: Team) -> String {
        let trimmed = (team.league ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ungroupedLeague : trimmed
    }

    /// Teams under their league headings, alphabetically, with the unfiled ones last so a
    /// roster missing a league doesn't push the real groups down the menu.
    var teamsByLeague: [LeagueGroup] {
        var groups: [String: [Team]] = [:]
        for team in teams {
            groups[Self.leagueKey(team), default: []].append(team)
        }
        return groups
            .map { heading, members in
                LeagueGroup(id: heading,
                            teams: members.sorted {
                                $0.name.localizedStandardCompare($1.name) == .orderedAscending
                            })
            }
            .sorted {
                if $0.id == Self.ungroupedLeague { return false }
                if $1.id == Self.ungroupedLeague { return true }
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
    }

    /// Whether the menus are worth splitting up. One group is just a header over everything.
    var leaguesAreWorthShowing: Bool { teamsByLeague.count > 1 }

    func upsert(team: Team) {
        if let i = teams.firstIndex(where: { $0.id == team.id }) {
            teams[i] = team
        } else {
            teams.append(team)
            teams.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        save()
    }

    func deleteTeam(id: String) {
        teams.removeAll { $0.id == id }
        save()
    }

    /// Adds to a section, or to the first one when none is named. A category has to be
    /// unique across every section, not just within one: the filter menu, the filename
    /// priority and the tags themselves all key on the bare word, so the same label in two
    /// sections would be the same category pretending to be two.
    func addCategory(_ name: String, to sectionID: String? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !categories.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
        else { return }
        let index = sectionID.flatMap { id in categorySections.firstIndex { $0.id == id } } ?? 0
        guard categorySections.indices.contains(index) else { return }
        categorySections[index].items.append(clean)
        save()
    }

    func removeCategory(_ name: String) {
        for index in categorySections.indices {
            categorySections[index].items.removeAll { $0 == name }
        }
        save()
    }

    // MARK: Sections

    func addSection(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Team.slug(clean)
        guard !clean.isEmpty, !slug.isEmpty,
              slug != CategorySection.reservedID,
              !categorySections.contains(where: { $0.id == slug })
        else { return }
        categorySections.append(CategorySection(name: clean, items: []))
        save()
    }

    /// Removing a section takes its categories with it. Clips already tagged with them keep
    /// the word — a tag records the label, not a pointer to this list — which is why this
    /// doesn't need the warning that removing a player does.
    func removeSection(_ id: String) {
        // Never leave nothing to arrow between: a grid with no sections has no way back.
        guard categorySections.count > 1 else { return }
        categorySections.removeAll { $0.id == id }
        save()
    }

    func moveSection(_ id: String, by offset: Int) {
        guard let from = categorySections.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard categorySections.indices.contains(to) else { return }
        categorySections.swapAt(from, to)
        save()
    }

    // MARK: One-offs

    /// How many one-offs are kept before the oldest falls off.
    ///
    /// Capped on purpose. The whole point is that a word you used once on one card ages out
    /// by itself — a list that only ever grows is the thing being avoided, and an uncapped
    /// one would just be the permanent list with extra steps.
    static let recentLimit = 12

    /// Records a category that isn't in the permanent list, newest first.
    ///
    /// Called when a tag is applied rather than when a word is typed, so a word you thought
    /// better of never appears. Anything already permanent is ignored: a category can be in
    /// one list or the other, never both, or it would draw twice in the grid and the cursor
    /// would stop on it twice.
    func noteRecent(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !categories.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
        else { return }
        recentCategories.removeAll { $0.caseInsensitiveCompare(clean) == .orderedSame }
        recentCategories.insert(clean, at: 0)
        if recentCategories.count > Self.recentLimit {
            recentCategories = Array(recentCategories.prefix(Self.recentLimit))
        }
        save()
    }

    /// Promotes a one-off into the permanent list. It leaves the recents in the same breath,
    /// because being in both is the one state that draws it twice.
    func keepCategory(_ name: String, to sectionID: String? = nil) {
        recentCategories.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        addCategory(name, to: sectionID)          // saves
    }

    /// Where a new category goes when you haven't said: the section on screen, unless that's
    /// the one-offs, in which case the last real one — which is Misc out of the box, and is
    /// the catch-all wherever you've moved it to.
    func sectionForNewCategory(viewing sectionID: String?) -> String? {
        if let sectionID, sectionID != CategorySection.reservedID,
           categorySections.contains(where: { $0.id == sectionID }) {
            return sectionID
        }
        return categorySections.last?.id
    }

    func forgetRecent(_ name: String) {
        recentCategories.removeAll { $0 == name }
        save()
    }

    /// What the grid draws and the cursor walks: the permanent list, then the one-offs.
    ///
    /// Also the filename priority, so a clip tagged both Goal and Dancing is named for the
    /// goal — anything permanent outranks anything passing through.
    var allCategories: [String] { categories + recentCategories }

    /// Rejects a name whose slug is already taken, not just an exact repeat: two subjects
    /// sharing a slug would share a bench id, and a duplicate id in a grid is the one thing
    /// SwiftUI misbehaves over rather than merely drawing oddly.
    func addSubject(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Team.slug(clean)
        guard !clean.isEmpty, !slug.isEmpty,
              !subjects.contains(where: { Team.slug($0) == slug })
        else { return }
        subjects.append(clean)
        save()
    }

    func removeSubject(_ name: String) {
        subjects.removeAll { $0 == name }
        save()
    }

    /// The bench entries for the subjects, in the order they're listed.
    var subjectEntries: [Player] { subjects.map(Subjects.entry) }

    /// Reordering categories changes which tag wins in a filename, so it is a real setting
    /// rather than cosmetics.
    /// Whether `moveCategory` would do anything — a category can only move within its own
    /// section, so the arrow on the last item of Gameplay has to be dead even though there
    /// are more categories below it in the flattened list.
    func canMoveCategory(_ name: String, by offset: Int) -> Bool {
        guard let section = categorySections.firstIndex(where: { $0.items.contains(name) }),
              let from = categorySections[section].items.firstIndex(of: name)
        else { return false }
        return categorySections[section].items.indices.contains(from + offset)
    }

    /// Moves a category into another section, keeping its position at the end of the one it
    /// joins. An existing library migrates into a single section, so this is how a list built
    /// before sections existed gets sorted out without retyping any of it.
    func moveCategory(_ name: String, toSection sectionID: String) {
        guard let from = categorySections.firstIndex(where: { $0.items.contains(name) }),
              let to = categorySections.firstIndex(where: { $0.id == sectionID }),
              from != to
        else { return }
        categorySections[from].items.removeAll { $0 == name }
        categorySections[to].items.append(name)
        save()
    }

    func moveCategory(_ name: String, by offset: Int) {
        guard let section = categorySections.firstIndex(where: { $0.items.contains(name) }),
              let from = categorySections[section].items.firstIndex(of: name)
        else { return }
        let to = from + offset
        // Within its own section, not across the flattened list — a category sliding out of
        // Gameplay and into Media because you nudged it past the end would be a surprise.
        guard categorySections[section].items.indices.contains(to) else { return }
        categorySections[section].items.swapAt(from, to)
        save()
    }

    // MARK: Rename presets

    /// Saves on a short delay: the preset editor writes on every keystroke, and each save
    /// rewrites the whole library including every tag.
    /// "Bisons copy", then "Bisons copy 2". Presets are chosen from a menu that shows only
    /// their names, so two with the same name would be indistinguishable where it matters.
    func uniquePresetName(_ desired: String) -> String {
        let taken = Set(presets.map(\.name))
        guard taken.contains(desired) else { return desired }
        var n = 2
        while taken.contains("\(desired) \(n)") { n += 1 }
        return "\(desired) \(n)"
    }

    /// A copy of a preset under its own identity, for building a new client's convention
    /// out of one that already works rather than from the default tokens.
    @discardableResult
    func duplicate(preset source: RenamePreset) -> RenamePreset {
        var copy = source
        copy.id = UUID()
        copy.name = uniquePresetName("\(source.name) copy")
        presets.append(copy)
        saveSoon()
        return copy
    }

    func upsert(preset: RenamePreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        saveSoon()
    }

    private var pendingSave: DispatchWorkItem?

    func saveSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    // MARK: Persistence

    // Every field added after the first release is optional, because Swift's generated
    // decoder throws on a missing key even when the property has a default value.
    //
    // Internal rather than private so the tests can decode a fixture written by an older
    // version without going anywhere near the real library on disk.
    struct Archive: Codable {
        var teams: [Team]
        /// The flat list as written before sections existed. Still read, so an older library
        /// migrates; no longer written, so `categorySections` is the one source once saved.
        var categories: [String]?
        var categorySections: [CategorySection]?
        /// Optional, so a library written before subjects existed still reads. Swift's
        /// generated decoder throws on a missing key even where a default is declared, which
        /// is why every field added since the first version is written this way. Declared
        /// here, beside `categories`, because the memberwise initialiser takes its arguments
        /// in declaration order and `save()` passes them in this one.
        var subjects: [String]?
        /// Same reason as `subjects`: optional so an older library still reads.
        var recentCategories: [String]?
        var tags: [Tag]
        var presets: [RenamePreset]?
        /// Superseded by `flagOverrides`, and still written beside it so 0.9.4 and earlier
        /// open the file: they read a KEEP you set as true, anything else as false.
        var keepOverrides: [String: Bool]?
        /// The flag you set, by UMID: KEEP, OK, NG, or "" for one you cleared.
        var flagOverrides: [String: String]?
    }

    /// The overrides as `load()` reads them. A library from before OK and NG has only the
    /// yes/no ones, which were KEEP and cleared.
    static func flagOverrides(from archive: Archive) -> [String: FlagMark] {
        if let stored = archive.flagOverrides {
            // An unknown word is dropped rather than guessed at — a later version's flag
            // read as "cleared" would be written onto a copy as exactly that.
            return stored.compactMapValues { raw in
                raw.isEmpty ? FlagMark(flag: nil) : ClipFlag(rawValue: raw).map { FlagMark(flag: $0) }
            }
        }
        return (archive.keepOverrides ?? [:]).mapValues { FlagMark(flag: $0 ? .keep : nil) }
    }

    /// The whole of reading a library, with the file-handling taken out. `load()` is this
    /// plus a `Data(contentsOf:)`, which is what makes the format testable: the test can
    /// hand it the bytes an old version would have written.
    static func decodeArchive(_ data: Data) throws -> Archive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Archive.self, from: data)
    }

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("Keeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library.json")

        // Tagging grew up as a separate "Keeper Tagger" app with its own folder. Bring that
        // library across once, copying rather than moving so the original stays as a backup.
        if !FileManager.default.fileExists(atPath: url.path) {
            let legacy = base.appendingPathComponent("KeeperTag/library.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.copyItem(at: legacy, to: url)
            }
        }
        return url
    }

    /// Set when the file on disk existed but couldn't be read. The app then refuses to save
    /// over it, because an empty library quietly replacing a season of tagging is the worst
    /// thing this code could do.
    @Published private(set) var loadFailure: String?

    func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }

        let archive: Archive
        do {
            archive = try Self.decodeArchive(data)
        } catch {
            // Keep a copy of whatever was there, and stop writing until it's dealt with.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = Self.storeURL
                .deletingLastPathComponent()
                .appendingPathComponent("library-unreadable-\(stamp).json")
            try? data.write(to: backup)
            loadFailure = "The tag library couldn't be read. A copy was kept at "
                + "\(backup.lastPathComponent) and nothing will be saved over it. (\(error))"
            print(loadFailure ?? "")
            return
        }
        teams = archive.teams
        // Sections if the library has them, otherwise whatever flat list it had, moved
        // into one section. A library with neither gets the starting set.
        if let sections = archive.categorySections, !sections.isEmpty {
            categorySections = sections
        } else {
            categorySections = CategorySection.migrating(archive.categories ?? [])
        }
        // A library from before subjects existed has none, and should get the
        // starting set rather than an empty bench tail. One deliberately emptied
        // stays empty, which is why nil and [] are told apart.
        subjects = archive.subjects ?? Subjects.defaults
        recentCategories = archive.recentCategories ?? []
        tags = archive.tags
        presets = archive.presets ?? [.standard()]
        flagOverrides = Self.flagOverrides(from: archive)
        rebuildIndex()
        clearHistory()
    }

    func save() {
        guard loadFailure == nil else { return }   // never overwrite a library we couldn't read
        backUpIfDue()
        let archive = Archive(teams: teams,
                              // Written as well as the sections, not instead: a library
                              // saved here still opens in a build from before sections
                              // existed, which would otherwise fail to decode and refuse
                              // to load at all.
                              categories: categories,
                              categorySections: categorySections,
                              subjects: subjects,
                              recentCategories: recentCategories,
                              tags: tags,
                              presets: presets,
                              keepOverrides: flagOverrides.mapValues { $0.flag == .keep },
                              flagOverrides: flagOverrides.mapValues { $0.flag?.rawValue ?? "" })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return }
        // Write beside the real file then swap, so a crash mid-write can't shred the library.
        let temp = Self.storeURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(Self.storeURL, withItemAt: temp)
        } catch {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    // MARK: Backups

    /// A past version of the library, as the Restore menu lists it.
    struct Backup: Identifiable, Hashable {
        let url: URL
        let date: Date
        let size: Int64
        var id: URL { url }
    }

    static var backupFolder: URL {
        let folder = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let backupsKept = 10
    /// Long enough that a tagging session doesn't push the morning's work out of the ten
    /// slots, short enough that the newest copy is never far behind.
    private static let backupInterval: TimeInterval = 10 * 60

    private var lastBackup: Date?

    private static let stampFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Copies the file as it currently stands into `Backups/` before it's written over.
    ///
    /// Called from `save()`, which runs on every tag, so it's throttled — otherwise ten
    /// backups would all be from the same minute and the day's earlier work would be gone.
    /// The first save of a session always takes one, which is the version most worth having.
    private func backUpIfDue() {
        let fm = FileManager.default
        let source = Self.storeURL
        guard fm.fileExists(atPath: source.path) else { return }   // nothing to copy yet

        if let lastBackup, Date().timeIntervalSince(lastBackup) < Self.backupInterval { return }

        let target = Self.backupFolder
            .appendingPathComponent("library-\(Self.stampFormat.string(from: Date())).json")
        guard !fm.fileExists(atPath: target.path) else { return }

        do {
            try fm.copyItem(at: source, to: target)
            lastBackup = Date()
            pruneBackups()
            // Posted on the next turn of the loop rather than inline: `save()` can be
            // reached from a button's action, and the handler publishes a change to
            // `AppState`. Keeping the two apart means that can never land inside a
            // SwiftUI update.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .keeperLibraryBackedUp, object: nil)
            }
        } catch {
            // A backup that can't be written must never stop the save it was protecting.
            print("Keeper: couldn't write a library backup — \(error)")
        }
    }

    private func pruneBackups() {
        let all = backups()
        guard all.count > Self.backupsKept else { return }
        for old in all.dropFirst(Self.backupsKept) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    /// Newest first, which is the order the menu wants them in.
    func backups() -> [Backup] {
        let fm = FileManager.default
        guard let found = try? fm.contentsOfDirectory(at: Self.backupFolder,
                                                      includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles])
        else { return [] }

        return found.compactMap { url -> Backup? in
            guard url.pathExtension.lowercased() == "json",
                  let date = Self.date(fromBackupName: url.lastPathComponent)
            else { return nil }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return Backup(url: url, date: date, size: size)
        }
        .sorted { $0.date > $1.date }
    }

    /// The name carries the time, rather than reading the file's own dates: `copyItem` keeps
    /// the source's modification date, so the file would claim to be older than it is.
    private static func date(fromBackupName name: String) -> Date? {
        guard name.hasPrefix("library-"), name.hasSuffix(".json") else { return nil }
        let stamp = name.dropFirst("library-".count).dropLast(".json".count)
        return stampFormat.date(from: String(stamp))
    }

    enum RestoreError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That backup couldn't be read, so nothing was changed."
            }
        }
    }

    /// Puts a past version back, after backing up the current one — so restoring the wrong
    /// copy is itself undoable. Nothing is touched unless the file decodes cleanly.
    @discardableResult
    func restore(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let archive = try? Self.decodeArchive(data)
        else { throw RestoreError.unreadable }

        lastBackup = nil            // this one matters more than the schedule
        backUpIfDue()

        teams = archive.teams
        // Sections if the library has them, otherwise whatever flat list it had, moved
        // into one section. A library with neither gets the starting set.
        if let sections = archive.categorySections, !sections.isEmpty {
            categorySections = sections
        } else {
            categorySections = CategorySection.migrating(archive.categories ?? [])
        }
        // A library from before subjects existed has none, and should get the
        // starting set rather than an empty bench tail. One deliberately emptied
        // stays empty, which is why nil and [] are told apart.
        subjects = archive.subjects ?? Subjects.defaults
        recentCategories = archive.recentCategories ?? []
        tags = archive.tags
        presets = archive.presets ?? [.standard()]
        flagOverrides = Self.flagOverrides(from: archive)
        rebuildIndex()
        // Those edits describe the library this one just replaced, so they'd put back
        // fragments of a version nobody asked for. The restore itself is reversible by
        // restoring the backup it took on the way in.
        clearHistory()
        // A readable library is now in memory, so saving is safe again even if the file on
        // disk was the unreadable one that set this.
        loadFailure = nil
        save()

        return "Restored \(teams.count) team(s), \(tags.count) tag(s) "
             + "and \(presets.count) preset(s) from \(url.lastPathComponent)."
    }

    private func rebuildIndex() {
        index = Dictionary(grouping: tags, by: \.umid)
    }

    // MARK: Roster import

    enum ImportError: LocalizedError {
        case unreadable
        case noRows
        case duplicateNumbers(team: String, numbers: [String])

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read as text."
            case .noRows:     return "No players were found in that file."
            case .duplicateNumbers(let team, let numbers):
                let blanks = numbers.contains("")
                let real = numbers.filter { !$0.isEmpty }.sorted()
                var parts: [String] = []
                if !real.isEmpty {
                    parts.append("\(real.count == 1 ? "number" : "numbers") "
                                 + real.joined(separator: ", "))
                }
                if blanks { parts.append("a blank number") }
                return "\(team) has two players sharing \(parts.joined(separator: ", and more sharing ")). "
                     + "Keeper tells players apart by their number, so each has to be unique "
                     + "within the team — a blank one included. Fix the file and import again."
            }
        }
    }

    /// Accepts `team,number,name[,position]`, with or without a header row. When there's no
    /// team column the file's own name becomes the team.
    @discardableResult
    func importRoster(from url: URL) throws -> (team: String, players: Int, tagsUpdated: Int) {
        guard let text = CSV.readText(url) else { throw ImportError.unreadable }
        return try importRoster(csv: text,
                                fallbackTeam: url.deletingPathExtension().lastPathComponent)
    }

    /// Reads and replaces in one go, with nothing asked. What the checks and any caller that
    /// doesn't review changes use; the app's own import paths go through `parseRoster`,
    /// `conflicts(in:)` and `applyImport` so a team you already have isn't overwritten unseen.
    @discardableResult
    func importRoster(csv text: String,
                      fallbackTeam: String) throws -> (team: String, players: Int, tagsUpdated: Int) {
        let incoming = try Self.parseRoster(csv: text, fallbackTeam: fallbackTeam)
        let result = applyImport(incoming)
        return (result.team, result.players, result.tagsUpdated)
    }

    /// One team as a file or a download describes it, before it touches the library.
    struct IncomingTeam {
        /// The slug of the name, which the players are stamped with until the import decides
        /// which real team id they belong to.
        let slug: String
        let name: String
        let code: String?
        let league: String?
        let players: [Player]
    }

    /// The order a roster is kept in: by number, numberless last, then by name.
    static func rosterOrder(_ a: Player, _ b: Player) -> Bool {
        (Int(a.number) ?? Int.max, a.name) < (Int(b.number) ?? Int.max, b.name)
    }

    /// The reading half of an import, with the file-reading taken out — the same split
    /// `load()` has.
    ///
    /// A roster fetched over the network comes in as CSV text and goes through this, so it
    /// gets the identical column handling and duplicate-number refusal. Two import paths that
    /// validated differently would be two sets of bugs.
    static func parseRoster(csv text: String, fallbackTeam: String) throws -> [IncomingTeam] {
        var rows = CSV.parse(text).filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { throw ImportError.noRows }

        var columns: [String: Int] = [:]

        // Header row?
        let first = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let knownHeaders = ["team", "code", "teamcode", "number", "no", "#",
                            "name", "player", "position", "pos",
                            "league", "org", "organisation", "organization", "group"]
        if first.contains(where: { knownHeaders.contains($0) }) {
            for (i, heading) in first.enumerated() {
                switch heading {
                case "team":                   columns["team"] = i
                case "code", "teamcode":       columns["code"] = i
                case "number", "no", "#":      columns["number"] = i
                case "name", "player":         columns["name"] = i
                case "position", "pos":        columns["position"] = i
                case "league", "org", "organisation", "organization", "group":
                    columns["league"] = i
                default: break
                }
            }
            rows.removeFirst()
        } else {
            // Positional: team, number, name — or just number, name.
            if rows[0].count >= 3 {
                columns = ["team": 0, "number": 1, "name": 2]
            } else {
                columns = ["number": 0, "name": 1]
            }
        }

        func field(_ row: [String], _ key: String) -> String {
            guard let i = columns[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        var grouped: [String: [Player]] = [:]
        var teamNames: [String: String] = [:]
        var teamCodes: [String: String] = [:]
        var teamLeagues: [String: String] = [:]

        for row in rows {
            let name = field(row, "name")
            let number = field(row, "number")
            guard !name.isEmpty || !number.isEmpty else { continue }
            let teamName = field(row, "team").isEmpty ? fallbackTeam : field(row, "team")
            let id = Team.slug(teamName)
            teamNames[id] = teamName
            let code = field(row, "code")
            if !code.isEmpty { teamCodes[id] = code }
            let league = field(row, "league")
            if !league.isEmpty { teamLeagues[id] = league }
            grouped[id, default: []].append(
                Player(teamID: id, number: number, name: name, position: field(row, "position"))
            )
        }

        guard !grouped.isEmpty else { throw ImportError.noRows }

        // The same rule the roster editor enforces, which the import used to skip. A player's
        // id is team-and-number, so two players sharing one share an id — and a duplicate id
        // in a SwiftUI list is the thing that misbehaves rather than merely looking wrong.
        // Refused whole rather than half-imported: a team missing the player who lost the
        // clash would be worse than one that didn't arrive.
        for (id, players) in grouped {
            var counts: [String: Int] = [:]
            for player in players { counts[player.number, default: 0] += 1 }
            let clashes = counts.filter { $0.value > 1 }.map(\.key)
            if !clashes.isEmpty {
                throw ImportError.duplicateNumbers(team: teamNames[id] ?? id, numbers: clashes)
            }
        }

        return grouped.map { id, players in
            IncomingTeam(slug: id,
                         name: teamNames[id] ?? id,
                         code: teamCodes[id],
                         league: teamLeagues[id],
                         players: players.sorted(by: rosterOrder))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Re-importing a team you already have

    /// What a new list would do to a roster, matched on number — a player's identity.
    struct RosterChanges: Equatable {
        struct Change: Equatable {
            let old: Player
            let new: Player
        }
        var added: [Player] = []
        var removed: [Player] = []
        var changed: [Change] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        /// "3 new · 2 gone · 1 changed", leaving out what's zero.
        var summary: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("\(added.count) new") }
            if !removed.isEmpty { parts.append("\(removed.count) gone") }
            if !changed.isEmpty { parts.append("\(changed.count) changed") }
            return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
        }
    }

    /// A position left blank in the new list isn't a change: a CSV without a position column
    /// says nothing about positions, the same way a missing code column keeps the code.
    static func rosterChanges(old: [Player], new: [Player]) -> RosterChanges {
        var changes = RosterChanges()
        let oldByNumber = Dictionary(old.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let newNumbers = Set(new.map(\.number))
        for player in new {
            guard let was = oldByNumber[player.number] else {
                changes.added.append(player)
                continue
            }
            let renamed = was.name != player.name
            let moved = !player.position.isEmpty && was.position != player.position
            if renamed || moved { changes.changed.append(.init(old: was, new: player)) }
        }
        changes.removed = old.filter { !newNumbers.contains($0.number) }
        return changes
    }

    /// What Merge does: adds the numbers you don't have and leaves everyone you do have
    /// exactly as they are. It never renames or removes, which is the point of it — a name
    /// you corrected by hand survives a download that still spells it the league's way.
    static func merged(existing: [Player], incoming: [Player], teamID: String) -> [Player] {
        let have = Set(existing.map(\.number))
        let additions = incoming
            .filter { !have.contains($0.number) }
            .map { Player(teamID: teamID, number: $0.number, name: $0.name, position: $0.position) }
        return (existing + additions).sorted(by: rosterOrder)
    }

    enum ImportMode: String, CaseIterable, Identifiable {
        case merge = "Merge"
        case replace = "Replace"
        case skip = "Skip"
        var id: String { rawValue }
    }

    /// A team that's already in the library and that the new list would change.
    struct RosterConflict: Identifiable {
        let incoming: IncomingTeam
        let existingName: String
        let changes: RosterChanges
        var id: String { incoming.slug }
    }

    /// The incoming teams that match one you have and differ from it. A team you don't have,
    /// or one that would come in identical, has nothing to ask about.
    func conflicts(in incoming: [IncomingTeam]) -> [RosterConflict] {
        incoming.compactMap { team in
            guard let existing = Self.importTarget(slug: team.slug, name: team.name, in: teams)
            else { return nil }
            let changes = Self.rosterChanges(old: existing.players, new: team.players)
            guard !changes.isEmpty else { return nil }
            return RosterConflict(incoming: team, existingName: existing.name, changes: changes)
        }
    }

    /// The writing half. Each team goes in by its mode — replace unless told otherwise — and
    /// the result names the team ids actually written, which is what the panel should jump
    /// to: a team you made by hand keeps its original id, so the slug can point at nothing.
    @discardableResult
    func applyImport(_ incoming: [IncomingTeam], modes: [String: ImportMode] = [:])
        -> (team: String, players: Int, tagsUpdated: Int, teamIDs: [String]) {
        var players = 0
        var written: [String] = []
        var names: [String] = []

        for team in incoming {
            let mode = modes[team.slug] ?? .replace
            if mode == .skip { continue }

            // Match on the id first, then on the name. A team keeps its id for life, so one
            // created by the + button and renamed still has the id `new-team` — and matching
            // on the id alone would file this import as a *second* team with the same name.
            // Two teams of one name is a state the roster editor then refuses to save, which
            // is a brick wall reached by doing nothing unusual.
            let existing = Self.importTarget(slug: team.slug, name: team.name, in: teams)

            // Keep whichever id already exists, because tags are keyed to it. The players
            // were stamped with the slug while they were being grouped, so they have to be
            // re-stamped to match, or the roster and its tags would belong to different teams.
            let teamID = existing?.id ?? team.slug
            let restamped = team.players.map {
                Player(teamID: teamID, number: $0.number, name: $0.name, position: $0.position)
            }

            switch mode {
            case .replace, .skip:
                // An import replaces the whole team, so a CSV without a code or league column
                // would otherwise silently wipe one you'd already set. Fall back to what's
                // there: re-importing to fix a spelling shouldn't cost you a filename code.
                upsert(team: Team(id: teamID,
                                  name: team.name,
                                  code: team.code ?? existing?.code,
                                  league: team.league ?? existing?.league,
                                  players: restamped))
            case .merge:
                // Yours wins throughout, the name included: Merge only ever adds.
                let base = existing?.players ?? []
                upsert(team: Team(id: teamID,
                                  name: existing?.name ?? team.name,
                                  code: existing?.code ?? team.code,
                                  league: existing?.league ?? team.league,
                                  players: Self.merged(existing: base, incoming: restamped,
                                                       teamID: teamID)))
            }
            players += restamped.count
            written.append(teamID)
            names.append(team.name)
        }

        // Existing tags adopt any corrected names and newly added columns.
        let updated = written.isEmpty ? 0 : refreshTagsFromRoster()
        let label = names.count == 1 ? names[0] : "\(names.count) teams"
        return (label, players, updated, written)
    }
}

// MARK: - Minimal CSV reader

enum CSV {
    static func readText(_ url: URL) -> String? {
        var text: String?
        if let s = try? String(contentsOf: url, encoding: .utf8) { text = s }
        else if let s = try? String(contentsOf: url, encoding: .isoLatin1) { text = s }
        guard var text else { return nil }

        // Excel writes UTF-8 with a byte-order mark, which survives decoding as an invisible
        // first character. It would ride along on the first heading — "\u{FEFF}team" never
        // matches "team" — so that column goes unrecognised with nothing on screen to say why.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// Handles quoted fields, escaped quotes, commas inside quotes, and CRLF.
    static func parse(_ text: String) -> [[String]] {
        // Line endings are normalised before the loop rather than handled inside it, because
        // Swift's Character is a grapheme cluster and CR-LF is a *single* one: iterating
        // Characters over a CRLF file never yields a bare "\n", so a switch looking for one
        // silently appends every line ending into a field and parses the whole file as one
        // row. Excel and Numbers both write CRLF, so that's the common case, not an exotic
        // one. Do not move this logic into the switch below.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = normalised.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }

        func endRow() {
            endField()
            // A blank line in the middle of a file isn't a record. Without this it comes out
            // as a row holding one empty field, which every caller then has to weed out.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"":            inQuotes = true
            case ",", ";", "\t":  endField()
            case "\n":            endRow()       // normalised above, so this is every form
            default:              field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
