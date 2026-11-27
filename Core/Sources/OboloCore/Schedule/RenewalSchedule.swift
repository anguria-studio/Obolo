import Foundation

/// Where every date in the app comes from.
///
/// The whole model is one sequence: `occurrence(0)` is the anchor, `occurrence(n)` is
/// the anchor advanced by *n* cycles. Two properties fall out of defining it that way,
/// and both are load-bearing:
///
/// - **Clamping is anchor-relative.** A 31 Jan anchor gives 28 Feb, 31 Mar, 30 Apr —
///   not 28 Feb, 28 Mar, 28 Apr. Stepping from the previous *clamped* date walks the
///   day-of-month down a notch every February and never recovers; stepping from the
///   anchor is what a real biller does.
/// - **Nothing accumulates.** `nextPayment`, `upcoming` and `paymentsMade` all resolve
///   to an index into the same sequence, so they cannot disagree with each other.
///
/// All comparisons are at day granularity in the injected calendar's time zone. Never
/// `TimeInterval` arithmetic: a month is not 30 days and a day is not always 86 400
/// seconds.
public enum RenewalSchedule {

    /// A cycle count high enough to cover a weekly plan anchored a century ago, and low
    /// enough that a pathological input fails fast instead of hanging the UI.
    private static let maximumSteps = 20_000

    /// The first occurrence on or after `today`.
    ///
    /// An anchor in the future *is* the next payment — the sample's 2-year plan, paid
    /// up front, anchored 31 Aug 2028.
    public static func nextPayment(anchor: Date, cycle: BillingCycle, today: Date, calendar: Calendar) -> Date {
        let anchorDay = calendar.startOfDay(for: anchor)
        let todayDay = calendar.startOfDay(for: today)
        guard anchorDay < todayDay else { return anchorDay }
        return occurrence(index: firstIndex(onOrAfter: todayDay, anchor: anchorDay, cycle: cycle, calendar: calendar),
                          anchor: anchorDay, cycle: cycle, calendar: calendar)
    }

    /// The next `count` occurrences, starting at `nextPayment`.
    ///
    /// Each one is computed from the anchor rather than from its predecessor, so the
    /// month-end clamp shows the biller's real dates: 31 Jan → 28 Feb → 31 Mar → 30 Apr.
    public static func upcoming(anchor: Date, cycle: BillingCycle, today: Date, count: Int, calendar: Calendar) -> [Date] {
        guard count > 0 else { return [] }
        let anchorDay = calendar.startOfDay(for: anchor)
        let todayDay = calendar.startOfDay(for: today)
        let start = anchorDay >= todayDay
            ? 0
            : firstIndex(onOrAfter: todayDay, anchor: anchorDay, cycle: cycle, calendar: calendar)
        return (0..<count).map {
            occurrence(index: start + $0, anchor: anchorDay, cycle: cycle, calendar: calendar)
        }
    }

    /// How many charges have already landed — occurrences strictly before `today`.
    ///
    /// This is the index of the first occurrence on or after today, which is exactly
    /// the number of occurrences below it. Zero for a future anchor, so the Detail's
    /// "Total spent" reads `–` rather than claiming nothing was paid.
    public static func paymentsMade(anchor: Date, cycle: BillingCycle, today: Date, calendar: Calendar) -> Int {
        let anchorDay = calendar.startOfDay(for: anchor)
        let todayDay = calendar.startOfDay(for: today)
        guard anchorDay < todayDay else { return 0 }
        return firstIndex(onOrAfter: todayDay, anchor: anchorDay, cycle: cycle, calendar: calendar)
    }

    /// Whole days from `today` to `date`, both taken at the start of their day. Negative
    /// in the past, 0 for today.
    public static func daysUntil(_ date: Date, today: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: today),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    /// Every occurrence inside `[from, to)`, in order.
    ///
    /// Unlike `upcoming`, this looks **backwards** as well: the Calendar section shows
    /// past months as what was actually paid, so a March grid has to list the charge
    /// that landed on 4 March. What it never does is invent history before the anchor —
    /// the sequence starts there, so a plan bought in June has nothing in May.
    ///
    /// Each date is still computed from the anchor, so the month-end clamp reads the
    /// same here as it does in the Detail's next payment: 31 Jan → 28 Feb → 31 Mar → 30 Apr.
    public static func occurrences(
        anchor: Date,
        cycle: BillingCycle,
        from: Date,
        to: Date,
        calendar: Calendar
    ) -> [Date] {
        let anchorDay = calendar.startOfDay(for: anchor)
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        guard fromDay < toDay, anchorDay < toDay else { return [] }

        // Below the anchor there is nothing, so an anchor inside (or after) the window
        // is simply where the walk starts.
        var index = anchorDay >= fromDay
            ? 0
            : firstIndex(onOrAfter: fromDay, anchor: anchorDay, cycle: cycle, calendar: calendar)

        var dates: [Date] = []
        while dates.count < maximumSteps {
            let date = occurrence(index: index, anchor: anchorDay, cycle: cycle, calendar: calendar)
            guard date < toDay else { break }
            dates.append(date)
            index += 1
        }
        return dates
    }

    // MARK: - The sequence

    /// The `index`-th occurrence, always measured from the anchor.
    public static func occurrence(index: Int, anchor: Date, cycle: BillingCycle, calendar: Calendar) -> Date {
        guard index > 0 else { return calendar.startOfDay(for: anchor) }
        let anchorDay = calendar.startOfDay(for: anchor)
        let stepped: Date?
        if let months = cycle.months {
            // `Calendar` already clamps an overflowing day-of-month to the end of the
            // target month, which is precisely the rule the design asks for.
            stepped = calendar.date(byAdding: .month, value: months * index, to: anchorDay)
        } else {
            stepped = calendar.date(byAdding: .day, value: 7 * index, to: anchorDay)
        }
        return calendar.startOfDay(for: stepped ?? anchorDay)
    }

    /// Smallest `n` with `occurrence(n) >= day`. Assumes `anchor < day`.
    private static func firstIndex(onOrAfter day: Date, anchor: Date, cycle: BillingCycle, calendar: Calendar) -> Int {
        var index = estimatedIndex(onOrAfter: day, anchor: anchor, cycle: cycle, calendar: calendar)

        // The estimate can land on either side — month arithmetic is not linear once
        // clamping is involved — so close in from wherever it put us.
        var guardrail = 0
        while index > 0,
              occurrence(index: index - 1, anchor: anchor, cycle: cycle, calendar: calendar) >= day,
              guardrail < maximumSteps {
            index -= 1
            guardrail += 1
        }
        while occurrence(index: index, anchor: anchor, cycle: cycle, calendar: calendar) < day,
              guardrail < maximumSteps {
            index += 1
            guardrail += 1
        }
        return index
    }

    /// A cheap first guess so the loops above run a handful of times, not a thousand,
    /// for an anchor set years ago.
    private static func estimatedIndex(onOrAfter day: Date, anchor: Date, cycle: BillingCycle, calendar: Calendar) -> Int {
        if let months = cycle.months {
            let elapsed = calendar.dateComponents([.month], from: anchor, to: day).month ?? 0
            return max(0, elapsed / max(1, months))
        }
        let elapsed = calendar.dateComponents([.day], from: anchor, to: day).day ?? 0
        return max(0, elapsed / 7)
    }
}
