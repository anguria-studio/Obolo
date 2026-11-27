import Foundation
import Testing
@testable import OboloCore

@Suite("Home queries")
struct LedgerHomeTests {

    @Test("Tick runs add up to the tick count and follow the amounts")
    func tickRuns() {
        let runs = TickAllocation.runs(
            for: [Fixed.money("21.96"), Fixed.money("2.99"), Fixed.money("14.99"),
                  Fixed.money("104.80"), Fixed.money("7.99"), Fixed.money("7.99")],
            count: 100
        )
        #expect(runs.reduce(0, +) == 100)
        #expect(runs[3] == 65)
        #expect(runs[1] == 2)
    }

    @Test("Zero amounts own no ticks, and nothing countable gives zeros")
    func tickRunsEdges() {
        #expect(TickAllocation.runs(for: [0, Fixed.money("10")], count: 100) == [0, 100])
        #expect(TickAllocation.runs(for: [0, 0], count: 100) == [0, 0])
        #expect(TickAllocation.runs(for: [], count: 100) == [])
    }

    @Test("The month splits into paid and to come around today")
    func monthProgress() {
        let early = Subscription(
            name: "Early", categoryID: Category.fallbackID,
            price: Fixed.money("10"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 7, 3), createdAt: Fixed.today
        )
        let late = Subscription(
            name: "Late", categoryID: Category.fallbackID,
            price: Fixed.money("5"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 7, 28), createdAt: Fixed.today
        )
        let ledger = Ledger(document: Fixed.document([early, late]), today: Fixed.today, calendar: Fixed.calendar)
        let progress = ledger.monthProgress()

        #expect(progress.payments.map(\.name) == ["Early", "Late"])
        #expect(progress.paid == Fixed.money("10"))
        #expect(progress.toCome == Fixed.money("5"))
        #expect(progress.total == Fixed.money("15"))
        #expect(progress.tickRuns().reduce(0, +) == 100)
    }

    @Test("A price change since last month moves the monthly total")
    func priceChangeDelta() {
        var plan = Subscription(
            name: "Plan", categoryID: Category.fallbackID,
            price: Fixed.money("12"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 10), createdAt: Fixed.today
        )
        plan.priceChanges = [PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 10), price: Fixed.money("10"), currency: "EUR")]
        plan.currentPriceSince = Fixed.billingDay(2026, 8, 10)

        let steady = Subscription(
            name: "Steady", categoryID: Category.fallbackID,
            price: Fixed.money("7"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 10), createdAt: Fixed.today
        )
        let ledger = Ledger(document: Fixed.document([plan, steady]), today: Fixed.today, calendar: Fixed.calendar)

        #expect(ledger.monthlyTotalChange(since: Fixed.day(2026, 7, 22)) == Fixed.money("2"))
        #expect(ledger.monthlyTotalChange(since: Fixed.day(2026, 8, 20)) == nil)
    }

    @Test("Another month is all paid behind today and all to come ahead of it")
    func otherMonths() {
        let plan = Subscription(
            name: "Plan", categoryID: Category.fallbackID,
            price: Fixed.money("10"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 15), createdAt: Fixed.today
        )
        let ledger = Ledger(document: Fixed.document([plan]), today: Fixed.today, calendar: Fixed.calendar)

        let june = ledger.monthProgress(containing: Fixed.day(2026, 6, 1), paidThrough: Fixed.today)
        #expect(june.paid == Fixed.money("10"))
        #expect(june.toCome == 0)

        let october = ledger.monthProgress(containing: Fixed.day(2026, 10, 1), paidThrough: Fixed.today)
        #expect(october.paid == 0)
        #expect(october.toCome == Fixed.money("10"))

        #expect(ledger.referenceDate(forMonthContaining: Fixed.day(2026, 8, 3)) == Fixed.today)
        #expect(ledger.referenceDate(forMonthContaining: Fixed.day(2026, 6, 9)) == Fixed.day(2026, 6, 30))
        #expect(ledger.referenceDate(forMonthContaining: Fixed.day(2026, 10, 9)) == Fixed.day(2026, 10, 1))
    }

    @Test("A month ahead of a price rise reads the new price")
    func datedLedger() {
        var plan = Subscription(
            name: "Plan", categoryID: Category.fallbackID,
            price: Fixed.money("12"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 10), createdAt: Fixed.today
        )
        plan.priceChanges = [PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 10), price: Fixed.money("10"), currency: "EUR")]
        plan.currentPriceSince = Fixed.billingDay(2026, 10, 10)
        let ledger = Ledger(document: Fixed.document([plan]), today: Fixed.today, calendar: Fixed.calendar)

        #expect(ledger.ledger(forMonthContaining: Fixed.day(2026, 11, 1)).monthlyTotal == Fixed.money("12"))
        #expect(ledger.ledger(forMonthContaining: Fixed.day(2026, 8, 1)).monthlyTotal == ledger.monthlyTotal)
    }

    @Test("Renewals count only the cycles longer than a month")
    func renewals() {
        let monthly = Subscription(
            name: "Monthly", categoryID: Category.fallbackID,
            price: Fixed.money("10"), currency: "EUR", cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 5), createdAt: Fixed.today
        )
        let yearly = Subscription(
            name: "Yearly", categoryID: Category.fallbackID,
            price: Fixed.money("99"), currency: "EUR", cycle: .yearly,
            anchorDate: Fixed.billingDay(2025, 8, 26), createdAt: Fixed.today
        )
        let ledger = Ledger(document: Fixed.document([monthly, yearly]), today: Fixed.today, calendar: Fixed.calendar)
        #expect(ledger.renewalsCharged(from: Fixed.day(2026, 8, 1), to: Fixed.day(2026, 9, 1)) == Fixed.money("99"))
        #expect(ledger.renewalsCharged(from: Fixed.day(2026, 7, 1), to: Fixed.day(2026, 8, 1)) == 0)
    }
}
