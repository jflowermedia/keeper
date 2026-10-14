import SwiftUI
import AppKit

/// Editing a roster after it's been imported: team name, filename code, league heading, and
/// the players themselves.
///
/// Edits are made to a draft and applied in one go rather than written through on every
/// keystroke. Half-typed state is the reason — a number cleared on its way to becoming
/// another number would briefly collide with a real player, and a team renamed one letter at
/// a time would trip the duplicate-name check on the way past. Applying once also means the
/// renumbering can be worked out by comparing the draft to what's stored.
struct RosterEditor: View {
    /// Needed only to keep the tag filters honest: an edit here can remove the very team or
    /// player a filter points at, and a filter aimed at nothing shows an empty clip list
    /// with no visible cause.
    @ObservedObject var state: AppState
    @ObservedObject private var library = TagLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTeamID: String?
    @State private var draft: Draft?
    @State private var problem: String?
    @State private var note: String?

    /// A player row with an identity of its own, so renumbering can be spotted. `wasNumber`
    /// is what this row's player was called when the draft was made; nil means a new row.
    private struct Row: Identifiable {
        let id = UUID()
        var wasNumber: String?
        var number: String
        var name: String
        var position: String
    }

    private struct Draft {
        var teamID: String
        var name: String
        var code: String
        var league: String
        var rows: [Row]
    }

    private var team: Team? { library.team(id: selectedTeamID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rosters").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { commitIfPossible(thenDismiss: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 0) {
                teamList
                Divider()
                if draft != nil {
                    teamDetail
                } else {
                    emptyState
                }
            }
        }
        .frame(width: 760, height: 620)
        .onAppear {
            if selectedTeamID == nil { select(library.teams.first?.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(library.teams.isEmpty ? "No rosters yet." : "Pick a team.")
                .foregroundStyle(.secondary)
            if library.teams.isEmpty {
                Text("Import a CSV from the tagging panel, or add a team with + and type it in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Team list

    private var teamList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedTeamID }, set: { select($0) })) {
                if library.leaguesAreWorthShowing {
                    ForEach(library.teamsByLeague) { group in
                        Section(group.name) {
                            ForEach(group.teams) { teamRow($0) }
                        }
                    }
                } else {
                    ForEach(library.teams) { teamRow($0) }
                }
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    addTeam()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add an empty team to type a roster into")

                Button {
                    deleteTeam()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(team == nil)
                .help("Remove this team. Tags already on your clips keep the names they recorded.")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 230)
    }

    private func teamRow(_ item: Team) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).lineLimit(1)
            Text("\(item.players.count) player\(item.players.count == 1 ? "" : "s")"
                 + (item.code.map { " · \($0)" } ?? ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .tag(item.id)
    }

    // MARK: Team detail

    private var teamDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            teamFields
            Divider()
            playerHeader
            playerRows
            Divider()
            detailFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var teamFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Team").foregroundStyle(.secondary)
                TextField("Team name", text: binding(\.name))
            }
            GridRow {
                Text("Code").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("YWP", text: binding(\.code)).frame(width: 90)
                    Text("Short form used in filenames")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            GridRow {
                Text("League").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("MJHL", text: binding(\.league)).frame(width: 160)
                    if !library.knownLeagues.isEmpty {
                        Menu {
                            ForEach(library.knownLeagues, id: \.self) { league in
                                Button(league) { draft?.league = league }
                            }
                            Divider()
                            Button("None") { draft?.league = "" }
                        } label: {
                            Text("Use existing")
                        }
                        .frame(width: 130)
                    }
                    Text("Groups the team menus")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
    }

    private var playerHeader: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: 54, alignment: .leading)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Position").frame(width: 130, alignment: .leading)
            Spacer().frame(width: 24)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var playerRows: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Array((draft?.rows ?? []).enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        TextField("", text: rowBinding(index, \.number))
                            .frame(width: 54)
                            .multilineTextAlignment(.trailing)
                        TextField("Name", text: rowBinding(index, \.name))
                            .frame(maxWidth: .infinity)
                        positionField(index)
                        Button {
                            draft?.rows.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this player")
                    }
                    // A renumber moves every tag on that player, so it's worth seeing.
                    .background(renumbered(row) ? Color.orange.opacity(0.12) : Color.clear)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    private func positionField(_ index: Int) -> some View {
        HStack(spacing: 2) {
            TextField("", text: rowBinding(index, \.position))
            Menu {
                ForEach(["Forward", "Defence", "Goalie"], id: \.self) { position in
                    Button(position) { draft?.rows[index].position = position }
                }
                Divider()
                Button("Clear") { draft?.rows[index].position = "" }
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help("Pick one of the usual positions, or type your own")
        }
        .frame(width: 130)
    }

    private func renumbered(_ row: Row) -> Bool {
        guard let was = row.wasNumber else { return false }
        return was != row.number.trimmingCharacters(in: .whitespaces)
    }

    private var detailFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Add Player") {
                    draft?.rows.append(Row(wasNumber: nil, number: "", name: "", position: ""))
                }
                Spacer()
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                } else if let summary = pendingSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Button("Apply") { commitIfPossible(thenDismiss: false) }
                    .disabled(draft == nil)
            }
        }
        .padding(16)
    }

    /// What applying would do, so neither a renumber nor a removal is a surprise.
    private var pendingSummary: String? {
        guard let draft else { return nil }

        func tagCount(_ number: String) -> Int {
            library.tags.filter { $0.teamID == draft.teamID && $0.playerNumber == number }.count
        }

        var parts: [String] = []

        let moved = draft.rows.filter { renumbered($0) }.compactMap(\.wasNumber)
        if !moved.isEmpty {
            let tags = moved.reduce(0) { $0 + tagCount($1) }
            parts.append("\(moved.count) renumbered"
                         + (tags > 0 ? ", \(tags) tag\(tags == 1 ? "" : "s") moving with them" : ""))
        }

        // Removing a player leaves their tags behind on a number that may now belong to
        // somebody else — and the next roster refresh would rewrite those tags to that
        // person's name. Renumbering carries the tags; removing abandons them.
        let kept = Set(draft.rows.compactMap(\.wasNumber))
        let dropped = (library.team(id: draft.teamID)?.players ?? [])
            .filter { !kept.contains($0.number) }
        let strandedTags = dropped.reduce(0) { $0 + tagCount($1.number) }
        if strandedTags > 0 {
            parts.append("\(strandedTags) tag\(strandedTags == 1 ? "" : "s") left on removed "
                         + "player\(dropped.count == 1 ? "" : "s")")
        } else if !dropped.isEmpty {
            parts.append("\(dropped.count) removed")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Bindings

    private func binding(_ path: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: path] ?? "" },
                set: { draft?[keyPath: path] = $0; problem = nil; note = nil })
    }

    private func rowBinding(_ index: Int, _ path: WritableKeyPath<Row, String>) -> Binding<String> {
        Binding(
            get: {
                guard let draft, draft.rows.indices.contains(index) else { return "" }
                return draft.rows[index][keyPath: path]
            },
            set: {
                guard draft?.rows.indices.contains(index) == true else { return }
                draft?.rows[index][keyPath: path] = $0
                problem = nil
                note = nil
            })
    }

    // MARK: Actions

    /// Switching away without applying would lose the edit silently, so it's saved on the
    /// way out — and if it won't save, you stay put with the reason on screen rather than
    /// losing what you typed.
    private func select(_ id: String?) {
        guard commitIfPossible(thenDismiss: false) else { return }
        selectedTeamID = id
        problem = nil
        note = nil
        loadDraft(for: id)
    }

    /// Kept separate from `select` on purpose: `commitIfPossible` reloads the draft after a
    /// successful apply, and if that went through `select` the two would call each other
    /// forever.
    private func loadDraft(for id: String?) {
        guard let team = library.team(id: id) else { draft = nil; return }
        draft = Draft(teamID: team.id,
                      name: team.name,
                      code: team.code ?? "",
                      league: team.league ?? "",
                      rows: team.players.map {
                          Row(wasNumber: $0.number, number: $0.number,
                              name: $0.name, position: $0.position)
                      })
    }

    private func addTeam() {
        // Save first, so a team isn't created and then left unreachable behind a bad edit.
        guard commitIfPossible(thenDismiss: false) else { return }

        var name = "New team"
        var n = 2
        while library.teams.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "New team \(n)"
            n += 1
        }
        // Starts in the league you were just looking at, which is usually the right one.
        let league = (draft?.league).flatMap { $0.isEmpty ? nil : $0 }
        guard let team = library.addTeam(named: name, league: league) else { return }
        selectedTeamID = team.id
        problem = nil
        note = nil
        loadDraft(for: team.id)
    }

    private func deleteTeam() {
        guard let team else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(team.name)?"
        alert.informativeText = "Its \(team.players.count) players go with it. Tags already on "
            + "your clips are left alone and keep the names they recorded, but they'll no "
            + "longer line up with a roster."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        guard alert.runModal() != .alertFirstButtonReturn else { return }
        draft = nil
        library.deleteTeam(id: team.id)
        state.dropDanglingFilters()
        select(library.teams.first?.id)
    }

    /// Applies the draft. Returns false when it couldn't be saved, which is the caller's cue
    /// not to navigate away from it.
    @discardableResult
    private func commitIfPossible(thenDismiss: Bool) -> Bool {
        guard let draft, library.team(id: draft.teamID) != nil else {
            if thenDismiss { dismiss() }
            return true
        }

        let edit = TagLibrary.RosterEdit(
            name: draft.name,
            code: draft.code,
            league: draft.league,
            players: draft.rows.map {
                Player(teamID: draft.teamID, number: $0.number, name: $0.name, position: $0.position)
            },
            renumbered: draft.rows.compactMap {
                guard let was = $0.wasNumber else { return nil }
                let now = $0.number.trimmingCharacters(in: .whitespaces)
                return was == now ? nil : (from: was, to: now)
            })

        do {
            let moved = try library.apply(edit, to: draft.teamID)
            problem = nil
            note = moved > 0 ? "Saved — \(moved) tag\(moved == 1 ? "" : "s") moved." : "Saved."
            state.dropDanglingFilters()
            // Re-read, so wasNumber catches up and the orange rows settle.
            loadDraft(for: draft.teamID)
            if thenDismiss { dismiss() }
            return true
        } catch {
            // The draft stays exactly as typed so it can be fixed rather than retyped, and
            // Done deliberately doesn't close while something's wrong.
            problem = error.localizedDescription
            note = nil
            return false
        }
    }
}
