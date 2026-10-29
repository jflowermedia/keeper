import AppKit

// Checking a card reached its destinations.

extension AppState {

    /// Opens Check Copied, with the folder a copy just went to already in the list.
    func openVerify() {
        if let folder = verifySuggestion, !verifyDestinations.contains(folder),
           !(root.map { overlaps(folder, $0) } ?? false) {
            verifyDestinations.append(folder)
        }
        verifySuggestion = nil
        showVerifySheet = true
    }

    func addVerifyDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Where did you copy this card's footage?"
        guard panel.runModal() == .OK else { return }

        var refused: [String] = []
        for url in panel.urls where !verifyDestinations.contains(url) {
            // The card can't vouch for itself. Comparing a folder against itself, or against
            // anything containing it, matches every clip and reports the card safe to format
            // — the exact outcome this feature exists to prevent.
            if let root, overlaps(url, root) {
                refused.append(url.lastPathComponent)
                continue
            }
            verifyDestinations.append(url)
        }

        if !refused.isEmpty {
            status = "\(refused.joined(separator: ", ")): that's the footage you scanned, not a "
                + "copy of it. Add the folder you copied it to."
        }
        verifyReport = nil
    }

    /// True when either folder is the other, or sits inside it.
    private func overlaps(_ a: URL, _ b: URL) -> Bool {
        let one = FileUtil.folderPath(a), two = FileUtil.folderPath(b)
        return one.hasPrefix(two) || two.hasPrefix(one)
    }

    func runVerify() {
        guard !isVerifying, !isScanning, !clips.isEmpty, !verifyDestinations.isEmpty else { return }
        if let root, let clash = verifyDestinations.first(where: { overlaps($0, root) }) {
            status = "\(clash.lastPathComponent) is the footage you scanned, not a copy of it. "
                + "Remove it before checking."
            return
        }
        isVerifying = true
        verifyReport = nil
        status = "Checking \(clips.count) clips against \(verifyDestinations.count) folder(s)…"
        let source = clips
        let destinations = verifyDestinations
        let word = keepWord
        Task.detached(priority: .userInitiated) {
            let report = Verifier.verify(source: source, destinations: destinations, keepWord: word)
            await MainActor.run {
                self.verifyReport = report
                self.isVerifying = false
                self.status = report.summary
                self.addLog("Verify: " + report.summary)
                self.appendLog(report.log)
                for result in report.missing {
                    self.addLog("✗ \(result.name) is not in any of those folders")
                }
                for result in report.wrongSize {
                    if case .wrongSize(let found) = result.outcome {
                        self.addLog("✗ \(result.name): \(FileUtil.sizeText(found)) there, "
                                    + "\(FileUtil.sizeText(result.sourceSize)) on the card")
                    }
                }
            }
        }
    }
}
