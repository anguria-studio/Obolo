import Foundation
import Testing
@testable import OboloCore

struct SyncMergeTests {
    @Test func changesAreStableAndRecordBased() {
        let firstID = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-4000-A000-000000000002")!
        let old = Self.document(
            subscriptions: [Self.subscription(id: secondID, name: "Old")],
            rates: ["USD": SyncedManualRate(value: 0.9, updatedAt: Fixed.today)]
        )
        var new = Self.document(
            subscriptions: [Self.subscription(id: firstID, name: "New")],
            rates: ["GBP": SyncedManualRate(value: 1.1, updatedAt: Fixed.today)]
        )
        new.preferences.defaultReminderLeadDays = 5

        let changes = SyncChangeSet(from: old, to: new).changes

        #expect(changes.map(\.recordID) == [
            .manualRate("GBP"),
            .manualRate("USD"),
            .preferences,
            .subscription(firstID),
            .subscription(secondID)
        ])
        #expect(changes[0] == .save(.manualRate(
            currency: "GBP",
            rate: SyncedManualRate(value: 1.1, updatedAt: Fixed.today)
        )))
        #expect(changes[1] == .delete(.manualRate("USD")))
        #expect(changes[4] == .delete(.subscription(secondID)))
    }

    @Test func aChangeSetKeepsTheLatestChangeForEachRecord() {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let saved = SyncChange.save(.subscription(Self.subscription(id: id, name: "Old")))
        let deleted = SyncChange.delete(.subscription(id))

        let result = SyncChangeSet(changes: [saved, deleted, saved, deleted])

        #expect(result.changes == [deleted])
    }

    @Test func editsToDifferentRecordsBothSurvive() throws {
        let firstID = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-4000-A000-000000000002")!
        let base = Self.document(subscriptions: [
            Self.subscription(id: firstID, name: "First"),
            Self.subscription(id: secondID, name: "Second")
        ])
        var local = base
        local.subscriptions[0].name = "Local first"
        var remote = base
        remote.subscriptions[1].price = 25

        let result = try Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.isEmpty)
        #expect(result.document.subscriptions.first { $0.id == firstID }?.name == "Local first")
        #expect(result.document.subscriptions.first { $0.id == secondID }?.price == 25)
        #expect(result.changesForLocalStore.changes.map(\.recordID) == [.subscription(secondID)])
        #expect(result.changesForRemoteStore.changes.map(\.recordID) == [.subscription(firstID)])
    }

    @Test func differentEditsToOneRecordCreateAConflict() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let base = Self.document(subscriptions: [Self.subscription(id: id, name: "Base")])
        var local = base
        local.subscriptions[0].name = "Local"
        var remote = base
        remote.subscriptions[0].name = "Remote"

        let result = try Self.merge(base: base, local: local, remote: remote)
        let conflict = try #require(result.conflicts.first)

        #expect(result.document.subscriptions[0].name == "Local")
        #expect(conflict.recordID == .subscription(id))
        #expect(conflict.base == .subscription(base.subscriptions[0]))
        #expect(conflict.local == .subscription(local.subscriptions[0]))
        #expect(conflict.remote == .subscription(remote.subscriptions[0]))
        #expect(result.changesForLocalStore.changes.isEmpty)
        #expect(result.changesForRemoteStore.changes.isEmpty)
        #expect(conflict.resolution(.remote) == .save(.subscription(remote.subscriptions[0])))
    }

    @Test func theSameEditOnBothSidesNeedsNoAction() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let base = Self.document(subscriptions: [Self.subscription(id: id, name: "Base")])
        var local = base
        local.subscriptions[0].name = "Same edit"
        let remote = local

        let result = try Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.isEmpty)
        #expect(result.document.subscriptions[0].name == "Same edit")
        #expect(result.changesForLocalStore.changes.isEmpty)
        #expect(result.changesForRemoteStore.changes.isEmpty)
    }

    @Test func anAcceptedLocalDeletionDoesNotReturn() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let base = Self.document(subscriptions: [Self.subscription(id: id, name: "Delete me")])
        var local = base
        local.subscriptions = []

        let result = try Self.merge(base: base, local: local, remote: base)

        #expect(result.conflicts.isEmpty)
        #expect(result.document.subscriptions.isEmpty)
        #expect(result.changesForLocalStore.changes.isEmpty)
        #expect(result.changesForRemoteStore.changes == [.delete(.subscription(id))])
    }

    @Test func anEditAndADeletionNeedAChoice() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let base = Self.document(subscriptions: [Self.subscription(id: id, name: "Base")])
        var local = base
        local.subscriptions[0].name = "Edited locally"
        var remote = base
        remote.subscriptions = []

        let result = try Self.merge(base: base, local: local, remote: remote)
        let conflict = try #require(result.conflicts.first)

        #expect(conflict.base == .subscription(base.subscriptions[0]))
        #expect(conflict.local == .subscription(local.subscriptions[0]))
        #expect(conflict.remote == nil)
        #expect(result.document.subscriptions[0].name == "Edited locally")
        #expect(conflict.resolution(.remote) == .delete(.subscription(id)))
        #expect(conflict.resolution(.local) == .save(.subscription(local.subscriptions[0])))
    }

    @Test func concurrentCreatesNeedAChoice() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let base = Self.document()
        var local = base
        local.subscriptions = [Self.subscription(id: id, name: "Local")]
        var remote = base
        remote.subscriptions = [Self.subscription(id: id, name: "Remote")]

        let result = try Self.merge(base: base, local: local, remote: remote)

        let conflict = try #require(result.conflicts.first)
        #expect(conflict.base == nil)
        #expect(conflict.local == .subscription(local.subscriptions[0]))
        #expect(conflict.remote == .subscription(remote.subscriptions[0]))
        #expect(result.document.subscriptions[0].name == "Local")
    }

    @Test func categoryDeletionRepairsReferences() throws {
        let workID = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!
        let subscriptionID = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let fallback = Self.fallbackCategory
        let work = OboloCore.Category(id: workID, name: "Work", tint: .violet, sortOrder: 1)
        let base = Self.document(
            subscriptions: [Self.subscription(
                id: subscriptionID,
                name: "Work plan",
                categoryID: workID
            )],
            categories: [fallback, work]
        )
        var remote = base
        remote.categories = [fallback]

        let result = try Self.merge(base: base, local: base, remote: remote)

        #expect(result.conflicts.isEmpty)
        #expect(result.document.categories == [fallback])
        #expect(result.document.subscriptions[0].categoryID == OboloCore.Category.fallbackID)
        #expect(result.changesForRemoteStore.changes.map(\.recordID) == [
            .subscription(subscriptionID)
        ])
    }

    @Test func equalCategoryOrdersUseStableIdentifiers() throws {
        let firstID = UUID(uuidString: "A0000000-0000-4000-A000-000000000001")!
        let secondID = UUID(uuidString: "B0000000-0000-4000-A000-000000000002")!
        let first = OboloCore.Category(
            id: firstID,
            name: "Zulu",
            tint: .blue,
            sortOrder: 0
        )
        let second = OboloCore.Category(
            id: secondID,
            name: "Alpha",
            tint: .green,
            sortOrder: 0
        )
        let base = Self.document(categories: [second, first])

        let result = try Self.merge(base: base, local: base, remote: base)

        #expect(result.document.categories.map { $0.id } == [firstID, secondID])
        #expect(result.document.categories.map { $0.sortOrder } == [0, 1])
    }

    @Test func changesToDifferentManualRatesBothSurvive() throws {
        let base = Self.document()
        var local = base
        local.manualRates["USD"] = SyncedManualRate(value: 0.9, updatedAt: Fixed.today)
        var remote = base
        remote.manualRates["GBP"] = SyncedManualRate(value: 1.1, updatedAt: Fixed.today)

        let result = try Self.merge(base: base, local: local, remote: remote)

        #expect(result.conflicts.isEmpty)
        #expect(result.document.manualRates.keys.sorted() == ["GBP", "USD"])
    }

    @Test func mergeNormalizesPortableData() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let base = Self.document()
        var malformed = Self.subscription(
            id: id,
            name: "Normalize",
            categoryID: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-AFFF-FFFFFFFFFFFF")!
        )
        malformed.currency = " usd "
        malformed.website = "https://WWW.Example.com/path"
        malformed.currentPriceSince = Fixed.billingDay(2027, 1, 1)
        malformed.priceChanges = [
            PriceChange(effectiveFrom: Fixed.billingDay(2027, 2, 1), price: 30, currency: "usd"),
            PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 1), price: 20, currency: "usd")
        ]
        var local = base
        local.subscriptions = [malformed]
        local.manualRates = [
            "EUR": SyncedManualRate(value: 2, updatedAt: Fixed.today),
            "GBP": SyncedManualRate(value: -1, updatedAt: Fixed.today),
            "usd": SyncedManualRate(value: 0.9, updatedAt: Fixed.today)
        ]

        let result = try Self.merge(base: base, local: local, remote: base)
        let subscription = try #require(result.document.subscriptions.first)

        #expect(subscription.currency == "USD")
        #expect(subscription.website == "example.com")
        // A current price dated ahead survives the merge: it is the announced rise. The
        // *entry* dated ahead does not — see `PriceHistoryTests`.
        #expect(subscription.currentPriceSince == Fixed.billingDay(2027, 1, 1))
        #expect(subscription.priceChanges.map(\.effectiveFrom) == [Fixed.billingDay(2026, 1, 1)])
        #expect(subscription.categoryID == OboloCore.Category.fallbackID)
        #expect(result.document.manualRates.keys.sorted() == ["USD"])
    }

    /// The last session sent the record with the exact date it had in memory. After a
    /// relaunch this Mac reads the record from the store file, which keeps whole seconds.
    @Test("A date the store file rounded does not turn the other Mac's edit into a conflict")
    func storedDatePrecisionIsNotAnEdit() throws {
        let id = UUID(uuidString: "10000000-0000-4000-A000-000000000001")!
        let subscription = Subscription(
            id: id,
            name: "Base",
            categoryID: OboloCore.Category.fallbackID,
            price: 10,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 1),
            createdAt: Fixed.today.addingTimeInterval(0.437)
        )
        let sent = Self.document(subscriptions: [SyncedSubscription(subscription)])
        let reloaded = try DocumentStore.decode(DocumentStore.encode(
            StoreDocument(subscriptions: [subscription])
        )).subscriptions[0]
        #expect(reloaded.createdAt != subscription.createdAt)
        let local = Self.document(subscriptions: [SyncedSubscription(reloaded)])
        var remote = sent
        remote.subscriptions[0].name = "Renamed elsewhere"

        let result = try Self.merge(base: sent, local: local, remote: remote)

        #expect(result.conflicts.isEmpty)
        #expect(result.document.subscriptions[0].name == "Renamed elsewhere")
        #expect(result.document.subscriptions[0].createdAt == reloaded.createdAt)
        #expect(result.changesForLocalStore.changes.map(\.recordID) == [.subscription(id)])
    }

    @Test("Two Macs that enter the same rate in the same second agree, and different rates still conflict")
    func sameSecondRateEdits() throws {
        let base = Self.document(rates: ["USD": SyncedManualRate(value: 0.9, updatedAt: Fixed.today)])
        let second = Fixed.today.addingTimeInterval(3_600)
        var local = base
        local.manualRates["USD"] = SyncedManualRate(value: 0.92, updatedAt: second.addingTimeInterval(0.1))
        var remote = base
        remote.manualRates["USD"] = SyncedManualRate(value: 0.92, updatedAt: second.addingTimeInterval(0.8))

        let same = try Self.merge(base: base, local: local, remote: remote)

        #expect(same.conflicts.isEmpty)
        #expect(same.document.manualRates["USD"] == SyncedManualRate(value: 0.92, updatedAt: second))

        remote.manualRates["USD"] = SyncedManualRate(value: 0.95, updatedAt: second.addingTimeInterval(0.8))
        let different = try Self.merge(base: base, local: local, remote: remote)

        #expect(different.conflicts.map(\.recordID) == [.manualRate("USD")])
        #expect(different.document.manualRates["USD"]?.value == 0.92)
    }

    @Test("An older preferences record with another due-soon window is no change, upload or conflict")
    func olderWindowIsNotAnEdit() throws {
        let local = Self.document()
        var older = local
        older.preferences.dueSoonWindowDays = 21

        #expect(SyncChangeSet(from: local, to: older).changes.isEmpty)
        #expect(SyncChangeSet(from: older, to: local).changes.isEmpty)

        // The other Mac's record arrives against this Mac's base, and against a base
        // that a session with that Mac stored.
        for base in [local, older] {
            let result = try Self.merge(base: base, local: local, remote: older)

            #expect(result.conflicts.isEmpty)
            #expect(result.changesForLocalStore.changes.isEmpty)
            #expect(result.changesForRemoteStore.changes.isEmpty)
            #expect(result.document.preferences.dueSoonWindowDays == Settings.paymentHighlightWindowDays)
        }
    }

    @Test("A real preferences edit still syncs either way, and edits on both sides still conflict")
    func realPreferencesEditsStillSync() throws {
        var olderBase = Self.document()
        olderBase.preferences.dueSoonWindowDays = 21

        // This Mac changes the reminder lead: the change goes up, with the window this
        // build writes.
        var local = Self.document()
        local.preferences.defaultReminderLeadDays = 5
        let sent = try Self.merge(base: olderBase, local: local, remote: olderBase)
        #expect(sent.conflicts.isEmpty)
        #expect(sent.changesForLocalStore.changes.isEmpty)
        let upload = try #require(sent.changesForRemoteStore.changes.first)
        #expect(sent.changesForRemoteStore.changes.count == 1)
        guard case .save(.preferences(let record)) = upload else {
            Issue.record("Expected a preferences save, got \(upload)")
            return
        }
        #expect(record.preferences.defaultReminderLeadDays == 5)
        #expect(record.preferences.dueSoonWindowDays == Settings.paymentHighlightWindowDays)

        // An older Mac changes the base currency: the change comes down.
        var remote = olderBase
        remote.preferences.baseCurrency = "GBP"
        let received = try Self.merge(base: Self.document(), local: Self.document(), remote: remote)
        #expect(received.conflicts.isEmpty)
        #expect(received.changesForLocalStore.changes.map(\.recordID) == [.preferences])
        #expect(received.changesForRemoteStore.changes.isEmpty)
        #expect(received.document.preferences.baseCurrency == "GBP")

        // Both sides change the base currency to different values.
        var both = Self.document()
        both.preferences.baseCurrency = "USD"
        let conflicted = try Self.merge(base: olderBase, local: both, remote: remote)
        #expect(conflicted.conflicts.map(\.recordID) == [.preferences])
        #expect(conflicted.document.preferences.baseCurrency == "USD")
    }

    @Test func aNewerSchemaStopsTheMerge() {
        let base = Self.document()
        var remote = base
        remote.schemaVersion = SyncedDocument.currentSchemaVersion + 1

        #expect(throws: SyncMergeError.unsupportedSchemaVersion(
            found: SyncedDocument.currentSchemaVersion + 1,
            supported: SyncedDocument.currentSchemaVersion
        )) {
            try Self.merge(base: base, local: base, remote: remote)
        }
    }

    private static let fallbackCategory = OboloCore.Category(
        id: OboloCore.Category.fallbackID,
        name: OboloCore.Category.fallbackName,
        tint: .gray,
        sortOrder: 0
    )

    private static func subscription(
        id: UUID,
        name: String,
        categoryID: OboloCore.Category.ID = OboloCore.Category.fallbackID
    ) -> SyncedSubscription {
        SyncedSubscription(Subscription(
            id: id,
            name: name,
            categoryID: categoryID,
            price: 10,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 1),
            createdAt: Fixed.day(2026, 1, 1)
        ))
    }

    private static func document(
        subscriptions: [SyncedSubscription] = [],
        categories: [OboloCore.Category] = [fallbackCategory],
        rates: [String: SyncedManualRate] = [:]
    ) -> SyncedDocument {
        SyncedDocument(
            subscriptions: subscriptions,
            categories: categories,
            preferences: SyncedPreferences(
                baseCurrency: "EUR",
                dueSoonWindowDays: 7,
                defaultReminderLeadDays: 2
            ),
            manualRates: rates
        )
    }

    private static func merge(
        base: SyncedDocument,
        local: SyncedDocument,
        remote: SyncedDocument
    ) throws -> SyncMergeResult {
        try SyncMerge.merge(
            base: base,
            local: local,
            remote: remote,
            today: Fixed.today,
            calendar: Fixed.calendar
        )
    }
}
