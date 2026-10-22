import Foundation

/// Keeper's checks, run with `swift run Keeper --self-check`.
///
/// These were an XCTest target to begin with, which was a mistake: XCTest ships with Xcode,
/// not with the Command Line Tools, and the Command Line Tools are all this app needs to
/// build. A check suite that only runs on a machine set up differently from the one that
/// builds the app is a check suite that never runs. So it lives in the app instead, behind
/// a flag, with a dozen lines of harness standing in for XCTest.
///
/// What's covered is the three things that have actually shipped broken: the CSV reader,
/// the stored library format, and pairing sidecars to videos. Everything here works on
/// bytes or a temporary folder — nothing touches the real `library.json`, and nothing
/// writes outside `FileManager.default.temporaryDirectory`. Keep it that way.
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
