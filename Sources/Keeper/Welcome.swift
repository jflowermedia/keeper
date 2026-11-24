import SwiftUI

/// Something the welcome sheet offers to do for you once it's out of the way.
///
/// Recorded rather than run: most of these open an `NSOpenPanel`, and a modal panel put up
/// from inside a sheet that's still animating away is how you end up with a picker attached
/// to a window that's no longer there. `ContentView` runs it from the sheet's `onDismiss`,
/// which fires after the sheet has actually gone.
enum WelcomeAction {
    case chooseFolder
    case importRoster
    case downloadRoster

    var label: String {
        switch self {
        case .chooseFolder: return "Choose Folder…"
        case .importRoster: return "Import Roster CSV…"
        case .downloadRoster: return "Download a Roster…"
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
                // The why before the what: the time saved is the reason to use it at all.
                Text("Flag the good clips at the game, and Keeper starts you from those — then "
                     + "tags, renames and copies them out, organised.")
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
                .background(Color.keeperAccent.opacity(0.12))
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
                            .background(Color.keeperSecondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(action.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let link = current.link {
                    Button(link.label) { NSWorkspace.shared.open(link.url) }
                }

                if !current.doIt.isEmpty {
                    HStack {
                        ForEach(current.doIt, id: \.label) { doIt in
                            Button(doIt.label) { finish(then: doIt) }
                        }
                    }
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
        var doIt: [WelcomeAction] = []
        /// A page to open, with the button's label. Unlike `doIt` it leaves the tour open —
        /// reading the guide is something you do alongside it, not instead of finishing.
        var link: (label: String, url: URL)? = nil
    }

    /// A shoot day in order, and the same six steps under the same headings as the guide in the
    /// README, so the two can't drift into describing different apps. Change one, change both.
    /// Each is one job and a few lines; anything longer belongs in the guide's Reference.
    static let steps: [Step] = [
        // First, because it happens in the camera before there's a card to point at — and
        // without it everything after ends at an empty Picks list with no clue why.
        Step(title: "Set up the camera",
             body: "On a Sony, assign Clip Flag KEEP to a custom button with Custom Key Setting, and "
                 + "OK to another if you want it. Press it while recording or playing back, and "
                 + "again to take it off.\n\n"
                 + "KEEP is for the best, OK for the rest worth keeping. The flag is saved in the "
                 + "XML file beside each clip, so keep those files when you offload.",
             link: (label: "Sony's guide to Clip Flag", url: AppInfo.sonyClipFlag)),

        Step(title: "Get your roster",
             body: "Download a Roster has the NHL, AHL, ECHL, PWHL, the three major junior leagues "
                 + "and western Junior A. Any other league or sport: import a CSV with a number and "
                 + "a name per player.\n\n"
                 + "Later, File → Update All Rosters… brings them up to date. Clips you've already "
                 + "tagged don't change.",
             key: .importRoster,
             doIt: [.downloadRoster, .importRoster]),

        Step(title: "Open the card",
             body: "Choose a card, drive or folder. Keeper only reads it: nothing on the card is "
                 + "ever changed.\n\n"
                 + "You start on Picks, your KEEP and OK clips. Arrow keys move between them and "
                 + "Space plays. \(Shortcuts.shared.display(.toggleKeep)) marks KEEP or unpicks, "
                 + "\(Shortcuts.shared.display(.toggleOK)) marks OK, and ⌘Z undoes.\n\n"
                 + "Nothing under Picks? Check the Camera menu in the toolbar.",
             key: .chooseFolder,
             doIt: [.chooseFolder]),

        Step(title: "Tag",
             body: "Pick your team in the panel under the video, and tick Both teams for a game. "
                 + "Click a player, then what happened. The mascot, the crowd and the anthem are "
                 + "on the Subjects pill.\n\n"
                 + "Faster, with keyboard tagging on: Return, the shirt number or a name, Return, "
                 + "the category or its number, Return. That tags it and moves to the next clip.\n\n"
                 + "Two games on one card? Right-click the first clip of the second and choose "
                 + "New Game Starts Here.",
             key: .keyboardFlow),

        Step(title: "Export",
             body: "Pick a filename preset and a folder, and your picks are copied out, named from "
                 + "their tags.\n\n"
                 + "Run it again and anything already copied is skipped.",
             key: .export),

        // Last, and with the guide's link: the step that stops someone wiping footage that
        // didn't copy is the one to end on.
        Step(title: "Check, then format",
             body: "Check Copied compares your copies with the card and lists anything missing or "
                 + "the wrong size. Only format the card once it's clean.\n\n"
                 + "That's the whole day. The guide has the rest, and it's always under "
                 + "Help → Keeper Guide.",
             key: .verify,
             link: (label: "Open the Keeper Guide", url: AppInfo.guide))
    ]
}
