import Foundation
import Testing
@testable import OboloCore

/// The sample dataset publishes a set of figures and says every one of them reconciles.
/// This suite is that claim, made executable: if a rounding rule or a normalisation
/// formula ever drifts, one of these breaks before anyone opens the app.
///
/// The expected totals are €129.41 a month, €1 552.92 a year, 9 active, 2 due within
/// 7 days totalling €23.40, 2 needing attention, and category totals of
/// €73.49 · €13.99 · €11.99 · €9.41 · €8.70 · €7.00 · €4.83.
@Suite("Sample dataset reconciliation")
struct HandoffReconciliationTests {

    private let ledger = SampleData.handoffLedger()

    @Test("Eleven subscriptions, nine of them still billing")
    func counts() {
        #expect(ledger.summaries.count == 11)
        #expect(ledger.activeCount == 9)
        #expect(ledger.filtered(search: "", section: .pausedCancelled).count == 2)
    }

    @Test("Monthly €129.41 and yearly €1 552.92")
    func totals() {
        #expect(ledger.monthlyTotal == Fixed.money("129.41"))
        #expect(ledger.yearlyTotal == Fixed.money("1552.92"))
    }

    @Test("Two payments inside the week, €23.40 between them")
    func dueSoon() {
        // The app answers this through `upcoming(within:)`. The two fall on different
        // days, so the order does not depend on how names break a tie.
        let week = ledger.upcoming(within: Settings.paymentHighlightWindowDays)
        #expect(week.map(\.name) == ["Netflix", "Spotify Premium"])
        #expect(week.compactMap(\.chargeInBase).reduce(Decimal.zero, +) == Fixed.money("23.40"))
    }

    @Test("Two items need attention: the one with no date and the one with a guessed price")
    func attention() {
        #expect(ledger.needsAttention.count == 2)
        #expect(Set(ledger.needsAttention.map(\.name)) == ["Adobe Creative Cloud", "NordVPN"])
        #expect(ledger.needsAttention.count(where: \.isEstimate) == 1)
        #expect(ledger.missingRateCount == 0)
    }

    @Test("Category totals are €73.49 · €13.99 · €11.99 · €9.41 · €8.70 · €7.00 · €4.83, at 57 / 11 / 9 / 7 / 7 / 5 / 4 per cent")
    func categoryTotals() {
        let totals = ledger.categoryTotals
        #expect(totals.map(\.category.name) == [
            "Software", "Streaming", "Cloud storage", "Music", "Security & VPN", "Other", "Fitness & health"
        ])
        #expect(totals.map(\.monthly) == [
            Fixed.money("73.49"), Fixed.money("13.99"), Fixed.money("11.99"), Fixed.money("9.41"),
            Fixed.money("8.70"), Fixed.money("7.00"), Fixed.money("4.83")
        ])
        #expect(totals.map { Int(($0.share * 100).rounded()) } == [57, 11, 9, 7, 7, 5, 4])
    }

    @Test("Every next payment lands on the day the published table prints")
    func nextPayments() {
        func next(_ name: String) -> Date? {
            ledger.summaries.first { $0.name == name }?.nextPayment
        }
        #expect(next("Netflix") == Fixed.day(2026, 8, 24))              // Mon, in 2 days
        #expect(next("Spotify Premium") == Fixed.day(2026, 8, 25))      // Tue, in 3 days
        #expect(next("Dropbox Plus") == Fixed.day(2026, 9, 17))         // Thu
        #expect(next("Duolingo Super") == Fixed.day(2026, 11, 4))       // Wed
        #expect(next("1Password Families") == Fixed.day(2027, 1, 2))    // Sat
        #expect(next("Headspace") == Fixed.day(2027, 1, 17))            // Sun
        #expect(next("Notion Plus") == Fixed.day(2027, 3, 9))           // Tue
        #expect(next("NordVPN") == Fixed.day(2028, 8, 31))              // Thu, the future anchor
        #expect(next("Adobe Creative Cloud") == nil)                    // no date
        #expect(next("Disney+") == nil)                                 // cancelled
        #expect(next("Audible") == nil)                                 // paused
    }

    @Test("Every monthly equivalent matches the published column")
    func monthlyEquivalents() {
        func monthly(_ name: String) -> Decimal? {
            ledger.summaries.first { $0.name == name }?.monthlyInBase
        }
        #expect(monthly("Netflix") == Fixed.money("13.99"))
        #expect(monthly("Spotify Premium") == Fixed.money("9.41"))      // $10.99 × 0.856
        #expect(monthly("Adobe Creative Cloud") == Fixed.money("65.49"))
        #expect(monthly("Dropbox Plus") == Fixed.money("11.99"))
        #expect(monthly("Duolingo Super") == Fixed.money("7.00"))       // 83.99 ÷ 12
        #expect(monthly("1Password Families") == Fixed.money("4.99"))   // 59.88 ÷ 12
        #expect(monthly("Headspace") == Fixed.money("4.83"))            // 57.99 ÷ 12
        #expect(monthly("Notion Plus") == Fixed.money("8.00"))          // 96.00 ÷ 12
        #expect(monthly("NordVPN") == Fixed.money("3.71"))              // 89.00 ÷ 24
        #expect(monthly("Disney+") == nil)                              // cancelled, excluded
        #expect(monthly("Audible") == nil)                              // paused, excluded
    }

    @Test("Netflix's figures: €251.82 over 18 payments, €167.88 a year")
    func netflixFigures() {
        let netflix = ledger.summaries.first { $0.name == "Netflix" }!
        #expect(netflix.paidSoFar?.count == 18)
        #expect(netflix.paidSoFar?.total == Fixed.money("251.82"))
        #expect(netflix.yearlyInBase == Fixed.money("167.88"))
        #expect(netflix.daysUntil == 2)
        // "Next three payments" makes the cycle tangible.
        #expect(RenewalSchedule.upcoming(
            anchor: netflix.subscription.anchorDate!.startOfDay(in: Fixed.calendar), cycle: netflix.cycle,
            today: Fixed.today, count: 3, calendar: Fixed.calendar
        ) == [Fixed.day(2026, 8, 24), Fixed.day(2026, 9, 24), Fixed.day(2026, 10, 24)])
    }

    @Test("The totals, the next renewal and the five soonest prices format as expected")
    func totalsAndUpcomingFormat() {
        let base = ledger.document.settings.baseCurrency
        #expect(MoneyFormatting.amount(ledger.monthlyTotal, currency: base, locale: Fixed.locale) == "€129.41")
        #expect(MoneyFormatting.amount(ledger.yearlyTotal, currency: base, locale: Fixed.locale) == "€1,552.92")

        // "Next: Netflix in 2 days".
        let next = ledger.upcoming(within: 365)[0]
        #expect(next.name == "Netflix")
        #expect(DateFormatting.renewal(next.nextPayment!, today: Fixed.today, calendar: Fixed.calendar, locale: Fixed.locale)
                == "in 2 days")

        // The five upcoming rows, in the original currency.
        let rows = ledger.upcoming(within: 365).prefix(5).map {
            MoneyFormatting.amount($0.price, currency: $0.currency, estimate: $0.isEstimate, locale: Fixed.locale)
        }
        #expect(rows == ["€13.99", "$10.99", "€11.99", "€83.99", "€59.88"])
    }

    @Test("Missing dates, estimates and cancellations affect totals and renewal details")
    func edgeCases() {
        func summary(_ name: String) -> SubscriptionSummary {
            ledger.summaries.first { $0.name == name }!
        }

        // No date: still in the totals, still shown, flagged.
        let undated = summary("Adobe Creative Cloud")
        #expect(undated.countsInTotals)
        #expect(undated.attention == .noDate)
        #expect(undated.paidSoFar == nil)

        // Estimate with a future anchor: in the totals, "paid so far" hidden.
        let guessed = summary("NordVPN")
        #expect(guessed.countsInTotals)
        #expect(guessed.isEstimate)
        #expect(guessed.attention == .estimate)
        #expect(guessed.paidSoFar == nil)

        // Cancelled with an end date: out of the totals, still listed, "ends 5 Sep".
        let ending = summary("Disney+")
        #expect(!ending.countsInTotals)
        #expect(ending.attention == .endsOn(Fixed.day(2026, 9, 5)))
        #expect(ending.attention.label(today: Fixed.today, calendar: Fixed.calendar, locale: Fixed.locale)
                == "ends 5 Sep")

        // Was paused, now cancelled with access ended 1 Aug: out of the totals, no next
        // payment, nothing to fix.
        let resting = summary("Audible")
        #expect(resting.status == .cancelled)
        #expect(!resting.countsInTotals)
        #expect(resting.nextPayment == nil)
        #expect(!resting.attention.isFixable)
    }

    @Test("The sample survives a save and a load unchanged")
    func roundTripsThroughTheStore() throws {
        let document = SampleData.handoff()
        let decoded = try DocumentStore.decode(DocumentStore.encode(document))
        #expect(decoded == document)
        #expect(Ledger(document: decoded, today: Fixed.today, calendar: Fixed.calendar).monthlyTotal
                == Fixed.money("129.41"))
    }
}
