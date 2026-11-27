import Foundation

/// The queries behind Home's Months chart.
///
/// The timeline goes through `occurrences(from:to:)`, which is the only thing in the app
/// that knows what a charge on a given day cost. Nothing here does money or date arithmetic
/// of its own: it buckets and it sums, so a rule fixed in one place stays fixed here.
extension Ledger {

    /// A window wider than this is a bug in the caller, not a chart anybody reads.
    /// A hundred years of monthly bars.
    private static let maximumBuckets = 1200

    /// The earliest day any subscription in the document can have been charged on: the
    /// oldest anchor, start of day. `nil` when no subscription has one.
    ///
    /// The floor of every honest history in the app. Nothing was charged before it,
    /// because nothing in the document is anchored before it, and a chart that plots a
    /// bucket ending on or before this date is drawing an absence of records as an
    /// absence of spending.
    public var recordBegins: Date? {
        document.subscriptions
            .compactMap(\.anchorDate)
            .min()
            .map { $0.startOfDay(in: calendar) }
    }

    /// What was charged over `[from, to)`, cut into `interval`-wide buckets.
    ///
    /// The window grows outwards to whole buckets: `from` snaps down to its bucket's
    /// first day and `to` snaps up to the end of its own, so every bar covers a full
    /// interval. A bar drawn over four days of a month reads as a collapse in spending
    /// rather than as a window that stopped on the 4th, and the fix belongs here rather
    /// than in each chart. The window actually used is on `SpendTimeline.start`/`.end`.
    ///
    /// Buckets with nothing in them are kept. A chart needs the gap: an empty February
    /// between two full months is information, and closing it up would draw January
    /// next to March as though they were adjacent.
    public func timeline(
        from: Date,
        to: Date,
        interval: SpendInterval
    ) -> SpendTimeline {
        let windowStart = interval.start(of: from, calendar: calendar)
        let requestedEnd = interval.bounds(of: to, calendar: calendar)
        // A `to` that already sits on a boundary is exclusive and needs no rounding; any
        // other lands inside a bucket, and that bucket is drawn whole.
        let windowEnd = to == requestedEnd.start ? requestedEnd.start : requestedEnd.end

        let floor = recordBegins
        guard windowStart < windowEnd else {
            return SpendTimeline(
                interval: interval,
                buckets: [],
                start: windowStart,
                end: windowStart,
                recordBegins: floor,
                charged: 0,
                count: 0,
                excludedCount: 0
            )
        }

        // Totals keyed by the first day of the bucket the charge fell in, which is the
        // same key the empty bucket below is built with.
        var chargedByBucket: [Date: Decimal] = [:]
        var countByBucket: [Date: Int] = [:]
        var excludedByBucket: [Date: Int] = [:]

        for occurrence in occurrences(from: windowStart, to: windowEnd) {
            let key = interval.start(of: occurrence.date, calendar: calendar)
            let amount = occurrence.amountInBase ?? 0
            chargedByBucket[key, default: 0] += amount
            countByBucket[key, default: 0] += 1
            if occurrence.amountInBase == nil {
                excludedByBucket[key, default: 0] += 1
            }
        }

        let todayStart = calendar.startOfDay(for: today)
        var buckets: [SpendTimeline.Bucket] = []
        var cursor = windowStart
        while cursor < windowEnd, buckets.count < Ledger.maximumBuckets {
            let next = interval.start(of: cursor, offsetByBuckets: 1, calendar: calendar)
            // `MonthRange` returns the input unchanged if the calendar cannot step, and
            // a bucket that does not advance would spin here forever.
            guard next > cursor else { break }

            let phase: SpendTimeline.Bucket.Phase
            if cursor <= todayStart, todayStart < next {
                phase = .current
            } else if next <= todayStart {
                phase = .past
            } else {
                phase = .future
            }

            buckets.append(
                SpendTimeline.Bucket(
                    start: cursor,
                    end: next,
                    charged: chargedByBucket[cursor] ?? 0,
                    count: countByBucket[cursor] ?? 0,
                    excludedCount: excludedByBucket[cursor] ?? 0,
                    phase: phase,
                    isBeforeRecord: floor.map { next <= $0 } ?? true
                )
            )
            cursor = next
        }

        return SpendTimeline(
            interval: interval,
            buckets: buckets,
            start: windowStart,
            end: buckets.last?.end ?? windowStart,
            recordBegins: floor,
            charged: buckets.reduce(Decimal.zero) { $0 + $1.charged },
            count: buckets.reduce(0) { $0 + $1.count },
            excludedCount: buckets.reduce(0) { $0 + $1.excludedCount }
        )
    }
}
