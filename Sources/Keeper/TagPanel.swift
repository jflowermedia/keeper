import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The tagging panel: pick a player, click a category, the clip is tagged.
struct TagPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject private var library = TagLibrary.shared
    @State private var selectedTeamID: String?
    @State private var selectedPlayerIDs: Set<String> = []
    @State private var newCategory = ""
    @State private var showingCategoryField = false
    @State private var importMessage: String?

    private var clip: Clip? { state.previewClip }

    private var team: Team? {
        library.team(id: selectedTeamID) ?? library.teams.first
    }

    private var players: [Player] { team?.players ?? [] }

    /// In roster order, so "Goal" on three selected players reads sensibly in the log.
    private var selectedPlayers: [Player] {
        players.filter { selectedPlayerIDs.contains($0.id) }
    }

    private var currentTags: [Tag] {
        library.tags(forUMID: clip?.umid).sorted { $0.created < $1.created }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if library.teams.isEmpty {
                emptyRoster
            } else {
                teamPicker
                playerGrid
                Divider()
                categoryRow
            }

            if !currentTags.isEmpty {
                Divider()
                tagList
            }

            Spacer(minLength: 0)

            if !state.taggedInScope.isEmpty {
                Divider()
                Button(role: .destructive) {
                    state.removeTagsInScope()
                } label: {
                    Label(state.removeTagsLabel, systemImage: "tag.slash")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .help(state.hasExplicitSelection
                      ? "Clears every tag from the clips you have selected"
                      : "Nothing is selected, so this clears tags from every clip the filter is showing")
            }
        }
        .padding(12)
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 380,
               maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Tagging", systemImage: "number").font(.headline)
            Spacer()
            Menu {
                Button("Import Roster CSV…") { importRoster() }
                Button("Update Tags from Roster") {
                    let n = library.refreshTagsFromRoster()
                    state.status = n == 0
                        ? "Tags already match the roster."
                        : "Updated \(n) tag(s) from the roster."
                }
                .disabled(library.teams.isEmpty)
                if let team {
                    Divider()
                    Button("Remove \(team.name)", role: .destructive) {
                        // Clear any filter pointing at it, or the list goes empty with no
                        // way to see why: the menus no longer offer what's filtering it.
                        if state.filterTeamID == team.id { state.filterTeamID = nil }
                        if state.filterPlayerID?.hasPrefix("\(team.id)/") == true {
                            state.filterPlayerID = nil
                        }
                        library.deleteTeam(id: team.id)
                        selectedTeamID = nil
                        selectedPlayerIDs = []
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var emptyRoster: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No roster yet.")
                .foregroundStyle(.secondary)
            Button("Import Roster CSV…") { importRoster() }
            Text("Columns: team, number, name. A header row is optional, and without a team column the file's name is used.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let importMessage {
                Text(importMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Roster

    private var teamPicker: some View {
        HStack(spacing: 8) {
            Picker("Team", selection: Binding(
                get: { team?.id ?? "" },
                set: { selectedTeamID = $0; selectedPlayerIDs = [] }
            )) {
                ForEach(library.teams) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()

            if !selectedPlayerIDs.isEmpty {
                Button("Clear \(selectedPlayerIDs.count)") { selectedPlayerIDs = [] }
                    .buttonStyle(.link)
                    .help("Deselect every player")
            }
        }
    }

    private var playerGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], spacing: 6) {
                ForEach(players) { player in
                    Button {
                        if selectedPlayerIDs.contains(player.id) {
                            selectedPlayerIDs.remove(player.id)
                        } else {
                            selectedPlayerIDs.insert(player.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(player.number.isEmpty ? "–" : player.number)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(minWidth: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(player.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                if !player.position.isEmpty {
                                    Text(player.position)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(selectedPlayerIDs.contains(player.id)
                                    ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 190)
    }

    // MARK: Categories

    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingCategoryField.toggle()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add a category")
            }

            if showingCategoryField {
                HStack(spacing: 6) {
                    TextField("New category", text: $newCategory)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitCategory)
                    Button("Add", action: commitCategory)
                        .disabled(newCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                ForEach(library.categories, id: \.self) { category in
                    Button { tag(with: category) } label: {
                        Text(category)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(clip == nil)
                    .opacity(clip == nil ? 0.4 : 1)
                    .contextMenu {
                        Button("Remove \"\(category)\"", role: .destructive) {
                            if state.filterCategory == category { state.filterCategory = nil }
                            library.removeCategory(category)
                        }
                    }
                }
            }
        }
    }

    private var hint: String {
        if clip == nil { return "Select a clip to tag" }
        switch selectedPlayers.count {
        case 0:  return currentTags.isEmpty ? "Pick a player, then a category" : "Pick the next player"
        case 1:  return "Click a category to tag \(selectedPlayers[0].number.isEmpty ? selectedPlayers[0].name : "#" + selectedPlayers[0].number)"
        default: return "Click a category to tag \(selectedPlayers.count) players"
        }
    }

    private func commitCategory() {
        library.addCategory(newCategory)
        newCategory = ""
        showingCategoryField = false
    }

    // MARK: Tags on this clip

    private var tagList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("On this clip").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(currentTags) { tag in
                HStack(spacing: 6) {
                    Text(tag.category)
                        .font(.caption.weight(.semibold))
                    if let who = tag.playerLabel {
                        Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let position = tag.playerPosition {
                        Text(position).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        library.remove(tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Actions

    /// One tag per selected player, so a play involving three of them is three clicks, not nine.
    /// With nobody selected it tags the clip itself.
    private func tag(with category: String) {
        guard let clip else { return }
        guard let umid = clip.umid else {
            state.status = "\(clip.name) has no UMID in its XML, so it can't be tagged."
            return
        }

        func makeTag(_ player: Player?) -> Tag {
            Tag(umid: umid,
                clipName: clip.name,
                volumeName: clip.volumeName,
                path: clip.videoURL.path,
                teamID: player?.teamID ?? team?.id,
                teamName: team?.name,
                playerNumber: player?.number,
                playerName: player?.name,
                playerPosition: player.flatMap { $0.position.isEmpty ? nil : $0.position },
                category: category)
        }

        let chosen = selectedPlayers
        if chosen.isEmpty {
            state.status = library.add(makeTag(nil))
                ? "Tagged \(clip.name) as \(category)."
                : "\(clip.name) is already tagged \(category)."
            return
        }

        var added: [Player] = []
        for player in chosen where library.add(makeTag(player)) {
            added.append(player)
        }

        if added.isEmpty {
            state.status = "Already tagged \(category) — nothing to add."
        } else {
            let who = added.count == 1
                ? added[0].label
                : added.map { $0.number.isEmpty ? $0.name : "#\($0.number)" }.joined(separator: ", ")
            let skipped = chosen.count - added.count
            state.status = "Tagged \(clip.name) as \(category) — \(who)."
                + (skipped > 0 ? " \(skipped) already had it." : "")
        }

        // Cleared on purpose: the next category is usually for a different player
        // (one scores, another assists), so carrying the selection over invites mistakes.
        selectedPlayerIDs = []
    }

    private func importRoster() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.message = "Choose a roster CSV: team, number, name"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try library.importRoster(from: url)
            importMessage = "Imported \(result.players) players."
            state.status = "Imported \(result.players) players from \(result.team)."
                + (result.tagsUpdated > 0 ? " Updated \(result.tagsUpdated) existing tag(s)." : "")
            // Jump to the team just imported, not whichever sorts first.
            let imported = Team.slug(result.team)
            selectedTeamID = library.team(id: imported) != nil ? imported : library.teams.first?.id
        } catch {
            importMessage = error.localizedDescription
            state.status = "Roster import failed: \(error.localizedDescription)"
        }
    }
}

/// Small coloured chips shown on each clip row.
struct TagChips: View {
    let tags: [Tag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    Text(chipText(tag))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.22))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chipText(_ tag: Tag) -> String {
        if let number = tag.playerNumber, !number.isEmpty {
            return "\(number) · \(tag.category)"
        }
        return tag.category
    }
}
