import Foundation
import Testing
@testable import OboloCore

/// The rule the calendar event repeats by, checked against the rule the app itself
/// follows.
///
/// Asserting the plan's fields is half of it. The half that matters is the expansion
/// below: a repeat rule is only right if the days it produces are the days the app's own
/// list shows, and the two are computed by completely different means — one clamps a
/// date, the other picks the last of a set of candidate days.
@Suite("Recurrence plans")
struct RecurrencePlanTests {

    private let calendar = Fixed.calendar

    // MARK: - The plans

    @Test("A weekly plan is a week, with nothing to clamp")
    func weekly() {
        let plan = RecurrencePlan.plan(for: .weekly, anchor: Fixed.day(2026, 1, 31), calendar: calendar)
        #expect(plan == RecurrencePlan(frequency: .weekly, interval: 1))
        #expect(plan.daysOfTheMonth == nil)
        #expect(plan.setPositions == nil)
    }

    @Test("An anchor on the 31st offers every month end and keeps the last")
    func monthlyOnTheThirtyFirst() {
        let plan = RecurrencePlan.plan(for: .monthly, anchor: Fixed.day(2026, 1, 31), calendar: calendar)
        #expect(plan == RecurrencePlan(
            frequency: .monthly,
            interval: 1,
            daysOfTheMonth: [28, 29, 30, 31],
            setPositions: [-1]
        ))
    }

    @Test("An anchor on the 30th offers the days a 30th can fall back to, and no more")
    func monthlyOnTheThirtieth() {
        let plan = RecurrencePlan.plan(for: .monthly, anchor: Fixed.day(2026, 1, 30), calendar: calendar)
        #expect(plan == RecurrencePlan(
            frequency: .monthly,
            interval: 1,
            daysOfTheMonth: [28, 29, 30],
            setPositions: [-1]
        ))
    }

    @Test("An anchor every month has needs no day list at all")
    func monthlyMidMonth() {
        let plan = RecurrencePlan.plan(for: .monthly, anchor: Fixed.day(2026, 3, 15), calendar: calendar)
        #expect(plan == RecurrencePlan(frequency: .monthly, interval: 1))
    }

    @Test("Quarterly and custom cadences are the same rule with a longer step")
    func monthlyIntervals() {
        let quarterly = RecurrencePlan.plan(for: .quarterly, anchor: Fixed.day(2026, 3, 15), calendar: calendar)
        #expect(quarterly == RecurrencePlan(frequency: .monthly, interval: 3))

        let custom = RecurrencePlan.plan(for: .custom(months: 5), anchor: Fixed.day(2026, 1, 31), calendar: calendar)
        #expect(custom == RecurrencePlan(
            frequency: .monthly,
            interval: 5,
            daysOfTheMonth: [28, 29, 30, 31],
            setPositions: [-1]
        ))
    }

    @Test("A yearly anchor is a year, and two years is the same rule twice as slow")
    func yearlyIntervals() {
        #expect(RecurrencePlan.plan(for: .yearly, anchor: Fixed.day(2026, 3, 15), calendar: calendar)
                == RecurrencePlan(frequency: .yearly, interval: 1))
        #expect(RecurrencePlan.plan(for: .everyTwoYears, anchor: Fixed.day(2026, 1, 31), calendar: calendar)
                == RecurrencePlan(frequency: .yearly, interval: 2))
    }

    @Test("A yearly anchor on 29 February falls back to the 28th in the three years it is missing")
    func yearlyOnLeapDay() {
        let leapDay = Fixed.day(2024, 2, 29)
        let expected = RecurrencePlan(
            frequency: .yearly,
            interval: 1,
            daysOfTheMonth: [28, 29],
            monthsOfTheYear: [2],
            setPositions: [-1]
        )
        #expect(RecurrencePlan.plan(for: .yearly, anchor: leapDay, calendar: calendar) == expected)

        var everyTwoYears = expected
        everyTwoYears.interval = 2
        #expect(RecurrencePlan.plan(for: .everyTwoYears, anchor: leapDay, calendar: calendar) == everyTwoYears)
    }

    // MARK: - The cross-check

    /// Every shape the clamp has to survive: a 31st, a 30th, a leap day, and a day no
    /// month is ever short of.
    @Test(
        "A plan expands to exactly the dates the app's own schedule produces",
        arguments: [
            (Fixed.day(2026, 1, 31), BillingCycle.monthly),
            (Fixed.day(2026, 1, 30), BillingCycle.monthly),
            (Fixed.day(2024, 2, 29), BillingCycle.monthly),
            (Fixed.day(2026, 3, 15), BillingCycle.monthly),
            (Fixed.day(2026, 1, 31), BillingCycle.quarterly),
            (Fixed.day(2026, 1, 31), BillingCycle.custom(months: 5)),
            (Fixed.day(2024, 2, 29), BillingCycle.yearly),
            (Fixed.day(2024, 2, 29), BillingCycle.everyTwoYears),
            (Fixed.day(2026, 3, 15), BillingCycle.weekly)
        ]
    )
    func expansionMatchesTheSchedule(anchor: Date, cycle: BillingCycle) throws {
        let plan = RecurrencePlan.plan(for: cycle, anchor: anchor, calendar: calendar)
        let expanded = expand(plan, anchor: anchor, periods: 24)

        // Two years of a monthly plan, a fortnight short of half a century of a two-year
        // one: enough of either to walk through every February in question.
        #expect(expanded.count == 24)
        let last = try #require(expanded.last)

        let scheduled = RenewalSchedule.occurrences(
            anchor: anchor,
            cycle: cycle,
            from: anchor,
            to: calendar.date(byAdding: .day, value: 1, to: last) ?? last,
            calendar: calendar
        )
        #expect(expanded == scheduled)
    }

    @Test("Without the clamp the rule would skip every month that is too short")
    func aPlainRuleLosesFebruary() {
        // What a naive mapping writes: monthly on the anchor's day and nothing else.
        // RFC 5545 has no 31 February to offer, so the charge simply does not happen —
        // which is the bug the day list and the set position exist to prevent.
        let naive = RecurrencePlan(frequency: .monthly, interval: 1)
        let expanded = expand(naive, anchor: Fixed.day(2026, 1, 31), periods: 24)
        #expect(expanded.count < 24)
        #expect(!expanded.contains(Fixed.day(2026, 2, 28)))
    }

    // MARK: - A reader for the rule

    /// The smallest expander that reads a `RecurrencePlan` the way a calendar would:
    /// step period by period, and in each period take the last of the candidate days
    /// that the month actually has (`setPositions == [-1]`). A period whose days do not
    /// exist produces nothing, exactly as RFC 5545 says.
    private func expand(_ plan: RecurrencePlan, anchor: Date, periods: Int) -> [Date] {
        let anchorDay = calendar.component(.day, from: anchor)
        let anchorMonth = calendar.component(.month, from: anchor)
        let anchorYear = calendar.component(.year, from: anchor)
        let candidates = plan.daysOfTheMonth ?? [anchorDay]

        var dates: [Date] = []
        for period in 0..<periods {
            switch plan.frequency {
            case .weekly:
                let stepped = calendar.date(byAdding: .day, value: 7 * plan.interval * period, to: anchor)
                if let stepped { dates.append(calendar.startOfDay(for: stepped)) }
            case .monthly:
                let months = anchorYear * 12 + (anchorMonth - 1) + plan.interval * period
                if let date = lastExistingDay(candidates, year: months / 12, month: months % 12 + 1) {
                    dates.append(date)
                }
            case .yearly:
                let year = anchorYear + plan.interval * period
                let month = plan.monthsOfTheYear?.first ?? anchorMonth
                if let date = lastExistingDay(candidates, year: year, month: month) {
                    dates.append(date)
                }
            }
        }
        return dates
    }

    /// The last of `days` that this month has — the whole meaning of `[-1]`.
    private func lastExistingDay(_ days: [Int], year: Int, month: Int) -> Date? {
        for day in days.sorted().reversed() {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == day,
                  calendar.component(.month, from: date) == month
            else { continue }
            return calendar.startOfDay(for: date)
        }
        return nil
    }
}
