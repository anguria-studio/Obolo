import Foundation

/// Dates, rendered through the Mac's locale.
///
/// Show relative dates within a week. For later payments, use an absolute date that
/// readers can check against a statement. Include the year when it differs from the current year.
public enum DateFormatting {

    /// The window inside which a date is described relative to today.
    public static let relativeWindowDays = 7

    /// "today" · "tomorrow" · "in 2 days" · "17 Sep" · "2 Jan 2027".
    public static func renewal(
        _ date: Date,
        today: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> String {
        let days = RenewalSchedule.daysUntil(date, today: today, calendar: calendar)
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...relativeWindowDays: return "in \(days) days"
        case (-relativeWindowDays)...(-2): return "\(-days) days ago"
        default: return absolute(date, today: today, calendar: calendar, locale: locale)
        }
    }

    /// "17 Sep" this year, "2 Jan 2027" beyond it. Ordering follows the locale, so an
    /// American Mac gets "Sep 17".
    public static func absolute(
        _ date: Date,
        today: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
        var style = base(calendar: calendar, locale: locale).day().month(.abbreviated)
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }

    /// "2 Jan 2027" — always with the year. For anything that outlives the current
    /// glance: notes, exports shown to the user, the "Paid so far" hint.
    public static func full(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        date.formatted(base(calendar: calendar, locale: locale).day().month(.abbreviated).year())
    }

    public static func dayAndMonth(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        date.formatted(base(calendar: calendar, locale: locale).day().month(.abbreviated))
    }

    /// "Sunday" — the notification title's "Netflix renews **Sunday**".
    public static func weekday(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        date.formatted(base(calendar: calendar, locale: locale).weekday(.wide))
    }

    /// "Tue 25 Aug" — the add/edit sheet's live preview line, where the weekday is what
    /// makes a clamped month-end date believable.
    public static func weekdayAndDate(
        _ date: Date,
        today: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
        var style = base(calendar: calendar, locale: locale).weekday(.abbreviated).day().month(.abbreviated)
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }

    /// "August 2026" — the month headers the Upcoming section groups under.
    public static func monthAndYear(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        date.formatted(base(calendar: calendar, locale: locale).month(.wide).year())
    }

    /// "November" — the twelve-month strip's peak caption.
    public static func month(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        date.formatted(base(calendar: calendar, locale: locale).month(.wide))
    }

    /// ISO `yyyy-MM-dd`, for CSV and for anything that must not depend on a locale.
    public static func iso(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// A format style pinned to the injected calendar and its time zone, so tests do
    /// not read the machine's.
    private static func base(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}
