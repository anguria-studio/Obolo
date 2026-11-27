@preconcurrency import EventKit
import Foundation
import OboloCore

/// One recurring all-day event per billing subscription, in a calendar the user chose.
///
/// The point of this service is the iPhone. Obolo is a Mac app with no server and
/// no account; writing the payments into an iCloud calendar is the one mechanism that
/// gets a reminder onto a phone without becoming a different kind of product.
///
/// Three rules shape everything below:
///
/// - **Never touch an event it did not create.** Every event Obolo writes carries
///   `marker` in its notes, and the sweep that removes orphans only considers events
///   that carry it. An event the user made by hand in the same calendar is not this
///   app's business.
/// - **Reconcile, don't patch.** `reconcile(document:)` computes the set of events the
///   document implies and moves the calendar to it. There is no change log.
/// - **Write as little as possible.** The identifier of a newly created event goes to
///   device-local state. It never enters the portable document.
actor CalendarSync: CalendarSyncHook {

    /// The sentence in every event's notes. Both a warning to the user and this
    /// service's only claim of ownership.
    nonisolated static let marker = "Obolo manages this event. Make changes in the Obolo app."

    /// Only this exact marker establishes ownership. Do not infer it from event titles
    /// or subscription names.
    nonisolated static func hasManagedMarker(in notes: String?) -> Bool {
        guard let notes else { return false }
        return notes.contains(marker)
    }


    /// The picker store stays on the main actor for permission and picker data. The
    /// actor uses a separate store, then resolves the saved calendar identifier again.
    @MainActor private static let pickerStore = EKEventStore()

    /// The sync store belongs to this actor. EventKit reads and writes can block, so
    /// they must not run on the main actor with the interface.
    private let store = EKEventStore()

    /// Weak: `AppModel` owns this service, and this service writes event identifiers
    /// back into it.
    private weak var model: AppModel?

    init(model: AppModel?) {
        self.model = model
    }

    // MARK: - Access

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Full access rather than write-only: reconciling means reading back the events
    /// Obolo itself created, so it can update and remove them.
    @MainActor static func requestAccess() async -> Bool {
        (try? await pickerStore.requestFullAccessToEvents()) ?? false
    }

    /// The calendars the picker offers: writable only, iCloud first.
    ///
    /// iCloud first because it is the one source that reaches the user's phone, which
    /// is the entire reason this feature exists. "On My Mac" syncs nowhere.
    @MainActor static func calendars() -> [EKCalendar] {
        pickerStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { left, right in
                let leftRank = sourceRank(left.source)
                let rightRank = sourceRank(right.source)
                if leftRank != rightRank { return leftRank < rightRank }
                let sources = (left.source?.title ?? "").localizedCaseInsensitiveCompare(right.source?.title ?? "")
                if sources != .orderedSame { return sources == .orderedAscending }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }

    private static func sourceRank(_ source: EKSource?) -> Int {
        switch source?.sourceType {
        case .calDAV where source?.title == "iCloud": 0
        case .calDAV, .mobileMe:                      1
        case .exchange:                               2
        case .local:                                  3
        default:                                      4
        }
    }

    // MARK: - Reconcile

    func reconcile(document: StoreDocument) async {
        do {
            try await syncNow(document: document)
        } catch is CancellationError {
            // A newer document will be reconciled by the replacement task.
        } catch {
            await model?.recordCalendarSyncError(error.localizedDescription)
        }
    }

    /// Explicit failures let Settings distinguish a completed sync from a skipped one.
    func syncNow(document: StoreDocument) async throws {
        let settings = document.settings
        guard settings.calendarSyncEnabled else { throw SyncError.disabled }
        guard let identifier = settings.calendarIdentifier else { throw SyncError.noCalendar }
        guard Self.authorizationStatus == .fullAccess else { throw SyncError.noAccess }
        guard let target = store.calendar(withIdentifier: identifier),
              target.allowsContentModifications else { throw SyncError.unavailableCalendar }

        let (calendar, today) = await MainActor.run { [weak model] in
            (model?.calendar ?? .autoupdatingCurrent, model?.today ?? Date())
        }
        var referenced: Set<String> = []

        for subscription in document.subscriptions {
            try Task.checkCancellation()
            guard
                subscription.status.isBilling,
                let plan = EventPlan(
                    subscription: subscription,
                    settings: settings,
                    today: today,
                    calendar: calendar
                )
            else {
                // Paused, cancelled, or an anchor that was cleared: the event goes.
                try await removeEvent(for: subscription)
                continue
            }

            if let eventID = try await syncEvent(for: subscription, plan: plan, in: target) {
                referenced.insert(eventID)
            }
        }

        try Task.checkCancellation()
        // Anything left carrying our marker belongs to a subscription that no longer
        // exists — deleted while the app was closed, or dropped by a restore.
        try removeOrphans(in: target, keeping: referenced, today: today)

        try Task.checkCancellation()
        await model?.recordCalendarSync(at: Date())
    }

    enum SyncError: LocalizedError {
        case disabled, noCalendar, noAccess, unavailableCalendar

        var errorDescription: String? {
            switch self {
            case .disabled: "Turn on calendar sync first."
            case .noCalendar: "Choose a calendar before syncing."
            case .noAccess: "Allow full calendar access in System Settings, then try again."
            case .unavailableCalendar: "The selected calendar is unavailable or read-only. Choose another calendar."
            }
        }
    }

    // MARK: - Teardown

    /// Empties a calendar of everything Obolo put in it, and forgets the identifiers.
    ///
    /// Called when the switch goes off and when the user picks a different calendar —
    /// the two moments `reconcile` cannot cover, because by the time it runs the settings
    /// no longer name the calendar that needs tidying. Leaving the events behind is the
    /// bug this closes: a user who turns sync off and sees the payments still in Calendar
    /// the next morning has no way to get rid of them except by hand.
    ///
    /// Both halves run, not one or the other. The stored identifiers cover events whose
    /// series has moved outside any sensible date window; the marker sweep covers events
    /// whose identifier local state lost — a restore from an older backup, a duplicate
    /// that dropped it.
    func removeAllManagedEvents(from calendarIdentifier: String?) async {
        do {
            try await removeAllManagedEventsReporting(from: calendarIdentifier)
        } catch {
            await model?.recordCalendarSyncError(error.localizedDescription)
        }
    }

    func removeAllManagedEventsReporting(from calendarIdentifier: String?) async throws {
        guard Self.authorizationStatus == .fullAccess else { throw SyncError.noAccess }
        guard let model else { return }
        let snapshot = await MainActor.run {
            (model.allCalendarEventIdentifiers, model.today)
        }
        for identifier in snapshot.0 {
            try Task.checkCancellation()
            try removeChecked(identifier: identifier)
        }
        if let calendarIdentifier {
            guard let target = store.calendar(withIdentifier: calendarIdentifier) else {
                throw SyncError.unavailableCalendar
            }
            for identifier in managedEventIdentifiers(in: target, around: snapshot.1) {
                try Task.checkCancellation()
                try removeChecked(identifier: identifier)
            }
        }
        await model.clearCalendarEventIdentifiers()
        await model.recordCalendarSync(at: nil)
    }

    /// Removes one event this app created, wherever it is. Used by the delete path, which
    /// runs whether or not sync is on: a row that carries an identifier has an event out
    /// there, and the delete alert promises to take it with the row.
    func removeManagedEvent(identifier: String) async {
        guard Self.authorizationStatus == .fullAccess else { return }
        remove(identifier: identifier)
    }

    /// Resolves by identifier and removes the whole series.
    ///
    /// By identifier rather than from an occurrence in hand: `events(matching:)` vends
    /// occurrences, and removing a middle one with `.futureEvents` would leave every
    /// earlier occurrence in place.
    private func remove(identifier: String) {
        try? removeChecked(identifier: identifier)
    }

    private func removeChecked(identifier: String) throws {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .futureEvents, commit: true)
    }

    // MARK: One subscription

    /// Creates or updates the event, and returns the identifier it now has.
    private func syncEvent(for subscription: Subscription, plan: EventPlan, in target: EKCalendar) async throws -> String? {
        let existing = await storedIdentifier(for: subscription.id)
            .flatMap { store.event(withIdentifier: $0) }

        // An event that moved calendars is not updated in place: the user changed
        // which calendar Obolo writes to, and the old one keeps nothing of ours.
        if let existing, existing.calendar?.calendarIdentifier != target.calendarIdentifier {
            try store.remove(existing, span: .futureEvents, commit: true)
            return try await create(plan: plan, for: subscription, in: target)
        }

        guard let existing else {
            return try await create(plan: plan, for: subscription, in: target)
        }

        // The loop guard: if the event already says what the document says, nothing is
        // written, so nothing calls back into the model, so this does not run again.
        guard plan.differs(from: existing) else { return existing.eventIdentifier }

        plan.apply(to: existing)
        try store.save(existing, span: .futureEvents, commit: true)
        return existing.eventIdentifier
    }

    private func create(plan: EventPlan, for subscription: Subscription, in target: EKCalendar) async throws -> String? {
        let event = EKEvent(eventStore: store)
        event.calendar = target
        plan.apply(to: event)
        try store.save(event, span: .futureEvents, commit: true)
        guard let identifier = event.eventIdentifier else { return nil }
        await write(identifier, to: subscription.id)
        return identifier
    }

    private func removeEvent(for subscription: Subscription) async throws {
        guard let eventID = await storedIdentifier(for: subscription.id) else { return }
        try removeChecked(identifier: eventID)
        await write(nil, to: subscription.id)
    }

    /// Events in our calendar wearing our marker that no live subscription claims.
    private func removeOrphans(in target: EKCalendar, keeping referenced: Set<String>, today: Date) throws {
        for identifier in managedEventIdentifiers(in: target, around: today)
        where !referenced.contains(identifier) {
            try Task.checkCancellation()
            try removeChecked(identifier: identifier)
        }
    }

    // MARK: The sweep window

    /// How far either side of today the sweep looks, in years.
    ///
    /// Five, because a two-year cycle is one of the cadences this app offers: a window of
    /// ±400 days can contain no occurrence at all of an event that charges every other
    /// January, so the orphan left behind by a deleted two-year subscription was
    /// invisible to the sweep and stayed in the user's calendar forever.
    private static let sweepYears = 5

    /// How many years one predicate may span.
    ///
    /// EventKit caps `predicateForEvents(withStart:end:calendars:)` at four years and
    /// quietly truncates a longer range rather than refusing it, so the ten-year window
    /// above is asked for in chunks that stay under the cap.
    private static let maximumPredicateYears = 2

    /// Every event in `target` that Obolo created, over ±`sweepYears`, deduplicated.
    ///
    /// Identifiers rather than events: `events(matching:)` vends one object per
    /// occurrence, and the same series turns up in several chunks. The identifier is what
    /// the removal resolves by anyway.
    private func managedEventIdentifiers(in target: EKCalendar, around today: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        guard
            let windowStart = calendar.date(byAdding: .year, value: -Self.sweepYears, to: today),
            let windowEnd = calendar.date(byAdding: .year, value: Self.sweepYears, to: today)
        else { return [] }

        var found: [String] = []
        var seen: Set<String> = []
        var chunkStart = windowStart

        while chunkStart < windowEnd {
            guard !Task.isCancelled else { return found }
            let chunkEnd = min(
                calendar.date(byAdding: .year, value: Self.maximumPredicateYears, to: chunkStart) ?? windowEnd,
                windowEnd
            )
            // A zero-length or backwards chunk would loop forever.
            guard chunkEnd > chunkStart else { break }

            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: [target])
            for event in store.events(matching: predicate) {
                guard
                    let identifier = event.eventIdentifier,
                    Self.hasManagedMarker(in: event.notes),
                    seen.insert(identifier).inserted
                else { continue }
                found.append(identifier)
            }
            chunkStart = chunkEnd
        }
        return found
    }

    // MARK: Writing back

    private func storedIdentifier(for id: Subscription.ID) async -> String? {
        await MainActor.run { [weak model] in
            model?.calendarEventIdentifier(for: id)
        }
    }

    /// The one place an EventKit identifier is written. It uses device-local state
    /// because the identifier has no meaning on another Mac.
    private func write(_ identifier: String?, to id: Subscription.ID) async {
        await MainActor.run { [weak model] in
            model?.recordCalendarEventIdentifier(identifier, for: id)
        }
    }
}

// MARK: - The event a subscription implies

/// The desired state of one calendar event, computed from a subscription.
///
/// Separated from the store work so the comparison that stops the update→reconcile
/// loop is a plain value comparison, and so the mapping from a billing cycle to an
/// `EKRecurrenceRule` sits in one readable place.
private struct EventPlan {
    let title: String
    let start: Date
    let end: Date
    let notes: String
    /// The repeat rule, as `OboloCore` computes it. Never worked out here: the
    /// month-end clamp that keeps a 31 January plan on the last day of February is the
    /// part that can be wrong, and it is proved by the Core tests against the same
    /// schedule the rest of the app reads.
    let recurrence: RecurrencePlan
    let alarmOffsets: [TimeInterval]
    /// The calendar the plan was computed in, kept so the comparison below asks the same
    /// question the same way. A day is a calendar's idea, not a number of seconds.
    let calendar: Calendar

    init?(subscription: Subscription, settings: Settings, today: Date, calendar: Calendar) {
        self.calendar = calendar
        guard let day = subscription.anchorDate?.startOfDay(in: calendar) else { return nil }

        // "💳 Netflix · €13.99" — the amount as charged, in its own currency, so the
        // event matches the line that will appear on the statement.
        let amount = MoneyFormatting.amount(
            subscription.price, currency: subscription.currency, estimate: subscription.isEstimate
        )
        title = "💳 \(subscription.name) · \(amount)"

        // All-day, so it reads as a marker on the day rather than an appointment at a
        // made-up hour. One day, not two: `end` is the last second of the same day.
        start = day
        end = calendar.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1)
            ?? day.addingTimeInterval(86_399)

        let userNotes = subscription.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        notes = userNotes.isEmpty ? CalendarSync.marker : "\(userNotes)\n\n\(CalendarSync.marker)"

        recurrence = RecurrencePlan.plan(for: subscription.cycle, anchor: day, calendar: calendar)

        // The alert offsets are relative to the occurrence's start, which for an all-day
        // event is midnight — so the reminder hour has to be added back on.
        //
        // "Three days before at 9 am" is a wall clock time on a calendar day, and neither
        // half survives plain seconds. Three days is 259,200 seconds only when no clock
        // change falls inside them, and 9 am is 32,400 seconds after midnight only when
        // the two share an offset from UTC. So the day is stepped with the calendar, the
        // hour is set on that day with the calendar, and the offset is whatever interval
        // that moment turns out to be from the occurrence.
        //
        // Honest about what this cannot do: EventKit stores a recurring alarm as one
        // fixed `TimeInterval` from the event start, and every occurrence of the series
        // gets that same interval. No single offset can hold 9 am across every future
        // DST relationship, because the relationship changes twice a year. What is
        // computed here is correct for the *next* occurrence, which is the one about to
        // fire, and `reconcile` recomputes and re-applies it on every run — so a clock
        // change moves the alarm back to 9 am well before the occurrence it would have
        // missed by an hour.
        let occurrence = calendar.startOfDay(
            for: RenewalSchedule.nextPayment(
                anchor: day, cycle: subscription.cycle, today: today, calendar: calendar
            )
        )
        let hour = settings.notificationTime.hour ?? 9
        let minute = settings.notificationTime.minute ?? 0
        alarmOffsets = (subscription.remindersEnabled ? settings.calendarAlertOffsetsDays : [])
            .sorted()
            .map { leadDays in
                let leadDay = calendar.date(byAdding: .day, value: -leadDays, to: occurrence) ?? occurrence
                let moment = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: leadDay)
                    ?? leadDay.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
                return moment.timeIntervalSince(occurrence)
            }
    }

    func apply(to event: EKEvent) {
        event.title = title
        event.isAllDay = true
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.recurrenceRules = [RecurrenceRule.make(recurrence)]

        for alarm in event.alarms ?? [] { event.removeAlarm(alarm) }
        for offset in alarmOffsets { event.addAlarm(EKAlarm(relativeOffset: offset)) }
    }

    /// Whether the stored event has drifted from what the document now says.
    ///
    /// Deliberately narrow: it compares the fields this service writes and nothing
    /// else, so a colour or an invitee the user added by hand does not count as drift
    /// and does not get overwritten on the next edit.
    func differs(from event: EKEvent) -> Bool {
        if event.title != title { return true }
        if event.isAllDay != true { return true }
        if !sameDay(event.startDate, start) { return true }
        if !sameDay(event.endDate, end) { return true }
        if (event.notes ?? "") != notes { return true }

        // The repeat rule, in full. An event written by a build that had no month-end
        // clamp carries a plain "every month" rule and is exactly the drift worth
        // catching: it differs here, so reconcile re-applies the plan to it with
        // `span: .futureEvents` and the series is corrected from here on.
        let rules = event.recurrenceRules ?? []
        guard rules.count == 1, let rule = rules.first else { return true }
        if !RecurrenceRule.matches(rule, recurrence) { return true }

        let existing = (event.alarms ?? []).map(\.relativeOffset).sorted()
        if existing.count != alarmOffsets.count { return true }
        return zip(existing, alarmOffsets.sorted()).contains { abs($0 - $1) > 1 }
    }

    /// EventKit normalises an all-day event's dates to its own time zone, so the exact
    /// instants come back different from the ones that went in. The day is what was
    /// meant, and the day is what is compared.
    ///
    /// Asked of the calendar, not of the clock. "Within 86,400 seconds" is not "the same
    /// day": it called two genuinely different days the same one whenever the pair
    /// straddled midnight by less than a day, and on the two nights a year the clocks
    /// move it got the width of the day itself wrong. Either way the event stopped being
    /// rewritten when it should have been, or was rewritten when it should not.
    private func sameDay(_ left: Date?, _ right: Date) -> Bool {
        guard let left else { return false }
        return calendar.isDate(left, inSameDayAs: right)
    }
}
