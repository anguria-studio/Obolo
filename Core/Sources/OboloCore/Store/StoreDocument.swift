import Foundation

/// Everything Obolo owns, in one value.
///
/// Subscriptions, categories, rates *and* settings live together so that "Back up"
/// writes one file and "Restore" reads one file — there is no second place where a
/// preference could get out of step with the data it configures.
public struct StoreDocument: Codable, Hashable, Sendable {
    /// The on-disk format version.
    public let version: Int
    public var subscriptions: [Subscription]
    public var categories: [Category]
    public var rates: RateTable
    public var settings: Settings

    public init(
        subscriptions: [Subscription] = [],
        categories: [Category] = Category.seeded,
        rates: RateTable = RateTable(base: "EUR"),
        settings: Settings = Settings()
    ) {
        self.version = Self.currentVersion
        self.subscriptions = subscriptions
        self.categories = categories
        self.rates = rates
        self.settings = settings
    }

    public static let currentVersion = 1

    public struct NewerVersion: LocalizedError, Equatable {
        public let version: Int

        public var errorDescription: String? {
            "A newer version of Obolo wrote this file (format \(version)). Update Obolo to open it."
        }
    }

    /// What a first launch gets: the seeded categories, a EUR base and the defaults.
    /// Also what `DocumentStore.load()` returns when there is no file yet — a missing
    /// store is a new user, not an error.
    public static func initial(baseCurrency: String = "EUR") -> StoreDocument {
        StoreDocument(
            subscriptions: [],
            categories: Category.seeded,
            rates: RateTable(base: baseCurrency),
            settings: Settings(baseCurrency: baseCurrency)
        )
    }

    // MARK: - Lookups

    public func category(id: Category.ID) -> Category? {
        categories.first(id: id)
    }

    public func category(named name: String) -> Category? {
        categories.first(named: name)
    }

    public func subscription(id: Subscription.ID) -> Subscription? {
        subscriptions.first { $0.id == id }
    }

    /// The bucket that orphans land in, which deleting a category moves its items to.
    ///
    /// Found by `Category.fallbackID`, never by name: the user may rename it, and a
    /// renamed bucket is still the one every subscription was filed into. The name is
    /// tried only for a document written before the seeded IDs existed, and the first
    /// category only when even that finds nothing, so this never returns a dangling ID.
    public var fallbackCategoryID: Category.ID {
        if categories.contains(where: { $0.id == Category.fallbackID }) { return Category.fallbackID }
        return category(named: Category.fallbackName)?.id
            ?? categories.first?.id
            ?? Category.fallbackID
    }

    // MARK: - Mutations

    /// Appends, or replaces in place when the ID is already present.
    public mutating func upsert(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
    }

    /// Deletes a category and re-homes its subscriptions, per the design's rule. Refuses
    /// to delete the last one, and refuses to delete the fallback bucket — there has to
    /// be somewhere for orphans to land.
    ///
    /// The bucket is refused by ID, so renaming it does not make it deletable, and a
    /// second category the user names "Other" is an ordinary one that can go.
    @discardableResult
    public mutating func removeCategory(id: Category.ID) -> Bool {
        guard categories.count > 1, id != Category.fallbackID, id != fallbackCategoryID else { return false }
        categories.removeAll { $0.id == id }
        let destination = fallbackCategoryID
        for index in subscriptions.indices where subscriptions[index].categoryID == id {
            subscriptions[index].categoryID = destination
        }
        return true
    }

    /// Points any subscription whose category has gone missing at "Other". Called on
    /// load so a hand-edited or partially restored file cannot produce rows that render
    /// with no chip.
    public mutating func repairDanglingCategories() {
        let known = Set(categories.map(\.id))
        guard !known.isEmpty else { return }
        let destination = fallbackCategoryID
        for index in subscriptions.indices where !known.contains(subscriptions[index].categoryID) {
            subscriptions[index].categoryID = destination
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case version, subscriptions, categories, rates, settings
    }

    /// Reads the format before interpreting any subscription or settings fields.
    struct Header: Decodable {
        let version: Int

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decodeIfPresent(Int.self, forKey: .version) ?? StoreDocument.currentVersion
            guard version <= StoreDocument.currentVersion else { throw NewerVersion(version: version) }
        }
    }

    public init(from decoder: any Decoder) throws {
        version = try Header(from: decoder).version
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        let decodedCategories = try container.decodeIfPresent([Category].self, forKey: .categories) ?? []
        categories = decodedCategories.isEmpty ? Category.seeded : decodedCategories
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        rates = try container.decodeIfPresent(RateTable.self, forKey: .rates) ?? RateTable(base: settings.baseCurrency)
        repairDanglingCategories()
    }
}
