import Foundation

/// Writes the clip flag — KEEP, OK, NG or none — into a sidecar **at the destination**, after it has been copied.
/// Cards are never touched: an override you set in the app lives in the library until the
/// clip is copied out, and only the copy gets the edited XML.
///
/// The edit is made on the text rather than by re-serialising the document, so everything
/// else in the file — formatting, attribute order, the camera's own metadata — is left
/// exactly as it was.
enum KeepWriter {
    enum Failure: LocalizedError {
        case notUTF8
        case noTargetMaterial

        var errorDescription: String? {
            switch self {
            case .notUTF8:
                return "the sidecar isn't UTF-8 text"
            case .noTargetMaterial:
                return "the sidecar has no <TargetMaterial> element to flag"
            }
        }
    }

    /// Returns true when the file was changed. Matches the Sony layout the app reads:
    /// `status="KEEP"` on `<TargetMaterial>`, with whatever word KEEP is configured as.
    /// nil clears the flag.
    @discardableResult
    static func apply(_ flag: ClipFlag?, keepWord: String, toXMLAt url: URL) throws -> Bool {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.notUTF8
        }
        guard let open = text.range(of: "<TargetMaterial", options: .caseInsensitive),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex)
        else {
            throw Failure.noTargetMaterial
        }

        let elementRange = open.lowerBound..<close.upperBound
        var element = String(text[elementRange])
        let original = element
        let word = flag?.word(keepWord: keepWord)

        let statusPattern = #"\sstatus\s*=\s*"([^"]*)""#
        if let status = element.range(of: statusPattern,
                                      options: [.regularExpression, .caseInsensitive]) {
            if let word {
                element.replaceSubrange(status, with: " status=\"\(word)\"")
            } else if isFlag(String(element[status]), keepWord: keepWord) {
                // Only clear a flag; leave any other status alone.
                element.removeSubrange(status)
            }
        } else if let word {
            if let selfClosing = element.range(of: "/>", options: .backwards) {
                element.replaceSubrange(selfClosing, with: " status=\"\(word)\"/>")
            } else if let bracket = element.range(of: ">", options: .backwards) {
                element.replaceSubrange(bracket, with: " status=\"\(word)\">")
            }
        }

        guard element != original else { return false }
        text.replaceSubrange(elementRange, with: element)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// For the log: what a change did to the sidecar.
    static func describe(_ flag: ClipFlag?, keepWord: String) -> String {
        flag.map { "flag set to \($0.word(keepWord: keepWord))" } ?? "flag cleared"
    }

    /// Whether `status="…"` holds one of the flags Keeper writes.
    private static func isFlag(_ attribute: String, keepWord: String) -> Bool {
        let value = attribute.split(separator: "\"", omittingEmptySubsequences: false)
            .dropFirst().first.map(String.init) ?? ""
        return ClipFlag.allCases.contains {
            $0.word(keepWord: keepWord).caseInsensitiveCompare(value) == .orderedSame
        }
    }
}
