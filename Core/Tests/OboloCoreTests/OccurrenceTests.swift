import Foundation
import Testing
@testable import OboloCore

/// The Calendar section's arithmetic: which charges land in a window, and what a month
/// adds up to.
@Suite("Occurrences")
struct OccurrenceTests {

    /// February to May, exclusive of the May bound.
    private static let februaryToApril2026 = (from: Fixed.day(2026, 2, 1), to: Fixed.day(2026, 5, 1))

    // MARK: - Stepping

    @Test("A monthly anchor on 31 January clamps to 28 Feb, 31 Mar, 30 Apr")
    func monthEndClampsPerOccurrence() {
        // The clamp is anchor-relative, so the day-of-month recovers after February
        // instead of walking down to the 28th and staying there.
        let ledger = Fixed.ledger([
            Fixed.subscription("Month end", price: "9.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 31))
        ])
        let dates = ledger.occurrences(
            from: Self.februaryToApril2026.from, to: Self.februaryToApril2026.to
        ).map(\.date)

        #expect(dates == [Fixed.day(2026, 2, 28), Fixed.day(2026, 3, 31), Fixed.day(2026, 4, 30)])
    }

    @Test("A yearly subscription lands once in a three-month window")
    func yearlyAppearsOnce() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Yearly", price: "83.99", cycle: .yearly, anchor: Fixed.day(2023, 3, 9))
        ])
        let dates = ledger.occurrences(
            from: Self.februaryToApril2026.from, to: Self.februaryToApril2026.to
        ).map(\.date)

        #expect(dates == [Fixed.day(2026, 3, 9)])
    }

    @Test("A 2-year plan paid up front appears only in the month its anchor falls in")
    func futureAnchorAppearsInItsOwnMonthOnly() {
        // The sample's NordVPN: bought ahead, so the anchor *is* the first charge and
        // there is nothing at all before it.
        let anchor = Fixed.day(2028, 8, 31)
        let ledger = Fixed.ledger([
            Fixed.subscription("Two years", price: "89.00", cycle: .everyTwoYears, anchor: anchor)
        ])

        let itsMonth = ledger.occurrences(from: Fixed.day(2028, 8, 1), to: Fixed.day(2028, 9, 1))
        #expect(itsMonth.map(\.date) == [anchor])

        #expect(ledger.occurrences(from: Fixed.day(2028, 7, 1), to: Fixed.day(2028, 8, 1)).isEmpty)
        #expect(ledger.occurrences(from: Fixed.day(2028, 9, 1), to: Fixed.day(2028, 10, 1)).isEmpty)
        // The next one is two years on, not one.
        #expect(ledger.occurrences(from: Fixed.day(2029, 8, 1), to: Fixed.day(2029, 9, 1)).isEmpty)
        #expect(
            ledger.occurrences(from: Fixed.day(2030, 8, 1), to: Fixed.day(2030, 9, 1)).map(\.date)
                == [Fixed.day(2030, 8, 31)]
        )
    }

    @Test("Nothing appears before the anchor, in any cycle")
    func nothingBeforeTheAnchor() {
        let anchor = Fixed.day(2026, 3, 12)
        for cycle in BillingCycle.fixedCases {
            let ledger = Fixed.ledger([
                Fixed.subscription("Started in March", price: "5.00", cycle: cycle, anchor: anchor)
            ])
            let earlier = ledger.occurrences(from: Fixed.day(2020, 1, 1), to: anchor)
            #expect(earlier.isEmpty, "\(cycle.displayName) invented a charge before its anchor")

            let straddling = ledger.occurrences(from: Fixed.day(2026, 1, 1), to: Fixed.day(2026, 4, 1))
            #expect(straddling.first?.date == anchor)
            #expect(straddling.allSatisfy { $0.date >= anchor })
        }
    }

    // MARK: - What is left out

    @Test("Paused and cancelled subscriptions keep charges from before they stopped")
    func stoppedItemsKeepHistory() {
        let anchor = Fixed.day(2026, 3, 4)
        let stopped = Fixed.billingDay(2026, 5, 1)
        let ledger = Fixed.ledger([
            Fixed.subscription("Active", price: "10.00", anchor: anchor),
            Fixed.subscription("Trial", price: "20.00", anchor: anchor, status: .trial),
            Fixed.subscription(
                "Paused", price: "40.00", anchor: anchor, status: .paused,
                billingStoppedOn: stopped
            ),
            Fixed.subscription(
                "Cancelled", price: "80.00", anchor: anchor, status: .cancelled,
                billingStoppedOn: stopped
            ),
            // The no-date case: it counts in the monthly total, but there is no square
            // to put it on.
            Fixed.subscription("No date", price: "60.00", anchor: nil)
        ])
        let names = ledger.occurrences(from: Fixed.day(2026, 3, 1), to: Fixed.day(2026, 4, 1))
            .compactMap { ledger.summary(id: $0.subscriptionID)?.name }

        #expect(names == ["Active", "Cancelled", "Paused", "Trial"])

        let afterStop = ledger.occurrences(
            from: Fixed.day(2026, 5, 1), to: Fixed.day(2026, 6, 1)
        ).compactMap { ledger.summary(id: $0.subscriptionID)?.name }
        #expect(afterStop == ["Active", "Trial"])
    }

    @Test("A stopped subscription with no stop date lists nothing and reports no total")
    func stoppedWithoutADateHasNoHistory() throws {
        let ledger = Fixed.ledger([
            Fixed.subscription(
                "Cancelled long ago", price: "10.00",
                anchor: Fixed.day(2025, 1, 15), status: .cancelled
            ),
            Fixed.subscription(
                "Paused long ago", price: "20.00",
                anchor: Fixed.day(2025, 1, 15), status: .paused
            )
        ])

        // Nothing is known about when these stopped charging, so nothing is claimed.
        // Today would be a guess, and a guess here prints months of charges nobody made.
        #expect(ledger.occurrences(from: Fixed.day(2025, 1, 1), to: Fixed.day(2026, 9, 1)).isEmpty)
        #expect(ledger.monthTotal(containing: Fixed.day(2025, 3, 15)).count == 0)
        for summary in ledger.summaries {
            #expect(summary.paidSoFar == nil)
        }
    }

    @Test("The stop day is exclusive: the charge that falls on it is not counted")
    func theStopDayItselfIsNotCharged() throws {
        let anchor = Fixed.day(2025, 1, 15)
        let subscription = Fixed.subscription(
            "Stopped mid-March", price: "10.00", anchor: anchor,
            status: .cancelled, billingStoppedOn: Fixed.billingDay(2026, 3, 15)
        )
        let ledger = Fixed.ledger([subscription])

        // February charged on the 15th; March's charge falls on the stop day itself and
        // is the first one that did not happen.
        #expect(ledger.monthTotal(containing: Fixed.day(2026, 2, 1)).charged == Fixed.money("10.00"))
        #expect(ledger.monthTotal(containing: Fixed.day(2026, 3, 1)).count == 0)

        // Fourteen charges: 15 Jan 2025 through 15 Feb 2026.
        let paid = try #require(ledger.summaries.first?.paidSoFar)
        #expect(paid.count == 14)
        #expect(paid.total == Fixed.money("140.00"))
    }

    @Test("Occurrences sort by date, then by name")
    func sortedByDateThenName() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Zulu", price: "1.00", anchor: Fixed.day(2026, 3, 10)),
            Fixed.subscription("Alpha", price: "2.00", anchor: Fixed.day(2026, 3, 10)),
            Fixed.subscription("Mike", price: "3.00", anchor: Fixed.day(2026, 3, 2))
        ])
        let names = ledger.occurrences(from: Fixed.day(2026, 3, 1), to: Fixed.day(2026, 4, 1))
            .compactMap { ledger.summary(id: $0.subscriptionID)?.name }

        #expect(names == ["Mike", "Alpha", "Zulu"])
    }

    @Test("A charge in a currency with no rate is listed and excluded from the money")
    func missingRateIsCountedButNotSummed() {
        let ledger = Fixed.ledger(
            [
                Fixed.subscription("Euro thing", price: "10.00", anchor: Fixed.day(2026, 3, 5)),
                Fixed.subscription("Swiss thing", price: "50.00", currency: "CHF", anchor: Fixed.day(2026, 3, 6))
            ]
        )
        let swiss = ledger.occurrences(from: Fixed.day(2026, 3, 1), to: Fixed.day(2026, 4, 1))
            .first { $0.currency == "CHF" }

        #expect(swiss?.amount == Fixed.money("50"))
        // Never a zero: the amount in base is genuinely unknown.
        #expect(swiss?.amountInBase == nil)

        let total = ledger.monthTotal(containing: Fixed.day(2026, 3, 15))
        #expect(total.charged == Fixed.money("10"))
        #expect(total.count == 2)
        #expect(total.excludedCount == 1)
    }

    // MARK: - Month totals

    @Test("The window is half-open: the first of the next month belongs to the next month")
    func windowExcludesItsUpperBound() {
        let ledger = Fixed.ledger([
            Fixed.subscription("First of the month", price: "7.00", anchor: Fixed.day(2026, 3, 1))
        ])
        #expect(ledger.occurrences(from: Fixed.day(2026, 2, 1), to: Fixed.day(2026, 3, 1)).isEmpty)
        #expect(ledger.occurrences(from: Fixed.day(2026, 3, 1), to: Fixed.day(2026, 4, 1)).count == 1)
    }

    @Test("August 2026 reconciles against the sample dataset")
    func sampleMonthReconciles() {
        let ledger = SampleData.handoffLedger()
        let august = ledger.monthTotal(containing: SampleData.referenceToday)

        // Three charges land in August 2026, and only three. Dropbox on the 17th
        // (€11.99), Netflix on the 24th (€13.99), Spotify on the 25th ($10.99 → €9.41
        // at the sample's 0.856). Adobe has no date, the four yearly plans renew in
        // January, March and November, NordVPN's anchor is 2028, and Disney+ and
        // Audible are not billing.
        #expect(august.count == 3)
        #expect(august.excludedCount == 0)
        #expect(august.charged == Fixed.money("35.39"))

        let rows = ledger.occurrences(from: Fixed.day(2026, 8, 1), to: Fixed.day(2026, 9, 1))
        #expect(rows.map(\.date) == [Fixed.day(2026, 8, 17), Fixed.day(2026, 8, 24), Fixed.day(2026, 8, 25)])
        #expect(rows.compactMap { ledger.summary(id: $0.subscriptionID)?.name }
            == ["Dropbox Plus", "Netflix", "Spotify Premium"])
        // The charge stays in the currency it is charged in; only the base figure is
        // converted.
        #expect(rows.last?.currency == "USD")
        #expect(rows.last?.amount == Fixed.money("10.99"))
        #expect(rows.last?.amountInBase == Fixed.money("9.41"))

        // The sum of the parts is the total the header prints.
        #expect(rows.reduce(Decimal.zero) { $0 + ($1.amountInBase ?? 0) } == august.charged)
    }

    @Test("A month the sample does not touch totals nothing, honestly")
    func emptySampleMonth() {
        let ledger = SampleData.handoffLedger()
        // February 2026: nothing monthly had started except Netflix (Feb 2025),
        // Dropbox (Sep 2024) and Spotify (Mar 2025) — all three renew in February.
        let february = ledger.monthTotal(containing: Fixed.day(2026, 2, 10))
        #expect(february.count == 3)

        // October 2023 is before every anchor in the dataset.
        let october2023 = ledger.monthTotal(containing: Fixed.day(2023, 10, 10))
        #expect(october2023.count == 0)
        #expect(october2023.charged == 0)
        #expect(october2023.excludedCount == 0)
    }

    @Test("A past month shows what was paid, not an empty grid")
    func pastMonthsAreVisible() {
        let ledger = SampleData.handoffLedger()
        // March 2026 held Notion's yearly renewal, the three current monthlies, and
        // Disney+, which still billed then.
        let names = ledger.occurrences(from: Fixed.day(2026, 3, 1), to: Fixed.day(2026, 4, 1))
            .compactMap { ledger.summary(id: $0.subscriptionID)?.name }
        #expect(names.contains("Notion Plus"))
        #expect(names.contains("Disney+"))
        #expect(names.count == 5)
    }

    // MARK: - Section

    @Test("Calendar is a section with a title")
    func calendarSection() {
        let ledger = SampleData.handoffLedger()
        #expect(Section.calendar.title(in: ledger.document) == "Calendar")
    }


}
