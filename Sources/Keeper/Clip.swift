import Foundation

struct Clip: Identifiable, Hashable {
    let id: URL            // the video file's URL
    let videoURL: URL
    let xmlURL: URL
    let isKeep: Bool
    let videoSize: Int64
    let xmlSize: Int64

    var name: String { videoURL.lastPathComponent }
    var totalSize: Int64 { videoSize + xmlSize }
}

// MARK: - File helpers (deliberately not main-actor bound: used from background copy tasks)

enum FileUtil {
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func size(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey]), let s = v.fileSize else { return -1 }
        return Int64(s)
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

        for xml in xmls.sorted(by: { $0.path < $1.path }) {
            guard let parsed = XMLFlags.parse(url: xml, keepWord: keepWord) else {
                unmatched.append(xml)
                log.append("✗ \(xml.lastPathComponent): could not be read")
                continue
            }
            guard let video = match(xml: xml, referenced: parsed.referencedNames, videos: videos) else {
                unmatched.append(xml)
                log.append("✗ \(xml.lastPathComponent): no matching video (probably not a clip XML)")
                continue
            }
            guard used.insert(video).inserted else {
                log.append("– \(xml.lastPathComponent): \(video.lastPathComponent) is already paired, skipped")
                continue
            }
            clips.append(Clip(id: video,
                              videoURL: video,
                              xmlURL: xml,
                              isKeep: parsed.isKeep,
                              videoSize: sizes[video] ?? 0,
                              xmlSize: sizes[xml] ?? 0))
            let verdict = parsed.isKeep ? "KEEP    " : "NOT KEEP"
            let why = parsed.reason.map { "  [\($0)]" } ?? ""
            log.append("\(verdict) \(video.lastPathComponent) ← \(xml.lastPathComponent)\(why)")
        }

        // Videos with no sidecar can't be classified, so they never appear in the list. Say so.
        let orphans = allVideos.filter { !used.contains($0) }.sorted { $0.path < $1.path }
        for v in orphans {
            log.append("⚠︎ \(v.lastPathComponent): no XML sidecar found, so it is not listed")
        }

        clips.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let keepCount = clips.filter { $0.isKeep }.count
        let total = clips.reduce(Int64(0)) { $0 + $1.totalSize }
        log.append("Done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: "
                   + "\(clips.count) clips (\(keepCount) KEEP, \(clips.count - keepCount) NOT KEEP), "
                   + "\(FileUtil.sizeText(total)) total, \(unmatched.count) XML unmatched, \(orphans.count) video(s) without XML")
        return Result(clips: clips, unmatchedXML: unmatched, videosWithoutXML: orphans, log: log)
    }

    /// Pairs an XML with its video: same base name first, then Sony-style "C0001M01.XML" -> "C0001",
    /// then any video file name mentioned inside the XML itself.
    private static func match(xml: URL, referenced: [String], videos: [String: [URL]]) -> URL? {
        let base = xml.deletingPathExtension().lastPathComponent.lowercased()
        var keys = [base]
        if let r = base.range(of: #"m\d{2}$"#, options: .regularExpression) {
            keys.append(String(base[..<r.lowerBound]))
        }
        for ref in referenced {
            keys.append(URL(fileURLWithPath: ref).deletingPathExtension().lastPathComponent.lowercased())
        }
        let xmlDir = xml.deletingLastPathComponent()
        for key in keys {
            if let list = videos[key] {
                // Prefer a video sitting next to the XML, so two cards' C0001.MP4 don't get crossed.
                return list.first { $0.deletingLastPathComponent() == xmlDir }
                    ?? list.sorted { $0.path < $1.path }.first
            }
        }
        return nil
    }
}

// MARK: - XML flag detection

/// Camera makers store the KEEP flag differently, so this looks for the flag word in
/// element names, attribute names, attribute values and text, and checks it isn't set to false/0/off.
final class XMLFlags: NSObject, XMLParserDelegate {
    struct Parsed {
        var isKeep: Bool
        var referencedNames: [String]
        var reason: String?      // what in the XML triggered KEEP (shown in debug mode)
    }

    private static let falsey: Set<String> = ["false", "0", "off", "no", "none", "null", "n"]

    private let word: String
    private var reason: String?
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
        return Parsed(isKeep: handler.reason != nil, referencedNames: handler.refs, reason: handler.reason)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append((elementName, attributeDict, ""))
        for v in attributeDict.values { noteReference(v) }
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
