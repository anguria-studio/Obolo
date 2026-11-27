import Foundation

/// Two incompatible changes to one record.
///
/// A missing value means that side deleted the record.
public struct SyncConflict: Codable, Hashable, Sendable, Identifiable {
    public var recordID: SyncRecordID
    public var base: SyncRecord?
    public var local: SyncRecord?
    public var remote: SyncRecord?

    public var id: SyncRecordID { recordID }

    public init(
        recordID: SyncRecordID,
        base: SyncRecord?,
        local: SyncRecord?,
        remote: SyncRecord?
    ) {
        self.recordID = recordID
        self.base = base
        self.local = local
        self.remote = remote
    }

    /// The change that applies the selected side.
    public func resolution(_ choice: SyncConflictChoice) -> SyncChange {
        let selected = choice == .local ? local : remote
        if let selected { return .save(selected) }
        return .delete(recordID)
    }
}

public enum SyncConflictChoice: String, Codable, Hashable, Sendable {
    case local
    case remote
}

/// The result of one three-way merge.
public struct SyncMergeResult: Codable, Hashable, Sendable {
    /// The local working copy after all safe remote changes.
    public var document: SyncedDocument
    /// Same-record changes that need a user decision.
    public var conflicts: [SyncConflict]
    /// Changes that the app must write to its local document.
    public var changesForLocalStore: SyncChangeSet
    /// Safe local changes that the app can send to CloudKit.
    public var changesForRemoteStore: SyncChangeSet

    public init(
        document: SyncedDocument,
        conflicts: [SyncConflict],
        changesForLocalStore: SyncChangeSet,
        changesForRemoteStore: SyncChangeSet
    ) {
        self.document = document
        self.conflicts = conflicts.sorted { $0.recordID < $1.recordID }
        self.changesForLocalStore = changesForLocalStore
        self.changesForRemoteStore = changesForRemoteStore
    }
}

public enum SyncMergeError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// A deterministic three-way merge for sync records.
public enum SyncMerge {
    public static func merge(
        base: SyncedDocument,
        local: SyncedDocument,
        remote: SyncedDocument,
        today: Date,
        calendar: Calendar
    ) throws -> SyncMergeResult {
        try validateSchema(base.schemaVersion)
        try validateSchema(local.schemaVersion)
        try validateSchema(remote.schemaVersion)

        let normalizedBase = normalize(base, today: today, calendar: calendar)
        let normalizedLocal = normalize(local, today: today, calendar: calendar)
        let normalizedRemote = normalize(remote, today: today, calendar: calendar)
        let baseRecords = normalizedBase.recordMap
        let localRecords = normalizedLocal.recordMap
        let remoteRecords = normalizedRemote.recordMap
        let ids = Set(baseRecords.keys)
            .union(localRecords.keys)
            .union(remoteRecords.keys)
            .sorted()

        var mergedRecords: [SyncRecordID: SyncRecord] = [:]
        var conflicts: [SyncConflict] = []

        for id in ids {
            let baseValue = baseRecords[id]
            let localValue = localRecords[id]
            let remoteValue = remoteRecords[id]

            if localValue == remoteValue {
                mergedRecords[id] = localValue
            } else if localValue == baseValue {
                mergedRecords[id] = remoteValue
            } else if remoteValue == baseValue {
                mergedRecords[id] = localValue
            } else {
                // Keep the local working value until the user resolves the conflict.
                mergedRecords[id] = localValue
                conflicts.append(SyncConflict(
                    recordID: id,
                    base: baseValue,
                    local: localValue,
                    remote: remoteValue
                ))
            }
        }

        let merged = normalize(
            document(from: mergedRecords),
            today: today,
            calendar: calendar
        )
        let outputRecords = merged.recordMap
        let conflictIDs = Set(conflicts.map(\.recordID))

        return SyncMergeResult(
            document: merged,
            conflicts: conflicts,
            changesForLocalStore: SyncChangeSet(changes: SyncChangeSet.changes(
                from: local.recordMap,
                to: outputRecords,
                excluding: conflictIDs
            )),
            changesForRemoteStore: SyncChangeSet(changes: SyncChangeSet.changes(
                from: remote.recordMap,
                to: outputRecords,
                excluding: conflictIDs
            ))
        )
    }

    private static func validateSchema(_ version: Int) throws {
        guard version <= SyncedDocument.currentSchemaVersion else {
            throw SyncMergeError.unsupportedSchemaVersion(
                found: version,
                supported: SyncedDocument.currentSchemaVersion
            )
        }
    }

    private static func document(
        from records: [SyncRecordID: SyncRecord]
    ) -> SyncedDocument {
        var subscriptions: [SyncedSubscription] = []
        var categories: [Category] = []
        var manualRates: [String: SyncedManualRate] = [:]
        var preferencesRecord: SyncedPreferencesRecord?

        for id in records.keys.sorted() {
            guard let record = records[id] else { continue }
            switch record {
            case .subscription(let value): subscriptions.append(value)
            case .category(let value): categories.append(value)
            case .preferences(let value): preferencesRecord = value
            case .manualRate(let currency, let rate):
                manualRates[Subscription.normalizedCurrency(currency)] = rate
            }
        }

        let fallbackPreferences = SyncedPreferences(
            baseCurrency: "EUR",
            dueSoonWindowDays: 7,
            defaultReminderLeadDays: 2
        )
        return SyncedDocument(
            schemaVersion: preferencesRecord?.schemaVersion
                ?? SyncedDocument.currentSchemaVersion,
            subscriptions: subscriptions,
            categories: categories,
            preferences: preferencesRecord?.preferences ?? fallbackPreferences,
            manualRates: manualRates
        )
    }

    private static func normalize(
        _ document: SyncedDocument,
        today: Date,
        calendar: Calendar
    ) -> SyncedDocument {
        // The retired `dueSoonWindowDays` goes out as this build writes it.
        let preferences = SyncedPreferences(
            baseCurrency: document.preferences.baseCurrency,
            defaultReminderLeadDays: document.preferences.defaultReminderLeadDays
        )

        var categoriesByID: [Category.ID: Category] = [:]
        for category in document.categories {
            categoriesByID[category.id] = category
        }
        if categoriesByID.isEmpty {
            categoriesByID[Category.fallbackID] = Category(
                id: Category.fallbackID,
                name: Category.fallbackName,
                tint: .gray,
                sortOrder: 0
            )
        }
        var categories = Array(categoriesByID.values).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        for index in categories.indices {
            categories[index].sortOrder = index
        }

        let categoryIDs = Set(categories.map(\.id))
        let fallbackID = categories.first(where: { $0.id == Category.fallbackID })?.id
            ?? categories.first(named: Category.fallbackName)?.id
            ?? categories[0].id
        let latestHistoryDay = BillingDay.latestWorldwide(at: today)
        var subscriptionsByID: [Subscription.ID: SyncedSubscription] = [:]
        for synced in document.subscriptions {
            // A paused record from an older copy merges as cancelled. The merge reports
            // the difference from the raw remote record, so the corrected record goes
            // back to iCloud.
            var subscription = synced.subscription
                .droppingFutureHistory(after: latestHistoryDay)
                .subscription
                .resolvingLegacyPause(today: today, calendar: calendar)
            if !categoryIDs.contains(subscription.categoryID) {
                subscription.categoryID = fallbackID
            }
            // Compared as the store file keeps dates. A record that an earlier session
            // sent with an exact date then equals the same record read back from disk.
            // A remote record with an exact date merges with whole seconds, and goes
            // back to iCloud corrected.
            subscriptionsByID[subscription.id] = SyncedSubscription(subscription).atStoredPrecision
        }
        let subscriptions = subscriptionsByID.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }

        var manualRates: [String: SyncedManualRate] = [:]
        for currency in document.manualRates.keys.sorted() {
            guard let rate = document.manualRates[currency], rate.value > 0 else { continue }
            let code = Subscription.normalizedCurrency(currency)
            guard code != preferences.baseCurrency else { continue }
            manualRates[code] = rate.atStoredPrecision
        }

        return SyncedDocument(
            schemaVersion: document.schemaVersion,
            subscriptions: subscriptions,
            categories: categories,
            preferences: preferences,
            manualRates: manualRates
        )
    }
}
