import Foundation
import Testing
@testable import OboloCore

/// The sums the status line, the day's popover and the calendar key print: an amount
/// with no rate is left out and counted, never added as zero.
@Suite("Converted sums")
struct ConvertedSumTests {

    @Test("Nothing to add is zero, not unknown")
    func empty() {
        let sum = ConvertedSum([Decimal?]())
        #expect(sum.total == 0)
        #expect(sum.excludedCount == 0)
    }

    @Test("Amounts that all have a rate add up, with nothing left out")
    func allConverted() {
        let sum = ConvertedSum([Fixed.money("10.00"), Fixed.money("2.50")])
        #expect(sum.total == Fixed.money("12.50"))
        #expect(sum.excludedCount == 0)
    }

    @Test("One amount without a rate is unknown, never zero")
    func onlyMissing() {
        let sum = ConvertedSum([nil])
        #expect(sum.total == nil)
        #expect(sum.excludedCount == 1)
    }

    @Test("A mix adds what it can and counts what it left out")
    func mixed() {
        let sum = ConvertedSum([Fixed.money("10.00"), nil, nil])
        #expect(sum.total == Fixed.money("10.00"))
        #expect(sum.excludedCount == 2)
    }

    // MARK: - From the ledger

    private let euro = Fixed.subscription("Euro thing", price: "10.00", anchor: Fixed.day(2026, 3, 5))
    private let swiss = Fixed.subscription("Swiss thing", price: "50.00", currency: "CHF", anchor: Fixed.day(2026, 3, 5))
    private let swissLater = Fixed.subscription("Swiss later", price: "30.00", currency: "CHF", anchor: Fixed.day(2026, 3, 6))

    @Test("A calendar day whose only charge has no rate has an unknown total")
    func dayWithOnlyAMissingRate() {
        let ledger = Fixed.ledger([euro, swissLater])
        let day = ledger.occurrences(from: Fixed.day(2026, 3, 6), to: Fixed.day(2026, 3, 7))
        #expect(day.count == 1)
        let sum = ConvertedSum(charges: day)
        #expect(sum.total == nil)
        #expect(sum.excludedCount == 1)
    }

    @Test("A calendar day with one charge with a rate and one without says what it left out")
    func dayWithAMix() {
        let ledger = Fixed.ledger([euro, swiss])
        let day = ledger.occurrences(from: Fixed.day(2026, 3, 5), to: Fixed.day(2026, 3, 6))
        #expect(day.count == 2)
        let sum = ConvertedSum(charges: day)
        #expect(sum.total == Fixed.money("10.00"))
        #expect(sum.excludedCount == 1)
    }

    @Test("A month's sum agrees with the month total under the calendar grid")
    func agreesWithMonthTotal() {
        let ledger = Fixed.ledger([euro, swiss, swissLater])
        let month = ledger.occurrences(from: Fixed.day(2026, 3, 1), to: Fixed.day(2026, 4, 1))
        let reference = ledger.monthTotal(containing: Fixed.day(2026, 3, 15))
        let sum = ConvertedSum(charges: month)
        #expect(sum.total == reference.charged)
        #expect(sum.excludedCount == reference.excludedCount)
    }

    @Test("Rows per month: billing rows only, and one without a rate is left out and counted")
    func monthlyRows() {
        let ledger = Fixed.ledger([
            euro,
            swiss,
            Fixed.subscription("Resting", price: "40.00", status: .paused)
        ])
        let sum = ConvertedSum(monthly: ledger.summaries)
        // The same figures as the hero and its footnote.
        #expect(sum.total == ledger.monthlyTotal)
        #expect(sum.total == Fixed.money("10.00"))
        #expect(sum.excludedCount == ledger.missingRateCount)
        #expect(sum.excludedCount == 1)
    }

    @Test("Rows with no rate at all have an unknown monthly figure; paused rows cost nothing")
    func monthlyRowsUnknownOrZero() {
        let missing = Fixed.ledger([swiss])
        #expect(ConvertedSum(monthly: missing.summaries).total == nil)

        let paused = Fixed.ledger([Fixed.subscription("Resting", price: "40.00", status: .paused)])
        let sum = ConvertedSum(monthly: paused.summaries)
        #expect(sum.total == 0)
        #expect(sum.excludedCount == 0)
    }
}
