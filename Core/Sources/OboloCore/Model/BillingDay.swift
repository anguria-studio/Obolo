import Foundation

/// A Gregorian calendar day shared by every device. Convert to a local Date only
/// when doing calendar arithmetic or displaying the day.
public struct BillingDay: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ date: Date, calendar: Calendar) {
        let local = Self.gregorian(in: calendar.timeZone)
        let components = local.dateComponents([.year, .month, .day], from: date)
        year = components.year!
        month = components.month!
        day = components.day!
    }

    /// The latest day a device anywhere could have recorded at this instant.
    public static func latestWorldwide(at instant: Date) -> BillingDay {
        let easternmostZone = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        return BillingDay(instant, calendar: gregorian(in: easternmostZone))
    }

    /// Reads an ISO calendar day and checks that it exists before keeping it.
    public init?(isoDate: String) {
        let utc = Self.gregorian(in: .gmt)
        guard let date = ISODay.parse(isoDate, calendar: utc) else { return nil }
        self.init(date, calendar: utc)
    }

    public var isoDate: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func startOfDay(in calendar: Calendar) -> Date {
        let local = Self.gregorian(in: calendar.timeZone)
        let components = DateComponents(year: year, month: month, day: day)
        return local.startOfDay(for: local.date(from: components)!)
    }

    public static func < (lhs: BillingDay, rhs: BillingDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let day = BillingDay(isoDate: text), day.isoDate == text else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a calendar date in YYYY-MM-DD format.")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoDate)
    }

    private static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
