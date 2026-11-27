import Foundation

/// One charge, on one day.
///
/// The Calendar section's unit. A `SubscriptionSummary` answers "when does this renew
/// next"; an occurrence answers the opposite question — "what lands on this square" —
/// so the same subscription contributes twelve of these to a year and none at all to a
/// month it does not touch.
///
/// It carries both figures on purpose. `amount` is what the biller charged **on that
/// day** — the price in force then, which for a subscription with a price history is
/// not today's — in the currency they charge it in, which is the number a bank
/// statement will show;
/// `amountInBase` is the same charge converted, which is the only one a month total can
/// sum. `amountInBase` is `nil` when the currency has no rate, and a `nil` there is
/// what "excluded from the total" means — never a zero.
public struct RenewalOccurrence: Hashable, Sendable {
    public let subscriptionID: Subscription.ID
    /// Start of day, in the ledger's calendar and time zone.
    public let date: Date
    public let amount: Decimal
    public let currency: String
    public let amountInBase: Decimal?

    public init(
        subscriptionID: Subscription.ID,
        date: Date,
        amount: Decimal,
        currency: String,
        amountInBase: Decimal?
    ) {
        self.subscriptionID = subscriptionID
        self.date = date
        self.amount = amount
        self.currency = currency
        self.amountInBase = amountInBase
    }
}
