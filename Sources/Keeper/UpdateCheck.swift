import SwiftUI

/// Asks GitHub whether there's a newer release, and says so in a strip along the bottom of
/// the window, where the load-failure notice goes. It does not download or install anything
/// — the link opens the release page and the rest is the ordinary drag-to-Applications. A
/// notice about a release shouldn't shove the clip grid down while you're working, which is
/// why it sits at the bottom rather than the top.
///
/// One of only two things in Keeper that touch the network — the other is downloading a
/// roster, which you ask for by name. That's why this is one file,
/// why it can be turned off, and why it sends nothing: an unauthenticated GET to a public
/// endpoint, no identifiers, no version reported back, nothing about your footage. The
/// version comparison happens here.
@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var checking = false
    /// Only set by a check you asked for, so a failed automatic one stays quiet.
    @Published var manualResult: String?

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "updateCheckEnabled") }
    }

    private var lastChecked: Date? {
        get { UserDefaults.standard.object(forKey: "updateLastChecked") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateLastChecked") }
    }

    /// A version you've told it to stop mentioning.
    private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "updateSkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSkippedVersion") }
    }

    private init() {
        // Defaults to on, but `bool(forKey:)` is false for a key that was never set, so the
        // absence has to be checked rather than read.
        if UserDefaults.standard.object(forKey: "updateCheckEnabled") == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: "updateCheckEnabled")
        }
    }

    // MARK: Asking

    /// Every release, newest first — *not* `/releases/latest`, which leaves out
    /// pre-releases. Every Keeper release so far is marked as one, so the convenient
    /// endpoint would have reported nothing at all.
    private static let endpoint = URL(
        string: "https://api.github.com/repos/jflowermedia/keeper/releases?per_page=10")!

    private static let interval: TimeInterval = 24 * 60 * 60

    /// Called on launch, and by the Help menu. An automatic check is throttled to once a
    /// day and stays silent when it fails; one you asked for always runs and always answers.
    func check(manual: Bool = false) {
        guard !checking else { return }
        if !manual {
            guard enabled else { return }
            if let lastChecked {
                // A negative interval means the stored date is in the future — the clock was
                // wrong when it was written, or has been set back since. Treated as due
                // rather than as "not yet", or one bad clock reading would stop the automatic
                // check for good.
                let since = Date().timeIntervalSince(lastChecked)
                if since >= 0, since < Self.interval { return }
            }
        }
        checking = true
        manualResult = nil
        Task { await perform(manual: manual) }
    }

    private func perform(manual: Bool) async {
        defer { checking = false }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Keeper/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if manual {
                    manualResult = "GitHub answered \(http.statusCode). Try again later."
                }
                return
            }

            // The check succeeded, so the clock restarts whether or not there's anything new.
            lastChecked = Date()

            guard let newest = ReleaseFeed.newest(in: data) else {
                if manual { manualResult = "Couldn't read the release list." }
                return
            }

            if ReleaseFeed.isNewer(newest.version, than: AppInfo.version) {
                // A version you've skipped stays hidden on an automatic check. A check you
                // asked for answers honestly — you've just asked about it.
                let hidden = !manual && newest.version == skipped
                available = hidden ? nil : newest
                if manual { manualResult = "\(newest.title) is available." }
            } else {
                available = nil
                if manual {
                    manualResult = "You're on the latest version (\(AppInfo.version))."
                }
            }
        } catch {
            // Offline on launch is the normal case, not a problem worth a banner.
            if manual {
                manualResult = "Couldn't reach GitHub — \(error.localizedDescription)"
            }
        }
    }

    /// Both clear `manualResult` as well as the release. Without that, dismissing the strip
    /// would reveal a second one underneath saying the same thing — the answer to the check
    /// that put the first one there.
    func skipAvailable() {
        skipped = available?.version
        available = nil
        manualResult = nil
    }

    func dismiss() {
        available = nil
        manualResult = nil
    }

}

/// A release as GitHub describes it.
struct ReleaseInfo: Equatable {
    /// The numbers out of the tag — "v0.7.0-alpha" becomes "0.7.0".
    let version: String
    /// What the release is called, for the strip.
    let title: String
    let page: URL
}

/// Reading GitHub's release list, and deciding whether a version is newer.
///
/// Pure: bytes in, an answer out. Kept apart from the class that holds the state and does
/// the networking, so the self-check can exercise the part that actually gets things wrong
/// without a network, a main actor, or a real release.
enum ReleaseFeed {

    /// Every field optional, the same rule the stored library follows: GitHub adding or
    /// dropping one must not make the whole list unreadable.
    private struct Entry: Decodable {
        var tag: String?
        var title: String?
        var page: String?
        var draft: Bool?

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case title = "name"
            case page = "html_url"
            case draft
        }
    }

    /// The highest version in the list, not the first one GitHub sends. The list arrives in
    /// the order the releases were published, which is usually the same thing — but publish a
    /// 0.6.1 fix after 0.7 is out and the first entry would be the older release, which would
    /// then shadow the newer one for good.
    static func newest(in data: Data) -> ReleaseInfo? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        var best: ReleaseInfo?
        for entry in entries where entry.draft != true {
            guard let tag = entry.tag,
                  let page = entry.page.flatMap(URL.init(string:)),
                  // This URL is handed to `NSWorkspace.open`, so it has to be a web page and
                  // nothing else. GitHub only ever sends an https link; a `file:` or scheme-
                  // less one arriving here would mean something has gone wrong upstream, and
                  // "open whatever this says" is not the behaviour to have in that case.
                  page.scheme?.lowercased() == "https"
            else { continue }
            let version = numbersOnly(tag)
            guard !version.isEmpty else { continue }
            if let best, !isNewer(version, than: best.version) { continue }
            best = ReleaseInfo(version: version,
                               title: entry.title ?? "Keeper \(version)",
                               page: page)
        }
        return best
    }

    /// "v0.7.0-alpha" becomes "0.7.0". Anything after a dash is a label, not a number, so
    /// "0.6.1-alpha2" doesn't come out with a stray 2 on the end.
    static func numbersOnly(_ tag: String) -> String {
        let core = tag.split(separator: "-").first.map(String.init) ?? tag
        return core.split(whereSeparator: { !$0.isNumber }).joined(separator: ".")
    }

    /// Compares component by component, treating a missing component as zero, so 0.7 beats
    /// 0.6.9, 0.10 beats 0.9, and 0.6 and 0.6.0 are the same thing.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        numbersOnly(version).split(separator: ".").compactMap { Int($0) }
    }
}

/// The strip along the bottom of the window: a newer release, or the answer to a check you
/// asked for. Never both, and nothing at all the rest of the time.
struct UpdateBanner: View {
    @ObservedObject private var updates = UpdateCheck.shared

    var body: some View {
        if let release = updates.available {
            strip(tint: Color.accentColor.opacity(0.18)) {
                Image(systemName: "arrow.down.circle.fill")
                Text("\(release.title) is available. You're on \(AppInfo.version).")
                    .lineLimit(1)

                Button("What's New") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.link)
                Button("Skip This One") { updates.skipAvailable() }
                    .buttonStyle(.link)

                Spacer(minLength: 0)

                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Hide until the next check")
            }
        } else if let result = updates.manualResult {
            strip(tint: Color.secondary.opacity(0.15)) {
                Text(result).lineLimit(1)
                Spacer(minLength: 0)
                Button { updates.manualResult = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
        }
    }

    private func strip<Content: View>(tint: Color,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
    }
}
