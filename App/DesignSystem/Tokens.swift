import SwiftUI
import OboloCore

/// The tint palette and size behind `IconInitial`: what is left of the system-colour
/// design that came before `DS`.
///
/// System colours give each of the ten tints a light and dark appearance.
enum Token {

    // MARK: - Tints

    /// The category / subscription palette.
    ///
    /// Every one of these has an AppKit name, which is the whole point: the system
    /// colour adapts to the appearance on its own. `.accent` additionally follows the
    /// user's accent selection in System Settings.
    static func color(_ tint: Tint) -> Color {
        switch tint {
        case .accent: Color(nsColor: .controlAccentColor)
        case .green:  Color(nsColor: .systemGreen)
        case .orange: Color(nsColor: .systemOrange)
        case .red:    Color(nsColor: .systemRed)
        case .yellow: Color(nsColor: .systemYellow)
        case .purple: Color(nsColor: .systemPurple)
        case .teal:   Color(nsColor: .systemTeal)
        case .pink:   Color(nsColor: .systemPink)
        case .gray:   Color(nsColor: .systemGray)
        case .cyan:   Color(nsColor: .systemCyan)
        }
    }

    /// The ink that sits *on* a solid tint fill — the letter in an icon initial.
    ///
    /// The prototype pairs each tint with a hand-picked foreground: near-black on the
    /// light tints (`#08240f` on green, `#04222c` on cyan), white on the dark ones.
    /// The split is by the tint's own luminance, and since the fill is the same
    /// saturated colour in both appearances, so is the answer — this token is one of
    /// the few that does not need a light variant.
    static func onTint(_ tint: Tint) -> Color {
        switch tint {
        case .green, .orange, .yellow, .teal, .cyan: .black.opacity(0.78)
        case .accent, .red, .purple, .pink, .gray:   .white
        }
    }

    // MARK: - Geometry

    enum Size {
        /// The circular tinted initial at its default size.
        static let initialSmall: CGFloat = 22
    }
}
