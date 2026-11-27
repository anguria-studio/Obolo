import Foundation
import Testing
@testable import OboloCore

/// The date engine. Everything the app shows about *when* comes through here, so the
/// cases below are the ones that would otherwise be found by a user noticing their gym
/// membership drifted to the 28th.
@Suite("Renewal schedule")
struct RenewalScheduleTests {

    private let calendar = Fixed.calendar

    // MARK: - Month-end clamping

    @Test("A 31st anchor clamps to each month's end, measured from the anchor")
    func clampsFromTheAnchor() {
        let anchor = Fixed.day(2026, 1, 31)

        // The chain the design calls out. The second date is the trap: stepping from the
        // previous *clamped* date gives 28 Mar and then 28 Apr, and the day-of-month
        // never recovers. Stepping from the anchor gives back the 31st.
        let chain = RenewalSchedule.upcoming(
            anchor: anchor, cycle: .monthly, today: Fixed.day(2026, 2, 1), count: 4, calendar: calendar
        )
        #expect(chain == [
            Fixed.day(2026, 2, 28),
            Fixed.day(2026, 3, 31),
            Fixed.day(2026, 4, 30),
            Fixed.day(2026, 5, 31)
        ])
    }

    @Test("Each clamped step is also what nextPayment returns on its own")
    func clampedStepsAgreeWithNextPayment() {
        let anchor = Fixed.day(2026, 1, 31)
        func next(_ today: Date) -> Date {
            RenewalSchedule.nextPayment(anchor: anchor, cycle: .monthly, today: today, calendar: calendar)
        }
        #expect(next(Fixed.day(2026, 1, 31)) == Fixed.day(2026, 1, 31))   // today counts
        #expect(next(Fixed.day(2026, 2, 1)) == Fixed.day(2026, 2, 28))
        #expect(next(Fixed.day(2026, 3, 1)) == Fixed.day(2026, 3, 31))
        #expect(next(Fixed.day(2026, 4, 1)) == Fixed.day(2026, 4, 30))
        #expect(next(Fixed.day(2026, 5, 1)) == Fixed.day(2026, 5, 31))
    }

    @Test("February gains a day in a leap year")
    func clampsToLeapFebruary() {
        #expect(RenewalSchedule.nextPayment(
            anchor: Fixed.day(2028, 1, 31), cycle: .monthly, today: Fixed.day(2028, 2, 1), calendar: calendar
        ) == Fixed.day(2028, 2, 29))
    }

    @Test("A 29 February anchor survives the three years it does not exist")
    func clampsLeapDayAnchor() {
        // Every two years from 29 Feb 2020: 2022 and 2026 have no 29th, 2024 and 2028 do.
        let anchor = Fixed.day(2020, 2, 29)
        let dates = RenewalSchedule.upcoming(
            anchor: anchor, cycle: .everyTwoYears, today: Fixed.day(2021, 1, 1), count: 4, calendar: calendar
        )
        #expect(dates == [
            Fixed.day(2022, 2, 28),
            Fixed.day(2024, 2, 29),
            Fixed.day(2026, 2, 28),
            Fixed.day(2028, 2, 29)
        ])
    }

    // MARK: - Future anchors

    @Test("An anchor in the future is the next payment")
    func futureAnchorIsTheNextPayment() {
        // A 2-year plan paid up front, anchored 31 Aug 2028.
        let anchor = Fixed.day(2028, 8, 31)
        #expect(RenewalSchedule.nextPayment(
            anchor: anchor, cycle: .everyTwoYears, today: Fixed.today, calendar: calendar
        ) == anchor)
        #expect(RenewalSchedule.upcoming(
            anchor: anchor, cycle: .everyTwoYears, today: Fixed.today, count: 2, calendar: calendar
        ) == [anchor, Fixed.day(2030, 8, 31)])
    }

    @Test("Nothing has been paid on a subscription that has not charged yet")
    func futureAnchorHasNoPaymentsMade() {
        #expect(RenewalSchedule.paymentsMade(
            anchor: Fixed.day(2028, 8, 31), cycle: .everyTwoYears, today: Fixed.today, calendar: calendar
        ) == 0)
    }

    // MARK: - Cadences

    @Test("Weekly steps seven days and ignores months entirely")
    func weekly() {
        let anchor = Fixed.day(2026, 8, 5)   // Wednesday
        #expect(RenewalSchedule.nextPayment(
            anchor: anchor, cycle: .weekly, today: Fixed.today, calendar: calendar
        ) == Fixed.day(2026, 8, 26))
        #expect(RenewalSchedule.upcoming(
            anchor: anchor, cycle: .weekly, today: Fixed.today, count: 3, calendar: calendar
        ) == [Fixed.day(2026, 8, 26), Fixed.day(2026, 9, 2), Fixed.day(2026, 9, 9)])
        // 5, 12 and 19 August already went through.
        #expect(RenewalSchedule.paymentsMade(
            anchor: anchor, cycle: .weekly, today: Fixed.today, calendar: calendar
        ) == 3)
    }

    @Test("A weekly cycle that lands exactly on today counts today as next, not next week")
    func weeklyOnTheDay() {
        let anchor = Fixed.day(2026, 8, 1)   // 22 Aug is three weeks later to the day
        #expect(RenewalSchedule.nextPayment(
            anchor: anchor, cycle: .weekly, today: Fixed.today, calendar: calendar
        ) == Fixed.today)
        #expect(RenewalSchedule.paymentsMade(
            anchor: anchor, cycle: .weekly, today: Fixed.today, calendar: calendar
        ) == 3)
    }

    @Test("A custom cadence steps by its own month count, clamping like any other")
    func customMonths() {
        let anchor = Fixed.day(2026, 1, 31)
        // Every four months: 31 Jan, 31 May, 30 Sep — September has thirty days.
        #expect(RenewalSchedule.nextPayment(
            anchor: anchor, cycle: .custom(months: 4), today: Fixed.today, calendar: calendar
        ) == Fixed.day(2026, 9, 30))
        #expect(RenewalSchedule.paymentsMade(
            anchor: anchor, cycle: .custom(months: 4), today: Fixed.today, calendar: calendar
        ) == 2)
        #expect(RenewalSchedule.upcoming(
            anchor: anchor, cycle: .custom(months: 4), today: Fixed.today, count: 2, calendar: calendar
        ) == [Fixed.day(2026, 9, 30), Fixed.day(2027, 1, 31)])
    }

    @Test("Every two years steps twenty-four months")
    func everyTwoYears() {
        let anchor = Fixed.day(2024, 3, 15)
        #expect(RenewalSchedule.nextPayment(
            anchor: anchor, cycle: .everyTwoYears, today: Fixed.today, calendar: calendar
        ) == Fixed.day(2028, 3, 15))
        #expect(RenewalSchedule.paymentsMade(
            anchor: anchor, cycle: .everyTwoYears, today: Fixed.today, calendar: calendar
        ) == 2)   // 2024 and 2026
    }

    @Test("Quarterly and yearly land where a calendar says they should")
    func quarterlyAndYearly() {
        #expect(RenewalSchedule.nextPayment(
            anchor: Fixed.day(2025, 2, 9), cycle: .quarterly, today: Fixed.today, calendar: calendar
        ) == Fixed.day(2026, 11, 9))
        #expect(RenewalSchedule.nextPayment(
            anchor: Fixed.day(2023, 11, 4), cycle: .yearly, today: Fixed.today, calendar: calendar
        ) == Fixed.day(2026, 11, 4))
    }

    // MARK: - Counting

    @Test("Netflix has been charged eighteen times since February 2025")
    func paymentsMadeCountsEachChargeSinceTheAnchor() {
        // The Detail's "Total spent" of €251.82 — 18 × €13.99.
        #expect(RenewalSchedule.paymentsMade(
            anchor: Fixed.day(2025, 2, 24), cycle: .monthly, today: Fixed.today, calendar: calendar
        ) == 18)
    }

    @Test("A payment due today has not been made yet")
    func todayIsNotYetPaid() {
        let anchor = Fixed.day(2026, 2, 22)
        #expect(RenewalSchedule.nextPayment(anchor: anchor, cycle: .monthly, today: Fixed.today, calendar: calendar) == Fixed.today)
        // Six charges landed (Feb through July); today's has not.
        #expect(RenewalSchedule.paymentsMade(anchor: anchor, cycle: .monthly, today: Fixed.today, calendar: calendar) == 6)
    }

    // MARK: - Day arithmetic

    @Test("Days are counted in the calendar, not in seconds")
    func daysUntilSurvivesADaylightSavingChange() {
        // Europe/Rome puts its clocks back on 25 October 2026: the span below is 49
        // hours, and any implementation dividing by 86 400 would call it one day.
        #expect(RenewalSchedule.daysUntil(
            Fixed.day(2026, 10, 26), today: Fixed.day(2026, 10, 24), calendar: calendar
        ) == 2)
    }

    @Test("Days until is zero today, negative in the past")
    func daysUntilSigns() {
        #expect(RenewalSchedule.daysUntil(Fixed.today, today: Fixed.today, calendar: calendar) == 0)
        #expect(RenewalSchedule.daysUntil(Fixed.day(2026, 8, 24), today: Fixed.today, calendar: calendar) == 2)
        #expect(RenewalSchedule.daysUntil(Fixed.day(2026, 8, 20), today: Fixed.today, calendar: calendar) == -2)
    }

    @Test("A time of day on the anchor does not shift the schedule")
    func anchorTimeIsIgnored() {
        // Anchors arrive from a DatePicker and can carry an afternoon with them.
        let afternoon = calendar.date(byAdding: .hour, value: 15, to: Fixed.day(2026, 8, 24))!
        #expect(RenewalSchedule.nextPayment(
            anchor: afternoon, cycle: .monthly, today: Fixed.today, calendar: calendar
        ) == Fixed.day(2026, 8, 24))
    }

    @Test("Asking for no occurrences returns none")
    func upcomingWithZeroCount() {
        #expect(RenewalSchedule.upcoming(
            anchor: Fixed.day(2026, 1, 1), cycle: .monthly, today: Fixed.today, count: 0, calendar: calendar
        ).isEmpty)
    }
}
