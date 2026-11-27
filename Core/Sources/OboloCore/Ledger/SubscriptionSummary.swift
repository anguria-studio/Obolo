import Foundation

/// Charges from one subscription, grouped by charged currency.
///
/// A subscription can move from one currency to another. These totals stay separate
/// because adding dollars to euros would produce a number with no valid meaning.
public struct PaidHistory: Equatable, Sendable {

    public let count: Int
    public let totalsByCurrency: [String: Decimal]

    public init(count: Int, totalsByCurrency: [String: Decimal]) {
        self.count = count
        self.totalsByCurrency = totalsByCurrency
    }

    /// The total when all charges used one currency. Kept for simple consumers and
    /// tests. A mixed-currency history has no single total.
    public var total: Decimal? {
        guard totalsByCurrency.count == 1 else { return nil }
        return totalsByCurrency.values.first
    }
}

/// An amount as it is charged, in the currency it is charged in.
public struct PricePoint: Equatable, Sendable {
    public let price: Decimal
    public let currency: String

    public init(price: Decimal, currency: String) {
        self.price = price
        self.currency = currency
    }
}

/// A subscription plus everything the UI needs to draw it, as of one `today`.
///
/// Produced by `Ledger` and never stored. Deliberately **not** `Codable`: writing one
/// of these to disk would be storing a derived value, which is the thing the whole
/// design forbids.
public struct SubscriptionSummary: Identifiable, Sendable {
    public let subscription: Subscription
    /// Always resolved — `Ledger` substitutes `Category.unknown` rather than hand the
    /// UI an optional it would have to branch on in six places.
    public let category: Category
    /// `nil` for paused, cancelled, and active-with-no-anchor items.
    public let nextPayment: Date?
    public let daysUntil: Int?
    /// `nil` when the currency has no rate or the item is out of the totals.
    public let monthlyInBase: Decimal?
    public let yearlyInBase: Decimal?
    /// The charge itself, converted to base — what leaves the account on `nextPayment`.
    /// `nil` when the currency has no rate.
    public let chargeInBase: Decimal?
    /// Active or trial, with a rate.
    public let countsInTotals: Bool
    public let attention: Attention
    /// `nil` when the anchor is missing or in the future — the Detail's "Total spent"
    /// reads `–` rather than claiming zero.
    public let paidSoFar: PaidHistory?

    /// What this subscription costs **today**, and in which currency.
    ///
    /// Stored rather than read off `subscription.price`, because those two differ once a
    /// rise has been announced: the stored pair is the latest *known* price, which may
    /// not have started yet. Everything that means "what am I paying" — the All list's
    /// Amount, the Detail, the totals — reads this.
    public let price: Decimal
    public let currency: String
    /// What the charge on `nextPayment` will cost, which is not always today's price: a
    /// rise announced for the first of the month lands before a payment on the fifth.
    /// `nil` exactly when `nextPayment` is.
    public let nextCharge: PricePoint?
    /// A rise this subscription has been told about and not yet reached. `nil` for
    /// nearly every row — see `Subscription.announcedPriceChange(on:calendar:)`.
    public let announcedPriceChange: PriceChange?

    public var id: Subscription.ID { subscription.id }
    public var name: String { subscription.name }
    public var cycle: BillingCycle { subscription.cycle }
    public var status: Status { subscription.status }
    public var isEstimate: Bool { subscription.isEstimate }

    public init(
        subscription: Subscription,
        category: Category,
        price: Decimal,
        currency: String,
        nextCharge: PricePoint? = nil,
        announcedPriceChange: PriceChange? = nil,
        nextPayment: Date?,
        daysUntil: Int?,
        monthlyInBase: Decimal?,
        yearlyInBase: Decimal?,
        chargeInBase: Decimal?,
        countsInTotals: Bool,
        attention: Attention,
        paidSoFar: PaidHistory?
    ) {
        self.subscription = subscription
        self.category = category
        self.price = price
        self.currency = currency
        self.nextCharge = nextCharge
        self.announcedPriceChange = announcedPriceChange
        self.nextPayment = nextPayment
        self.daysUntil = daysUntil
        self.monthlyInBase = monthlyInBase
        self.yearlyInBase = yearlyInBase
        self.chargeInBase = chargeInBase
        self.countsInTotals = countsInTotals
        self.attention = attention
        self.paidSoFar = paidSoFar
    }

    /// The lead time this item's reminder uses, resolving `nil` against the default.
    public func reminderLeadDays(default fallback: Int) -> Int {
        subscription.reminderLeadDays ?? fallback
    }
}

extension SubscriptionSummary: Equatable {}
