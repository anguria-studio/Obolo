import Foundation

/// A price this subscription charged before the current one, and the day it started.
///
/// A subscription's `price` is always the **current** one: it is what the All list shows,
/// what the totals use and what the next payment will cost. The entries in
/// `Subscription.priceChanges` describe the periods below it — each one says "from this
/// day the price was that", and the next entry (or `Subscription.currentPriceSince`)
/// says when it stopped.
///
/// Kept as a list of starts rather than a list of ranges because that is how a price
/// rise arrives: an email saying "from 20 January your plan is €15". Ranges would make
/// the app ask for an end date nobody was told.
public struct PriceChange: Codable, Hashable, Sendable {

    /// The first day this price was charged. Compared at day granularity, so a change
    /// dated 20 January applies to the charge that lands on 20 January.
    public var effectiveFrom: BillingDay
    /// Per billing cycle, as charged, exactly like `Subscription.price`.
    public var price: Decimal
    /// ISO 4217, uppercase. The editor and CSV keep it with each entry. A plan that
    /// moved from USD to EUR did not charge dollars at the euro price.
    public var currency: String

    public init(effectiveFrom: BillingDay, price: Decimal, currency: String) {
        self.effectiveFrom = effectiveFrom
        self.price = price
        self.currency = Subscription.normalizedCurrency(currency)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case effectiveFrom, price, currency
    }

    /// The effective day is required. An undated price cannot be placed in the history.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effectiveFrom = try container.decode(BillingDay.self, forKey: .effectiveFrom)
        price = try container.decodeIfPresent(Decimal.self, forKey: .price) ?? 0
        currency = Subscription.normalizedCurrency(
            try container.decodeIfPresent(String.self, forKey: .currency) ?? "EUR"
        )
    }
}
