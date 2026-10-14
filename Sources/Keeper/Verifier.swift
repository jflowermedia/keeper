import Foundation

/// Checking that everything on a card reached somewhere safe, before the card is formatted.
///
/// The interesting part is matching a renamed copy back to its original. Once a clip has been
/// exported as `C7531_261003_WHKY_Marchetti_Goal.MP4`, nothing about the name says it came
/// from `C7531.MP4`, so a compare by filename reports the whole card missing. The camera's
/// UMID is the thing that survives renaming, which is why this can answer the question at all
/// and a generic folder-compare can't.
enum Verifier {

    enum Outcome {
        /// Found at full size in at least one destination.
        case found
        /// Found, but not the same size as the original — a truncated or interrupted copy.
        case wrongSize(Int64)
        /// Not found in any destination.
        case missing
    }

    struct ClipResult: Identifiable {
        let id: URL             // the source clip's video URL
        let name: String
        let umid: String?
        let sourceSize: Int64
        let outcome: Outcome
        /// Every destination holding a copy, so a clip in two places reads as such.
        let locations: [URL]
        /// True when the match came from the filename and size rather than the UMID, which is
        /// weaker: two clips of identical size would be indistinguishable.
        let matchedWeakly: Bool
    }

    /// What one destination turned out to hold. `matchedBytes` counts only this card's
    /// clips, not everything in the folder, so the numbers add up against the card.
    struct DestinationSummary: Identifiable {
        let id: URL
        var folder: URL { id }
        let videosThere: Int
        let matched: Int
        let matchedBytes: Int64
    }

    struct Report {
        let results: [ClipResult]
        let destinations: [URL]
        let summaries: [DestinationSummary]
        /// Destinations that turned out to hold nothing Keeper recognises, usually the wrong
        /// folder picked rather than a real failure.
        let emptyDestinations: [URL]
        /// Videos sitting in the destinations that no clip on this card claimed. Usually
        /// footage from another shoot, and unremarkable — but if everything reads as missing
        /// while this is high, the copies are almost certainly there and simply unmatchable,
        /// which happens when footage was renamed *and* exported without its sidecars.
        let unclaimed: Int
        let log: [String]

        var found: [ClipResult] { results.filter { if case .found = $0.outcome { return true }; return false } }
        var wrongSize: [ClipResult] { results.filter { if case .wrongSize = $0.outcome { return true }; return false } }
        var missing: [ClipResult] { results.filter { if case .missing = $0.outcome { return true }; return false } }
        var weak: [ClipResult] { results.filter(\.matchedWeakly) }

        var allAccountedFor: Bool { missing.isEmpty && wrongSize.isEmpty }

        /// Total video bytes on the card.
        var sourceBytes: Int64 { results.reduce(0) { $0 + $1.sourceSize } }

        /// Bytes of clips found at full size. Counted once per clip, so a clip copied into
        /// two folders doesn't inflate it.
        var accountedBytes: Int64 { found.reduce(0) { $0 + $1.sourceSize } }

        var summary: String {
            guard !results.isEmpty else { return "Nothing on the card to check." }
            if allAccountedFor {
                return "All \(results.count) clip\(results.count == 1 ? "" : "s") accounted for."
            }
            var parts: [String] = ["\(found.count) of \(results.count) accounted for"]
            if !missing.isEmpty { parts.append("\(missing.count) missing") }
            if !wrongSize.isEmpty { parts.append("\(wrongSize.count) the wrong size") }
            return parts.joined(separator: " · ")
        }
    }

    /// One copy of a clip found at a destination.
    private struct Candidate {
        let id = UUID()
        let url: URL
        let size: Int64
        let folder: URL
    }

    /// Runs off the main actor: each destination is a full recursive scan.
    static func verify(source: [Clip], destinations: [URL], keepWord: String) -> Report {
        var byUMID: [String: [Candidate]] = [:]
        var byName: [String: [Candidate]] = [:]
        var log: [String] = []
        var empty: [URL] = []
        var videoCount: [URL: Int] = [:]

        for destination in destinations {
            let scan = ClipScanner.scan(root: destination, keepWord: keepWord)

            // Clips with sidecars: index by UMID, which survives any renaming.
            var indexed = 0
            for clip in scan.clips {
                let candidate = Candidate(url: clip.videoURL, size: clip.videoSize, folder: destination)
                if let umid = clip.umid {
                    byUMID[umid, default: []].append(candidate)
                    indexed += 1
                }
                // Also by name, so a copy whose sidecar went missing can still be matched.
                byName[clip.videoURL.lastPathComponent.lowercased(), default: []].append(candidate)
            }

            // Videos with no sidecar can only ever be matched the weak way.
            for video in scan.videosWithoutXML {
                byName[video.lastPathComponent.lowercased(), default: []].append(
                    Candidate(url: video, size: FileUtil.size(of: video), folder: destination))
            }

            let total = scan.clips.count + scan.videosWithoutXML.count
            videoCount[destination] = total
            log.append("\(destination.lastPathComponent): \(total) video(s), \(indexed) with a UMID")
            if total == 0 { empty.append(destination) }
        }

        var results: [ClipResult] = []
        var claimed = Set<UUID>()
        var seen = Set<UUID>()
        for list in byName.values { for candidate in list { seen.insert(candidate.id) } }

        for clip in source {
            var matches: [Candidate] = []
            var weak = false

            if let umid = clip.umid, let strong = byUMID[umid], !strong.isEmpty {
                matches = strong
            } else {
                // No UMID on the original, or no copy carries one. Fall back to the filename,
                // which only works while the copy hasn't been renamed.
                matches = byName[clip.name.lowercased()] ?? []
                weak = !matches.isEmpty
            }

            let outcome: Outcome
            if matches.isEmpty {
                outcome = .missing
            } else if matches.contains(where: { $0.size == clip.videoSize }) {
                // One good copy is enough: the clip reached somewhere intact.
                outcome = .found
            } else {
                // Every copy is a different size. Report the largest, which is the one
                // closest to complete and so the most useful number to see.
                outcome = .wrongSize(matches.map(\.size).max() ?? 0)
            }

            for candidate in matches { claimed.insert(candidate.id) }
            results.append(ClipResult(id: clip.videoURL,
                                      name: clip.name,
                                      umid: clip.umid,
                                      sourceSize: clip.videoSize,
                                      outcome: outcome,
                                      locations: Array(Set(matches.map(\.folder))).sorted { $0.path < $1.path },
                                      matchedWeakly: weak))
        }

        // Per-folder totals, counting each clip once per folder it was found in.
        var summaries: [DestinationSummary] = []
        for destination in destinations {
            let here = results.filter { $0.locations.contains(destination) }
            summaries.append(DestinationSummary(
                id: destination,
                videosThere: videoCount[destination] ?? 0,
                matched: here.count,
                matchedBytes: here.reduce(0) { $0 + $1.sourceSize }))
        }

        return Report(results: results,
                      destinations: destinations,
                      summaries: summaries,
                      emptyDestinations: empty,
                      unclaimed: seen.subtracting(claimed).count,
                      log: log)
    }
}
