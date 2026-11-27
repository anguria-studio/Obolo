import Foundation

/// The width of one bar in a `SpendTimeline`; Home's Months chart draws months.
///
/// Every case is a whole number of months, so all three snap to the same boundaries
/// `MonthRange` already decides: a quarter is three of its months and a year is twelve.
/// Nothing here invents a second opinion about where March begins.
///
/// There is no `.week` on purpose. Billing cycles are anchored to a day of the month,
/// so a weekly bucket puts the same monthly charge in a different bar depending on
/// which weekday the month started, and the shape it draws is an artefact of the
/// calendar rather than of the spending.
public enum SpendInterval: String, Codable, Hashable, Sendable, CaseIterable {
    case month
    case quarter
    case year

    /// How many months one bucket spans.
    public var months: Int {
        switch self {
        case .month: 1
        case .quarter: 3
        case .year: 12
        }
    }

    /// The first day of the bucket `date` falls in.
    ///
    /// Quarters are calendar quarters (January, April, July, October), not quarters
    /// measured from the requested window: two windows over the same data have to
    /// bucket it the same way, or the same charge lands in "Q1" in one view and "Q2"
    /// in another.
    public func start(of date: Date, calendar: Calendar) -> Date {
        let monthStart = MonthRange.start(of: date, calendar: calendar)
        let month = calendar.component(.month, from: monthStart)
        let stepBack: Int
        switch self {
        case .month: stepBack = 0
        case .quarter: stepBack = (month - 1) % 3
        case .year: stepBack = month - 1
        }
        guard stepBack > 0 else { return monthStart }
        return MonthRange.start(of: monthStart, offsetByMonths: -stepBack, calendar: calendar)
    }

    /// `[start, end)` for the bucket `date` falls in.
    public func bounds(of date: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let first = start(of: date, calendar: calendar)
        return (first, MonthRange.start(of: first, offsetByMonths: months, calendar: calendar))
    }

    /// The bucket `count` buckets away from the one starting at `start`. Negative steps
    /// back, which is what a "previous year" control asks for.
    public func start(of date: Date, offsetByBuckets count: Int, calendar: Calendar) -> Date {
        let first = start(of: date, calendar: calendar)
        guard count != 0 else { return first }
        return MonthRange.start(of: first, offsetByMonths: months * count, calendar: calendar)
    }
}
