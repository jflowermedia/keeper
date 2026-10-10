import SwiftUI
import AppKit

/// One place to decide what leaves Keeper and how. Replaces a pair of buttons whose
/// difference wasn't obvious and whose scope — your selection, or everything the filter
/// shows — was invisible until it surprised you.
struct ExportSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject private var library = TagLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingPresets = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    whichClips
                    naming
                    whereTo
                    also
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 640)
        .sheet(isPresented: $editingPresets) {
            PresetEditor()
        }
    }

    // MARK: Which clips

    private var whichClips: some View {
        section("Which clips") {
            Picker("", selection: $state.exportScope) {
                Text(selectionLabel).tag(AppState.ExportScope.selection)
                Text(shownLabel).tag(AppState.ExportScope.shown)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Label(state.filterSummary, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionLabel: String {
        let n = state.selectedCount
        return n == 0 ? "Your selection (nothing selected)"
                      : "The \(n) clip\(n == 1 ? "" : "s") you've selected"
    }

    private var shownLabel: String {
        let n = state.visible.count
        return "All \(n) clip\(n == 1 ? "" : "s") the filter is showing"
    }

    // MARK: Naming

    private var naming: some View {
        section("Naming") {
            Menu {
                Button("Keep the camera's names") { state.renamePresetID = nil }
                if !library.presets.isEmpty {
                    Divider()
                    ForEach(library.presets) { preset in
                        Button(preset.name) { state.renamePresetID = preset.id }
                    }
                }
                Divider()
                Button("Edit Presets…") { editingPresets = true }
            } label: {
                Text(state.activePreset?.name ?? "Keep the camera's names")
            }
            .frame(width: 260)

            if let example = state.exportNameExample {
                VStack(alignment: .leading, spacing: 3) {
                    Text(example.from).foregroundStyle(.secondary)
                    Text(example.to)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Files keep the names the camera gave them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Where they go

    private var whereTo: some View {
        section("Where they go") {
            Picker("", selection: $state.exportDestination) {
                Text("Copy to another folder").tag(AppState.ExportDestination.copy)
                Text("Rename them where they already are").tag(AppState.ExportDestination.inPlace)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if state.exportDestination == .copy {
                copyOptions
            } else {
                inPlaceOptions
            }
        }
    }

    private var copyOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Choose Folder…") { state.chooseExportFolder() }
                Text(state.exportFolder?.path ?? "No folder chosen yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            HStack(spacing: 8) {
                Text("Layout").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $state.grouping) {
                    ForEach(AppState.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            Text(layoutNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Shown here as well as by the button, because this is where it gets fixed.
            if let caution = state.exportCaution {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var layoutNote: String {
        switch state.grouping {
        case .flat:
            return "Everything together in that folder. The originals stay where they are."
        case .byCategory:
            return "One copy of each clip, in the folder for its highest-priority tag — the "
                 + "same tag its filename uses. Nothing is duplicated."
        case .byPlayer:
            return "A copy in each tagged player's folder, so every player's folder is "
                 + "complete. Clips tagged to several players are copied more than once."
        }
    }

    private var inPlaceOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let folder = state.exportSourceFolder {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Label(inPlaceNote, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inPlaceNote: String {
        "Nothing is copied, so you won't end up with the same footage twice. This is for "
        + "footage you've already offloaded and are tagging after the fact. It will break "
        + "the media links in any edit already built on these files."
    }

    // MARK: Also

    private var also: some View {
        section("Along with the video") {
            // Renaming always takes the sidecar — the pair have to keep matching names —
            // so there's nothing to choose, and a disabled checkbox would only mislead.
            if state.exportDestination == .inPlace {
                Label("Each clip's XML sidecar is renamed to match",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Take each clip's XML sidecar", isOn: $state.includeXML)
                    .toggleStyle(.checkbox)
            }

            Text(xmlNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.exportFlagChanges > 0 {
                Label(flagNote, systemImage: flagsWillTravel ? "pencil" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(flagsWillTravel ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var xmlNote: String {
        if state.exportDestination == .inPlace {
            return "The video and its sidecar have to share a name to stay paired, so they "
                 + "are always renamed together."
        }
        return "The sidecar carries the KEEP flag, the shoot date and the clip's ID. Leaving "
             + "it behind means a later scan of that folder can't see these clips."
    }

    /// Whether a changed flag actually reaches the files this export produces.
    private var flagsWillTravel: Bool {
        state.exportDestination == .inPlace || state.includeXML
    }

    private var flagNote: String {
        let n = state.exportFlagChanges
        let count = "\(n) clip\(n == 1 ? " has" : "s have") a KEEP flag you changed. "
        if !flagsWillTravel {
            return count + "Turn the sidecar back on, or the change won't go anywhere — "
                 + "your card still has what you flagged in camera."
        }
        return count + (state.exportDestination == .inPlace
            ? "It'll be written into the sidecars in that folder."
            : "It'll be written into the copied sidecars. Your card is left alone.")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.callout)
                if let note = state.exportBlocker ?? state.exportCaution {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            // Return only fires the safe case: a copy, into a folder with nothing to warn
            // about. Renaming on the spot and copying over your own footage both have to be
            // clicked, so neither can happen to someone tapping Return out of habit.
            if returnIsSafe {
                actionButton.keyboardShortcut(.defaultAction)
            } else {
                actionButton.buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var returnIsSafe: Bool {
        state.exportDestination == .copy && state.exportCaution == nil
    }

    private var actionButton: some View {
        Button(actionLabel) {
            // The sheet goes first. Copying can still put up a free-space alert of its own,
            // and an alert stacked on a sheet that's mid-dismissal is a mess — so the work
            // starts on the next pass through the main queue, with the sheet already gone.
            dismiss()
            Task { @MainActor in state.runExport() }
        }
        .disabled(state.exportBlocker != nil)
    }

    private var summary: String {
        let clips = state.exportClips.count
        guard clips > 0 else { return "Nothing in view" }

        if state.exportDestination == .copy {
            let files = state.exportFileCount
            return "\(clips) clip\(clips == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")"
                 + " · \(FileUtil.sizeText(state.exportSize))"
        }

        var parts: [String] = []
        let renames = state.exportRenameCount
        if renames > 0 { parts.append("\(renames) renamed") }
        if state.exportFlagChanges > 0 { parts.append("\(state.exportFlagChanges) reflagged") }
        if parts.isEmpty { parts.append("already named correctly") }
        return "\(clips) clip\(clips == 1 ? "" : "s") · " + parts.joined(separator: " · ")
    }

    /// The button says what's about to happen, so there's no pressing OK on the wrong one.
    private var actionLabel: String {
        if state.exportDestination == .copy {
            let clips = state.exportClips.count
            return "Copy \(clips) Clip\(clips == 1 ? "" : "s")"
        }
        let renames = state.exportRenameCount
        if renames > 0 {
            return "Rename \(renames) Clip\(renames == 1 ? "" : "s")"
        }
        let flags = state.exportFlagChanges
        return "Write \(flags) Flag\(flags == 1 ? "" : "s")"
    }

    // MARK: Layout helper

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}
