import AppKit
import Foundation
import OboloCore
import Testing

@MainActor
@Suite("Application model")
struct AppModelTests {
    @Test("Manual calendar sync reports missing configuration without accessing calendars")
    func manualCalendarSyncReportsMissingConfiguration() async {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let service = CalendarSync(model: model)
        var document = fixture.document
        document.settings.calendarSyncEnabled = true
        document.settings.calendarIdentifier = nil
        await service.reconcile(document: document)
        #expect(model.calendarSyncError == "Choose a calendar before syncing.")
        #expect(model.lastCalendarSyncAt == nil)
        model.recordCalendarSync(at: fixture.day(2026, 8, 22))
        #expect(model.calendarSyncError == nil)
        #expect(model.lastCalendarSyncAt != nil)
    }

    @Test("Home and Calendar share one month; All leaves it alone, and it goes back to the current one")
    func homeAndCalendarShareOneMonth() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let calendar = model.calendar
        let current = MonthRange.start(of: model.today, calendar: calendar)
        let march = MonthRange.start(of: model.today, offsetByMonths: -5, calendar: calendar)
        #expect(model.isShowingCurrentMonth)

        // Picked on Home, it is the month Calendar opens on.
        model.section = .overview
        model.showMonth(containing: march)
        model.section = .calendar
        #expect(model.shownMonth == march)
        #expect(!model.isShowingCurrentMonth)

        // A move on Calendar is the month Home reads; All keeps it.
        model.showNext()
        model.section = .all
        model.section = .overview
        #expect(model.shownMonth == MonthRange.start(of: march, offsetByMonths: 1, calendar: calendar))

        // A reopened window starts again from the current month.
        model.showCurrentMonth()
        #expect(model.shownMonth == current)
        #expect(model.isShowingCurrentMonth)
    }

    @Test("Save fetches a logo only in logo mode, with a domain and no usable logo file")
    func logoNeededOnSave() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        var plain = fixture.subscription(name: "Netflix")
        plain.website = "netflix.com"
        plain.icon = .initial
        #expect(model.logoFetchDomain(for: plain) == "netflix.com")

        // Letter and back to Logo leaves an icon whose file isn't there: fetch again.
        var missingFile = plain
        missingFile.icon = .image("gone.png")
        #expect(model.logoFetchDomain(for: missingFile) == "netflix.com")

        // A letter the person picked stays as it is.
        var letter = plain
        letter.icon = .letter(.blue)
        #expect(model.logoFetchDomain(for: letter) == nil)

        // Nothing to fetch from without a domain.
        var noDomain = plain
        noDomain.website = nil
        #expect(model.logoFetchDomain(for: noDomain) == nil)
    }

    @Test("Mutations update the document and ledger")
    func mutationsUpdateState() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let subscription = fixture.subscription(name: "Cloud storage")

        model.add(subscription)
        #expect(model.selectedID == subscription.id)
        #expect(model.ledger.monthlyTotal == subscription.price)

        // Pause is gone: a request for it writes nothing.
        model.setStatus(.paused, for: subscription.id)
        #expect(model.subscription(subscription.id)?.status == .active)
        #expect(model.ledger.monthlyTotal == subscription.price)

        let end = BillingDay(isoDate: "2026-11-03")!
        model.cancel(subscription.id, endsOn: end)
        #expect(model.subscription(subscription.id)?.status == .cancelled)
        #expect(model.subscription(subscription.id)?.endsOn == end)
        #expect(model.ledger.monthlyTotal == 0)

        try await model.flushSave()
        let saved = try await fixture.store.load()
        #expect(saved.subscriptions == model.document.subscriptions)
    }

    @Test("A mutation notifies the injected services")
    func mutationNotifiesServices() async throws {
        let fixture = TestFixture(calendarSyncEnabled: true)
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let scheduler = SchedulerSpy()
        let calendarSync = CalendarSyncSpy()
        model.notificationScheduler = scheduler
        model.calendarSync = calendarSync

        let subscription = fixture.subscription(name: "Fitness")
        model.add(subscription)

        let scheduledLedger = await scheduler.nextLedger()
        let syncedDocument = await calendarSync.nextDocument()
        #expect(scheduledLedger.summary(id: subscription.id) != nil)
        #expect(syncedDocument.subscription(id: subscription.id) == subscription)

        try await model.flushSave()
    }

    @Test("Rapid reminder edits finish the in-flight pass before applying the latest time")
    func reminderEditsRescheduleInOrder() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let scheduler = SchedulerSpy(pauseFirstPass: true)
        model.notificationScheduler = scheduler

        func setReminderHour(_ hour: Int) {
            var settings = model.document.settings
            settings.notificationTime = DateComponents(hour: hour, minute: 0)
            model.updateSettings(settings)
        }

        setReminderHour(10)
        let first = try #require(model.notificationScheduleTask)
        let started = await scheduler.nextLedger()
        #expect(started.document.settings.notificationTime.hour == 10)

        setReminderHour(11)
        let superseded = try #require(model.notificationScheduleTask)
        setReminderHour(12)
        let latest = try #require(model.notificationScheduleTask)
        #expect(first.isCancelled)
        #expect(superseded.isCancelled)

        await scheduler.finishFirstPass()
        await latest.value
        let completed = await scheduler.completedLedgers
        #expect(completed.map { $0.document.settings.notificationTime.hour } == [10, 12])

        try await model.flushSave()
    }

    @Test("Cloud sync starts only after the local document is safe")
    func cloudSyncStartsAfterLoad() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        let subscription = fixture.subscription(name: "Shared plan")
        document.subscriptions = [subscription]
        try await fixture.store.save(document)
        try await fixture.setCloudSyncEnabled()

        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()

        let started = await cloudSync.nextEvent()
        #expect(started == .started(SyncedDocument(document: document)))
        #expect(await cloudSync.eventCount == 1)

        var updated = subscription
        updated.name = "Updated plan"
        model.update(updated)
        #expect(await cloudSync.eventCount == 1)

        try await model.flushSave()
        let saved = await cloudSync.nextEvent()
        #expect(saved == .saved(SyncedDocument(document: model.document)))
    }

    @Test("Cloud sync stays off until this Mac opts in")
    func cloudSyncIsOffByDefault() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)

        await model.load()

        #expect(!model.isCloudSyncEnabled)
        #expect(await cloudSync.eventCount == 0)
    }

    @Test("Turning on cloud sync makes a backup before the service starts")
    func enablingCloudSyncMakesBackup() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()

        try await model.enableCloudSync()

        #expect(await cloudSync.nextEvent() == .started(SyncedDocument(document: fixture.document)))
        #expect(model.isCloudSyncEnabled)
        #expect(try await fixture.deviceStateStore.load().cloudSyncEnabled)
        let backupURL = try #require(model.cloudSyncBackupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try await fixture.store.load() == fixture.document)
    }

    @Test("Turning off cloud sync stops work and keeps local data")
    func disablingCloudSyncStopsWork() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        await model.disableCloudSync()

        #expect(await cloudSync.nextEvent() == .stopped)
        #expect(!model.isCloudSyncEnabled)
        #expect(!(try await fixture.deviceStateStore.load().cloudSyncEnabled))
        #expect(try await fixture.store.load() == fixture.document)
    }

    @Test("A reviewed cloud conflict reaches the sync service")
    func reviewedCloudConflictReachesService() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()
        let recordID = SyncRecordID.subscription(UUID())

        await model.resolveCloudSyncConflict(recordID, choice: .remote)

        #expect(await cloudSync.nextEvent() == .resolved(recordID, .remote))
    }

    @Test("Continuing after an account change makes another backup")
    func approvingCloudAccountMakesBackup() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()
        await cloudSync.sendStatus(CloudSyncSnapshot(
            phase: .paused,
            message: "The iCloud account changed.",
            requiresAccountApproval: true
        ))

        try await model.approveCurrentCloudSyncAccount()

        #expect(await cloudSync.nextEvent() == .approved(SyncedDocument(document: fixture.document)))
        let backupURL = try #require(model.cloudSyncBackupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    /// The CloudKit service moves an unreadable `cloud-sync.json` aside and starts paused,
    /// with the same approval the account-change flow uses (`CloudSyncStateStore`).
    @Test("An unreadable sync state offers continue, which makes a backup first")
    func unreadableSyncStateContinuesAfterBackup() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let message = "Obolo cannot read the iCloud sync state on this Mac. Your data on this Mac is unchanged."
        let backups = fixture.directory.appending(
            path: AppPaths.cloudSyncBackupsDirectoryName,
            directoryHint: .isDirectory
        )
        let cloudSync = FakeCloudSyncService(
            startStatus: CloudSyncSnapshot(
                phase: .paused,
                message: message,
                requiresAccountApproval: true
            ),
            backupsDirectory: backups
        )
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        #expect(model.cloudSyncStatus.phase == .paused)
        #expect(model.cloudSyncStatus.requiresAccountApproval)
        #expect(model.cloudSyncNotes == [AppModel.CloudSyncNote(text: message, isError: false)])
        #expect(await cloudSync.backupsWhenApproved == nil)

        try await model.approveCurrentCloudSyncAccount()

        #expect(await cloudSync.nextEvent() == .approved(SyncedDocument(document: fixture.document)))
        let backupURL = try #require(model.cloudSyncBackupURL)
        #expect(await cloudSync.backupsWhenApproved == [backupURL.lastPathComponent])
        #expect(try await fixture.store.load() == fixture.document)
    }

    @Test("Retrying a paused cloud session starts a new service session")
    func retryingCloudSyncRestartsService() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()
        await cloudSync.sendStatus(CloudSyncSnapshot(phase: .paused))

        await model.retryCloudSync()

        #expect(await cloudSync.nextEvent() == .stopped)
        #expect(await cloudSync.nextEvent() == .started(SyncedDocument(document: fixture.document)))
    }

    @Test("Try Again writes a waiting edit first and starts from the document on disk")
    func retryStartsFromTheWrittenDocument() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        // The edit waits for its debounced save when the user asks for a new session.
        model.add(fixture.subscription(name: "Waiting plan"))
        let edited = model.document
        await model.retryCloudSync()

        #expect(await cloudSync.nextEvent() == .stopped)
        let stored = try await fixture.store.load()
        #expect(stored == edited)
        #expect(await cloudSync.nextEvent() == .started(SyncedDocument(document: stored)))
    }

    @Test("Try Again starts nothing while the store cannot write, and the edit saves later")
    func retryWaitsForAWritableStore() async throws {
        let fixture = TestFixture()
        defer {
            try? fixture.setStoreWritable(true)
            fixture.remove()
        }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        try fixture.setStoreWritable(false)
        model.add(fixture.subscription(name: "Unsaved plan"))
        let edited = model.document
        await model.retryCloudSync()

        // The running session stays. Sync never hears about a document the disk lacks.
        #expect(await cloudSync.eventCount == 1)
        #expect(model.saveError != nil)

        // The save that the write replaced comes back, and reaches the same session.
        try fixture.setStoreWritable(true)
        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: edited)))
        #expect(try await fixture.store.load() == edited)
        #expect(model.saveError == nil)
    }

    @Test("Enabling sync again while a save waits starts only after the store writes")
    func repeatedEnableStartsAfterTheWrite() async throws {
        let fixture = TestFixture()
        defer {
            try? fixture.setStoreWritable(true)
            fixture.remove()
        }
        // A paused row is corrected on load, so the load saves before sync starts.
        var legacy = fixture.document
        var paused = fixture.subscription(name: "Old paused plan")
        paused.anchorDate = BillingDay(isoDate: "2026-03-10")!
        paused.status = .paused
        legacy.subscriptions = [paused]
        try await fixture.store.save(legacy)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        let corrected = model.document
        #expect(corrected != legacy)
        #expect(await cloudSync.eventCount == 0)

        try fixture.setStoreWritable(false)
        try await model.enableCloudSync()

        #expect(await cloudSync.eventCount == 0)
        #expect(model.saveError != nil)

        try fixture.setStoreWritable(true)
        #expect(await cloudSync.nextEvent() == .started(SyncedDocument(document: corrected)))
        #expect(try await fixture.store.load() == corrected)
    }

    @Test("Remote changes include a local edit that is waiting to save")
    func remoteChangesIncludePendingLocalWork() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        let localSubscription = fixture.subscription(name: "Local plan")
        model.add(localSubscription)

        let remoteSubscription = fixture.subscription(name: "Remote plan")
        var remoteStore = fixture.document
        remoteStore.subscriptions = [remoteSubscription]
        let received = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: SyncedDocument(document: remoteStore)
        )
        let result = try #require(received)

        #expect(result.document.subscriptions.contains { $0.id == localSubscription.id })
        #expect(result.document.subscriptions.contains { $0.id == remoteSubscription.id })
        #expect(result.changesForRemoteStore.changes.map(\.recordID) == [
            .subscription(localSubscription.id)
        ])
        let stored = try await fixture.store.load()
        #expect(stored.subscription(id: localSubscription.id) != nil)
        #expect(stored.subscription(id: remoteSubscription.id) != nil)

        try? await Task.sleep(for: .milliseconds(350))
        #expect(await cloudSync.eventCount == 1)
    }

    @Test("A saved local change reaches sync before a later remote change")
    func savedLocalChangePrecedesRemoteChange() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Base plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription]
        try await fixture.store.save(baseStore)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        #expect(await cloudSync.nextEvent() == .started(SyncedDocument(document: baseStore)))

        var localSubscription = subscription
        localSubscription.name = "Local name"
        model.update(localSubscription)
        try await model.flushSave()
        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: model.document)))

        let remoteSubscription = fixture.subscription(name: "Remote plan")
        var remoteStore = baseStore
        remoteStore.subscriptions.append(remoteSubscription)
        let received = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: baseStore),
            remote: SyncedDocument(document: remoteStore)
        )
        let result = try #require(received)

        #expect(result.document.subscriptions.first {
            $0.id == localSubscription.id
        }?.name == "Local name")
        #expect(result.document.subscriptions.contains { $0.id == remoteSubscription.id })
        #expect(await cloudSync.eventCount == 2)
    }

    @Test("Concurrent remote batches are applied one after the other")
    func concurrentRemoteBatchesKeepTheirOrder() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        let firstSubscription = fixture.subscription(name: "First remote plan")
        var firstStore = fixture.document
        firstStore.subscriptions = [firstSubscription]
        let secondSubscription = fixture.subscription(name: "Second remote plan")
        var secondStore = fixture.document
        secondStore.subscriptions = [secondSubscription]
        let base = SyncedDocument(document: fixture.document)

        async let firstResult = cloudSync.sendRemoteChanges(
            base: base,
            remote: SyncedDocument(document: firstStore)
        )
        async let secondResult = cloudSync.sendRemoteChanges(
            base: base,
            remote: SyncedDocument(document: secondStore)
        )
        let results = await (firstResult, secondResult)

        #expect(results.0 != nil)
        #expect(results.1 != nil)
        let stored = try await fixture.store.load()
        #expect(stored.subscription(id: firstSubscription.id) != nil)
        #expect(stored.subscription(id: secondSubscription.id) != nil)
    }

    @Test("A remote document from a newer app does not replace local data")
    func newerRemoteSchemaKeepsLocalData() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let localSubscription = fixture.subscription(name: "Local plan")
        var localStore = fixture.document
        localStore.subscriptions = [localSubscription]
        try await fixture.store.save(localStore)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        var newerRemote = SyncedDocument(document: localStore)
        newerRemote.schemaVersion = SyncedDocument.currentSchemaVersion + 1
        let result = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: localStore),
            remote: newerRemote
        )

        #expect(result == nil)
        #expect(model.cloudSyncRemoteChangesError != nil)
        #expect(model.subscription(localSubscription.id) == localSubscription)
        #expect(try await fixture.store.load() == localStore)
    }

    /// The CloudKit service publishes a healthy status right after a batch it could not
    /// hand over: the fetch itself worked. That status used to clear the error before
    /// anything could show it.
    @Test("A remote batch that cannot merge stays visible under a healthy status")
    func unmergedRemoteBatchStaysVisible() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let localSubscription = fixture.subscription(name: "Local plan")
        var localStore = fixture.document
        localStore.subscriptions = [localSubscription]
        try await fixture.store.save(localStore)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()
        #expect(model.cloudSyncNotes.isEmpty)
        #expect(!model.cloudSyncNeedsAttention)

        var newerRemote = SyncedDocument(document: localStore)
        newerRemote.schemaVersion = SyncedDocument.currentSchemaVersion + 1
        _ = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: localStore),
            remote: newerRemote
        )
        await cloudSync.sendStatus(CloudSyncSnapshot(phase: .current))

        let mergeError = AppModel.CloudSyncNote(
            text: "Obolo cannot merge the iCloud changes. Update Obolo and try again.",
            isError: true
        )
        #expect(model.cloudSyncNotes == [mergeError])
        #expect(model.cloudSyncNeedsAttention)

        // A later batch that applies is the success that clears it.
        let remoteSubscription = fixture.subscription(name: "Remote plan")
        var remoteStore = localStore
        remoteStore.subscriptions.append(remoteSubscription)
        let applied = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: localStore),
            remote: SyncedDocument(document: remoteStore)
        )
        #expect(applied != nil)
        #expect(model.cloudSyncNotes.isEmpty)
        #expect(!model.cloudSyncNeedsAttention)
    }

    @Test("Turning off cloud sync clears a remote batch error")
    func disablingCloudSyncClearsRemoteBatchError() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        var newerRemote = SyncedDocument(document: fixture.document)
        newerRemote.schemaVersion = SyncedDocument.currentSchemaVersion + 1
        _ = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: newerRemote
        )
        #expect(!model.cloudSyncNotes.isEmpty)

        await model.disableCloudSync()

        #expect(model.cloudSyncNotes.isEmpty)
        #expect(!model.cloudSyncNeedsAttention)
    }

    @Test("A batch that the store could not save applies after the next successful save")
    func unsavedRemoteBatchReplaysAfterNextSave() async throws {
        let fixture = TestFixture()
        defer {
            try? fixture.setStoreWritable(true)
            fixture.remove()
        }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        let remoteSubscription = fixture.subscription(name: "Remote plan")
        var remoteStore = fixture.document
        remoteStore.subscriptions = [remoteSubscription]
        try fixture.setStoreWritable(false)
        let refused = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: SyncedDocument(document: remoteStore)
        )
        #expect(refused == nil)
        #expect(model.cloudSyncRemoteChangesError
            == "Obolo cannot save the iCloud changes on this Mac. Obolo tries again when it saves your next change.")
        #expect(model.subscription(remoteSubscription.id) == nil)

        // The store works again, but nothing replays until a save shows it.
        try fixture.setStoreWritable(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await cloudSync.replayCount == 0)

        let localSubscription = fixture.subscription(name: "Local plan")
        model.add(localSubscription)
        let edited = model.document
        try await model.flushSave()

        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: edited)))
        #expect(await cloudSync.nextEvent() == .replayed)
        #expect(model.cloudSyncRemoteChangesError == nil)
        #expect(model.saveError == nil)
        #expect(model.subscription(remoteSubscription.id) != nil)
        #expect(model.subscription(localSubscription.id) != nil)
        let stored = try await fixture.store.load()
        #expect(stored.subscription(id: remoteSubscription.id) != nil)
        #expect(stored.subscription(id: localSubscription.id) != nil)

        // One replay for one refusal: a later save does not ask again.
        var renamed = localSubscription
        renamed.name = "Renamed plan"
        model.update(renamed)
        try await model.flushSave()
        if case .saved = await cloudSync.nextEvent() {} else {
            Issue.record("Expected the later save to reach sync")
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await cloudSync.replayCount == 1)
    }

    @Test("A successful local save replays a waiting batch and reports same-record conflicts")
    func localEditBeforeReplayConflicts() async throws {
        let fixture = TestFixture()
        defer {
            try? fixture.setStoreWritable(true)
            fixture.remove()
        }
        let subscription = fixture.subscription(name: "Base name")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription]
        try await fixture.store.save(baseStore)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        var remoteSubscription = subscription
        remoteSubscription.name = "Remote name"
        var remoteStore = baseStore
        remoteStore.subscriptions = [remoteSubscription]
        try fixture.setStoreWritable(false)
        let refused = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: baseStore),
            remote: SyncedDocument(document: remoteStore)
        )
        #expect(refused == nil)
        try fixture.setStoreWritable(true)

        var localSubscription = subscription
        localSubscription.name = "Local name"
        model.update(localSubscription)
        let edited = model.document
        try await model.flushSave()

        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: edited)))
        #expect(await cloudSync.nextEvent() == .replayed)
        let result = try #require(await cloudSync.lastReplayResult)
        #expect(result.conflicts.map(\.recordID) == [.subscription(subscription.id)])
        #expect(result.conflicts.first?.remote == .subscription(SyncedSubscription(remoteSubscription)))
        #expect(result.changesForRemoteStore.changes.isEmpty)
        #expect(model.subscription(subscription.id)?.name == "Local name")
    }

    @Test("A batch from a newer Obolo is not replayed after a save")
    func newerRemoteBatchDoesNotReplayAfterSave() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        var newerRemote = SyncedDocument(document: fixture.document)
        newerRemote.schemaVersion = SyncedDocument.currentSchemaVersion + 1
        let refused = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: newerRemote
        )
        #expect(refused == nil)

        for name in ["First plan", "Second plan"] {
            model.add(fixture.subscription(name: name))
            try await model.flushSave()
            if case .saved = await cloudSync.nextEvent() {} else {
                Issue.record("Expected the save to reach sync")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await cloudSync.replayCount == 0)
        #expect(model.cloudSyncRemoteChangesError
            == "Obolo cannot merge the iCloud changes. Update Obolo and try again.")
    }

    /// Store recovery is not tested here: it starts only at load, before sync starts, so
    /// no batch can be refused in a session that is in recovery
    /// ("Store recovery does not start cloud sync").
    @Test("A batch that the store could not save is not replayed while sync is paused")
    func unsavedRemoteBatchWaitsWhilePaused() async throws {
        let fixture = TestFixture()
        defer {
            try? fixture.setStoreWritable(true)
            fixture.remove()
        }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        let remoteSubscription = fixture.subscription(name: "Remote plan")
        var remoteStore = fixture.document
        remoteStore.subscriptions = [remoteSubscription]
        try fixture.setStoreWritable(false)
        _ = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: SyncedDocument(document: remoteStore)
        )
        try fixture.setStoreWritable(true)

        let pauses = [
            CloudSyncSnapshot(
                phase: .paused,
                message: "The iCloud account changed.",
                requiresAccountApproval: true
            ),
            CloudSyncSnapshot(
                phase: .paused,
                message: "Sign in to iCloud in System Settings to use sync."
            ),
        ]
        for (index, paused) in pauses.enumerated() {
            await cloudSync.sendStatus(paused)
            model.add(fixture.subscription(name: "Local plan \(index)"))
            try await model.flushSave()
            if case .saved = await cloudSync.nextEvent() {} else {
                Issue.record("Expected the save to reach sync")
            }
            try? await Task.sleep(for: .milliseconds(50))
            #expect(await cloudSync.replayCount == 0)
            #expect(model.cloudSyncRemoteChangesError != nil)
        }

        // The refusal waits: the first save after the pause asks for the replay.
        await cloudSync.sendStatus(CloudSyncSnapshot(phase: .syncing))
        model.add(fixture.subscription(name: "Later plan"))
        try await model.flushSave()
        if case .saved = await cloudSync.nextEvent() {} else {
            Issue.record("Expected the save to reach sync")
        }
        #expect(await cloudSync.nextEvent() == .replayed)
        #expect(model.cloudSyncRemoteChangesError == nil)
        #expect(model.subscription(remoteSubscription.id) != nil)
    }

    @Test("A failed merged write schedules the local save it cancelled, and nothing repeats")
    func failedMergedWriteSchedulesCancelledSaveOnce() async throws {
        let fixture = TestFixture()
        defer {
            try? fixture.setStoreWritable(true)
            fixture.remove()
        }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        // A local edit waits for its debounced save when the remote batch arrives.
        let localSubscription = fixture.subscription(name: "Local plan")
        model.add(localSubscription)
        let edited = model.document

        let remoteSubscription = fixture.subscription(name: "Remote plan")
        var remoteStore = fixture.document
        remoteStore.subscriptions = [remoteSubscription]
        try fixture.setStoreWritable(false)
        let refused = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: SyncedDocument(document: remoteStore)
        )
        #expect(refused == nil)

        // The store writes again for the local save, but each replay finds it read-only:
        // the merged write keeps failing.
        let directoryPath = fixture.directory.path(percentEncoded: false)
        await cloudSync.setBeforeReplay {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: directoryPath
            )
        }
        try fixture.setStoreWritable(true)

        // The cancelled save comes back once, and its success asks for one replay.
        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: edited)))
        #expect(await cloudSync.nextEvent() == .replayed)

        // The replay failed again with no pending save, so nothing more happens.
        let eventsAfterReplay = await cloudSync.eventCount
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await cloudSync.eventCount == eventsAfterReplay)
        #expect(await cloudSync.replayCount == 1)
        #expect(model.cloudSyncRemoteChangesError
            == "Obolo cannot save the iCloud changes on this Mac. Obolo tries again when it saves your next change.")
        #expect(model.subscription(localSubscription.id) != nil)
        #expect(model.subscription(remoteSubscription.id) == nil)

        // The local edit is on disk; the remote batch is not.
        try fixture.setStoreWritable(true)
        let stored = try await fixture.store.load()
        #expect(stored.subscription(id: localSubscription.id) != nil)
        #expect(stored.subscription(id: remoteSubscription.id) == nil)
    }

    @Test("A flush tells sync about the document it wrote, not an edit made during the write")
    func flushTellsSyncWhatItWrote() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Base plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription]
        try await fixture.store.save(baseStore)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        var written = subscription
        written.name = "Written name"
        model.update(written)
        let writtenDocument = model.document

        // The flush runs up to its write. The edit below lands while the store writes.
        let flush = Task { try await model.flushSave() }
        await Task.yield()
        var later = written
        later.name = "Later name"
        model.update(later)
        try await flush.value

        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: writtenDocument)))
        #expect(try await fixture.store.load() == writtenDocument)

        // The later edit reaches sync after its own save writes it.
        #expect(await cloudSync.nextEvent() == .saved(SyncedDocument(document: model.document)))
        #expect(try await fixture.store.load() == model.document)
        #expect(model.subscription(subscription.id)?.name == "Later name")
    }

    @Test("A failed status and its mirrored error show one line")
    func failedStatusShowsOnce() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        await cloudSync.sendStatus(CloudSyncSnapshot(
            phase: .failed,
            message: "Obolo cannot finish iCloud sync."
        ))

        #expect(model.cloudSyncError == "Obolo cannot finish iCloud sync.")
        #expect(model.cloudSyncNotes == [
            AppModel.CloudSyncNote(text: "Obolo cannot finish iCloud sync.", isError: true)
        ])
        #expect(model.cloudSyncNeedsAttention)
    }

    @Test("Sync lines keep the status message and add each other error once")
    func cloudSyncNotesCombineSources() {
        let paused = CloudSyncSnapshot(
            phase: .paused,
            message: "Sign in to iCloud in System Settings to use sync."
        )
        let mergeError = "Obolo cannot merge the iCloud changes. Update Obolo and try again."

        #expect(AppModel.cloudSyncNotes(status: paused, errors: [nil, mergeError]) == [
            AppModel.CloudSyncNote(text: "Sign in to iCloud in System Settings to use sync.", isError: false),
            AppModel.CloudSyncNote(text: mergeError, isError: true),
        ])
        #expect(AppModel.cloudSyncNotes(
            status: CloudSyncSnapshot(phase: .current),
            errors: [nil, nil]
        ).isEmpty)
        #expect(AppModel.cloudSyncNotes(
            status: CloudSyncSnapshot(phase: .syncing),
            errors: [mergeError, mergeError]
        ) == [AppModel.CloudSyncNote(text: mergeError, isError: true)])

        // Paused and preparing keep their own word; a healthy one gives way.
        #expect(!AppModel.cloudSyncNeedsAttention(status: paused, remoteChangesError: mergeError))
        #expect(!AppModel.cloudSyncNeedsAttention(
            status: CloudSyncSnapshot(phase: .preparing),
            remoteChangesError: mergeError
        ))
        #expect(AppModel.cloudSyncNeedsAttention(
            status: CloudSyncSnapshot(phase: .syncing),
            remoteChangesError: mergeError
        ))
        #expect(!AppModel.cloudSyncNeedsAttention(
            status: CloudSyncSnapshot(phase: .current),
            remoteChangesError: nil
        ))
    }

    @Test("Store recovery does not start cloud sync")
    func recoveryBlocksCloudSync() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fixture.store.url)
        try await fixture.setCloudSyncEnabled()

        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        try await model.flushSave()

        #expect(model.storeRecovery != nil)
        #expect(await cloudSync.eventCount == 0)
    }

    @Test("A newer store stays in place until the user updates Obolo")
    func newerStoreRequiresUpdate() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.setCloudSyncEnabled()
        let newer = Data(#"{"version":2,"subscriptions":{"futureField":42}}"#.utf8)
        try newer.write(to: fixture.store.url)
        let backup = fixture.directory.appending(path: "backup.json")
        try DocumentStore.encode(fixture.document).write(to: backup)
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)

        await model.load()
        #expect(model.storeRecovery?.newerVersion?.version == 2)
        #expect(model.storeRecovery?.path == fixture.store.url)
        let shortcut = NextRenewalReader(
            store: fixture.store, today: fixture.now, calendar: fixture.calendar, locale: .current
        )
        #expect(await shortcut.read().message == model.storeRecovery?.error)
        #expect(throws: StoreDocument.NewerVersion.self) { try model.continueAfterRecovery() }
        await #expect(throws: StoreDocument.NewerVersion.self) { try await model.restore(from: backup) }
        try await model.flushSave()
        #expect(await cloudSync.eventCount == 0)
        #expect(RecoverySidecar.read(besideStoreAt: fixture.store.url) == nil)
        #expect(try Data(contentsOf: fixture.store.url) == newer)
    }

    /// The launch used to adopt the only other `*.json` beside a missing `obolo.json` as
    /// the store — a one-day migration from an earlier file name. After a quarantine on a
    /// Mac that has used iCloud sync, that file was `cloud-sync.json`: it decoded as an
    /// empty document, the load took the "file reads" branch and deleted the recovery
    /// note, and the banner was gone.
    @Test("A quarantined store stays in recovery beside the iCloud sync state")
    func recoverySurvivesBesideCloudSyncState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OboloAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = TestFixture(directory: AppPaths.supportDirectory(in: root))
        let storeURL = AppPaths.storeURL(in: root)
        #expect(fixture.store.url == storeURL)
        #expect(fixture.deviceStateStore.url == AppPaths.deviceStateURL(in: root))

        // What the support directory holds after last launch's quarantine: the sync
        // state, the device state, the moved-aside store, and the note about it.
        let cloudSyncState = AppPaths.cloudSyncStateURL(in: root)
        try CloudSyncStateStore(url: cloudSyncState).save(
            CloudSyncStateFile(baseDocument: SyncedDocument(document: fixture.document))
        )
        let cloudSyncBytes = try Data(contentsOf: cloudSyncState)
        try await fixture.setCloudSyncEnabled()
        let quarantined = fixture.directory.appending(path: "obolo.json.corrupt-20261125-090000")
        try Data("not json".utf8).write(to: quarantined)
        let note = RecoverySidecar(
            movedTo: quarantined,
            error: "Test error",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try note.write(besideStoreAt: storeURL)

        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        try await model.flushSave()

        #expect(model.storeRecovery?.path == quarantined)
        #expect(RecoverySidecar.read(besideStoreAt: storeURL) == note)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: cloudSyncState) == cloudSyncBytes)
        #expect(FileManager.default.fileExists(atPath: quarantined.path(percentEncoded: false)))
        #expect(await cloudSync.eventCount == 0)
    }

    @Test("A burst of edits starts one calendar sync with the newest document")
    func calendarSyncIsDebounced() async {
        let fixture = TestFixture(calendarSyncEnabled: true)
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let calendarSync = CalendarSyncSpy()
        model.calendarSync = calendarSync

        var subscription = fixture.subscription(name: "First name")
        model.add(subscription)
        subscription.name = "Final name"
        model.update(subscription)

        let syncedDocument = await calendarSync.nextDocument()
        #expect(syncedDocument.subscription(id: subscription.id)?.name == "Final name")
        try? await Task.sleep(for: .milliseconds(300))
        let callCount = await calendarSync.callCount
        #expect(callCount == 1)
    }

    @Test("Turning calendar sync off cancels a pending reconcile")
    func disablingCalendarSyncCancelsPendingWork() async {
        let fixture = TestFixture(calendarSyncEnabled: true)
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let calendarSync = CalendarSyncSpy()
        model.calendarSync = calendarSync

        model.add(fixture.subscription(name: "Pending"))
        model.settings.calendarSyncEnabled = false

        try? await Task.sleep(for: .milliseconds(350))
        #expect(await calendarSync.callCount == 0)
    }

    @Test("Recording an event identifier does not start calendar sync")
    func recordingCalendarIdentifierDoesNotReconcile() async throws {
        let fixture = TestFixture(calendarSyncEnabled: true)
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let calendarSync = CalendarSyncSpy()
        model.calendarSync = calendarSync
        let subscription = fixture.subscription(name: "Calendar row")
        model.add(subscription)
        _ = await calendarSync.nextDocument()

        model.recordCalendarEventIdentifier("event-1", for: subscription.id)
        try? await Task.sleep(for: .milliseconds(350))

        #expect(model.calendarEventIdentifier(for: subscription.id) == "event-1")
        #expect(await calendarSync.callCount == 1)

        try await model.flushSave()
        let savedState = try await fixture.deviceStateStore.load()
        #expect(savedState.calendarEventIdentifier(for: subscription.id) == "event-1")
    }

    /// The store as builds before 2026-08-26 wrote it, with this Mac's calendar values
    /// inside the portable document.
    private func legacyDeviceKeysStore(
        _ fixture: TestFixture,
        subscription: Subscription
    ) throws -> Data {
        var document = fixture.document
        document.subscriptions = [subscription]
        var json = try #require(
            try JSONSerialization.jsonObject(with: DocumentStore.encode(document)) as? [String: Any]
        )
        var rows = try #require(json["subscriptions"] as? [[String: Any]])
        rows[0]["calendarEventIdentifier"] = "legacy-event"
        json["subscriptions"] = rows
        var settings = try #require(json["settings"] as? [String: Any])
        settings["lastCalendarSyncAt"] = "2026-08-20T09:00:00Z"
        json["settings"] = settings
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test("Loading a store with old calendar values opens it and ignores them")
    func loadIgnoresLegacyCalendarValues() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        let subscription = fixture.subscription(name: "Legacy calendar row")
        let data = try legacyDeviceKeysStore(fixture, subscription: subscription)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try data.write(to: fixture.store.url)

        let model = fixture.makeModel()
        await model.load()

        #expect(model.storeRecovery == nil)
        #expect(model.subscription(subscription.id) == subscription)
        #expect(model.calendarEventIdentifier(for: subscription.id) == nil)
        #expect(model.lastCalendarSyncAt == nil)

        // The next save writes the document without the old keys.
        model.update(subscription)
        try await model.flushSave()
        let saved = String(decoding: try Data(contentsOf: fixture.store.url), as: UTF8.self)
        #expect(!saved.contains("calendarEventIdentifier"))
        #expect(!saved.contains("lastCalendarSyncAt"))
    }

    @Test("Restoring a backup with old calendar values keeps this Mac's values")
    func restoreIgnoresLegacyCalendarValues() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        let subscription = fixture.subscription(name: "Shared row")
        var current = fixture.document
        current.subscriptions = [subscription]
        let model = fixture.makeModel(document: current)
        model.recordCalendarEventIdentifier("this-mac-event", for: subscription.id)
        model.recordCalendarSync(at: fixture.day(2026, 8, 20))

        let backupURL = fixture.directory.appending(path: "other-mac.json")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try legacyDeviceKeysStore(fixture, subscription: subscription).write(to: backupURL)

        try await model.restore(from: backupURL)

        #expect(model.subscription(subscription.id) == subscription)
        #expect(model.calendarEventIdentifier(for: subscription.id) == "this-mac-event")
        #expect(model.lastCalendarSyncAt == fixture.day(2026, 8, 20))
    }

    @Test("Unreadable device state does not run calendar sync or replace the file")
    func unreadableDeviceStateStopsCalendarSync() async throws {
        let fixture = TestFixture(calendarSyncEnabled: true)
        defer { fixture.remove() }

        try await fixture.store.save(fixture.document)
        let unreadable = Data("not json".utf8)
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: true
        )
        try unreadable.write(to: fixture.deviceStateStore.url)

        let model = fixture.makeModel()
        let calendarSync = CalendarSyncSpy()
        model.calendarSync = calendarSync
        await model.load()
        try? await Task.sleep(for: .milliseconds(350))

        #expect(model.deviceStateError != nil)
        #expect(await calendarSync.callCount == 0)
        try await model.flushSave()
        #expect(try Data(contentsOf: fixture.deviceStateStore.url) == unreadable)
    }

    @Test("Loading an old paused row never invents a billing stop date")
    func loadKeepsLegacyBillingStopUnknown() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        var legacy = fixture.document
        var undated = fixture.subscription(name: "Old paused plan")
        undated.status = .paused
        undated.billingStoppedOn = nil
        // A cancelled row whose access already ran out: that day answers for the stop.
        var ended = fixture.subscription(name: "Old cancelled plan")
        ended.status = .cancelled
        ended.billingStoppedOn = nil
        ended.endsOn = BillingDay(isoDate: "2026-03-04")!
        legacy.subscriptions = [undated, ended]
        try await fixture.store.save(legacy)

        let model = fixture.makeModel()
        await model.load()

        // Unknown stays unknown: stamping today would invent charges the user never made.
        #expect(model.subscription(undated.id)?.billingStoppedOn == nil)
        #expect(model.ledger.summary(id: undated.id)?.paidSoFar == nil)
        #expect(model.subscription(ended.id)?.billingStoppedOn == BillingDay(isoDate: "2026-03-04")!)
    }

    @Test("Loading an old paused row cancels it on its last payment and saves the result")
    func loadConvertsPausedRow() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        var legacy = fixture.document
        var paused = fixture.subscription(name: "Old paused plan")
        paused.anchorDate = BillingDay(isoDate: "2026-03-10")!
        paused.status = .paused
        legacy.subscriptions = [paused]
        try await fixture.store.save(legacy)

        let model = fixture.makeModel()
        await model.load()

        // The model's day is 25 August, so the last monthly payment was on 10 August.
        let converted = try #require(model.subscription(paused.id))
        #expect(converted.status == .cancelled)
        #expect(converted.endsOn == BillingDay(isoDate: "2026-08-10")!)
        #expect(converted.billingStoppedOn == BillingDay(isoDate: "2026-08-10")!)

        try await model.flushSave()
        #expect(try await fixture.store.load().subscription(id: paused.id) == converted)
    }

    @Test("Restoring a backup with a paused row cancels it on the day it was paused")
    func restoreConvertsPausedRow() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        var paused = fixture.subscription(name: "Paused in a backup")
        paused.anchorDate = BillingDay(isoDate: "2026-03-10")!
        paused.status = .paused
        paused.billingStoppedOn = BillingDay(isoDate: "2026-06-01")!
        var backup = fixture.document
        backup.subscriptions = [paused]
        let backupURL = fixture.directory.appending(path: "old-backup.json")
        try await DocumentStore(url: backupURL).save(backup)

        let model = fixture.makeModel()
        try await model.restore(from: backupURL)

        let converted = try #require(model.subscription(paused.id))
        #expect(converted.status == .cancelled)
        #expect(converted.endsOn == BillingDay(isoDate: "2026-06-01")!)
        #expect(converted.billingStoppedOn == BillingDay(isoDate: "2026-06-01")!)

        try await model.flushSave()
        #expect(try await fixture.store.load().subscription(id: paused.id)?.status == .cancelled)
    }

    @Test("A paused row from iCloud is saved as cancelled and sent back corrected")
    func remotePausedRowIsConverted() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        try await fixture.store.save(fixture.document)
        try await fixture.setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        let model = fixture.makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()

        var paused = fixture.subscription(name: "Paused on another Mac")
        paused.anchorDate = BillingDay(isoDate: "2026-03-10")!
        paused.status = .paused
        var remoteStore = fixture.document
        remoteStore.subscriptions = [paused]
        let received = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document),
            remote: SyncedDocument(document: remoteStore)
        )
        let result = try #require(received)

        let converted = try #require(model.subscription(paused.id))
        #expect(converted.status == .cancelled)
        #expect(converted.endsOn == BillingDay(isoDate: "2026-08-10")!)
        #expect(converted.billingStoppedOn == BillingDay(isoDate: "2026-08-10")!)
        #expect(try await fixture.store.load().subscription(id: paused.id) == converted)
        // The merge sends the corrected record back to iCloud.
        #expect(result.changesForRemoteStore.changes == [
            .save(.subscription(SyncedSubscription(converted)))
        ])
        // Applying the merge rewrote nothing, so no extra save follows it.
        try? await Task.sleep(for: .milliseconds(350))
        #expect(await cloudSync.eventCount == 1)
    }

    @Test("A write keeps a current price date in the future — it is the announced rise")
    func addKeepsFutureCurrentPriceSince() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        // "From 1 October your plan is €18", entered in August: €12.99 since the first
        // payment, €18 from a day that has not arrived.
        let model = fixture.makeModel()
        var subscription = fixture.subscription(name: "Mail")
        subscription.anchorDate = BillingDay(isoDate: "2026-01-03")!
        subscription.price = Decimal(string: "18.00")!
        subscription.priceChanges = [
            PriceChange(
                effectiveFrom: BillingDay(isoDate: "2026-01-03")!,
                price: Decimal(string: "12.99")!,
                currency: "EUR"
            )
        ]
        subscription.currentPriceSince = BillingDay(isoDate: "2026-10-01")!

        model.add(subscription)

        let stored = try #require(model.subscription(subscription.id))
        #expect(stored.currentPriceSince == BillingDay(isoDate: "2026-10-01")!)
        // Today is still the old price: the rise answers from its own day, not before.
        #expect(
            stored.price(on: fixture.now, calendar: fixture.calendar).price
                == Decimal(string: "12.99")!
        )
        #expect(
            stored.price(on: fixture.day(2026, 10, 1), calendar: fixture.calendar).price
                == Decimal(string: "18.00")!
        )

        let summary = try #require(model.ledger.summary(id: subscription.id))
        #expect(summary.price == Decimal(string: "12.99")!)
        #expect(summary.announcedPriceChange?.price == Decimal(string: "18.00")!)
        #expect(summary.announcedPriceChange?.effectiveFrom == BillingDay(isoDate: "2026-10-01")!)
        // The next payment is 3 September, before the rise, so it costs the old price.
        #expect(summary.nextCharge?.price == Decimal(string: "12.99")!)

        try await model.flushSave()
    }

    @Test("Synced history survives a reload, an edit and a duplicate west of the date line")
    func recordedHistorySurvivesLocalWrites() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var pacific = fixture.calendar
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(BillingDay(fixture.now, calendar: pacific).isoDate == "2026-08-24")
        let history = [PriceChange(effectiveFrom: BillingDay(isoDate: "2026-08-25")!, price: 5, currency: "EUR")]
        var plan = fixture.subscription(name: "Mail")
        plan.priceChanges = history
        plan.currentPriceSince = BillingDay(isoDate: "2026-09-01")
        var remote = fixture.document
        remote.subscriptions = [plan]
        let cloudSync = FakeCloudSyncService()
        try await fixture.setCloudSyncEnabled()
        let model = AppModel(
            store: fixture.store, calendar: pacific, clock: { [now = fixture.now] in now },
            cloudSyncService: cloudSync, autoload: false
        )
        await model.load()
        _ = await cloudSync.nextEvent()
        let received = await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: fixture.document), remote: SyncedDocument(document: remote)
        )
        #expect(try #require(received).changesForRemoteStore.changes.isEmpty)
        #expect(model.subscription(plan.id)?.priceChanges == history)
        await model.load()
        var edited = try #require(model.subscription(plan.id))
        #expect(edited.priceChanges == history)
        edited.name = "Renamed"
        model.update(edited)
        model.presentDuplicate(plan.id)
        let draft = try #require(duplicateCopy(model))
        let copy = model.add(draft, copyingHistoryFrom: draft)
        try await model.flushSave()
        let saved = try await fixture.store.load()
        #expect(saved.subscription(id: plan.id)?.priceChanges == history)
        #expect(saved.subscription(id: copy.id)?.priceChanges == history)
    }

    @Test("A write refuses a price history entry in the future")
    func updateDropsFutureHistory() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let subscription = fixture.subscription(name: "Music")
        model.add(subscription)

        var edited = try #require(model.subscription(subscription.id))
        edited.priceChanges = [
            PriceChange(effectiveFrom: BillingDay(isoDate: "2025-03-01")!, price: 9, currency: "EUR"),
            // A mistyped year. Below every settled charge, it would answer for all of them.
            PriceChange(effectiveFrom: BillingDay(isoDate: "2027-03-01")!, price: 4, currency: "EUR")
        ]
        model.update(edited)

        let stored = try #require(model.subscription(subscription.id))
        #expect(stored.priceChanges.map(\.effectiveFrom) == [BillingDay(isoDate: "2025-03-01")!])
        try await model.flushSave()
    }

    @Test("An update of a row that is not in the list adds nothing")
    func updateOfMissingRowAddsNothing() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let kept = fixture.subscription(name: "Kept")
        let deleted = fixture.subscription(name: "Deleted")
        model.add(kept)
        model.add(deleted)
        model.delete(deleted.id)
        let before = model.document

        var edited = deleted
        edited.name = "Edited after the delete"
        model.update(edited)

        #expect(model.document == before)
        #expect(model.subscription(deleted.id) == nil)
        try await model.flushSave()
    }

    @Test("Importing a currency the table cannot convert asks for a rate")
    func importRequestsMissingRates() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let fetcher = GatedRateFetcher()
        let model = fixture.makeModel(rateService: fetcher)

        let preview = try model.previewImport(data: Data(fixture.dollarRowCSV.utf8))
        model.importCSV(preview, createMissingCategories: true)

        await fetcher.waitForCalls(1)
        await fetcher.release()
        // One request, not one per imported row.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fetcher.calls == 1)
        try await model.flushSave()
    }

    @Test("Importing rows in the base currency asks for nothing")
    func importInBaseCurrencyAsksForNothing() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let fetcher = GatedRateFetcher()
        let model = fixture.makeModel(rateService: fetcher)

        let preview = try model.previewImport(data: Data(fixture.euroRowCSV.utf8))
        model.importCSV(preview, createMissingCategories: true)

        await fetcher.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fetcher.calls == 0)
        try await model.flushSave()
    }

    @Test("Restore refreshes an old automatic rate")
    func restoreRefreshesOldAutomaticRate() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let fetcher = GatedRateFetcher()
        let model = fixture.makeModel(rateService: fetcher)
        var backup = fixture.documentWithDollarPlan()
        backup.rates.applyAutomatic(
            ["USD": Decimal(string: "0.80")!],
            asOf: fixture.day(2026, 7, 1),
            checkedAt: fixture.day(2026, 7, 1)
        )
        let backupURL = fixture.directory.appending(path: "old-rates.json")
        try await DocumentStore(url: backupURL).save(backup)

        try await model.restore(from: backupURL)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fetcher.calls == 1)
        await fetcher.release()
        try await model.flushSave()
    }

    @Test("Restore keeps a fresh automatic rate")
    func restoreKeepsFreshAutomaticRate() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let fetcher = GatedRateFetcher()
        let model = fixture.makeModel(rateService: fetcher)
        var backup = fixture.documentWithDollarPlan()
        backup.rates.applyAutomatic(
            ["USD": Decimal(string: "0.80")!],
            asOf: fixture.now,
            checkedAt: fixture.now
        )
        let backupURL = fixture.directory.appending(path: "fresh-rates.json")
        try await DocumentStore(url: backupURL).save(backup)

        try await model.restore(from: backupURL)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fetcher.calls == 0)
        await fetcher.release()
        try await model.flushSave()
    }

    @Test("A forced refresh that arrives during a refresh runs again after it")
    func forcedRefreshRunsAfterInFlight() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let fetcher = GatedRateFetcher()
        let model = fixture.makeModel(document: fixture.documentWithDollarPlan(), rateService: fetcher)

        let first = Task { await model.refreshRates() }
        await fetcher.waitForCalls(1)
        // Arrives while the first request is still at the network: it must not vanish
        // behind it, which is what left every automatic rate blank after a base change.
        let second = Task { await model.refreshRates(force: true) }
        await fetcher.release()
        await first.value
        await second.value

        #expect(await fetcher.calls == 2)
    }

    @Test("Two automatic refreshes at the same time make one request")
    func concurrentAutomaticRefreshesCoalesce() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let fetcher = GatedRateFetcher()
        let model = fixture.makeModel(document: fixture.documentWithDollarPlan(), rateService: fetcher)

        let first = Task { await model.refreshRates() }
        await fetcher.waitForCalls(1)
        let second = Task { await model.refreshRates() }
        await fetcher.release()
        await first.value
        await second.value

        #expect(await fetcher.calls == 1)
    }

    @Test("A form prefill changes editor state but does not change the document")
    func prefillDoesNotSave() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }

        let model = fixture.makeModel()
        let original = model.document
        let prefill = SubscriptionFormPrefill(
            name: "Video",
            price: Decimal(string: "8.99"),
            currency: "EUR",
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-09-03")!
        )

        model.presentAdd(prefill: prefill)

        let sheet = try #require(model.activeSheet)
        #expect(sheet.content == .add(prefill))
        #expect(model.document == original)

        model.dismissSheet(sheet.id)
        #expect(model.activeSheet == nil)
        model.presentAdd()

        #expect(model.activeSheet?.content == .add(.init()))
        #expect(model.document == original)
    }

    @Test("Deleting the row in the edit form closes the form, and Undo does not reopen it")
    func deletingEditedRowClosesForm() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Edited plan")
        var document = fixture.document
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)
        model.section = .all
        model.selectSubscriptionRow(subscription.id)
        model.presentEdit(subscription.id)
        #expect(model.isFormPresented)

        model.delete(subscription.id)

        #expect(model.activeSheet == nil)
        #expect(!model.isFormPresented)
        #expect(model.canUndoDelete)

        model.undoDelete()

        #expect(model.subscription(subscription.id) == subscription)
        #expect(model.selectedID == subscription.id)
        #expect(model.activeSheet == nil)
        #expect(!model.isFormPresented)
        try await model.flushSave()
    }

    @Test("An iCloud merge that removes the edited row closes the form")
    func remoteRemovalClosesEditForm() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Shared plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription]
        let model = try await fixture.makeSyncingModel(document: baseStore)

        model.presentEdit(subscription.id)
        #expect(model.isFormPresented)

        let applied = await fixture.removeRemotely(subscription.id, from: baseStore)
        #expect(applied)

        #expect(model.subscription(subscription.id) == nil)
        #expect(model.activeSheet == nil)
        #expect(!model.isFormPresented)
    }

    @Test("An iCloud merge that removes a row being reactivated closes the form")
    func remoteRemovalClosesReactivationForm() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var subscription = fixture.subscription(name: "Cancelled plan")
        subscription.status = .cancelled
        subscription.billingStoppedOn = BillingDay(isoDate: "2026-08-22")!
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription]
        let model = try await fixture.makeSyncingModel(document: baseStore)

        model.setStatus(.active, for: subscription.id)
        #expect(model.isFormPresented)

        let applied = await fixture.removeRemotely(subscription.id, from: baseStore)
        #expect(applied)

        #expect(model.subscription(subscription.id) == nil)
        #expect(model.activeSheet == nil)
        #expect(!model.isFormPresented)
    }

    @Test("An iCloud merge that removes the open subscription closes its detail")
    func remoteRemovalClosesDetail() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Shared plan")
        let other = fixture.subscription(name: "Other plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription, other]
        let model = try await fixture.makeSyncingModel(document: baseStore)
        model.section = .all
        model.selectSubscriptionRow(subscription.id)
        #expect(model.isShowingSubscriptionDetail)

        let applied = await fixture.removeRemotely(subscription.id, from: baseStore)
        #expect(applied)

        #expect(model.selectedID == nil)
        #expect(!model.isShowingSubscriptionDetail)
        #expect(model.section == .all)
    }

    @Test("An iCloud merge that keeps the edited row leaves the form open")
    func remoteChangeElsewhereKeepsEditForm() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Edited plan")
        let other = fixture.subscription(name: "Other plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription, other]
        let model = try await fixture.makeSyncingModel(document: baseStore)
        model.section = .all
        model.selectSubscriptionRow(subscription.id)
        model.presentEdit(subscription.id)

        let applied = await fixture.removeRemotely(other.id, from: baseStore)
        #expect(applied)

        #expect(model.activeSheet?.content == .edit(subscription.id, focus: .name))
        #expect(model.selectedID == subscription.id)
        #expect(model.isShowingSubscriptionDetail)
    }

    @Test("An iCloud merge that removes the row in the delete alert closes the alert")
    func remoteRemovalClosesDeleteAlert() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Shared plan")
        let other = fixture.subscription(name: "Other plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription, other]
        let model = try await fixture.makeSyncingModel(document: baseStore)
        model.pendingDelete = subscription.id

        let applied = await fixture.removeRemotely(subscription.id, from: baseStore)
        #expect(applied)

        #expect(model.pendingDelete == nil)
        // The remote removal is not a local delete: there is nothing to undo.
        #expect(!model.canUndoDelete)
    }

    @Test("An iCloud merge that removes the row in a waiting cancel prompt clears it")
    func remoteRemovalClearsCancelPrompt() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Shared plan")
        let other = fixture.subscription(name: "Other plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription, other]
        let model = try await fixture.makeSyncingModel(document: baseStore)
        model.section = .all
        model.requestCancel(subscription.id)
        #expect(model.cancelPromptID == subscription.id)

        let applied = await fixture.removeRemotely(subscription.id, from: baseStore)
        #expect(applied)

        #expect(model.cancelPromptID == nil)
        #expect(model.selectedID == nil)
    }

    @Test("An iCloud merge that removes another row leaves the delete alert and cancel prompt")
    func remoteRemovalElsewhereKeepsDialogs() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Kept plan")
        let other = fixture.subscription(name: "Other plan")
        var baseStore = fixture.document
        baseStore.subscriptions = [subscription, other]
        let model = try await fixture.makeSyncingModel(document: baseStore)
        model.section = .all
        model.requestCancel(subscription.id)
        model.pendingDelete = subscription.id

        let applied = await fixture.removeRemotely(other.id, from: baseStore)
        #expect(applied)

        #expect(model.pendingDelete == subscription.id)
        #expect(model.cancelPromptID == subscription.id)
        #expect(model.selectedID == subscription.id)
    }

    @Test("Mark cancelled for a row that is not in the list asks nothing")
    func requestCancelForMissingRowAsksNothing() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.section = .all

        model.requestCancel(UUID())

        #expect(model.cancelPromptID == nil)
        #expect(model.selectedID == nil)
    }

    @Test("A delete confirmed in the alert still deletes, closes the alert and offers Undo")
    func confirmedDeleteStillOffersUndo() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Deleted plan")
        let other = fixture.subscription(name: "Other plan")
        var document = fixture.document
        document.subscriptions = [subscription, other]
        let model = fixture.makeModel(document: document)
        model.section = .all
        model.selectSubscriptionRow(subscription.id)
        model.pendingDelete = subscription.id

        // What the alert's Delete button does.
        model.delete(subscription.id)

        #expect(model.subscription(subscription.id) == nil)
        #expect(model.pendingDelete == nil)
        #expect(model.canUndoDelete)
        #expect(model.lastDeletedName == "Deleted plan")

        model.undoDelete()

        #expect(model.document.subscriptions == [subscription, other])
        #expect(model.selectedID == subscription.id)
        #expect(model.pendingDelete == nil)
        try await model.flushSave()
    }

    @Test("A restore that brings the deleted row back drops the Undo offer")
    func restoreOfDeletedRowDropsUndo() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Restored plan")
        var document = fixture.document
        document.subscriptions = [subscription]
        let backupURL = fixture.directory.appending(path: "with-row.json")
        try await DocumentStore(url: backupURL).save(document)
        let model = fixture.makeModel(document: document)

        model.delete(subscription.id)
        #expect(model.canUndoDelete)

        try await model.restore(from: backupURL)

        #expect(model.subscription(subscription.id) != nil)
        #expect(!model.canUndoDelete)
        // Undo has nothing left to put back: the row is in the list once.
        model.undoDelete()
        #expect(model.document.subscriptions.filter { $0.id == subscription.id }.count == 1)
        try await model.flushSave()
    }

    @Test("Edit for a row that is not in the list does not open the form")
    func editForMissingRowDoesNotOpen() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.presentEdit(UUID())

        #expect(model.activeSheet == nil)
        #expect(!model.isFormPresented)
    }

    @Test("Missing-logo count keeps manual icons and finds a restored missing file")
    func missingLogoCountHandlesRestoredFiles() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        var initial = fixture.subscription(name: "Initial")
        initial.website = "initial.example"
        var symbol = fixture.subscription(name: "Symbol")
        symbol.website = "symbol.example"
        symbol.icon = .symbol("star")
        var emoji = fixture.subscription(name: "Emoji")
        emoji.website = "emoji.example"
        emoji.icon = .emoji("🎬")
        var restored = fixture.subscription(name: "Restored")
        restored.website = "restored.example"
        restored.icon = .image("\(restored.id.uuidString).png")
        document.subscriptions = [initial, symbol, emoji, restored]

        let model = AppModel(
            store: fixture.store,
            document: document,
            calendar: fixture.calendar,
            clock: { [now = fixture.now] in now },
            autoload: false
        )

        #expect(model.missingLogoCount == 2)
    }

    @Test("A click on a calendar day selects it, a second click clears it, and no detail opens")
    func calendarDayToggles() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.subscriptions = [fixture.subscription(name: "Calendar plan")]
        let model = fixture.makeModel(document: document)
        model.section = .calendar
        let day = fixture.day(2026, 11, 12)

        model.selectCalendarDay(day)
        #expect(model.selectedCalendarDay == day)
        #expect(!model.isShowingSubscriptionDetail)

        model.selectCalendarDay(day)
        #expect(model.selectedCalendarDay == nil)

        model.selectCalendarDay(day)
        model.selectCalendarDay(fixture.day(2026, 11, 13))
        #expect(model.selectedCalendarDay == fixture.day(2026, 11, 13))
    }

    @Test("A row selection opens its detail at once, moves with the row, and an empty one closes it")
    func rowSelectionDrivesDetail() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        let first = fixture.subscription(name: "First plan")
        let second = fixture.subscription(name: "Second plan")
        document.subscriptions = [first, second]
        let model = fixture.makeModel(document: document)
        model.section = .all

        // No wait for the double-click interval: the first click is the reveal.
        model.selectSubscriptionRow(first.id)
        #expect(model.selectedID == first.id)
        #expect(model.isShowingSubscriptionDetail)

        model.selectSubscriptionRow(second.id)
        #expect(model.selectedID == second.id)
        #expect(model.isShowingSubscriptionDetail)

        // Clicking below the rows clears the selection and closes it.
        model.selectSubscriptionRow(nil)
        #expect(model.selectedID == nil)
        #expect(!model.isShowingSubscriptionDetail)
    }

    @Test("Undo of a delete opens the row's detail again, even after Back")
    func undoDeleteOpensDetail() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        let subscription = fixture.subscription(name: "Restored plan")
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)
        model.section = .all
        model.selectSubscriptionRow(subscription.id)
        model.closeSubscriptionDetail()

        // Back, then a delete and its Undo: the row comes back selected, and its detail
        // shows, whatever was clicked before.
        model.delete(subscription.id)
        #expect(!model.isShowingSubscriptionDetail)
        model.undoDelete()
        #expect(model.selectedID == subscription.id)
        #expect(model.isShowingSubscriptionDetail)
    }

    @Test("Changing views clears both kinds of selection")
    func changingViewsClearsSelection() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        let subscription = fixture.subscription(name: "Selected plan")
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)

        model.section = .all
        #expect(model.selectedID == nil)
        #expect(!model.isShowingSubscriptionDetail)

        model.selectSubscriptionRow(subscription.id)
        #expect(model.isShowingSubscriptionDetail)

        model.section = .upcoming
        #expect(model.selectedID == nil)
        #expect(model.selectedCalendarDay == nil)
        #expect(!model.isShowingSubscriptionDetail)

        model.section = .overview
        model.openHomeSubscriptionDetail(subscription.id)
        #expect(model.isShowingSubscriptionDetail)

        model.section = .calendar
        #expect(model.selectedID == nil)
        #expect(!model.isShowingSubscriptionDetail)

        model.selectCalendarDay(fixture.day(2026, 11, 12))
        model.section = .overview
        #expect(model.selectedCalendarDay == nil)
        #expect(!model.isShowingSubscriptionDetail)
    }

    @Test("Back from a Home legend detail preserves the chart and selected month")
    func closeHomeSubscriptionDetail() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Historical plan")
        var document = fixture.document
        document.subscriptions = [subscription]
        document.settings.spendView = .subscription
        let model = fixture.makeModel(document: document)
        let month = MonthRange.start(of: model.today, offsetByMonths: -1, calendar: fixture.calendar)
        model.showMonth(containing: month)

        model.openHomeSubscriptionDetail(subscription.id)
        #expect(model.selectedID == subscription.id)
        #expect(model.isShowingSubscriptionDetail)
        #expect(model.section == .overview)
        #expect(model.shownMonth == month)

        model.closeSubscriptionDetail()
        #expect(model.selectedID == nil)
        #expect(!model.isShowingSubscriptionDetail)
        #expect(model.section == .overview)
        #expect(model.document.settings.spendView == .subscription)
        #expect(model.shownMonth == month)
    }

    @Test("Home opens details only on explicit legend activation for an existing subscription")
    func homeSelectionRequiresLegendActivation() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Selected plan")
        var document = fixture.document
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)

        model.selectSubscriptionRow(subscription.id)
        #expect(!model.isShowingSubscriptionDetail)
        model.openHomeSubscriptionDetail(UUID())
        #expect(!model.isShowingSubscriptionDetail)

        model.openHomeSubscriptionDetail(subscription.id)
        #expect(model.isShowingSubscriptionDetail)
        model.delete(subscription.id)
        #expect(model.selectedID == nil)
        #expect(!model.isShowingSubscriptionDetail)

        model.undoDelete()
        #expect(model.selectedID == subscription.id)
        #expect(!model.isShowingSubscriptionDetail)
    }

    @Test("A selected id with no row in the document shows no detail")
    func missingRowShowsNoDetail() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.section = .all

        model.selectedID = UUID()
        #expect(!model.isShowingSubscriptionDetail)
    }

    @Test("Opening and closing a subscription leaves the document alone and saves nothing")
    func selectionWritesNothing() async {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        let subscription = fixture.subscription(name: "Viewed plan")
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)
        model.section = .all
        let before = model.document

        model.selectSubscriptionRow(subscription.id)
        model.closeSubscriptionDetail()
        model.selectSubscriptionRow(subscription.id)
        model.selectSubscriptionRow(nil)
        model.section = .calendar
        model.selectCalendarDay(fixture.day(2026, 11, 12))
        model.selectCalendarDay(fixture.day(2026, 11, 12))
        model.section = .overview
        model.openHomeSubscriptionDetail(subscription.id)
        model.closeSubscriptionDetail()

        #expect(model.document == before)
        // Past the 250 ms save debounce: nothing was scheduled, so no file appears.
        try? await Task.sleep(for: .milliseconds(350))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path(percentEncoded: false)))
    }

    @Test("A selection made before the document loads survives only if the loaded document has the row")
    func selectionBeforeLoad() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Notified plan")
        var stored = fixture.document
        stored.subscriptions = [subscription]
        try await fixture.store.save(stored)

        // A notification click during a cold launch: the row is not in the initial
        // document yet, so nothing shows until the store answers.
        let model = fixture.makeModel()
        model.section = .all
        model.selectSubscriptionRow(subscription.id)
        #expect(!model.isShowingSubscriptionDetail)
        await model.load()
        #expect(model.selectedID == subscription.id)
        #expect(model.isShowingSubscriptionDetail)

        let other = fixture.makeModel()
        other.section = .all
        other.selectSubscriptionRow(UUID())
        await other.load()
        #expect(other.selectedID == nil)
        #expect(!other.isShowingSubscriptionDetail)
    }

    @Test("No reminder suppresses advance and same-day notifications and survives storage")
    func noReminderScheduling() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        for daysAhead in [0, 3] {
            var subscription = fixture.subscription(name: "Quiet plan")
            let next = fixture.calendar.date(byAdding: .day, value: daysAhead, to: fixture.now)!
            subscription.anchorDate = BillingDay(next, calendar: fixture.calendar)
            subscription.reminderLeadDays = daysAhead == 0 ? 0 : 2
            var document = fixture.document
            document.settings.notificationTime = DateComponents(hour: 9, minute: 0)
            document.subscriptions = [subscription]
            let enabled = Ledger(document: document, today: fixture.now, calendar: fixture.calendar)
            #expect(!NotificationScheduler.requests(for: enabled).isEmpty)
            subscription.reminderLeadDays = Subscription.noReminder
            let data = try JSONEncoder().encode(subscription)
            let restored = try JSONDecoder().decode(Subscription.self, from: data)
            #expect(!restored.remindersEnabled)
            document.subscriptions = [restored]
            let disabled = Ledger(document: document, today: fixture.now, calendar: fixture.calendar)
            #expect(NotificationScheduler.requests(for: disabled).isEmpty)
        }
    }

    // MARK: Duplicate
    //
    // The detail's ⋮, a row's menu and ⌘D all call `presentDuplicate`: the detail and
    // the row menu with the row's id, ⌘D with the selection.

    private func duplicateCopy(_ model: AppModel) -> Subscription? {
        if case .duplicate(let copy)? = model.activeSheet?.content { return copy }
        return nil
    }

    /// The subscription the form would add. Supplying the same ID lets tests compare
    /// drafts from separate requests.
    private func duplicateDraft(_ copy: Subscription, id: UUID? = nil) throws -> Subscription {
        var copy = copy
        if let id { copy.id = id }
        return try #require(SubscriptionDraft(copy, isNew: false).subscription())
    }

    @Test("Every Duplicate opens the same pre-filled form and writes nothing")
    func duplicateDoorsOpenTheSameForm() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let original = fixture.richSubscription()
        var document = fixture.document
        document.subscriptions = [original]
        let model = fixture.makeModel(document: document)

        // The detail's ⋮ and a row's menu.
        model.presentDuplicate(original.id)
        let sheet = try #require(model.activeSheet)
        let copy = try #require(duplicateCopy(model))
        #expect(copy.id != original.id)
        #expect(copy.name == "Streaming copy")
        #expect(copy.createdAt == fixture.now)
        #expect(copy.icon == original.icon)
        #expect(model.document.subscriptions == [original])
        let fromRow = try duplicateDraft(copy)

        // ⌘D, with the row selected.
        model.dismissSheet(sheet.id)
        #expect(model.activeSheet == nil)
        model.selectedID = original.id
        model.presentDuplicate(model.selectedID)
        let fromMenuBar = try duplicateDraft(#require(duplicateCopy(model)), id: copy.id)
        #expect(fromMenuBar == fromRow)
        #expect(model.document.subscriptions == [original])
    }

    @Test("Duplicate with no row, or a row that is not in the list, opens nothing")
    func duplicateWithoutRowDoesNothing() {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.subscriptions = [fixture.subscription(name: "Kept")]
        let model = fixture.makeModel(document: document)

        model.presentDuplicate(nil)
        #expect(model.activeSheet == nil)

        model.presentDuplicate(UUID())
        #expect(model.activeSheet == nil)
        #expect(model.document.subscriptions.count == 1)
    }

    @Test("Closing the duplicate form clears the request and adds no row")
    func duplicateCancelLeavesNothing() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let original = fixture.richSubscription()
        var document = fixture.document
        document.subscriptions = [original]
        let model = fixture.makeModel(document: document)

        model.presentDuplicate(original.id)
        let sheet = try #require(model.activeSheet)
        model.dismissSheet(sheet.id)
        #expect(model.activeSheet == nil)
        #expect(model.document.subscriptions == [original])

        // The next New is the plain form, not the copy again.
        model.presentAdd()
        #expect(model.activeSheet?.content == .add(.init()))
    }

    @Test("Add from the duplicate form adds the copy once, selects it, and keeps the original")
    func duplicateSaveAddsCopyOnce() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let original = fixture.richSubscription()
        var document = fixture.document
        document.subscriptions = [original]
        let model = fixture.makeModel(document: document)

        model.presentDuplicate(original.id)
        let sheet = try #require(model.activeSheet)
        let copy = try #require(duplicateCopy(model))
        let added = model.add(try duplicateDraft(copy), copyingHistoryFrom: copy)
        model.dismissSheet(sheet.id)

        #expect(model.document.subscriptions.count == 2)
        #expect(model.document.subscriptions.filter { $0.id == copy.id }.count == 1)
        #expect(model.selectedID == copy.id)
        #expect(model.subscription(original.id) == original)

        // Everything but the id, the name and the day it was added comes from the
        // original: price and price history, cycle, dates, category, status, reminder,
        // notes, website, manage page, tint and icon.
        var expected = original
        expected.id = copy.id
        expected.name = "Streaming copy"
        expected.createdAt = fixture.now
        #expect(added == expected)
        #expect(model.subscription(copy.id) == expected)
        try await model.flushSave()
    }

    @Test("A duplicate gets its own copy of the logo on Add, and none on Cancel")
    func duplicateCopiesLogoOnAdd() async throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = try duplicateCopiesLogoWithoutSuspending(fixture)
        try await model.flushSave()
    }

    /// The body of the logo test. `LogoStore.shared` is one per process, so it points at
    /// the fixture's folder only while nothing else on the main actor can run: from here
    /// to the return, with no suspension.
    private func duplicateCopiesLogoWithoutSuspending(_ fixture: TestFixture) throws -> AppModel {
        let icons = fixture.directory.appending(path: "Icons", directoryHint: .isDirectory)
        let previous = LogoStore.shared.directory
        LogoStore.configureSharedDirectory(icons)
        defer { LogoStore.configureSharedDirectory(previous) }
        func files() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: icons.path(percentEncoded: false))) ?? [])
        }

        var original = fixture.richSubscription()
        let logo = try #require(fixture.logoPNG())
        let filename = try LogoStore.shared.store(imageData: logo, for: original.id)
        try LogoStore.shared.storeDark(imageData: logo, besideLogo: filename)
        original.icon = .image(filename)
        var document = fixture.document
        document.subscriptions = [original]
        let model = fixture.makeModel(document: document)
        let originalFiles = files()
        #expect(originalFiles == [filename, LogoStore.darkFilename(for: filename)])

        // Cancel: the form showed the original's logo, and no file was written.
        model.presentDuplicate(original.id)
        #expect(duplicateCopy(model)?.icon == .image(filename))
        model.dismissSheet(try #require(model.activeSheet).id)
        #expect(files() == originalFiles)

        // Add: the copy has its own file, and its own dark version.
        model.presentDuplicate(original.id)
        let copy = try #require(duplicateCopy(model))
        let added = model.add(try duplicateDraft(copy), copyingHistoryFrom: copy)
        let copyFile = LogoStore.filename(for: copy.id)
        #expect(added.icon == .image(copyFile))
        #expect(files() == originalFiles.union([copyFile, LogoStore.darkFilename(for: copyFile)]))
        #expect(model.subscription(original.id)?.icon == .image(filename))

        // A logo file that has gone missing leaves the copy on the initial.
        model.presentDuplicate(original.id)
        LogoStore.shared.delete(filename: filename)
        let orphan = try #require(duplicateCopy(model))
        #expect(model.add(try duplicateDraft(orphan), copyingHistoryFrom: orphan).icon == .initial)
        return model
    }
}

private actor SchedulerSpy: SchedulerHook {
    private var ledgers: [Ledger] = []
    private var waiters: [CheckedContinuation<Ledger, Never>] = []
    private var pauseFirstPass: Bool
    private var firstPass: CheckedContinuation<Void, Never>?
    private(set) var completedLedgers: [Ledger] = []

    init(pauseFirstPass: Bool = false) {
        self.pauseFirstPass = pauseFirstPass
    }

    func reschedule(ledger: Ledger) async {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: ledger)
        } else {
            ledgers.append(ledger)
        }
        if pauseFirstPass {
            pauseFirstPass = false
            await withCheckedContinuation { firstPass = $0 }
        }
        completedLedgers.append(ledger)
    }

    func finishFirstPass() {
        firstPass?.resume()
        firstPass = nil
    }

    func nextLedger() async -> Ledger {
        if !ledgers.isEmpty { return ledgers.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor CalendarSyncSpy: CalendarSyncHook {
    private var documents: [StoreDocument] = []
    private var waiters: [CheckedContinuation<StoreDocument, Never>] = []
    private var totalCalls = 0

    func reconcile(document: StoreDocument) async {
        totalCalls += 1
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: document)
        } else {
            documents.append(document)
        }
    }

    func nextDocument() async -> StoreDocument {
        if !documents.isEmpty { return documents.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    var callCount: Int { totalCalls }
}

@MainActor
final class TestFixture {
    let calendar: Calendar
    let now: Date
    let directory: URL
    let store: DocumentStore
    let deviceStateStore: DeviceStateStore
    let document: StoreDocument

    init(calendarSyncEnabled: Bool = false, directory: URL? = nil) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        self.now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))!
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appending(path: "OboloAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.store = DocumentStore(url: self.directory.appending(path: "obolo.json"))
        self.deviceStateStore = DeviceStateStore(url: self.directory.appending(path: DeviceStateStore.fileName))

        var document = StoreDocument.initial()
        document.settings.calendarSyncEnabled = calendarSyncEnabled
        self.document = document
    }

    func makeModel(
        document: StoreDocument? = nil,
        rateService: any RateFetching = RateService(),
        cloudSyncService: any CloudSyncService = DisabledCloudSyncService()
    ) -> AppModel {
        AppModel(
            store: store,
            deviceStateStore: deviceStateStore,
            document: document ?? self.document,
            calendar: calendar,
            clock: { [now] in now },
            rateService: rateService,
            cloudSyncService: cloudSyncService,
            autoload: false
        )
    }

    /// Makes the store's folder read-only, so a save fails, or writable again.
    func setStoreWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555],
            ofItemAtPath: directory.path(percentEncoded: false)
        )
    }

    func setCloudSyncEnabled() async throws {
        var state = DeviceState.initial()
        state.cloudSyncEnabled = true
        try await deviceStateStore.save(state)
    }

    /// The service `makeSyncingModel` started, for `removeRemotely`.
    private var cloudSync: FakeCloudSyncService?

    /// A loaded model with `document` on disk and a running sync session.
    func makeSyncingModel(document: StoreDocument) async throws -> AppModel {
        try await store.save(document)
        try await setCloudSyncEnabled()
        let cloudSync = FakeCloudSyncService()
        self.cloudSync = cloudSync
        let model = makeModel(cloudSyncService: cloudSync)
        await model.load()
        _ = await cloudSync.nextEvent()
        return model
    }

    /// Delivers a remote batch in which another Mac deleted one row of `base`. Returns
    /// whether the model applied it.
    func removeRemotely(_ id: Subscription.ID, from base: StoreDocument) async -> Bool {
        guard let cloudSync else { return false }
        var remote = base
        remote.subscriptions.removeAll { $0.id == id }
        return await cloudSync.sendRemoteChanges(
            base: SyncedDocument(document: base),
            remote: SyncedDocument(document: remote)
        ) != nil
    }

    func subscription(name: String) -> Subscription {
        Subscription(
            name: name,
            categoryID: document.fallbackCategoryID,
            price: Decimal(string: "12.99")!,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-09-03")!,
            createdAt: now
        )
    }

    /// A row with something in every field Duplicate carries: a price history, a
    /// category of its own, a reminder, notes, a website, a manage page and a tint.
    func richSubscription() -> Subscription {
        let category = document.categories.first { $0.id != document.fallbackCategoryID }?.id
            ?? document.fallbackCategoryID
        return Subscription(
            name: "Streaming",
            tint: .red,
            categoryID: category,
            price: Decimal(string: "12.99")!,
            currency: "EUR",
            priceChanges: [PriceChange(effectiveFrom: BillingDay(isoDate: "2026-03-03")!, price: Decimal(string: "9.99")!, currency: "EUR")],
            currentPriceSince: BillingDay(isoDate: "2026-06-03")!,
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-03-03")!,
            isEstimate: true,
            reminderLeadDays: 5,
            manageURL: URL(string: "https://streaming.example/account"),
            website: "streaming.example",
            notes: "Family plan",
            createdAt: day(2026, 3, 1)
        )
    }

    /// A 64-pixel PNG, large enough for `LogoStore` to keep.
    func logoPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A document with one USD row under the EUR base, so a refresh has something to ask
    /// for. The fetcher answers with a currency the document does not use, so USD keeps
    /// needing a rate and a second pass is a real request rather than a no-op.
    func documentWithDollarPlan() -> StoreDocument {
        var document = self.document
        document.settings.autoUpdateRates = true
        var plan = subscription(name: "Dollar plan")
        plan.currency = "USD"
        document.subscriptions = [plan]
        return document
    }

    /// A one-row import that puts a currency the EUR base has no rate for into the list.
    let dollarRowCSV = """
    Name,Cost,Currency,Billing cycle
    Dollar plan,10.00,USD,Monthly
    """

    /// The same file in the base currency, which needs no rate at all.
    let euroRowCSV = """
    Name,Cost,Currency,Billing cycle
    Euro plan,10.00,EUR,Monthly
    """

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor FakeCloudSyncService: CloudSyncService {
    enum Event: Equatable {
        case started(SyncedDocument)
        case saved(SyncedDocument)
        case resolved(SyncRecordID, SyncConflictChoice)
        case approved(SyncedDocument)
        case replayed
        case stopped
    }

    private var events: [Event] = []
    /// The last batch the model refused, kept as the real service keeps it.
    private var refusedBatch: (base: SyncedDocument, remote: SyncedDocument)?
    private(set) var replayCount = 0
    /// What the model returned for the last replay.
    private(set) var lastReplayResult: SyncMergeResult?
    /// Runs at the start of each replay, before the batch reaches the model.
    private var beforeReplay: (@Sendable () async -> Void)?
    private var waiters: [CheckedContinuation<Event, Never>] = []
    private var totalEvents = 0
    private var receiveRemoteChanges: CloudSyncRemoteChangeHandler?
    private var reportStatus: CloudSyncStatusHandler?
    private let startStatus: CloudSyncSnapshot
    private let backupsDirectory: URL?
    /// The files in `backupsDirectory` when `approveCurrentAccount` ran.
    private(set) var backupsWhenApproved: [String]?

    init(
        startStatus: CloudSyncSnapshot = CloudSyncSnapshot(phase: .current),
        backupsDirectory: URL? = nil
    ) {
        self.startStatus = startStatus
        self.backupsDirectory = backupsDirectory
    }

    func start(
        localDocument: SyncedDocument,
        receiveRemoteChanges: @escaping CloudSyncRemoteChangeHandler,
        reportStatus: @escaping CloudSyncStatusHandler
    ) async {
        self.receiveRemoteChanges = receiveRemoteChanges
        self.reportStatus = reportStatus
        await reportStatus(startStatus)
        record(.started(localDocument))
    }

    func localDocumentDidSave(_ snapshot: CloudSyncLocalSnapshot) async {
        record(.saved(snapshot.document))
    }

    func resolveConflict(
        _ recordID: SyncRecordID,
        choice: SyncConflictChoice
    ) async {
        record(.resolved(recordID, choice))
    }

    func approveCurrentAccount(localDocument: SyncedDocument) async {
        if let backupsDirectory {
            backupsWhenApproved = (try? FileManager.default.contentsOfDirectory(
                atPath: backupsDirectory.path(percentEncoded: false)
            )) ?? []
        }
        record(.approved(localDocument))
    }

    /// Offers the refused batch again, as `CloudKitSyncService` does, and records the
    /// call after the model answered.
    func replayRemoteChanges() async {
        replayCount += 1
        await beforeReplay?()
        if let refusedBatch, let receiveRemoteChanges {
            lastReplayResult = await receiveRemoteChanges(refusedBatch.base, refusedBatch.remote)?.result
            if lastReplayResult != nil { self.refusedBatch = nil }
        }
        record(.replayed)
    }

    func stop() async { record(.stopped) }

    func nextEvent() async -> Event {
        if !events.isEmpty { return events.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    var eventCount: Int { totalEvents }

    func sendRemoteChanges(
        base: SyncedDocument,
        remote: SyncedDocument
    ) async -> SyncMergeResult? {
        guard let receiveRemoteChanges else { return nil }
        let result = await receiveRemoteChanges(base, remote)
        refusedBatch = result == nil ? (base, remote) : nil
        return result?.result
    }

    func sendStatus(_ snapshot: CloudSyncSnapshot) async {
        await reportStatus?(snapshot)
    }

    func setBeforeReplay(_ action: @escaping @Sendable () async -> Void) {
        beforeReplay = action
    }

    private func record(_ event: Event) {
        totalEvents += 1
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }
}

/// A rate service that holds every request at the network until `release()`, and counts
/// them. Later requests pass straight through once released.
actor GatedRateFetcher: RateFetching {
    private(set) var calls = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fetch(base: String, symbols: [String]) async throws -> (asOf: Date, ratesToBase: [String: Decimal]) {
        calls += 1
        if !open {
            await withCheckedContinuation { waiters.append($0) }
        }
        return (asOf: Date(timeIntervalSince1970: 1_700_000_000), ratesToBase: ["GBP": Decimal(string: "1.15")!])
    }

    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForCalls(_ count: Int) async {
        while calls < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("Calendar event ownership")
struct CalendarEventOwnershipTests {
    @Test("Cleanup recognises the ownership marker, alone or after the user's notes")
    func recognisesManagedEvents() {
        #expect(CalendarSync.hasManagedMarker(in: CalendarSync.marker))
        #expect(CalendarSync.hasManagedMarker(in: "Personal notes\n\n" + CalendarSync.marker))
    }

    @Test("An event with the marker from before the rename is no longer claimed")
    func leavesPreRenameEventsAlone() {
        let preRename = "Renewals manages this event. Make changes in the Renewals app."
        #expect(!CalendarSync.hasManagedMarker(in: preRename))
        #expect(!CalendarSync.hasManagedMarker(in: "Personal notes\n\n" + preRename))
    }

    @Test("Cleanup does not claim unrelated events or infer ownership from names")
    func ignoresUnrelatedEvents() {
        #expect(!CalendarSync.hasManagedMarker(in: nil))
        #expect(!CalendarSync.hasManagedMarker(in: ""))
        #expect(!CalendarSync.hasManagedMarker(in: "Renewals: Netflix and iCloud"))
        #expect(!CalendarSync.hasManagedMarker(in: "Check Obolo for the next payment"))
    }
}
