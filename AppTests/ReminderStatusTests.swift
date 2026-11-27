import Foundation
import OboloCore
import Testing
import UserNotifications

/// The window's status line on a Detail says "Remind 2 days before" from
/// `Settings.reminderLeadDays(for:)`. These hold that rule to what the scheduler does: it
/// names a reminder exactly when Mac notifications get one.
@MainActor
@Suite("Reminder in the status line")
struct ReminderStatusTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func requests(for subscription: Subscription, today: Date) -> Int {
        var document = StoreDocument.initial()
        document.settings.notificationTime = DateComponents(hour: 9, minute: 0)
        document.subscriptions = [subscription]
        return NotificationScheduler.requests(for: Ledger(document: document, today: today, calendar: calendar)).count
    }

    @Test(
        "An empty queue with eligible renewals reflects the current notification permission",
        arguments: [
            (UNAuthorizationStatus.authorized, "No reminders are scheduled."),
            (.provisional, "No reminders are scheduled."),
            (.denied, "Obolo does not have permission to send notifications on this Mac."),
            (.notDetermined, "Choose Allow notifications to let Obolo send reminders.")
        ]
    )
    func emptyQueuePermission(status: UNAuthorizationStatus, message: String) {
        let today = day(2026, 11, 26)
        var document = StoreDocument.initial()
        document.settings.notificationsEnabled = true
        document.subscriptions = [
            Subscription(
                name: "Netflix",
                categoryID: OboloCore.Category.unknown.id,
                price: 15,
                currency: "EUR",
                cycle: .monthly,
                anchorDate: BillingDay(isoDate: "2026-01-05")!
            )
        ]
        let ledger = Ledger(document: document, today: today, calendar: calendar)
        #expect(!NotificationScheduler.requests(for: ledger).isEmpty)
        #expect(RemindersPane.emptyQueueDescription(ledger: ledger, status: status) == message)
    }

    @Test("The empty queue explains disabled notifications and missing renewal dates")
    func emptyQueueWithoutRenewals() {
        let today = day(2026, 11, 26)
        var document = StoreDocument.initial()
        document.settings.notificationsEnabled = true
        let empty = Ledger(document: document, today: today, calendar: calendar)
        #expect(RemindersPane.emptyQueueDescription(ledger: empty, status: .authorized)
            == "No subscription has a known renewal date.")

        document.settings.notificationsEnabled = false
        let disabled = Ledger(document: document, today: today, calendar: calendar)
        #expect(RemindersPane.emptyQueueDescription(ledger: disabled, status: .authorized) == "Notifications are off.")
    }

    @Test(
        "A cancelled subscription with access to an end date a month ahead has no reminder",
        arguments: [nil, 2, 7] as [Int?]
    )
    func cancelledHasNoReminder(lead: Int?) {
        let today = day(2026, 11, 26)
        var subscription = Subscription(
            name: "Netflix",
            categoryID: OboloCore.Category.unknown.id,
            price: 15,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-01-05")!,
            reminderLeadDays: lead
        )
        let settings = StoreDocument.initial().settings

        // Active: a reminder is scheduled, and the line names it.
        #expect(requests(for: subscription, today: today) == 1)
        #expect(settings.reminderLeadDays(for: subscription) == (lead ?? settings.defaultReminderLeadDays))

        // Cancelled, with access until 26 December: nothing is scheduled, and the line
        // must not promise a reminder.
        subscription.status = .cancelled
        subscription.billingStoppedOn = BillingDay(isoDate: "2026-11-05")!
        subscription.endsOn = BillingDay(isoDate: "2026-12-26")!
        #expect(requests(for: subscription, today: today) == 0)
        #expect(settings.reminderLeadDays(for: subscription) == nil)
    }
}
