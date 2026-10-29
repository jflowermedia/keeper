import Foundation

/// Keeper's checks, run with `swift run Keeper --self-check`.
///
/// These were an XCTest target to begin with, which was a mistake: XCTest ships with Xcode,
/// not with the Command Line Tools, and the Command Line Tools are all this app needs to
/// build. A check suite that only runs on a machine set up differently from the one that
/// builds the app is a check suite that never runs. So it lives in the app instead, behind
/// a flag, with a dozen lines of harness standing in for XCTest.
///
/// What's covered is the three things that have actually shipped broken — the CSV reader, the
/// stored library format, and pairing sidecars to videos — plus the quieter logic added since:
/// version comparison, the tutorial's content, and the sleep hold.
///
/// Almost everything here works on bytes or a temporary folder: nothing touches the real
/// `library.json`, and nothing writes outside `FileManager.default.temporaryDirectory`. Keep it
/// that way. Two deliberate exceptions, both named where they happen:
///
/// - `welcome()` reads the live `Shortcuts`, which only ever reads from defaults itself.
/// - `sleepHold()` takes one real power assertion and releases it in the same breath, because
///   "idempotent in both directions" is the property the rest of the design leans on and a
///   stub wouldn't be testing it. It nets to zero, and the process exits straight after.
enum SelfCheck {

    // MARK: Harness

    private static var failures: [String] = []
    private static var passes = 0

    private static func expect<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want {
            passes += 1
            print("  ok   \(name)")
        } else {
            failures.append(name)
            print("  FAIL \(name)")
            print("       got  \(got)")
            print("       want \(want)")
        }
    }

    private static func expectTrue(_ name: String, _ value: Bool) {
        expect(name, value, true)
    }

    private static func section(_ title: String) {
        print("\n\(title)")
    }

    /// Returns true when everything passed.
    static func run() -> Bool {
        failures = []
        passes = 0

        print("Keeper \(AppInfo.version) self-check")
        csv()
        libraryFormat()
        scanner()
        updates()
        welcome()
        scanSummary()
        cameraPresets()
        teamPick()
        benchStops()
        clipRange()
        reimport()
        sleepHold()
        addingTeams()
        subjects()
        oneOffCategories()
        rosterDownload()
        categorySections()

        print("\n\(passes) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("Failed: \(failures.joined(separator: ", "))")
        }
        return failures.isEmpty
    }

    // MARK: Temporary files

    private static func tempFolder() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    private static func write(_ bytes: [UInt8], named name: String, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func write(_ text: String, named name: String, in folder: URL) -> URL? {
        write(Array(text.utf8), named: name, in: folder)
    }

    // MARK: - The CSV reader
    //
    // `Character` in Swift is a grapheme cluster and "\r\n" is a single one, so a parser
    // switching on "\n" matched nothing, appended every line ending into the current field
    // and returned the whole file as one row. Excel and Numbers both write CRLF, so every
    // roster exported from either failed to import with "no players found" as the only
    // clue. Excel also writes a byte-order mark, which rode along on the first heading and
    // made that column unrecognisable.

    private static func csv() {
        section("The CSV reader")

        let crlf = CSV.parse("league,team,number,name\r\nMJHL,Virden,27,Liam Goertzen\r\n")
        expect("CRLF ends a row", crlf.count, 2)
        expect("CRLF row contents", crlf.last ?? [], ["MJHL", "Virden", "27", "Liam Goertzen"])

        expect("bare CR ends a row too",
               CSV.parse("number,name\r27,Liam\r31,Micky\r").count, 3)
        expect("plain LF still works", CSV.parse("number,name\n27,Liam\n").count, 2)
        expect("mixed endings in one file",
               CSV.parse("a,b\r\nc,d\ne,f\rg,h").count, 4)

        expect("semicolons separate", CSV.parse("27;Liam").first ?? [], ["27", "Liam"])
        expect("tabs separate", CSV.parse("27\tLiam").first ?? [], ["27", "Liam"])

        let quoted = CSV.parse("number,name\n27,\"Goertzen, Liam\"\n")
        expect("a quoted field keeps its comma", quoted.last ?? [], ["27", "Goertzen, Liam"])
        expect("a quoted field keeps a newline",
               CSV.parse("number,name\n27,\"Liam\nGoertzen\"\n").count, 2)
        expect("a doubled quote is one quote",
               CSV.parse("name\n\"Liam \"\"Goose\"\" Goertzen\"\n").last ?? [],
               ["Liam \"Goose\" Goertzen"])

        expect("a blank line isn't a row", CSV.parse("a,b\n\n\nc,d\n").count, 2)
        expect("a trailing comma keeps the empty field",
               CSV.parse("a,b,\n").first ?? [], ["a", "b", ""])
        expect("no trailing newline is fine", CSV.parse("a,b").count, 1)

        guard let folder = tempFolder() else {
            failures.append("couldn't make a temporary folder for the CSV checks")
            print("  FAIL couldn't make a temporary folder")
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        // What Excel actually writes: a byte-order mark, then CRLF.
        var excel: [UInt8] = [0xEF, 0xBB, 0xBF]
        excel += Array("team,code,number,name,position\r\n".utf8)
        excel += Array("Virden Oil Capitals,VIR,27,Liam Goertzen,Forward\r\n".utf8)
        excel += Array("Virden Oil Capitals,VIR,31,Micky Gross,Goalie\r\n".utf8)

        if let url = write(excel, named: "excel.csv", in: folder), let text = CSV.readText(url) {
            expectTrue("the byte-order mark is stripped", !text.hasPrefix("\u{FEFF}"))
            let rows = CSV.parse(text)
            expect("an Excel file parses end to end", rows.count, 3)
            expect("and its first heading is readable", rows.first?.first ?? "", "team")
            expect("and the last row is intact", rows.last?.count ?? 0, 5)
        } else {
            failures.append("couldn't write the Excel fixture")
            print("  FAIL couldn't write the Excel fixture")
        }

        // 0xE9 is "é" in Latin-1 and not valid UTF-8 on its own.
        let latin1 = Array("number,name\n9,Ren".utf8) + [0xE9] + Array("\n".utf8)
        if let url = write(latin1, named: "latin1.csv", in: folder) {
            expectTrue("an odd encoding still reads", CSV.readText(url)?.contains("Ren") == true)
        }
    }

    // MARK: - The stored library format
    //
    // Swift's generated decoder throws on a missing key even for a property with a default
    // value, so the moment a field is added every library written before it existed stops
    // loading — and a library that won't load is a season of tagging gone. These fixtures
    // are written the way older versions wrote them.

    private static func libraryFormat() {
        section("The stored library format")

        let oldest = """
        {
          "teams": [
            { "id": "yateley-wood-pigeons", "name": "Yateley Wood Pigeons",
              "players": [ { "teamID": "yateley-wood-pigeons", "number": "17",
                             "name": "Marchetti", "position": "Forward" } ] }
          ],
          "categories": ["Goal", "Save"],
          "tags": [
            { "id": "A1B2C3D4-0000-0000-0000-000000000001", "umid": "060A2B34ABCD",
              "clipName": "C0001.MP4", "volumeName": "CARD A",
              "path": "/Volumes/CARD A/C0001.MP4", "category": "Goal",
              "note": "", "created": "2026-01-04T18:22:01Z" }
          ]
        }
        """
        do {
            let archive = try TagLibrary.decodeArchive(Data(oldest.utf8))
            expect("the first release's shape still decodes", archive.teams.count, 1)
            expect("its players survive", archive.teams.first?.players.count ?? 0, 1)
            expect("its tags survive", archive.tags.count, 1)
            expectTrue("presets absent means absent", archive.presets == nil)
            expectTrue("keep overrides absent means absent", archive.keepOverrides == nil)
        } catch {
            failures.append("the oldest archive threw")
            print("  FAIL the oldest archive threw: \(error)")
        }

        // `code` and `league` came later. Neither may ever become non-optional.
        let bare = """
        { "teams": [ { "id": "virden", "name": "Virden Oil Capitals", "players": [] } ],
          "categories": [], "tags": [] }
        """
        do {
            let archive = try TagLibrary.decodeArchive(Data(bare.utf8))
            expectTrue("a team with no code decodes", archive.teams.first?.code == nil)
            expectTrue("a team with no league decodes", archive.teams.first?.league == nil)
        } catch {
            failures.append("a team without code or league threw")
            print("  FAIL a team without code or league threw: \(error)")
        }

        // Fields that are non-optional with a default: the generated decoder would reject
        // these outright.
        let team = """
        { "id": "t", "name": "Team" }
        """
        if let decoded = try? JSONDecoder().decode(Team.self, from: Data(team.utf8)) {
            expect("a team with no players list decodes", decoded.players.count, 0)
        } else {
            failures.append("a team with no players list threw")
            print("  FAIL a team with no players list threw")
        }

        let player = """
        { "teamID": "t", "number": "9", "name": "Nine" }
        """
        if let decoded = try? JSONDecoder().decode(Player.self, from: Data(player.utf8)) {
            expect("a player with no position decodes", decoded.position, "")
            expect("and its id is computed", decoded.id, "t/9")
        } else {
            failures.append("a player with no position threw")
            print("  FAIL a player with no position threw")
        }

        let tag = """
        { "umid": "ABC", "clipName": "C0002.MP4", "volumeName": "CARD A",
          "path": "/x/C0002.MP4", "category": "Save" }
        """
        if let decoded = try? JSONDecoder().decode(Tag.self, from: Data(tag.utf8)) {
            expect("a tag with no note decodes", decoded.note, "")
            expect("and keeps its category", decoded.category, "Save")
        } else {
            failures.append("a tag with no note or created threw")
            print("  FAIL a tag with no note or created threw")
        }

        let unnamed = """
        { "name": "Dauphin Kings", "players": [] }
        """
        if let decoded = try? JSONDecoder().decode(Team.self, from: Data(unnamed.utf8)) {
            expect("a team with no id gets the slug of its name", decoded.id, "dauphin-kings")
            expect("built the same way an import builds it", decoded.id, Team.slug(decoded.name))
        }

        // What this build writes has to come back unchanged, or a backup is worthless.
        let roundTripTeam = Team(id: "virden", name: "Virden Oil Capitals",
                                 code: "VIR", league: "MJHL",
                                 players: [Player(teamID: "virden", number: "27",
                                                  name: "Liam Goertzen", position: "Forward")])
        let roundTripTag = Tag(umid: "060A2B34", clipName: "C0001.MP4",
                               volumeName: "CARD A", path: "/Volumes/CARD A/C0001.MP4",
                               teamID: roundTripTeam.id, teamName: roundTripTeam.name,
                               playerNumber: "27", playerName: "Liam Goertzen",
                               playerPosition: "Forward", category: "Goal")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = TagLibrary.Archive(teams: [roundTripTeam], categories: ["Goal"],
                                         tags: [roundTripTag], presets: nil,
                                         keepOverrides: ["060A2B34": true])
        if let data = try? encoder.encode(archive),
           let back = try? TagLibrary.decodeArchive(data) {
            expect("a round trip keeps the team", back.teams, [roundTripTeam])
            expect("and the tag's player", back.tags.first?.playerID ?? "", "virden/27")
            expect("and the keep override", back.keepOverrides?["060A2B34"] ?? false, true)
        } else {
            failures.append("the round trip failed")
            print("  FAIL the round trip failed")
        }

        // Nonsense must throw rather than decode as an empty library — that's what stops
        // the app saving an empty file over a good one.
        var threwOnRubbish = false
        do { _ = try TagLibrary.decodeArchive(Data("not json".utf8)) } catch { threwOnRubbish = true }
        expectTrue("rubbish throws", threwOnRubbish)

        var threwOnEmpty = false
        do { _ = try TagLibrary.decodeArchive(Data("{}".utf8)) } catch { threwOnEmpty = true }
        expectTrue("an empty object throws", threwOnEmpty)
    }

    // MARK: - The update check
    //
    // Comparing versions is the kind of thing that fails quietly: too eager and it nags
    // about a release you already have, too shy and it never mentions one. The tag parsing
    // matters too — `/releases/latest` leaves out pre-releases and every Keeper release so
    // far is one, so the list endpoint is used and its tags have to be read correctly.

    private static func updates() {
        section("The update check")

        expect("a plain tag", ReleaseFeed.numbersOnly("v0.7.0"), "0.7.0")
        expect("a pre-release tag drops its label", ReleaseFeed.numbersOnly("v0.7.0-alpha"), "0.7.0")
        expect("a numbered label doesn't become a component",
               ReleaseFeed.numbersOnly("v0.6.1-alpha2"), "0.6.1")
        expect("no leading v", ReleaseFeed.numbersOnly("1.2.3"), "1.2.3")
        expect("two components stay two", ReleaseFeed.numbersOnly("v0.6"), "0.6")

        expectTrue("0.7 is newer than 0.6", ReleaseFeed.isNewer("0.7", than: "0.6"))
        expectTrue("0.6.1 is newer than 0.6", ReleaseFeed.isNewer("0.6.1", than: "0.6"))
        expectTrue("1.0 is newer than 0.9.9", ReleaseFeed.isNewer("1.0", than: "0.9.9"))
        expectTrue("0.10 is newer than 0.9 — not a string compare",
                   ReleaseFeed.isNewer("0.10", than: "0.9"))
        expectTrue("the same version is not newer", !ReleaseFeed.isNewer("0.6", than: "0.6"))
        expectTrue("0.6 and 0.6.0 are the same thing",
                   !ReleaseFeed.isNewer("0.6.0", than: "0.6"))
        expectTrue("an older one is not newer", !ReleaseFeed.isNewer("0.5", than: "0.6"))
        expectTrue("a pre-release tag still compares",
                   ReleaseFeed.isNewer(ReleaseFeed.numbersOnly("v0.7.0-alpha"), than: "0.6"))

        // What GitHub actually sends back, newest first, with a draft at the front.
        let json = """
        [
          { "tag_name": "v0.8.0-alpha", "name": "Keeper 0.8",
            "html_url": "https://github.com/jflowermedia/keeper/releases/tag/v0.8.0-alpha",
            "draft": true, "prerelease": true },
          { "tag_name": "v0.7.0-alpha", "name": "Keeper 0.7",
            "html_url": "https://github.com/jflowermedia/keeper/releases/tag/v0.7.0-alpha",
            "draft": false, "prerelease": true }
        ]
        """
        if let release = ReleaseFeed.newest(in: Data(json.utf8)) {
            expect("a draft is skipped", release.version, "0.7.0")
            expect("and the published one is taken", release.title, "Keeper 0.7")
            expectTrue("with its page",
                       release.page.absoluteString.hasSuffix("v0.7.0-alpha"))
        } else {
            failures.append("the release list didn't parse")
            print("  FAIL the release list didn't parse")
        }

        // A field GitHub might drop must not make the whole list unreadable.
        let sparse = """
        [ { "tag_name": "v0.9.0", "html_url": "https://example.com/r" } ]
        """
        if let release = ReleaseFeed.newest(in: Data(sparse.utf8)) {
            expect("a release with no name falls back", release.title, "Keeper 0.9.0")
        } else {
            failures.append("a sparse release didn't parse")
            print("  FAIL a sparse release didn't parse")
        }

        expectTrue("rubbish reads as nothing rather than crashing",
                   ReleaseFeed.newest(in: Data("not json".utf8)) == nil)
        expectTrue("an empty list reads as nothing",
                   ReleaseFeed.newest(in: Data("[]".utf8)) == nil)
        // The page URL ends up at `NSWorkspace.open`, so anything that isn't a web page is
        // dropped rather than opened.
        expectTrue("a file: URL is refused",
                   ReleaseFeed.newest(in: Data(#"[{"tag_name":"v9.0.0","html_url":"file:///etc/passwd"}]"#.utf8)) == nil)
        expectTrue("a scheme-less URL is refused",
                   ReleaseFeed.newest(in: Data(#"[{"tag_name":"v9.0.0","html_url":"example.com/r"}]"#.utf8)) == nil)
        expectTrue("plain http is refused",
                   ReleaseFeed.newest(in: Data(#"[{"tag_name":"v9.0.0","html_url":"http://example.com/r"}]"#.utf8)) == nil)

        expectTrue("a tag with no numbers is ignored",
                   ReleaseFeed.newest(in: Data(#"[{"tag_name":"nightly","html_url":"https://example.com"}]"#.utf8)) == nil)

        // Publish a fix to an old line after a new release and GitHub's list is no longer in
        // version order. The highest version has to win, or the late 0.6.1 would hide 0.7 for
        // good.
        let outOfOrder = """
        [
          { "tag_name": "v0.6.1", "name": "Keeper 0.6.1", "html_url": "https://example.com/a" },
          { "tag_name": "v0.7.0", "name": "Keeper 0.7",   "html_url": "https://example.com/b" }
        ]
        """
        expect("the highest version wins, not the first listed",
               ReleaseFeed.newest(in: Data(outOfOrder.utf8))?.version ?? "none", "0.7.0")

        // The one that matters in practice, and the one that would nag you every launch: a
        // release of the version you're already running. Built from `AppInfo.version` rather
        // than a literal, so it keeps testing the real thing after every version bump instead
        // of quietly becoming a test of some old number.
        let same = """
        [ { "tag_name": "v\(AppInfo.version).0-alpha", "name": "Keeper \(AppInfo.version)",
            "html_url": "https://example.com/c" } ]
        """
        if let release = ReleaseFeed.newest(in: Data(same.utf8)) {
            expectTrue("the version you're already on isn't offered",
                       !ReleaseFeed.isNewer(release.version, than: AppInfo.version))
        } else {
            failures.append("the current version's own release didn't parse")
            print("  FAIL the current version's own release didn't parse")
        }
    }

    // MARK: - Downloading a roster
    //
    // The league's field names aren't documented anywhere official, so every one of them is
    // optional and has alternatives. What must never happen is a roster that looks fine and
    // isn't: a player with no number can't be imported at all, and a name that lost half of
    // itself would file footage under the wrong person.

    private static func rosterDownload() {
        section("Downloading a roster")
        // Every league needs a name to show and endpoints to ask, or its entry in the picker
        // would open a sheet that can only say "Couldn't reach the league".
        let team = LeagueTeam(code: "XYZ", name: "Test")
        expect("every league has a name", RosterSource.allCases.filter { $0.name.isEmpty }.count, 0)
        expect("league names are distinct",
               Set(RosterSource.allCases.map(\.name)).count, RosterSource.allCases.count)
        expect("every league has endpoints",
               RosterSource.allCases.filter { $0.teamsURL == nil || $0.rosterURL(for: team) == nil }.count, 0)

        let jets = LeagueTeam(code: "WPG", name: "Winnipeg Jets")

        // The shape the API is expected to return.
        let nested = """
        { "forwards": [
            { "sweaterNumber": 26, "firstName": { "default": "Blake" },
              "lastName": { "default": "Wheeler" }, "positionCode": "R" }],
          "defensemen": [
            { "sweaterNumber": 33, "firstName": { "default": "Dustin" },
              "lastName": { "default": "Byfuglien" }, "positionCode": "D" }],
          "goalies": [
            { "sweaterNumber": 34, "firstName": { "default": "Michael" },
              "lastName": { "default": "Hutchinson" }, "positionCode": "G" }] }
        """
        if let csv = RosterFeed.csv(from: Data(nested.utf8), team: jets) {
            let lines = csv.split(separator: "\n").map(String.init)
            expect("a header and three players", lines.count, 4)
            expect("the header is what the importer reads", lines[0],
                   "league,team,code,number,name,position")
            expect("a forward", lines[1], "NHL,Winnipeg Jets,WPG,26,Blake Wheeler,Forward")
            expect("a defenceman", lines[2], "NHL,Winnipeg Jets,WPG,33,Dustin Byfuglien,Defence")
            expect("a goalie", lines[3], "NHL,Winnipeg Jets,WPG,34,Michael Hutchinson,Goalie")
        } else {
            failures.append("the expected roster shape didn't parse")
            print("  FAIL the expected roster shape didn't parse")
        }

        // The flatter shape, in case the league ever sends it.
        let flat = """
        { "forwards": [{ "sweaterNumber": "9", "firstName": "Evander",
                         "lastName": "Kane", "positionCode": "L" }] }
        """
        expect("a flat name and a numeric string still read",
               RosterFeed.csv(from: Data(flat.utf8), team: jets)?
                   .split(separator: "\n").last.map(String.init) ?? "none",
               "NHL,Winnipeg Jets,WPG,9,Evander Kane,Forward")

        // A player with no number is dropped, not carried through — an import refuses a
        // blank number, so one unsigned call-up would otherwise cost the whole team.
        let missing = """
        { "forwards": [{ "firstName": { "default": "No" }, "lastName": { "default": "Number" } },
                       { "sweaterNumber": 55, "firstName": { "default": "Mark" },
                         "lastName": { "default": "Scheifele" }, "positionCode": "C" }] }
        """
        expect("the numberless player is left out",
               RosterFeed.csv(from: Data(missing.utf8), team: jets)?
                   .split(separator: "\n").count ?? 0, 2)

        expectTrue("rubbish reads as nothing rather than crashing",
                   RosterFeed.csv(from: Data("not json".utf8), team: jets) == nil)
        expectTrue("an empty roster reads as nothing",
                   RosterFeed.csv(from: Data("{}".utf8), team: jets) == nil)
        expectTrue("a roster with nobody usable reads as nothing",
                   RosterFeed.csv(from: Data(#"{"forwards":[{"firstName":"A"}]}"#.utf8),
                                  team: jets) == nil)

        // A comma in a name or a team would shift every column after it.
        let rows = [RosterFeed.Row(number: "9", name: "A", position: ""),
                    RosterFeed.Row(number: "12", name: "B", position: ""),
                    RosterFeed.Row(number: "9", name: "C", position: ""),
                    RosterFeed.Row(number: "12", name: "D", position: ""),
                    RosterFeed.Row(number: "33", name: "E", position: "")]
        expect("shared numbers are found, in order", RosterFeed.sharedNumbers(rows), ["9", "12"])
        expect("a clean roster shares none", RosterFeed.sharedNumbers(Array(rows.suffix(3))), [])
        expect("the preview and the import read the same players",
               RosterFeed.rows(from: Data(nested.utf8))?.count,
               RosterFeed.csv(from: Data(nested.utf8), team: jets)
                   .map { $0.split(separator: "\n").count - 1 })

        expect("a plain field isn't quoted", RosterFeed.field("Winnipeg Jets"), "Winnipeg Jets")
        expect("a comma is quoted", RosterFeed.field("Jets, The"), "\"Jets, The\"")
        expect("a quote is doubled", RosterFeed.field("Da \"Bus\""), "\"Da \"\"Bus\"\"\"")

        // Positions map to what the roster editor shows, and anything unknown comes back
        // empty rather than inventing a position.
        expect("centre", RosterFeed.position("C"), "Forward")
        expect("left wing", RosterFeed.position("L"), "Forward")
        expect("right wing", RosterFeed.position("R"), "Forward")
        expect("defence", RosterFeed.position("D"), "Defence")
        expect("goalie", RosterFeed.position("G"), "Goalie")
        expect("lower case still reads", RosterFeed.position("d"), "Defence")
        expect("an unknown code is left blank", RosterFeed.position("W"), "")
        expect("a missing code is left blank", RosterFeed.position(nil), "")

        // The team list, discovered rather than written down.
        let standings = """
        { "standings": [
            { "teamAbbrev": { "default": "WPG" }, "teamName": { "default": "Winnipeg Jets" } },
            { "teamAbbrev": { "default": "MTL" }, "teamName": { "default": "Montreal Canadiens" } },
            { "teamAbbrev": { "default": "WPG" }, "teamName": { "default": "Winnipeg Jets" } }] }
        """
        let teams = RosterFeed.teams(in: Data(standings.utf8))
        expect("a repeated team is listed once", teams.count, 2)
        expect("and they're in reading order", teams.first?.name ?? "none", "Montreal Canadiens")
        expectTrue("each carries its code", teams.allSatisfy { !$0.code.isEmpty })
        expect("rubbish standings give no teams",
               RosterFeed.teams(in: Data("not json".utf8)).count, 0)
        expect("empty standings give no teams",
               RosterFeed.teams(in: Data(#"{"standings":[]}"#.utf8)).count, 0)

        // Duplicate numbers have to be refused by the *import*, not only by the roster
        // editor. A player's id is team-and-number, so two players sharing one share an id,
        // and the import used to accept that silently — which is how a downloaded or pasted
        // roster could leave a team that misbehaves in every list it appears in.
        func numbers(_ csv: String) -> [String] {
            csv.split(separator: "\n").dropFirst().compactMap {
                let parts = $0.split(separator: ",", omittingEmptySubsequences: false)
                return parts.count > 3 ? String(parts[3]) : nil
            }
        }
        func hasClash(_ csv: String) -> Bool {
            let all = numbers(csv)
            return Set(all).count != all.count
        }

        let clean = """
        league,team,code,number,name,position
        NHL,Jets,WPG,26,Blake Wheeler,Forward
        NHL,Jets,WPG,33,Dustin Byfuglien,Defence
        """
        let clashing = """
        league,team,code,number,name,position
        NHL,Jets,WPG,14,Anthony Peluso,Forward
        NHL,Jets,WPG,14,Tim Stapleton,Forward
        """
        let blanks = """
        league,team,code,number,name,position
        NHL,Jets,WPG,,One Player,Forward
        NHL,Jets,WPG,,Another Player,Forward
        """
        expectTrue("a clean roster has no clash", !hasClash(clean))
        expectTrue("a repeated number is a clash", hasClash(clashing))
        expectTrue("two blanks are a clash too, since a blank is still an id",
                   hasClash(blanks))

        // And the message has to name the number, or you can't find it in the file.
        let message = TagLibrary.ImportError
            .duplicateNumbers(team: "Jets", numbers: ["14"]).errorDescription ?? ""
        expectTrue("the team is named", message.contains("Jets"))
        expectTrue("the number is named", message.contains("14"))
        let blankMessage = TagLibrary.ImportError
            .duplicateNumbers(team: "Jets", numbers: [""]).errorDescription ?? ""
        expectTrue("a blank clash is described rather than shown as nothing",
                   blankMessage.contains("blank"))
    }

    // MARK: - Category sections
    //
    // Sections are organisation, not meaning: the flattened order is still the one order,
    // and a tag records a bare word. So the things that can break are structural — a label
    // in two sections is one category pretending to be two, a migration that drops a
    // customised list loses work silently, and an empty section list leaves the grid with
    // nothing to arrow between and no way back.

    private static func categorySections() {
        section("Category sections")

        let defaults = CategorySection.defaults
        expectTrue("there are sections out of the box", !defaults.isEmpty)

        let flat = defaults.flatMap(\.items)
        expect("no category appears in two sections", Set(flat).count, flat.count)

        let ids = defaults.map(\.id)
        expect("no two sections share an id", Set(ids).count, ids.count)
        expectTrue("none of them is called Recent",
                   !ids.contains("recent"))

        // Migration: a library from before sections keeps every word it had, in order.
        let customised = ["Goal", "Zamboni", "Chirp", "Mascot cam"]
        let migrated = CategorySection.migrating(customised)
        expect("a customised list survives migration", migrated.flatMap(\.items), customised)
        expect("and lands in one section", migrated.filter { !$0.items.isEmpty }.count, 1)
        expect("under a name you'd expect", migrated.first?.name ?? "none", "Gameplay")

        // An empty library gets the starting set rather than no sections at all.
        expect("nothing to migrate gives the defaults",
               CategorySection.migrating([]).count, defaults.count)
        expectTrue("which is never empty", !CategorySection.migrating([]).isEmpty)

        // The flattened order is what filenames rank on, so it has to be stable and complete.
        expect("flattening keeps section order",
               defaults.first?.items.first ?? "none", "Goal")
        expect("and reaches the last section",
               defaults.flatMap(\.items).count, defaults.reduce(0) { $0 + $1.items.count })

        // ← → wrap in both directions, over any number of sections.
        func step(_ index: Int, _ count: Int, forward: Bool) -> Int {
            (index + (forward ? 1 : -1) + count) % count
        }
        expect("right wraps past the end", step(2, 3, forward: true), 0)
        expect("left wraps past the start", step(0, 3, forward: false), 2)
        expect("right advances", step(0, 3, forward: true), 1)
        expect("left goes back", step(2, 3, forward: false), 1)
        for count in 1...6 {
            var seen: Set<Int> = []
            var index = 0
            for _ in 0..<count {
                seen.insert(index)
                index = step(index, count, forward: true)
            }
            expect("\(count) section(s): every one is reachable", seen.count, count)
            expect("\(count) section(s): and it returns to the start", index, 0)
        }

        // A clamp, because a section can vanish while the cursor sits past it — removing one,
        // or the Recent section emptying itself.
        func clamp(_ index: Int, _ count: Int) -> Int {
            guard count > 0 else { return 0 }
            return min(max(index, 0), count - 1)
        }
        // "Recent" is reserved. A real section with that name would share the one-offs'
        // id and could never be moved or removed again — the pill's menu keys on the id.
        expect("the reserved id is what the pseudo-section uses",
               CategorySection.reservedID, "recent")
        expectTrue("so a section named Recent must be refused",
                   Team.slug("Recent") == CategorySection.reservedID)
        expectTrue("and one named RECENT too",
                   Team.slug("RECENT") == CategorySection.reservedID)
        expectTrue("but Recents is fine",
                   Team.slug("Recents") != CategorySection.reservedID)

        // Typing a number to reach a category. It narrows by position rather than jumping,
        // so it copes with a section holding more than nine — and the number is positional,
        // so reordering has to renumber without anything being stored.
        func numbered(_ items: [String]) -> [(Int, String)] {
            items.enumerated().map { ($0.offset + 1, $0.element) }
        }
        func narrowed(_ items: [String], typing entry: String) -> [(Int, String)] {
            guard !entry.isEmpty else { return numbered(items) }
            return numbered(items).filter { String($0.0).hasPrefix(entry) }
        }

        let gameplay = ["Goal", "Assist", "Save", "Hit", "Penalty", "Faceoff", "Shot",
                        "Celebration", "Interview", "B-Roll", "Chant", "Dancing"]

        expect("nothing typed shows everything", narrowed(gameplay, typing: "").count,
               gameplay.count)
        expect("typing 1 leaves 1, 10, 11 and 12",
               narrowed(gameplay, typing: "1").map(\.0), [1, 10, 11, 12])
        expect("and the cursor's first is the one you meant",
               narrowed(gameplay, typing: "1").first?.1 ?? "none", "Goal")
        expect("typing 11 leaves one", narrowed(gameplay, typing: "11").map(\.1), ["Chant"])
        expect("typing 3 leaves one", narrowed(gameplay, typing: "3").map(\.1), ["Save"])
        expect("a single-digit match leaves just that one",
               narrowed(gameplay, typing: "9").map(\.1), ["Interview"])
        expect("a two-digit miss leaves nothing",
               narrowed(gameplay, typing: "19").count, 0)

        // The refusal guard: a digit that would empty the grid is turned away, so what's
        // typed can never leave nothing on screen.
        func accepts(_ items: [String], _ entry: String, _ digit: String) -> Bool {
            !narrowed(items, typing: entry + digit).isEmpty
        }
        expectTrue("1 is accepted", accepts(gameplay, "", "1"))
        expectTrue("1 then 1 is accepted", accepts(gameplay, "1", "1"))
        expectTrue("1 then 9 is refused", !accepts(gameplay, "1", "9"))
        expectTrue("0 on its own is refused", !accepts(gameplay, "", "0"))

        // Positional, so reordering renumbers and nothing has to be migrated.
        var reordered = gameplay
        reordered.swapAt(0, 2)
        expect("after a swap the number follows the category",
               narrowed(reordered, typing: "1").first?.1 ?? "none", "Save")
        expect("and the one that moved takes its new number",
               numbered(reordered).first { $0.1 == "Goal" }?.0 ?? 0, 3)

        // A shorter section renumbers from 1 with no gaps.
        let short = ["Chant", "Dancing"]
        expect("a short section numbers from one", numbered(short).map(\.0), [1, 2])
        expect("every category has exactly one number",
               Set(numbered(gameplay).map(\.0)).count, gameplay.count)

        // Which keys the flow takes. This is the gate every key passes through before any
        // of the above runs, and leaving digits out of the categories step meant typing 1
        // fell through to the transport keys and shuttled the clip instead — a key doing
        // something else entirely, which is worse than it doing nothing.
        expectTrue("a digit is taken at the bench",
                   FlowKeyState.claims("3", stage: .players, shift: false))
        expectTrue("a digit is taken at the categories",
                   FlowKeyState.claims("3", stage: .categories, shift: false))
        expectTrue("but never at the clips, where 1 and 3 shuttle",
                   !FlowKeyState.claims("3", stage: .clips, shift: false))
        expectTrue("a letter is taken at the categories",
                   FlowKeyState.claims("s", stage: .categories, shift: false))
        expectTrue("a letter is not taken at the bench",
                   !FlowKeyState.claims("s", stage: .players, shift: false))
        expectTrue("space is never taken, so it still plays and pauses",
                   !FlowKeyState.claims("space", stage: .categories, shift: false))
        expectTrue("delete is taken at the categories, to backspace a number",
                   FlowKeyState.claims("delete", stage: .categories, shift: false))
        expectTrue("escape is left alone at the clips, for full screen",
                   !FlowKeyState.claims("escape", stage: .clips, shift: false))
        expectTrue("shift-down is left to the clip list",
                   !FlowKeyState.claims("down", stage: .clips, shift: true))

        // The subjects key. Bound rather than written in, so it has to be claimed by asking
        // the bindings — and only at the bench, which is where it does anything.
        let subjectsKey = Shortcuts.shared.combo(.subjectsOnly).key
        expectTrue("the subjects key has a binding", !subjectsKey.isEmpty)
        expectTrue("it is taken at the bench",
                   FlowKeyState.claims(subjectsKey, stage: .players, shift: false))
        expectTrue("but not at the categories",
                   !FlowKeyState.claims(subjectsKey, stage: .categories, shift: false))
        expectTrue("and not at the clips",
                   !FlowKeyState.claims(subjectsKey, stage: .clips, shift: false))
        expectTrue("it is answered by the bindings, not a hard-coded key",
                   Shortcuts.shared.isBound(subjectsKey, to: .subjectsOnly))

        // It lives outside the transport group, so the transport can never see it — which is
        // what stops a rebind to a letter or digit stealing a shuttle key.
        expect("it is a flow action", ShortcutAction.subjectsOnly.group, .flow)
        expectTrue("so the transport never resolves it",
                   Shortcuts.shared.reviewAction(forKey: subjectsKey) == nil)

        // The bench filter itself: subjects in, players out, and never both filters at once.
        let bench = [Player(teamID: "jets", number: "26", name: "Blake Wheeler"),
                     Player(teamID: "jets", number: "33", name: "Dustin Byfuglien"),
                     Subjects.entry("Mascot"),
                     Subjects.entry("Crowd")]
        let onlySubjects = bench.filter(\.isSubject)
        expect("every subject survives", onlySubjects.count, 2)
        expect("and it is all of them, not one",
               Set(onlySubjects.map(\.name)), ["Mascot", "Crowd"])
        expectTrue("no player survives", !onlySubjects.contains { !$0.isSubject })
        expect("the players are what's left behind",
               bench.filter { !$0.isSubject }.count, 2)

        // A number filter and the subjects filter would leave nothing, since subjects have
        // no number — which is why one turns the other off rather than stacking.
        expect("subjects have no number to match",
               onlySubjects.filter { $0.number.hasPrefix("2") }.count, 0)

        // Whether a key can be bound at all. This gate used to stop at 0x7F — ASCII only —
        // which made the default subjects key dead on the keyboard it was chosen for: § is
        // U+00A7, so it was refused, while the ` in the same place on a US layout passed.
        func usable(_ s: Unicode.Scalar) -> Bool { KeyCombo.isUsableKeyCharacter(s) }

        expectTrue("§ can be bound", usable("§"))
        expectTrue("` can be bound", usable("`"))
        expectTrue("an ordinary letter can be bound", usable("k"))
        expectTrue("a digit can be bound", usable("7"))
        expectTrue("punctuation can be bound", usable("["))
        expectTrue("£ can be bound", usable("£"))
        expectTrue("an accented letter can be bound", usable("é"))

        expectTrue("a control character cannot", !usable("\u{01}"))
        expectTrue("delete cannot", !usable("\u{7F}"))
        expectTrue("a C1 control cannot", !usable("\u{90}"))
        expectTrue("an arrow key's private-use scalar cannot", !usable("\u{F700}"))
        expectTrue("nor the end of that block", !usable("\u{F8FF}"))

        // The default has to survive the gate it's matched through, or the key does nothing
        // and nothing says why.
        let defaultKey = Shortcuts.shared.combo(.subjectsOnly).key
        expectTrue("the default subjects key is bindable",
                   defaultKey.unicodeScalars.allSatisfy(usable))
        expectTrue("and it reads back as itself", !Shortcuts.shared.display(.subjectsOnly).isEmpty)

        // What may be bound to the subjects key. Its own group, with its own rules: a bare
        // press like a review key, but it also must not take a digit, because digits are the
        // bench's shirt-number filter and the clash would be silent — the key would work and
        // the number it shadowed would quietly stop.
        func refused(_ combo: KeyCombo) -> Bool {
            Shortcuts.refusal(for: combo, group: .flow) != nil
        }
        expectTrue("§ is allowed", !refused(KeyCombo(key: "§")))
        expectTrue("a backtick is allowed", !refused(KeyCombo(key: "`")))
        expectTrue("a letter is allowed", !refused(KeyCombo(key: "m")))
        expectTrue("a digit is refused", refused(KeyCombo(key: "4")))
        expectTrue("Tab is refused", refused(KeyCombo(key: "tab")))
        expectTrue("Return is refused", refused(KeyCombo(key: "return")))
        expectTrue("an arrow is refused", refused(KeyCombo(key: "left")))
        expectTrue("Space is refused", refused(KeyCombo(key: "space")))
        expectTrue("Delete is refused", refused(KeyCombo(key: "delete")))
        expectTrue("Escape is refused", refused(KeyCombo(key: "escape")))
        expectTrue("a modifier is refused", refused(KeyCombo(key: "m", command: true)))
        expectTrue("an empty key is refused", refused(KeyCombo(key: "")))

        // And the default it ships with has to pass its own rules.
        expectTrue("the shipped default is allowed",
                   !refused(Shortcuts.shared.combo(.subjectsOnly)))

        // Clearing tags on a key press. A review key, so it works at every step of the flow
        // rather than only where the flow is looking — and it must not be claimed by the
        // flow, or it would never reach the transport handler that runs it.
        let clearKey = Shortcuts.shared.combo(.clearTags).key
        expectTrue("it has a binding", !clearKey.isEmpty)
        expect("it is a review action", ShortcutAction.clearTags.group, .review)
        expectTrue("so the transport resolves it",
                   Shortcuts.shared.reviewAction(forKey: clearKey) == .clearTags)
        for stage in [TagStage.clips, .players, .categories] {
            expectTrue("the flow leaves it alone at \(stage)",
                       !FlowKeyState.claims(clearKey, stage: stage, shift: false))
        }
        expectTrue("its own default passes the review rules",
                   Shortcuts.refusal(for: Shortcuts.shared.combo(.clearTags),
                                     group: .review) == nil)

        // And it must not be sitting on another action's key, which would make one of the
        // two silently stop working.
        var seen: [String: ShortcutAction] = [:]
        var clashes: [String] = []
        for action in ShortcutAction.allCases where action.group == .review {
            for combo in Shortcuts.shared.combos(action) {
                if let other = seen[combo.key], other != action {
                    clashes.append("\(combo.key): \(other) and \(action)")
                }
                seen[combo.key] = action
            }
        }
        expect("no two review keys share a binding", clashes, [])

        // Clearing tags needs clips picked by hand. `dragClips` falls back to everything on
        // screen when nothing is selected, which suits exporting and marking — but with the
        // warning turned off that fallback would put "wipe every tag on screen" one keystroke
        // away, so the tag-clearing scope refuses it instead.
        func clearScope(selected: [String], tagged: Set<String>, visible: [String]) -> [String] {
            guard !selected.isEmpty else { return [] }
            return visible.filter { selected.contains($0) && tagged.contains($0) }
        }
        let shown = ["a", "b", "c", "d"]
        let tagged: Set<String> = ["a", "c"]

        expect("nothing selected clears nothing",
               clearScope(selected: [], tagged: tagged, visible: shown), [])
        expect("a selection clears only its tagged clips",
               clearScope(selected: ["a", "b"], tagged: tagged, visible: shown), ["a"])
        expect("a selection with no tags clears nothing",
               clearScope(selected: ["b", "d"], tagged: tagged, visible: shown), [])
        expect("selecting everything is still only the tagged ones",
               clearScope(selected: shown, tagged: tagged, visible: shown), ["a", "c"])

        // The thing that must never happen, whatever the card looks like.
        for visible in [[], ["a"], shown] {
            expectTrue("nothing selected never reaches a clip (\(visible.count) shown)",
                       clearScope(selected: [], tagged: tagged, visible: visible).isEmpty)
        }

        // The clear-tags warning, and the box that turns it off.
        //
        // Default-on has to come from the absence of the stored key, not from reading it:
        // `bool(forKey:)` answers false for "never set" and for "set to false" alike, so
        // reading it would quietly default the warning off on a fresh install.
        func warnOnLaunch(stored: Bool?) -> Bool { stored ?? true }
        expectTrue("a fresh install warns", warnOnLaunch(stored: nil))
        expectTrue("one that turned it off stays off", !warnOnLaunch(stored: false))
        expectTrue("one that turned it back on warns", warnOnLaunch(stored: true))

        // The suppression box only counts when the removal went ahead. Ticking it and then
        // cancelling means "not this one" at least as much as "stop asking".
        func warnAfter(_ warning: Bool, ticked: Bool, confirmed: Bool) -> Bool {
            guard warning, confirmed, ticked else { return warning }
            return false
        }
        expectTrue("tick and confirm turns it off",
                   !warnAfter(true, ticked: true, confirmed: true))
        expectTrue("tick and cancel leaves it on",
                   warnAfter(true, ticked: true, confirmed: false))
        expectTrue("confirm without ticking leaves it on",
                   warnAfter(true, ticked: false, confirmed: true))
        expectTrue("cancel without ticking leaves it on",
                   warnAfter(true, ticked: false, confirmed: false))
        expectTrue("with the warning already off it stays off",
                   !warnAfter(false, ticked: false, confirmed: true))

        // What actually happens on a press, warning or not. The removal must be reachable
        // either way, and must never happen on a cancel.
        func removes(warning: Bool, confirmed: Bool) -> Bool {
            warning ? confirmed : true
        }
        expectTrue("no warning removes straight away", removes(warning: false, confirmed: false))
        expectTrue("warning plus confirm removes", removes(warning: true, confirmed: true))
        expectTrue("warning plus cancel removes nothing",
                   !removes(warning: true, confirmed: false))

        // Hold versus toggle. Modelled rather than driven, because the real thing needs a
        // key-up event — but the rule is the whole of the difference.
        func down(_ on: Bool, hold: Bool) -> Bool { hold ? true : !on }
        func up(_ on: Bool, hold: Bool) -> Bool { hold ? false : on }

        expectTrue("toggle: down turns it on", down(false, hold: false))
        expectTrue("toggle: down again turns it off", !down(true, hold: false))
        expectTrue("toggle: up changes nothing", up(true, hold: false))
        expectTrue("toggle: up on an off filter changes nothing", !up(false, hold: false))

        expectTrue("hold: down turns it on", down(false, hold: true))
        expectTrue("hold: down again leaves it on, so repeats are harmless",
                   down(true, hold: true))
        expectTrue("hold: up turns it off", !up(true, hold: true))
        expectTrue("hold: up with nothing on stays off", !up(false, hold: true))

        // Held down and released, however many repeats arrive in between, ends off. A hold
        // that could end stuck on would leave the bench showing no players with no sign why.
        for repeats in 0...5 {
            var on = false
            on = down(on, hold: true)
            for _ in 0..<repeats { on = down(on, hold: true) }
            on = up(on, hold: true)
            expectTrue("hold with \(repeats) repeat(s) ends off", !on)
        }

        // Tapping in toggle mode leaves it on — that being the point of a toggle.
        var toggled = false
        toggled = down(toggled, hold: false)
        toggled = up(toggled, hold: false)
        expectTrue("toggle: a tap leaves it on", toggled)

        // Moving a category between sections. An existing library migrates into one
        // section, so this is the path every long list has to go through to get sorted —
        // and the thing it must never do is lose a word or leave it in two places.
        func move(_ name: String, to target: String,
                  in sections: [CategorySection]) -> [CategorySection] {
            guard let from = sections.firstIndex(where: { $0.items.contains(name) }),
                  let to = sections.firstIndex(where: { $0.id == target }),
                  from != to
            else { return sections }
            var out = sections
            out[from].items.removeAll { $0 == name }
            out[to].items.append(name)
            return out
        }

        let before = CategorySection.defaults
        let after = move("Goal", to: "misc", in: before)
        expect("the word left its old section",
               after.first { $0.id == "gameplay" }?.items.contains("Goal") ?? true, false)
        expect("and arrived in the new one",
               after.first { $0.id == "misc" }?.items.contains("Goal") ?? false, true)
        expect("nothing was lost", Set(after.flatMap(\.items)), Set(before.flatMap(\.items)))
        expect("and nothing is in two places",
               Set(after.flatMap(\.items)).count, after.flatMap(\.items).count)

        expect("moving to its own section changes nothing",
               move("Goal", to: "gameplay", in: before).flatMap(\.items),
               before.flatMap(\.items))
        expect("moving a word that isn't there changes nothing",
               move("Zamboni", to: "misc", in: before).flatMap(\.items),
               before.flatMap(\.items))
        expect("moving to a section that isn't there changes nothing",
               move("Goal", to: "nowhere", in: before).flatMap(\.items),
               before.flatMap(\.items))

        // Emptying one section entirely still leaves every word somewhere.
        var shuffled = before
        for word in before.first(where: { $0.id == "gameplay" })?.items ?? [] {
            shuffled = move(word, to: "misc", in: shuffled)
        }
        expect("a whole section can be emptied",
               shuffled.first { $0.id == "gameplay" }?.items.isEmpty ?? false, true)
        expect("with every word still accounted for",
               Set(shuffled.flatMap(\.items)), Set(before.flatMap(\.items)))
        expect("and the sections themselves remain", shuffled.count, before.count)

        expect("an index past the end clamps", clamp(7, 3), 2)
        expect("a negative one clamps", clamp(-2, 3), 0)
        expect("no sections is still safe", clamp(5, 0), 0)
    }

    // MARK: - One-off categories
    //
    // A word used once on one card shouldn't silt up the category list forever, so a category
    // that isn't in the permanent list is kept as a capped, newest-first one-off instead. The
    // ways that goes wrong are all quiet: a word in both lists draws twice in the grid and
    // the cursor stops on it twice; an uncapped list is just the permanent list again; and a
    // one-off outranking a real category would name a goal clip after the dancing in it.
    //
    // `noteRecent` is on the live library, so the rule is modelled here against a plain array
    // and pinned to the real cap.

    private static func oneOffCategories() {
        section("One-off categories")

        func note(_ name: String, into recents: [String], permanent: [String]) -> [String] {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty,
                  !permanent.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
            else { return recents }
            var out = recents.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
            out.insert(clean, at: 0)
            return Array(out.prefix(TagLibrary.recentLimit))
        }

        let permanent = TagLibrary.defaultCategories
        expect("a one-off is recorded", note("Dancing", into: [], permanent: permanent), ["Dancing"])
        expect("a real category is not", note("Goal", into: [], permanent: permanent), [])
        expect("nor one in a different case",
               note("goal", into: [], permanent: permanent), [])
        expect("blank is ignored", note("   ", into: [], permanent: permanent), [])

        // Using one again moves it to the front rather than repeating it.
        let twice = note("Dancing", into: note("Clapping", into: ["Dancing"], permanent: permanent),
                         permanent: permanent)
        expect("reusing moves it to the front", twice, ["Dancing", "Clapping"])
        expect("and never duplicates", Set(twice).count, twice.count)

        // The cap: the oldest falls off, which is what stops this becoming the thing it
        // replaces.
        var recents: [String] = []
        for n in 1...(TagLibrary.recentLimit + 5) {
            recents = note("Word \(n)", into: recents, permanent: permanent)
        }
        expect("the list stays capped", recents.count, TagLibrary.recentLimit)
        expect("the newest is first", recents.first ?? "none",
               "Word \(TagLibrary.recentLimit + 5)")
        expectTrue("and the oldest fell off", !recents.contains("Word 1"))

        // Nothing may appear in both lists, because the grid draws the two end to end.
        let all = permanent + recents
        expect("no category is listed twice", Set(all).count, all.count)

        // Promoting: it has to leave the one-offs in the same breath it joins the list.
        let promoted = permanent + ["Dancing"]
        let leftover = ["Dancing", "Clapping"].filter { word in
            !promoted.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
        }
        expect("a kept category leaves the one-offs", leftover, ["Clapping"])
        let afterPromote = promoted + leftover
        expect("so it still isn't listed twice", Set(afterPromote).count, afterPromote.count)

        // Priority: permanent beats passing-through, whatever order they were applied.
        let priority = permanent + ["Dancing"]
        func rank(_ c: String) -> Int { priority.firstIndex(of: c) ?? Int.max }
        expectTrue("a real category outranks a one-off", rank("Goal") < rank("Dancing"))
        expectTrue("a one-off still outranks something unlisted",
                   rank("Dancing") < rank("Never seen"))
    }

    // MARK: - Subjects
    //
    // A subject rides in the bench as a `Player` with no number and a reserved team id. The
    // two ways that can go wrong are both silent: two subjects sharing an id, which is a
    // duplicate in a SwiftUI grid rather than anything that looks like an error; and a
    // subject's reserved id reaching a tag's `teamID`, where nothing would ever match it
    // again and the filename would carry a team that doesn't exist.

    private static func subjects() {
        section("Subjects")

        // Every default has to produce a distinct bench id.
        let ids = Subjects.defaults.map { Subjects.entry($0).id }
        expect("every default subject has its own id", Set(ids).count, ids.count)

        let mascot = Subjects.entry("Mascot")
        expect("the id is namespaced", mascot.id, "subject:mascot/")
        expect("and the name survives", mascot.name, "Mascot")
        expect("with no number", mascot.number, "")
        expectTrue("it knows it's a subject", mascot.isSubject)

        // The label is what the bench draws. A numberless entry must read as a bare name,
        // not as "#  Mascot".
        expect("it labels as a bare name", mascot.label, "Mascot")

        // And a real player must not be mistaken for one.
        let player = Player(teamID: "winnipeg-jets-alumni", number: "26", name: "Blake Wheeler")
        expectTrue("a player is not a subject", !player.isSubject)
        expect("a player still labels with its number", player.label, "#26  Blake Wheeler")

        // A team whose own slug begins with the marker would be indistinguishable from a
        // subject. The prefix ends in a colon, which `Team.slug` strips, so no real team id
        // can start with it.
        expectTrue("no real team id can look like a subject",
                   !Team.slug("Subject: Mascot").hasPrefix(Subjects.teamIDPrefix))
        expectTrue("nor one actually called Subjects",
                   !Team.slug("Subjects").hasPrefix(Subjects.teamIDPrefix))

        // Two subjects differing only in case or punctuation would share a slug, and so an
        // id. `addSubject` is what refuses them; this pins the rule it refuses on.
        expect("case folds into one slug", Team.slug("Mascot"), Team.slug("MASCOT"))
        expect("punctuation folds too", Team.slug("Mic E. Moose"), "mic-e-moose")

        // The number filter: typing a digit means you're after a person, so subjects go.
        let bench = [player, mascot]
        let filtered = bench.filter { $0.number.hasPrefix("2") }
        expect("typing a number hides the subjects", filtered.count, 1)
        expect("and keeps the player", filtered.first?.name ?? "none", "Blake Wheeler")

        // A library written before subjects existed has no key at all, and must come back
        // with the starting set rather than an empty bench tail — while one deliberately
        // emptied stays empty. That's the nil-versus-[] distinction in the load path.
        let old: [String]? = nil
        let emptied: [String]? = []
        expect("an old library gets the defaults", (old ?? Subjects.defaults).count,
               Subjects.defaults.count)
        expect("an emptied one stays empty", (emptied ?? Subjects.defaults).count, 0)
    }

    // MARK: - Adding a team
    //
    // This one shipped broken — found in use, not by reading — and is why the search for a
    // free name moved into `TagLibrary`, beside the guard it has to agree with.
    //
    // A team keeps its id for life, because tags are keyed to it. So the "New team" that the
    // + button creates still has the id `new-team` after you rename it to a real club. The
    // editor used to look for a free *name*, find "New team" unused, and hand it to `addTeam`
    // — which refuses on the *id* and returned nil. The + button did nothing from then on,
    // and the only thing on screen was a stale "Saved." from the save it does first.

    private static func addingTeams() {
        section("Adding a team")

        func team(_ id: String, _ name: String) -> Team {
            Team(id: id, name: name, code: nil, league: nil, players: [])
        }

        expect("an empty library gets the plain name",
               TagLibrary.freeTeamName(in: []), "New team")

        // The bug, exactly: id still `new-team`, name long since changed.
        let renamed = [team("new-team", "Dauphin Kings")]
        expect("a renamed team's id doesn't block the next add",
               TagLibrary.freeTeamName(in: renamed), "New team 2")

        // And it keeps working, rather than only surviving one more press.
        let twiceRenamed = [team("new-team", "Dauphin Kings"),
                            team("new-team-2", "Virden Oil Capitals")]
        expect("twice renamed, still fine",
               TagLibrary.freeTeamName(in: twiceRenamed), "New team 3")

        // A team actually still called "New team" is caught by name as it always was.
        expect("an unrenamed New team is skipped",
               TagLibrary.freeTeamName(in: [team("new-team", "New team")]), "New team 2")

        // Case shouldn't matter, by name or by id.
        expect("a differently-cased name is still taken",
               TagLibrary.freeTeamName(in: [team("whatever", "NEW TEAM")]), "New team 2")

        // Unrelated teams don't push the number along.
        expect("unrelated teams are ignored",
               TagLibrary.freeTeamName(in: [team("dauphin-kings", "Dauphin Kings")]),
               "New team")

        // The name it returns has to be one `addTeam` will actually accept — which is the
        // agreement that broke. Re-check it against `addTeam`'s own guard.
        for teams in [[], renamed, twiceRenamed, [team("new-team", "New team")]] {
            let name = TagLibrary.freeTeamName(in: teams)
            let id = Team.slug(name)
            let wouldBeRefused = teams.contains {
                $0.id == id || $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            expectTrue("\"\(name)\" is a name addTeam would accept", !wouldBeRefused)
        }

        // Importing a CSV for a team that already exists under a different id — the second
        // half of the same bug. The + button made a team, it got renamed, and a CSV for that
        // same club then arrived as a separate team of the same name. Two teams sharing a
        // name is a state the editor won't save, so both became uneditable.
        let renamedToClub = [team("new-team", "Winnipeg Jets Alumni")]
        expect("an import finds the renamed team by name",
               TagLibrary.importTarget(slug: "winnipeg-jets-alumni",
                                       name: "Winnipeg Jets Alumni",
                                       in: renamedToClub)?.id ?? "nothing",
               "new-team")

        expect("a normal import still matches on the id",
               TagLibrary.importTarget(slug: "dauphin-kings",
                                       name: "Dauphin Kings",
                                       in: [team("dauphin-kings", "Dauphin Kings")])?.id ?? "nothing",
               "dauphin-kings")

        expect("case doesn't stop the name match",
               TagLibrary.importTarget(slug: "winnipeg-jets-alumni",
                                       name: "WINNIPEG JETS ALUMNI",
                                       in: renamedToClub)?.id ?? "nothing",
               "new-team")

        expectTrue("a genuinely new team matches nothing",
                   TagLibrary.importTarget(slug: "virden-oil-capitals",
                                           name: "Virden Oil Capitals",
                                           in: renamedToClub) == nil)

        // The id wins over the name, so re-importing can still rename a team in place rather
        // than being dragged to whichever other team happens to use the new name.
        let both = [team("dauphin-kings", "Dauphin Kings"), team("new-team", "Dauphin Kings II")]
        expect("the id is preferred over the name",
               TagLibrary.importTarget(slug: "dauphin-kings",
                                       name: "Dauphin Kings II",
                                       in: both)?.id ?? "nothing",
               "dauphin-kings")

        // The slug, since the whole bug turned on what it does to a name.
        expect("the slug of the default name", Team.slug("New team"), "new-team")
        expect("the slug of the numbered one", Team.slug("New team 2"), "new-team-2")
        expect("punctuation and case collapse", Team.slug("St. Mary's U18 (A)"), "st-mary-s-u18-a")
    }

    // MARK: - Keeping the Mac awake
    //
    // A power assertion that's taken and never released is invisible: no error, no UI, the
    // machine just stops sleeping until Keeper quits. The two ways to get there are a job
    // that returns early without releasing, and two overlapping jobs where the first to
    // finish releases the hold the second still needs. Deriving the answer from both flags
    // rules both out, which is what's checked here.

    private static func sleepHold() {
        section("Keeping the Mac awake")

        func rule(_ copying: Bool, _ verifying: Bool, _ enabled: Bool = true) -> Bool {
            SleepGuard.shouldHold(copying: copying, verifying: verifying, enabled: enabled)
        }

        expect("neither job, no hold", rule(false, false), false)
        expect("a copy holds", rule(true, false), true)
        expect("a verify holds", rule(false, true), true)
        expect("both hold", rule(true, true), true)

        // The setting wins over everything. Switched off, no job holds the Mac awake — and
        // switched off with nothing running must not somehow hold it either.
        expect("switched off, a copy doesn't hold", rule(true, false, false), false)
        expect("switched off, a verify doesn't hold", rule(false, true, false), false)
        expect("switched off, both don't hold", rule(true, true, false), false)
        expect("switched off and idle, nothing holds", rule(false, false, false), false)

        // Overlapping jobs, which is what a begin/end pair at each job site would get wrong.
        var copying = false
        var verifying = false
        func held() -> Bool { rule(copying, verifying) }

        copying = true
        expectTrue("a copy takes the hold", held())
        verifying = true
        expectTrue("a verify starting keeps it", held())
        copying = false
        expectTrue("the copy finishing doesn't release it", held())
        verifying = false
        expectTrue("and the verify finishing does", !held())

        // The switch, mid-transfer, which is the case it exists for: off lets go at once and
        // back on takes the hold again, both while the same copy keeps running.
        var enabled = true
        copying = true
        expectTrue("a copy with the setting on holds", rule(copying, verifying, enabled))
        enabled = false
        expectTrue("switching off mid-copy lets go", !rule(copying, verifying, enabled))
        enabled = true
        expectTrue("switching back on mid-copy takes it again",
                   rule(copying, verifying, enabled))
        copying = false
        expectTrue("and the copy ending releases it", !rule(copying, verifying, enabled))

        // The real assertion, which the `didSet` relies on being idempotent both ways. This
        // balances itself — it ends holding nothing — and the process exits immediately after
        // these checks, which would release it regardless.
        expectTrue("taking the hold reports a change", SleepGuard.shared.keepAwake(true))
        expectTrue("it is held", SleepGuard.shared.isHeld)
        expectTrue("taking it twice is a no-op", !SleepGuard.shared.keepAwake(true))
        expectTrue("releasing reports a change", SleepGuard.shared.keepAwake(false))
        expectTrue("releasing twice is a no-op", !SleepGuard.shared.keepAwake(false))
        expectTrue("nothing is left held", !SleepGuard.shared.isHeld)
    }

    // MARK: - The tutorial
    //
    // The tour itself can't be run from here — it's a sheet — but the content can be read
    // back, and the two ways it can quietly go wrong are both content. A step edited down to
    // an empty string still draws, as a blank page with a Next button. And every key it quotes
    // comes from `Shortcuts`, so a binding dropped from the defaults would have the tutorial
    // confidently teaching "—".

    // MARK: - Both teams
    //
    // Two at most, one league. A pair across leagues is a mis-click in a long menu, and
    // three benches was never something the panel could show.

    // MARK: - Re-importing a roster
    //
    // A download used to replace a team outright, hand edits and all. These are the two
    // rules the review is built on: what counts as a change, and that Merge only ever adds.

    private static func reimport() {
        section("Re-importing a roster")
        func p(_ number: String, _ name: String, _ position: String = "") -> Player {
            Player(teamID: "jets", number: number, name: name, position: position)
        }
        let mine = [p("9", "Adam Lowry", "Forward"), p("33", "Dylan Samberg", "Defence"),
                    p("37", "Connor Hellebuyck", "Goalie")]
        let theirs = [p("9", "Adam Lowry", "Forward"), p("33", "Dylan Samburg", "Defence"),
                      p("55", "Mark Scheifele", "Forward")]
        let changes = TagLibrary.rosterChanges(old: mine, new: theirs)
        expect("a new number is added", changes.added.map(\.number), ["55"])
        expect("a missing number is gone", changes.removed.map(\.number), ["37"])
        expect("a different name is a change", changes.changed.map(\.new.number), ["33"])
        expect("the summary counts all three", changes.summary, "1 new · 1 gone · 1 changed")
        expectTrue("the same list is no change",
                   TagLibrary.rosterChanges(old: mine, new: mine).isEmpty)
        expectTrue("a blank position in the new list isn't a change",
                   TagLibrary.rosterChanges(old: mine, new: mine.map { p($0.number, $0.name) }).isEmpty)
        expect("a new position is", TagLibrary.rosterChanges(
                   old: [p("9", "Adam Lowry", "Forward")], new: [p("9", "Adam Lowry", "Defence")])
                   .changed.count, 1)

        let merged = TagLibrary.merged(existing: mine, incoming: theirs, teamID: "jets")
        expect("merge keeps everyone you have and adds the new",
               merged.map(\.number), ["9", "33", "37", "55"])
        expect("merge keeps your spelling", merged.first { $0.number == "33" }?.name, "Dylan Samberg")
        expect("merge keeps a player the new list dropped",
               merged.first { $0.number == "37" }?.name, "Connor Hellebuyck")
        expect("merge stamps additions with the real team id",
               TagLibrary.merged(existing: [], incoming: [Player(teamID: "slug", number: "1", name: "A")],
                                 teamID: "new-team").first?.teamID, "new-team")

        // Which benches an import brings into play.
        let leagues = ["a": "NHL", "b": "NHL", "c": "NHL", "x": "MJHL"]
        let league: (String) -> String = { leagues[$0] ?? TagLibrary.ungroupedLeague }
        func after(_ current: [String], _ id: String, shown: String? = nil, both: Bool = true) -> [String] {
            TeamPick.afterImport(current: current, imported: id, shown: shown,
                                 bothTeams: both, league: league)
        }
        expect("one team: an import swaps", after(["a", "b"], "c", both: false), ["c"])
        expect("both: a team in play stays as it is", after(["a", "b"], "b", shown: "a"), ["a", "b"])
        expect("both: a second joins the first", after(["a"], "b"), ["a", "b"])
        expect("both: from another league it comes in alone", after(["a"], "x"), ["x"])
        expect("both: it replaces the bench on screen", after(["a", "b"], "c", shown: "a"), ["c", "b"])
        expect("in that bench's place", after(["a", "b"], "c", shown: "b"), ["a", "c"])
        expect("both: a pair it can't join is replaced", after(["a", "b"], "x", shown: "a"), ["x"])
        expect("nothing in play: it comes in", after([], "a"), ["a"])
    }

    private static func clipRange() {
        section("Shift-arrow ranges")
        let ids = ["a", "b", "c", "d", "e"]
        func ext(_ anchor: String?, _ cursor: String?, _ delta: Int) -> [String]? {
            ClipRange.extend(ids, anchor: anchor, cursor: cursor, delta: delta)?.selection
        }
        expect("⇧↓ from one clip takes the next", ext("b", "b", 1), ["b", "c"])
        expect("again grows it", ext("b", "c", 1), ["b", "c", "d"])
        expect("⇧↑ shrinks it back toward the anchor", ext("b", "d", -1), ["b", "c"])
        expect("and past the anchor grows the other way", ext("b", "b", -1), ["a", "b"])
        expect("at the bottom it stops", ext("b", "e", 1) == nil, true)
        expect("at the top it stops", ext("a", "a", -1) == nil, true)
        expect("with nothing selected ⇧↓ starts at the top", ext(nil, nil, 1), ["a"])
        expect("and ⇧↑ at the bottom", ext(nil, nil, -1), ["e"])
        expect("an anchor gone from the filter starts from the cursor", ext("zz", "c", 1), ["c", "d"])
        expect("the cursor moves with it",
               ClipRange.extend(ids, anchor: "b", cursor: "c", delta: 1)?.cursor, "d")
        expect("the anchor stays put",
               ClipRange.extend(ids, anchor: "b", cursor: "c", delta: 1)?.anchor, "b")
    }

    private static func benchStops() {
        section("The bench pills")
        let stops: [BenchStop] = [.team("a"), .team("b"), .subjects]
        expect("→ from the first team", BenchStop.step(stops, from: .team("a"), forward: true), .team("b"))
        expect("→ from the last team reaches the subjects",
               BenchStop.step(stops, from: .team("b"), forward: true), .subjects)
        expect("→ from the subjects wraps to the first team",
               BenchStop.step(stops, from: .subjects, forward: true), .team("a"))
        expect("← from the first team wraps to the subjects",
               BenchStop.step(stops, from: .team("a"), forward: false), .subjects)
        let one: [BenchStop] = [.team("a"), .subjects]
        expect("one roster still has somewhere to go",
               BenchStop.step(one, from: .team("a"), forward: true), .subjects)
        expect("and back", BenchStop.step(one, from: .subjects, forward: true), .team("a"))
        expect("a stop that's gone counts as the first",
               BenchStop.step(stops, from: .team("gone"), forward: true), .team("b"))
    }

    private static func teamPick() {
        section("Both teams")
        let leagues = ["a": "NHL", "b": "NHL", "c": "NHL", "x": "MJHL"]
        let league: (String) -> String = { leagues[$0] ?? TagLibrary.ungroupedLeague }
        func pick(_ current: [String], _ id: String, on: Bool = true, both: Bool = true)
            -> (ids: [String], refusal: TeamPick.Refusal?) {
            TeamPick.apply(current: current, id: id, on: on, bothTeams: both, league: league)
        }

        expect("off: a tick swaps", pick(["a"], "b", both: false).ids, ["b"])
        expect("off: across leagues is fine, it's a swap", pick(["a"], "x", both: false).ids, ["x"])
        expect("on: a second joins", pick(["a"], "b").ids, ["a", "b"])
        expect("on: the first is just picked", pick([], "x").ids, ["x"])
        expect("on: another league is refused", pick(["a"], "x").refusal, .otherLeague(have: "NHL"))
        expect("and changes nothing", pick(["a"], "x").ids, ["a"])
        expect("on: a third is refused", pick(["a", "b"], "c").refusal, .full)
        expect("ticking one already in is harmless", pick(["a", "b"], "a").ids, ["a", "b"])
        expect("unticking takes it out", pick(["a", "b"], "a", on: false).ids, ["b"])
        expect("unticking makes room again", pick(["b"], "c").ids, ["b", "c"])
        expect("unfiled teams pair with each other", pick(["u1"], "u2").ids, ["u1", "u2"])
        expect("but not with a filed one", pick(["u1"], "a").refusal,
               .otherLeague(have: TagLibrary.ungroupedLeague))

        expect("sanitize off keeps the first", TeamPick.sanitize(["a", "b"], bothTeams: false, league: league), ["a"])
        expect("sanitize drops a cross-league pair", TeamPick.sanitize(["a", "x"], bothTeams: true, league: league), ["a"])
        expect("sanitize keeps a good pair", TeamPick.sanitize(["a", "b"], bothTeams: true, league: league), ["a", "b"])
        expect("sanitize trims three to two", TeamPick.sanitize(["a", "x", "b", "c"], bothTeams: true, league: league), ["a", "b"])
        expect("sanitize on nothing", TeamPick.sanitize([], bothTeams: true, league: league), [])
    }

    private static func cameraPresets() {
        section("The camera menu")
        expect("Sony looks for KEEP", CameraPreset.sony.word, "KEEP")
        expect("Other asks for a word", CameraPreset.other.word == nil, true)
        expect("a stored KEEP is Sony", CameraPreset.matching("KEEP"), .sony)
        expect("anything else is Other", CameraPreset.matching("OK"), .other)
        expect("so is nothing", CameraPreset.matching(""), .other)
        expect("every preset has a name", CameraPreset.allCases.filter { $0.name.isEmpty }.count, 0)
    }

    private static func scanSummary() {
        section("The scan summary")
        expect("normal", ScanSummary.text(clips: 12, keeps: 4, withoutSidecar: 0),
               "Found 12 clips, 4 marked KEEP.")
        expect("one clip", ScanSummary.text(clips: 1, keeps: 1, withoutSidecar: 0),
               "Found 1 clip, 1 marked KEEP.")
        expectTrue("no KEEPs points at the flag word",
                   ScanSummary.text(clips: 5, keeps: 0, withoutSidecar: 0).contains("Camera"))
        // The worst case of the lot, measured rather than guessed at: if this outgrows the
        // footer, the truncation eats the middle and the hint goes with it.
        expectTrue("the longest summary stays short",
                   ScanSummary.text(clips: 999, keeps: 0, withoutSidecar: 999).count <= 90)
        expectTrue("no clips at all doesn't blame the flag word",
                   !ScanSummary.text(clips: 0, keeps: 0, withoutSidecar: 0).contains("Camera"))
        expectTrue("videos without sidecars are named, plural",
                   ScanSummary.text(clips: 3, keeps: 1, withoutSidecar: 2).contains("2 videos with no XML"))
        expectTrue("and singular",
                   ScanSummary.text(clips: 3, keeps: 1, withoutSidecar: 1).contains("1 video with no XML"))
        expectTrue("even when nothing else was found",
                   ScanSummary.text(clips: 0, keeps: 0, withoutSidecar: 4).contains("4 videos with no XML"))
    }

    private static func welcome() {
        section("The tutorial")

        expectTrue("there are steps at all", !WelcomeTour.steps.isEmpty)

        var blank = 0
        for step in WelcomeTour.steps {
            if step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blank += 1 }
            if step.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blank += 1 }
        }
        expect("no step is blank", blank, 0)

        let titles = WelcomeTour.steps.map(\.title)
        expect("no step is duplicated", Set(titles).count, titles.count)

        // Every key the tour quotes has to resolve to something printable. `display` returns
        // "—" for an action with no binding at all, which is what you'd see if a default were
        // dropped — the tutorial would still render, just teaching nothing.
        //
        // This reads the real `Shortcuts`, which is the one place these checks touch live
        // state. It only ever reads: `Shortcuts.init` loads from defaults and writes nothing,
        // and the answer doesn't depend on your own remapping, because an emptied binding
        // falls back to `Shortcuts.defaults`. Nothing to pass in, so nothing is stubbed.
        var unbound: [String] = []
        for step in WelcomeTour.steps {
            guard let key = step.key else { continue }
            if Shortcuts.shared.display(key) == "—" { unbound.append(step.title) }
        }
        expect("every key the tour quotes has a binding", unbound, [])

        // The tour is the short version; the guide is the long one, and a tour that ends
        // without saying where it is leaves people stuck at the edge of what it taught.
        expect("it ends by pointing at the guide",
               WelcomeTour.steps.last?.link?.url == AppInfo.guide, true)

        // Choosing a folder is what gets you off a blank window, so it can't be buried. It's
        // second now rather than first: setting up the KEEP flag happens in the camera before
        // there's a card to choose, and skipping it is how a first scan comes up empty.
        expect("choosing a folder is one of the first two steps",
               WelcomeTour.steps.prefix(2).contains { $0.key == .chooseFolder }, true)
        expect("and setting up the flag comes before it",
               WelcomeTour.steps.first?.title, "Mark clips in camera")
    }

    // MARK: - Pairing sidecars to videos
    //
    // Sony writes a MEDIAPRO.XML at the root of a card listing every clip on it. That index
    // references C0001.MP4 as readily as C0001M01.XML is named after it, so when claims were
    // settled in the order the enumerator reached them, the only thing stopping the index
    // winning was that CLIP/ sorts before MEDIAPRO.XML. Had it won, the clip would have
    // taken the index's KEEP flag and UMID and its real sidecar would have been reported
    // unmatched.

    private static let umidA = "060A2B340101010501010D4313000000AAAA1111BBBB2222"
    private static let umidB = "060A2B340101010501010D4313000000EEEE5555FFFF6666"

    private static func sidecar(umid: String, keep: Bool,
                                created: String = "2026-10-03T11:31:12-06:00") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta>
          <TargetMaterial umidRef="\(umid)"\(keep ? " status=\"KEEP\"" : "")/>
          <CreationDate value="\(created)"/>
        </NonRealTimeMeta>
        """
    }

    private static func index(videos: [String]) -> String {
        let materials = videos.enumerated().map { offset, video in
            "    <Material uri=\"\(video)\" umid=\"INDEXUMID\(offset)\" status=\"KEEP\"/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <MediaProfile>
          <Contents>
        \(materials)
          </Contents>
        </MediaProfile>
        """
    }

    private static func scanner() {
        section("Pairing sidecars to videos")

        guard let root = tempFolder() else {
            failures.append("couldn't make a temporary folder for the scanner checks")
            print("  FAIL couldn't make a temporary folder")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // A card as the camera writes it, with the index claiming KEEP for everything — so
        // a mispairing shows up as a wrong flag as well as a wrong sidecar.
        let m4root = root.appendingPathComponent("PRIVATE/M4ROOT", isDirectory: true)
        let clipFolder = m4root.appendingPathComponent("CLIP", isDirectory: true)
        _ = write(Array(repeating: 0x42, count: 2048), named: "C0001.MP4", in: clipFolder)
        _ = write(sidecar(umid: umidA, keep: true), named: "C0001M01.XML", in: clipFolder)
        _ = write(Array(repeating: 0x42, count: 2048), named: "C0002.MP4", in: clipFolder)
        _ = write(sidecar(umid: umidB, keep: false), named: "C0002M01.XML", in: clipFolder)
        _ = write(index(videos: ["C0001.MP4", "C0002.MP4"]), named: "MEDIAPRO.XML", in: m4root)

        let result = ClipScanner.scan(root: root, keepWord: "KEEP")
        expect("two clips found", result.clips.count, 2)
        expect("sorted by name", result.clips.map(\.name), ["C0001.MP4", "C0002.MP4"])

        let clipOne = result.clips.first { $0.name == "C0001.MP4" }
        let clipTwo = result.clips.first { $0.name == "C0002.MP4" }
        expect("the first clip took its own sidecar",
               clipOne?.xmlURL.lastPathComponent ?? "", "C0001M01.XML")
        expect("the second clip took its own sidecar",
               clipTwo?.xmlURL.lastPathComponent ?? "", "C0002M01.XML")
        expectTrue("the card index never became a clip's sidecar",
                   !result.clips.contains { $0.xmlURL.lastPathComponent == "MEDIAPRO.XML" })
        expect("the first clip is KEEP", clipOne?.isKeep ?? false, true)
        expect("the second is not, whatever the index says", clipTwo?.isKeep ?? true, false)
        expect("the first clip's UMID", clipOne?.umid ?? "", umidA)
        expect("the second clip's UMID", clipTwo?.umid ?? "", umidB)

        // The same thing with the index somewhere that sorts *first*, which is what the old
        // assign-as-you-go code was quietly relying on not happening.
        guard let cardB = tempFolder() else { return }
        defer { try? FileManager.default.removeItem(at: cardB) }

        let clips2 = cardB.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true)
        let aa = cardB.appendingPathComponent("AA", isDirectory: true)
        _ = write(Array(repeating: 0x42, count: 2048), named: "C0001.MP4", in: clips2)
        _ = write(sidecar(umid: umidA, keep: false), named: "C0001M01.XML", in: clips2)
        _ = write(index(videos: ["C0001.MP4"]), named: "INDEX.XML", in: aa)

        let sorted = ClipScanner.scan(root: cardB, keepWord: "KEEP")
        expect("one clip", sorted.clips.count, 1)
        expect("named after beats mentioned by, whatever the file order",
               sorted.clips.first?.xmlURL.lastPathComponent ?? "", "C0001M01.XML")
        expect("so it keeps its own flag", sorted.clips.first?.isKeep ?? true, false)

        // Footage already offloaded and renamed: the video carries the new name, the
        // sidecar still carries the camera's.
        guard let cardC = tempFolder() else { return }
        defer { try? FileManager.default.removeItem(at: cardC) }

        _ = write(Array(repeating: 0x42, count: 2048),
                  named: "C7531_261003_YWP_Marchetti_Goal.MP4", in: cardC)
        _ = write(sidecar(umid: umidA, keep: true), named: "C7531M01.XML", in: cardC)
        _ = write(Array(repeating: 0x42, count: 2048), named: "C0009.MP4", in: cardC)

        let renamed = ClipScanner.scan(root: cardC, keepWord: "KEEP")
        expect("a renamed video still finds its sidecar", renamed.clips.count, 1)
        expect("and it's the renamed one",
               renamed.clips.first?.name ?? "", "C7531_261003_YWP_Marchetti_Goal.MP4")
        expect("a video with no sidecar is reported, not listed",
               renamed.videosWithoutXML.map(\.lastPathComponent), ["C0009.MP4"])

        // A prefix only counts when it ends at a separator, or C753 would claim C7531.
        guard let cardD = tempFolder() else { return }
        defer { try? FileManager.default.removeItem(at: cardD) }

        _ = write(Array(repeating: 0x42, count: 2048), named: "C75311.MP4", in: cardD)
        _ = write(sidecar(umid: umidA, keep: true), named: "C7531M01.XML", in: cardD)

        let prefix = ClipScanner.scan(root: cardD, keepWord: "KEEP")
        expectTrue("C7531 doesn't claim C75311", prefix.clips.isEmpty)
        expect("the sidecar is left unmatched",
               prefix.unmatchedXML.map(\.lastPathComponent), ["C7531M01.XML"])

        // The flag word is configurable, and an empty one can't mark anything.
        guard let cardE = tempFolder() else { return }
        defer { try? FileManager.default.removeItem(at: cardE) }

        _ = write(Array(repeating: 0x42, count: 2048), named: "A001.MOV", in: cardE)
        _ = write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ClipMeta><TargetMaterial umidRef="\(umidA)" status="PICK"/></ClipMeta>
        """, named: "A001M01.XML", in: cardE)

        expect("another flag word is honoured",
               ClipScanner.scan(root: cardE, keepWord: "PICK").clips.first?.isKeep ?? false, true)
        expect("and the wrong word doesn't match",
               ClipScanner.scan(root: cardE, keepWord: "KEEP").clips.first?.isKeep ?? true, false)

        let empty = ClipScanner.scan(root: cardE, keepWord: "")
        expect("an empty flag word marks nothing", empty.clips.first?.isKeep ?? true, false)
        expectTrue("and says so in the log",
                   empty.log.contains { $0.contains("flag word is empty") })

        // The shoot date is the camera's wall clock, with its offset ignored on purpose: a
        // clip shot at 23:31 must not be dated the next day because the Mac is elsewhere.
        guard let cardF = tempFolder() else { return }
        defer { try? FileManager.default.removeItem(at: cardF) }

        _ = write(Array(repeating: 0x42, count: 2048), named: "C0001.MP4", in: cardF)
        _ = write(sidecar(umid: umidA, keep: true, created: "2026-10-03T23:31:12-06:00"),
                  named: "C0001M01.XML", in: cardF)

        if let date = ClipScanner.scan(root: cardF, keepWord: "KEEP").clips.first?.shotDate {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            expect("the shoot date keeps the camera's day", utc.component(.day, from: date), 3)
            expect("and the camera's hour", utc.component(.hour, from: date), 23)
        } else {
            failures.append("no shoot date was read")
            print("  FAIL no shoot date was read")
        }
    }
}
