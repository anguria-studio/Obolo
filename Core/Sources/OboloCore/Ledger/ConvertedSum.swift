import Foundation

/// A sum in the base currency of amounts that may have no rate.
///
/// The honest-numbers rule in one place, for every figure that adds up a few amounts
/// on screen: an amount with no rate is left out of the sum and counted in
/// `excludedCount`, never added as zero, and a sum with nothing in it that could be
/// converted is `nil`, which the UI shows as `MoneyFormatting.unknown`, never as 0.
public struct ConvertedSum: Equatable, Sendable {
    /// The amounts that could be converted, added up. `nil` when there were amounts and
    /// none of them had a rate. Zero for no amounts at all: nothing costs nothing.
    public let total: Decimal?
    /// How many amounts had no rate, so are not in `total`.
    public let excludedCount: Int

    /// `amounts` in the base currency, `nil` where the currency has no rate.
    public init(_ amounts: some Sequence<Decimal?>) {
        var total = Decimal.zero
        var count = 0
        var excluded = 0
        for amount in amounts {
            count += 1
            if let amount { total += amount } else { excluded += 1 }
        }
        self.total = count > 0 && excluded == count ? nil : total
        self.excludedCount = excluded
    }
}

extension ConvertedSum {
    /// What a set of charges comes to: a calendar day, or a month.
    public init(charges: some Sequence<RenewalOccurrence>) {
        self.init(charges.lazy.map(\.amountInBase))
    }

    /// What a set of rows costs each month, as the hero counts it: only billing rows,
    /// because a paused or cancelled one costs nothing; a billing row with no rate is
    /// left out and counted, as in `Ledger.missingRateCount`.
    public init(monthly rows: some Sequence<SubscriptionSummary>) {
        self.init(rows.lazy.filter { $0.status.isBilling }.map(\.monthlyInBase))
    }
}
