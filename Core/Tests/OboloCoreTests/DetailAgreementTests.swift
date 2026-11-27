import Foundation
import Testing
@testable import OboloCore

/// The Detail states one fact four times: "Total spent" (`paidSoFar`), the chart's
/// header and drawing (`DetailHistory.paid`), the payments count under it (the paid
/// `Ledger.payments`) and the top card's "Next payment". The rule they share: a charge
/// due today is the next one, not a paid one, until the day is over.
///
/// Each case pins today to the day before a payment, the payment day (at its first and
/// last minute) and the day after, and checks that every figure moves on the same day.
@Suite("Detail figures agree on a payment day")
struct DetailAgreementTests {

    private static let calendar = Fixed.calendar

    /// Every Detail figure for `subscription` at `today`, checked against `paid`
    /// payments made and `next` as the next payment.
    private func expectAgreement(
        _ subscription: Subscription,
        today: Date,
        paid expected: Int,
        next expectedNext: Date?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let calendar = Self.calendar
        let ledger = Ledger(document: Fixed.document([subscription]), today: today, calendar: calendar)
        guard let summary = ledger.summary(id: subscription.id) else {
            Issue.record("No summary", sourceLocation: sourceLocation)
            return
        }
        let payments = ledger.payments(for: subscription.id)
        let history = DetailHistory(subscription: subscription, payments: payments, today: today, calendar: calendar)
        let todayStart = calendar.startOfDay(for: today)

        // "Total spent": `–` (nil) with nothing paid, never a zero.
        #expect((summary.paidSoFar?.count ?? 0) == expected, "paidSoFar.count", sourceLocation: sourceLocation)
        if expected == 0 {
            #expect(summary.paidSoFar == nil, "Total spent is – with nothing paid", sourceLocation: sourceLocation)
        }

        // The payments count under the chart ("N payments") counts the paid payments.
        #expect(payments.filter { !$0.isNext }.count == expected, "N payments", sourceLocation: sourceLocation)

        // The chart and its header.
        #expect(history.paid.count == expected, "chart's paid count", sourceLocation: sourceLocation)
        #expect(history.paid.allSatisfy { $0.date < todayStart }, "nothing paid on or after today", sourceLocation: sourceLocation)
        var chartTotals: [String: Decimal] = [:]
        for item in history.paid { chartTotals[item.currency, default: 0] += item.amount }
        #expect(chartTotals == (summary.paidSoFar?.totalsByCurrency ?? [:]), "header total = Total spent", sourceLocation: sourceLocation)

        // "Next payment" in the top card, and the one orange block.
        #expect(summary.nextPayment == expectedNext, "Next payment", sourceLocation: sourceLocation)
        let nextItems = history.items.filter { $0.state == .next }
        #expect(nextItems.map(\.date) == (expectedNext.map { [$0] } ?? []), "chart's next block", sourceLocation: sourceLocation)
        #expect(payments.filter(\.isNext).map(\.date) == (expectedNext.map { [$0] } ?? []), "payments' next", sourceLocation: sourceLocation)
        if let expectedNext {
            #expect(expectedNext >= todayStart, "the next payment is today or later", sourceLocation: sourceLocation)
        }
    }

    /// The day before `day`, `day` at 00:00 and 23:59, and the day after.
    private func around(_ day: Date) -> (before: Date, start: Date, end: Date, after: Date) {
        let calendar = Self.calendar
        return (
            calendar.date(byAdding: .day, value: -1, to: day)!,
            day,
            calendar.date(byAdding: .minute, value: 23 * 60 + 59, to: day)!,
            calendar.date(byAdding: .day, value: 1, to: day)!
        )
    }

    @Test("Weekly: the charge on the day is paid from the day after")
    func weekly() {
        // Mondays from 2 Nov 2026: 2, 9, 16, 23, 30 Nov.
        let plan = Fixed.subscription("Weekly", price: "3.50", cycle: .weekly, anchor: Fixed.day(2026, 11, 2))
        let day = around(Fixed.day(2026, 11, 23))
        expectAgreement(plan, today: day.before, paid: 3, next: Fixed.day(2026, 11, 23))
        expectAgreement(plan, today: day.start, paid: 3, next: Fixed.day(2026, 11, 23))
        expectAgreement(plan, today: day.end, paid: 3, next: Fixed.day(2026, 11, 23))
        expectAgreement(plan, today: day.after, paid: 4, next: Fixed.day(2026, 11, 30))
    }

    @Test("Monthly on the 31st: the clamped 30 Nov is paid from 1 Dec")
    func monthlyOnThe31st() {
        // 31 Jan, 28 Feb, 31 Mar, 30 Apr, 31 May, 30 Jun, 31 Jul, 31 Aug, 30 Sep, 31 Oct,
        // 30 Nov, 31 Dec.
        let plan = Fixed.subscription("Month end", price: "9.99", anchor: Fixed.day(2026, 1, 31))
        let day = around(Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.before, paid: 10, next: Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.start, paid: 10, next: Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.end, paid: 10, next: Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.after, paid: 11, next: Fixed.day(2026, 12, 31))

        // February's clamp as well: 28 Feb is the second payment.
        let february = around(Fixed.day(2026, 2, 28))
        expectAgreement(plan, today: february.before, paid: 1, next: Fixed.day(2026, 2, 28))
        expectAgreement(plan, today: february.start, paid: 1, next: Fixed.day(2026, 2, 28))
        expectAgreement(plan, today: february.after, paid: 2, next: Fixed.day(2026, 3, 31))
    }

    @Test("Monthly on the 31st with a price change: the totals follow the same days")
    func monthlyOnThe31stWithAPriceChange() {
        var plan = Fixed.subscription("Month end, rose", price: "12.00", anchor: Fixed.day(2026, 1, 31))
        plan.priceChanges = [PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 31), price: Fixed.money("10.00"), currency: "EUR")]
        plan.currentPriceSince = Fixed.billingDay(2026, 11, 1)
        let day = around(Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.before, paid: 10, next: Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.end, paid: 10, next: Fixed.day(2026, 11, 30))
        expectAgreement(plan, today: day.after, paid: 11, next: Fixed.day(2026, 12, 31))

        // Ten at 10 €, then the 30 Nov charge at 12 €.
        let after = Ledger(document: Fixed.document([plan]), today: day.after, calendar: Self.calendar)
        #expect(after.summary(id: plan.id)?.paidSoFar?.totalsByCurrency == ["EUR": Fixed.money("112.00")])
    }

    @Test("A first payment today: nothing paid until tomorrow")
    func firstPaymentToday() {
        let plan = Fixed.subscription("New", price: "5.00", anchor: Fixed.day(2026, 11, 26))
        let day = around(Fixed.day(2026, 11, 26))
        expectAgreement(plan, today: day.before, paid: 0, next: Fixed.day(2026, 11, 26))
        expectAgreement(plan, today: day.start, paid: 0, next: Fixed.day(2026, 11, 26))
        expectAgreement(plan, today: day.end, paid: 0, next: Fixed.day(2026, 11, 26))
        expectAgreement(plan, today: day.after, paid: 1, next: Fixed.day(2026, 12, 26))
    }

    @Test("Cancelled with an end date: a last charge counts from the day after; the stop day charges nothing")
    func cancelledWithAnEndDate() {
        // 10 Jan … 10 Sep charged; billing stopped on 10 Oct, the day the next would land.
        let plan = Fixed.subscription(
            "Cancelled", price: "7.00", anchor: Fixed.day(2026, 1, 10), status: .cancelled,
            billingStoppedOn: Fixed.billingDay(2026, 10, 10), endsOn: Fixed.billingDay(2026, 10, 10)
        )
        let last = around(Fixed.day(2026, 9, 10))
        expectAgreement(plan, today: last.before, paid: 8, next: nil)
        expectAgreement(plan, today: last.start, paid: 8, next: nil)
        expectAgreement(plan, today: last.end, paid: 8, next: nil)
        expectAgreement(plan, today: last.after, paid: 9, next: nil)

        let stop = around(Fixed.day(2026, 10, 10))
        expectAgreement(plan, today: stop.before, paid: 9, next: nil)
        expectAgreement(plan, today: stop.start, paid: 9, next: nil)
        expectAgreement(plan, today: stop.after, paid: 9, next: nil)
    }
}
