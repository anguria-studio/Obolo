import Foundation
import OboloCore

/// A saved projection carries the last remote merge it includes. Earlier save
/// notifications may still be queued when a merge writes a newer projection.
struct CloudSyncLocalSnapshot: Sendable {
    let document: SyncedDocument
    var remoteRevision = 0

    func afterApplying(_ merge: CloudSyncAppliedMerge) -> Self {
        guard remoteRevision < merge.remoteRevision else { return self }
        return Self(document: merge.result.document, remoteRevision: merge.remoteRevision)
    }
}

struct CloudSyncAppliedMerge: Sendable {
    let result: SyncMergeResult
    let remoteRevision: Int
}

/// Applies a remote state against the newest local state.
///
/// The service supplies the common base and the remote state. `AppModel` supplies the
/// current local state, saves the merge result, and returns the result to the service.
typealias CloudSyncRemoteChangeHandler = @Sendable (
    _ baseDocument: SyncedDocument,
    _ remoteDocument: SyncedDocument
) async -> CloudSyncAppliedMerge?

enum CloudSyncPhase: String, Sendable {
    case disabled
    case preparing
    case syncing
    case current
    case paused
    case failed
}

struct CloudSyncSnapshot: Sendable, Equatable {
    var phase: CloudSyncPhase
    var pendingChangeCount: Int = 0
    var conflicts: [SyncConflict] = []
    var lastSuccessfulSyncAt: Date?
    var message: String?
    var requiresAccountApproval = false

    static let disabled = CloudSyncSnapshot(phase: .disabled)
}

typealias CloudSyncStatusHandler = @Sendable (CloudSyncSnapshot) async -> Void

/// Runs remote batches in the order in which the service delivers them.
actor CloudSyncRemoteQueue {
    private var tail: Task<Void, Never>?
    private var operationNumber = 0

    func perform(
        _ operation: @escaping @Sendable () async -> CloudSyncAppliedMerge?
    ) async -> CloudSyncAppliedMerge? {
        operationNumber += 1
        let currentOperation = operationNumber
        let previous = tail
        let resultTask = Task {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await resultTask.value }
        let result = await resultTask.value
        if currentOperation == operationNumber { tail = nil }
        return result
    }
}

/// The boundary between the local document and a future CloudKit adapter.
protocol CloudSyncService: Sendable {
    /// Prepares sync with the local document that is already safe on disk.
    ///
    /// This method must return after it prepares local work. It must not wait for a
    /// network connection.
    func start(
        localDocument: SyncedDocument,
        receiveRemoteChanges: @escaping CloudSyncRemoteChangeHandler,
        reportStatus: @escaping CloudSyncStatusHandler
    ) async

    /// Adds one saved local document to the sync work queue.
    ///
    /// This method must make the work durable and return. It must not wait for a
    /// network upload.
    func localDocumentDidSave(_ snapshot: CloudSyncLocalSnapshot) async

    /// Applies one version of a conflict that the user reviewed.
    func resolveConflict(
        _ recordID: SyncRecordID,
        choice: SyncConflictChoice
    ) async

    /// Starts a new sync session after the iCloud account or private zone changed.
    /// The caller must make a local backup before it calls this method.
    func approveCurrentAccount(localDocument: SyncedDocument) async

    /// Gives a kept remote batch to the remote-changes handler again.
    ///
    /// The service keeps a batch that the handler refused. This method offers it once
    /// more, on the same path as a start or a new fetch. It does nothing when no batch
    /// waits, or while sync is stopped, paused, or waiting for approval. It must not
    /// wait for a network connection.
    func replayRemoteChanges() async

    /// Stops network work without deleting local data or the durable sync state.
    func stop() async
}

/// Keeps sync disabled without adding optional checks to `AppModel`.
struct DisabledCloudSyncService: CloudSyncService {
    func start(
        localDocument: SyncedDocument,
        receiveRemoteChanges: @escaping CloudSyncRemoteChangeHandler,
        reportStatus: @escaping CloudSyncStatusHandler
    ) async {
        await reportStatus(.disabled)
    }

    func localDocumentDidSave(_ snapshot: CloudSyncLocalSnapshot) async {}

    func resolveConflict(
        _ recordID: SyncRecordID,
        choice: SyncConflictChoice
    ) async {}

    func approveCurrentAccount(localDocument: SyncedDocument) async {}

    func replayRemoteChanges() async {}

    func stop() async {}
}
