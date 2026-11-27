import Foundation

/// Twelve category hues with similar intensity, distinct from the orange action colour.
///
/// Separate from `Tint`, which subscriptions keep.
public enum CategoryHue: String, Codable, Hashable, Sendable, CaseIterable {
    case rose
    case magenta
    case violet
    case blue
    case sky
    case teal
    case mint
    case green
    case lime
    case olive
    case slate
    case gray

    public var displayName: String {
        switch self {
        case .rose: "Rose"
        case .magenta: "Magenta"
        case .violet: "Violet"
        case .blue: "Blue"
        case .sky: "Sky"
        case .teal: "Teal"
        case .mint: "Mint"
        case .green: "Green"
        case .lime: "Lime"
        case .olive: "Olive"
        case .slate: "Slate"
        case .gray: "Grey"
        }
    }

    /// The hues a new category cycles through when nobody picked one; grey and slate
    /// are left for the categories that mean "everything else".
    public static let roundRobin: [CategoryHue] = [
        .blue, .green, .violet, .sky, .rose, .teal, .lime, .magenta, .mint, .olive
    ]

    /// The hue at `index` in the round-robin, wrapping.
    public static func roundRobin(_ index: Int) -> CategoryHue {
        let count = roundRobin.count
        return roundRobin[((index % count) + count) % count]
    }
}
