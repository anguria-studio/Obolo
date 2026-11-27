import Foundation

/// Amounts, rendered through the Mac's locale.
///
/// Nothing here hard-codes a symbol or a separator: an Italian Mac must show
/// `14,99 €` and an Irish one `€14.99`, and the only way to get both is to let
/// `Locale` decide. What the app *does* fix is the `~` that marks an estimate and the
/// choice of narrow currency symbols.
public enum MoneyFormatting {

    /// The `~` an estimated price carries everywhere it appears.
    public static let estimatePrefix = "~"

    /// The currency's standard number of minor-unit digits, such as 0 for JPY and 3 for KWD.
    public static func fractionDigits(of currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = Subscription.normalizedCurrency(currency)
        return formatter.maximumFractionDigits
    }

    /// "€14.99" · "$24.40" · "~€80.00".
    ///
    /// Narrow presentation is deliberate: in `en_IE` the standard form renders USD as
    /// "US$24.40", and the design's popover row reads "$24.40". Narrow keeps the
    /// symbol short in every locale while still disambiguating where the locale itself
    /// insists.
    ///
    /// `wholeUnits` drops the fraction, rounding half up: "€23,457" for 23,456.79. For a
    /// big figure in a tight spot, such as the Subscriptions ring's centre.
    public static func amount(
        _ value: Decimal,
        currency: String,
        estimate: Bool = false,
        locale: Locale = .current,
        wholeUnits: Bool = false
    ) -> String {
        let code = Subscription.normalizedCurrency(currency)
        let style = Decimal.FormatStyle.Currency(code: code).locale(locale).presentation(.narrow)
        let rendered = wholeUnits
            ? value.formatted(style.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero))
            : value.formatted(style)
        return estimate ? estimatePrefix + rendered : rendered
    }

    /// The same amount with no fraction digits: "€159".
    ///
    /// Used by the menu bar, where every pixel is rented. The caller appends the
    /// cadence — `Ledger.menuBarLabel(style:)` builds "€159/mo" from this.
    public static func compact(_ value: Decimal, currency: String, locale: Locale = .current) -> String {
        let code = Subscription.normalizedCurrency(currency)
        return value.formatted(
            .currency(code: code).locale(locale).presentation(.narrow).precision(.fractionLength(0))
        )
    }

    /// What the UI shows where a number is genuinely unknown. Never "0".
    public static let unknown = "-"
}
