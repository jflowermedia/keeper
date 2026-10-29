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

    func rows(from data: Data) -> [RosterFeed.Row]? {
        switch self {
        case .nhl: return RosterFeed.rows(from: data)
        }
    }

    func csv(from data: Data, team: LeagueTeam) -> String? {
        rows(from: data).map { RosterFeed.csv(rows: $0, team: team, league: name) }
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

    /// One player as the preview shows them and the import receives them.
    struct Row: Hashable {
        let number: String
        let name: String
        let position: String
    }

    /// The players in an NHL roster response, in the league's order.
    ///
    /// Returns nil when the response holds no usable players — a changed shape, or a team
    /// with nobody listed. Players with no number are dropped rather than carried through:
    /// an import refuses a blank number, so one unsigned call-up would otherwise cost you the
    /// whole team. The preview reads this too, so what it lists is exactly what imports.
    static func rows(from data: Data) -> [Row]? {
        guard let roster = try? JSONDecoder().decode(Roster.self, from: data) else { return nil }
        var out: [Row] = []
        for entry in roster.everyone {
            guard let number = entry.sweaterNumber?.value?.trimmingCharacters(in: .whitespaces),
                  !number.isEmpty
            else { continue }
            let first = entry.firstName?.value ?? ""
            let last = entry.lastName?.value ?? ""
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            out.append(Row(number: number, name: name, position: position(entry.positionCode)))
        }
        return out.isEmpty ? nil : out
    }

    /// Rows as CSV, in the columns the importer reads.
    static func csv(rows: [Row], team: LeagueTeam, league: String) -> String {
        var lines = ["league,team,code,number,name,position"]
        for row in rows {
            lines.append([league, team.name, team.code, row.number, row.name, row.position]
                .map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func csv(from data: Data, team: LeagueTeam, league: String = "NHL") -> String? {
        rows(from: data).map { csv(rows: $0, team: team, league: league) }
    }

    /// Numbers more than one player wears. The importer refuses such a team outright, so the
    /// preview says so before you try — the same rule, asked early rather than re-stated.
    static func sharedNumbers(_ rows: [Row]) -> [String] {
        var count: [String: Int] = [:]
        for row in rows { count[row.number, default: 0] += 1 }
        return count.filter { $0.value > 1 }.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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

    private var allShownPicked: Bool {
        !shown.isEmpty && shown.allSatisfy { picked.contains($0.code) }
    }

    /// A tick to import and a name to preview, kept apart. On a checkbox the label toggles
    /// it too, so a name you clicked to look at would also be queued for import.
    private func teamRow(_ team: LeagueTeam) -> some View {
        let previewing = state.previewTeam == team
        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { picked.contains(team.code) },
                set: { on in
                    if on { picked.insert(team.code) } else { picked.remove(team.code) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Button {
                state.previewRoster(team)
            } label: {
                HStack(spacing: 8) {
                    Text(team.name)
                    Text(team.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show who's on \(team.name)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(previewing ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var preview: some View {
        if let team = state.previewTeam {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name).font(.headline)
                    if !state.previewRows.isEmpty {
                        Text("\(state.previewRows.count) players")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)

                let shared = RosterFeed.sharedNumbers(state.previewRows)
                if !shared.isEmpty {
                    Label("More than one player wears #\(shared.joined(separator: ", #")), so "
                          + "this team won't import. Keeper tells players apart by number — fix "
                          + "it in a CSV and import that instead.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                Divider()

                if state.isPreviewing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let note = state.previewNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            // By position, not by value: a league that lists a player twice
                            // would give two rows one id, and SwiftUI misdraws a duplicate id
                            // rather than merely repeating it.
                            ForEach(Array(state.previewRows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 8) {
                                    Text("#\(row.number)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(shared.contains(row.number)
                                                         ? Color.orange : Color.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(row.name)
                                    Spacer(minLength: 0)
                                    Text(row.position)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
        } else {
            Text("Click a team's name to see who's on it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(16)
        }
    }

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
                     + "you're shooting, or click a name to see who's on it.")
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

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("\(shown.count) team\(shown.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(allShownPicked ? "Select None" : "Select All") {
                                if allShownPicked {
                                    picked.subtract(shown.map(\.code))
                                } else {
                                    picked.formUnion(shown.map(\.code))
                                }
                            }
                            .buttonStyle(.link)
                            .disabled(shown.isEmpty)
                            .help("Ticks every team in the list — the whole league, or what "
                                  + "the search is showing")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(shown) { teamRow($0) }
                                if shown.isEmpty {
                                    Text("No team matches \"\(search)\".")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.vertical, 8)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                    .frame(width: 300)

                    Divider()

                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(width: 680, height: 540)
        .onAppear { state.loadLeagueTeams() }
        // Ticks are team codes, and codes from one league mean nothing in another.
        .onChange(of: state.rosterSource) { _ in
            picked.removeAll()
            search = ""
        }
    }
}
