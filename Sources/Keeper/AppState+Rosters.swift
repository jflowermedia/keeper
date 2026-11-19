import AppKit

// Roster downloads, the review of a re-import, and the CSV import that shares it.
// Split out of AppState.swift; the stored state these read stays on the class.

/// What one chosen file turned out to hold, shown before anything is written.
struct RosterFileReport: Identifiable {
    let id = UUID()
    let file: String
    var layout: TagLibrary.RosterLayout?
    var teams: [String] = []
    /// Why some or all of this file isn't going in.
    var problem: String?
}

/// An import held for you to look at. A download writes its new teams straight away and
/// only holds the ones you have, so `files`, `new` and `unchanged` are empty for it.
struct RosterImportReview {
    var files: [RosterFileReport] = []
    var new: [TagLibrary.IncomingTeam] = []
    var unchanged: [TagLibrary.RosterConflict] = []
    var conflicts: [TagLibrary.RosterConflict] = []

    var fromFiles: Bool { !files.isEmpty }
    /// New and unchanged teams aren't in the modes, so they go in as Replace, which for them
    /// only adds or fills blanks. One that's identical stays out: writing it reports an import
    /// that changed nothing, and moves the benches onto it.
    var toWrite: [TagLibrary.IncomingTeam] {
        new + unchanged.filter { !$0.changesNothing }.map(\.incoming) + conflicts.map(\.incoming)
    }
    var writesAnything: Bool { !toWrite.isEmpty }
}

extension AppState {

    func previewRoster(_ team: LeagueTeam) {
        previewTeam = team
        previewNote = nil
        if let cached = previewCache[team.code] {
            previewRows = cached
            isPreviewing = false
            return
        }
        previewRows = []
        isPreviewing = true
        let source = rosterSource
        Task {
            var rows: [RosterFeed.Row]? = nil
            var note: String? = nil
            do {
                if let url = source.rosterURL(for: team) {
                    rows = source.rows(from: try await fetch(url))
                }
                if rows == nil { note = "The league didn't list anyone for \(team.name)." }
            } catch {
                note = "Couldn't reach the league — \(error.localizedDescription)"
            }
            if let rows, source == rosterSource { previewCache[team.code] = rows }
            // Clicking on through the list sends several of these at once, and they can
            // land in any order. Only the one for the team still selected gets to draw.
            guard previewTeam == team, source == rosterSource else { return }
            previewRows = rows ?? []
            previewNote = note
            isPreviewing = false
        }
    }

    /// Fetches the team list for the picker. Only when it's empty: the list changes once a
    /// season at most, and re-fetching every time the sheet opens would be a network call
    /// for nothing.
    func loadLeagueTeams() {
        guard leagueTeams.isEmpty, !isFetchingRosters else { return }
        isFetchingRosters = true
        rosterDownloadNote = nil
        Task { await fetchLeagueTeams() }
    }

    private func fetchLeagueTeams() async {
        defer { isFetchingRosters = false }
        let source = rosterSource
        guard let url = source.teamsURL else { return }
        do {
            let data = try await fetch(url)
            let teams = source.teams(in: data)
            guard !teams.isEmpty else {
                rosterDownloadNote = "The league list came back empty. Try again later, or "
                    + "import a CSV instead."
                return
            }
            leagueTeams = teams
        } catch {
            rosterDownloadNote = "Couldn't reach the league — \(error.localizedDescription)"
        }
    }

    /// Fetches the chosen rosters and imports each one exactly as a CSV would be.
    func downloadRosters(_ teams: [LeagueTeam]) {
        guard !teams.isEmpty, !isFetchingRosters else { return }
        isFetchingRosters = true
        rosterDownloadNote = nil
        Task { await fetchRosters(teams) }
    }

    private func fetchRosters(_ teams: [LeagueTeam]) async {
        defer { isFetchingRosters = false }

        var incoming: [TagLibrary.IncomingTeam] = []
        var failed: [String] = []

        let source = rosterSource
        for (index, team) in teams.enumerated() {
            // A whole league is thirty-odd requests in a row. Without a count the sheet sits
            // on a spinner long enough to look stuck.
            if teams.count > 1 {
                rosterDownloadNote = "Fetching \(index + 1) of \(teams.count) — \(team.name)…"
            }
            guard let url = source.rosterURL(for: team) else {
                failed.append(team.code)
                continue
            }
            do {
                let data = try await fetch(url)
                guard let csv = source.csv(from: data, team: team) else {
                    failed.append(team.name)
                    continue
                }
                // Through the file importer's reader, so a downloaded roster gets the same
                // duplicate refusal and column handling an imported one does.
                incoming += try TagLibrary.parseRoster(csv: csv, fallbackTeam: team.name)
            } catch {
                // Named rather than counted: one team failing out of thirty-two is worth
                // knowing which, and the usual reason is a roster the league hasn't filled in.
                failed.append(team.name)
                addLog("Couldn't download \(team.name): \(error.localizedDescription)")
            }
        }

        var note = incoming.isEmpty
            ? (failed.isEmpty ? "Nothing was imported." : "")
            : stageImport(incoming, fromDownload: true)
        if !failed.isEmpty {
            note += (note.isEmpty ? "" : " ") + "Couldn't get \(failed.joined(separator: ", "))."
        }
        rosterDownloadNote = note
        status = note
    }

    /// Writes what needs no asking — teams you don't have, and ones that come in identical —
    /// and holds the rest for review. Returns what to tell you.
    func stageImport(_ incoming: [TagLibrary.IncomingTeam], fromDownload: Bool) -> String {
        let sorted = TagLibrary.sortImport(incoming, against: library.teams)
        let straight = RosterImportReview(new: sorted.new, unchanged: sorted.unchanged).toWrite
        let conflicts = sorted.conflicts

        var parts: [String] = []
        if !straight.isEmpty {
            let result = library.applyImport(straight)
            addLog("Imported \(result.team): \(result.players) players")
            parts.append("Imported \(result.team), \(result.players) players.")
            if result.tagsUpdated > 0 { parts.append("Updated \(result.tagsUpdated) existing tag(s).") }
            adoptImported(result.teamIDs)
            dropDanglingFilters()
        }
        if !conflicts.isEmpty {
            rosterReviewModes = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .merge) })
            rosterReviewSamePlayer = [:]
            rosterReviewFromDownload = fromDownload
            rosterReview = RosterImportReview(conflicts: conflicts)
            parts.append(conflicts.count == 1
                ? "\(conflicts[0].existingName) is already here and has changed — choose what to do."
                : "\(conflicts.count) teams you already have have changed — choose what to do.")
        }
        if parts.isEmpty, !sorted.unchanged.isEmpty {
            parts.append("Already up to date. Nothing changed.")
        }
        return parts.joined(separator: " ")
    }

    /// Reads every chosen file and holds the lot for review, written or not. A file's
    /// columns are where a code comes from, and a code arriving unseen from a column you'd
    /// forgotten was there is the bug this exists for — so even a plain import of a brand
    /// new team shows what was read before it's written.
    func reviewRosterFiles(_ urls: [URL]) {
        var files: [RosterFileReport] = []
        // By position, not by name: two files called roster.csv from different folders are
        // still two files.
        var parsed: [(index: Int, teams: [TagLibrary.IncomingTeam])] = []

        for url in urls {
            var report = RosterFileReport(file: url.lastPathComponent)
            guard let text = CSV.readText(url) else {
                report.problem = TagLibrary.ImportError.unreadable.localizedDescription
                files.append(report)
                continue
            }
            report.layout = TagLibrary.rosterLayout(TagLibrary.rosterRows(text))
            do {
                let teams = try TagLibrary.parseRoster(
                    csv: text, fallbackTeam: url.deletingPathExtension().lastPathComponent)
                report.teams = teams.map(\.name)
                parsed.append((files.count, teams))
            } catch {
                report.problem = error.localizedDescription
            }
            files.append(report)
        }

        let repeated = TagLibrary.repeatedTeams(parsed.map { (files[$0.index].file, $0.teams) },
                                                against: library.teams)
        var incoming: [TagLibrary.IncomingTeam] = []
        for (index, teams) in parsed {
            var notes: [String] = []
            for team in teams {
                guard let places = repeated[TagLibrary.importKey(team, against: library.teams)] else {
                    incoming.append(team)
                    continue
                }
                let listed = Array(Set(places)).sorted().joined(separator: ", ")
                notes.append("\(team.name) is in more than one file (\(listed)), so it was left out.")
            }
            if !notes.isEmpty {
                files[index].problem = (notes + ["Import those files one at a time."])
                    .joined(separator: " ")
            }
        }

        let sorted = TagLibrary.sortImport(incoming, against: library.teams)
        rosterReviewModes = Dictionary(uniqueKeysWithValues: sorted.conflicts.map { ($0.id, .merge) })
        rosterReviewSamePlayer = [:]
        rosterReviewFromDownload = false
        rosterReview = RosterImportReview(files: files,
                                          new: sorted.new,
                                          unchanged: sorted.unchanged,
                                          conflicts: sorted.conflicts)
        status = "Check the import — nothing has changed yet."
    }

    /// Import or Cancel in the review. Anything not applied leaves your roster untouched.
    func finishRosterReview(apply: Bool) {
        guard let review = rosterReview else { return }
        rosterReview = nil
        guard apply, review.writesAnything else {
            status = review.fromFiles ? "Nothing was imported." : "Kept your rosters as they were."
            rosterDownloadNote = status
            if review.fromFiles { importMessage = status }
            return
        }
        let result = library.applyImport(review.toWrite, modes: rosterReviewModes,
                                         samePlayer: rosterReviewSamePlayer)
        let skipped = review.conflicts.filter { rosterReviewModes[$0.id] == .skip }.count
        var note: String
        if result.teamIDs.isEmpty {
            note = "Kept your rosters as they were."
        } else if review.fromFiles {
            note = "Imported \(result.team), \(result.players) players."
            if result.tagsUpdated > 0 { note += " Updated \(result.tagsUpdated) existing tag(s)." }
        } else {
            note = "Updated \(result.team)."
        }
        if skipped > 0, !result.teamIDs.isEmpty { note += " Left \(skipped) as they were." }
        status = note
        rosterDownloadNote = note
        if review.fromFiles { importMessage = note }
        addLog(note)
        adoptImported(result.teamIDs)
        dropDanglingFilters()
    }

    /// Brings a freshly imported team into play, if there was just the one. A batch — a whole
    /// league, a thirteen-team file — leaves the benches alone, since no one of them is
    /// obviously the one you're about to shoot.
    func adoptImported(_ ids: [String]) {
        guard ids.count == 1, let id = ids.first else {
            if activeTeamIDs.isEmpty, let first = ids.first { setActiveTeams([first]) }
            return
        }
        let next = TeamPick.afterImport(current: activeTeamIDs, imported: id,
                                        shown: shownTeamID, bothTeams: bothTeams,
                                        league: { [library] in
                                            library.team(id: $0).map(TagLibrary.leagueKey)
                                                ?? TagLibrary.ungroupedLeague
                                        })
        setActiveTeams(next)
        focusedTeamID = id
        subjectsOnly = false
        lastImportedTeamID = id
    }

    /// A GET that treats an error page as an error. Without the status check a 404 or a 503
    /// body just fails to decode, and the sheet blames the league's data rather than saying
    /// the league answered with an error.
    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "the league answered \(http.statusCode)"])
        }
        return data
    }

    /// A plain GET with a name on it, the same shape the update check uses.
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Keeper/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    /// The tag filters point at a team, a player or a position by value, and a roster edit
    /// can move or remove any of them — renumbering #15 changes that player's id, deleting a
    /// team takes its players with it. A filter aimed at something that no longer exists
    /// shows an empty clip list with nothing in the menus to explain why, so it's dropped.
    func dropDanglingFilters() {
        dropStaleGame()
        if let id = filterTeamID, library.team(id: id) == nil {
            filterTeamID = nil
        }
        if let id = filterPlayerID, !library.allPlayers.contains(where: { $0.id == id }) {
            filterPlayerID = nil
        }
        if let position = filterPosition,
           !library.allPlayers.contains(where: { $0.position == position }) {
            filterPosition = nil
        }
        // Removing a section takes its categories with it, and a one-off ages out on its
        // own. Either way the filter bar would go on claiming to filter by something the
        // menu no longer offers, with no way to clear it but Clear.
        if let category = filterCategory, !library.allCategories.contains(category) {
            filterCategory = nil
        }
        if let subject = filterSubject, !library.filterableSubjects.contains(subject) {
            filterSubject = nil
        }
    }

    func importRoster() {
        // As with `requestExport`: don't put a file picker in front of someone who was
        // trying to record ⌘I.
        guard !showShortcutsSheet else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more roster CSVs: team, number, name"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        reviewRosterFiles(panel.urls)
    }
}
