import Foundation

/// The subscription detail's queries: every payment from the first to the next, and the
/// prices the subscription has had.
extension Ledger {

    /// One payment on the detail's price-history chart.
    public struct Payment: Sendable, Equatable, Identifiable {
        public let date: Date
        public let price: Decimal
        public let currency: String
        /// The upcoming payment: drawn as an outline, not yet paid.
        public let isNext: Bool
        /// Set on the first payment at a new price: how far the price moved from the one
        /// before (same currency only).
        public let change: Decimal?

        public var id: Date { date }
    }

    /// Every payment from the first payment up to today (or the day billing stopped),
    /// then the next one when there is one. A payment due today is the next one, not a
    /// paid one, until the day is over. Empty without a first payment.
    ///
    /// The same window `paidSoFar` counts, so the bars and "Total spent" agree.
    public func payments(for id: Subscription.ID) -> [Payment] {
        guard let summary = summary(id: id),
              let anchor = summary.subscription.anchorDate?.startOfDay(in: calendar)
        else { return [] }
        let subscription = summary.subscription
        let paidThrough: Date
        if subscription.status.isBilling {
            paidThrough = today
        } else if let stopped = subscription.billingStoppedOn?.startOfDay(in: calendar) {
            paidThrough = min(today, stopped)
        } else {
            paidThrough = anchor
        }

        // `occurrences` is half-open at the end: a payment due today is still the next
        // one until the day is over, as in "Total spent" and the top card's "Next payment".
        let dates = RenewalSchedule.occurrences(
            anchor: anchor, cycle: subscription.cycle,
            from: anchor, to: paidThrough, calendar: calendar
        )
        var result: [Payment] = []
        var previous: (price: Decimal, currency: String)?
        func append(_ date: Date, isNext: Bool) {
            let charge = subscription.price(on: date, calendar: calendar)
            var change: Decimal?
            if let previous, previous.currency == charge.currency, previous.price != charge.price {
                change = charge.price - previous.price
            }
            result.append(Payment(date: date, price: charge.price, currency: charge.currency, isNext: isNext, change: change))
            previous = (charge.price, charge.currency)
        }
        for date in dates where date >= anchor { append(date, isNext: false) }
        if subscription.status.isBilling, let next = summary.nextPayment,
           !result.contains(where: { calendar.isDate($0.date, inSameDayAs: next) }) {
            append(next, isNext: true)
        }
        return result
    }
}

extension Subscription {
    /// One price and the day it took over, for the detail's price list.
    public struct PricePeriod: Sendable, Equatable {
        public let start: Date
        public let price: Decimal
        public let currency: String
        /// The move from the period before, when both are in the same currency.
        public let change: Decimal?
        /// Whether this is the price in force on the given day.
        public let isCurrent: Bool
    }

    /// Every price the subscription has had, oldest first: the first starting at the
    /// first payment (or its own date without one), each later one at its change.
    public func pricePeriods(today: Date, calendar: Calendar) -> [PricePeriod] {
        var entries: [(start: Date, price: Decimal, currency: String)] =
            priceChanges.map { ($0.effectiveFrom.startOfDay(in: calendar), $0.price, $0.currency) }
            + [(currentPriceStart?.startOfDay(in: calendar) ?? createdAt, price, currency)]
        if let anchorDate = anchorDate?.startOfDay(in: calendar) {
            // The list starts at the first payment: of the prices set by then only the
            // last one was ever paid, and it counts from that payment.
            if let lastBefore = entries.lastIndex(where: { calendar.startOfDay(for: $0.start) <= anchorDate }) {
                entries.removeFirst(lastBefore)
            }
            if !entries.isEmpty { entries[0].start = anchorDate }
        }
        let inForce = price(on: today, calendar: calendar)
        let todayStart = calendar.startOfDay(for: today)
        // The last period that has started by today is the current one.
        let currentIndex = entries.lastIndex { calendar.startOfDay(for: $0.start) <= todayStart } ?? 0
        return entries.enumerated().map { index, entry in
            var change: Decimal?
            if index > 0, entries[index - 1].currency == entry.currency, entries[index - 1].price != entry.price {
                change = entry.price - entries[index - 1].price
            }
            return PricePeriod(
                start: entry.start,
                price: entry.price,
                currency: entry.currency,
                change: change,
                isCurrent: index == currentIndex && entry.price == inForce.price
            )
        }
    }
}
