import OboloCore
import Testing

@Suite("Subscription reminder switch")
struct SubscriptionReminderSwitchTests {
    /// The four standard segments, and a fifth in its numeric place for a lead that has
    /// none. The lit segment is always the lead that applies.
    @Test(
        "The reminder switch always lights the lead that applies",
        arguments: [
            // nil: the default from Settings applies.
            (nil, 0, ["Off", "On the day", "1 day", "2 days", "1 week"], 0),
            (nil, 1, ["Off", "1 day", "2 days", "1 week"], 1),
            (nil, 2, ["Off", "1 day", "2 days", "1 week"], 2),
            (nil, 3, ["Off", "1 day", "2 days", "3 days", "1 week"], 3),
            (nil, 7, ["Off", "1 day", "2 days", "1 week"], 7),
            (nil, 14, ["Off", "1 day", "2 days", "1 week", "14 days"], 14),
            // Stored on the subscription: the default (2) does not count.
            (Subscription.noReminder, 2, ["Off", "1 day", "2 days", "1 week"], Subscription.noReminder),
            (0, 2, ["Off", "On the day", "1 day", "2 days", "1 week"], 0),
            (1, 2, ["Off", "1 day", "2 days", "1 week"], 1),
            (2, 0, ["Off", "1 day", "2 days", "1 week"], 2),
            (3, 2, ["Off", "1 day", "2 days", "3 days", "1 week"], 3),
            (5, 2, ["Off", "1 day", "2 days", "5 days", "1 week"], 5),
            (7, 2, ["Off", "1 day", "2 days", "1 week"], 7),
            (14, 2, ["Off", "1 day", "2 days", "1 week", "14 days"], 14)
        ] as [(Int?, Int, [String], Int)]
    )
    func reminderSwitch(stored: Int?, defaultLead: Int, titles: [String], selected: Int) {
        let shown = SubscriptionReminderSwitch(stored: stored, defaultLead: defaultLead)
        #expect(shown.segments.map(\.title) == titles)
        #expect(shown.selected == selected)
        // Exactly one segment is lit, and the days are in order.
        #expect(shown.segments.filter { $0.days == shown.selected }.count == 1)
        #expect(shown.segments.map(\.days) == shown.segments.map(\.days).sorted())
    }

    @Test("The extra segment writes nothing: a lead from the default still saves as nil")
    func reminderSwitchWritesNothing() throws {
        let subscription = Subscription(
            name: "ChatGPT",
            categoryID: OboloCore.Category.unknown.id,
            price: 10,
            currency: "USD",
            cycle: .monthly
        )
        let draft = SubscriptionDraft(subscription, isNew: false)
        let shown = SubscriptionReminderSwitch(stored: draft.reminderLeadDays, defaultLead: 0)
        #expect(shown.segments.map(\.title) == ["Off", "On the day", "1 day", "2 days", "1 week"])
        #expect(shown.selected == 0)
        #expect(draft.reminderLeadDays == nil)
        #expect(try #require(draft.subscription()).reminderLeadDays == nil)

        // A pick of a standard segment writes it, and the extra one goes.
        var picked = draft
        picked.reminderLeadDays = 1
        #expect(SubscriptionReminderSwitch(stored: picked.reminderLeadDays, defaultLead: 0).segments.map(\.title) == ["Off", "1 day", "2 days", "1 week"])
        #expect(try #require(picked.subscription()).reminderLeadDays == 1)
    }
}
