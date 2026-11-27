import Foundation
import OboloCore

/// The note that Obolo writes after it moves an unreadable store file.
///
/// The app reads this file at the next launch (`AppModel.pendingRecovery`), and so does
/// its Shortcuts action. Both show the recovery state until the user restores a backup
/// or continues with an empty document.
struct RecoverySidecar: Codable, Equatable {
    var movedTo: URL
    var error: String
    var at: Date

    /// Returns the sidecar URL for the specified store URL.
    static func url(besideStoreAt storeURL: URL) -> URL {
        let base = storeURL.deletingPathExtension().lastPathComponent
        return storeURL
            .deletingLastPathComponent()
            .appending(path: "\(base).recovery.json", directoryHint: .notDirectory)
    }

    /// Returns the recovery note, or `nil` when no valid note exists.
    static func read(besideStoreAt storeURL: URL) -> RecoverySidecar? {
        let url = Self.url(besideStoreAt: storeURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? DocumentStore.makeDecoder().decode(RecoverySidecar.self, from: data)
    }

    /// Writes the recovery note before the app moves the unreadable store file.
    func write(besideStoreAt storeURL: URL) throws {
        let url = Self.url(besideStoreAt: storeURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try DocumentStore.makeEncoder().encode(self)
        try data.write(to: url, options: [.atomic])
    }

    /// Deletes the recovery note. This function ignores a missing note.
    static func delete(besideStoreAt storeURL: URL) {
        try? FileManager.default.removeItem(at: Self.url(besideStoreAt: storeURL))
    }
}
