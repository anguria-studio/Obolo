import Foundation
import Testing
@testable import OboloCore

/// The arithmetic behind Home's Months chart: what a window of charges adds up to once it is cut
/// into bars, and what the bars are allowed to claim.
///
/// Every scenario is anchored around the sample library's reference date, Saturday 22 August 2026, so
/// "past", "current" and "future" mean the same thing in every test below.
@Suite("Spend timeline")
struct SpendTimelineTests {

    /// The whole of 2026, which is twelve monthly buckets, four quarters or one year.
    private static let year2026 = (from: Fixed.day(2026, 1, 1), to: Fixed.day(2027, 1, 1))

    /// The bucket holding `date`, found the way the Home chart finds one.
    private func bucket(_ timeline: SpendTimeline, containing date: Date) -> SpendTimeline.Bucket? {
        timeline.buckets.first { $0.start <= date && date < $0.end }
    }

    private func charged(_ timeline: SpendTimeline, _ year: Int, _ month: Int) -> Decimal? {
        bucket(timeline, containing: Fixed.day(year, month, 15))?.charged
    }

    /// The buckets the document can speak to, which is what the Home chart plots.
    private func covered(_ timeline: SpendTimeline) -> [SpendTimeline.Bucket] {
        timeline.buckets.filter { !$0.isBeforeRecord }
    }

    // MARK: - Bucketing

    @Test("A monthly plan puts one charge in every bucket")
    func monthlyFillsEveryBucket() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2025, 3, 12))
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(timeline.buckets.count == 12)
        #expect(timeline.buckets.allSatisfy { $0.count == 1 })
        #expect(timeline.charged == Fixed.money("120.00"))
    }

    @Test("A yearly plan lands whole in one bucket and leaves the other eleven empty")
    func yearlyIsLumpy() {
        // The reason this feature exists. A monthly equivalent would draw twelve bars of
        // €7 and hide the fact that August costs €84 and nothing else costs anything.
        let ledger = Fixed.ledger([
            Fixed.subscription("Yearly", price: "84.00", cycle: .yearly, anchor: Fixed.day(2024, 8, 9))
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(charged(timeline, 2026, 8) == Fixed.money("84.00"))
        #expect(timeline.buckets.count { $0.charged == 0 } == 11)
        #expect(timeline.buckets.filter { $0.charged > 0 }.map(\.start) == [Fixed.day(2026, 8, 1)])
    }

    @Test("Empty buckets are kept, so the gap between two charges stays visible")
    func emptyBucketsSurvive() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Quarterly", price: "30.00", cycle: .quarterly, anchor: Fixed.day(2026, 1, 5))
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(timeline.buckets.map(\.count) == [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0])
    }

    @Test("Quarters and years snap to the calendar, not to the requested window")
    func bucketsSnapToCalendarBoundaries() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 20))
        ])

        // Asked for May to late November; a quarter still begins in April, July and
        // October, and both ends of the window move outwards to reach them.
        let quarters = ledger.timeline(
            from: Fixed.day(2026, 5, 1), to: Fixed.day(2026, 11, 20), interval: .quarter
        )
        #expect(quarters.buckets.map(\.start) == [
            Fixed.day(2026, 4, 1), Fixed.day(2026, 7, 1), Fixed.day(2026, 10, 1)
        ])
        #expect(quarters.end == Fixed.day(2027, 1, 1))

        let years = ledger.timeline(
            from: Fixed.day(2026, 5, 1), to: Fixed.day(2026, 11, 20), interval: .year
        )
        #expect(years.buckets.map(\.start) == [Fixed.day(2026, 1, 1)])
        #expect(years.buckets.first?.end == Fixed.day(2027, 1, 1))
    }

    @Test("The window grows outwards to whole buckets rather than drawing a part bar")
    func windowGrowsToWholeBuckets() {
        // A bar covering four days of March would read as a collapse in spending.
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 20))
        ])
        let timeline = ledger.timeline(
            from: Fixed.day(2026, 1, 18), to: Fixed.day(2026, 3, 4), interval: .month
        )

        #expect(timeline.start == Fixed.day(2026, 1, 1))
        #expect(timeline.end == Fixed.day(2026, 4, 1))
        #expect(timeline.buckets.count == 3)
        #expect(timeline.charged == Fixed.money("30.00"))
    }

    @Test("A window shorter than a bucket still draws the bucket it falls in")
    func shortWindowGrowsToItsBucket() {
        // A fortnight in March is drawn as March.
        let ledger = SampleData.handoffLedger()
        let timeline = ledger.timeline(
            from: Fixed.day(2026, 3, 10), to: Fixed.day(2026, 3, 25), interval: .month
        )

        #expect(timeline.buckets.count == 1)
        #expect(timeline.start == Fixed.day(2026, 3, 1))
        #expect(timeline.end == Fixed.day(2026, 4, 1))
    }

    @Test("An end that already sits on a boundary is exclusive and adds no bar")
    func boundaryEndAddsNoBucket() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 20))
        ])
        let timeline = ledger.timeline(
            from: Fixed.day(2026, 1, 1), to: Fixed.day(2026, 3, 1), interval: .month
        )

        #expect(timeline.buckets.map(\.start) == [Fixed.day(2026, 1, 1), Fixed.day(2026, 2, 1)])
    }

    @Test("A window with nothing in it produces no buckets rather than an empty bar")
    func invertedWindowIsEmpty() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 20))
        ])
        let timeline = ledger.timeline(
            from: Fixed.day(2026, 5, 1), to: Fixed.day(2026, 5, 1), interval: .month
        )

        #expect(timeline.buckets.isEmpty)
        #expect(timeline.charged == 0)
    }

    // MARK: - Past, present and future

    @Test("The bucket holding today is neither past nor future")
    func phaseSplitsAtToday() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 20))
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        // Today is 22 August 2026, so July is behind, August straddles, September ahead.
        #expect(bucket(timeline, containing: Fixed.day(2026, 7, 15))?.phase == .past)
        #expect(bucket(timeline, containing: Fixed.day(2026, 8, 15))?.phase == .current)
        #expect(bucket(timeline, containing: Fixed.day(2026, 9, 15))?.phase == .future)
        #expect(timeline.buckets.count { $0.phase == .current } == 1)
    }

    @Test("A future window is entirely forecast and still totals")
    func futureWindowTotals() {
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "12.50", cycle: .monthly, anchor: Fixed.day(2026, 1, 20))
        ])
        let timeline = ledger.timeline(
            from: Fixed.day(2027, 1, 1), to: Fixed.day(2028, 1, 1), interval: .month
        )

        #expect(timeline.buckets.allSatisfy { $0.phase == .future })
        #expect(timeline.charged == Fixed.money("150.00"))
    }

    // MARK: - What a zero is allowed to mean

    @Test("The record begins on the oldest anchor in the document")
    func recordBeginsAtTheOldestAnchor() {
        // Duolingo Super, anchored 4 November 2023, is the oldest thing in the sample.
        #expect(SampleData.handoffLedger().recordBegins == Fixed.day(2023, 11, 4))
    }

    @Test("Buckets before the oldest anchor are marked, so an empty bar is not a fact")
    func bucketsBeforeTheRecordAreMarked() {
        // Obolo holds no payment record. A plan anchored in March 2026 says nothing at
        // all about January, and a zero bar there means "no data", not "no spending".
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 3, 15))
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(timeline.recordBegins == Fixed.day(2026, 3, 15))
        // January and February end on or before the anchor; March holds it.
        #expect(timeline.buckets.prefix(2).allSatisfy { $0.isBeforeRecord })
        #expect(timeline.buckets.dropFirst(2).allSatisfy { !$0.isBeforeRecord })
        #expect(covered(timeline).count == 10)
    }

    @Test("A document with no anchors can speak to nothing")
    func noAnchorsMeansNoCoverage() {
        let ledger = Fixed.ledger([
            Fixed.subscription("No date", price: "10.00", cycle: .monthly, anchor: nil)
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(timeline.recordBegins == nil)
        #expect(timeline.buckets.allSatisfy { $0.isBeforeRecord })
        #expect(covered(timeline).isEmpty)
    }

    @Test("Only buckets from the record onwards carry figures a chart may average")
    func coveredBucketsHoldTheRecord() {
        // Anchored 1 July: six covered buckets holding €10 each, six uncovered zeroes.
        // Averaging all twelve would print €5 and halve every month the user paid.
        let ledger = Fixed.ledger([
            Fixed.subscription("Monthly", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 7, 1))
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        let plotted = covered(timeline)
        #expect(plotted.count == 6)
        #expect(plotted.first?.start == Fixed.day(2026, 7, 1))
        #expect(plotted.allSatisfy { $0.charged == Fixed.money("10.00") })
        #expect(plotted.reduce(Decimal.zero) { $0 + $1.charged } == timeline.charged)
    }

    @Test("A stopped plan contributes up to the day billing stopped and no further")
    func stoppedPlanStopsContributing() {
        let ledger = Fixed.ledger([
            Fixed.subscription(
                "Cancelled", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 10),
                status: .cancelled, billingStoppedOn: Fixed.billingDay(2026, 4, 1)
            )
        ])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(timeline.buckets.map(\.count) == [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(timeline.charged == Fixed.money("30.00"))
    }

    // MARK: - Honest money

    @Test("A past bucket uses the price in force then, not today's")
    func pastBucketsUseTheHistoricPrice() {
        // €10 from January, €20 from July. A year of this is €90 + €120, and twelve
        // times the current price would say €240.
        let subscription = Subscription(
            name: "Risen",
            categoryID: Category.seeded.first(named: "Software")?.id ?? Category.unknown.id,
            price: Fixed.money("20.00"),
            currency: "EUR",
            priceChanges: [
                PriceChange(effectiveFrom: Fixed.billingDay(2026, 1, 15), price: Fixed.money("10.00"), currency: "EUR")
            ],
            currentPriceSince: Fixed.billingDay(2026, 7, 15),
            cycle: .monthly,
            anchorDate: Fixed.billingDay(2026, 1, 15),
            createdAt: Fixed.day(2026, 1, 15)
        )
        let ledger = Fixed.ledger([subscription])
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        #expect(charged(timeline, 2026, 6) == Fixed.money("10.00"))
        #expect(charged(timeline, 2026, 7) == Fixed.money("20.00"))
        #expect(timeline.charged == Fixed.money("180.00"))
    }

    @Test("A charge with no rate is counted and left out of the money, never added as zero")
    func missingRateIsExcludedNotZeroed() {
        let ledger = Fixed.ledger(
            [
                Fixed.subscription("In base", price: "10.00", cycle: .monthly, anchor: Fixed.day(2026, 1, 10)),
                Fixed.subscription("No rate", price: "99.00", currency: "JPY", cycle: .monthly, anchor: Fixed.day(2026, 1, 10))
            ]
        )
        let timeline = ledger.timeline(
            from: Self.year2026.from, to: Self.year2026.to, interval: .month
        )

        let january = bucket(timeline, containing: Fixed.day(2026, 1, 15))
        #expect(january?.count == 2)
        #expect(january?.excludedCount == 1)
        #expect(january?.charged == Fixed.money("10.00"))
        #expect(timeline.excludedCount == 12)
    }

    // MARK: - Against the sample dataset

    @Test("Every monthly bucket agrees with the month total the Calendar section draws")
    func bucketsAgreeWithMonthTotal() {
        // The two are separate code paths over the same occurrences. If they ever
        // disagree, the user sees two answers to one question in two clicks.
        let ledger = SampleData.handoffLedger()
        let timeline = ledger.timeline(
            from: Fixed.day(2026, 1, 1), to: Fixed.day(2027, 1, 1), interval: .month
        )

        #expect(timeline.buckets.count == 12)
        for bucket in timeline.buckets {
            let month = ledger.monthTotal(containing: bucket.start)
            #expect(bucket.charged == month.charged)
            #expect(bucket.count == month.count)
            #expect(bucket.excludedCount == month.excludedCount)
        }
    }

    @Test("A quarter is exactly its three months, and a year exactly its four quarters")
    func coarserBucketsSumTheFinerOnes() {
        let ledger = SampleData.handoffLedger()
        let window = (from: Fixed.day(2026, 1, 1), to: Fixed.day(2027, 1, 1))
        let months = ledger.timeline(from: window.from, to: window.to, interval: .month)
        let quarters = ledger.timeline(from: window.from, to: window.to, interval: .quarter)
        let years = ledger.timeline(from: window.from, to: window.to, interval: .year)

        #expect(quarters.buckets.count == 4)
        for (index, quarter) in quarters.buckets.enumerated() {
            let three = months.buckets[(index * 3)..<(index * 3 + 3)]
            #expect(quarter.charged == three.reduce(Decimal.zero) { $0 + $1.charged })
            #expect(quarter.count == three.reduce(0) { $0 + $1.count })
        }
        #expect(years.buckets.count == 1)
        #expect(years.charged == months.charged)
        #expect(years.charged == quarters.charged)
    }
}
