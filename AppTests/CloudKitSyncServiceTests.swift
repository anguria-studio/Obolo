import CloudKit
import Foundation
import OboloCore
import Testing

@Suite("CloudKit sync adapter")
struct CloudKitSyncServiceTests {
    @Test("CloudKit record names round-trip every sync identity")
    func recordIdentitiesRoundTrip() {
        let values: [SyncRecordID] = [
            .subscription(UUID()),
            .category(UUID()),
            .preferences,
            .manualRate("usd")
        ]

        for value in values {
            let recordID = CloudKitRecordCodec.recordID(for: value)
            #expect(CloudKitRecordCodec.syncRecordID(for: recordID) == normalized(value))
        }
        #expect(CloudKitRecordCodec.syncRecordID(for: CKRecord.ID(
            recordName: "subscription:../../file",
            zoneID: CloudKitRecordCodec.zoneID
        )) == nil)
    }

    @Test("A subscription record keeps its payload and icon asset")
    func subscriptionRecordRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscriptionID = UUID()
        let filename = "\(subscriptionID.uuidString).png"
        let iconData = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try iconData.write(to: directory.appending(path: filename))
        let value = SyncRecord.subscription(SyncedSubscription(Subscription(
            id: subscriptionID,
            name: "Cloud plan",
            icon: .image(filename),
            categoryID: Category.fallbackID,
            price: 3,
            currency: "EUR",
            cycle: .monthly
        )))

        let cloudRecord = try CloudKitRecordCodec.makeRecord(
            for: value,
            systemFields: nil,
            iconsDirectory: directory
        )
        let result = try CloudKitRecordCodec.decode(cloudRecord)

        #expect(result.record == value)
        #expect(result.iconData == iconData)
        #expect(cloudRecord.recordType == "OBSubscription")
    }

    @Test("An icon filename must belong to its subscription")
    func iconFilenameMustMatchSubscription() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscriptionID = UUID()
        let otherFilename = "\(UUID().uuidString).png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([137, 80, 78, 71, 13, 10, 26, 10]).write(
            to: directory.appending(path: otherFilename)
        )
        let value = SyncRecord.subscription(SyncedSubscription(Subscription(
            id: subscriptionID,
            name: "Cloud plan",
            icon: .image(otherFilename),
            categoryID: Category.fallbackID,
            price: 3,
            currency: "EUR",
            cycle: .monthly
        )))

        let record = try CloudKitRecordCodec.makeRecord(
            for: value,
            systemFields: nil,
            iconsDirectory: directory
        )

        #expect(record[CloudKitRecordCodec.iconAssetKey] == nil)
        #expect(try CloudKitRecordCodec.decode(record).iconData == nil)
    }

    @Test("Icon fingerprints detect replacement and reject a symbolic link")
    func iconFingerprintsDetectReplacement() throws {
        let root = temporaryDirectory()
        let directory = root.appending(path: "Icons", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let subscriptionID = UUID()
        let filename = "\(subscriptionID.uuidString).png"
        let subscription = SyncedSubscription(Subscription(
            id: subscriptionID,
            name: "Cloud plan",
            icon: .image(filename),
            categoryID: Category.fallbackID,
            price: 3,
            currency: "EUR",
            cycle: .monthly
        ))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iconURL = directory.appending(path: filename)
        try Data([1, 2, 3]).write(to: iconURL)
        let first = CloudKitRecordCodec.iconFingerprint(for: subscription, in: directory)
        try Data([4, 5, 6]).write(to: iconURL)
        let second = CloudKitRecordCodec.iconFingerprint(for: subscription, in: directory)

        #expect(first != second)

        let target = root.appending(path: "outside.png")
        try Data([7, 8, 9]).write(to: target)
        try FileManager.default.removeItem(at: iconURL)
        try FileManager.default.createSymbolicLink(at: iconURL, withDestinationURL: target)

        #expect(CloudKitRecordCodec.iconAssetURL(for: subscription, in: directory) == nil)
        #expect(
            CloudKitRecordCodec.iconFingerprint(for: subscription, in: directory) == "missing"
        )
    }

    @Test("Stored system fields keep the CloudKit record identity")
    func systemFieldsRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = SyncRecord.manualRate(
            currency: "USD",
            rate: SyncedManualRate(value: 0.9, updatedAt: .distantPast)
        )
        let first = try CloudKitRecordCodec.makeRecord(
            for: value,
            systemFields: nil,
            iconsDirectory: directory
        )

        let second = try CloudKitRecordCodec.makeRecord(
            for: value,
            systemFields: CloudKitRecordCodec.systemFields(for: first),
            iconsDirectory: directory
        )

        #expect(second.recordID == first.recordID)
        #expect(second.recordType == first.recordType)
        #expect(try CloudKitRecordCodec.decode(second).record == value)
    }

    @Test("The durable queue keeps the newest change for each record")
    func durableQueueCoalescesChanges() {
        let original = syncedSubscription(name: "Original")
        let updated = syncedSubscription(id: original.id, name: "Updated")
        var state = CloudSyncStateFile(baseDocument: emptyDocument())

        state.enqueue(SyncChangeSet(changes: [
            .save(.subscription(original)),
            .delete(.subscription(original.id)),
            .save(.subscription(updated))
        ]))

        let expected = SyncChange.save(.subscription(updated))
        #expect(state.pendingChanges == [expected])
        state.removePendingChange(for: original.idRecord, when: .delete(.subscription(original.id)))
        #expect(state.pendingChanges == [expected])
        state.removePendingChange(for: original.idRecord, when: expected)
        #expect(state.pendingChanges.isEmpty)
    }

    @Test("The durable queue repairs duplicate record entries")
    func durableQueueRepairsDuplicates() {
        let original = syncedSubscription(name: "Original")
        let updated = syncedSubscription(id: original.id, name: "Updated")
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.pendingChanges = [
            .save(.subscription(original)),
            .save(.subscription(updated))
        ]

        state.enqueue(SyncChangeSet(changes: []))

        #expect(state.pendingChanges == [.save(.subscription(updated))])
    }

    @Test("Records wait for the first merge and private zone")
    func recordsWaitForFirstMergeAndZone() {
        var state = CloudSyncStateFile(baseDocument: emptyDocument())

        #expect(!state.canSendRecords)
        state.initialMergeCompleted = true
        #expect(!state.canSendRecords)
        state.zoneCreated = true
        #expect(state.canSendRecords)
        state.accountNeedsApproval = true
        #expect(!state.canSendRecords)
    }

    @Test("A refused batch holds queued saves and deletes until the merge selects safe uploads")
    func refusedBatchHoldsUploads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudSyncStateStore(url: directory.appending(path: "state.json"))

        let edited = syncedSubscription(name: "Edited")
        let deleted = syncedSubscription(name: "Deleted locally")
        let removed = syncedSubscription(name: "Deleted only locally")
        let shared = syncedSubscription(name: "Both sides edited")
        let added = syncedSubscription(name: "Added locally")
        var base = emptyDocument()
        base.categories = StoreDocument.initial().categories
        base.subscriptions = [edited, deleted, removed, shared]
        var state = CloudSyncStateFile(baseDocument: base)
        state.initialMergeCompleted = true
        state.zoneCreated = true

        var localEdit = edited
        localEdit.name = "First local edit"
        let earlierChanges = SyncChangeSet(changes: [
            .save(.subscription(localEdit)), .delete(deleted.idRecord), .delete(removed.idRecord),
        ])
        let earlierLocal = base.applying(earlierChanges)
        state.enqueue(earlierChanges)

        var remoteEdit = edited
        remoteEdit.name = "Remote edit"
        var remoteReplacement = deleted
        remoteReplacement.name = "Edited remotely despite the local delete"
        var identicalEdit = shared
        identicalEdit.name = "Same change on both Macs"
        state.stageRemoteChanges(SyncChangeSet(changes: [
            .save(.subscription(remoteEdit)), .save(.subscription(remoteReplacement)),
            .save(.subscription(identicalEdit)),
        ]))

        localEdit.name = "Second local edit"
        let local = earlierLocal.applying(SyncChangeSet(changes: [
            .save(.subscription(localEdit)), .save(.subscription(added)),
            .save(.subscription(identicalEdit)),
        ]))
        state.enqueueSavedLocalChanges(from: earlierLocal, to: local, iconFingerprints: [:])
        try store.save(state)
        let queued = try store.load()
        state = try #require(queued)

        let engineChanges: [CKSyncEngine.PendingRecordZoneChange] = [
            .saveRecord(CloudKitRecordCodec.recordID(for: edited.idRecord)),
            .deleteRecord(CloudKitRecordCodec.recordID(for: deleted.idRecord)),
            .deleteRecord(CloudKitRecordCodec.recordID(for: removed.idRecord)),
            .saveRecord(CloudKitRecordCodec.recordID(for: added.idRecord)),
            .deleteRecord(CloudKitRecordCodec.recordID(for: added.idRecord)), // Stale opposite operation.
            .saveRecord(CloudKitRecordCodec.recordID(for: shared.idRecord)),
        ]
        #expect(state.pendingChanges.count == 5)
        #expect(CloudKitSyncService.makeRecordZoneChangeBatch(
            state: state, pending: engineChanges, iconsDirectory: directory
        ) == nil)

        let remote = try #require(state.pendingRemoteDocument)
        let result = try SyncMerge.merge(
            base: state.baseDocument, local: local, remote: remote, today: Date(), calendar: .current
        )
        state.finishRemoteMerge(with: result, localDocument: result.document, iconFingerprints: [:])
        try store.save(state)
        let replayed = try store.load()
        state = try #require(replayed)

        #expect(state.pendingRemoteDocument == nil)
        #expect(Set(state.conflicts.map(\.recordID)) == [edited.idRecord, deleted.idRecord])
        #expect(state.conflicts.first { $0.recordID == edited.idRecord }?.local == .subscription(localEdit))
        #expect(Set(state.pendingChanges) == [.save(.subscription(added)), .delete(removed.idRecord)])
        let batch = try #require(CloudKitSyncService.makeRecordZoneChangeBatch(
            state: state, pending: engineChanges, iconsDirectory: directory
        ))
        #expect(try batch.recordsToSave.map { try CloudKitRecordCodec.decode($0).record } == [.subscription(added)])
        #expect(batch.recordIDsToDelete == [CloudKitRecordCodec.recordID(for: removed.idRecord)])
    }

    @Test("A replay keeps unrelated pending icon uploads and prior conflicts")
    func replayKeepsUnrelatedIconUploadsAndConflicts() throws {
        var icon = syncedSubscription(name: "Updated asset")
        icon.icon = .image("\(icon.id.uuidString).png")
        let iconName = CloudKitRecordCodec.recordID(for: icon.idRecord).recordName
        let conflicted = syncedSubscription(name: "Remote choice")
        var localChoice = conflicted
        localChoice.name = "Local choice"
        let unrelated = syncedSubscription(name: "Fetched while conflict remains")
        var base = emptyDocument()
        base.categories = StoreDocument.initial().categories
        base.subscriptions = [icon, conflicted]
        var state = CloudSyncStateFile(baseDocument: base)
        state.initialMergeCompleted = true
        state.zoneCreated = true
        state.localIconFingerprints = [iconName: "original image"]
        state.conflicts = [SyncConflict(
            recordID: conflicted.idRecord,
            base: nil,
            local: .subscription(localChoice),
            remote: .subscription(conflicted)
        )]
        let local = base.applying(SyncChangeSet(changes: [.save(.subscription(localChoice))]))
        state.stageRemoteChanges(SyncChangeSet(changes: [.save(.subscription(unrelated))]))
        let newFingerprints = [iconName: "replacement image"]
        state.enqueueSavedLocalChanges(from: local, to: local, iconFingerprints: newFingerprints)
        #expect(state.changesToSend.isEmpty)

        let remote = try #require(state.pendingRemoteDocument)
        let result = try SyncMerge.merge(
            base: state.baseDocument, local: local, remote: remote, today: Date(), calendar: .current
        )
        state.finishRemoteMerge(with: result, localDocument: result.document, iconFingerprints: newFingerprints)

        #expect(state.changesToSend == [.save(.subscription(icon))])
        #expect(state.conflicts.map(\.recordID) == [conflicted.idRecord])
    }

    @Test("A save queued while replay waits cannot replace the newer edit that replay saves")
    func replayKeepsTheNewestSavedProjection() throws {
        let original = syncedSubscription(name: "Base")
        var earlier = original
        earlier.name = "Saved during replay"
        var newer = original
        newer.name = "Newer edit included in replay"
        let incoming = syncedSubscription(name: "Incoming plan")
        var base = emptyDocument()
        base.categories = StoreDocument.initial().categories
        base.subscriptions = [original]
        var state = CloudSyncStateFile(baseDocument: base)
        state.initialMergeCompleted = true
        state.zoneCreated = true
        state.stageRemoteChanges(SyncChangeSet(changes: [.save(.subscription(incoming))]))

        let earlierDocument = base.applying(SyncChangeSet(changes: [.save(.subscription(earlier))]))
        let earlierSnapshot = CloudSyncLocalSnapshot(document: earlierDocument)
        state.enqueueSavedLocalChanges(from: base, to: earlierDocument, iconFingerprints: [:])
        #expect(state.pendingChanges == [.save(.subscription(earlier))])
        #expect(state.changesToSend.isEmpty)

        let newerDocument = base.applying(SyncChangeSet(changes: [.save(.subscription(newer))]))
        let remote = try #require(state.pendingRemoteDocument)
        let result = try SyncMerge.merge(
            base: base, local: newerDocument, remote: remote, today: Date(), calendar: .current
        )
        let applied = CloudSyncAppliedMerge(result: result, remoteRevision: 1)
        let latest = earlierSnapshot.afterApplying(applied)
        state.finishRemoteMerge(with: applied.result, localDocument: latest.document, iconFingerprints: [:])

        #expect(latest.remoteRevision == 1)
        #expect(Set(latest.document.subscriptions) == [newer, incoming])
        #expect(state.changesToSend == [.save(.subscription(newer))])

        var later = newer
        later.name = "Saved after the merge committed"
        let laterDocument = latest.document.applying(SyncChangeSet(changes: [.save(.subscription(later))]))
        let laterSnapshot = CloudSyncLocalSnapshot(document: laterDocument, remoteRevision: 1)
        #expect(laterSnapshot.afterApplying(applied).document == laterDocument)
    }

    @Test("An in-flight acknowledgement advances only records outside the kept batch")
    func acknowledgementKeepsRemoteBatch() {
        let original = syncedSubscription(name: "Base")
        var remote = original
        remote.name = "Fetched"
        var overlappingUpload = original
        overlappingUpload.name = "Overlapping upload"
        let sent = syncedSubscription(name: "Acknowledged local change")
        var newer = sent
        newer.name = "Newer queued change"
        var base = emptyDocument()
        base.subscriptions = [original]
        var state = CloudSyncStateFile(baseDocument: base)
        state.stageRemoteChanges(SyncChangeSet(changes: [.save(.subscription(remote))]))
        state.enqueue(SyncChangeSet(changes: [.save(.subscription(newer))]))
        let name = CloudKitRecordCodec.recordID(for: original.idRecord).recordName
        state.recordSystemFields[name] = Data([1])

        state.acknowledgeSentChange(.save(.subscription(overlappingUpload)), systemFields: Data([2]))
        state.acknowledgeSentChange(.save(.subscription(sent)), systemFields: Data([3]))

        #expect(Set(state.baseDocument.subscriptions) == [original, sent])
        #expect(Set(state.pendingRemoteDocument?.subscriptions ?? []) == [remote, sent])
        #expect(state.recordSystemFields[name] == Data([1]))
        #expect(state.pendingChanges == [.save(.subscription(newer))])
    }

    @Test("An older upload acknowledgement keeps a newer icon queued for replay")
    func acknowledgementKeepsNewerIcon() throws {
        var subscription = syncedSubscription(name: "Plan")
        subscription.icon = .image("\(subscription.id.uuidString).png")
        let name = CloudKitRecordCodec.recordID(for: subscription.idRecord).recordName
        var base = emptyDocument()
        base.categories = StoreDocument.initial().categories
        base.subscriptions = [subscription]
        var state = CloudSyncStateFile(baseDocument: base)
        state.initialMergeCompleted = true
        state.zoneCreated = true
        state.stageRemoteChanges(SyncChangeSet(changes: []))
        state.enqueue(SyncChangeSet(changes: [.save(.subscription(subscription))]))
        state.localIconFingerprints = [name: "new image"]

        state.acknowledgeSentChange(
            .save(.subscription(subscription)), systemFields: nil, sentIconFingerprint: "old image"
        )
        let result = try SyncMerge.merge(
            base: base, local: base, remote: base, today: Date(), calendar: .current
        )
        state.finishRemoteMerge(
            with: result, localDocument: result.document, iconFingerprints: [name: "new image"]
        )

        #expect(state.changesToSend == [.save(.subscription(subscription))])
    }

    @Test("A refused remote batch does not count as a successful sync")
    func refusedRemoteBatchDoesNotStamp() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_600)
        let appliedAt = Date(timeIntervalSince1970: 1_700_001_200)
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.initialMergeCompleted = true
        state.zoneCreated = true
        state.lastSuccessfulSyncAt = earlier

        // The fetch delivered a batch, and `AppModel` returned nil: the service keeps
        // the batch to try again.
        var remote = emptyDocument()
        remote.subscriptions = [syncedSubscription(name: "Remote plan")]
        state.pendingRemoteDocument = remote

        let stampedWhileRefused = state.recordSuccessfulSync(at: fetchedAt)
        #expect(!stampedWhileRefused)
        #expect(state.lastSuccessfulSyncAt == earlier)
        #expect(state.pendingRemoteDocument == remote)
        #expect(state.phase == .syncing)

        // The next batch applies, and the service clears the pending document.
        state.baseDocument = remote
        state.pendingRemoteDocument = nil

        let stampedAfterApply = state.recordSuccessfulSync(at: appliedAt)
        #expect(stampedAfterApply)
        #expect(state.lastSuccessfulSyncAt == appliedAt)
        #expect(state.phase == .current)
    }

    @Test("A send with no refused batch records a successful sync")
    func sendWithoutRefusedBatchStamps() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.initialMergeCompleted = true
        state.zoneCreated = true
        state.enqueue(SyncChangeSet(changes: [
            .save(.subscription(syncedSubscription(name: "Queued plan")))
        ]))
        #expect(state.phase == .syncing)

        // The upload finished and removed its change from the queue.
        state.pendingChanges = []

        let stamped = state.recordSuccessfulSync(at: sentAt)
        #expect(stamped)
        #expect(state.lastSuccessfulSyncAt == sentAt)
        #expect(state.phase == .current)
    }

    @Test("A replay completes the first merge only after the first fetch finished")
    func replayCompletesFirstMergeAfterFirstFetch() {
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        var remote = emptyDocument()
        remote.subscriptions = [syncedSubscription(name: "Remote plan")]
        state.pendingRemoteDocument = remote

        // The first fetch still runs: a batch that applies now is only part of it.
        #expect(!state.replayCompletesInitialMerge)

        // The first fetch finished, and the store refused its merge.
        state.initialFetchCompleted = true
        #expect(state.replayCompletesInitialMerge)

        state.accountNeedsApproval = true
        #expect(!state.replayCompletesInitialMerge)
        state.accountNeedsApproval = false

        state.initialMergeCompleted = true
        #expect(!state.replayCompletesInitialMerge)
    }

    @Test("A first-sync batch that applies on a replay completes the merge and stamps")
    func firstSyncReplayCompletesAndStamps() {
        let refusedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let replayedAt = Date(timeIntervalSince1970: 1_700_000_600)
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.zoneCreated = true
        var remote = emptyDocument()
        remote.subscriptions = [syncedSubscription(name: "Remote plan")]

        // didFetchChanges: the first fetch finished, and `AppModel` refused the batch.
        state.initialFetchCompleted = true
        state.pendingRemoteDocument = remote
        let stampedWhileRefused = state.recordSuccessfulSync(at: refusedAt)
        #expect(!stampedWhileRefused)
        #expect(state.lastSuccessfulSyncAt == nil)
        #expect(!state.canSendRecords)
        #expect(state.phase == .syncing)

        // A replay is refused again: still no stamp, and the merge still waits.
        let stampedOnRefusedReplay = state.recordSuccessfulSync(at: replayedAt)
        #expect(!stampedOnRefusedReplay)
        #expect(state.lastSuccessfulSyncAt == nil)

        // A replay applies: the batch leaves the state, and the merge can complete.
        state.baseDocument = remote
        state.pendingRemoteDocument = nil
        #expect(state.replayCompletesInitialMerge)
        state.initialMergeCompleted = true
        let stampedOnAppliedReplay = state.recordSuccessfulSync(at: replayedAt)
        #expect(stampedOnAppliedReplay)
        #expect(state.lastSuccessfulSyncAt == replayedAt)
        #expect(state.canSendRecords)
        #expect(state.phase == .current)
    }

    @Test("The first-fetch marker survives a save and load")
    func firstFetchMarkerRoundTrips() throws {
        let directory = temporaryDirectory()
        let store = CloudSyncStateStore(
            url: directory.appending(path: AppPaths.cloudSyncStateFileName)
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.initialFetchCompleted = true
        state.pendingRemoteDocument = emptyDocument()

        try store.save(state)
        let loaded = try #require(try store.load())

        #expect(loaded.initialFetchCompleted == true)
        #expect(loaded.replayCompletesInitialMerge)
    }

    @Test("A start queues a saved local change that was never queued, once")
    func startQueuesUnqueuedLocalChangeOnce() {
        let kept = syncedSubscription(name: "Kept plan")
        let edited = syncedSubscription(name: "Edited plan")
        let removed = syncedSubscription(name: "Removed plan")
        let queued = syncedSubscription(name: "Queued plan")
        var base = emptyDocument()
        base.subscriptions = [kept, edited, removed]
        var state = CloudSyncStateFile(baseDocument: base)
        state.initialMergeCompleted = true
        state.zoneCreated = true
        state.enqueue(SyncChangeSet(changes: [.save(.subscription(queued))]))

        // The queue write failed for these changes: the local document has them, and
        // the state does not.
        var renamed = edited
        renamed.name = "Renamed plan"
        let added = syncedSubscription(name: "Added plan")
        var local = base
        local.subscriptions = [kept, renamed, queued, added]

        let changes = state.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])

        // Only the differences. The kept record and the pending one are not sent again.
        #expect(Set(changes.changes) == [
            .save(.subscription(renamed)),
            .delete(removed.idRecord),
            .save(.subscription(added)),
        ])
        #expect(Set(state.pendingChanges) == [
            .save(.subscription(queued)),
            .save(.subscription(renamed)),
            .delete(removed.idRecord),
            .save(.subscription(added)),
        ])

        // A second start finds nothing new, and the queue keeps one entry per record.
        let pendingAfterFirstStart = state.pendingChanges
        let again = state.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])
        #expect(again.changes.isEmpty)
        #expect(state.pendingChanges == pendingAfterFirstStart)
    }

    @Test("A start after a relaunch queues nothing for a date that the store file rounded")
    func startIgnoresStoredDatePrecision() throws {
        var inMemory = StoreDocument.initial()
        inMemory.subscriptions = [Subscription(
            name: "Created last session",
            categoryID: Category.fallbackID,
            price: 4,
            currency: "EUR",
            cycle: .monthly,
            createdAt: Date(timeIntervalSinceReferenceDate: 810_000_000.437)
        )]
        inMemory.rates.setRate(
            0.9,
            for: "USD",
            updatedAt: Date(timeIntervalSinceReferenceDate: 810_000_100.6)
        )
        // The last session sent what memory held, and the send completed.
        var state = CloudSyncStateFile(baseDocument: SyncedDocument(document: inMemory))
        state.initialMergeCompleted = true
        state.zoneCreated = true

        // This launch reads the document from the store file.
        let reloaded = try DocumentStore.decode(DocumentStore.encode(inMemory))
        let changes = state.enqueueUnqueuedLocalChanges(
            in: SyncedDocument(document: reloaded),
            iconFingerprints: [:]
        )

        #expect(changes.changes.isEmpty)
        #expect(state.pendingChanges.isEmpty)
    }

    @Test("A start replaces a pending value that the local document changed since")
    func startReplacesStalePendingValue() {
        let queued = syncedSubscription(name: "Queued plan")
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.initialMergeCompleted = true
        state.enqueue(SyncChangeSet(changes: [.save(.subscription(queued))]))

        var newer = queued
        newer.name = "Newer plan"
        var local = emptyDocument()
        local.subscriptions = [newer]

        let changes = state.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])

        #expect(changes.changes == [.save(.subscription(newer))])
        #expect(state.pendingChanges == [.save(.subscription(newer))])
    }

    @Test("A start queues nothing before the first merge, before approval, or for a conflict")
    func startQueuesNothingThatMustWait() {
        let added = syncedSubscription(name: "Added plan")
        var local = emptyDocument()
        local.subscriptions = [added]

        // The first merge compares the whole document itself.
        var firstSync = CloudSyncStateFile(baseDocument: emptyDocument())
        #expect(firstSync.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])
            .changes.isEmpty)
        #expect(firstSync.pendingChanges.isEmpty)

        // Nothing is sent before the user approves the account.
        var paused = CloudSyncStateFile(baseDocument: emptyDocument())
        paused.initialMergeCompleted = true
        paused.accountNeedsApproval = true
        #expect(paused.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])
            .changes.isEmpty)
        #expect(paused.pendingChanges.isEmpty)

        // A refused batch queues the local changes through its own merge.
        var refused = CloudSyncStateFile(baseDocument: emptyDocument())
        refused.initialMergeCompleted = true
        refused.pendingRemoteDocument = emptyDocument()
        #expect(refused.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])
            .changes.isEmpty)
        #expect(refused.pendingChanges.isEmpty)

        // The local value of a conflict stays on this Mac until the user selects one.
        var remoteValue = added
        remoteValue.name = "Remote plan"
        var conflicted = CloudSyncStateFile(baseDocument: emptyDocument())
        conflicted.initialMergeCompleted = true
        conflicted.conflicts = [SyncConflict(
            recordID: added.idRecord,
            base: nil,
            local: .subscription(added),
            remote: .subscription(remoteValue)
        )]
        #expect(conflicted.enqueueUnqueuedLocalChanges(in: local, iconFingerprints: [:])
            .changes.isEmpty)
        #expect(conflicted.pendingChanges.isEmpty)
    }

    @Test("The sync state store is atomic and a missing file is empty")
    func stateStoreRoundTrip() async throws {
        let directory = temporaryDirectory()
        let store = CloudSyncStateStore(
            url: directory.appending(path: AppPaths.cloudSyncStateFileName)
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.load() == nil)

        let subscription = syncedSubscription(name: "Queued plan")
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.enqueue(SyncChangeSet(changes: [.save(.subscription(subscription))]))
        var remote = emptyDocument()
        remote.subscriptions = [subscription]
        state.pendingRemoteDocument = remote
        state.recordSystemFields = ["subscription:a": Data([1, 2, 3])]
        state.pendingRemoteAssets = ["subscription:b": Data([4, 5])]
        state.localIconFingerprints = ["subscription:c": "fingerprint"]
        state.conflicts = [SyncConflict(
            recordID: subscription.idRecord,
            base: nil,
            local: .subscription(subscription),
            remote: nil
        )]
        state.zoneCreated = true
        state.accountRecordName = "account-1"
        state.accountNeedsApproval = true
        state.initialMergeCompleted = true
        state.lastSuccessfulSyncAt = Date(timeIntervalSince1970: 1_700_000_000.25)
        try store.save(state)

        let result = try #require(try store.load())
        #expect(result.version == CloudSyncStateFile.currentVersion)
        #expect(result.engineState == nil)
        #expect(result.baseDocument == state.baseDocument)
        #expect(result.pendingRemoteDocument == remote)
        #expect(result.pendingChanges == state.pendingChanges)
        #expect(result.recordSystemFields == state.recordSystemFields)
        #expect(result.pendingRemoteAssets == state.pendingRemoteAssets)
        #expect(result.localIconFingerprints == state.localIconFingerprints)
        #expect(result.conflicts == state.conflicts)
        #expect(result.zoneCreated)
        #expect(result.accountRecordName == "account-1")
        #expect(result.accountNeedsApproval)
        #expect(result.initialMergeCompleted)
        #expect(result.lastSuccessfulSyncAt == state.lastSuccessfulSyncAt)
    }

    @Test("The state store refuses a file from a newer adapter")
    func stateStoreRefusesNewerVersion() throws {
        let directory = temporaryDirectory()
        let store = CloudSyncStateStore(
            url: directory.appending(path: AppPaths.cloudSyncStateFileName)
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = CloudSyncStateFile(baseDocument: emptyDocument())
        state.version = CloudSyncStateFile.currentVersion + 1
        try store.save(state)

        #expect(throws: CloudSyncStateStore.StoreError.self) {
            try store.load()
        }
    }

    @Test("A state file from a newer Obolo stays in place and says to update")
    func newerStateFileExplainsItself() throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: AppPaths.cloudSyncStateFileName)
        let store = CloudSyncStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        var newer = CloudSyncStateFile(baseDocument: emptyDocument())
        newer.version = CloudSyncStateFile.currentVersion + 1
        try store.save(newer)
        let bytes = try Data(contentsOf: url)

        var thrown: (any Error)?
        do {
            _ = try store.loadForStart(
                orFresh: CloudSyncStateFile(baseDocument: emptyDocument()),
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        } catch {
            thrown = error
        }
        let error = try #require(thrown)

        #expect(error as? CloudSyncStateStore.StoreError == .unsupportedVersion(
            found: CloudSyncStateFile.currentVersion + 1,
            supported: CloudSyncStateFile.currentVersion
        ))
        #expect(CloudKitSyncService.startFailureMessage(for: error)
            == "Obolo cannot start iCloud sync. A newer version of Obolo wrote the iCloud sync state on this Mac. Update Obolo to continue. Your data on this Mac is unchanged.")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        ) == [AppPaths.cloudSyncStateFileName])
    }

    @Test("Each sync error on the start path reads as a sentence")
    func startErrorsReadAsSentences() {
        #expect(CloudKitSyncService.startFailureMessage(
            for: CloudSyncStateStore.StoreError.unreadable(reason: "Unexpected character")
        ) == "Obolo cannot start iCloud sync. Obolo cannot read the iCloud sync state on this Mac. Your data on this Mac is unchanged.")
        #expect(CloudKitRecordCodec.CodecError.missingPayload.localizedDescription
            == "Obolo cannot read a record from iCloud.")
        // A file-system error keeps the system's own sentence.
        let fileError = CocoaError(.fileReadNoPermission)
        #expect(CloudKitSyncService.startFailureMessage(for: fileError)
            == "Obolo cannot start iCloud sync. \(fileError.localizedDescription)")
        #expect(!fileError.localizedDescription.contains("NSCocoaErrorDomain"))
    }

    @Test("An unreadable state file is moved aside and sync waits for approval")
    func unreadableStateIsMovedAside() throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: AppPaths.cloudSyncStateFileName)
        let store = CloudSyncStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("not a sync state {".utf8)
        try garbage.write(to: url)

        #expect(throws: CloudSyncStateStore.StoreError.self) { try store.load() }

        let result = try store.loadForStart(
            orFresh: CloudSyncStateFile(baseDocument: emptyDocument()),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .replacedUnreadable(let state, let movedTo) = result else {
            Issue.record("Expected the unreadable file to be moved aside, got \(result)")
            return
        }
        #expect(state.accountNeedsApproval)
        #expect(!state.initialMergeCompleted)
        #expect(state.baseDocument == emptyDocument())
        #expect(movedTo.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL)
        #expect(movedTo.lastPathComponent.hasPrefix("\(AppPaths.cloudSyncStateFileName).corrupt-"))
        #expect(try Data(contentsOf: movedTo) == garbage)

        // The saved replacement keeps sync paused on the next launch.
        let reloaded = try store.loadForStart(
            orFresh: CloudSyncStateFile(baseDocument: emptyDocument()),
            now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        guard case .loaded(let next) = reloaded else {
            Issue.record("Expected the replacement to load, got \(reloaded)")
            return
        }
        #expect(next.accountNeedsApproval)
    }

    @Test("A second unreadable state file does not replace the first quarantine")
    func secondUnreadableStateKeepsFirstQuarantine() throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: AppPaths.cloudSyncStateFileName)
        let store = CloudSyncStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Data("first damaged file".utf8)
        let second = Data("second damaged file".utf8)

        try first.write(to: url)
        let firstResult = try store.loadForStart(
            orFresh: CloudSyncStateFile(baseDocument: emptyDocument()),
            now: now
        )
        try second.write(to: url)
        let secondResult = try store.loadForStart(
            orFresh: CloudSyncStateFile(baseDocument: emptyDocument()),
            now: now
        )

        guard case .replacedUnreadable(_, let firstURL) = firstResult,
              case .replacedUnreadable(_, let secondURL) = secondResult else {
            Issue.record("Expected two quarantines, got \(firstResult) and \(secondResult)")
            return
        }
        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == first)
        #expect(try Data(contentsOf: secondURL) == second)
    }

    @Test("A missing state file is a fresh start and moves nothing")
    func missingStateIsFreshStart() throws {
        let directory = temporaryDirectory()
        let store = CloudSyncStateStore(
            url: directory.appending(path: AppPaths.cloudSyncStateFileName)
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = CloudSyncStateFile(baseDocument: emptyDocument())

        let result = try store.loadForStart(orFresh: fresh, now: Date())

        guard case .fresh(let state) = result else {
            Issue.record("Expected a fresh start, got \(result)")
            return
        }
        #expect(!state.accountNeedsApproval)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    @Test("A readable, a newer, or a file the system cannot read stays in place")
    func otherStatesStayInPlace() throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: AppPaths.cloudSyncStateFileName)
        let store = CloudSyncStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = CloudSyncStateFile(baseDocument: emptyDocument())
        func directoryContents() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        }

        var readable = CloudSyncStateFile(baseDocument: emptyDocument())
        readable.initialMergeCompleted = true
        try store.save(readable)
        let readableBytes = try Data(contentsOf: url)
        guard case .loaded(let loaded) = try store.loadForStart(orFresh: fresh, now: Date()) else {
            Issue.record("Expected the readable file to load")
            return
        }
        #expect(loaded.initialMergeCompleted)
        #expect(!loaded.accountNeedsApproval)
        #expect(try Data(contentsOf: url) == readableBytes)

        var newer = CloudSyncStateFile(baseDocument: emptyDocument())
        newer.version = CloudSyncStateFile.currentVersion + 1
        try store.save(newer)
        #expect(throws: CloudSyncStateStore.StoreError.self) {
            try store.loadForStart(orFresh: fresh, now: Date())
        }
        #expect(try directoryContents() == [AppPaths.cloudSyncStateFileName])

        // A read error from the file system, not a decode error.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try store.loadForStart(orFresh: fresh, now: Date())
        }
        #expect(try directoryContents() == [AppPaths.cloudSyncStateFileName])
    }

    @Test("A state file in the shape of the first connected adapter still loads")
    func firstConnectedStateLoads() throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: AppPaths.cloudSyncStateFileName)
        let store = CloudSyncStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A fresh session as the 2026-09-09 adapter wrote it: every non-optional key,
        // and no key for an optional value that is not set.
        let json = """
        {"accountNeedsApproval":false,"baseDocument":{"categories":[],"manualRates":{},\
        "preferences":{"baseCurrency":"EUR","defaultReminderLeadDays":2,"dueSoonWindowDays":7},\
        "schemaVersion":1,"subscriptions":[]},"conflicts":[],"initialMergeCompleted":false,\
        "localIconFingerprints":{},"pendingChanges":[],"pendingRemoteAssets":{},\
        "recordSystemFields":{},"version":2,"zoneCreated":false}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let result = try #require(try store.load())

        #expect(result.version == 2)
        #expect(result.baseDocument == emptyDocument())
        #expect(result.pendingRemoteDocument == nil)
        #expect(!result.initialMergeCompleted)
        #expect(result.initialFetchCompleted == nil)
        #expect(!result.replayCompletesInitialMerge)
        #expect(result.lastSuccessfulSyncAt == nil)

        // The current encoder writes the same keys back.
        try store.save(result)
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }

    /// The base that a session with an older Mac stored holds that Mac's due-soon window.
    @Test("A saved base with another due-soon window loads, saves back unchanged and queues nothing")
    func storedOlderWindowQueuesNothing() throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: AppPaths.cloudSyncStateFileName)
        let store = CloudSyncStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"accountNeedsApproval":false,"baseDocument":{"categories":[],"manualRates":{},\
        "preferences":{"baseCurrency":"EUR","defaultReminderLeadDays":2,"dueSoonWindowDays":21},\
        "schemaVersion":1,"subscriptions":[]},"conflicts":[],"initialMergeCompleted":true,\
        "localIconFingerprints":{},"pendingChanges":[],"pendingRemoteAssets":{},\
        "recordSystemFields":{},"version":2,"zoneCreated":true}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        var state = try #require(try store.load())
        #expect(state.baseDocument.preferences.dueSoonWindowDays == 21)
        #expect(state.baseDocument == emptyDocument())
        try store.save(state)
        #expect(try Data(contentsOf: url) == Data(json.utf8))

        // A start on this build: the local document carries the window this build writes.
        let changes = state.enqueueUnqueuedLocalChanges(in: emptyDocument(), iconFingerprints: [:])
        #expect(emptyDocument().preferences.dueSoonWindowDays == Settings.paymentHighlightWindowDays)
        #expect(changes.changes.isEmpty)
        #expect(state.pendingChanges.isEmpty)
    }

    private func normalized(_ id: SyncRecordID) -> SyncRecordID {
        if case .manualRate(let currency) = id {
            return .manualRate(Subscription.normalizedCurrency(currency))
        }
        return id
    }

    private func emptyDocument() -> SyncedDocument {
        SyncedDocument(
            subscriptions: [],
            categories: [],
            preferences: SyncedPreferences(
                baseCurrency: "EUR",
                dueSoonWindowDays: 7,
                defaultReminderLeadDays: 2
            ),
            manualRates: [:]
        )
    }

    private func syncedSubscription(id: UUID = UUID(), name: String) -> SyncedSubscription {
        SyncedSubscription(Subscription(
            id: id,
            name: name,
            categoryID: Category.fallbackID,
            price: 4,
            currency: "EUR",
            cycle: .monthly,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "OboloCloudKitTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}

private extension SyncedSubscription {
    var idRecord: SyncRecordID { .subscription(id) }
}
