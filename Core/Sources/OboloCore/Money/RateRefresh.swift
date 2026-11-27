import Foundation

/// The shape Frankfurter answers with:
///
/// ```json
/// {"amount":1.0,"base":"EUR","date":"2026-08-21","rates":{"USD":1.1699,"GBP":0.8567}}
/// ```
///
/// `Decimal` rather than `Double` throughout, because `JSONDecoder` builds a `Decimal`
/// from the digits it scanned rather than through a binary float — 1.1699 stays 1.1699.
public struct FrankfurterResponse: Codable, Hashable, Sendable {
    /// How much of `base` the rates are quoted for. Always 1 for a `latest` query, and
    /// the parser divides by it rather than trusting that.
    public var amount: Decimal
    public var base: String
    /// The ECB publication day, `yyyy-MM-dd`. Not today: rates are published on
    /// weekdays around 16:00 CET, so a Saturday's answer is Friday's number.
    public var date: String
    public var rates: [String: Decimal]

    public init(amount: Decimal, base: String, date: String, rates: [String: Decimal]) {
        self.amount = amount
        self.base = base
        self.date = date
        self.rates = rates
    }
}

/// Turning one Frankfurter response into rates this app can store — the pure half of
/// the refresh, so the direction and the rounding are testable without a network.
///
/// **The direction is the whole point.** Frankfurter quotes *units of quote per 1 base*
/// ("one euro buys 1.1699 dollars"); `RateTable` stores *rate to base* (multiply a
/// foreign amount by it to get base). One is the reciprocal of the other, and getting
/// it backwards makes a $24.40 subscription cost €28.55 instead of €20.86 — a number
/// wrong enough to be believed.
public enum RateRefresh {

    /// `api.frankfurter.app` still answers, with a 301 to this. Asking the canonical
    /// host directly saves the redirect.
    public static let endpoint = URL(string: "https://api.frankfurter.dev/v1/latest")!

    /// Six decimal places: enough that a 0.000001 error on a four-figure yearly charge
    /// stays under a cent, short enough that the pane's rate column reads as a number
    /// rather than a hash.
    public static let rateScale = 6

    public enum ParseError: Error, Equatable {
        /// Not JSON, or JSON of some other shape.
        case malformed
        /// The server answered about a different base than the one asked for — an
        /// unsupported base is a 404, so this is belt and braces.
        case wrongBase(expected: String, got: String)
        /// `date` was not a `yyyy-MM-dd` day.
        case badDate(String)
    }

    /// The request for one refresh: one base, however many symbols, one round trip.
    ///
    /// `symbols` is the *only* thing sent — three-letter currency codes and nothing
    /// else. No identifier, no list of what they are for.
    public static func url(base: String, symbols: [String]) -> URL? {
        let code = Subscription.normalizedCurrency(base)
        let wanted = symbols
            .map { Subscription.normalizedCurrency($0) }
            .filter { $0.count == 3 && $0 != code }
            .sorted()
        guard code.count == 3, !wanted.isEmpty else { return nil }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "base", value: code),
            URLQueryItem(name: "symbols", value: wanted.joined(separator: ","))
        ]
        return components?.url
    }

    /// The day the rates were published, and each rate inverted into "multiply by this
    /// to get base", rounded to `rateScale`.
    ///
    /// A currency Frankfurter does not cover simply is not in `rates` — the ECB
    /// publishes about thirty. That is not an error here: the code comes back missing,
    /// the table keeps no rate for it, and the subscription drops out of the totals with
    /// the "without a rate" note it already has.
    public static func parse(data: Data, base: String) throws -> (asOf: Date, ratesToBase: [String: Decimal]) {
        guard let response = try? JSONDecoder().decode(FrankfurterResponse.self, from: data) else {
            throw ParseError.malformed
        }

        let expected = Subscription.normalizedCurrency(base)
        let got = Subscription.normalizedCurrency(response.base)
        guard got == expected else { throw ParseError.wrongBase(expected: expected, got: got) }
        guard let asOf = day(response.date) else { throw ParseError.badDate(response.date) }
        guard response.amount > 0 else { throw ParseError.malformed }

        var ratesToBase: [String: Decimal] = [:]
        for (code, quoted) in response.rates {
            let normalized = Subscription.normalizedCurrency(code)
            guard normalized.count == 3, normalized != expected, quoted > 0 else { continue }
            ratesToBase[normalized] = Normalizer.rounded(response.amount / quoted, scale: rateScale)
        }
        return (asOf, ratesToBase)
    }

    /// `"2026-08-21"` as midday UTC.
    ///
    /// Midday rather than midnight so that the date the user is shown is the 21st
    /// whichever side of the Atlantic they read it from — a UTC midnight formats as the
    /// 20th in every American time zone, and this stamp exists to be printed.
    ///
    /// The day itself is read by `ISODay`, the same parser the CSV importer uses, so a
    /// server that answered `2026-02-31` is refused here exactly as a spreadsheet cell
    /// saying the same thing would be.
    public static func day(_ text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        guard let midnight = ISODay.parse(text, calendar: calendar) else { return nil }
        return calendar.date(byAdding: .hour, value: 12, to: midnight)
    }
}
