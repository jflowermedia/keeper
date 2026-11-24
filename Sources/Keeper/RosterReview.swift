import SwiftUI

/// What an import is about to do, and Merge, Replace or Skip for each team it would change.
///
/// Exists because a download used to replace a team outright, and a roster is where hand
/// edits live — a corrected spelling, a call-up the league hasn't listed yet. Nothing is
/// written until Apply, and Merge is the default because it's the one that can't lose
/// anything you did.
///
/// From files it also shows what each file was read as, every time. A code column you'd
/// forgotten about used to put its code back over the one you'd typed, on every re-import,
/// with nothing anywhere to say where it was coming from.
struct RosterReviewSheet: View {
    @ObservedObject var state: AppState

    private var review: RosterImportReview { state.rosterReview ?? RosterImportReview() }

    var body: some View {
        if let check = state.rosterCheck {
            progress(check)
        } else {
            reviewBody
        }
    }

    private func progress(_ check: RosterCheck) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update All Rosters").font(.headline)
            if let result = check.result {
                Text(result).fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView(value: Double(check.done), total: Double(max(1, check.total)))
                Text("Checking \(check.done + 1) of \(check.total) — \(check.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Spacer()
                Button(check.result == nil ? "Cancel" : "Done") { state.closeRosterReview() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(review.fromFiles
                     ? "Check what Keeper read from each file. Nothing changes until you press Import."
                     : "The new list differs from what's in Keeper. Choose what to do with each "
                        + "team — nothing changes until you press Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !review.missed.isEmpty {
                    Text("Couldn't get \(review.missed.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.keeperOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Divider()

            if review.conflicts.count > 1 {
                setAll
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if review.fromFiles {
                        section("From \(review.files.count == 1 ? "the file" : "\(review.files.count) files")") {
                            ForEach(review.files) { fileRow($0) }
                        }
                    }
                    if !review.new.isEmpty {
                        section("New teams") {
                            ForEach(review.new, id: \.slug) { newRow($0) }
                        }
                    }
                    if !review.conflicts.isEmpty {
                        section(review.fromFiles ? "Teams you already have" : "") {
                            ForEach(review.conflicts) { conflictRow($0) }
                        }
                    }
                    if !review.unchanged.isEmpty {
                        section("Already up to date") {
                            ForEach(review.unchanged) { unchangedRow($0) }
                        }
                    }
                    if review.fromFiles && !review.writesAnything && review.unchanged.isEmpty {
                        Text("There's nothing here Keeper can import.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button(review.fromFiles ? "Cancel" : "Skip All") { state.finishRosterReview(apply: false) }
                    .keyboardShortcut(.cancelAction)
                Button(review.fromFiles ? "Import" : "Apply") { state.finishRosterReview(apply: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!review.writesAnything)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }

    private var title: String {
        if review.updating {
            return review.conflicts.count == 1 ? "A roster that's changed"
                : "\(review.conflicts.count) rosters that have changed"
        }
        guard review.fromFiles else { return "Rosters you already have" }
        return review.files.count == 1 ? "Import a roster" : "Import \(review.files.count) rosters"
    }

    @ViewBuilder
    private func section<Content: View>(_ heading: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !heading.isEmpty {
                Text(heading).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            content()
        }
    }

    // MARK: Files

    private func fileRow(_ file: RosterFileReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(file.file, systemImage: file.problem == nil ? "doc.text" : "exclamationmark.triangle")
                .font(.body.weight(.semibold))
                .foregroundStyle(file.problem == nil && !file.teams.isEmpty ? Color.keeperText : Color.keeperOrange)
            if let layout = file.layout {
                Text(describe(layout))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !layout.ignored.isEmpty {
                    Text("Not used: \(layout.ignored.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !file.teams.isEmpty {
                Text(file.teams.joined(separator: " · "))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = file.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.keeperOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func describe(_ layout: TagLibrary.RosterLayout) -> String {
        let read = layout.fields.joined(separator: ", ")
        if layout.headerless { return "No header row, so read as \(read)." }
        // Said outright either way, because which one it is decides whether this import can
        // change a filename code.
        let code = layout.columns["code"] == nil
            ? " No code column, so codes you've set are kept."
            : ""
        return "Columns: \(read).\(code)"
    }

    // MARK: Teams

    private func newRow(_ team: TagLibrary.IncomingTeam) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(team.name).font(.body.weight(.semibold))
                Text("\(team.players.count) player\(team.players.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(teamFacts(code: team.code, league: team.league))
                .font(.caption)
                .foregroundStyle(.secondary)
            sharedNumbers(team)
        }
    }

    /// Said for every team it happens to, since a letter nobody typed needs explaining.
    @ViewBuilder
    private func sharedNumbers(_ team: TagLibrary.IncomingTeam) -> some View {
        if !team.lettered.isEmpty {
            line("·", "Sharing a number, so lettered: \(TagLibrary.IncomingTeam.list(team.lettered))",
                 Color.keeperSecondary)
        }
        if !team.leftOut.isEmpty {
            line("·", "Left out, no jersey number yet: \(TagLibrary.IncomingTeam.list(team.leftOut))",
                 Color.keeperSecondary)
        }
    }

    /// One press for a league's worth. Each team can still be changed after.
    private var setAll: some View {
        HStack(spacing: 8) {
            Text("Set all").font(.caption).foregroundStyle(.secondary)
            ForEach(TagLibrary.ImportMode.allCases) { mode in
                Button(mode.rawValue) {
                    for conflict in review.conflicts { state.rosterReviewModes[conflict.id] = mode }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func unchangedRow(_ conflict: TagLibrary.RosterConflict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conflict.existingName).font(.body.weight(.semibold))
            if conflict.details.isEmpty {
                Text("Same as yours — nothing changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conflict.details, id: \.field) { detailLine($0, mode: .replace) }
            }
        }
    }

    /// Where a new team's filename code will come from, said before it's the reason an
    /// export came out wrong.
    private func teamFacts(code: String?, league: String?) -> String {
        let code = code.map { "Code \($0)" } ?? "No code — filenames use the preset's team code"
        return [code, league.map { "League \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func mode(for id: String) -> Binding<TagLibrary.ImportMode> {
        Binding(
            get: { state.rosterReviewModes[id] ?? .merge },
            set: { state.rosterReviewModes[id] = $0 }
        )
    }

    private func conflictRow(_ conflict: TagLibrary.RosterConflict) -> some View {
        let changes = conflict.changes
        let chosen = state.rosterReviewModes[conflict.id] ?? .merge
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conflict.existingName).font(.body.weight(.semibold))
                    Text(summary(conflict))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Picker("", selection: mode(for: conflict.id)) {
                    ForEach(TagLibrary.ImportMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(explanation(chosen, conflict))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Out in the open rather than under Show changes: a code that quietly changes
                // is the one difference you'd never think to go looking for.
                if !conflict.details.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(conflict.details, id: \.field) { detailLine($0, mode: chosen) }
                    }
                }

                sharedNumbers(conflict.incoming)

                // Drawn for the option that's chosen, not for the difference between the two
                // lists. Under Merge a red minus beside a player reads as "will be removed",
                // which is exactly what Merge doesn't do.
                if !changes.isEmpty {
                    DisclosureGroup("Show player changes") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(changes.added, id: \.number) { player in
                                switch chosen {
                                case .skip:
                                    line("·", "#\(player.number)  \(player.name) — not added", Color.keeperSecondary)
                                case .merge, .replace:
                                    line("+", "#\(player.number)  \(player.name)", .keeperGreen)
                                }
                            }
                            ForEach(changes.removed, id: \.number) { player in
                                switch chosen {
                                case .replace:
                                    line("−", "#\(player.number)  \(player.name)", .keeperRed)
                                case .merge, .skip:
                                    line("=", "#\(player.number)  \(player.name) — not in the new list, kept",
                                         Color.keeperSecondary)
                                }
                            }
                            ForEach(changes.changed, id: \.new.number) { change in
                                switch chosen {
                                case .replace:
                                    HStack(alignment: .firstTextBaseline) {
                                        line("~", describe(change, in: conflict.id), .keeperOrange)
                                        if renamed(change) {
                                            Spacer()
                                            Toggle("Same player", isOn: samePlayer(change, in: conflict.id))
                                                .toggleStyle(.checkbox)
                                                .help("Tick for a corrected spelling: clips tagged "
                                                      + "\(change.old.name) take the new name. Leave it for "
                                                      + "someone new in the number: those clips keep "
                                                      + "\(change.old.name) and show Not on roster.")
                                        }
                                    }
                                case .merge, .skip:
                                    line("=", "#\(change.old.number)  \(change.old.name) — kept as yours "
                                         + "(new list: \(change.new.name))", Color.keeperSecondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
            .padding(4)
        }
    }

    private func summary(_ conflict: TagLibrary.RosterConflict) -> String {
        var parts = conflict.changes.isEmpty ? [] : [conflict.changes.summary]
        let fields = conflict.details.filter(\.overwrites).map { $0.field.lowercased() }
        if !fields.isEmpty { parts.append("different \(fields.joined(separator: " and "))") }
        return parts.joined(separator: " · ")
    }

    /// One team-level field, as the chosen option will leave it. Merge and Skip keep a value
    /// you set; Skip alone leaves a blank blank.
    private func detailLine(_ detail: TagLibrary.DetailChange,
                            mode: TagLibrary.ImportMode) -> some View {
        switch (detail.overwrites, mode) {
        case (true, .replace):
            return line("~", "\(detail.field): \(detail.old) → \(detail.new)", .keeperOrange)
        case (true, _):
            return line("=", "\(detail.field): keeps \(detail.old) (new list: \(detail.new))",
                        Color.keeperSecondary)
        case (false, .skip):
            return line("·", "\(detail.field) \(detail.new) — not added", Color.keeperSecondary)
        case (false, _):
            return line("+", "\(detail.field): \(detail.new)", .keeperGreen)
        }
    }

    private func line(_ mark: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(text).font(.caption)
        }
    }

    /// A new name on the number, not just a new position or a change of case.
    private func renamed(_ change: TagLibrary.RosterChanges.Change) -> Bool {
        !change.old.isNamed(change.new.name)
    }

    private func samePlayer(_ change: TagLibrary.RosterChanges.Change,
                            in id: String) -> Binding<Bool> {
        let number = change.new.number
        return Binding(
            get: { state.rosterReviewSamePlayer[id]?.contains(number) ?? false },
            set: { on in
                var numbers = state.rosterReviewSamePlayer[id] ?? []
                if on { numbers.insert(number) } else { numbers.remove(number) }
                state.rosterReviewSamePlayer[id] = numbers
            }
        )
    }

    private func describe(_ change: TagLibrary.RosterChanges.Change, in id: String) -> String {
        var parts: [String] = []
        if change.old.name != change.new.name {
            parts.append("\(change.old.name) → \(change.new.name)")
        } else {
            parts.append(change.new.name)
        }
        if !change.new.position.isEmpty, change.old.position != change.new.position {
            let was = change.old.position.isEmpty ? "no position" : change.old.position
            parts.append("\(was) → \(change.new.position)")
        }
        // Said here, since nothing else would show it going.
        if !change.old.nickname.isEmpty, renamed(change),
           state.rosterReviewSamePlayer[id]?.contains(change.new.number) != true {
            parts.append("drops nickname “\(change.old.nickname)”")
        }
        return "#\(change.new.number)  " + parts.joined(separator: ", ")
    }

    /// What the chosen option will do to this team, in its own numbers.
    private func explanation(_ mode: TagLibrary.ImportMode,
                             _ conflict: TagLibrary.RosterConflict) -> String {
        let changes = conflict.changes
        let overwritten = conflict.details.filter(\.overwrites).map { $0.field.lowercased() }
        switch mode {
        case .merge:
            let adds = changes.added.count
            let kept = changes.removed.count + changes.changed.count + overwritten.count
            let fills = conflict.details.contains { !$0.overwrites }
            let start = adds == 0
                ? (fills ? "Keeps your players exactly as they are, and fills in the blanks shown."
                         : "Keeps your roster exactly as it is — there's nobody new to add.")
                : "Adds the \(adds) new player\(adds == 1 ? "" : "s"). Everything you already have "
                    + "stays exactly as you have it"
            guard adds > 0 else { return start }
            return start + (kept == 0 ? "." : ", including what the new list drops or spells "
                                + "differently.")
        case .replace:
            let gone = changes.removed.count
            var text = "Uses the new list exactly."
            if !overwritten.isEmpty {
                text += " Your \(overwritten.joined(separator: " and ")) "
                    + "\(overwritten.count == 1 ? "is" : "are") replaced as shown."
            }
            if gone > 0 {
                text += " \(gone) player\(gone == 1 ? "" : "s") you have will be "
                    + "removed; clips already tagged with them keep their tags."
            }
            let renames = changes.changed.filter(renamed).count
            if renames > 0 {
                text += " \(renames) number\(renames == 1 ? " has" : "s have") a new name. "
                    + "Clips keep the old name and show Not on roster, unless you tick Same "
                    + "player under Show player changes for a corrected spelling."
            }
            return text
        case .skip:
            return "Leaves your roster as it is."
        }
    }
}
