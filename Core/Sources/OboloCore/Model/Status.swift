import Foundation

/// Where a subscription stands. Only `.active` and `.trial` count towards totals;
/// cancelled ones stay listed so the user can see what they stopped paying for.
///
/// `.paused` is no longer offered. It stays in the enum because old
/// store files, backups and another Mac's iCloud records can still carry the raw value,
/// and all of them must decode. `Subscription.resolvingLegacyPause(today:calendar:)`
/// turns it into `.cancelled` where data comes in, so the live document never holds it.
/// Nothing in the app creates it.
public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case paused
    case cancelled
    case trial

    public var displayName: String {
        switch self {
        case .active: "Active"
        // A paused row that has not been converted yet reads as what it becomes.
        case .paused, .cancelled: "Cancelled"
        case .trial: "Trial"
        }
    }

    /// Whether the subscription is still charging, and therefore whether it belongs in
    /// the monthly total, the upcoming list and the reminder schedule.
    public var isBilling: Bool {
        self == .active || self == .trial
    }

    /// Parses the `Status` column of a CSV, and the `Yes`/`No` of the Google Sheet's
    /// `Active` column.
    public init?(parsing text: String) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "yes", "y", "true", "1", "on": self = .active
        // Pause is gone: a paused row imports as cancelled.
        case "paused", "pause", "on hold", "hold": self = .cancelled
        case "cancelled", "canceled", "cancel", "no", "n", "false", "0", "off": self = .cancelled
        case "trial", "free trial": self = .trial
        default: return nil
        }
    }
}
