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
        sleepHold()
        addingTeams()
        subjects()
        oneOffCategories()
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

        // The first step has to be the one that gets you off a blank window. A tour that opens
        // on anything else is a tour for someone who's already started.
        expect("it opens on choosing a folder",
               WelcomeTour.steps.first?.key == .chooseFolder, true)
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
