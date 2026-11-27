import Foundation
import Testing
import OboloCore

/// The turn between the two shapes of a price history.
///
/// The store keeps the price that is charged **now** plus the ones before it, because
/// that is what every reader wants first: the All list, the totals and the next payment all
/// ask "what does this cost". The form edits the same history forward — the price at the
/// first payment, then each change since — because that is the order somebody remembers
/// it in, and because a change that cannot be dated before the first payment cannot
/// strand the price it replaced.
///
/// `SubscriptionDraft.init` and `SubscriptionDraft.subscription()` are the only two places those shapes meet, so
/// what these tests hold is that going through both changes nothing a charge can see.
@Suite("Subscription draft")
struct SubscriptionDraftTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func money(_ literal: String) -> Decimal {
        Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX"))!
    }

    /// Five months of ChatGPT Plus at $24.40 from 25 March, then Pro at $121.71 from
    /// 25 August — as the store holds it.
    private func chatGPT() -> Subscription {
        Subscription(
            name: "ChatGPT",
            categoryID: Category.unknown.id,
            price: money("121.71"),
            currency: "USD",
            priceChanges: [
                PriceChange(effectiveFrom: BillingDay(isoDate: "2026-03-25")!, price: money("24.40"), currency: "USD")
            ],
            currentPriceSince: BillingDay(isoDate: "2026-08-25")!,
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2026-03-25")!,
            createdAt: day(2026, 3, 25)
        )
    }

    private func roundTrip(_ subscription: Subscription) throws -> Subscription {
        try #require(
            SubscriptionDraft(subscription, isNew: false).subscription()
        )
    }

    // MARK: - What the form shows

    @Test("Editing on a second device preserves every stored billing day")
    func editAcrossTimeZones() throws {
        var original = chatGPT()
        original.priceChanges[0].effectiveFrom = BillingDay(isoDate: "2026-03-20")!
        original.status = .cancelled
        original.billingStoppedOn = BillingDay(isoDate: "2026-10-25")!
        original.endsOn = BillingDay(isoDate: "2026-11-25")!
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!

        let enteredInRome = SubscriptionDraft(original, isNew: false, calendar: calendar)
        let stored = try #require(enteredInRome.subscription())
        var editedInNewYork = SubscriptionDraft(stored, isNew: false, calendar: newYork)
        editedInNewYork.notes = "Updated on the phone"
        var expected = original
        expected.notes = editedInNewYork.notes
        #expect(editedInNewYork.subscription() == expected)
    }

    @Test("The form shows the starting price, and the changes after it")
    func draftReadsForward() throws {
        let draft = SubscriptionDraft(chatGPT(), isNew: false)

        // The top field is what was paid on the first payment, not what is paid now.
        #expect(draft.startingPrice == money("24.40"))
        #expect(draft.currency == "USD")

        #expect(draft.priceChanges.count == 1)
        #expect(draft.priceChanges[0].date == BillingDay(isoDate: "2026-08-25")!)
        #expect(draft.priceChanges[0].price == money("121.71"))
    }

    @Test("Stored prices show the currency's fraction digits: 108,80, never 108,8")
    func storedPricesKeepTheirFractionDigits() {
        let english = Locale(identifier: "en_US")
        let italian = Locale(identifier: "it_IT")
        #expect(SubscriptionDraft.format(money("108.8"), currency: "EUR", locale: italian) == "108,80")
        #expect(SubscriptionDraft.format(money("109.8"), currency: "USD", locale: english) == "109.80")
        #expect(SubscriptionDraft.format(money("12"), currency: "EUR", locale: english) == "12.00")
        #expect(SubscriptionDraft.format(money("1200"), currency: "JPY", locale: english) == "1200")

        // Leaving a field tidies what was typed; text that isn't a price stays as it is.
        #expect(SubscriptionDraft.tidied("108,8", currency: "EUR", locale: italian) == "108,80")
        #expect(SubscriptionDraft.tidied("14.", currency: "USD", locale: english) == "14.00")
        #expect(SubscriptionDraft.tidied("abc", currency: "EUR", locale: english) == "abc")

        // The form's own rows, filled from a stored history, carry both digits.
        let draft = SubscriptionDraft(chatGPT(), isNew: false)
        let separator = Locale.current.decimalSeparator ?? "."
        #expect(draft.priceText == "24\(separator)40")
        #expect(draft.priceChanges[0].priceText == "121\(separator)71")
    }

    @Test("Three-place price fields and grouped amounts use the correct separators")
    func threePlacePriceFields() {
        typealias Draft = SubscriptionDraft
        let english = Locale(identifier: "en_US")
        let italian = Locale(identifier: "it_IT")
        let price = money("1.234")

        #expect(Draft.format(price, currency: "KWD", locale: english) == "1.234")
        #expect(Draft.format(price, currency: "KWD", locale: italian) == "1,234")
        #expect(Draft.tidied("1.234", currency: "KWD", locale: english) == "1.234")
        #expect(Draft.tidied("1,234", currency: "KWD", locale: italian) == "1,234")
        #expect(Draft.parsePrice("1,234", currency: "KWD", locale: english) == money("1234"))
        #expect(Draft.parsePrice("1.234", currency: "KWD", locale: italian) == money("1234"))
        #expect(Draft.parsePrice("1.234", currency: "EUR", locale: italian) == money("1234"))
        #expect(Draft.parsePrice("1.234.567", currency: "KWD", locale: italian) == money("1234567"))
        #expect(Draft.parsePrice("1,234.567", currency: "KWD", locale: italian) == money("1234.567"))
        #expect(Draft.parsePrice("1.234,567", currency: "KWD", locale: english) == money("1234.567"))

        let arabic = Locale(identifier: "ar_KW@numbers=arab")
        let arabicPrice = Draft.format(price, currency: "KWD", locale: arabic)
        #expect(Draft.parsePrice(arabicPrice, currency: "KWD", locale: arabic) == price)
    }

    @Test("Opening, tidying and saving mixed-currency prices preserves every amount")
    func mixedCurrencyPriceHistory() throws {
        typealias Draft = SubscriptionDraft
        var original = chatGPT()
        original.price = money("5.678")
        original.currency = "KWD"
        original.priceChanges[0].price = money("1.234")
        // USD can contain more than two fraction digits after a CSV import.

        var draft = Draft(original, isNew: false, calendar: calendar)
        draft.priceText = Draft.tidied(draft.priceText, currency: draft.currency)
        let change = draft.priceChanges[0]
        draft.priceChanges[0].priceText = Draft.tidied(change.priceText, currency: change.currency)

        let saved = try #require(draft.subscription())
        #expect(saved.price == original.price)
        #expect(saved.currency == original.currency)
        #expect(saved.priceChanges == original.priceChanges)

        draft.setCurrency("EUR")
        let recoded = try #require(draft.subscription())
        #expect(recoded.price == original.price)
        #expect(recoded.currency == "EUR")
        #expect(recoded.priceChanges.first?.price == original.priceChanges.first?.price)
        #expect(recoded.priceChanges.first?.currency == "EUR")
    }

    @Test("A row that never changed price shows one price and no changes")
    func draftWithoutHistory() throws {
        let plain = Subscription(
            name: "Netflix",
            categoryID: Category.unknown.id,
            price: money("20.00"),
            currency: "EUR",
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2025-01-10")!
        )
        let draft = SubscriptionDraft(plain, isNew: false)

        #expect(draft.startingPrice == money("20.00"))
        #expect(draft.priceChanges.isEmpty)

        let saved = try roundTrip(plain)
        #expect(saved.price == money("20.00"))
        #expect(saved.priceChanges.isEmpty)
        // No change, so there is no earlier price for the current one to have replaced.
        #expect(saved.currentPriceSince == nil)
    }

    // MARK: - What the store gets back

    @Test("A round trip changes nothing a charge can see")
    func roundTripPreservesEveryCharge() throws {
        let original = chatGPT()
        let saved = try roundTrip(original)

        #expect(saved.price == original.price)
        #expect(saved.currency == original.currency)
        #expect(saved.currentPriceSince == original.currentPriceSince)

        // The invariant that matters: every charge this row ever made still costs what
        // it cost. Checked day by day rather than field by field, because the fields are
        // exactly what the turn rearranges.
        for date in RenewalSchedule.occurrences(
            anchor: day(2026, 3, 25), cycle: .monthly,
            from: day(2026, 3, 25), to: day(2027, 3, 25), calendar: calendar
        ) {
            let before = original.price(on: date, calendar: calendar)
            let after = saved.price(on: date, calendar: calendar)
            #expect(before.price == after.price)
            #expect(before.currency == after.currency)
        }
    }

    @Test("Three prices survive the turn in order")
    func roundTripWithSeveralChanges() throws {
        let original = Subscription(
            name: "Streaming",
            categoryID: Category.unknown.id,
            price: money("20.00"),
            currency: "EUR",
            priceChanges: [
                PriceChange(effectiveFrom: BillingDay(isoDate: "2025-03-20")!, price: money("10.00"), currency: "EUR"),
                PriceChange(effectiveFrom: BillingDay(isoDate: "2026-01-20")!, price: money("15.00"), currency: "EUR")
            ],
            currentPriceSince: BillingDay(isoDate: "2026-06-20")!,
            cycle: .monthly,
            anchorDate: BillingDay(isoDate: "2025-03-20")!
        )
        let saved = try roundTrip(original)

        #expect(saved.price == money("20.00"))
        #expect(saved.priceChanges.map(\.price) == [money("10.00"), money("15.00")])
        #expect(saved.priceChanges.map(\.effectiveFrom) == [BillingDay(isoDate: "2025-03-20")!, BillingDay(isoDate: "2026-01-20")!])
        #expect(saved.currentPriceSince == BillingDay(isoDate: "2026-06-20")!)
    }

    @Test("A change typed out of order still saves as the current price")
    func changesSortOnTheWayOut() throws {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        // A second change, dated before the one already there — as it looks the moment
        // its date has been typed and its row has not moved yet.
        draft.priceChanges.append(
            SubscriptionDraft.PriceChangeRow(
                date: BillingDay(isoDate: "2026-06-25")!, priceText: "30", currency: "USD"
            )
        )
        let saved = try #require(draft.subscription())

        // The latest date is the current price, whatever order the rows were in.
        #expect(saved.price == money("121.71"))
        #expect(saved.currentPriceSince == BillingDay(isoDate: "2026-08-25")!)
        #expect(saved.priceChanges.map(\.price) == [money("24.40"), money("30")])
        #expect(saved.price(on: day(2026, 7, 25), calendar: calendar).price == money("30"))
    }

    @Test("The starting price is pinned to the first payment")
    func startingPriceFollowsTheAnchor() throws {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        draft.anchorDate = BillingDay(isoDate: "2026-01-25")!
        let saved = try #require(draft.subscription())

        // Moving the first payment moves the day the starting price began with it, so
        // the earliest entry can never end up stranded above the first charge — the
        // failure the old editor's "earlier prices" list invited.
        #expect(saved.priceChanges.first?.effectiveFrom == BillingDay(isoDate: "2026-01-25")!)
        #expect(saved.price(on: day(2026, 1, 25), calendar: calendar).price == money("24.40"))
    }

    @Test("A change dated ahead saves as the announced rise")
    func futureChangeBecomesTheAnnouncedRise() throws {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        // "From 25 October it is $180." Entered in August, so it has not happened.
        draft.priceChanges.append(
            SubscriptionDraft.PriceChangeRow(
                date: BillingDay(isoDate: "2026-10-25")!, priceText: "180", currency: "USD"
            )
        )
        let saved = try #require(draft.subscription())

        // The newest row is what the store keeps as `price`, and the day it starts is
        // `currentPriceSince`. Everything below it is history, all of it in the past.
        #expect(saved.price == money("180"))
        #expect(saved.currentPriceSince == BillingDay(isoDate: "2026-10-25")!)
        #expect(saved.priceChanges.map(\.price) == [money("24.40"), money("121.71")])

        // Until that day the row still costs what it costs.
        #expect(saved.price(on: day(2026, 9, 25), calendar: calendar).price == money("121.71"))
        #expect(saved.price(on: day(2026, 10, 25), calendar: calendar).price == money("180"))

        let rise = try #require(
            saved.announcedPriceChange(on: day(2026, 8, 28), calendar: calendar)
        )
        #expect(rise.price == money("180"))
    }

    @Test("Reopening a subscription with an announced rise shows it as the newest row")
    func announcedRiseRoundTrips() throws {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        draft.priceChanges.append(
            SubscriptionDraft.PriceChangeRow(
                date: BillingDay(isoDate: "2026-10-25")!, priceText: "180", currency: "USD"
            )
        )
        let saved = try #require(draft.subscription())
        let reopened = SubscriptionDraft(saved, isNew: false)

        #expect(reopened.startingPrice == money("24.40"))
        #expect(reopened.priceChanges.map(\.date) == [BillingDay(isoDate: "2026-08-25")!, BillingDay(isoDate: "2026-10-25")!])
        #expect(reopened.priceChanges.last?.price == money("180"))
    }

    @Test("Without a first payment the starting price still begins below every change")
    func noAnchorKeepsTheStartingPriceReachable() throws {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        draft.hasAnchor = false
        let saved = try #require(draft.subscription())

        #expect(saved.anchorDate == nil)
        #expect(saved.priceChanges.count == 1)
        // Not after the change above it, which would make it answer for nothing.
        #expect(saved.priceChanges[0].effectiveFrom <= BillingDay(isoDate: "2026-08-25")!)
        #expect(saved.price == money("121.71"))
    }

    // MARK: - Save and footer rules

    @Test("A new draft requires a name and positive starting price and can save without a first payment")
    func newDraftCanSaveWithoutAnAnchor() throws {
        let template = Subscription(
            name: "",
            categoryID: Category.unknown.id,
            price: 0,
            currency: "USD",
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 3, 25),
            createdAt: day(2026, 3, 25)
        )
        var draft = SubscriptionDraft(template, isNew: true, calendar: calendar)
        #expect(draft.priceText.isEmpty)
        #expect(!draft.hasAnchor)
        #expect(draft.subscription() == nil)

        draft.priceText = "10"
        draft.name = " \n\t "
        #expect(draft.subscription() == nil)

        draft.name = "  Music  "
        draft.paymentMethod = "  Card  "
        draft.manageURLText = "  music.example/account  "
        draft.websiteText = "https://www.music.example/account"
        let saved = try #require(draft.subscription())
        #expect(saved.name == "Music")
        #expect(saved.price == 10)
        #expect(saved.anchorDate == nil)
        #expect(saved.paymentMethod == "Card")
        #expect(saved.manageURL?.absoluteString == "https://music.example/account")
        #expect(saved.website == "music.example")
    }

    @Test("Blank change rows leave the save and price summary alone")
    func ignoresBlankPriceChanges() throws {
        let original = chatGPT()
        var draft = SubscriptionDraft(original, isNew: false)
        draft.priceChanges.append(.init(
            date: Fixed.billingDay(2026, 9, 25), priceText: "", currency: "USD"
        ))
        draft.priceChanges.append(.init(
            date: Fixed.billingDay(2026, 10, 25), priceText: "  \t ", currency: ""
        ))

        #expect(draft.priceSummary == .currentPrice(amount: original.price, currency: original.currency))
        #expect(try #require(draft.subscription()) == original)
        #expect(draft.priceChanges.count == 3)
    }

    @Test("A blank, malformed, zero or negative starting price blocks save even with valid history",
          arguments: ["", "abc", "0", "-1"])
    func invalidStartingPrice(_ text: String) {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        draft.priceText = text
        #expect(draft.priceSummary == .missingStartingPrice)
        #expect(draft.subscription() == nil)
    }

    @Test("An unreadable, negative or invalid-currency change blocks save",
          arguments: [("abc", "USD"), ("-", "USD"), ("-1", "USD"), ("8", "US")])
    func invalidPriceChange(_ priceText: String, _ currency: String) {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        draft.priceChanges.append(.init(
            date: Fixed.billingDay(2026, 10, 25), priceText: priceText, currency: currency
        ))
        #expect(draft.subscription() == nil)
    }

    @Test("The footer reports unreadable changes before a missing starting price")
    func unreadableChangeTakesPriorityInSummary() {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        draft.priceText = ""
        draft.priceChanges.append(.init(
            date: Fixed.billingDay(2026, 10, 25), priceText: "abc", currency: "USD"
        ))
        #expect(draft.priceSummary == .unreadableChange)
    }

    @Test("The later row on the same day controls the saved price and footer")
    func sameDayChangesKeepEditorOrder() throws {
        var draft = SubscriptionDraft(chatGPT(), isNew: false)
        let changeDay = draft.priceChanges[0].date
        draft.priceChanges.append(.init(date: changeDay, priceText: "0", currency: "JPY"))
        draft.priceChanges.append(.init(
            date: Fixed.billingDay(2026, 6, 25), priceText: "15", currency: "EUR"
        ))

        #expect(draft.priceSummary == .currentPrice(amount: 0, currency: "JPY"))
        let saved = try #require(draft.subscription())
        #expect(saved.price == 0)
        #expect(saved.currency == "JPY")
        #expect(saved.currentPriceSince == changeDay)
        #expect(saved.priceChanges.map(\.price) == [money("24.40"), 15, money("121.71")])
        #expect(saved.priceChanges.map(\.currency) == ["USD", "EUR", "USD"])
    }

    // MARK: - Reminder

    /// The form's switch has no segment for "use the default", and shows 0 or a lead such
    /// as 5 from an older document only while it applies. Only a click on a segment
    /// writes the lead, so a save that does not touch the switch keeps the stored value
    /// as it is.
    @Test(
        "A save keeps a reminder lead the switch has no segment for",
        arguments: [nil, 0, 5, 14, Subscription.noReminder, 7] as [Int?]
    )
    func reminderLeadRoundTrips(lead: Int?) throws {
        var subscription = chatGPT()
        subscription.reminderLeadDays = lead
        #expect(try roundTrip(subscription).reminderLeadDays == lead)
    }
}
