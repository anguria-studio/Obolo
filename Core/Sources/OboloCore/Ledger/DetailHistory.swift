import Foundation

// The data behind the detail's payment-history drawings: which of
// the two the subscription gets, and every payment they show.

// MARK: - Which chart

public enum DetailChartKind: Equatable, Sendable {
    /// A 4 × 3 tray of months per year.
    case yearTrays
    /// A stack of plates per year.
    case coinColumns
    /// One strip of year cells, a block per year: a plan that bills once a year or less
    /// often.
    case yearStrip

    /// The most years the trays show side by side.
    public static let maxTrayYears = 4

    /// The one rule, decided from the data. A trial with nothing paid yet gets one tray.
    /// A plan that bills once a year or less often (yearly, every two years, every 12+
    /// months) gets the year strip: as coin columns, one payment is a plate as thick as
    /// a whole year. A monthly plan whose first payment falls in the last four calendar
    /// years gets trays; a longer monthly history, or any other cycle (weekly,
    /// quarterly, every few months), gets columns. Price changes play no part.
    public static func `for`(
        _ subscription: Subscription,
        paidCount: Int,
        today: Date,
        calendar: Calendar
    ) -> DetailChartKind {
        if subscription.status == .trial, paidCount == 0 { return .yearTrays }
        if let months = subscription.cycle.months, months >= 12 { return .yearStrip }
        guard subscription.cycle == .monthly else { return .coinColumns }
        guard let anchor = subscription.anchorDate?.startOfDay(in: calendar) else { return .yearTrays }
        let years = calendar.component(.year, from: today) - calendar.component(.year, from: anchor) + 1
        return years <= maxTrayYears ? .yearTrays : .coinColumns
    }
}

// MARK: - The data

/// Every payment the drawing shows: those made, the next one, and the rest of this year.
///
/// A payment due today is the next one until the day is over (as in `Ledger.payments`
/// and "Total spent"); it turns into a paid one tomorrow.
public struct DetailHistory: Sendable {
    public enum State: Equatable, Sendable { case paid, next, toCome }

    public struct Item: Identifiable, Equatable, Sendable {
        public let date: Date
        public let amount: Decimal
        public let currency: String
        public let state: State
        public var id: Date { date }
    }

    public let items: [Item]
    public let firstYear: Int
    public let lastYear: Int
    public let currentYear: Int
    private let calendar: Calendar

    public init(subscription: Subscription, payments: [Ledger.Payment], today: Date, calendar: Calendar) {
        self.calendar = calendar
        let paid = payments.filter { !$0.isNext }
        var items = paid.map { Item(date: $0.date, amount: $0.price, currency: $0.currency, state: .paid) }
        let currentYear = calendar.component(.year, from: today)
        if let next = payments.first(where: \.isNext) {
            // A trial that has not been charged yet: its first payment is only a promise.
            let isUnpaidTrial = subscription.status == .trial && paid.isEmpty
            items.append(Item(date: next.date, amount: next.price, currency: next.currency, state: isUnpaidTrial ? .toCome : .next))
        }
        // The rest of this year, after the last payment shown, to 31 December — even if
        // no next payment was found, so a billing plan's year never ends early.
        if subscription.status.isBilling,
           let anchor = subscription.anchorDate?.startOfDay(in: calendar),
           let last = items.last,
           let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last.date)),
           let yearEnd = calendar.date(from: DateComponents(year: currentYear + 1, month: 1, day: 1)) {
            for date in RenewalSchedule.occurrences(anchor: anchor, cycle: subscription.cycle, from: dayAfter, to: yearEnd, calendar: calendar) {
                let charge = subscription.price(on: date, calendar: calendar)
                items.append(Item(date: date, amount: charge.price, currency: charge.currency, state: .toCome))
            }
        }
        self.items = items
        self.currentYear = currentYear
        firstYear = items.first.map { calendar.component(.year, from: $0.date) } ?? currentYear
        lastYear = max(currentYear, items.last.map { calendar.component(.year, from: $0.date) } ?? currentYear)
    }

    public var years: [Int] { Array(min(firstYear, lastYear)...lastYear) }
    public var paid: [Item] { items.filter { $0.state == .paid } }

    public func year(of item: Item) -> Int { calendar.component(.year, from: item.date) }

    public func items(in year: Int) -> [Item] { items.filter { self.year(of: $0) == year } }

    public func item(id: Date?) -> Item? { id.flatMap { id in items.first { $0.id == id } } }

    /// The item in a month (1–12), the last one when a month holds several.
    public func item(year: Int, month: Int) -> Item? {
        items.last {
            calendar.component(.year, from: $0.date) == year && calendar.component(.month, from: $0.date) == month
        }
    }
}
