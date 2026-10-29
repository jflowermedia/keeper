import SwiftUI

/// Merge, Replace or Skip for each team an import would change.
///
/// Exists because a download used to replace a team outright, and a roster is where hand
/// edits live — a corrected spelling, a call-up the league hasn't listed yet. Nothing is
/// written until Apply, and Merge is the default because it's the one that can't lose
/// anything you did.
struct RosterReviewSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rosters you already have").font(.headline)
                Text("The new list differs from what's in Keeper. Choose what to do with each "
                     + "team — nothing changes until you press Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.rosterReview ?? []) { conflict in
                        row(conflict)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Skip All") { state.finishRosterReview(apply: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { state.finishRosterReview(apply: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 500)
    }

    private func mode(for id: String) -> Binding<TagLibrary.ImportMode> {
        Binding(
            get: { state.rosterReviewModes[id] ?? .merge },
            set: { state.rosterReviewModes[id] = $0 }
        )
    }

    private func row(_ conflict: TagLibrary.RosterConflict) -> some View {
        let changes = conflict.changes
        let chosen = state.rosterReviewModes[conflict.id] ?? .merge
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conflict.existingName).font(.body.weight(.semibold))
                    Text(changes.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Picker("", selection: mode(for: conflict.id)) {
                    ForEach(TagLibrary.ImportMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(explanation(chosen, changes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Drawn for the option that's chosen, not for the difference between the two
                // lists. Under Merge a red minus beside a player reads as "will be removed",
                // which is exactly what Merge doesn't do.
                DisclosureGroup("Show changes") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(changes.added, id: \.number) { player in
                            switch chosen {
                            case .skip:
                                line("·", "#\(player.number)  \(player.name) — not added", Color.secondary)
                            case .merge, .replace:
                                line("+", "#\(player.number)  \(player.name)", .green)
                            }
                        }
                        ForEach(changes.removed, id: \.number) { player in
                            switch chosen {
                            case .replace:
                                line("−", "#\(player.number)  \(player.name)", .red)
                            case .merge, .skip:
                                line("=", "#\(player.number)  \(player.name) — not in the new list, kept",
                                     Color.secondary)
                            }
                        }
                        ForEach(changes.changed, id: \.new.number) { change in
                            switch chosen {
                            case .replace:
                                line("~", describe(change), .orange)
                            case .merge, .skip:
                                line("=", "#\(change.old.number)  \(change.old.name) — kept as yours "
                                     + "(new list: \(change.new.name))", Color.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            .padding(4)
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

    private func describe(_ change: TagLibrary.RosterChanges.Change) -> String {
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
        return "#\(change.new.number)  " + parts.joined(separator: ", ")
    }

    /// What the chosen option will do to this team, in its own numbers.
    private func explanation(_ mode: TagLibrary.ImportMode,
                             _ changes: TagLibrary.RosterChanges) -> String {
        switch mode {
        case .merge:
            let adds = changes.added.count
            let kept = changes.removed.count + changes.changed.count
            let start = adds == 0
                ? "Keeps your roster exactly as it is — there's nobody new to add."
                : "Adds the \(adds) new player\(adds == 1 ? "" : "s"). Everyone you already have "
                    + "stays exactly as you have them"
            guard adds > 0 else { return start }
            return start + (kept == 0 ? "." : ", including what the new list drops or spells "
                                + "differently.")
        case .replace:
            let gone = changes.removed.count
            return "Uses the new list exactly."
                + (gone == 0 ? "" : " \(gone) player\(gone == 1 ? "" : "s") you have will be "
                    + "removed; clips already tagged with them keep their tags.")
        case .skip:
            return "Leaves your roster as it is."
        }
    }
}
