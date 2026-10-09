import SwiftUI

/// Builds the filename templates used when copying. A preset is an ordered list of tokens
/// plus a separator and a client's team code.
struct PresetEditor: View {
    @ObservedObject private var library = TagLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    private var preset: RenamePreset? {
        library.presets.first { $0.id == selectedID } ?? library.presets.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filename Presets").font(.headline)
                Spacer()
                Button("Done") {
                    library.flush()     // commit any debounced keystrokes before closing
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            HStack(spacing: 0) {
                presetList
                Divider()
                if let preset {
                    editor(for: preset)
                } else {
                    Text("Add a preset to begin.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 740, height: 560)
        .onAppear { if selectedID == nil { selectedID = library.presets.first?.id } }
    }

    // MARK: Preset list

    private var presetList: some View {
        VStack(spacing: 0) {
            List(library.presets, selection: $selectedID) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(Renamer.preview(preset: item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(item.id)
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    let new = RenamePreset(name: "New preset")
                    library.upsert(preset: new)
                    selectedID = new.id
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    guard let id = preset?.id else { return }
                    library.deletePreset(id: id)
                    selectedID = library.presets.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(preset == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 230)
    }

    // MARK: Editor

    private func editor(for preset: RenamePreset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Renamer.preview(preset: preset))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Preset name").foregroundStyle(.secondary)
                        TextField("", text: binding(preset, \.name))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Team code").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("YWP", text: binding(preset, \.teamCode))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            Text("Used when the roster has no code of its own. Give each roster CSV a `code` column and one preset covers every team.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GridRow {
                        Text("Separator").foregroundStyle(.secondary)
                        TextField("_", text: binding(preset, \.separator))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }

                tokenSection(preset)
                prioritySection
            }
            .padding(16)
        }
    }

    private func tokenSection(_ preset: RenamePreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Name parts, in order").font(.subheadline.weight(.semibold))
                Spacer()
                Menu("Add") {
                    ForEach(NameToken.allCases) { token in
                        Button(token.label) {
                            var copy = preset
                            copy.tokens.append(token)
                            library.upsert(preset: copy)
                        }
                    }
                }
                .fixedSize()
            }

            if preset.tokens.isEmpty {
                Text("No parts yet — the original name will be kept.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !preset.tokens.contains(.originalName) {
                Label("Without the original name, two clips of the same player, tag and date "
                      + "produce the same filename. They won't overwrite each other — the second "
                      + "becomes \"name 2\" — but they'll be hard to tell apart.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(Array(preset.tokens.enumerated()), id: \.offset) { index, token in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(token.label)
                    Text(token == .teamCode ? preset.teamCode : token.example)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        move(preset, from: index, to: index - 1)
                    } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button {
                        move(preset, from: index, to: index + 1)
                    } label: { Image(systemName: "chevron.down") }
                        .disabled(index == preset.tokens.count - 1)
                    Button {
                        var copy = preset
                        copy.tokens.remove(at: index)
                        library.upsert(preset: copy)
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tag priority").font(.subheadline.weight(.semibold))
            Text("When a clip carries several tags, the one nearest the top is the one that goes in its filename.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(library.categories.enumerated()), id: \.element) { index, category in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(category).font(.callout)
                    Spacer()
                    Button { library.moveCategory(category, by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    Button { library.moveCategory(category, by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == library.categories.count - 1)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Helpers

    private func binding(_ preset: RenamePreset, _ key: WritableKeyPath<RenamePreset, String>) -> Binding<String> {
        Binding(
            get: { preset[keyPath: key] },
            set: { newValue in
                var copy = preset
                copy[keyPath: key] = newValue
                library.upsert(preset: copy)
            }
        )
    }

    private func move(_ preset: RenamePreset, from: Int, to: Int) {
        guard preset.tokens.indices.contains(from), preset.tokens.indices.contains(to) else { return }
        var copy = preset
        copy.tokens.swapAt(from, to)
        library.upsert(preset: copy)
    }
}
