import XCTest
@testable import Keeper

/// Pairing sidecars to videos, because a card index nearly took a clip's identity.
///
/// Sony writes a `MEDIAPRO.XML` at the root of the card listing every clip on it. That index
/// "references" `C0001.MP4` exactly as readily as `C0001M01.XML` is named after it, so when
/// claims were settled in the order the enumerator happened to reach them, the only thing
/// stopping the index winning was that `CLIP/` sorts before `MEDIAPRO.XML`. Had it won, the
/// clip would have taken the index's KEEP flag and UMID — the wrong flag and a tag identity
/// shared with every other clip on the card — and its real sidecar would have been reported
/// unmatched. Claims are settled strongest first now, and these tests hold that in place.
final class ScannerTests: XCTestCase {

    // MARK: A card as the camera writes it

    func testRealSidecarWinsOverTheCardIndex() throws {
        let root = try makeTempFolder()
        let clipFolder = root.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true)

        try write(video: "C0001.MP4", in: clipFolder)
        try write(sidecar: "C0001M01.XML", in: clipFolder, umid: umidA, keep: true)
        try write(video: "C0002.MP4", in: clipFolder)
        try write(sidecar: "C0002M01.XML", in: clipFolder, umid: umidB, keep: false)

        // The index claims KEEP for everything, so a mispairing shows up as a wrong flag
        // as well as a wrong sidecar.
        try write(index: "MEDIAPRO.XML",
                  in: root.appendingPathComponent("PRIVATE/M4ROOT", isDirectory: true),
                  videos: ["C0001.MP4", "C0002.MP4"])

        let result = ClipScanner.scan(root: root, keepWord: "KEEP")

        XCTAssertEqual(result.clips.count, 2)
        XCTAssertEqual(result.clips.map(\.name), ["C0001.MP4", "C0002.MP4"], "sorted by name")

        let first = try XCTUnwrap(result.clips.first { $0.name == "C0001.MP4" })
        let second = try XCTUnwrap(result.clips.first { $0.name == "C0002.MP4" })

        XCTAssertEqual(first.xmlURL.lastPathComponent, "C0001M01.XML")
        XCTAssertEqual(second.xmlURL.lastPathComponent, "C0002M01.XML")
        XCTAssertFalse(result.clips.contains { $0.xmlURL.lastPathComponent == "MEDIAPRO.XML" },
                       "the card index must never end up as a clip's sidecar")

        XCTAssertTrue(first.isKeep)
        XCTAssertFalse(second.isKeep, "C0002's own sidecar says not KEEP; only the index says KEEP")

        XCTAssertEqual(first.umid, umidA)
        XCTAssertEqual(second.umid, umidB)
        XCTAssertNotEqual(first.umid, second.umid, "two clips sharing a UMID share their tags")
    }

    /// The same thing with the index somewhere that sorts *first*, which is what the old
    /// assign-as-you-go code was quietly relying on not happening.
    func testIndexLosesEvenWhenItSortsFirst() throws {
        let root = try makeTempFolder()
        let clipFolder = root.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true)
        // "AA" sorts before "PRIVATE", so this index is reached before either sidecar.
        let indexFolder = root.appendingPathComponent("AA", isDirectory: true)

        try write(video: "C0001.MP4", in: clipFolder)
        try write(sidecar: "C0001M01.XML", in: clipFolder, umid: umidA, keep: false)
        try write(index: "INDEX.XML", in: indexFolder, videos: ["C0001.MP4"])

        let result = ClipScanner.scan(root: root, keepWord: "KEEP")

        XCTAssertEqual(result.clips.count, 1)
        let clip = try XCTUnwrap(result.clips.first)
        XCTAssertEqual(clip.xmlURL.lastPathComponent, "C0001M01.XML",
                       "being named after the video beats being mentioned by an index, "
                       + "whatever order the files are reached in")
        XCTAssertFalse(clip.isKeep)
        XCTAssertEqual(clip.umid, umidA)
    }

    // MARK: Other pairings worth keeping

    /// Footage already offloaded and renamed: the video carries the new name, the sidecar
    /// still carries the camera's.
    func testRenamedVideoStillFindsItsSidecar() throws {
        let root = try makeTempFolder()
        try write(video: "C7531_261003_YWP_Marchetti_Goal.MP4", in: root)
        try write(sidecar: "C7531M01.XML", in: root, umid: umidA, keep: true)

        let result = ClipScanner.scan(root: root, keepWord: "KEEP")
        XCTAssertEqual(result.clips.count, 1)
        XCTAssertEqual(result.clips.first?.name, "C7531_261003_YWP_Marchetti_Goal.MP4")
        XCTAssertEqual(result.clips.first?.isKeep, true)
    }

    /// A prefix only counts when it ends at a separator, or C753 would claim C7531.
    func testShorterPrefixDoesNotClaimALongerClip() throws {
        let root = try makeTempFolder()
        try write(video: "C75311.MP4", in: root)
        try write(sidecar: "C7531M01.XML", in: root, umid: umidA, keep: true)

        let result = ClipScanner.scan(root: root, keepWord: "KEEP")
        XCTAssertTrue(result.clips.isEmpty, "C7531 must not claim C75311")
        XCTAssertEqual(result.videosWithoutXML.map(\.lastPathComponent), ["C75311.MP4"])
        XCTAssertEqual(result.unmatchedXML.map(\.lastPathComponent), ["C7531M01.XML"])
    }

    func testVideoWithNoSidecarIsReportedNotListed() throws {
        let root = try makeTempFolder()
        try write(video: "C0001.MP4", in: root)
        try write(sidecar: "C0001M01.XML", in: root, umid: umidA, keep: true)
        try write(video: "C0009.MP4", in: root)

        let result = ClipScanner.scan(root: root, keepWord: "KEEP")
        XCTAssertEqual(result.clips.count, 1, "a clip with no sidecar can't be classified")
        XCTAssertEqual(result.videosWithoutXML.map(\.lastPathComponent), ["C0009.MP4"])
    }

    /// The flag word is configurable because other cameras use other words.
    func testAnotherFlagWordIsHonoured() throws {
        let root = try makeTempFolder()
        try write(video: "A001.MOV", in: root)
        try write(text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <ClipMeta>
              <TargetMaterial umidRef="\(umidA)" status="PICK"/>
            </ClipMeta>
            """, to: "A001M01.XML", in: root)

        XCTAssertEqual(ClipScanner.scan(root: root, keepWord: "PICK").clips.first?.isKeep, true)
        XCTAssertEqual(ClipScanner.scan(root: root, keepWord: "KEEP").clips.first?.isKeep, false)
    }

    /// An empty flag word can't mark anything, and says so rather than marking everything.
    func testEmptyFlagWordMarksNothing() throws {
        let root = try makeTempFolder()
        try write(video: "C0001.MP4", in: root)
        try write(sidecar: "C0001M01.XML", in: root, umid: umidA, keep: true)

        let result = ClipScanner.scan(root: root, keepWord: "")
        XCTAssertEqual(result.clips.count, 1)
        XCTAssertEqual(result.clips.first?.isKeep, false)
        XCTAssertTrue(result.log.contains { $0.contains("flag word is empty") })
    }

    func testShootDateComesFromTheXML() throws {
        let root = try makeTempFolder()
        try write(video: "C0001.MP4", in: root)
        try write(sidecar: "C0001M01.XML", in: root, umid: umidA, keep: true,
                  created: "2026-10-03T23:31:12-06:00")

        let clip = try XCTUnwrap(ClipScanner.scan(root: root, keepWord: "KEEP").clips.first)
        let date = try XCTUnwrap(clip.shotDate)

        // Read as the camera's wall clock, with the offset ignored on purpose: a clip shot at
        // 23:31 must not be dated the next day because the Mac is in another timezone.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(utc.component(.day, from: date), 3)
        XCTAssertEqual(utc.component(.hour, from: date), 23)
    }

    // MARK: Fixtures

    private let umidA = "060A2B340101010501010D4313000000AAAA1111BBBB2222CCCC3333DDDD4444"
    private let umidB = "060A2B340101010501010D4313000000EEEE5555FFFF6666AAAA7777BBBB8888"

    private func makeTempFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Enough bytes to have a size. Nothing reads the contents of a video.
    private func write(video name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 2048)
            .write(to: folder.appendingPathComponent(name))
    }

    /// A clip sidecar shaped like the A7S III's: the flag on `status`, the identity on
    /// `umidRef`, and no mention of the video's name anywhere — the pairing is by filename.
    private func write(sidecar name: String,
                       in folder: URL,
                       umid: String,
                       keep: Bool,
                       created: String = "2026-10-03T11:31:12-06:00") throws {
        try write(text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
              <TargetMaterial umidRef="\(umid)"\(keep ? " status=\"KEEP\"" : "")/>
              <CreationDate value="\(created)"/>
              <VideoFormat>
                <VideoFrame videoCodec="AVC_3840_2160_HP@L51"/>
              </VideoFormat>
            </NonRealTimeMeta>
            """, to: name, in: folder)
    }

    /// A card index: it lists every clip by name, and claims KEEP for all of them.
    private func write(index name: String, in folder: URL, videos: [String]) throws {
        let materials = videos.enumerated().map { offset, video in
            "    <Material uri=\"\(video)\" umid=\"INDEXUMID\(offset)\" status=\"KEEP\"/>"
        }.joined(separator: "\n")

        try write(text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <MediaProfile xmlns="urn:schemas-professionalDisc:mediaProfile">
              <Contents>
            \(materials)
              </Contents>
            </MediaProfile>
            """, to: name, in: folder)
    }

    private func write(text: String, to name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }
}
