import XCTest
@testable import Keeper

/// The CSV parser, because it shipped broken.
///
/// `Character` in Swift is a grapheme cluster, and "\r\n" is a single one — so a parser
/// switching on "\n" matched nothing, appended every line ending into the current field and
/// returned the whole file as one row. Excel and Numbers both write CRLF, so every roster
/// anyone exported from either failed to import, with "no players found" as the only clue.
/// Excel also writes a UTF-8 BOM, which rode along on the first heading and made that column
/// unrecognisable.
final class CSVTests: XCTestCase {

    // MARK: Line endings

    func testCRLFSplitsIntoRows() {
        let rows = CSV.parse("league,team,number,name\r\nMJHL,Virden,27,Liam Goertzen\r\n")
        XCTAssertEqual(rows.count, 2, "CRLF has to end a row, not join the file into one")
        XCTAssertEqual(rows[0], ["league", "team", "number", "name"])
        XCTAssertEqual(rows[1], ["MJHL", "Virden", "27", "Liam Goertzen"])
    }

    func testClassicMacCRSplitsIntoRows() {
        let rows = CSV.parse("number,name\r27,Liam Goertzen\r31,Micky Gross\r")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[2], ["31", "Micky Gross"])
    }

    func testLFStillWorks() {
        let rows = CSV.parse("number,name\n27,Liam Goertzen\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["27", "Liam Goertzen"])
    }

    func testMixedEndingsInOneFile() {
        let rows = CSV.parse("a,b\r\nc,d\ne,f\rg,h")
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[3], ["g", "h"])
    }

    /// The symptom as it was reported: a header row and nothing else left over.
    func testCRLFFileIsNotOneSingleRow() {
        let text = "team,number,name\r\nVirden,27,Liam\r\nVirden,31,Micky\r\n"
        let rows = CSV.parse(text)
        XCTAssertGreaterThan(rows.count, 1,
                             "one row means the header is all there is, and the import reports "
                             + "no players found")
    }

    // MARK: Separators and quoting

    func testSemicolonAndTabAreSeparatorsToo() {
        XCTAssertEqual(CSV.parse("27;Liam Goertzen").first, ["27", "Liam Goertzen"])
        XCTAssertEqual(CSV.parse("27\tLiam Goertzen").first, ["27", "Liam Goertzen"])
    }

    func testQuotedFieldKeepsItsComma() {
        let rows = CSV.parse("number,name\n27,\"Goertzen, Liam\"\n")
        XCTAssertEqual(rows[1], ["27", "Goertzen, Liam"])
    }

    func testQuotedFieldKeepsAnEmbeddedNewline() {
        let rows = CSV.parse("number,name\n27,\"Liam\nGoertzen\"\n")
        XCTAssertEqual(rows.count, 2, "a newline inside quotes is part of the field")
    }

    func testDoubledQuoteIsALiteralQuote() {
        let rows = CSV.parse("name\n\"Liam \"\"Goose\"\" Goertzen\"\n")
        XCTAssertEqual(rows[1], ["Liam \"Goose\" Goertzen"])
    }

    func testBlankRowsAreNotReturned() {
        let rows = CSV.parse("a,b\n\n\nc,d\n")
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: Reading a file

    func testReadTextStripsAUTF8BOM() throws {
        let url = try write(bytes: [0xEF, 0xBB, 0xBF] + Array("league,team,number,name\r\nMJHL,Virden,27,Liam\r\n".utf8))

        let text = try XCTUnwrap(CSV.readText(url))
        XCTAssertFalse(text.hasPrefix("\u{FEFF}"), "a BOM left on the front hides the first column")

        let rows = CSV.parse(text)
        XCTAssertEqual(rows[0].first, "league",
                       "with the BOM still attached this heading reads as \"\\u{FEFF}league\" "
                       + "and the league column goes unrecognised")
        XCTAssertEqual(rows.count, 2)
    }

    /// What Excel actually produces: BOM and CRLF together.
    func testExcelShapedFileParsesEndToEnd() throws {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes += Array("team,code,number,name,position\r\n".utf8)
        bytes += Array("Virden Oil Capitals,VIR,27,Liam Goertzen,Forward\r\n".utf8)
        bytes += Array("Virden Oil Capitals,VIR,31,Micky Gross,Goalie\r\n".utf8)
        let url = try write(bytes: bytes)

        let rows = CSV.parse(try XCTUnwrap(CSV.readText(url)))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["team", "code", "number", "name", "position"])
        XCTAssertEqual(rows[2][3], "Micky Gross")
    }

    func testReadTextFallsBackToLatin1() throws {
        // 0xE9 is "é" in Latin-1 and not valid UTF-8 on its own.
        let url = try write(bytes: Array("number,name\n9,Ren".utf8) + [0xE9] + Array("\n".utf8))
        let text = try XCTUnwrap(CSV.readText(url), "an odd encoding shouldn't read as nothing")
        XCTAssertTrue(text.contains("Ren"))
    }

    // MARK: Helper

    private func write(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-test-\(UUID().uuidString).csv")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
