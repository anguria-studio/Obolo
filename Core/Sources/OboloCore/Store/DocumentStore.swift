import Foundation

/// Reading and writing the one file this app owns.
///
/// An `actor` because the app saves on a 250 ms debounce, on `willTerminate`, and from
/// the import coordinator — three call sites that must not interleave a half-written
/// file. Every write is atomic (`Data.write(options: .atomic)` stages a temporary file
/// and renames it), so a crash mid-save leaves the previous document intact rather than
/// a truncated one.
///
/// JSON, pretty-printed with sorted keys and ISO-8601 dates: the store is a file the
/// user can open, read, diff and put in a backup, which is worth more than the bytes a
/// binary format would save.
public actor DocumentStore {

    /// Exposed outside the actor so the Data pane can print the path without awaiting.
    public nonisolated let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static let directoryName = "Obolo"
    public static let fileName = "obolo.json"

    // MARK: - Load and save

    /// A missing file is a new user: `StoreDocument.initial()`, not an error.
    ///
    /// A *corrupt* file is a different matter and does throw — silently replacing
    /// someone's subscription list with an empty one because a byte flipped would be the
    /// worst failure this app could have. The Data pane's Restore is the recovery path.
    public func load() throws -> StoreDocument {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return StoreDocument.initial()
        }
        return try DocumentStore.decode(try Data(contentsOf: url))
    }

    public func save(_ document: StoreDocument) throws {
        try DocumentStore.write(document, to: url)
    }

    /// Copies the current document to `url` — used by "Back up", which writes wherever
    /// the save panel points, outside the container.
    public func backup(to destination: URL) throws {
        try DocumentStore.write(try load(), to: destination, replacingUnreadableFile: true)
    }

    /// Reads a backup, installs it as the live document and returns it. Validating by
    /// decoding first means a bad file is rejected before the good one is overwritten.
    @discardableResult
    public func restore(from source: URL) throws -> StoreDocument {
        let document = try DocumentStore.decode(try Data(contentsOf: source))
        try DocumentStore.write(document, to: url, replacingUnreadableFile: true)
        return document
    }

    // MARK: - Coding

    /// Timestamps use ISO 8601. BillingDay encodes its own Gregorian calendar date.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A date as this store keeps it. The ISO-8601 format above has no fraction of a
    /// second, so a write drops it, rounding down. Sync compares records at this
    /// precision (`SyncedDocument(document:)`, `SyncMerge`): a value read back from the
    /// file after a relaunch is then the value that was sent, not a new edit.
    public static func storedDate(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    public static func encode(_ document: StoreDocument) throws -> Data {
        try makeEncoder().encode(document)
    }

    public static func decode(_ data: Data) throws -> StoreDocument {
        try makeDecoder().decode(StoreDocument.self, from: data)
    }

    private static func write(_ document: StoreDocument, to url: URL, replacingUnreadableFile: Bool = false) throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            // The destination may have been replaced since launch, including by another app version.
            let existing = try Data(contentsOf: url, options: .mappedIfSafe)
            do {
                _ = try makeDecoder().decode(StoreDocument.Header.self, from: existing)
            } catch is DecodingError where replacingUnreadableFile {
                // An explicit backup or restore may replace a damaged file.
            }
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(document).write(to: url, options: [.atomic])
    }
}
