import Foundation

/// The stable identity of one CloudKit record.
public enum SyncRecordID: Codable, Hashable, Sendable, Comparable {
    case subscription(UUID)
    case category(UUID)
    case preferences
    case manualRate(String)

    /// A stable value for sorting changes and conflicts.
    public var sortKey: String {
        switch self {
        case .subscription(let id): "subscription:\(id.uuidString.lowercased())"
        case .category(let id): "category:\(id.uuidString.lowercased())"
        case .preferences: "preferences"
        case .manualRate(let currency):
            "manual-rate:\(Subscription.normalizedCurrency(currency))"
        }
    }

    public static func < (lhs: SyncRecordID, rhs: SyncRecordID) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

/// The synced value for one record.
public enum SyncRecord: Codable, Hashable, Sendable {
    case subscription(SyncedSubscription)
    case category(Category)
    case preferences(SyncedPreferencesRecord)
    case manualRate(currency: String, rate: SyncedManualRate)

    public var id: SyncRecordID {
        switch self {
        case .subscription(let value): .subscription(value.id)
        case .category(let value): .category(value.id)
        case .preferences: .preferences
        case .manualRate(let currency, _):
            .manualRate(Subscription.normalizedCurrency(currency))
        }
    }
}

/// The preferences record and its independent sync schema version.
public struct SyncedPreferencesRecord: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var preferences: SyncedPreferences

    public init(
        schemaVersion: Int = SyncedDocument.currentSchemaVersion,
        preferences: SyncedPreferences
    ) {
        self.schemaVersion = schemaVersion
        self.preferences = preferences
    }
}

/// One save or deletion in a local sync queue.
public enum SyncChange: Codable, Hashable, Sendable {
    case save(SyncRecord)
    case delete(SyncRecordID)

    public var recordID: SyncRecordID {
        switch self {
        case .save(let record): record.id
        case .delete(let id): id
        }
    }
}

/// A stable list of changes between two projections.
public struct SyncChangeSet: Codable, Hashable, Sendable {
    public var changes: [SyncChange]

    public init(changes: [SyncChange]) {
        var latestByID: [SyncRecordID: SyncChange] = [:]
        for change in changes {
            latestByID[change.recordID] = change
        }
        self.changes = latestByID.keys.sorted().compactMap { latestByID[$0] }
    }

    public init(from old: SyncedDocument, to new: SyncedDocument) {
        self.init(changes: Self.changes(from: old.recordMap, to: new.recordMap))
    }

    static func changes(
        from old: [SyncRecordID: SyncRecord],
        to new: [SyncRecordID: SyncRecord],
        excluding excludedIDs: Set<SyncRecordID> = []
    ) -> [SyncChange] {
        let ids = Set(old.keys).union(new.keys).subtracting(excludedIDs).sorted()
        return ids.compactMap { id in
            let previous = old[id]
            let current = new[id]
            guard previous != current else { return nil }
            if let current { return .save(current) }
            return .delete(id)
        }
    }
}

extension SyncedDocument {
    /// One value for each record identity.
    public var records: [SyncRecord] {
        let recordsByID = recordMap
        return recordsByID.keys.sorted().compactMap { recordsByID[$0] }
    }

    /// The same records indexed by identity for merging and upload decisions.
    public var recordMap: [SyncRecordID: SyncRecord] {
        var result: [SyncRecordID: SyncRecord] = [:]
        for subscription in subscriptions {
            let record = SyncRecord.subscription(subscription)
            result[record.id] = record
        }
        for category in categories {
            let record = SyncRecord.category(category)
            result[record.id] = record
        }
        let preferencesRecord = SyncRecord.preferences(SyncedPreferencesRecord(
            schemaVersion: schemaVersion,
            preferences: preferences
        ))
        result[preferencesRecord.id] = preferencesRecord
        for currency in manualRates.keys.sorted() {
            guard let rate = manualRates[currency] else { continue }
            let record = SyncRecord.manualRate(currency: currency, rate: rate)
            result[record.id] = record
        }
        return result
    }

    /// Applies one remote batch without changing records that the batch does not name.
    public func applying(_ changeSet: SyncChangeSet) -> SyncedDocument {
        var result = self

        for change in changeSet.changes {
            switch change {
            case .save(let record):
                result.apply(record)
            case .delete(let id):
                result.remove(id)
            }
        }
        return result
    }

    private mutating func apply(_ record: SyncRecord) {
        switch record {
        case .subscription(let value):
            subscriptions.removeAll { $0.id == value.id }
            subscriptions.append(value)
            subscriptions.sort { $0.id.uuidString < $1.id.uuidString }
        case .category(let value):
            categories.removeAll { $0.id == value.id }
            categories.append(value)
            categories.sort {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .preferences(let value):
            schemaVersion = value.schemaVersion
            preferences = value.preferences
        case .manualRate(let currency, let rate):
            manualRates[Subscription.normalizedCurrency(currency)] = rate
        }
    }

    private mutating func remove(_ id: SyncRecordID) {
        switch id {
        case .subscription(let value):
            subscriptions.removeAll { $0.id == value }
        case .category(let value):
            categories.removeAll { $0.id == value }
        case .preferences:
            // A synced projection always has preferences. A server-side deletion resets
            // them to stable defaults, and the next merge can upload the selected value.
            schemaVersion = SyncedDocument.currentSchemaVersion
            preferences = SyncedPreferences(
                baseCurrency: "EUR",
                dueSoonWindowDays: 7,
                defaultReminderLeadDays: 2
            )
        case .manualRate(let currency):
            manualRates.removeValue(forKey: Subscription.normalizedCurrency(currency))
        }
    }
}
