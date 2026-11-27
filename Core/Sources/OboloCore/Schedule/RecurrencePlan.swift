import Foundation

/// The repeat rule one subscription implies, as a value.
///
/// EventKit is not imported here, and deliberately: the mapping from a billing cycle to
/// a repeat rule is the part that can be wrong, and it can only be tested against
/// `RenewalSchedule` if it is a value the tests can read. `CalendarSync` turns this into
/// an `EKRecurrenceRule` and does nothing else with it.
///
/// **The month-end clamp is the whole reason this type exists.** A plain "every month on
/// the 31st" rule follows RFC 5545, which *skips* a month that has no 31st: a Netflix
/// plan anchored 31 January would show in the user's calendar in January, March, May and
/// nowhere else, while the app's own list says 28 February. The fix is the one the spec
/// provides for it — offer the rule every day from the 28th up to the anchor's day and
/// keep only the last match in each month (`setPositions = [-1]`), which lands on the
/// 31st where there is one and on the month's last day where there is not. That is
/// exactly what `RenewalSchedule.occurrence` computes.
public struct RecurrencePlan: Hashable, Sendable {

    public enum Frequency: String, Sendable {
        case weekly, monthly, yearly
    }

    public var frequency: Frequency
    /// How many periods between charges: 3 monthly for a quarterly plan, 2 yearly for a
    /// two-year one. Never below 1.
    public var interval: Int
    /// The days a charge may land on inside one period, e.g. `[28, 29, 30, 31]` for an
    /// anchor on the 31st. `nil` when the anchor's own day exists in every month.
    public var daysOfTheMonth: [Int]?
    /// Which months a yearly rule applies to, e.g. `[2]` for an anchor on 29 February.
    public var monthsOfTheYear: [Int]?
    /// Which of the matching days in a period to keep. `[-1]` is the last one, which is
    /// what turns a list of candidate days into "the last day this month has".
    public var setPositions: [Int]?

    public init(
        frequency: Frequency,
        interval: Int,
        daysOfTheMonth: [Int]? = nil,
        monthsOfTheYear: [Int]? = nil,
        setPositions: [Int]? = nil
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.daysOfTheMonth = daysOfTheMonth
        self.monthsOfTheYear = monthsOfTheYear
        self.setPositions = setPositions
    }

    /// The first day of the month that every month is guaranteed to have. Below this a
    /// plain rule needs no help; at or above it, February decides.
    private static let shortestMonthLength = 28

    /// The rule a cycle anchored on this date repeats by.
    ///
    /// Weekly is the one cadence the calendar cannot lose a day of. Everything else is
    /// month arithmetic, and the anchor's day-of-month decides whether the rule needs
    /// the clamp above.
    public static func plan(for cycle: BillingCycle, anchor: Date, calendar: Calendar) -> RecurrencePlan {
        let day = calendar.component(.day, from: anchor)
        let month = calendar.component(.month, from: anchor)

        switch cycle {
        case .weekly:
            return RecurrencePlan(frequency: .weekly, interval: 1)

        case .yearly, .everyTwoYears:
            let interval = cycle == .yearly ? 1 : 2
            // 29 February is the only yearly anchor a calendar can fail to provide, and
            // it fails three years in four.
            guard month == 2, day == 29 else {
                return RecurrencePlan(frequency: .yearly, interval: interval)
            }
            return RecurrencePlan(
                frequency: .yearly,
                interval: interval,
                daysOfTheMonth: [28, 29],
                monthsOfTheYear: [2],
                setPositions: [-1]
            )

        case .monthly, .quarterly, .custom:
            let months = cycle.months ?? 1
            guard day > shortestMonthLength else {
                return RecurrencePlan(frequency: .monthly, interval: months)
            }
            return RecurrencePlan(
                frequency: .monthly,
                interval: months,
                daysOfTheMonth: Array(shortestMonthLength...day),
                setPositions: [-1]
            )
        }
    }
}
