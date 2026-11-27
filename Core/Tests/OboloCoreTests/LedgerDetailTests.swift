import Foundation
import Testing
@testable import OboloCore

@Suite("Detail queries")
struct LedgerDetailTests {

    private func plan(rose: Bool) -> Subscription {
        var plan = Subscription(
            name: "Plan", categoryID: Category.fallbackID,
            price: Fixed.money("12"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 3, 10), createdAt: Fixed.day(2026, 3, 1)
        )
        if rose {
            plan.priceChanges = [PriceChange(effectiveFrom: Fixed.billingDay(2026, 3, 10), price: Fixed.money("10"), currency: "EUR")]
            plan.currentPriceSince = Fixed.billingDay(2026, 6, 1)
        }
        return plan
    }

    @Test("Payments run from the first payment to the next, with the change marked once")
    func paymentsTimeline() {
        let subscription = plan(rose: true)
        let ledger = Ledger(document: Fixed.document([subscription]), today: Fixed.today, calendar: Fixed.calendar)
        let payments = ledger.payments(for: subscription.id)

        // 10 Mar … 10 Aug paid (six), 10 Sep next.
        #expect(payments.count == 7)
        #expect(payments.first?.date == Fixed.day(2026, 3, 10))
        #expect(payments.last?.isNext == true)
        #expect(payments.last?.date == Fixed.day(2026, 9, 10))
        #expect(payments.filter { !$0.isNext }.count == ledger.summary(id: subscription.id)?.paidSoFar?.count)
        #expect(payments.compactMap(\.change) == [Fixed.money("2")])
        #expect(payments.first { $0.change != nil }?.date == Fixed.day(2026, 6, 10))
    }

    @Test("Plans billed once a year or less often get the year strip; the rest keep trays or columns")
    func chartKindRule() {
        func kind(_ cycle: BillingCycle, anchor: Date = Fixed.day(2025, 3, 10), status: Status = .active, paid: Int = 3) -> DetailChartKind {
            var subscription = Subscription(
                name: "Plan", categoryID: Category.fallbackID,
                price: Fixed.money("12"), currency: "EUR", cycle: cycle,
                anchorDate: BillingDay(anchor, calendar: Fixed.calendar), createdAt: anchor
            )
            subscription.status = status
            return DetailChartKind.for(subscription, paidCount: paid, today: Fixed.today, calendar: Fixed.calendar)
        }
        #expect(kind(.yearly) == .yearStrip)
        #expect(kind(.everyTwoYears) == .yearStrip)
        #expect(kind(.custom(months: 12)) == .yearStrip)
        #expect(kind(.custom(months: 18)) == .yearStrip)

        #expect(kind(.weekly) == .coinColumns)
        #expect(kind(.quarterly) == .coinColumns)
        #expect(kind(.custom(months: 6)) == .coinColumns)

        // Monthly: trays within four calendar years, columns for a longer history.
        #expect(kind(.monthly) == .yearTrays)
        #expect(kind(.monthly, anchor: Fixed.day(2019, 3, 10)) == .coinColumns)

        // A trial with nothing paid yet keeps its one tray, whatever the cycle.
        #expect(kind(.yearly, status: .trial, paid: 0) == .yearTrays)
    }

    @Test("A payment due today is the next one: orange, not yet paid, and December still to come")
    func dueToday() {
        let today = Fixed.day(2026, 11, 25)
        let subscription = Subscription(
            name: "Gym", categoryID: Category.fallbackID,
            price: Fixed.money("14.99"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2025, 8, 25), createdAt: Fixed.day(2025, 8, 1)
        )
        let ledger = Ledger(document: Fixed.document([subscription]), today: today, calendar: Fixed.calendar)
        let payments = ledger.payments(for: subscription.id)
        let summary = ledger.summary(id: subscription.id)

        // 25 Aug 2025 … 25 Oct 2026 paid (15), 25 Nov 2026 next.
        #expect(summary?.nextPayment == today)
        #expect(payments.last?.date == today)
        #expect(payments.last?.isNext == true)
        #expect(payments.filter { !$0.isNext }.count == 15)
        #expect(payments.filter { !$0.isNext }.count == summary?.paidSoFar?.count)

        let history = DetailHistory(subscription: subscription, payments: payments, today: today, calendar: Fixed.calendar)
        #expect(history.paid.count == 15)
        #expect(history.item(year: 2026, month: 11)?.state == .next)
        #expect(history.item(year: 2026, month: 12)?.state == .toCome)
        #expect(history.items.filter { $0.state == .next }.count == 1)
    }

    @Test("No first payment, no bars")
    func noAnchor() {
        var subscription = plan(rose: false)
        subscription.anchorDate = nil
        let ledger = Ledger(document: Fixed.document([subscription]), today: Fixed.today, calendar: Fixed.calendar)
        #expect(ledger.payments(for: subscription.id).isEmpty)
    }

    @Test("Price periods start at the first payment and mark the price in force")
    func periods() {
        let periods = plan(rose: true).pricePeriods(today: Fixed.today, calendar: Fixed.calendar)
        #expect(periods.map(\.price) == [Fixed.money("10"), Fixed.money("12")])
        #expect(periods.map(\.start) == [Fixed.day(2026, 3, 10), Fixed.day(2026, 6, 1)])
        #expect(periods.map(\.change) == [nil, Fixed.money("2")])
        #expect(periods.map(\.isCurrent) == [false, true])

        let single = plan(rose: false).pricePeriods(today: Fixed.today, calendar: Fixed.calendar)
        #expect(single.count == 1)
        #expect(single[0].isCurrent)
    }

    @Test("A price set before the first payment counts from that payment; older ones drop")
    func periodsBeforeFirstPayment() {
        var subscription = plan(rose: true)
        subscription.priceChanges = [
            PriceChange(effectiveFrom: Fixed.billingDay(2025, 1, 1), price: Fixed.money("8"), currency: "EUR"),
            PriceChange(effectiveFrom: Fixed.billingDay(2025, 6, 1), price: Fixed.money("10"), currency: "EUR"),
        ]
        let periods = subscription.pricePeriods(today: Fixed.today, calendar: Fixed.calendar)
        #expect(periods.map(\.price) == [Fixed.money("10"), Fixed.money("12")])
        #expect(periods.first?.start == Fixed.day(2026, 3, 10))
        #expect(periods.first?.change == nil)
    }
}
