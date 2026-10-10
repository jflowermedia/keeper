import Foundation

// MARK: - Model

struct Player: Codable, Identifiable, Hashable {
    var teamID: String
    var number: String
    var name: String
    var position: String = ""

    var id: String { "\(teamID)/\(number)" }
    var label: String { number.isEmpty ? name : "#\(number)  \(name)" }
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

// MARK: - Library

/// Deliberately not actor-isolated: every call comes from the UI on the main thread,
/// and a plain class keeps it simple to observe from SwiftUI views.
final class TagLibrary: ObservableObject {
    static let shared = TagLibrary()

    @Published var teams: [Team] = []
    /// Order matters: it is also the tag priority used when naming a clip that has several.
    @Published var categories: [String] = TagLibrary.defaultCategories
    @Published private(set) var tags: [Tag] = []
    @Published var presets: [RenamePreset] = [.standard()]

    /// Clips you've marked or unmarked yourself, by UMID. The card is never touched: the
    /// override is applied to the sidecar at the destination when the clip is copied out.
    @Published private(set) var keepOverrides: [String: Bool] = [:]

    private init() { load() }

    // MARK: Keep overrides

    func keepOverride(for umid: String?) -> Bool? {
        guard let umid else { return nil }
        return keepOverrides[umid]
    }

    /// Setting it back to the camera's own flag clears the override rather than storing it,
    /// so "changed" only ever means genuinely different from the card.
    func setKeep(_ keep: Bool, umid: String, cameraFlag: Bool) {
        if keep == cameraFlag {
            keepOverrides[umid] = nil
        } else {
            keepOverrides[umid] = keep
        }
        save()
    }

    /// Bulk version: one write of the library rather than one per clip. Marking a hundred
    /// clips individually rewrote every tag a hundred times.
    func setKeep(_ keep: Bool, for clips: [(umid: String, cameraFlag: Bool)]) {
        guard !clips.isEmpty else { return }
        for clip in clips {
            if keep == clip.cameraFlag {
                keepOverrides[clip.umid] = nil
            } else {
                keepOverrides[clip.umid] = keep
            }
        }
        save()
    }

    func clearKeepOverride(umid: String) {
        guard keepOverrides[umid] != nil else { return }
        keepOverrides[umid] = nil
        save()
    }

    @discardableResult
    func clearKeepOverrides(umids: [String]) -> Int {
        let hits = umids.filter { keepOverrides[$0] != nil }
        guard !hits.isEmpty else { return 0 }
        for umid in hits { keepOverrides[umid] = nil }
        save()
        return hits.count
    }

    func clearAllKeepOverrides() {
        guard !keepOverrides.isEmpty else { return }
        keepOverrides = [:]
        save()
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

    /// Positions in use across every roster, for the filter menu.
    var allPositions: [String] {
        Array(Set(allPlayers.map(\.position).filter { !$0.isEmpty })).sorted()
    }

    // MARK: Editing

    /// Returns false when this clip already carries that exact tag. Clicking a category
    /// twice in quick succession is easy, and two identical tags would double-count the
    /// clip on export and clutter the list.
    @discardableResult
    func add(_ tag: Tag) -> Bool {
        let alreadyThere = (index[tag.umid] ?? []).contains {
            $0.category == tag.category && $0.playerID == tag.playerID
        }
        guard !alreadyThere else { return false }

        tags.append(tag)
        index[tag.umid, default: []].append(tag)
        save()
        return true
    }

    func remove(_ tag: Tag) {
        tags.removeAll { $0.id == tag.id }
        index[tag.umid]?.removeAll { $0.id == tag.id }
        if index[tag.umid]?.isEmpty == true { index[tag.umid] = nil }
        save()
    }

    func removeAllTags(forUMID umid: String) {
        tags.removeAll { $0.umid == umid }
        index[umid] = nil
        save()
    }

    /// Clears several clips in one pass, so a bulk delete writes the library once.
    @discardableResult
    func removeAllTags(forUMIDs umids: [String]) -> Int {
        let targets = Set(umids)
        guard !targets.isEmpty else { return 0 }
        let before = tags.count
        tags.removeAll { targets.contains($0.umid) }
        for umid in targets { index[umid] = nil }
        let removed = before - tags.count
        if removed > 0 { save() }
        return removed
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

    func addCategory(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !categories.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
        else { return }
        categories.append(clean)
        save()
    }

    func removeCategory(_ name: String) {
        categories.removeAll { $0 == name }
        save()
    }

    /// Reordering categories changes which tag wins in a filename, so it is a real setting
    /// rather than cosmetics.
    func moveCategory(_ name: String, by offset: Int) {
        guard let from = categories.firstIndex(of: name) else { return }
        let to = from + offset
        guard categories.indices.contains(to) else { return }
        categories.swapAt(from, to)
        save()
    }

    // MARK: Rename presets

    /// Saves on a short delay: the preset editor writes on every keystroke, and each save
    /// rewrites the whole library including every tag.
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
    private struct Archive: Codable {
        var teams: [Team]
        var categories: [String]
        var tags: [Tag]
        var presets: [RenamePreset]?
        var keepOverrides: [String: Bool]?
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let archive: Archive
        do {
            archive = try decoder.decode(Archive.self, from: data)
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
        categories = archive.categories.isEmpty ? Self.defaultCategories : archive.categories
        tags = archive.tags
        presets = archive.presets ?? [.standard()]
        keepOverrides = archive.keepOverrides ?? [:]
        rebuildIndex()
    }

    func save() {
        guard loadFailure == nil else { return }   // never overwrite a library we couldn't read
        let archive = Archive(teams: teams,
                              categories: categories,
                              tags: tags,
                              presets: presets,
                              keepOverrides: keepOverrides)
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

    private func rebuildIndex() {
        index = Dictionary(grouping: tags, by: \.umid)
    }

    // MARK: Roster import

    enum ImportError: LocalizedError {
        case unreadable
        case noRows

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read as text."
            case .noRows:     return "No players were found in that file."
            }
        }
    }

    /// Accepts `team,number,name[,position]`, with or without a header row. When there's no
    /// team column the file's own name becomes the team.
    @discardableResult
    func importRoster(from url: URL) throws -> (team: String, players: Int, tagsUpdated: Int) {
        guard let text = CSV.readText(url) else { throw ImportError.unreadable }
        var rows = CSV.parse(text).filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { throw ImportError.noRows }

        let fallbackTeam = url.deletingPathExtension().lastPathComponent
        var columns: [String: Int] = [:]

        // Header row?
        let first = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let knownHeaders = ["team", "code", "teamcode", "number", "no", "#",
                            "name", "player", "position", "pos"]
        if first.contains(where: { knownHeaders.contains($0) }) {
            for (i, heading) in first.enumerated() {
                switch heading {
                case "team":                   columns["team"] = i
                case "code", "teamcode":       columns["code"] = i
                case "number", "no", "#":      columns["number"] = i
                case "name", "player":         columns["name"] = i
                case "position", "pos":        columns["position"] = i
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

        for row in rows {
            let name = field(row, "name")
            let number = field(row, "number")
            guard !name.isEmpty || !number.isEmpty else { continue }
            let teamName = field(row, "team").isEmpty ? fallbackTeam : field(row, "team")
            let id = Team.slug(teamName)
            teamNames[id] = teamName
            let code = field(row, "code")
            if !code.isEmpty { teamCodes[id] = code }
            grouped[id, default: []].append(
                Player(teamID: id, number: number, name: name, position: field(row, "position"))
            )
        }

        guard !grouped.isEmpty else { throw ImportError.noRows }

        var imported = 0
        for (id, players) in grouped {
            let sorted = players.sorted {
                (Int($0.number) ?? Int.max, $0.name) < (Int($1.number) ?? Int.max, $1.name)
            }
            upsert(team: Team(id: id,
                              name: teamNames[id] ?? id,
                              code: teamCodes[id],
                              players: sorted))
            imported += sorted.count
        }

        // Existing tags adopt any corrected names and newly added columns.
        let updated = refreshTagsFromRoster()

        let label = grouped.count == 1
            ? (teamNames.first?.value ?? fallbackTeam)
            : "\(grouped.count) teams"
        return (label, imported, updated)
    }
}

// MARK: - Minimal CSV reader

enum CSV {
    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        return nil
    }

    /// Handles quoted fields, escaped quotes, commas inside quotes, and CRLF.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

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
            case "\n":            endRow()
            case "\r":            break          // CRLF: the \n does the work
            default:              field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
