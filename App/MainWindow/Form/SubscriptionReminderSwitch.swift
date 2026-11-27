import OboloCore

struct SubscriptionReminderSwitch {

    /// One segment of the form's Remind me switch: a lead in days (`noReminder` is Off)
    /// and its label.
    struct Segment: Equatable {
        let days: Int
        let title: String
    }

    let segments: [Segment]
    let selected: Int

    /// The four segments the switch always has.
    private static let standardSegments = [
        Segment(days: Subscription.noReminder, title: "Off"),
        Segment(days: 1, title: "1 day"),
        Segment(days: 2, title: "2 days"),
        Segment(days: 7, title: "1 week")
    ]

    /// The Remind me switch for a stored lead (`nil` uses `defaultLead`, the default
    /// from Settings › Reminders).
    ///
    /// The lit segment is always the lead that applies. When that lead has no standard
    /// segment (on the day, 3 or 14 days from Settings, or 5 from an older document), one
    /// more segment shows it, in its numeric place. It goes when a standard segment is
    /// picked. Showing it writes nothing: only a pick sets `reminderLeadDays`.
    init(stored: Int?, defaultLead: Int) {
        let lead = stored ?? defaultLead
        var segments = Self.standardSegments
        if !segments.contains(where: { $0.days == lead }) {
            let index = segments.firstIndex { $0.days > lead } ?? segments.endIndex
            segments.insert(Segment(days: lead, title: Self.segmentTitle(days: lead)), at: index)
        }
        self.segments = segments
        self.selected = lead
    }

    /// A lead in the switch's words: "On the day", "1 day", "3 days", "1 week", "14 days".
    /// The same days as `Settings.reminderLeadText`, without "before".
    private static func segmentTitle(days: Int) -> String {
        switch days {
        case Subscription.noReminder: "Off"
        case ..<1: "On the day"
        case 1: "1 day"
        case 7: "1 week"
        default: "\(days) days"
        }
    }
}
