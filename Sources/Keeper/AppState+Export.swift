import AppKit

// The export sheet's answers, copying, and renaming in place.
// Split out of AppState.swift; the stored state these read stays on the class.

extension AppState {

    /// What the export sheet will act on. Unlike `dragClips`, which infers a scope from
    /// the selection, this is whatever the sheet says it is — chosen deliberately.
    var exportClips: [Clip] {
        switch exportScope {
        case .selection: return visible.filter { selection.contains($0.id) }
        // Split by flag, everything shown means both flags of what the tag filters show. The
        // list sitting on Kept, as it does by default, is exactly when you'd reach for this.
        case .shown:     return splitsByKeep ? matchingTagFilters(clips) : visible
        }
    }

    /// Only a copy can be split. Renaming in place leaves every file where it is.
    var splitsByKeep: Bool { splitByKeep && exportDestination == .copy }

    /// Where one clip's copy goes. Copying, the counts and the warnings all ask this, so they
    /// can't disagree about which folder a clip is headed for.
    func copyFolder(for clip: Clip) -> URL? {
        KeepSplit.folder(keep: isKeep(clip), split: splitsByKeep,
                         kept: exportFolder, notKept: notKeptFolder)
    }

    /// How the export divides up when it's split, for the sheet to show beside each folder.
    var exportSplitCounts: (kept: Int, notKept: Int) {
        let kept = exportClips.filter { isKeep($0) }.count
        return (kept, exportClips.count - kept)
    }

    var selectedCount: Int { visible.filter { selection.contains($0.id) }.count }

    /// How many clips the sheet would open on. The Export button's label, whether it's
    /// enabled, and `requestExport` all use this, so a button can't offer thirty clips and
    /// then refuse to open — which a Kept list with nothing in it, split by flag, did.
    var exportButtonCount: Int {
        if selectedCount > 0 { return selectedCount }
        return splitsByKeep ? matchingTagFilters(clips).count : visible.count
    }

    /// Plain-English description of what the export sheet's scope is drawn from. Split by
    /// flag, the KEEP filter is set aside — see `exportClips`.
    var filterSummary: String {
        var parts = [splitsByKeep && exportScope == .shown ? "Kept and not kept" : filter.rawValue]
        if let id = filterTeamID, let team = library.team(id: id) { parts.append(team.name) }
        if let id = filterPlayerID,
           let player = library.allPlayers.first(where: { $0.id == id }) { parts.append(player.label) }
        if let position = filterPosition { parts.append(position) }
        if let category = filterCategory { parts.append(category) }
        return parts.joined(separator: " · ")
    }

    /// The folder in-place renaming would act on, when they're all in one.
    var exportSourceFolder: URL? {
        let folders = Set(exportClips.map { $0.videoURL.deletingLastPathComponent() })
        return folders.count == 1 ? folders.first : nil
    }

    var exportIsOnCard: Bool {
        exportClips.contains { FileUtil.looksLikeCameraCard($0.videoURL) }
    }

    /// One example of the renaming, for the sheet's preview.
    var exportNameExample: (from: String, to: String)? {
        guard let preset = activePreset, let clip = exportClips.first else { return nil }
        let tags = library.tags(forUMID: clip.umid)
        let rosterCode = library
            .team(id: Renamer.topTag(of: tags, priority: library.allCategories)?.teamID)
            .flatMap(\.code)
        let base = Renamer.baseName(for: clip, tags: tags, preset: preset,
                                    priority: library.allCategories, rosterCode: rosterCode)
        return (clip.name, "\(base).\(clip.videoURL.pathExtension)")
    }

    /// Clips in this export that will carry the name of someone no longer on a roster, and
    /// who. Not a caution: usually it's a traded player and exactly right. It's here so a
    /// name that was never meant to stay is seen before it's in a filename, not after.
    ///
    /// Only the tags whose name actually lands: the top tag when the preset uses a player
    /// part, every player tag when copying a folder per player. A note about a tag that
    /// changes nothing would teach you to ignore the one that does.
    var exportFormerPlayers: (clips: [String], players: [String]) {
        let playerParts: Set<NameToken> = [.playerSurname, .playerFirstName, .playerNumber]
        let inName = activePreset.map { !playerParts.isDisjoint(with: $0.tokens) } ?? false
        let inFolder = exportDestination == .copy && grouping == .byPlayer
        guard inName || inFolder else { return ([], []) }

        var clips: [String] = []
        var players: [String] = []
        for clip in exportClips {
            let tags = library.tags(forUMID: clip.umid)
            var used = inFolder ? tags.filter { $0.folderSafePlayer != nil } : []
            if inName, let top = Renamer.topTag(of: tags, priority: library.allCategories) {
                used.append(top)
            }
            let former = used.filter { library.isFormerPlayer($0) }
            guard !former.isEmpty else { continue }
            clips.append(clip.name)
            for label in former.compactMap(\.playerLabel) where !players.contains(label) {
                players.append(label)
            }
        }
        return (clips, players)
    }

    /// How many copies of one clip this layout makes. Only per-player ever makes more than
    /// one, and only for a clip tagged to several players. Must agree with `copyPlan()`.
    private func copiesPerClip(_ clip: Clip) -> Int {
        guard grouping == .byPlayer else { return 1 }
        let players = Set(library.tags(forUMID: clip.umid).compactMap(\.folderSafePlayer))
        return max(1, players.count)
    }

    /// Both of these run on every redraw of the sheet, so they use the sizes the scan
    /// already recorded rather than stat'ing every file again — which on a card full of
    /// clips made the radio buttons feel sticky.
    var exportFileCount: Int {
        guard exportDestination == .copy else { return exportClips.count }
        let perCopy = includeXML ? 2 : 1
        return exportClips.reduce(0) { $0 + perCopy * copiesPerClip($1) }
    }

    var exportSize: Int64 {
        guard exportDestination == .copy else { return exportClips.reduce(0) { $0 + $1.totalSize } }
        return exportClips.reduce(Int64(0)) { running, clip in
            let each = clip.videoSize + (includeXML ? clip.xmlSize : 0)
            return running + each * Int64(copiesPerClip(clip))
        }
    }

    var exportFlagChanges: Int { exportClips.filter { isKeepChanged($0) }.count }

    /// How many clips would actually get a new name. Anything already named correctly is
    /// left alone, so the button can say the real number rather than the scope's.
    var exportRenameCount: Int {
        guard let preset = activePreset else { return 0 }
        return exportClips.filter { clip in
            let tags = library.tags(forUMID: clip.umid)
            let rosterCode = library
                .team(id: Renamer.topTag(of: tags, priority: library.allCategories)?.teamID)
                .flatMap(\.code)
            let base = Renamer.baseName(for: clip, tags: tags, preset: preset,
                                        priority: library.allCategories, rosterCode: rosterCode)
            return base != clip.videoURL.deletingPathExtension().lastPathComponent
        }.count
    }

    /// Clips in this export that already live in the copy destination, or anywhere under it.
    /// Copying those is how you end up with the footage twice — the original under the
    /// camera's name and a copy under the new one — which is the whole reason renaming in
    /// place exists. It's remembering the last destination that makes this easy to walk
    /// into: offload to Cam A, come back later to tag Cam A, and the sheet is still aimed
    /// at Cam A.
    var exportClipsInsideDestination: Int {
        guard exportDestination == .copy else { return 0 }
        // Resolving a path touches the disk, and this runs on every redraw of the sheet,
        // so each distinct pair of folders is judged once — usually there's only one.
        var destPaths: [URL: String] = [:]
        var verdicts: [[URL]: Bool] = [:]
        return exportClips.filter { clip in
            guard let dest = copyFolder(for: clip) else { return false }
            let folder = clip.videoURL.deletingLastPathComponent()
            if let known = verdicts[[folder, dest]] { return known }
            let destPath = destPaths[dest] ?? FileUtil.folderPath(dest)
            destPaths[dest] = destPath
            let inside = FileUtil.folderPath(folder).hasPrefix(destPath)
            verdicts[[folder, dest]] = inside
            return inside
        }.count
    }

    /// The folders this copy writes into, kept first. One unless it's split, and then only
    /// the halves that have clips in them.
    var exportCopyFolders: [URL] {
        guard splitsByKeep else { return exportFolder.map { [$0] } ?? [] }
        let counts = exportSplitCounts
        var folders: [URL] = []
        if counts.kept > 0, let kept = exportFolder { folders.append(kept) }
        if counts.notKept > 0, let notKept = notKeptFolder, !folders.contains(notKept) {
            folders.append(notKept)
        }
        return folders
    }

    /// Something worth reading before pressing the button, but the caller's decision to make.
    /// Unlike `exportBlocker` this doesn't disable anything — it only takes away the Return
    /// key, so the action has to be clicked deliberately.
    var exportCaution: String? {
        let inside = exportClipsInsideDestination
        guard inside > 0 else { return nil }
        let all = inside == exportClips.count
        let place = splitsByKeep ? "the folder they'd be copied to" : "that folder"
        return (all ? "These clips are already in \(place)" :
                      "\(inside) of these clips are already in \(place)")
            + ". Copying them there leaves you with the same footage twice, once under each "
            + "name. To get the new names without a second copy, choose “Rename them where "
            + "they already are”."
    }

    var exportBlocker: String? {
        if exportClips.isEmpty {
            return exportScope == .selection
                ? "Nothing is selected. Pick some clips, or switch to everything the filter is showing."
                : "Nothing to export — the filter isn't showing any clips."
        }
        if exportDestination == .inPlace {
            if exportIsOnCard {
                return "These files are on a camera card. Keeper only reads cards, so copy them off first."
            }
            if activePreset == nil {
                return "Renaming needs a filename preset."
            }
            if exportRenameCount == 0, exportFlagChanges == 0 {
                return "Nothing to do — these clips are already named correctly."
            }
        }
        if exportDestination == .copy {
            // A half with nothing in it doesn't need a folder: splitting a list that turns
            // out to be all kept shouldn't hold the copy up over a folder it will never use.
            let counts = exportSplitCounts
            let halves: [(folder: URL?, needed: Bool, name: String)] = splitsByKeep
                ? [(exportFolder, counts.kept > 0, "kept clips"),
                   (notKeptFolder, counts.notKept > 0, "not-kept clips")]
                : [(exportFolder, true, "copies")]
            for half in halves where half.needed {
                guard let folder = half.folder else {
                    return "Choose where the \(half.name) should go."
                }
                let which = splitsByKeep ? "The \(half.name)' folder" : "That folder"
                if !FileUtil.isReachableFolder(folder) {
                    return "\(which) isn't there any more. Is the drive still plugged in?"
                }
                // Writing into a camera's own folder structure is the one thing Keeper
                // promises never to do, and a changed flag would otherwise be written into
                // the sidecar sitting there — which is the original.
                if FileUtil.looksLikeCameraCard(folder) {
                    return "\(which) is inside a camera card's own structure. Keeper only ever "
                         + "reads those — pick somewhere else to copy to."
                }
            }
            if splitsByKeep, counts.kept > 0, counts.notKept > 0,
               let kept = exportFolder, let notKept = notKeptFolder, FileUtil.sameFile(kept, notKept) {
                return "Kept and not-kept clips are both set to go to the same folder. Choose a "
                     + "different one for either, or turn off sending them to separate folders."
            }
        }
        return nil
    }

    /// Opens the sheet. The scope starts as whatever you'd expect from what you were just
    /// doing: a selection if you made one, otherwise everything in view.
    func requestExport() {
        // While the shortcuts sheet is recording a key, a ⌘ combo is meant for the recorder.
        // The event monitor should get it first, but this is cheap and means the worst case
        // is a key that didn't record rather than an export sheet appearing underneath.
        guard !showShortcutsSheet else { return }
        guard !isCopying, !isScanning, exportButtonCount > 0 else { return }
        exportScope = selectedCount > 0 ? .selection : .shown
        // Scope first, because this reads it. Footage on a card can only be copied off, so
        // the sheet doesn't open on an option that's already blocked.
        if exportIsOnCard { exportDestination = .copy }
        showExportSheet = true
    }

    func runExport() {
        guard exportBlocker == nil else { return }
        switch exportDestination {
        case .inPlace:
            renameInPlace()
        case .copy:
            copy()
        }
    }

    // MARK: - Copying

    /// One clip's files heading into one folder. They travel as a set so the video and its
    /// sidecar get the same base name — resolved once, after any clash is settled.
    /// A clip tagged with two players produces two jobs when grouping by player, which is
    /// the point: each gets a full set.
    struct CopyJob: Sendable {
        let sources: [URL]         // video first, sidecar after it when included
        let destination: URL       // the folder chosen for this clip's flag
        let subfolder: String
        let baseName: String?      // nil keeps each file's own name
        /// Set when you've changed this clip's flag: the copied sidecar gets it written in.
        let writeKeep: Bool?
    }

    /// nil means "keep original names".
    var activePreset: RenamePreset? {
        guard let renamePresetID else { return nil }
        return library.presets.first { $0.id == renamePresetID }
    }

    func copyPlan() -> [CopyJob] {
        let preset = activePreset
        var jobs: [CopyJob] = []

        for clip in exportClips {
            // Only missing when the sheet would have blocked the copy.
            guard let destination = copyFolder(for: clip) else { continue }
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
                let top = Renamer.topTag(of: tags, priority: library.allCategories)?.category
                folders = [top ?? "Untagged"]
            }

            // The video and its sidecar must share a base name, or they stop pairing up
            // when this folder is scanned later.
            let winningTeam = Renamer.topTag(of: tags, priority: library.allCategories)?.teamID
            let rosterCode = library.team(id: winningTeam).flatMap(\.code)
            let base = preset.map {
                Renamer.baseName(for: clip,
                                 tags: tags,
                                 preset: $0,
                                 priority: library.allCategories,
                                 rosterCode: rosterCode)
            }

            let sources = includeXML ? [clip.videoURL, clip.xmlURL] : [clip.videoURL]
            let override = isKeepChanged(clip) ? isKeep(clip) : nil
            for folder in folders {
                jobs.append(CopyJob(sources: sources,
                                    destination: destination,
                                    subfolder: folder,
                                    baseName: base,
                                    writeKeep: override))
            }
        }
        return jobs
    }

    private func fileCount(_ jobs: [CopyJob]) -> Int {
        jobs.reduce(0) { $0 + $1.sources.count }
    }

    // MARK: - Renaming where the files already are

    /// For footage already offloaded: rename it where it sits rather than copying it again.
    /// Without this, getting named files means a second copy of the same footage — one set
    /// under the camera's names from the rush edit, one renamed.
    ///
    /// Only `ExportSheet` calls this, and the sheet is the confirmation: it states the
    /// counts, the folder and the broken-links warning before the button is pressed.
    func renameInPlace() {
        guard !isCopying, !isScanning else { return }
        guard let preset = activePreset else {
            status = "Pick a filename preset first — renaming uses the same preset as copying."
            return
        }

        let scope = exportClips
        guard !scope.isEmpty else { return }

        // The sheet blocks this already. It stays as a last line of defence, because this is
        // the one mistake that would write to a card.
        if scope.contains(where: { FileUtil.looksLikeCameraCard($0.videoURL) }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "These files are on a camera card"
            alert.informativeText = "Keeper only ever reads cards. Copy the footage off first, "
                + "then rename it where it lands."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Work out the new names first, so the confirmation can be specific and nothing
        // is touched if there's nothing to do.
        var plan: [(clip: Clip, base: String)] = []
        for clip in scope {
            let tags = library.tags(forUMID: clip.umid)
            let rosterCode = library
                .team(id: Renamer.topTag(of: tags, priority: library.allCategories)?.teamID)
                .flatMap(\.code)
            let base = Renamer.baseName(for: clip,
                                        tags: tags,
                                        preset: preset,
                                        priority: library.allCategories,
                                        rosterCode: rosterCode)
            if base != clip.videoURL.deletingPathExtension().lastPathComponent {
                plan.append((clip, base))
            }
        }

        let flagChanges = scope.filter { isKeepChanged($0) }.count
        guard !plan.isEmpty || flagChanges > 0 else {
            status = "Everything in view is already named correctly."
            return
        }

        performRename(plan, flagWord: keepWord)
    }

    private func performRename(_ plan: [(clip: Clip, base: String)], flagWord: String) {
        let fm = FileManager.default
        var renamed = 0
        var flagged = 0
        var failed = 0
        var lines: [String] = []
        var handled = Set<URL>()

        addLog("Renaming \(plan.count) clip(s) in place")

        for entry in plan {
            let clip = entry.clip
            let folder = clip.videoURL.deletingLastPathComponent()
            let extensions = [clip.videoURL.pathExtension, clip.xmlURL.pathExtension]
            let base = FileUtil.freeBase(entry.base, in: folder, extensions: extensions)

            var movedAll = true
            for source in [clip.videoURL, clip.xmlURL] {
                let target = source.deletingLastPathComponent()
                    .appendingPathComponent("\(base).\(source.pathExtension)")
                guard target != source else { continue }
                do {
                    try fm.moveItem(at: source, to: target)
                } catch {
                    movedAll = false
                    failed += 1
                    lines.append("✗ \(source.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if movedAll {
                renamed += 1
                lines.append("→ \(clip.name) renamed to \(base).\(clip.videoURL.pathExtension)")
                handled.insert(clip.id)

                // While we're editing this folder, make the sidecar say what the app says.
                if isKeepChanged(clip), let umid = clip.umid {
                    let xml = folder.appendingPathComponent("\(base).\(clip.xmlURL.pathExtension)")
                    do {
                        if try KeepWriter.apply(keep: isKeep(clip), word: flagWord, toXMLAt: xml) {
                            flagged += 1
                        }
                        // No undo label on purpose: the flag is now written into the
                        // file on disk, so putting the override back would only make the
                        // library disagree with it.
                        library.clearKeepOverride(umid: umid, undoLabel: nil)
                    } catch {
                        lines.append("✗ \(base): flag couldn't be written — \(error.localizedDescription)")
                    }
                }
            }
        }

        // Clips that only needed a flag change, with no rename.
        for clip in exportClips where !handled.contains(clip.id) && isKeepChanged(clip) {
            guard let umid = clip.umid else { continue }
            do {
                if try KeepWriter.apply(keep: isKeep(clip), word: flagWord, toXMLAt: clip.xmlURL) {
                    flagged += 1
                    lines.append("✎ \(clip.xmlURL.lastPathComponent): flag set to "
                                 + (isKeep(clip) ? flagWord : "not \(flagWord)"))
                }
                library.clearKeepOverride(umid: umid, undoLabel: nil)   // written to the file
            } catch {
                lines.append("✗ \(clip.xmlURL.lastPathComponent): flag couldn't be written — "
                             + error.localizedDescription)
            }
        }

        appendLog(lines + ["In-place rename finished: \(renamed) renamed, "
                           + "\(flagged) flag(s) written, \(failed) failed"])
        status = "Renamed \(renamed) clip(s) in place"
            + (flagged > 0 ? ", wrote \(flagged) flag(s)" : "")
            + (failed > 0 ? ", \(failed) FAILED — see the debug log" : "")
            + "."
        scan()   // the names on disk have changed, so the list has to be rebuilt
    }

    /// `notKept` picks the second folder of a copy split by flag.
    @discardableResult
    func chooseExportFolder(notKept: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = !splitsByKeep ? "Where should the copies go?"
            : notKept ? "Where should the not-kept clips go?"
            : "Where should the kept clips go?"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if notKept { notKeptFolder = url } else { exportFolder = url }
        return url
    }

    func copy() {
        guard !isCopying, !isScanning else { return }
        let picked = exportClips
        guard !picked.isEmpty else { return }
        let jobs = copyPlan()
        guard !jobs.isEmpty else { return }
        let totalFiles = fileCount(jobs)
        func bytes(_ job: CopyJob) -> Int64 {
            job.sources.reduce(Int64(0)) { $0 + max(0, FileUtil.size(of: $1)) }
        }
        let needed = jobs.reduce(Int64(0)) { $0 + bytes($1) }
        let destinations = exportCopyFolders

        // A half-finished offload is worse than none, so check the space first.
        // The APFS-aware figure is the accurate one, but it reads 0 on exFAT and other
        // non-APFS volumes — which is how most external video drives are formatted. Fall back
        // to the plain figure, and treat "can't tell" as fine rather than as full, so a
        // perfectly healthy SSD is never reported as out of space.
        //
        // Per disk, not per folder: a copy split into two folders on one drive draws on the
        // same free space twice, and checking each half alone would pass a copy that can't fit.
        var volumes: [URL] = []
        var neededOn: [URL: Int64] = [:]
        for job in jobs {
            let volume = FileUtil.volume(of: job.destination)
            if neededOn[volume] == nil { volumes.append(volume) }
            neededOn[volume, default: 0] += bytes(job)
        }
        for volume in volumes {
            let needs = neededOn[volume] ?? 0
            let freeSpace = FileUtil.freeSpace(at: volume)
            let readings = FileUtil.freeSpaceReadings(at: volume)
            addLog("Destination free space on \(volume.path) — "
                   + "important usage: \(readings.important.map(FileUtil.sizeText) ?? "unavailable"), "
                   + "plain: \(readings.plain.map(FileUtil.sizeText) ?? "unavailable"), "
                   + "using: \(freeSpace.map(FileUtil.sizeText) ?? "neither, so the check is skipped")")

            if let free = freeSpace, needs > free {
                // "/" is what the startup disk's URL ends in, so ask for the name Finder shows.
                let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?
                    .volumeLocalizedName ?? volume.lastPathComponent
                let disk = volumes.count > 1 ? "on \(name)" : "on that disk"
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Not enough free space"
                alert.informativeText = "This copy needs \(FileUtil.sizeText(needs)) \(disk), but "
                    + "only \(FileUtil.sizeText(free)) is free there."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Copy Anyway")
                if alert.runModal() == .alertFirstButtonReturn {
                    addLog("Copy cancelled: needs \(FileUtil.sizeText(needs)) on \(volume.path), "
                           + "only \(FileUtil.sizeText(free)) free")
                    status = "Copy cancelled, not enough free space."
                    return
                }
            }
        }

        copyFilesDone = 0
        copyFilesTotal = totalFiles
        copyBytesDone = 0
        copyBytesTotal = needed
        status = "Copying \(totalFiles) file(s)…"
        let whereTo: String
        if splitsByKeep {
            let counts = exportSplitCounts
            var halves: [String] = []
            if counts.kept > 0, let kept = exportFolder {
                halves.append("\(counts.kept) kept clip(s) to \(kept.path)")
            }
            if counts.notKept > 0, let notKept = notKeptFolder {
                halves.append("\(counts.notKept) not kept to \(notKept.path)")
            }
            whereTo = "— " + halves.joined(separator: ", ")
        } else {
            whereTo = "to " + (destinations.first?.path ?? "")
        }
        addLog("Copying \(totalFiles) file(s) (\(FileUtil.sizeText(needed))) \(whereTo)"
               + (grouping == .flat ? "" : ", \(grouping.rawValue.lowercased())"))
        if let preset = activePreset, let first = jobs.first, let base = first.baseName,
           let video = first.sources.first {
            addLog("Renaming with \"\(preset.name)\" — e.g. \(video.lastPathComponent) → \(base).\(video.pathExtension)")
        }

        let changedInBatch = jobs.filter { $0.writeKeep != nil }.count
        if changedInBatch > 0 {
            addLog(includeXML
                   ? "\(changedInBatch) clip(s) have a changed flag, written into the copied XML"
                   : "⚠︎ \(changedInBatch) clip(s) have a changed flag, but Include XML is off so "
                     + "it can't travel with them")
        }

        let flagWord = keepWord

        // Raised last, immediately before the work starts, for two reasons: it's the flag
        // that holds the Mac awake, so the log reads in the order things happen rather than
        // announcing the sleep hold before the copy it's for; and if anything above ever
        // grows an early return, the gate won't already be up with no job behind it.
        // Everything from here to the `Task` runs synchronously on the main actor, so the
        // UI never sees a half-set state.
        isCopying = true

        Task.detached(priority: .userInitiated) {
            var copied = 0
            var skipped = 0
            var failed = 0
            var lines: [String] = []
            let fm = FileManager.default

            var fileIndex = 0

            // A destination that has filled up, gone offline or turned out to be read-only
            // fails every single file, and the old behaviour was to keep going and write one
            // identical error per file — seventy lines of log for one problem, with the copy
            // still claiming to be in progress. Five in a row is taken as the destination
            // itself being the problem, and the whole copy stops there.
            var consecutiveFailures = 0
            var stoppedEarly = false
            let failureLimit = 5

            // Deliberately no early `continue` anywhere in here: every path has to reach the
            // progress update at the bottom, or the bar stalls on the first skipped file.
            copying: for job in jobs {
                var folder = job.destination
                var folderReady = true
                if !job.subfolder.isEmpty {
                    folder = job.destination.appendingPathComponent(job.subfolder, isDirectory: true)
                    do {
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    } catch {
                        failed += 1
                        folderReady = false
                        lines.append("✗ \(job.subfolder): couldn't make that folder — \(error.localizedDescription)")
                        // Counted here rather than per file: with no folder the loop below
                        // neither succeeds nor fails, so it would reset the tally each time
                        // and a destination refusing every folder would never trip the limit.
                        consecutiveFailures += 1
                        if consecutiveFailures >= failureLimit {
                            stoppedEarly = true
                            break copying
                        }
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
                    let failedBefore = failed

                    await MainActor.run {
                        self.status = "Copying \(position) of \(totalFiles): \(name)"
                    }

                    if folderReady {
                        var target = folder.appendingPathComponent(name)
                        var shouldCopy = true
                        let isSidecar = src.pathExtension.lowercased() == "xml"

                        // A sidecar carrying a changed flag that's already at the destination
                        // gets the flag applied in place. Otherwise copying the same selection
                        // twice would skip it as a duplicate and quietly lose the change.
                        //
                        // `sameFile` is the guard that keeps this honest. Copy into the folder
                        // the clips are already in and the target IS the source, so this would
                        // edit the original — and on a card, that would break the one promise
                        // Keeper makes. The sheet blocks a card destination; this makes sure
                        // the originals are never touched wherever they are.
                        if isSidecar, let wanted = job.writeKeep, fm.fileExists(atPath: target.path),
                           !FileUtil.sameFile(target, src) {
                            shouldCopy = false
                            do {
                                let edited = try KeepWriter.apply(keep: wanted,
                                                                  word: flagWord,
                                                                  toXMLAt: target)
                                skipped += 1
                                lines.append(edited
                                    ? "✎ \(name): already there, flag set to "
                                      + (wanted ? flagWord : "not \(flagWord)")
                                    : "– \(name): already there with the right flag, skipped")
                            } catch {
                                failed += 1
                                lines.append("✗ \(name): already there, but the flag couldn't be "
                                             + "changed — \(error.localizedDescription)")
                            }
                        } else if fm.fileExists(atPath: target.path) {
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

                                    // The flag you changed in the app goes into the copy, never
                                    // the card. Done after the size check so a bad copy is still
                                    // reported as a bad copy.
                                    if isSidecar, let wanted = job.writeKeep {
                                        do {
                                            let edited = try KeepWriter.apply(keep: wanted,
                                                                              word: flagWord,
                                                                              toXMLAt: target)
                                            if edited {
                                                lines.append("✎ \(name): flag set to "
                                                             + (wanted ? flagWord : "not \(flagWord)"))
                                            }
                                        } catch {
                                            failed += 1
                                            lines.append("✗ \(name): copied, but the flag couldn't "
                                                         + "be changed — \(error.localizedDescription)")
                                        }
                                    }
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

                    // Only while there's a folder to write into: with a dead folder nothing
                    // here succeeded or failed, and resetting would hide the folder's own
                    // failures counted above.
                    if folderReady {
                        consecutiveFailures = failed > failedBefore ? consecutiveFailures + 1 : 0
                    }

                    let moved = max(0, srcSize)
                    await MainActor.run {
                        self.copyFilesDone = position
                        self.copyBytesDone += moved
                    }

                    // After the progress update, so the bar shows how far it actually got.
                    if consecutiveFailures >= failureLimit {
                        stoppedEarly = true
                        break copying
                    }
                }
            }

            // Everything the closure below reads has to be a `let`. Capturing a `var` from
            // out here in concurrently-executing code is a warning now and an error under
            // Swift 6, which is what the rest of these copies are for.
            let finalCopied = copied, finalSkipped = skipped, finalFailed = failed
            let reachedFile = fileIndex
            let halted = stoppedEarly

            var assembled = lines
            if halted {
                assembled.append("■ STOPPED after \(failureLimit) failures in a row, at file "
                                 + "\(reachedFile) of \(totalFiles). The destination is most "
                                 + "likely full, disconnected or read-only. Nothing already "
                                 + "copied was removed, and nothing was touched at the source.")
            }
            assembled.append("Copy finished: \(finalCopied) copied, "
                             + "\(finalSkipped) skipped, \(finalFailed) failed")
            let finalLines = assembled

            await MainActor.run {
                self.appendLog(finalLines)
                self.isCopying = false
                self.copyFilesDone = 0
                self.copyFilesTotal = 0
                self.copyBytesDone = 0
                self.copyBytesTotal = 0
                if halted {
                    // Said plainly and first: this copy is incomplete, and the card it came
                    // from must not be formatted on the strength of it.
                    self.status = "Copy STOPPED after \(failureLimit) failures in a row — "
                        + "\(finalCopied) of \(totalFiles) file(s) had copied. Check the "
                        + "destination has room and is still connected, then run it again. "
                        + "Turn on Debug for the errors."
                    return
                }
                var message = "Copied \(finalCopied) file(s)"
                if finalSkipped > 0 { message += ", skipped \(finalSkipped) already there" }
                if finalFailed > 0 { message += ", \(finalFailed) FAILED — turn on Debug for details" }
                self.status = message + "."
                // Not after failures: the copy is incomplete, and the status already says so.
                if finalFailed == 0, finalCopied + finalSkipped > 0 { self.verifySuggestions = destinations }
            }
        }
    }
}

/// Which folder a clip goes to when an export is split by its KEEP flag. Kept apart from the
/// app's state so the rule can be checked on its own.
enum KeepSplit {
    static func folder(keep: Bool, split: Bool, kept: URL?, notKept: URL?) -> URL? {
        split && !keep ? notKept : kept
    }
}
