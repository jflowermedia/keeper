import SwiftUI

/// One team you can fetch a roster for.
struct LeagueTeam: Identifiable, Hashable {
    let code: String
    let name: String
    /// What the feed calls the team, for the leagues whose feed doesn't go by code, and the
    /// seasons to ask for it in, best first.
    var feedID: String? = nil
    var seasons: [String] = []
    var id: String { code }
}

/// A league Keeper can fetch rosters from.
///
/// Two feeds: the NHL's own, and HockeyTech's, which serves every other league here in one
/// shape. A league on HockeyTech is a case, a name, a group and a key. The switches are
/// exhaustive and have no default, so the compiler points at each place a new one is missing.
enum RosterSource: String, CaseIterable, Identifiable {
    case nhl, ahl, echl, pwhl
    case whl, ohl, qmjhl
    case mjhl, sjhl, ajhl, bchl

    var id: String { rawValue }

    /// What a downloaded team is filed under, and how a team you have is matched to its feed.
    var name: String { rawValue.uppercased() }

    enum Group: String, CaseIterable {
        case pro = "Professional"
        case major = "Major Junior"
        case juniorA = "Junior A"

        var sources: [RosterSource] { RosterSource.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .nhl, .ahl, .echl, .pwhl:    return .pro
        case .whl, .ohl, .qmjhl:          return .major
        case .mjhl, .sjhl, .ajhl, .bchl:  return .juniorA
        }
    }

    /// Nil for a league with a feed of its own.
    var hockeyTech: HockeyTechLeague? {
        switch self {
        case .nhl:   return nil
        case .ahl:   return HockeyTechLeague(client: "ahl", key: "ccb91f29d6744675")
        case .echl:  return HockeyTechLeague(client: "echl", key: "2c2b89ea7345cae8")
        case .pwhl:  return HockeyTechLeague(client: "pwhl", key: "446521baf8c38984")
        case .whl:   return HockeyTechLeague(client: "whl", key: "f1aa699db3d81487")
        case .ohl:   return HockeyTechLeague(client: "ohl", key: "f1aa699db3d81487")
        case .qmjhl: return HockeyTechLeague(client: "lhjmq", key: "f322673b6bcae299")
        case .mjhl:  return HockeyTechLeague(client: "mjhl", key: "f894c324fe5fd8f0")
        case .sjhl:  return HockeyTechLeague(client: "sjhl", key: "2fb5c2e84bf3e4a8")
        case .ajhl:  return HockeyTechLeague(client: "ajhl", key: "cbe60a1d91c44ade")
        case .bchl:  return HockeyTechLeague(client: "bchl", key: "f3ed30007ad2124e")
        }
    }

    /// Where to ask for a team's roster, best first. More than one only where the feed may
    /// have opened a season it hasn't filled in yet.
    func rosterURLs(for team: LeagueTeam) -> [URL] {
        if let league = hockeyTech {
            guard let id = team.feedID else { return [] }
            return team.seasons.compactMap { league.rosterURL(team: id, season: $0) }
        }
        return [URL(string: "\(RosterFeed.api)/roster/\(team.code)/current")].compactMap { $0 }
    }

    func rows(from data: Data) -> [RosterFeed.Row]? {
        hockeyTech == nil ? RosterFeed.rows(from: data) : HockeyTechFeed.rows(from: data)
    }

    /// Through the file importer's reader, so a downloaded roster gets the same column
    /// handling an imported one does. Players who can't go in travel alongside.
    func incoming(_ rows: [RosterFeed.Row], team: LeagueTeam) throws -> [TagLibrary.IncomingTeam] {
        let sorted = RosterFeed.usable(rows)
        let csv = RosterFeed.csv(rows: sorted.rows, team: team, league: name)
        var parsed = try TagLibrary.parseRoster(csv: csv, fallbackTeam: team.name)
        for i in parsed.indices {
            parsed[i].leftOut = sorted.leftOut.map {
                Player(teamID: parsed[i].slug, number: $0.number, name: $0.name, position: $0.position)
            }
        }
        return parsed
    }

    // MARK: Asking

    func fetchTeams() async throws -> [LeagueTeam] {
        guard let league = hockeyTech else {
            guard let url = URL(string: "\(RosterFeed.api)/standings/now") else { return [] }
            return RosterFeed.teams(in: try await RosterFeed.fetch(url))
        }
        guard let url = league.seasonsURL else { return [] }
        let seasons = HockeyTechFeed.seasons(in: try await RosterFeed.fetch(url),
                                             today: HockeyTechFeed.today())
        for (i, season) in seasons.enumerated() {
            guard let url = league.teamsURL(season: season) else { continue }
            let teams = HockeyTechFeed.teams(in: try await RosterFeed.fetch(url),
                                             seasons: Array(seasons[i...]))
            if !teams.isEmpty { return teams }
        }
        return []
    }

    /// Nil when the league answered and listed nobody.
    func fetchRows(_ team: LeagueTeam) async throws -> [RosterFeed.Row]? {
        for url in rosterURLs(for: team) {
            if let rows = rows(from: try await RosterFeed.fetch(url)) { return rows }
        }
        return nil
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
        case "C", "L", "R", "LW", "RW", "F": return "Forward"
        case "D", "LD", "RD":                return "Defence"
        case "G":                            return "Goalie"
        default:                             return ""
        }
    }

    /// One player as the preview shows them and the import receives them.
    struct Row: Hashable {
        let number: String
        let name: String
        let position: String
        /// Up from another club for a game or two. See `usable`.
        var affiliate = false
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
        var lines = ["league,team,code,number,name,position,mascots"]
        // Semicolons, because a comma would end the field. Only the first row carries them;
        // the importer gathers the column across the team.
        // The NHL's only: its codes are shared, and the AHL's CGY isn't the Flames.
        let mascots = (league == RosterSource.nhl.name ? Self.mascots[team.code] ?? [] : [])
            .joined(separator: "; ")
        for (i, row) in rows.enumerated() {
            lines.append([league, team.name, team.code, row.number, row.name, row.position,
                          i == 0 ? mascots : ""]
                .map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Each team's mascots, by the code the API files it under.
    ///
    /// The API doesn't publish these, so they're kept here and are only as current as the
    /// release. Checked November 2026 against the teams' own pages: the Rangers have none,
    /// and Utah's Archie (a team dog) and Pittsburgh's Tux (their AHL affiliate's) aren't
    /// counted. Anything that's gone stale is fixed in the roster editor, and a download
    /// never overwrites mascots you've set without asking.
    static let mascots: [String: [String]] = [
        "ANA": ["Wild Wing"],
        "BOS": ["Blades"],
        "BUF": ["Sabretooth"],
        "CGY": ["Harvey the Hound"],
        "CAR": ["Stormy", "Caroline"],
        "CHI": ["Tommy Hawk"],
        "COL": ["Bernie", "Lil' Bern"],
        "CBJ": ["Stinger"],
        "DAL": ["Victor E. Green"],
        "DET": ["Al"],
        "EDM": ["Hunter"],
        "FLA": ["Stanley C. Panther", "Viktor E. Ratt"],
        "LAK": ["Bailey"],
        "MIN": ["Nordy"],
        "MTL": ["Youppi!", "METAL!"],
        "NSH": ["Gnash"],
        "NJD": ["NJ Devil"],
        "NYI": ["Sparky", "Nyisles"],
        "OTT": ["Spartacat"],
        "PHI": ["Gritty"],
        "PIT": ["Iceburgh"],
        "SJS": ["S.J. Sharkie"],
        "SEA": ["Buoy"],
        "STL": ["Louie"],
        "TBL": ["ThunderBug"],
        "TOR": ["Carlton the Bear"],
        "UTA": ["Tusky"],
        "VAN": ["Fin"],
        "VGK": ["Chance"],
        "WSH": ["Slapshot", "Hat Trick"],
        "WPG": ["Mick E. Moose", "Benny"],
    ]

    static func csv(from data: Data, team: LeagueTeam, league: String = "NHL") -> String? {
        rows(from: data).map { csv(rows: $0, team: team, league: league) }
    }

    /// Who has a number of their own, and who doesn't. `TagLibrary.placed` deals with the rest.
    ///
    /// Junior leagues list call-ups in a number a regular already wears; where exactly one of
    /// them isn't a call-up, they keep it. Otherwise nobody does: picking one would file the
    /// other's clips under the wrong name.
    static func usable(_ rows: [Row]) -> (rows: [Row], leftOut: [Row]) {
        // A league can list one player twice, who'd otherwise clash with themselves.
        var listed: Set<String> = []
        let rows = rows.filter { listed.insert("\($0.number)|\($0.name.lowercased())").inserted }
        let byNumber = Dictionary(grouping: rows.filter { !ShirtNumber.isPlaceholder($0.number) }, by: \.number)
        var keep: [Row] = [], leave: [Row] = []
        for row in rows {
            let wearers = byNumber[row.number] ?? []
            let regulars = wearers.filter { !$0.affiliate }
            if wearers.count == 1 || (regulars.count == 1 && regulars[0] == row) {
                keep.append(row)
            } else {
                leave.append(row)
            }
        }
        return (keep, leave)
    }

    /// A GET that treats an error page as an error. Without the status check a 404 or a 503
    /// body just fails to decode, and the sheet blames the league's data rather than saying
    /// the league answered with an error.
    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Keeper/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "the league answered \(http.statusCode)"])
        }
        return data
    }

    /// Quotes a field if it needs it. Team names don't contain commas today, but a league or
    /// a name that did would silently shift every column after it.
    static func field(_ text: String) -> String {
        guard text.contains(",") || text.contains(";") || text.contains("\"") || text.contains("\n") else { return text }
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
        .background(previewing ? Color.keeperAccent.opacity(0.15) : Color.clear)
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

                let leftOut = Set(RosterFeed.usable(state.previewRows).leftOut)
                if !leftOut.isEmpty {
                    Label("In orange: players sharing a number come in with a letter, like 15b. "
                          + "Three digits means no shirt yet, so they're left out.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.keeperOrange)
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
                                        .foregroundStyle(leftOut.contains(row)
                                                         ? Color.keeperOrange : Color.keeperSecondary)
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
                        ForEach(RosterSource.Group.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(group.sources) { Text($0.name).tag($0) }
                            }
                        }
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
        .sheet(isPresented: Binding(
            get: { state.rosterReview != nil && state.rosterReviewFromDownload },
            set: { if !$0 { state.finishRosterReview(apply: false) } }
        )) {
            RosterReviewSheet(state: state)
                .keeperThemed()
        }
        .onAppear { state.loadLeagueTeams() }
        // Ticks are team codes, and codes from one league mean nothing in another.
        .onChange(of: state.rosterSource) { _ in
            picked.removeAll()
            search = ""
        }
    }
}
