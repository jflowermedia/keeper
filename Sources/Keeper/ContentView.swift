import SwiftUI
import AVKit
import AVFoundation

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var inspecting: Clip?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                clipList
                    .frame(minWidth: 420, idealWidth: 500)
                PreviewPane(clip: state.previewClip)
                    .frame(minWidth: 320)
            }
            if state.debugMode {
                Divider()
                DebugPanel(state: state)
            }
            Divider()
            footer
        }
        .frame(minWidth: 940, minHeight: 580)
        .sheet(item: $inspecting) { clip in
            XMLInspector(clip: clip, keepWord: state.keepWord)
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Choose Card…") { state.chooseCard() }
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
            .help("Rescan the card")
            .disabled(state.root == nil || state.isScanning || state.isCopying)

            Toggle(isOn: $state.debugMode) {
                Label("Debug", systemImage: "ladybug")
            }
            .toggleStyle(.button)
            .help("Show the debug log: which XML pairs with which video, and why each clip is KEEP or not")

            if state.isScanning || state.isCopying { ProgressView().controlSize(.small) }
        }
        .padding(10)
    }

    // MARK: List

    private var clipList: some View {
        Group {
            if state.visible.isEmpty {
                Text(state.clips.isEmpty ? state.status : "No clips match this filter.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.visible, selection: $state.selection) { clip in
                    ClipRow(clip: clip, urls: state.urls(for: clip), includeXML: state.includeXML)
                        .contextMenu {
                            Button("Show XML…") { inspecting = clip }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([clip.videoURL])
                            }
                        }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
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

            Button("Copy to Folder…") { state.copyToFolder() }
                .disabled(state.dragClips.isEmpty || state.isCopying || state.isScanning)

            MultiDragHandle(urls: state.isCopying ? [] : state.dragURLs, label: dragLabel, style: .bar)
                .frame(width: 250, height: 36)
                .help(dragHelp)
        }
        .padding(10)
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

    var body: some View {
        if let clip {
            PlayerView(url: clip.videoURL).id(clip.id)
        } else {
            Text("Select a clip to preview")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Uses AppKit's AVPlayerView directly. SwiftUI's VideoPlayer crashes at launch when the app
/// is run as a plain Swift package (AVKit isn't loaded), so this wraps the AppKit view instead.
struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
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
