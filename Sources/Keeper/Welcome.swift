import SwiftUI

/// Something the welcome sheet offers to do for you once it's out of the way.
///
/// Recorded rather than run: both of these open an `NSOpenPanel`, and a modal panel put up
/// from inside a sheet that's still animating away is how you end up with a picker attached
/// to a window that's no longer there. `ContentView` runs it from the sheet's `onDismiss`,
/// which fires after the sheet has actually gone.
enum WelcomeAction {
    case chooseFolder
    case importRoster

    var label: String {
        switch self {
        case .chooseFolder: return "Choose Folder…"
        case .importRoster: return "Import Roster CSV…"
        }
    }
}

/// The first-launch question, and the short tour behind it.
///
/// Opens by itself once — on the first launch with no `welcomeShown` in defaults — and after
/// that only from Help → Welcome & Tutorial, so it's never in the way twice.
///
/// The tour is pages of text rather than arrows pointed at the real controls. Coach marks have
/// to be re-aimed every time the layout moves, and the filter bar, the footer and the tagging
/// panel have all moved in the last two versions; text that's slightly general stays true,
/// where an arrow pointing at the wrong corner is just wrong. The keys it quotes are read from
/// `Shortcuts` as it draws, so they follow your own remapping instead of repeating the
/// defaults back at you.
struct WelcomeSheet: View {
    @ObservedObject var state: AppState
    /// Observed so a tour left open while you remap something redraws with the new key.
    @ObservedObject private var shortcuts = Shortcuts.shared

    @State private var touring = false
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if touring {
                tourHeader
                Divider()
                tourBody
                Divider()
                tourFooter
            } else {
                question
            }
        }
        .frame(width: 560, height: touring ? 430 : 350)
    }

    // MARK: - The question

    private var question: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Keeper").font(.title2.weight(.semibold))
                Text("Keeper reads the KEEP flag your camera writes, sorts a card by it, and "
                     + "copies out the clips you're keeping — tagged and renamed.")
                    .fixedSize(horizontal: false, vertical: true)

                // The thing a new user is actually nervous about, said plainly and early.
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "lock.shield")
                    Text("Keeper never writes to your camera cards. It only ever reads them.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout.weight(.medium))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // The count comes from the array, not from a number typed into the
                // sentence — add a step and the copy would otherwise go quietly wrong.
                Text("Would you like a quick run through how it works? It's "
                     + "\(WelcomeTour.steps.count) short steps and you can leave at any point.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Spacer(minLength: 0)
            Divider()

            HStack {
                Text("You can reopen this from Help → Welcome & Tutorial.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("No Thanks") { finish() }
                    .keyboardShortcut(.cancelAction)
                Button("Show Me How") { touring = true }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    // MARK: - The tour

    /// Clamped rather than indexed straight: `step` is view state and the array is a
    /// constant, so they can only disagree by a bug — but the cost of that bug would be a
    /// crash on a tutorial, which is the worst possible place for one.
    private var current: WelcomeTour.Step {
        WelcomeTour.steps[min(max(step, 0), WelcomeTour.steps.count - 1)]
    }

    private var tourHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Step \(step + 1) of \(WelcomeTour.steps.count)")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(current.title).font(.headline)
        }
        .padding(16)
    }

    private var tourBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(current.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = current.key {
                    HStack(spacing: 8) {
                        Text(shortcuts.display(action))
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(action.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let doIt = current.doIt {
                    Button(doIt.label) { finish(then: doIt) }
                    Text("This closes the tutorial so you can see what happens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var tourFooter: some View {
        HStack {
            Button("Skip") { finish() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Back") { step -= 1 }
                .disabled(step == 0)
            if step == WelcomeTour.steps.count - 1 {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    /// Marks the welcome as seen and closes. Anything the tour offered to do for you is left
    /// on `state` for `ContentView` to run once the sheet has gone.
    private func finish(then action: WelcomeAction? = nil) {
        state.pendingWelcomeAction = action
        // Lowering the flag is what closes the sheet — the same flag Help raises — so there's
        // no second dismissal path to keep in step with it. `ContentView`'s `onDismiss` fires
        // either way, which is what runs the action above.
        state.finishWelcome()
    }
}

/// What the tutorial says, and in what order.
///
/// At file scope rather than inside the view for the same reason `ReleaseFeed` is: the
/// self-check reads it back, and a static tucked inside a SwiftUI view carries that view's
/// isolation along with it. Text in a plain array is also the easiest thing in this app to
/// keep honest — it sits next to nothing it has to agree with except the README.
enum WelcomeTour {

    struct Step {
        let title: String
        let body: String
        /// Shown as a key cap, read live from `Shortcuts`.
        var key: ShortcutAction? = nil
        /// A button that really does this step, after the sheet closes.
        var doIt: WelcomeAction? = nil
    }

    /// In the order the work actually happens, which is also the order the guide in the
    /// README follows — so the two can't drift into describing different apps.
    static let steps: [Step] = [
        Step(title: "Point it at a card",
             body: "Choose the card, or any folder holding camera clips. Keeper looks for "
                 + "video files and the XML sidecars beside them, and the sidecar is where the "
                 + "KEEP flag lives — a clip with no sidecar can't be listed or tagged.\n\n"
                 + "Nothing is copied or changed by scanning. You can point it at a card "
                 + "straight out of the camera.",
             key: .chooseFolder,
             doIt: .chooseFolder),

        Step(title: "KEEP and NOT KEEP",
             body: "The filter bar splits the card by the flag your camera wrote. KEEP is what "
                 + "you marked in-camera; NOT KEEP is everything else.\n\n"
                 + "If KEEP comes up empty, your camera may use a different word. Right-click "
                 + "a clip and choose Show XML… to see what it actually writes, then put that "
                 + "word in Flag word."),

        Step(title: "Change your mind",
             body: "The flag isn't final. With a clip in the preview, the Mark menu's toggle "
                 + "flips it; the badge on a row does the same without moving the preview; and "
                 + "with several clips selected, the Mark commands do the lot at once.\n\n"
                 + "⌘Z takes any of it back — in bulk as well as one at a time — and the undo "
                 + "button names what it's about to undo before you press it.",
             key: .toggleKeep),

        Step(title: "Get through them quickly",
             body: "Arrow keys move between clips, and the preview follows. Space plays and "
                 + "pauses, and the shuttle keys step through a clip without reaching for the "
                 + "scrubber.\n\n"
                 + "All of these are one press with no modifier, so a whole pass can be worked "
                 + "one-handed. They do nothing while you're typing in a field.",
             key: .playPause),

        Step(title: "Rosters, then tags",
             body: "Import a team as a CSV, one player per line, with a number and a name. A "
                 + "header row is optional, several teams can share one file, and there's a "
                 + "sample roster in the repo to try it with. Two players can't share a "
                 + "number — that's how Keeper tells them apart.\n\n"
                 + "Once a roster is in, its bench appears in the tagging panel and you tag a "
                 + "clip by picking a player and a category. Tags aren't just labels: they're "
                 + "what the filenames are built from, so a tagged clip comes out of an export "
                 + "already named for the player and the moment.",
             key: .importRoster,
             doIt: .importRoster),

        Step(title: "Tagging without the mouse",
             body: "Optional, and worth it for a long card. Tab moves between the clip list, "
                 + "the bench and the categories, and the section you're on is outlined. "
                 + "Return selects. Type a number while you're on the bench and it filters to "
                 + "that shirt, then clears itself when you move on.\n\n"
                 + "Shooting both teams, the focus keys swap benches without going back to the "
                 + "mouse.",
             key: .keyboardFlow),

        Step(title: "Export what you're keeping",
             body: "Export copies the clips you've chosen to wherever you're keeping them, "
                 + "renaming each one by your filename preset as it goes. Sidecars travel with "
                 + "them if you want them to.\n\n"
                 + "It reads the card and writes to your drive. A copy that keeps failing stops "
                 + "itself after five in a row rather than filling the log with the same error, "
                 + "and anything already copied is skipped if you run it again.",
             key: .export),

        Step(title: "Before you format the card",
             body: "This is the one that matters. Check Copied takes every folder you copied "
                 + "the card into and reports what's accounted for, what's missing, and what "
                 + "arrived the wrong size — gigabytes on the card against gigabytes found.\n\n"
                 + "Matching is by the camera's clip ID, so renamed copies are still "
                 + "recognised. Keeper is alpha software: check, then format.",
             key: .verify)
    ]
}
