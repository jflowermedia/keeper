import Foundation

struct Clip: Identifiable, Hashable {
    let id: URL            // the video file's URL
    let videoURL: URL
    let xmlURL: URL
    /// What the camera flagged it, or nil for no flag.
    let flag: ClipFlag?
    let videoSize: Int64
    let xmlSize: Int64

    /// The camera's unique material ID from the XML. Tags hang off this rather than the
    /// filename, because cards restart their numbering and C0001.MP4 comes round again.
    let umid: String?

    /// When the camera recorded it, from the XML's CreationDate. Used by the rename presets,
    /// and more trustworthy than a file date that copying can change.
    let shotDate: Date?

    var name: String { videoURL.lastPathComponent }
    var totalSize: Int64 { videoSize + xmlSize }

    /// Name of the disk this clip is sitting on, for tags to remember.
    var volumeName: String {
        guard let values = try? videoURL.resourceValues(forKeys: [.volumeNameKey]),
              let name = values.volumeName
        else { return "Unknown volume" }
        return name
    }
}

// MARK: - File helpers (deliberately not main-actor bound: used from background copy tasks)

enum FileUtil {
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The two readings macOS offers for free space. Either can be missing or zero
    /// depending on the file system — an exFAT drive, which is how most external video
    /// drives are formatted, does not report the APFS-aware figure.
    static func freeSpaceReadings(at url: URL) -> (important: Int64?, plain: Int64?) {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else { return (nil, nil) }
        return (values.volumeAvailableCapacityForImportantUsage,
                values.volumeAvailableCapacity.map(Int64.init))
    }

    /// The volume a folder lives on, so two folders on one drive can be counted together.
    /// Falls back to the folder itself, which checks that folder on its own.
    static func volume(of url: URL) -> URL {
        (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? url
    }

    /// Free space at a folder, or nil when neither reading is usable.
    ///
    /// Takes the larger of the two. Apple's own documentation warns that "a zero or
    /// unexpectedly small result doesn't necessarily mean the volume is full", and this
    /// figure only drives an advisory warning — wrongly blocking a copy onto a half-empty
    /// drive is a far worse failure than not warning about a genuinely full one, which the
    /// copy itself would report anyway.
    static func freeSpace(at url: URL) -> Int64? {
        let readings = freeSpaceReadings(at: url)
        let usable = [readings.important, readings.plain].compactMap { $0 }.filter { $0 > 0 }
        return usable.max()
    }

    /// True when a file sits inside a camera's own folder structure. Used to refuse
    /// in-place renaming on a card — Keeper only ever reads those.
    static func looksLikeCameraCard(_ url: URL) -> Bool {
        let path = url.path.uppercased()
        return path.contains("/PRIVATE/M4ROOT/")
            || path.contains("/DCIM/")
            || path.contains("/AVCHD/")
            || path.contains("/BDMV/")
            || path.contains("/XDROOT/")
    }

    static func size(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey]), let s = v.fileSize else { return -1 }
        return Int64(s)
    }

    /// A folder's standardized path with a trailing slash, so a prefix test can decide
    /// containment without "/Cam A" also matching "/Cam A copy".
    static func folderPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Whether two URLs name the same file on disk. Two URLs for one file can differ as
    /// strings — a relative component, a symlinked volume path — so they're resolved first.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A folder that exists right now. A remembered export destination on a drive that has
    /// since been unplugged still looks like a perfectly good URL.
    static func isReachableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Finds a base name free for *every* extension in the set, so a clip and its sidecar
    /// are renamed together. Uniquifying them separately can leave a video called
    /// "X 2.MP4" beside a sidecar called "X.XML", and then they stop pairing up.
    static func freeBase(_ base: String, in folder: URL, extensions: [String]) -> String {
        func taken(_ candidate: String) -> Bool {
            extensions.contains { ext in
                let name = ext.isEmpty ? candidate : "\(candidate).\(ext)"
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
            }
        }
        guard taken(base) else { return base }
        for n in 2...999 {
            let candidate = "\(base) \(n)"
            if !taken(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(6))"
    }

    /// "C0001.MP4" -> "C0001 2.MP4" -> "C0001 3.MP4", so a copy never overwrites a different file.
    static func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...999 {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString).\(ext)")
    }
}

// MARK: - Scanner

enum ClipScanner {
    static let videoExts: Set<String> = ["mp4", "mov", "mxf", "mts", "m2ts", "mpg", "avi", "braw", "r3d"]

    struct Result {
        var clips: [Clip]
        var unmatchedXML: [URL]
        var videosWithoutXML: [URL]
        var log: [String]
    }

    /// Walks the card, parses every .xml, pairs it with its video and evaluates the KEEP flag.
    static func scan(root: URL, keepWord: String) -> Result {
        var videos: [String: [URL]] = [:]   // lowercased base name -> video files
        var xmls: [URL] = []
        var sizes: [URL: Int64] = [:]

        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let en = FileManager.default.enumerator(at: root,
                                                   includingPropertiesForKeys: Array(keys),
                                                   options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                let ext = url.pathExtension.lowercased()
                guard ext == "xml" || videoExts.contains(ext) else { continue }
                let values = try? url.resourceValues(forKeys: keys)
                if let isRegular = values?.isRegularFile, isRegular == false { continue }
                if let values, let bytes = values.fileSize {
                    sizes[url] = Int64(bytes)
                }
                if ext == "xml" {
                    xmls.append(url)
                } else {
                    videos[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(url)
                }
            }
        }

        var clips: [Clip] = []
        var unmatched: [URL] = []
        var used = Set<URL>()
        var log: [String] = []
        let started = Date()
        let allVideos = videos.values.flatMap { $0 }

        log.append("Scanning \(root.path)")
        log.append("Flag word \"\(keepWord)\" · \(xmls.count) XML file(s), \(allVideos.count) video file(s)")
        if keepWord.trimmingCharacters(in: .whitespaces).isEmpty {
            log.append("⚠︎ The flag word is empty, so no clip can be marked KEEP.")
        }

        // Every sidecar states its claim first, then claims are settled strongest first.
        // Settling as we go would let whichever file the enumerator reached first win, and a
        // card index that merely lists a clip would beat that clip's own sidecar.
        struct Claim {
            let xml: URL
            let parsed: XMLFlags.Parsed
            let video: URL
            let strength: MatchStrength
        }

        var reasons: [URL: String] = [:]
        var claims: [Claim] = []
        for xml in xmls.sorted(by: { $0.path < $1.path }) {
            guard let parsed = XMLFlags.parse(url: xml, keepWord: keepWord) else {
                unmatched.append(xml)
                log.append("✗ \(xml.lastPathComponent): could not be read")
                continue
            }
            guard let found = match(xml: xml, referenced: parsed.referencedNames, videos: videos) else {
                unmatched.append(xml)
                log.append("✗ \(xml.lastPathComponent): no matching video (probably not a clip XML)")
                continue
            }
            if let reason = parsed.reason { reasons[xml] = reason }
            claims.append(Claim(xml: xml, parsed: parsed, video: found.video, strength: found.strength))
        }

        claims.sort { ($0.strength, $0.xml.path) < ($1.strength, $1.xml.path) }

        for claim in claims {
            guard used.insert(claim.video).inserted else {
                log.append("– \(claim.xml.lastPathComponent): \(claim.video.lastPathComponent) "
                           + "is already paired with its own sidecar, skipped")
                continue
            }
            clips.append(Clip(id: claim.video,
                              videoURL: claim.video,
                              xmlURL: claim.xml,
                              flag: claim.parsed.flag,
                              videoSize: sizes[claim.video] ?? 0,
                              xmlSize: sizes[claim.xml] ?? 0,
                              umid: claim.parsed.umid,
                              shotDate: claim.parsed.creationDate))
            if claim.parsed.umid == nil {
                log.append("⚠︎ \(claim.xml.lastPathComponent): no UMID in the XML, so this clip can't be tagged")
            }
        }

        // Videos with no sidecar can't be classified, so they never appear in the list. Say so.
        let orphans = allVideos.filter { !used.contains($0) }.sorted { $0.path < $1.path }
        for v in orphans {
            log.append("⚠︎ \(v.lastPathComponent): no XML sidecar found, so it is not listed")
        }

        clips.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Logged after sorting, so the list reads in clip order rather than the order claims
        // happened to be settled in.
        for clip in clips {
            let verdict = (clip.flag?.rawValue ?? "—").padding(toLength: 5, withPad: " ", startingAt: 0)
            let why = reasons[clip.xmlURL].map { "  [\($0)]" } ?? ""
            log.append("\(verdict) \(clip.name) ← \(clip.xmlURL.lastPathComponent)\(why)")
        }

        let counts = ClipFlag.allCases.map { flag in
            "\(clips.filter { $0.flag == flag }.count) \(flag.rawValue)"
        }.joined(separator: ", ")
        let total = clips.reduce(Int64(0)) { $0 + $1.totalSize }
        log.append("Done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: "
                   + "\(clips.count) clips (\(counts)), "
                   + "\(FileUtil.sizeText(total)) total, \(unmatched.count) XML unmatched, \(orphans.count) video(s) without XML")
        return Result(clips: clips, unmatchedXML: unmatched, videosWithoutXML: orphans, log: log)
    }

    /// How a sidecar found its video. The order matters: a card index like Sony's
    /// MEDIAPRO.XML lists every clip on the card, so it can "reference" C7787.MP4 just as
    /// readily as C7787M01.XML can be named after it. Claims are settled strongest first, so
    /// the real sidecar always wins and the index is left over.
    enum MatchStrength: Int, Comparable {
        case name = 0        // named after the video, allowing for Sony's M01 suffix
        case referenced = 1  // the video's name appears inside the XML
        case prefix = 2      // the video was renamed, the sidecar kept its camera name
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Pairs an XML with its video: same base name first, then Sony-style "C0001M01.XML" -> "C0001",
    /// then any video file name mentioned inside the XML itself.
    private static func match(xml: URL,
                              referenced: [String],
                              videos: [String: [URL]]) -> (video: URL, strength: MatchStrength)? {
        let base = xml.deletingPathExtension().lastPathComponent.lowercased()
        var named = [base]
        if let r = base.range(of: #"m\d{2}$"#, options: .regularExpression) {
            named.append(String(base[..<r.lowerBound]))
        }
        let mentioned = referenced.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased()
        }
        let keys = named + mentioned
        let xmlDir = xml.deletingLastPathComponent()

        for key in keys {
            if let list = videos[key] {
                // Prefer a video sitting next to the XML, so two cards' C0001.MP4 don't get crossed.
                let video = list.first { $0.deletingLastPathComponent() == xmlDir }
                    ?? list.sorted { $0.path < $1.path }.first
                if let video {
                    return (video, named.contains(key) ? .name : .referenced)
                }
            }
        }

        // Last resort: the video was renamed on copy while the sidecar kept its camera name,
        // so C7531M01.XML needs to find C7531_261003_YWP_Marchetti_Goal.MP4. Only a prefix that
        // ends at a separator counts, or C753 would claim C7531.
        for key in keys where !key.isEmpty {
            var matches: [URL] = []
            for (base, list) in videos where base.hasPrefix(key) && base.count > key.count {
                let next = base[base.index(base.startIndex, offsetBy: key.count)]
                guard !next.isLetter, !next.isNumber else { continue }
                matches.append(contentsOf: list)
            }
            guard !matches.isEmpty else { continue }
            let video = matches.first { $0.deletingLastPathComponent() == xmlDir }
                ?? matches.sorted { $0.path < $1.path }.first
            if let video { return (video, .prefix) }
        }
        return nil
    }
}

// MARK: - XML flag detection

/// Camera makers store the KEEP flag differently, so this looks for the flag word in
/// element names, attribute names, attribute values and text, and checks it isn't set to false/0/off.
final class XMLFlags: NSObject, XMLParserDelegate {
    struct Parsed {
        var flag: ClipFlag?
        var referencedNames: [String]
        var reason: String?      // what in the XML set the flag (shown in debug mode)
        var umid: String?        // the clip's permanent identity, which tags are keyed to
        var creationDate: Date?  // when the camera recorded it
    }

    /// Reads the camera's wall-clock time and ignores its UTC offset deliberately. A clip shot
    /// at 23:30 in one timezone must not be dated the next day because the Mac sits in another.
    /// Renaming formats it back with the same fixed zone, so the date is the one on the camera.
    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let falsey: Set<String> = ["false", "0", "off", "no", "none", "null", "n"]

    private let word: String
    private var reason: String?
    /// Sony's OK or NG, read off `<TargetMaterial status>` alone. KEEP has the loose search
    /// below; these two can't, because "OK" turns up as a value all over XML and searching
    /// for it the same way would mark clips OK that the camera never flagged.
    private var sonyStatus: (flag: ClipFlag, reason: String)?
    private var umid: String?
    private var created: Date?
    private var refs: [String] = []
    private var stack: [(name: String, attrs: [String: String], text: String)] = []

    /// Loose "contains" matching needs a word long enough not to match half the file.
    private var allowsSubstringMatch: Bool { word.count >= 2 }

    private init(word: String) {
        self.word = word.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func parse(url: URL, keepWord: String) -> Parsed? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let handler = XMLFlags(word: keepWord)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        _ = parser.parse()   // a partial parse still yields usable results
        // The flag word wins over OK and NG: it's what you told Keeper to look for.
        let flag: ClipFlag? = handler.reason != nil ? .keep : handler.sonyStatus?.flag
        return Parsed(flag: flag,
                      referencedNames: handler.refs,
                      reason: handler.reason ?? handler.sonyStatus?.reason,
                      umid: handler.umid,
                      creationDate: handler.created)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append((elementName, attributeDict, ""))
        if sonyStatus == nil, elementName.lowercased() == "targetmaterial",
           let raw = attributeDict.first(where: { $0.key.lowercased() == "status" })?.value,
           let flag = ClipFlag(sonyStatus: raw), flag != .keep {
            sonyStatus = (flag, "<\(elementName)> status=\"\(raw)\"")
        }
        for (key, value) in attributeDict {
            noteReference(value)
            // Sony writes it as umidRef on <TargetMaterial>; other makers vary the spelling.
            if umid == nil, key.lowercased().contains("umid") {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { umid = clean }
            }
        }

        // <CreationDate value="2026-10-03T11:31:12-06:00"/>
        if created == nil, elementName.lowercased().contains("creationdate"),
           let raw = attributeDict.first(where: { $0.key.lowercased() == "value" })?.value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            created = Self.isoParser.date(from: String(trimmed.prefix(19)))   // drop the offset
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let e = stack.popLast() else { return }
        let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        noteReference(text)
        if reason == nil, let r = evaluate(name: e.name, attrs: e.attrs, text: text) { reason = r }
    }

    private func noteReference(_ s: String) {
        guard s.count < 300 else { return }
        let ext = (s as NSString).pathExtension.lowercased()
        if ClipScanner.videoExts.contains(ext) { refs.append(s) }
    }

    /// Returns a short description of what matched, or nil if this element doesn't mark the clip as KEEP.
    private func evaluate(name: String, attrs: [String: String], text: String) -> String? {
        guard !word.isEmpty else { return nil }

        // 1. Name-based: <Keep>true</Keep>, <Keep/>, <Keep value="1"/>, <Clip Keep="true"/>
        if allowsSubstringMatch {
            if name.lowercased().contains(word), isTruthy(text: text, attrs: attrs) {
                return "element <\(name)>"
            }
            for (k, v) in attrs where k.lowercased().contains(word) {
                if !v.isEmpty && !Self.falsey.contains(v.lowercased()) {
                    return "<\(name)> attribute \(k)=\"\(v)\""
                }
            }
        }

        // 2. Value-based: <ClipFlag>KEEP</ClipFlag>, <Mark type="KEEP"/>, <TargetMaterial status="KEEP"/>
        if text.lowercased() == word { return "<\(name)> text \"\(text)\"" }
        for (k, v) in attrs where v.lowercased() == word {
            let others = attrs.filter { $0.key != k }.values.map { $0.lowercased() }
            if !others.contains(where: { Self.falsey.contains($0) }) {
                return "<\(name)> \(k)=\"\(v)\""
            }
        }
        return nil
    }

    private func isTruthy(text: String, attrs: [String: String]) -> Bool {
        if !text.isEmpty { return !Self.falsey.contains(text.lowercased()) }
        if attrs.isEmpty { return true }   // bare <Keep/> means "marked"
        for key in ["value", "enabled", "state", "flag", "on"] {
            if let v = attrs.first(where: { $0.key.lowercased() == key })?.value {
                return !Self.falsey.contains(v.lowercased())
            }
        }
        return true
    }
}

/// What the status line says once a scan finishes.
///
/// Pure, and kept apart from `AppState`, so the wording can be checked. It exists because the
/// two quiet failures — a camera whose flag word isn't KEEP, and clips with no sidecar — both
/// used to end in a list that simply looked short, with the reason only in the log.
enum ScanSummary {
    static func text(clips: Int, keeps: Int, oks: Int, withoutSidecar: Int) -> String {
        // Short, because the footer shows this on one line and truncates the middle — a long
        // hint loses exactly the part that says what to do. The full text is on hover.
        let skipped = withoutSidecar == 0 ? "" :
            " \(withoutSidecar) video\(withoutSidecar == 1 ? "" : "s") with no XML not listed."

        if clips == 0 {
            return "No clips with XML sidecars were found in there." + skipped
        }
        // Zero KEEPs on a card that has clips is the signature of a different flag word, far
        // more often than of a shoot where nothing was marked. Not when there are OKs, though:
        // those prove the camera's flags are being read, and a card you only marked OK on
        // would otherwise be told to check Camera on every scan. The count still shows 0 KEEP.
        if keeps == 0 && oks == 0 {
            return "Found \(clips) clip\(clips == 1 ? "" : "s"), none marked KEEP — check Camera."
                + skipped
        }
        let ok = oks == 0 ? "" : ", \(oks) OK"
        return "Found \(clips) clip\(clips == 1 ? "" : "s"), \(keeps) marked KEEP\(ok)." + skipped
    }
}

/// The flag a clip carries. Sony writes one of these into `status` on `<TargetMaterial>`.
/// No flag is nil rather than a case, so "unflagged" can only be spelled one way.
enum ClipFlag: String, CaseIterable {
    case keep = "KEEP"
    case ok = "OK"
    case ng = "NG"

    /// KEEP and OK are both worth keeping; NG is the camera's word for a bad take. This is
    /// the one definition of a pick, so the list, the counts and the export split agree.
    var isPick: Bool { self != .ng }

    /// What goes into the sidecar. KEEP is whatever word the scanner is set to look for, so
    /// a copy flagged here reads back as KEEP; OK and NG are Sony's own and don't vary.
    func word(keepWord: String) -> String {
        self == .keep ? keepWord : rawValue
    }

    init?(sonyStatus raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let flag = ClipFlag(rawValue: clean) else { return nil }
        self = flag
    }
}

/// A flag you set in Keeper. Wrapping the optional keeps "you cleared it" apart from "you
/// haven't touched it", which a bare `ClipFlag??` blurs the moment anything chains through it.
struct FlagMark: Equatable {
    var flag: ClipFlag?
}

extension Optional where Wrapped == ClipFlag {
    var isPick: Bool { self?.isPick ?? false }
    /// For the log, the badges and the status line.
    var label: String { self?.rawValue ?? "no flag" }
}

/// A camera whose KEEP flag Keeper knows how to find, or Other for one it doesn't.
///
/// Only Sony is listed because only Sony has been tested — a brand in the menu is a promise
/// that picking it works. Each new one goes in once its sidecars have been seen.
enum CameraPreset: String, CaseIterable, Identifiable {
    case sony
    case other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sony:  return "Sony"
        case .other: return "Other…"
        }
    }

    /// The word the scanner looks for, or nil when you type it yourself.
    var word: String? {
        switch self {
        case .sony:  return "KEEP"
        case .other: return nil
        }
    }

    /// Which preset a stored word belongs to.
    static func matching(_ word: String) -> CameraPreset {
        allCases.first { $0.word == word } ?? .other
    }
}
