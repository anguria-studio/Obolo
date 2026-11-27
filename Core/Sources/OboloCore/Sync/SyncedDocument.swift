import Foundation

/// The data that Obolo can send to another device.
///
/// This type is separate from `StoreDocument`. Thus, a new device-only field cannot
/// enter a CloudKit record only because the local store contains it.
public struct SyncedDocument: Codable, Hashable, Sendable {
    /// This version is independent of `StoreDocument.version`.
    public var schemaVersion: Int
    public var subscriptions: [SyncedSubscription]
    public var categories: [Category]
    public var preferences: SyncedPreferences
    public var manualRates: [String: SyncedManualRate]

    public init(
        schemaVersion: Int = SyncedDocument.currentSchemaVersion,
        subscriptions: [SyncedSubscription],
        categories: [Category],
        preferences: SyncedPreferences,
        manualRates: [String: SyncedManualRate]
    ) {
        self.schemaVersion = schemaVersion
        self.subscriptions = subscriptions
        self.categories = categories
        self.preferences = preferences
        self.manualRates = manualRates
    }

    /// Dates are held as the store file keeps them (`DocumentStore.storedDate`), so the
    /// projection of a document in memory equals the projection of the same document
    /// read back from disk.
    public init(document: StoreDocument) {
        schemaVersion = SyncedDocument.currentSchemaVersion
        subscriptions = document.subscriptions.map { SyncedSubscription($0).atStoredPrecision }
        categories = document.categories
        let projectedPreferences = SyncedPreferences(settings: document.settings)
        preferences = projectedPreferences
        manualRates = Dictionary(
            uniqueKeysWithValues: document.rates.rates.compactMap { currency, rate in
                guard rate.source == .manual else { return nil }
                let code = Subscription.normalizedCurrency(currency)
                guard code != projectedPreferences.baseCurrency else { return nil }
                return (code, SyncedManualRate(value: rate.value, updatedAt: rate.updatedAt).atStoredPrecision)
            }
        )
    }

    public static let currentSchemaVersion = 1

    /// Replaces synced data and keeps settings that belong to this Mac.
    public func applying(to localDocument: StoreDocument) -> StoreDocument {
        var result = localDocument
        result.subscriptions = subscriptions.map(\.subscription)
        result.categories = categories
        result.settings.baseCurrency = preferences.baseCurrency
        result.settings.defaultReminderLeadDays = preferences.defaultReminderLeadDays

        let keepsAutomaticRates = localDocument.rates.base == preferences.baseCurrency
        let automaticRates = keepsAutomaticRates
            ? localDocument.rates.rates.filter { _, rate in rate.source == .automatic }
            : [:]
        result.rates = RateTable(
            base: preferences.baseCurrency,
            rates: automaticRates,
            automaticAsOf: keepsAutomaticRates ? localDocument.rates.automaticAsOf : nil,
            lastCheckedAt: keepsAutomaticRates ? localDocument.rates.lastCheckedAt : nil
        )
        for (currency, rate) in manualRates {
            result.rates.setRate(rate.value, for: currency, updatedAt: rate.updatedAt)
        }
        result.rates.rates.removeValue(forKey: preferences.baseCurrency)
        result.repairDanglingCategories()
        return result
    }
}

/// One subscription without data that belongs to one Mac.
public struct SyncedSubscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: Icon
    public var tint: Tint
    public var categoryID: Category.ID
    public var price: Decimal
    public var currency: String
    public var priceChanges: [PriceChange]
    public var currentPriceSince: BillingDay?
    public var cycle: BillingCycle
    public var anchorDate: BillingDay?
    public var status: Status
    public var billingStoppedOn: BillingDay?
    public var endsOn: BillingDay?
    public var isEstimate: Bool
    public var reminderLeadDays: Int?
    public var paymentMethod: String
    public var manageURL: URL?
    public var website: String?
    public var notes: String
    public var createdAt: Date

    public init(_ subscription: Subscription) {
        id = subscription.id
        name = subscription.name
        icon = subscription.icon
        tint = subscription.tint
        categoryID = subscription.categoryID
        price = subscription.price
        currency = subscription.currency
        priceChanges = subscription.priceChanges
        currentPriceSince = subscription.currentPriceSince
        cycle = subscription.cycle
        anchorDate = subscription.anchorDate
        status = subscription.status
        billingStoppedOn = subscription.billingStoppedOn
        endsOn = subscription.endsOn
        isEstimate = subscription.isEstimate
        reminderLeadDays = subscription.reminderLeadDays
        paymentMethod = subscription.paymentMethod
        manageURL = subscription.manageURL
        website = subscription.website
        notes = subscription.notes
        createdAt = subscription.createdAt
    }

    /// The creation timestamp as the store file keeps it. Billing days are exact.
    var atStoredPrecision: SyncedSubscription {
        var result = self
        result.createdAt = DocumentStore.storedDate(createdAt)
        return result
    }

    /// The local value.
    public var subscription: Subscription {
        Subscription(
            id: id,
            name: name,
            icon: icon,
            tint: tint,
            categoryID: categoryID,
            price: price,
            currency: currency,
            priceChanges: priceChanges,
            currentPriceSince: currentPriceSince,
            cycle: cycle,
            anchorDate: anchorDate,
            status: status,
            billingStoppedOn: billingStoppedOn,
            endsOn: endsOn,
            isEstimate: isEstimate,
            reminderLeadDays: reminderLeadDays,
            paymentMethod: paymentMethod,
            manageURL: manageURL,
            website: website,
            notes: notes,
            createdAt: createdAt
        )
    }
}

/// Settings that change the meaning of the synced data.
///
/// Settings for the interface, notifications, calendars, launch behavior, and rate
/// refreshes stay on each Mac.
public struct SyncedPreferences: Codable, Hashable, Sendable {
    public var baseCurrency: String
    /// Retired: nothing reads it, and payment highlighting uses
    /// `Settings.paymentHighlightWindowDays`. The key stays in the wire format because
    /// an earlier Obolo decodes each preferences record strictly and needs it. This
    /// build writes `Settings.paymentHighlightWindowDays`, and a record from a Mac that
    /// holds another value keeps it as decoded.
    ///
    /// Equality and hashing leave it out, so a difference in this field alone is never
    /// an edit, an upload or a conflict, on any path that compares records.
    public var dueSoonWindowDays: Int
    public var defaultReminderLeadDays: Int

    public init(
        baseCurrency: String,
        dueSoonWindowDays: Int = Settings.paymentHighlightWindowDays,
        defaultReminderLeadDays: Int
    ) {
        self.baseCurrency = Subscription.normalizedCurrency(baseCurrency)
        self.dueSoonWindowDays = dueSoonWindowDays
        self.defaultReminderLeadDays = defaultReminderLeadDays
    }

    public init(settings: Settings) {
        self.init(
            baseCurrency: settings.baseCurrency,
            defaultReminderLeadDays: settings.defaultReminderLeadDays
        )
    }

    public static func == (lhs: SyncedPreferences, rhs: SyncedPreferences) -> Bool {
        lhs.baseCurrency == rhs.baseCurrency
            && lhs.defaultReminderLeadDays == rhs.defaultReminderLeadDays
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(baseCurrency)
        hasher.combine(defaultReminderLeadDays)
    }
}

/// A rate that the user entered.
///
/// The currency is the key in `SyncedDocument.manualRates`. Automatic rates and their
/// check dates stay on each Mac.
public struct SyncedManualRate: Codable, Hashable, Sendable {
    public var value: Decimal
    public var updatedAt: Date

    public init(value: Decimal, updatedAt: Date) {
        self.value = value
        self.updatedAt = updatedAt
    }

    /// The same rate with its date as the store file keeps it.
    var atStoredPrecision: SyncedManualRate {
        SyncedManualRate(value: value, updatedAt: DocumentStore.storedDate(updatedAt))
    }
}
