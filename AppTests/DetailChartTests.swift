import Foundation
import OboloCore
import Testing

/// The Detail's drawing counts what "Total spent" counts: a charge due today is the one
/// orange block, not a grey one, until the day is over. (The figures behind it are
/// checked in OboloCore's `DetailAgreementTests`; this checks the blocks drawn.)
@Suite("Detail chart")
struct DetailChartTests {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .gmt
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func plan(
        cycle: BillingCycle,
        anchor: Date,
        status: Status = .active,
        stopped: Date? = nil
    ) -> Subscription {
        let stopDay = stopped.map { BillingDay($0, calendar: calendar) }
        return Subscription(
            name: "Plan", categoryID: OboloCore.Category.fallbackID,
            price: 10, currency: "EUR", cycle: cycle,
            anchorDate: BillingDay(anchor, calendar: calendar), status: status,
            billingStoppedOn: stopDay, endsOn: stopDay,
            createdAt: day(2026, 1, 1)
        )
    }

    /// Paid and next blocks drawn at `today`, beside what "Total spent" counts and the
    /// top card's next payment.
    private static func drawn(_ subscription: Subscription, today: Date) -> (paid: Int, next: [Date], spent: Int, nextPayment: Date?) {
        var table = RateTable(base: "EUR")
        table.setRate(1, for: "EUR", updatedAt: today)
        let document = StoreDocument(
            subscriptions: [subscription], categories: OboloCore.Category.seeded,
            rates: table, settings: OboloCore.Settings(baseCurrency: "EUR")
        )
        let ledger = Ledger(document: document, today: today, calendar: calendar)
        let summary = ledger.summary(id: subscription.id)
        let history = DetailHistory(
            subscription: subscription, payments: ledger.payments(for: subscription.id),
            today: today, calendar: calendar
        )
        let kind = DetailChartKind.for(subscription, paidCount: history.paid.count, today: today, calendar: calendar)
        let scene = switch kind {
        case .yearTrays: IsoScene.yearTrays(history)
        case .coinColumns: IsoScene.coinColumns(history, subscription: subscription)
        case .yearStrip: IsoScene.yearStrip(history)
        }
        return (
            scene.prisms.count { $0.style == .paid },
            scene.prisms.filter { $0.style == .next }.compactMap(\.id),
            summary?.paidSoFar?.count ?? 0,
            summary?.nextPayment
        )
    }

    /// The day before `payment`, the day itself and the day after: paid blocks, next
    /// block and "Total spent" move on the same day.
    private static func expectAgreement(
        _ subscription: Subscription,
        payment: Date,
        paidBefore: Int,
        nextAfter: Date?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let isBilling = subscription.status.isBilling
        for (offset, paid) in [(-1, paidBefore), (0, paidBefore), (1, paidBefore + 1)] {
            let today = calendar.date(byAdding: .day, value: offset, to: payment)!
            let figures = drawn(subscription, today: today)
            #expect(figures.paid == paid, "paid blocks, day \(offset)", sourceLocation: sourceLocation)
            #expect(figures.spent == paid, "Total spent, day \(offset)", sourceLocation: sourceLocation)
            let next = offset < 1 ? payment : nextAfter
            let expectedNext = isBilling ? next.map { [$0] } ?? [] : []
            #expect(figures.next == expectedNext, "next block, day \(offset)", sourceLocation: sourceLocation)
            #expect(figures.nextPayment == (isBilling ? next : nil), "Next payment, day \(offset)", sourceLocation: sourceLocation)
        }
    }

    @Test("Weekly coin columns")
    func weekly() {
        let plan = Self.plan(cycle: .weekly, anchor: Self.day(2026, 11, 2))
        Self.expectAgreement(plan, payment: Self.day(2026, 11, 23), paidBefore: 3, nextAfter: Self.day(2026, 11, 30))
    }

    @Test("Monthly trays anchored on the 31st")
    func monthlyOnThe31st() {
        let plan = Self.plan(cycle: .monthly, anchor: Self.day(2026, 1, 31))
        Self.expectAgreement(plan, payment: Self.day(2026, 11, 30), paidBefore: 10, nextAfter: Self.day(2026, 12, 31))
    }

    @Test("A first payment today")
    func firstPaymentToday() {
        let plan = Self.plan(cycle: .monthly, anchor: Self.day(2026, 11, 26))
        // The day before, the anchor is already the next payment.
        Self.expectAgreement(plan, payment: Self.day(2026, 11, 26), paidBefore: 0, nextAfter: Self.day(2026, 12, 26))
    }

    @Test("Cancelled with an end date: the last charge and no next block")
    func cancelled() {
        let plan = Self.plan(
            cycle: .monthly, anchor: Self.day(2026, 1, 10), status: .cancelled, stopped: Self.day(2026, 10, 10)
        )
        Self.expectAgreement(plan, payment: Self.day(2026, 9, 10), paidBefore: 8, nextAfter: nil)
    }
}
