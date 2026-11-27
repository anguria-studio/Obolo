import Foundation

/// State that belongs to one Mac and must never enter CloudKit records.
///
/// The main document remains portable. This value contains references to local
/// system objects, such as EventKit events, that have no meaning on another Mac.
public struct DeviceState: Codable, Hashable, Sendable {
    public var version: Int
    private var calendarEventIdentifiers: [String: String]
    public var lastCalendarSyncAt: Date?
    /// Whether this Mac may connect the portable document to the private iCloud
    /// database. The value is local because each Mac must opt in separately.
    public var cloudSyncEnabled: Bool

    public init(
        version: Int = DeviceState.currentVersion,
        calendarEventIdentifiers: [String: String] = [:],
        lastCalendarSyncAt: Date? = nil,
        cloudSyncEnabled: Bool = false
    ) {
        self.version = version
        self.calendarEventIdentifiers = calendarEventIdentifiers
        self.lastCalendarSyncAt = lastCalendarSyncAt
        self.cloudSyncEnabled = cloudSyncEnabled
    }

    public static let currentVersion = 2

    public static func initial() -> DeviceState {
        DeviceState()
    }

    public func calendarEventIdentifier(for subscriptionID: UUID) -> String? {
        calendarEventIdentifiers[subscriptionID.uuidString]
    }

    public var allCalendarEventIdentifiers: [String] {
        Array(calendarEventIdentifiers.values)
    }

    public mutating func setCalendarEventIdentifier(_ identifier: String?, for subscriptionID: UUID) {
        let key = subscriptionID.uuidString
        if let identifier {
            calendarEventIdentifiers[key] = identifier
        } else {
            calendarEventIdentifiers.removeValue(forKey: key)
        }
    }

    public mutating func removeAllCalendarEventIdentifiers() {
        calendarEventIdentifiers.removeAll()
    }

    private enum CodingKeys: String, CodingKey {
        case version, calendarEventIdentifiers, lastCalendarSyncAt, cloudSyncEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? DeviceState.currentVersion
        calendarEventIdentifiers = try container.decodeIfPresent(
            [String: String].self,
            forKey: .calendarEventIdentifiers
        ) ?? [:]
        lastCalendarSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastCalendarSyncAt)
        cloudSyncEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .cloudSyncEnabled
        ) ?? false
    }
}
