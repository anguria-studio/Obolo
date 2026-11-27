import Foundation

/// When to ask the rate server for a new set of numbers.
///
/// Pure, so the answer can be tested without a clock, a network or an app: the decision
/// is a function of what the table already holds and what time it is.
///
/// **The throttle runs on the check, not on the quote.** The ECB publishes on working
/// days only, so from Friday evening to Monday morning the newest fixing there is stays
/// Friday's. Throttling on that publication day makes the app ask again every few hours
/// all weekend, and each answer is the same Friday number: the one date that says
/// anything about whether a request is worth making is the moment the app last got an
/// answer.
public enum RateRefreshPolicy {

    /// One request a day, which is as often as the rates can change.
    public static let defaultMinimumInterval: TimeInterval = 24 * 3600

    /// Whether a refresh is worth making.
    ///
    /// - Parameters:
    ///   - lastCheckedAt: When an answer last came back, whatever day it named. `nil`
    ///     means the app has never had one, so it asks.
    ///   - automaticAsOf: The publication day of the rates in hand. Read only to notice
    ///     that there are none; it is never the throttle.
    ///   - now: The current moment.
    ///   - force: The user asked, or a currency has just appeared with nothing to
    ///     convert it. Skips the throttle, not the "is there anything to ask about"
    ///     check.
    ///   - hasCurrenciesNeedingRates: Whether any subscription is priced in something
    ///     other than the base. An all-euro list has nothing to download.
    ///   - minimumInterval: How long an answer stays fresh.
    public static func shouldRefresh(
        lastCheckedAt: Date?,
        automaticAsOf: Date?,
        now: Date,
        force: Bool,
        hasCurrenciesNeedingRates: Bool,
        minimumInterval: TimeInterval = RateRefreshPolicy.defaultMinimumInterval
    ) -> Bool {
        // Nothing to convert: a forced refresh of an empty list is still a request for
        // nothing.
        guard hasCurrenciesNeedingRates else { return false }
        guard !force else { return true }

        // No answer has ever landed — nothing to hold back.
        guard let lastCheckedAt, automaticAsOf != nil else { return true }

        return now.timeIntervalSince(lastCheckedAt) >= minimumInterval
    }
}
