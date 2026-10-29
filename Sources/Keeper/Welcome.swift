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

    /// In the order the work actually happens on a shoot day, which is also the order the guide
    /// in the README follows — so the two can't drift into describing different apps. Each step
    /// is one job and a couple of lines; anything longer belongs in the README.
    static let steps: [Step] = [
        // First, because it happens in the camera before there's a card to point at — and
        // without it everything after ends at an empty Kept list with no clue why.
        Step(title: "Mark clips in camera",
             body: "Keeper sorts by the KEEP flag your camera puts on a clip. On a Sony, assign "
                 + "Clip Flag KEEP to a custom button with Custom Key Setting, then press it "
                 + "while recording or playing back. Press it twice to take the flag off.\n\n"
                 + "The flag is saved in the XML file the camera writes beside each clip, not "
                 + "in the video. Point Keeper at the card itself, or at a copy that kept the "
                 + "XML files.",
             link: (label: "Sony's guide to Clip Flag", url: AppInfo.sonyClipFlag)),

        Step(title: "Choose your card",
             body: "Plug in the card and choose it, or any folder of camera clips. Keeper lists "
                 + "each clip by its XML sidecar, so a video with no sidecar won't appear.\n\n"
                 + "Keeper only reads. Nothing on the card is ever changed.",
             key: .chooseFolder,
             doIt: [.chooseFolder]),

        Step(title: "Review your KEEPs",
             body: "The filter bar along the top splits the card into Kept and Not kept, using "
                 + "the flag your camera wrote. Nothing under Kept? Check the Camera menu in the "
                 + "toolbar — Other… takes whatever word your camera uses.\n\n"
                 + "Arrow keys move between clips and Space plays. Changed your mind? The Mark "
                 + "menu flips the flag, and ⌘Z undoes it. A flag you change is applied to "
                 + "your copy, never to the card.",
             key: .toggleKeep),

        Step(title: "Load your roster",
             body: "File → Download a Roster… fetches today's numbers for a league — the NHL, "
                 + "for now.\n\n"
                 + "Any other league: import a CSV with a number and a name per player.\n\n"
                 + "Already have the team? Keeper shows what's changed and asks before it "
                 + "touches your roster.",
             key: .importRoster,
             doIt: [.downloadRoster, .importRoster]),

        Step(title: "Tag your clips",
             body: "Pick a clip, then a player and a category in the panel on the right. "
                 + "Shooting a game? Tick Both teams and add the other bench.\n\n"
                 + "To skip the mouse: Tab moves between the list, the bench and the "
                 + "categories, and typing a shirt number jumps to that player.",
             key: .keyboardFlow),

        Step(title: "Export",
             body: "Export copies the clips you're keeping to your drive. Pick a filename "
                 + "preset in the sheet and each one is named from its tags; leave it and they "
                 + "keep the camera's names.\n\n"
                 + "Run it again and anything already copied is skipped.",
             key: .export),

        Step(title: "Check before you format",
             body: "Check Copied compares your copies with the card and lists anything missing "
                 + "or the wrong size. When an export finishes, a link beside the status line "
                 + "opens it with that folder already added.\n\n"
                 + "Only format the card once it's clean.",
             key: .verify),

        Step(title: "Where to go next",
             body: "That's the whole shoot-day loop. The guide covers the rest: filename "
                 + "presets for each client, every setting, rebinding keys, backups and "
                 + "restoring your tags, and what to do when something's off.\n\n"
                 + "It's always under Help → Keeper Guide.",
             link: (label: "Open the Keeper Guide", url: AppInfo.guide))
    ]
}
