import Foundation

/// A league on HockeyTech's stats platform.
struct HockeyTechLeague: Equatable {
    let client: String
    /// Not a secret: it's the key the league's own website hands every visitor's browser to
    /// read these same pages. It only says which site is asking.
    let key: String

    static let feed = "https://lscluster.hockeytech.com/feed/index.php"

    private func url(_ view: String, _ extra: [String: String] = [:]) -> URL? {
        var parts = URLComponents(string: Self.feed)
        let query = ["feed": "modulekit", "view": view, "client_code": client,
                     "key": key, "fmt": "json", "lang": "en"].merging(extra) { $1 }
        parts?.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts?.url
    }

    var seasonsURL: URL? { url("seasons") }
    func teamsURL(season: String) -> URL? { url("teamsbyseason", ["season_id": season]) }
    func rosterURL(team: String, season: String) -> URL? {
        url("roster", ["team_id": team, "season_id": season])
    }
}

/// Reading HockeyTech's feed. One shape for every league on it, so one parser.
///
/// Undocumented, like the NHL's, and read the same way: every field optional, and anything
/// unexpected comes back as nothing rather than as a roster full of blanks. Pure, so the
/// checks can run it on bytes.
enum HockeyTechFeed {

    // MARK: Decoding

    /// An element that isn't the shape expected is skipped rather than failing the list.
    /// Every roster really does end in a stray empty array after the last player.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Kit<Body: Decodable>: Decodable {
        let body: Body
        enum CodingKeys: String, CodingKey { case body = "SiteKit" }
    }

    private struct Season: Decodable {
        var season_id: RosterFeed.Number?
        var season_name: String?
        var playoff: RosterFeed.Number?
        var start_date: String?
    }

    private struct Seasons: Decodable {
        var list: [Lossy<Season>]?
        enum CodingKeys: String, CodingKey { case list = "Seasons" }
    }

    private struct TeamRow: Decodable {
        var id: RosterFeed.Number?
        var name: String?
        var code: String?
    }

    private struct Teams: Decodable {
        var list: [Lossy<TeamRow>]?
        enum CodingKeys: String, CodingKey { case list = "Teamsbyseason" }
    }

    private struct Entry: Decodable {
        var first_name: String?
        var last_name: String?
        var tp_jersey_number: RosterFeed.Number?
        var position: String?
        var flags: [Lossy<String>]?

        var isAffiliate: Bool { (flags ?? []).contains { $0.value == "ht-affiliate" } }
    }

    private struct Roster: Decodable {
        var list: [Lossy<Entry>]?
        enum CodingKeys: String, CodingKey { case list = "Roster" }
    }

    // MARK: Reading

    /// Seasons worth asking for a roster, best first.
    ///
    /// The newest that has started, because a season is listed months ahead with every roster
    /// in it empty. The one before follows as a fallback, for a season that has started on
    /// paper and still has nobody in it. Not playoffs, which list only the teams left in, and
    /// not all-star weekends and prospect series, which the feed calls seasons too.
    static func seasons(in data: Data, today: String) -> [String] {
        guard let decoded = try? JSONDecoder().decode(Kit<Seasons>.self, from: data) else { return [] }
        let usable = (decoded.body.list ?? []).compactMap(\.value).compactMap { season -> (id: String, start: String)? in
            guard let id = season.season_id?.value, !id.isEmpty,
                  let start = season.start_date, start.count == 10, start <= today,
                  season.playoff?.value != "1",
                  !isEvent(season.season_name ?? "")
            else { return nil }
            return (id, start)
        }
        return usable.sorted { $0.start > $1.start }.prefix(2).map(\.id)
    }

    static func isEvent(_ name: String) -> Bool {
        name.range(of: "all[- ]?star|showcase|prospect|combine|special|challenge|play[- ]?in",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Today as the feed writes dates. Fixed calendar and locale, or a Mac set to another
    /// calendar would compare against the wrong year.
    static func today(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    static func teams(in data: Data, seasons: [String]) -> [LeagueTeam] {
        guard let decoded = try? JSONDecoder().decode(Kit<Teams>.self, from: data) else { return [] }
        var seen: Set<String> = []
        return (decoded.body.list ?? []).compactMap(\.value).compactMap { row -> LeagueTeam? in
            guard let id = row.id?.value, !id.isEmpty else { return nil }
            // The QMJHL lists the other league's clubs it plays as "- Ottawa, 67's (OHL) -".
            let raw = tidy(row.name)
            guard !raw.isEmpty, !raw.hasPrefix("-") else { return nil }
            // And its own as "Halifax, Mooseheads".
            let name = raw.replacingOccurrences(of: ", ", with: " ")
            let code = tidy(row.code).uppercased()
            guard !code.isEmpty, seen.insert(code).inserted else { return nil }
            return LeagueTeam(code: code, name: name, feedID: id, seasons: seasons)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func rows(from data: Data) -> [RosterFeed.Row]? {
        guard let decoded = try? JSONDecoder().decode(Kit<Roster>.self, from: data) else { return nil }
        let out = (decoded.body.list ?? []).compactMap(\.value).compactMap { entry -> RosterFeed.Row? in
            let number = tidy(entry.tp_jersey_number?.value)
            let name = tidy("\(entry.first_name ?? "") \(entry.last_name ?? "")")
            guard !number.isEmpty, !name.isEmpty else { return nil }
            return RosterFeed.Row(number: number, name: name,
                                  position: RosterFeed.position(entry.position),
                                  affiliate: entry.isAffiliate)
        }
        return out.isEmpty ? nil : out
    }

    /// These are typed in by the teams, stray spaces and all.
    private static func tidy(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
