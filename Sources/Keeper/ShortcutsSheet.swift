import SwiftUI
import AppKit

/// Catches the next key press while a slot in the sheet is listening.
///
/// A local monitor rather than a first-responder view, so a ⌘ combo is caught here instead of
/// firing the menu item it's currently bound to. One monitor lives for as long as the sheet is
/// open and does nothing at all unless `target` is set.
final class KeyRecorder: ObservableObject {
    struct Target: Equatable {
        let action: ShortcutAction
        let slot: Int
    }

    @Published var target: Target?
    @Published var message: String?

    private var monitor: Any?

    func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let target = self.target else { return event }

            // Escape stops listening without changing anything, so there's always a way out
            // of a sheet that's swallowing every key.
            if KeyCombo.name(for: event) == "escape", !event.modifierFlags.contains(.command) {
                self.target = nil
                self.message = nil
                return nil
            }

            guard let combo = KeyCombo(event: event) else {
                self.message = "That key can't be used for a shortcut."
                return nil
            }

            self.target = nil
            self.message = Shortcuts.shared.assign(combo, to: target.action, slot: target.slot)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        target = nil
        message = nil
    }
}

struct ShortcutsSheet: View {
    @ObservedObject private var shortcuts = Shortcuts.shared
    @StateObject private var recorder = KeyRecorder()
    @Environment(\.dismiss) private var dismiss

    private var reviewActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == .review }
    }

    private var menuActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == .menu }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Reviewing",
                            note: "One press, no modifier, so the whole pass can be worked "
                                + "with one hand. They do nothing while you're typing in a field.",
                            actions: reviewActions)

                    section("Menu commands",
                            note: "These sit in the menus, so each one needs ⌘.",
                            actions: menuActions)

                    fixedKeys
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 580)
        .onAppear { recorder.listen() }
        .onDisappear { recorder.stop() }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Keyboard Shortcuts").font(.headline)
            Text("Click a key to change it, then press the one you want. Escape to leave it alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Reset All") { shortcuts.resetAll(); recorder.message = nil }
                .disabled(!shortcuts.isCustomised)

            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Sections

    private func section(_ title: String, note: String, actions: [ShortcutAction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(note)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(actions) { action in
                    row(action)
                }
            }
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let all = shortcuts.combos(action)
        let isDefault = all == (Shortcuts.defaults[action] ?? [])

        return HStack(spacing: 6) {
            Text(action.title)
                .font(.callout)
                .frame(width: 230, alignment: .leading)
                .lineLimit(1)

            keyButton(action, slot: 0, combo: all.first)

            if action.takesSecondKey {
                keyButton(action, slot: 1, combo: all.count > 1 ? all[1] : nil)
                Button {
                    shortcuts.clearSecond(action)
                    recorder.message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove the second key")
                .opacity(all.count > 1 ? 1 : 0)
                .disabled(all.count < 2)
            }

            Spacer()

            Button("Reset") {
                shortcuts.reset(action)
                recorder.message = nil
            }
            .buttonStyle(.link)
            .font(.caption)
            .opacity(isDefault ? 0 : 1)
            .disabled(isDefault)
        }
        .padding(.vertical, 1)
    }

    private func keyButton(_ action: ShortcutAction, slot: Int, combo: KeyCombo?) -> some View {
        let listening = recorder.target == KeyRecorder.Target(action: action, slot: slot)

        return Button {
            recorder.message = nil
            recorder.target = listening ? nil : KeyRecorder.Target(action: action, slot: slot)
        } label: {
            Text(listening ? "Press a key" : (combo?.display ?? "Add"))
                .font(.caption.weight(.medium))
                .foregroundStyle(labelColour(listening: listening, combo: combo))
                .frame(width: 86)
                .padding(.vertical, 4)
                .background(fill(listening: listening, combo: combo))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(listening ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(listening ? "Press the key you want" : "Click, then press the key you want")
    }

    private func labelColour(listening: Bool, combo: KeyCombo?) -> Color {
        if listening { return .accentColor }
        return combo == nil ? .secondary : .primary
    }

    private func fill(listening: Bool, combo: KeyCombo?) -> Color {
        if listening { return .accentColor.opacity(0.12) }
        return combo == nil ? .clear : Color.secondary.opacity(0.14)
    }

    // MARK: The ones that don't move

    private var fixedKeys: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIXED")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("Escape leaves the full-screen preview · ⌘, opens this sheet · "
                 + "⌘A selects every clip shown · ⇧ and ⌥ with a click extend the selection")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
