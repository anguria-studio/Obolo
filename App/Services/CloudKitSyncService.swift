import CloudKit
import CryptoKit
import Foundation
import OboloCore
import OSLog

private enum CloudSyncCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // The shared document format writes whole ISO-8601 seconds. Cloud sync must
        // keep the exact Date value, or the next comparison can report a false edit.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

/// Durable state that belongs to one CloudKit session on one Mac.
///
/// Synthesised `Codable`: every revision of this type that the app has used writes
/// every non-optional key, so no stored file lacks one. A key added later is optional,
/// so a file written before it still loads.
struct CloudSyncStateFile: Codable, Sendable {
    var version: Int = currentVersion
    var engineState: CKSyncEngine.State.Serialization?
    var baseDocument: SyncedDocument
    var pendingRemoteDocument: SyncedDocument?
    /// Fetched identities include payloads that compare equal but have new system fields or assets.
    var pendingRemoteRecordIDs: Set<SyncRecordID>?
    var pendingChanges: [SyncChange] = []
    var recordSystemFields: [String: Data] = [:]
    var pendingRemoteAssets: [String: Data] = [:]
    var localIconFingerprints: [String: String] = [:]
    var conflicts: [SyncConflict] = []
    var zoneCreated = false
    var accountRecordName: String?
    var accountNeedsApproval = false
    var initialMergeCompleted = false
    /// True after the first fetch finished (`didFetchChanges`), also when its merge was
    /// refused. A replay that applies later can then complete the first merge. Nil in a
    /// file written before this key, and before the first fetch finishes.
    var initialFetchCompleted: Bool?
    var lastSuccessfulSyncAt: Date?

    static let currentVersion = 2

    init(baseDocument: SyncedDocument) {
        self.baseDocument = baseDocument
    }

    mutating func enqueue(_ changeSet: SyncChangeSet) {
        var latest: [SyncRecordID: SyncChange] = [:]
        for change in pendingChanges {
            latest[change.recordID] = change
        }
        for change in changeSet.changes {
            latest[change.recordID] = change
        }
        pendingChanges = latest.keys.sorted().compactMap { latest[$0] }
    }

    mutating func removePendingChange(
        for id: SyncRecordID,
        when expected: SyncChange
    ) {
        guard pendingChanges.first(where: { $0.recordID == id }) == expected else { return }
        pendingChanges.removeAll { $0.recordID == id }
    }

    func pendingChange(for id: SyncRecordID) -> SyncChange? {
        pendingChanges.first { $0.recordID == id }
    }

    @discardableResult
    mutating func enqueueSavedLocalChanges(
        from previous: SyncedDocument,
        to document: SyncedDocument,
        iconFingerprints: [String: String]
    ) -> Bool {
        let changeSet = SyncChangeSet(changes:
            SyncChangeSet(from: previous, to: document).changes
                + iconChanges(in: document, iconFingerprints: iconFingerprints)
        )
        guard !changeSet.changes.isEmpty else { return false }

        localIconFingerprints = iconFingerprints
        let values = document.recordMap
        let conflictIDs = Set(conflicts.map(\.recordID))
        for index in conflicts.indices {
            conflicts[index].local = values[conflicts[index].recordID]
        }
        enqueue(SyncChangeSet(changes: changeSet.changes.filter {
            !conflictIDs.contains($0.recordID)
        }))
        return true
    }

    /// Saves of the records in `document` whose icon file is not the one that
    /// `localIconFingerprints` records. `iconFingerprints` are the files now on disk.
    func iconChanges(
        in document: SyncedDocument,
        iconFingerprints: [String: String]
    ) -> [SyncChange] {
        let recordsByID = document.recordMap
        var changes: [SyncChange] = []
        for (name, fingerprint) in iconFingerprints
        where localIconFingerprints[name] != fingerprint {
            let recordID = CKRecord.ID(recordName: name, zoneID: CloudKitRecordCodec.zoneID)
            guard let id = CloudKitRecordCodec.syncRecordID(for: recordID),
                  let record = recordsByID[id] else { continue }
            changes.append(.save(record))
        }
        return changes
    }

    /// Queues the local changes that this state does not hold, and returns them.
    ///
    /// The state expects the local document to be `baseDocument` with `pendingChanges`
    /// applied. A change that this Mac saved but did not queue (the queue write failed,
    /// or sync was off) is the difference. A session start calls this, because the
    /// session's first local document is otherwise only the start point for later
    /// saves. A record that is already pending with the same value is not a difference,
    /// so nothing is queued twice, and an unchanged record is not sent again.
    ///
    /// Nothing is queued:
    /// - before the first merge, which compares the whole local document itself;
    /// - while the account waits for approval: nothing is sent before approval;
    /// - while a refused remote batch waits: `baseDocument` does not have it yet, and
    ///   its merge queues the local changes when it applies. A value queued now could
    ///   replace a remote change that conflicts with it.
    /// A record with an open conflict is left out: the user's choice decides it.
    @discardableResult
    mutating func enqueueUnqueuedLocalChanges(
        in localDocument: SyncedDocument,
        iconFingerprints: [String: String]
    ) -> SyncChangeSet {
        guard initialMergeCompleted,
              !accountNeedsApproval,
              !hasUnappliedRemoteChanges else { return SyncChangeSet(changes: []) }
        let expected = baseDocument.applying(SyncChangeSet(changes: pendingChanges))
        let conflictIDs = Set(conflicts.map(\.recordID))
        let changes = (
            SyncChangeSet(from: expected, to: localDocument).changes
                + iconChanges(in: localDocument, iconFingerprints: iconFingerprints)
        ).filter { !conflictIDs.contains($0.recordID) }
        let changeSet = SyncChangeSet(changes: changes)
        localIconFingerprints = iconFingerprints
        enqueue(changeSet)
        return changeSet
    }

    var canSendRecords: Bool {
        initialMergeCompleted && zoneCreated && !accountNeedsApproval && !hasUnappliedRemoteChanges
    }

    var changesToSend: [SyncChange] {
        guard canSendRecords else { return [] }
        let conflictIDs = Set(conflicts.map(\.recordID))
        return pendingChanges.filter { !conflictIDs.contains($0.recordID) }
    }

    mutating func stageRemoteChanges(_ changeSet: SyncChangeSet) {
        pendingRemoteRecordIDs = (pendingRemoteRecordIDs ?? []).union(changeSet.changes.map(\.recordID))
        pendingRemoteDocument = (pendingRemoteDocument ?? baseDocument).applying(changeSet)
    }

    /// Fetched identities also cover a replacement CKAsset whose filename and record
    /// payload are unchanged. A document diff alone cannot describe that fetch.
    var fetchedSubscriptionChanges: [SyncChange] {
        guard let remote = pendingRemoteDocument else { return [] }
        let records = remote.recordMap
        return (pendingRemoteRecordIDs ?? []).sorted().compactMap { id in
            guard case .subscription = id else { return nil }
            return records[id].map(SyncChange.save) ?? .delete(id)
        }
    }

    /// An acknowledgement can arrive for a batch that had already been handed to CloudKit.
    /// Keep overlapping fetched records for the merge, and advance both snapshots for other IDs.
    mutating func acknowledgeSentChange(
        _ change: SyncChange,
        systemFields: Data?,
        sentIconFingerprint: String? = nil
    ) {
        if pendingRemoteRecordIDs?.contains(change.recordID) == true { return }
        let changeSet = SyncChangeSet(changes: [change])
        baseDocument = baseDocument.applying(changeSet)
        pendingRemoteDocument = pendingRemoteDocument?.applying(changeSet)
        let name = CloudKitRecordCodec.recordID(for: change.recordID).recordName
        recordSystemFields[name] = systemFields
        if let sentIconFingerprint, localIconFingerprints[name] != sentIconFingerprint { return }
        removePendingChange(for: change.recordID, when: change)
    }

    /// The merge decides which payloads still need sending. The queue also carries icon
    /// changes that can have the same payload as the base and so are absent from the diff.
    mutating func finishRemoteMerge(
        with result: SyncMergeResult,
        localDocument: SyncedDocument,
        iconFingerprints: [String: String]
    ) {
        guard let remote = pendingRemoteDocument else { return }
        let localRecords = localDocument.recordMap
        let remoteRecords = remote.recordMap
        var conflictsByID: [SyncRecordID: SyncConflict] = [:]
        for var conflict in conflicts + result.conflicts {
            let id = conflict.recordID
            guard localRecords[id] != remoteRecords[id] else { continue }
            conflict.local = localRecords[id]
            conflict.remote = remoteRecords[id]
            conflictsByID[id] = conflict
        }
        conflicts = conflictsByID.values.sorted { $0.recordID < $1.recordID }

        let fetchedIDs = pendingRemoteRecordIDs ?? []
        let iconSaves = (pendingChanges + iconChanges(in: localDocument, iconFingerprints: iconFingerprints))
            .filter { change in
                guard !fetchedIDs.contains(change.recordID),
                      case .save(.subscription(let value)) = change,
                      value.icon.imageFilename != nil else { return false }
                return localRecords[change.recordID] == .subscription(value)
            }
        let payloadChanges = SyncChangeSet(from: remote, to: localDocument).changes
        pendingChanges = SyncChangeSet(changes: (iconSaves + payloadChanges).filter {
            conflictsByID[$0.recordID] == nil
        }).changes
        baseDocument = remote
        pendingRemoteDocument = nil
        pendingRemoteRecordIDs = nil
        let conflictNames = Set(conflicts.map {
            CloudKitRecordCodec.recordID(for: $0.recordID).recordName
        })
        pendingRemoteAssets = pendingRemoteAssets.filter { conflictNames.contains($0.key) }
        localIconFingerprints = iconFingerprints
    }

    /// A fetched remote batch that the app has not applied yet.
    ///
    /// `pendingRemoteDocument` stays set when `AppModel` refuses a batch (a newer schema,
    /// or a save that failed), and the next start or fetch tries it again. After a failed
    /// save, `AppModel` also asks for one replay when a later local save succeeds
    /// (`CloudSyncService.replayRemoteChanges`). Until then
    /// this Mac does not have the iCloud data, so no sync counts as a success.
    var hasUnappliedRemoteChanges: Bool { pendingRemoteDocument != nil }

    /// Stamps `lastSuccessfulSyncAt` after a fetch, a send, or a replay that applied,
    /// unless a remote batch is still waiting to apply. Returns whether it stamped.
    mutating func recordSuccessfulSync(at date: Date) -> Bool {
        guard !hasUnappliedRemoteChanges else { return false }
        lastSuccessfulSyncAt = date
        return true
    }

    /// Whether a kept batch that applies outside a fetch (a replay) completes the first
    /// merge, as `didFetchChanges` does. Only after the first fetch finished: a batch
    /// replayed while that fetch still runs is part of it, and the first merge waits for
    /// all of the iCloud records.
    var replayCompletesInitialMerge: Bool {
        initialFetchCompleted == true && !initialMergeCompleted && !accountNeedsApproval
    }

    /// The phase that this state supports when nothing has failed.
    var phase: CloudSyncPhase {
        if accountNeedsApproval { return .paused }
        if !initialMergeCompleted || hasUnappliedRemoteChanges { return .syncing }
        return pendingChanges.isEmpty ? .current : .syncing
    }
}

/// Atomic storage for the engine token, record change tags, and unsent work.
struct CloudSyncStateStore: Sendable {
    enum StoreError: LocalizedError, Equatable {
        /// A newer Obolo wrote the file. It stays in place, so that version can use it.
        case unsupportedVersion(found: Int, supported: Int)
        /// The file was read, but its contents do not decode. A read error from the
        /// file system is not this case: it can be temporary.
        case unreadable(reason: String)

        /// The Data pane shows this text after "Obolo cannot start iCloud sync."
        /// (`CloudKitSyncService.startFailureMessage`). The versions and the decoder's
        /// reason go to the log, not to the user.
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                "A newer version of Obolo wrote the iCloud sync state on this Mac. Update Obolo to continue. Your data on this Mac is unchanged."
            case .unreadable:
                "Obolo cannot read the iCloud sync state on this Mac. Your data on this Mac is unchanged."
            }
        }
    }

    /// What `loadForStart` found.
    enum StartingState: Sendable {
        /// The file loaded.
        case loaded(CloudSyncStateFile)
        /// There was no file. Sync starts with the fresh state, as on a first enable.
        case fresh(CloudSyncStateFile)
        /// The file did not decode. It is now at `movedTo`, and a fresh state that
        /// waits for the user's approval is saved in its place.
        case replacedUnreadable(CloudSyncStateFile, movedTo: URL)
    }

    nonisolated let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() throws -> CloudSyncStateFile? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = CloudSyncCoding.makeDecoder()
        // The version first: a file from a newer adapter is not damaged, and a newer
        // Obolo can still use it.
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw StoreError.unreadable(reason: error.localizedDescription)
        }
        guard version <= CloudSyncStateFile.currentVersion else {
            throw StoreError.unsupportedVersion(
                found: version,
                supported: CloudSyncStateFile.currentVersion
            )
        }
        do {
            return try decoder.decode(CloudSyncStateFile.self, from: data)
        } catch {
            throw StoreError.unreadable(reason: error.localizedDescription)
        }
    }

    /// Loads the state for a new session.
    ///
    /// A file that does not decode is moved aside, never deleted, and `fresh` with
    /// `accountNeedsApproval` set is saved in its place. So sync waits for the user's
    /// continue action, on this launch and on each later one, and that action makes a
    /// backup before the first sync. Other errors (a file-system read error, a file
    /// from a newer adapter) are thrown, and the file stays where it is.
    func loadForStart(
        orFresh fresh: CloudSyncStateFile,
        now: Date
    ) throws -> StartingState {
        do {
            guard let state = try load() else { return .fresh(fresh) }
            return .loaded(state)
        } catch StoreError.unreadable {
            var paused = fresh
            paused.accountNeedsApproval = true
            let movedTo = try replaceUnreadableFile(with: paused, now: now)
            return .replacedUnreadable(paused, movedTo: movedTo)
        }
    }

    func save(_ state: CloudSyncStateFile) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try CloudSyncCoding.makeEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Moves the file to `cloud-sync.json.corrupt-<yyyyMMdd-HHmmss>` beside itself, then
    /// saves `replacement` at the file's own path. Returns where the file went.
    ///
    /// The move never replaces a file: an existing quarantine name gets a `-2`, `-3`
    /// suffix. If the replacement cannot be saved, the file is moved back. Without a
    /// replacement, the next start would find no file and begin a first sync that the
    /// user did not start.
    private func replaceUnreadableFile(
        with replacement: CloudSyncStateFile,
        now: Date
    ) throws -> URL {
        let manager = FileManager.default
        // A fixed pattern, in a fixed locale, as for the store quarantine in `AppModel`.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)

        let folder = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        var destination = folder.appending(
            path: "\(base).corrupt-\(stamp)",
            directoryHint: .notDirectory
        )
        var attempt = 2
        while manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = folder.appending(
                path: "\(base).corrupt-\(stamp)-\(attempt)",
                directoryHint: .notDirectory
            )
            attempt += 1
        }

        try manager.moveItem(at: url, to: destination)
        do {
            try save(replacement)
        } catch {
            try? manager.moveItem(at: destination, to: url)
            throw error
        }
        return destination
    }
}

enum CloudKitRecordCodec {
    struct DecodedRecord: Sendable {
        let record: SyncRecord
        let iconData: Data?
    }

    enum CodecError: LocalizedError {
        case invalidRecordName
        case recordTypeMismatch
        case missingPayload
        case recordIdentityMismatch
        case invalidSystemFields

        /// A sent record that does not decode reaches the Data pane after "Obolo cannot
        /// finish iCloud sync." Each case means the same thing to the user.
        var errorDescription: String? {
            "Obolo cannot read a record from iCloud."
        }
    }

    static let zoneName = "OboloData"
    static let payloadKey = "payload"
    static let iconAssetKey = "iconAsset"
    static let maximumIconBytes = 8 * 1_024 * 1_024
    static let zoneID = CKRecordZone.ID(zoneName: zoneName)

    static func recordID(for id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.sortKey, zoneID: zoneID)
    }

    static func syncRecordID(for recordID: CKRecord.ID) -> SyncRecordID? {
        guard recordID.zoneID == zoneID else { return nil }
        let name = recordID.recordName
        if name == "preferences" { return .preferences }
        if name.hasPrefix("subscription:"),
           let id = UUID(uuidString: String(name.dropFirst("subscription:".count))) {
            return .subscription(id)
        }
        if name.hasPrefix("category:"),
           let id = UUID(uuidString: String(name.dropFirst("category:".count))) {
            return .category(id)
        }
        if name.hasPrefix("manual-rate:") {
            let currency = Subscription.normalizedCurrency(
                String(name.dropFirst("manual-rate:".count))
            )
            guard currency.count == 3, currency.allSatisfy({ $0.isLetter }) else { return nil }
            return .manualRate(currency)
        }
        return nil
    }

    static func makeRecord(
        for value: SyncRecord,
        systemFields: Data?,
        iconsDirectory: URL
    ) throws -> CKRecord {
        let id = recordID(for: value.id)
        let cloudRecord: CKRecord
        if let systemFields {
            let decoded = try record(fromSystemFields: systemFields)
            guard decoded.recordID == id else { throw CodecError.invalidSystemFields }
            cloudRecord = decoded
        } else {
            cloudRecord = CKRecord(recordType: recordType(for: value), recordID: id)
        }
        guard cloudRecord.recordType == recordType(for: value) else {
            throw CodecError.recordTypeMismatch
        }

        cloudRecord[payloadKey] = try CloudSyncCoding.makeEncoder().encode(value)
        cloudRecord[iconAssetKey] = nil
        if case .subscription(let subscription) = value,
           let url = iconAssetURL(for: subscription, in: iconsDirectory) {
            cloudRecord[iconAssetKey] = CKAsset(fileURL: url)
        }
        return cloudRecord
    }

    static func decode(_ record: CKRecord) throws -> DecodedRecord {
        guard let id = syncRecordID(for: record.recordID) else {
            throw CodecError.invalidRecordName
        }
        guard let data = record[payloadKey] as? Data else {
            throw CodecError.missingPayload
        }
        let value = try CloudSyncCoding.makeDecoder().decode(SyncRecord.self, from: data)
        guard value.id == id else { throw CodecError.recordIdentityMismatch }
        guard record.recordType == recordType(for: value) else {
            throw CodecError.recordTypeMismatch
        }

        var iconData: Data?
        if case .subscription(let subscription) = value,
           safeImageFilename(for: subscription) != nil,
           let asset = record[iconAssetKey] as? CKAsset,
           let fileURL = asset.fileURL,
           isSafeAssetFile(fileURL) {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            if data.starts(with: pngSignature) {
                iconData = data
            }
        }
        return DecodedRecord(record: value, iconData: iconData)
    }

    static func systemFields(for record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func containedIconURL(filename: String, in directory: URL) -> URL? {
        guard Icon.isValidImageFilename(filename) else { return nil }
        let candidate = directory
            .appending(path: filename, directoryHint: .notDirectory)
            .standardizedFileURL
        var folder = directory.standardizedFileURL.path(percentEncoded: false)
        if !folder.hasSuffix("/") { folder += "/" }
        guard candidate.path(percentEncoded: false).hasPrefix(folder) else { return nil }
        return candidate
    }

    static func iconAssetURL(
        for subscription: SyncedSubscription,
        in directory: URL
    ) -> URL? {
        guard let filename = safeImageFilename(for: subscription),
              let url = containedIconURL(filename: filename, in: directory),
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path(percentEncoded: false)
              ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumIconBytes else { return nil }
        return url
    }

    static func iconFingerprint(
        for subscription: SyncedSubscription,
        in directory: URL
    ) -> String? {
        guard subscription.icon.imageFilename != nil else { return nil }
        guard let url = iconAssetURL(for: subscription, in: directory),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return "missing"
        }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    private static func isSafeAssetFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue <= maximumIconBytes
    }

    private static func safeImageFilename(for subscription: SyncedSubscription) -> String? {
        guard let filename = subscription.icon.imageFilename,
              Icon.isValidImageFilename(filename),
              let fileID = UUID(uuidString: String(filename.dropLast(4))),
              fileID == subscription.id else { return nil }
        return filename
    }

    private static func recordType(for record: SyncRecord) -> CKRecord.RecordType {
        switch record {
        case .subscription: "OBSubscription"
        case .category: "OBCategory"
        case .preferences: "OBPreferences"
        case .manualRate: "OBManualRate"
        }
    }

    private static func record(fromSystemFields data: Data) throws -> CKRecord {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver) else {
            throw CodecError.invalidSystemFields
        }
        return record
    }
}

/// Syncs the private Obolo zone after the user enables iCloud sync.
actor CloudKitSyncService: CloudSyncService, CKSyncEngineDelegate {
    static let containerIdentifier = "iCloud.studio.anguria.obolo"

    private static let log = Logger(
        subsystem: "studio.anguria.obolo",
        category: "CloudSync"
    )

    private let container: CKContainer
    private let stateStore: CloudSyncStateStore
    private let iconsDirectory: URL
    private let automaticallySync: Bool
    private let clock: @Sendable () -> Date
    private var syncEngine: CKSyncEngine?
    private var state: CloudSyncStateFile?
    private var latestLocalSnapshot: CloudSyncLocalSnapshot?
    private var receiveRemoteChanges: CloudSyncRemoteChangeHandler?
    private var reportStatus: CloudSyncStatusHandler?
    private var remoteReplayTask: Task<Bool, any Error>?
    private var sentIconFingerprints: [String: String] = [:]
    private var isRunning = false

    init(
        stateStore: CloudSyncStateStore,
        iconsDirectory: URL,
        container: CKContainer = CKContainer(identifier: containerIdentifier),
        automaticallySync: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stateStore = stateStore
        self.iconsDirectory = iconsDirectory
        self.container = container
        self.automaticallySync = automaticallySync
        self.clock = clock
    }

    func start(
        localDocument: SyncedDocument,
        receiveRemoteChanges: @escaping CloudSyncRemoteChangeHandler,
        reportStatus: @escaping CloudSyncStatusHandler
    ) async {
        guard syncEngine == nil else { return }
        isRunning = true
        self.receiveRemoteChanges = receiveRemoteChanges
        self.reportStatus = reportStatus
        latestLocalSnapshot = CloudSyncLocalSnapshot(document: localDocument)
        await reportStatus(CloudSyncSnapshot(phase: .preparing))

        do {
            guard try await accountIsAvailable() else { return }
            let fresh = CloudSyncStateFile(baseDocument: emptyDocument(using: localDocument))
            switch try stateStore.loadForStart(orFresh: fresh, now: clock()) {
            case .loaded(let loaded):
                state = loaded
            case .fresh(let fresh):
                state = fresh
            case .replacedUnreadable(let paused, let movedTo):
                // The continue action (`approveCurrentAccount`) starts the first sync
                // after `AppModel` makes a backup. The saved state keeps sync paused on
                // later launches too.
                state = paused
                Self.log.error(
                    "Cloud sync moved an unreadable state file to \(movedTo.lastPathComponent, privacy: .public)"
                )
                await publishStatus(
                    phase: .paused,
                    message: "Obolo cannot read the iCloud sync state on this Mac. Your data on this Mac is unchanged."
                )
                return
            }
            if try await replayRemoteChangesIfNeeded() {
                try await finishAppliedReplay()
            }
            // A local change that a failed queue write, or a session with sync off, did
            // not queue is otherwise never sent: this session compares later saves with
            // `localDocument`, which already has the change.
            if var current = state, let local = latestLocalSnapshot?.document {
                current.enqueueUnqueuedLocalChanges(
                    in: local,
                    iconFingerprints: iconFingerprints(in: local)
                )
                state = current
            }
            if let state { try persist(state) }
            guard state?.accountNeedsApproval != true else {
                await publishStatus(
                    phase: .paused,
                    message: "Select a first-sync action before Obolo uses this iCloud account."
                )
                return
            }
            initializeEngine()
            refreshEnginePendingChanges()
            await publishStatus(phase: .syncing)
        } catch {
            Self.log.error("Cloud sync cannot start: \(String(describing: error), privacy: .public)")
            await publishStatus(
                phase: .failed,
                message: Self.startFailureMessage(for: error)
            )
        }
    }

    /// The Data pane's line for a start that failed.
    ///
    /// The errors on this path are a `CloudSyncStateStore.StoreError` (its own sentence;
    /// a file from a newer Obolo stays in place), a file-system error from Foundation, or
    /// a CloudKit error from the account check. The last two carry the system's
    /// localized sentence.
    static func startFailureMessage(for error: any Error) -> String {
        "Obolo cannot start iCloud sync. \(error.localizedDescription)"
    }

    func stop() async {
        isRunning = false
        remoteReplayTask?.cancel()
        if let syncEngine { await syncEngine.cancelOperations() }
        _ = try? await remoteReplayTask?.value
        syncEngine = nil
        sentIconFingerprints.removeAll()
        receiveRemoteChanges = nil
        latestLocalSnapshot = nil
        await reportStatus?(.disabled)
        reportStatus = nil
    }

    func localDocumentDidSave(_ snapshot: CloudSyncLocalSnapshot) async {
        guard isRunning, var state, let previous = latestLocalSnapshot,
              snapshot.remoteRevision >= previous.remoteRevision else { return }
        let document = snapshot.document
        guard state.enqueueSavedLocalChanges(
            from: previous.document,
            to: document,
            iconFingerprints: iconFingerprints(in: document)
        ) else {
            latestLocalSnapshot = snapshot
            return
        }

        do {
            try persist(state)
            self.state = state
            latestLocalSnapshot = snapshot
            if state.canSendRecords { refreshEnginePendingChanges() }
            await publishStatus(phase: .syncing)
        } catch {
            if state.hasUnappliedRemoteChanges { latestLocalSnapshot = snapshot }
            Self.log.error("Cloud sync cannot queue a local change: \(error.localizedDescription, privacy: .public)")
            await publishStatus(
                phase: .failed,
                message: "Obolo cannot queue the iCloud changes. \(error.localizedDescription)"
            )
        }
    }

    func resolveConflict(
        _ recordID: SyncRecordID,
        choice: SyncConflictChoice
    ) async {
        await waitForRemoteReplay()
        guard isRunning,
              var state,
              !state.accountNeedsApproval,
              let conflict = state.conflicts.first(where: { $0.recordID == recordID })
        else { return }

        switch choice {
        case .local:
            let change = conflict.resolution(.local)
            state.conflicts.removeAll { $0.recordID == recordID }
            state.pendingRemoteAssets.removeValue(
                forKey: CloudKitRecordCodec.recordID(for: recordID).recordName
            )
            state.enqueue(SyncChangeSet(changes: [change]))
            do {
                try persist(state)
                self.state = state
                if state.canSendRecords { refreshEnginePendingChanges() }
                await publishStatus(phase: .syncing)
            } catch {
                await publishStatus(
                    phase: .failed,
                    message: "Obolo cannot save the conflict choice. \(error.localizedDescription)"
                )
            }

        case .remote:
            guard let local = latestLocalSnapshot?.document,
                  let receiveRemoteChanges else { return }
            let selectedRemote = local.applying(SyncChangeSet(changes: [
                conflict.resolution(.remote)
            ]))
            guard let merge = await receiveRemoteChanges(local, selectedRemote),
                  let latestState = self.state,
                  !latestState.accountNeedsApproval
            else {
                await publishStatus(
                    phase: .failed,
                    message: "Obolo cannot apply the iCloud version."
                )
                return
            }
            let result = merge.result
            latestLocalSnapshot = latestLocalSnapshot?.afterApplying(merge)

            do {
                try await Self.installRemoteAssets(
                    from: latestState, result: result, changes: [conflict.resolution(.remote)]
                )
            } catch {
                await publishStatus(phase: .failed, message: "Obolo cannot save the iCloud logo. \(error.localizedDescription)")
                return
            }

            guard var currentState = self.state,
                  !currentState.accountNeedsApproval else { return }
            currentState.conflicts.removeAll { $0.recordID == recordID }
            currentState.pendingRemoteAssets.removeValue(
                forKey: CloudKitRecordCodec.recordID(for: recordID).recordName
            )
            currentState.conflicts.append(contentsOf: result.conflicts)
            currentState.conflicts = Array(Set(currentState.conflicts)).sorted {
                $0.recordID < $1.recordID
            }
            currentState.enqueue(result.changesForRemoteStore)
            currentState.localIconFingerprints = iconFingerprints(in: result.document)
            do {
                try persist(currentState)
                self.state = currentState
                if currentState.canSendRecords { refreshEnginePendingChanges() }
                await publishStatus(phase: currentPhase)
            } catch {
                await publishStatus(
                    phase: .failed,
                    message: "Obolo cannot save the conflict choice. \(error.localizedDescription)"
                )
            }
        }
    }

    func approveCurrentAccount(localDocument: SyncedDocument) async {
        guard isRunning else { return }
        isRunning = false
        remoteReplayTask?.cancel()
        if let syncEngine { await syncEngine.cancelOperations() }
        _ = try? await remoteReplayTask?.value
        syncEngine = nil
        sentIconFingerprints.removeAll()
        latestLocalSnapshot = CloudSyncLocalSnapshot(document: localDocument)

        var resetState = CloudSyncStateFile(
            baseDocument: emptyDocument(using: localDocument)
        )
        resetState.localIconFingerprints = iconFingerprints(in: localDocument)
        do {
            try persist(resetState)
            state = resetState
            isRunning = true
            initializeEngine()
            await publishStatus(phase: .syncing)
        } catch {
            isRunning = true
            await publishStatus(
                phase: .failed,
                message: "Obolo cannot prepare sync for this iCloud account. \(error.localizedDescription)"
            )
        }
    }

    /// Offers the kept remote batch to `AppModel` again, on the path that a start and a
    /// fetch use (`replayRemoteChangesIfNeeded`). `AppModel` calls this after a local
    /// save succeeds, when the last batch failed because the store could not save it.
    func replayRemoteChanges() async {
        guard isRunning,
              syncEngine != nil,
              let state,
              !state.accountNeedsApproval,
              state.hasUnappliedRemoteChanges else { return }
        do {
            if try await replayRemoteChangesIfNeeded() {
                try await finishAppliedReplay()
            }
            await publishStatus(phase: currentPhase)
        } catch {
            Self.log.error("Cloud sync cannot replay remote changes: \(error.localizedDescription, privacy: .public)")
            await publishStatus(
                phase: .failed,
                message: "Obolo cannot finish iCloud sync. \(error.localizedDescription)"
            )
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An AppModel-initiated replay may already be waiting for the store. Let it
        // commit before handling the next change to either of its snapshots.
        switch event {
        case .fetchedRecordZoneChanges, .fetchedDatabaseChanges, .sentRecordZoneChanges:
            await waitForRemoteReplay()
        default:
            break
        }
        guard isRunning, self.syncEngine === syncEngine else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                guard var state else { return }
                state.engineState = update.stateSerialization
                try persist(state)
                self.state = state
            case .fetchedRecordZoneChanges(let changes):
                try await handleFetchedRecordChanges(changes)
            case .fetchedDatabaseChanges(let changes):
                try await handleFetchedDatabaseChanges(changes)
            case .sentRecordZoneChanges(let changes):
                try await handleSentRecordChanges(changes, syncEngine: syncEngine)
            case .sentDatabaseChanges(let changes):
                try await handleSentDatabaseChanges(changes, syncEngine: syncEngine)
            case .accountChange(let change):
                try await handleAccountChange(change, syncEngine: syncEngine)
            case .didFetchChanges:
                guard state?.accountNeedsApproval != true else { return }
                try await completeInitialMergeIfNeeded()
                try markSyncSuccessful()
                await publishStatus(phase: currentPhase)
            case .didSendChanges:
                guard state?.accountNeedsApproval != true else { return }
                try markSyncSuccessful()
                await publishStatus(phase: currentPhase)
            case .willFetchChanges,
                 .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges,
                 .willSendChanges:
                break
            @unknown default:
                Self.log.notice("Cloud sync received an event from a newer system.")
            }
        } catch {
            Self.log.error("Cloud sync cannot handle an event: \(error.localizedDescription, privacy: .public)")
            await publishStatus(
                phase: .failed,
                message: "Obolo cannot finish iCloud sync. \(error.localizedDescription)"
            )
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard isRunning, self.syncEngine === syncEngine, let state else { return nil }
        let batch = Self.makeRecordZoneChangeBatch(
            state: state,
            pending: syncEngine.state.pendingRecordZoneChanges,
            scope: context.options.scope,
            iconsDirectory: iconsDirectory
        )
        for record in batch?.recordsToSave ?? [] {
            let name = record.recordID.recordName
            sentIconFingerprints[name] = state.localIconFingerprints[name]
        }
        return batch
    }

    static func makeRecordZoneChangeBatch(
        state: CloudSyncStateFile,
        pending: [CKSyncEngine.PendingRecordZoneChange],
        scope: CKSyncEngine.SendChangesOptions.Scope = .all,
        iconsDirectory: URL
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        let engineChanges = Set(pending.filter { scope.contains($0) })
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        for change in state.changesToSend where engineChanges.contains(change.cloudKitPendingChange) {
            let recordID = CloudKitRecordCodec.recordID(for: change.recordID)
            switch change {
            case .save(let value):
                do {
                    recordsToSave.append(try CloudKitRecordCodec.makeRecord(
                        for: value,
                        systemFields: state.recordSystemFields[recordID.recordName],
                        iconsDirectory: iconsDirectory
                    ))
                } catch {
                    Self.log.error("Cloud sync cannot encode a record: \(error.localizedDescription, privacy: .public)")
                }
            case .delete:
                recordIDsToDelete.append(recordID)
            }
            // CloudKit allows up to 250 saves and deletions in one request.
            if recordsToSave.count + recordIDsToDelete.count == 250 { break }
        }
        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete
        )
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        guard state?.accountNeedsApproval == true else { return context.options }
        var options = context.options
        options.scope = .allExcluding([CloudKitRecordCodec.zoneID])
        return options
    }

    private func initializeEngine() {
        guard let state else { return }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state.engineState,
            delegate: self
        )
        configuration.automaticallySync = automaticallySync
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        if state.initialMergeCompleted, !state.zoneCreated, !state.accountNeedsApproval {
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: CloudKitRecordCodec.zoneID))
            ])
        }
    }

    private func handleFetchedRecordChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async throws {
        guard var state, !state.accountNeedsApproval else { return }
        var changes: [SyncChange] = []

        for modification in event.modifications {
            guard modification.record.recordID.zoneID == CloudKitRecordCodec.zoneID else { continue }
            let decoded: CloudKitRecordCodec.DecodedRecord
            do {
                decoded = try CloudKitRecordCodec.decode(modification.record)
            } catch {
                Self.log.error(
                    "Cloud sync ignored an invalid record: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            changes.append(.save(decoded.record))
            let name = modification.record.recordID.recordName
            state.recordSystemFields[name] = CloudKitRecordCodec.systemFields(
                for: modification.record
            )
            if let iconData = decoded.iconData {
                state.pendingRemoteAssets[name] = iconData
            } else if case .subscription = decoded.record {
                state.pendingRemoteAssets.removeValue(forKey: name)
            }
        }

        for deletion in event.deletions {
            guard let id = CloudKitRecordCodec.syncRecordID(for: deletion.recordID) else { continue }
            changes.append(.delete(id))
            let name = deletion.recordID.recordName
            state.recordSystemFields.removeValue(forKey: name)
            state.pendingRemoteAssets.removeValue(forKey: name)
        }

        guard !changes.isEmpty else { return }
        state.stageRemoteChanges(SyncChangeSet(changes: changes))
        try keepRemoteChanges(state)
        try await replayRemoteChangesIfNeeded()
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges
    ) async throws {
        if event.modifications.contains(where: { $0.zoneID == CloudKitRecordCodec.zoneID }),
           var state,
           !state.zoneCreated,
           !state.accountNeedsApproval {
            state.zoneCreated = true
            try persist(state)
            self.state = state
            refreshEnginePendingChanges()
        }
        guard event.deletions.contains(where: { $0.zoneID == CloudKitRecordCodec.zoneID }),
              var state,
              !state.accountNeedsApproval else { return }
        state.zoneCreated = false
        state.recordSystemFields.removeAll()
        state.pendingRemoteDocument = nil
        state.pendingRemoteRecordIDs = nil
        state.pendingRemoteAssets.removeAll()
        // A deleted private zone can represent an account or recovery event. Keep
        // the local document until the user selects the next sync action.
        state.accountNeedsApproval = true
        try persist(state)
        self.state = state
        refreshEnginePendingChanges()
        await publishStatus(
            phase: .paused,
            message: "The Obolo iCloud data was removed. Your data on this Mac is unchanged."
        )
    }

    /// Completes the first three-way merge only after CloudKit has finished its first
    /// fetch. Until this point the engine has no record or zone changes to send.
    /// `didFetchChanges` calls it, and so does a replay that applies after that fetch
    /// (`finishAppliedReplay`).
    private func completeInitialMergeIfNeeded() async throws {
        guard var state,
              !state.initialMergeCompleted,
              !state.accountNeedsApproval else { return }
        if state.pendingRemoteDocument == nil || state.initialFetchCompleted != true {
            if state.pendingRemoteDocument == nil { state.stageRemoteChanges(SyncChangeSet(changes: [])) }
            // If the store refuses this merge, a replay that applies later completes it.
            state.initialFetchCompleted = true
            try keepRemoteChanges(state)
        }

        try await replayRemoteChangesIfNeeded()
        try markInitialMergeCompleted()
    }

    private func markInitialMergeCompleted() throws {
        guard var mergedState = self.state,
              !mergedState.initialMergeCompleted,
              mergedState.pendingRemoteDocument == nil,
              !mergedState.accountNeedsApproval else { return }
        mergedState.initialMergeCompleted = true
        try persist(mergedState)
        self.state = mergedState

        if !mergedState.zoneCreated {
            syncEngine?.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: CloudKitRecordCodec.zoneID))
            ])
        } else {
            refreshEnginePendingChanges()
        }
    }

    /// Offers the kept remote batch to `AppModel`. Returns true when it applied and the
    /// state no longer keeps it.
    @discardableResult
    private func replayRemoteChangesIfNeeded() async throws -> Bool {
        if let remoteReplayTask { return try await remoteReplayTask.value }
        guard isRunning,
              let state,
              !state.accountNeedsApproval,
              let remote = state.pendingRemoteDocument,
              let receiveRemoteChanges else { return false }
        let base = state.baseDocument
        let task = Task {
            defer { remoteReplayTask = nil }
            guard let merge = await receiveRemoteChanges(base, remote) else { return false }
            return try await self.finishRemoteReplay(merge)
        }
        remoteReplayTask = task
        return try await task.value
    }

    private func waitForRemoteReplay() async {
        while let task = remoteReplayTask {
            _ = try? await task.value
        }
    }

    private func finishRemoteReplay(_ merge: CloudSyncAppliedMerge) async throws -> Bool {
        guard isRunning, !Task.isCancelled,
              let currentState = self.state,
              !currentState.accountNeedsApproval,
              currentState.hasUnappliedRemoteChanges else { return false }
        latestLocalSnapshot = latestLocalSnapshot?.afterApplying(merge)

        try await Self.installRemoteAssets(from: currentState, result: merge.result)
        guard isRunning, !Task.isCancelled,
              var latestState = self.state,
              !latestState.accountNeedsApproval,
              let local = latestLocalSnapshot?.document else { return false }
        latestState.finishRemoteMerge(
            with: merge.result,
            localDocument: local,
            iconFingerprints: iconFingerprints(in: local)
        )
        try persist(latestState)
        self.state = latestState
        refreshEnginePendingChanges()
        return true
    }

    /// A kept batch applied on a replay, outside the fetch that delivered it. Does what
    /// `didFetchChanges` does for a fetch: completes the first merge when only this batch
    /// held it back (`replayCompletesInitialMerge`), and stamps the sync as successful
    /// (`recordSuccessfulSync`). A replay that is refused again does not reach this.
    ///
    /// At a start the engine does not exist yet. `initializeEngine` then adds the zone,
    /// and `start` adds the pending records.
    private func finishAppliedReplay() async throws {
        if state?.replayCompletesInitialMerge == true {
            try markInitialMergeCompleted()
        }
        try markSyncSuccessful()
    }

    private func handleSentRecordChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        guard var state, !state.accountNeedsApproval else { return }
        var acknowledgedIDs: Set<SyncRecordID> = []

        for record in event.savedRecords {
            let decoded = try CloudKitRecordCodec.decode(record)
            state.acknowledgeSentChange(
                .save(decoded.record),
                systemFields: CloudKitRecordCodec.systemFields(for: record),
                sentIconFingerprint: sentIconFingerprints.removeValue(forKey: record.recordID.recordName)
            )
            acknowledgedIDs.insert(decoded.record.id)
        }

        for recordID in event.deletedRecordIDs {
            guard let id = CloudKitRecordCodec.syncRecordID(for: recordID) else { continue }
            state.acknowledgeSentChange(.delete(id), systemFields: nil)
            acknowledgedIDs.insert(id)
        }

        var serverRecords: [CKRecord] = []
        var serverDeletions: [SyncRecordID] = []
        var retryZone = false
        for failure in event.failedRecordSaves {
            sentIconFingerprints.removeValue(forKey: failure.record.recordID.recordName)
            switch failure.error.code {
            case .serverRecordChanged:
                if let serverRecord = failure.error.serverRecord {
                    serverRecords.append(serverRecord)
                }
            case .zoneNotFound:
                retryZone = true
                state.recordSystemFields.removeValue(forKey: failure.record.recordID.recordName)
            case .unknownItem:
                if let id = CloudKitRecordCodec.syncRecordID(for: failure.record.recordID) {
                    serverDeletions.append(id)
                }
            default:
                break
            }
        }
        for (recordID, error) in event.failedRecordDeletes {
            switch error.code {
            case .serverRecordChanged:
                if let serverRecord = error.serverRecord {
                    serverRecords.append(serverRecord)
                }
            case .zoneNotFound, .unknownItem:
                if error.code == .zoneNotFound { retryZone = true }
                if let id = CloudKitRecordCodec.syncRecordID(for: recordID) {
                    state.acknowledgeSentChange(.delete(id), systemFields: nil)
                    acknowledgedIDs.insert(id)
                }
            default:
                break
            }
        }

        if retryZone { state.zoneCreated = false }
        try persist(state)
        self.state = state
        if retryZone {
            syncEngine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: CloudKitRecordCodec.zoneID))
            ])
        }
        for record in serverRecords {
            try keepServerRecord(record)
        }
        for id in serverDeletions {
            try keepServerDeletion(id)
        }
        if !serverRecords.isEmpty || !serverDeletions.isEmpty {
            try await replayRemoteChangesIfNeeded()
        } else {
            refreshEnginePendingChanges(adding: acknowledgedIDs)
        }
    }

    private func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        guard var state, !state.accountNeedsApproval else { return }
        if event.savedZones.contains(where: { $0.zoneID == CloudKitRecordCodec.zoneID }) {
            state.zoneCreated = true
        }
        for failure in event.failedZoneSaves where failure.zone.zoneID == CloudKitRecordCodec.zoneID {
            if failure.error.code == .serverRecordChanged {
                state.zoneCreated = true
            }
        }
        if event.deletedZoneIDs.contains(CloudKitRecordCodec.zoneID) {
            state.zoneCreated = false
        }
        try persist(state)
        self.state = state
        refreshEnginePendingChanges()
    }

    private func keepServerRecord(_ record: CKRecord) throws {
        guard var state, !state.accountNeedsApproval else { return }
        let decoded = try CloudKitRecordCodec.decode(record)
        state.stageRemoteChanges(SyncChangeSet(changes: [
            .save(decoded.record)
        ]))
        state.recordSystemFields[record.recordID.recordName] = CloudKitRecordCodec.systemFields(
            for: record
        )
        if let iconData = decoded.iconData {
            state.pendingRemoteAssets[record.recordID.recordName] = iconData
        } else if case .subscription = decoded.record {
            state.pendingRemoteAssets.removeValue(forKey: record.recordID.recordName)
        }
        try keepRemoteChanges(state)
    }

    private func keepServerDeletion(_ id: SyncRecordID) throws {
        guard var state, !state.accountNeedsApproval else { return }
        state.stageRemoteChanges(SyncChangeSet(changes: [.delete(id)]))
        let name = CloudKitRecordCodec.recordID(for: id).recordName
        state.recordSystemFields.removeValue(forKey: name)
        state.pendingRemoteAssets.removeValue(forKey: name)
        try keepRemoteChanges(state)
    }

    private func keepRemoteChanges(_ state: CloudSyncStateFile) throws {
        // Block sends immediately, even if persisting this batch fails. A later state
        // update can only advance the engine token along with the staged batch.
        self.state = state
        refreshEnginePendingChanges()
        try persist(state)
    }

    private func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        guard var state else { return }
        switch event.changeType {
        case .signIn(let currentUser):
            let currentName = currentUser.recordName
            if let previousName = state.accountRecordName, previousName != currentName {
                state.accountNeedsApproval = true
            }
            state.accountRecordName = currentName
        case .signOut:
            state.accountNeedsApproval = true
        case .switchAccounts(_, let currentUser):
            state.accountRecordName = currentUser.recordName
            state.accountNeedsApproval = true
        @unknown default:
            state.accountNeedsApproval = true
        }
        try persist(state)
        self.state = state
        if state.accountNeedsApproval {
            refreshEnginePendingChanges()
            Task { await syncEngine.cancelOperations() }
            await publishStatus(
                phase: .paused,
                message: "The iCloud account changed. Your data on this Mac is unchanged."
            )
        }
    }

    private func refreshEnginePendingChanges(adding ids: Set<SyncRecordID>? = nil) {
        guard let state, let syncEngine else { return }
        let changes = state.changesToSend
        let desired = Set(changes.map(\.cloudKitPendingChange))
        let current = Set(syncEngine.state.pendingRecordZoneChanges)
        let obsolete = current.subtracting(desired)
        if !obsolete.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: Array(obsolete))
        }
        let new = changes.filter { change in
            (ids?.contains(change.recordID) ?? true) && !current.contains(change.cloudKitPendingChange)
        }
        if !new.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: new.map(\.cloudKitPendingChange))
        }
    }

    private var currentPhase: CloudSyncPhase {
        state?.phase ?? .preparing
    }

    private func accountIsAvailable() async throws -> Bool {
        let status = try await container.accountStatus()
        switch status {
        case .available:
            return true
        case .noAccount:
            await publishStatus(
                phase: .paused,
                message: "Sign in to iCloud in System Settings to use sync."
            )
        case .restricted:
            await publishStatus(
                phase: .paused,
                message: "This Mac does not allow access to the iCloud account."
            )
        case .couldNotDetermine:
            await publishStatus(
                phase: .paused,
                message: "Obolo cannot check the iCloud account now."
            )
        case .temporarilyUnavailable:
            await publishStatus(
                phase: .paused,
                message: "iCloud is temporarily unavailable. Obolo will keep your local data."
            )
        @unknown default:
            await publishStatus(
                phase: .paused,
                message: "Obolo cannot use the iCloud account with this system version."
            )
        }
        return false
    }

    /// A fetch or send finished. It counts as a success only if no refused remote batch
    /// is waiting (`CloudSyncStateFile.recordSuccessfulSync`).
    private func markSyncSuccessful() throws {
        guard var state, state.recordSuccessfulSync(at: clock()) else { return }
        try persist(state)
        self.state = state
    }

    private func publishStatus(
        phase: CloudSyncPhase,
        message: String? = nil
    ) async {
        guard let reportStatus else { return }
        await reportStatus(CloudSyncSnapshot(
            phase: phase,
            pendingChangeCount: state?.pendingChanges.count ?? 0,
            conflicts: state?.conflicts ?? [],
            lastSuccessfulSyncAt: state?.lastSuccessfulSyncAt,
            message: message,
            requiresAccountApproval: state?.accountNeedsApproval ?? false
        ))
    }

    private func persist(_ state: CloudSyncStateFile) throws {
        try stateStore.save(state)
    }

    private func emptyDocument(using document: SyncedDocument) -> SyncedDocument {
        SyncedDocument(
            subscriptions: [],
            categories: [],
            preferences: document.preferences,
            manualRates: [:]
        )
    }

    private func iconFingerprints(in document: SyncedDocument) -> [String: String] {
        var result: [String: String] = [:]
        for subscription in document.subscriptions {
            guard let fingerprint = CloudKitRecordCodec.iconFingerprint(
                for: subscription,
                in: iconsDirectory
            ) else { continue }
            let id = SyncRecordID.subscription(subscription.id)
            result[CloudKitRecordCodec.recordID(for: id).recordName] = fingerprint
        }
        return result
    }

    @MainActor
    static func installRemoteAssets(
        from state: CloudSyncStateFile,
        result: SyncMergeResult,
        changes: [SyncChange]? = nil,
        in logos: LogoStore = .shared
    ) throws {
        let newConflicts = Set(result.conflicts.map(\.recordID))
        let priorConflicts = Set(state.conflicts.map(\.recordID))
        let merged = result.document.recordMap

        for change in changes ?? state.fetchedSubscriptionChanges {
            let id = change.recordID
            guard case .subscription(let subscriptionID) = id, !newConflicts.contains(id) else { continue }
            let filename = LogoStore.filename(for: subscriptionID)
            guard case .save(.subscription(let remote)) = change else {
                if merged[id] == nil { logos.delete(filename: filename) }
                continue
            }
            guard case .subscription(let local) = merged[id],
                  local.icon == remote.icon,
                  !priorConflicts.contains(id) || local == remote else { continue }
            guard remote.icon.imageFilename != nil else {
                logos.delete(filename: filename)
                continue
            }
            let name = CloudKitRecordCodec.recordID(for: id).recordName
            guard let data = state.pendingRemoteAssets[name] else { continue }
            // A filesystem failure leaves the durable batch available for replay.
            do {
                try logos.storeArrived(imageData: data, for: subscriptionID)
            } catch let error as LogoStore.StoreError {
                log.error("Cloud sync ignored an invalid icon asset: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension SyncChange {
    var cloudKitPendingChange: CKSyncEngine.PendingRecordZoneChange {
        let id = CloudKitRecordCodec.recordID(for: recordID)
        switch self {
        case .save: return .saveRecord(id)
        case .delete: return .deleteRecord(id)
        }
    }
}
