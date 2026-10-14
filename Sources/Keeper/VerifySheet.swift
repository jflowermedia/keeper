import SwiftUI
import AppKit

/// Checks that everything on the card reached a destination, before the card is formatted.
///
/// Several destinations because a card rarely goes to one place — KEEP to the working drive,
/// the rest to a second folder. The question worth answering is whether every clip reached
/// *somewhere*, not whether it's all in one place.
struct VerifySheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Check the card copied").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    source
                    destinations
                    if let report = state.verifyReport {
                        results(report)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 640)
    }

    // MARK: Source

    private var source: some View {
        section("The card") {
            if let root = state.root {
                Text(root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("\(state.clips.count) clip\(state.clips.count == 1 ? "" : "s") · "
                     + FileUtil.sizeText(cardBytes) + " to account for"
                     + (umidCoverage < state.clips.count
                        ? " · \(state.clips.count - umidCoverage) without a UMID" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Keeper only sees clips that have a sidecar, so anything else on the card
                // isn't part of this check. Saying "all accounted for" without mentioning
                // them would be the most expensive kind of half-truth.
                if !state.videosWithoutXML.isEmpty {
                    Label("\(state.videosWithoutXML.count) video\(state.videosWithoutXML.count == 1 ? "" : "s") "
                          + "on the card have no XML sidecar — "
                          + FileUtil.sizeText(uncoveredBytes)
                          + " that this check can't account for either way. ⌘D lists them by name.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Scan a card first.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var umidCoverage: Int {
        state.clips.filter { $0.umid != nil }.count
    }

    private var cardBytes: Int64 {
        state.clips.reduce(0) { $0 + $1.videoSize }
    }

    /// Videos on the card with no sidecar. Sized on demand because the scan never needed
    /// their size, and this is only reached when there are some — usually none.
    private var uncoveredBytes: Int64 {
        state.videosWithoutXML.reduce(0) { $0 + max(0, FileUtil.size(of: $1)) }
    }

    // MARK: Destinations

    private var destinations: some View {
        section("Where you copied it") {
            if state.verifyDestinations.isEmpty {
                Text("Add every folder this card's footage went to. A clip found in any of "
                     + "them counts as safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.verifyDestinations, id: \.self) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(folder.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                        Button {
                            state.verifyDestinations.removeAll { $0 == folder }
                            state.verifyReport = nil
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Button("Add Folder…") { state.addVerifyDestination() }
                .disabled(state.isVerifying)
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ report: Verifier.Report) -> some View {
        section("Result") {
            Label(report.summary,
                  systemImage: report.allAccountedFor ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(report.allAccountedFor ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            Text(FileUtil.sizeText(report.sourceBytes) + " in these clips · "
                 + FileUtil.sizeText(report.accountedBytes) + " accounted for")
                .font(.callout)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 3) {
                ForEach(report.summaries) { summary in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(summary.folder.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(summary.matched) clip\(summary.matched == 1 ? "" : "s") · "
                             + FileUtil.sizeText(summary.matchedBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        // Footage from other shoots living in the same folder.
                        if summary.videosThere > summary.matched {
                            Text("(+\(summary.videosThere - summary.matched) others)")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if report.allAccountedFor {
                Text("Every clip was found at full size. Worth opening a couple before you "
                     + "format — a file can be the right size and still not play.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !report.missing.isEmpty {
                problemList("Not found anywhere", report.missing) { _ in "" }
            }

            if !report.wrongSize.isEmpty {
                problemList("There, but the wrong size", report.wrongSize) { result in
                    guard case .wrongSize(let found) = result.outcome else { return "" }
                    return "\(FileUtil.sizeText(found)) vs \(FileUtil.sizeText(result.sourceSize))"
                }
            }

            // The one false alarm this check can raise: footage renamed on export with the
            // sidecar switched off has nothing left to match on, so it reads as missing even
            // though it's sitting right there. Say so rather than let the summary mislead.
            if !report.missing.isEmpty, report.unclaimed >= report.missing.count {
                Label("There are \(report.unclaimed) other videos in those folders that didn't "
                      + "match anything on the card. If you exported these renamed and without "
                      + "their XML sidecars, they may well be the missing clips — there's just "
                      + "nothing left in them to prove it. Check by hand before formatting.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !report.emptyDestinations.isEmpty {
                Label("Nothing recognisable in: "
                      + report.emptyDestinations.map(\.lastPathComponent).joined(separator: ", "),
                      systemImage: "questionmark.folder")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !report.weak.isEmpty {
                Label("\(report.weak.count) matched on filename rather than the camera's ID, "
                      + "because the copy has no XML sidecar. That's reliable only while those "
                      + "files keep their original names.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func problemList(_ title: String,
                             _ items: [Verifier.ClipResult],
                             detail: @escaping (Verifier.ClipResult) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.orange)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.system(.caption, design: .monospaced))
                    Text(detail(item)).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if state.isVerifying {
                ProgressView().controlSize(.small)
                Text("Scanning the folders…").font(.caption).foregroundStyle(.secondary)
            } else if let blocker {
                Text(blocker).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Check") { state.runVerify() }
                .keyboardShortcut(.defaultAction)
                .disabled(blocker != nil || state.isVerifying)
        }
        .padding(16)
    }

    private var blocker: String? {
        if state.root == nil || state.clips.isEmpty { return "Scan a card first." }
        if state.verifyDestinations.isEmpty { return "Add at least one folder to check against." }
        return nil
    }

    // MARK: Layout

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
