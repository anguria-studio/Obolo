import Foundation

/// The single thing worth saying about a subscription right now.
///
/// One value, not a set: an All row has one alert mark and Needs attention one issue, so
/// the priority order in `AttentionEvaluator` is part of the design, not an
/// implementation detail.
public enum Attention: Hashable, Sendable {
    case none
    /// Renews within the fixed seven-day highlighting window.
    case dueSoon
    /// Renews today.
    case dueToday
    /// The price is a guess.
    case estimate
    /// The currency has no rate, so the item is out of the totals.
    case missingRate
    /// Active, but no anchor date — counts in totals, shows `—` for Next.
    case noDate
    /// Cancelled, with access until this date.
    case endsOn(Date)
    /// A trial that converts on this date.
    case trialEnds(Date)

    /// Whether this state belongs in the Needs attention list — i.e. whether the user
    /// can *do* something about it. `dueSoon` is news, not a problem, so it is not
    /// here; the dated cases only qualify once the date is close (see
    /// `Ledger.needsAttention`).
    public var isFixable: Bool {
        switch self {
        case .estimate, .missingRate, .noDate: true
        case .none, .dueSoon, .dueToday, .endsOn, .trialEnds: false
        }
    }

    /// The date this state hangs on, when it has one.
    public var date: Date? {
        switch self {
        case .endsOn(let date), .trialEnds(let date): date
        default: nil
        }
    }

    /// Short label for the status pill. Dated cases get theirs from
    /// `label(today:calendar:locale:)`, which can say "ends 5 Sep".
    public var shortLabel: String {
        switch self {
        case .none: ""
        case .dueSoon: "due soon"
        case .dueToday: "today"
        case .estimate: "estimate"
        case .missingRate: "no rate"
        case .noDate: "no date"
        case .endsOn: "ends"
        case .trialEnds: "trial ends"
        }
    }

    /// "ends 5 Sep" · "trial ends in 3 days" · the short label for everything else.
    public func label(today: Date, calendar: Calendar, locale: Locale = .current) -> String {
        switch self {
        case .endsOn(let date):
            "ends \(DateFormatting.renewal(date, today: today, calendar: calendar, locale: locale))"
        case .trialEnds(let date):
            "trial ends \(DateFormatting.renewal(date, today: today, calendar: calendar, locale: locale))"
        default:
            shortLabel
        }
    }
}
