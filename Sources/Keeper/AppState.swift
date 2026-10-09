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

    @Published var root: URL?
    @Published var clips: [Clip] = []
    @Published var unmatchedXML: [URL] = []
    @Published var videosWithoutXML: [URL] = []
    @Published var isScanning = false
    @Published var isCopying = false
    @Published var log: [String] = []
    @Published var status = "Choose your SD card to begin."

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

    init() {
        keepWord = UserDefaults.standard.string(forKey: "keepWord") ?? "KEEP"
        if UserDefaults.standard.object(forKey: "includeXML") != nil {
            includeXML = UserDefaults.standard.bool(forKey: "includeXML")
        }
        debugMode = UserDefaults.standard.bool(forKey: "debugMode")
    }

    // MARK: - Derived state

    var visible: [Clip] {
        switch filter {
        case .isKeep: return clips.filter { $0.isKeep }
        case .isNotKeep: return clips.filter { !$0.isKeep }
        case .all: return clips
        }
    }

    var keepCount: Int { clips.filter { $0.isKeep }.count }
    var notKeepCount: Int { clips.count - keepCount }

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
        panel.message = "Choose the SD card (or its clip folder)"
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
                    ? "No clips with XML files were found on this card."
                    : "Found \(result.clips.count) clips, \(result.clips.filter { $0.isKeep }.count) marked KEEP."
            }
        }
    }

    // MARK: - Copying

    func copyToFolder() {
        guard !isCopying, !isScanning else { return }
        let picked = dragClips
        guard !picked.isEmpty else { return }
        let files = dragURLs
        let needed = dragSize

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose a destination for \(picked.count) clip(s) — "
            + "\(files.count) file(s), \(FileUtil.sizeText(needed))"
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
        status = "Copying \(files.count) file(s)…"
        addLog("Copying \(files.count) file(s) (\(FileUtil.sizeText(needed))) to \(dest.path)")

        Task.detached(priority: .userInitiated) {
            var copied = 0
            var skipped = 0
            var failed = 0
            var lines: [String] = []
            let fm = FileManager.default

            for (index, src) in files.enumerated() {
                let name = src.lastPathComponent
                await MainActor.run {
                    self.status = "Copying \(index + 1) of \(files.count): \(name)"
                }

                let srcSize = FileUtil.size(of: src)
                var target = dest.appendingPathComponent(name)

                if fm.fileExists(atPath: target.path) {
                    if FileUtil.size(of: target) == srcSize {
                        skipped += 1
                        lines.append("– \(name): already in the destination, skipped")
                        continue
                    }
                    // Same name, different file: never overwrite, and never silently skip.
                    target = FileUtil.uniqueURL(for: target)
                    lines.append("⚠︎ \(name): a different file of that name was already there, "
                                 + "copied as \(target.lastPathComponent)")
                }

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

            let finalCopied = copied, finalSkipped = skipped, finalFailed = failed
            let finalLines = lines + ["Copy finished: \(finalCopied) copied, "
                                      + "\(finalSkipped) skipped, \(finalFailed) failed"]
            await MainActor.run {
                self.appendLog(finalLines)
                self.isCopying = false
                var message = "Copied \(finalCopied) file(s)"
                if finalSkipped > 0 { message += ", skipped \(finalSkipped) already there" }
                if finalFailed > 0 { message += ", \(finalFailed) FAILED — turn on Debug for details" }
                self.status = message + "."
            }
        }
    }
}
