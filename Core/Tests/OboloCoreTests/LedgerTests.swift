import Foundation
import Testing
@testable import OboloCore

/// Totals, attention states, filtering and sorting — the layer the whole UI reads from.
@Suite("Ledger")
struct LedgerTests {

    // MARK: - What counts

    @Test("Only active and trial subscriptions reach the totals")
    func totalsCoverBillingItemsOnly() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Active", price: "10.00"),
            Fixed.subscription("Trial", price: "20.00", status: .trial),
            Fixed.subscription("Paused", price: "40.00", status: .paused),
            Fixed.subscription("Cancelled", price: "80.00", status: .cancelled)
        ])
        #expect(ledger.monthlyTotal == Fixed.money("30"))
        #expect(ledger.activeCount == 2)
        #expect(ledger.filtered(search: "", section: .pausedCancelled).count == 2)
    }

    @Test("The yearly total is twelve times the monthly one, so the two tiles agree")
    func yearlyIsTwelveTimesMonthly() {
        // Summing each item's own yearly figure would give €1 552.89 here; the tiles sit
        // one above the other and the user multiplies in their head.
        let ledger = SampleData.handoffLedger()
        #expect(ledger.yearlyTotal == ledger.monthlyTotal * 12)
        #expect(ledger.yearlyTotal == Fixed.money("1552.92"))
    }

    @Test("A currency with no rate is excluded from totals and counted separately")
    func missingRateExcludesAndCounts() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Euro thing", price: "10.00", anchor: Fixed.day(2026, 1, 5)),
            Fixed.subscription("Swiss thing", price: "50.00", currency: "CHF", anchor: Fixed.day(2026, 1, 5))
        ])
        let swiss = ledger.summaries.first { $0.name == "Swiss thing" }!

        #expect(swiss.countsInTotals == false)
        #expect(swiss.monthlyInBase == nil)
        #expect(swiss.yearlyInBase == nil)
        #expect(swiss.attention == .missingRate)
        // Excluded, and the total says so rather than quietly counting it as zero.
        #expect(ledger.monthlyTotal == Fixed.money("10"))
        #expect(ledger.missingRateCount == 1)
        #expect(ledger.needsAttention.map(\.name) == ["Swiss thing"])
    }

    @Test("Adding the rate brings the excluded item back into the totals")
    func addingARateRestoresTheItem() {
        let subscriptions = [
            Fixed.subscription("Euro thing", price: "10.00", anchor: Fixed.day(2026, 1, 5)),
            Fixed.subscription("Swiss thing", price: "50.00", currency: "CHF", anchor: Fixed.day(2026, 1, 5))
        ]
        let after = Fixed.ledger(subscriptions, rates: ["CHF": Fixed.money("1.05")])
        #expect(after.missingRateCount == 0)
        #expect(after.monthlyTotal == Fixed.money("62.50"))   // 10 + 50 × 1.05
    }

    @Test("An item with no date still counts. The amount is known, the day is not")
    func noDateStillCounts() {
        let ledger = Fixed.ledger([Fixed.subscription("Adobe Creative Cloud", price: "65.49", anchor: nil)])
        let summary = ledger.summaries[0]
        #expect(summary.nextPayment == nil)
        #expect(summary.daysUntil == nil)
        #expect(summary.countsInTotals)
        #expect(summary.monthlyInBase == Fixed.money("65.49"))
        #expect(summary.attention == .noDate)
        #expect(ledger.monthlyTotal == Fixed.money("65.49"))
    }

    @Test("Category totals add up to the monthly hero exactly")
    func categoryTotalsReconcile() {
        let ledger = SampleData.handoffLedger()
        let sum = ledger.categoryTotals.reduce(Decimal.zero) { $0 + $1.monthly }
        #expect(sum == ledger.monthlyTotal)
        // Shares are of that same total, so they add to one.
        let shares = ledger.categoryTotals.reduce(0.0) { $0 + $1.share }
        #expect(abs(shares - 1.0) < 0.000001)
    }

    @Test("Categories with nothing in them are left out of the chart")
    func emptyCategoriesAreOmitted() {
        let ledger = Fixed.ledger([Fixed.subscription("Only one", price: "10.00", category: "Software")])
        #expect(ledger.categoryTotals.count == 1)
        #expect(ledger.categoryTotals[0].category.name == "Software")
        #expect(ledger.categoryTotals[0].share == 1.0)
    }

    // MARK: - Attention

    @Test("Every attention state resolves to the one thing worth saying")
    func attentionStates() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Today", anchor: Fixed.today),
            Fixed.subscription("Soon", anchor: Fixed.day(2026, 8, 24)),
            Fixed.subscription("Later", anchor: Fixed.day(2026, 12, 1)),
            Fixed.subscription("Guessed", anchor: Fixed.day(2026, 12, 1), isEstimate: true),
            Fixed.subscription("Undated", anchor: nil),
            Fixed.subscription("Foreign", currency: "CHF", anchor: Fixed.day(2026, 12, 1)),
            Fixed.subscription("Ending", anchor: Fixed.day(2026, 3, 5), status: .cancelled, endsOn: Fixed.billingDay(2026, 9, 5)),
            Fixed.subscription("Converting", anchor: Fixed.day(2026, 12, 1), status: .trial, endsOn: Fixed.billingDay(2026, 8, 25)),
            Fixed.subscription("Resting", anchor: Fixed.day(2026, 12, 1), status: .paused)
        ])
        func attention(_ name: String) -> Attention {
            ledger.summaries.first { $0.name == name }!.attention
        }

        #expect(attention("Today") == .dueToday)
        #expect(attention("Soon") == .dueSoon)
        #expect(attention("Later") == .none)
        #expect(attention("Guessed") == .estimate)
        #expect(attention("Undated") == .noDate)
        #expect(attention("Foreign") == .missingRate)
        #expect(attention("Ending") == .endsOn(Fixed.day(2026, 9, 5)))
        #expect(attention("Converting") == .trialEnds(Fixed.day(2026, 8, 25)))
        // Paused has nothing actionable: it is already out of the totals and dimmed.
        #expect(attention("Resting") == .none)
    }

    @Test("Needs attention holds the fixable states, plus dated ones once they are close")
    func needsAttentionMembership() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Guessed", anchor: Fixed.day(2026, 12, 1), isEstimate: true),
            Fixed.subscription("Undated", anchor: nil),
            Fixed.subscription("Foreign", currency: "CHF", anchor: Fixed.day(2026, 12, 1)),
            Fixed.subscription("Soon", anchor: Fixed.day(2026, 8, 24)),
            // Ends in fourteen days: outside the seven-day window, so not yet a problem.
            Fixed.subscription("Ends later", anchor: Fixed.day(2026, 3, 5), status: .cancelled, endsOn: Fixed.billingDay(2026, 9, 5)),
            // Ends in three days: inside it.
            Fixed.subscription("Ends soon", anchor: Fixed.day(2026, 3, 5), status: .cancelled, endsOn: Fixed.billingDay(2026, 8, 25))
        ])
        #expect(Set(ledger.needsAttention.map(\.name)) == ["Guessed", "Undated", "Foreign", "Ends soon"])
        // "Due soon" is news, not a problem, so it stays out.
        #expect(!ledger.needsAttention.contains { $0.name == "Soon" })
    }

    @Test("A dated warning leaves the list once its date has gone past")
    func needsAttentionDropsDatesInThePast() {
        let ledger = Fixed.ledger([
            // Cancelled seven years ago. There is nothing left to act on, and a list
            // that keeps it is a list nobody can ever empty.
            Fixed.subscription(
                "Ended in 2019", anchor: Fixed.day(2019, 1, 5), status: .cancelled,
                billingStoppedOn: Fixed.billingDay(2019, 6, 5), endsOn: Fixed.billingDay(2019, 6, 5)
            ),
            // Ends in three days: inside the window and still ahead.
            Fixed.subscription(
                "Ends soon", anchor: Fixed.day(2026, 3, 5), status: .cancelled,
                billingStoppedOn: Fixed.billingDay(2026, 8, 25), endsOn: Fixed.billingDay(2026, 8, 25)
            )
        ])

        #expect(ledger.needsAttention.map(\.name) == ["Ends soon"])
    }

    // MARK: - Due soon

    @Test("Due soon is the window's charges, in base currency, soonest first")
    func dueSoon() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Gym", price: "13.99", anchor: Fixed.day(2026, 8, 24)),
            Fixed.subscription("Chat", price: "10.99", currency: "USD", anchor: Fixed.day(2026, 8, 25)),
            Fixed.subscription("Cloud", price: "2.99", anchor: Fixed.day(2026, 9, 17))
        ], rates: ["USD": Fixed.money("0.856")])

        let week = ledger.upcoming(within: Settings.paymentHighlightWindowDays)
        #expect(week.map(\.name) == ["Gym", "Chat"])
        #expect(week.compactMap(\.chargeInBase).reduce(Decimal.zero, +) == Fixed.money("23.40"))   // 13.99 + 10.99 × 0.856
    }

    @Test("Payment highlighting stays at seven days regardless of legacy settings")
    func dueSoonWindowIsFixed() {
        let subscriptions = [
            Fixed.subscription("Seven days", anchor: Fixed.day(2026, 8, 29)),
            Fixed.subscription("Eight days", anchor: Fixed.day(2026, 8, 30))
        ]
        let ledger = Fixed.ledger(subscriptions, settings: Settings(baseCurrency: "EUR"))
        #expect(ledger.summaries.first { $0.name == "Seven days" }?.attention == .dueSoon)
        #expect(ledger.summaries.first { $0.name == "Eight days" }?.attention != .dueSoon)
    }

    @Test("A charge that is due soon is the charge, not a monthly equivalent")
    func dueSoonTotalUsesTheCharge() {
        // A yearly plan falling due on Tuesday takes €120 out of the account, not €10.
        let ledger = Fixed.ledger([
            Fixed.subscription("Yearly thing", price: "120.00", cycle: .yearly, anchor: Fixed.day(2026, 8, 25))
        ])
        #expect(ledger.upcoming(within: Settings.paymentHighlightWindowDays).map(\.chargeInBase) == [Fixed.money("120")])
        #expect(ledger.monthlyTotal == Fixed.money("10"))
    }

    @Test("Due soon does not show zero when every rate is missing")
    func dueSoonWithNoKnownRate() {
        let ledger = Fixed.ledger([
            Fixed.subscription(
                "Swiss plan",
                price: "20.00",
                currency: "CHF",
                anchor: Fixed.day(2026, 8, 25)
            )
        ])

        let week = ledger.upcoming(within: Settings.paymentHighlightWindowDays)
        #expect(week.count == 1)
        #expect(week.first?.chargeInBase == nil)
    }

    // MARK: - Paid so far

    @Test("Paid so far counts charges in the subscription's own currency")
    func paidSoFar() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Netflix", price: "13.99", anchor: Fixed.day(2025, 2, 24))
        ])
        let paid = ledger.summaries[0].paidSoFar
        #expect(paid?.count == 18)
        #expect(paid?.total == Fixed.money("251.82"))
    }

    @Test("Paid so far is hidden, not zeroed, when the anchor is in the future")
    func paidSoFarHiddenForFutureAnchor() {
        let ledger = Fixed.ledger([
            Fixed.subscription("NordVPN", price: "89.00", cycle: .everyTwoYears, anchor: Fixed.day(2028, 8, 31))
        ])
        #expect(ledger.summaries[0].paidSoFar == nil)
        #expect(Fixed.ledger([Fixed.subscription("Undated", anchor: nil)]).summaries[0].paidSoFar == nil)
    }

    // MARK: - Upcoming

    @Test("Upcoming covers billing items inside the window, soonest first")
    func upcoming() {
        let ledger = SampleData.handoffLedger()
        #expect(ledger.upcoming(within: 30).map(\.name) == ["Netflix", "Spotify Premium", "Dropbox Plus"])
        // The popover's five: `upcoming(within: 365).prefix(5)`.
        #expect(Array(ledger.upcoming(within: 365).prefix(5).map(\.name))
                == ["Netflix", "Spotify Premium", "Dropbox Plus", "Duolingo Super", "1Password Families"])
    }

    // MARK: - Menu bar

    @Test("Something charging today does not override the chosen label style")
    func dueTodayLeavesTheLabelStyleAlone() {
        let ledger = Fixed.ledger([
            Fixed.subscription("A", anchor: Fixed.today),
            Fixed.subscription("B", anchor: Fixed.today)
        ])
        #expect(ledger.summaries.count { $0.daysUntil == 0 } == 2)
        // Icon only stays icon only on the one day it used to break, and the other two
        // keep saying the thing they were asked to say.
        #expect(ledger.menuBarLabel(style: .iconOnly) == .iconOnly)
        #expect(ledger.menuBarLabel(style: .nextRenewal, locale: Fixed.locale) == .text("A \u{00B7} today"))
        if case .text = ledger.menuBarLabel(style: .monthlyTotal, locale: Fixed.locale) {} else {
            Issue.record("Monthly total should still state a total on a due-today day")
        }
    }

    @Test("Menu bar labels show the next renewal, monthly total or icon")
    func menuBarLabelStyles() {
        let ledger = SampleData.handoffLedger()
        #expect(ledger.menuBarLabel(style: .nextRenewal, locale: Fixed.locale) == .text("Netflix · in 2 days"))
        #expect(ledger.menuBarLabel(style: .monthlyTotal, locale: Fixed.locale) == .text("€129"))
        // A long name is cut so the menu bar keeps its room.
        #expect(Ledger.menuBarName("Adobe Creative Cloud") == "Adobe Creativ…")
        #expect(Ledger.menuBarName("Spotify") == "Spotify")
        #expect(ledger.menuBarLabel(style: .iconOnly, locale: Fixed.locale) == .iconOnly)
    }

    @Test("Nothing tracked dims the glyph rather than showing a zero")
    func emptyMenuBar() {
        let ledger = Fixed.ledger([])
        #expect(ledger.menuBarLabel(style: .monthlyTotal) == .empty)
        #expect(ledger.menuBarLabel(style: .monthlyTotal).isDimmed)
        #expect(ledger.menuBarLabel(style: .monthlyTotal).title == nil)
    }

    // MARK: - Sections and search

    @Test("Each section filters to what its name promises")
    func sections() {
        let ledger = SampleData.handoffLedger()
        func names(_ section: Section) -> [String] {
            ledger.sorted(.name, search: "", section: section).map(\.name)
        }
        #expect(names(.all).count == 11)
        #expect(names(.upcoming) == ["Dropbox Plus", "Netflix", "Spotify Premium"])
        #expect(names(.attention) == ["Adobe Creative Cloud", "NordVPN"])
        #expect(names(.pausedCancelled) == ["Audible", "Disney+"])
        // A category holds its cancelled rows too.
        let streaming = Category.seeded.first(named: "Streaming")!.id
        #expect(names(.category(streaming)) == ["Disney+", "Netflix"])
    }

    @Test("Search matches names, case- and accent-insensitively, inside the current section")
    func search() {
        let ledger = SampleData.handoffLedger()
        #expect(ledger.sorted(.name, search: "spotify", section: .all).map(\.name) == ["Spotify Premium"])
        #expect(ledger.sorted(.name, search: "  PREMIUM ", section: .all).map(\.name) == ["Spotify Premium"])
        #expect(ledger.sorted(.name, search: "zzz", section: .all).isEmpty)
        // Scoped to the section, not the whole list.
        #expect(ledger.sorted(.name, search: "spotify", section: .pausedCancelled).isEmpty)
    }

    // MARK: - Sorting

    @Test("Next payment sorts soonest first and puts undated items last")
    func sortByNextPayment() {
        let ledger = SampleData.handoffLedger()
        let names = ledger.sorted(.nextPayment, search: "", section: .all).map(\.name)
        #expect(names == [
            "Netflix", "Spotify Premium", "Dropbox Plus", "Duolingo Super",
            "1Password Families", "Headspace", "Notion Plus", "NordVPN",
            // No date, by name: the undated active row and the two cancelled ones.
            "Adobe Creative Cloud", "Audible", "Disney+"
        ])
    }

    @Test("Name sorts case-insensitively rather than by ASCII")
    func sortByName() {
        let ledger = Fixed.ledger([
            Fixed.subscription("zebra"),
            Fixed.subscription("Apple"),
            Fixed.subscription("banana")
        ])
        #expect(ledger.sorted(.name, search: "", section: .all).map(\.name)
                == ["Apple", "banana", "zebra"])
    }

    @Test("Amount sorts on the price as charged, not on the converted one")
    func sortByAmount() {
        // $10.99 converts to €9.41, which is less than €10 — but sorting by amount is a
        // question about the numbers on the screen, and $10.99 is the bigger number.
        let ledger = Fixed.ledger([
            Fixed.subscription("Euro", price: "10.00"),
            Fixed.subscription("Dollar", price: "10.99", currency: "USD")
        ], rates: ["USD": Fixed.money("0.856")])
        #expect(ledger.sorted(.amount, search: "", section: .all).map(\.name) == ["Dollar", "Euro"])
        #expect(ledger.sorted(.monthly, search: "", section: .all).map(\.name) == ["Euro", "Dollar"])
    }

    @Test("Monthly puts items with no monthly figure last")
    func sortByMonthlyPutsExcludedLast() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Small", price: "5.00"),
            Fixed.subscription("Unrated", price: "500.00", currency: "CHF"),
            Fixed.subscription("Large", price: "50.00")
        ])
        #expect(ledger.sorted(.monthly, search: "", section: .all).map(\.name)
                == ["Large", "Small", "Unrated"])
    }

    @Test("Category sorts by the categories' order, then by name inside each category")
    func sortByCategory() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Zed", category: "AI tools"),          // sortOrder 4
            Fixed.subscription("Alpha", category: "AI tools"),
            Fixed.subscription("Middle", category: "Cloud storage")   // sortOrder 3
        ])
        #expect(ledger.sorted(.category, search: "", section: .all).map(\.name)
                == ["Middle", "Alpha", "Zed"])
    }

    @Test("Ties break on name, so the table never reshuffles between renders")
    func sortingIsTotal() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Beta", price: "10.00", anchor: Fixed.day(2026, 9, 1)),
            Fixed.subscription("Alpha", price: "10.00", anchor: Fixed.day(2026, 9, 1))
        ])
        for order in SortOrder.allCases {
            #expect(ledger.sorted(order, search: "", section: .all).map(\.name) == ["Alpha", "Beta"],
                    "order \(order.rawValue)")
        }
    }

    // MARK: - Sorting the other way

    @Test("Reversing next payment gives the latest first, and undated items stay last")
    func reverseNextPayment() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Soon", anchor: Fixed.day(2026, 8, 25)),
            Fixed.subscription("Later", anchor: Fixed.day(2026, 9, 10)),
            Fixed.subscription("Undated")
        ])
        func names(ascending: Bool) -> [String] {
            ledger.sorted(.nextPayment, search: "", section: .all, ascending: ascending).map(\.name)
        }
        #expect(names(ascending: true) == ["Soon", "Later", "Undated"])
        // Reversed, but "no date" is not a date: it is still the bottom of the column.
        #expect(names(ascending: false) == ["Later", "Soon", "Undated"])
    }

    @Test("Reversing amount gives the smallest first, and reversing monthly keeps the excluded last")
    func reverseAmountAndMonthly() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Small", price: "5.00"),
            Fixed.subscription("Unrated", price: "500.00", currency: "CHF"),
            Fixed.subscription("Large", price: "50.00")
        ])
        func names(_ order: OboloCore.SortOrder, ascending: Bool) -> [String] {
            ledger.sorted(order, search: "", section: .all, ascending: ascending).map(\.name)
        }
        #expect(names(.amount, ascending: false) == ["Unrated", "Large", "Small"])
        #expect(names(.amount, ascending: true) == ["Small", "Large", "Unrated"])
        #expect(names(.monthly, ascending: false) == ["Large", "Small", "Unrated"])
        #expect(names(.monthly, ascending: true) == ["Small", "Large", "Unrated"])
    }

    @Test("A reversed sort is total too: ties still break on name")
    func reversedSortingIsTotal() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Beta", price: "10.00", anchor: Fixed.day(2026, 9, 1)),
            Fixed.subscription("Alpha", price: "10.00", anchor: Fixed.day(2026, 9, 1))
        ])
        for order in SortOrder.allCases {
            let names = ledger
                .sorted(order, search: "", section: .all, ascending: !order.naturalAscending)
                .map(\.name)
            // Only the name column has a primary comparison left to reverse here; every
            // other column is a tie, and a tie reads forwards whichever way the column
            // was clicked.
            #expect(names == (order == .name ? ["Beta", "Alpha"] : ["Alpha", "Beta"]), "order \(order.rawValue)")
        }
    }

    @Test("No direction means the natural one, so a document written before this sorts as it did")
    func noDirectionIsTheNaturalOne() {
        let ledger = SampleData.handoffLedger()
        func names(_ order: OboloCore.SortOrder, ascending: Bool? = nil) -> [String] {
            ledger.sorted(order, search: "", section: .all, ascending: ascending).map(\.name)
        }
        for order in SortOrder.allCases {
            #expect(names(order) == names(order, ascending: order.naturalAscending), "order \(order.rawValue)")
            #expect(names(order) != names(order, ascending: !order.naturalAscending), "order \(order.rawValue)")
        }
        #expect(names(.name, ascending: false) == Array(names(.name).reversed()))
    }

    // MARK: - Sections

    @Test("The chart drops a category whose items are all paused")
    func chartDropsEmptyTotals() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Working", price: "10.00", category: "Software"),
            Fixed.subscription("Resting", price: "40.00", status: .paused, category: "Gaming")
        ])
        // One slice, because a zero slice is not a slice.
        #expect(ledger.categoryTotals.map(\.category.name) == ["Software"])
    }

    @Test("The sample library filters into All, Needs attention and Inactive")
    func sectionCounts() {
        let ledger = SampleData.handoffLedger()
        func count(_ section: OboloCore.Section) -> Int {
            ledger.sorted(.name, search: "", section: section).count
        }
        #expect(count(.all) == 11)
        #expect(count(.attention) == 2)
        #expect(count(.pausedCancelled) == 2)
        #expect(Fixed.ledger([Fixed.subscription("Fine", anchor: Fixed.day(2026, 12, 1))]).needsAttention.isEmpty)
    }

    // MARK: - Snapshot semantics

    @Test("A ledger is a snapshot: the same document at a later today reads differently")
    func ledgerIsASnapshotOfOneDay() {
        let document = SampleData.handoff()
        let onTheDay = Ledger(document: document, today: Fixed.day(2026, 8, 24), calendar: Fixed.calendar)
        #expect(onTheDay.summaries.filter { $0.daysUntil == 0 }.map(\.name) == ["Netflix"])
        #expect(onTheDay.summaries.first { $0.name == "Netflix" }?.daysUntil == 0)

        let afterwards = Ledger(document: document, today: Fixed.day(2026, 8, 25), calendar: Fixed.calendar)
        #expect(afterwards.summaries.first { $0.name == "Netflix" }?.nextPayment == Fixed.day(2026, 9, 24))
        // The document never changed — only the day did.
        #expect(onTheDay.document == afterwards.document)
    }
}
