import SwiftUI
import AVKit
import AVFoundation

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var library = TagLibrary.shared
    @State private var inspecting: Clip?
    @State private var editingPresets = false
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
        .frame(minWidth: 1020, maxWidth: .infinity,
               minHeight: 620, maxHeight: .infinity)
        .sheet(item: $inspecting) { clip in
            XMLInspector(clip: clip, keepWord: state.keepWord)
        }
        .sheet(isPresented: $editingPresets) {
            PresetEditor()
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            Playback.shared.startListening()
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
            .help("Show or hide the tagging panel (⌘E)")

            Toggle(isOn: $state.debugMode) {
                Label("Debug", systemImage: "ladybug")
            }
            .toggleStyle(.button)
            .help("Show the debug log: which XML pairs with which video, and why each clip is KEEP or not")

            if state.isScanning || state.isCopying { ProgressView().controlSize(.small) }
        }
        .padding(10)
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
                    ForEach(state.library.teams) { team in
                        Button(team.name) { state.filterTeamID = team.id }
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
                ForEach(state.library.categories, id: \.self) { category in
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
                List(state.visible, selection: $state.selection) { clip in
                    ClipRow(clip: clip,
                            urls: state.urls(for: clip),
                            includeXML: state.includeXML,
                            tags: state.library.tags(forUMID: clip.umid))
                        .contextMenu {
                            Button("Show XML…") { inspecting = clip }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([clip.videoURL])
                            }
                            if let umid = clip.umid, state.library.isTagged(umid) {
                                Divider()
                                Button("Remove all tags from this clip", role: .destructive) {
                                    state.library.removeAllTags(forUMID: umid)
                                }
                            }
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
                Text("\(state.keepCount) KEEP · \(state.notKeepCount) NOT KEEP")
                    .font(.callout)
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Toggle("Include XML", isOn: $state.includeXML)
                .toggleStyle(.checkbox)
                .help("Take each clip's XML sidecar along with its video")

            Picker("", selection: $state.grouping) {
                ForEach(AppState.Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("""
                  How Copy to Folder lays out the destination.
                  Per category: one copy of each clip, in the folder for its highest-priority tag — the same tag its filename uses.
                  Per player: a copy in each tagged player's folder, so every player's folder is complete.
                  """)

            Menu {
                Button("Keep original names") { state.renamePresetID = nil }
                if !state.library.presets.isEmpty {
                    Divider()
                    ForEach(state.library.presets) { preset in
                        Button(preset.name) { state.renamePresetID = preset.id }
                    }
                }
                Divider()
                Button("Edit Presets…") { editingPresets = true }
            } label: {
                Text(state.activePreset?.name ?? "Original names")
            }
            .frame(width: 150)
            .help(state.activePreset.map { "Copies are renamed: \(Renamer.preview(preset: $0))" }
                  ?? "Copies keep their camera filenames. Pick a preset to rename them.")

            Button("Copy to Folder…") { state.copyToFolder() }
                .disabled(state.dragClips.isEmpty || state.isCopying || state.isScanning)

            MultiDragHandle(urls: state.isCopying ? [] : state.dragURLs, label: dragLabel, style: .bar)
                .frame(width: 250, height: 36)
                .help(dragHelp)
        }
    }

    private var dragLabel: String {
        let n = state.dragClips.count
        guard n > 0 else { return "Nothing to drag" }
        return "Drag \(n) clip\(n == 1 ? "" : "s") · \(FileUtil.sizeText(state.dragSize))"
    }

    private var dragHelp: String {
        let selected = state.visible.filter { state.selection.contains($0.id) }.count
        let scope = selected == 0
            ? "Nothing is selected, so this drags every clip shown by the current filter."
            : "This drags the \(selected) selected clip\(selected == 1 ? "" : "s")."
        let xml = state.includeXML ? " Each clip's XML comes too." : " Videos only (Include XML is off)."
        return "Drag onto a Finder window or the Desktop. " + scope + xml
    }
}

// MARK: - Row

struct ClipRow: View {
    let clip: Clip
    let urls: [URL]
    let includeXML: Bool
    let tags: [Tag]

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

            Text(clip.isKeep ? "KEEP" : "—")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(clip.isKeep ? Color.green.opacity(0.25) : Color.clear)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
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

    var body: some View {
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
                Text("Space or 2 — play / pause\n1 and 3 — shuttle back and forward\npress again for 4x and 8x")
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
    private var monitor: Any?
    private var scrubTimer: Timer?
    private var scrubbing = false
    private var rateObservation: NSKeyValueObservation?

    // MARK: Wiring

    func attach(_ player: AVPlayer) {
        stopScrub()
        self.player = player
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

    func startListening() {
        guard monitor == nil else { return }
        let blocking: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(blocking).isEmpty,
                  let key = event.charactersIgnoringModifiers
            else { return event }

            if let responder = event.window?.firstResponder, responder is NSText {
                return event                        // a text field is being edited
            }

            let playback = Playback.shared
            switch key {
            case " ", "2": return playback.toggle() ? nil : event
            case "3":      return playback.shuttle(forward: true) ? nil : event
            case "1":      return playback.shuttle(forward: false) ? nil : event
            default:       return event
            }
        }
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
        Playback.shared.attach(player)      // so the transport keys can reach it
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.player?.pause()
        view.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
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
