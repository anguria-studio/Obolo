import Foundation

/// One exchange rate, with the date it was last written and where it came from.
///
/// The source is what makes an automatic refresh safe: a number the user typed is a
/// decision — the rate their bank actually charged, a card fee folded in — and a daily
/// download must never quietly overwrite it. Everything else is a reference rate that
/// is only ever improved by being replaced.
public struct Rate: Codable, Hashable, Sendable {

    /// Who wrote this rate.
    public enum Source: String, Codable, Hashable, Sendable {
        /// Typed into the Categories & currencies pane.
        case manual
        /// Downloaded from the ECB's daily reference rates.
        case automatic
    }

    /// Multiply an amount in this currency by `value` to get the base currency.
    public var value: Decimal
    public var updatedAt: Date
    public var source: Source

    public init(value: Decimal, updatedAt: Date, source: Source = .manual) {
        self.value = value
        self.updatedAt = updatedAt
        self.source = source
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case value, updatedAt, source
    }

    /// A document written before rates could refresh themselves has no `source`, and
    /// every rate in it was typed by hand — which is exactly what `.manual` means, and
    /// exactly what must survive the first automatic refresh.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Decimal.self, forKey: .value)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .manual
    }
}

/// Currency → rate to base.
///
/// A currency that is missing here is *not* treated as 1:1. The subscription drops out
/// of the totals and the UI shows a footnote — a wrong total is worse than an
/// incomplete one that says so.
public struct RateTable: Codable, Hashable, Sendable {
    public var base: String
    public var rates: [String: Rate]

    /// When the last automatic refresh landed — the ECB publication day it carried, not
    /// the moment of the download. `nil` until one has succeeded. Read by the Settings
    /// status line and by the YEARLY tile's caption, and used to decide whether today's
    /// refresh has already happened.
    public var automaticAsOf: Date?

    /// When the app last asked and got an answer — the moment of the download, not the
    /// day it carried. `nil` until one has succeeded, and unchanged by a failure.
    ///
    /// The ECB publishes on working days only, so from Friday evening to Monday morning
    /// the newest quote there is stays Friday's. Without this, a status line built on
    /// `automaticAsOf` alone says "updated 21 Aug" all weekend and reads as "the app has
    /// stopped looking", when in fact it looked this morning and Friday's fixing *is*
    /// the latest. The two dates answer two different questions and both are shown.
    public var lastCheckedAt: Date?

    public init(
        base: String,
        rates: [String: Rate] = [:],
        automaticAsOf: Date? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.base = Subscription.normalizedCurrency(base)
        self.rates = Dictionary(
            rates.map { (Subscription.normalizedCurrency($0.key), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        self.automaticAsOf = automaticAsOf
        self.lastCheckedAt = lastCheckedAt
    }

    /// `1` for the base currency, the stored rate for anything else, `nil` when there
    /// is none.
    public func rate(for currency: String) -> Decimal? {
        let code = Subscription.normalizedCurrency(currency)
        if code == base { return 1 }
        return rates[code]?.value
    }

    public func hasRate(for currency: String) -> Bool {
        rate(for: currency) != nil
    }

    public func source(for currency: String) -> Rate.Source? {
        rates[Subscription.normalizedCurrency(currency)]?.source
    }

    /// Every currency the table can convert, base first then the rest alphabetically.
    public var currencies: [String] {
        [base] + rates.keys.filter { $0 != base }.sorted()
    }

    /// Writes a rate the user typed. Always `.manual`: this is only ever called from
    /// the pane, and typing over a downloaded number is how the user says "no, this
    /// one".
    public mutating func setRate(_ value: Decimal, for currency: String, updatedAt: Date) {
        let code = Subscription.normalizedCurrency(currency)
        guard code != base else { return }
        rates[code] = Rate(value: value, updatedAt: updatedAt, source: .manual)
    }

    public mutating func removeRate(for currency: String) {
        rates.removeValue(forKey: Subscription.normalizedCurrency(currency))
    }

    // MARK: - Automatic rates

    /// Folds a downloaded set of rates in, leaving every hand-entered one alone.
    ///
    /// `asOf` stamps both the rates written and `automaticAsOf`, so "updated 21 Aug"
    /// means the day the ECB published the number rather than the day the app happened
    /// to ask for it. A code that is already manual is skipped entirely — not even its
    /// timestamp moves.
    ///
    /// `checkedAt` is the other half: the moment the answer came back. Every successful
    /// refresh moves it, even one that changes no rate at all — a weekend refresh that
    /// gets Friday's fixing again is still proof the app is looking. Callers that have
    /// no clock to hand may leave it out, and the publication day stands in.
    public mutating func applyAutomatic(
        _ downloaded: [String: Decimal],
        asOf: Date,
        checkedAt: Date? = nil
    ) {
        for (code, value) in downloaded {
            let normalized = Subscription.normalizedCurrency(code)
            guard normalized != base, value > 0 else { continue }
            if rates[normalized]?.source == .manual { continue }
            rates[normalized] = Rate(value: value, updatedAt: asOf, source: .automatic)
        }
        automaticAsOf = asOf
        lastCheckedAt = checkedAt ?? asOf
    }

    /// Every currency a refresh should ask about: everything any subscription is priced
    /// in, minus the base.
    ///
    /// Deliberately *not* filtered to the ones missing a rate — an automatic rate that
    /// already exists is a day older every morning, and refreshing all of them is the
    /// same single request.
    public func currenciesNeedingRates(in document: StoreDocument) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for subscription in document.subscriptions {
            let code = Subscription.normalizedCurrency(subscription.currency)
            guard code != base, code.count == 3, seen.insert(code).inserted else { continue }
            result.append(code)
        }
        return result.sorted()
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case base, rates, automaticAsOf, lastCheckedAt
    }

    /// A document written before the app recorded its checks has no `lastCheckedAt`, and
    /// there is nothing to infer one from: the status line simply names the quote day
    /// until the next refresh lands.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = Subscription.normalizedCurrency(try container.decode(String.self, forKey: .base))
        rates = try container.decodeIfPresent([String: Rate].self, forKey: .rates) ?? [:]
        automaticAsOf = try container.decodeIfPresent(Date.self, forKey: .automaticAsOf)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }
}
