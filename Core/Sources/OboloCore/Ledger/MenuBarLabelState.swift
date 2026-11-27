import Foundation

/// What the status item draws beside its glyph.
///
/// There is no case for "something renews today". There was, and it overrode the
/// user's label style, which meant "Icon only" was icon only on most days and icon
/// plus text on the days a renewal happened to fall — the one thing a status item
/// must never do. Today's renewals are said in the morning's notification instead.
/// See `Ledger.menuBarLabel(style:locale:)`.
public enum MenuBarLabelState: Hashable, Sendable {
    /// Glyph alone, at full opacity.
    case iconOnly
    /// Glyph plus this label: "Netflix · in 2 days", "129 €".
    case text(String)
    /// Nothing tracked — glyph alone, dimmed.
    case empty

    /// The string to draw, if any.
    public var title: String? {
        switch self {
        case .text(let value): value
        case .iconOnly, .empty: nil
        }
    }

    /// The glyph is dimmed only when there is genuinely nothing to track.
    public var isDimmed: Bool {
        self == .empty
    }
}
