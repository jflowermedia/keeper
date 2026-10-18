import XCTest
@testable import Keeper

/// The stored library format, because a field added without care stops every existing
/// `library.json` from loading — and a library that won't load is a season of tagging gone.
///
/// Swift's generated decoder throws on a missing key even for a property that has a default
/// value, so these fixtures are deliberately written the way older versions wrote them: no
/// `presets`, no `keepOverrides`, teams with no `code` or `league`. Every one of them has to
/// decode. Nothing here touches the real library — `decodeArchive` takes bytes.
final class LibraryFormatTests: XCTestCase {

    /// The shape of the very first release: three keys, and nothing else.
    func testOldestArchiveStillDecodes() throws {
        let json = """
        {
          "teams": [
            {
              "id": "yateley-wood-pigeons",
              "name": "Yateley Wood Pigeons",
              "players": [
                { "teamID": "yateley-wood-pigeons", "number": "17",
                  "name": "Marchetti", "position": "Forward" }
              ]
            }
          ],
          "categories": ["Goal", "Save"],
          "tags": [
            {
              "id": "A1B2C3D4-0000-0000-0000-000000000001",
              "umid": "060A2B34ABCD",
              "clipName": "C0001.MP4",
              "volumeName": "CARD A",
              "path": "/Volumes/CARD A/PRIVATE/M4ROOT/CLIP/C0001.MP4",
              "category": "Goal",
              "note": "",
              "created": "2026-01-04T18:22:01Z"
            }
          ]
        }
        """

        let archive = try TagLibrary.decodeArchive(Data(json.utf8))
        XCTAssertEqual(archive.teams.count, 1)
        XCTAssertEqual(archive.teams[0].players.count, 1)
        XCTAssertEqual(archive.tags.count, 1)
        XCTAssertEqual(archive.categories, ["Goal", "Save"])
        XCTAssertNil(archive.presets, "absent means absent, and `load` substitutes the standard one")
        XCTAssertNil(archive.keepOverrides)
    }

    /// `code` and `league` were both added later. Neither may ever become non-optional.
    func testTeamWithoutCodeOrLeagueDecodes() throws {
        let json = """
        { "teams": [ { "id": "virden-oil-capitals", "name": "Virden Oil Capitals",
                       "players": [] } ],
          "categories": [], "tags": [] }
        """
        let archive = try TagLibrary.decodeArchive(Data(json.utf8))
        XCTAssertEqual(archive.teams[0].name, "Virden Oil Capitals")
        XCTAssertNil(archive.teams[0].code)
        XCTAssertNil(archive.teams[0].league)
    }

    /// A team written before `players` existed, and a player written before `position` did.
    /// Both are non-optional with a default, which the generated decoder would reject.
    func testMissingDefaultedFieldsTakeTheirDefaults() throws {
        let json = """
        { "teams": [ { "id": "t", "name": "Team" } ],
          "categories": [],
          "tags": [] }
        """
        let archive = try TagLibrary.decodeArchive(Data(json.utf8))
        XCTAssertEqual(archive.teams[0].players, [])

        let playerJSON = """
        { "teamID": "t", "number": "9", "name": "Nine" }
        """
        let player = try JSONDecoder().decode(Player.self, from: Data(playerJSON.utf8))
        XCTAssertEqual(player.position, "")
        XCTAssertEqual(player.id, "t/9", "the id is computed from team and number")
    }

    /// A tag written before `note` and `created` existed.
    func testTagWithoutNoteOrCreatedDecodes() throws {
        let json = """
        { "umid": "ABC", "clipName": "C0002.MP4", "volumeName": "CARD A",
          "path": "/x/C0002.MP4", "category": "Save" }
        """
        let tag = try JSONDecoder().decode(Tag.self, from: Data(json.utf8))
        XCTAssertEqual(tag.umid, "ABC")
        XCTAssertEqual(tag.note, "")
        XCTAssertEqual(tag.category, "Save")
    }

    /// A team with no stored id gets one built the same way an import would, because a team
    /// whose id changed is a team whose tags have come loose.
    func testTeamWithNoIDGetsTheSlugOfItsName() throws {
        let json = """
        { "name": "Dauphin Kings", "players": [] }
        """
        let team = try JSONDecoder().decode(Team.self, from: Data(json.utf8))
        XCTAssertEqual(team.id, "dauphin-kings")
        XCTAssertEqual(team.id, Team.slug(team.name))
    }

    /// What this build writes has to come back unchanged, or a backup is worthless.
    func testRoundTripKeepsEverything() throws {
        let team = Team(id: "virden-oil-capitals",
                        name: "Virden Oil Capitals",
                        code: "VIR",
                        league: "MJHL",
                        players: [Player(teamID: "virden-oil-capitals", number: "27",
                                         name: "Liam Goertzen", position: "Forward")])
        let tag = Tag(umid: "060A2B34",
                      clipName: "C0001.MP4",
                      volumeName: "CARD A",
                      path: "/Volumes/CARD A/C0001.MP4",
                      teamID: team.id,
                      teamName: team.name,
                      playerNumber: "27",
                      playerName: "Liam Goertzen",
                      playerPosition: "Forward",
                      category: "Goal")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(TagLibrary.Archive(teams: [team],
                                                         categories: ["Goal"],
                                                         tags: [tag],
                                                         presets: nil,
                                                         keepOverrides: ["060A2B34": true]))

        let back = try TagLibrary.decodeArchive(data)
        XCTAssertEqual(back.teams, [team])
        XCTAssertEqual(back.tags.first?.playerID, "virden-oil-capitals/27")
        XCTAssertEqual(back.keepOverrides?["060A2B34"], true)
    }

    /// Nonsense must throw rather than decode as an empty library: that's what stops the app
    /// saving an empty file over a good one.
    func testRubbishThrows() {
        XCTAssertThrowsError(try TagLibrary.decodeArchive(Data("not json at all".utf8)))
        XCTAssertThrowsError(try TagLibrary.decodeArchive(Data("{}".utf8)),
                             "teams, categories and tags are required keys")
    }
}
