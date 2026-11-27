import Foundation

/// Turns "£46.80 a year" into "€3.90 a month".
///
/// Convert the full charge to the base currency before dividing by the billing period.
/// Rounding a foreign monthly amount first can change the result by a cent.
public enum Normalizer {

    /// Round each monthly amount once so category subtotals add up to the displayed total.
    public static let moneyScale = 2

    /// Price for one cycle, expressed per month.
    ///
    /// | weekly | `× 52 ÷ 12` |
    /// | n months | `÷ n` |
    public static func monthlyEquivalent(price: Decimal, cycle: BillingCycle) -> Decimal {
        guard let months = cycle.months else { return price * 52 / 12 }
        return price / Decimal(months)
    }

    /// Price for one cycle, expressed per year: `× paymentsPerYear`.
    public static func yearlyEquivalent(price: Decimal, cycle: BillingCycle) -> Decimal {
        guard let months = cycle.months else { return price * 52 }
        return price * 12 / Decimal(months)
    }

    /// `nil` when `currency` has no rate — the caller must exclude the item and say so.
    public static func convert(_ amount: Decimal, from currency: String, using rates: RateTable) -> Decimal? {
        guard let rate = rates.rate(for: currency) else { return nil }
        return amount * rate
    }

    /// Converts and normalises in the order above, rounded to cents.
    public static func monthlyInBase(price: Decimal, currency: String, cycle: BillingCycle, rates: RateTable) -> Decimal? {
        guard let converted = convert(price, from: currency, using: rates) else { return nil }
        return rounded(monthlyEquivalent(price: converted, cycle: cycle))
    }

    /// The per-item yearly figure the Detail prints under a monthly price
    /// ("€14.99 / month", then "€179.88 / year"). Computed from the charge, not from the
    /// rounded monthly figure, so a €8.90 yearly plan reads €8.90 and not €8.88.
    public static func yearlyInBase(price: Decimal, currency: String, cycle: BillingCycle, rates: RateTable) -> Decimal? {
        guard let converted = convert(price, from: currency, using: rates) else { return nil }
        return rounded(yearlyEquivalent(price: converted, cycle: cycle))
    }

    /// Half-away-from-zero to `scale` decimal places, on `Decimal` throughout — money
    /// never touches `Double` in this package.
    public static func rounded(_ value: Decimal, scale: Int = Normalizer.moneyScale) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    /// `part / whole` as a 0…1 fraction for the donut. `Double` is fine here — it is a
    /// pie slice, not an amount.
    public static func share(_ part: Decimal, of whole: Decimal) -> Double {
        guard whole != 0 else { return 0 }
        return (part / whole).doubleValue
    }
}

extension Decimal {
    /// Only used for chart geometry and for `paymentsPerYear`, never for money.
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
