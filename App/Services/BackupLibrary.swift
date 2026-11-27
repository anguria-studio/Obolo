import Foundation
import OboloCore

/// A backup Obolo can offer to restore: where it is, when it was written, and how many
/// subscriptions it holds.
struct BackupEntry: Identifiable, Hashable {
    let url: URL
    let date: Date
    /// `nil` when the file could not be read as a document.
    let subscriptionCount: Int?
    /// Picked with the open panel rather than one Obolo keeps: it is named by its file.
    var isChosenFile = false

    var id: URL { url }

    /// "Today, 09:12", "Yesterday, 18:40", "22 Nov 2026".
    func when(now: Date, calendar: Calendar) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// The confirmation's question: "Restore the backup from yesterday at 18:40?", or
    /// "Restore “Obolo 2026-11-20.json”?" for a file picked by hand.
    func question(now: Date, calendar: Calendar) -> String {
        if isChosenFile { return "Restore “\(url.lastPathComponent)”?" }
        let phrase = when(now: now, calendar: calendar)
            .replacingOccurrences(of: "Today, ", with: "today at ")
            .replacingOccurrences(of: "Yesterday, ", with: "yesterday at ")
        return "Restore the backup from \(phrase)?"
    }

    var countText: String? {
        subscriptionCount.map { "\($0) subscription\($0 == 1 ? "" : "s")" }
    }
}

/// The backups Obolo keeps by itself, for the restore list: the copies it writes beside
/// the store before iCloud first replaces anything ("iCloud Backups"). Backups saved with
/// Back up live wherever the user put them, so the list also offers "Choose a file".
enum BackupLibrary {
    /// Newest first.
    static func entries(besideStoreAt storeURL: URL, fileManager: FileManager = .default) -> [BackupEntry] {
        let directory = storeURL.deletingLastPathComponent()
            .appending(path: AppPaths.cloudSyncBackupsDirectoryName, directoryHint: .isDirectory)
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { entry(for: $0) }
            .sorted { $0.date > $1.date }
    }

    /// One file, read for its date and its count.
    static func entry(for url: URL, isChosenFile: Bool = false) -> BackupEntry {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let count = (try? Data(contentsOf: url))
            .flatMap { try? DocumentStore.makeDecoder().decode(StoreDocument.self, from: $0) }?
            .subscriptions.count
        return BackupEntry(url: url, date: date, subscriptionCount: count, isChosenFile: isChosenFile)
    }
}
