import Foundation

/// The Home screen's queries: how the monthly figure moved, and how far through its
/// payments the current month is.
extension Ledger {

    // MARK: - Monthly spend change

    /// How much the monthly total moved since `date` because prices changed, in base
    /// currency, or `nil` when nothing changed.
    ///
    /// Only price history can be read back honestly. The document does not record when
    /// a subscription was added, paused or cancelled, so "what the total was a month
    /// ago" cannot be rebuilt; what can is the price each subscription counted today was
    /// charging on `date`. The figure is therefore today's total minus the same set of
    /// subscriptions at their earlier prices. A row without a rate is left out of both
    /// sides, as it is left out of the total.
    public func monthlyTotalChange(since date: Date) -> Decimal? {
        var delta = Decimal.zero
        for summary in summaries where summary.countsInTotals {
            guard let now = summary.monthlyInBase else { continue }
            let earlier = summary.subscription.price(on: date, calendar: calendar)
            guard let before = Normalizer.monthlyInBase(
                price: earlier.price,
                currency: earlier.currency,
                cycle: summary.cycle,
                rates: document.rates
            ) else { continue }
            delta += now - before
        }
        let rounded = Normalizer.rounded(delta)
        return rounded == 0 ? nil : rounded
    }

    // MARK: - Non-monthly

    /// What the longer cycles (quarterly, yearly and up) charged over `[from, to)`, in
    /// base currency: the part of a month that is not the steady monthly baseline. The
    /// Home month chart's "Non-monthly" figure. Charges without a rate are left out.
    public func renewalsCharged(from: Date, to: Date) -> Decimal {
        let total = occurrences(from: from, to: to).reduce(Decimal.zero) { sum, occurrence in
            guard let months = summary(id: occurrence.subscriptionID)?.cycle.months, months > 1 else { return sum }
            return sum + (occurrence.amountInBase ?? 0)
        }
        return Normalizer.rounded(total)
    }

    // MARK: - A month on Home

    /// The day Home reads a month at: today in the current month, the last day of a
    /// past month (everything in it has happened) and the first day of a future one.
    public func referenceDate(forMonthContaining date: Date) -> Date {
        let bounds = MonthRange.bounds(of: date, calendar: calendar)
        let current = MonthRange.bounds(of: today, calendar: calendar)
        if bounds.start == current.start { return today }
        if bounds.start < current.start {
            return calendar.date(byAdding: .day, value: -1, to: bounds.end) ?? bounds.start
        }
        return bounds.start
    }

    /// The same document seen on `referenceDate(forMonthContaining:)`: the monthly total,
    /// categories and price-change figures as they stood (or will stand) that month.
    /// Status is today's, because the document keeps no status history.
    public func ledger(forMonthContaining date: Date) -> Ledger {
        let reference = referenceDate(forMonthContaining: date)
        guard reference != today else { return self }
        return Ledger(document: document, today: reference, calendar: calendar)
    }

    // MARK: - This month

    /// The payments of the month that holds `today`, split into paid and to come.
    public func monthProgress() -> MonthProgress {
        monthProgress(containing: today, paidThrough: today)
    }

    /// The payments of the month that holds `date`. A payment on or before
    /// `paidThrough` counts as paid, so a past month is all paid and a future one all
    /// to come.
    public func monthProgress(containing date: Date, paidThrough: Date) -> MonthProgress {
        let bounds = MonthRange.bounds(of: date, calendar: calendar)
        let todayStart = calendar.startOfDay(for: paidThrough)
        let payments = occurrences(from: bounds.start, to: bounds.end).map { occurrence in
            MonthProgress.Payment(
                occurrence: occurrence,
                name: summary(id: occurrence.subscriptionID)?.name ?? "",
                // A charge due today is treated as taken: it leaves the account today.
                isPaid: occurrence.date <= todayStart
            )
        }
        return MonthProgress(month: bounds.start, payments: payments)
    }
}

/// One month's payments in date order, for the Home tick meter.
public struct MonthProgress: Sendable, Equatable {
    public struct Payment: Sendable, Equatable, Identifiable {
        public let occurrence: RenewalOccurrence
        public let name: String
        public let isPaid: Bool

        public var id: String { "\(occurrence.subscriptionID.uuidString)-\(occurrence.date.timeIntervalSinceReferenceDate)" }
    }

    /// The first day of the month.
    public let month: Date
    public let payments: [Payment]

    public init(month: Date, payments: [Payment]) {
        self.month = month
        self.payments = payments
    }

    /// Converted total of the month. Charges without a rate are excluded, never zero.
    public var total: Decimal { Normalizer.rounded(payments.reduce(.zero) { $0 + ($1.occurrence.amountInBase ?? 0) }) }
    public var paid: Decimal { Normalizer.rounded(payments.filter(\.isPaid).reduce(.zero) { $0 + ($1.occurrence.amountInBase ?? 0) }) }
    public var toCome: Decimal { Normalizer.rounded(payments.filter { !$0.isPaid }.reduce(.zero) { $0 + ($1.occurrence.amountInBase ?? 0) }) }
    /// Charges the totals leave out because their currency has no rate.
    public var excludedCount: Int { payments.count { $0.occurrence.amountInBase == nil } }

    /// How many of `count` ticks each payment owns, in payment order, proportional to its
    /// converted amount. Uses largest remainders so the runs always add up to `count`
    /// (when anything is countable at all), and a payment too small for a whole tick
    /// still gets one if a remainder falls its way. Excluded charges own no ticks.
    public func tickRuns(count: Int = 100) -> [Int] {
        TickAllocation.runs(for: payments.map { $0.occurrence.amountInBase ?? 0 }, count: count)
    }
}

/// Splits a fixed number of ticks between amounts.
public enum TickAllocation {
    /// Largest-remainder apportionment. Zero and negative amounts get no ticks; an empty
    /// or all-zero input gets an array of zeros.
    public static func runs(for amounts: [Decimal], count: Int) -> [Int] {
        let values = amounts.map { max(0, NSDecimalNumber(decimal: $0).doubleValue) }
        let total = values.reduce(0, +)
        guard total > 0, count > 0 else { return Array(repeating: 0, count: amounts.count) }

        let exact = values.map { $0 / total * Double(count) }
        var runs = exact.map { Int($0.rounded(.down)) }
        let missing = count - runs.reduce(0, +)
        let order = exact.indices
            .filter { values[$0] > 0 }
            .sorted { (exact[$0] - Double(runs[$0])) > (exact[$1] - Double(runs[$1])) }
        for index in order.prefix(missing) { runs[index] += 1 }
        return runs
    }
}
