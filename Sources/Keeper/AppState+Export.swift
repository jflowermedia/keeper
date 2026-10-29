import AppKit

// The export sheet's answers, copying, and renaming in place.
// Split out of AppState.swift; the stored state these read stays on the class.

extension AppState {

    /// What the export sheet will act on. Unlike `dragClips`, which infers a scope from
    /// the selection, this is whatever the sheet says it is — chosen deliberately.
    var exportClips: [Clip] {
        switch exportScope {
        case .selection: return visible.filter { selection.contains($0.id) }
        case .shown:     return visible
        }
    }

    var selectedCount: Int { visible.filter { selection.contains($0.id) }.count }

    /// Plain-English description of what the filters are currently showing.
    var filterSummary: String {
        var parts = [filter.rawValue]
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
        guard exportDestination == .copy, let dest = exportFolder else { return 0 }
        let destPath = FileUtil.folderPath(dest)
        // Resolving a path touches the disk, and this runs on every redraw of the sheet,
        // so each distinct folder is judged once — usually there's only one.
        var verdicts: [URL: Bool] = [:]
        return exportClips.filter { clip in
            let folder = clip.videoURL.deletingLastPathComponent()
            if let known = verdicts[folder] { return known }
            let inside = FileUtil.folderPath(folder).hasPrefix(destPath)
            verdicts[folder] = inside
            return inside
        }.count
    }

    /// Something worth reading before pressing the button, but the caller's decision to make.
    /// Unlike `exportBlocker` this doesn't disable anything — it only takes away the Return
    /// key, so the action has to be clicked deliberately.
    var exportCaution: String? {
        let inside = exportClipsInsideDestination
        guard inside > 0 else { return nil }
        let all = inside == exportClips.count
        return (all ? "These clips are already in that folder" :
                      "\(inside) of these clips are already in that folder")
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
            guard let folder = exportFolder else {
                return "Choose where the copies should go."
            }
            if !FileUtil.isReachableFolder(folder) {
                return "That folder isn't there any more. Is the drive still plugged in?"
            }
            // Writing into a camera's own folder structure is the one thing Keeper promises
            // never to do, and a changed flag would otherwise be written into the sidecar
            // sitting there — which is the original.
            if FileUtil.looksLikeCameraCard(folder) {
                return "That folder is inside a camera card's own structure. Keeper only ever "
                     + "reads those — pick somewhere else to copy to."
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
        guard !isCopying, !isScanning, !visible.isEmpty else { return }
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
            if let folder = exportFolder { copy(to: folder) }
        }
    }

    // MARK: - Copying

    /// One clip's files heading into one folder. They travel as a set so the video and its
    /// sidecar get the same base name — resolved once, after any clash is settled.
    /// A clip tagged with two players produces two jobs when grouping by player, which is
    /// the point: each gets a full set.
    struct CopyJob: Sendable {
        let sources: [URL]         // video first, sidecar after it when included
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

    @discardableResult
    func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should the copies go?"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        exportFolder = url
        return url
    }

    func copy(to dest: URL) {
        guard !isCopying, !isScanning else { return }
        let picked = exportClips
        guard !picked.isEmpty else { return }
        let jobs = copyPlan()
        let totalFiles = fileCount(jobs)
        let needed = jobs.reduce(Int64(0)) { running, job in
            running + job.sources.reduce(Int64(0)) { $0 + max(0, FileUtil.size(of: $1)) }
        }

        // A half-finished offload is worse than none, so check the space first.
        // The APFS-aware figure is the accurate one, but it reads 0 on exFAT and other
        // non-APFS volumes — which is how most external video drives are formatted. Fall back
        // to the plain figure, and treat "can't tell" as fine rather than as full, so a
        // perfectly healthy SSD is never reported as out of space.
        let freeSpace = FileUtil.freeSpace(at: dest)
        let readings = FileUtil.freeSpaceReadings(at: dest)
        addLog("Destination free space — "
               + "important usage: \(readings.important.map(FileUtil.sizeText) ?? "unavailable"), "
               + "plain: \(readings.plain.map(FileUtil.sizeText) ?? "unavailable"), "
               + "using: \(freeSpace.map(FileUtil.sizeText) ?? "neither, so the check is skipped")")

        if let free = freeSpace, needed > free {
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
                if finalFailed == 0, finalCopied + finalSkipped > 0 { self.verifySuggestion = dest }
            }
        }
    }
}
