import Foundation

/// A calendar month as a half-open range of days, `[start, end)`.
///
/// One place decides where a month begins and ends, so `Ledger.monthTotal` and the
/// grid the Calendar section draws cannot disagree about which charges belong to
/// March. Every value is a start of day in the injected calendar's time zone.
public enum MonthRange {

    /// The first day of the month `date` falls in.
    public static func start(of date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }

    /// The first day of the month `months` away from the one `date` falls in. Negative
    /// steps back, which is what the previous-month chevron asks for.
    public static func start(of date: Date, offsetByMonths months: Int, calendar: Calendar) -> Date {
        let first = start(of: date, calendar: calendar)
        guard months != 0 else { return first }
        return calendar.date(byAdding: .month, value: months, to: first) ?? first
    }

    /// `[first of this month, first of next month)`.
    public static func bounds(of date: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let first = start(of: date, calendar: calendar)
        return (first, start(of: first, offsetByMonths: 1, calendar: calendar))
    }
}
