import AppKit

// The rolling backups of library.json: listing, restoring and revealing them.

extension AppState {

    func refreshBackups() {
        libraryBackups = library.backups()
    }

    private static let backupLabelFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func backupLabel(_ backup: TagLibrary.Backup) -> String {
        "\(backupLabelFormat.string(from: backup.date))  ·  \(FileUtil.sizeText(backup.size))"
    }

    /// Asks first, because it replaces every tag in one go, and then says what it did.
    func restoreLibrary(from backup: TagLibrary.Backup) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore the tag library from "
            + "\(Self.backupLabelFormat.string(from: backup.date))?"
        alert.informativeText = "Every team, player, tag, category and preset goes back to how "
            + "it was then, and anything added since is gone from the library.\n\nThe version "
            + "you have now is backed up first, so this can be undone the same way. Nothing on "
            + "your cards or drives is touched either way."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let summary = try library.restore(from: backup.url)
            addLog("Restored the tag library from \(backup.url.lastPathComponent)")
            status = summary
            // The filters point at teams and players by value, and the restored roster
            // may not have them.
            dropDanglingFilters()
            selection = []
            refreshBackups()      // restoring takes a backup of its own first
        } catch {
            addLog("Restore failed: \(error.localizedDescription)")
            status = error.localizedDescription
        }
    }

    func revealBackups() {
        NSWorkspace.shared.activateFileViewerSelecting([TagLibrary.backupFolder])
    }
}
