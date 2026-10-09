import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case isKeep = "IS KEEP"
        case isNotKeep = "IS NOT KEEP"
        case all = "ALL"
        var id: String { rawValue }
    }

    /// How a copy lays out its destination folder.
    enum Grouping: String, CaseIterable, Identifiable {
        case flat = "One folder"
        case byPlayer = "Folder per player"
        case byCategory = "Folder per category"
        var id: String { rawValue }
    }

    let library = TagLibrary.shared

    @Published var root: URL?
    @Published var clips: [Clip] = []
    @Published var unmatchedXML: [URL] = []
    @Published var videosWithoutXML: [URL] = []
    @Published var isScanning = false
    @Published var isCopying = false

    // Copy progress, measured in bytes rather than file count so a 470 MB clip
    // doesn't count the same as its 3 KB sidecar.
    @Published var copyFilesDone = 0
    @Published var copyFilesTotal = 0
    @Published var copyBytesDone: Int64 = 0
    @Published var copyBytesTotal: Int64 = 0

    var copyFraction: Double {
        guard copyBytesTotal > 0 else { return 0 }
        return min(1, Double(copyBytesDone) / Double(copyBytesTotal))
    }
    @Published var log: [String] = []
    @Published var status = "Choose a card, drive or folder to begin."

    /// Switching filter clears the selection, so the drag set never silently means
    /// "everything in the new filter" while stale rows are still ticked.
    @Published var filter: Filter = .isKeep {
        didSet {
            guard filter != oldValue else { return }
            selection = []
        }
    }

    /// Tracks the most recently added row so the preview follows the clip you just clicked.
    @Published private(set) var lastSelected: URL?
    @Published var selection = Set<URL>() {
        didSet {
            if let added = selection.subtracting(oldValue).first {
                lastSelected = added
            } else if let last = lastSelected, !selection.contains(last) {
                lastSelected = selection.first
            }
        }
    }

    @Published var debugMode: Bool = false {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }
    @Published var includeXML: Bool = true {
        didSet { UserDefaults.standard.set(includeXML, forKey: "includeXML") }
    }
    @Published var keepWord: String {
        didSet { UserDefaults.standard.set(keepWord, forKey: "keepWord") }
    }

    // Tag filtering and export layout
    /// Narrows the clip list and, more usefully, the player menu — one roster at a time
    /// instead of every player of every team in one list.
    @Published var filterTeamID: String? {
        didSet {
            guard filterTeamID != oldValue else { return }
            // A player filter from another team would make the list permanently empty.
            if let player = filterPlayerID, let team = filterTeamID, !player.hasPrefix("\(team)/") {
                filterPlayerID = nil
            }
            selection = []
        }
    }
    @Published var filterPlayerID: String? { didSet { if filterPlayerID != oldValue { selection = [] } } }
    @Published var filterCategory: String? { didSet { if filterCategory != oldValue { selection = [] } } }
    @Published var filterPosition: String? { didSet { if filterPosition != oldValue { selection = [] } } }
    @Published var grouping: Grouping = .flat
    @Published var renamePresetID: UUID?

    init() {
        keepWord = UserDefaults.standard.string(forKey: "keepWord") ?? "KEEP"
        if UserDefaults.standard.object(forKey: "includeXML") != nil {
            includeXML = UserDefaults.standard.bool(forKey: "includeXML")
        }
        debugMode = UserDefaults.standard.bool(forKey: "debugMode")
    }

    // MARK: - Derived state

    var visible: [Clip] {
        var list: [Clip]
        switch filter {
        case .isKeep:    list = clips.filter { $0.isKeep }
        case .isNotKeep: list = clips.filter { !$0.isKeep }
        case .all:       list = clips
        }
        if let filterTeamID {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.teamID == filterTeamID }
            }
        }
        if let filterPlayerID {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.playerID == filterPlayerID }
            }
        }
        if let filterCategory {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.category == filterCategory }
            }
        }
        if let filterPosition {
            list = list.filter { clip in
                library.tags(forUMID: clip.umid).contains { $0.playerPosition == filterPosition }
            }
        }
        return list
    }

    var isTagFiltered: Bool {
        filterTeamID != nil || filterPlayerID != nil || filterCategory != nil || filterPosition != nil
    }

    func clearTagFilters() {
        filterTeamID = nil
        filterPlayerID = nil
        filterCategory = nil
        filterPosition = nil
    }

    /// The rosters the player menu should offer: just the chosen team, or all of them.
    var teamsForFilter: [Team] {
        guard let filterTeamID, let team = library.team(id: filterTeamID) else { return library.teams }
        return [team]
    }

    var keepCount: Int { clips.filter { $0.isKeep }.count }
    var notKeepCount: Int { clips.count - keepCount }
    var taggedCount: Int { clips.filter { library.isTagged($0.umid) }.count }

    /// The clip shown in the preview pane: the one clicked most recently, if it's still on screen.
    var previewClip: Clip? {
        if let last = lastSelected, let clip = visible.first(where: { $0.id == last }) { return clip }
        return visible.first { selection.contains($0.id) }
    }

    /// What gets dragged out: the selected clips, or everything in the current view if none are selected.
    var dragClips: [Clip] {
        let selected = visible.filter { selection.contains($0.id) }
        return selected.isEmpty ? visible : selected
    }

    /// The actual files to drag or copy: each video, plus its XML when "Include XML" is on.
    var dragURLs: [URL] {
        dragClips.flatMap { includeXML ? [$0.videoURL, $0.xmlURL] : [$0.videoURL] }
    }

    var dragSize: Int64 {
        dragClips.reduce(0) { $0 + (includeXML ? $1.totalSize : $1.videoSize) }
    }

    /// The clips the tag buttons act on: whatever is selected, or everything the filter
    /// is showing when nothing is — the same rule the drag bar and Copy to Folder use.
    var taggedInScope: [Clip] {
        dragClips.filter { library.isTagged($0.umid) }
    }

    var hasExplicitSelection: Bool {
        !visible.filter { selection.contains($0.id) }.isEmpty
    }

    var removeTagsLabel: String {
        let count = taggedInScope.count
        guard count > 0 else { return "No tags to remove" }
        return hasExplicitSelection
            ? "Remove tags from \(count) selected"
            : "Remove tags from all \(count) shown"
    }

    /// Destructive and unpickable from the clip list in bulk, so it asks first and spells
    /// out the scope — "all shown" is easy to trigger by not selecting anything.
    func removeTagsInScope() {
        let targets = taggedInScope
        guard !targets.isEmpty else { return }
        let tagCount = targets.reduce(0) { $0 + library.tags(forUMID: $1.umid).count }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(tagCount) tag\(tagCount == 1 ? "" : "s")?"
        alert.informativeText = hasExplicitSelection
            ? "This clears every tag from the \(targets.count) selected clip\(targets.count == 1 ? "" : "s"). It can't be undone."
            : "Nothing is selected, so this clears every tag from all \(targets.count) tagged clip\(targets.count == 1 ? "" : "s") the filter is showing. It can't be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Tags")
        guard alert.runModal() != .alertFirstButtonReturn else { return }

        let removed = library.removeAllTags(forUMIDs: targets.compactMap(\.umid))
        addLog("Removed \(removed) tag(s) from \(targets.count) clip(s)")
        status = "Removed \(removed) tag\(removed == 1 ? "" : "s") from \(targets.count) clip\(targets.count == 1 ? "" : "s")."
    }

    /// The files for one row's drag handle, honouring the Include XML setting.
    func urls(for clip: Clip) -> [URL] {
        includeXML ? [clip.videoURL, clip.xmlURL] : [clip.videoURL]
    }

    // MARK: - Logging

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Appends in one batch, so a 200-clip scan redraws the panel once instead of 200 times.
    func appendLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let stamp = Self.timeFormatter.string(from: Date())
        let stamped = lines.map { "\(stamp)  \($0)" }
        for line in stamped { print(line) }
        log.append(contentsOf: stamped)
    }

    func addLog(_ line: String) { appendLog([line]) }

    var logText: String { log.joined(separator: "\n") }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
        status = "Debug log copied to the clipboard."
    }

    // MARK: - Scanning

    func chooseCard() {
        guard !isScanning, !isCopying else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.message = "Choose a card, drive, or folder of clips"
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            root = url
            scan()
        }
    }

    func scan() {
        guard let root, !isScanning else { return }
        isScanning = true
        clips = []
        selection = []
        lastSelected = nil
        log = []
        status = "Scanning \(root.lastPathComponent)…"
        addLog("Scan started")
        let word = keepWord
        Task.detached(priority: .userInitiated) {
            let result = ClipScanner.scan(root: root, keepWord: word)
            await MainActor.run {
                self.clips = result.clips
                self.unmatchedXML = result.unmatchedXML
                self.videosWithoutXML = result.videosWithoutXML
                self.appendLog(result.log)
                self.isScanning = false
                self.status = result.clips.isEmpty
                    ? "No clips with XML sidecars were found in there."
                    : "Found \(result.clips.count) clips, \(result.clips.filter { $0.isKeep }.count) marked KEEP."
            }
        }
    }

    // MARK: - Copying

    /// One clip's files heading into one folder. They travel as a set so the video and its
    /// sidecar can be given the same base name — resolved once, after any clash is settled.
    /// A clip tagged with two players produces two jobs when grouping by player, which is
    /// the point: each gets a full set.
    /// One clip's files heading into one folder. They travel as a set so the video and its
    /// sidecar get the same base name — resolved once, after any clash is settled.
    /// A clip tagged with two players produces two jobs when grouping by player, which is
    /// the point: each gets a full set.
    struct CopyJob: Sendable {
        let sources: [URL]         // video first, sidecar after it when included
        let subfolder: String
        let baseName: String?      // nil keeps each file's own name
    }

    /// nil means "keep original names".
    var activePreset: RenamePreset? {
        guard let renamePresetID else { return nil }
        return library.presets.first { $0.id == renamePresetID }
    }

    func copyPlan() -> [CopyJob] {
        let preset = activePreset
        var jobs: [CopyJob] = []

        for clip in dragClips {
            let tags = library.tags(forUMID: clip.umid)

            let folders: [String]
            switch grouping {
            case .flat:
                folders = [""]
            case .byPlayer:
                // Still one folder per player the clip is tagged with: a player's folder
                // should hold every clip they appear in.
                let names = Set(tags.compactMap(\.folderSafePlayer))
                folders = names.isEmpty ? ["Untagged"] : names.sorted()
            case .byCategory:
                // Exactly one folder, matching the tag the file is being named after, so a
                // clip exists once rather than copied into every category it carries.
                let top = Renamer.topTag(of: tags, priority: library.categories)?.category
                folders = [top ?? "Untagged"]
            }

            // The video and its sidecar must share a base name, or they stop pairing up
            // when this folder is scanned later.
            let winningTeam = Renamer.topTag(of: tags, priority: library.categories)?.teamID
            let rosterCode = library.team(id: winningTeam).flatMap(\.code)
            let base = preset.map {
                Renamer.baseName(for: clip,
                                 tags: tags,
                                 preset: $0,
                                 priority: library.categories,
                                 rosterCode: rosterCode)
            }

            let sources = includeXML ? [clip.videoURL, clip.xmlURL] : [clip.videoURL]
            for folder in folders {
                jobs.append(CopyJob(sources: sources, subfolder: folder, baseName: base))
            }
        }
        return jobs
    }

    private func fileCount(_ jobs: [CopyJob]) -> Int {
        jobs.reduce(0) { $0 + $1.sources.count }
    }

    func copyToFolder() {
        guard !isCopying, !isScanning else { return }
        let picked = dragClips
        guard !picked.isEmpty else { return }
        let jobs = copyPlan()
        let totalFiles = fileCount(jobs)
        let needed = jobs.reduce(Int64(0)) { running, job in
            running + job.sources.reduce(Int64(0)) { $0 + max(0, FileUtil.size(of: $1)) }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose a destination for \(picked.count) clip(s) — "
            + "\(totalFiles) file(s), \(FileUtil.sizeText(needed))"
            + (grouping == .flat ? "" : " — \(grouping.rawValue.lowercased())")
            + (activePreset.map { " — renamed with \"\($0.name)\"" } ?? "")
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // A half-finished offload is worse than none, so check the space first.
        let destValues = try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let destValues, let free = destValues.volumeAvailableCapacityForImportantUsage, needed > free {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Not enough free space"
            alert.informativeText = "This copy needs \(FileUtil.sizeText(needed)), but only "
                + "\(FileUtil.sizeText(free)) is free on that disk."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Copy Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                addLog("Copy cancelled: needs \(FileUtil.sizeText(needed)), only \(FileUtil.sizeText(free)) free")
                status = "Copy cancelled, not enough free space."
                return
            }
        }

        isCopying = true
        copyFilesDone = 0
        copyFilesTotal = totalFiles
        copyBytesDone = 0
        copyBytesTotal = needed
        status = "Copying \(totalFiles) file(s)…"
        addLog("Copying \(totalFiles) file(s) (\(FileUtil.sizeText(needed))) to \(dest.path)"
               + (grouping == .flat ? "" : ", \(grouping.rawValue.lowercased())"))
        if let preset = activePreset, let first = jobs.first, let base = first.baseName,
           let video = first.sources.first {
            addLog("Renaming with \"\(preset.name)\" — e.g. \(video.lastPathComponent) → \(base).\(video.pathExtension)")
        }

        Task.detached(priority: .userInitiated) {
            var copied = 0
            var skipped = 0
            var failed = 0
            var lines: [String] = []
            let fm = FileManager.default

            var fileIndex = 0

            // Deliberately no early `continue` anywhere in here: every path has to reach the
            // progress update at the bottom, or the bar stalls on the first skipped file.
            for job in jobs {
                var folder = dest
                var folderReady = true
                if !job.subfolder.isEmpty {
                    folder = dest.appendingPathComponent(job.subfolder, isDirectory: true)
                    do {
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    } catch {
                        failed += 1
                        folderReady = false
                        lines.append("✗ \(job.subfolder): couldn't make that folder — \(error.localizedDescription)")
                    }
                }

                // Settle the shared base name once per clip, before any of its files move,
                // so the video and its sidecar can't end up named differently.
                var base = job.baseName
                if folderReady, let wanted = job.baseName, let video = job.sources.first {
                    let candidate = folder.appendingPathComponent("\(wanted).\(video.pathExtension)")
                    let sameClipAlreadyHere = fm.fileExists(atPath: candidate.path)
                        && FileUtil.size(of: candidate) == FileUtil.size(of: video)

                    if sameClipAlreadyHere {
                        // Keep the name rather than bumping it: the per-file checks below skip
                        // what matches and still fill in a sidecar that never made it last time.
                        base = wanted
                    } else {
                        let free = FileUtil.freeBase(wanted,
                                                     in: folder,
                                                     extensions: job.sources.map(\.pathExtension))
                        base = free
                        if free != wanted {
                            lines.append("⚠︎ \(wanted) was taken, this clip went in as \(free)")
                        }
                    }
                }

                for src in job.sources {
                    let name = base.map { "\($0).\(src.pathExtension)" } ?? src.lastPathComponent
                    let srcSize = FileUtil.size(of: src)
                    fileIndex += 1
                    let position = fileIndex

                    await MainActor.run {
                        self.status = "Copying \(position) of \(totalFiles): \(name)"
                    }

                    if folderReady {
                        var target = folder.appendingPathComponent(name)
                        var shouldCopy = true

                        if fm.fileExists(atPath: target.path) {
                            if FileUtil.size(of: target) == srcSize {
                                skipped += 1
                                shouldCopy = false
                                lines.append("– \(name): already in the destination, skipped")
                            } else if job.baseName != nil {
                                // Renaming: the base was already settled for the whole clip, so
                                // bumping one file now would split it from its sidecar.
                                skipped += 1
                                shouldCopy = false
                                lines.append("⚠︎ \(name): a different file of that name is already "
                                             + "there, left alone")
                            } else {
                                // Original names: never overwrite, never silently skip.
                                target = FileUtil.uniqueURL(for: target)
                                lines.append("⚠︎ \(name): a different file of that name was already there, "
                                             + "copied as \(target.lastPathComponent)")
                            }
                        }

                        if shouldCopy {
                            do {
                                try fm.copyItem(at: src, to: target)
                                let wrote = FileUtil.size(of: target)
                                if wrote == srcSize {
                                    copied += 1
                                } else {
                                    failed += 1
                                    lines.append("✗ \(name): copied \(wrote) bytes but the source is \(srcSize) bytes")
                                }
                            } catch {
                                failed += 1
                                lines.append("✗ \(name): \(error.localizedDescription)")
                            }
                        }
                    }

                    let moved = max(0, srcSize)
                    await MainActor.run {
                        self.copyFilesDone = position
                        self.copyBytesDone += moved
                    }
                }
            }

            let finalCopied = copied, finalSkipped = skipped, finalFailed = failed
            let finalLines = lines + ["Copy finished: \(finalCopied) copied, "
                                      + "\(finalSkipped) skipped, \(finalFailed) failed"]
            await MainActor.run {
                self.appendLog(finalLines)
                self.isCopying = false
                self.copyFilesDone = 0
                self.copyFilesTotal = 0
                self.copyBytesDone = 0
                self.copyBytesTotal = 0
                var message = "Copied \(finalCopied) file(s)"
                if finalSkipped > 0 { message += ", skipped \(finalSkipped) already there" }
                if finalFailed > 0 { message += ", \(finalFailed) FAILED — turn on Debug for details" }
                self.status = message + "."
            }
        }
    }
}
