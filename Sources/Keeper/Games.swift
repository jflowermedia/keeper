import Foundation

// One card, more than one game. The split lives in the library against each clip's UMID, the
// same as tags, so it's there when the card goes back in and nothing is ever written to it.

/// One game on a card. Named from its teams when it's drawn rather than stored, so renaming a
/// team renames its tab.
struct Game: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    /// The rosters in play for this game. Here rather than beside `activeTeamIDs` in
    /// UserDefaults, or a card you come back to would have its tabs but not its benches.
    var teamIDs: [String] = []
}

extension Game {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        teamIDs = try c.decodeIfPresent([String].self, forKey: .teamIDs) ?? []
    }
}

/// The rules for dividing a card, over UMIDs in list order. Pure, so the self-check can run
/// them. `assignment` maps a UMID to a game's id; it can hold other cards' clips, which are
/// left alone because they're never in `order`.
enum GameSplit {
    /// The games on this card, in the order they were shot.
    static func games(order: [String], in assignment: [String: String]) -> [String] {
        var seen = Set<String>()
        return order.compactMap { assignment[$0] }.filter { seen.insert($0).inserted }
    }

    /// A game has to have something before the split, or nothing would be left in it. A clip
    /// in no game on a split card has nothing to leave, so it can always start one.
    static func canSplit(at umid: String, order: [String], in assignment: [String: String]) -> Bool {
        guard let index = order.firstIndex(of: umid) else { return false }
        if assignment[umid] == nil, !games(order: order, in: assignment).isEmpty { return true }
        return order[..<index].contains { assignment[$0] == assignment[umid] }
    }

    /// The clip and everything after it in the same game move to `newGame`. Other games on the
    /// card stay put, so splitting the first of two leaves the second alone. On a card not yet
    /// split, what comes before goes to `firstGame`. On one that is, clips in no game before
    /// this one stay that way: nothing says they're part of anything.
    static func split(at umid: String, order: [String], in assignment: [String: String],
                      firstGame: String, newGame: String) -> [String: String] {
        guard let index = order.firstIndex(of: umid) else { return assignment }
        let from = assignment[umid]
        let unsplit = games(order: order, in: assignment).isEmpty
        var out = assignment
        for (position, clip) in order.enumerated() where assignment[clip] == from {
            if position >= index {
                out[clip] = newGame
            } else if unsplit {
                out[clip] = firstGame
            }
        }
        return out
    }

    /// How far apart two clips can be and still be the same shoot. Hours rather than a calendar
    /// day, so a game running past midnight stays in one piece.
    static let sameShoot: TimeInterval = 12 * 60 * 60

    /// Clips with no game join the one next to them, if they were shot close to it. Not
    /// otherwise: a folder of other shoots holding one split card would have every clip in it
    /// saved into that game, and hockey on a card still holding last week's basketball isn't
    /// more basketball. A clip with no date can't show it belongs, so it stays out too.
    static func fill(order: [String], in assignment: [String: String],
                     shot: [String: Date]) -> [String: String] {
        guard !games(order: order, in: assignment).isEmpty else { return assignment }
        func close(_ a: String, _ b: String) -> Bool {
            guard let first = shot[a], let second = shot[b] else { return false }
            return abs(first.timeIntervalSince(second)) <= sameShoot
        }
        var out = assignment
        func pass(_ clips: [String]) {
            var previous: String?
            for clip in clips {
                if out[clip] == nil, let previous, let game = out[previous], close(clip, previous) {
                    out[clip] = game
                }
                previous = clip
            }
        }
        pass(order)
        pass(order.reversed())
        return out
    }

    /// A game's clips go to the game before it, or after it if it was first. With one game
    /// left the card isn't split any more, so nothing on it needs a game.
    static func removing(_ game: String, order: [String],
                         in assignment: [String: String]) -> [String: String] {
        let all = games(order: order, in: assignment)
        guard let index = all.firstIndex(of: game), all.count > 1 else { return assignment }
        var out = assignment
        if all.count == 2 {
            for clip in order { out[clip] = nil }
            return out
        }
        let heir = index > 0 ? all[index - 1] : all[index + 1]
        for clip in order where out[clip] == game { out[clip] = heir }
        return out
    }

    /// Tab labels made safe to be folders. Two games between the same teams on one card have
    /// the same label, and sharing a folder would mix them back together.
    static func folderNames(_ labels: [String]) -> [String] {
        var used = Set<String>()
        return labels.map { label in
            let clean = Renamer.safe(label)
            var name = clean
            var n = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(clean) \(n)"
                n += 1
            }
            return name
        }
    }
}

extension AppState {
    /// The tab for clips in no game. A real id can't look like this.
    static let noGameTab = "*no-game"

    /// In the order they were shot, whatever the files are called now: Rename in Place changes
    /// the list's order, and a game is a stretch of time. No date goes last.
    private var cardOrder: [String] {
        clips.enumerated()
            .sorted {
                ($0.element.shotDate ?? .distantFuture, $0.offset)
                    < ($1.element.shotDate ?? .distantFuture, $1.offset)
            }
            .compactMap(\.element.umid)
    }

    private var filledGames: [String: String] {
        let dates = clips.compactMap { clip in clip.umid.flatMap { umid in
            clip.shotDate.map { (umid, $0) }
        } }
        return GameSplit.fill(order: cardOrder, in: library.clipGames,
                              shot: Dictionary(dates, uniquingKeysWith: { first, _ in first }))
    }

    var cardGames: [Game] {
        GameSplit.games(order: cardOrder, in: library.clipGames).compactMap { library.game(id: $0) }
    }

    func gameLabel(_ game: Game) -> String {
        let teams = game.teamIDs.compactMap { library.team(id: $0) }
        if let label = Self.rosterLabel(teams) { return label }
        let number = (cardGames.firstIndex(of: game) ?? 0) + 1
        return "Game \(number)"
    }

    func clipCount(in game: Game) -> Int {
        clips.filter { library.gameID(forUMID: $0.umid) == game.id }.count
    }

    /// Clips on a split card that are in no game: no UMID, or shot at another time. A tab of
    /// their own, or exporting each game in turn would leave them behind unseen.
    var looseClipCount: Int { clips.filter { library.gameID(forUMID: $0.umid) == nil }.count }

    /// What the tab bar shows besides All, for the keys as well as the bar.
    private var gameStops: [String?] {
        let games = cardGames
        guard games.count > 1 else { return [nil] }
        return [nil] + games.map(\.id) + (looseClipCount > 0 ? [Self.noGameTab] : [])
    }

    /// The tab's name, for anything saying what the list is limited to. Nil on All.
    var activeGameTitle: String? {
        if activeGameID == Self.noGameTab { return "No Game" }
        return library.game(id: activeGameID).map(gameLabel)
    }

    /// The game whose teams should be on the bench: the tab's, or on All, the clip's.
    var benchGame: Game? {
        if let activeGameID { return library.game(id: activeGameID) }
        guard let last = lastSelected, let clip = clips.first(where: { $0.id == last }) else {
            return nil
        }
        return library.game(id: library.gameID(forUMID: clip.umid))
    }

    private func useBench(of game: Game) {
        // Picked from the other game's bench, so it can't be tagged on this one.
        flowPlayerID = nil
        focusedTeamID = nil
        if game.teamIDs.count > 1 { bothTeams = true }
        setActiveTeams(game.teamIDs)
    }

    /// On All, each clip brings its own game's teams. You land on All whenever a split card
    /// is opened, and a game one clip must not be tagged against game two's roster.
    func followBench() {
        guard activeGameID == nil, let game = benchGame, game.teamIDs != activeTeamIDs else { return }
        useBench(of: game)
    }

    /// Moves to a tab, nil being All. All leaves the benches as they are: it's for looking
    /// across the card, and has no teams of its own to bring.
    func showGame(_ id: String?) {
        guard id != activeGameID, !aSheetIsUp else { return }
        // The copy is working from this list.
        guard !isCopying else {
            status = "A copy is running — switch games once it's finished."
            return
        }
        activeGameID = id
        // One game's team isn't in the next, so its filter would empty the list.
        filterTeamID = nil
        filterPlayerID = nil
        guard let game = library.game(id: id) else {
            if id == Self.noGameTab {
                status = "Clips in no game. Move them to one, or start a new game from them."
            }
            return
        }
        resetFlow()
        useBench(of: game)
        status = game.teamIDs.isEmpty
            ? "\(gameLabel(game)) has no teams yet. Choose them in the tagging panel."
            : "Tagging \(gameLabel(game))."
    }

    /// ⌘1 to ⌘9, by position on the card. ⌘0 is All.
    func showGame(number: Int) {
        let games = cardGames
        guard games.count > 1 else {
            status = Self.oneGameNote
            return
        }
        guard number > 0 else { return showGame(nil) }
        guard games.indices.contains(number - 1) else {
            status = "This card has \(games.count) games, so there's no game \(number)."
            return
        }
        showGame(games[number - 1].id)
    }

    /// ⌘] through All and every game, for the keyboard.
    func nextGame() {
        let stops = gameStops
        guard stops.count > 1 else {
            status = Self.oneGameNote
            return
        }
        let at = stops.firstIndex(of: activeGameID) ?? 0
        showGame(stops[(at + 1) % stops.count])
    }

    private static let oneGameNote =
        "This card is one game. Right-click a clip and choose New Game Starts Here."

    func startGame(at clip: Clip) {
        guard let umid = clip.umid else {
            status = "\(clip.name) has no UMID in its XML, so it can't start a game."
            return
        }
        let order = cardOrder
        let current = filledGames
        guard GameSplit.canSplit(at: umid, order: order, in: current) else {
            status = "\(clip.name) is already the first clip of its game."
            return
        }
        // What's on the bench now is what you've been tagging, so it's the first game's.
        // `activeTeams`, not the ids: with nothing ticked the bench is still a real team.
        let first = Game(teamIDs: activeTeams.map(\.id))
        let new = Game()
        let split = GameSplit.split(at: umid, order: order, in: current,
                                    firstGame: first.id, newGame: new.id)
        library.assignGames(split, adding: [first, new])
        showGame(new.id)
        status = "A new game starts at \(clip.name). Choose its teams in the tagging panel."
    }

    func moveClips(_ targets: [Clip], to game: Game) {
        var assignment = library.clipGames
        let umids = targets.compactMap(\.umid)
        for umid in umids { assignment[umid] = game.id }
        library.assignGames(assignment)
        dropStaleGame()
        let skipped = targets.count - umids.count
        status = "Moved \(umids.count) clip\(umids.count == 1 ? "" : "s") to \(gameLabel(game))."
            + (skipped > 0 ? " \(skipped) with no UMID stayed where they were." : "")
    }

    func removeGame(_ game: Game) {
        let label = gameLabel(game)
        // With two, the game left stops existing too, and its teams would go with it.
        let games = cardGames
        let survivor = games.count == 2 ? games.first { $0.id != game.id } : nil
        let merged = GameSplit.removing(game.id, order: cardOrder, in: library.clipGames)
        library.assignGames(merged)
        dropStaleGame()
        if let survivor, !survivor.teamIDs.isEmpty { useBench(of: survivor) }
        status = cardGames.count > 1
            ? "Removed \(label). Its clips joined the game beside it. Tags aren't affected."
            : "This card is one game again. Tags aren't affected."
    }

    /// After a scan. Anything new on a split card goes in a game, and says so, because it
    /// would otherwise only be findable under All.
    func adoptNewClips() -> Int {
        let filled = filledGames
        let added = filled.count - library.clipGames.count
        if added > 0 { library.assignGames(filled) }
        dropStaleGame()
        return added
    }

    /// A tab whose last clip has gone, or that belongs to another card. Or the only tab left:
    /// the bar is hidden with one game, and nothing else could get you back to All.
    func dropStaleGame() {
        guard let activeGameID else { return }
        if !gameStops.contains(activeGameID) { self.activeGameID = nil }
    }

    /// Each game's folder by id, for a copy that's using them. Clips in no game get one too,
    /// rather than sitting loose beside the games.
    var gameFolders: [String: String] {
        let games = cardGames
        let names = GameSplit.folderNames(games.map(gameLabel) + ["No Game"])
        return Dictionary(uniqueKeysWithValues: zip(games.map(\.id) + [Self.noGameTab], names))
    }

    /// Only from All, and only a copy: a game's own tab has nothing to divide.
    var exportsByGame: Bool {
        folderPerGame && exportDestination == .copy && activeGameID == nil && cardGames.count > 1
    }
}
