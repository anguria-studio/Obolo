import Foundation

/// What was charged over a window, cut into equal buckets.
///
/// The data behind Home's Months chart. It answers the question a monthly equivalent is built
/// to hide: **not** "what do you pay a month" but "what actually left the account in
/// March, and what will leave it next March". A yearly plan contributes its whole price
/// to one bucket and nothing to the other eleven, which is the entire point — smoothing
/// it into twelve equal slices is what stops anybody noticing that three annual renewals
/// all land in the same week.
///
/// Built from `Ledger.occurrences(from:to:)`, so every rule that governs the Calendar
/// grid governs this too: the anchor is the floor, a stopped plan needs a
/// `billingStoppedOn` before it contributes anything, and a charge in a currency with no
/// rate is counted in `count` and left out of `charged`.
///
/// ## What a zero means
///
/// Obolo holds no record of payments. It holds anchors, cycles and price changes, and
/// reconstructs the past from them. So an empty bucket has two possible causes that must
/// not look alike: nothing was charged, or the document knows nothing about that far
/// back. `recordBegins` and `Bucket.isBeforeRecord` separate them, and a chart that
/// draws a bar for a bucket with `isBeforeRecord` is claiming a fact it does not have.
public struct SpendTimeline: Sendable, Equatable {

    /// One bar.
    public struct Bucket: Identifiable, Sendable, Equatable {
        /// First day of the bucket, start of day in the ledger's calendar.
        public let start: Date
        /// First day of the *next* bucket. The range is half-open, `[start, end)`.
        public let end: Date
        /// The sum of every charge in the bucket, converted to base. Charges with no
        /// rate contribute nothing here and are counted in `excludedCount`.
        public let charged: Decimal
        /// How many charges land in the bucket, including the excluded ones.
        public let count: Int
        /// How many of `count` had no conversion rate, so `charged` left them out. The
        /// honest-numbers footnote, applied to a bar.
        public let excludedCount: Int
        public let phase: Phase
        /// The whole bucket ends on or before the first date the document knows about,
        /// so a zero here means "no data", not "no spending". Always `true` when no
        /// subscription has an anchor at all.
        public let isBeforeRecord: Bool

        public var id: Date { start }

        /// Whether the bucket holds `today`, sits wholly behind it, or wholly ahead.
        ///
        /// `.current` is its own case rather than being folded into either side because
        /// the bar it describes is half history and half forecast, and a chart that
        /// paints it as one or the other is wrong twice a month.
        public enum Phase: String, Hashable, Sendable {
            case past
            case current
            case future
        }

        public init(
            start: Date,
            end: Date,
            charged: Decimal,
            count: Int,
            excludedCount: Int,
            phase: Phase,
            isBeforeRecord: Bool
        ) {
            self.start = start
            self.end = end
            self.charged = charged
            self.count = count
            self.excludedCount = excludedCount
            self.phase = phase
            self.isBeforeRecord = isBeforeRecord
        }
    }

    public let interval: SpendInterval
    public let buckets: [Bucket]
    /// The window actually covered, which is the requested one grown outwards to whole
    /// buckets. A half-drawn bar reads as a fall in spending rather than as a window
    /// that stopped early, so the timeline widens instead of truncating.
    public let start: Date
    public let end: Date
    /// The earliest date any subscription in the document can have been charged on: the
    /// oldest anchor. `nil` when no subscription has one.
    public let recordBegins: Date?
    /// The whole window, converted to base.
    public let charged: Decimal
    public let count: Int
    public let excludedCount: Int

    public init(
        interval: SpendInterval,
        buckets: [Bucket],
        start: Date,
        end: Date,
        recordBegins: Date?,
        charged: Decimal,
        count: Int,
        excludedCount: Int
    ) {
        self.interval = interval
        self.buckets = buckets
        self.start = start
        self.end = end
        self.recordBegins = recordBegins
        self.charged = charged
        self.count = count
        self.excludedCount = excludedCount
    }
}
