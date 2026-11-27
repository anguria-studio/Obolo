import Foundation
import Testing
@testable import OboloCore

/// `Settings.reminderLeadDays(for:)`: the reminder the window's status line states for a
/// subscription. It must name a reminder only when one comes.
@Suite("Reminder lead")
struct ReminderLeadTests {

    private func subscription(status: Status = .active, lead: Int? = nil) -> Subscription {
        Subscription(
            name: "Netflix",
            categoryID: Category.unknown.id,
            price: 15,
            currency: "EUR",
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 5, 28),
            status: status,
            endsOn: status == .cancelled ? Fixed.billingDay(2026, 9, 21) : nil,
            reminderLeadDays: lead
        )
    }

    private func settings(defaultLead: Int) -> Settings {
        Settings(baseCurrency: "EUR", defaultReminderLeadDays: defaultLead)
    }

    @Test("A billing subscription uses its own lead, or the default when it has none")
    func billing() {
        let settings = settings(defaultLead: 2)
        for status in [Status.active, .trial] {
            #expect(settings.reminderLeadDays(for: subscription(status: status)) == 2)
            #expect(settings.reminderLeadDays(for: subscription(status: status, lead: 0)) == 0)
            #expect(settings.reminderLeadDays(for: subscription(status: status, lead: 7)) == 7)
        }
        #expect(self.settings(defaultLead: 0).reminderLeadDays(for: subscription()) == 0)
    }

    @Test("Its own reminder off: no reminder")
    func off() {
        #expect(settings(defaultLead: 2).reminderLeadDays(for: subscription(lead: Subscription.noReminder)) == nil)
    }

    @Test(
        "Cancelled, also with access to an end date: no reminder, whatever its lead",
        arguments: [nil, 0, 2, 7, Subscription.noReminder] as [Int?]
    )
    func cancelled(lead: Int?) {
        let settings = settings(defaultLead: 2)
        #expect(settings.reminderLeadDays(for: subscription(status: .cancelled, lead: lead)) == nil)
        // A paused row from an old file reads as cancelled.
        #expect(settings.reminderLeadDays(for: subscription(status: .paused, lead: lead)) == nil)
    }
}
