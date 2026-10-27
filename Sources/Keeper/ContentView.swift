import SwiftUI
import AVKit
import AVFoundation
import Combine

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var library = TagLibrary.shared
    @ObservedObject private var shortcuts = Shortcuts.shared
    @State private var inspecting: Clip?
    @AppStorage("showTagging") private var showTagging = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !state.library.teams.isEmpty {
                Divider()
                tagFilterBar
            }
            Divider()
            HSplitView {
                clipList
                    .flowSection(.clips, current: state.tagStage, active: state.keyboardFlow)
                    .frame(minWidth: 400, idealWidth: 460, maxHeight: .infinity)
                PreviewPane(clip: state.previewClip)
                    .frame(minWidth: 300, maxHeight: .infinity)
                if showTagging {
                    TagPanel(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.debugMode {
                Divider()
                DebugPanel(state: state)
            }
            Divider()
            footer
        }
        // Without the .infinity maxima the whole window's content sizes to itself
        // and floats in the middle of a larger window.
        .frame(minWidth: 1100, maxWidth: .infinity,
               minHeight: 620, maxHeight: .infinity)
        .sheet(item: $inspecting) { clip in
            XMLInspector(clip: clip, keepWord: state.keepWord)
        }
        .sheet(isPresented: $state.showExportSheet) {
            ExportSheet(state: state)
        }
        // The export sheet opens this itself. This is the route from the menu, so presets
        // are still reachable without going through an export.
        .sheet(isPresented: $state.showPresetEditor) {
            PresetEditor()
        }
        .sheet(isPresented: $state.showRosterEditor) {
            RosterEditor(state: state)
        }
        .sheet(isPresented: $state.showVerifySheet) {
            VerifySheet(state: state)
        }
        .sheet(isPresented: $state.showShortcutsSheet) {
            ShortcutsSheet()
        }
        // `onDismiss` rather than a button inside the sheet: both of the things the tutorial
        // offers to do open a modal file picker, which needs the sheet to be gone first.
        .sheet(isPresented: $state.showWelcome, onDismiss: { state.runPendingWelcomeAction() }) {
            WelcomeSheet(state: state)
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            Playback.shared.startListening()
            state.refreshBackups()
            // Throttled to once a day, and silent when it fails — being offline on launch
            // is the normal case, not something worth a banner.
            UpdateCheck.shared.check()
            state.offerWelcomeIfFirstLaunch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .keeperLibraryBackedUp)) { _ in
            state.refreshBackups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .keeperFlowKey)) { note in
            guard let key = note.userInfo?["key"] as? String,
                  let shift = note.userInfo?["shift"] as? Bool,
                  let token = note.userInfo?["token"] as? Int
            else { return }
            state.handleFlowKey(key, shift: shift, token: token,
                                up: note.userInfo?["up"] as? Bool ?? false)
        }
        // A roster can be edited or deleted while the cursor is sitting in it.
        .onChange(of: state.library.teams) { _ in
            state.clampFlowCursors()
        }
        // The key monitor can't touch `AppState` — it runs outside the main actor and this
        // does not — so it posts instead and the move happens here.
        .onReceive(NotificationCenter.default.publisher(for: .keeperMoveSelection)) { note in
            guard let delta = note.userInfo?["delta"] as? Int,
                  let token = note.userInfo?["token"] as? Int
            else { return }
            // Every window's view hears this, and they share one `AppState`, so without the
            // token a second window would move the selection twice for one key press.
            state.moveSelection(delta, token: token)
        }
        // Same hop, same reason: the monitor can't put an alert up from outside the main
        // actor, and the token stops a second window asking twice for one key press.
        .onReceive(NotificationCenter.default.publisher(for: .keeperClearTags)) { note in
            guard let token = note.userInfo?["token"] as? Int else { return }
            // Off the current turn of the run loop before the alert goes up. `onReceive`
            // fires as part of SwiftUI's own update, and `runModal` spins a nested run loop
            // inside it — the same shape of problem as putting a file picker up from inside
            // a sheet, which cost a week earlier in this app's life.
            //
            // A second window's copy of this hop can run *during* that modal, because the
            // nested run loop drains the main queue. It's harmless only because the token is
            // claimed at the top of `removeTagsInScope`, before the alert goes up — so the
            // second one is already a repeat by the time it gets there.
            DispatchQueue.main.async { state.removeTagsInScope(token: token) }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Choose Folder…") { state.chooseCard() }
                .disabled(state.isScanning || state.isCopying)

            if let root = state.root {
                Text(root.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root.path)
            }

            Spacer()

            Picker("Filter", selection: $state.filter) {
                ForEach(AppState.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()

            HStack(spacing: 4) {
                Text("Flag word")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("KEEP", text: $state.keepWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { state.scan() }
                    .help("The word in the XML that marks a clip. Press Return to rescan.")
            }

            Button {
                state.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan")
            .disabled(state.root == nil || state.isScanning || state.isCopying)

            Toggle(isOn: $showTagging) {
                Label("Tagging", systemImage: "number")
            }
            .toggleStyle(.button)
            .help("Show or hide the tagging panel (\(shortcuts.display(.taggingPanel)))")

            Toggle(isOn: $state.debugMode) {
                Label("Debug", systemImage: "ladybug")
            }
            .toggleStyle(.button)
            .help("Show the debug log: which XML pairs with which video, and why each clip is KEEP or not")

            if state.isScanning || state.isCopying { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            UpdateBanner()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = state.library.loadFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.8))
            }
        }
    }

    // MARK: Tag filter bar

    private var tagFilterBar: some View {
        HStack(spacing: 10) {
            Text("Filter by tag")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.library.teams.count > 1 {
                Menu {
                    Button("Any team") { state.filterTeamID = nil }
                    Divider()
                    // Headed by league once there's more than one, because a flat list of
                    // every roster you've ever imported gets long fast.
                    if state.library.leaguesAreWorthShowing {
                        ForEach(state.library.teamsByLeague) { group in
                            Section(group.name) {
                                ForEach(group.teams) { team in
                                    Button(team.name) { state.filterTeamID = team.id }
                                }
                            }
                        }
                    } else {
                        ForEach(state.library.teams) { team in
                            Button(team.name) { state.filterTeamID = team.id }
                        }
                    }
                } label: {
                    Text(state.library.team(id: state.filterTeamID)?.name ?? "Any team")
                }
                .frame(width: 170)
                .help("Narrows the clips, and the player menu, to one roster")
            }

            Menu {
                Button("Any player") { state.filterPlayerID = nil }
                Divider()
                if state.teamsForFilter.count == 1, let only = state.teamsForFilter.first {
                    ForEach(only.players) { player in
                        Button(player.label) { state.filterPlayerID = player.id }
                    }
                } else {
                    ForEach(state.teamsForFilter) { team in
                        Section(team.name) {
                            ForEach(team.players) { player in
                                Button(player.label) { state.filterPlayerID = player.id }
                            }
                        }
                    }
                }
            } label: {
                Text(playerFilterLabel)
            }
            .frame(width: 190)

            if !positionsForFilter.isEmpty {
                Menu {
                    Button("Any position") { state.filterPosition = nil }
                    Divider()
                    ForEach(positionsForFilter, id: \.self) { position in
                        Button(position) { state.filterPosition = position }
                    }
                } label: {
                    Text(state.filterPosition ?? "Any position")
                }
                .frame(width: 140)
            }

            Menu {
                Button("Any category") { state.filterCategory = nil }
                Divider()
                // The one-offs too, or a word you tagged five clips with this afternoon
                // would be the one thing you couldn't filter by.
                ForEach(state.library.allCategories, id: \.self) { category in
                    Button(category) { state.filterCategory = category }
                }
            } label: {
                Text(state.filterCategory ?? "Any category")
            }
            .frame(width: 150)

            if state.isTagFiltered {
                Button("Clear") { state.clearTagFilters() }
                    .buttonStyle(.link)
            }

            Spacer()

            Text("\(state.taggedCount) of \(state.clips.count) clips tagged")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var playerFilterLabel: String {
        guard let id = state.filterPlayerID,
              let player = state.library.allPlayers.first(where: { $0.id == id })
        else { return "Any player" }
        return player.label
    }

    /// Only the positions in play for the chosen team, for the same reason as the players.
    private var positionsForFilter: [String] {
        let players = state.teamsForFilter.flatMap(\.players)
        return Array(Set(players.map(\.position).filter { !$0.isEmpty })).sorted()
    }

    // MARK: List

    private var clipList: some View {
        Group {
            if state.visible.isEmpty {
                if state.clips.isEmpty {
                    welcome
                } else {
                    Text("No clips match this filter.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Wrapped so the arrow keys can bring their row into view. Rows are
                // identified by their video URL, which is `Clip.id`, so `scrollTo` takes
                // the same value the selection holds.
                ScrollViewReader { proxy in
                    clipRows
                        .onChange(of: state.lastSelected) { id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(id)
                            }
                        }
                }
            }
        }
    }

    private var clipRows: some View {
        List(state.visible, selection: $state.selection) { clip in
            ClipRow(clip: clip,
                    urls: state.urls(for: clip),
                    includeXML: state.includeXML,
                    tags: state.library.tags(forUMID: clip.umid),
                    isKeep: state.isKeep(clip),
                    isChanged: state.isKeepChanged(clip),
                    onToggleKeep: { state.toggleKeep(clip) })
                .contextMenu {
                    Button("Show XML…") { inspecting = clip }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([clip.videoURL])
                    }
                    Divider()
                    Button(state.isKeep(clip) ? "Mark NOT KEEP" : "Mark KEEP") {
                        state.toggleKeep(clip)
                    }
                    if state.isKeepChanged(clip), let umid = clip.umid {
                        Button("Revert to the camera's flag") {
                            state.library.clearKeepOverride(
                                umid: umid,
                                undoLabel: "Revert \(clip.name) to the Camera's Flag")
                        }
                    }
                    if let umid = clip.umid, state.library.isTagged(umid) {
                        Divider()
                        Button("Remove all tags from this clip", role: .destructive) {
                            state.library.removeAllTags(
                                forUMID: umid,
                                undoLabel: "Remove the Tags from \(clip.name)")
                        }
                    }
                }
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "sdcard")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(.tertiary)

                Text(AppInfo.name)
                    .font(.title2.weight(.semibold))

                Text(AppInfo.versionLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18))
                    .clipShape(Capsule())

                Text(state.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)

                Button("Choose Folder…") { state.chooseCard() }
                    .controlSize(.large)
                    .disabled(state.isScanning)
                    .padding(.top, 2)
            }
            Spacer()
            VStack(spacing: 4) {
                Text("Built by JFlowerMedia")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Link("jflowermedia.com", destination: AppInfo.website)
                    Text("·").foregroundStyle(.tertiary)
                    Link("Instagram", destination: AppInfo.instagram)
                }
                .font(.caption)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            footerControls
            if state.isCopying {
                copyProgressBar
            }
        }
        .padding(10)
    }

    private var copyProgressBar: some View {
        VStack(spacing: 3) {
            ProgressView(value: state.copyFraction)
                .progressViewStyle(.linear)
            HStack {
                Text("\(state.copyFilesDone) of \(state.copyFilesTotal) files")
                Spacer()
                Text("\(FileUtil.sizeText(state.copyBytesDone)) of \(FileUtil.sizeText(state.copyBytesTotal))")
                    .monospacedDigit()
                Text("·")
                Text("\(Int(state.copyFraction * 100))%")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var footerControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Link("JFlowerMedia", destination: AppInfo.website)
                    .font(.caption.weight(.medium))
                Text(AppInfo.versionLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Divider().frame(height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(state.keepCount) KEEP · \(state.notKeepCount) NOT KEEP")
                        .font(.callout)
                    if !state.clips.isEmpty {
                        // Follows the filter, so IS KEEP / IS NOT KEEP / ALL answers "how
                        // much is that" without a second control. The tooltip has all three.
                        Text(FileUtil.sizeText(state.visibleBytes))
                            .font(.callout.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14))
                            .clipShape(Capsule())
                            .help(state.sizeBreakdown)
                    }
                    if state.changedKeepCount > 0 {
                        Text("\(state.changedKeepCount) changed")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25))
                            .clipShape(Capsule())
                            .help("Flags you changed. They're written into the XML on export, never onto the card.")
                    }
                }
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Include XML used to sit here, next to the two buttons that matter. It's the
            // same setting the export sheet carries — one flag, two places — so the copy
            // here only mattered for dragging a row to Finder, which isn't worth the space.
            // It's in the View menu now.

            // Always present rather than appearing when there's something to undo: a button
            // that comes and goes would shift Export and Check Copied out from under the
            // pointer. Icon only, like Rescan in the toolbar, with the tooltip naming the
            // change — the menu item carries the full wording.
            Button { state.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .controlSize(.large)
            .disabled(!state.canUndo)
            .help(state.canUndo ? "\(state.undoMenuTitle) (⌘Z)" : "Nothing to undo")

            // Both live here now: the two things you do with a scanned card, in the corner
            // you end up in.
            Button {
                state.showVerifySheet = true
            } label: {
                Label("Check Copied", systemImage: "checkmark.shield")
            }
            .controlSize(.large)
            .disabled(state.clips.isEmpty || state.isScanning || state.isCopying)
            .help("Account for every clip on this card before you format it")

            Button(exportLabel) { state.requestExport() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.visible.isEmpty || state.isCopying || state.isScanning)
                .help("Copy the clips somewhere else, or rename them where they already are")
        }
    }

    /// The button carries the count, so the footer still says what's in scope.
    private var exportLabel: String {
        // The same rule the sheet opens on, so the button doesn't promise a different
        // number from the one you then see.
        let n = state.selectedCount > 0 ? state.selectedCount : state.visible.count
        guard n > 0 else { return "Export…" }
        return "Export \(n) Clip\(n == 1 ? "" : "s")…"
    }

}

// MARK: - Row

struct ClipRow: View {
    let clip: Clip
    let urls: [URL]
    let includeXML: Bool
    let tags: [Tag]
    let isKeep: Bool
    let isChanged: Bool
    let onToggleKeep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MultiDragHandle(urls: urls, style: .grip)
                .frame(width: 16, height: 40)
                .help(includeXML
                      ? "Drag this clip and its XML to Finder"
                      : "Drag this clip to Finder")

            Thumbnail(url: clip.videoURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name).font(.body)
                Text("\(clip.xmlURL.lastPathComponent) · \(FileUtil.sizeText(clip.videoSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagChips(tags: tags)
            }

            Spacer()

            Button(action: onToggleKeep) {
                HStack(spacing: 4) {
                    if isChanged {
                        Image(systemName: "pencil")
                            .font(.caption2)
                    }
                    Text(isKeep ? "KEEP" : "—")
                        .font(.caption.weight(.bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeFill)
                .overlay(
                    Capsule().strokeBorder(isChanged ? Color.orange.opacity(0.9) : .clear,
                                           lineWidth: 1)
                )
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(clip.umid == nil)      // no UMID, nothing to hang an override on
            .help(helpText)
        }
        .padding(.vertical, 2)
    }

    private var badgeFill: Color {
        if isKeep { return isChanged ? .orange.opacity(0.28) : .green.opacity(0.25) }
        return isChanged ? .orange.opacity(0.18) : .clear
    }

    private var helpText: String {
        guard clip.umid != nil else { return "No UMID in this clip's XML, so its flag can't be changed" }
        if isChanged {
            return "You changed this to \(isKeep ? "KEEP" : "NOT KEEP"). The camera says "
                 + "\(clip.isKeep ? "KEEP" : "NOT KEEP"). Click to change back. Applied to the copy, never the card."
        }
        return "From the camera. Click to mark \(isKeep ? "NOT KEEP" : "KEEP")."
    }
}

// MARK: - Thumbnails

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 96, height: 54)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            image = nil      // rows get recycled, so clear before loading the new clip's frame
            image = await ThumbnailCache.shared.thumbnail(for: url)?.image
        }
    }
}

/// NSImage isn't Sendable, but these are created once and never mutated, so a box carries them safely.
struct ImageBox: @unchecked Sendable {
    let image: NSImage
}

/// Caches generated frames so scrolling back up doesn't re-decode, and coalesces duplicate requests.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private var cache: [URL: ImageBox] = [:]
    private var order: [URL] = []
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<ImageBox?, Never>] = [:]
    private let limit = 400

    func thumbnail(for url: URL) async -> ImageBox? {
        if let hit = cache[url] { return hit }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }

        let task = Task.detached(priority: .utility) { await ThumbnailCache.generate(url) }
        inFlight[url] = task
        let box = await task.value
        inFlight[url] = nil

        if let box {
            cache[url] = box
            order.append(url)
            if order.count > limit {
                let drop = order.removeFirst()
                cache[drop] = nil
            }
        } else {
            failed.insert(url)   // formats macOS can't decode shouldn't be retried on every scroll
        }
        return box
    }

    private static func generate(_ url: URL) async -> ImageBox? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        for seconds in [1.0, 0.0] {
            if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return ImageBox(image: NSImage(cgImage: result.image, size: .zero))
            }
        }
        return nil
    }
}

// MARK: - Preview

struct PreviewPane: View {
    let clip: Clip?
    @ObservedObject private var playback = Playback.shared
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        ZStack {
            // Always present, so the pane keeps the width you gave it when the branch below
            // flips. Without it, losing the player leaves only the small placeholder and the
            // split collapses around it — and dragging the divider back is the only way out.
            Color.clear

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let clip {
            PlayerView(url: clip.videoURL)
                .overlay(alignment: .topTrailing) {
                    TransportHUD(speed: playback.speed)
                        .padding(14)
                        .animation(.easeOut(duration: 0.15), value: playback.speed)
                }
        } else {
            VStack(spacing: 6) {
                Text("Select a clip to preview")
                // Read off the bindings rather than written out, so it still tells the
                // truth after someone has changed them.
                Text("\(shortcuts.display(.playPause)) — play / pause\n"
                     + "\(shortcuts.combo(.shuttleBack).display) and "
                     + "\(shortcuts.combo(.shuttleForward).display) — shuttle back and forward, "
                     + "press again for 4x and 8x\n"
                     + "\(shortcuts.combo(.previousClip).display) and "
                     + "\(shortcuts.combo(.nextClip).display) — previous and next clip")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Transport keys for the preview: Space or 2 to play/pause, 3 for 2x forward, 1 for 2x reverse.
///
/// The clip list keeps keyboard focus while you're selecting, so the player never receives these
/// keys itself. A local event monitor catches them instead, and steps aside for text fields so
/// you can still type into them.
final class Playback: ObservableObject {
    static let shared = Playback()

    /// Signed: negative is reverse, 0 is stopped. Drives the on-screen readout.
    @Published private(set) var speed: Double = 0

    static let maxSpeed: Double = 8

    private(set) weak var player: AVPlayer?
    /// The view itself, for full screen. Weak: AppKit owns it, and it outlives nothing.
    private(set) weak var playerView: AVPlayerView?
    private var monitor: Any?
    /// Separate from the key-down monitor on purpose. Folding `.keyUp` into that one would
    /// send every key through the flow twice, and the flow's answer to most keys is to move
    /// something — so a stray second pass is a visible bug rather than a wasted call.
    private var releaseMonitor: Any?
    private var scrubTimer: Timer?
    private var scrubbing = false
    private var rateObservation: NSKeyValueObservation?

    // MARK: Full screen

    /// A window of our own for the full-screen preview.
    ///
    /// The obvious approach — `enterFullScreenMode` on the player view SwiftUI already owns —
    /// doesn't work here, and failed in three different ways before this replaced it. SwiftUI
    /// sizes a representable's view itself, AppKit's full-screen mode sizes it through the
    /// autoresizing mask, and handing one view to both leaves it the width of the split pane
    /// going in and the wrong size coming back. A second window has no such seam: the inline
    /// view is never moved, resized or re-parented.
    ///
    /// Borderless windows refuse key status by default, which would stop the transport keys
    /// and Escape reaching it.
    private final class FullScreenWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var fullScreenWindow: NSWindow?
    private var fullScreenView: AVPlayerView?

    var isFullScreen: Bool { fullScreenWindow != nil }

    /// Puts the clip on a screen of its own. The same `AVPlayer` moves to the full-screen
    /// view, so the clip carries on from exactly where it was rather than reloading — only
    /// one view may render a player at a time, which is why the inline one gives it up.
    func toggleFullScreen() {
        if isFullScreen {
            leaveFullScreen()
        } else {
            enterFullScreen()
        }
    }

    private func enterFullScreen() {
        guard let player, let inline = playerView else { return }
        // A sheet would be left floating over a screen-filling player with no way back to it.
        guard inline.window?.attachedSheet == nil else { return }
        guard let screen = inline.window?.screen ?? NSScreen.main else { return }

        let view = AVPlayerView()
        view.controlsStyle = .floating   // overlays and auto-hides, unlike the inline bar
        view.videoGravity = .resizeAspect

        inline.player = nil             // one renderer at a time
        view.player = player

        let window = FullScreenWindow(contentRect: screen.frame,
                                      styleMask: [.borderless],
                                      backing: .buffered,
                                      defer: false)
        window.contentView = view
        window.backgroundColor = .black
        window.isOpaque = true
        // Default is true, which has AppKit release the window on close while ARC still
        // holds it. We only order it out, but this costs nothing and removes the trap.
        window.isReleasedWhenClosed = false
        // Above the menu bar, so it really does cover the screen.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        fullScreenWindow = window
        fullScreenView = view
    }

    private func leaveFullScreen() {
        guard let window = fullScreenWindow else { return }
        fullScreenView?.player = nil
        window.orderOut(nil)
        fullScreenWindow = nil
        fullScreenView = nil

        // Read the player back rather than trusting a captured one: if the preview was
        // rebuilt while full screen, `attach` will have replaced it.
        if let player, let inline = playerView {
            inline.player = player
            inline.window?.makeKeyAndOrderFront(nil)
            inline.window?.makeFirstResponder(inline)
        } else {
            // The preview was torn down while we were full screen, so there's nothing to
            // hand the clip back to. Don't leave it playing to an empty room.
            player?.pause()
        }
    }

    // MARK: Wiring

    func attach(_ player: AVPlayer, view: AVPlayerView) {
        stopScrub()
        self.player = player
        playerView = view
        speed = 0

        // Catches the clip ending, and the player's own on-screen controls, so the readout
        // never claims to be playing when it isn't.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            let rate = Double(change.newValue ?? 0)
            DispatchQueue.main.async {
                guard !self.scrubbing else { return }   // the shuttle reports its own speed
                self.speed = rate
            }
        }
    }

    /// Which keys do what is now `Shortcuts`, so this looks the press up rather than
    /// switching on a hard-coded character. Review keys carry no modifiers by rule, which is
    /// what lets this bail out early on anything held down.
    func startListening() {
        guard monitor == nil else { return }
        startListeningForRelease()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘, ⌥ and ⌃ belong to the menus. Shift is let through, because the keyboard
            // flow uses ⇧Return and ⇧Tab; the review keys below still insist on no
            // modifier at all.
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard held.isSubset(of: .shift), let key = KeyCombo.name(for: event) else {
                return event
            }
            let shift = held.contains(.shift)

            if let responder = event.window?.firstResponder, responder is NSText {
                return event                        // a text field is being edited
            }

            // These keys are only ours while the app's own window is the one in front with
            // nothing on top of it.
            //
            // The file picker is why this is four tests rather than one. `NSOpenPanel` runs
            // a modal loop in a window of its own: it isn't a sheet, and its first responder
            // is the file list rather than a text field, so it slipped past both of the
            // checks that were here. Arrowing to a folder in the panel was read as "next
            // clip", and `selectRelative` replaces the whole selection with that one clip —
            // so picking an export folder with the keyboard quietly threw away the clips you
            // were about to export. Alerts run modally the same way.
            if NSApp.modalWindow != nil {
                return event                        // an open panel, a save panel, an alert
            }
            if event.window is NSPanel {
                return event                        // any panel, modal or not
            }
            // Sheets — export, rosters, presets — are their own windows. Space scrubbing the
            // clip behind one you're typing in is never what was meant.
            if event.window?.isSheet == true || event.window?.attachedSheet != nil {
                return event
            }

            // The keyboard flow gets first refusal on the keys it uses at the stage it's
            // at. Everything else falls through, which is what keeps Space playing the clip
            // while you tag.
            let flow = FlowKeyState.shared
            if flow.active, FlowKeyState.claims(key, stage: flow.stage, shift: shift) {
                Playback.shared.sendFlowKey(key, shift: shift)
                return nil
            }

            guard !shift else { return event }

            let playback = Playback.shared

            // Escape isn't bindable: it's the way out of full screen and nothing else, so
            // it keeps working as Escape everywhere it has nothing to do.
            if key == "escape" {
                guard playback.isFullScreen else { return event }
                playback.toggleFullScreen()
                return nil
            }

            guard let action = Shortcuts.shared.reviewAction(forKey: key) else { return event }
            switch action {
            case .playPause:      return playback.toggle() ? nil : event
            case .shuttleForward: return playback.shuttle(forward: true) ? nil : event
            case .shuttleBack:    return playback.shuttle(forward: false) ? nil : event
            case .previousClip:   return playback.moveSelection(-1) ? nil : event
            case .nextClip:       return playback.moveSelection(1) ? nil : event
            case .clearTags:      return playback.requestClearTags() ? nil : event
            default:              return event
            }
        }
    }

    /// Counts the presses, so a second window's copy of the view can't act on the same one.
    private var moveToken = 0

    /// Hands a keystroke to the tagging flow, which lives on `AppState` where the clips and
    /// the rosters are. Same reason as `moveSelection`: this closure runs outside the main
    /// actor, so it posts rather than calls.
    /// Watches only for the subjects key coming back up, and only when that key is a hold.
    ///
    /// Everything else is returned untouched, including the key-up of every other key — the
    /// narrowest possible reach for something that has to see every release in the app.
    private func startListeningForRelease() {
        guard releaseMonitor == nil else { return }
        releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            let flow = FlowKeyState.shared
            guard flow.active, flow.holdSubjects, flow.stage == .players,
                  let key = KeyCombo.name(for: event),
                  Shortcuts.shared.isBound(key, to: .subjectsOnly)
            else { return event }

            // Same guards the key-down monitor applies: a release while a panel, a sheet or
            // a text field has the keyboard is not ours to act on.
            if let responder = event.window?.firstResponder, responder is NSText { return event }
            if NSApp.modalWindow != nil { return event }
            if event.window is NSPanel { return event }
            if event.window?.isSheet == true || event.window?.attachedSheet != nil { return event }

            Playback.shared.sendFlowKey(key, shift: false, up: true)
            return nil
        }
    }

    func sendFlowKey(_ key: String, shift: Bool, up: Bool = false) {
        moveToken += 1
        NotificationCenter.default.post(name: .keeperFlowKey,
                                        object: nil,
                                        userInfo: ["key": key,
                                                   "shift": shift,
                                                   "up": up,
                                                   "token": moveToken])
    }

    /// Asks the window to move the preview one clip along.
    ///
    /// Only once a clip is loaded, so before the first selection the arrow keys fall through
    /// to the list's own handling and pick a row the ordinary way. Returns false when there's
    /// nothing loaded, which is what leaves the key press untouched.
    /// Asks the window to clear the tags on whatever is in scope.
    ///
    /// Always returns true, unlike the transport keys: there's nothing here that depends on
    /// a clip being loaded, and the window itself works out whether there's anything to
    /// remove — and says so if there isn't, rather than letting the key fall through to
    /// whatever else might want it.
    @discardableResult
    func requestClearTags() -> Bool {
        moveToken += 1
        NotificationCenter.default.post(name: .keeperClearTags,
                                        object: nil,
                                        userInfo: ["token": moveToken])
        return true
    }

    func moveSelection(_ delta: Int) -> Bool {
        guard player?.currentItem != nil else { return false }
        moveToken += 1
        NotificationCenter.default.post(name: .keeperMoveSelection,
                                        object: nil,
                                        userInfo: ["delta": delta, "token": moveToken])
        return true
    }

    // MARK: Transport

    var isPlaying: Bool { speed != 0 }

    /// Each of these returns false when nothing is loaded, so the key press falls through untouched.
    @discardableResult
    func toggle() -> Bool {
        guard player?.currentItem != nil else { return false }
        if isPlaying { pause() } else { play(speed: 1) }
        return true
    }

    /// Repeated presses step 2x → 4x → 8x. Pressing the opposite key starts again at 2x.
    @discardableResult
    func shuttle(forward: Bool) -> Bool {
        guard player?.currentItem != nil else { return false }
        let direction: Double = forward ? 1 : -1
        let sameWay = speed != 0 && (speed > 0) == forward
        let magnitude = sameWay ? min(abs(speed) * 2, Self.maxSpeed) : 2
        return play(speed: magnitude * direction)
    }

    func pause() {
        stopScrub()
        player?.pause()
        speed = 0
    }

    /// Same player, different clip: stop any shuttle and clear the readout.
    func didChangeClip() {
        stopScrub()
        speed = 0
    }

    @discardableResult
    func play(speed newSpeed: Double) -> Bool {
        guard let player, let item = player.currentItem else { return false }
        stopScrub()
        if newSpeed > 0, atEnd(item) { player.seek(to: .zero) }

        // Not every codec can shuttle natively — 4K all-intra often can't, especially backwards.
        let nativeOK = newSpeed > 0
            ? (newSpeed == 1 || item.canPlayFastForward)
            : item.canPlayFastReverse
        if nativeOK {
            player.rate = Float(newSpeed)
        } else {
            startScrub(speed: newSpeed)
        }
        speed = newSpeed
        return true
    }

    private func atEnd(_ item: AVPlayerItem) -> Bool {
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite else { return false }
        return item.currentTime().seconds >= duration.seconds - 0.05
    }

    // MARK: Emulated shuttle, for formats AVPlayer won't scrub itself

    private func startScrub(speed: Double) {
        scrubbing = true
        player?.pause()
        let tick = 1.0 / 20.0
        scrubTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] timer in
            guard let self, let player = self.player, let item = player.currentItem else {
                timer.invalidate()
                return
            }
            let duration = item.duration
            let limit = (duration.isValid && !duration.isIndefinite)
                ? duration.seconds : Double.greatestFiniteMagnitude
            let target = player.currentTime().seconds + tick * speed

            if target <= 0 || target >= limit {
                player.seek(to: CMTime(seconds: max(0, min(target, limit)), preferredTimescale: 600))
                self.stopScrub()
                self.speed = 0                  // ran off the end of the clip
                return
            }
            // Loose tolerance: lands on the nearest keyframe, which keeps 4K shuttling smooth.
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
        }
    }

    private func stopScrub() {
        scrubTimer?.invalidate()
        scrubTimer = nil
        scrubbing = false
    }
}

/// The speed readout over the player: direction arrows and a multiplier.
struct TransportHUD: View {
    let speed: Double

    var body: some View {
        if speed != 0 {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.62))
            .clipShape(Capsule())
            .transition(.opacity)
        }
    }

    private var icon: String {
        if abs(speed) == 1 { return speed > 0 ? "play.fill" : "backward.fill" }
        return speed > 0 ? "forward.fill" : "backward.fill"
    }

    private var label: String {
        let magnitude = abs(speed)
        let number = magnitude == magnitude.rounded()
            ? String(Int(magnitude))
            : String(format: "%.1f", magnitude)
        return "\(number)×  \(speed > 0 ? "forward" : "reverse")"
    }
}

/// Uses AppKit's AVPlayerView directly. SwiftUI's VideoPlayer crashes at launch when the app
/// is run as a plain Swift package (AVKit isn't loaded), so this wraps the AppKit view instead.
///
/// One player view is built once and kept: selecting another clip swaps the item inside it.
/// Rebuilding the view per clip made the pane jump to the video's own size and then settle,
/// and paid for a fresh AVPlayer every time you clicked a row.
struct PlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect

        // Without this the 4K frame size becomes the view's preferred size and shoves the
        // split view around on the first clip.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        let player = AVPlayer()
        view.player = player
        Playback.shared.attach(player, view: view)   // so the transport keys and ⌘F can reach it
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        // Not `view.player`: while the full-screen window is up this view has handed the
        // player over, and loading into nothing would leave the bookkeeping saying the new
        // clip is showing while the old one is still on screen.
        let player = view.player ?? Playback.shared.player
        player?.pause()
        player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        Playback.shared.didChangeClip()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - Debug panel

struct DebugPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Debug log", systemImage: "ladybug").font(.headline)
                Spacer()
                Button("Copy Log") { state.copyLog() }
                    .disabled(state.log.isEmpty)
                Button("Clear") { state.log = [] }
                    .disabled(state.log.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.logText.isEmpty ? "Nothing logged yet. Choose a card to scan." : state.logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: state.log.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(height: 150)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
    }
}

// MARK: - XML inspector

struct XMLInspector: View {
    let clip: Clip
    let keepWord: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(clip.xmlURL.lastPathComponent).font(.headline)
                    Text("\"\(keepWord)\" detected: \(clip.isKeep ? "YES" : "NO")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .background(.quaternary.opacity(0.4))
        }
        .padding(16)
        .frame(width: 700, height: 500)
        .task { text = Self.read(clip.xmlURL) }
    }

    /// Most sidecars are UTF-8, but fall back rather than showing an error for an odd encoding.
    private static func read(_ url: URL) -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf16) { return s }
        return "Couldn't read this XML file."
    }
}
