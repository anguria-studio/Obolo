import Foundation
import Testing
@testable import OboloCore

/// A subscription whose price moved, and everything downstream of that: what a past
/// charge cost, what has been paid altogether, and what a CSV carries.
@Suite("Price history")
struct PriceHistoryTests {

    private let calendar = Fixed.calendar

    // MARK: - The reference plan
    //
    // Monthly, anchored 20 March 2025, so it charges on the 20th of every month. Three
    // prices over its life:
    //
    //   €10 from 20 Mar 2025 — ten charges, Mar 2025 to Dec 2025
    //   €15 from 20 Jan 2026 — five charges, Jan 2026 to May 2026
    //   €20 from 20 Jun 2026 — three charges by the sample library's reference date, 22 Aug 2026
    //
    // Eighteen payments, €235 altogether. Eighteen times the current price would say
    // €360, which is the number this whole feature exists to stop the app printing.

    private static let anchor = Fixed.billingDay(2025, 3, 20)
    private static let secondPriceFrom = Fixed.billingDay(2026, 1, 20)
    private static let currentPriceFrom = Fixed.billingDay(2026, 6, 20)

    private func plan(
        currentPriceSince: BillingDay? = PriceHistoryTests.currentPriceFrom,
        anchor: BillingDay? = PriceHistoryTests.anchor
    ) -> Subscription {
        Subscription(
            name: "Streaming plan",
            categoryID: Category.seeded.first(named: "Streaming")?.id ?? Category.unknown.id,
            price: Fixed.money("20.00"),
            currency: "EUR",
            priceChanges: [
                PriceChange(effectiveFrom: PriceHistoryTests.secondPriceFrom, price: Fixed.money("15.00"), currency: "EUR"),
                PriceChange(effectiveFrom: PriceHistoryTests.anchor, price: Fixed.money("10.00"), currency: "EUR")
            ],
            currentPriceSince: currentPriceSince,
            cycle: .monthly,
            anchorDate: anchor,
            createdAt: PriceHistoryTests.anchor.startOfDay(in: calendar)
        )
    }

    // MARK: - price(on:)

    @Test("The entries sort themselves, whatever order they arrive in")
    func entriesAreSorted() {
        #expect(plan().priceChanges.map(\.price) == [Fixed.money("10.00"), Fixed.money("15.00")])

        var subscription = plan()
        subscription.priceChanges = [
            PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 20), price: Fixed.money("15.00"), currency: "EUR"),
            PriceChange(effectiveFrom: Fixed.billingDay(2024, 1, 20), price: Fixed.money("5.00"), currency: "EUR")
        ]
        #expect(subscription.priceChanges.map(\.effectiveFrom) == [Fixed.billingDay(2024, 1, 20), Fixed.billingDay(2026, 1, 20)])
    }

    @Test("A change applies on its own day and not the day before")
    func boundaries() {
        let subscription = plan()

        // The day before each boundary, and the boundary itself.
        #expect(subscription.price(on: Fixed.day(2026, 1, 19), calendar: calendar).price == Fixed.money("10.00"))
        #expect(subscription.price(on: Fixed.day(2026, 1, 20), calendar: calendar).price == Fixed.money("15.00"))
        #expect(subscription.price(on: Fixed.day(2026, 6, 19), calendar: calendar).price == Fixed.money("15.00"))
        #expect(subscription.price(on: Fixed.day(2026, 6, 20), calendar: calendar).price == Fixed.money("20.00"))

        // On the first entry's own day, and everywhere after the current price started.
        #expect(subscription.price(on: PriceHistoryTests.anchor.startOfDay(in: calendar), calendar: calendar).price == Fixed.money("10.00"))
        #expect(subscription.price(on: Fixed.today, calendar: calendar).price == Fixed.money("20.00"))
        #expect(subscription.price(on: Fixed.day(2030, 1, 1), calendar: calendar).price == Fixed.money("20.00"))

        // Before the first entry, that first entry's price: Obolo knows of no earlier
        // one and does not invent one.
        #expect(subscription.price(on: Fixed.day(2019, 5, 1), calendar: calendar).price == Fixed.money("10.00"))
        #expect(subscription.price(on: Fixed.day(2026, 3, 20), calendar: calendar).currency == "EUR")
    }

    @Test("A future history entry does not rewrite past charges")
    func futureHistoryDoesNotRewritePast() {
        // A mistyped year, as it arrives: an entry dated December and a current price
        // that starts next year, on a plan that has been charging since January. Rule 4
        // would hand every 2026 charge to the €15 entry, so the entry never gets in —
        // every door that carries a clock drops it first.
        //
        // The `currentPriceSince` beside it is a different thing and is kept: a current
        // price that has not started is the announced rise, not a fault. With the entry
        // above gone there is no earlier price left for it to sit over, so it answers
        // for nothing until its own day.
        let typed = Subscription(
            name: "Future change",
            categoryID: Category.unknown.id,
            price: Fixed.money("10.00"),
            currency: "EUR",
            priceChanges: [
                PriceChange(
                    effectiveFrom: Fixed.billingDay(2026, 12, 1),
                    price: Fixed.money("15.00"),
                    currency: "EUR"
                )
            ],
            currentPriceSince: Fixed.billingDay(2027, 1, 1),
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 1)
        )
        // What it would have done had it been kept.
        #expect(typed.price(on: Fixed.day(2026, 2, 1), calendar: calendar).price == Fixed.money("15.00"))

        let (subscription, dropped) = typed.droppingFutureHistory(after: BillingDay(Fixed.today, calendar: calendar))
        #expect(dropped == 1)
        #expect(subscription.priceChanges.isEmpty)
        #expect(subscription.currentPriceSince == Fixed.billingDay(2027, 1, 1))
        #expect(subscription.price(on: Fixed.day(2026, 2, 1), calendar: calendar).price == Fixed.money("10.00"))
        #expect(subscription.price(on: Fixed.day(2026, 12, 1), calendar: calendar).price == Fixed.money("10.00"))
        // And with no history under it, it is not an announcement of anything either.
        #expect(subscription.announcedPriceChange(on: Fixed.today, calendar: calendar) == nil)
    }

    @Test("Dropping future history keeps every entry dated today or earlier")
    func droppingFutureHistoryKeepsThePast() {
        let (kept, dropped) = plan().droppingFutureHistory(after: BillingDay(Fixed.today, calendar: calendar))
        #expect(dropped == 0)
        #expect(kept.priceChanges.count == 2)
        #expect(kept.currentPriceSince == PriceHistoryTests.currentPriceFrom)

        // Today itself is history: a rise recorded this morning applies to this
        // morning's charge.
        var todayEntry = plan()
        todayEntry.priceChanges.append(
            PriceChange(effectiveFrom: BillingDay(Fixed.today, calendar: calendar), price: Fixed.money("25.00"), currency: "EUR")
        )
        #expect(todayEntry.droppingFutureHistory(after: BillingDay(Fixed.today, calendar: calendar)).dropped == 0)

        // Tomorrow is not.
        var tomorrowEntry = plan()
        tomorrowEntry.priceChanges.append(
            PriceChange(effectiveFrom: Fixed.billingDay(2026, 8, 23), price: Fixed.money("25.00"), currency: "EUR")
        )
        let result = tomorrowEntry.droppingFutureHistory(after: BillingDay(Fixed.today, calendar: calendar))
        #expect(result.dropped == 1)
        #expect(result.subscription.priceChanges.count == 2)
    }

    @Test("Cancelling keeps paid history and stops future charges")
    func cancelledHistoryStops() throws {
        let subscription = Fixed.subscription(
            "Cancelled",
            price: "10.00",
            anchor: Fixed.day(2026, 1, 1),
            status: .cancelled,
            billingStoppedOn: Fixed.billingDay(2026, 4, 1)
        )
        let ledger = Fixed.ledger([subscription])
        let summary = try #require(ledger.summaries.first)

        #expect(summary.paidSoFar?.count == 3)
        #expect(summary.paidSoFar?.total == Fixed.money("30.00"))
        #expect(
            ledger.occurrences(from: Fixed.day(2026, 1, 1), to: Fixed.day(2026, 6, 1)).count
                == 3
        )
    }

    @Test("A subscription with no history costs its current price on every day")
    func noHistoryIsTheCurrentPrice() {
        let subscription = Fixed.subscription("Netflix", price: "13.99", anchor: PriceHistoryTests.anchor.startOfDay(in: calendar))
        #expect(subscription.priceChanges.isEmpty)
        #expect(subscription.price(on: Fixed.day(2019, 1, 1), calendar: calendar).price == Fixed.money("13.99"))
        #expect(subscription.price(on: Fixed.today, calendar: calendar).price == Fixed.money("13.99"))
    }

    @Test("An unset “current price since” falls back to the last change, never swallowing the history")
    func unsetCurrentPriceSince() {
        let subscription = plan(currentPriceSince: nil)
        // The anchor is older than the last change, so the current price took over on
        // the day of that change and the two earlier periods still answer below it.
        #expect(subscription.currentPriceStart == PriceHistoryTests.secondPriceFrom)
        #expect(subscription.price(on: Fixed.day(2025, 12, 20), calendar: calendar).price == Fixed.money("10.00"))
        #expect(subscription.price(on: PriceHistoryTests.secondPriceFrom.startOfDay(in: calendar), calendar: calendar).price == Fixed.money("20.00"))

        // With no anchor either, the last change is still the boundary.
        #expect(plan(currentPriceSince: nil, anchor: nil).currentPriceStart == PriceHistoryTests.secondPriceFrom)

        // And an anchor *after* the last change wins, because the current price cannot
        // have started before the plan did.
        let late = plan(currentPriceSince: nil, anchor: Fixed.billingDay(2026, 3, 20))
        #expect(late.currentPriceStart == Fixed.billingDay(2026, 3, 20))
    }

    // MARK: - Paid so far

    @Test("Eighteen payments at three prices are summed, not multiplied")
    func paidSoFarSumsThePricesInForce() throws {
        let ledger = Fixed.ledger([plan()])
        let summary = try #require(ledger.summaries.first)

        #expect(summary.paidSoFar?.count == 18)
        #expect(summary.paidSoFar?.total == Fixed.money("235.00"))
        // What the old arithmetic would have claimed.
        #expect(summary.paidSoFar?.total != Fixed.money("360.00"))
    }

    @Test("A row with no history still multiplies to the same answer")
    func paidSoFarWithoutHistory() throws {
        let ledger = Fixed.ledger([Fixed.subscription("Plain", price: "10.00", anchor: PriceHistoryTests.anchor.startOfDay(in: calendar))])
        let summary = try #require(ledger.summaries.first)
        #expect(summary.paidSoFar?.count == 18)
        #expect(summary.paidSoFar?.total == Fixed.money("180.00"))
    }

    @Test("Paid history keeps different currencies separate")
    func paidSoFarKeepsCurrenciesSeparate() throws {
        var subscription = plan()
        subscription.priceChanges[0].currency = "USD"
        let paid = try #require(Fixed.ledger([subscription]).summaries.first?.paidSoFar)

        #expect(paid.count == 18)
        #expect(paid.total == nil)
        #expect(paid.totalsByCurrency["USD"] == Fixed.money("100.00"))
        #expect(paid.totalsByCurrency["EUR"] == Fixed.money("135.00"))
    }

    /// The paid payments the Detail lists, as (price, how many) in the order the prices
    /// were first charged: the breakdown its price list prints beside each price.
    private func breakdown(_ subscription: Subscription) -> [(price: Decimal, count: Int)] {
        let ledger = Fixed.ledger([subscription])
        var rows: [(price: Decimal, count: Int)] = []
        for payment in ledger.payments(for: subscription.id) where !payment.isNext {
            if let index = rows.firstIndex(where: { $0.price == payment.price }) {
                rows[index].count += 1
            } else {
                rows.append((payment.price, 1))
            }
        }
        return rows
    }

    @Test("The payments itemise what was charged, first-charged first")
    func paymentsItemiseThePrices() throws {
        let subscription = plan()
        let paid = try #require(Fixed.ledger([subscription]).summaries.first?.paidSoFar)
        let rows = breakdown(subscription)

        #expect(rows.map(\.count) == [10, 5, 3])
        #expect(rows.map(\.price) == [
            Fixed.money("10.00"), Fixed.money("15.00"), Fixed.money("20.00")
        ])
        // The breakdown and "Total spent" are the same eighteen payments.
        #expect(rows.reduce(0) { $0 + $1.count } == paid.count)
        #expect(rows.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.count) } == paid.total)
    }

    @Test("A row with no history itemises as its one price")
    func paymentsItemiseASinglePrice() throws {
        let subscription = Fixed.subscription("Plain", price: "10.00", anchor: PriceHistoryTests.anchor.startOfDay(in: calendar))
        let rows = breakdown(subscription)

        #expect(rows.count == 1)
        #expect(rows.first?.count == 18)
        #expect(rows.first?.price == Fixed.money("10.00"))
    }

    @Test("A history the first payment sits after is charged at one price, and says so")
    func historyBelowTheFirstPaymentIsNeverCharged() throws {
        // The mistake the editor's timeline warns about, as the data records it: five
        // months of ChatGPT Plus at $24.40, an upgrade to $121.71, and the *upgrade*
        // date typed into "first payment" instead of the February one. Every charge then
        // lands on or after the current price's start, so the $24.40 entry answers for
        // nothing — which is exactly what a single-price breakdown means.
        let subscription = Subscription(
            name: "ChatGPT",
            categoryID: Category.unknown.id,
            price: Fixed.money("121.71"),
            currency: "USD",
            priceChanges: [
                PriceChange(
                    effectiveFrom: Fixed.billingDay(2026, 2, 25), price: Fixed.money("24.40"), currency: "USD"
                )
            ],
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 7, 25)
        )
        let paid = try #require(Fixed.ledger([subscription]).summaries.first?.paidSoFar)
        let rows = breakdown(subscription)

        #expect(rows.count == 1)
        #expect(rows.first?.price == Fixed.money("121.71"))
        #expect(paid.total == Fixed.money("121.71"))

        // With the first payment where it belongs, both prices are charged.
        var corrected = subscription
        corrected.anchorDate = Fixed.billingDay(2026, 2, 25)
        corrected.currentPriceSince = Fixed.billingDay(2026, 7, 25)
        let fixed = try #require(Fixed.ledger([corrected]).summaries.first?.paidSoFar)

        #expect(breakdown(corrected).map(\.count) == [5, 1])
        #expect(fixed.count == 6)
        #expect(fixed.total == Fixed.money("243.71"))
    }

    // MARK: - The announced rise

    /// "From 20 September your plan is €25", entered before it happens.
    private func announced() -> Subscription {
        var subscription = plan()
        subscription.price = Fixed.money("25.00")
        subscription.priceChanges = [
            PriceChange(effectiveFrom: PriceHistoryTests.anchor, price: Fixed.money("10.00"), currency: "EUR"),
            PriceChange(effectiveFrom: Fixed.billingDay(2026, 6, 20), price: Fixed.money("20.00"), currency: "EUR")
        ]
        subscription.currentPriceSince = Fixed.billingDay(2026, 9, 20)
        return subscription
    }

    @Test("A rise announced for next month leaves this month's price alone")
    func announcedRiseDoesNotStartEarly() {
        let subscription = announced()

        #expect(subscription.price(on: Fixed.today, calendar: calendar).price == Fixed.money("20.00"))
        #expect(subscription.price(on: Fixed.day(2026, 9, 19), calendar: calendar).price == Fixed.money("20.00"))
        #expect(subscription.price(on: Fixed.day(2026, 9, 20), calendar: calendar).price == Fixed.money("25.00"))
        // And it rewrites nothing below it.
        #expect(subscription.price(on: Fixed.day(2025, 4, 20), calendar: calendar).price == Fixed.money("10.00"))
    }

    @Test("The rise is reported, and only while it is still ahead")
    func announcedRiseIsReported() throws {
        let subscription = announced()

        let rise = try #require(subscription.announcedPriceChange(on: Fixed.today, calendar: calendar))
        #expect(rise.price == Fixed.money("25.00"))
        #expect(rise.effectiveFrom == Fixed.billingDay(2026, 9, 20))

        // On the day it starts it is no longer an announcement, it is the price.
        #expect(subscription.announcedPriceChange(on: Fixed.day(2026, 9, 20), calendar: calendar) == nil)
        // And a row with no rise pending has none to report.
        #expect(plan().announcedPriceChange(on: Fixed.today, calendar: calendar) == nil)
    }

    @Test("The totals stay on the price being paid, and the next charge does not")
    func announcedRiseInTheLedger() throws {
        // Anchored on the 20th, today is 22 August, so the next payment is 20 September
        // — the day the rise starts. That charge is the new price; this month is not.
        let summary = try #require(Fixed.ledger([announced()]).summaries.first)

        #expect(summary.price == Fixed.money("20.00"))
        #expect(summary.nextPayment == Fixed.day(2026, 9, 20))
        #expect(summary.nextCharge?.price == Fixed.money("25.00"))
        #expect(summary.announcedPriceChange?.price == Fixed.money("25.00"))
        // The monthly figure follows what is being paid now, not what was announced.
        #expect(summary.monthlyInBase == Fixed.money("20.00"))
    }

    @Test("Dropping future history leaves an announced rise standing")
    func announcedRiseSurvivesNormalisation() {
        let (kept, dropped) = announced().droppingFutureHistory(after: BillingDay(Fixed.today, calendar: calendar))

        #expect(dropped == 0)
        #expect(kept.currentPriceSince == Fixed.billingDay(2026, 9, 20))
        #expect(kept.priceChanges.count == 2)
        #expect(kept.price(on: Fixed.today, calendar: calendar).price == Fixed.money("20.00"))
    }

    // MARK: - Occurrences and month totals

    @Test("A charge in a past month carries the price that was in force then")
    func pastOccurrencesUseTheOldPrice() throws {
        let ledger = Fixed.ledger([plan()])

        let november = ledger.monthTotal(containing: Fixed.day(2025, 11, 15))
        #expect(november.count == 1)
        #expect(november.charged == Fixed.money("10.00"))

        let february = ledger.monthTotal(containing: Fixed.day(2026, 2, 15))
        #expect(february.charged == Fixed.money("15.00"))

        // The current month, and a future one, are the current price.
        #expect(ledger.monthTotal(containing: Fixed.today).charged == Fixed.money("20.00"))
        #expect(ledger.monthTotal(containing: Fixed.day(2026, 12, 1)).charged == Fixed.money("20.00"))

        let occurrence = try #require(
            ledger.occurrences(from: Fixed.day(2025, 11, 1), to: Fixed.day(2025, 12, 1)).first
        )
        #expect(occurrence.date == Fixed.day(2025, 11, 20))
        #expect(occurrence.amount == Fixed.money("10.00"))
        #expect(occurrence.amountInBase == Fixed.money("10.00"))
    }

    @Test("Current-month and future figures are untouched by a history")
    func totalsAreUnchanged() {
        let ledger = Fixed.ledger([plan()])
        // The monthly total is the *current* price, as the All list shows it.
        #expect(ledger.monthlyTotal == Fixed.money("20.00"))
        #expect(ledger.summaries.first?.price == Fixed.money("20.00"))
        #expect(ledger.summaries.first?.nextPayment == Fixed.day(2026, 9, 20))
    }

    // MARK: - CSV

    @Test("The history survives an export and an import")
    func csvRoundTrip() throws {
        let original = Fixed.document([plan()])
        let data = CSVExporter.export(original)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("2025-03-20=10.00 EUR;2026-01-20=15.00 EUR"))
        #expect(text.contains("2026-06-20"))

        var rebuilt = StoreDocument.initial()
        let preview = try CSVImporter.preview(data: data, document: rebuilt, calendar: calendar, locale: Fixed.locale)
        #expect(preview.errorCount == 0)
        #expect(preview.rows.count { $0.severity == .warning } == 0)
        CSVImporter.apply(preview, to: &rebuilt, createMissingCategories: true)

        #expect(rebuilt.subscriptions == original.subscriptions)
        let imported = try #require(rebuilt.subscriptions.first)
        #expect(imported.priceChanges.count == 2)
        #expect(imported.currentPriceSince == PriceHistoryTests.currentPriceFrom)
        #expect(imported.price(on: Fixed.day(2025, 11, 20), calendar: calendar).price == Fixed.money("10.00"))
    }

    @Test("CSV keeps the currency of each earlier price")
    func csvKeepsHistoryCurrencies() throws {
        var subscription = plan()
        subscription.priceChanges[0] = PriceChange(
            effectiveFrom: PriceHistoryTests.anchor,
            price: Fixed.money("10.00"),
            currency: "USD"
        )
        let original = Fixed.document([subscription])
        let data = CSVExporter.export(original)

        var rebuilt = StoreDocument.initial()
        let preview = try CSVImporter.preview(
            data: data,
            document: rebuilt,
            calendar: calendar,
            locale: Fixed.locale
        )
        CSVImporter.apply(preview, to: &rebuilt, createMissingCategories: true)

        #expect(rebuilt.subscriptions.first?.priceChanges.first?.currency == "USD")
        #expect(rebuilt.subscriptions == original.subscriptions)
    }

    @Test("An unreadable entry loses that entry and warns, rather than the whole row")
    func csvPartialHistory() throws {
        let csv = """
        Name,Price,Currency,Billing cycle,Anchor date,Price history,Current price since
        Thing,20.00,EUR,Monthly,2025-03-20,2025-03-20=10.00;whenever=15.00,2026-06-20
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        let row = try #require(preview.rows.first)
        #expect(row.isImportable)
        #expect(row.severity == .warning)
        #expect(row.subscription?.priceChanges.count == 1)
        #expect(row.subscription?.currentPriceSince == PriceHistoryTests.currentPriceFrom)
    }

    @Test("An import drops price history dated after today and says how much it dropped")
    func csvDropsFutureHistory() throws {
        let csv = """
        Name,Price,Currency,Billing cycle,Anchor date,Price history,Current price since
        Thing,20.00,EUR,Monthly,2025-03-20,2025-03-20=10.00;2026-12-01=15.00,2027-01-01
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8),
            document: .initial(),
            calendar: calendar,
            locale: Fixed.locale,
            now: Fixed.today
        )
        let row = try #require(preview.rows.first)

        #expect(row.isImportable)
        #expect(row.severity == .warning)
        #expect(row.subscription?.priceChanges.count == 1)
        #expect(row.subscription?.priceChanges.first?.price == Fixed.money("10.00"))
        // Kept: a current price dated ahead is the announced rise, and the import has no
        // reason to disbelieve it. Only the *entry* above was dangerous.
        #expect(row.subscription?.currentPriceSince == Fixed.billingDay(2027, 1, 1))
        #expect(row.issues.contains {
            $0.message == "Obolo removed 1 price history entry dated after today."
        })
        // The entry that survived answers for every day below the announced rise.
        #expect(row.subscription?.price(on: Fixed.day(2025, 3, 19), calendar: calendar).price == Fixed.money("10.00"))
        #expect(row.subscription?.price(on: Fixed.today, calendar: calendar).price == Fixed.money("10.00"))
        #expect(row.subscription?.price(on: Fixed.day(2027, 1, 1), calendar: calendar).price == Fixed.money("20.00"))
    }

    @Test("A file with neither column imports as a subscription that never changed price")
    func csvWithoutTheColumns() throws {
        let csv = """
        Name,Price,Currency,Billing cycle,Anchor date
        Thing,20.00,EUR,Monthly,2025-03-20
        """
        let preview = try CSVImporter.preview(
            data: Data(csv.utf8), document: .initial(), calendar: calendar, locale: Fixed.locale
        )
        #expect(preview.rows.first?.subscription?.priceChanges.isEmpty == true)
        #expect(preview.rows.first?.subscription?.currentPriceSince == nil)
        #expect(preview.unmatchedColumns.isEmpty)
    }

    // MARK: - Decoding

    @Test("A store written before price history existed still decodes")
    func oldDocumentsDecode() throws {
        let json = """
        {
          "id": "50000000-0000-4000-B000-0000000000FF",
          "name": "Old Netflix",
          "price": 13.99,
          "currency": "EUR",
          "cycle": "monthly",
          "status": "active",
          "isEstimate": false,
          "paymentMethod": "",
          "notes": ""
        }
        """
        let decoder = JSONDecoder()
        let subscription = try decoder.decode(Subscription.self, from: Data(json.utf8))

        #expect(subscription.priceChanges.isEmpty)
        #expect(subscription.currentPriceSince == nil)
        #expect(subscription.price(on: Fixed.day(2019, 1, 1), calendar: calendar).price == Fixed.money("13.99"))
    }

    @Test("A store with a history round-trips through JSON")
    func encodedDocumentsDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // One instance: `plan()` mints a fresh id on every call.
        let subscription = plan()
        let data = try encoder.encode(subscription)
        let decoded = try decoder.decode(Subscription.self, from: data)

        #expect(decoded.priceChanges == subscription.priceChanges)
        #expect(decoded.currentPriceSince == PriceHistoryTests.currentPriceFrom)
        #expect(decoded == subscription)
    }
}
