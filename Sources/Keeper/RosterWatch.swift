import SwiftUI

/// Asks the league, once a day, whether the rosters in play have changed, and marks the team
/// if one has. It never changes a roster: the mark opens the same review a download does.
///
/// Only the teams in play. Every team downloaded would be dozens of requests a day for
/// rosters nobody's shooting, and in season most of them would be marked most of the time.
@MainActor
final class RosterWatch: ObservableObject {
    static let shared = RosterWatch()

    /// The league's new list, by team id, for teams that have one worth looking at.
    @Published private(set) var updates: [String: TagLibrary.IncomingTeam] = [:]

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "rosterWatchEnabled")
            if !enabled { updates = [:] }
        }
    }

    /// The list as you last saw it, by team id. What a new one is compared with: comparing
    /// with the roster alone would never go quiet, because Merge keeps players the league has
    /// dropped and you keep spellings it hasn't.
    private var seen: [String: String] {
        didSet { UserDefaults.standard.set(seen, forKey: "rosterWatchSeen") }
    }
    private var checked: [String: Date] {
        didSet { UserDefaults.standard.set(checked, forKey: "rosterWatchChecked") }
    }
    /// Marked when Keeper last quit. The list itself isn't kept, so these are asked again at
    /// launch, or a mark would vanish until tomorrow.
    private var marked: Set<String> {
        didSet { UserDefaults.standard.set(marked.sorted(), forKey: "rosterWatchMarked") }
    }
    private var attempted: [String: Date] = [:]
    private var leagueTeams: [RosterSource: (date: Date, teams: [LeagueTeam])] = [:]
    private var checking = false
    /// Teams brought into play during a check, asked about after it.
    private var waiting: [String]?

    private init() {
        let defaults = UserDefaults.standard
        // On unless it's been turned off, so the absence of the key is what's tested.
        enabled = defaults.object(forKey: "rosterWatchEnabled") == nil
            || defaults.bool(forKey: "rosterWatchEnabled")
        seen = defaults.dictionary(forKey: "rosterWatchSeen") as? [String: String] ?? [:]
        checked = defaults.dictionary(forKey: "rosterWatchChecked") as? [String: Date] ?? [:]
        marked = Set(defaults.stringArray(forKey: "rosterWatchMarked") ?? [])
    }

    // MARK: Asking

    func check(_ teamIDs: [String]) {
        guard enabled else { return }
        guard !checking else { waiting = teamIDs; return }
        let now = Date()
        let due = teamIDs.compactMap { TagLibrary.shared.team(id: $0) }.filter { team in
            RosterWatchRule.source(for: team) != nil
                && RosterWatchRule.isDue(checked: checked[team.id], attempted: attempted[team.id],
                                         lostMark: marked.contains(team.id) && updates[team.id] == nil,
                                         now: now)
        }
        guard !due.isEmpty else { return }
        checking = true
        Task {
            for team in due { await ask(team) }
            checking = false
            if let next = waiting {
                waiting = nil
                check(next)
            }
        }
    }

    /// Silent when it fails. A rink with no signal is the normal case.
    private func ask(_ team: Team) async {
        guard let source = RosterWatchRule.source(for: team) else { return }
        attempted[team.id] = Date()
        guard let listed = try? await teams(of: source) else { return }
        guard let match = RosterWatchRule.match(team, in: listed, library: TagLibrary.shared.teams)
        else {
            // A team of your own filed under a league's name. Not worth asking about again
            // today.
            checked[team.id] = Date()
            return
        }
        guard let rows = try? await source.fetchRows(match),
              let incoming = try? source.incoming(rows, team: match).first
        else { return }
        checked[team.id] = Date()
        // Read again: the roster may have been edited, or the switch turned off, meanwhile.
        guard enabled, let current = TagLibrary.shared.team(id: team.id) else { return }
        if RosterWatchRule.isNews(incoming, for: current, seen: seen[team.id]) {
            updates[team.id] = incoming
            marked.insert(team.id)
        } else {
            settle(team.id, as: incoming)
        }
    }

    private func teams(of source: RosterSource) async throws -> [LeagueTeam] {
        if let kept = leagueTeams[source], RosterWatchRule.isFresh(kept.date, now: Date()) {
            return kept.teams
        }
        let teams = try await source.fetchTeams()
        // An empty list is a feed having a bad day, not a league with nobody in it.
        guard !teams.isEmpty else { throw URLError(.cannotParseResponse) }
        leagueTeams[source] = (Date(), teams)
        return teams
    }

    // MARK: Settling

    /// You've been shown these lists, or they've been written as they are.
    func markSeen(_ incoming: [TagLibrary.IncomingTeam]) {
        for team in incoming {
            guard let existing = TagLibrary.importTarget(slug: team.slug, name: team.name,
                                                         in: TagLibrary.shared.teams)
            else { continue }
            settle(existing.id, as: team)
        }
    }

    private func settle(_ id: String, as incoming: TagLibrary.IncomingTeam) {
        let print = RosterWatchRule.fingerprint(incoming)
        if seen[id] != print { seen[id] = print }
        clear(id)
    }

    private func clear(_ id: String) {
        if updates[id] != nil { updates[id] = nil }
        if marked.contains(id) { marked.remove(id) }
    }

    /// Drops marks a roster edit has answered, and ones on teams that have gone.
    func prune() {
        for (id, incoming) in updates {
            guard let team = TagLibrary.shared.team(id: id) else { clear(id); continue }
            if !RosterWatchRule.differs(incoming, from: team) { settle(id, as: incoming) }
        }
    }
}

/// What counts as a change worth a mark. Pure, so the checks can run it without a network.
enum RosterWatchRule {

    static let interval: TimeInterval = 24 * 60 * 60
    /// After a failure. Moving between games shouldn't ask a dead network every time.
    static let retry: TimeInterval = 60 * 60

    static func isFresh(_ date: Date, now: Date) -> Bool {
        // Negative means the clock has been set back since. Treated as stale, or one bad
        // reading would stop the checks for good.
        let since = now.timeIntervalSince(date)
        return since >= 0 && since < interval
    }

    static func isDue(checked: Date?, attempted: Date?, lostMark: Bool, now: Date) -> Bool {
        if let attempted {
            let since = now.timeIntervalSince(attempted)
            if since >= 0, since < retry { return false }
        }
        guard let checked, !lostMark else { return true }
        return !isFresh(checked, now: now)
    }

    /// The league a team is filed under, if it's one Keeper can ask.
    static func source(for team: Team) -> RosterSource? {
        let league = (team.league ?? "").trimmingCharacters(in: .whitespaces)
        return RosterSource.allCases.first { $0.name.caseInsensitiveCompare(league) == .orderedSame }
    }

    /// The importer's own matching, so the mark can't open a review that files the list as a
    /// second team.
    static func match(_ team: Team, in listed: [LeagueTeam], library: [Team]) -> LeagueTeam? {
        listed.first {
            TagLibrary.importTarget(slug: Team.slug($0.name), name: $0.name, in: library)?.id == team.id
        }
    }

    /// Who's on the league's list. As it listed them, not as `keepingYours` leaves them: a
    /// list you'd reviewed would read as a different one, and the mark would be back tomorrow.
    /// Not positions: a league moving a winger to centre isn't news.
    static func fingerprint(_ team: TagLibrary.IncomingTeam) -> String {
        Set((team.asListed ?? team.players + team.leftOut).map { "\($0.number)|\($0.name.lowercased())" })
            .sorted().joined(separator: "\n")
    }

    static func differs(_ incoming: TagLibrary.IncomingTeam, from team: Team) -> Bool {
        let theirs = TagLibrary.keepingYours(incoming, existing: team).players
        let changes = TagLibrary.rosterChanges(old: team.players, new: theirs)
        return !changes.added.isEmpty || !changes.removed.isEmpty
            || changes.changed.contains { !$0.old.isNamed($0.new.name) }
    }

    static func isNews(_ incoming: TagLibrary.IncomingTeam, for team: Team, seen: String?) -> Bool {
        fingerprint(incoming) != seen && differs(incoming, from: team)
    }
}
