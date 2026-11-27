import Foundation
import UserNotifications
import OboloCore

/// Mac notifications, derived from the document and nothing else.
///
/// The rule the whole design rests on is "one source of truth": there is no second
/// list of reminders kept in step with the subscriptions. `reschedule(ledger:)` throws
/// away every reminder this app owns and schedules the set the ledger implies, every
/// time. That is why it can be called after every mutation, after a restore, and at
/// midnight without anyone reasoning about what changed.
///
/// Identifiers are namespaced `obolo.<uuid>.lead` / `obolo.<uuid>.today` so the
/// clear-out can be exact. `removeAllPendingNotificationRequests()` would also delete
/// anything another part of the app ever scheduled, and "never touch what you did not
/// create" applies here as much as it does to the calendar.
@MainActor
final class NotificationScheduler: SchedulerHook {

    /// Every identifier this app owns starts with this.
    static let identifierPrefix = "obolo."

    /// Lets Settings notice permission changes made outside Obolo.
    private(set) var wasAuthorized: Bool?

    // MARK: - Scheduling

    func reschedule(ledger: Ledger) async {
        await removeOurPendingRequests()

        guard !Task.isCancelled, ledger.document.settings.notificationsEnabled else { return }
        let status = await Self.authorizationStatus()
        guard !Task.isCancelled else { return }
        let isAuthorized = Self.allowsNotifications(status)
        wasAuthorized = isAuthorized
        guard isAuthorized else { return }

        for request in Self.requests(for: ledger) {
            guard !Task.isCancelled else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// What macOS has queued, soonest first.
    func pending() async -> [(title: String, date: Date)] {
        await UNUserNotificationCenter.current()
            .pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
            .compactMap { request in
                guard
                    let trigger = request.trigger as? UNCalendarNotificationTrigger,
                    let date = trigger.nextTriggerDate()
                else { return nil }
                return (title: request.content.title, date: date)
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Authorization

    /// The permission prompt follows a click on "Allow", on the empty Home's setup
    /// step or in Settings › Reminders. Scheduling checks the current system grant.
    static func allowsNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// The permission prompt, behind the "Allow" buttons on the empty Home and in
    /// Settings › Reminders.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Obolo's own page in System Settings › Notifications, where "Allow notifications"
    /// is, rather than the list of every app.
    static var settingsURL: String {
        let page = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let id = Bundle.main.bundleIdentifier else { return page }
        return page + "?id=" + id
    }

    /// The current status, for the Reminders pane's permission row.
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Clearing

    private func removeOurPendingRequests() async {
        let ours = await UNUserNotificationCenter.current()
            .pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        guard !Task.isCancelled, !ours.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ours)
    }

    // MARK: - Building the set

    /// Pure, static and testable: a ledger in, the requests it implies out.
    static func requests(for ledger: Ledger) -> [UNNotificationRequest] {
        let settings = ledger.document.settings
        let calendar = ledger.calendar
        let now = ledger.today

        return ledger.summaries.flatMap { summary -> [UNNotificationRequest] in
            guard summary.subscription.remindersEnabled, summary.status.isBilling, let nextPayment = summary.nextPayment else { return [] }

            var requests: [UNNotificationRequest] = []
            let lead = summary.reminderLeadDays(default: settings.defaultReminderLeadDays)
            let body = body(for: summary)

            // The lead reminder. Skipped when the charge is today, because the
            // due-today notification below says the same thing better.
            if summary.daysUntil != 0,
               let leadDate = calendar.date(byAdding: .day, value: -lead, to: nextPayment),
               let fire = time(settings.notificationTime, on: leadDate, calendar: calendar),
               fire > now {
                requests.append(request(
                    identifier: identifier(summary.id, suffix: "lead"),
                    title: leadTitle(name: summary.name, payment: nextPayment, lead: lead, calendar: calendar),
                    body: body,
                    subscriptionID: summary.id,
                    fire: fire,
                    calendar: calendar
                ))
            }

            // Due today, if the hour has not already gone by. A reminder posted at
            // 09:00 for a charge that lands today is the last useful moment to cancel.
            if summary.daysUntil == 0,
               let fire = time(settings.notificationTime, on: nextPayment, calendar: calendar),
               fire > now {
                requests.append(request(
                    identifier: identifier(summary.id, suffix: "today"),
                    title: "\(summary.name) renews today",
                    body: body,
                    subscriptionID: summary.id,
                    fire: fire,
                    calendar: calendar
                ))
            }

            return requests
        }
    }

    static func identifier(_ id: Subscription.ID, suffix: String) -> String {
        "\(identifierPrefix)\(id.uuidString).\(suffix)"
    }

    // MARK: Copy

    /// Use a weekday for renewals within a week (for example, “Netflix renews Sunday”).
    /// Longer leads use a date to distinguish between successive Sundays.
    private static func leadTitle(name: String, payment: Date, lead: Int, calendar: Calendar) -> String {
        if lead < 7 {
            return "\(name) renews \(DateFormatting.weekday(payment, calendar: calendar))"
        }
        return "\(name) renews on \(DateFormatting.absolute(payment, today: payment, calendar: calendar))"
    }

    /// "€14.99 · Direct debit", or just the amount when there is no method recorded.
    private static func body(for summary: SubscriptionSummary) -> String {
        // The amount this payment will be, which an announced rise may already have
        // changed. A reminder that quotes last month's price is a reminder that gets the
        // one thing it exists to say wrong.
        let amount = MoneyFormatting.amount(
            summary.nextCharge?.price ?? summary.price,
            currency: summary.nextCharge?.currency ?? summary.currency,
            estimate: summary.isEstimate
        )
        let method = summary.subscription.paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        return method.isEmpty ? amount : "\(amount) · \(method)"
    }

    // MARK: Requests

    private static func request(
        identifier: String,
        title: String,
        body: String,
        subscriptionID: Subscription.ID,
        fire: Date,
        calendar: Calendar
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // What the responder opens the window on.
        content.userInfo = ["subscriptionID": subscriptionID.uuidString]

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            // Never repeating: the next occurrence is scheduled by the next
            // `reschedule`, which the day-change timer guarantees happens.
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }

    /// `time` (hour and minute only) applied to `day`.
    private static func time(_ time: DateComponents, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: time.hour ?? 9,
            minute: time.minute ?? 0,
            second: 0,
            of: day
        )
    }
}
