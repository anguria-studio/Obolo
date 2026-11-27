import EventKit
import OboloCore

/// The one place a `RecurrencePlan` becomes an `EKRecurrenceRule`, and the one place a
/// stored rule is compared back against a plan.
///
/// Its own type, with nothing but EventKit and `OboloCore` behind it, for two
/// reasons. It is the only part of `CalendarSync` that can be checked without a calendar
/// and without permission — the rule it builds for a 31 January plan either carries the
/// month-end clamp or it does not — and keeping the comparison next to the construction
/// is what stops the two drifting apart, which is how an event ends up rewritten on
/// every reconcile.
enum RecurrenceRule {

    /// The plan as EventKit expresses it.
    ///
    /// The long initialiser rather than the two-argument one: `daysOfTheMonth` and
    /// `setPositions` are what carry the month-end clamp, and the short form has no way
    /// to say them. `daysOfTheWeek`, `weeksOfTheYear` and `daysOfTheYear` stay `nil` —
    /// no billing cycle in this app repeats by weekday.
    static func make(_ plan: RecurrencePlan) -> EKRecurrenceRule {
        EKRecurrenceRule(
            recurrenceWith: frequency(plan.frequency),
            interval: plan.interval,
            daysOfTheWeek: nil,
            daysOfTheMonth: numbers(plan.daysOfTheMonth),
            monthsOfTheYear: numbers(plan.monthsOfTheYear),
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: numbers(plan.setPositions),
            end: nil
        )
    }

    /// Whether an event's stored rule already says what the plan says.
    ///
    /// `false` is drift, and drift is what makes `reconcile` re-apply the plan with
    /// `span: .futureEvents`. An event written by a build that had no month-end clamp
    /// carries a plain "every month" rule and is caught exactly here.
    static func matches(_ rule: EKRecurrenceRule, _ plan: RecurrencePlan) -> Bool {
        guard rule.frequency == frequency(plan.frequency),
              rule.interval == plan.interval,
              rule.recurrenceEnd == nil,
              rule.daysOfTheWeek?.isEmpty != false,
              same(rule.daysOfTheMonth, plan.daysOfTheMonth),
              same(rule.monthsOfTheYear, plan.monthsOfTheYear),
              same(rule.setPositions, plan.setPositions)
        else { return false }
        return true
    }

    static func frequency(_ frequency: RecurrencePlan.Frequency) -> EKRecurrenceFrequency {
        switch frequency {
        case .weekly:  .weekly
        case .monthly: .monthly
        case .yearly:  .yearly
        }
    }

    private static func numbers(_ values: [Int]?) -> [NSNumber]? {
        values.map { $0.map { NSNumber(value: $0) } }
    }

    /// Whether a rule's number list says the same thing as the plan's.
    ///
    /// An absent list and an empty one mean the same thing to EventKit — "no constraint"
    /// — and it hands back one or the other depending on how the event was written, so
    /// treating them as different would report drift on every reconcile and rewrite an
    /// event that is already correct. Order is not compared either: `[28, 29]` and
    /// `[29, 28]` are the same set of days.
    private static func same(_ rule: [NSNumber]?, _ plan: [Int]?) -> Bool {
        Set((rule ?? []).map(\.intValue)) == Set(plan ?? [])
    }
}
