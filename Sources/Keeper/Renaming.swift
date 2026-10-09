import Foundation

/// A piece of a filename. Templates are a list of these rather than a string with
/// placeholders, so the builder can't produce something unparseable.
enum NameToken: String, Codable, CaseIterable, Identifiable {
    case originalName
    case dateShort
    case dateLong
    case teamCode
    case rosterTeam
    case playerSurname
    case playerFirstName
    case playerNumber
    case topTag
    case allTags

    var id: String { rawValue }

    var label: String {
        switch self {
        case .originalName:    return "Original name"
        case .dateShort:       return "Date (yymmdd)"
        case .dateLong:        return "Date (yyyy-mm-dd)"
        case .teamCode:        return "Team code"
        case .rosterTeam:      return "Team name"
        case .playerSurname:   return "Player surname"
        case .playerFirstName: return "Player first name"
        case .playerNumber:    return "Player number"
        case .topTag:          return "Tag"
        case .allTags:         return "All tags"
        }
    }

    var example: String {
        switch self {
        case .originalName:    return "C7531"
        case .dateShort:       return "261003"
        case .dateLong:        return "2026-10-03"
        case .teamCode:        return "WHKY"
        case .rosterTeam:      return "Yateley-Wood-Pigeons"
        case .playerSurname:   return "Flower"
        case .playerFirstName: return "Jack"
        case .playerNumber:    return "15"
        case .topTag:          return "Goal"
        case .allTags:         return "Goal-Celebration"
        }
    }
}

struct RenamePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var teamCode: String = ""
    var separator: String = "_"
    var tokens: [NameToken] = [.originalName, .dateShort, .teamCode, .playerSurname, .topTag]

    /// The preset asked for first: Original_yymmdd_TEAM_Surname_Tag
    static func bisons() -> RenamePreset {
        RenamePreset(name: "Bisons",
                     teamCode: "WHKY",
                     separator: "_",
                     tokens: [.originalName, .dateShort, .teamCode, .playerSurname, .topTag])
    }
}

// MARK: - Building names

enum Renamer {
    // Fixed locale and zone, matching how the XML's time was read: the date in a filename
    // should be the one the camera recorded, not one shifted by the Mac's own timezone.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    private static let shortDate = formatter("yyMMdd")
    private static let longDate = formatter("yyyy-MM-dd")

    /// Which tag wins when a clip has several. Priority is the order of the category list,
    /// so moving Goal above Save in the preset editor is what decides it.
    static func topTag(of tags: [Tag], priority: [String]) -> Tag? {
        func rank(_ category: String) -> Int {
            priority.firstIndex(of: category) ?? Int.max
        }
        return tags.min { rank($0.category) < rank($1.category) }
    }

    /// Everything except the extension. The caller adds that, so a clip and its XML
    /// end up sharing a base name and still pair up on the next scan.
    /// `rosterCode` is the code on the team the winning tag belongs to. When a roster carries
    /// one it wins, so a single preset covers Bisons WHKY and Bisons MHKY without duplicating.
    static func baseName(for clip: Clip,
                         tags: [Tag],
                         preset: RenamePreset,
                         priority: [String],
                         rosterCode: String?) -> String {
        let chosen = topTag(of: tags, priority: priority)
        let original = clip.videoURL.deletingPathExtension().lastPathComponent
        let date = clip.shotDate ?? fileDate(clip.videoURL)

        let parts: [String] = preset.tokens.map { token in
            switch token {
            case .originalName:
                return original
            case .dateShort:
                return date.map { shortDate.string(from: $0) } ?? ""
            case .dateLong:
                return date.map { longDate.string(from: $0) } ?? ""
            case .teamCode:
                let fromRoster = rosterCode?.trimmingCharacters(in: .whitespaces) ?? ""
                return fromRoster.isEmpty ? preset.teamCode : fromRoster
            case .rosterTeam:
                return chosen?.teamName ?? ""
            case .playerSurname:
                return surname(of: chosen?.playerName)
            case .playerFirstName:
                return firstName(of: chosen?.playerName)
            case .playerNumber:
                return chosen?.playerNumber ?? ""
            case .topTag:
                return chosen?.category ?? ""
            case .allTags:
                let ordered = tags
                    .map(\.category)
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    .sorted { (priority.firstIndex(of: $0) ?? .max) < (priority.firstIndex(of: $1) ?? .max) }
                return ordered.joined(separator: "-")
            }
        }

        let cleaned = parts.map(tidy).filter { !$0.isEmpty }
        let joined = cleaned.joined(separator: safeSeparator(preset.separator))
        return joined.isEmpty ? original : joined
    }

    /// A worked example for the preset editor, using no real clip.
    static func preview(preset: RenamePreset) -> String {
        let parts = preset.tokens.map { $0 == .teamCode ? preset.teamCode : $0.example }
        let cleaned = parts.map(tidy).filter { !$0.isEmpty }
        let joined = cleaned.joined(separator: safeSeparator(preset.separator))
        return (joined.isEmpty ? "C7531" : joined) + ".MP4"
    }

    /// A separator of "/" would quietly turn one filename into nested folders, so the
    /// same cleaning the parts get is applied here too.
    private static func safeSeparator(_ raw: String) -> String {
        var text = raw
        for bad in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] {
            text = text.replacingOccurrences(of: bad, with: "-")
        }
        return text
    }

    // MARK: Helpers

    private static func surname(of name: String?) -> String {
        guard let name else { return "" }
        let words = name.split(separator: " ")
        return words.count > 1 ? String(words.last!) : name
    }

    private static func firstName(of name: String?) -> String {
        guard let name, let first = name.split(separator: " ").first else { return "" }
        return String(first)
    }

    /// Only used when an XML carries no CreationDate. Shifted into the same fixed zone the
    /// formatters use, so the fallback still prints the local calendar date.
    private static func fileDate(_ url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let date = values.creationDate ?? values.contentModificationDate
        else { return nil }
        return date.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for: date)))
    }

    /// Strips the characters a filename can't carry, and turns inner spaces into hyphens
    /// so the separator stays the only thing dividing the parts.
    private static func tidy(_ part: String) -> String {
        var text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        for bad in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] {
            text = text.replacingOccurrences(of: bad, with: "-")
        }
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return text
    }
}
