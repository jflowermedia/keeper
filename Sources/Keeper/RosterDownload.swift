import SwiftUI

/// One team you can fetch a roster for.
struct LeagueTeam: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

/// A league Keeper can fetch rosters from.
///
/// Every case needs its own endpoints *and* its own parser, because no two leagues publish the
/// same JSON — which is why the switches below are exhaustive and have no default. Adding a
/// league is a new case, and the compiler then points at each place that has to learn about it.
enum RosterSource: String, CaseIterable, Identifiable {
    case nhl

    var id: String { rawValue }

    var name: String {
        switch self {
        case .nhl: return "NHL"
        }
    }

    var teamsURL: URL? {
        switch self {
        case .nhl: return URL(string: "\(RosterFeed.api)/standings/now")
        }
    }

    func rosterURL(for team: LeagueTeam) -> URL? {
        switch self {
        case .nhl: return URL(string: "\(RosterFeed.api)/roster/\(team.code)/current")
        }
    }

    func teams(in data: Data) -> [LeagueTeam] {
        switch self {
        case .nhl: return RosterFeed.teams(in: data)
        }
    }

    func csv(from data: Data, team: LeagueTeam) -> String? {
        switch self {
        case .nhl: return RosterFeed.csv(from: data, team: team, league: name)
        }
    }
}

/// Reading the NHL's public API: the team list, and a roster turned into the CSV Keeper
/// already knows how to import.
///
/// The parsing is pure and lives apart from the fetching, the same split `ReleaseFeed` has,
/// so the checks can run it on bytes without a network.
///
/// **Why CSV in the middle.** It would be shorter to build `Player` values straight from the
/// JSON, but then a downloaded roster and an imported file would go through different code —
/// and the file path is where the duplicate-number refusal, the column handling and the team
/// matching all live. Turning the JSON into CSV and handing it to the importer means there is
/// one set of rules, not two.
enum RosterFeed {

    static let api = "https://api-web.nhle.com/v1"

    // MARK: Decoding
    //
    // The API's field names aren't documented anywhere official. Every field here is optional
    // and every name has alternatives, so a shape that isn't what this expects comes back as
    // "couldn't read it" rather than as a roster full of blanks — and a blank number is the
    // one thing an import refuses outright.

    /// Either `{"default": "Blake"}` or a plain `"Blake"`.
    struct Localized: Decodable, Hashable {
        let value: String?

        init(from decoder: Decoder) throws {
            if let flat = try? decoder.singleValueContainer().decode(String.self) {
                value = flat
                return
            }
            let keyed = try? decoder.container(keyedBy: CodingKeys.self)
            value = try? keyed?.decodeIfPresent(String.self, forKey: .default)
        }

        enum CodingKeys: String, CodingKey { case `default` }
    }

    /// A shirt number arrives as a number, but has been known to arrive as a string.
    struct Number: Decodable, Hashable {
        let value: String?

        init(from decoder: Decoder) throws {
            let single = try? decoder.singleValueContainer()
            if let int = try? single?.decode(Int.self) {
                value = String(int)
            } else if let text = try? single?.decode(String.self) {
                value = text
            } else {
                value = nil
            }
        }
    }

    struct Entry: Decodable {
        var sweaterNumber: Number?
        var firstName: Localized?
        var lastName: Localized?
        var positionCode: String?
    }

    struct Roster: Decodable {
        var forwards: [Entry]?
        var defensemen: [Entry]?
        var goalies: [Entry]?

        var everyone: [Entry] {
            (forwards ?? []) + (defensemen ?? []) + (goalies ?? [])
        }
    }

    struct StandingsRow: Decodable {
        var teamAbbrev: Localized?
        var teamName: Localized?
        var teamCommonName: Localized?
    }

    struct Standings: Decodable {
        var standings: [StandingsRow]?
    }

    // MARK: Reading

    /// The teams playing right now, read from the standings rather than written down — the
    /// league moves and renames franchises, and a list in the source would be one more thing
    /// that quietly goes out of date.
    static func teams(in data: Data) -> [LeagueTeam] {
        guard let decoded = try? JSONDecoder().decode(Standings.self, from: data) else { return [] }
        var out: [LeagueTeam] = []
        var seen: Set<String> = []
        for row in decoded.standings ?? [] {
            guard let code = row.teamAbbrev?.value?.trimmingCharacters(in: .whitespaces),
                  !code.isEmpty, !seen.contains(code)
            else { continue }
            let name = row.teamName?.value ?? row.teamCommonName?.value ?? code
            seen.insert(code)
            out.append(LeagueTeam(code: code, name: name))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func position(_ code: String?) -> String {
        switch (code ?? "").uppercased() {
        case "C", "L", "R": return "Forward"
        case "D":           return "Defence"
        case "G":           return "Goalie"
        default:            return ""
        }
    }

    /// One team's roster as CSV, in the columns the importer reads.
    ///
    /// Returns nil when the response holds no usable players — a changed shape, or a team
    /// with nobody listed. Players with no number are dropped rather than carried through:
    /// an import refuses a blank number, so one unsigned call-up would otherwise cost you the
    /// whole team.
    static func csv(from data: Data, team: LeagueTeam, league: String = "NHL") -> String? {
        guard let roster = try? JSONDecoder().decode(Roster.self, from: data) else { return nil }

        var lines = ["league,team,code,number,name,position"]
        for entry in roster.everyone {
            guard let number = entry.sweaterNumber?.value?.trimmingCharacters(in: .whitespaces),
                  !number.isEmpty
            else { continue }
            let first = entry.firstName?.value ?? ""
            let last = entry.lastName?.value ?? ""
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            lines.append([league, team.name, team.code, number, name,
                          position(entry.positionCode)].map(field).joined(separator: ","))
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    /// Quotes a field if it needs it. Team names don't contain commas today, but a league or
    /// a name that did would silently shift every column after it.
    static func field(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}


/// Picking teams to download. A list with a search box and a tick each — the whole point is
/// that it takes no files, no Terminal and no explaining.
struct RosterDownloadSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var picked: Set<String> = []

    private var shown: [LeagueTeam] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return state.leagueTeams }
        return state.leagueTeams.filter {
            $0.name.lowercased().contains(query) || $0.code.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Download a Roster").font(.headline)
                    Spacer()
                    Picker("League", selection: $state.rosterSource) {
                        ForEach(RosterSource.allCases) { Text($0.name).tag($0) }
                    }
                    .frame(width: 150)
                    .disabled(state.isFetchingRosters)
                }
                Text("Straight from the league, so the numbers are today's. Tick the teams "
                     + "you're shooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            if state.leagueTeams.isEmpty {
                VStack(spacing: 8) {
                    if state.isFetchingRosters {
                        ProgressView()
                        Text("Asking the league who's playing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(state.rosterDownloadNote ?? "No teams yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { state.loadLeagueTeams() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { team in
                            Toggle(isOn: Binding(
                                get: { picked.contains(team.code) },
                                set: { on in
                                    if on { picked.insert(team.code) } else { picked.remove(team.code) }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Text(team.name)
                                    Text(team.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if shown.isEmpty {
                            Text("No team matches \"\(search)\".")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack(spacing: 8) {
                if let note = state.rosterDownloadNote, !state.leagueTeams.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if state.isFetchingRosters && !state.leagueTeams.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(picked.count <= 1 ? "Import" : "Import \(picked.count)") {
                    state.downloadRosters(state.leagueTeams.filter { picked.contains($0.code) })
                    picked.removeAll()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || state.isFetchingRosters)
            }
            .padding(16)
        }
        .frame(width: 440, height: 520)
        .onAppear { state.loadLeagueTeams() }
        // Ticks are team codes, and codes from one league mean nothing in another.
        .onChange(of: state.rosterSource) { _ in
            picked.removeAll()
            search = ""
        }
    }
}
