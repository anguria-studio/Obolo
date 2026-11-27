import Foundation

/// The fixed palette a subscription or category can be tinted with.
///
/// Store each tint by name so the app can resolve its system colour for the current appearance.
public enum Tint: String, Codable, Hashable, Sendable, CaseIterable {
    case accent
    case green
    case orange
    case red
    case yellow
    case purple
    case teal
    case pink
    case gray
    case cyan

    /// Human label for pickers.
    public var displayName: String {
        switch self {
        case .accent: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .red: "Red"
        case .yellow: "Yellow"
        case .purple: "Purple"
        case .teal: "Teal"
        case .pink: "Pink"
        case .gray: "Grey"
        case .cyan: "Cyan"
        }
    }

    /// The order categories and imported rows cycle through when they need a tint and
    /// nobody picked one. `.gray` is left out: it reads as "paused", not as a colour.
    public static let roundRobin: [Tint] = [
        .accent, .green, .orange, .purple, .cyan, .pink, .teal, .yellow, .red
    ]

    /// The tint at `index` in the round-robin, wrapping.
    public static func roundRobin(_ index: Int) -> Tint {
        let count = roundRobin.count
        let wrapped = ((index % count) + count) % count
        return roundRobin[wrapped]
    }

    /// Decodes unknown names to `.accent` rather than failing the whole document — a
    /// tint is decoration, and losing the user's subscriptions over one is not a trade
    /// worth making.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Tint(rawValue: raw) ?? .accent
    }
}
