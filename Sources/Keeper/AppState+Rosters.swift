import AppKit

// Roster downloads, the review of a re-import, and the CSV import that shares it.
// Split out of AppState.swift; the stored state these read stays on the class.

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
        let conflicts = library.conflicts(in: incoming)
        let held = Set(conflicts.map(\.id))
        let straight = incoming.filter { !held.contains($0.slug) }

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
            rosterReviewFromDownload = fromDownload
            rosterReview = conflicts
            parts.append(conflicts.count == 1
                ? "\(conflicts[0].existingName) is already here and has changed — choose what to do."
                : "\(conflicts.count) teams you already have have changed — choose what to do.")
        }
        return parts.joined(separator: " ")
    }

    /// Apply or Skip All in the review. Anything not applied leaves your roster untouched.
    func finishRosterReview(apply: Bool) {
        guard let conflicts = rosterReview else { return }
        rosterReview = nil
        guard apply else {
            status = "Kept your rosters as they were."
            rosterDownloadNote = status
            return
        }
        let result = library.applyImport(conflicts.map(\.incoming), modes: rosterReviewModes)
        let skipped = conflicts.filter { rosterReviewModes[$0.id] == .skip }.count
        var note = result.teamIDs.isEmpty
            ? "Kept your rosters as they were."
            : "Updated \(result.team)."
        if skipped > 0, !result.teamIDs.isEmpty { note += " Left \(skipped) as they were." }
        status = note
        rosterDownloadNote = note
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
    }

    func importRoster() {
        // As with `requestExport`: don't put a file picker in front of someone who was
        // trying to record ⌘I.
        guard !showShortcutsSheet else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.message = "Choose a roster CSV: team, number, name"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let text = CSV.readText(url) else { throw TagLibrary.ImportError.unreadable }
            let incoming = try TagLibrary.parseRoster(
                csv: text, fallbackTeam: url.deletingPathExtension().lastPathComponent)
            let note = stageImport(incoming, fromDownload: false)
            importMessage = note
            status = note
        } catch {
            importMessage = error.localizedDescription
            status = "Roster import failed: \(error.localizedDescription)"
        }
    }
}
